#!/usr/bin/env bash
# Lifeline native recomp: build-from-your-own-disc kit. Contains only our code;
# the game-derived ps2run binary is produced locally and must never be shared.
#
# usage: build.sh [path/to/your/Lifeline.iso] [workdir]
#   defaults: ISO=/home/deck/Downloads/Life Line (USA).iso, workdir=~/lifeline-recomp
#   (or set LIFELINE_ISO / LIFELINE_WORK). Everything lands under $HOME; no root, no system changes.
#   env: KIT_NO_CONTAINER=1   build directly on the host (dev box / non-SteamOS)
#        PORT_ARGS="..."      extra args for port.sh (default: --no-explore)
#        SKIP_VOSK=1          don't fetch Vosk lib/model
#        CPU_TUNED=1          -march=native + ThinLTO for this CPU (launcher: [build] cpu_tuned); falls back to generic
set -euo pipefail
T0=$SECONDS; TL=$SECONDS; phase() { local m="== [time $(date +%H:%M:%S)] $1: $((SECONDS-TL))s"; echo "$m"; echo "$m" >> "$PROG"; TL=$SECONDS; }
KIT="$(cd "$(dirname "$0")" && pwd)"
OURCODE="$(cd "$KIT/.." && pwd)"          # ourcode/: 0001, 0002, voice/
case "${1:-}" in -h|--help) sed -n 2,13p "$0"; exit 0;; esac
ISO="$(realpath "${1:-${LIFELINE_ISO:-/home/deck/Downloads/Life Line (USA).iso}}")"
WORK="$(realpath -m "${2:-${LIFELINE_WORK:-$HOME/lifeline-recomp}}")"
mkdir -p "$WORK"; PROG="$WORK/build-progress.log"; echo "== [time $(date +%H:%M:%S)] start${KIT_IN_BOX:+ (in container)}" >> "$PROG"; exec > >(tee -a "$WORK/build.log") 2>&1; echo "== [time $(date +%H:%M:%S)] start ($(nproc) cores)"
[ -f "$ISO" ] || { echo "ISO not found: $ISO" >&2; exit 1; }

UPSTREAM=https://github.com/snuri00/ps2-web-recomp
COMMIT=1b4808793a12c45125262fd2d5f50a9ec9f7c020     # exact commit tested
BOX=lifeline-build
IMAGE=${KIT_IMAGE:-quay.io/toolbx/arch-toolbox:latest}   # toolbox image: base pkgs preinstalled, far fewer mirror downloads

# --- On SteamOS: re-run inside a Distrobox (read-only root stays untouched) --
if [ -z "${KIT_NO_CONTAINER:-}" ] && [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ]; then
  command -v distrobox >/dev/null || { echo "distrobox not found (SteamOS 3.5+ ships it); or set KIT_NO_CONTAINER=1" >&2; exit 1; }
  distrobox list | grep -qw "$BOX" || { for i in 1 2 3; do distrobox create -Y -n "$BOX" -i "$IMAGE" && distrobox enter "$BOX" -- true && break; echo "container init failed (try $i), retrying" | tee -a "$PROG"; distrobox rm -f "$BOX" || true; sleep 20; done; }
  exec distrobox enter "$BOX" -- env KIT_IN_BOX=1 PORT_ARGS="${PORT_ARGS:-}" SKIP_VOSK="${SKIP_VOSK:-}" CPU_TUNED="${CPU_TUNED:-0}" CPU_MARCH="${CPU_MARCH:-}" bash "$0" "$ISO" "$WORK"
fi

# --- Dependencies (inside the container only) --------------------------------
if [ -n "${KIT_IN_BOX:-}" ] && command -v pacman >/dev/null; then
  # rootless podman: "sudo" here is root only inside the container
  for i in 1 2 3; do sudo pacman -Syu --disable-download-timeout --needed --noconfirm git cmake ninja clang python python-pip sdl2 libpulse pipewire vulkan-radeon vulkan-icd-loader lld curl unzip p7zip && break; sleep 15; done
fi
phase deps
for t in git cmake ninja clang++ python3 curl unzip; do command -v $t >/dev/null || { echo "missing $t" >&2; exit 1; }; done

# --- Source at the pinned commit + our patches -------------------------------
SRC="$WORK/ps2-web-recomp"
# Our patches, oldest first; see patches.sh for how applied ones are tracked.
PATCHES=(0001-usbmic-hle-and-deci2-nohost.patch 0002-ee-overrides-and-voice-stage-a-b.patch 0003-input-remap-hook.patch
         0004-audio-buffer-and-perf-log.patch 0005-hotkeys-and-clean-quit.patch 0006-vu-fast-interpreter-and-check.patch
         0007-save-state-slots.patch 0008-texture-upload-hook.patch
         0009-widescreen-present.patch
         0010-fast-forward.patch
         0011-pad-buttons-getter.patch
         0012-windows-build.patch)
if [ ! -d "$SRC/.git" ]; then
  git clone "$UPSTREAM" "$SRC"
  git -C "$SRC" checkout --detach "$COMMIT"
fi
# shellcheck source=steam-machine/patches.sh
source "$KIT/patches.sh"
apply_patches "$SRC" "$OURCODE" "${PATCHES[@]}"
phase clone+patch
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "unexpected commit in $SRC" >&2; exit 1; }

# --- port.sh (translate + native build) --------------------------------------
NAME=lifeline
V="$OURCODE/voice"
# every .cpp in voice/ and input/ (Vosk is dlopen'ed at run time, so no build-time libvosk)
VOICE_SRCS=$(printf '%s;' "$V"/*.cpp "$OURCODE"/input/*.cpp "$OURCODE"/icons/*.cpp "$OURCODE"/widescreen/*.cpp "$OURCODE"/fmv/*.cpp); VOICE_SRCS=${VOICE_SRCS%;}   # + remap, icons, widescreen, FMV skip
GAME="$SRC/games/$NAME"; GEN="$SRC/generated/$NAME"; NAT="$SRC/build/native-$NAME"
# shellcheck source=steam-machine/cpu_flags.sh
. "$KIT/cpu_flags.sh"
unset CPU_FLAVOR   # set by cpu_flags only; an inherited value would skip the flag selection
cpu_flags   # decided once: every configure below passes the same compiler/linker flags
configure() {
  cpu_cmake_args
  cmake -S "$SRC" -B "$NAT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++ \
      -DPS2_GENERATED="$GEN" -DPS2_EXTRA_SOURCES="$VOICE_SRCS" "${CPU_CMAKE_ARGS[@]}" >/dev/null
}
configure_existing() { [ ! -f "$NAT/build.ninja" ] || configure; }
# Keep a working game if any compile/link below fails: back up ps2run, put it back unless we finish.
BUILD_OK=""
# A ps2run.prev left behind means an earlier run was killed (SIGKILL skips the restore below): it is the
# last good binary, so put it back first.
# shellcheck source=steam-machine/ps2run_backup.sh
. "$KIT/ps2run_backup.sh"
restore_ps2run "$NAT" "restored ps2run from an interrupted build" || true
# A bad .prev (no matching sha256) was moved to ps2run.prev.bad by restore_ps2run, so this build still gets a backup.
if [ -e "$NAT/ps2run.prev" ]; then mv -f "$NAT/ps2run.prev" "$NAT/ps2run.prev.bad"; echo "moved the unusable ps2run.prev to ps2run.prev.bad" >&2; fi
backup_ps2run "$NAT" || echo "warning: could not back up ps2run" >&2
keep_old_ps2run() {
  if [ -z "$BUILD_OK" ]; then restore_ps2run "$NAT" "build failed: the previous ps2run was kept" >&2 || true; fi
}
trap keep_old_ps2run EXIT
# An existing build dir has the source list and flags of the previous build: refresh both before port.sh
# compiles, so new files (e.g. input/*.cpp) are linked, a flavor switch compiles once, and stale cached flags
# (e.g. -fuse-ld=lld with lld gone) can't fail the first compile. port.sh (upstream) configures a new build
# dir itself without our flags, so the very first install of a tuned build compiles twice.
configure_existing
# shellcheck disable=SC2086
port_with_fallback configure_existing "$SRC/scripts/port.sh" "$NAME" "$ISO" --native-only ${PORT_ARGS:---no-explore}
phase "port.sh (tools+translate+first compile)"

# --- Re-translate with the voice overrides, relink with the voice module ------
ELF="$GAME/disc/$(sed -n 's/^BOOT2 *= *//p' "$GAME/disc/SYSTEM.CNF" | tr -d '\r' | sed 's/.*\\//; s/;.*//')"
mods=(); [ -d "$GAME/modules" ] && mods=(--modules "$GAME/modules")
cat "$V/overrides.txt" "$OURCODE/widescreen/overrides.txt" "$OURCODE/fmv/overrides.txt" > "$WORK/overrides.txt"   # every EE hook address
"$SRC/build/tools/eerecomp" "$ELF" --entries "$GAME/entries.txt" "${mods[@]}" \
    --overrides "$WORK/overrides.txt" --out "$GEN" | tail -1
phase "re-translate with overrides"
FLAVOR_FILE="$WORK/build-flavor" build_native "$SRC" "$NAT" -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++ \
    -DPS2_GENERATED="$GEN" -DPS2_EXTRA_SOURCES="$VOICE_SRCS" || exit 1
BUILD_OK=1; drop_ps2run_backup "$NAT"
echo "== [time $(date +%H:%M:%S)] build flavor: $(head -1 "$WORK/build-flavor")" >> "$PROG"
# [qol] vu_fast self-check: random VU1 programs (no game data) through both interpreters; must all match. Non-fatal:
# a failure only means the toggle should stay off (run.sh falls back to the interpreter when it is off).
if VU_ST=$(PS2_VU_SELFTEST=5000 "$NAT/ps2run" 2>/dev/null | tail -1) && [[ $VU_ST == *" 0 mismatches"* ]]; then
  echo "== $VU_ST"; echo "== [time $(date +%H:%M:%S)] $VU_ST" >> "$PROG"
else echo "== WARNING: vu_fast selftest failed (${VU_ST:-no output}); keep [qol] vu_fast off" | tee -a "$PROG"; fi

phase "relink with voice module"
# --- Vosk 0.3.45 + model (fetched on the device, never bundled; loaded at run time) ---
VOSK_VER=0.3.45; MODEL=vosk-model-small-en-us-0.15      # model: Apache-2.0
VOSK_DIR="$WORK/vosk"; mkdir -p "$VOSK_DIR"
# sha256 of the exact files we tested (computed from the real downloads on 2026-10-13)
WHEEL=vosk-$VOSK_VER-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.whl
WHEEL_SHA=25e025093c4399d7278f543568ed8cc5460ac3a4bf48c23673ace1e25d26619f
MODEL_SHA=30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498
need_space() { local avail; avail=$(df -Pk "$1" | awk 'NR==2{print $4}'); [ "$avail" -ge $(($2*1024)) ] || { echo "not enough free space in $1: need ${2} MB" >&2; exit 1; }; }
fetch() {  # url dest sha256 -> verified file at dest (.part removed on any failure)
  local part="$2.part"; rm -f "$part"
  if ! curl -fL -o "$part" "$1"; then rm -f "$part"; echo "download failed: $1" >&2; return 1; fi
  if ! echo "$3  $part" | sha256sum -c --quiet -; then rm -f "$part"; echo "sha256 mismatch: $1" >&2; return 1; fi
  mv "$part" "$2"
}
if [ -z "${SKIP_VOSK:-}" ]; then
  if [ ! -f "$VOSK_DIR/vosk/libvosk.so" ]; then
    need_space "$VOSK_DIR" 40
    fetch "https://files.pythonhosted.org/packages/py3/v/vosk/$WHEEL" "$VOSK_DIR/$WHEEL" "$WHEEL_SHA" 2>/dev/null || true
    if [ ! -f "$VOSK_DIR/$WHEEL" ]; then   # fall back to pip's resolver, still verified
      python3 -m pip download --no-deps --only-binary=:all: --platform manylinux2010_x86_64 \
        --python-version 3 "vosk==$VOSK_VER" -d "$VOSK_DIR"      # PyPI wheel carries libvosk.so
      echo "$WHEEL_SHA  $VOSK_DIR/$WHEEL" | sha256sum -c --quiet - || { rm -f "$VOSK_DIR/$WHEEL"; echo "sha256 mismatch: $WHEEL" >&2; exit 1; }
    fi
    unzip -oq "$VOSK_DIR/$WHEEL" 'vosk/libvosk.so' -d "$VOSK_DIR"
  fi
  if [ ! -d "$VOSK_DIR/$MODEL" ]; then
    need_space "$VOSK_DIR" 200
    fetch "https://alphacephei.com/vosk/models/$MODEL.zip" "$VOSK_DIR/$MODEL.zip" "$MODEL_SHA" || exit 1
    unzip -oq "$VOSK_DIR/$MODEL.zip" -d "$VOSK_DIR"
  fi
fi
phase vosk
# --- Voice assets (context/word tables) extracted from YOUR ISO ---------------
# voice/tools/extract_assets.py runs voice/tools/{fat,arcx}.py with their baked-in dev-box paths
# swapped for this machine's ISO / OS.FAT / output dir (shared with windows/install.ps1).
ASSETS="$WORK/voice-assets"
if [ ! -d "$ASSETS" ] || [ -z "$(ls -A "$ASSETS")" ]; then
  python3 -I "$SRC/scripts/disc.py" extract "$GAME/disc.iso" "$WORK/iso-meta" OS.FAT > /dev/null
  # extract into a staging folder and rename it only when complete, so a half-finished extraction is never
  # taken for a finished one next time (same as windows/install.ps1)
  rm -rf "$ASSETS.partial"   # our own leftover from an interrupted run
  python3 "$V/tools/extract_assets.py" "$WORK/iso-meta/OS.FAT" "$(realpath "$GAME/disc.iso")" "$ASSETS.partial"
  [ -n "$(ls -A "$ASSETS.partial" 2>/dev/null)" ] || { echo "voice asset extraction wrote nothing" >&2; exit 1; }
  if [ -d "$ASSETS" ]; then rmdir "$ASSETS"; fi   # empty (checked above)
  mv "$ASSETS.partial" "$ASSETS"
fi
phase "voice assets"
# --- Launcher config ---------------------------------------------------------
mkdir -p "$WORK/saves"
cat > "$WORK/lifeline.env" <<ENV
SRC="$SRC"
PS2RUN="$NAT/ps2run"
ELF="$ELF"
ISO="$GAME/disc.iso"
MEMCARD="$WORK/saves/lifeline.ps2"
VOSK_DIR="$VOSK_DIR"
PS2_VOICE_VOSK_MODEL="$VOSK_DIR/$MODEL"
PS2_VOICE_VOSK_LIB="$VOSK_DIR/vosk/libvosk.so"
PS2_VOICE_ASSETS="$ASSETS"
ENV
install -m755 "$KIT/run.sh" "$WORK/run.sh"
install -m755 "$KIT/vu-check.sh" "$WORK/vu-check.sh"   # vu_fast check on states made here (see the script)
rm -rf "$WORK/icons.new"; cp -r "$OURCODE/icons/packs" "$WORK/icons.new" && rm -rf "$WORK/icons" && mv "$WORK/icons.new" "$WORK/icons"   # shipped icon packs (our art); user packs live in icons.local/, never touched
echo "== [time] total: $((SECONDS-T0))s" | tee -a "$PROG"
echo "== built. Launch with: $WORK/run.sh   (game-derived build; keep it on this machine)"

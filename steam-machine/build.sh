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
set -euo pipefail
T0=$SECONDS; TL=$SECONDS; phase() { local m="== [time $(date +%H:%M:%S)] $1: $((SECONDS-TL))s"; echo "$m"; echo "$m" >> "$PROG"; TL=$SECONDS; }
KIT="$(cd "$(dirname "$0")" && pwd)"
OURCODE="$(cd "$KIT/.." && pwd)"          # ourcode/: 0001, 0002, voice/
case "${1:-}" in -h|--help) sed -n 2,12p "$0"; exit 0;; esac
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
  exec distrobox enter "$BOX" -- env KIT_IN_BOX=1 PORT_ARGS="${PORT_ARGS:-}" SKIP_VOSK="${SKIP_VOSK:-}" bash "$0" "$ISO" "$WORK"
fi

# --- Dependencies (inside the container only) --------------------------------
if [ -n "${KIT_IN_BOX:-}" ] && command -v pacman >/dev/null; then
  # rootless podman: "sudo" here is root only inside the container
  for i in 1 2 3; do sudo pacman -Syu --disable-download-timeout --needed --noconfirm git cmake ninja clang python python-pip sdl2 libpulse pipewire vulkan-radeon vulkan-icd-loader curl unzip p7zip && break; sleep 15; done
fi
phase deps
for t in git cmake ninja clang++ python3 curl unzip; do command -v $t >/dev/null || { echo "missing $t" >&2; exit 1; }; done

# --- Source at the pinned commit + our patches -------------------------------
SRC="$WORK/ps2-web-recomp"
if [ ! -d "$SRC/.git" ]; then
  git clone "$UPSTREAM" "$SRC"
  git -C "$SRC" checkout --detach "$COMMIT"
  git -C "$SRC" apply --index "$OURCODE/0001-usbmic-hle-and-deci2-nohost.patch"
  git -C "$SRC" apply --index "$OURCODE/0002-ee-overrides-and-voice-stage-a-b.patch"
fi
phase clone+patch
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "unexpected commit in $SRC" >&2; exit 1; }

# --- port.sh (translate + native build) --------------------------------------
NAME=lifeline
# shellcheck disable=SC2086
"$SRC/scripts/port.sh" "$NAME" "$ISO" --native-only ${PORT_ARGS:---no-explore}
phase "port.sh (tools+translate+first compile)"

# --- Re-translate with the voice overrides, relink with the voice module ------
V="$OURCODE/voice"
# every .cpp in voice/ (Vosk is dlopen'ed at run time, so no build-time libvosk)
VOICE_SRCS=$(printf '%s;' "$V"/*.cpp); VOICE_SRCS=${VOICE_SRCS%;}
GAME="$SRC/games/$NAME"; GEN="$SRC/generated/$NAME"; NAT="$SRC/build/native-$NAME"
ELF="$GAME/disc/$(sed -n 's/^BOOT2 *= *//p' "$GAME/disc/SYSTEM.CNF" | tr -d '\r' | sed 's/.*\\//; s/;.*//')"
mods=(); [ -d "$GAME/modules" ] && mods=(--modules "$GAME/modules")
"$SRC/build/tools/eerecomp" "$ELF" --entries "$GAME/entries.txt" "${mods[@]}" \
    --overrides "$V/overrides.txt" --out "$GEN" | tail -1
phase "re-translate with overrides"
cmake -S "$SRC" -B "$NAT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++ \
    -DPS2_GENERATED="$GEN" \
    -DPS2_EXTRA_SOURCES="$VOICE_SRCS" >/dev/null
ninja -C "$NAT" ps2run > "$NAT/ninja.log" 2>&1 || { tail -30 "$NAT/ninja.log"; exit 1; }

phase "relink with voice module"
# --- Vosk 0.3.45 + model (fetched on the device, never bundled; loaded at run time) ---
VOSK_VER=0.3.45; MODEL=vosk-model-small-en-us-0.15      # model: Apache-2.0
VOSK_DIR="$WORK/vosk"; mkdir -p "$VOSK_DIR"
if [ -z "${SKIP_VOSK:-}" ]; then
  if [ ! -f "$VOSK_DIR/vosk/libvosk.so" ]; then
    python3 -m pip download --no-deps --only-binary=:all: --platform manylinux2010_x86_64 \
      --python-version 3 "vosk==$VOSK_VER" -d "$VOSK_DIR"      # PyPI wheel carries libvosk.so
    unzip -oq "$VOSK_DIR"/vosk-$VOSK_VER-*.whl 'vosk/libvosk.so' -d "$VOSK_DIR"
  fi
  if [ ! -d "$VOSK_DIR/$MODEL" ]; then
    curl -fL -o "$VOSK_DIR/$MODEL.zip" "https://alphacephei.com/vosk/models/$MODEL.zip"
    unzip -oq "$VOSK_DIR/$MODEL.zip" -d "$VOSK_DIR"
  fi
fi
phase vosk
# --- Voice assets (context/word tables) extracted from YOUR ISO ---------------
# voice/tools/{fat,arcx}.py have dev-box paths baked in; run them unmodified with
# those three paths swapped for this machine's ISO / OS.FAT / output dir.
ASSETS="$WORK/voice-assets"
if [ ! -d "$ASSETS" ] || [ -z "$(ls -A "$ASSETS")" ]; then
  python3 -I "$SRC/scripts/disc.py" extract "$GAME/disc.iso" "$WORK/iso-meta" OS.FAT > /dev/null
  python3 - "$V/tools" "$WORK/iso-meta/OS.FAT" "$(realpath "$GAME/disc.iso")" "$ASSETS" <<'PY'
import os, sys
tools, fat, iso, out = sys.argv[1:]
src = open(os.path.join(tools, 'arcx.py')).read()
fatsrc = open(os.path.join(tools, 'fat.py')).read().split('for e in ents')[0]
src = src.replace("exec(open(os.path.join(os.path.dirname(__file__),'fat.py')).read().split('for e in ents')[0])", 'exec(FATSRC)')
fatsrc = fatsrc.replace('<repo-root>/private/iso/OS.FAT', fat)
src = src.replace('<repo-root>/dump/Life Line (USA).iso', iso).replace('<repo-root>/private/asr_files', out)
g = {'__file__': os.path.join(tools, 'arcx.py'), '__name__': '__main__', 'FATSRC': fatsrc}
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    exec(compile(src, 'arcx.py', 'exec'), g)
print('voice assets:', len(os.listdir(out)), 'folders')
PY
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
echo "== [time] total: $((SECONDS-T0))s" | tee -a "$PROG"
echo "== built. Launch with: $WORK/run.sh   (game-derived build; keep it on this machine)"

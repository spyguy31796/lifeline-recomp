#!/usr/bin/env bash
# shellcheck disable=SC2015   # ok/bad always succeed, so A && ok || bad is safe
# Upgrade test for build.sh (needs a built workdir to seed from, your ISO, and the repo with git history):
#   steam-machine/tests/build-upgrade-test.sh <built-workdir> <iso> <scratch-dir> [old-ref]
# 1. copies the workdir to scratch, resets its checkout to 0001-0004 (old-ref, default: before 0005) and
#    builds an old ps2run with the old kit's source list, like a device on the previous release;
# 2. runs the new build.sh (must apply 0005 and link with input/hotkeys.cpp), then again (idempotent);
# 3. runs it with a source that can't link: the build must fail and keep the previous ps2run.
# Everything stays in scratch (game-derived; keep it on this machine).
set -euo pipefail
SEED=$1; ISO=$2; T=$3; OLD=${4:-505f384^1}
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
has_hotkeys() { nm "$1" > "$T/nm.txt"; grep -q lifeline_hotkeys "$T/nm.txt"; }   # no pipe: grep -q + pipefail = SIGPIPE
rm -rf "$T"; mkdir -p "$T"; cp -a "$SEED" "$T/work"
W="$T/work"; S="$W/ps2-web-recomp"; N="$S/build/native-lifeline"
rm -rf "$S/build"   # a copied CMake build dir points at the seed; the old build is rebuilt here
git -C "$REPO" worktree add -f --detach "$T/oldkit" "$OLD" >/dev/null 2>&1
rm -f "$S/.git/lifeline-patches"
git -C "$S" reset -q --hard
for p in 0001-usbmic-hle-and-deci2-nohost 0002-ee-overrides-and-voice-stage-a-b 0003-input-remap-hook 0004-audio-buffer-and-perf-log; do
  git -C "$S" apply --index "$T/oldkit/$p.patch"
done
OLDSRCS=$(printf '%s;' "$T"/oldkit/voice/*.cpp "$T"/oldkit/input/*.cpp); OLDSRCS=${OLDSRCS%;}
cmake -S "$S" -B "$N" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++ -DPS2_GENERATED="$S/generated/lifeline" \
    -DPS2_EXTRA_SOURCES="$OLDSRCS" >/dev/null && ninja -C "$N" ps2run >/dev/null
has_hotkeys "$N/ps2run" && bad "old ps2run already has hotkeys" || ok "old release state: 0001-0004, old build dir, ps2run without hotkeys"

run() { KIT_NO_CONTAINER=1 SKIP_VOSK=1 bash "$1/steam-machine/build.sh" "$ISO" "$W" > "$T/build-$2.log" 2>&1; }
if run "$REPO" 1; then ok "upgrade build exit 0"; else bad "upgrade build failed"; tail -20 "$T/build-1.log"; fi
grep -q "patches already applied: .*0004-audio-buffer-and-perf-log.patch" "$T/build-1.log" && grep -q "applied 0005-hotkeys-and-clean-quit.patch" "$T/build-1.log" \
  && ok "detected 0001-0004, applied 0005" || bad "patch detection"
has_hotkeys "$N/ps2run" && ok "ps2run links the hotkey code" || bad "no hotkey code in ps2run"
[ "$(wc -l < "$S/.git/lifeline-patches")" = 5 ] && ok "marker lists 5 patches" || bad "marker"
[ ! -e "$N/ps2run.prev" ] && ok "backup removed after success" || bad "ps2run.prev left behind"
h1=$(git -C "$S" diff --cached | sha256sum)
if run "$REPO" 2; then ok "second run exit 0"; else bad "second run failed"; tail -20 "$T/build-2.log"; fi
grep -q "applied 0" "$T/build-2.log" && bad "second run applied a patch again" || ok "second run applied nothing"
[ "$(git -C "$S" diff --cached | sha256sum)" = "$h1" ] && ok "source tree unchanged by the second run" || bad "tree changed"

# a kit whose sources can't link: the old ps2run must survive
cp -a "$REPO" "$T/badkit"; rm -rf "$T/badkit/.git"
printf 'int lifeline_missing_symbol();\nint lifeline_force_link_error() { return lifeline_missing_symbol(); }\n' > "$T/badkit/input/zz_link_error.cpp"
before=$(sha256sum < "$N/ps2run")
if run "$T/badkit" 3; then bad "broken kit built"; else ok "broken kit fails"; fi
grep -q "previous ps2run was kept" "$T/build-3.log" && ok "failure message" || bad "no keep message"
[ -x "$N/ps2run" ] && [ "$(sha256sum < "$N/ps2run")" = "$before" ] && ok "previous ps2run kept (same sha256)" || bad "ps2run lost or changed"
git -C "$REPO" worktree remove --force "$T/oldkit" >/dev/null 2>&1 || true
[ "$fail" = 0 ] && echo "build upgrade test passed" || echo "build upgrade test FAILED"
exit "$fail"

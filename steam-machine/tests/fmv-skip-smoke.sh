#!/usr/bin/env bash
# FMV skip smoke (needs a built workdir, skip_*.state mid-movie, game-derived; stays local):
#   steam-machine/tests/fmv-skip-smoke.sh <workdir> <state> [press-frame]
# Loads a mid-movie state, presses Start shortly after, and checks: with PS2_FMV_SKIP=1 the movie is
# skipped (log) and the game keeps running past the skip; with the gate off, Start does not skip.
# Also: Cross alone does not skip; the full-screen path is logged.
# shellcheck disable=SC2015
set -uo pipefail
W=$1; STATE=$2; PRESS=${3:-38760}
T=$(mktemp -d); fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
. "$W/lifeline.env"
END=$((PRESS + 800))
run() {   # run <log> <press-spec> [env...]
  local log=$1 press=$2; shift 2
  env "$@" PS2_VOICE_CONTEXT=013.a/os_601 "$PS2RUN" "$ELF" --disc "$ISO" --memcard "$T/mc.ps2" \
    --load-state "$STATE" --frames "$END" --press "$press" > "$log" 2>&1
}
: > "$T/mc.ps2"
run "$T/on.log" "${PRESS}:start:4" PS2_FMV_SKIP=1
grep -q "^\[fmv\] skip on" "$T/on.log" && ok "FMV skip registered" || bad "no [fmv] skip on"
grep -q "^\[fmv\] full-screen movie:" "$T/on.log" && ok "full-screen path: $(grep -m1 '^\[fmv\] full-screen movie:' "$T/on.log")" || bad "no full-screen movie log (caller gate?)"
grep -q "^\[fmv\] skipped " "$T/on.log" && ok "movie skipped on Start: $(grep '^\[fmv\] skipped' "$T/on.log")" || bad "movie not skipped"
grep -q "frame limit reached" "$T/on.log" && ok "emulation continued after skip" || bad "run did not finish"
run "$T/off.log" "${PRESS}:start:4"
grep -q "^\[fmv\] skipped" "$T/off.log" && bad "skipped with the gate off" || ok "Start ignored with the gate off"
run "$T/cross.log" "${PRESS}:cross:4" PS2_FMV_SKIP=1
grep -q "^\[fmv\] skipped" "$T/cross.log" && bad "Cross skipped a movie" || ok "Cross alone does not skip"
cp "$T/on.log" "${FMV_SMOKE_LOG:-/dev/null}" 2>/dev/null || true
rm -rf "$T"
[ $fail = 0 ] && echo "fmv-skip smoke passed" || { echo "fmv-skip smoke FAILED"; exit 1; }

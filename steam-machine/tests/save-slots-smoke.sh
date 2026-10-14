#!/usr/bin/env bash
# Headless check of the save-slot hotkeys on a built install (needs Xvfb + xdotool):
#   xvfb-run -a steam-machine/tests/save-slots-smoke.sh [~/lifeline-recomp/run.sh]
# F5 saves slot 1, F6 picks slot 2, a short F8 tap does not load, holding F8 loads slot 2 (empty -> refused),
# F6 x3 back to slot 1, holding F8 loads it; the voice side is reset; the game keeps running; Esc hold quits.
set -uo pipefail
RUN=${1:-$HOME/lifeline-recomp/run.sh}
HERE_RUN=$(dirname "$RUN"); LOG=$(mktemp)
rm -f "$HERE_RUN"/saves/slot[1-4].state "$HERE_RUN"/saves/slot[1-4].voice "$HERE_RUN"/saves/before-load.state
export SDL_AUDIODRIVER=dummy PS2_SDL_RENDERER=1 PS2_SAVE_SLOTS=1
"$RUN" >"$LOG" 2>&1 &
pid=$!
w=""
for _ in $(seq 60); do w=$(xdotool search --name "ps2-web-recomp" 2>/dev/null | head -1); [ -n "$w" ] && break; sleep 0.5; done
[ -n "$w" ] || { echo "FAIL: no window"; tail "$LOG"; kill "$pid" 2>/dev/null; exit 1; }
sleep 8; xdotool windowfocus --sync "$w"
fail=0
xdotool key F5; sleep 3
[ -s "$HERE_RUN/saves/slot1.state" ] && [ ! -e "$HERE_RUN/saves/slot1.state.tmp" ] || { echo "FAIL: slot 1 not saved"; fail=1; }
[ -e "$HERE_RUN/saves/slot1.voice" ] || { echo "FAIL: no slot1.voice"; fail=1; }
xdotool key F6; sleep 0.5
xdotool keydown F8; sleep 0.2; xdotool keyup F8; sleep 1   # tap: no load
xdotool keydown F8; sleep 0.8; xdotool keyup F8; sleep 1   # slot 2 is empty
for _ in 1 2 3; do xdotool key F6; sleep 0.4; done   # one press per frame poll
xdotool keydown F8; sleep 0.8; xdotool keyup F8; sleep 4
kill -0 "$pid" 2>/dev/null || { echo "FAIL: game exited after the load"; fail=1; }
xdotool keydown Escape; sleep 1.4; xdotool keyup Escape
for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
kill -0 "$pid" 2>/dev/null && { echo "FAIL: still running"; kill "$pid"; fail=1; }
wait "$pid"; rc=$?
grep -q "\[slots\] saved slot 1" "$LOG" || { echo "FAIL: no save log"; fail=1; }
grep -q "\[slots\] slot 2 is empty" "$LOG" || { echo "FAIL: empty slot not refused"; fail=1; }
[ "$(grep -c '\[state\] loaded' "$LOG")" = 1 ] || { echo "FAIL: expected exactly one load (tap must not load)"; fail=1; }
grep -q "\[slots\] loaded slot 1" "$LOG" || { echo "FAIL: slot 1 not loaded"; fail=1; }
[ -s "$HERE_RUN/saves/before-load.state" ] || { echo "FAIL: no before-load backup"; fail=1; }
[ "${PS2_VOICE_OFF:-0}" = 1 ] || grep -q "\[voice\] .*state loaded" "$LOG" || { echo "FAIL: voice not reset after load"; fail=1; }
[ "$rc" = 0 ] || { echo "FAIL: exit $rc"; fail=1; }
grep -E "\[slots\]|\[state\]|\[voice\] .*state loaded|halted" "$LOG"
[ "$fail" = 0 ] && echo "save-slot smoke passed (exit $rc)"
rm -f "$LOG"; exit "$fail"

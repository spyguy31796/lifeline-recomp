#!/usr/bin/env bash
# Headless check of the save-slot hotkeys on a built install (needs Xvfb + xdotool):
#   xvfb-run -a steam-machine/tests/save-slots-smoke.sh [~/lifeline-recomp/run.sh]
# F5 saves slot 1, F6 picks slot 2, a short F8 tap does not load, holding F8 loads slot 2 (empty -> refused),
# F6 x3 back to slot 1, holding F8 loads it; the voice side is reset; the game keeps running; Esc hold quits.
set -uo pipefail
RUN=${1:-$HOME/lifeline-recomp/run.sh}
HERE_RUN=$(dirname "$RUN"); LOG=$(mktemp)
rm -rf "$HERE_RUN"/saves/slot[1-4].state "$HERE_RUN"/saves/slot[1-4].voice "$HERE_RUN"/saves/before-load.state "$HERE_RUN"/saves/before-load.state.tmp
export SDL_AUDIODRIVER=dummy PS2_SDL_RENDERER=1 PS2_SAVE_SLOTS=1
# Own process group (setsid; run.sh execs env -> ps2run, so $pid is ps2run and the group leader). Cleanup kills only
# that group, never by name: other agents run ps2run on the same machine.
setsid "$RUN" >"$LOG" 2>&1 &
pid=$!
cleanup() {
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null
    for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -KILL -- "-$pid" 2>/dev/null
  fi
  rm -f "$LOG"
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM   # interrupted: exit, so the EXIT trap still cleans up
# Find our window by PID (_NET_WM_PID), not by title; fall back to any window in our process group.
find_window() {
  local p w
  for p in $(pgrep -g "$pid" 2>/dev/null || echo "$pid"); do
    w=$(xdotool search --onlyvisible --pid "$p" 2>/dev/null | head -1); [ -n "$w" ] && { echo "$w"; return; }
    w=$(xdotool search --pid "$p" 2>/dev/null | tail -1); [ -n "$w" ] && { echo "$w"; return; }
  done
}
w=""
for _ in $(seq 60); do w=$(find_window); [ -n "$w" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
[ -n "$w" ] || { echo "FAIL: no window"; tail "$LOG"; exit 1; }
sleep 8; xdotool windowfocus --sync "$w"
fail=0
xdotool key F5; sleep 3
[ -s "$HERE_RUN/saves/slot1.state" ] && [ ! -e "$HERE_RUN/saves/slot1.state.tmp" ] || { echo "FAIL: slot 1 not saved"; fail=1; }
[ -e "$HERE_RUN/saves/slot1.voice" ] || { echo "FAIL: no slot1.voice"; fail=1; }
xdotool key F6; sleep 0.5
xdotool keydown F8; sleep 0.2; xdotool keyup F8; sleep 1   # tap: no load
xdotool keydown F8; sleep 0.8; xdotool keyup F8; sleep 1   # slot 2 is empty
for _ in 1 2 3; do xdotool key F6; sleep 0.4; done   # one press per frame poll
# the before-load backup can't be written (its .tmp is a directory): the load must be refused, not attempted
mkdir -p "$HERE_RUN/saves/before-load.state.tmp"
xdotool keydown F8; sleep 0.8; xdotool keyup F8; sleep 3
rm -rf "$HERE_RUN/saves/before-load.state.tmp"   # before() removes an empty one itself
grep -q "\[slots\] load slot 1 refused" "$LOG" || { echo "FAIL: load not refused when the backup can't be kept"; fail=1; }
grep -q "\[state\] loaded" "$LOG" && { echo "FAIL: a refused load still loaded"; fail=1; }
grep -q "restoring the game from before" "$LOG" && { echo "FAIL: a refused load took the restore path"; fail=1; }
kill -0 "$pid" 2>/dev/null || { echo "FAIL: game exited after the refused load"; fail=1; }
xdotool keydown F8; sleep 0.8; xdotool keyup F8; sleep 4
kill -0 "$pid" 2>/dev/null || { echo "FAIL: game exited after the load"; fail=1; }
xdotool keydown Escape; sleep 1.4; xdotool keyup Escape
for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$pid" 2>/dev/null; then   # never wait on a game that ignored the quit: kill our group now
  echo "FAIL: still running"; fail=1; kill -KILL -- "-$pid" 2>/dev/null
fi
wait "$pid"; rc=$?
grep -q "\[slots\] saved slot 1" "$LOG" || { echo "FAIL: no save log"; fail=1; }
grep -q "\[slots\] slot 2 is empty" "$LOG" || { echo "FAIL: empty slot not refused"; fail=1; }
[ "$(grep -c '\[state\] loaded' "$LOG")" = 1 ] || { echo "FAIL: expected exactly one load (tap must not load)"; fail=1; }
grep -q "\[slots\] loaded slot 1" "$LOG" || { echo "FAIL: slot 1 not loaded"; fail=1; }
[ -s "$HERE_RUN/saves/before-load.state" ] || { echo "FAIL: no before-load backup"; fail=1; }
ls "$HERE_RUN"/saves/*.tmp >/dev/null 2>&1 && { echo "FAIL: .tmp left in saves/"; fail=1; }   # state, voice and backup are all renamed into place
[ "${PS2_VOICE_OFF:-0}" = 1 ] || grep -q "\[voice\] .*state loaded" "$LOG" || { echo "FAIL: voice not reset after load"; fail=1; }
[ "$rc" = 0 ] || { echo "FAIL: exit $rc"; fail=1; }
grep -E "\[slots\]|\[ee\]|\[state\]|\[voice\] .*state loaded|halted" "$LOG"
[ "$fail" = 0 ] && echo "save-slot smoke passed (exit $rc)"
exit "$fail"

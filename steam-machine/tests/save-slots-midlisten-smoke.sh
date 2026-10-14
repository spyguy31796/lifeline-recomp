#!/usr/bin/env bash
# Headless check: a slot saved mid-listen must listen on the next Circle press (cmd 1 then 2), not only stop.
#   xvfb-run -a steam-machine/tests/save-slots-midlisten-smoke.sh [~/lifeline-recomp/run.sh]
# Needs a skip-tutorial state (saves/room001.state from make-skip-state.sh) and an install with voice on.
set -uo pipefail
RUN=${1:-$HOME/lifeline-recomp/run.sh}
HERE=$(dirname "$RUN"); LOG=$(mktemp); MID=$(mktemp --suffix=.state)
source "$HERE/lifeline.env"
[ -f "$HERE/saves/room001.state" ] || { echo "FAIL: no $HERE/saves/room001.state (run make-skip-state.sh)"; exit 1; }
[ -x "$PS2RUN" ] || { echo "FAIL: no ps2run"; exit 1; }

# 1) Capture a mid-listen state: hold Circle across the save frame so CCanesVoice+0x10 and kState are listening.
#    CLI --save-state is not gated by voice_busy, so this is allowed (hotkey save would refuse).
#    --frames / --press / --save-state use absolute frame numbers (the loaded state's frame, not offsets).
rm -rf "$HERE"/saves/slot[1-4].state "$HERE"/saves/slot[1-4].voice "$HERE"/saves/before-load.state*
export SDL_AUDIODRIVER=dummy PS2_SDL_RENDERER=1 PS2_GPU_LOW_POWER=1 PS2_VOICE_DEBUG=1
export PS2_VOICE_CONTEXT=013.a/os_601 PS2_VOICE_ASSETS
F0=$("$PS2RUN" "$ELF" --disc "$ISO" --load-state "$HERE/saves/room001.state" --frames 1 2>&1 | sed -n 's/.*loaded frame \([0-9]*\).*/\1/p' | tail -1)
[ -n "$F0" ] || { echo "FAIL: could not read room001 frame"; exit 1; }
"$PS2RUN" "$ELF" --disc "$ISO" --load-state "$HERE/saves/room001.state" \
  --press $((F0+100)):circle:200 --save-state "$((F0+150)):$MID" --frames $((F0+160)) >"$LOG" 2>&1 || true
[ -s "$MID" ] || { echo "FAIL: no mid-listen state"; tail -30 "$LOG"; exit 1; }
grep -aq "cmd 1 " "$LOG" || { echo "FAIL: circle did not start listening while capturing"; tail -40 "$LOG"; exit 1; }
cp -f "$MID" "$HERE/saves/slot1.state"
printf '013.a/os_601\n' > "$HERE/saves/slot1.voice"
# Inject a phrase so the stop after one press yields a recognition (no mic needed).
INJ=$(mktemp)
# frame 0 = next listen; try_inject writes the result even if the word is not in the current VGP
echo "0 Hello" > "$INJ"

# 2) Load that slot via the hotkey path (the only path that calls lifeline_voice_after_load), then one Circle press.
rm -f "$LOG"; LOG=$(mktemp)
export PS2_SAVE_SLOTS=1 PS2_VOICE_INJECT="$INJ" PS2_VOICE_CONTEXT=013.a/os_601
setsid "$RUN" --load-state "$HERE/saves/room001.state" >"$LOG" 2>&1 &
pid=$!
cleanup() {
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null
    for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -KILL -- "-$pid" 2>/dev/null
  fi
  rm -f "$LOG" "$LOG.after" "$MID" "$INJ"
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM
find_window() {
  local p w
  for p in $(pgrep -g "$pid" 2>/dev/null || echo "$pid"); do
    w=$(xdotool search --onlyvisible --pid "$p" 2>/dev/null | head -1); [ -n "$w" ] && { echo "$w"; return; }
    w=$(xdotool search --pid "$p" 2>/dev/null | tail -1); [ -n "$w" ] && { echo "$w"; return; }
  done
}
w=""; for _ in $(seq 60); do w=$(find_window); [ -n "$w" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
[ -n "$w" ] || { echo "FAIL: no window"; tail "$LOG"; exit 1; }
sleep 6; xdotool windowfocus --sync "$w"
fail=0
# F8 hold loads slot 1 (the mid-listen capture). after_load must clear the game listening flag.
xdotool keydown F8; sleep 0.8; xdotool keyup F8; sleep 3
grep -q "\[slots\] loaded slot 1" "$LOG" || { echo "FAIL: slot 1 not loaded"; fail=1; }
grep -q "game was listening, reset to idle" "$LOG" || { echo "FAIL: the slot was not mid-listen on the game side"; fail=1; }
# One Circle press (keyboard X = Circle). Must issue cmd 1 on press and cmd 2 on release.
xdotool keydown x; sleep 0.6; xdotool keyup x; sleep 2
# After the load, the first cmd 1 / cmd 2 pair is the one we care about (ignore any from before the load).
after=$(grep -n "\[slots\] loaded slot 1" "$LOG" | tail -1 | cut -d: -f1)
[ -n "$after" ] || after=1
tail -n +"$after" "$LOG" > "$LOG.after"
# Expect start then stop, in that order, after the load.
cmd1=$(grep -n "cmd 1 " "$LOG.after" | head -1 | cut -d: -f1)
cmd2=$(grep -n "cmd 2 " "$LOG.after" | head -1 | cut -d: -f1)
[ -n "$cmd1" ] || { echo "FAIL: no cmd 1 after load (first press lost)"; fail=1; }
[ -n "$cmd2" ] || { echo "FAIL: no cmd 2 after load"; fail=1; }
[ -n "$cmd1" ] && [ -n "$cmd2" ] && [ "$cmd1" -lt "$cmd2" ] || { echo "FAIL: expected cmd 1 before cmd 2 (got cmd1=$cmd1 cmd2=$cmd2)"; fail=1; }
# A lone cmd 2 with no prior cmd 1 after the load is the bug.
if [ -z "$cmd1" ] && [ -n "$cmd2" ]; then echo "FAIL: stop without start (mid-listen flag not cleared)"; fail=1; fi
# The stop after that one press must deliver a recognition (the injected phrase).
grep -q "injected '" "$LOG.after" || { echo "FAIL: the word was not recognized after one press"; fail=1; }
xdotool keydown Escape; sleep 1.4; xdotool keyup Escape
for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
kill -0 "$pid" 2>/dev/null && { echo "FAIL: still running"; fail=1; kill -KILL -- "-$pid" 2>/dev/null; }
grep -E "\[slots\] loaded|cmd [12] |state loaded|injected" "$LOG" | tail -40
[ "$fail" = 0 ] && echo "save-slot mid-listen smoke passed"
exit "$fail"

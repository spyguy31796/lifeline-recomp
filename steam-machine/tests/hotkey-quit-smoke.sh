#!/usr/bin/env bash
# Headless check of the in-game hotkeys on a built install (needs Xvfb + xdotool):
#   xvfb-run -a steam-machine/tests/hotkey-quit-smoke.sh [~/lifeline-recomp/run.sh]
# A 0.3 s Esc tap must not quit, F11 toggles fullscreen, holding Esc 1.4 s quits and run.sh exits 0.
set -uo pipefail
RUN=${1:-$HOME/lifeline-recomp/run.sh}
LOG=$(mktemp)
export SDL_AUDIODRIVER=dummy PS2_SDL_RENDERER=1 PS2_VOICE_OFF=1
"$RUN" >"$LOG" 2>&1 &
pid=$!
w=""
for _ in $(seq 60); do w=$(xdotool search --name "ps2-web-recomp" 2>/dev/null | head -1); [ -n "$w" ] && break; sleep 0.5; done
[ -n "$w" ] || { echo "FAIL: no window"; tail "$LOG"; kill "$pid" 2>/dev/null; exit 1; }
sleep 6; xdotool windowfocus --sync "$w"
fail=0
xdotool keydown Escape; sleep 0.3; xdotool keyup Escape; sleep 2
kill -0 "$pid" 2>/dev/null || { echo "FAIL: a short Esc tap quit"; fail=1; }
xdotool key F11; sleep 1
xdotool keydown Escape; sleep 0.6
title=$(xdotool getwindowname "$w"); echo "title during hold: $title"
case "$title" in "Hold to quit"*) ;; *) echo "FAIL: no hold hint in the title"; fail=1;; esac
sleep 0.8; xdotool keyup Escape
for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$pid" 2>/dev/null; then echo "FAIL: still running after the quit hold"; exit 1; fi
wait "$pid"; rc=$?
grep -q "\[hotkey\] fullscreen" "$LOG" || { echo "FAIL: F11 not seen"; fail=1; }
grep -q "halted: quit hotkey" "$LOG" || { echo "FAIL: no clean halt"; fail=1; }
[ "$rc" = 0 ] || { echo "FAIL: exit $rc"; fail=1; }
grep -E "\[hotkey\]|halted|\[window\] exit|\[mc\]" "$LOG"
[ "$fail" = 0 ] && echo "hotkey smoke passed (exit $rc)"
rm -f "$LOG"; exit "$fail"

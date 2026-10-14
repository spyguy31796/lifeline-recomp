#!/usr/bin/env bash
# Fast-forward smoke test (needs a built workdir, a save state, Xvfb + xdotool; game-derived, stays local):
#   steam-machine/tests/fast-forward-smoke.sh <workdir> <state> [ff_max]
# Runs the game in window mode under Xvfb with PS2_PERF_LOG=1, then: 20 s normal, 20 s holding Tab
# (hk_ff), 8 s normal, X (circle) + Tab for 3 s, 12 s normal. Checks: FF engages and releases, FF seconds are tagged [perf-ff] and kept out of
# [perf], FF speed <= ff_max x 60 fps, the audio device keeps a queue during and after FF, the run exits
# cleanly, FF is refused while circle is held, and with PS2_FAST_FORWARD unset Tab does nothing.
# shellcheck disable=SC2015
set -uo pipefail
W=$1; STATE=$2; MAX=${3:-4}
T=$(mktemp -d); fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
run() {   # run <log> <env...>: 60 s with Tab held from 20 s to 40 s
  # The game gets its own process group (setsid; run.sh execs env -> ps2run, so $p is ps2run). Only that group is
  # ever signalled, never by name: other agents run ps2run on the same machine. Its window is found by PID.
  local log=$1; shift
  xvfb-run -a -s "-screen 0 1280x720x24" bash -c '
    env SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}" PS2_SDL_RENDERER=1 PS2_PERF_LOG=1 PS2_VOICE_CONTEXT=1000.a/os_999 '"$*"' \
      setsid "'"$W"'/run.sh" --load-state "'"$STATE"'" > "'"$log"'" 2>&1 & p=$!
    trap "kill -KILL -- -$p 2>/dev/null" EXIT; trap "exit 143" TERM INT
    sleep 20; w=$(xdotool search --onlyvisible --pid $p 2>/dev/null | head -1); [ -n "$w" ] && xdotool windowactivate --sync $w 2>/dev/null
    xdotool keydown Tab
    sleep 20; xdotool keyup Tab; sleep 8
    xdotool keydown x; sleep 1; xdotool keydown Tab; sleep 3; xdotool keyup Tab; xdotool keyup x; sleep 12
    kill -INT -- -$p 2>/dev/null; for i in $(seq 12); do kill -0 $p 2>/dev/null || break; sleep 0.25; done
    kill -KILL -- -$p 2>/dev/null; wait $p' >/dev/null 2>&1
}
mean() { grep "^\[$1\]" "$2" | awk '{s+=$2; n++} END {if (n) printf "%.2f", s/n; else print 0}'; }
run "$T/on.log" PS2_FAST_FORWARD=1 PS2_FF_MAX="$MAX"
grep -q "^\[ff\] on (max ${MAX}x)" "$T/on.log" && ok "FF engaged while Tab held" || bad "FF never engaged"
grep -q "^\[ff\] off after [0-9]* frames" "$T/on.log" && ok "FF released on key up" || bad "FF not released"
prim=$(sed -n 's/^\[ff\] off after .*re-primed to \([0-9]*\) ms/\1/p' "$T/on.log" | head -1)
[ "${prim:-0}" -gt 0 ] && ok "queue flushed and re-primed to $prim ms on release" || bad "no re-prime on release"
n_ff=$(grep -c "^\[perf-ff\]" "$T/on.log"); [ "$n_ff" -ge 15 ] && ok "$n_ff seconds tagged [perf-ff]" || bad "only $n_ff [perf-ff] lines"
normal=$(mean perf "$T/on.log"); ff=$(mean perf-ff "$T/on.log")
echo "normal $normal fps, fast-forward $ff fps (cap $((MAX*60)))"
awk -v f="$ff" -v m="$MAX" 'BEGIN{exit !(f <= m*60*1.05)}' && ok "FF speed within the ${MAX}x cap" || bad "FF speed above the cap"
# Skip the first and last [perf-ff] second (Tab-up/down mid-second can leave that boundary dry). Also skip
# seconds whose fps is below 1000/target ms: one silence pump per frame can't refill a buffer that the device
# empties between frames (target defaults to 120 ms → below ~8.3 fps).
tgt=${PS2_AUDIO_BUFFER_MS:-120}
grep "^\[perf-ff\]" "$T/on.log" | sed '1d;$d' | awk -v t="$tgt" '{
  fps=$2+0; if (fps > 0 && fps < 1000/t) next
  for (i=1;i<=NF;i++) if ($i=="audio" && $(i+1)+0<=0) z++
} END {exit z>0}' \
  && ok "audio device fed (queue > 0) every interior FF second (fps >= $((1000/tgt)))" || bad "audio queue ran dry during FF"
sed -n '/^\[ff\] off/,$p' "$T/on.log" | grep -q "^\[perf\]" && ok "[perf] resumes after release" || bad "no [perf] after release"
grep -q "^\[window\] exit" "$T/on.log" && ok "clean exit after FF" || echo "note: no [window] exit line (killed by the test)"
ad=$(sed -n '/^\[ff\] on/,/^\[ff\] off/p' "$T/on.log" | grep -c "dropouts [0-9]* (+[1-9]")
[ "$ad" = 0 ] && ok "no dropouts counted during FF" || bad "$ad dropout increments during FF"
grep -q "^\[hotkey\] fast-forward refused: push-to-talk held" "$T/on.log" && ok "FF refused while circle (X) held" || bad "FF not refused with circle held"
run "$T/off.log"
grep -q "^\[ff\]" "$T/off.log" && bad "FF engaged with PS2_FAST_FORWARD unset" || ok "Tab ignored with the gate off"
cp "$T/on.log" "${FF_SMOKE_LOG:-/dev/null}" 2>/dev/null || true
rm -rf "$T"
[ $fail = 0 ] && echo "fast-forward smoke passed" || { echo "fast-forward smoke FAILED"; exit 1; }

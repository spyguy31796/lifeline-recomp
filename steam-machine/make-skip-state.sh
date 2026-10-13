#!/usr/bin/env bash
# Make a "skip the tutorial" save state from YOUR disc, on this machine:
#   saves/room001.state = frame 52000, first playable room (scene 013, voice context 013.a/os_601).
# Replays the tutorial with injected answers (no mic needed) in the same segments (save/load points)
# it was first recorded with, skips the intro cutscenes with START, and saves at frame 50000.
# Contains no game data: tutorial answers come from a local file you supply (one phrase per line, in
# the order the tutorial asks), default saves/tutorial-queue.txt.
#
# usage: make-skip-state.sh [queue-file] [out-state]
set -euo pipefail
WORK="$(cd "$(dirname "$0")" && pwd)"          # ~/lifeline-recomp (installed next to run.sh)
source "$WORK/lifeline.env"
Q="$(realpath "${1:-$WORK/saves/tutorial-queue.txt}")"; OUT="$(realpath -m "${2:-$WORK/saves/room001.state}")"
[ -s "$Q" ] || { echo "queue file missing: $Q" >&2; exit 1; }
T=$WORK/logs/skip-state; rm -rf "$T"; mkdir -p "$T/st" "$(dirname "$OUT")"
sed -E '/^[0-9]+ /!s/^/0 /' "$Q" > "$T/queue.txt"                 # injector lines: "FRAME phrase" (0 = next listen)
INBOX=(); if [ ! -e /run/.containerenv ] && command -v distrobox >/dev/null && distrobox list 2>/dev/null | grep -qw lifeline-build; then
  INBOX=(distrobox enter lifeline-build --); fi
t0=$SECONDS
run() {  # run S E MODE : frames S..E from st/S.state (if S>0), save st/E.state
  local S=$1 E=$2 M=$3 P=() L=() f t
  if [ $M = tut ]; then
    [ $S -eq 0 ] && P+=(--press 1300:start --press 1420:cross)
    for ((f=1600;f<3250;f+=90)); do ((f>S && f<E)) && P+=(--press $f:square); done
    for ((t=3300;t<E;t+=400)); do
      ((t>S)) && P+=(--press $t:circle:60)
      for ((f=t+120;f<t+400;f+=70)); do ((f>S && f<E)) && P+=(--press $f:square); done
    done
  elif [ $M = skip ]; then for ((f=S+30;f<E-100;f+=30)); do P+=(--press $f:start); done
  elif [ $M = call ]; then P+=(--press $((S+50)):start)                    # answer the "press START" call prompt
  elif [ $M = probe ]; then P+=(--press $((S+100)):circle:60); fi
  [ $S -gt 0 ] && L=(--load-state "$T/st/$S.state")
  # a loaded state does not carry the voice module's context, so preset it (tutorial / first room)
  local C=1000.a/os_999; [ $M = tut ] || C=013.a/os_601
  "${INBOX[@]}" env PS2_VOICE_CONTEXT="$C" PS2_VOICE_INJECT="$T/queue.txt" PS2_VOICE_ASSETS="$PS2_VOICE_ASSETS" PS2_VOICE_DEBUG=1 PS2_GPU_LOW_POWER=1 \
    "$PS2RUN" "$ELF" --disc "$ISO" --memcard "$T/mc.ps2" "${L[@]}" --frames $((E+1)) --save-state "$E:$T/st/$E.state" "${P[@]}" \
    > "$T/run_$S.log" 2>&1 || true
  [ -f "$T/st/$E.state" ] || { echo "FAILED: segment $S-$E saved no state (see $T/run_$S.log)" >&2; exit 1; }
  local n; n=$(grep -a -c "injected '" "$T/run_$S.log" || true)   # drop delivered answers
  [ "$n" -gt 0 ] && sed -i "1,${n}d" "$T/queue.txt"
  echo "  frames $S-$E ($M): $n answers, $((SECONDS-t0))s"
}
echo "making $OUT (logs: $T) ..."
B=(0 2000 4000 6000 7700 9300 11300 13300 15300 17300 19300 20100 21300 22500 23700 25700 27700 29700 31700 33700 36700)
for ((i=0;i+1<${#B[@]};i++)); do run ${B[i]} ${B[i+1]} tut; done
run 36700 38700 skip; run 38700 41700 skip; run 41700 44700 skip
run 44700 48000 idle; run 48000 50000 idle; run 50000 52000 call
run 52000 52400 probe                                                       # does holding circle start listening?
cp "$T/st/52000.state" "$OUT"
echo "answers left unused: $(wc -l < "$T/queue.txt")"
grep -aqh "context identified.*013.a/os_601" "$T"/run_*.log || { echo "WARNING: room context 013.a/os_601 was never loaded" >&2; exit 2; }
grep -aq "cmd 1 " "$T/run_52000.log" || { echo "WARNING: the game does not listen in the saved state (see $T/run_52000.log)" >&2; exit 2; }
echo "OK: $OUT (first room, 013.a/os_601, listening) in $((SECONDS-t0))s"

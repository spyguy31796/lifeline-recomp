#!/usr/bin/env bash
# vu-check.sh: run the [qol] vu_fast correctness harness headless on save states made on this machine.
#   vu-check.sh STATE:END_FRAME ...     e.g. vu-check.sh saves/room001.state:52300
# Each state runs to END_FRAME (frame numbers are absolute; a state carries its own frame count) with
# PS2_VU_FAST=1 PS2_VU_CHECK=1: every VU1 call runs on the faster interpreter AND the original from the same
# snapshot; registers, flags, VU1 memory and GS packets are compared; the original's result is kept.
# Pass = "0 mismatches" for every state. Refuses to run while the game is open. Nothing leaves this machine.
# Install dir: $LIFELINE_WORK, else this script's dir when it holds lifeline.env (the installed copy in
# ~/lifeline-recomp), else ~/lifeline-recomp (running the kit's copy). ps2run is built inside the lifeline-build
# distrobox, so on SteamOS this script re-runs itself in there, the same way run.sh launches the game.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${LIFELINE_WORK:-}" ]; then WORK=$LIFELINE_WORK
elif [ -f "$HERE/lifeline.env" ]; then WORK=$HERE
else WORK="$HOME/lifeline-recomp"; fi
[ -f "$WORK/lifeline.env" ] || { echo "no $WORK/lifeline.env (install first, or set LIFELINE_WORK)" >&2; exit 2; }
[ $# -gt 0 ] || { sed -n '2,7p' "$0"; exit 2; }
if pgrep -x ps2run >/dev/null; then echo "the game is running; close it first" >&2; exit 3; fi
if [ ! -e /run/.containerenv ] && [ -z "${VU_CHECK_IN_BOX:-}" ] && command -v distrobox >/dev/null \
   && distrobox list 2>/dev/null | grep -qw lifeline-build; then
  args=()   # state paths absolute: the container may start in another directory
  for a in "$@"; do st=${a%:*}; [ -f "$st" ] && st="$(cd "$(dirname "$st")" && pwd)/$(basename "$st")"; args+=("$st:${a##*:}"); done
  exec distrobox enter lifeline-build -- env VU_CHECK_IN_BOX=1 LIFELINE_WORK="$WORK" bash "$HERE/vu-check.sh" "${args[@]}"
fi
# shellcheck disable=SC1091
source "$WORK/lifeline.env"
mkdir -p "$WORK/logs"; rc=0
for a in "$@"; do
  st=${a%:*}; end=${a##*:}; [ -f "$st" ] && [[ $end =~ ^[0-9]+$ ]] || { echo "bad argument '$a' (want STATE:END_FRAME)" >&2; exit 2; }
  log="$WORK/logs/vu-check-$(basename "$st" .state).log"; mc=$(mktemp); cp "$MEMCARD" "$mc" 2>/dev/null || true
  PS2_VU_FAST=1 PS2_VU_CHECK=1 PS2_VOICE_OFF=1 PS2_GPU_LOW_POWER=1 "$PS2RUN" "$ELF" --disc "$ISO" --memcard "$mc" \
    --load-state "$st" --frames "$end" > "$log" 2>&1 || true
  rm -f "$mc"
  res=$(grep -a '\[vu-check\] done' "$log" | tail -1); res=${res:-"[vu-check] no VU1 calls"}
  echo "$(basename "$st"): ${res#\[vu-check\] }"
  { grep -a 'MISMATCH' "$log" || true; } | head -5
  if grep -aq MISMATCH "$log"; then rc=1; fi
done
exit $rc

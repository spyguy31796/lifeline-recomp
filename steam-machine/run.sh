#!/usr/bin/env bash
# Launch Lifeline (native recomp). Add this file as a non-Steam game.
#   run.sh            normal launch (voice log -> logs/voice.log by default)
#   run.sh --debug    also stderr -> logs/run-*.log
#   run.sh --skip-tutorial   start in the first room (saves/room001.state)
# Extra args pass through to ps2run (e.g. --fullscreen, --load-state f).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lifeline.env"
DEBUG=0; SKIP=0
while [ $# -gt 0 ]; do case "$1" in --debug) DEBUG=1; shift;; --skip-tutorial) SKIP=1; shift;; *) break;; esac; done
# --skip-tutorial: start in the first room from saves/room001.state (made by make-skip-state.sh).
# A loaded state does not tell the voice module the active context, so preset it.
EXTRA=(); if [ "$SKIP" = 1 ]; then
  [ -f "$HERE/saves/room001.state" ] || { echo "no $HERE/saves/room001.state; run make-skip-state.sh first" >&2; exit 1; }
  EXTRA=(--load-state "$HERE/saves/room001.state"); : "${PS2_VOICE_CONTEXT:=013.a/os_601}"; fi
ENVS=(SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-pipewire,pulseaudio}")      # SDL mic capture
mkdir -p "$HERE/logs"
ENVS+=(PS2_VOICE_DEBUG="${PS2_VOICE_DEBUG:-1}" PS2_VOICE_LOG="${PS2_VOICE_LOG:-$HERE/logs/voice.log}")   # voice log on by default
[ -n "${PS2_VOICE_CONTEXT:-}" ] && ENVS+=(PS2_VOICE_CONTEXT="$PS2_VOICE_CONTEXT")
ENVS+=(PS2_VOICE_VOSK_MODEL="$PS2_VOICE_VOSK_MODEL" PS2_VOICE_VOSK_LIB="$PS2_VOICE_VOSK_LIB" PS2_VOICE_ASSETS="$PS2_VOICE_ASSETS")
if [ "$DEBUG" = 1 ]; then
  mkdir -p "$HERE/logs"; ts=$(date +%Y%m%d-%H%M%S)
  echo "debug: stderr -> $HERE/logs/run-$ts.log, voice -> $HERE/logs/voice.log" >&2
  exec 2> >(tee -a "$HERE/logs/run-$ts.log" >&2)
fi
CMD=(env "${ENVS[@]}" "$PS2RUN" "$ELF" --disc "$ISO" --memcard "$MEMCARD" --window "${EXTRA[@]}" "$@")
# Built inside the distrobox -> run inside it (the host lacks its libraries).
if [ ! -e /run/.containerenv ] && command -v distrobox >/dev/null && distrobox list 2>/dev/null | grep -qw lifeline-build; then
  exec distrobox enter lifeline-build -- "${CMD[@]}"
fi
exec "${CMD[@]}"

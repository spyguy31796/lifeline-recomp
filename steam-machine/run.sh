#!/usr/bin/env bash
# Launch Lifeline (native recomp). Add this file as a non-Steam game.
#   run.sh            normal launch (voice log -> logs/voice.log by default)
#   run.sh --debug    also stderr -> logs/run-*.log
#   run.sh --skip-tutorial   start in the first room (saves/room001.state)
# QoL toggles come from config.ini next to this script (see launcher/). LIFELINE_PRINT_ENV=1 prints the env and exits.
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
# --- QoL toggles from config.ini (written by launcher/). Env vars already set win. ---
CFG="${LIFELINE_CONFIG:-$HERE/config.ini}"
cfg() { [ -f "$CFG" ] && awk -F= -v s="[$1]" -v k="$2" '/^\[/{in_=($0==s)} in_ && $1~"^[ \t]*"k"[ \t]*$" {v=$2; gsub(/^[ \t]+|[ \t\r]+$/,"",v); print v; exit}' "$CFG"; }
on() { [ "$(cfg qol "$1")" = 1 ]; }
QOL_ENVS=()
sc=$(cfg qol resolution_scale); [ -z "${PS2_SCALE:-}" ] && [ -n "$sc" ] && [ "$sc" != 1 ] && QOL_ENVS+=(PS2_SCALE="$sc")   # item 3 (works)
[ -n "${PS2_SCALE:-}" ] && QOL_ENVS+=(PS2_SCALE="$PS2_SCALE")
on voice_readout && QOL_ENVS+=(PS2_VOICE_OVERLAY=1)                    # item 1 (reserved)
on voice_tuning  && QOL_ENVS+=(PS2_VOICE_CONFIG="${PS2_VOICE_CONFIG:-$HERE/voice.ini}")   # item 2 (reserved)
on save_slots    && QOL_ENVS+=(PS2_SAVE_SLOTS=1)                       # item 4 (reserved)
on always_on     && QOL_ENVS+=(PS2_VOICE_ALWAYS_ON=1)                  # item 5 (reserved)
on large_model   && [ -d "$VOSK_DIR/vosk-model-en-us-0.22" ] && PS2_VOICE_VOSK_MODEL="$VOSK_DIR/vosk-model-en-us-0.22"   # item 6
on widescreen    && QOL_ENVS+=(PS2_WIDESCREEN=1)                       # item 7 (reserved)
on faster_loads  && QOL_ENVS+=(PS2_FAST_LOADS=1)                       # item 8 (reserved)
[ "$(cfg launch voice_off)" = 1 ] && PS2_VOICE_OFF=1
[ -n "${PS2_VOICE_OFF:-}" ] && QOL_ENVS+=(PS2_VOICE_OFF="$PS2_VOICE_OFF")
[ -n "${PS2_VOICE_ALIASES:-}" ] && QOL_ENVS+=(PS2_VOICE_ALIASES="$PS2_VOICE_ALIASES")
ENVS=(SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-pipewire,pulseaudio}")      # SDL mic capture
mkdir -p "$HERE/logs"
ENVS+=(PS2_VOICE_DEBUG="${PS2_VOICE_DEBUG:-1}" PS2_VOICE_LOG="${PS2_VOICE_LOG:-$HERE/logs/voice.log}")   # voice log on by default
[ -n "${PS2_VOICE_CONTEXT:-}" ] && ENVS+=(PS2_VOICE_CONTEXT="$PS2_VOICE_CONTEXT")
ENVS+=(PS2_VOICE_VOSK_MODEL="$PS2_VOICE_VOSK_MODEL" PS2_VOICE_VOSK_LIB="$PS2_VOICE_VOSK_LIB" PS2_VOICE_ASSETS="$PS2_VOICE_ASSETS" "${QOL_ENVS[@]}")
[ -n "${LIFELINE_PRINT_ENV:-}" ] && { printf '%s\n' "${ENVS[@]}"; exit 0; }   # headless check
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

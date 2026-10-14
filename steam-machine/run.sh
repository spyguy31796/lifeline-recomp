#!/usr/bin/env bash
# Launch Lifeline (native recomp). Add this file (or launcher/launcher.sh) as a non-Steam game.
#   run.sh            normal launch (no voice log unless debug)
#   run.sh --debug    voice log -> logs/voice.log (PS2_VOICE_DEBUG=1) and stderr -> logs/run-*.log
#   run.sh --skip-tutorial   start in the first room (saves/room001.state)
# Extra args pass through to ps2run (e.g. --fullscreen, --load-state f).
# QoL toggles come from config.ini next to this script (written by launcher/).
# Precedence: variables already in the environment > config.ini > lifeline.env defaults.
# LIFELINE_PRINT_ENV=1 prints the environment that would be passed and exits.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# lifeline.env must not clobber exported voice paths: remember them, source, restore.
_m=${PS2_VOICE_VOSK_MODEL-}; _l=${PS2_VOICE_VOSK_LIB-}; _a=${PS2_VOICE_ASSETS-}
# shellcheck disable=SC1091
source "$HERE/lifeline.env"
[ -n "$_m" ] && PS2_VOICE_VOSK_MODEL=$_m; [ -n "$_l" ] && PS2_VOICE_VOSK_LIB=$_l; [ -n "$_a" ] && PS2_VOICE_ASSETS=$_a
DEBUG=0; SKIP=0
while [ $# -gt 0 ]; do case "$1" in --debug) DEBUG=1; shift;; --skip-tutorial) SKIP=1; shift;; *) break;; esac; done

# --- config.ini (env wins: every value is applied with := ) ---
CFG="${LIFELINE_CONFIG:-$HERE/config.ini}"
cfg() { [ -f "$CFG" ] || return 0; awk -F= -v s="[$1]" -v k="$2" '/^\[/{in_=($0==s)} in_ { kk=$1; gsub(/[ \t]/,"",kk); if (kk==k) { v=$2; gsub(/^[ \t]+|[ \t\r]+$/,"",v); print v; exit } }' "$CFG"; }
on() { [ "$(cfg qol "$1")" = 1 ]; }
QOL_VARS=(PS2_INPUT_MAP PS2_SCALE PS2_VOICE_OVERLAY PS2_VOICE_CONFIG PS2_SAVE_SLOTS PS2_VOICE_ALWAYS_ON PS2_WIDESCREEN PS2_FAST_LOADS PS2_VOICE_OFF PS2_VOICE_ALIASES)
sc=$(cfg qol resolution_scale); [ -n "$sc" ] && [ "$sc" != 1 ] && : "${PS2_SCALE:=$sc}"        # item 3 (works)
on voice_readout && : "${PS2_VOICE_OVERLAY:=1}"                         # item 1 (reserved)
on voice_tuning  && : "${PS2_VOICE_CONFIG:=$HERE/voice.ini}"            # item 2 (reserved)
on save_slots    && : "${PS2_SAVE_SLOTS:=1}"                            # item 4 (reserved)
on always_on     && : "${PS2_VOICE_ALWAYS_ON:=1}"                       # item 5 (reserved)
if on large_model && [ -z "$_m" ] && [ -d "$VOSK_DIR/vosk-model-en-us-0.22" ]; then PS2_VOICE_VOSK_MODEL="$VOSK_DIR/vosk-model-en-us-0.22"; fi  # item 6
on widescreen    && : "${PS2_WIDESCREEN:=1}"                            # item 7 (reserved)
on faster_loads  && : "${PS2_FAST_LOADS:=1}"                            # item 8 (reserved)
[ "$(cfg launch voice_off)" = 1 ] && : "${PS2_VOICE_OFF:=1}"
# Controller bindings: [bindings] -> PS2_INPUT_MAP="circle=b,paddle1;lx=leftx;..." (read by ourcode/input in ps2run)
if [ -f "$CFG" ] && [ -z "${PS2_INPUT_MAP+x}" ]; then
  PS2_INPUT_MAP=$(awk -F= '/^\[/{in_=($0=="[bindings]")} in_ && NF>=2 && $1!~/^[ \t]*[#;]/ { k=$1; v=substr($0,index($0,"=")+1); gsub(/[ \t\r]/,"",k); gsub(/^[ \t]+|[ \t\r]+$/,"",v); out=out (out?";":"") k "=" v } END{print out}' "$CFG")
fi
true

# --skip-tutorial: start in the first room from saves/room001.state (made by make-skip-state.sh).
# A loaded state does not tell the voice module the active context, so preset it.
EXTRA=(); if [ "$SKIP" = 1 ]; then
  [ -f "$HERE/saves/room001.state" ] || { echo "no $HERE/saves/room001.state; run make-skip-state.sh first" >&2; exit 1; }
  EXTRA=(--load-state "$HERE/saves/room001.state"); : "${PS2_VOICE_CONTEXT:=013.a/os_601}"; fi
mkdir -p "$HERE/logs"
ENVS=()
[ -z "${SDL_AUDIODRIVER:-}" ] && ENVS+=(SDL_AUDIODRIVER="pipewire,pulseaudio,alsa")   # SDL mic capture; env wins
if [ "$DEBUG" = 1 ]; then : "${PS2_VOICE_DEBUG:=1}"; else : "${PS2_VOICE_DEBUG:=0}"; fi
: "${PS2_VOICE_LOG:=$HERE/logs/voice.log}"
ENVS+=(PS2_VOICE_DEBUG="$PS2_VOICE_DEBUG" PS2_VOICE_LOG="$PS2_VOICE_LOG")
[ -n "${PS2_VOICE_CONTEXT:-}" ] && ENVS+=(PS2_VOICE_CONTEXT="$PS2_VOICE_CONTEXT")
ENVS+=(PS2_VOICE_VOSK_MODEL="$PS2_VOICE_VOSK_MODEL" PS2_VOICE_VOSK_LIB="$PS2_VOICE_VOSK_LIB" PS2_VOICE_ASSETS="$PS2_VOICE_ASSETS")
for v in "${QOL_VARS[@]}"; do [ -n "${!v:-}" ] && ENVS+=("$v=${!v}"); done
[ -n "${LIFELINE_PRINT_ENV:-}" ] && { printf '%s\n' "${ENVS[@]}"; exit 0; }   # headless check
if [ "$DEBUG" = 1 ]; then
  ts=$(date +%Y%m%d-%H%M%S)
  echo "debug: stderr -> $HERE/logs/run-$ts.log, voice -> $PS2_VOICE_LOG" >&2
  exec 2> >(tee -a "$HERE/logs/run-$ts.log" >&2)
fi
CMD=(env "${ENVS[@]}" "$PS2RUN" "$ELF" --disc "$ISO" --memcard "$MEMCARD" --window "${EXTRA[@]}" "$@")
# Built inside the distrobox -> run inside it (the host lacks its libraries).
if [ ! -e /run/.containerenv ] && command -v distrobox >/dev/null && distrobox list 2>/dev/null | grep -qw lifeline-build; then
  exec distrobox enter lifeline-build -- "${CMD[@]}"
fi
exec "${CMD[@]}"

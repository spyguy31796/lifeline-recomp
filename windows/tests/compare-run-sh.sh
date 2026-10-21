#!/usr/bin/env bash
# Parity check (Linux dev box with pwsh): run.sh and windows/run.ps1 must hand ps2run the same environment for the
# same config.ini + exported env, apart from the documented Windows differences:
#   - run.sh adds SDL_AUDIODRIVER=pipewire,pulseaudio,alsa; run.ps1 never sets it (dropped before comparing)
#   - run.sh passes forced-off PS2_VU_FAST= / PS2_FMV_SKIP= (empty); run.ps1 passes =0 (normalized before comparing)
#   windows/tests/compare-run-sh.sh [path/to/pwsh]
# Also starts a stub ps2run through run.ps1 to check the env/argv the child really gets, the exit code and --debug logging.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${1:-${PWSH:-pwsh}}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H="$T/w"; mkdir -p "$H/icons/xbox" "$H/icons.local/mine" "$H/saves" "$H/vosk/vosk-model-en-us-0.22"
cp "$REPO/steam-machine/run.sh" "$REPO/windows/run.ps1" "$H/"
: > "$H/icons/xbox/icons.txt"; : > "$H/icons.local/mine/icons.txt"; : > "$H/saves/room001.state"
printf 'PS2RUN="%s"\nELF="%s"\nISO="%s"\nMEMCARD="%s"\nVOSK_DIR="%s"\nPS2_VOICE_VOSK_MODEL="%s"\nPS2_VOICE_VOSK_LIB="%s"\nPS2_VOICE_ASSETS="%s"\n' \
  "$H/ps2run" "$H/game.elf" "$H/My Disc (USA).iso" "$H/saves/lifeline.ps2" "$H/vosk" "$H/vosk/small" "$H/vosk/vosk/libvosk.so" "$H/voice-assets" > "$H/lifeline.env"
fail=0; n=0
norm_sh() { grep -v '^SDL_AUDIODRIVER=' | sed -E 's/^(PS2_VU_FAST|PS2_FMV_SKIP)=$/\1=0/'; }
case_() {  # name, config.ini text ('-' = no file), run args..., then env after '--'
  local name=$1 cfg=$2; shift 2; local args=() envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done; [ $# -gt 0 ] && shift; envs=("$@")
  rm -f "$H/config.ini"; [ "$cfg" != - ] && printf '%b' "$cfg" > "$H/config.ini"
  local clean=(env -u PS2_VU_FAST -u PS2_FMV_SKIP -u PS2_INPUT_MAP -u PS2_SCALE -u PS2_ICON_PACK -u PS2_VOICE_VOSK_MODEL -u SDL_AUDIODRIVER -u PS2_PERF_LOG)
  local a b
  a=$("${clean[@]}" "${envs[@]}" LIFELINE_PRINT_ENV=1 bash "$H/run.sh" "${args[@]}" 2>"$T/sh.err" | norm_sh)
  b=$("${clean[@]}" "${envs[@]}" LIFELINE_PRINT_ENV=1 "$PWSH" -NoProfile -File "$H/run.ps1" "${args[@]}" 2>"$T/ps.err")
  n=$((n+1))
  if [ "$a" = "$b" ]; then echo "ok: $name ($(printf '%s\n' "$b" | wc -l) vars)"
  else echo "FAIL: $name"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/    /'; cat "$T/sh.err" "$T/ps.err" | sed 's/^/    err: /'; fail=1; fi
}
ALLON='[qol]\nvoice_readout = 1\nvoice_tuning = 1\nresolution_scale = 2   # sharper\nsave_slots = 1\nalways_on = 1\nlarge_model = 1\nwidescreen = 1\nfaster_loads = 1\nvu_fast = 1\nbutton_icons = xbox\nfast_forward = 1\nfmv_skip = 1\n[launch]\nvoice_off = 1\n'
ALLOFF='[qol]\nvoice_readout = 0\nvoice_tuning = 0\nresolution_scale = 1\nsave_slots = 0\nalways_on = 0\nlarge_model = 0\nwidescreen = 0\nfaster_loads = 0\nvu_fast = 0\nbutton_icons = ps2\nfast_forward = 0\nfmv_skip = 0\n[launch]\nvoice_off = 0\n'
BIND='[bindings]\ncircle = b, paddle1        # push-to-talk\nlx = leftx\n# a comment = x\n; other = y\nup = dpup, -lefty\nhk_quit = key:Ctrl&key:Q@500, key:Escape@1000, back&start@1500 ; note\n\tselect\t=\tnone\t\nhk_ff = key:Tab, back&righttrigger\n[qol]\nwidescreen=1\n'
WEIRD='widescreen = 1\n[qol]\nwidescreen = 1 = 2\nvu_fast\n[qol] \nfmv_skip = 1\n[launch]\nvoice_off = 1#nospace\n[qol]\nfast_forward = 1\nbutton_icons = ../icons/xbox\n'
case_ "no config.ini" -
case_ "all on" "$ALLON"
case_ "all off" "$ALLOFF"
case_ "bindings + comments + tabs" "$BIND"
case_ "parser edge cases" "$WEIRD"
case_ "icons.local user pack" '[qol]\nbutton_icons = mine\n'
case_ "unknown icon pack" '[qol]\nbutton_icons = nosuch\n'
case_ "--debug" "$ALLOFF" --debug
case_ "--skip-tutorial --debug + passthrough" "$ALLON" --skip-tutorial --debug --fullscreen
case_ "env forced off (empty) beats config on" "$ALLON" -- PS2_VU_FAST= PS2_FMV_SKIP=
case_ "env 0 beats config on" "$ALLON" -- PS2_VU_FAST=0 PS2_FMV_SKIP=0
case_ "env 1 with config off" "$ALLOFF" -- PS2_VU_FAST=1 PS2_FMV_SKIP=1
case_ "env overrides scale/map/icons/model" "$ALLON$BIND" -- PS2_SCALE=3 PS2_INPUT_MAP=circle=a PS2_ICON_PACK=/x PS2_VOICE_VOSK_MODEL=/m
case_ "empty env does not override := values" "$ALLON" -- PS2_SCALE= PS2_ICON_PACK=
case_ "env-only QoL passthrough" - -- PS2_PERF_LOG=1 PS2_FF_MAX=3 PS2_AUDIO_BUFFER_MS=80 PS2_VU_CHECK=1 PS2_VOICE_ALIASES=/a.tsv
case_ "exported SDL_AUDIODRIVER" "$ALLOFF" -- SDL_AUDIODRIVER=wasapi,directsound
case_ "LIFELINE_CONFIG elsewhere" - -- LIFELINE_CONFIG="$REPO/windows/tests/sample-config.ini"
# build.ps1 writes lifeline.env.json (no VOSK_DIR): same values -> same environment
python3 - "$H" <<'PY2'
import json, os, shlex, sys
h = sys.argv[1]; d = {}
for l in open(os.path.join(h, 'lifeline.env')):
    k, v = l.rstrip('\n').split('=', 1); d[k] = shlex.split(v)[0]
d.pop('VOSK_DIR')
json.dump(d, open(os.path.join(h, 'lifeline.env.json'), 'w'), indent=2)
PY2
mkdir -p "$H/vosk/vosk-model-en-us-0.22"
case_ "lifeline.env.json (build.ps1 format), all on" "$ALLON"
case_ "lifeline.env.json, bindings" "$BIND"

# --- Windows-only behaviour (run.ps1 alone) ---
ps_env() { env -u PS2_VU_FAST -u PS2_FMV_SKIP -u SDL_AUDIODRIVER -u PS2_INPUT_MAP LIFELINE_PRINT_ENV=1 "$@" "$PWSH" -NoProfile -File "$H/run.ps1" 2>/dev/null; }
expect() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: got '$2' want '$3'"; fail=1; fi; }
printf '\xef\xbb\xbf[qol]\r\nvu_fast = 1\r\nwidescreen = 1 ; c\r\n[bindings]\r\ncircle = b\r\n' > "$H/config.ini"
expect "CRLF + BOM config is read" "$(ps_env | grep -E '^PS2_(VU_FAST|WIDESCREEN|INPUT_MAP)=' | tr '\n' ' ')" "PS2_INPUT_MAP=circle=b PS2_WIDESCREEN=1 PS2_VU_FAST=1 "
expect "never an empty value" "$(ps_env PS2_VU_FAST= PS2_FMV_SKIP= | grep -c '=$')" "0"
expect "no SDL_AUDIODRIVER by default" "$(ps_env | grep -c '^SDL_AUDIODRIVER')" "0"

# --- start a stub ps2run through run.ps1: env + argv as the child sees them, exit code, --debug stderr log ---
cat > "$H/stub.sh" <<'STUB'
#!/bin/sh
for a in "$@"; do printf 'ARG<%s>\n' "$a"; done
env | grep -E '^(PS2_|SDL_AUDIODRIVER)' | sort | sed 's/^/ENV /'
echo "stub stderr line" >&2
exit 7
STUB
chmod +x "$H/stub.sh"; rm -f "$H/config.ini"; printf '[qol]\nvu_fast = 1\n' > "$H/config.ini"
out=$(env -u SDL_AUDIODRIVER -u PS2_VU_FAST "$PWSH" -NoProfile -File "$H/run.ps1" --debug --ps2run "$H/stub.sh" --fullscreen 'a "q" b\' 2>"$T/run.err"); rc=$?
expect "child exit code propagates" "$rc" "7"
expect "argv as ps2run sees it" "$(printf '%s\n' "$out" | grep '^ARG' | tr '\n' '|')" "ARG<$H/game.elf>|ARG<--disc>|ARG<$H/My Disc (USA).iso>|ARG<--memcard>|ARG<$H/saves/lifeline.ps2>|ARG<--window>|ARG<--fullscreen>|ARG<a \"q\" b\\>|"
expect "child env has PS2_VU_FAST=1, PS2_VOICE_DEBUG=1" "$(printf '%s\n' "$out" | grep -cE '^ENV (PS2_VU_FAST=1|PS2_VOICE_DEBUG=1)$')" "2"
expect "child env has no SDL_AUDIODRIVER" "$(printf '%s\n' "$out" | grep -c '^ENV SDL_AUDIODRIVER')" "0"
expect "--debug: stderr also in logs/run-*.log" "$(cat "$H"/logs/run-*.log 2>/dev/null)" "stub stderr line"
expect "--debug: stderr still on the console" "$(grep -c 'stub stderr line' "$T/run.err")" "1"
expect "--dry-run starts nothing" "$("$PWSH" -NoProfile -File "$H/run.ps1" --dry-run --ps2run "$H/stub.sh" | grep -c '^ARG')" "0"
expect "missing ps2run is an error" "$("$PWSH" -NoProfile -File "$H/run.ps1" --ps2run "$H/nope.exe" >/dev/null 2>&1; echo $?)" "1"
[ "$fail" = 0 ] && echo "run.ps1 parity: all $n checks passed" || echo "run.ps1 parity: FAILURES"; exit "$fail"

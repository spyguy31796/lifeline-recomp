#!/usr/bin/env bash
# run.sh's [qol] button_icons -> PS2_ICON_PACK (ps2 = off, shipped packs, icons.local/ user packs, env override).
#   steam-machine/tests/test_run_icons.sh
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$KIT/run.sh" "$T/run.sh"
printf 'PS2RUN=/bin/true\nELF=x\nISO=x\nMEMCARD=x\nVOSK_DIR=%s\nPS2_VOICE_VOSK_MODEL=x\nPS2_VOICE_VOSK_LIB=x\nPS2_VOICE_ASSETS=x\n' "$T" > "$T/lifeline.env"
mkdir -p "$T/icons/xbox" "$T/icons/deck" "$T/icons.local/mine" "$T/icons.local/xbox" "$T/icons.local/empty"
for d in icons/xbox icons/deck icons.local/mine icons.local/xbox; do : > "$T/$d/icons.txt"; done
fail=0
pack() { printf '[qol]\nbutton_icons = %s\n' "$1" > "$T/config.ini"; shift
  env -u PS2_ICON_PACK "$@" LIFELINE_PRINT_ENV=1 bash "$T/run.sh" | sed -n 's/^PS2_ICON_PACK=//p'; }
expect() { [ "$2" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1: got '$2' want '$3'"; fail=1; }; }
expect "ps2 = off" "$(pack ps2)" ""
expect "deck = shipped" "$(pack deck)" "$T/icons/deck"
expect "user pack in icons.local" "$(pack mine)" "$T/icons.local/mine"
expect "icons.local wins over a shipped name" "$(pack xbox)" "$T/icons.local/xbox"
expect "dir without icons.txt ignored" "$(pack empty)" ""
expect "unsafe name ignored" "$(pack '../icons/deck')" ""
expect "env overrides config" "$(pack deck PS2_ICON_PACK=/x)" "/x"
expect "empty env does not override (documented)" "$(pack deck PS2_ICON_PACK=)" "$T/icons/deck"
[ "$fail" = 0 ] && echo "run.sh icon tests passed"; exit "$fail"

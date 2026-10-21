#!/usr/bin/env bash
# Lifeline Recomp launcher entry point. Add THIS file to Steam as a non-Steam game.
# Uses a per-user venv with the pygame-ce wheel (bundles SDL2; has wheels for new Pythons such as 3.14), so nothing needs root.
# pygame-ce is pinned and hash-checked by launcher-requirements.txt (the same file Windows uses: next to this script
# once installed, windows/launcher-requirements.txt in the repo).
# First run needs network (pip downloads pygame); falls back to `pip install --user`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${LIFELINE_WORK:-$HOME/lifeline-recomp}"
VENV="$WORK/launcher-venv"; LOG="$WORK/launcher.log"
mkdir -p "$WORK"
REQ="$HERE/launcher-requirements.txt"; [ -f "$REQ" ] || REQ="$HERE/../../windows/launcher-requirements.txt"
if [ -f "$REQ" ]; then PIPSPEC=(-r "$REQ"); else PIPSPEC=(pygame-ce==2.5.8); fi   # pinned either way
has_pg() { "$1" -c 'import pygame' >/dev/null 2>&1; }
PY=""
if [ -x "$VENV/bin/python" ] && has_pg "$VENV/bin/python"; then PY="$VENV/bin/python"
elif has_pg python3; then PY=python3
else
  echo "first run: installing pygame (needs network) ..." >&2
  if { python3 -m venv "$VENV" && "$VENV/bin/python" -m pip install -q --only-binary=:all: "${PIPSPEC[@]}"; } >>"$LOG" 2>&1 && has_pg "$VENV/bin/python"; then PY="$VENV/bin/python"
  elif python3 -m pip install -q --user --only-binary=:all: "${PIPSPEC[@]}" >>"$LOG" 2>&1 && has_pg python3; then PY=python3
  fi
fi
if [ -z "$PY" ]; then
  msg="Lifeline launcher: could not install pygame (venv and pip --user both failed; network?). Details: $LOG"
  echo "$msg" >&2
  command -v zenity >/dev/null && zenity --error --text="$msg" 2>/dev/null || true
  exit 1
fi
exec "$PY" "$HERE/lifeline_launcher.py" "$@"

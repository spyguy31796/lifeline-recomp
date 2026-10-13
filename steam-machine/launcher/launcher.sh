#!/usr/bin/env bash
# Lifeline Recomp launcher entry point. Add THIS file to Steam as a non-Steam game.
# Uses a per-user venv with the pygame wheel (it bundles SDL2), so nothing needs root.
# First run needs network (pip downloads pygame); falls back to `pip install --user`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${LIFELINE_WORK:-$HOME/lifeline-recomp}"
VENV="$WORK/launcher-venv"; LOG="$WORK/launcher.log"
mkdir -p "$WORK"
has_pg() { "$1" -c 'import pygame' >/dev/null 2>&1; }
PY=""
if [ -x "$VENV/bin/python" ] && has_pg "$VENV/bin/python"; then PY="$VENV/bin/python"
elif has_pg python3; then PY=python3
else
  echo "first run: installing pygame (needs network) ..." >&2
  if { python3 -m venv "$VENV" && "$VENV/bin/python" -m pip install -q pygame; } >>"$LOG" 2>&1 && has_pg "$VENV/bin/python"; then PY="$VENV/bin/python"
  elif python3 -m pip install -q --user pygame >>"$LOG" 2>&1 && has_pg python3; then PY=python3
  fi
fi
if [ -z "$PY" ]; then
  msg="Lifeline launcher: could not install pygame (venv and pip --user both failed; network?). Details: $LOG"
  echo "$msg" >&2
  command -v zenity >/dev/null && zenity --error --text="$msg" 2>/dev/null || true
  exit 1
fi
exec "$PY" "$HERE/lifeline_launcher.py" "$@"

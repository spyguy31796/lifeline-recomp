#!/usr/bin/env bash
# Lifeline Recomp launcher entry point. Add THIS file to Steam as a non-Steam game.
# Uses a per-user venv with the pygame wheel (it bundles SDL2), so nothing needs root.
# Falls back to the lifeline-build distrobox if the host python has no venv/pip.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${LIFELINE_WORK:-$HOME/lifeline-recomp}"
VENV="$WORK/launcher-venv"
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c 'import pygame' 2>/dev/null; then
  mkdir -p "$WORK"
  if python3 -m venv "$VENV" 2>>"$WORK/launcher.log" && "$VENV/bin/python" -m pip install -q pygame >>"$WORK/launcher.log" 2>&1; then :
  elif command -v distrobox >/dev/null && distrobox list 2>/dev/null | grep -qw lifeline-build; then
    exec distrobox enter lifeline-build -- bash -c 'python3 -c "import pygame" 2>/dev/null || sudo pacman -S --needed --noconfirm python-pygame >/dev/null; exec python3 "$0" "$@"' "$HERE/lifeline_launcher.py" "$@"
  else echo "could not set up pygame; see $WORK/launcher.log" >&2; exit 1; fi
fi
exec "$VENV/bin/python" "$HERE/lifeline_launcher.py" "$@"

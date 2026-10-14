#!/usr/bin/env bash
# Sourced by build.sh. Puts ps2run.prev (the last good game binary) back as ps2run.
# Copies to ps2run.tmp first and renames it over ps2run, so ps2run is never half-written; a .prev
# that is empty or not executable is left alone (with a warning) instead of replacing a binary.
#   restore_ps2run <native build dir> <reason shown on success>
restore_ps2run() {
  local d=$1 why=$2 prev="$1/ps2run.prev" tmp="$1/ps2run.tmp"
  [ -e "$prev" ] || return 0
  if [ ! -f "$prev" ] || [ ! -s "$prev" ] || [ ! -x "$prev" ]; then
    echo "warning: $prev is empty or not executable; not restoring it (left in place)" >&2
    return 1
  fi
  if cp -p "$prev" "$tmp" && [ -s "$tmp" ] && [ -x "$tmp" ] && mv -f "$tmp" "$d/ps2run"; then
    rm -f "$prev"; echo "$why"
  else
    rm -f "$tmp"; echo "warning: could not restore ps2run from $prev (left in place)" >&2
    return 1
  fi
}

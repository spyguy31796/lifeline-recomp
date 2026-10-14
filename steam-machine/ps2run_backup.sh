#!/usr/bin/env bash
# Sourced by build.sh. Keeps the last good game binary as ps2run.prev and puts it back when a build fails.
# backup_ps2run copies ps2run to ps2run.prev.tmp and renames it, then writes ps2run.prev.sha256 (also via
# a .tmp + rename), so a killed backup never leaves a .prev with a matching checksum. restore_ps2run only
# restores a .prev whose sha256 matches its sidecar; anything else (truncated, empty, not executable, no
# sidecar) is moved to ps2run.prev.bad (only one is kept) and ps2run is left alone.
#   backup_ps2run  <native build dir>
#   restore_ps2run <native build dir> <reason shown on success>
#   drop_ps2run_backup <native build dir>
_ps2run_sha() { sha256sum < "$1" | cut -d' ' -f1; }
drop_ps2run_backup() { rm -f "$1/ps2run.prev" "$1/ps2run.prev.sha256" "$1/ps2run.prev.tmp" "$1/ps2run.prev.sha256.tmp"; }
_ps2run_prev_bad() {
  local d=$1 msg=$2
  mv -f "$d/ps2run.prev" "$d/ps2run.prev.bad"
  rm -f "$d/ps2run.prev.sha256"
  echo "warning: $d/ps2run.prev $msg; not restoring it (moved to ps2run.prev.bad)" >&2
}
backup_ps2run() {
  local d=$1 sum
  rm -f "$d/ps2run.prev.tmp" "$d/ps2run.prev.sha256.tmp"
  [ -f "$d/ps2run" ] || return 0
  rm -f "$d/ps2run.prev.sha256"   # the old sidecar must never vouch for a new .prev
  cp -p "$d/ps2run" "$d/ps2run.prev.tmp" && mv -f "$d/ps2run.prev.tmp" "$d/ps2run.prev" || { rm -f "$d/ps2run.prev.tmp"; return 1; }
  sum=$(_ps2run_sha "$d/ps2run.prev") && printf '%s\n' "$sum" > "$d/ps2run.prev.sha256.tmp" \
    && mv -f "$d/ps2run.prev.sha256.tmp" "$d/ps2run.prev.sha256"
}
restore_ps2run() {
  local d=$1 why=$2 prev="$1/ps2run.prev" tmp="$1/ps2run.tmp" want
  rm -f "$d/ps2run.prev.tmp" "$d/ps2run.prev.sha256.tmp"   # leftovers of a killed backup
  [ -e "$prev" ] || { rm -f "$d/ps2run.prev.sha256"; return 0; }
  if [ ! -f "$prev" ] || [ ! -s "$prev" ] || [ ! -x "$prev" ]; then _ps2run_prev_bad "$d" "is empty or not executable"; return 1; fi
  want=$(head -c 64 "$d/ps2run.prev.sha256" 2>/dev/null || true)
  if [ -z "$want" ] || [ "$(_ps2run_sha "$prev")" != "$want" ]; then
    _ps2run_prev_bad "$d" "has no matching sha256 (incomplete backup)"; return 1
  fi
  if cp -p "$prev" "$tmp" && [ "$(_ps2run_sha "$tmp")" = "$want" ] && [ -x "$tmp" ] && mv -f "$tmp" "$d/ps2run"; then
    rm -f "$prev" "$d/ps2run.prev.sha256"; echo "$why"
  else
    rm -f "$tmp"; echo "warning: could not restore ps2run from $prev (left in place)" >&2
    return 1
  fi
}

# shellcheck shell=bash
# Lifeline Recomp: apply our patches to the ps2-web-recomp checkout, once each (sourced by build.sh).
#   apply_patches <src checkout> <dir with the .patch files> <patch>...   (oldest first)
# State: <src>/.git/lifeline-patches, one "name sha256" line per applied patch, written atomically after
# every apply, plus a copy of each applied patch in <src>/.git/lifeline-patches.d/ so a changed patch can be
# reverse-applied and re-applied. No marker, an unreadable one, or an apply that fails -> detection from the
# tree: the newest patch that reverse-applies is applied, and so is everything before it (later patches touch
# the same lines, so only the newest one can be checked). Recovery: delete the marker and run again.
_lp_sha() { sha256sum "$1" | cut -d' ' -f1; }

_lp_write() {   # rewrite the marker from LP_DONE (atomic: tmp + rename)
  local p tmp="$LP_MARK.tmp"
  : > "$tmp"
  for p in "${LP_ALL[@]}"; do [ -n "${LP_DONE[$p]:-}" ] && printf '%s %s\n' "$p" "${LP_DONE[$p]}" >> "$tmp"; done
  mv -f "$tmp" "$LP_MARK"
}

_lp_detect() {
  local i newest=-1
  LP_DONE=()
  for ((i=${#LP_ALL[@]}-1; i>=0; i--)); do
    if git -C "$LP_SRC" apply --reverse --check "$LP_DIR/${LP_ALL[$i]}" 2>/dev/null; then newest=$i; break; fi
  done
  for ((i=0; i<=newest; i++)); do
    LP_DONE[${LP_ALL[$i]}]=$(_lp_sha "$LP_DIR/${LP_ALL[$i]}")
    cp -f "$LP_DIR/${LP_ALL[$i]}" "$LP_STORE/${LP_ALL[$i]}"
  done
  _lp_write
  if [ "$newest" -ge 0 ]; then echo "patches already applied: ${LP_ALL[*]:0:newest+1}"; else echo "patches already applied: none"; fi
}

_lp_load() {   # marker -> LP_DONE; returns 1 if missing, old-format or corrupt
  local name sha extra
  LP_DONE=()
  [ -f "$LP_MARK" ] || return 1
  while IFS=' ' read -r name sha extra || [ -n "$name" ]; do
    name=${name%$'\r'}; sha=${sha%$'\r'}; extra=${extra%$'\r'}
    [ -z "$name$sha" ] && continue
    if [ -z "$sha" ]; then echo "patch marker from an older kit, detecting from the tree"; return 1; fi
    if [[ ! " ${LP_ALL[*]} " == *" $name "* ]] || [[ ! $sha =~ ^[0-9a-f]{64}$ ]] || [ -n "$extra" ]; then
      echo "patch marker $LP_MARK: unreadable line '$name $sha', detecting from the tree" >&2; return 1
    fi
    LP_DONE[$name]=$sha
  done < "$LP_MARK"
}

apply_patches() {
  LP_SRC=$1; LP_DIR=$2; shift 2; LP_ALL=("$@")
  LP_MARK="$LP_SRC/.git/lifeline-patches"; LP_STORE="$LP_SRC/.git/lifeline-patches.d"
  declare -gA LP_DONE=()
  mkdir -p "$LP_STORE"
  _lp_load || _lp_detect
  local i j p cur
  for ((i=0; i<${#LP_ALL[@]}; i++)); do
    p=${LP_ALL[$i]}; cur=$(_lp_sha "$LP_DIR/$p")
    [ "${LP_DONE[$p]:-}" = "$cur" ] && continue
    if [ -n "${LP_DONE[$p]:-}" ]; then   # changed since it was applied: take it and every later one back out
      echo "$p changed since it was applied; re-applying it and the patches after it"
      for ((j=${#LP_ALL[@]}-1; j>=i; j--)); do
        local q=${LP_ALL[$j]}
        [ -n "${LP_DONE[$q]:-}" ] || continue
        if [ -f "$LP_STORE/$q" ] && git -C "$LP_SRC" apply --reverse --index "$LP_STORE/$q"; then
          unset "LP_DONE[$q]"; _lp_write; echo "reverted $q"
        else
          echo "cannot take back the old $q; reset the checkout (git -C $LP_SRC reset --hard; rm $LP_MARK) and run again" >&2; return 1
        fi
      done
    fi
    if git -C "$LP_SRC" apply --index "$LP_DIR/$p"; then
      cp -f "$LP_DIR/$p" "$LP_STORE/$p"; LP_DONE[$p]=$cur; _lp_write; echo "applied $p"
      continue
    fi
    echo "$p does not apply; checking which patches the tree already has" >&2
    _lp_detect
    [ "${LP_DONE[$p]:-}" = "$cur" ] && continue
    echo "$p can't be applied to $LP_SRC; delete $LP_MARK (or reset the checkout) and run again" >&2
    return 1
  done
}

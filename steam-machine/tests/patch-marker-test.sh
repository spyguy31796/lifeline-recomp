#!/usr/bin/env bash
# Fast test of steam-machine/patches.sh on a synthetic checkout (no game data, no network):
#   steam-machine/tests/patch-marker-test.sh
# shellcheck disable=SC2015   # ok/bad always succeed
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=steam-machine/patches.sh
source "$HERE/../patches.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
P=(p1.patch p2.patch p3.patch p4.patch)

# upstream: one file; each patch edits a line right next to the previous one (shared context, like 0003-0005)
git init -q "$T/up"; git -C "$T/up" config user.email t@t; git -C "$T/up" config user.name t
seq 1 30 > "$T/up/f.txt"; git -C "$T/up" add f.txt; git -C "$T/up" commit -qm base
mkdir "$T/patches"
for i in 1 2 3 4; do
  sed -i "$((10 + i))s/.*/patched $i/" "$T/up/f.txt"; git -C "$T/up" diff > "$T/patches/p$i.patch"; git -C "$T/up" commit -qam "p$i"
done
want=$(cat "$T/up/f.txt")
fresh() { rm -rf "$T/src"; git clone -q "$T/up" "$T/src"; git -C "$T/src" checkout -q --detach "$(git -C "$T/up" rev-list --max-parents=0 HEAD)"; }
upto() { local i; for ((i=0; i<$1; i++)); do git -C "$T/src" apply --index "$T/patches/${P[$i]}"; done; }
M="$T/src/.git/lifeline-patches"
run() { apply_patches "$T/src" "$T/patches" "${P[@]}" > "$T/out" 2>&1; }
done_ok() { [ "$(cat "$T/src/f.txt")" = "$want" ] && [ "$(wc -l < "$M")" = 4 ]; }

fresh; run && done_ok && grep -q "already applied: none" "$T/out" && ok "unpatched checkout, no marker: all applied" || { bad "unpatched"; cat "$T/out"; }
run && ! grep -q "^applied" "$T/out" && done_ok && ok "second run applies nothing" || bad "idempotent"
fresh; upto 1; run && done_ok && grep -q "already applied: p1.patch$" "$T/out" && ok "only the oldest applied (interrupted clone): rest applied" || { bad "partial"; cat "$T/out"; }
fresh; upto 3; run && done_ok && grep -q "applied p4.patch" "$T/out" && ok "older kit (no marker, p1-p3 in tree): p4 applied" || { bad "older kit"; cat "$T/out"; }
fresh; upto 3; printf '%s\n' p1.patch p2.patch p3.patch > "$M"; run && done_ok && grep -q "older kit" "$T/out" && ok "name-only marker from the previous kit: detected" || { bad "legacy marker"; cat "$T/out"; }
fresh; upto 2; printf 'garbage line\n' > "$M"; run && done_ok && grep -q "unreadable line" "$T/out" && ok "corrupt marker: warned and detected" || { bad "corrupt"; cat "$T/out"; }
fresh; run; sed -i 's/$/\r/' "$M"; run && done_ok && ! grep -q "^applied\|unreadable" "$T/out" && ok "CRLF marker read fine" || { bad "crlf"; cat "$T/out"; }
fresh; run; grep -q " [0-9a-f]\{64\}$" "$M" && [ -f "$T/src/.git/lifeline-patches.d/p4.patch" ] && ok "marker has sha256 per patch, applied copies stored" || bad "marker format"
# a changed patch: p2 now writes something else -> p4..p2 taken back out, p2..p4 re-applied
fresh; run
cp "$T/patches/p2.patch" "$T/p2.orig"
git clone -q "$T/up" "$T/v2"; git -C "$T/v2" checkout -q HEAD~3   # p1 state; new p2 = old p2 + one more line far away
sed -i -e '12s/.*/patched 2/' -e '28s/.*/patched 2 v2/' "$T/v2/f.txt"; git -C "$T/v2" diff > "$T/patches/p2.patch"
run && grep -q "p2.patch changed" "$T/out" && grep -q "reverted p4.patch" "$T/out" && grep -q "applied p2.patch" "$T/out" \
  && [ "$(sed -n 28p "$T/src/f.txt")" = "patched 2 v2" ] && [ "$(sed -n 14p "$T/src/f.txt")" = "patched 4" ] \
  && grep -q "^p2.patch $(sha256sum < "$T/patches/p2.patch" | cut -d' ' -f1)$" "$M" && ok "changed patch: re-applied with the patches after it" || { bad "changed patch"; cat "$T/out"; }
cp "$T/p2.orig" "$T/patches/p2.patch"; run >/dev/null || true
# marker says p3 is missing but the tree has it: apply fails -> detection instead of aborting
fresh; run; grep -v '^p3\|^p4' "$M" > "$M.x"; mv "$M.x" "$M"
run && done_ok && grep -q "does not apply" "$T/out" && ok "apply failure falls back to detection" || { bad "fallback"; cat "$T/out"; }
# a patch that really can't apply: clear error, non-zero
fresh; run; printf -- '--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,1 @@\n-nope\n+x\n' > "$T/patches/p4.patch"; sed -i '/^p4/d' "$M"
if run; then bad "broken patch accepted"; else grep -q "delete .*lifeline-patches" "$T/out" && ok "unappliable patch: error names the marker to delete" || bad "error text"; fi
[ "$fail" = 0 ] && echo "patch marker tests passed" || echo "patch marker tests FAILED"
exit "$fail"

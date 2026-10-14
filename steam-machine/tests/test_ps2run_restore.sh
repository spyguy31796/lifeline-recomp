#!/usr/bin/env bash
# Tests restore_ps2run (steam-machine/ps2run_backup.sh): bash steam-machine/tests/test_ps2run_restore.sh
# shellcheck disable=SC2015  # ok/bad one-liners
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=steam-machine/ps2run_backup.sh
. "$here/ps2run_backup.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "ok: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
reset() { rm -rf "$T/n"; mkdir "$T/n"; printf 'new\n' > "$T/n/ps2run"; chmod +x "$T/n/ps2run"; }
reset; printf 'old\n' > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"
out=$(restore_ps2run "$T/n" "kept") && [ "$out" = kept ] && [ "$(cat "$T/n/ps2run")" = old ] && [ -x "$T/n/ps2run" ] \
  && [ ! -e "$T/n/ps2run.prev" ] && [ ! -e "$T/n/ps2run.tmp" ] && ok "good .prev restored, .prev and .tmp gone" || bad "good restore"
reset; : > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"
! restore_ps2run "$T/n" x 2>"$T/err" && [ "$(cat "$T/n/ps2run")" = new ] && [ -e "$T/n/ps2run.prev" ] && grep -q "empty or not executable" "$T/err" \
  && ok "empty .prev: not restored, warned" || bad "empty prev"
reset; printf 'old\n' > "$T/n/ps2run.prev"; chmod -x "$T/n/ps2run.prev"
! restore_ps2run "$T/n" x 2>/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && ok "non-executable .prev: not restored" || bad "noexec prev"
reset; restore_ps2run "$T/n" x >/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && ok "no .prev: nothing done" || bad "no prev"
# ps2run missing (killed mid-link) is restored too
reset; rm "$T/n/ps2run"; printf 'old\n' > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"
restore_ps2run "$T/n" x >/dev/null && [ "$(cat "$T/n/ps2run")" = old ] && ok "missing ps2run restored" || bad "missing ps2run"
# copy failure (dir not writable): ps2run untouched, .prev kept, no .tmp left
if [ "$(id -u)" != 0 ]; then
  reset; printf 'old\n' > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"; chmod a-w "$T/n"
  ! restore_ps2run "$T/n" x 2>/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && [ -e "$T/n/ps2run.prev" ] && [ ! -e "$T/n/ps2run.tmp" ] \
    && ok "copy failure: old ps2run and .prev kept" || bad "copy failure"
  chmod u+w "$T/n"
fi
[ "$fail" = 0 ] && echo "ps2run restore tests passed" || echo "ps2run restore tests FAILED"
exit "$fail"

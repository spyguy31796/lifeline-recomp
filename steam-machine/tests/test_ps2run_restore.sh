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
goodprev() { printf 'old\n' > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"; sha256sum < "$T/n/ps2run.prev" | cut -d' ' -f1 > "$T/n/ps2run.prev.sha256"; }
reset; goodprev
out=$(restore_ps2run "$T/n" "kept") && [ "$out" = kept ] && [ "$(cat "$T/n/ps2run")" = old ] && [ -x "$T/n/ps2run" ] \
  && [ ! -e "$T/n/ps2run.prev" ] && [ ! -e "$T/n/ps2run.prev.sha256" ] && [ ! -e "$T/n/ps2run.tmp" ] && ok "good .prev restored, .prev, sidecar and .tmp gone" || bad "good restore"
reset; : > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"
! restore_ps2run "$T/n" x 2>"$T/err" && [ "$(cat "$T/n/ps2run")" = new ] && [ ! -e "$T/n/ps2run.prev" ] && [ -e "$T/n/ps2run.prev.bad" ] && grep -q "empty or not executable" "$T/err" \
  && ok "empty .prev: not restored, warned, moved to .prev.bad" || bad "empty prev"
reset; printf 'old\n' > "$T/n/ps2run.prev"; chmod -x "$T/n/ps2run.prev"
! restore_ps2run "$T/n" x 2>/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && [ -e "$T/n/ps2run.prev.bad" ] && ok "non-executable .prev: not restored, moved to .prev.bad" || bad "noexec prev"
reset; restore_ps2run "$T/n" x >/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && ok "no .prev: nothing done" || bad "no prev"
# ps2run missing (killed mid-link) is restored too
reset; rm "$T/n/ps2run"; goodprev
restore_ps2run "$T/n" x >/dev/null && [ "$(cat "$T/n/ps2run")" = old ] && ok "missing ps2run restored" || bad "missing ps2run"
# copy failure (dir not writable): ps2run untouched, .prev kept, no .tmp left
if [ "$(id -u)" != 0 ]; then
  reset; goodprev; chmod a-w "$T/n"
  ! restore_ps2run "$T/n" x 2>/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && [ -e "$T/n/ps2run.prev" ] && [ ! -e "$T/n/ps2run.tmp" ] \
    && ok "copy failure: old ps2run and .prev kept" || bad "copy failure"
  chmod u+w "$T/n"
fi
# Voice's repro: 1 MB truncated but executable .prev (killed backup) must not replace a good ps2run
reset; head -c 2097152 /dev/urandom > "$T/n/ps2run"; chmod +x "$T/n/ps2run"; good=$(sha256sum < "$T/n/ps2run")
backup_ps2run "$T/n" && [ -e "$T/n/ps2run.prev.sha256" ] && [ ! -e "$T/n/ps2run.prev.tmp" ] && ok "backup writes .prev + sidecar, no .tmp" || bad "backup"
head -c 1048576 "$T/n/ps2run" > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"
! restore_ps2run "$T/n" x 2>"$T/err" && [ "$(sha256sum < "$T/n/ps2run")" = "$good" ] && [ -e "$T/n/ps2run.prev.bad" ] && [ ! -e "$T/n/ps2run.prev" ] \
  && grep -q "no matching sha256" "$T/err" && ok "truncated exec .prev (stale sidecar): not restored, moved to .prev.bad" || bad "truncated prev"
# same with no sidecar at all (killed before the sidecar was written)
reset; head -c 1048576 /dev/urandom > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"
! restore_ps2run "$T/n" x 2>/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && [ -e "$T/n/ps2run.prev.bad" ] && ok "exec .prev without sidecar: not restored" || bad "no sidecar"
# only one .prev.bad is kept
printf 'x' > "$T/n/ps2run.prev"; chmod +x "$T/n/ps2run.prev"
! restore_ps2run "$T/n" x 2>/dev/null && [ "$(cat "$T/n/ps2run.prev.bad")" = x ] && [ "$(ls "$T/n" | grep -c prev.bad)" = 1 ] && ok "single .prev.bad kept" || bad "single bad"
# stale .prev.tmp from a killed backup is cleaned up
reset; printf 'half' > "$T/n/ps2run.prev.tmp"; printf 'h' > "$T/n/ps2run.prev.sha256.tmp"
restore_ps2run "$T/n" x >/dev/null && [ ! -e "$T/n/ps2run.prev.tmp" ] && [ ! -e "$T/n/ps2run.prev.sha256.tmp" ] && [ "$(cat "$T/n/ps2run")" = new ] && ok "stale .prev.tmp cleaned" || bad "stale tmp"
reset; printf 'half' > "$T/n/ps2run.prev.tmp"; backup_ps2run "$T/n" && [ "$(cat "$T/n/ps2run.prev")" = new ] && [ ! -e "$T/n/ps2run.prev.tmp" ] && restore_ps2run "$T/n" x >/dev/null && [ "$(cat "$T/n/ps2run")" = new ] && ok "backup then restore round-trips" || bad "roundtrip"
[ "$fail" = 0 ] && echo "ps2run restore tests passed" || echo "ps2run restore tests FAILED"
exit "$fail"

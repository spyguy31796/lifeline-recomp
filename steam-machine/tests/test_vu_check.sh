#!/usr/bin/env bash
# vu-check.sh wiring (no game data, fake ps2run/distrobox): finds lifeline.env from the install dir, re-runs
# itself inside the lifeline-build distrobox with absolute state paths, and reports pass/mismatch.
#   steam-machine/tests/test_vu_check.sh
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; expect() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: got '$2' want '$3'"; fail=1; fi; }
has() { if grep -q -- "$3" <<<"$2"; then echo "ok: $1"; else echo "FAIL: $1: '$3' not in: $2"; fail=1; fi; }
W="$T/home/lifeline-recomp"; mkdir -p "$W/saves" "$T/bin" "$T/other"
cp "$KIT/vu-check.sh" "$W/vu-check.sh"; chmod +x "$W/vu-check.sh"
: > "$W/saves/a.state"; : > "$W/mc.ps2"
cat > "$T/bin/ps2run" <<'P'
#!/bin/sh
echo "args: $*" >&2
case "$FAKE_RESULT" in mismatch) echo "[vu-check] MISMATCH x" >&2; echo "[vu-check] done: 3 calls checked, 1 mismatches" >&2;;
  *) echo "[vu-check] done: 3 calls checked, 0 mismatches" >&2;; esac
P
chmod +x "$T/bin/ps2run"
printf 'PS2RUN=%s\nELF=x.elf\nISO=x.iso\nMEMCARD=%s\n' "$T/bin/ps2run" "$W/mc.ps2" > "$W/lifeline.env"
# fake distrobox: lists the box, and "enter <box> -- cmd..." records the call then runs cmd (like the real one)
cat > "$T/bin/distrobox" <<'D'
#!/bin/bash
case "$1" in list) echo "ID | NAME | STATUS"; echo "x | lifeline-build | Up";;
  enter) echo "$*" > "$DBX_LOG"; shift 3; cd /; exec "$@";; esac
D
chmod +x "$T/bin/distrobox"
export HOME="$T/home" DBX_LOG="$T/dbx.log" PATH="$T/bin:$PATH"; unset LIFELINE_WORK VU_CHECK_IN_BOX
[ -e /run/.containerenv ] && echo "note: running inside a container; the distrobox step is skipped by design"

# 1) installed copy, relative state path: enters the box, absolute path, env found from the install dir
out=$(cd "$W" && ./vu-check.sh saves/a.state:100 2>&1); rc=$?
expect "pass exits 0" "$rc" 0
has "pass reported" "$out" "a.state: done: 3 calls checked, 0 mismatches"
if [ ! -e /run/.containerenv ]; then
  has "entered lifeline-build" "$(cat "$DBX_LOG")" "enter lifeline-build -- env VU_CHECK_IN_BOX=1 LIFELINE_WORK=$W"
  has "state path made absolute" "$(cat "$DBX_LOG")" "$W/saves/a.state:100"
fi
has "ps2run got the state and frames" "$(cat "$W/logs/vu-check-a.log")" "--load-state $W/saves/a.state --frames 100"
# 2) kit copy (no lifeline.env next to it): falls back to ~/lifeline-recomp
cp "$KIT/vu-check.sh" "$T/other/vu-check.sh"; rm -f "$DBX_LOG"
out=$(cd "$T/other" && bash ./vu-check.sh "$W/saves/a.state:100" 2>&1); rc=$?
expect "kit copy finds ~/lifeline-recomp" "$rc" 0
# 3) mismatch -> exit 1 and the line is shown
out=$(cd "$W" && FAKE_RESULT=mismatch ./vu-check.sh saves/a.state:100 2>&1); rc=$?
expect "mismatch exits 1" "$rc" 1
has "mismatch line shown" "$out" "MISMATCH"
# 4) no install: clear error, exit 2
out=$(cd "$T/other" && HOME="$T/nohome" bash ./vu-check.sh x.state:1 2>&1); rc=$?
expect "missing lifeline.env exits 2" "$rc" 2
has "missing lifeline.env message" "$out" "no $T/nohome/lifeline-recomp/lifeline.env"
# 5) no distrobox with the box: runs directly
printf '#!/bin/sh\n[ "$1" = list ] && echo "ID | NAME"\n' > "$T/bin/distrobox"; rm -f "$DBX_LOG"
out=$(cd "$W" && ./vu-check.sh saves/a.state:100 2>&1); rc=$?
expect "no lifeline-build: direct run passes" "$rc" 0
expect "no lifeline-build: distrobox not entered" "$([ -e "$DBX_LOG" ] && echo entered || echo direct)" direct
[ "$fail" = 0 ] && echo "vu-check tests passed"; exit "$fail"

#!/usr/bin/env bash
# Parity check (Linux dev box with pwsh): steam-machine/make-skip-state.sh and windows/make-skip-state.ps1 must start
# ps2run with the same segments, arguments, presses and per-segment environment, drop delivered answers from the
# queue the same way, and end with the same messages and exit codes. Both drive a stub ps2run (no game, no game
# data: the queue holds made-up words). Also checks make-skip-state.ps1 -DryRun against what the stub saw, -StopAt,
# the CRLF/BOM queue, and the "ps2run is running" refusal (inside unshare, so no other process is ever seen).
#   windows/tests/compare-skip-state-sh.sh [path/to/pwsh]
# Run it inside `unshare -Urpf --mount-proc` when a real ps2run may be running on this machine.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${1:-${PWSH:-pwsh}}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
ok() { n=$((n+1)); echo "ok: $1"; }
bad() { n=$((n+1)); echo "FAIL: $1"; fail=1; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
CLEAN=(env); for v in $(env | grep -o '^PS2_[A-Za-z0-9_]*'); do CLEAN+=(-u "$v"); done

# stub ps2run: prints what it got, "delivers" up to 2 queued answers per tutorial segment, saves the state file
cat > "$T/ps2run-stub" <<'STUB'
#!/bin/sh
for k in PS2_VOICE_CONTEXT PS2_VOICE_INJECT PS2_VOICE_ASSETS PS2_VOICE_DEBUG PS2_GPU_LOW_POWER; do
  eval "x=\${$k-UNSET}"; printf 'ENV %s=%s\n' "$k" "$x" >&2; done
printf 'ENV other PS2_ vars: %s\n' "$(env | grep '^PS2_' | grep -cvE '^PS2_(VOICE_(CONTEXT|INJECT|ASSETS|DEBUG)|GPU_LOW_POWER)=')" >&2
for a in "$@"; do printf 'ARG<%s>\n' "$a" >&2; done
sed 's/^/QUEUE </; s/$/>/' "$PS2_VOICE_INJECT" >&2
echo "[voice] f1 context identified (posted f1): ctx=$PS2_VOICE_CONTEXT (1 B)" >&2
save=; prev=; for a in "$@"; do [ "$prev" = --save-state ] && save=$a; prev=$a; done
frame=${save%%:*}; path=${save#*:}
case "$PS2_VOICE_CONTEXT" in 1000.a/os_999) head -n 2 "$PS2_VOICE_INJECT" | while IFS= read -r l; do echo "[voice] f9 injected '${l#* }' (1 words)" >&2; done ;; esac
[ "$PS2_VOICE_CONTEXT" = 013.a/os_601 ] && [ -z "${STUB_DEAF:-}" ] && echo "[voice] f52101 cmd 1 listen" >&2
[ "$frame" = "${STUB_NOSAVE:-}" ] || echo "state $frame" > "$path"
exit 3
STUB
chmod +x "$T/ps2run-stub"
mk() {  # fresh install root $1 with both settings files and a made-up queue
  local H=$1; rm -rf "$H"; mkdir -p "$H/saves"
  cp "$REPO/steam-machine/make-skip-state.sh" "$H/"
  printf 'PS2RUN="%s"\nELF="%s"\nISO="%s"\nPS2_VOICE_ASSETS="%s"\n' "$T/ps2run-stub" "$H/game.elf" "$H/My Disc (USA).iso" "$H/voice-assets" > "$H/lifeline.env"
  printf '{\n  "PS2RUN": "%s",\n  "ELF": "%s",\n  "ISO": "%s",\n  "PS2_VOICE_ASSETS": "%s"\n}\n' "$T/ps2run-stub" "$H/game.elf" "$H/My Disc (USA).iso" "$H/voice-assets" > "$H/lifeline.env.json"
  : > "$H/saves/tutorial-queue.txt"; for i in $(seq 1 30); do echo "word$i word$i" >> "$H/saves/tutorial-queue.txt"; done
  echo "500 timed answer" >> "$H/saves/tutorial-queue.txt"
}
norm() { sed -E 's/[0-9]+s$/Ns/; s/ in [0-9]+s$/ in Ns/'; }
H="$T/root"
run_sh() { "${CLEAN[@]}" "$@" bash "$H/make-skip-state.sh" > "$T/sh.out" 2> "$T/sh.err"; echo $?; }
run_ps() { local e=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done; [ $# -gt 0 ] && shift
  "${CLEAN[@]}" "${e[@]}" "$PWSH" -NoProfile -File "$REPO/windows/make-skip-state.ps1" -Root "$H" "$@" > "$T/ps.out" 2> "$T/ps.err"; echo $?; }

# 1. full run: same logs (argv, env, queue per segment), same state, same messages, same exit code
mk "$H"; rc_sh=$(run_sh); mv "$H/logs/skip-state" "$T/sh-logs"; cp "$H/saves/room001.state" "$T/sh.state"; rm -f "$H/saves/room001.state"
rc_ps=$(run_ps); mv "$H/logs/skip-state" "$T/ps-logs"
expect "full run: exit code (sh $rc_sh)" "$rc_ps" "$rc_sh"
expect "full run: 27 segment logs" "$(ls "$T/ps-logs"/run_*.log | wc -l)" "27"
if d=$(diff -r "$T/sh-logs" "$T/ps-logs"); then ok "full run: every segment's argv, env, queue and states identical"; else bad "full run: logs differ"; echo "$d" | head -40 | sed 's/^/    /'; fi
expect "full run: room001.state is frame 52000" "$(cat "$H/saves/room001.state" 2>/dev/null)" "$(cat "$T/sh.state")"
expect "full run: stdout" "$(norm < "$T/ps.out")" "$(norm < "$T/sh.out")"
expect "full run: per-segment context (tut x20, room x7)" "$(grep -h '^ENV PS2_VOICE_CONTEXT' "$T/ps-logs"/run_*.log | sort | uniq -c | sort -rn | tr -s ' ' | tr '\n' '|')" " 20 ENV PS2_VOICE_CONTEXT=1000.a/os_999| 7 ENV PS2_VOICE_CONTEXT=013.a/os_601|"
expect "full run: no stray PS2_ vars reach ps2run" "$(grep -h '^ENV other' "$T/ps-logs"/run_*.log | sort -u)" "ENV other PS2_ vars: 0"
expect "full run: no empty env value" "$(grep -hc '^ENV [A-Z0-9_]*=$' "$T/ps-logs"/run_0.log)" "0"

# 2. -DryRun prints exactly the env + argv the stub saw from the .sh, and writes nothing
mk "$H"; rc=$(run_ps -- -DryRun)
expect "dry run: exit 0" "$rc" "0"
expect "dry run: writes nothing" "$(ls "$H")" "$(printf 'lifeline.env\nlifeline.env.json\nmake-skip-state.sh\nsaves')"
dry=$(awk '/^segment /{s=$2; sub(/-.*/,"",s)} /^  (env|arg) /{sub(/^  /,""); print s" "$0}' "$T/ps.out")
seen=$(for f in $(ls "$T/sh-logs"/run_*.log | sort -t_ -k3 -n); do s=$(basename "$f" .log); s=${s#run_}
  grep -E '^(ARG<|ENV PS2_)' "$f" | sed -E "s/^ARG<(.*)>$/$s arg \\1/; s/^ENV /$s env /"; done)
seen=$(printf '%s\n' "$seen" | grep -v ' env PS2_.* other' | sort -s -n -k1,1); dry=$(printf '%s\n' "$dry" | sort -s -n -k1,1)
if [ "$dry" = "$seen" ]; then ok "dry run: env + argv of all 27 segments = what the .sh started ($(printf '%s\n' "$dry" | wc -l) lines)"
else bad "dry run differs from the .sh"; diff <(printf '%s\n' "$seen") <(printf '%s\n' "$dry") | head -20 | sed 's/^/    /'; fi

# 3. -StopAt 17300: the .sh's first 9 segments, then tut_17300.state
mk "$H"; rc=$(run_ps -- -StopAt 17300)
expect "-StopAt 17300: exit 0" "$rc" "0"
expect "-StopAt 17300: 9 segments" "$(ls "$H/logs/skip-state"/run_*.log | wc -l)" "9"
same=1; for f in "$H/logs/skip-state"/run_*.log; do cmp -s "$f" "$T/sh-logs/$(basename "$f")" || same=0; done
expect "-StopAt 17300: segment logs identical to the .sh's" "$same" "1"
expect "-StopAt 17300: default out saves/tut_17300.state" "$(cat "$H/saves/tut_17300.state" 2>/dev/null)" "state 17300"
expect "-StopAt 17300: no room001.state" "$(ls "$H/saves")" "$(printf 'tut_17300.state\ntutorial-queue.txt')"
expect "-StopAt 17300: OK line" "$(tail -n1 "$T/ps.out" | norm)" "OK: $H/saves/tut_17300.state (frame 17300) in Ns"
mk "$H"; rc=$(run_ps -- -StopAt 17301 -DryRun); expect "-StopAt not a segment end: exit 1" "$rc" "1"
mk "$H"; rc=$(run_ps -- -StopAt 41700 -Out "$T/x.state")
expect "-StopAt 41700 -Out: state + exit 0" "$rc $(cat "$T/x.state" 2>/dev/null)" "0 state 41700"

# 4. CRLF + BOM queue (Notepad) gives the same injector file as the LF queue
mk "$H"; { printf '\xef\xbb\xbf'; sed 's/$/\r/' "$H/saves/tutorial-queue.txt"; } > "$T/q-crlf.txt"
run_ps -- -Queue "$T/q-crlf.txt" -StopAt 2000 > /dev/null
expect "CRLF + BOM queue: same queue as the .sh" "$(grep '^QUEUE' "$H/logs/skip-state/run_0.log" | md5sum)" "$(grep '^QUEUE' "$T/sh-logs/run_0.log" | md5sum)"

# 5. failure paths: same exit code and message on both sides
check_fail() {  # name, env...
  local name=$1; shift; mk "$H"; local a b; a=$(run_sh "$@"); b=$(run_ps "$@")
  expect "$name: exit code (sh $a)" "$b" "$a"
  expect "$name: message" "$(tail -n1 "$T/ps.err")" "$(tail -n1 "$T/sh.err")"
}
check_fail "segment saves no state" STUB_NOSAVE=4000
check_fail "game does not listen" STUB_DEAF=1
mk "$H"; : > "$H/saves/tutorial-queue.txt"; a=$(run_sh); b=$(run_ps)
expect "empty queue: exit code (sh $a)" "$b" "$a"; expect "empty queue: message" "$(cat "$T/ps.err")" "$(cat "$T/sh.err")"

# 6. refuses while a ps2run runs (own pid namespace, so only our dummy is visible); stops nothing, writes nothing
if unshare -Urpf --mount-proc true 2>/dev/null; then
  mk "$H"; cp /bin/sleep "$T/ps2run"
  out=$(unshare -Urpf --mount-proc bash -c '"$1" 30 & d=$!; sleep 0.3
    "$3" -NoProfile -File "$2/windows/make-skip-state.ps1" -Root "$4" >/dev/null 2>"$4.err"; rc=$?
    kill -0 $d && alive=alive || alive=dead; kill $d; echo "$rc $alive"' _ "$T/ps2run" "$REPO" "$PWSH" "$H")
  expect "ps2run running: exit 2, the running one untouched" "$out" "2 alive"
  expect "ps2run running: message" "$(grep -c '^ps2run is running (pid [0-9]*); close the game first' "$H.err")" "1"
  expect "ps2run running: nothing written" "$(ls "$H/logs" 2>/dev/null | wc -l)" "0"
else echo "skip: unshare not available (ps2run-running check)"; fi

[ "$fail" = 0 ] && echo "make-skip-state parity: all $n checks passed" || echo "make-skip-state parity: FAILURES"; exit "$fail"

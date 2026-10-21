#!/usr/bin/env bash
# Linux behaviour of the launcher must not change with the Windows branches: run the launcher from REV (default
# origin/main) and from the working tree with the same configs and compare --dry-run, --print-config and the
# config.ini that --set / --reset-bindings write, byte for byte. No game data. Usage: windows/tests/compare-launcher-linux.sh [REV]
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; REV="${1:-origin/main}"; PY="${PY:-python3}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/old" "$T/new"
for f in lifeline_launcher.py bindings.py; do
  git -C "$REPO" show "$REV:steam-machine/launcher/$f" > "$T/old/$f" || exit 1
  cp "$REPO/steam-machine/launcher/$f" "$T/new/$f"
done
fail=0; n=0
# each case runs in a fresh $T/w (both versions see the same path, so outputs can be compared byte for byte)
case_run() { local name="$1" cfg="$2"; shift 2
  for v in old new; do
    rm -rf "$T/w" "$T/h"; mkdir -p "$T/w" "$T/h/Downloads"
    [ "$cfg" != - ] && printf '%b' "$cfg" > "$T/w/config.ini"
    HOME="$T/h" LIFELINE_WORK="$T/w" PYTHONDONTWRITEBYTECODE=1 "$PY" "$T/$v/lifeline_launcher.py" "$@" > "$T/out-$v" 2>&1; echo "exit $?" >> "$T/out-$v"
    if [ -f "$T/w/config.ini" ]; then cp "$T/w/config.ini" "$T/cfg-$v"; else : > "$T/cfg-$v"; fi
    (cd "$T/w" && find . -type f | sort) > "$T/files-$v"
  done
  n=$((n + 1))
  if cmp -s "$T/out-old" "$T/out-new" && cmp -s "$T/cfg-old" "$T/cfg-new" && cmp -s "$T/files-old" "$T/files-new"; then echo "same: $name"
  else echo "DIFF: $name"; diff "$T/out-old" "$T/out-new"; diff "$T/cfg-old" "$T/cfg-new"; diff "$T/files-old" "$T/files-new"; fail=1; fi
}
case_run "dry-run, fresh"                 -  --dry-run
case_run "dry-run --new-game, fresh"      -  --dry-run --new-game
case_run "print-config, fresh"            -  --print-config
SKIP='[launch]\nskip_tutorial = 1\ndebug = 0\nfullscreen = 1\nvoice_off = 1\n[qol]\nwidescreen = 1\nbutton_icons = xbox  # note\n'
case_run "dry-run, skip_tutorial"         "$SKIP" --dry-run
case_run "dry-run --new-game, skip_tutorial" "$SKIP" --dry-run --new-game
case_run "print-config, custom"           "$SKIP" --print-config
case_run "set qol + launch"               -  --set qol.resolution_scale=2 --set launch.debug=0 --set build.cpu_tuned=1
case_run "set bindings"                   -  --set bindings.cross=a --set bindings.ff=tab
case_run "set bad key"                    -  --set nosuch.key=1
case_run "reset-bindings"                 '[bindings]\ncross = a\n' --reset-bindings
case_run "help"                           -  --help
echo "compare-launcher-linux: $n cases vs $REV, $([ $fail = 0 ] && echo 'all identical' || echo 'DIFFERENCES')"; exit $fail

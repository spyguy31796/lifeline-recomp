#!/usr/bin/env bash
# Host-only unit tests (no game data, no runtime build): C++ logic tests + launcher Python tests.
# Usage: steam-machine/tests/run-unit-tests.sh      (CXX overrides the compiler; default clang++)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; CXX="${CXX:-clang++}"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
run_bin() { if "$@"; then :; else echo "FAILED: $*"; fail=1; fi; }
# fmv_skip is header-only: compile the test alone
if "$CXX" -std=c++20 -Wall -Wextra -I"$ROOT/fmv" "$ROOT/fmv/tests/test_fmv_skip.cpp" -o "$T/test_fmv_skip" && "$T/test_fmv_skip"; then :; else echo "FAILED: test_fmv_skip"; fail=1; fi
# hotkeys + input_map need their .cpp sources (see the comment at the top of each test file)
if "$CXX" -std=c++20 -Wall -Wextra -I"$ROOT/input" "$ROOT/input/input_map.cpp" "$ROOT/input/hotkeys.cpp" "$ROOT/input/tests/test_hotkeys.cpp" -o "$T/test_hotkeys" && "$T/test_hotkeys"; then :; else echo "FAILED: test_hotkeys"; fail=1; fi
if "$CXX" -std=c++20 -Wall -Wextra -I"$ROOT/input" "$ROOT/input/input_map.cpp" "$ROOT/input/tests/test_input_map.cpp" -o "$T/test_input_map" && "$T/test_input_map"; then :; else echo "FAILED: test_input_map"; fail=1; fi
if "$CXX" -std=c++20 -Wall -Wextra -I"$ROOT/voice" "$ROOT/voice/tests/test_listen_reset.cpp" -o "$T/test_listen_reset" && "$T/test_listen_reset"; then :; else echo "FAILED: test_listen_reset"; fail=1; fi
bash "$ROOT/steam-machine/tests/test_vu_check.sh" >/dev/null || { echo "FAILED: test_vu_check.sh"; fail=1; }
# Launcher tests: the launcher's own venv has pygame (test_bindings / test_play need it). LAUNCHER_PY overrides;
# else $LIFELINE_WORK (default ~/lifeline-recomp)/launcher-venv/bin/python if it runs and imports pygame; else python3.
PY="${LAUNCHER_PY:-}"
if [ -z "$PY" ]; then
  VPY="${LIFELINE_WORK:-$HOME/lifeline-recomp}/launcher-venv/bin/python"
  if [ -x "$VPY" ] && "$VPY" -c "import pygame" >/dev/null 2>&1; then PY="$VPY"; else PY=python3; fi
fi
echo "launcher tests with: $PY"
for t in "$ROOT"/steam-machine/launcher/tests/test_*.py; do "$PY" "$t" || { echo "FAILED: $(basename "$t")"; fail=1; }; done
[ $fail = 0 ] && echo "run-unit-tests: all OK" || echo "run-unit-tests: FAILURES"; exit $fail

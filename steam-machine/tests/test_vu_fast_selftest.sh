#!/usr/bin/env bash
# Runs the [qol] vu_fast self-test in a ps2run built with patch 0006 (no game data is loaded):
# random VU1 programs through the original interpreter and the faster one; every result must match.
#   tests/test_vu_fast_selftest.sh <ps2run> [programs]
set -euo pipefail
P=${1:?usage: test_vu_fast_selftest.sh <ps2run> [programs]}
out=$(PS2_VU_SELFTEST="${2:-20000}" "$P" 2>/dev/null | tail -1) || { echo "FAIL: $out"; exit 1; }
echo "$out"; [[ $out == *" 0 mismatches"* ]] && echo "vu_fast selftest passed"

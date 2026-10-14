#!/usr/bin/env bash
# Tests for steam-machine/cpu_flags.sh with stub cmake/ninja/ld.lld. Run: bash steam-machine/tests/test_cpu_flags.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
check() { if eval "$1"; then :; else echo "FAIL: $2"; fails=$((fails+1)); fi; }
mkdir -p "$T/bin" "$T/b"
# stub cmake records flags; stub ninja fails when the cached flags contain -flto and NINJA_LTO_FAILS=1
cat > "$T/bin/cmake" <<'S'
#!/bin/bash
for a; do case "$a" in -DCMAKE_CXX_FLAGS=*) echo "${a#*=}" > "$STUB/cxx";; -DCMAKE_EXE_LINKER_FLAGS=*) echo "${a#*=}" > "$STUB/ld";; esac; done
echo "cmake $*" >> "$STUB/calls"
S
cat > "$T/bin/ninja" <<'S'
#!/bin/bash
echo "ninja $(cat "$STUB/cxx")" >> "$STUB/calls"
if [ "${NINJA_LTO_FAILS:-0}" = 1 ] && grep -q flto "$STUB/cxx"; then echo "ld.lld: error: LTO failed"; exit 1; fi
echo built
S
printf '#!/bin/sh\n' > "$T/bin/ld.lld"; chmod +x "$T/bin/"*
# PATH = stubs + only the basic tools used here, so a real ld.lld/cmake on the machine can't leak in
mkdir -p "$T/sys"; for t in bash sh cat grep tail rm mkdir; do ln -s "$(command -v $t)" "$T/sys/$t"; done
export STUB="$T" PATH="$T/bin:$T/sys"
. "$HERE/../cpu_flags.sh"
run() { : > "$T/calls"; FLAVOR_FILE="$T/flavor" build_native /src "$T/b" -DX=1 > "$T/out" 2>&1; echo $? > "$T/rc"; }

CPU_TUNED=0 run
check '[ "$(cat $T/rc)" = 0 ] && [ "$(cat $T/flavor)" = generic ] && [ -z "$(cat $T/cxx)" ]' "default generic build, empty flags"
check 'grep -q "flavor=generic" $T/out' "generic flags logged"

CPU_TUNED=1 run
check '[ "$(cat $T/flavor)" = cpu_tuned ] && grep -q -- "-march=native -flto=thin" $T/cxx && grep -q -- "-fuse-ld=lld" $T/ld' "tuned: march + thinLTO + lld"
check 'grep -q "flavor=cpu_tuned CXXFLAGS=.-march=native -flto=thin" $T/out' "tuned flags logged"

CPU_TUNED=1 CPU_MARCH=znver4 run
check 'grep -q -- "-march=znver4" $T/cxx' "CPU_MARCH override"

CPU_TUNED=1 NINJA_LTO_FAILS=1 run
check '[ "$(cat $T/rc)" = 0 ] && [ "$(cat $T/flavor)" = generic-fallback ] && [ -z "$(cat $T/cxx)" ]' "LTO failure falls back to a clean generic build"
check 'grep -q "falling back to a generic build" $T/out && [ $(grep -c ^ninja $T/calls) = 2 ]' "fallback logged, built twice"

rm "$T/bin/ld.lld"; CPU_TUNED=1 run
check '[ "$(cat $T/flavor)" = cpu_tuned ] && ! grep -q flto $T/cxx && grep -q "ld.lld not found" $T/out' "no lld: march only, logged"

printf '#!/bin/bash\necho "ninja" >> "$STUB/calls"; exit 1\n' > "$T/bin/ninja"; CPU_TUNED=0 run
check '[ "$(cat $T/rc)" = 1 ]' "generic build failure is an error (no fallback loop)"
[ $fails = 0 ] && echo "all cpu_flags tests passed" || { echo "$fails FAILED"; exit 1; }

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
mkdir -p "$T/sys"; for t in bash sh cat grep tail rm mkdir sed head mv chmod; do ln -s "$(command -v $t)" "$T/sys/$t"; done
export STUB="$T" PATH="$T/bin:$T/sys"
. "$HERE/../cpu_flags.sh"
printf 'processor\t: 0\nmodel name\t: Test CPU 9000\n' > "$T/cpuinfo"; export LIFELINE_CPUINFO="$T/cpuinfo"
run() { unset CPU_FLAVOR; : > "$T/calls"; FLAVOR_FILE="$T/flavor" build_native /src "$T/b" -DX=1 > "$T/out" 2>&1; echo $? > "$T/rc"; }

CPU_TUNED=0 run
check '[ "$(cat $T/rc)" = 0 ] && [ "$(head -1 $T/flavor)" = generic ] && [ -z "$(cat $T/cxx)" ]' "default generic build, empty flags"
check 'grep -q "flavor=generic" $T/out' "generic flags logged"

CPU_TUNED=1 run
check '[ "$(head -1 $T/flavor)" = cpu_tuned ] && grep -q -- "-march=native -flto=thin" $T/cxx && grep -q -- "-fuse-ld=lld" $T/ld' "tuned: march + thinLTO + lld"
check 'grep -q "flavor=cpu_tuned CXXFLAGS=.-march=native -flto=thin" $T/out' "tuned flags logged"

CPU_TUNED=1 CPU_MARCH=znver4 run
check 'grep -q -- "-march=znver4" $T/cxx' "CPU_MARCH override"

CPU_TUNED=1 NINJA_LTO_FAILS=1 run
check '[ "$(cat $T/rc)" = 0 ] && [ "$(head -1 $T/flavor)" = generic-fallback ] && [ -z "$(cat $T/cxx)" ]' "LTO failure falls back to a clean generic build"
check 'grep -q "falling back to a generic build" $T/out && [ $(grep -c ^ninja $T/calls) = 2 ]' "fallback logged, built twice"

rm "$T/bin/ld.lld"; CPU_TUNED=1 run
check '[ "$(head -1 $T/flavor)" = cpu_tuned ] && ! grep -q flto $T/cxx && grep -q "ld.lld not found" $T/out' "no lld: march only, logged"

printf '#!/bin/bash\necho "ninja" >> "$STUB/calls"; exit 1\n' > "$T/bin/ninja"; CPU_TUNED=0 run
check '[ "$(cat $T/rc)" = 1 ]' "generic build failure is an error (no fallback loop)"
check 'grep -qx "cpu=Test CPU 9000" $T/flavor' "build-flavor records the CPU model"

# stale cached flags: a tuned build with lld cached -fuse-ld=lld; lld is gone now. The pre-port configure
# (always passing our flags) must clear them before port.sh's first compile, without a fallback.
cat > "$T/bin/ninja" <<'S'
#!/bin/bash
echo "ninja" >> "$STUB/calls"
if grep -q lld "$STUB/ld" && ! command -v ld.lld >/dev/null; then echo "clang: error: invalid linker name in argument '-fuse-ld=lld'"; exit 1; fi
echo built
S
chmod +x "$T/bin/ninja"
printf '#!/bin/sh\n' > "$T/bin/ld.lld"; chmod +x "$T/bin/ld.lld"
CPU_TUNED=1 run; check 'grep -q lld $T/ld' "setup: tuned build cached -fuse-ld=lld"
rm "$T/bin/ld.lld"; unset CPU_FLAVOR; : > "$T/calls"
cfg() { cpu_cmake_args; cmake -S /src -B "$T/b" "${CPU_CMAKE_ARGS[@]}"; }
port() { ninja; }   # port.sh's first compile uses whatever is cached
CPU_TUNED=1 cpu_flags > "$T/out" 2>&1; cfg; CPU_TUNED=1 port_with_fallback cfg port >> "$T/out" 2>&1; echo $? > "$T/rc"
check '[ "$(cat $T/rc)" = 0 ] && ! grep -q lld $T/ld && [ "$CPU_FLAVOR" = cpu_tuned ] && ! grep -q "falling back" $T/out' "stale lld flags cleared by the pre-port configure (still tuned, no fallback)"
# and if the tuned first compile does fail, port_with_fallback re-configures generic and retries once
printf '#!/bin/sh\n' > "$T/bin/ld.lld"; chmod +x "$T/bin/ld.lld"; unset CPU_FLAVOR
port() { if grep -q flto "$STUB/cxx"; then return 1; fi; ninja; }
CPU_TUNED=1 cpu_flags > "$T/out" 2>&1; cfg; CPU_TUNED=1 port_with_fallback cfg port >> "$T/out" 2>&1; echo $? > "$T/rc"
check '[ "$(cat $T/rc)" = 0 ] && [ "$CPU_FLAVOR" = generic-fallback ] && [ -z "$(cat $T/cxx)" ] && grep -q "first compile failed" $T/out' "tuned first compile failure falls back before the final build"
FLAVOR_FILE="$T/flavor" build_native /src "$T/b" > "$T/out" 2>&1
check '[ "$(head -1 $T/flavor)" = generic-fallback ] && [ -z "$(cat $T/cxx)" ]' "final build keeps the fallback (no second tuned attempt)"
[ $fails = 0 ] && echo "all cpu_flags tests passed" || { echo "$fails FAILED"; exit 1; }

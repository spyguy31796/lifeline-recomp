# Sourced by build.sh. CPU-tuned build option (launcher: [build] cpu_tuned, env CPU_TUNED=1).
#   cpu_flags            sets CPU_FLAVOR / CPU_CXXFLAGS / CPU_LDFLAGS from CPU_TUNED (+ CPU_MARCH, default native)
#   build_native S B ... configure (cmake -S S -B B ...extra args) + ninja ps2run with those flags; if the
#                        tuned build fails (e.g. LTO/linker trouble), reconfigure generic and build again.
#   Writes the flavor that was actually built to $FLAVOR_FILE (cpu_tuned | generic | generic-fallback).
# PGO is intentionally not part of this.
cpu_flags() {
  CPU_FLAVOR=generic; CPU_CXXFLAGS=""; CPU_LDFLAGS=""
  if [ "${CPU_TUNED:-0}" = 1 ]; then
    CPU_FLAVOR=cpu_tuned; CPU_CXXFLAGS="-march=${CPU_MARCH:-native}"
    if command -v ld.lld >/dev/null 2>&1; then
      CPU_CXXFLAGS="$CPU_CXXFLAGS -flto=thin"; CPU_LDFLAGS="-flto=thin -fuse-ld=lld"
    else
      echo "== cpu flags: ld.lld not found, building -march only (no LTO)"
    fi
  fi
}

_configure_and_build() {  # S B CXXFLAGS LDFLAGS extra-cmake-args...
  local s=$1 b=$2 cf=$3 lf=$4; shift 4
  cmake -S "$s" -B "$b" -G Ninja "$@" -DCMAKE_CXX_FLAGS="$cf" -DCMAKE_EXE_LINKER_FLAGS="$lf" >/dev/null &&
    ninja -C "$b" ps2run > "$b/ninja.log" 2>&1
}

build_native() {  # S B extra-cmake-args...
  local s=$1 b=$2; shift 2
  cpu_flags
  echo "== cpu flags: flavor=$CPU_FLAVOR CXXFLAGS='$CPU_CXXFLAGS' LDFLAGS='$CPU_LDFLAGS'"
  if _configure_and_build "$s" "$b" "$CPU_CXXFLAGS" "$CPU_LDFLAGS" "$@"; then
    :
  elif [ "$CPU_FLAVOR" = cpu_tuned ]; then
    echo "== cpu-tuned build failed; last lines:"; tail -15 "$b/ninja.log" 2>/dev/null || true
    echo "== falling back to a generic build"
    CPU_FLAVOR=generic-fallback
    _configure_and_build "$s" "$b" "" "" "$@" || { tail -30 "$b/ninja.log" 2>/dev/null; return 1; }
  else
    tail -30 "$b/ninja.log" 2>/dev/null; return 1
  fi
  echo "== built flavor: $CPU_FLAVOR"
  [ -n "${FLAVOR_FILE:-}" ] && echo "$CPU_FLAVOR" > "$FLAVOR_FILE"
  return 0
}

# shellcheck shell=bash
# Sourced by build.sh. CPU-tuned build option (launcher: [build] cpu_tuned, env CPU_TUNED=1).
#   cpu_flags            sets CPU_FLAVOR / CPU_CXXFLAGS / CPU_LDFLAGS from CPU_TUNED (+ CPU_MARCH, default native),
#                        once per build: build.sh calls it before the first configure so every configure gets
#                        the same flags (no full recompile when switching, no stale cached flags).
#   cpu_fallback         switch to a generic build (flavor generic-fallback)
#   cpu_cmake_args       the -DCMAKE_CXX_FLAGS / -DCMAKE_EXE_LINKER_FLAGS arguments, always passed (empty = generic)
#   port_with_fallback CFG CMD...   run CMD (port.sh); if it fails on a tuned build, fall back to generic,
#                        run CFG (re-configure) and CMD once more
#   build_native S B ... configure (cmake -S S -B B ...extra args) + ninja ps2run with those flags; if the
#                        tuned build fails (e.g. LTO/linker trouble), reconfigure generic and build again.
#   Writes the flavor actually built and this CPU's model to $FLAVOR_FILE:
#     line 1: cpu_tuned | generic | generic-fallback;  "cpu=<model name>"  (the launcher asks for a rebuild
#     when a cpu_tuned build finds another CPU model).
# PGO is intentionally not part of this.
cpu_flags() {
  [ -n "${CPU_FLAVOR:-}" ] && return 0
  CPU_FLAVOR=generic; CPU_CXXFLAGS=""; CPU_LDFLAGS=""
  if [ "${CPU_TUNED:-0}" = 1 ]; then
    CPU_FLAVOR=cpu_tuned; CPU_CXXFLAGS="-march=${CPU_MARCH:-native}"
    if command -v ld.lld >/dev/null 2>&1; then
      CPU_CXXFLAGS="$CPU_CXXFLAGS -flto=thin"; CPU_LDFLAGS="-flto=thin -fuse-ld=lld"
    else
      echo "== cpu flags: ld.lld not found, building -march only (no LTO)"
    fi
  fi
  echo "== cpu flags: flavor=$CPU_FLAVOR CXXFLAGS='$CPU_CXXFLAGS' LDFLAGS='$CPU_LDFLAGS'"
}

cpu_fallback() { CPU_FLAVOR=generic-fallback; CPU_CXXFLAGS=""; CPU_LDFLAGS=""; echo "== falling back to a generic build"; }

cpu_cmake_args() { CPU_CMAKE_ARGS=(-DCMAKE_CXX_FLAGS="$CPU_CXXFLAGS" -DCMAKE_EXE_LINKER_FLAGS="$CPU_LDFLAGS"); }

cpu_model() { sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "${LIFELINE_CPUINFO:-/proc/cpuinfo}" 2>/dev/null | head -1; }

port_with_fallback() {  # CFG CMD...
  local cfg=$1; shift
  "$@" && return 0
  [ "${CPU_FLAVOR:-}" = cpu_tuned ] || return 1
  echo "== cpu-tuned first compile failed"
  cpu_fallback; "$cfg" && "$@"
}

_configure_and_build() {  # S B extra-cmake-args...
  local s=$1 b=$2; shift 2
  cpu_cmake_args
  cmake -S "$s" -B "$b" -G Ninja "$@" "${CPU_CMAKE_ARGS[@]}" >/dev/null &&
    ninja -C "$b" ps2run > "$b/ninja.log" 2>&1
}

build_native() {  # S B extra-cmake-args...
  local s=$1 b=$2; shift 2
  cpu_flags
  if _configure_and_build "$s" "$b" "$@"; then
    :
  elif [ "$CPU_FLAVOR" = cpu_tuned ]; then
    echo "== cpu-tuned build failed; last lines:"; tail -15 "$b/ninja.log" 2>/dev/null || true
    cpu_fallback
    _configure_and_build "$s" "$b" "$@" || { tail -30 "$b/ninja.log" 2>/dev/null; return 1; }
  else
    tail -30 "$b/ninja.log" 2>/dev/null; return 1
  fi
  echo "== built flavor: $CPU_FLAVOR"
  if [ -n "${FLAVOR_FILE:-}" ]; then printf '%s\ncpu=%s\n' "$CPU_FLAVOR" "$(cpu_model)" > "$FLAVOR_FILE.tmp" && mv -f "$FLAVOR_FILE.tmp" "$FLAVOR_FILE"; fi
  return 0
}

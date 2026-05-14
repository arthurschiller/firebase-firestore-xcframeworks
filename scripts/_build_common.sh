#!/usr/bin/env bash
# Shared build setup for scripts/build-*.sh — source this after `set -euo pipefail`.
#
# Sets:
#   - PARALLEL_JOBS — clamp for `cmake --build ... -j$PARALLEL_JOBS`. Default 4.
#     gRPC's xds_* translation units hit 1-2 GB clang per file; bare -j OOMs
#     even a 24 GB machine. Override per-invocation with PARALLEL_JOBS=N env.
#   - CMAKE_CCACHE_ARGS — expand into cmake configure as launcher args.
#     Empty array if ccache not installed.
#   - CC, CXX, CCACHE_* env vars if ccache present.

PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

CMAKE_CCACHE_ARGS=()
if command -v ccache >/dev/null 2>&1; then
  export CC="ccache clang"
  export CXX="ccache clang++"
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
  export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-pch_defines,time_macros,include_file_mtime,include_file_ctime}"
  export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
  CMAKE_CCACHE_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
  _CCACHE_STATUS="ccache active ($CCACHE_DIR, max $CCACHE_MAXSIZE)"
else
  echo "warning: ccache not installed — incremental rebuilds will be slow (brew install ccache)"
  _CCACHE_STATUS="ccache off"
fi

echo "$(basename "$0"): -j$PARALLEL_JOBS, $_CCACHE_STATUS"

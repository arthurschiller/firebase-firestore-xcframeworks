# Build conventions for scripts/

## Parallelism — never use bare `-j`

`make -j` / `cmake --build ... -j` without a number means **unlimited
parallelism**. On Apple Silicon (12+ cores) this spawns one clang process per
core. gRPC's `xds_*` and envoy proto translation units use 1–2 GB RAM each
at peak — 12 of them in parallel exhausts even a 24 GB Mac and pushes the
system into many GB of swap (machine becomes unresponsive, thermal throttle).

**Rule:** every `cmake --build`, `make`, or `ninja` invocation in `scripts/`
must use `-j$PARALLEL_JOBS`, never bare `-j`. `PARALLEL_JOBS` defaults to 4
via `scripts/_build_common.sh`. Override per-invocation with
`PARALLEL_JOBS=N ./scripts/build-X.sh` if you have headroom.

## ccache

`scripts/_build_common.sh` detects ccache and wires it via
`-DCMAKE_C_COMPILER_LAUNCHER=ccache`. First run is a cache miss everywhere
(~45–60 min for gRPC); subsequent runs hit cache and finish in minutes.
`brew install ccache` if missing — warned but not required.

`CCACHE_COMPILERCHECK=content` is set so Xcode / Command Line Tools updates
don't invalidate the whole cache (mtime would). Relevant for visionOS beta
churn.

## Adding a new build-*.sh

After `set -euo pipefail`, source `_build_common.sh`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"
```

Then use `-j$PARALLEL_JOBS` in every build invocation and
`"${CMAKE_CCACHE_ARGS[@]}"` in every `cmake` configure line.

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

## Phase 3 (gRPC) — known ABI gaps vs Google's iOS slice

Our `grpc.framework` is ~17 MB vs Google's ~33 MB. Symbol diff at the
visionOS device slice:

- 11 missing public `_grpc_*` symbols: `grpc_absl_log*` (3, abseil log
  wrapper), `grpc_gcp_*` (6, ALTS handshake), `grpc_lb_v1_*` (2, deprecated
  LB v1). ALTS and LB v1 are not used by Firestore clients; `grpc_absl_log*`
  could be referenced broadly — flag if Phase 4 link fails on it.
- ~5000 missing absl `T` symbols: ~3500 are `container_internal` template
  instantiations parameterised on `grpc_core::*` types (gRPC's own internal
  use; Firestore instantiates its own with `FirestoreFoo` types instead).
  Not a Firestore link risk.

Likely cause of the size gap: `-fno-rtti -fno-exceptions -fvisibility=hidden`
in our CXX flags vs Google's CocoaPods build which doesn't set these. Means
some out-of-line template code is inlined-away in our build. Cosmetic for
Firestore's link path.

If Phase 4 link fails on a specific `_grpc_*` or absl symbol, dig in then —
don't pre-emptively beef up the build.

## Adding a new build-*.sh

After `set -euo pipefail`, source `_build_common.sh`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"
```

Then use `-j$PARALLEL_JOBS` in every build invocation and
`"${CMAKE_CCACHE_ARGS[@]}"` in every `cmake` configure line.

## Releasing — always zip with `-y`

XCFramework release zips MUST be created with `zip -y` (preserve symlinks):

```bash
zip -qry foo.xcframework.zip foo.xcframework
```

Without `-y`, zip follows macOS-style framework symlinks
(`Versions/Current → A`, top-level `<binary> → Versions/Current/<binary>`,
etc.) and stores duplicate files instead of the symlinks. Catalyst codesign
then fails with "Couldn't resolve framework symlink for Versions/Current
... NSPOSIXErrorDomain Code=22 Invalid argument". iOS/visionOS slices use
flat structure so they look fine in casual testing — the bug only surfaces
on macOS / Mac Catalyst.

# Build conventions for scripts/

## Upgrading to a new Firebase version

When Firebase ships a new release (e.g. `11.16.0`) and you want a matching
visionOS overlay, run:

```bash
./scripts/upgrade.sh 11.16.0
```

`scripts/upgrade.sh` is the one-command entrypoint. It chains:

1. `prepare-sources.sh <version>` — clones `firebase-ios-sdk` + deps
   (`abseil-cpp`, `grpc`, `leveldb`) at the right tags, downloads + extracts
   Google's `Firebase.zip`, rsyncs the vendored `Firestore/`, `FirebaseCore/`,
   `CoreOnly/`, `FirebaseFirestoreInternal/` trees from upstream, and
   re-applies our two source patches via `apply-patches.sh`.
2. `build-absl.sh`, `build-openssl_grpc.sh`, `build-grpc.sh`,
   `normalize-openssl-grpc-modulemap.sh`, `build-leveldb.sh`,
   `build-firestore-internal.sh` — produce visionOS slices and merge with
   Google's untouched iOS/macOS/Catalyst/tvOS slices.
3. `build-release.sh <version>` — `zip -y` each xcframework, compute
   checksums, generate a URL-mode `Package.swift` pointing at the
   to-be-uploaded release assets.

`upgrade.sh` does NOT auto-commit, tag, or push. It prints the exact
`git` and `gh release create` commands at the end for you to review and
run by hand.

### Notes on the source-version detection

`prepare-sources.sh` reads each xcframework's `CFBundleShortVersionString`
out of the extracted `Firebase.zip` and uses it to check out the matching
source tag (`abseil-cpp/20240722.0`, `grpc/v1.69.0`, etc.). Firebase
occasionally bumps a binary's bundle version without creating a matching
source tag (we saw this with leveldb `1.22.6` → no tag, falls back to
`1.22.5`). When that happens `prepare-sources.sh` prints a `WARN` and
keeps the previously checked-out source — usually fine, but verify the
build output matches Google's binary slice if you suspect drift.

### Patches re-applied on every upgrade

- `abseil-cpp/absl/base/options.h` — force `ABSL_OPTION_USE_STD_*=0` to
  match gRPC's bundled-absl ABI (applied to both the standalone tree
  and `grpc/third_party/abseil-cpp/`). Without this, our visionOS link
  fails with mismatched mangled names for any absl API that takes a
  `string_view`.
- `Firestore/Swift/Source/**/*.swift` — rewrite `import
  FirebaseFirestoreInternalWrapper` → `_FirebaseFirestoreInternalWrapper`
  and `FirebaseFirestore.<Type>` → `FirebaseFirestorePrebuilt.<Type>`.
  These compensate for the SPM-target renames we needed to avoid
  collisions with upstream `firebase-ios-sdk`'s same-named targets in
  the consumer dep graph.


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

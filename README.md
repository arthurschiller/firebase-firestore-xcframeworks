# firebase-firestore-xcframeworks

SPM overlay that provides **`FirebaseFirestore` with visionOS support**, built
as a binary `.xcframework` so consumers don't pay the 10-minute source-compile
cost (or any source-compile cost) on visionOS.

Google ships visionOS slices for every Firebase product *except* Firestore,
because Firestore depends on `google/grpc-binary` and `google/abseil-cpp-binary`
which lack `xros` slices. The official Firebase workaround is to set
`FIREBASE_SOURCE_FIRESTORE=1` and pay a multi-minute C++ source compile on
every clean build of every visionOS target. This repo eliminates that.

## What it ships

- **`FirebaseFirestoreInternal.xcframework`** — Google's six untouched iOS /
  macOS / Catalyst / tvOS slices merged with our two visionOS slices
  (`xros-arm64`, `xros-arm64-simulator`) built from Firebase 11.15.0's
  Firestore C++ source.
- **5 native dependencies** with visionOS slices added the same way:
  `absl.xcframework`, `openssl_grpc.xcframework`, `grpc.xcframework`,
  `grpcpp.xcframework`, `leveldb.xcframework`.

iOS / macOS / Catalyst / tvOS slices are **Google's exact bytes** — ABI
guaranteed identical to the official Firebase release, so existing iOS link
partners (e.g. ARCore Geospatial) continue to work unchanged.

## Integration (Swift Package Manager)

This package overlays only Firestore. Continue using upstream `firebase-ios-sdk`
for `FirebaseAuth`, `FirebaseRemoteConfig`, `FirebaseStorage`, etc. — those
source-compile fine on visionOS already (they have no native binary deps
that lack visionOS slices).

In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "11.15.0"),
    .package(url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks.git", exact: "11.15.6"),
],

targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "FirebaseAuth",            package: "firebase-ios-sdk"),
            .product(name: "FirebaseRemoteConfig",    package: "firebase-ios-sdk"),
            .product(name: "FirebaseStorage",         package: "firebase-ios-sdk"),
            .product(name: "FirebaseFirestorePrebuilt", package: "firebase-firestore-xcframeworks"),
        ]
    ),
]
```

In your source code, use `import FirebaseFirestorePrebuilt` wherever the
upstream docs say `import FirebaseFirestore`. The API surface is byte-identical
to upstream — only the module name changed (necessary to avoid SPM
target-name collisions when both packages are in the same resolved graph).

Pin both packages to the same Firebase version. Bumps move them in lockstep.

After integration:

- iOS / macOS / Catalyst / tvOS builds use Google's untouched binaries.
- visionOS builds use our binary slices — no source compile, no env-var dance,
  no `Package.resolved` swap script, no Xcode Cloud workaround.

## Versioning

Release tags map to the underlying Firebase iOS SDK version, with patch-level
suffixes for fixes to the overlay itself:

| Tag         | Firebase iOS SDK | Notes                                                                 |
|-------------|------------------|-----------------------------------------------------------------------|
| `11.15.6`   | 11.15.0          | **Current.** Use this. (See changelog below if you care.)             |
| `11.15.5`   | 11.15.0          | absl ABI fix; Catalyst zip was broken — superseded by 11.15.6.        |
| `11.15.4`   | 11.15.0          | grpc/absl link fixes; Catalyst zip was broken — superseded by 11.15.6.|
| `11.15.0–3` | 11.15.0          | Early iterations of the overlay layout. Don't use.                    |

Patch-level fixes within a Firebase version came from this overlay's own ABI /
packaging work, not from upstream — the underlying Firestore C++ source is the
same byte-identical Firebase 11.15.0.

## Upgrading to a new Firebase version

```bash
./scripts/upgrade.sh 11.16.0
```

The orchestrator does everything end-to-end:

1. Clones `firebase-ios-sdk` at the requested tag, downloads + extracts
   Google's `Firebase.zip`, detects dep versions (`abseil-cpp`, `grpc`,
   `leveldb`) from each xcframework's bundle metadata, clones each source
   repo at the matching tag, and re-applies the maintenance patches we keep
   on top of upstream.
2. Builds visionOS slices for all six xcframeworks and merges them with
   Google's untouched iOS / macOS / Catalyst / tvOS slices.
3. Zips with `-y` (preserves macOS framework symlinks — required for
   Catalyst codesign), computes SHA-256 checksums, generates a URL-mode
   `Package.swift` ready to commit.

After it finishes, the script prints the exact `git tag` / `git push` /
`gh release create` commands for you to review and run by hand — it does NOT
auto-publish. Review the `Package.swift` diff first.

See [CLAUDE.md](CLAUDE.md) for build conventions, the patches we apply, and
known quirks (e.g. Firebase sometimes bumps a binary's bundle version without
a matching source-repo tag).

## Building individual pieces

If you need to rebuild a single xcframework after a tweak (rather than running
the full upgrade flow):

```bash
scripts/build-absl.sh
scripts/build-openssl_grpc.sh
scripts/build-grpc.sh                              # builds grpc + grpcpp
scripts/normalize-openssl-grpc-modulemap.sh        # post-build modulemap rename
scripts/build-leveldb.sh
scripts/build-firestore-internal.sh

scripts/build-release.sh <tag>                     # zip + checksums + URL-mode Package.swift
```

Requires Xcode 26.5+ (visionOS SDK), `cmake`, `ninja`, optionally `ccache`.

`scripts/_build_common.sh` caps `make -j` to 4 by default (override with
`PARALLEL_JOBS=N`). Building bare `-j` against gRPC on an Apple Silicon Mac
will spawn enough parallel `clang` processes to OOM and thermal-throttle the
machine — don't.

## Caveats

- `build/artifacts/` is gitignored. A fresh clone can't `swift package
  resolve` without running the build scripts first OR consuming a published
  release (where `Package.swift` uses `.binaryTarget(url:..., checksum:...)`).
- Release assets are produced from the maintainer's local machine, not a
  reproducible CI run. A `workflow_dispatch` GitHub Actions wrapper around
  `scripts/upgrade.sh` is feasible but not yet in the repo.
- visionOS simulator slices ship `arm64` only. Building consumers for
  `generic/platform=visionOS Simulator` (which requests `arm64 + x86_64`)
  will fail link on x86_64; use a specific simulator destination
  (`platform=visionOS Simulator,id=...`) on Apple Silicon.

## License

Apache 2.0 — see [LICENSE](LICENSE). Redistributes Firebase / gRPC / Abseil /
BoringSSL / LevelDB / nanopb under their original Apache 2.0 / BSD licenses
(notices preserved in each xcframework's source tree).

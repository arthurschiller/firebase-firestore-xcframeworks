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

This package overlays only `FirebaseFirestore`. Continue using upstream
`firebase-ios-sdk` for `FirebaseAuth`, `FirebaseRemoteConfig`, `FirebaseStorage`,
etc. — those source-compile fine on visionOS already (they have no native
binary deps that lack visionOS slices).

In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "11.15.0"),
    .package(url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks.git", exact: "11.15.0"),
],

targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "FirebaseAuth",      package: "firebase-ios-sdk"),
            .product(name: "FirebaseRemoteConfig", package: "firebase-ios-sdk"),
            .product(name: "FirebaseStorage",   package: "firebase-ios-sdk"),
            .product(name: "FirebaseFirestore", package: "firebase-firestore-xcframeworks"),
        ]
    ),
]
```

Pin both packages to the same Firebase version. Bumps move them in lockstep.

After integration:

- iOS / macOS / Catalyst / tvOS builds use Google's untouched binaries.
- visionOS builds use our binary slices — no source compile, no env-var dance,
  no `Package.resolved` swap script, no Xcode Cloud workaround.

## Versioning

Release tags map 1:1 to the underlying Firebase iOS SDK version:

| Tag        | Firebase iOS SDK |
|------------|------------------|
| `11.15.0`  | 11.15.0          |

## Building / releasing locally

Requires Xcode 26.5 (visionOS SDK 26.5), `cmake`, `ninja`, optionally `ccache`.

```bash
scripts/build-absl.sh
scripts/build-openssl_grpc.sh
scripts/build-leveldb.sh
scripts/build-nanopb.sh
scripts/build-grpc.sh
scripts/normalize-openssl-grpc-modulemap.sh
scripts/build-firestore-internal.sh

# Produce zips + URL-mode Package.swift for a release
scripts/build-release.sh 11.15.0
```

`scripts/_build_common.sh` caps `make -j` to 4 by default (override with
`PARALLEL_JOBS=N`). Building bare `-j` against gRPC on an Apple Silicon Mac
will spawn enough parallel `clang` processes to OOM and thermal-throttle the
machine — don't.

## Caveats

- `build/artifacts/` is gitignored. A fresh clone can't `swift package
  resolve` without running the build scripts first OR consuming a published
  release (where `Package.swift` uses `.binaryTarget(url:..., checksum:...)`).
- Tag `11.15.0`'s release assets are produced from the maintainer's local
  machine, not a reproducible CI run. A `workflow_dispatch` CI workflow for
  reproducibility is on the roadmap.
- visionOS simulator slices ship `arm64` only. Building consumers for
  `generic/platform=visionOS Simulator` (which requests `arm64 + x86_64`)
  will fail link on x86_64; use a specific simulator destination
  (`platform=visionOS Simulator,id=...`) on Apple Silicon.

## License

Apache 2.0 — see [LICENSE](LICENSE). Redistributes Firebase / gRPC / Abseil /
BoringSSL / LevelDB / nanopb under their original Apache 2.0 / BSD licenses
(notices preserved in each xcframework's source tree).

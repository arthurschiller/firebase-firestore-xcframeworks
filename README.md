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

Both packages must reference the **same underlying Firebase version**. The
overlay's tag scheme is `<firebase_version>.<patch>` — e.g. `11.15.6` means
"Firebase 11.15.0, overlay patch 6". So `firebase-ios-sdk @ 11.15.0` pairs
with `firebase-firestore-xcframeworks @ 11.15.<latest>`.

If you need a Firebase version other than the ones listed in [Versioning](#versioning)
below, see [Need a different Firebase version?](#need-a-different-firebase-version) —
this repo doesn't auto-publish for every Firebase release, so a different
version may need a one-time build by you or a request via an issue.

After integration:

- iOS / macOS / Catalyst / tvOS builds use Google's untouched binaries.
- visionOS builds use our binary slices — no source compile, no env-var dance,
  no `Package.resolved` swap script, no Xcode Cloud workaround.

## Versioning

Release tags map to the underlying Firebase iOS SDK version, with patch-level
suffixes for fixes to the overlay itself.

### Published releases

| Tag         | Firebase iOS SDK | Notes                                                                 |
|-------------|------------------|-----------------------------------------------------------------------|
| `11.15.6`   | 11.15.0          | **Current.** Use this if you're on Firebase 11.15.x.                  |
| `11.15.5`   | 11.15.0          | absl ABI fix; Catalyst zip was broken — superseded by 11.15.6.        |
| `11.15.4`   | 11.15.0          | grpc/absl link fixes; Catalyst zip was broken — superseded by 11.15.6.|
| `11.15.0–3` | 11.15.0          | Early iterations of the overlay layout. Don't use.                    |

Patch-level fixes within a Firebase version came from this overlay's own ABI /
packaging work, not from upstream — the Firestore C++ source is byte-identical
to upstream Firebase 11.15.0.

### Need a different Firebase version?

If you need a Firebase release that isn't published as a tag here, you have
four options:

1. **Open an issue** asking for a specific Firebase version — that's the
   lowest-friction path, and it gives other users on the same version
   somewhere to point.
2. **Fork + run the GitHub Actions workflow** — `gh workflow run
   release-overlay.yml -f firebase_version=11.16.0 -f dry_run=false` on
   your fork. Builds on a fresh `macos-15` runner (~50 min cold) and
   produces a draft release with the six xcframework zips attached.
   See [CLAUDE.md](CLAUDE.md) for details and dry-run testing.
3. **Fork + run `./scripts/upgrade.sh <firebase_version>` locally** (see
   the next section). Takes ~30–90 min on a recent Apple Silicon Mac with
   Xcode 26+ installed. The script handles source prep, builds, zips, and
   prints the exact `gh release create` commands at the end.
4. **Use it as a local-path SPM dep** — for development only. Clone this
   repo, run `scripts/upgrade.sh`, then point your consumer `Package.swift`
   at `path: "../path/to/firebase-firestore-xcframeworks"` instead of a
   tagged URL.

Tags appear when the maintainer (or a contributor) triggers the upgrade
workflow and publishes the resulting draft release. Firebase point
releases are tracked manually — no auto-publish on upstream tag.

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
- Release assets can be produced either from the maintainer's local
  machine via `scripts/upgrade.sh` or from a fresh `macos-15` runner via
  the `release-overlay.yml` GitHub Actions workflow. The workflow is the
  recommended path — it's reproducible and doesn't tie up a local Mac.
- visionOS simulator slices ship `arm64` only. Building consumers for
  `generic/platform=visionOS Simulator` (which requests `arm64 + x86_64`)
  will fail link on x86_64; use a specific simulator destination
  (`platform=visionOS Simulator,id=...`) on Apple Silicon.

## License

Apache 2.0 — see [LICENSE](LICENSE). Redistributes Firebase / gRPC / Abseil /
BoringSSL / LevelDB / nanopb under their original Apache 2.0 / BSD licenses
(notices preserved in each xcframework's source tree).

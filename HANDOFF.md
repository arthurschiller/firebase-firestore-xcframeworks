# Session handoff — firebase-firestore-xcframeworks

Last updated: 2026-05-14. Read this end-to-end before doing anything.

## What this repo is

SPM overlay for `firebase-ios-sdk` 11.15.0 that lets the Scenery iOS/macOS/visionOS app
consume Firebase with a **single `Package.resolved` across all platforms** — no env-var dance,
no source-build spinner on visionOS, no swap script.

Goal originally specified in `prompt.md` — read that file too. It's the source of truth for
scope, constraints, and success criteria.

Consumer is **Scenery** at `/Users/arthurschiller/Repositories/GitHub/Amped Labs/Apple Apps/Scenery`.
**Read-only** until in-repo test app is verified green. Then Phase 7 = 5-line cleanup PR for
Arthur to apply.

## Locked decisions

These are not up for re-debate without explicit user input:

- **Firebase 11.15.0** target. ARCore Geospatial's `Package.swift` pins
  `.upToNextMajor(from: "11.0.0")` — hard cap at 11.x, will lift only when ARCore allows.
- **Fork-of-upstream Package.swift** strategy (not hand-written minimal). Tracks upstream
  product graph automatically on bump.
- **Vendor Firestore source** into this repo (path A — chosen during Phase 5 planning).
  ~12 MB added to git, but every clone reproduces the build. No download-at-resolve scripts.
- `TestConsumer/` folder inside this repo (not separate repo).
- `workflow_dispatch` manual trigger for CI. No cron auto-publish.
- Unsigned XCFrameworks.
- GH-hosted `macos-15` runner for CI.
- Scenery cleanup is final step (Phase 7), Arthur applies the patch.
- **iOS/macOS/Catalyst/tvOS slices must remain Google's exact bytes** (ARCore Geospatial
  on iOS links against same Google gRPC binary; rebuilding iOS risks ABI drift, breaks ARCore).
  We **only add** visionOS slices via `xcodebuild -create-xcframework` merge.

## Status by phase

| Phase | Status | Notes |
|---|---|---|
| 0. Scaffolding | ✅ | `c2994de`, `f61265d` |
| 1. abseil | ✅ | `03d51c6` — 8 slices, runtime test passes on all platforms incl. visionOS sim |
| 2. BoringSSL (openssl_grpc) | ✅ | `ff74a63` — 8 slices, **byte-identical GRPC_ symbols** vs Google's iOS (3446/3446) |
| 3. gRPC (grpc + grpcpp) | ✅ | `1b7b7ad` — 8 slices, partial ABI gaps documented in CLAUDE.md (most likely Firestore-irrelevant) |
| 4 part 1. leveldb + nanopb | ✅ | `484cc84` — both built and merged, 8 + 10 slices |
| 4 part 2. FirebaseFirestoreInternal binary | DEFERRED | See "Phase 4 part 2 backlog" below |
| 5. Package.swift + TestGround | ✅ | Minimal Package.swift exposes `FirebaseFirestore` + `FirebaseCore`. Source-compile Firestore C++ against our 6 binaryTargets (absl/openssl_grpc/grpc/grpcpp/leveldb + nanopb-as-source). TestGround Xcode project builds green on visionOS Sim / iOS Sim / macOS / Mac Catalyst. |
| 6. CI port | **NEXT** | Wrap proven local scripts in `.github/workflows/build.yml` |
| 7. Scenery cutover patch | pending | 5-line patch for Arthur to apply, only after Phase 5 green |

## Phase 5 — what shipped (vs. what HANDOFF originally planned)

Original plan said "fork upstream `Package.swift` verbatim, swap 6 binaryTargets". Reality: vendoring the full upstream SDK is ~70 MB and reaches paths we don't care about. We pivoted to a **minimal hand-written Package.swift** exposing only `FirebaseFirestore` + `FirebaseCore` and vendored exactly the source dirs those need (`Firestore/`, `FirebaseCore/`, `FirebaseSharedSwift/`, `FirebaseAppCheck/Interop/`, `FirebaseAuth/Interop/`, `CoreOnly/`, `SwiftPM-PlatformExclude/FirebaseFirestoreWrap/`). ~13.5 MB vendored, none of it from products the consumer doesn't use.

### Hacks introduced — flagged for review

1. **`scripts/normalize-openssl-grpc-modulemap.sh`** — rewrites every slice of
   `build/artifacts/openssl_grpc/openssl_grpc.xcframework/*/openssl_grpc.framework/Modules/module.modulemap`
   to use `framework module openssl_grpc` (was `BoringSSL-GRPC`). Clang rejects
   hyphens in module identifiers, so without this rename a source target listing
   `openssl_grpc` as a dependency dies at modulemap parse. Binary symbols are
   untouched — module name is pure compile-time metadata. **Must be re-run** if
   the openssl_grpc.xcframework is ever rebuilt or its iOS slices refreshed
   from Google's release zip (Google's iOS modulemap also says
   `BoringSSL-GRPC`).

2. **`FirebaseFirestoreInternalWrapper` directly depends on `openssl_grpc`** —
   the original HANDOFF instruction "do NOT add direct source-target dependency
   on openssl_grpc (modulemap hyphen issue)" is **invalidated by Hack #1**. With
   the modulemap normalized, openssl_grpc is depended on directly; this is
   necessary so the linker sees `-framework openssl_grpc` and resolves
   `_GRPC_ASN1_STRING_to_UTF8` and other BoringSSL symbols that grpc's binary
   references.

3. **nanopb is source-compiled via `firebase/nanopb` SPM package, not our
   binaryTarget** — our `nanopb.xcframework` builds successfully, but SPM
   doesn't expose a binaryTarget framework's `Headers/` directory as a flat
   `HEADER_SEARCH_PATHS` entry, so Firestore C++'s `#include <pb.h>` can't
   find headers without modules. nanopb is tiny (~6 files / ~50 KB), so
   source-compile cost is negligible on visionOS. The `nanopb.xcframework`
   artifact stays available for any future binary path (Phase 4 part 2).

4. **`scripts/build-grpc.sh` bundle list missing `libgpr.a` + `libupb_*.a`** —
   Phase 3 documented "11 missing public `_grpc_*` symbols and ~5000 absl
   template instantiations". Reality was worse: the original `libtool` bundle
   step omitted `libgpr.a` (grpc's portable runtime — gpr_malloc/gpr_mu_init/
   etc.) and the upb finder pattern was wrong (looked in
   `third_party/upb/` but CMake emits libs at the build-dir root). Fixed in
   place; visionOS slice rebundled from cached CMake output. iOS/macOS/
   Catalyst slices remain Google's bytes (unaffected — they had these symbols
   all along).

5. **`build/artifacts/` paths are local-only** — `Package.swift` uses
   `path: "build/artifacts/.../<name>.xcframework"` for the 5 remaining
   binaryTargets. `build/` is gitignored, so this repo is NOT yet
   consumer-shareable. Phase 6 will replace these with
   `.binaryTarget(url:..., checksum:...)` pointing at GH Release assets.

6. **Generic visionOS Simulator destination doesn't work** — `xcodebuild
   -destination 'generic/platform=visionOS Simulator'` requests both arm64
   and x86_64 sim slices; our xcframeworks ship arm64 only. For testing,
   use a specific sim destination (e.g.
   `platform=visionOS Simulator,id=<arm64 sim UDID>`). For shipping to
   consumers we may need to add x86_64 sim slices later (Rosetta visionOS
   sim is rare in practice).

## Repo layout (committed)

```
firebase-firestore-xcframeworks/
├── .claude/
│   └── settings.local.json    # gitignored — has Bash(rm:*) permission
├── .gitignore
├── CLAUDE.md                  # build conventions (-j4, ccache) — READ FIRST
├── HANDOFF.md                 # this file
├── Package.swift              # CURRENT: stub. Phase 5 replaces with fork of upstream.
├── prompt.md                  # original spec — READ
├── TestConsumer/              # Phase 1 abseil runtime test, all platforms green
│   ├── Package.swift
│   ├── Sources/
│   │   ├── AbseilCxxShim/     # C++ shim using absl::StrCat
│   │   └── AbseilSmokeTest/   # Swift target
│   └── Tests/AbseilSmokeTestTests/    # XCTest, 3 passing tests
└── scripts/
    ├── _build_common.sh       # shared: PARALLEL_JOBS=4, ccache wiring — source from each build script
    ├── build-absl.sh          # CMake + libtool + xcodebuild create-xcframework
    ├── build-openssl_grpc.sh  # ditto + ABI-parity check vs Google iOS
    ├── build-grpc.sh          # ditto + bundles 83 archives (abseil/upb/re2/zlib/address_sorting) into grpc binary
    ├── build-leveldb.sh
    └── build-nanopb.sh
```

## Repo state (gitignored — regenerable, NOT committed)

```
build/
├── downloads/
│   ├── Firebase.zip            # Firebase 11.15.0 release asset (~369 MB outer)
│   └── Firebase-extracted/     # Google's 30+ xcframeworks, untouched
├── sources/                    # Source clones at exact pins matching Firebase 11.15.0
│   ├── abseil-cpp/             # @ 20240722.0
│   ├── grpc/                   # @ v1.69.0 (closest tag — grpc-binary 1.69.1 has no upstream tag)
│   │   └── third_party/boringssl-with-bazel/   # @ b8b3e6e1166...
│   ├── leveldb/                # firebase fork @ 1.22.5
│   ├── nanopb/                 # firebase fork @ 2.30910.0
│   └── firebase-ios-sdk/       # @ 11.15.0 — for Firestore source and Package.swift reference
└── artifacts/
    ├── absl/absl.xcframework                       # 8 slices, ours has xros + xros-sim
    ├── openssl_grpc/openssl_grpc.xcframework       # 8 slices, byte-identical ABI to Google
    ├── grpc/grpc.xcframework                       # 8 slices, ~17 MB visionOS slice
    ├── grpcpp/grpcpp.xcframework                   # 8 slices, ~900 KB visionOS slice
    ├── leveldb/leveldb.xcframework                 # 8 slices, 394 KB visionOS slice
    ├── nanopb/nanopb.xcframework                   # 10 slices (incl. watchOS), 32 KB visionOS slice
    ├── *-build-xros/, *-build-xrsimulator/         # CMake build dirs (per-slice, ccache populated)
    └── *-slices/                                   # per-slice framework dirs before merge
```

**If you rebuild from scratch**, run each `scripts/build-*.sh` in order:
abseil → openssl_grpc → leveldb → nanopb → grpc. Each takes 5–90 min on first run, much
less on subsequent runs (ccache).

## Phase 5 plan — Step by step

Goal: SPM overlay Package.swift + in-repo test app that imports FirebaseFirestore,
builds + runs on visionOS simulator. Once green, Phase 5 is verified.

### Step 1: Vendor Firestore source

Copy `build/sources/firebase-ios-sdk/Firestore/` into the repo root at `Firestore/`.
~12 MB checked into git. Exclude tests/examples (already excluded by upstream Package.swift
`exclude` lists — replicate those).

Also vendor any other source paths the source-compile path needs from upstream:
- `Firestore/Source/` (Objective-C wrappers)
- `Firestore/Protos/` (proto generated code — already pre-generated, no protoc needed)
- `Firestore/core/` (C++ core)
- `Firestore/third_party/nlohmann_json/` (vendored JSON lib)

Reference: upstream `Package.swift` lines 1504-1610 for the `FirebaseFirestoreInternalWrapper`
target's exact source/exclude lists.

### Step 2: Fork Package.swift

Copy `build/sources/firebase-ios-sdk/Package.swift` to `Package.swift` (replaces current stub).
Then make these targeted modifications:

**Add visionOS platform** to the top-level `platforms:` list:
```swift
platforms: [.iOS(.v12), .macCatalyst(.v13), .macOS(.v10_15), .tvOS(.v13),
            .visionOS(.v1), .watchOS(.v7)]
```

**Remove** these `Package.Dependency` entries from the top-level `dependencies:` array:
- `.package(url: "https://github.com/firebase/nanopb.git", ...)`
- `.package(url: "https://github.com/firebase/leveldb.git", ...)`
- `abseilDependency()` call
- `grpcDependency()` call

**Delete the functions** `abseilDependency()` and `grpcDependency()`.

**Replace every `.product(name: "abseil", package: "abseil-cpp-binary")`** with `"absl"`.
Same for `grpc-cpp`, `nanopb`, `leveldb` → use direct target names.

**Add 6 `.binaryTarget` declarations** to the targets array, pointing at our local paths:
```swift
.binaryTarget(name: "absl",         path: "build/artifacts/absl/absl.xcframework"),
.binaryTarget(name: "openssl_grpc", path: "build/artifacts/openssl_grpc/openssl_grpc.xcframework"),
.binaryTarget(name: "grpc",         path: "build/artifacts/grpc/grpc.xcframework"),
.binaryTarget(name: "grpcpp",       path: "build/artifacts/grpcpp/grpcpp.xcframework"),
.binaryTarget(name: "leveldb",      path: "build/artifacts/leveldb/leveldb.xcframework"),
.binaryTarget(name: "nanopb",       path: "build/artifacts/nanopb/nanopb.xcframework"),
```
**CRITICAL:** `build/artifacts/` is gitignored. For consumer use later (Phase 6 CI), these
will be `.binaryTarget(url:..., checksum:...)` pointing at GH Release zips. For Phase 5
local test, `path:` is fine.

**`firestoreTargets()` function:** force the source-compile branch always (drop the
`FIREBASE_SOURCE_FIRESTORE` env check — always return the source-compile path). The
`FirebaseFirestoreInternalWrapper` target's `path:` changes from `Firestore` (relative to
firebase-ios-sdk root) to `Firestore` (relative to OUR repo root — which has our vendored
copy). Dependencies stay the same logically but reference our `absl`, `grpcpp`, `nanopb`,
`leveldb` binaryTargets instead of upstream package products.

**`firestoreWrapperTarget()` function:** add `.visionOS` to the condition platforms list
so it links FirebaseFirestore on visionOS too.

### Step 3: In-repo test app

Add a Swift target to `TestConsumer/Package.swift` that imports `FirebaseFirestore` and
does a trivial instantiation (`Firestore.firestore()` — doesn't need real backend, just
proves linking + module resolution).

Or: create a separate `IntegrationTest/` SPM package using `.package(path: "..")` to
consume our overlay. Cleaner separation.

### Step 4: Verify

```
xcodebuild -scheme <TestSchemeName> -destination 'generic/platform=visionOS Simulator' build
xcodebuild -scheme <TestSchemeName> -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.5' test  # if XCTest added
```

Also build for iOS sim, macOS, Mac Catalyst — verify these still use Google's binary path
for the 4 deps (slices we passed through untouched).

### Step 5: Commit

Per "commit at verified milestones" rule (see memory file `feedback_commit_at_verified_milestones.md`),
commit Phase 5 only after the build + ideally a runtime test passes.

## Phase 4 part 2 backlog (binary Firestore C++)

The source-compile path used in Phase 5 has a ~2–3 min C++ compile penalty on every clean
build. For a binary path, we'd need to:

1. Use Firebase's superbuild CMake (which downloads/builds all deps via ExternalProject_Add
   — wasteful since we have them already) **OR** craft a standalone CMake that builds
   `firestore_core` against our pre-built deps.
2. Generate Firestore's proto code (pre-generated in source tree, but needs protoc if
   regenerating — already-generated nanopb is in `Firestore/Protos/nanopb/`).
3. Build for `xros-arm64` + `xros-arm64-simulator`.
4. Merge with Google's existing `FirebaseFirestoreInternal.xcframework`.

Estimated 4–8 hours of iteration. Defer until Phase 5 confirms the source-compile path
works in production.

## Critical gotchas

### Build parallelism — never bare `-j`
`make -j` with no number = unlimited. gRPC's xds_* / envoy proto translation units use
1–2 GB clang per file; on a 24 GB Mac with 12 cores this OOMs and pushes the system into
many GB of swap (Arthur's M4 Pro froze during Phase 3 first attempt).

**Rule:** every `cmake --build`, `make`, `ninja` in `scripts/` must use `-j$PARALLEL_JOBS`.
See `CLAUDE.md` and `scripts/_build_common.sh`.

### `openssl_grpc` modulemap has hyphen
`framework module BoringSSL-GRPC` — Clang's modulemap parser rejects hyphens in module
names. Production consumers never compile a source target that directly depends on
`openssl_grpc`, so it's never reached. Phase 5 / future code: do NOT add a direct
dependency from any source target on `openssl_grpc`. It's transitive-only (consumed by
grpc/grpcpp/Firestore C++, which are themselves binaryTargets — no source code touches
its modulemap).

### gRPC ABI gaps vs Google's iOS slice
Documented in `CLAUDE.md`. 11 missing public `_grpc_*` symbols (ALTS / LB v1 / abseil log
wrappers — likely Firestore-irrelevant) and ~5000 missing absl template instantiations
(parameterised on gRPC's own types — Firestore brings its own with `FirestoreFoo` types).
**Don't pre-emptively fix.** If Phase 5 link fails on a specific named symbol, fix at
that point.

### iOS slices must be Google's exact bytes
ARCore Geospatial on iOS links against Google's iOS gRPC binary. Rebuilding the iOS slice
risks ABI drift → ARCore breaks at link time. We always pass through Google's iOS / macOS
/ Catalyst / tvOS slices unchanged. The merge step (`xcodebuild -create-xcframework`)
only ADDS our `xros-arm64` and `xros-arm64-simulator`.

### `build/sources/grpc/third_party/zlib/CMakeLists.txt` patched
`build-grpc.sh` runs a sed patch removing `gz*.c` sources (needed with `-DZ_SOLO=1` since
zutil.h's fdopen stub conflicts with visionOS SDK). The patch is idempotent and applied
only if needed. CI must re-apply on fresh clone. Already baked into the script.

### Scenery is read-only
Phase 7 is the only phase that touches Scenery. Until then, NO writes to
`/Users/arthurschiller/Repositories/GitHub/Amped Labs/Apple Apps/Scenery`. The five
relevant Scenery touchpoints:
- `Scenery.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — read for context
- `Scenery/ci_scripts/visionOS/Package.resolved` — read for context
- `Scenery/ci_scripts/ci_post_clone.sh` — read for context (swap block lines 5-21)
- The `xcode_cloud-build-visionOS` git branch (stale, to be deleted in Phase 7)

## Environment

- macOS 26.4.1 (Apple Silicon, M4 Pro, 24 GB RAM)
- Xcode 26.5 (visionOS SDK 26.5)
- Homebrew tools: `cmake 4.3.2`, `ninja 1.13.2`, `go 1.26.3`, `ccache 4.13.6`
- ccache configured via `_build_common.sh` with `CCACHE_COMPILERCHECK=content` to survive
  Xcode/CLT updates without invalidating cache.
- `gh` CLI authenticated as `arthurschiller`.

## Memory

Persistent memory at `~/.claude/projects/-Users-arthurschiller-Repositories-GitHub-Misc-firebase-firestore-xcframeworks/memory/`:
- `feedback_commit_at_verified_milestones.md` — commit only after verification passes,
  not just on implementation. Lead the user through each milestone with a commit
  proposal before moving on.

## How to resume — paste this prompt into the new session

```
Read HANDOFF.md, CLAUDE.md, and prompt.md in /Users/arthurschiller/Repositories/GitHub/Misc/firebase-firestore-xcframeworks before doing anything.

Then execute Phase 5: vendor Firestore source from build/sources/firebase-ios-sdk/Firestore/ into the repo root, fork upstream Package.swift, swap in our 6 local binaryTargets, set up source-compile path for FirebaseFirestoreInternalWrapper, add a Swift test target that imports FirebaseFirestore. Build on visionOS simulator first (it's the platform that didn't work before — if green, the whole pivot works). Then iOS sim, Mac Catalyst, macOS.

Commit only at verified milestones — both build green AND ideally a runtime smoke test (Firestore.firestore() instantiation succeeds).

Do NOT touch Scenery (read-only until Phase 7). Do NOT use bare -j in any build script. Do NOT add direct source-target dependency on openssl_grpc (modulemap hyphen issue).

Plan the work, show me before grinding. I'll approve concrete steps.
```

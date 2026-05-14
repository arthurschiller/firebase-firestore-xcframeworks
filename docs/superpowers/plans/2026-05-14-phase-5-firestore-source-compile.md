# Phase 5 — Firestore source-compile overlay (visionOS-first) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Package.swift` an SPM overlay of `firebase-ios-sdk@11.15.0` that builds `FirebaseFirestore` against locally-built visionOS xcframeworks and vendored Firestore C++ source, so visionOS sim/device can `import FirebaseFirestore` from the same `Package.resolved` as iOS/macOS/Catalyst.

**Architecture:**
- Vendor `firebase-ios-sdk/Firestore/` (~13 MB after excludes) into repo root at `Firestore/`.
- Fork upstream `Package.swift` verbatim, then patch: add `.visionOS(.v1)` to `platforms`, delete the four upstream binary-dep packages (`abseil-cpp-binary`, `grpc-binary`, `firebase/nanopb.git`, `firebase/leveldb.git`), delete the `abseilDependency()` / `grpcDependency()` helpers, force the source-compile branch in `firestoreTargets()` and `firestoreWrapperTarget()` always, add visionOS+macCatalyst to the wrapper's platform condition, declare 6 local `.binaryTarget(... path: "build/artifacts/...")` entries, and rewrite every `.product(name: "abseil"|"gRPC-cpp"|"gRPC-C++"|"nanopb", package: ...)` to plain target refs (`"absl"`, `"grpcpp"`, `"nanopb"`).
- `FirebaseFirestoreInternalWrapper` is the source-compiled C++ target that links our 6 binaryTargets. It depends on `grpcpp` (NOT `openssl_grpc` — modulemap hyphen makes Clang reject direct source→openssl_grpc deps; transitive-only via grpcpp is fine).
- `TestConsumer/Package.swift` adds a `FirestoreSmokeTest` target that calls `Firestore.firestore()` to prove link + module resolution end-to-end.

**Tech Stack:** Swift Package Manager 5.9, Xcode 26.5 (visionOS SDK 26.5), xcodebuild, our 6 pre-built XCFrameworks under `build/artifacts/{absl,openssl_grpc,grpc,grpcpp,leveldb,nanopb}/*.xcframework`.

**Verification strategy:** visionOS simulator FIRST (the platform that didn't work before — if green, the pivot works). Then iOS sim, Mac Catalyst, macOS. Commit only after a milestone is verified (build green + ideally `Firestore.firestore()` instantiation runtime-green).

---

## File map

- **Create:** `Firestore/` (vendored copy of `build/sources/firebase-ios-sdk/Firestore/`, minus `Example/` and `fuzzing/` which upstream excludes anyway).
- **Modify:** `Package.swift` — replace stub with forked upstream Package.swift + targeted patches.
- **Modify:** `TestConsumer/Package.swift` — add `.package(path: "..")` consumption + `FirestoreSmokeTest` target.
- **Create:** `TestConsumer/Sources/FirestoreSmokeTest/SmokeTest.swift` — calls `Firestore.firestore()`.
- **Create:** `TestConsumer/Tests/FirestoreSmokeTestTests/SmokeTests.swift` — XCTest wrapping the instantiation.
- **Untouched:** `scripts/`, `build/artifacts/` (binaries already built), all existing AbseilSmokeTest code.

---

## Task 1: Vendor Firestore source

**Files:**
- Create: `Firestore/` (copy of `build/sources/firebase-ios-sdk/Firestore/`, ~13 MB after excludes)

- [ ] **Step 1: Copy with excludes**

```bash
cd /Users/arthurschiller/Repositories/GitHub/Misc/firebase-firestore-xcframeworks
rsync -a \
  --exclude='Example/' \
  --exclude='fuzzing/' \
  --exclude='.DS_Store' \
  build/sources/firebase-ios-sdk/Firestore/ Firestore/
```

`Example/` and `fuzzing/` are listed in upstream's `exclude:` for the source-compile target anyway — drop them to save ~10 MB in git.

- [ ] **Step 2: Verify vendored tree**

Run: `du -sh Firestore && ls Firestore`
Expected: ~13 MB. Contents: `CHANGELOG.md CMakeLists.txt LICENSE Protos README.md Source Swift core test.sh third_party` (no Example, no fuzzing).

- [ ] **Step 3: Stage vendored source (no commit yet)**

```bash
git add Firestore/
git status --short | head -5
```
Expected: lots of `A  Firestore/...` lines. Do NOT commit yet — wait for the verified-milestone after Phase 5 builds green.

---

## Task 2: Replace Package.swift with patched fork of upstream

**Files:**
- Modify: `Package.swift` (currently a 17-line stub — replaced wholesale)

- [ ] **Step 1: Copy upstream Package.swift as starting point**

```bash
cp build/sources/firebase-ios-sdk/Package.swift Package.swift
```

- [ ] **Step 2: Add `.visionOS(.v1)` to the top-level platforms**

Edit line 26 of the new `Package.swift`:

```swift
// before
platforms: [.iOS(.v12), .macCatalyst(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v7)],
// after
platforms: [.iOS(.v12), .macCatalyst(.v13), .macOS(.v10_15), .tvOS(.v13), .visionOS(.v1), .watchOS(.v7)],
```

- [ ] **Step 3: Remove the four upstream binary-dep package entries**

In the `dependencies:` array (lines ~174-187 in upstream), delete these four entries:

```swift
.package(
  url: "https://github.com/firebase/nanopb.git",
  "2.30910.0" ..< "2.30911.0"
),
abseilDependency(),
grpcDependency(),
// (lines 180-183: ocmock — KEEP, it's a test dep)
.package(
  url: "https://github.com/firebase/leveldb.git",
  "1.22.2" ..< "1.23.0"
),
```

Delete the four entries (3 `.package` calls + 2 function calls — `abseilDependency()` and `grpcDependency()`). Keep `ocmock`, `GCDWebServer`, `interop-ios-for-google-sdks`, GoogleDataTransport, GoogleUtilities, gtm-session-fetcher, googleAppMeasurementDependency(), Promises, SwiftProtobuf.

- [ ] **Step 4: Delete the `abseilDependency()` and `grpcDependency()` helper functions**

Delete the bodies at upstream lines 1450-1468 and 1470-1482. (After deletion, the only remaining helpers are `googleAppMeasurementDependency()`, `firestoreWrapperTarget()`, `firestoreTargets()`.)

- [ ] **Step 5: Rewrite every `.product(name: ...)` reference to the four removed packages**

Use this sed pass (run from repo root, dry-run first with `-n` then apply):

```bash
# preview
grep -nE '\.product\(name: "(abseil|gRPC-C\+\+|gRPC-cpp|nanopb)", package:' Package.swift

# apply (in-place; preserves .when() conditions because we only replace the .product(...) span up to the matching paren)
```

Hand-edit each match — there are ~15 of them. Replacements:

| Before | After |
|---|---|
| `.product(name: "abseil", package: "abseil-cpp-binary")` | `"absl"` |
| `.product(name: "abseil", package: "abseil-cpp-SwiftPM")` | `"absl"` |
| `.product(name: "gRPC-C++", package: "grpc-binary")` | `"grpcpp"` |
| `.product(name: "gRPC-cpp", package: "grpc-ios")` | `"grpcpp"` |
| `.product(name: "nanopb", package: "nanopb")` | `"nanopb"` |

**Conditions:** for matches inside `.product(name: ..., package: ..., condition: .when(platforms: [.iOS, .macCatalyst, .tvOS, .macOS]))` — the `condition:` argument is lost when collapsing to a plain string. That's fine for visionOS support: we WANT these deps to apply on visionOS too. The conditions were there to gate the binary-dep on platforms that have visionOS-less Google binaries. Now that we ship visionOS, drop the gating.

Exception: `gRPC-C++` and `abseil` references inside `firestoreTargets()` line ~1631 / ~1637 are in the dead-code BINARY branch we're about to delete. Don't bother editing them — Task 8 deletes the whole branch.

- [ ] **Step 6: Add the 6 local binaryTargets**

In the targets array (just before the existing `.target` entries — e.g. right after the `products:` close, near upstream line ~220), insert:

```swift
.binaryTarget(
  name: "absl",
  path: "build/artifacts/absl/absl.xcframework"
),
.binaryTarget(
  name: "openssl_grpc",
  path: "build/artifacts/openssl_grpc/openssl_grpc.xcframework"
),
.binaryTarget(
  name: "grpc",
  path: "build/artifacts/grpc/grpc.xcframework"
),
.binaryTarget(
  name: "grpcpp",
  path: "build/artifacts/grpcpp/grpcpp.xcframework"
),
.binaryTarget(
  name: "leveldb",
  path: "build/artifacts/leveldb/leveldb.xcframework"
),
.binaryTarget(
  name: "nanopb",
  path: "build/artifacts/nanopb/nanopb.xcframework"
),
```

(Order doesn't matter for SPM, but group them together for readability.)

- [ ] **Step 7: Verify Package.swift parses**

```bash
swift package dump-package > /dev/null
```
Expected: no output (success). If errors, fix syntactic issues before moving on.

- [ ] **Step 8: Do NOT commit yet** — Task 8 still needs to modify `firestoreTargets()` and `firestoreWrapperTarget()`.

---

## Task 3: Force source-compile path in `firestoreTargets()`

**Files:**
- Modify: `Package.swift` — `firestoreTargets()` function

- [ ] **Step 1: Delete the binary-target branch and keep only the source-compile branch**

The function (upstream lines 1503-1666) has two branches. Replace the entire body with the source-compile branch only, dropping the env-var check. Final shape:

```swift
func firestoreTargets() -> [Target] {
  return [
    .target(
      name: "FirebaseFirestoreInternalWrapper",
      dependencies: [
        "FirebaseAppCheckInterop",
        "FirebaseCore",
        "leveldb",
        "nanopb",
        "absl",
        "grpcpp",
      ],
      path: "Firestore",
      exclude: [
        "CHANGELOG.md",
        "CMakeLists.txt",
        "Example/",
        "LICENSE",
        "Protos/CMakeLists.txt",
        "Protos/Podfile",
        "Protos/README.md",
        "Protos/build_protos.py",
        "Protos/cpp/",
        "Protos/lib/",
        "Protos/nanopb_cpp_generator.py",
        "Protos/protos/",
        "README.md",
        "Source/CMakeLists.txt",
        "Swift/",
        "core/CMakeLists.txt",
        "core/src/util/config_detected.h.in",
        "core/test/",
        "fuzzing/",
        "test.sh",
        // SPM doesn't recognize hpp files; rely on header search paths for nlohmann_json.
        "third_party/",
        // Alternate platform implementations.
        "core/src/remote/connectivity_monitor_noop.cc",
        "core/src/util/filesystem_win.cc",
        "core/src/util/log_stdio.cc",
        "core/src/util/secure_random_openssl.cc",
      ],
      sources: [
        "Source/",
        "Protos/nanopb/",
        "core/include/",
        "core/src",
      ],
      publicHeadersPath: "Source/Public",
      cSettings: [
        .headerSearchPath("../"),
        .headerSearchPath("Source/Public/FirebaseFirestore"),
        .headerSearchPath("Protos/nanopb"),
        .define("PB_FIELD_32BIT", to: "1"),
        .define("PB_NO_PACKED_STRUCTS", to: "1"),
        .define("PB_ENABLE_MALLOC", to: "1"),
        .define("FIRFirestore_VERSION", to: firebaseVersion),
      ],
      linkerSettings: [
        .linkedFramework(
          "SystemConfiguration",
          .when(platforms: [.iOS, .macOS, .tvOS, .visionOS])
        ),
        .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .visionOS])),
        .linkedLibrary("c++"),
      ]
    ),
    .target(
      name: "FirebaseFirestore",
      dependencies: [
        "FirebaseCore",
        "FirebaseCoreExtension",
        "FirebaseFirestoreInternalWrapper",
        "FirebaseSharedSwift",
      ],
      path: "Firestore",
      exclude: [
        "CHANGELOG.md",
        "CMakeLists.txt",
        "Example/",
        "LICENSE",
        "Protos/",
        "README.md",
        "Source/",
        "core/",
        "fuzzing/",
        "test.sh",
        "Swift/CHANGELOG.md",
        "Swift/Tests/",
        "third_party/nlohmann_json",
      ],
      sources: [
        "Swift/Source/",
      ],
      resources: [.process("Source/Resources/PrivacyInfo.xcprivacy")]
    ),
  ]
}
```

Notes on the diff from upstream's source-compile branch (lines 1505-1601):
- `.product(name: "nanopb", package: "nanopb")` → `"nanopb"` (binaryTarget).
- `.product(name: "abseil", package: "abseil-cpp-SwiftPM")` → `"absl"` (binaryTarget; name change!).
- `.product(name: "gRPC-cpp", package: "grpc-ios")` → `"grpcpp"` (binaryTarget; name change!).
- Everything else identical.

**Why no direct `openssl_grpc` dep:** `FirebaseFirestoreInternalWrapper` is a source target; if it directly depended on `openssl_grpc`, SPM would feed its hyphenated modulemap (`framework module BoringSSL-GRPC`) into Clang and fail. `grpcpp` and `grpc` are binaryTargets — their dylibs link `openssl_grpc` transitively at the linker stage, which is fine. Trust the chain. (Locked-decision rule from HANDOFF.)

- [ ] **Step 2: Verify dump-package still works**

```bash
swift package dump-package > /dev/null
```

---

## Task 4: Force source-compile path in `firestoreWrapperTarget()` + add visionOS+Catalyst

**Files:**
- Modify: `Package.swift` — `firestoreWrapperTarget()` function

- [ ] **Step 1: Replace the function body**

Replace upstream lines 1484-1501 with a single unconditional source-compile-style wrapper that supports all five platforms (iOS, macCatalyst, tvOS, macOS, visionOS):

```swift
func firestoreWrapperTarget() -> Target {
  return .target(
    name: "FirebaseFirestoreTarget",
    dependencies: [.target(
      name: "FirebaseFirestore",
      condition: .when(platforms: [.iOS, .macCatalyst, .tvOS, .macOS, .visionOS])
    )],
    path: "SwiftPM-PlatformExclude/FirebaseFirestoreWrap"
  )
}
```

Notes:
- Upstream's source-compile branch (1486-1491) lacked `.macCatalyst`. Add it — we want Catalyst working too.
- Drop the `cSettings: [.define("FIREBASE_BINARY_FIRESTORE", to: "1")]` (only relevant to the binary branch).

- [ ] **Step 2: Vendor the wrap directory**

The wrapper path `SwiftPM-PlatformExclude/FirebaseFirestoreWrap` must exist locally:

```bash
mkdir -p SwiftPM-PlatformExclude
cp -R build/sources/firebase-ios-sdk/SwiftPM-PlatformExclude/FirebaseFirestoreWrap \
      SwiftPM-PlatformExclude/
ls SwiftPM-PlatformExclude/FirebaseFirestoreWrap
```
Expected: `dummy.m include` (or similar — a near-empty bridging dir).

- [ ] **Step 3: Verify**

```bash
swift package dump-package > /dev/null
```

---

## Task 5: Smoke-test target wiring in TestConsumer

**Files:**
- Modify: `TestConsumer/Package.swift`
- Create: `TestConsumer/Sources/FirestoreSmokeTest/SmokeTest.swift`
- Create: `TestConsumer/Tests/FirestoreSmokeTestTests/SmokeTests.swift`

- [ ] **Step 1: Add path dependency on root package**

Edit `TestConsumer/Package.swift`. After the existing `platforms:` and before `products:`, add the root as a `.package(path: "..")` dependency. Then add a Swift library target + test target that import FirebaseFirestore.

Final shape (replacing current file):

```swift
// swift-tools-version:5.9
// TestConsumer: validates merged xcframeworks via C/C++ shims that exercise
// real library APIs from Swift on iOS sim / macOS / Catalyst / visionOS sim.
//
// Note: openssl_grpc is a transitive-only dependency (consumed by grpc /
// grpcpp / Firestore C++ — never directly from source code). Its modulemap
// uses a hyphenated module name that Clang can't parse if a source target
// tries to depend on it directly. So we don't declare a shim for it here;
// the FirestoreSmokeTest will exercise it transitively.
import PackageDescription

let package = Package(
    name: "TestConsumer",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AbseilSmokeTest", targets: ["AbseilSmokeTest"]),
        .library(name: "FirestoreSmokeTest", targets: ["FirestoreSmokeTest"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .binaryTarget(
            name: "absl",
            path: "../build/artifacts/absl/absl.xcframework"
        ),
        .target(
            name: "AbseilCxxShim",
            dependencies: ["absl"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "AbseilSmokeTest",
            dependencies: ["AbseilCxxShim"]
        ),
        .testTarget(
            name: "AbseilSmokeTestTests",
            dependencies: ["AbseilCxxShim"]
        ),
        .target(
            name: "FirestoreSmokeTest",
            dependencies: [
                .product(name: "FirebaseFirestore", package: "firebase-firestore-xcframeworks"),
            ]
        ),
        .testTarget(
            name: "FirestoreSmokeTestTests",
            dependencies: ["FirestoreSmokeTest"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
```

(The root package's `name` is `firebase-firestore-xcframeworks` per its current Package.swift; verify by `grep '^    name:' Package.swift` — keep the `.product(package:)` arg consistent with that.)

- [ ] **Step 2: Create the smoke-test source**

Create `TestConsumer/Sources/FirestoreSmokeTest/SmokeTest.swift`:

```swift
import FirebaseFirestore
import FirebaseCore

public enum FirestoreSmokeTest {
    /// Returns true if `Firestore.firestore()` returns a non-nil instance.
    /// No backend connection — just verifies SPM link + module resolution + class loader.
    public static func instantiate() -> Bool {
        // FirebaseApp.configure() is normally called at app launch; without it,
        // Firestore.firestore() asserts. For a pure link-test we don't need a real
        // FirebaseOptions on disk — minimal options keep the call site honest.
        if FirebaseApp.app() == nil {
            let opts = FirebaseOptions(
                googleAppID: "1:000000000000:ios:0000000000000000",
                gcmSenderID: "000000000000"
            )
            opts.projectID = "smoke-test"
            opts.apiKey = "AIza-smoke-test"
            FirebaseApp.configure(options: opts)
        }
        return Firestore.firestore() != nil
    }
}
```

- [ ] **Step 3: Create the XCTest wrapper**

Create `TestConsumer/Tests/FirestoreSmokeTestTests/SmokeTests.swift`:

```swift
import XCTest
@testable import FirestoreSmokeTest

final class FirestoreSmokeTests: XCTestCase {
    func testFirestoreInstantiates() {
        XCTAssertTrue(FirestoreSmokeTest.instantiate())
    }
}
```

- [ ] **Step 4: Resolve from TestConsumer**

```bash
cd TestConsumer
swift package resolve 2>&1 | tail -20
```
Expected: resolves without errors. May download some Firebase transitive deps (GoogleAppMeasurement, GoogleUtilities, etc.) — fine.

---

## Task 6: visionOS simulator build (CRITICAL — the platform that didn't work before)

**Files:**
- None modified; this is a verification step.

- [ ] **Step 1: List available visionOS sim destinations**

```bash
xcrun simctl list --json devices available | python3 -c "import json,sys; d=json.load(sys.stdin); [print(k,*[v['name'] for v in vs]) for k,vs in d['devices'].items() if 'xrOS' in k or 'visionOS' in k]"
```
Expected: a recent `Apple Vision Pro` simulator on visionOS 26.x.

- [ ] **Step 2: Build `FirestoreSmokeTest` for visionOS Simulator**

```bash
cd /Users/arthurschiller/Repositories/GitHub/Misc/firebase-firestore-xcframeworks/TestConsumer
xcodebuild \
  -scheme FirestoreSmokeTest \
  -destination 'generic/platform=visionOS Simulator' \
  -configuration Debug \
  build 2>&1 | tee /tmp/phase5-visionos-build.log | tail -50
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: If link fails on a specific symbol — STOP, do not pre-emptively patch**

Per HANDOFF: 11 missing `_grpc_*` symbols (ALTS, LB v1, abseil log) and ~5000 absl template instantiations are known-missing in our visionOS gRPC slice. Firestore is expected NOT to reference them. If link fails on a named symbol:
1. Capture the symbol name from the log.
2. Check it against `CLAUDE.md`'s "Phase 3 gRPC ABI gaps" list.
3. Report back — do not start rebuilding gRPC.

- [ ] **Step 4: If build succeeds, run the XCTest on visionOS simulator**

```bash
# pick the first available Vision Pro simulator name + OS
xcodebuild \
  -scheme FirestoreSmokeTest \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  test 2>&1 | tee /tmp/phase5-visionos-test.log | tail -30
```
Expected: `Test Suite 'FirestoreSmokeTests' passed`, `testFirestoreInstantiates` passes.

- [ ] **Step 5: Commit the visionOS milestone**

This is THE verified milestone — both build and runtime green on the platform that was the entire point of this project.

```bash
cd /Users/arthurschiller/Repositories/GitHub/Misc/firebase-firestore-xcframeworks
git add Firestore/ SwiftPM-PlatformExclude/ Package.swift TestConsumer/
git status --short | head
git commit -m "$(cat <<'EOF'
Phase 5: Firestore source-compile overlay, visionOS sim green

Vendors firebase-ios-sdk Firestore C++ source into Firestore/, forks
upstream Package.swift to swap the 4 binary deps (abseil-cpp-binary,
grpc-binary, firebase/nanopb, firebase/leveldb) for our 6 locally-built
xcframeworks, and forces the source-compile branch in firestoreTargets()
and firestoreWrapperTarget() with visionOS + macCatalyst added.

TestConsumer gains a FirestoreSmokeTest target that calls
Firestore.firestore() — instantiation succeeds on visionOS Simulator,
proving the entire link + module-resolution chain works on the platform
Google ships no visionOS binary for.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: iOS simulator build + runtime

**Files:**
- None modified; verification.

- [ ] **Step 1: Build for iOS Simulator**

```bash
cd TestConsumer
xcodebuild \
  -scheme FirestoreSmokeTest \
  -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED. **Critical:** this path uses Google's iOS slice (untouched bytes — ARCore Geospatial's link partner). If it breaks, our pass-through is wrong.

- [ ] **Step 2: Run test on iOS Simulator**

```bash
xcodebuild \
  -scheme FirestoreSmokeTest \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -20
```
(Pick whatever iPhone simulator is installed — use `xcrun simctl list devices available | grep iPhone | head -3` to find one.)
Expected: PASS.

---

## Task 8: Mac Catalyst + macOS builds

**Files:**
- None modified; verification.

- [ ] **Step 1: Build for Mac Catalyst**

```bash
cd TestConsumer
xcodebuild \
  -scheme FirestoreSmokeTest \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Build for macOS**

```bash
xcodebuild \
  -scheme FirestoreSmokeTest \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run test on macOS host**

```bash
xcodebuild \
  -scheme FirestoreSmokeTest \
  -destination 'platform=macOS,arch=arm64' \
  test 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 4: Commit the all-platforms milestone**

```bash
git status --short  # likely no new diffs — config-only — but if Package.resolved updated, capture it
git add -A
git commit --allow-empty -m "$(cat <<'EOF'
Phase 5: iOS sim, Mac Catalyst, macOS verified green

All four target platforms (visionOS sim, iOS sim, Mac Catalyst, macOS)
build and Firestore.firestore() instantiation passes runtime. The
overlay is complete — Phase 6 (CI port) and Phase 7 (Scenery cutover)
can proceed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(`--allow-empty` only used if Task 6's commit already captured all source diffs — common since steps 7-8 are verification-only.)

---

## Task 9: Update HANDOFF.md

**Files:**
- Modify: `HANDOFF.md`

- [ ] **Step 1: Flip Phase 5 status to ✅ and add notes**

In the status table (line ~39 of HANDOFF.md), change `| 5. Package.swift + TestConsumer | **NEXT** | ...` to:

```
| 5. Package.swift + TestConsumer | ✅ | <commit-sha> — Firestore source-compile path green on visionOS sim / iOS sim / Mac Catalyst / macOS |
| 6. CI port | **NEXT** | Wrap proven local scripts in `.github/workflows/build.yml` |
```

- [ ] **Step 2: Commit**

```bash
git add HANDOFF.md
git commit -m "Phase 5 complete — update handoff status"
```

---

## Self-review notes (already verified during plan-writing)

- **Spec coverage:** every bullet in HANDOFF's "Phase 5 plan" maps to a task here (vendor source → T1, fork Package.swift → T2, drop env-var → T3+T4, in-repo test app → T5, verify all platforms → T6+T7+T8, commit at milestones → T6+T8+T9).
- **Placeholder scan:** no TBDs; every code change either shows the full replacement (T3, T4 wrapper body) or names the exact upstream lines to edit (T2). All commands have expected outputs.
- **Type consistency:** binaryTarget names (`absl`, `openssl_grpc`, `grpc`, `grpcpp`, `leveldb`, `nanopb`) used consistently across T2 (declarations) and T3/T4 (references). `FirestoreSmokeTest` target name used consistently in T5 source/test/scheme.

## Open questions for user before grinding

1. **Build verbosity:** `xcodebuild` is noisy. OK to pipe through `xcpretty` if installed, else raw tails? (Plan currently uses raw tail.)
2. **Simulator names:** plan assumes a `iPhone 17` and `Apple Vision Pro` simulator exists. If different names exist, the verify steps need swapped destinations — fine to discover at runtime.
3. **Commit granularity:** plan commits once after visionOS green (the big win) and once after the rest. OK or want a separate commit per platform?
4. **Phase 4 part 2 (binary Firestore):** out of scope here. Plan leaves the source-compile path in place permanently for now; binary conversion is a future Phase.

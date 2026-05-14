# Build visionOS slices for Firebase Firestore — minimal SPM overlay

## Goal

A GitHub repo that acts as a **drop-in SPM replacement for `firebase/firebase-ios-sdk` for one consumer** (the Scenery iOS/macOS/visionOS app). Only `FirebaseFirestore` and its four C++ dependencies need rebuilt artifacts — everything else passes through to upstream Firebase unchanged.

After integration, the consumer's project resolves a single `Package.resolved` across iOS, macOS, Mac Catalyst, and visionOS — no env-var dance, no source builds, no Package.resolved swap, no second branch.

## Why this is needed

Google ships visionOS slices for every Firebase binary *except* Firestore, because Firestore depends on `google/grpc-binary` + `google/abseil-cpp-binary`, neither of which include `xros` slices. The only Google-sanctioned visionOS path is the `FIREBASE_SOURCE_FIRESTORE=1` source compile, which uses a different SPM dependency graph — so iOS and visionOS can't share a `Package.resolved`. That's the maintenance nightmare we're killing.

## Strict additive constraint

Google's `Firebase.zip` (e.g. https://github.com/firebase/firebase-ios-sdk/releases/download/12.13.0/Firebase.zip) ships valid, signed XCFrameworks for every platform *except* visionOS. **Do not rebuild any existing slice.** Download Google's binaries, build only the two missing visionOS slices (`xros-arm64` + `xrsimulator-arm64`) for the 5 affected frameworks, merge with `xcodebuild -create-xcframework`. Five hybrid XCFrameworks; iOS/macOS/Catalyst/tvOS slices remain Google's exact bytes.

**Why this strictness matters:** the consumer also uses `arcore-ios-sdk` (ARCoreGeospatial) on iOS, which links against the same Google gRPC C++ runtime. The iOS Firestore slice and the iOS ARCore slice currently coexist because they were built against the same gRPC binaries. Rebuilding the iOS slice yourself risks ABI/symbol drift that breaks ARCore at link time. By keeping Google's iOS slices untouched, ARCore + Firestore on iOS continue to work exactly as they do today. ARCoreGeospatial is `iOS`-only at the SPM level (the consumer's Package.swift already conditions it `.when(platforms: [.iOS])`), so it never participates in the visionOS build graph — there's no ARCore↔visionOS-slice interaction to worry about.

## The 5 XCFrameworks to add visionOS slices to

Inside Google's `Firebase.zip` under `Firebase/FirebaseFirestore/`:

1. `FirebaseFirestore.xcframework` — Firestore's own C++ core
2. `gRPC-C++.xcframework` — gRPC's C++ bindings
3. `gRPC-Core.xcframework` — gRPC's C core
4. `openssl_grpc.xcframework` — BoringSSL with Google's `BORINGSSL_PREFIX_grpc_` symbol prefix
5. `absl.xcframework` — abseil-cpp

Every other XCFramework in `Firebase.zip` (FirebaseAuth, FirebaseStorage, FirebaseMessaging, FirebaseRemoteConfig, FirebaseAppCheck, FirebaseAnalytics, FirebaseDatabase, FirebaseABTesting, FirebaseCrashlytics, FirebaseMLModelDownloader, FirebaseFunctions, FirebaseCore, transitive Firebase deps) **already includes visionOS slices** as of recent Firebase releases — pass them through unchanged. Verify by inspecting their `Info.plist` `SupportedPlatform` lists; if any are missing visionOS, pass them through anyway since the consumer's runtime path doesn't require them on visionOS.

## Deliverable

A single GitHub repo, this one (`firebase-firestore-xcframeworks`), containing:

1. **`Package.swift`** that mirrors the public product surface of `firebase-ios-sdk` exactly — same product names, same module names, same import statements work unchanged. For the 5 rebuilt frameworks, `.binaryTarget` URLs point at this repo's GH Release zips. For every other product, declare them as if they came from upstream (the simplest path is forking `firebase-ios-sdk` and replacing only the 5 affected `.binaryTarget` URLs + checksums; everything else stays untouched).
2. **`.github/workflows/build.yml`** — `workflow_dispatch` with input `firebase_version` (e.g. `12.13.0`). Runs on `macos-15` (ships visionOS SDK). For each Firebase version:
   - Download Google's `Firebase.zip`.
   - Resolve upstream source commits: gRPC version from `google/grpc-binary`'s Package.swift at the matching Firebase release; BoringSSL submodule SHA inside gRPC; abseil version from `google/abseil-cpp-binary`; Firestore C++ source from `firebase-ios-sdk` at the same tag.
   - Build `xros-arm64` + `xrsimulator-arm64` slices via CMake/Xcode for each of the 5 libraries.
   - **BoringSSL gotcha:** Google's `openssl_grpc` is BoringSSL with all symbols renamed via `BORINGSSL_PREFIX=BORINGSSL_PREFIX_grpc_`. Run `boringssl/util/make_prefix_headers.go` with the same prefix string so the new slices' symbols match Google's existing iOS slice. Likely need `-DOPENSSL_NO_ASM=1` for `xros-simulator-arm64` until upstream assembly probes know that triple. Verify via `nm` that `BORINGSSL_PREFIX_grpc_*` symbols are present in the built `.a` and identical-named ones exist in Google's iOS slice.
   - For each of the 5 XCFrameworks: extract Google's `.xcframework`, copy in the new `xros` + `xrsimulator` framework directories, repackage via `xcodebuild -create-xcframework -framework iOS/… -framework iOS-sim/… -framework macOS/… -framework Catalyst/… -framework tvOS/… -framework tvOS-sim/… -framework xros/… -framework xrsimulator/… -output …`. Zip.
   - `swift package compute-checksum` per zip.
   - Upload zips as GH Release assets tagged with the Firebase version.
   - `sed`-patch `Package.swift` with the 5 new URLs + checksums, commit, tag, push.
3. **README** with one-paragraph integration: replace `https://github.com/firebase/firebase-ios-sdk.git` with this repo's URL in `Scenery.xcodeproj`'s package dependencies, pin to the desired tag, delete `Scenery/ci_scripts/visionOS/Package.resolved` and the Package.resolved-swap block in `ci_post_clone.sh`, delete the `xcode_cloud-build-visionOS` branch.

## Out of scope

- **All Firebase products other than Firestore** — pass through to Google's binaries.
- **ARCore Geospatial** — already iOS-only at the SPM level in the consumer's project. No work needed; iOS slices remain Google's untouched binaries, so ARCore + Firestore on iOS keep linking cleanly.
- **watchOS** — not used.
- **Source distribution** — explicitly not building from source. This entire project exists to make the *binary* path work on visionOS.

## First-run plan

Don't try to build all 5 frameworks on first attempt. Smallest end-to-end roundtrip first:

1. Build `absl.xcframework` visionOS slices only (pure CMake, no prefix dance, ~10 min per slice).
2. Merge with Google's existing `absl.xcframework`.
3. Publish a v0.0.1 release with that one merged framework + a `Package.swift` that proxies all other Firebase products to upstream.
4. Consume from a throwaway test project, confirm `import abseil` resolves on an `xrsimulator` scheme. Confirm iOS still builds against the unchanged Google slice.

Once that roundtrip is green: add gRPC (medium difficulty), then BoringSSL (hard, iteration expected), then Firestore (depends on the three). BoringSSL is where Action runs get slow — 30–60 minutes per attempt. Plan for 3–5 iterations.

## Reference links

- Upstream Firebase SDK: https://github.com/firebase/firebase-ios-sdk
- `Firebase.zip` releases: https://github.com/firebase/firebase-ios-sdk/releases
- `grpc-binary` Package.swift (URL/checksum pattern, gRPC version pins): https://github.com/google/grpc-binary/blob/main/Package.swift
- `abseil-cpp-binary` Package.swift: https://github.com/google/abseil-cpp-binary/blob/main/Package.swift
- gRPC source + Apple build scripts: https://github.com/grpc/grpc
- BoringSSL symbol-prefix tool: https://boringssl.googlesource.com/boringssl/+/refs/heads/main/util/make_prefix_headers.go
- Firebase's stated position (the consumer's own issue): https://github.com/firebase/firebase-ios-sdk/issues/14414
- akaffenberger's CocoaPods-style precedent (no visionOS): https://github.com/akaffenberger/firebase-ios-sdk-xcframeworks
- invertase's CocoaPods precedent (no visionOS): https://github.com/invertase/firestore-ios-sdk-frameworks

## Success criteria

The consumer can:

1. Replace `https://github.com/firebase/firebase-ios-sdk.git` with this repo's URL in `Scenery.xcodeproj`.
2. Open Xcode normally (no `open --env`, no shell env var).
3. Archive iOS scheme — builds, links cleanly with ARCore Geospatial.
4. Archive visionOS scheme — builds, no source-compile spinner, no Package.resolved mismatch.
5. Both archives use the **same** `Package.resolved`.
6. `Scenery/ci_scripts/visionOS/Package.resolved` and the swap block in `ci_post_clone.sh` are deleted. The `xcode_cloud-build-visionOS` branch is deleted.

All six green → done. Document the bump procedure in the README and hand off.

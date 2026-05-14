// swift-tools-version:5.9
// firebase-firestore-xcframeworks — overlay on firebase-ios-sdk 11.15.x that
// swaps FirebaseFirestore for a binary path with visionOS slices.
//
// Architecture:
//   - Five `firestore_*` binaryTargets for Firestore's native C/C++ deps.
//     Names prefixed to avoid collisions with upstream firebase-ios-sdk's
//     external package deps (abseil-cpp-binary, grpc-binary, firebase/leveldb).
//   - `_FirebaseFirestoreInternal` binaryTarget — Google's six untouched
//     iOS/macOS/Catalyst/tvOS slices merged with our two visionOS slices.
//     The framework's modulemap module identifier is still
//     `FirebaseFirestoreInternal` (intrinsic to the binary). SPM target name
//     is the underscored variant to avoid collision.
//   - `_FirebaseFirestoreInternalWrapper` source target (Obj-C shim around
//     the binary's headers). Renamed in SPM space; reachable from Firestore
//     Swift code via a moduleAlias.
//   - `FirebaseFirestorePrebuilt` source target (Swift wrapper). Renamed
//     from upstream's `FirebaseFirestore` to avoid SPM target-name collision
//     with firebase-ios-sdk's own target of the same name, which is in the
//     same dep graph (pulled by FirebaseCore/Auth/RemoteConfig). Consumer
//     code imports `FirebaseFirestorePrebuilt` instead of `FirebaseFirestore`.
//   - Firebase Core / SharedSwift / CoreExtension / AppCheckInterop /
//     AuthInterop come from upstream firebase-ios-sdk, pulled either by
//     direct product references (FirebaseCore) or transitively via heavier
//     products that bring internal-only targets into the build graph
//     (FirebaseAuth → CoreExtension, AppCheckInterop, AuthInterop;
//     FirebaseRemoteConfig → SharedSwift). Source-compile cost: seconds, on
//     every platform including visionOS.
//
// HACK — openssl_grpc modulemap module identifier was renamed from
// `BoringSSL-GRPC` to `openssl_grpc` in every slice via
// scripts/normalize-openssl-grpc-modulemap.sh. Re-run that script if the
// xcframework is rebuilt or its iOS slices refreshed from Google's release.
//
// HACK — grpc.xcframework's visionOS slices were originally built with
// libabsl_*.a bundled into the binary (per scripts/build-grpc.sh, mirroring
// Google's iOS build). That created duplicate-symbol link errors in
// consumer apps because absl.xcframework also provides those symbols on
// visionOS. Fix: scripts/build-grpc.sh no longer bundles libabsl_*.a;
// absl symbols come exclusively from firestore_absl. Google's iOS slices
// are untouched. If grpc is ever rebuilt from scratch, ensure the
// libabsl_*.a bundling line stays removed.
//
// HACK — absl.xcframework's visionOS slices are built with
// ABSL_OPTION_USE_STD_* forced to 0 (see scripts/build-absl.sh). Default
// auto-detect (=2) chooses std:: aliases when compiled with C++17, but
// gRPC's bundled absl auto-detects differently and uses distinct classes,
// producing mismatched mangled names at link time. Forcing 0 makes ABI
// deterministic and matches Google's iOS/macOS/tvOS slices.

import PackageDescription

let firebaseVersion = "11.15.0"

let package = Package(
    name: "firebase-firestore-xcframeworks",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        // Product and target are both named `FirebaseFirestorePrebuilt` —
        // a deliberate rename from upstream's `FirebaseFirestore` to avoid
        // SPM target-name and PIF product-name collisions with
        // firebase-ios-sdk (which ships its own `FirebaseFirestore` in the
        // same dep graph). Consumers `import FirebaseFirestorePrebuilt`
        // wherever upstream docs say `import FirebaseFirestore`. API
        // surface is otherwise identical to upstream Firestore.
        .library(name: "FirebaseFirestorePrebuilt", targets: ["FirebaseFirestorePrebuilt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "11.15.0"),
        .package(url: "https://github.com/firebase/nanopb.git", "2.30910.0" ..< "2.30911.0"),
    ],
    targets: [
        // MARK: - Local binaryTargets

        .binaryTarget(name: "firestore_absl",
                      // Re-released under 11.15.5 after rebuilding visionOS slices
                      // with ABSL_OPTION_USE_STD_* forced to 0 (distinct-class ABI).
                      // The previous build's auto-detect produced std::string_view
                      // aliasing, mangling differently than gRPC's bundled absl —
                      // breaking visionOS link with undefined symbol errors.
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.5/absl.xcframework.zip",
                      checksum: "8ba5ac93460c99955306c11cd036aafd1db9e05b5013f0b29731aa64a902f435"),
        .binaryTarget(name: "firestore_openssl_grpc",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/openssl_grpc.xcframework.zip",
                      checksum: "b0a0b744a3699bf741b7ada2a2892e1d8f3d0d4b40bf509685ee0916060236b2"),
        .binaryTarget(name: "firestore_grpc",
                      // Re-released under 11.15.4 after rebuilding visionOS slices
                      // without bundling libabsl_*.a — those symbols are now
                      // provided exclusively by firestore_absl, eliminating
                      // duplicate-symbol link errors in consumer apps on visionOS.
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.4/grpc.xcframework.zip",
                      checksum: "92fb564a3482c1736815b773040c83d9e78773686519ac433a2079b5736b73ec"),
        .binaryTarget(name: "firestore_grpcpp",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/grpcpp.xcframework.zip",
                      checksum: "fb07719d3313e99f729de9f2f26fafbe141d7288ff89c60a0c576480b8d8caef"),
        .binaryTarget(name: "firestore_leveldb",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/leveldb.xcframework.zip",
                      checksum: "72c900231e7880febd6172f9ecea89eff5893a7b19c02bab256e1162f6015014"),
        .binaryTarget(name: "_FirebaseFirestoreInternal",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/FirebaseFirestoreInternal.xcframework.zip",
                      checksum: "4ac88cf4607aff62e75f62833d70cc6415f47bb7e063e737946c25e7d9ce9a2c"),

        // MARK: - Firestore Obj-C wrapper around the binary

        // The vendored Firestore Swift sources do:
        //   #if SWIFT_PACKAGE
        //     @_exported import FirebaseFirestoreInternalWrapper
        //   #else
        //     @_exported import FirebaseFirestoreInternal
        //   #endif
        // SWIFT_PACKAGE is always defined under SPM, so a module named
        // FirebaseFirestoreInternalWrapper must be visible to our Swift
        // wrapper. We name the SPM target `_FirebaseFirestoreInternalWrapper`
        // (to avoid collision with upstream's same-named target) and use
        // moduleAliases at the dependency edge to make it appear as
        // `FirebaseFirestoreInternalWrapper` to compilers downstream.
        .target(
            name: "_FirebaseFirestoreInternalWrapper",
            dependencies: [.target(
                name: "_FirebaseFirestoreInternal",
                condition: .when(platforms: [.iOS, .macCatalyst, .tvOS, .macOS, .visionOS])
            )],
            path: "FirebaseFirestoreInternal",
            publicHeadersPath: "."
        ),

        // MARK: - Firestore Swift wrapper

        .target(
            name: "FirebaseFirestorePrebuilt",
            dependencies: [
                "_FirebaseFirestoreInternalWrapper",
                "firestore_absl",
                "firestore_grpc",
                "firestore_grpcpp",
                "firestore_openssl_grpc",
                "firestore_leveldb",
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                // FirebaseAuth product transitively pulls FirebaseAppCheckInterop,
                // FirebaseAuthInterop, FirebaseCoreExtension — internal-only
                // targets that aren't exposed as products by upstream.
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                // FirebaseRemoteConfig transitively pulls FirebaseSharedSwift.
                .product(name: "FirebaseRemoteConfig", package: "firebase-ios-sdk"),
                .product(name: "nanopb", package: "nanopb"),
            ],
            path: "Firestore/Swift/Source",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("SystemConfiguration",
                                 .when(platforms: [.iOS, .macOS, .tvOS, .visionOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .visionOS])),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)

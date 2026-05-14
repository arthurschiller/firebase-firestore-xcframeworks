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
                      // 11.15.6 build: visionOS slices with ABSL_OPTION_USE_STD_*
                      // forced to 0 (distinct-class ABI matching gRPC's bundled
                      // absl), AND re-zipped with `zip -y` to preserve macOS-style
                      // framework symlinks. Earlier 11.15.5 zip dereferenced
                      // Versions/Current symlinks, breaking Catalyst codesign.
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.6/absl.xcframework.zip",
                      checksum: "f3b2a3bb92c1d1f155184088123184d164d239493bb9d4bfb373051ece59f4f7"),
        .binaryTarget(name: "firestore_openssl_grpc",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/openssl_grpc.xcframework.zip",
                      checksum: "b0a0b744a3699bf741b7ada2a2892e1d8f3d0d4b40bf509685ee0916060236b2"),
        .binaryTarget(name: "firestore_grpc",
                      // 11.15.6 build: visionOS slices without bundled libabsl_*.a
                      // (absl symbols come from firestore_absl), AND re-zipped
                      // with `zip -y` to preserve framework symlinks for Catalyst.
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.6/grpc.xcframework.zip",
                      checksum: "4aafe55b44a5ad7be798f4bdd46f970413e198321e7b283aab2c94cc0a9e59f5"),
        .binaryTarget(name: "firestore_grpcpp",
                      // 11.15.6 build: re-zipped with `zip -y` to preserve
                      // framework symlinks (the 11.15.0 zip dereferenced them,
                      // breaking Catalyst codesign).
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.6/grpcpp.xcframework.zip",
                      checksum: "9a86a314b22c45d07f3fd29905a5c5376f3d6bfa3f56a12262332fdc05519171"),
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

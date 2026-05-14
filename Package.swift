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
//   - `_FirebaseFirestore` source target (Swift wrapper). Underscored. Its
//     product is exported as `FirebaseFirestore`; consumers add a
//     moduleAlias to see it under the unprefixed name.
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
        // Product name is `Firestore` (not `FirebaseFirestore`) to avoid a
        // PIF-level product-name collision with firebase-ios-sdk, which also
        // ships a product named `FirebaseFirestore`. Consumers depend on
        // this product with a moduleAlias mapping our `_FirebaseFirestore`
        // target's module to `FirebaseFirestore`, so consumer code keeps
        // using the standard `import FirebaseFirestore`:
        //
        //   .product(name: "Firestore",
        //            package: "firebase-firestore-xcframeworks",
        //            moduleAliases: ["_FirebaseFirestore": "FirebaseFirestore"])
        .library(name: "Firestore", targets: ["_FirebaseFirestore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "11.15.0"),
        .package(url: "https://github.com/firebase/nanopb.git", "2.30910.0" ..< "2.30911.0"),
    ],
    targets: [
        // MARK: - Local binaryTargets

        .binaryTarget(name: "firestore_absl",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/absl.xcframework.zip",
                      checksum: "959a61d05f95f831193454282a90c32cb167aaeb22abfd2b636c915c0b9e8bf3"),
        .binaryTarget(name: "firestore_openssl_grpc",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/openssl_grpc.xcframework.zip",
                      checksum: "b0a0b744a3699bf741b7ada2a2892e1d8f3d0d4b40bf509685ee0916060236b2"),
        .binaryTarget(name: "firestore_grpc",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/grpc.xcframework.zip",
                      checksum: "bfca1a75fa2bf4bb4b7963edbe0889f77c031f2507ac5a7235b6576e122d3f21"),
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
            name: "_FirebaseFirestore",
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

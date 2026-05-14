// swift-tools-version:5.9
// SPM overlay for firebase-ios-sdk 11.15.0, replacing FirebaseFirestore on
// every platform — including visionOS — with locally-built binaryTargets.
// No source compile on consumer's machine. Same instant link as iOS today.
//
// 6 binaryTargets for the native deps (absl, openssl_grpc, grpc, grpcpp,
// leveldb, nanopb) + FirebaseFirestoreInternal which combines Google's
// untouched iOS/macOS/Catalyst/tvOS slices with our two visionOS slices
// (xros-arm64, xros-arm64-simulator) built from Firestore's C++ source.
//
// HACK — openssl_grpc modulemap module name was renamed `BoringSSL-GRPC` →
// `openssl_grpc` in every slice via `scripts/normalize-openssl-grpc-modulemap.sh`.
// CocoaPods historically named the module `BoringSSL-GRPC` but the framework
// dir on disk is `openssl_grpc.framework`. Clang rejects hyphens in module
// identifiers; the rename allows direct SPM source-target deps without
// changing any binary symbols. Re-run the normalize script if the xcframework
// is rebuilt or its iOS slices refreshed from Google's release.

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
        .library(name: "FirebaseFirestore", targets: ["FirebaseFirestore"]),
        .library(name: "FirebaseCore", targets: ["FirebaseCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleUtilities.git", "8.1.0" ..< "9.0.0"),
        .package(url: "https://github.com/firebase/nanopb.git", "2.30910.0" ..< "2.30911.0"),
    ],
    targets: [
        // MARK: - Local binaryTargets (visionOS slices baked in)

        .binaryTarget(name: "absl",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/absl.xcframework.zip",
                      checksum: "959a61d05f95f831193454282a90c32cb167aaeb22abfd2b636c915c0b9e8bf3"),
        .binaryTarget(name: "openssl_grpc",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/openssl_grpc.xcframework.zip",
                      checksum: "b0a0b744a3699bf741b7ada2a2892e1d8f3d0d4b40bf509685ee0916060236b2"),
        .binaryTarget(name: "grpc",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/grpc.xcframework.zip",
                      checksum: "bfca1a75fa2bf4bb4b7963edbe0889f77c031f2507ac5a7235b6576e122d3f21"),
        .binaryTarget(name: "grpcpp",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/grpcpp.xcframework.zip",
                      checksum: "fb07719d3313e99f729de9f2f26fafbe141d7288ff89c60a0c576480b8d8caef"),
        .binaryTarget(name: "leveldb",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/leveldb.xcframework.zip",
                      checksum: "72c900231e7880febd6172f9ecea89eff5893a7b19c02bab256e1162f6015014"),
        .binaryTarget(name: "FirebaseFirestoreInternal",
                      url: "https://github.com/arthurschiller/firebase-firestore-xcframeworks/releases/download/11.15.0/FirebaseFirestoreInternal.xcframework.zip",
                      checksum: "4ac88cf4607aff62e75f62833d70cc6415f47bb7e063e737946c25e7d9ce9a2c"),

        // MARK: - Firebase umbrella + Core

        .target(
            name: "Firebase",
            path: "CoreOnly/Sources",
            publicHeadersPath: "./"
        ),
        .target(
            name: "FirebaseCore",
            dependencies: [
                "Firebase",
                "FirebaseCoreInternal",
                .product(name: "GULEnvironment", package: "GoogleUtilities"),
                .product(name: "GULLogger", package: "GoogleUtilities"),
            ],
            path: "FirebaseCore/Sources",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            publicHeadersPath: "Public",
            cSettings: [
                .headerSearchPath("../.."),
                .define("Firebase_VERSION", to: firebaseVersion),
            ],
            linkerSettings: [
                .linkedFramework("UIKit", .when(platforms: [.iOS, .macCatalyst, .tvOS, .visionOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "FirebaseCoreExtension",
            path: "FirebaseCore/Extension",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("../../"),
            ]
        ),
        .target(
            name: "FirebaseCoreInternal",
            dependencies: [
                .product(name: "GULNSData", package: "GoogleUtilities"),
            ],
            path: "FirebaseCore/Internal/Sources",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "FirebaseSharedSwift",
            path: "FirebaseSharedSwift/Sources",
            exclude: [
                "third_party/FirebaseDataEncoder/LICENSE",
                "third_party/FirebaseDataEncoder/METADATA",
            ]
        ),

        // MARK: - Firestore (binary path on all platforms)

        // ObjC wrapper target that re-exports the binary's public headers.
        // The Swift sources in `Firestore/Swift/Source/` `@_exported import
        // FirebaseFirestoreInternalWrapper` when SWIFT_PACKAGE is defined
        // (always true under SPM), so this target name must exist.
        // Mirrors upstream's binary-path wrapper.
        .target(
            name: "FirebaseFirestoreInternalWrapper",
            dependencies: [.target(
                name: "FirebaseFirestoreInternal",
                condition: .when(platforms: [.iOS, .macCatalyst, .tvOS, .macOS, .visionOS])
            )],
            path: "FirebaseFirestoreInternal",
            publicHeadersPath: "."
        ),

        .target(
            name: "FirebaseFirestore",
            dependencies: [
                "FirebaseCore",
                "FirebaseCoreExtension",
                "FirebaseFirestoreInternalWrapper",
                "FirebaseSharedSwift",
                "absl",
                "grpc",
                "grpcpp",
                "openssl_grpc",
                "leveldb",
                .product(name: "nanopb", package: "nanopb"),
            ],
            path: "Firestore/Swift/Source",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("SystemConfiguration", .when(platforms: [.iOS, .macOS, .tvOS, .visionOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .visionOS])),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)

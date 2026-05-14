// swift-tools-version:5.9
// SOURCE-COMPILE MANIFEST — used only by scripts/build-firestore-internal.sh
// to produce the visionOS object files that get libtool'd into
// FirebaseFirestoreInternal.xcframework. The script swaps this in for the
// main Package.swift, runs xcodebuild, then swaps the main one back.
//
// Never resolved by consumers. Do not edit unless you also keep the main
// (binary-path) Package.swift in sync — the target signatures must match.

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
        .library(name: "FirebaseFirestoreInternalWrapper",
                 targets: ["FirebaseFirestoreInternalWrapper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleUtilities.git", "8.1.0" ..< "9.0.0"),
        .package(url: "https://github.com/firebase/nanopb.git", "2.30910.0" ..< "2.30911.0"),
    ],
    targets: [
        .binaryTarget(name: "absl",        path: "build/artifacts/absl/absl.xcframework"),
        .binaryTarget(name: "openssl_grpc", path: "build/artifacts/openssl_grpc/openssl_grpc.xcframework"),
        .binaryTarget(name: "grpc",        path: "build/artifacts/grpc/grpc.xcframework"),
        .binaryTarget(name: "grpcpp",      path: "build/artifacts/grpcpp/grpcpp.xcframework"),
        .binaryTarget(name: "leveldb",     path: "build/artifacts/leveldb/leveldb.xcframework"),

        .target(name: "Firebase",
                path: "CoreOnly/Sources",
                publicHeadersPath: "./"),
        .target(name: "FirebaseCoreInternal",
                dependencies: [.product(name: "GULNSData", package: "GoogleUtilities")],
                path: "FirebaseCore/Internal/Sources",
                resources: [.process("Resources/PrivacyInfo.xcprivacy")]),
        .target(name: "FirebaseCore",
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
                ]),
        .target(name: "FirebaseAppCheckInterop",
                path: "FirebaseAppCheck/Interop",
                exclude: ["CMakeLists.txt"],
                publicHeadersPath: "Public",
                cSettings: [.headerSearchPath("../../")]),
        .target(name: "FirebaseAuthInterop",
                path: "FirebaseAuth/Interop",
                exclude: ["CMakeLists.txt"],
                publicHeadersPath: "Public",
                cSettings: [.headerSearchPath("../../")]),

        .target(
            name: "FirebaseFirestoreInternalWrapper",
            dependencies: [
                "FirebaseAppCheckInterop",
                "FirebaseAuthInterop",
                "FirebaseCore",
                "leveldb",
                .product(name: "nanopb", package: "nanopb"),
                "absl",
                "grpc",
                "grpcpp",
                "openssl_grpc",
            ],
            path: "Firestore",
            exclude: [
                "CHANGELOG.md",
                "CMakeLists.txt",
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
                "test.sh",
                "third_party/",
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
                .linkedFramework("SystemConfiguration",
                                 .when(platforms: [.iOS, .macOS, .tvOS, .visionOS])),
                .linkedFramework("UIKit",
                                 .when(platforms: [.iOS, .tvOS, .visionOS])),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)

// swift-tools-version:5.9
// TestConsumer: validates merged xcframeworks via C/C++ shims that exercise
// real library APIs from Swift on iOS sim / macOS / Catalyst / visionOS sim.
//
// Note: openssl_grpc is a transitive-only dependency (consumed by grpc /
// grpcpp / Firestore C++ — never directly from source code). Its modulemap
// uses a hyphenated module name that Clang can't parse if a source target
// tries to depend on it directly. So we don't declare a shim for it here;
// Phase 3 (gRPC) and Phase 4 (Firestore) will exercise it transitively.
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
    ],
    cxxLanguageStandard: .cxx17
)

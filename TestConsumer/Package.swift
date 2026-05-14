// swift-tools-version:5.9
// Phase 1 TestConsumer: validates the merged absl.xcframework resolves +
// links + runs on each target platform via a C++ shim wrapping absl::StrCat.
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
            cxxSettings: [
                .headerSearchPath("."),
            ]
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

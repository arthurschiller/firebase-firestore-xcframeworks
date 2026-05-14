// swift-tools-version:5.9
// Stub — grown incrementally per phase. Final shape mirrors firebase-ios-sdk's Package.swift
// at the pinned upstream version, with 5 binaryTargets repointed at this repo's releases.
import PackageDescription

let package = Package(
    name: "firebase-firestore-xcframeworks",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .visionOS(.v1),
        .watchOS(.v7),
    ],
    products: [],
    targets: []
)

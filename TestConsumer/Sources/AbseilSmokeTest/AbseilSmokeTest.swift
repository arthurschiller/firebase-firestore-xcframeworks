// Phase 1 smoke test: TestConsumer declares absl.xcframework as a
// binaryTarget dependency. Reaching successful compile on each platform
// proves SPM resolved the right slice per target. Real C++/linker
// validation lands in Phase 4 when Firestore C++ links against absl.
public enum AbseilSmokeTest {
    public static let resolved: Bool = true
}

import XCTest
@testable import AbseilCxxShim

final class AbseilSmokeTestTests: XCTestCase {
    func testStrCatLengthMatchesNaiveConcatenation() {
        // "hello" (5) + "world" (5) = 10
        let len = absl_shim_strcat_len("hello", "world")
        XCTAssertEqual(len, 10)
    }

    func testStrCatEmptyInputs() {
        let len = absl_shim_strcat_len("", "")
        XCTAssertEqual(len, 0)
    }

    func testStrCatNumericConcatenation() {
        // Just exercises the codepath again with different sizes
        let len = absl_shim_strcat_len("abcdefghij", "klmno")
        XCTAssertEqual(len, 15)
    }
}

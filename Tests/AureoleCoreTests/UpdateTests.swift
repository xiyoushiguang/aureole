import XCTest
@testable import AureoleCore

final class UpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.3.1", than: "0.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.3.0", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.2.1", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.4.0", than: "dev"))        // dev builds never nag
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "0.3.0"))
    }
}

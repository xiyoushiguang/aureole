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

    func testDmgAssetAndTeam() {
        let rel: [String: Any] = ["assets": [["name": "notes.txt", "browser_download_url": "https://github.com/a/b/notes.txt"],
                                             ["name": "Aureole-0.5.0.dmg", "browser_download_url": "https://github.com/x/aureole/releases/download/v0.5.0/Aureole-0.5.0.dmg"]]]
        XCTAssertEqual(UpdateChecker.dmgAsset(rel)?.lastPathComponent, "Aureole-0.5.0.dmg")
        XCTAssertNil(UpdateChecker.dmgAsset(["assets": [["name": "a.dmg", "browser_download_url": "https://evil.example/a.dmg"]]]))
        XCTAssertEqual(UpdateChecker.teamIdentifier(inCodesignOutput: "Identifier=app\nTeamIdentifier=49KHQQ9Y53\n"), "49KHQQ9Y53")
        XCTAssertNil(UpdateChecker.teamIdentifier(inCodesignOutput: "TeamIdentifier=not set"))
    }
}

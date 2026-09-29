import XCTest
@testable import AureoleCore

final class DecoderTests: XCTestCase {
    override func setUp() { L10n.language = .english }
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testClaudeDecode() throws {
        let snap = try ClaudeUsageDecoder.decode(try fixture("claude_usage"), plan: "max")
        XCTAssertEqual(snap.provider, .claude)
        XCTAssertEqual(snap.planLabel, "Max")
        XCTAssertEqual(snap.session?.usedPercent, 23.5)
        XCTAssertEqual(snap.session?.duration, 5 * 3600)
        XCTAssertEqual(snap.weekly?.usedPercent, 41.2)
        XCTAssertEqual(snap.session?.resetsAt, ISO8601DateFormatter().date(from: "2026-09-27T05:00:00Z"))
        // null opus, null extra_usage and the reset-less codename window are dropped; scoped weeks come from `limits`
        XCTAssertEqual(snap.extras.map(\.label).sorted(), ["Fable wk", "Sonnet wk"])
        XCTAssertEqual(snap.extras.first { $0.label == "Fable wk" }?.usedPercent, 6)
        XCTAssertEqual(snap.windows.first?.kind, .fiveHour)
    }

    func testCodexDecode() throws {
        let snap = try CodexUsageDecoder.decode(try fixture("codex_usage"))
        XCTAssertEqual(snap.planLabel, "Plus")
        XCTAssertEqual(CodexUsageDecoder.planName("prolite"), "Pro Lite")
        XCTAssertEqual(snap.session?.usedPercent, 17)
        XCTAssertEqual(snap.session?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(snap.weekly?.usedPercent, 52)
        XCTAssertEqual(snap.weekly?.duration, 604800)
        XCTAssertEqual(snap.extras.count, 1)
        XCTAssertEqual(snap.extras.first?.label, "gpt-5-codex 5h")
    }

    func testCodexCredentialsParse() throws {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_1","chatgpt_plan_type":"plus"}}"#
        let b64 = Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let json = #"{"tokens":{"access_token":"tok","id_token":"h.\#(b64).s"}}"#
        let creds = try CodexCredentialReader.parse(Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "tok")
        XCTAssertEqual(creds.accountID, "acct_1")
        XCTAssertEqual(creds.planFromToken, "plus")
    }

    func testClaudeCredentialsParse() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1790000000000,"subscriptionType":"max"}}"#
        let creds = try ClaudeCredentialReader.parse(Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "abc")
        XCTAssertEqual(creds.subscriptionType, "max")
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testHexDecode() {
        XCTAssertEqual(Data(hexString: "7b7d"), Data("{}".utf8))
        XCTAssertNil(Data(hexString: "zz"))
    }
}

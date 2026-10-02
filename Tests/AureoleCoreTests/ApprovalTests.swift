import XCTest
@testable import AureoleCore

final class ApprovalTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func request(_ id: String, expiresIn: TimeInterval) -> ApprovalRequest {
        let now = Date()
        return ApprovalRequest(id: id, sessionId: "s1", provider: .claude, tool: "Bash", full: "rm -rf build",
                               at: now, expires: now.addingTimeInterval(expiresIn))
    }

    func testFullTextIsNeverShortened() {
        let long = String(repeating: "x", count: 5000)
        XCTAssertEqual(ApprovalRequest.fullText(tool: "Bash", input: ["command": long]).count, 5000)
        XCTAssertEqual(ApprovalRequest.fullText(tool: "shell", input: ["command": ["bash", "-lc", "npm test"]]), "bash -lc npm test")
        let edit = ApprovalRequest.fullText(tool: "Edit", input: ["file_path": "/a/b.swift", "old_string": "x", "new_string": "y"])
        XCTAssertTrue(edit.hasPrefix("/a/b.swift\n"))
        XCTAssertTrue(edit.contains("\"new_string\" : \"y\""))
    }

    func testDecisionOnlyForAnOpenRequest() throws {
        try ApprovalFiles.save(request("t1", expiresIn: 30), in: dir)
        XCTAssertEqual(ApprovalFiles.pending(in: dir).map(\.id), ["t1"])
        XCTAssertFalse(ApprovalFiles.decide("other", .allow, in: dir))         // no such request
        XCTAssertTrue(ApprovalFiles.decide("t1", .deny, in: dir))
        XCTAssertEqual(ApprovalFiles.wait(for: "t1", until: Date().addingTimeInterval(1), in: dir, poll: 0.05), .deny)
        ApprovalFiles.remove("t1", in: dir)
        XCTAssertTrue(ApprovalFiles.pending(in: dir).isEmpty)

        try ApprovalFiles.save(request("old", expiresIn: -1), in: dir)          // the hook already gave up
        XCTAssertFalse(ApprovalFiles.decide("old", .allow, in: dir))
        XCTAssertNil(ApprovalFiles.wait(for: "none", until: Date().addingTimeInterval(0.2), in: dir, poll: 0.05))
    }

    func testHookOutputShape() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(ApprovalDecision.allow.hookOutput.utf8)) as! [String: Any]
        let out = obj["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(out["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((out["decision"] as! [String: Any])["behavior"] as? String, "allow")
        XCTAssertTrue(ApprovalDecision.deny.hookOutput.contains("\"behavior\":\"deny\""))
    }

    func testPermissionRequestGetsTheLongerTimeout() {
        let merged = HookInstaller.merge(settings: [:], helperPath: "/h/aureole-hook", install: true)
        func timeout(_ e: String) -> Int? {
            (((merged["hooks"] as! [String: Any])[e] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]["timeout"] as? Int
        }
        XCTAssertEqual(timeout("PermissionRequest"), 120)
        XCTAssertEqual(timeout("PreToolUse"), 5)
    }
}

import XCTest
@testable import AureoleCore

final class AgentScanTests: XCTestCase {
    func testProcessNames() {
        XCTAssertEqual(KnownApps.provider(forProcessName: "claude"), .claude)
        XCTAssertEqual(KnownApps.provider(forProcessName: "codex"), .codex)
        XCTAssertEqual(KnownApps.provider(forProcessName: "claude.exe"), .claude)   // npm's native binary
        XCTAssertNil(KnownApps.provider(forProcessName: "Claude"))                  // the desktop app itself
        XCTAssertNil(KnownApps.provider(forProcessName: "Claude Helper"))
        XCTAssertNil(KnownApps.provider(forProcessName: "zsh"))
    }

    func testWhereAnAgentRuns() {
        var codex = AgentFinding(provider: .codex)
        codex.desktopApps = ["com.openai.codex"]
        XCTAssertTrue(codex.usesDesktop)
        XCTAssertFalse(codex.usesTerminal)
        codex.addRunning(["com.openai.codex", "com.apple.Terminal", "com.openai.codex", nil])
        XCTAssertEqual(codex.runningIn, ["com.openai.codex", "com.apple.Terminal"])
        XCTAssertTrue(codex.usesTerminal && codex.usesDesktop)

        var claude = AgentFinding(provider: .claude)
        claude.cliPath = "/x/bin/claude"
        XCTAssertTrue(claude.installed && claude.usesTerminal)
        XCTAssertFalse(AgentFinding(provider: .claude).installed)
    }

    func testOutermostApp() {
        XCTAssertEqual(ProcessTree.outermostApp(inPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
                       "/Applications/ChatGPT.app")
        XCTAssertNil(ProcessTree.outermostApp(inPath: "/usr/local/bin/codex"))
    }
}

import XCTest
@testable import ClaudeStatusBar

final class HookInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HookInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsURL = tempDir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSettings(_ json: String) throws {
        try json.data(using: .utf8)!.write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - currentInstallation

    func testCurrentInstallationReturnsNilWhenSettingsAbsent() throws {
        XCTAssertNil(try HookInstaller.currentInstallation(settingsURL: settingsURL))
    }

    func testCurrentInstallationReturnsNilWhenNoPermissionRequestHook() throws {
        try writeSettings(#"{"hooks": {"PreToolUse": []}}"#)
        XCTAssertNil(try HookInstaller.currentInstallation(settingsURL: settingsURL))
    }

    func testCurrentInstallationParsesExistingEntry() throws {
        try writeSettings(#"""
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {"type":"command","command":"/Applications/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBarHook","timeout":600}
                ]
              }
            ]
          }
        }
        """#)
        let cfg = try XCTUnwrap(HookInstaller.currentInstallation(settingsURL: settingsURL))
        XCTAssertEqual(cfg.hookSpec["command"] as? String, "/Applications/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBarHook")
        XCTAssertEqual(cfg.hookSpec["timeout"] as? Int, 600)
        XCTAssertEqual(cfg.hookSpec["type"] as? String, "command")
    }

    func testCurrentInstallationPreservesArbitraryFields() throws {
        // 用户在 hook spec 里加了 async/env/什么 → currentInstallation 必须原样回吐。
        try writeSettings(#"""
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {"type":"command","command":"/path/ClaudeStatusBarHook","timeout":600,"async":true,"env":{"FOO":"bar"}}
                ]
              }
            ]
          }
        }
        """#)
        let cfg = try XCTUnwrap(HookInstaller.currentInstallation(settingsURL: settingsURL))
        XCTAssertEqual(cfg.hookSpec["async"] as? Bool, true)
        XCTAssertEqual((cfg.hookSpec["env"] as? [String: Any])?["FOO"] as? String, "bar")
    }

    func testCurrentInstallationIgnoresUnrelatedHooksInSameArray() throws {
        // audit-hook + 我们的 hook 共存。应只识别我们的。
        try writeSettings(#"""
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {"type":"command","command":"node /path/audit-hook.mjs","timeout":5,"async":true},
                  {"type":"command","command":"/Apps/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBarHook","timeout":600}
                ]
              }
            ]
          }
        }
        """#)
        let cfg = try XCTUnwrap(HookInstaller.currentInstallation(settingsURL: settingsURL))
        XCTAssertTrue((cfg.hookSpec["command"] as? String)?.contains("ClaudeStatusBarHook") ?? false)
    }

    // MARK: - install (fresh)

    func testInstallCreatesSettingsWhenAbsent() throws {
        try HookInstaller.install(.default, settingsURL: settingsURL)
        let root = try readSettings()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let pr = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let inner = try XCTUnwrap(pr.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.first?["command"] as? String, HookInstaller.Configuration.defaultBundleCommand)
        XCTAssertEqual(inner.first?["timeout"] as? Int, 600)
        XCTAssertEqual(inner.first?["type"] as? String, "command")
    }

    func testInstallCreatesPermissionRequestKeyWhenHooksObjectExistsButKeyAbsent() throws {
        try writeSettings(#"{"hooks": {"PreToolUse": [{"hooks":[{"type":"command","command":"foo"}]}]}, "tui": "fullscreen"}"#)
        try HookInstaller.install(.default, settingsURL: settingsURL)
        let root = try readSettings()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"], "其他 hook 必须保留")
        XCTAssertNotNil(hooks["PermissionRequest"], "PermissionRequest 必须新建")
        XCTAssertEqual(root["tui"] as? String, "fullscreen", "顶层非 hooks 字段必须保留")
    }

    // MARK: - install (preserve other hooks)

    func testInstallPreservesUnrelatedHookInSameArray() throws {
        try writeSettings(#"""
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {"type":"command","command":"node /path/audit-hook.mjs","timeout":5,"async":true}
                ]
              }
            ]
          }
        }
        """#)
        try HookInstaller.install(.default, settingsURL: settingsURL)

        let root = try readSettings()
        let pr = try XCTUnwrap(((root["hooks"] as? [String: Any])?["PermissionRequest"]) as? [[String: Any]])
        let inner = try XCTUnwrap(pr.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.count, 2, "audit-hook 必须保留 + 我们的 hook 追加")
        XCTAssertTrue(inner.contains(where: { ($0["command"] as? String)?.contains("audit-hook") == true }))
        XCTAssertTrue(inner.contains(where: { ($0["command"] as? String)?.contains("ClaudeStatusBarHook") == true }))
    }

    // MARK: - install (replace existing)

    func testInstallReplacesExistingClaudeStatusBarHookEntry() throws {
        try writeSettings(#"""
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {"type":"command","command":"/old/path/ClaudeStatusBarHook","timeout":300}
                ]
              }
            ]
          }
        }
        """#)
        let newConfig = HookInstaller.Configuration(hookSpec: [
            "type": "command",
            "command": "/Users/dev/.build/debug/ClaudeStatusBarHook",
            "timeout": 120,
        ])
        try HookInstaller.install(newConfig, settingsURL: settingsURL)

        let cfg = try XCTUnwrap(HookInstaller.currentInstallation(settingsURL: settingsURL))
        XCTAssertEqual(cfg.hookSpec["command"] as? String, "/Users/dev/.build/debug/ClaudeStatusBarHook")
        XCTAssertEqual(cfg.hookSpec["timeout"] as? Int, 120)

        // 数组里只剩一条 — 替换不是追加
        let root = try readSettings()
        let pr = try XCTUnwrap(((root["hooks"] as? [String: Any])?["PermissionRequest"]) as? [[String: Any]])
        let inner = try XCTUnwrap(pr.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.count, 1)
    }

    func testInstallReplacesOursAlongsideAuditHook() throws {
        try writeSettings(#"""
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {"type":"command","command":"node /path/audit-hook.mjs","timeout":5,"async":true},
                  {"type":"command","command":"/old/path/ClaudeStatusBarHook","timeout":300}
                ]
              }
            ]
          }
        }
        """#)
        let newConfig = HookInstaller.Configuration(hookSpec: [
            "type": "command",
            "command": "/new/path/ClaudeStatusBarHook",
            "timeout": 900,
        ])
        try HookInstaller.install(newConfig, settingsURL: settingsURL)

        let root = try readSettings()
        let pr = try XCTUnwrap(((root["hooks"] as? [String: Any])?["PermissionRequest"]) as? [[String: Any]])
        let inner = try XCTUnwrap(pr.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.count, 2)
        XCTAssertTrue(inner.contains(where: { ($0["command"] as? String) == "node /path/audit-hook.mjs" }), "audit-hook 不能丢")
        XCTAssertTrue(inner.contains(where: { ($0["command"] as? String) == "/new/path/ClaudeStatusBarHook" }), "我们的 hook 必须更新")
    }

    // MARK: - backup + atomicity

    func testInstallWritesBackupOfPreviousSettings() throws {
        try writeSettings(#"{"foo":"bar"}"#)
        try HookInstaller.install(.default, settingsURL: settingsURL)
        let backupURL = settingsURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let backupData = try Data(contentsOf: backupURL)
        let backupRoot = try JSONSerialization.jsonObject(with: backupData) as! [String: Any]
        XCTAssertEqual(backupRoot["foo"] as? String, "bar", "备份必须是改动前的内容")
    }

    func testInstallSkipsBackupWhenNoPriorFile() throws {
        try HookInstaller.install(.default, settingsURL: settingsURL)
        let backupURL = settingsURL.appendingPathExtension("bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    // MARK: - error paths

    func testInstallThrowsOnMalformedJSON() throws {
        try "not json {".data(using: .utf8)!.write(to: settingsURL)
        XCTAssertThrowsError(try HookInstaller.install(.default, settingsURL: settingsURL)) { err in
            guard case HookInstaller.InstallError.parseFailed = err else {
                XCTFail("Expected parseFailed, got \(err)"); return
            }
        }
    }

    func testCurrentInstallationThrowsOnMalformedJSON() throws {
        try "not json {".data(using: .utf8)!.write(to: settingsURL)
        XCTAssertThrowsError(try HookInstaller.currentInstallation(settingsURL: settingsURL))
    }

    // MARK: - Configuration.parse / prettyJSON

    func testConfigurationParseAndPrettyJSONRoundTrip() throws {
        let pretty = HookInstaller.Configuration.default.prettyJSON()
        XCTAssertTrue(pretty.contains("\"command\""))
        XCTAssertTrue(pretty.contains("ClaudeStatusBarHook"))
        XCTAssertTrue(pretty.contains("\n"), "pretty 必须多行,UI 编辑器才看得清")

        let cfg = try HookInstaller.Configuration.parse(jsonString: pretty)
        XCTAssertEqual(cfg.hookSpec["command"] as? String,
                       HookInstaller.Configuration.defaultBundleCommand)
        XCTAssertEqual(cfg.hookSpec["timeout"] as? Int, 600)
    }

    func testConfigurationParseRejectsInvalidJSON() {
        XCTAssertThrowsError(try HookInstaller.Configuration.parse(jsonString: "{ broken")) { err in
            guard case HookInstaller.InstallError.parseFailed = err else {
                XCTFail("Expected parseFailed, got \(err)"); return
            }
        }
    }

    func testConfigurationParseRejectsMissingCommand() {
        XCTAssertThrowsError(try HookInstaller.Configuration.parse(
            jsonString: #"{"type":"command","timeout":600}"#
        )) { err in
            guard case HookInstaller.InstallError.unexpectedSchema = err else {
                XCTFail("Expected unexpectedSchema, got \(err)"); return
            }
        }
    }

    func testConfigurationParseRejectsCommandWithoutMarker() {
        // 用户改坏了 command,把我们的 marker 删了 — 这条以后会找不回来,提前拒。
        XCTAssertThrowsError(try HookInstaller.Configuration.parse(
            jsonString: #"{"type":"command","command":"/some/other/binary","timeout":600}"#
        )) { err in
            guard case HookInstaller.InstallError.unexpectedSchema = err else {
                XCTFail("Expected unexpectedSchema, got \(err)"); return
            }
        }
    }

    func testInstallPersistsArbitraryFields() throws {
        // 用户在 UI 加了 async: true,install 必须原样保留。
        let config = HookInstaller.Configuration(hookSpec: [
            "type": "command",
            "command": "/path/ClaudeStatusBarHook",
            "timeout": 600,
            "async": true,
        ])
        try HookInstaller.install(config, settingsURL: settingsURL)

        let root = try readSettings()
        let pr = try XCTUnwrap(((root["hooks"] as? [String: Any])?["PermissionRequest"]) as? [[String: Any]])
        let inner = try XCTUnwrap(pr.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.first?["async"] as? Bool, true)
    }
}

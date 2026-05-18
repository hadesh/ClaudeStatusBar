import Foundation

/// 把 ClaudeStatusBarHook 注册到 ~/.claude/settings.json 的
/// `hooks.PermissionRequest` 数组里,**保留**用户已有的其他 hooks(audit-hook、
/// rtk-rewrite 等)。识别"我们这条"的方法:command 字符串包含 marker
/// `ClaudeStatusBarHook`(支持用户自定路径,只要末段是这个文件名就行)。
///
/// 写入流程:
/// 1. 读 settings.json → 解析 JSON;不存在则视为空 `{}`
/// 2. mutate `hooks.PermissionRequest` 数组(找到我们的 entry 替换,否则追加)
/// 3. 写 `.bak`(每次覆盖式;原子性不重要 — 只是 belt-and-braces)
/// 4. 写到 `.tmp` → `rename` 到 `settings.json`(原子)
///
/// 解析失败 / 写入失败抛 `InstallError`,UI 显示错误。
public enum HookInstaller {

    /// 一份完整的 hook spec(将原样作为 PermissionRequest 数组里某条 entry 的
    /// `hooks[i]`)。允许任意字段(`type`/`command`/`timeout`/`async`/...),
    /// `install` 不解构 — 用户在 UI 文本框里改成什么样我们就原样写下去。
    /// 唯一硬要求:`command` 字段存在且包含 marker `ClaudeStatusBarHook`,
    /// 否则后续无法识别"我们这条"做替换。
    public struct Configuration {
        public var hookSpec: [String: Any]

        public init(hookSpec: [String: Any]) {
            self.hookSpec = hookSpec
        }

        public static let defaultBundleCommand = "/Applications/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBarHook"
        public static let defaultTimeoutSeconds = 600

        /// 识别 command 字符串是否指向我们的 helper。比 `==` 宽松一档:
        /// 路径末段是 `ClaudeStatusBarHook` 即视为我们这条,这样用户改了路径
        /// (例如 dev 模式跑 `.build/debug/ClaudeStatusBarHook`)还能匹配上。
        public static let commandMarker = "ClaudeStatusBarHook"

        public static let `default` = Configuration(hookSpec: [
            "type": "command",
            "command": defaultBundleCommand,
            "timeout": defaultTimeoutSeconds,
        ])

        /// PreToolUse hook 的默认 timeout(秒)。与 PermissionPromptStore.timeout
        /// (300s)对齐 — 浮窗超时后让 helper 也被 kill,CLI 终端 select 接管。
        public static let defaultPreToolUseTimeoutSeconds = 300

        /// PreToolUse 默认配置。matcher 在 install 路径里写死 AskUserQuestion,
        /// 这里只装 hookSpec 本体。
        public static let defaultPreToolUse = Configuration(hookSpec: [
            "type": "command",
            "command": defaultBundleCommand,
            "timeout": defaultPreToolUseTimeoutSeconds,
        ])

        /// 漂亮印刷形式,给 UI 多行编辑框做初始内容用。换行 + key 排序 + 不
        /// escape `/`(看起来更清爽)。
        public func prettyJSON() -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: hookSpec,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ), let s = String(data: data, encoding: .utf8) else {
                return ""
            }
            return s
        }

        /// 反向从 UI 文本框拿一段 JSON 字符串。校验 root 是 object 且
        /// `command` 字段含 marker;否则报错(防止用户把整条 hook 改没了)。
        public static func parse(jsonString: String) throws -> Configuration {
            let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8) else {
                throw InstallError.parseFailed("不是合法 UTF-8")
            }
            let obj: Any
            do {
                obj = try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                throw InstallError.parseFailed(error.localizedDescription)
            }
            guard let dict = obj as? [String: Any] else {
                throw InstallError.unexpectedSchema("根节点必须是 JSON object")
            }
            guard let command = dict["command"] as? String, !command.isEmpty else {
                throw InstallError.unexpectedSchema("缺少 `command` 字段")
            }
            guard command.contains(commandMarker) else {
                throw InstallError.unexpectedSchema("`command` 必须包含 \(commandMarker),否则无法被识别为本 app 的 hook")
            }
            return Configuration(hookSpec: dict)
        }
    }

    public enum InstallError: Error, Equatable {
        case readFailed(String)
        case parseFailed(String)
        case unexpectedSchema(String)
        case writeFailed(String)
    }

    /// 默认 settings 文件位置:`~/.claude/settings.json`。
    public static var defaultSettingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    /// 读出当前已安装的 ClaudeStatusBar hook(如果有)。返回 nil = 未安装。
    /// 抛错只在 settings.json 存在但格式损坏时发生。
    public static func currentInstallation(settingsURL: URL = defaultSettingsURL) throws -> Configuration? {
        guard let root = try readSettings(at: settingsURL) else { return nil }
        guard let hooks = root["hooks"] as? [String: Any],
              let permissionRequest = hooks["PermissionRequest"] as? [[String: Any]]
        else { return nil }
        for entry in permissionRequest {
            guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
            for hook in inner {
                guard let command = hook["command"] as? String,
                      command.contains(Configuration.commandMarker)
                else { continue }
                return Configuration(hookSpec: hook)
            }
        }
        return nil
    }

    /// 把 `config` 安装/更新到 settings.json。已有我们的 entry 就替换,否则追加。
    /// 总是写一份 `.bak`(覆盖最近一次的合法状态),原子 rename 写主文件。
    public static func install(_ config: Configuration, settingsURL: URL = defaultSettingsURL) throws {
        var root = (try readSettings(at: settingsURL)) ?? [:]

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var permissionRequest = (hooks["PermissionRequest"] as? [[String: Any]]) ?? []

        let ourHook = config.hookSpec

        var replaced = false

        // PermissionRequest 是 array<{hooks: array<hookSpec>}>。我们扫一遍,
        // 看哪个 entry 的 hooks 数组里有"我们的"那一条 → 替换。否则追加到
        // 第一个 entry(或新建一个 entry)。
        for i in permissionRequest.indices {
            guard var entry = permissionRequest[i] as? [String: Any],
                  var inner = entry["hooks"] as? [[String: Any]]
            else { continue }
            for j in inner.indices {
                if let cmd = inner[j]["command"] as? String,
                   cmd.contains(Configuration.commandMarker) {
                    inner[j] = ourHook
                    entry["hooks"] = inner
                    permissionRequest[i] = entry
                    replaced = true
                    break
                }
            }
            if replaced { break }
        }

        if !replaced {
            if permissionRequest.isEmpty {
                permissionRequest = [["hooks": [ourHook]]]
            } else if var firstEntry = permissionRequest[0] as? [String: Any] {
                var inner = (firstEntry["hooks"] as? [[String: Any]]) ?? []
                inner.append(ourHook)
                firstEntry["hooks"] = inner
                permissionRequest[0] = firstEntry
            } else {
                // 第一个 entry 形态异常 — 兜底:在数组末尾新建一个我们的 entry
                permissionRequest.append(["hooks": [ourHook]])
            }
        }

        hooks["PermissionRequest"] = permissionRequest
        root["hooks"] = hooks

        try writeSettings(root, to: settingsURL)
    }

    // MARK: - PreToolUse 路径(代答 AskUserQuestion)

    /// PreToolUse hook 在 settings.json 里以 matcher=AskUserQuestion 锚定。
    /// 我们用「matcher == AskUserQuestion AND inner.command 含 marker」双锚定
    /// 识别"自己的"那条,避免误覆盖用户在 PreToolUse 上挂的别的 matcher entry。
    public static let preToolUseMatcher = "AskUserQuestion"

    /// 读出当前 PreToolUse 路径上已安装的 ClaudeStatusBar hook(matcher=AskUserQuestion)。
    /// 返回 nil = 未安装。
    public static func currentPreToolUseInstallation(
        settingsURL: URL = defaultSettingsURL
    ) throws -> Configuration? {
        guard let root = try readSettings(at: settingsURL) else { return nil }
        guard let hooks = root["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]]
        else { return nil }
        for entry in preToolUse {
            guard (entry["matcher"] as? String) == preToolUseMatcher,
                  let inner = entry["hooks"] as? [[String: Any]]
            else { continue }
            for hook in inner {
                guard let command = hook["command"] as? String,
                      command.contains(Configuration.commandMarker)
                else { continue }
                return Configuration(hookSpec: hook)
            }
        }
        return nil
    }

    /// 把 `config` 安装/更新到 settings.json 的 PreToolUse 数组,matcher 写死
    /// AskUserQuestion。已有「matcher=AskUserQuestion + ClaudeStatusBarHook」
    /// entry 就替换;否则追加一个新 matcher entry(不和用户已有的 Bash matcher
    /// 等共用 entry,这样 uninstall 时只删自己那一行)。
    public static func installPreToolUse(
        _ config: Configuration,
        settingsURL: URL = defaultSettingsURL
    ) throws {
        var root = (try readSettings(at: settingsURL)) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var preToolUse = (hooks["PreToolUse"] as? [[String: Any]]) ?? []

        let ourHook = config.hookSpec
        var replaced = false

        for i in preToolUse.indices {
            guard var entry = preToolUse[i] as? [String: Any],
                  (entry["matcher"] as? String) == preToolUseMatcher,
                  var inner = entry["hooks"] as? [[String: Any]]
            else { continue }
            for j in inner.indices {
                if let cmd = inner[j]["command"] as? String,
                   cmd.contains(Configuration.commandMarker) {
                    inner[j] = ourHook
                    entry["hooks"] = inner
                    preToolUse[i] = entry
                    replaced = true
                    break
                }
            }
            if replaced { break }
        }

        if !replaced {
            preToolUse.append([
                "matcher": preToolUseMatcher,
                "hooks": [ourHook],
            ])
        }

        hooks["PreToolUse"] = preToolUse
        root["hooks"] = hooks
        try writeSettings(root, to: settingsURL)
    }

    // MARK: - Private I/O

    private static func readSettings(at url: URL) throws -> [String: Any]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw InstallError.readFailed(error.localizedDescription)
        }
        if data.isEmpty { return nil }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw InstallError.parseFailed(error.localizedDescription)
        }
        guard let dict = parsed as? [String: Any] else {
            throw InstallError.unexpectedSchema("root is not a JSON object")
        }
        return dict
    }

    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw InstallError.writeFailed("encode: \(error.localizedDescription)")
        }

        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 备份(已存在的话)
        if fm.fileExists(atPath: url.path) {
            let backupURL = url.appendingPathExtension("bak")
            _ = try? fm.removeItem(at: backupURL)
            do {
                try fm.copyItem(at: url, to: backupURL)
            } catch {
                // 备份失败不致命 — 继续写,只是少一份保险
            }
        }

        // atomic: 写到 .tmp,然后 rename。FileManager 的 atomic 选项也行,
        // 但我们要保证跟 backup 同目录(同分区),所以手撸更稳。
        let tmpURL = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.moveItem(at: tmpURL, to: url)
        } catch {
            _ = try? fm.removeItem(at: tmpURL)
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}

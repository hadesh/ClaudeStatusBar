import Foundation

/// 应用内所有键盘快捷键的元数据中心 —— 单一数据源。
///
/// 设计意图:
/// - **元数据集中**:组合键(modifiers + key)、显示文本、作用域、说明文本都从这里取,
///   消除调用点散落硬编码导致的漂移。MenuController / PermissionPromptPanelManager /
///   MenuBuilder 仍然各自负责注册生命周期,但参数从 catalog 读。
/// - **Foundation only**:Carbon 与 AppKit 的转换分别放在 `KeyCombo+Carbon.swift`
///   (Services/,沿用 GlobalHotkey 的硬例外)和 `KeyCombo+AppKit.swift`(UI/),
///   保持本文件不污染依赖图。
/// - **只读**:本期 catalog 是常量,后续若要支持自定义快捷键,在外面包一层
///   UserDefaults-backed store + 冲突检测即可,不必改本文件结构。

public struct ShortcutModifiers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option  = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift   = ShortcutModifiers(rawValue: 1 << 3)

    /// macOS HIG 顺序:⌃⌥⇧⌘。
    public var displayString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option)  { out += "⌥" }
        if contains(.shift)   { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

public enum ShortcutKey: Hashable {
    /// 字母键,一律小写存储。
    case letter(Character)
    case comma
    case `return`
    case escape

    public var displayString: String {
        switch self {
        case .letter(let c): return String(c).uppercased()
        case .comma:         return ","
        case .return:        return "⏎"
        case .escape:        return "⎋"
        }
    }
}

public struct KeyCombo: Hashable {
    public let modifiers: ShortcutModifiers
    public let key: ShortcutKey

    public init(modifiers: ShortcutModifiers, key: ShortcutKey) {
        self.modifiers = modifiers
        self.key = key
    }

    public var displayString: String { modifiers.displayString + key.displayString }
}

public enum ShortcutScope: Hashable {
    case global
    case menu
    case panel

    public var label: String {
        switch self {
        case .global: return "全局"
        case .menu:   return "菜单展开时"
        case .panel:  return "浮窗内"
        }
    }
}

public struct Shortcut: Hashable {
    /// 稳定 ID,UI 渲染时作为行标识。
    public let id: String
    public let title: String
    public let scope: ShortcutScope
    public let combo: KeyCombo
    public let note: String?

    public init(id: String, title: String, scope: ShortcutScope, combo: KeyCombo, note: String? = nil) {
        self.id = id
        self.title = title
        self.scope = scope
        self.combo = combo
        self.note = note
    }
}

public enum KeyboardShortcutCatalog {
    public static let toggleMenu = Shortcut(
        id: "toggleMenu",
        title: "打开 / 关闭状态栏菜单",
        scope: .global,
        combo: KeyCombo(modifiers: [.control, .shift], key: .letter("c"))
    )

    public static let allowPanel = Shortcut(
        id: "allowPanel",
        title: "允许权限请求",
        scope: .global,
        combo: KeyCombo(modifiers: [.control, .shift], key: .letter("y")),
        note: "仅在权限浮窗可见时生效,作用于最新一个浮窗"
    )

    public static let denyPanel = Shortcut(
        id: "denyPanel",
        title: "拒绝权限请求",
        scope: .global,
        combo: KeyCombo(modifiers: [.control, .shift], key: .letter("n")),
        note: "仅在权限浮窗可见时生效,作用于最新一个浮窗"
    )

    public static let openSettings = Shortcut(
        id: "openSettings",
        title: "打开偏好设置",
        scope: .menu,
        combo: KeyCombo(modifiers: .command, key: .comma)
    )

    public static let quit = Shortcut(
        id: "quit",
        title: "退出 ClaudeStatusBar",
        scope: .menu,
        combo: KeyCombo(modifiers: .command, key: .letter("q"))
    )

    public static let panelConfirm = Shortcut(
        id: "panelConfirm",
        title: "确认浮窗默认按钮",
        scope: .panel,
        combo: KeyCombo(modifiers: [], key: .return),
        note: "权限浮窗:允许;AskUserQuestion 浮窗:跳回终端答;Hook 编辑器:应用"
    )

    public static let panelCancel = Shortcut(
        id: "panelCancel",
        title: "拒绝 / 关闭浮窗",
        scope: .panel,
        combo: KeyCombo(modifiers: [], key: .escape),
        note: "权限浮窗:拒绝"
    )

    public static let all: [Shortcut] = [
        toggleMenu,
        allowPanel,
        denyPanel,
        openSettings,
        quit,
        panelConfirm,
        panelCancel,
    ]
}

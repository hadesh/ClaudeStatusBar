import AppKit

/// `KeyCombo` 到 NSMenuItem 入参的转换。
///
/// 放在 UI 层是为了让 `Services/KeyboardShortcutCatalog.swift` 保持 Foundation-only。
/// 凡是要把 catalog 元数据落到 NSMenuItem 的地方,统一走 `applyToMenuItem(_:)`,
/// 避免直接操作 `keyEquivalent` / `keyEquivalentModifierMask` 时漏赋 mask
/// (NSMenuItem 的 `addItem(withTitle:action:keyEquivalent:)` 默认就给 ⌘ mask,
/// 不显式赋值会跟 catalog 脱钩)。

extension ShortcutModifiers {
    public var nsEventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.control) { flags.insert(.control) }
        if contains(.option)  { flags.insert(.option) }
        if contains(.shift)   { flags.insert(.shift) }
        return flags
    }
}

extension ShortcutKey {
    /// NSMenuItem.keyEquivalent 用的字符串。一律小写;Shift 通过 modifier mask 表达,
    /// 不通过大小写隐式表达 —— 后者会跟 macOS 默认行为冲突。
    public var menuKeyEquivalent: String {
        switch self {
        case .letter(let c): return String(c).lowercased()
        case .comma:         return ","
        case .return:        return "\r"
        case .escape:        return "\u{1B}"
        }
    }
}

extension KeyCombo {
    public func applyToMenuItem(_ item: NSMenuItem) {
        item.keyEquivalent = key.menuKeyEquivalent
        item.keyEquivalentModifierMask = modifiers.nsEventFlags
    }
}

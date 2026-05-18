import Carbon.HIToolbox

/// `KeyCombo` 到 Carbon `RegisterEventHotKey` 入参的转换。
///
/// 本文件是 Services 层 Foundation-only 约定的硬例外,理由跟 `GlobalHotkey.swift`
/// 一样:Carbon 是 macOS 全局热键的唯一可行路径。把转换层放这里、不放
/// `KeyboardShortcutCatalog.swift`,是为了让调用方(MenuController / Permission-
/// PromptPanelManager)只依赖纯整数,自身不再 import Carbon.HIToolbox。

extension ShortcutModifiers {
    /// `cmdKey | shiftKey | optionKey | controlKey` 组合,直接喂给 `RegisterEventHotKey`。
    public var carbonValue: Int {
        var v = 0
        if contains(.command) { v |= cmdKey }
        if contains(.control) { v |= controlKey }
        if contains(.option)  { v |= optionKey }
        if contains(.shift)   { v |= shiftKey }
        return v
    }
}

extension ShortcutKey {
    /// Carbon 物理键位码(`kVK_ANSI_*` 等)。
    /// 注意:Carbon 用物理键位,Dvorak 等非 ANSI 布局下用户敲的不是字面字母 ——
    /// 这是已知限制,跟改造前现状一致。
    public var carbonKeyCode: Int {
        switch self {
        case .letter(let c):
            switch Character(String(c).lowercased()) {
            case "c": return kVK_ANSI_C
            case "n": return kVK_ANSI_N
            case "q": return kVK_ANSI_Q
            case "y": return kVK_ANSI_Y
            default:
                // 当前 catalog 只用到 c/n/q/y 四个字母。后续新增字母时在此扩展。
                fatalError("ShortcutKey.letter(\(c)) 未在 carbonKeyCode 表中登记")
            }
        case .comma:  return kVK_ANSI_Comma
        case .return: return kVK_Return
        case .escape: return kVK_Escape
        }
    }
}

extension KeyCombo {
    public var carbonKeyCode: Int { key.carbonKeyCode }
    public var carbonModifiers: Int { modifiers.carbonValue }
}

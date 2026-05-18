import XCTest
@testable import ClaudeStatusBar

final class KeyboardShortcutCatalogTests: XCTestCase {

    // MARK: - Catalog 唯一性 / 完整性

    func test_all_包含全部7个快捷键且id唯一() {
        let all = KeyboardShortcutCatalog.all
        XCTAssertEqual(all.count, 7)
        XCTAssertEqual(Set(all.map(\.id)).count, 7)
    }

    func test_all_包含每个静态条目() {
        let ids = Set(KeyboardShortcutCatalog.all.map(\.id))
        XCTAssertTrue(ids.contains(KeyboardShortcutCatalog.toggleMenu.id))
        XCTAssertTrue(ids.contains(KeyboardShortcutCatalog.allowPanel.id))
        XCTAssertTrue(ids.contains(KeyboardShortcutCatalog.denyPanel.id))
        XCTAssertTrue(ids.contains(KeyboardShortcutCatalog.openSettings.id))
        XCTAssertTrue(ids.contains(KeyboardShortcutCatalog.quit.id))
        XCTAssertTrue(ids.contains(KeyboardShortcutCatalog.panelConfirm.id))
        XCTAssertTrue(ids.contains(KeyboardShortcutCatalog.panelCancel.id))
    }

    // MARK: - displayString

    func test_modifiers_displayString_按macOS_HIG顺序() {
        // HIG 标准:Control, Option, Shift, Command(⌃⌥⇧⌘)
        let all: ShortcutModifiers = [.command, .control, .option, .shift]
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘")

        XCTAssertEqual(ShortcutModifiers([.control, .shift]).displayString, "⌃⇧")
        XCTAssertEqual(ShortcutModifiers.command.displayString, "⌘")
        XCTAssertEqual(ShortcutModifiers([]).displayString, "")
    }

    func test_key_displayString_字母键大写_特殊键用图形() {
        XCTAssertEqual(ShortcutKey.letter("c").displayString, "C")
        XCTAssertEqual(ShortcutKey.letter("y").displayString, "Y")
        XCTAssertEqual(ShortcutKey.comma.displayString, ",")
        XCTAssertEqual(ShortcutKey.return.displayString, "⏎")
        XCTAssertEqual(ShortcutKey.escape.displayString, "⎋")
    }

    func test_combo_displayString_组合modifier和key() {
        XCTAssertEqual(KeyboardShortcutCatalog.toggleMenu.combo.displayString, "⌃⇧C")
        XCTAssertEqual(KeyboardShortcutCatalog.allowPanel.combo.displayString, "⌃⇧Y")
        XCTAssertEqual(KeyboardShortcutCatalog.denyPanel.combo.displayString, "⌃⇧N")
        XCTAssertEqual(KeyboardShortcutCatalog.openSettings.combo.displayString, "⌘,")
        XCTAssertEqual(KeyboardShortcutCatalog.quit.combo.displayString, "⌘Q")
        XCTAssertEqual(KeyboardShortcutCatalog.panelConfirm.combo.displayString, "⏎")
        XCTAssertEqual(KeyboardShortcutCatalog.panelCancel.combo.displayString, "⎋")
    }

    // MARK: - scope label

    func test_scope_label_中文() {
        XCTAssertEqual(ShortcutScope.global.label, "全局")
        XCTAssertEqual(ShortcutScope.menu.label, "菜单展开时")
        XCTAssertEqual(ShortcutScope.panel.label, "浮窗内")
    }

    // MARK: - Carbon 转换(硬编码 Int,不 import Carbon)

    func test_modifiers_carbonValue_对应Carbon常量() {
        // cmdKey=0x100, controlKey=0x1000, optionKey=0x800, shiftKey=0x200
        XCTAssertEqual(ShortcutModifiers.command.carbonValue, 0x100)
        XCTAssertEqual(ShortcutModifiers.control.carbonValue, 0x1000)
        XCTAssertEqual(ShortcutModifiers.option.carbonValue,  0x800)
        XCTAssertEqual(ShortcutModifiers.shift.carbonValue,   0x200)
        XCTAssertEqual(ShortcutModifiers([.control, .shift]).carbonValue, 0x1000 | 0x200)
    }

    func test_key_carbonKeyCode_对应Carbon物理键位() {
        // kVK_ANSI_C=0x08, Y=0x10, N=0x2D, Comma=0x2B, Return=0x24, Escape=0x35
        XCTAssertEqual(ShortcutKey.letter("c").carbonKeyCode, 0x08)
        XCTAssertEqual(ShortcutKey.letter("y").carbonKeyCode, 0x10)
        XCTAssertEqual(ShortcutKey.letter("n").carbonKeyCode, 0x2D)
        XCTAssertEqual(ShortcutKey.comma.carbonKeyCode,       0x2B)
        XCTAssertEqual(ShortcutKey.return.carbonKeyCode,      0x24)
        XCTAssertEqual(ShortcutKey.escape.carbonKeyCode,      0x35)
    }

    func test_toggleMenu_combo_对应GlobalHotkey注册值() {
        // 守住改造前的现状:MenuController 注册 keyCode=kVK_ANSI_C, modifiers=controlKey|shiftKey
        let combo = KeyboardShortcutCatalog.toggleMenu.combo
        XCTAssertEqual(combo.carbonKeyCode, 0x08)
        XCTAssertEqual(combo.carbonModifiers, 0x1000 | 0x200)
    }

    func test_allowPanel_combo_对应GlobalHotkey注册值() {
        let combo = KeyboardShortcutCatalog.allowPanel.combo
        XCTAssertEqual(combo.carbonKeyCode, 0x10)
        XCTAssertEqual(combo.carbonModifiers, 0x1000 | 0x200)
    }

    func test_denyPanel_combo_对应GlobalHotkey注册值() {
        let combo = KeyboardShortcutCatalog.denyPanel.combo
        XCTAssertEqual(combo.carbonKeyCode, 0x2D)
        XCTAssertEqual(combo.carbonModifiers, 0x1000 | 0x200)
    }
}

import XCTest
import AppKit
@testable import ClaudeStatusBar

final class SettingsStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SettingsStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testReadsBuiltInDefaultsWhenUserDefaultsIsEmpty() {
        let store = SettingsStore(defaults: makeDefaults())

        XCTAssertEqual(store.workingColor.usingColorSpace(.sRGB)?.redComponent ?? 0,
                       SettingsStore.defaultWorkingColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(store.attentionColor.colorNameComponent,
                       SettingsStore.defaultAttentionColor.colorNameComponent)
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertEqual(store.reminderInterval, SettingsStore.defaultReminderInterval)
    }

    func testColorRoundTripsThroughHexEncoding() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let pink = NSColor(srgbRed: 0.97, green: 0.31, blue: 0.55, alpha: 1.0)
        store.workingColor = pink

        let reloaded = SettingsStore(defaults: defaults)
        let r = reloaded.workingColor.usingColorSpace(.sRGB)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.redComponent, 0.97, accuracy: 0.01)
        XCTAssertEqual(r!.greenComponent, 0.31, accuracy: 0.01)
        XCTAssertEqual(r!.blueComponent, 0.55, accuracy: 0.01)
    }

    func testReminderIntervalNilPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.reminderInterval = nil

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertNil(reloaded.reminderInterval)
    }

    func testNotificationsEnabledPersists() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.notificationsEnabled = false

        XCTAssertFalse(SettingsStore(defaults: defaults).notificationsEnabled)
    }
}

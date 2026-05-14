import AppKit
import Combine
import Foundation

public final class SettingsStore: ObservableObject {
    private enum Key {
        static let workingColor = "settings.workingColor"
        static let attentionColor = "settings.attentionColor"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let reminderIntervalSeconds = "settings.reminderIntervalSeconds"
    }

    public static let defaultWorkingColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.27, alpha: 1.0)
    public static let defaultAttentionColor = NSColor.systemYellow
    public static let defaultReminderInterval: TimeInterval = 30

    /// `< 0` means "已禁用提醒"。`UserDefaults` 没有原生 nil 标记。
    private static let disabledIntervalSentinel: TimeInterval = -1

    private let defaults: UserDefaults

    @Published public var workingColor: NSColor {
        didSet { defaults.set(Self.encodeColor(workingColor), forKey: Key.workingColor) }
    }

    @Published public var attentionColor: NSColor {
        didSet { defaults.set(Self.encodeColor(attentionColor), forKey: Key.attentionColor) }
    }

    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// `nil` = 不发送二次提醒。
    @Published public var reminderInterval: TimeInterval? {
        didSet {
            defaults.set(reminderInterval ?? Self.disabledIntervalSentinel, forKey: Key.reminderIntervalSeconds)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.workingColor = (defaults.string(forKey: Key.workingColor).flatMap(Self.decodeColor)) ?? Self.defaultWorkingColor
        self.attentionColor = (defaults.string(forKey: Key.attentionColor).flatMap(Self.decodeColor)) ?? Self.defaultAttentionColor
        self.notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        if let raw = defaults.object(forKey: Key.reminderIntervalSeconds) as? Double {
            self.reminderInterval = raw < 0 ? nil : raw
        } else {
            self.reminderInterval = Self.defaultReminderInterval
        }
    }

    public func resetColors() {
        workingColor = Self.defaultWorkingColor
        attentionColor = Self.defaultAttentionColor
    }

    static func encodeColor(_ color: NSColor) -> String {
        let rgba = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgba.redComponent * 255).rounded()).clamped(0, 255)
        let g = Int((rgba.greenComponent * 255).rounded()).clamped(0, 255)
        let b = Int((rgba.blueComponent * 255).rounded()).clamped(0, 255)
        let a = Int((rgba.alphaComponent * 255).rounded()).clamped(0, 255)
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }

    static func decodeColor(_ hex: String) -> NSColor? {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 24) & 0xFF) / 255
        let g = CGFloat((value >> 16) & 0xFF) / 255
        let b = CGFloat((value >> 8) & 0xFF) / 255
        let a = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

private extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self {
        min(max(self, low), high)
    }
}

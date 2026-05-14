import AppKit

public enum StatusIcon {
    public static func image(
        for status: AggregateStatus,
        working: NSColor = SettingsStore.defaultWorkingColor,
        attention: NSColor = SettingsStore.defaultAttentionColor
    ) -> NSImage {
        switch status {
        case .none, .idle:
            // 模板图,AppKit 按当前外观自动反相:浅色栏 → 深色 icon,深色栏 → 浅色 icon。
            return OctopusIcon.image(color: .black, isTemplate: true)
        case .working:
            return OctopusIcon.image(color: working, isTemplate: false)
        case .needsAttention:
            return OctopusIcon.image(color: attention, isTemplate: false)
        }
    }
}

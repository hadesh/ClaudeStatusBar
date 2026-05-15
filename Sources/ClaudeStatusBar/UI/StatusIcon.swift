import AppKit

public enum StatusIcon {
    public static func image(
        for status: AggregateStatus,
        working: NSColor = SettingsStore.defaultWorkingColor,
        attention: NSColor = SettingsStore.defaultAttentionColor,
        badgeCount: Int = 0,
        frameIndex: Int = 0
    ) -> NSImage {
        // badgeCount > 0 → 角标存在,必须非模板,否则红圈被 AppKit 反相成灰色。
        let templateAllowed = badgeCount == 0
        switch status {
        case .none, .idle:
            return OctopusIcon.image(
                color: .black, isTemplate: templateAllowed,
                badgeCount: badgeCount, frameIndex: frameIndex
            )
        case .working:
            return OctopusIcon.image(
                color: working, isTemplate: false,
                badgeCount: badgeCount, frameIndex: frameIndex
            )
        case .needsAttention:
            return OctopusIcon.image(
                color: attention, isTemplate: false,
                badgeCount: badgeCount, frameIndex: frameIndex
            )
        }
    }
}

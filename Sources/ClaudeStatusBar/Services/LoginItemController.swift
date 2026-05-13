import Foundation
import ServiceManagement

public final class LoginItemController {
    /// SMAppService.mainApp only works inside a code-signed bundle. `swift run`
    /// starts without a bundle identifier, so we hide the menu item there.
    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

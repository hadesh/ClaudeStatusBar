import Cocoa
import Carbon.HIToolbox

/// Thin wrapper around Carbon's `RegisterEventHotKey`. The lifetime of the
/// instance owns the hotkey: deinit unregisters. AppKit's `NSEvent` monitor
/// can't intercept events delivered to other apps, so for "press anywhere"
/// shortcuts Carbon is still the only path.
public final class GlobalHotkey {
    public typealias Handler = () -> Void

    private let id: UInt32
    private let handler: Handler
    private var ref: EventHotKeyRef?

    /// Active hotkeys keyed by the per-instance id. The Carbon event handler
    /// is a `@convention(c)` function and can't capture Swift context, so we
    /// dispatch through this static registry.
    private static var registry: [UInt32: GlobalHotkey] = [:]
    private static var nextId: UInt32 = 1
    private static var handlerInstalled = false

    public init?(keyCode: Int, modifiers: Int, handler: @escaping Handler) {
        let assignedId = Self.nextId
        Self.nextId &+= 1
        self.id = assignedId
        self.handler = handler
        Self.installEventHandlerIfNeeded()
        let hkID = EventHotKeyID(signature: 0x43534241 /* "CSBA" */, id: assignedId)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hkID,
            GetApplicationEventTarget(), 0, &newRef
        )
        guard status == noErr, let newRef else {
            NSLog("GlobalHotkey RegisterEventHotKey failed: \(status)")
            return nil
        }
        self.ref = newRef
        Self.registry[assignedId] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.registry[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                if let hk = GlobalHotkey.registry[hkID.id] {
                    DispatchQueue.main.async { hk.handler() }
                }
                return noErr
            },
            1, &spec, nil, nil
        )
    }
}

import Cocoa
import Combine

/// Owns the collection of `PermissionPromptPanel`s for the in-flight requests.
/// Subscribes to `store.incoming` to spawn a panel per request and to
/// `store.resolved` so panels close even when the request was settled by
/// timeout or by the terminal prompt winning the race. Registers the
/// Ctrl+Shift+Y / Ctrl+Shift+N global hotkeys while at least one panel is
/// visible. All panel mutations happen on the main queue via the Combine
/// `receive(on:)` operator.
final class PermissionPromptPanelManager {
    private let store: PermissionPromptStore
    private let stack: FloatingPanelStack
    private var entries: [(id: String, panel: PermissionPromptPanel)] = []
    private var cancellables = Set<AnyCancellable>()

    private var allowHotkey: GlobalHotkey?
    private var denyHotkey: GlobalHotkey?

    init(store: PermissionPromptStore, stack: FloatingPanelStack) {
        self.store = store
        self.stack = stack
        store.incoming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] req in self?.present(req) }
            .store(in: &cancellables)
        store.resolved
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.dismiss(id: id) }
            .store(in: &cancellables)
    }

    func present(_ request: PermissionPromptRequest) {
        // AskUserQuestion 走 PreToolUse hook + AskUserQuestionPanelManager 那条线;
        // helper 端 PermissionRequest+AskUserQuestion 直接 allow,理论上不会送到这里,
        // kind 过滤是双保险。
        guard request.kind == .permission else { return }
        guard !entries.contains(where: { $0.id == request.id }) else { return }
        let panel = PermissionPromptPanel(request: request) { [weak self] outcome in
            self?.handleResponse(id: request.id, outcome: outcome)
        }
        entries.append((request.id, panel))
        if entries.count == 1 {
            registerHotkeys()
        }
        stack.register(panel, owner: "permission:\(request.id)")
        panel.orderFrontRegardless()
    }

    func dismiss(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: idx).panel
        stack.unregister(panel)
        panel.orderOut(nil)
        panel.close()
        if entries.isEmpty {
            unregisterHotkeys()
        }
    }

    /// Resolves the **most recent** pending panel — what the user means by
    /// "the latest 气泡" when triggering the global hotkey.
    func resolveLatest(_ outcome: PermissionPromptPanel.Outcome) {
        guard let last = entries.last else { return }
        handleResponse(id: last.id, outcome: outcome)
    }

    // MARK: - Private

    private func handleResponse(id: String, outcome: PermissionPromptPanel.Outcome) {
        switch outcome {
        case .allow:
            store.resolveAllow(id: id)
        case .allowAlways:
            store.resolveAllowAlways(id: id)
        case .deny:
            store.resolveDeny(id: id, message: "User denied via status bar")
        case .abandon:
            store.abandon(id: id)
        }
    }

    private func registerHotkeys() {
        let allow = KeyboardShortcutCatalog.allowPanel.combo
        let deny = KeyboardShortcutCatalog.denyPanel.combo
        allowHotkey = GlobalHotkey(keyCode: allow.carbonKeyCode, modifiers: allow.carbonModifiers) { [weak self] in
            self?.resolveLatest(.allow)
        }
        denyHotkey = GlobalHotkey(keyCode: deny.carbonKeyCode, modifiers: deny.carbonModifiers) { [weak self] in
            self?.resolveLatest(.deny)
        }
    }

    private func unregisterHotkeys() {
        allowHotkey = nil
        denyHotkey = nil
    }
}

import Cocoa
import Combine
import Carbon.HIToolbox

/// Owns the collection of `PermissionPromptPanel`s for the in-flight requests.
/// Subscribes to `store.incoming` to spawn a panel per request and to
/// `store.resolved` so panels close even when the request was settled by
/// timeout or by the terminal prompt winning the race. Registers the
/// Ctrl+Shift+Y / Ctrl+Shift+N global hotkeys while at least one panel is
/// visible. All panel mutations happen on the main queue via the Combine
/// `receive(on:)` operator.
final class PermissionPromptPanelManager {
    private let store: PermissionPromptStore
    private var entries: [(id: String, panel: PermissionPromptPanel)] = []
    private var cancellables = Set<AnyCancellable>()

    private let edgeInset: CGFloat = 20
    private let stackGap: CGFloat = 12

    private var allowHotkey: GlobalHotkey?
    private var denyHotkey: GlobalHotkey?

    /// 这些工具不走常规 allow/deny 浮窗 —— `AskUserQuestion` 是结构化的多选题,
    /// 「允许 / 拒绝」按钮没语义。`AskUserQuestionPanelManager` 在同一条
    /// `store.incoming` 上单独订阅,给这些请求弹专属浮窗(只展示 + 跳回终端,
    /// 本期不代答)。本管理器对它们直接 early-return。
    static let toolsRoutedAwayFromPanel: Set<String> = ["AskUserQuestion"]

    init(store: PermissionPromptStore) {
        self.store = store
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
        guard !Self.toolsRoutedAwayFromPanel.contains(request.toolName) else { return }
        guard !entries.contains(where: { $0.id == request.id }) else { return }
        let panel = PermissionPromptPanel(request: request) { [weak self] outcome in
            self?.handleResponse(id: request.id, outcome: outcome)
        }
        entries.append((request.id, panel))
        if entries.count == 1 {
            registerHotkeys()
        }
        layout()
        panel.orderFrontRegardless()
    }

    func dismiss(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: idx).panel
        panel.orderOut(nil)
        panel.close()
        if entries.isEmpty {
            unregisterHotkeys()
        }
        layout()
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

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.maxX - PermissionPromptPanel.panelWidth - edgeInset
        var y = frame.maxY - edgeInset
        for (_, panel) in entries {
            y -= panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            y -= stackGap
        }
    }

    private func registerHotkeys() {
        let mods = controlKey | shiftKey
        allowHotkey = GlobalHotkey(keyCode: kVK_ANSI_Y, modifiers: mods) { [weak self] in
            self?.resolveLatest(.allow)
        }
        denyHotkey = GlobalHotkey(keyCode: kVK_ANSI_N, modifiers: mods) { [weak self] in
            self?.resolveLatest(.deny)
        }
    }

    private func unregisterHotkeys() {
        allowHotkey = nil
        denyHotkey = nil
    }
}

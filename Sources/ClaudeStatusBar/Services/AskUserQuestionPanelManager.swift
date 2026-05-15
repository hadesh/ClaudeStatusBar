import Cocoa
import Combine

/// 终端激活的注入点 —— 真实实现走 TerminalNavigator + NSRunningApplication;
/// 测试用 mock。manager 不直接依赖 NSApp / 跨进程逻辑,方便单测。
protocol TerminalActivating {
    func activate(forSessionId sessionId: String?, cwd: String?)
}

/// 订阅 PermissionPromptStore.incoming/resolved,过滤 toolName==AskUserQuestion
/// 并管理对应浮窗。与 PermissionPromptPanelManager 平行存在,各管各的窗位:
/// AskUserQuestion 浮窗固定右上,**不参与**权限浮窗的纵向堆叠队列。
final class AskUserQuestionPanelManager {
    private let store: PermissionPromptStore
    private let navigator: TerminalActivating
    private var entries: [(id: String, panel: AskUserQuestionPanel)] = []
    private var cancellables = Set<AnyCancellable>()

    private let edgeInset: CGFloat = 20
    private let stackGap: CGFloat = 12

    init(store: PermissionPromptStore, navigator: TerminalActivating) {
        self.store = store
        self.navigator = navigator
        store.incoming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] req in self?.present(req) }
            .store(in: &cancellables)
        store.resolved
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.dismiss(id: id) }
            .store(in: &cancellables)
    }

    // MARK: - Test Hooks

    var entryCountForTesting: Int { entries.count }
    func handleResponseForTesting(id: String, outcome: AskUserQuestionPanel.Outcome) {
        handleResponse(id: id, outcome: outcome)
    }

    // MARK: - Private

    private func present(_ request: PermissionPromptRequest) {
        guard request.toolName == "AskUserQuestion" else { return }
        guard !entries.contains(where: { $0.id == request.id }) else { return }
        let panel = AskUserQuestionPanel(request: request) { [weak self] outcome in
            self?.handleResponse(id: request.id, outcome: outcome)
        }
        entries.append((request.id, panel))
        layout()
        panel.orderFrontRegardless()
    }

    private func dismiss(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: idx).panel
        panel.orderOut(nil)
        panel.close()
        layout()
    }

    private func handleResponse(id: String, outcome: AskUserQuestionPanel.Outcome) {
        switch outcome {
        case .goToTerminal:
            // 顺序很关键:先抓 request 再 abandon —— abandon 会把 entry 移除,
            // 之后再去 entries 里取就拿不到 cwd/sessionId 了。
            let req = entries.first(where: { $0.id == id })?.panel.request
            navigator.activate(forSessionId: req?.sessionId, cwd: req?.cwd)
            store.abandon(id: id)
        case .abandon:
            store.abandon(id: id)
        }
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.maxX - AskUserQuestionPanel.panelWidth - edgeInset
        // 起点比 PermissionPromptPanelManager 低 80px,避免和权限浮窗叠死。
        var y = frame.maxY - edgeInset - 80
        for (_, panel) in entries {
            y -= panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            y -= stackGap
        }
    }
}

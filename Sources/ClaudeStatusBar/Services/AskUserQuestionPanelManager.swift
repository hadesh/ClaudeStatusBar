import Cocoa
import Combine

/// 订阅 PermissionPromptStore.incoming/resolved,过滤 toolName==AskUserQuestion
/// 并管理对应浮窗。与 PermissionPromptPanelManager 平行存在,各管各的窗位:
/// AskUserQuestion 浮窗固定右上,**不参与**权限浮窗的纵向堆叠队列。
final class AskUserQuestionPanelManager {
    private let store: PermissionPromptStore
    private let stack: FloatingPanelStack
    private let navigator: TerminalActivating
    private var entries: [(id: String, panel: AskUserQuestionPanel)] = []
    private var cancellables = Set<AnyCancellable>()

    init(store: PermissionPromptStore, stack: FloatingPanelStack, navigator: TerminalActivating) {
        self.store = store
        self.stack = stack
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
        guard request.kind == .askUserQuestion else { return }
        guard !entries.contains(where: { $0.id == request.id }) else { return }
        let panel = AskUserQuestionPanel(request: request) { [weak self] outcome in
            self?.handleResponse(id: request.id, outcome: outcome)
        }
        entries.append((request.id, panel))
        stack.register(panel, owner: "askq:\(request.id)")
        panel.orderFrontRegardless()
    }

    private func dismiss(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: idx).panel
        stack.unregister(panel)
        panel.orderOut(nil)
        panel.close()
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
        case .submit(let answers):
            // 用户在浮窗里答完。把 answers 包进 AskUserQuestionOutput 形态喂给
            // helper 当作 PreToolUse hook 的 updatedInput,CLI 直接 short-circuit
            // 工具执行,跳过终端 select。schema: sdk-tools.d.ts:2620-2798。
            guard let req = entries.first(where: { $0.id == id })?.panel.request else { return }
            var merged: [String: JSONValue] = [:]
            merged["questions"] = req.input["questions"] ?? .array([])
            merged["answers"] = .object(answers.mapValues { .string($0) })
            store.resolve(id: id, decision: .allow(id: id, input: merged))
        }
    }

}

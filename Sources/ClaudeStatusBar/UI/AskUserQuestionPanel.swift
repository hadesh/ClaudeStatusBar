import Cocoa

/// 解析 AskUserQuestion 工具的 input 字段。结构是
/// `{questions: [{question: string, options: [{value, label, description?}]}]}`,
/// schema 漂移时返回 nil 让上层降级到「仅显示 toolName + 跳回终端」。
struct AskUserQuestionInput {
    struct Option {
        let value: String?
        let label: String
        let description: String?
    }
    struct Question {
        let question: String
        let options: [Option]
    }
    let questions: [Question]

    static func parse(_ request: PermissionPromptRequest) -> AskUserQuestionInput? {
        guard case .array(let qs)? = request.input["questions"], !qs.isEmpty else {
            return nil
        }
        let questions: [Question] = qs.compactMap { qVal in
            guard case .object(let q) = qVal,
                  case .string(let text)? = q["question"]
            else { return nil }
            let opts: [Option]
            if case .array(let optArr)? = q["options"] {
                opts = optArr.compactMap { oVal in
                    guard case .object(let o) = oVal,
                          case .string(let label)? = o["label"]
                    else { return nil }
                    let value: String? = {
                        if case .string(let v)? = o["value"] { return v }
                        return nil
                    }()
                    let desc: String? = {
                        if case .string(let d)? = o["description"] { return d }
                        return nil
                    }()
                    return Option(value: value, label: label, description: desc)
                }
            } else {
                opts = []
            }
            return Question(question: text, options: opts)
        }
        return questions.isEmpty ? nil : AskUserQuestionInput(questions: questions)
    }
}

// UI 部分在 Task 8 补。

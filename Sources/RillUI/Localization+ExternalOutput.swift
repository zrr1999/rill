import RillCore

enum WorkflowExternalOutputField {
    case webhookURL
    case webhookHeadersJSON
    case shortcutName
    case markdownAppendPath
}

enum WorkflowExternalOutputValidationMessage {
    case webhookUnavailable
    case shortcutNameRequired
    case markdownPathRequired
    case markdownPathInvalid
}

extension UIStrings {
    static func externalOutputField(_ field: WorkflowExternalOutputField, language: AppLanguage) -> String {
        switch (language, field) {
        case (.english, .webhookURL): return "Webhook URL"
        case (.simplifiedChinese, .webhookURL): return "Webhook URL"
        case (.english, .webhookHeadersJSON): return "Headers JSON (optional)"
        case (.simplifiedChinese, .webhookHeadersJSON): return "请求头 JSON（可选）"
        case (.english, .shortcutName): return "Shortcut Name"
        case (.simplifiedChinese, .shortcutName): return "快捷指令名称"
        case (.english, .markdownAppendPath): return "Markdown File Path"
        case (.simplifiedChinese, .markdownAppendPath): return "Markdown 文件路径"
        }
    }

    static func externalOutputHint(
        _ destination: WorkflowEditorDraft.DestinationChoice,
        language: AppLanguage
    ) -> String {
        switch (language, destination) {
        case (.english, .sendToWebhook): return "Webhook output is unavailable until its endpoint and headers use secure storage."
        case (.simplifiedChinese, .sendToWebhook): return "Webhook 端点和请求头迁入安全存储前，此输出不可用。"
        case (.english, .runShortcut): return "Runs a macOS Shortcut and passes the final text as input."
        case (.simplifiedChinese, .runShortcut): return "运行 macOS 快捷指令，并把最终文本作为输入。"
        case (.english, .appendToMarkdown):
            return "Atomically appends to an Obsidian-compatible note in an existing folder. Linked paths and files over 64 MiB are rejected."
        case (.simplifiedChinese, .appendToMarkdown):
            return "原子追加到现有文件夹中的 Obsidian 兼容笔记；拒绝链接路径和超过 64 MiB 的文件。"
        default: return ""
        }
    }

    static func externalOutputValidationMessage(
        _ message: WorkflowExternalOutputValidationMessage,
        language: AppLanguage
    ) -> String {
        switch (language, message) {
        case (.english, .webhookUnavailable): return "Webhook workflows are unavailable until endpoint and header credentials use secure storage."
        case (.simplifiedChinese, .webhookUnavailable): return "Webhook 端点和请求头凭据迁入安全存储前，不能保存此工作流。"
        case (.english, .shortcutNameRequired): return "Enter a Shortcut name before saving."
        case (.simplifiedChinese, .shortcutNameRequired): return "保存前请填写快捷指令名称。"
        case (.english, .markdownPathRequired): return "Enter a Markdown file path before saving."
        case (.simplifiedChinese, .markdownPathRequired): return "保存前请填写 Markdown 文件路径。"
        case (.english, .markdownPathInvalid): return "Markdown file path must end in .md or .markdown."
        case (.simplifiedChinese, .markdownPathInvalid): return "Markdown 文件路径必须以 .md 或 .markdown 结尾。"
        }
    }
}

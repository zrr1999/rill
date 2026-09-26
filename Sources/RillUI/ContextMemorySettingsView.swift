import RillCore
import SwiftUI

struct ContextMemorySettingsView: View {
    @Bindable var memory: ContextMemoryModel
    let workflows: [WorkflowDefinition]
    let language: AppLanguage
    @Binding var isExpanded: Bool
    @State private var pendingScreen = false
    @State private var pendingMemory = false
    @State private var pendingVocabulary = false
    @State private var showConsent = false
    @State private var showMemories = false

    private func text(_ english: String, _ chinese: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    var body: some View {
        DisclosureGroup(text("Context correction & memory", "上下文纠错与记忆"), isExpanded: $isExpanded) {
            Text(text("Speech remains the only content source. References help correct recognition errors.",
                      "语音识别正文是唯一内容主体；参考仅用于纠正识别错误。"))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(text("Use vocabulary for Smart Cleanup", "润色使用词库"), isOn: Binding(
                get: { memory.settings.vocabularyCorrectionEnabled },
                set: { propose(screen: memory.settings.screenContextEnabled, memoryEnabled: memory.settings.memoryEnabled, vocabulary: $0) }
            )).accessibilityIdentifier("settings.context.vocabulary")
            Text(text("Applicable hotwords are shared with the current LLM for new Smart Cleanup recordings, including words that do not fit the ASR budget.",
                      "新录音的 Smart Cleanup 会向当前 LLM 提供适用热词，包括 ASR 预算装不下的词。"))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(text("Screen context", "屏幕上下文"), isOn: Binding(
                get: { memory.settings.screenContextEnabled },
                set: { propose(screen: $0, memoryEnabled: memory.settings.memoryEnabled, vocabulary: memory.settings.vocabularyCorrectionEnabled) }
            )).accessibilityIdentifier("settings.context.screen")
            Toggle(text("Long-term memory & idle organization", "长期记忆与空闲整理"), isOn: Binding(
                get: { memory.settings.memoryEnabled },
                set: { propose(screen: memory.settings.screenContextEnabled, memoryEnabled: $0, vocabulary: memory.settings.vocabularyCorrectionEnabled) }
            )).accessibilityIdentifier("settings.context.memory")
            if memory.settings.screenContextEnabled && !memory.hasScreenPermission {
                Text(text("Screen Recording permission is unavailable; recordings continue without a screenshot.",
                          "屏幕录制权限不可用，录音会跳过截图。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !memory.isAuthorized && (memory.settings.screenContextEnabled || memory.settings.memoryEnabled || memory.settings.vocabularyCorrectionEnabled) {
                Button(text("Authorize current provider", "授权当前服务")) {
                    propose(screen: memory.settings.screenContextEnabled, memoryEnabled: memory.settings.memoryEnabled, vocabulary: memory.settings.vocabularyCorrectionEnabled)
                }
            }
            HStack {
                Button(text("Manage memories", "管理记忆")) { showMemories = true }
                Button(text("Organize when idle", "下次空闲时整理")) { memory.scheduleMaintenance() }
                    .disabled(!memory.isAuthorized || !memory.settings.memoryEnabled)
                Text("\(memory.status.requestsToday)/8 " + text("background requests today", "今日后台请求"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(memory.status.foregroundRequestsToday) " + text("foreground summary requests today (main corrections appear in history)", "今日前台摘要请求（主纠错请求见历史）"))
                .font(.caption).foregroundStyle(.secondary)
            if let error = memory.error { Text(L10n.contextMemoryFailure(error).string(for: language)).font(.caption).foregroundStyle(.red) }
        }
        .disabled(memory.isLoading || memory.isSaving)
        .confirmationDialog(text("Authorize context processing", "授权上下文处理"), isPresented: $showConsent) {
            Button(text("Enable for these voice workflows", "为这些语音工作流开启")) {
                memory.apply(screen: pendingScreen, memory: pendingMemory, workflowIDs: Set(consentWorkflows.map(\.id)), vocabulary: pendingVocabulary)
            }
            Button(text("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(consentMessage)
        }
        .sheet(isPresented: $showMemories) { MemoryManagementView(model: memory, language: language) }
        .task { await memory.refresh() }
    }

    private var consentWorkflows: [WorkflowDefinition] {
        pendingScreen || pendingMemory ? workflows : workflows.filter(\.supportsVocabularyCorrection)
    }

    private var consentMessage: String {
        var parts: [String] = []
        if pendingVocabulary {
            parts.append(text("Smart Cleanup sends its applicable hotwords to the current LLM as correction references. No screen or history access is needed. Reference terms are not copied into history.",
                              "Smart Cleanup 将适用热词发送给当前 LLM 作为纠错参考，无需访问屏幕或历史，也不会将参考词表复制到历史中。"))
        }
        if pendingScreen {
            parts.append(text("The current LLM receives the pre-recording image and its optional summary. Screen summaries are encrypted locally.",
                              "当前 LLM 将收到录音前图片及可选摘要，屏幕摘要在本地加密保存。"))
        }
        if pendingMemory {
            parts.append(text("The current LLM receives authorized voice history, explicit corrections and saved screen observations for idle organization, plus relevant terms and confirmed corrections during recordings. Memories survive history cleanup; deletion excludes their sources from relearning.",
                              "当前 LLM 将收到已授权的语音历史、明确纠正和已存屏幕观察，用于空闲整理；录音时还会接收相关术语和已确认纠正。记忆独立于历史留存，删除记忆会排除其来源，防止再次生成。"))
        }
        parts.append(text("Provider changes require authorization again. Workflows: ", "服务变更需重新授权。工作流：")
            + consentWorkflows.map(\.name).joined(separator: "、"))
        return parts.joined(separator: "\n\n")
    }

    private func propose(screen: Bool, memoryEnabled: Bool, vocabulary: Bool) {
        let isReducingScope = (!screen || memory.settings.screenContextEnabled)
            && (!memoryEnabled || memory.settings.memoryEnabled)
            && (!vocabulary || memory.settings.vocabularyCorrectionEnabled)
        if (!screen && !memoryEnabled && !vocabulary) || (isReducingScope && memory.isAuthorized) {
            memory.apply(screen: screen, memory: memoryEnabled, workflowIDs: memory.settings.authorizedWorkflowIDs, vocabulary: vocabulary)
        } else {
            pendingScreen = screen
            pendingMemory = memoryEnabled
            pendingVocabulary = vocabulary
            showConsent = true
        }
    }
}

private struct MemoryManagementView: View {
    @Bindable var model: ContextMemoryModel
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var editing: LongTermMemory?
    @State private var deleting: LongTermMemory?
    private func text(_ english: String, _ chinese: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    private func evidenceLabel(_ kind: MemoryEvidenceKind) -> String {
        switch kind {
        case .userStatement: text("User statement", "用户陈述")
        case .userCorrection: text("Explicit correction", "明确纠正")
        case .screenObservation: text("Screen observation", "屏幕观察")
        }
    }
    private func stateLabel(_ state: LongTermMemoryState) -> String {
        switch state {
        case .candidate: text("Needs confirmation", "待确认")
        case .active: text("Active", "使用中")
        case .archived: text("Archived", "已归档")
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(text("Long-term memories", "长期记忆")).font(.title2)
                Spacer()
                Button(text("Refresh", "刷新")) { Task { await model.refresh() } }
                Button(text("Done", "完成")) { dismiss() }
            }
            List(model.memories) { memory in
                VStack(alignment: .leading, spacing: 8) {
                    Text(memory.summary).textSelection(.enabled)
                    Text("\(evidenceLabel(memory.evidenceKind)) · \(stateLabel(memory.state)) · \(memory.sources.count) "
                         + text("sources", "条来源") + (memory.sourceHistoryDeleted ? text(" · history deleted", " · 原始历史已清理") : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(memory.corrections, id: \.self) { correction in
                        Text(correction.original + " → " + correction.corrected).font(.callout.monospaced())
                    }
                    if let replacedID = memory.replacesMemoryID {
                        Text(text("Proposed replacement: ", "拟替代：") + (model.memories.first { $0.id == replacedID }?.summary ?? replacedID.uuidString))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(text("Edit", "编辑")) { editing = memory }
                        Button(memory.confirmed ? text("Confirmed", "已确认") : text("Confirm", "确认")) {
                            var updated = memory; updated.confirm()
                            Task { await model.save(updated) }
                        }.disabled(memory.confirmed)
                        Button(memory.locked ? text("Unlock", "解锁") : text("Lock", "锁定")) {
                            var updated = memory; updated.locked.toggle()
                            Task { await model.save(updated) }
                        }
                        Button(memory.state == .archived ? text("Restore", "恢复") : text("Archive", "归档")) {
                            var updated = memory
                            updated.state = memory.state == .archived ? (memory.confirmed || memory.corrections.isEmpty ? .active : .candidate) : .archived
                            Task { await model.save(updated) }
                        }
                        Button(text("Delete", "删除"), role: .destructive) { deleting = memory }
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 8)
            }
            if let error = model.error { Text(L10n.contextMemoryFailure(error).string(for: language)).foregroundStyle(.red) }
        }.padding(20).frame(minWidth: 660, minHeight: 440)
            .task { await model.refresh() }
            .sheet(item: $editing) { memory in
                MemoryEditor(memory: memory, language: language) { edited in
                    await model.save(edited)
                }
            }
            .confirmationDialog(text("Permanently delete this memory and exclude its sources?", "永久删除记忆并排除其来源？"),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(text("Delete permanently", "永久删除"), role: .destructive) {
                    if let memory = deleting { Task { await model.delete(memory) } }
                    deleting = nil
                }
            }
    }
}

private struct MemoryEditor: View {
    @State var memory: LongTermMemory
    let language: AppLanguage
    let save: (LongTermMemory) async -> ContextMemoryMutationResult
    @State private var isSaving = false
    @State private var failure: ContextMemoryFailure?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            TextEditor(text: $memory.summary).frame(minHeight: 160)
            TextField(language == .simplifiedChinese ? "术语（用逗号分隔）" : "Terms (comma separated)", text: Binding(
                get: { memory.terms.joined(separator: ", ") },
                set: { memory.terms = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            Toggle(language == .simplifiedChinese ? "设置到期时间" : "Set expiry", isOn: Binding(
                get: { memory.expiresAt != nil }, set: { memory.expiresAt = $0 ? Date().addingTimeInterval(86_400) : nil }
            ))
            if memory.expiresAt != nil {
                DatePicker(language == .simplifiedChinese ? "到期后归档" : "Archive after", selection: Binding(
                    get: { memory.expiresAt ?? Date() }, set: { memory.expiresAt = $0 }
                ))
            }
            if let failure { Text(L10n.contextMemoryFailure(failure).string(for: language)).foregroundStyle(.red) }
            HStack {
                Button(language == .simplifiedChinese ? "取消" : "Cancel") { dismiss() }
                Button(language == .simplifiedChinese ? "保存并确认" : "Save & confirm") {
                    memory.confirm()
                    isSaving = true
                    Task {
                        let result = await save(memory)
                        isSaving = false
                        switch result {
                        case .saved: dismiss()
                        case .failed(let error): failure = error
                        case .stopped: failure = .unavailable
                        }
                    }
                }.disabled(!memory.isValid || isSaving)
            }
        }.padding(20).frame(width: 540)
            .interactiveDismissDisabled(isSaving)
    }
}

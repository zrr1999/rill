import RillCore
import SwiftUI

struct ContextMemorySettingsView: View {
    @Bindable var memory: ContextMemoryModel
    let workflows: [WorkflowDefinition]
    let language: AppLanguage
    @State private var pendingScreen = false
    @State private var pendingMemory = false
    @State private var showConsent = false
    @State private var showMemories = false

    private func text(_ english: String, _ chinese: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    var body: some View {
        DisclosureGroup(text("Context correction & memory", "上下文纠错与记忆")) {
            Text(text("Speech remains the only content source. References help correct recognition errors.",
                      "语音识别正文是唯一内容主体；参考仅用于纠正识别错误。"))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(text("Screen context", "屏幕上下文"), isOn: Binding(
                get: { memory.settings.screenContextEnabled },
                set: { propose(screen: $0, memoryEnabled: memory.settings.memoryEnabled) }
            )).accessibilityIdentifier("settings.context.screen")
            Toggle(text("Long-term memory & idle organization", "长期记忆与空闲整理"), isOn: Binding(
                get: { memory.settings.memoryEnabled },
                set: { propose(screen: memory.settings.screenContextEnabled, memoryEnabled: $0) }
            )).accessibilityIdentifier("settings.context.memory")
            if memory.settings.screenContextEnabled && !memory.hasScreenPermission {
                Text(text("Screen Recording permission is unavailable; recordings continue without a screenshot.",
                          "屏幕录制权限不可用，录音会跳过截图。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !memory.isAuthorized && (memory.settings.screenContextEnabled || memory.settings.memoryEnabled) {
                Button(text("Authorize current provider", "授权当前服务")) {
                    propose(screen: memory.settings.screenContextEnabled, memoryEnabled: memory.settings.memoryEnabled)
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
            if let error = memory.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .disabled(memory.isLoading || memory.isSaving)
        .confirmationDialog(text("Authorize context processing", "授权上下文处理"), isPresented: $showConsent) {
            Button(text("Enable for these voice workflows", "为这些语音工作流开启")) {
                memory.apply(screen: pendingScreen, memory: pendingMemory, workflowIDs: Set(workflows.map(\.id)))
            }
            Button(text("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(text(
                "The current LLM provider receives a pre-recording image and optional summaries. Screen summaries are encrypted locally. Voice history and explicit corrections may be organized while idle. Memories survive history cleanup; deleting a memory excludes its original sources from relearning. Provider changes require authorization again. Workflows: ",
                "当前 LLM 服务将收到录音前图片与可选摘要。屏幕摘要在本地加密保存；空闲时可整理语音历史和明确纠正。记忆独立于历史留存，删除记忆会排除其原始来源，防止再次生成。服务变更需重新授权。工作流："
            ) + workflows.map(\.name).joined(separator: "、"))
        }
        .sheet(isPresented: $showMemories) { MemoryManagementView(model: memory, language: language) }
        .task { await memory.refresh() }
    }

    private func propose(screen: Bool, memoryEnabled: Bool) {
        if (!screen || screen == memory.settings.screenContextEnabled)
            && (!memoryEnabled || memoryEnabled == memory.settings.memoryEnabled) && memory.isAuthorized {
            memory.apply(screen: screen, memory: memoryEnabled, workflowIDs: memory.settings.authorizedWorkflowIDs)
        } else {
            pendingScreen = screen
            pendingMemory = memoryEnabled
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
            if let error = model.error { Text(error).foregroundStyle(.red) }
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
    let save: (LongTermMemory) async -> Void
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
            HStack {
                Button(language == .simplifiedChinese ? "取消" : "Cancel") { dismiss() }
                Button(language == .simplifiedChinese ? "保存并确认" : "Save & confirm") {
                    memory.confirm()
                    Task { await save(memory); dismiss() }
                }.disabled(!memory.isValid)
            }
        }.padding(20).frame(width: 540)
    }
}

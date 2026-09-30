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

    private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }

    var body: some View {
        DisclosureGroup(text(.contextCorrectionMemory), isExpanded: $isExpanded) {
            Text(text(.speechRemainsTheOnlyContent))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(text(.useVocabularyForSmartCleanup), isOn: Binding(
                get: { memory.settings.vocabularyCorrectionEnabled },
                set: { propose(screen: memory.settings.screenContextEnabled, memoryEnabled: memory.settings.memoryEnabled, vocabulary: $0) }
            )).accessibilityIdentifier("settings.context.vocabulary")
            Text(text(.applicableHotwordsAreSharedWith))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(text(.screenContext), isOn: Binding(
                get: { memory.settings.screenContextEnabled },
                set: { propose(screen: $0, memoryEnabled: memory.settings.memoryEnabled, vocabulary: memory.settings.vocabularyCorrectionEnabled) }
            )).accessibilityIdentifier("settings.context.screen")
            Toggle(text(.longTermMemoryIdleOrganization), isOn: Binding(
                get: { memory.settings.memoryEnabled },
                set: { propose(screen: memory.settings.screenContextEnabled, memoryEnabled: $0, vocabulary: memory.settings.vocabularyCorrectionEnabled) }
            )).accessibilityIdentifier("settings.context.memory")
            if memory.settings.screenContextEnabled && !memory.hasScreenPermission {
                Text(text(.screenRecordingPermissionIsUnavailable))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !memory.isAuthorized && (memory.settings.screenContextEnabled || memory.settings.memoryEnabled || memory.settings.vocabularyCorrectionEnabled) {
                Button(text(.authorizeCurrentProvider)) {
                    propose(screen: memory.settings.screenContextEnabled, memoryEnabled: memory.settings.memoryEnabled, vocabulary: memory.settings.vocabularyCorrectionEnabled)
                }
            }
            HStack {
                Button(text(.manageMemories)) { showMemories = true }
                Button(text(.organizeWhenIdle)) { memory.scheduleMaintenance() }
                    .disabled(!memory.isAuthorized || !memory.settings.memoryEnabled)
                Text("\(memory.status.requestsToday)/8 " + text(.backgroundRequestsToday))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(memory.status.foregroundRequestsToday) " + text(.foregroundSummaryRequestsTodayMain))
                .font(.caption).foregroundStyle(.secondary)
            if let error = memory.error { Text(L10n.contextMemoryFailure(error).string(for: language)).font(.caption).foregroundStyle(.red) }
        }
        .disabled(memory.isLoading || memory.isSaving)
        .confirmationDialog(text(.authorizeContextProcessing), isPresented: $showConsent) {
            Button(text(.enableForTheseVoiceWorkflows)) {
                memory.apply(screen: pendingScreen, memory: pendingMemory, workflowIDs: Set(consentWorkflows.map(\.id)), vocabulary: pendingVocabulary)
            }
            Button(text(.cancel), role: .cancel) {}
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
            parts.append(text(.smartCleanupSendsItsApplicable))
        }
        if pendingScreen {
            parts.append(text(.theCurrentLlmReceivesThe))
        }
        if pendingMemory {
            parts.append(text(.theCurrentLlmReceivesAuthorized))
        }
        parts.append(text(.providerChangesRequireAuthorizatioAgain)
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
    private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }

    private func evidenceLabel(_ kind: MemoryEvidenceKind) -> String {
        switch kind {
        case .userStatement: text(.userStatement)
        case .userCorrection: text(.explicitCorrection)
        case .screenObservation: text(.screenObservation)
        }
    }
    private func stateLabel(_ state: LongTermMemoryState) -> String {
        switch state {
        case .candidate: text(.needsConfirmation)
        case .active: text(.active)
        case .archived: text(.archived)
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(text(.longTermMemories)).font(.title2)
                Spacer()
                Button(text(.refresh)) { Task { await model.refresh() } }
                Button(text(.done)) { dismiss() }
            }
            List(model.memories) { memory in
                VStack(alignment: .leading, spacing: 8) {
                    Text(memory.summary).textSelection(.enabled)
                    Text("\(evidenceLabel(memory.evidenceKind)) · \(stateLabel(memory.state)) · \(memory.sources.count) "
                         + text(.sources) + (memory.sourceHistoryDeleted ? text(.historyDeleted) : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(memory.corrections, id: \.self) { correction in
                        Text(correction.original + " → " + correction.corrected).font(.callout.monospaced())
                    }
                    if let replacedID = memory.replacesMemoryID {
                        Text(text(.proposedReplacement) + (model.memories.first { $0.id == replacedID }?.summary ?? replacedID.uuidString))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(text(.edit)) { editing = memory }
                        Button(memory.confirmed ? text(.confirmed) : text(.confirm)) {
                            var updated = memory; updated.confirm()
                            Task { await model.save(updated) }
                        }.disabled(memory.confirmed)
                        Button(memory.locked ? text(.unlock) : text(.lock)) {
                            var updated = memory; updated.locked.toggle()
                            Task { await model.save(updated) }
                        }
                        Button(memory.state == .archived ? text(.restore) : text(.archive)) {
                            var updated = memory
                            updated.state = memory.state == .archived ? (memory.confirmed || memory.corrections.isEmpty ? .active : .candidate) : .archived
                            Task { await model.save(updated) }
                        }
                        Button(text(.delete), role: .destructive) { deleting = memory }
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
            .confirmationDialog(text(.permanentlyDeleteThisMemoryAnd),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(text(.deletePermanently), role: .destructive) {
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
            TextField(L10n.surface(.termsCommaSeparated, language: language), text: Binding(
                get: { memory.terms.joined(separator: ", ") },
                set: { memory.terms = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            Toggle(L10n.surface(.setExpiry, language: language), isOn: Binding(
                get: { memory.expiresAt != nil }, set: { memory.expiresAt = $0 ? Date().addingTimeInterval(86_400) : nil }
            ))
            if memory.expiresAt != nil {
                DatePicker(L10n.surface(.archiveAfter, language: language), selection: Binding(
                    get: { memory.expiresAt ?? Date() }, set: { memory.expiresAt = $0 }
                ))
            }
            if let failure { Text(L10n.contextMemoryFailure(failure).string(for: language)).foregroundStyle(.red) }
            HStack {
                Button(L10n.surface(.cancel, language: language)) { dismiss() }
                Button(L10n.surface(.saveConfirm, language: language)) {
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

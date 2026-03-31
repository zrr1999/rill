import AppKit
import Foundation
import Observation
import VoxTypeCore
import VoxTypeRuntime

public enum DeepgramAudioTestState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
}

public enum WhisperKitPreparationState: Sendable, Equatable {
    case idle
    case preparing
    case ready
}

enum WorkflowAudioRunState: Sendable, Equatable {
    case idle
    case recording(workflowID: UUID)
    case transcribing(workflowID: UUID)
}

private actor WhisperKitPreparationProgressRelay {
    weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func update(progress: Progress) async {
        await MainActor.run { [weak model] in
            model?.updateWhisperKitPreparationProgress(progress)
        }
    }
}

public struct WorkflowTriggerConflict: Identifiable, Equatable, Sendable {
    public let trigger: TriggerBinding
    public let workflowIDs: [UUID]

    public var id: String { trigger.rawValue }

    public init(trigger: TriggerBinding, workflowIDs: [UUID]) {
        self.trigger = trigger
        self.workflowIDs = workflowIDs
    }
}

@MainActor
@Observable
public final class AppModel {
    private static let settingsLoadKeys: [AppSettingKey] = [
        .interfaceLanguage,
        .selectedWorkflowID,
        .customWorkflows,
        .workflowEnabledStates,
        .clipboardMergeSimilarItems,
        .clipboardPanelHotkey,
        .preferredSpeechEngine,
        .whisperKitModel,
        .whisperKitDownloadedModels,
        .whisperKitCustomModel,
        .whisperKitModelRepo,
        .whisperKitModelToken,
        .whisperKitModelFolder,
        .whisperKitLanguage,
        .whisperKitDownloadIfNeeded,
        .whisperKitPrewarm,
        .deepgramAPIKey,
        .deepgramBaseURL,
        .deepgramModel,
        .deepgramLanguage,
    ]

    private static let debouncedStringSettingKeys: Set<AppSettingKey> = [
        .whisperKitModel,
        .whisperKitCustomModel,
        .whisperKitModelRepo,
        .whisperKitModelToken,
        .whisperKitModelFolder,
        .whisperKitLanguage,
        .deepgramAPIKey,
        .deepgramBaseURL,
        .deepgramModel,
        .deepgramLanguage,
    ]

    private static let recognizerIDsRequiringCapturedAudio: Set<String> = [
        whisperKitRecognizerID,
        deepgramRecognizerID,
    ]

    public private(set) var builtInWorkflows: [WorkflowDefinition]
    public private(set) var customWorkflows: [WorkflowDefinition] = []
    public private(set) var workflows: [WorkflowDefinition]
    public private(set) var workflowTriggerConflicts: [WorkflowTriggerConflict] = []
    public private(set) var workflowConflictIDsByWorkflowID: [UUID: [UUID]] = [:]
    public var selectedSidebarSection: SidebarSection? = .dashboard
    public var selectedWorkflowID: UUID {
        didSet {
            guard oldValue != selectedWorkflowID else { return }
            persistSelectedWorkflowPreference()
        }
    }
    public var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            persistLanguagePreference()
        }
    }
    public var clipboardPanelHotkeyBinding: HotkeyBindingDescriptor {
        didSet {
            guard oldValue != clipboardPanelHotkeyBinding else { return }
            persistClipboardPanelHotkeyPreference()
            updateClipboardPanelHotkeyAction(clipboardPanelHotkeyBinding)
        }
    }
    public var preferredSpeechEngine: PreferredSpeechEngine {
        didSet {
            guard oldValue != preferredSpeechEngine else { return }
            persistPreferredSpeechEnginePreference()
            applyPreferredSpeechEngineSelectionIfNeeded()
            guard !isRestoringSettings, preferredSpeechEngine == .local else { return }
            prepareWhisperKitModel()
        }
    }
    public var whisperKitModelOption: WhisperKitModelOption {
        didSet {
            guard oldValue != whisperKitModelOption else { return }
            if whisperKitModelOption == .custom {
                let customModel = whisperKitCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if whisperKitModel != customModel {
                    whisperKitModel = customModel
                }
                guard !isRestoringSettings else { return }
                resetWhisperKitPreparationStatus()
                return
            }

            let presetModel = whisperKitModelOption.modelIdentifier ?? ""
            if whisperKitModel != presetModel {
                whisperKitModel = presetModel
            }
            guard !isRestoringSettings else { return }
            prepareWhisperKitModel()
        }
    }
    public var whisperKitCustomModel: String {
        didSet {
            guard oldValue != whisperKitCustomModel else { return }
            persistWhisperKitStringSetting(
                whisperKitCustomModel,
                for: .whisperKitCustomModel,
                englishFailurePrefix: "WhisperKit custom model persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 自定义模型持久化失败"
            )

            guard whisperKitModelOption == .custom else { return }
            let customModel = whisperKitCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if whisperKitModel != customModel {
                whisperKitModel = customModel
            } else {
                resetWhisperKitPreparationStatus()
            }
        }
    }
    public var whisperKitModel: String {
        didSet {
            guard oldValue != whisperKitModel else { return }
            resetWhisperKitPreparationStatus()
            persistWhisperKitStringSetting(
                whisperKitModel,
                for: .whisperKitModel,
                englishFailurePrefix: "WhisperKit model persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 模型持久化失败"
            )
        }
    }
    public var whisperKitModelRepo: String {
        didSet {
            guard oldValue != whisperKitModelRepo else { return }
            resetWhisperKitPreparationStatus()
            persistWhisperKitStringSetting(
                whisperKitModelRepo,
                for: .whisperKitModelRepo,
                englishFailurePrefix: "WhisperKit model repository persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 模型仓库持久化失败"
            )
        }
    }
    public var whisperKitModelToken: String {
        didSet {
            guard oldValue != whisperKitModelToken else { return }
            resetWhisperKitPreparationStatus()
            persistWhisperKitStringSetting(
                whisperKitModelToken,
                for: .whisperKitModelToken,
                englishFailurePrefix: "WhisperKit access token persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 访问令牌持久化失败"
            )
        }
    }
    public var whisperKitModelFolder: String {
        didSet {
            guard oldValue != whisperKitModelFolder else { return }
            resetWhisperKitPreparationStatus()
            persistWhisperKitStringSetting(
                whisperKitModelFolder,
                for: .whisperKitModelFolder,
                englishFailurePrefix: "WhisperKit model folder persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 模型目录持久化失败"
            )
        }
    }
    public var whisperKitLanguage: String {
        didSet {
            guard oldValue != whisperKitLanguage else { return }
            resetWhisperKitPreparationStatus()
            persistWhisperKitStringSetting(
                whisperKitLanguage,
                for: .whisperKitLanguage,
                englishFailurePrefix: "WhisperKit language persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 语言持久化失败"
            )
        }
    }
    public var whisperKitDownloadIfNeeded: Bool {
        didSet {
            guard oldValue != whisperKitDownloadIfNeeded else { return }
            resetWhisperKitPreparationStatus()
            persistWhisperKitBooleanSetting(
                whisperKitDownloadIfNeeded,
                for: .whisperKitDownloadIfNeeded,
                englishFailurePrefix: "WhisperKit download preference persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 下载偏好持久化失败"
            )
        }
    }
    public var whisperKitPrewarm: Bool {
        didSet {
            guard oldValue != whisperKitPrewarm else { return }
            resetWhisperKitPreparationStatus()
            persistWhisperKitBooleanSetting(
                whisperKitPrewarm,
                for: .whisperKitPrewarm,
                englishFailurePrefix: "WhisperKit prewarm preference persistence failed",
                simplifiedChineseFailurePrefix: "WhisperKit 预热偏好持久化失败"
            )
        }
    }
    public var deepgramAPIKey: String {
        didSet {
            guard oldValue != deepgramAPIKey else { return }
            persistDeepgramSetting(
                deepgramAPIKey,
                for: .deepgramAPIKey,
                englishFailurePrefix: "Deepgram API key persistence failed",
                simplifiedChineseFailurePrefix: "Deepgram API Key 持久化失败"
            )
        }
    }
    public var deepgramBaseURL: String {
        didSet {
            guard oldValue != deepgramBaseURL else { return }
            persistDeepgramSetting(
                deepgramBaseURL,
                for: .deepgramBaseURL,
                englishFailurePrefix: "Deepgram base URL persistence failed",
                simplifiedChineseFailurePrefix: "Deepgram Base URL 持久化失败"
            )
        }
    }
    public var deepgramModel: String {
        didSet {
            guard oldValue != deepgramModel else { return }
            persistDeepgramSetting(
                deepgramModel,
                for: .deepgramModel,
                englishFailurePrefix: "Deepgram model persistence failed",
                simplifiedChineseFailurePrefix: "Deepgram 模型持久化失败"
            )
        }
    }
    public var deepgramLanguage: String {
        didSet {
            guard oldValue != deepgramLanguage else { return }
            persistDeepgramSetting(
                deepgramLanguage,
                for: .deepgramLanguage,
                englishFailurePrefix: "Deepgram language persistence failed",
                simplifiedChineseFailurePrefix: "Deepgram 语言持久化失败"
            )
        }
    }
    public var isRunning = false
    private(set) var workflowAudioRunState: WorkflowAudioRunState = .idle
    public private(set) var whisperKitPreparationState: WhisperKitPreparationState = .idle
    public private(set) var whisperKitPreparationProgress: Double = 0
    public private(set) var whisperKitPreparedModelIdentifier: String?
    public private(set) var downloadedWhisperKitModels: [String] = []
    public var whisperKitPreparationError: String?
    public private(set) var deepgramAudioTestState: DeepgramAudioTestState = .idle
    public var deepgramTestTranscript: String?
    public var deepgramTestError: String?
    public var workflowEditorError: String?
    public var workflowLibraryError: String?
    public var pendingResolution: CandidateResolutionCase?
    public var permissionSnapshot: PermissionSnapshot
    public var stackCount = 0
    public var stackPreview: String?
    public var lastCompletedText: String?
    public var lastFailure: String?
    public var eventFeed: [EventFeedEntry] = []
    public private(set) var diagnosticEvents: [DiagnosticEvent] = []
    public private(set) var historyRecords: [HistoryRecord] = []
    public private(set) var clipboardItems: [ClipboardHistoryItem] = []
    public private(set) var clipboardGroups: [ClipboardGroupSummary] = []
    public private(set) var clipboardAppAssignments: [ClipboardAppAssignment] = []
    private(set) var clipboardHistoryEntries: [ClipboardHistoryEntry] = []
    public var mergeSimilarClipboardItems = false {
        didSet {
            guard oldValue != mergeSimilarClipboardItems else { return }
            rebuildClipboardHistoryEntries()
            persistClipboardMergeSimilarPreference()
        }
    }
    public var canRunSelectedWorkflow: Bool {
        canTriggerWorkflow(selectedWorkflow)
    }
    public var canDeliverTopOfStack: Bool {
        stackCount > 0 && permissionSnapshot.accessibility == .granted
    }
    public var localizedWindowTitle: String {
        UIStrings.text(.appTitle, language: language)
    }
    public var localizedMenuBarTitle: String {
        UIStrings.text(.menuBarLabel, language: language)
    }
    public var localizedWorkflowWindowTitle: String {
        UIStrings.text(.workflowsTitle, language: language)
    }

    private let eventBus: EventBus
    private let sessionCoordinator: SessionCoordinator
    private let deliveryStack: DeliveryStack?
    private let candidateResolver: CandidateResolver
    private let historyRepository: (any HistoryRepository)?
    private let diagnosticRepository: (any DiagnosticRepository)?
    private let settingsStore: (any SettingsStore)?
    private let settingsWriteDebounceDuration: Duration
    private let prepareWhisperKitAction: @Sendable (
        WhisperKitSettings,
        @escaping @Sendable (Progress) -> Void
    ) async throws -> String
    private let startWorkflowAudioRunAction: @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void
    private let finishWorkflowAudioRunAction: @Sendable () async throws -> Void
    private let startDeepgramAudioTestAction: @Sendable (DeepgramSettings) async throws -> Void
    private let finishDeepgramAudioTestAction: @Sendable (DeepgramSettings) async throws -> RecognitionResult
    private let cancelDeepgramAudioTestAction: @Sendable () async -> Void
    private let pasteTopOfStackAction: () -> Void
    private let refreshPermissionsAction: () -> Void
    private let requestAccessibilityAction: () -> Void
    private let requestMicrophoneAction: () -> Void
    private let openAccessibilitySettingsAction: () -> Void
    private let openMicrophoneSettingsAction: () -> Void
    private var showClipboardPanelAction: () -> Void = {}
    private var openWorkflowEditorAction: () -> Void = {}
    private var updateClipboardPanelHotkeyAction: (HotkeyBindingDescriptor) -> Void = { _ in }
    private var useClipboardItemAction: (ClipboardHistoryItem) -> Void = { _ in }
    private var pendingRuns: [UUID: PendingRunInfo] = [:]
    private var listenerTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var workflowEnabledStates: [UUID: Bool] = [:]
    private var hasModifiedWorkflowLibrary = false
    private var isRestoringSettings = false
    private var pendingSettingWriteTasks: [AppSettingKey: Task<Void, Never>] = [:]
    private var pendingSettingWriteGenerations: [AppSettingKey: Int] = [:]

    public init(
        workflows: [WorkflowDefinition],
        eventBus: EventBus,
        sessionCoordinator: SessionCoordinator,
        deliveryStack: DeliveryStack? = nil,
        candidateResolver: CandidateResolver,
        historyRepository: (any HistoryRepository)? = nil,
        diagnosticRepository: (any DiagnosticRepository)? = nil,
        settingsStore: (any SettingsStore)? = nil,
        settingsWriteDebounceDuration: Duration = .milliseconds(300),
        prepareWhisperKitAction: @escaping @Sendable (
            WhisperKitSettings,
            @escaping @Sendable (Progress) -> Void
        ) async throws -> String = { _, _ in
            throw NSError(
                domain: "VoxType.AppModel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Local speech preparation is not configured."]
            )
        },
        startWorkflowAudioRunAction: @escaping @Sendable (WorkflowDefinition, TriggerBinding) async throws -> Void = { _, _ in
            throw NSError(
                domain: "VoxType.AppModel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Workflow audio capture is not configured."]
            )
        },
        finishWorkflowAudioRunAction: @escaping @Sendable () async throws -> Void = {
            throw NSError(
                domain: "VoxType.AppModel",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Workflow audio completion is not configured."]
            )
        },
        startDeepgramAudioTestAction: @escaping @Sendable (DeepgramSettings) async throws -> Void = { _ in },
        finishDeepgramAudioTestAction: @escaping @Sendable (DeepgramSettings) async throws -> RecognitionResult = { _ in
            throw NSError(
                domain: "VoxType.AppModel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Deepgram audio testing is not configured."]
            )
        },
        cancelDeepgramAudioTestAction: @escaping @Sendable () async -> Void = {},
        pasteTopOfStackAction: @escaping () -> Void,
        permissionSnapshot: PermissionSnapshot,
        language: AppLanguage = .preferred,
        refreshPermissionsAction: @escaping () -> Void,
        requestAccessibilityAction: @escaping () -> Void,
        requestMicrophoneAction: @escaping () -> Void,
        openAccessibilitySettingsAction: @escaping () -> Void,
        openMicrophoneSettingsAction: @escaping () -> Void
    ) {
        self.builtInWorkflows = workflows
        self.workflows = workflows
        self.selectedWorkflowID = workflows.first?.id ?? UUID()
        self.language = language
        self.clipboardPanelHotkeyBinding = .doubleCommand
        self.preferredSpeechEngine = .local
        self.whisperKitModelOption = .automatic
        self.whisperKitCustomModel = ""
        self.whisperKitModel = WhisperKitSettings().model
        self.whisperKitModelRepo = WhisperKitSettings().modelRepo
        self.whisperKitModelToken = WhisperKitSettings().modelToken
        self.whisperKitModelFolder = WhisperKitSettings().modelFolder
        self.whisperKitLanguage = WhisperKitSettings().language
        self.whisperKitDownloadIfNeeded = WhisperKitSettings().downloadIfNeeded
        self.whisperKitPrewarm = WhisperKitSettings().prewarm
        self.deepgramAPIKey = ""
        self.deepgramBaseURL = DeepgramSettings().baseURL
        self.deepgramModel = DeepgramSettings().model
        self.deepgramLanguage = DeepgramSettings().language
        self.permissionSnapshot = permissionSnapshot
        self.eventBus = eventBus
        self.sessionCoordinator = sessionCoordinator
        self.deliveryStack = deliveryStack
        self.candidateResolver = candidateResolver
        self.historyRepository = historyRepository
        self.diagnosticRepository = diagnosticRepository
        self.settingsStore = settingsStore
        self.settingsWriteDebounceDuration = settingsWriteDebounceDuration
        self.prepareWhisperKitAction = prepareWhisperKitAction
        self.startWorkflowAudioRunAction = startWorkflowAudioRunAction
        self.finishWorkflowAudioRunAction = finishWorkflowAudioRunAction
        self.startDeepgramAudioTestAction = startDeepgramAudioTestAction
        self.finishDeepgramAudioTestAction = finishDeepgramAudioTestAction
        self.cancelDeepgramAudioTestAction = cancelDeepgramAudioTestAction
        self.pasteTopOfStackAction = pasteTopOfStackAction
        self.refreshPermissionsAction = refreshPermissionsAction
        self.requestAccessibilityAction = requestAccessibilityAction
        self.requestMicrophoneAction = requestMicrophoneAction
        self.openAccessibilitySettingsAction = openAccessibilitySettingsAction
        self.openMicrophoneSettingsAction = openMicrophoneSettingsAction
        synchronizeWorkflowEnabledStates()
        reconcileSelectedWorkflow(preferredWorkflowID: self.selectedWorkflowID)
        if let deliveryStack {
            Task { [weak self] in
                let snapshot = await deliveryStack.clipboardSnapshot()
                await MainActor.run {
                    self?.updateClipboardSnapshot(snapshot)
                }
            }
        }
        loadSettings()
        loadHistory()
        loadDiagnostics()
        startListening()
    }

    public var selectedWorkflow: WorkflowDefinition? {
        workflows.first(where: { $0.id == selectedWorkflowID })
    }

    public func isWorkflowEnabled(_ workflow: WorkflowDefinition) -> Bool {
        workflowEnabledStates[workflow.id] ?? true
    }

    public func setWorkflowEnabled(_ isEnabled: Bool, for workflowID: UUID) {
        guard let workflow = workflows.first(where: { $0.id == workflowID }) else { return }

        if isEnabled {
            let conflicts = conflictingEnabledWorkflowsForActivation(of: workflow)
            guard conflicts.isEmpty else {
                workflowLibraryError = UIStrings.workflowEnableConflict(
                    trigger: workflow.trigger,
                    names: conflicts.map { localizedWorkflowName(for: $0) },
                    language: language
                )
                return
            }
        }

        hasModifiedWorkflowLibrary = true
        workflowEnabledStates[workflowID] = isEnabled
        workflowLibraryError = nil
        updateWorkflowTriggerConflicts()
        reconcileSelectedWorkflow(preferredWorkflowID: selectedWorkflowID)
        persistWorkflowEnabledStates()
    }

    public func enabledWorkflows(for trigger: TriggerBinding) -> [WorkflowDefinition] {
        workflows.filter { workflow in
            workflow.trigger == trigger && isWorkflowEnabled(workflow)
        }
    }

    public func conflictingWorkflows(for workflow: WorkflowDefinition) -> [WorkflowDefinition] {
        guard
            triggerRequiresExclusiveBinding(workflow.trigger),
            isWorkflowEnabled(workflow),
            let conflictWorkflowIDs = workflowConflictIDsByWorkflowID[workflow.id]
        else {
            return []
        }

        return workflows.filter { candidate in
            candidate.id != workflow.id && conflictWorkflowIDs.contains(candidate.id)
        }
    }

    func deleteClipboardHistoryEntry(_ entry: ClipboardHistoryEntry) {
        guard let deliveryStack else { return }

        Task { [weak self, deliveryStack] in
            await deliveryStack.deleteItems(ids: entry.mergedItemIDs)
            await MainActor.run {
                self?.append(
                    english: "Removed clipboard history entry",
                    simplifiedChinese: "已移除剪切板历史项"
                )
            }
        }
    }

    public var workflowSelectableWhisperKitModels: [String] {
        let predefinedModels = WhisperKitModelOption.allCases.compactMap(\.modelIdentifier)
        let downloadedCustomModels = downloadedWhisperKitModels.filter { modelIdentifier in
            !predefinedModels.contains(modelIdentifier)
        }
        return predefinedModels + downloadedCustomModels
    }

    public func isWhisperKitModelDownloaded(_ modelIdentifier: String) -> Bool {
        downloadedWhisperKitModels.contains(modelIdentifier)
    }

    public func whisperKitModelDisplayName(
        _ modelIdentifier: String,
        includeStatus: Bool = false
    ) -> String {
        guard includeStatus else { return modelIdentifier }
        let status = isWhisperKitModelDownloaded(modelIdentifier)
            ? UIStrings.text(.whisperKitDownloaded, language: language)
            : UIStrings.text(.whisperKitNotDownloaded, language: language)
        return "\(modelIdentifier) · \(status)"
    }

    public func whisperKitModelOptionLabel(_ option: WhisperKitModelOption) -> String {
        guard let modelIdentifier = option.modelIdentifier else {
            return UIStrings.whisperKitModelOption(option, language: language)
        }
        return whisperKitModelDisplayName(modelIdentifier, includeStatus: true)
    }

    public func useDownloadedWhisperKitModel(_ modelIdentifier: String) {
        workflowLibraryError = nil
        if let option = WhisperKitModelOption(rawValue: modelIdentifier) {
            whisperKitModelOption = option
        } else {
            whisperKitModelOption = .custom
            whisperKitCustomModel = modelIdentifier
        }
        whisperKitModel = modelIdentifier
        whisperKitPreparationState = .ready
        whisperKitPreparationProgress = 1
        whisperKitPreparedModelIdentifier = modelIdentifier
        whisperKitPreparationError = nil
    }

    public func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func copyHistoryFailure(_ record: HistoryRecord) {
        guard let failureMessage = record.failureMessage else { return }
        let payload = [
            "workflow: \(UIStrings.workflowName(record.workflow, language: language))",
            "timestamp: \(record.timestamp.formatted(date: .numeric, time: .standard))",
            "failure: \(failureMessage)",
        ].joined(separator: "\n")
        copyTextToClipboard(payload)
    }

    public func copyDiagnosticEvent(_ event: DiagnosticEvent) {
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let payload = [
            "level: \(UIStrings.diagnosticLevel(event.level, language: .english))",
            "subsystem: \(UIStrings.subsystem(event.subsystem, language: .english))",
            "time: \(event.timestamp.formatted(date: .numeric, time: .standard))",
            "event: \(event.event)",
            "message: \(event.message)",
            metadata.isEmpty ? nil : "metadata:\n\(metadata)",
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        copyTextToClipboard(payload)
    }

    public func runSelectedWorkflow() {
        guard let workflow = selectedWorkflow else { return }
        runWorkflow(workflow, initiatedBy: .manual)
    }

    public func runWorkflow(_ workflow: WorkflowDefinition) {
        runWorkflow(workflow, initiatedBy: .manual)
    }

    public func runWorkflow(_ workflow: WorkflowDefinition, initiatedBy binding: TriggerBinding) {
        if isRecordingWorkflowAudioRun(for: workflow) {
            finishCapturedAudioWorkflowRun(for: workflow)
            return
        }

        guard !isRunning else { return }
        guard isWorkflowEnabled(workflow) else {
            let english = "Enable the workflow before running it."
            let simplifiedChinese = "请先启用这个工作流再运行。"
            lastFailure = language == .english ? english : simplifiedChinese
            append(
                english: english,
                simplifiedChinese: simplifiedChinese
            )
            return
        }

        if requiresCapturedAudioForInteractiveRun(workflow) {
            startCapturedAudioWorkflowRun(for: workflow, initiatedBy: binding)
            return
        }

        launchWorkflowRun(workflow, initiatedBy: binding)
    }

    func canTriggerWorkflow(_ workflow: WorkflowDefinition?) -> Bool {
        guard let workflow else { return false }
        guard isWorkflowEnabled(workflow) else { return false }

        if isRecordingWorkflowAudioRun(for: workflow) {
            return true
        }

        return !isRunning
    }

    func workflowRunButtonTitle(for workflow: WorkflowDefinition?) -> String {
        guard let workflow else {
            return UIStrings.text(.runSelectedWorkflow, language: language)
        }

        if isRecordingWorkflowAudioRun(for: workflow) {
            return UIStrings.text(.workflowStopAndTranscribe, language: language)
        }

        if isTranscribingWorkflowAudioRun(for: workflow) {
            return UIStrings.text(.workflowTranscribing, language: language)
        }

        if isRunning {
            return UIStrings.text(.running, language: language)
        }

        if requiresCapturedAudioForInteractiveRun(workflow) {
            return UIStrings.text(.workflowRecordAndRun, language: language)
        }

        return UIStrings.text(.runSelectedWorkflow, language: language)
    }

    func workflowMenuButtonTitle(for workflow: WorkflowDefinition) -> String {
        let name = localizedWorkflowName(for: workflow)

        if isRecordingWorkflowAudioRun(for: workflow) {
            return "\(name) · \(UIStrings.text(.workflowStopAndTranscribe, language: language))"
        }

        if isTranscribingWorkflowAudioRun(for: workflow) {
            return "\(name) · \(UIStrings.text(.workflowTranscribing, language: language))"
        }

        return name
    }

    private func launchWorkflowRun(_ workflow: WorkflowDefinition, initiatedBy binding: TriggerBinding) {
        isRunning = true
        lastFailure = nil

        Task { [weak self, sessionCoordinator] in
            guard let self else { return }
            do {
                try await self.persistProviderSettingsForRun(workflow)
                await sessionCoordinator.run(
                    workflow: workflow,
                    triggerEvent: Self.makeInteractiveTriggerEvent(for: workflow, binding: binding)
                )
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.lastFailure = error.localizedDescription
                    self.append(
                        english: "Workflow settings could not be saved before run: \(error.localizedDescription)",
                        simplifiedChinese: "运行前无法保存工作流设置：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func startCapturedAudioWorkflowRun(for workflow: WorkflowDefinition, initiatedBy binding: TriggerBinding) {
        isRunning = true
        lastFailure = nil
        workflowAudioRunState = .recording(workflowID: workflow.id)

        Task { [weak self, startWorkflowAudioRunAction] in
            guard let self else { return }
            do {
                try await self.persistProviderSettingsForRun(workflow)
                try await startWorkflowAudioRunAction(workflow, binding)
                await MainActor.run {
                    self.append(
                        english: "Recording started. Click again to stop and transcribe.",
                        simplifiedChinese: "已开始录音。再次点击即可停止并转写。"
                    )
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.workflowAudioRunState = .idle
                    self.lastFailure = error.localizedDescription
                    self.append(
                        english: "Workflow recording could not start: \(error.localizedDescription)",
                        simplifiedChinese: "无法开始工作流录音：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func finishCapturedAudioWorkflowRun(for workflow: WorkflowDefinition) {
        workflowAudioRunState = .transcribing(workflowID: workflow.id)

        Task { [weak self, finishWorkflowAudioRunAction] in
            guard let self else { return }
            do {
                try await finishWorkflowAudioRunAction()
                await MainActor.run {
                    self.workflowAudioRunState = .idle
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.workflowAudioRunState = .idle
                    self.lastFailure = error.localizedDescription
                    self.append(
                        english: "Recorded workflow could not be transcribed: \(error.localizedDescription)",
                        simplifiedChinese: "无法处理这段录音：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func requiresCapturedAudioForInteractiveRun(_ workflow: WorkflowDefinition) -> Bool {
        Self.recognizerIDsRequiringCapturedAudio.contains(workflow.pipeline.recognizerID)
    }

    private func isRecordingWorkflowAudioRun(for workflow: WorkflowDefinition) -> Bool {
        guard case .recording(let workflowID) = workflowAudioRunState else { return false }
        return workflowID == workflow.id
    }

    private func isTranscribingWorkflowAudioRun(for workflow: WorkflowDefinition) -> Bool {
        guard case .transcribing(let workflowID) = workflowAudioRunState else { return false }
        return workflowID == workflow.id
    }

    private func persistProviderSettingsForRun(_ workflow: WorkflowDefinition) async throws {
        guard let settingsStore else { return }

        if workflow.pipeline.recognizerID == Self.whisperKitRecognizerID {
            try await Self.persistWhisperKitSettings(currentWhisperKitSettings(), into: settingsStore)
        }

        if workflow.pipeline.recognizerID == Self.deepgramRecognizerID {
            try await Self.persistDeepgramSettings(currentDeepgramSettings(), into: settingsStore)
        }
    }

    private static func makeInteractiveTriggerEvent(
        for workflow: WorkflowDefinition,
        binding: TriggerBinding
    ) -> WorkflowTriggerEvent {
        WorkflowTriggerEvent(
            binding: binding,
            workflowID: workflow.id,
            sourceID: interactiveTriggerSourceID(for: binding),
            metadata: ["requestedTrigger": workflow.trigger.rawValue]
        )
    }

    private static func interactiveTriggerSourceID(for binding: TriggerBinding) -> String {
        switch binding {
        case .manual:
            return "dashboard.run"
        case .menuBar:
            return "menu-bar.run"
        case .hotkey:
            return "hotkey.run"
        case .wakeWord:
            return "wake-word.run"
        }
    }

    public func deliverTopOfStack() {
        pasteTopOfStackAction()
    }

    public func refreshPermissions() {
        refreshPermissionsAction()
    }

    public func requestAccessibilityPermission() {
        requestAccessibilityAction()
    }

    public func requestMicrophonePermission() {
        requestMicrophoneAction()
    }

    public func openAccessibilitySettings() {
        openAccessibilitySettingsAction()
    }

    public func openMicrophoneSettings() {
        openMicrophoneSettingsAction()
    }

    public func installClipboardPanelAction(_ action: @escaping () -> Void) {
        showClipboardPanelAction = action
    }

    public func installOpenWorkflowEditorAction(_ action: @escaping () -> Void) {
        openWorkflowEditorAction = action
    }

    public func installClipboardPanelHotkeyAction(
        _ action: @escaping (HotkeyBindingDescriptor) -> Void
    ) {
        updateClipboardPanelHotkeyAction = action
        action(clipboardPanelHotkeyBinding)
    }

    public func installUseClipboardItemAction(_ action: @escaping (ClipboardHistoryItem) -> Void) {
        useClipboardItemAction = action
    }

    public func showClipboardPanel() {
        showClipboardPanelAction()
    }

    public func openWorkflowEditor() {
        openWorkflowEditorAction()
    }

    public func setClipboardPanelHotkeyShortcut(_ shortcut: KeyboardShortcut) {
        clipboardPanelHotkeyBinding = .keyboardShortcut(shortcut)
    }

    public func resetClipboardPanelHotkeyBinding() {
        clipboardPanelHotkeyBinding = .doubleCommand
    }

    public func useClipboardItem(_ item: ClipboardHistoryItem) {
        useClipboardItemAction(item)
    }

    public func pasteClipboardItem(_ item: ClipboardHistoryItem) {
        lastFailure = nil
        Task { [sessionCoordinator] in
            await sessionCoordinator.deliverClipboardItem(itemID: item.id, actionID: "inject.text")
        }
    }

    public func updatePermissionSnapshot(_ snapshot: PermissionSnapshot) {
        permissionSnapshot = snapshot
    }

    public func localizedWorkflowName(for workflow: WorkflowDefinition) -> String {
        UIStrings.workflowName(workflow.presentation, language: language)
    }

    public func defaultWorkflowDraft() -> WorkflowEditorDraft {
        WorkflowEditorDraft(
            recognizer: preferredSpeechEngine == .cloud ? .cloudSpeech : .localSpeech
        )
    }

    public func isCustomWorkflow(_ workflow: WorkflowDefinition) -> Bool {
        workflow.metadata[Self.workflowOriginMetadataKey] == Self.userWorkflowOriginMetadataValue
    }

    public func saveWorkflowDraft(_ draft: WorkflowEditorDraft, editing workflowID: UUID? = nil) {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            workflowEditorError = language == .english
                ? "Enter a workflow name before saving."
                : "请先填写工作流名称。"
            return
        }

        let existingMetadata = workflowID
            .flatMap { id in customWorkflows.first(where: { $0.id == id })?.metadata } ?? [:]
        var sanitizedDraft = draft
        sanitizedDraft.name = trimmedName

        let workflow = sanitizedDraft.makeWorkflow(
            id: workflowID ?? UUID(),
            existingMetadata: existingMetadata,
            hotkeyGesture: Self.defaultHotkeyGesture
        )

        hasModifiedWorkflowLibrary = true
        if let workflowID, let index = customWorkflows.firstIndex(where: { $0.id == workflowID }) {
            customWorkflows[index] = workflow
        } else {
            customWorkflows.insert(workflow, at: 0)
        }

        let enableConflicts = conflictingEnabledWorkflowsForActivation(of: workflow)
        let desiredEnabledState = workflowEnabledStates[workflow.id] ?? true
        if desiredEnabledState && !enableConflicts.isEmpty {
            workflowEnabledStates[workflow.id] = false
            workflowLibraryError = UIStrings.workflowEnableConflict(
                trigger: workflow.trigger,
                names: enableConflicts.map { localizedWorkflowName(for: $0) },
                language: language
            )
        } else {
            if workflowEnabledStates[workflow.id] == nil {
                workflowEnabledStates[workflow.id] = true
            }
            workflowLibraryError = nil
        }

        workflowEditorError = nil
        rebuildWorkflowLibrary(selecting: workflow.id)
        persistWorkflowEnabledStates()
        persistCustomWorkflows()
        append(
            english: "Workflow saved: \(workflow.name)",
            simplifiedChinese: "工作流已保存：\(workflow.name)"
        )
    }

    public func deleteCustomWorkflow(_ workflow: WorkflowDefinition) {
        guard let index = customWorkflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        hasModifiedWorkflowLibrary = true
        customWorkflows.remove(at: index)
        workflowEnabledStates.removeValue(forKey: workflow.id)
        workflowEditorError = nil
        workflowLibraryError = nil

        let nextSelection: UUID?
        if selectedWorkflowID == workflow.id {
            nextSelection = customWorkflows.first?.id ?? builtInWorkflows.first?.id
        } else {
            nextSelection = selectedWorkflowID
        }

        rebuildWorkflowLibrary(selecting: nextSelection)
        persistWorkflowEnabledStates()
        persistCustomWorkflows()
        append(
            english: "Workflow removed: \(workflow.name)",
            simplifiedChinese: "工作流已删除：\(workflow.name)"
        )
    }

    public func refreshDiagnostics() {
        loadDiagnostics()
    }

    public func prepareWhisperKitModel() {
        guard whisperKitPreparationState != .preparing else { return }
        if whisperKitModelOption == .custom {
            let customModel = whisperKitCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !customModel.isEmpty else {
                whisperKitPreparationState = .idle
                whisperKitPreparationProgress = 0
                whisperKitPreparedModelIdentifier = nil
                whisperKitPreparationError = UIStrings.text(
                    UIStrings.Key.whisperKitCustomModelRequired,
                    language: language
                )
                return
            }
            if whisperKitModel != customModel {
                whisperKitModel = customModel
            }
        }
        whisperKitPreparationState = .preparing
        whisperKitPreparationProgress = 0
        whisperKitPreparedModelIdentifier = nil
        whisperKitPreparationError = nil
        let settings = currentWhisperKitSettings()
        let progressRelay = WhisperKitPreparationProgressRelay(model: self)

        Task { [weak self, prepareWhisperKitAction] in
            do {
                let preparedModel = try await prepareWhisperKitAction(settings, { progress in
                    Task {
                        await progressRelay.update(progress: progress)
                    }
                })
                await MainActor.run {
                    self?.whisperKitPreparationState = .ready
                    self?.whisperKitPreparationProgress = 1
                    self?.whisperKitPreparedModelIdentifier = preparedModel
                    self?.recordDownloadedWhisperKitModel(preparedModel)
                    self?.append(
                        english: "WhisperKit local model is ready: \(preparedModel)",
                        simplifiedChinese: "WhisperKit 本地模型已准备就绪：\(preparedModel)"
                    )
                }
            } catch {
                await MainActor.run {
                    self?.whisperKitPreparationState = .idle
                    self?.whisperKitPreparationProgress = 0
                    self?.whisperKitPreparedModelIdentifier = nil
                    self?.whisperKitPreparationError = error.localizedDescription
                    self?.append(
                        english: "WhisperKit preparation failed: \(error.localizedDescription)",
                        simplifiedChinese: "WhisperKit 准备失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    public func toggleDeepgramAudioTest() {
        switch deepgramAudioTestState {
        case .idle:
            guard permissionSnapshot.microphone == .granted else {
                deepgramTestError = UIStrings.text(.deepgramMicrophoneRequired, language: language)
                return
            }

            deepgramAudioTestState = .recording
            deepgramTestError = nil
            deepgramTestTranscript = nil
            let settings = currentDeepgramSettings()

            Task { [weak self, startDeepgramAudioTestAction] in
                do {
                    try await startDeepgramAudioTestAction(settings)
                    await MainActor.run {
                        self?.append(
                            english: "Deepgram test recording started.",
                            simplifiedChinese: "Deepgram 测试录音已开始。"
                        )
                    }
                } catch {
                    await MainActor.run {
                        self?.deepgramAudioTestState = .idle
                        self?.deepgramTestError = error.localizedDescription
                        self?.append(
                            english: "Deepgram test failed to start: \(error.localizedDescription)",
                            simplifiedChinese: "Deepgram 测试无法开始：\(error.localizedDescription)"
                        )
                    }
                }
            }
        case .recording:
            deepgramAudioTestState = .transcribing
            let settings = currentDeepgramSettings()

            Task { [weak self, finishDeepgramAudioTestAction] in
                do {
                    let result = try await finishDeepgramAudioTestAction(settings)
                    await MainActor.run {
                        self?.deepgramAudioTestState = .idle
                        self?.deepgramTestTranscript = result.bestText
                        self?.deepgramTestError = nil
                        self?.append(
                            english: "Deepgram test completed: \(result.bestText)",
                            simplifiedChinese: "Deepgram 测试完成：\(result.bestText)"
                        )
                    }
                } catch {
                    await MainActor.run {
                        self?.deepgramAudioTestState = .idle
                        self?.deepgramTestError = error.localizedDescription
                        self?.append(
                            english: "Deepgram test failed: \(error.localizedDescription)",
                            simplifiedChinese: "Deepgram 测试失败：\(error.localizedDescription)"
                        )
                    }
                }
            }
        case .transcribing:
            break
        }
    }

    public func cancelDeepgramAudioTest() {
        deepgramAudioTestState = .idle
        Task { [cancelDeepgramAudioTestAction] in
            await cancelDeepgramAudioTestAction()
        }
    }

    public func replayClipboardItem(
        _ item: ClipboardHistoryItem,
        with workflow: WorkflowDefinition,
        replacingSourceItem: Bool = false
    ) {
        guard !isRunning else { return }
        isRunning = true
        lastFailure = nil
        Task { [sessionCoordinator] in
            await sessionCoordinator.replayClipboardItem(
                itemID: item.id,
                workflow: workflow,
                replacingSourceItem: replacingSourceItem
            )
        }
    }

    public func deleteClipboardItem(_ item: ClipboardHistoryItem) {
        Task { [deliveryStack] in
            await deliveryStack?.deleteItem(id: item.id)
        }
    }

    public func setClipboardMode(_ mode: ClipboardPasteMode, forGroup groupID: UUID) {
        Task { [deliveryStack] in
            await deliveryStack?.setMode(mode, forGroup: groupID)
        }
    }

    public func createClipboardGroup(named name: String) {
        Task { [deliveryStack] in
            _ = await deliveryStack?.createGroup(named: name)
        }
    }

    public func assignApplication(_ assignment: ClipboardAppAssignment, toGroup groupID: UUID) {
        Task { [deliveryStack] in
            await deliveryStack?.assignApplication(
                bundleIdentifier: assignment.bundleIdentifier,
                applicationName: assignment.applicationName,
                toGroup: groupID
            )
        }
    }

    public func acceptResolution(selections: [UUID: UUID]) {
        guard let pendingResolution else { return }
        Task {
            _ = await candidateResolver.accept(caseID: pendingResolution.id, selections: selections)
        }
    }

    public func dismissResolution() {
        guard let pendingResolution else { return }
        Task {
            _ = await candidateResolver.dismiss(caseID: pendingResolution.id)
        }
    }

    private func startListening() {
        listenerTask?.cancel()
        listenerTask = Task { [weak self, eventBus] in
            let stream = await eventBus.stream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    self.handle(event)
                    return true
                }
                guard shouldContinue else { break }
            }
        }
    }

    private func handle(_ event: VoxTypeEvent) {
        switch event {
        case .runStarted(let run):
            activeRunID = run.runID
            isRunning = true
            workflowAudioRunState = .idle
            lastFailure = nil
            let wf = workflows.first(where: { $0.id == run.workflowID })
            let isStack = wf?.pipeline.deliveryPolicy.strategy == .stackFirst
            pendingRuns[run.runID] = PendingRunInfo(
                workflowID: run.workflowID,
                workflow: run.workflow,
                isStackRelated: isStack
            )
            append(
                english: "Run started: \(UIStrings.workflowName(run.workflow, language: .english))",
                simplifiedChinese: "工作流开始：\(UIStrings.workflowName(run.workflow, language: .simplifiedChinese))"
            )
        case .contextCaptured(let context):
            let appName = context.focus.applicationName ?? "Unknown"
            append(
                english: "Context captured from \(appName)",
                simplifiedChinese: "已捕获上下文：\(appName)"
            )
        case .recognitionCompleted(let recognition):
            append(
                english: "Recognition: \(recognition.bestText)",
                simplifiedChinese: "识别结果：\(recognition.bestText)"
            )
        case .candidateResolutionRequested(let candidateCase):
            pendingResolution = candidateCase
            append(
                english: "Candidate resolution requested",
                simplifiedChinese: "已请求候选词消歧"
            )
        case .candidateResolutionFinished(_, let resolvedText):
            pendingResolution = nil
            lastCompletedText = resolvedText
            append(
                english: "Resolution completed: \(resolvedText)",
                simplifiedChinese: "消歧完成：\(resolvedText)"
            )
        case .transformationApplied(_, let text):
            lastCompletedText = text
            append(
                english: "Transformation applied: \(text)",
                simplifiedChinese: "文本处理完成：\(text)"
            )
        case .actionExecuted(let actionID, let result):
            append(
                english: "Action \(actionID): \(result.localizedDescription(language: .english))",
                simplifiedChinese: "动作 \(actionID)：\(result.localizedDescription(language: .simplifiedChinese))"
            )
        case .stackUpdated(let snapshot):
            stackCount = snapshot.count
            stackPreview = snapshot.topPreview
        case .clipboardUpdated(let snapshot):
            updateClipboardSnapshot(snapshot)
        case .clipboardPanelRequested:
            showClipboardPanel()
        case .runCompleted(let summary):
            if activeRunID == summary.runID {
                isRunning = false
                activeRunID = nil
            }
            workflowAudioRunState = .idle
            lastCompletedText = summary.finalText
            lastFailure = nil
            let completedPending = pendingRuns.removeValue(forKey: summary.runID)
            let isStackRelated =
                completedPending?.isStackRelated
                ?? (
                    summary.workflow.titleKey == .stackDelivery
                        || (workflows.first(where: { $0.id == summary.workflowID })?.pipeline.deliveryPolicy.strategy == .stackFirst)
                )
            recordHistory(HistoryRecord(
                runID: summary.runID,
                workflowID: summary.workflowID,
                workflow: summary.workflow,
                finalText: summary.finalText,
                timestamp: summary.finishedAt,
                isStackRelated: isStackRelated,
                outcome: .completed
            ))
            append(
                english: "Run completed: \(summary.finalText)",
                simplifiedChinese: "工作流完成：\(summary.finalText)"
            )
        case .runFailed(let failedRunID, let workflow, let message):
            lastFailure = message
            if activeRunID == failedRunID {
                isRunning = false
                activeRunID = nil
            }
            workflowAudioRunState = .idle
            if let failedRunID, let failedPending = pendingRuns.removeValue(forKey: failedRunID) {
                recordHistory(HistoryRecord(
                    runID: failedRunID,
                    workflowID: failedPending.workflowID,
                    workflow: workflow ?? failedPending.workflow,
                    failureMessage: message,
                    timestamp: Date(),
                    isStackRelated: failedPending.isStackRelated,
                    outcome: .failed
                ))
            } else if failedRunID != nil, let workflow {
                recordHistory(HistoryRecord(
                    runID: failedRunID,
                    workflow: workflow,
                    failureMessage: message,
                    timestamp: Date(),
                    isStackRelated: workflow.titleKey == .stackDelivery,
                    outcome: .failed
                ))
            }
            append(
                english: "Failure: \(message)",
                simplifiedChinese: "失败：\(message)"
            )
        case .diagnostic(let event):
            diagnosticEvents.insert(event, at: 0)
            if diagnosticEvents.count > 50 {
                diagnosticEvents.removeLast(diagnosticEvents.count - 50)
            }
            append(
                english: "[\(UIStrings.subsystem(event.subsystem, language: .english))] \(event.message)",
                simplifiedChinese: "[\(UIStrings.subsystem(event.subsystem, language: .simplifiedChinese))] \(event.message)"
            )
        }
    }

    private func append(english: String, simplifiedChinese: String) {
        let entry = EventFeedEntry(english: english, simplifiedChinese: simplifiedChinese)
        eventFeed.insert(entry, at: 0)
        if eventFeed.count > 20 {
            eventFeed.removeLast(eventFeed.count - 20)
        }
    }

    private func recordHistory(_ record: HistoryRecord) {
        historyRecords.insert(record, at: 0)
        if historyRecords.count > 50 {
            historyRecords.removeLast(historyRecords.count - 50)
        }
        guard let historyRepository else { return }
        Task { [weak self, historyRepository] in
            do {
                try await historyRepository.save(record)
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "History persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "历史记录持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func loadHistory() {
        guard let historyRepository else { return }
        Task { [weak self, historyRepository] in
            do {
                let stored = try await historyRepository.records(matching: HistoryQuery(limit: 50))
                await MainActor.run {
                    self?.historyRecords = stored
                }
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "History repository unavailable: \(error.localizedDescription)",
                        simplifiedChinese: "历史记录仓库不可用：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func loadSettings() {
        guard let settingsStore else { return }
        Task { [weak self, settingsStore] in
            do {
                let storedSettings = try await settingsStore.strings(forKeys: Self.settingsLoadKeys)
                let storedLanguage = storedSettings[.interfaceLanguage]
                let storedWorkflowID = storedSettings[.selectedWorkflowID]
                let storedCustomWorkflows = try Self.loadCustomWorkflows(from: storedSettings[.customWorkflows])
                let storedWorkflowEnabledStates = try Self.loadWorkflowEnabledStates(
                    from: storedSettings[.workflowEnabledStates]
                )
                let storedClipboardMergeSimilarItems = storedSettings[.clipboardMergeSimilarItems]
                let storedClipboardPanelHotkey = storedSettings[.clipboardPanelHotkey]
                let storedPreferredSpeechEngine = storedSettings[.preferredSpeechEngine]
                let storedWhisperKitModel = storedSettings[.whisperKitModel]
                let storedDownloadedWhisperKitModels = try Self.loadDownloadedWhisperKitModels(
                    from: storedSettings[.whisperKitDownloadedModels]
                )
                let storedWhisperKitCustomModel = storedSettings[.whisperKitCustomModel]
                let storedWhisperKitModelRepo = storedSettings[.whisperKitModelRepo]
                let storedWhisperKitModelToken = storedSettings[.whisperKitModelToken]
                let storedWhisperKitModelFolder = storedSettings[.whisperKitModelFolder]
                let storedWhisperKitLanguage = storedSettings[.whisperKitLanguage]
                let storedWhisperKitDownloadIfNeeded = storedSettings[.whisperKitDownloadIfNeeded]
                let storedWhisperKitPrewarm = storedSettings[.whisperKitPrewarm]
                let storedDeepgramAPIKey = storedSettings[.deepgramAPIKey]
                let storedDeepgramBaseURL = storedSettings[.deepgramBaseURL]
                let storedDeepgramModel = storedSettings[.deepgramModel]
                let storedDeepgramLanguage = storedSettings[.deepgramLanguage]

                await MainActor.run {
                    guard let self else { return }
                    self.isRestoringSettings = true

                    if !self.hasModifiedWorkflowLibrary {
                        self.customWorkflows = storedCustomWorkflows
                        self.workflowEnabledStates = storedWorkflowEnabledStates
                        self.rebuildWorkflowLibrary()
                    }

                    if let storedLanguage, let language = AppLanguage(rawValue: storedLanguage) {
                        self.language = language
                    }

                    if let storedClipboardMergeSimilarItems {
                        self.mergeSimilarClipboardItems = Self.storedBoolean(
                            storedClipboardMergeSimilarItems,
                            defaultValue: false
                        )
                    }

                    self.clipboardPanelHotkeyBinding = HotkeyBindingDescriptor(
                        storageString: storedClipboardPanelHotkey
                    )

                    if
                        let storedPreferredSpeechEngine,
                        let preferredSpeechEngine = PreferredSpeechEngine(rawValue: storedPreferredSpeechEngine)
                    {
                        self.preferredSpeechEngine = preferredSpeechEngine
                    }

                    self.downloadedWhisperKitModels = storedDownloadedWhisperKitModels

                    self.whisperKitModelOption = WhisperKitModelOption(storedModelValue: storedWhisperKitModel)

                    if let storedWhisperKitCustomModel {
                        self.whisperKitCustomModel = storedWhisperKitCustomModel
                    } else if self.whisperKitModelOption == .custom, let storedWhisperKitModel {
                        self.whisperKitCustomModel = storedWhisperKitModel
                    }

                    if
                        let storedWorkflowID,
                        let workflowID = UUID(uuidString: storedWorkflowID),
                        self.workflows.contains(where: { $0.id == workflowID })
                    {
                        self.selectedWorkflowID = workflowID
                    }

                    if let storedWhisperKitModel {
                        self.whisperKitModel = storedWhisperKitModel
                    }

                    if let storedWhisperKitModelRepo {
                        self.whisperKitModelRepo = storedWhisperKitModelRepo
                    }

                    if let storedWhisperKitModelToken {
                        self.whisperKitModelToken = storedWhisperKitModelToken
                    }

                    if let storedWhisperKitModelFolder {
                        self.whisperKitModelFolder = storedWhisperKitModelFolder
                    }

                    if let storedWhisperKitLanguage {
                        self.whisperKitLanguage = storedWhisperKitLanguage
                    }

                    if let storedWhisperKitDownloadIfNeeded {
                        self.whisperKitDownloadIfNeeded = Self.storedBoolean(
                            storedWhisperKitDownloadIfNeeded,
                            defaultValue: WhisperKitSettings().downloadIfNeeded
                        )
                    }

                    if let storedWhisperKitPrewarm {
                        self.whisperKitPrewarm = Self.storedBoolean(
                            storedWhisperKitPrewarm,
                            defaultValue: WhisperKitSettings().prewarm
                        )
                    }

                    if let storedDeepgramAPIKey {
                        self.deepgramAPIKey = storedDeepgramAPIKey
                    }

                    if let storedDeepgramBaseURL, !storedDeepgramBaseURL.isEmpty {
                        self.deepgramBaseURL = storedDeepgramBaseURL
                    }

                    if let storedDeepgramModel, !storedDeepgramModel.isEmpty {
                        self.deepgramModel = storedDeepgramModel
                    }

                    if let storedDeepgramLanguage, !storedDeepgramLanguage.isEmpty {
                        self.deepgramLanguage = storedDeepgramLanguage
                    }

                    self.applyPreferredSpeechEngineSelectionIfNeeded()
                    self.rebuildWorkflowLibrary(selecting: self.selectedWorkflowID)
                    self.isRestoringSettings = false
                }
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "Settings repository unavailable: \(error.localizedDescription)",
                        simplifiedChinese: "设置仓库不可用：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func loadDiagnostics() {
        guard let diagnosticRepository else { return }
        Task { [weak self, diagnosticRepository] in
            do {
                let stored = try await diagnosticRepository.events(
                    matching: DiagnosticQuery(limit: 50)
                )
                await MainActor.run {
                    self?.diagnosticEvents = stored
                }
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "Diagnostics repository unavailable: \(error.localizedDescription)",
                        simplifiedChinese: "诊断仓库不可用：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func persistPreferredSpeechEnginePreference() {
        guard !isRestoringSettings, let settingsStore else { return }
        let preferredSpeechEngine = preferredSpeechEngine.rawValue

        Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(preferredSpeechEngine, forKey: .preferredSpeechEngine)
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "Speech engine preference persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "语音引擎偏好持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func persistLanguagePreference() {
        guard !isRestoringSettings, let settingsStore else { return }
        let language = language

        Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(language.rawValue, forKey: .interfaceLanguage)
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "Language persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "语言设置持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func persistSelectedWorkflowPreference() {
        guard !isRestoringSettings, let settingsStore else { return }
        let selectedWorkflowID = selectedWorkflowID.uuidString

        Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(selectedWorkflowID, forKey: .selectedWorkflowID)
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "Workflow selection persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "工作流选择持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func persistClipboardPanelHotkeyPreference() {
        guard !isRestoringSettings, let settingsStore else { return }
        let storageString = clipboardPanelHotkeyBinding.storageString

        Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(storageString, forKey: .clipboardPanelHotkey)
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "Clipboard panel hotkey persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "剪切板页面快捷键持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func persistClipboardMergeSimilarPreference() {
        persistStringSetting(
            mergeSimilarClipboardItems ? "true" : "false",
            for: .clipboardMergeSimilarItems,
            englishFailurePrefix: "Clipboard merge-similar preference persistence failed",
            simplifiedChineseFailurePrefix: "剪切板相似内容合并偏好持久化失败"
        )
    }

    private func persistDeepgramSetting(
        _ value: String,
        for key: AppSettingKey,
        englishFailurePrefix: String,
        simplifiedChineseFailurePrefix: String
    ) {
        persistStringSetting(
            value,
            for: key,
            englishFailurePrefix: englishFailurePrefix,
            simplifiedChineseFailurePrefix: simplifiedChineseFailurePrefix
        )
    }

    private func persistWhisperKitStringSetting(
        _ value: String,
        for key: AppSettingKey,
        englishFailurePrefix: String,
        simplifiedChineseFailurePrefix: String
    ) {
        persistStringSetting(
            value,
            for: key,
            englishFailurePrefix: englishFailurePrefix,
            simplifiedChineseFailurePrefix: simplifiedChineseFailurePrefix
        )
    }

    private func persistWhisperKitBooleanSetting(
        _ value: Bool,
        for key: AppSettingKey,
        englishFailurePrefix: String,
        simplifiedChineseFailurePrefix: String
    ) {
        persistStringSetting(
            value ? "true" : "false",
            for: key,
            englishFailurePrefix: englishFailurePrefix,
            simplifiedChineseFailurePrefix: simplifiedChineseFailurePrefix
        )
    }

    private func persistStringSetting(
        _ value: String,
        for key: AppSettingKey,
        englishFailurePrefix: String,
        simplifiedChineseFailurePrefix: String
    ) {
        guard !isRestoringSettings, let settingsStore else { return }

        if Self.debouncedStringSettingKeys.contains(key) {
            scheduleDebouncedStringSettingWrite(
                value,
                for: key,
                settingsStore: settingsStore,
                englishFailurePrefix: englishFailurePrefix,
                simplifiedChineseFailurePrefix: simplifiedChineseFailurePrefix
            )
            return
        }

        Task { [weak self, settingsStore] in
            do {
                try await settingsStore.setString(value, forKey: key)
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "\(englishFailurePrefix): \(error.localizedDescription)",
                        simplifiedChinese: "\(simplifiedChineseFailurePrefix)：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func scheduleDebouncedStringSettingWrite(
        _ value: String,
        for key: AppSettingKey,
        settingsStore: any SettingsStore,
        englishFailurePrefix: String,
        simplifiedChineseFailurePrefix: String
    ) {
        pendingSettingWriteTasks[key]?.cancel()

        let generation = (pendingSettingWriteGenerations[key] ?? 0) + 1
        pendingSettingWriteGenerations[key] = generation
        let debounceDuration = settingsWriteDebounceDuration

        pendingSettingWriteTasks[key] = Task { [weak self, settingsStore] in
            do {
                try await Task.sleep(for: debounceDuration)
                try Task.checkCancellation()
                try await settingsStore.setString(value, forKey: key)
                await MainActor.run {
                    self?.finishPendingSettingWrite(for: key, generation: generation)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishPendingSettingWrite(for: key, generation: generation)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.finishPendingSettingWrite(for: key, generation: generation)
                    self.append(
                        english: "\(englishFailurePrefix): \(error.localizedDescription)",
                        simplifiedChinese: "\(simplifiedChineseFailurePrefix)：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func finishPendingSettingWrite(for key: AppSettingKey, generation: Int) {
        guard pendingSettingWriteGenerations[key] == generation else { return }
        pendingSettingWriteTasks[key] = nil
        pendingSettingWriteGenerations[key] = nil
    }

    private func resetWhisperKitPreparationStatus() {
        if whisperKitPreparationState != .preparing {
            whisperKitPreparationState = .idle
        }
        whisperKitPreparationProgress = 0
        whisperKitPreparedModelIdentifier = nil
        whisperKitPreparationError = nil
    }

    private func updateClipboardSnapshot(_ snapshot: ClipboardStoreSnapshot) {
        clipboardItems = snapshot.items
        clipboardGroups = snapshot.groups
        clipboardAppAssignments = snapshot.appAssignments
        rebuildClipboardHistoryEntries()
    }

    private func rebuildClipboardHistoryEntries() {
        clipboardHistoryEntries = ClipboardHistoryEntryBuilder.build(
            from: clipboardItems,
            mergeSimilarText: mergeSimilarClipboardItems
        )
    }

    fileprivate func updateWhisperKitPreparationProgress(_ progress: Progress) {
        guard whisperKitPreparationState == .preparing else { return }
        let fraction = progress.fractionCompleted
        if fraction.isFinite {
            whisperKitPreparationProgress = min(max(fraction, 0), 1)
        }
    }

    private func rebuildWorkflowLibrary(selecting workflowID: UUID? = nil) {
        let sortedCustomWorkflows = customWorkflows.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        workflows = sortedCustomWorkflows + builtInWorkflows
        synchronizeWorkflowEnabledStates()
        reconcileSelectedWorkflow(preferredWorkflowID: workflowID)
    }

    private func applyPreferredSpeechEngineSelectionIfNeeded() {
        guard let selectedWorkflow else { return }
        guard selectedWorkflow.titleKey == .localDictation || selectedWorkflow.titleKey == .cloudDictation else { return }

        let targetTitleKey: WorkflowTitleKey = preferredSpeechEngine == .cloud ? .cloudDictation : .localDictation
        guard
            let workflowID = workflows.first(where: {
                $0.titleKey == targetTitleKey && isWorkflowEnabled($0)
            })?.id,
            workflowID != selectedWorkflowID
        else {
            return
        }

        selectedWorkflowID = workflowID
    }

    private func persistCustomWorkflows() {
        guard let settingsStore else { return }
        let customWorkflows = self.customWorkflows

        Task { [weak self, settingsStore] in
            do {
                if customWorkflows.isEmpty {
                    try await settingsStore.removeValue(forKey: .customWorkflows)
                } else {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(customWorkflows)
                    try await settingsStore.setString(
                        String(decoding: data, as: UTF8.self),
                        forKey: .customWorkflows
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.workflowEditorError = self.language == .english
                        ? "Workflow library could not be saved: \(error.localizedDescription)"
                        : "工作流库保存失败：\(error.localizedDescription)"
                    self.append(
                        english: "Workflow library persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "工作流库持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private static func loadCustomWorkflows(
        from rawValue: String?
    ) throws -> [WorkflowDefinition] {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        let data = Data(rawValue.utf8)
        let decoded = try JSONDecoder().decode([WorkflowDefinition].self, from: data)
        return decoded.map(Self.normalizeCustomWorkflow)
    }

    private static func loadWorkflowEnabledStates(
        from rawValue: String?
    ) throws -> [UUID: Bool] {
        guard let rawValue, !rawValue.isEmpty else { return [:] }
        let data = Data(rawValue.utf8)
        let decoded = try JSONDecoder().decode([String: Bool].self, from: data)
        return decoded.reduce(into: [:]) { partialResult, entry in
            guard let workflowID = UUID(uuidString: entry.key) else { return }
            partialResult[workflowID] = entry.value
        }
    }

    private static func loadDownloadedWhisperKitModels(
        from rawValue: String?
    ) throws -> [String] {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        let data = Data(rawValue.utf8)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        return decoded.sorted()
    }

    private static func normalizeCustomWorkflow(_ workflow: WorkflowDefinition) -> WorkflowDefinition {
        var workflow = workflow
        workflow.titleKey = nil
        workflow.metadata[workflowOriginMetadataKey] = userWorkflowOriginMetadataValue
        return workflow
    }

    private func currentWhisperKitSettings() -> WhisperKitSettings {
        WhisperKitSettings(
            model: whisperKitModel,
            modelRepo: whisperKitModelRepo,
            modelToken: whisperKitModelToken,
            modelFolder: whisperKitModelFolder,
            language: whisperKitLanguage,
            downloadIfNeeded: whisperKitDownloadIfNeeded,
            prewarm: whisperKitPrewarm
        )
    }

    private func currentDeepgramSettings() -> DeepgramSettings {
        DeepgramSettings(
            apiKey: deepgramAPIKey,
            baseURL: deepgramBaseURL,
            model: deepgramModel,
            language: deepgramLanguage
        )
    }

    private static func persistWhisperKitSettings(
        _ settings: WhisperKitSettings,
        into settingsStore: any SettingsStore
    ) async throws {
        try await settingsStore.setString(settings.model, forKey: .whisperKitModel)
        try await settingsStore.setString(settings.modelRepo, forKey: .whisperKitModelRepo)
        try await settingsStore.setString(settings.modelToken, forKey: .whisperKitModelToken)
        try await settingsStore.setString(settings.modelFolder, forKey: .whisperKitModelFolder)
        try await settingsStore.setString(settings.language, forKey: .whisperKitLanguage)
        try await settingsStore.setString(
            settings.downloadIfNeeded ? "true" : "false",
            forKey: .whisperKitDownloadIfNeeded
        )
        try await settingsStore.setString(settings.prewarm ? "true" : "false", forKey: .whisperKitPrewarm)
    }

    private static func persistDeepgramSettings(
        _ settings: DeepgramSettings,
        into settingsStore: any SettingsStore
    ) async throws {
        try await settingsStore.setString(settings.apiKey, forKey: .deepgramAPIKey)
        try await settingsStore.setString(settings.baseURL, forKey: .deepgramBaseURL)
        try await settingsStore.setString(settings.model, forKey: .deepgramModel)
        try await settingsStore.setString(settings.language, forKey: .deepgramLanguage)
    }

    private static func storedBoolean(_ value: String, defaultValue: Bool) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    private func persistWorkflowEnabledStates() {
        guard let settingsStore else { return }
        let disabledStates = workflowEnabledStates
            .filter { !$0.value }
            .reduce(into: [String: Bool]()) { partialResult, entry in
                partialResult[entry.key.uuidString] = entry.value
            }

        Task { [weak self, settingsStore] in
            do {
                if disabledStates.isEmpty {
                    try await settingsStore.removeValue(forKey: .workflowEnabledStates)
                } else {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(disabledStates)
                    try await settingsStore.setString(
                        String(decoding: data, as: UTF8.self),
                        forKey: .workflowEnabledStates
                    )
                }
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "Workflow enabled state persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "工作流启用状态持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func persistDownloadedWhisperKitModels() {
        guard let settingsStore else { return }
        let downloadedWhisperKitModels = self.downloadedWhisperKitModels

        Task { [weak self, settingsStore] in
            do {
                if downloadedWhisperKitModels.isEmpty {
                    try await settingsStore.removeValue(forKey: .whisperKitDownloadedModels)
                } else {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(downloadedWhisperKitModels)
                    try await settingsStore.setString(
                        String(decoding: data, as: UTF8.self),
                        forKey: .whisperKitDownloadedModels
                    )
                }
            } catch {
                await MainActor.run {
                    self?.append(
                        english: "WhisperKit downloaded model persistence failed: \(error.localizedDescription)",
                        simplifiedChinese: "WhisperKit 已下载模型持久化失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func recordDownloadedWhisperKitModel(_ modelIdentifier: String) {
        guard !downloadedWhisperKitModels.contains(modelIdentifier) else { return }
        downloadedWhisperKitModels.append(modelIdentifier)
        downloadedWhisperKitModels.sort()
        persistDownloadedWhisperKitModels()
    }

    private func synchronizeWorkflowEnabledStates() {
        let validWorkflowIDs = Set(workflows.map(\.id))
        workflowEnabledStates = workflowEnabledStates.filter { validWorkflowIDs.contains($0.key) }

        for workflow in workflows where workflowEnabledStates[workflow.id] == nil {
            workflowEnabledStates[workflow.id] = true
        }

        updateWorkflowTriggerConflicts()
    }

    private func updateWorkflowTriggerConflicts() {
        let grouped = Dictionary(grouping: workflows.filter { workflow in
            triggerRequiresExclusiveBinding(workflow.trigger) && isWorkflowEnabled(workflow)
        }, by: \.trigger)

        workflowTriggerConflicts = grouped
            .filter { $0.value.count > 1 }
            .map { trigger, workflows in
                WorkflowTriggerConflict(
                    trigger: trigger,
                    workflowIDs: workflows
                        .map(\.id)
                        .sorted { $0.uuidString < $1.uuidString }
                )
            }
            .sorted { $0.trigger.rawValue < $1.trigger.rawValue }

        workflowConflictIDsByWorkflowID = workflowTriggerConflicts.reduce(into: [:]) { result, conflict in
            for workflowID in conflict.workflowIDs {
                result[workflowID] = conflict.workflowIDs.filter { $0 != workflowID }
            }
        }
    }

    private func triggerRequiresExclusiveBinding(_ trigger: TriggerBinding) -> Bool {
        switch trigger {
        case .manual, .menuBar:
            return false
        case .hotkey, .wakeWord:
            return true
        }
    }

    private func reconcileSelectedWorkflow(preferredWorkflowID: UUID? = nil) {
        let desiredWorkflowID = preferredWorkflowID ?? selectedWorkflowID

        if
            let desiredWorkflow = workflows.first(where: { $0.id == desiredWorkflowID }),
            isWorkflowEnabled(desiredWorkflow)
        {
            selectedWorkflowID = desiredWorkflow.id
            return
        }

        if let firstEnabledWorkflowID = workflows.first(where: { isWorkflowEnabled($0) })?.id {
            selectedWorkflowID = firstEnabledWorkflowID
            return
        }

        if workflows.contains(where: { $0.id == desiredWorkflowID }) {
            selectedWorkflowID = desiredWorkflowID
        } else if let firstWorkflowID = workflows.first?.id {
            selectedWorkflowID = firstWorkflowID
        }
    }

    private func conflictingEnabledWorkflowsForActivation(of workflow: WorkflowDefinition) -> [WorkflowDefinition] {
        guard workflow.trigger != .manual else { return [] }
        return workflows.filter { candidate in
            candidate.id != workflow.id &&
                candidate.trigger == workflow.trigger &&
                isWorkflowEnabled(candidate)
        }
    }
}

private struct PendingRunInfo {
    let workflowID: UUID
    let workflow: WorkflowPresentation
    let isStackRelated: Bool
}

extension AppModel {
    nonisolated static let whisperKitRecognizerID = "whisperkit.local"
    nonisolated static let deepgramRecognizerID = "deepgram.prerecorded"
    nonisolated static let workflowOriginMetadataKey = "workflow.origin"
    nonisolated static let userWorkflowOriginMetadataValue = "user"
    nonisolated static let defaultHotkeyGesture = "control-option-shift-space"
}

private extension ActionResult {
    func localizedDescription(language: AppLanguage) -> String {
        switch self {
        case .injected:
            return language == .english ? "injected" : "已注入"
        case .copiedToClipboard:
            return language == .english ? "copied to clipboard" : "已复制到剪贴板"
        case .pushedToStack:
            return language == .english ? "pushed to stack" : "已压入栈"
        case .skipped(let reason):
            return language == .english ? "skipped (\(reason))" : "已跳过（\(reason)）"
        case .failed(let reason):
            return language == .english ? "failed (\(reason))" : "失败（\(reason)）"
        }
    }
}

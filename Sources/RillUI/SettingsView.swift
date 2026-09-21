import SwiftUI
import RillCore

enum SettingsDestructiveConfirmation: Sendable {
  case clipboardHistory
  case runHistory
  case failedAudioRecovery
  case benchmarkRecordingArchive
  case sensitiveAppRule(UUID)
}

enum SettingsSheetDestination: Identifiable {
  case privacyNotice(PrivacyNoticeDocument)

  var id: String {
    switch self {
    case .privacyNotice:
      return "privacy-notice"
    }
  }
}

enum LLMModelSelection: String, CaseIterable, Identifiable {
  case deepSeek
  case luna
  case terra
  case sol
  case custom

  var id: String { rawValue }

  var modelIdentifier: String? {
    switch self {
    case .deepSeek:
      LLMTextProcessing.deepSeekModel
    case .luna:
      OpenAIModelOption.luna.rawValue
    case .terra:
      OpenAIModelOption.terra.rawValue
    case .sol:
      OpenAIModelOption.sol.rawValue
    case .custom:
      nil
    }
  }

  init(modelIdentifier: String) {
    switch modelIdentifier {
    case LLMTextProcessing.deepSeekModel:
      self = .deepSeek
    case OpenAIModelOption.luna.rawValue:
      self = .luna
    case OpenAIModelOption.terra.rawValue:
      self = .terra
    case OpenAIModelOption.sol.rawValue:
      self = .sol
    default:
      self = .custom
    }
  }
}

struct VoiceAssistantSettingsActionVisibility: Equatable {
  let showsWakeWordPreparation: Bool
  let showsTTSPreparation: Bool
  let showsStopPlayback: Bool

  init(
    wakeWordState: VoiceAssistantResourceState,
    ttsState: VoiceAssistantResourceState,
    isSpeechPlaybackActive: Bool
  ) {
    showsWakeWordPreparation = Self.showsPreparation(for: wakeWordState)
    showsTTSPreparation = Self.showsPreparation(for: ttsState)
    showsStopPlayback = isSpeechPlaybackActive
  }

  private static func showsPreparation(
    for state: VoiceAssistantResourceState
  ) -> Bool {
    switch state {
    case .notInstalled, .failed:
      true
    case .preparing, .ready, .unavailable:
      false
    }
  }
}

enum SettingsPermissionAction: Equatable {
  case none
  case request
  case openSettings
}

enum SettingsPermissionTone: Equatable {
  case success
  case secondary
  case warning
  case error
}

struct SettingsPermissionPresentation: Equatable {
  let detail: String
  let tone: SettingsPermissionTone
  let action: SettingsPermissionAction

  static func make(
    state: PermissionState,
    isRequired: Bool,
    optionalDetail: String?,
    language: AppLanguage
  ) -> Self {
    if state == .granted {
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .success,
        action: .none
      )
    }
    if !isRequired {
      return Self(
        detail: optionalDetail
          ?? UIStrings.permissionState(state, language: language),
        tone: .secondary,
        action: .none
      )
    }
    switch state {
    case .granted:
      preconditionFailure("Granted permissions are handled above")
    case .unknown:
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .warning,
        action: .request
      )
    case .denied:
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .error,
        action: .openSettings
      )
    }
  }
}

public struct SettingsView: View {
  @Bindable var model: AppModel
  let privacyNoticeDocument: PrivacyNoticeDocument?
  @State var vocabularyKind: VocabularyRuleKind = .mapping
  @State var vocabularyPattern = ""
  @State var vocabularyReplacement = ""
  @State var vocabularyMatchMode: VocabularyMatchMode = .exactPhrase
  @State var vocabularyCaseSensitive = false
  @State var vocabularyBundleIdentifier = ""
  @State var vocabularyGroupID: UUID?
  @State var vocabularyLocale = ""
  @State var vocabularyPriority = 0
  @State var sensitiveAppBundleIdentifier = ""
  @State var sensitiveAppApplicationName = ""
  @State var editingSensitiveAppRuleID: UUID?
  @State var sensitiveAppRuleError: String?
  @State var destructiveConfirmation: SettingsDestructiveConfirmation?
  @State var presentedSheet: SettingsSheetDestination?
  private let pane: SettingsPane
  @State private var expandedSettingsSections: Set<SettingsSection> = []
  @State private var showsDiagnostics = false
  @State var wakePhrasesText: String
  @State var wakeListeningDraftEnabled: Bool
  @State var isApplyingWakeWordSettings = false
  @State var wakeWordSettingsError: String?
  @FocusState private var focusedSettingsSection: SettingsSection?
  @FocusState var wakePhrasesFieldFocused: Bool
  @AccessibilityFocusState private var accessibilityFocusedSettingsSection: SettingsSection?
  // Shared with the section extensions for Reduce-Motion-aware transitions.
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  public init(
    model: AppModel,
    privacyNoticeDocument: PrivacyNoticeDocument? = PrivacyNoticeDocument.bundled,
    pane: SettingsPane = .general
  ) {
    self.model = model
    self.pane = pane
    _expandedSettingsSections = State(initialValue: Set(pane.sections))
    self.privacyNoticeDocument = privacyNoticeDocument
    let wakeWordSettings = model.wakeWordSettingsSnapshot
    _wakePhrasesText = State(
      initialValue: wakeWordSettings.phrases.joined(separator: "\n")
    )
    _wakeListeningDraftEnabled = State(
      initialValue: wakeWordSettings.isEnabled
    )
  }

  public var body: some View {
    ScrollViewReader { proxy in
      Form {
        if let unsavedSummary = model.settingsSaveState.unsavedSummary {
          settingsSaveFailureSection(unsavedSummary)
        }
        switch pane {
        case .general:
          Section { languageSection }
        case .input:
          Section { builtinPushToTalkSection; recordPanelSection }
        case .voice:
          Section { speechEngineSection; voiceAssistantResourcesSection }
        case .vocabulary:
          Section {
            vocabularySection
            if let memory = model.contextMemory {
              ContextMemorySettingsView(memory: memory, workflows: model.workflows.filter(\.supportsContextualCorrection), language: model.language, isExpanded: settingsDisclosureBinding(for: .contextMemory))
                .id(SettingsSection.contextMemory)
                .accessibilityIdentifier("settings.section.contextMemory")
                .focusable()
                .focused($focusedSettingsSection, equals: .contextMemory)
                .accessibilityFocused($accessibilityFocusedSettingsSection, equals: .contextMemory)
            }
          }
        case .privacy:
          Section { permissionsSection; privacySection }
        case .data:
          Section { localDataAndRetentionSection; diagnosticsEntryRow }
        }
      }
      .formStyle(.grouped)
      .task(id: model.settingsNavigationRequest?.id) {
        guard let request = model.settingsNavigationRequest else { return }
        await positionSettingsSection(request, proxy: proxy)
      }
    }
    .navigationTitle(pane.title(language: model.language))
    .sheet(isPresented: $showsDiagnostics) {
      VStack(spacing: 0) {
        HStack {
          Text(UIStrings.text(.sidebarDiagnostics, language: model.language)).font(.headline)
          Spacer()
          Button(L10n.workspace(.done, language: model.language)) { showsDiagnostics = false }
            .keyboardShortcut(.cancelAction)
        }.padding()
        DiagnosticsView(model: model)
      }.frame(minWidth: 680, minHeight: 480)
    }
    .sheet(item: $presentedSheet) { destination in
      switch destination {
      case .privacyNotice(let document):
        PrivacyNoticeSheet(document: document, language: model.language)
      }
    }
    .confirmationDialog(
      destructiveConfirmationTitle,
      isPresented: Binding(
        get: { destructiveConfirmation != nil },
        set: { isPresented in
          if !isPresented {
            destructiveConfirmation = nil
          }
        }
      ),
      presenting: destructiveConfirmation
    ) { confirmation in
      Button(destructiveConfirmationActionTitle(confirmation), role: .destructive) {
        destructiveConfirmation = nil
        performDestructiveConfirmation(confirmation)
      }
      Button(
        L10n.historySettingsText(.cancel, language: model.language),
        role: .cancel
      ) {
        destructiveConfirmation = nil
      }
    } message: { confirmation in
      Text(destructiveConfirmationDetail(confirmation))
    }
  }

  private var permissionsSection: some View {
    settingsDisclosure(.permissions) {
      HStack {
        Spacer()
        Button(UIStrings.text(.refreshPermissions, language: model.language)) {
          model.refreshPermissions()
        }
      }

      globalInputPermissionRow(model.globalInputCapability)

      permissionRow(
        title: UIStrings.text(.accessibility, language: model.language),
        state: model.permissionSnapshot.accessibility,
        isRequired: model.voiceSetupReadiness.accessibilityRequired,
        optionalDetail: UIStrings.text(
          .voiceSetupAccessibilityOptional,
          language: model.language
        ),
        requestAction: model.requestAccessibilityPermission,
        openSettingsAction: model.openAccessibilitySettings
      )

      permissionRow(
        title: UIStrings.text(.microphone, language: model.language),
        state: model.permissionSnapshot.microphone,
        requestAction: model.requestMicrophonePermission,
        openSettingsAction: model.openMicrophoneSettings
      )

      if model.voiceSetupReadiness.accessibilityRequired,
        model.permissionSnapshot.accessibility != .granted
      {
        Text(UIStrings.text(.appNotListedHint, language: model.language))
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Text(UIStrings.text(.permissionHint, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

}

extension SettingsView {
  private var recordPanelSection: some View {
    settingsDisclosure(.recordPanel) {
      if model.hasUnavailableScalarSettings(in: .systemClipboard) {
        unavailableScalarSettingsWarning(.systemClipboard)
      }

      Toggle(
        UIStrings.text(
          .settingsClipboardCaptureEnabled,
          language: model.language
        ),
        isOn: Binding(
          get: { model.systemClipboardCaptureEnabled },
          set: { model.setSystemClipboardCaptureEnabled($0) }
        )
      )
      .disabled(!model.canMutateScalarSettings(in: .systemClipboard))
      .accessibilityIdentifier("settings.systemClipboard.capture-enabled")

      Text(
        UIStrings.text(
          .settingsClipboardCaptureEnabledDescription,
          language: model.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      HotkeyRecorderView(
        binding: model.recordPanelHotkeyBinding,
        language: model.language,
        beginRecordPanelShortcutRecording: {
          model.beginRecordPanelShortcutRecording()
        },
        endRecordPanelShortcutRecording: { suspensionID in
          model.endRecordPanelShortcutRecording(suspensionID)
        },
        commitRecordPanelShortcutRecording: { suspensionID, keyCode in
          model.commitRecordPanelShortcutRecording(
            suspensionID,
            keyCode: keyCode
          )
        },
        onRecord: { shortcut in
          model.setRecordPanelHotkeyShortcut(shortcut)
        },
        onReset: {
          model.resetRecordPanelHotkeyBinding()
        }
      )
      .disabled(model.hasUnavailableScalarSettings(in: .systemClipboard))

      Text(UIStrings.text(.settingsRecordPanelDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var languageSection: some View {
    settingsDisclosure(.language) {
      if model.hasUnavailableScalarSettings(in: .interface) {
        unavailableScalarSettingsWarning(.interface)
      }

      Picker(
        UIStrings.text(.language, language: model.language),
        selection: Binding(
          get: { model.language },
          set: { model.setInterfaceLanguage($0) }
        )
      ) {
        ForEach(AppLanguage.allCases) { language in
          Text(language.displayName).tag(language)
        }
      }
      .pickerStyle(.segmented)
      // Keep the two language segments compact instead of stretching across
      // the full form width.
      .frame(maxWidth: 260)
      .disabled(!model.canMutateScalarSettings(in: .interface))

      Text(UIStrings.text(.settingsLanguageDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func settingsSectionHeader(_ section: SettingsSection) -> some View {
    Label(section.title(language: model.language), systemImage: section.symbolName)

  }

  private var diagnosticsEntryRow: some View {
    Button {
      showsDiagnostics = true
    } label: {
      HStack {
        Label(
          UIStrings.text(.sidebarDiagnostics, language: model.language),
          systemImage: SidebarSection.diagnostics.symbolName
        )
        Spacer()
        Image(systemName: RillSystemSymbol.chevronRight.rawValue)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(SettingsNavigationRowButtonStyle())
    .accessibilityIdentifier("settings.diagnostics.open")
    .id(SettingsSection.diagnostics)
    .focused($focusedSettingsSection, equals: .diagnostics)
    .accessibilityFocused($accessibilityFocusedSettingsSection, equals: .diagnostics)
  }

  func settingsDisclosure<Content: View>(
    _ section: SettingsSection,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    DisclosureGroup(isExpanded: settingsDisclosureBinding(for: section)) {
      VStack(alignment: .leading, spacing: 12) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        settingsSectionHeader(section)
        Text(settingsSectionSummary(section))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 2)
    }
    .focusable()
    .focused($focusedSettingsSection, equals: section)
    .accessibilityFocused($accessibilityFocusedSettingsSection, equals: section)
    .accessibilityIdentifier("settings.section.\(section.rawValue)")
    .id(section)
  }

  private func settingsDisclosureBinding(
    for section: SettingsSection
  ) -> Binding<Bool> {
    Binding(
      get: { expandedSettingsSections.contains(section) },
      set: { isExpanded in
        if isExpanded {
          expandedSettingsSections.insert(section)
        } else {
          expandedSettingsSections.remove(section)
        }
      }
    )
  }

  private func settingsSectionSummary(_ section: SettingsSection) -> String {
    switch section {
    case .permissions:
      return UIStrings.text(.microphone, language: model.language) + " · "
        + UIStrings.permissionState(model.permissionSnapshot.microphone, language: model.language)
    case .speech:
      let name = model.selectedTrustedLocalSpeechModelIdentifier
      return name.isEmpty
        ? UIStrings.speechEngine(model.preferredSpeechEngine, language: model.language)
        : UIStrings.speechEngine(model.preferredSpeechEngine, language: model.language) + " · " + name
    case .input:
      return UIStrings.builtinPushToTalkOutputMode(model.builtinPushToTalkOutputMode, language: model.language)
    case .language:
      return model.language.displayName
    case .storage:
      return L10n.historySettingsText(.runRetention, language: model.language) + " · "
        + L10n.historyRetentionPeriod(model.runHistoryRetentionPeriod, language: model.language)
    default:
      return L10n.settingsSectionSummary(section, language: model.language)
    }
  }

  private func positionSettingsSection(
    _ request: SettingsNavigationRequest,
    proxy: ScrollViewProxy
  ) async {
    await Task.yield()
    guard pane == request.section.pane,
      model.settingsNavigationRequest?.id == request.id
    else {
      return
    }
    if request.section == .diagnostics { showsDiagnostics = true }
    expandedSettingsSections.insert(request.section)
    await Task.yield()
    // Navigation scroll, not decorative motion: keep the fixed duration
    // easing so section positioning stays predictable.
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      proxy.scrollTo(request.section, anchor: .top)
    }
    await waitForMainRunLoopDefaultMode()
    guard !Task.isCancelled, model.settingsNavigationRequest?.id == request.id else { return }
    focusedSettingsSection = request.section
    accessibilityFocusedSettingsSection = request.section
    model.settingsNavigationRequest = nil
  }

  private var destructiveConfirmationTitle: String {
    guard let destructiveConfirmation else { return "" }
    return switch destructiveConfirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboardConfirmation, language: model.language)
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmation, language: model.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmation,
        language: model.language
      )
    case .benchmarkRecordingArchive:
      L10n.string(
        .settingsBenchmarkRecordingArchiveClearConfirmation,
        language: model.language
      )
    case .sensitiveAppRule:
      L10n.settingsText(.settingsSensitiveAppRuleDeleteConfirmation, language: model.language)
    }
  }

  private func destructiveConfirmationActionTitle(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboard, language: model.language)
    case .runHistory:
      L10n.historySettingsText(.clearRun, language: model.language)
    case .failedAudioRecovery:
      L10n.string(.settingsFailedAudioRecoveryClear, language: model.language)
    case .benchmarkRecordingArchive:
      L10n.string(.settingsBenchmarkRecordingArchiveClear, language: model.language)
    case .sensitiveAppRule:
      L10n.privacyText(.deleteRule, language: model.language)
    }
  }

  private func destructiveConfirmationDetail(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(
        .clearClipboardConfirmationDetail,
        language: model.language
      )
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmationDetail, language: model.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmationDetail,
        language: model.language
      )
    case .benchmarkRecordingArchive:
      L10n.string(
        .settingsBenchmarkRecordingArchiveClearConfirmationDetail,
        language: model.language
      )
    case .sensitiveAppRule:
      L10n.settingsText(
        .settingsSensitiveAppRuleDeleteConfirmationDetail,
        language: model.language
      )
    }
  }

  private func performDestructiveConfirmation(
    _ confirmation: SettingsDestructiveConfirmation
  ) {
    switch confirmation {
    case .clipboardHistory:
      model.clearRecordHistory()
    case .runHistory:
      model.clearRunHistory()
    case .failedAudioRecovery:
      model.clearFailedAudioRecoveries()
    case .benchmarkRecordingArchive:
      model.clearBenchmarkRecordingArchive()
    case .sensitiveAppRule(let ruleID):
      if let rule = model.privacyPolicySettings.sensitiveAppRules.first(where: {
        $0.id == ruleID
      }) {
        deleteSensitiveAppRule(rule)
      }
    }
  }

  private func permissionRow(
    title: String,
    state: PermissionState,
    isRequired: Bool = true,
    optionalDetail: String? = nil,
    requestAction: @escaping () -> Void,
    openSettingsAction: @escaping () -> Void
  ) -> some View {
    let presentation = SettingsPermissionPresentation.make(
      state: state,
      isRequired: isRequired,
      optionalDetail: optionalDetail,
      language: model.language
    )
    return HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(presentation.detail)
          .font(.caption)
          .foregroundStyle(permissionColor(presentation.tone))
      }
      Spacer()
      switch presentation.action {
      case .none:
        EmptyView()
      case .request:
        Button(UIStrings.text(.requestAccess, language: model.language)) {
          requestAction()
        }
      case .openSettings:
        Button(UIStrings.text(.openSettings, language: model.language)) {
          openSettingsAction()
        }
      }
    }
  }

  private func settingsSaveFailureSection(
    _ summary: UnsavedSettingsSummary
  ) -> some View {
    Section {
      Label(
        UIStrings.text(.settingsSaveFailedTitle, language: model.language),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .foregroundStyle(.orange)
      .accessibilityIdentifier("settings.unsaved.title")

      Text(UIStrings.settingsSaveFailureDescription(summary, language: model.language))
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("settings.unsaved.description")

      HStack {
        Spacer()
        Button {
          model.retryUnsavedSettingsSave()
        } label: {
          if model.settingsSaveState.isRetrying {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(UIStrings.text(.settingsSaveRetrying, language: model.language))
            }
          } else {
            Text(UIStrings.text(.settingsSaveRetry, language: model.language))
          }
        }
        .disabled(model.settingsSaveState.isRetrying)
        .accessibilityIdentifier("settings.unsaved.retry")
      }
    }
  }

  func unavailableScalarSettingsWarning(
    _ domain: ScalarSettingsDomain
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        domain.unavailableWarning(language: model.language),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .font(.callout)
      .foregroundStyle(.orange)

      HStack {
        Spacer()
        Button {
          model.retryUnavailableScalarSettings(in: domain)
        } label: {
          if model.isRetryingUnavailableScalarSettings(in: domain) {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(UIStrings.text(.settingsSaveRetrying, language: model.language))
            }
          } else {
            Text(L10n.settingsText(.settingsRetryLoading, language: model.language))
          }
        }
        .disabled(model.isRetryingUnavailableScalarSettings(in: domain))
        .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue).retry")
      }
    }
    .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue)")
  }

  @ViewBuilder
  private func globalInputPermissionRow(_ capability: GlobalInputCapability) -> some View {
    let title = UIStrings.text(.globalInput, language: model.language)
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(globalInputPermissionDetail(capability))
          .font(.caption)
          .foregroundStyle(globalInputPermissionColor(capability))
      }
      Spacer()
      switch capability {
      case .checking, .available:
        EmptyView()
      case .permissionRequired:
        Button(UIStrings.text(.requestAccess, language: model.language)) {
          model.requestGlobalInputPermission()
        }
        .accessibilityIdentifier("settings.global-input.request")
      case .installationFailed:
        Button(UIStrings.text(.retryGlobalInput, language: model.language)) {
          model.retryGlobalInputInstallation()
        }
        .accessibilityIdentifier("settings.global-input.retry")
      }
    }
    .accessibilityIdentifier("settings.global-input.status")
  }

  private func globalInputPermissionDetail(_ capability: GlobalInputCapability) -> String {
    let key: UIStrings.Key =
      switch capability {
      case .checking:
        .voiceSetupGlobalInputChecking
      case .available:
        .voiceSetupGlobalInputReady
      case .permissionRequired:
        .voiceSetupGlobalInputPermissionNeeded
      case .installationFailed:
        .voiceSetupGlobalInputInstallationFailed
      }
    return UIStrings.text(key, language: model.language)
  }

  private func globalInputPermissionColor(_ capability: GlobalInputCapability) -> Color {
    switch capability {
    case .checking:
      .secondary
    case .available:
      .green
    case .permissionRequired:
      .orange
    case .installationFailed:
      .red
    }
  }

  private var builtinPushToTalkSection: some View {
    settingsDisclosure(.input) {
      if model.hasUnavailableScalarSettings(in: .input) {
        unavailableScalarSettingsWarning(.input)
      }

      Toggle(
        L10n.string(.settingsLongRecordingMode, language: model.language),
        isOn: Binding(
          get: { model.longRecordingModeEnabled },
          set: { model.setLongRecordingModeEnabled($0) }
        )
      )
      .disabled(!model.canMutateScalarSettings(in: .input))

      Text(L10n.string(.settingsLongRecordingModeDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker(
        L10n.string(.settingsRecordingDurationLimit, language: model.language),
        selection: Binding(
          get: { model.recordingDurationLimit },
          set: { _ = model.setRecordingDurationLimit($0) }
        )
      ) {
        ForEach(RecordingDurationLimit.allCases) { limit in
          Text(UIStrings.recordingDurationLimit(limit, language: model.language)).tag(limit)
        }
      }
      .pickerStyle(.menu)
      .disabled(!model.canMutateScalarSettings(in: .input))

      Text(L10n.string(.settingsRecordingDurationLimitDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker(
        UIStrings.text(.builtinPushToTalkOutputMode, language: model.language),
        selection: Binding(
          get: { model.builtinPushToTalkOutputMode },
          set: { model.setBuiltinPushToTalkOutputMode($0) }
        )
      ) {
        ForEach(BuiltinPushToTalkOutputMode.allCases) { mode in
          Text(UIStrings.builtinPushToTalkOutputMode(mode, language: model.language)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .disabled(!model.canMutateScalarSettings(in: .input))
      Text(UIStrings.text(.settingsBuiltinPushToTalkDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func permissionColor(_ tone: SettingsPermissionTone) -> Color {
    switch tone {
    case .success: return .green
    case .secondary: return .secondary
    case .warning: return .orange
    case .error: return .red
    }
  }
}

/// Hover feedback for plain navigation rows in settings, mirroring
/// RillCardButtonStyle's pointer acknowledgement as a quiet fill instead of
/// a stroke so the row's layout inside the grouped form stays untouched.
private struct SettingsNavigationRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SettingsNavigationRowButtonBody(configuration: configuration)
  }
}

private struct SettingsNavigationRowButtonBody: View {
  let configuration: ButtonStyleConfiguration

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: RillRadius.row, style: .continuous)
          .fill(
            .quaternary.opacity(isHovering ? RillCardProminence.regular.fillOpacity : 0)
          )
      }
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.15),
        value: isHovering
      )
      .onHover { isHovering = $0 }
  }
}

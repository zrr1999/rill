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
  case benchmarkArchive

  var id: String {
    switch self {
    case .privacyNotice:
      return "privacy-notice"
    case .benchmarkArchive:
      return "benchmark-archive"
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
        detail: L10n.permissionState(state, language: language),
        tone: .success,
        action: .none
      )
    }
    if !isRequired {
      return Self(
        detail: optionalDetail
          ?? L10n.permissionState(state, language: language),
        tone: .secondary,
        action: .none
      )
    }
    switch state {
    case .granted:
      preconditionFailure("Granted permissions are handled above")
    case .unknown:
      return Self(
        detail: L10n.permissionState(state, language: language),
        tone: .warning,
        action: .request
      )
    case .denied:
      return Self(
        detail: L10n.permissionState(state, language: language),
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
  @FocusState var focusedSettingsItem: SettingsItem?
  @AccessibilityFocusState var accessibilityFocusedSettingsItem: SettingsItem?
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
          if let input = model.inputMethod { InputMethodSettingsView(input: input, language: model.settings.language) }
        case .voice:
          Section { speechEngineSection; apiProviderSettingsSection; voiceAssistantResourcesSection }
        case .vocabulary:
          Section {
            vocabularySection
            if let memory = model.contextMemory {
              ContextMemorySettingsView(memory: memory, workflows: model.workflowLibrary.workflows.filter(\.supportsContextualCorrection), language: model.settings.language, isExpanded: settingsDisclosureBinding(for: .contextMemory))
                .id(SettingsSection.contextMemory)
                .disclosureGroupStyle(settingsDisclosureStyle(for: .contextMemory))
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
    .navigationTitle(pane.title(language: model.settings.language))
    .sheet(isPresented: $showsDiagnostics) {
      VStack(spacing: 0) {
        HStack {
          Text(L10n.text(.sidebarDiagnostics, language: model.settings.language)).font(.headline)
          Spacer()
          Button(L10n.workspace(.done, language: model.settings.language)) { showsDiagnostics = false }
            .keyboardShortcut(.cancelAction)
        }.padding()
        DiagnosticsView(model: model)
      }.frame(minWidth: 680, minHeight: 480)
    }
    .sheet(item: $presentedSheet) { destination in
      switch destination {
      case .privacyNotice(let document):
        PrivacyNoticeSheet(document: document, language: model.settings.language)
      case .benchmarkArchive:
        BenchmarkRecordingArchiveSheet(model: model.benchmarkArchive, language: model.settings.language)
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
        L10n.historySettingsText(.cancel, language: model.settings.language),
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
        Button(L10n.text(.refreshPermissions, language: model.settings.language)) {
          model.refreshPermissions()
        }
      }

      globalInputPermissionRow(model.globalInputCapability)

      permissionRow(
        title: L10n.text(.accessibility, language: model.settings.language),
        state: model.permissionSnapshot.accessibility,
        isRequired: model.voiceSetupReadiness.accessibilityRequired,
        optionalDetail: L10n.text(
          .voiceSetupAccessibilityOptional,
          language: model.settings.language
        ),
        requestAction: model.requestAccessibilityPermission,
        openSettingsAction: model.openAccessibilitySettings
      )

      permissionRow(
        title: L10n.text(.microphone, language: model.settings.language),
        state: model.permissionSnapshot.microphone,
        requestAction: model.requestMicrophonePermission,
        openSettingsAction: model.openMicrophoneSettings
      )

      if model.voiceSetupReadiness.accessibilityRequired,
        model.permissionSnapshot.accessibility != .granted
      {
        Text(L10n.text(.appNotListedHint, language: model.settings.language))
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Text(L10n.text(.permissionHint, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

}

extension SettingsView {
  private var recordPanelSection: some View {
    settingsDisclosure(.recordPanel) {
      if model.settings.hasUnavailableScalarSettings(in: .systemClipboard) {
        unavailableScalarSettingsWarning(.systemClipboard)
      }

      Toggle(
        L10n.text(
          .settingsClipboardCaptureEnabled,
          language: model.settings.language
        ),
        isOn: Binding(
          get: { model.settings.systemClipboardCaptureEnabled },
          set: { model.setSystemClipboardCaptureEnabled($0) }
        )
      )
      .disabled(!model.settings.canMutateScalarSettings(in: .systemClipboard))
      .accessibilityIdentifier("settings.systemClipboard.capture-enabled")

      Text(
        L10n.text(
          .settingsClipboardCaptureEnabledDescription,
          language: model.settings.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      HotkeyRecorderView(
        binding: model.settings.recordPanelHotkeyBinding,
        language: model.settings.language,
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
      .disabled(model.settings.hasUnavailableScalarSettings(in: .systemClipboard))

      Text(L10n.text(.settingsRecordPanelDescription, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var languageSection: some View {
    settingsDisclosure(.language) {
      if model.settings.hasUnavailableScalarSettings(in: .interface) {
        unavailableScalarSettingsWarning(.interface)
      }

      Picker(
        L10n.text(.language, language: model.settings.language),
        selection: Binding(
          get: { model.settings.language },
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
      .disabled(!model.settings.canMutateScalarSettings(in: .interface))

      Text(L10n.text(.settingsLanguageDescription, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func settingsSectionHeader(_ section: SettingsSection) -> some View {
    Label(section.title(language: model.settings.language), systemImage: section.symbolName)

  }

  private var diagnosticsEntryRow: some View {
    Button {
      showsDiagnostics = true
    } label: {
      HStack {
        Label(
          L10n.text(.sidebarDiagnostics, language: model.settings.language),
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
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        settingsSectionHeader(section)
        Text(settingsSectionSummary(section))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 2)
    }
    .disclosureGroupStyle(settingsDisclosureStyle(for: section))
    .id(section)
  }

  private func settingsDisclosureStyle(for section: SettingsSection) -> SettingsDisclosureStyle {
    SettingsDisclosureStyle(section: section, keyboardFocus: $focusedSettingsSection,
      accessibilityFocus: $accessibilityFocusedSettingsSection)
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
      return L10n.text(.microphone, language: model.settings.language) + " · "
        + L10n.permissionState(model.permissionSnapshot.microphone, language: model.settings.language)
    case .speech:
      let name = model.selectedTrustedLocalSpeechModelIdentifier
      return name.isEmpty
        ? L10n.speechEngine(model.settings.preferredSpeechEngine, language: model.settings.language)
        : L10n.speechEngine(model.settings.preferredSpeechEngine, language: model.settings.language) + " · " + name
    case .input:
      return L10n.builtinPushToTalkOutputMode(model.settings.builtinPushToTalkOutputMode, language: model.settings.language)
    case .language:
      return model.settings.language.displayName
    case .storage:
      return L10n.historySettingsText(.runRetention, language: model.settings.language) + " · "
        + L10n.historyRetentionPeriod(model.history.runHistoryRetentionPeriod, language: model.settings.language)
    default:
      return L10n.settingsSectionSummary(section, language: model.settings.language)
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
      if let item = request.item { proxy.scrollTo(item, anchor: .top) }
      else { proxy.scrollTo(request.section, anchor: .top) }
    }
    await waitForMainRunLoopDefaultMode()
    guard !Task.isCancelled, model.settingsNavigationRequest?.id == request.id else { return }
    if let item = request.item {
      focusedSettingsItem = item
      accessibilityFocusedSettingsItem = item
    } else {
      focusedSettingsSection = request.section
      accessibilityFocusedSettingsSection = request.section
    }
    model.settingsNavigationRequest = nil
  }

  private var destructiveConfirmationTitle: String {
    guard let destructiveConfirmation else { return "" }
    return switch destructiveConfirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboardConfirmation, language: model.settings.language)
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmation, language: model.settings.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmation,
        language: model.settings.language
      )
    case .benchmarkRecordingArchive:
      L10n.string(
        .settingsBenchmarkRecordingArchiveClearConfirmation,
        language: model.settings.language
      )
    case .sensitiveAppRule:
      L10n.settingsText(.settingsSensitiveAppRuleDeleteConfirmation, language: model.settings.language)
    }
  }

  private func destructiveConfirmationActionTitle(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboard, language: model.settings.language)
    case .runHistory:
      L10n.historySettingsText(.clearRun, language: model.settings.language)
    case .failedAudioRecovery:
      L10n.string(.settingsFailedAudioRecoveryClear, language: model.settings.language)
    case .benchmarkRecordingArchive:
      L10n.string(.settingsBenchmarkRecordingArchiveClear, language: model.settings.language)
    case .sensitiveAppRule:
      L10n.privacyText(.deleteRule, language: model.settings.language)
    }
  }

  private func destructiveConfirmationDetail(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(
        .clearClipboardConfirmationDetail,
        language: model.settings.language
      )
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmationDetail, language: model.settings.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmationDetail,
        language: model.settings.language
      )
    case .benchmarkRecordingArchive:
      L10n.string(
        .settingsBenchmarkRecordingArchiveClearConfirmationDetail,
        language: model.settings.language
      )
    case .sensitiveAppRule:
      L10n.settingsText(
        .settingsSensitiveAppRuleDeleteConfirmationDetail,
        language: model.settings.language
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
      model.benchmarkArchive.clear()
    case .sensitiveAppRule(let ruleID):
      if let rule = model.settings.privacyPolicySettings.sensitiveAppRules.first(where: {
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
      language: model.settings.language
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
        Button(L10n.text(.requestAccess, language: model.settings.language)) {
          requestAction()
        }
      case .openSettings:
        Button(L10n.text(.openSettings, language: model.settings.language)) {
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
        L10n.text(.settingsSaveFailedTitle, language: model.settings.language),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .foregroundStyle(.orange)
      .accessibilityIdentifier("settings.unsaved.title")

      Text(L10n.settingsSaveFailureDescription(summary, language: model.settings.language))
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
              Text(L10n.text(.settingsSaveRetrying, language: model.settings.language))
            }
          } else {
            Text(L10n.text(.settingsSaveRetry, language: model.settings.language))
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
        domain.unavailableWarning(language: model.settings.language),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .font(.callout)
      .foregroundStyle(.orange)

      HStack {
        Spacer()
        Button {
          model.retryUnavailableScalarSettings(in: domain)
        } label: {
          if model.settings.isRetryingUnavailableScalarSettings(in: domain) {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(L10n.text(.settingsSaveRetrying, language: model.settings.language))
            }
          } else {
            Text(L10n.settingsText(.settingsRetryLoading, language: model.settings.language))
          }
        }
        .disabled(model.settings.isRetryingUnavailableScalarSettings(in: domain))
        .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue).retry")
      }
    }
    .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue)")
  }

  @ViewBuilder
  private func globalInputPermissionRow(_ capability: GlobalInputCapability) -> some View {
    let title = L10n.text(.globalInput, language: model.settings.language)
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
        Button(L10n.text(.requestAccess, language: model.settings.language)) {
          model.requestGlobalInputPermission()
        }
        .accessibilityIdentifier("settings.global-input.request")
      case .installationFailed:
        Button(L10n.text(.retryGlobalInput, language: model.settings.language)) {
          model.retryGlobalInputInstallation()
        }
        .accessibilityIdentifier("settings.global-input.retry")
      }
    }
    .accessibilityIdentifier("settings.global-input.status")
  }

  private func globalInputPermissionDetail(_ capability: GlobalInputCapability) -> String {
    let key: L10n.InterfaceKey =
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
    return L10n.text(key, language: model.settings.language)
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
      if model.settings.hasUnavailableScalarSettings(in: .input) {
        unavailableScalarSettingsWarning(.input)
      }

      Toggle(
        L10n.string(.settingsLongRecordingMode, language: model.settings.language),
        isOn: Binding(
          get: { model.settings.longRecordingModeEnabled },
          set: { model.setLongRecordingModeEnabled($0) }
        )
      )
      .disabled(!model.settings.canMutateScalarSettings(in: .input))

      Text(L10n.string(.settingsLongRecordingModeDescription, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker(
        L10n.string(.settingsRecordingDurationLimit, language: model.settings.language),
        selection: Binding(
          get: { model.settings.recordingDurationLimit },
          set: { _ = model.setRecordingDurationLimit($0) }
        )
      ) {
        ForEach(RecordingDurationLimit.allCases) { limit in
          Text(L10n.recordingDurationLimit(limit, language: model.settings.language)).tag(limit)
        }
      }
      .pickerStyle(.menu)
      .disabled(!model.settings.canMutateScalarSettings(in: .input))

      Text(L10n.string(.settingsRecordingDurationLimitDescription, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker(
        L10n.text(.builtinPushToTalkOutputMode, language: model.settings.language),
        selection: Binding(
          get: { model.settings.builtinPushToTalkOutputMode },
          set: { model.setBuiltinPushToTalkOutputMode($0) }
        )
      ) {
        ForEach(BuiltinPushToTalkOutputMode.allCases) { mode in
          Text(L10n.builtinPushToTalkOutputMode(mode, language: model.settings.language)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .disabled(!model.settings.canMutateScalarSettings(in: .input))
      Text(L10n.text(.settingsBuiltinPushToTalkDescription, language: model.settings.language))
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

// Settings navigation targets the header, never the expanded content container.
struct SettingsDisclosureStyle: DisclosureGroupStyle {
  let section: SettingsSection
  let keyboardFocus: FocusState<SettingsSection?>.Binding
  let accessibilityFocus: AccessibilityFocusState<SettingsSection?>.Binding
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.semibold))
          .frame(width: 12)
          .accessibilityHidden(true)
        configuration.label
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .focusable(isEnabled)
      .focused(keyboardFocus, equals: section)
      .onTapGesture { if isEnabled { configuration.isExpanded.toggle() } }
      .onKeyPress(.space) {
        guard isEnabled else { return .ignored }
        configuration.isExpanded.toggle()
        return .handled
      }
      .accessibilityRepresentation {
        DisclosureGroup(isExpanded: configuration.$isExpanded) {
          EmptyView()
        } label: {
          configuration.label
        }
        .disclosureGroupStyle(.automatic)
        .accessibilityFocused(accessibilityFocus, equals: section)
        .accessibilityIdentifier("settings.section.\(section.rawValue)")
      }

      if configuration.isExpanded {
        VStack(alignment: .leading, spacing: 12) {
          configuration.content.disclosureGroupStyle(.automatic)
        }
        .padding(.top, 8)
      }
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

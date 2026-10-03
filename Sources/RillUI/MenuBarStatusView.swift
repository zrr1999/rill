import Foundation
import SwiftUI
import RillCore

enum MenuBarLayoutMetrics {
  static let contentWidth: CGFloat = 360
}

struct MenuBarFixedWidthText: View {
  let text: String

  var body: some View {
    Text(text)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(width: MenuBarLayoutMetrics.contentWidth, alignment: .leading)
      // The .menu bar-extra style does not reliably present tooltips, so the
      // fixed width remains a copy-length budget; .help still exposes the
      // full string wherever tooltips do render.
      .help(text)
  }
}

struct MenuBarFixedWidthLabel: View {
  let title: String
  let systemImage: String

  var body: some View {
    Label {
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
    } icon: {
      Image(systemName: systemImage)
    }
    .frame(width: MenuBarLayoutMetrics.contentWidth, alignment: .leading)
    // Same tooltip caveat as MenuBarFixedWidthText: under the .menu style
    // this may never surface, so keep titles short enough for 360pt.
    .help(title)
  }
}

public enum MenuBarSystemSymbolPolicy {
  public static func symbol(
    isVoiceRunActive: Bool,
    globalInputCapability: GlobalInputCapability,
    systemClipboardCaptureEnabled: Bool,
    clipboardCaptureState: SystemClipboardCaptureControlState,
    recordCount: Int
  ) -> RillSystemSymbol {
    if isVoiceRunActive {
      return .micFill
    }

    switch globalInputCapability {
    case .checking:
      return .questionmarkBubble
    case .permissionRequired, .installationFailed:
      return .exclamationmarkCircleFill
    case .available:
      break
    }

    guard systemClipboardCaptureEnabled else {
      return .waveform
    }
    switch clipboardCaptureState {
    case .pausing, .paused:
      return .waveform
    case .resuming:
      return .playCircleFill
    case .armingIgnoreNextExternalChange, .ignoringNextExternalChange:
      return .eyeSlashFill
    case .active:
      return recordCount > 0 ? .squareStack3dUpFill : .waveform
    }
  }
}

public enum MenuBarVoiceSetupStatus: Sendable, Equatable {
  case loading
  case incomplete
  case ready

  init(readiness: VoiceSetupReadiness) {
    if readiness.isComplete {
      self = .ready
    } else if readiness.globalInput == .checking
      || readiness.provider == .loading
      || readiness.privacy == .loading
    {
      self = .loading
    } else {
      self = .incomplete
    }
  }
}

public struct MenuBarOperationPanelState: Sendable, Equatable {
  public let language: AppLanguage
  public let isRunning: Bool
  public let activeStage: WorkflowRunStage?
  public let lastCompletedText: String?
  public let lastFailure: String?
  public let recordCount: Int
  public let canDeliverNextRecord: Bool
  public let preferredSpeechEngine: PreferredSpeechEngine
  public let outputMode: BuiltinPushToTalkOutputMode
  public let longRecordingModeEnabled: Bool
  public let systemClipboardCaptureEnabled: Bool
  public let clipboardSettingsAvailable: Bool
  public let clipboardCaptureState: SystemClipboardCaptureControlState
  public let voiceSetupStatus: MenuBarVoiceSetupStatus
  public let localPersistenceStatus: LocalPersistenceStatus

  public init(
    language: AppLanguage,
    isRunning: Bool,
    activeStage: WorkflowRunStage? = nil,
    lastCompletedText: String? = nil,
    lastFailure: String? = nil,
    recordCount: Int,
    canDeliverNextRecord: Bool,
    preferredSpeechEngine: PreferredSpeechEngine,
    outputMode: BuiltinPushToTalkOutputMode,
    longRecordingModeEnabled: Bool = false,
    systemClipboardCaptureEnabled: Bool = true,
    clipboardSettingsAvailable: Bool = true,
    clipboardCaptureState: SystemClipboardCaptureControlState = .active,
    voiceSetupStatus: MenuBarVoiceSetupStatus = .ready,
    localPersistenceStatus: LocalPersistenceStatus = .ready
  ) {
    self.language = language
    self.isRunning = isRunning
    self.activeStage = activeStage
    self.lastCompletedText = lastCompletedText
    self.lastFailure = lastFailure
    self.recordCount = recordCount
    self.canDeliverNextRecord = canDeliverNextRecord
    self.preferredSpeechEngine = preferredSpeechEngine
    self.outputMode = outputMode
    self.longRecordingModeEnabled = longRecordingModeEnabled
    self.systemClipboardCaptureEnabled = systemClipboardCaptureEnabled
    self.clipboardSettingsAvailable = clipboardSettingsAvailable
    self.clipboardCaptureState = clipboardCaptureState
    self.voiceSetupStatus = voiceSetupStatus
    self.localPersistenceStatus = localPersistenceStatus
  }

  public var canCopyLastResult: Bool {
    trimmedLastResult != nil
  }

  public var trimmedLastResult: String? {
    trimmedNonEmpty(lastCompletedText)
  }

  public var statusTitle: String {
    if trimmedFailure != nil {
      return L10n.string(.menuStatusNeedsAttention, language: language)
    }

    if isRunning {
      return activeStage.map { L10n.runStageTitle($0, language: language) }
        ?? L10n.string(.menuStatusRunning, language: language)
    }

    switch voiceSetupStatus {
    case .loading:
      return L10n.string(.menuStatusSetupLoading, language: language)
    case .incomplete:
      return L10n.string(.menuStatusFinishSetup, language: language)
    case .ready:
      break
    }

    return L10n.string(.menuStatusReady, language: language)
  }

  public var statusDetail: String? {
    if let failure = trimmedFailure {
      return RecordTextFormatting.previewText(failure, limit: 96)
    }

    if isRunning {
      return L10n.string(.menuStatusRunningDetail, language: language)
    }

    switch voiceSetupStatus {
    case .loading:
      return L10n.string(.menuStatusSetupLoadingDetail, language: language)
    case .incomplete:
      return L10n.string(.menuStatusFinishSetupDetail, language: language)
    case .ready:
      break
    }

    return L10n.string(
      longRecordingModeEnabled ? .menuToggleRecordingHint : .menuHoldToTalkHint,
      language: language
    )
  }

  public var statusSystemImage: String {
    if trimmedFailure != nil {
      return RillSystemSymbol.exclamationmarkTriangleFill.rawValue
    }

    if isRunning {
      return RillSystemSymbol.waveformCircleFill.rawValue
    }

    switch voiceSetupStatus {
    case .loading:
      return RillSystemSymbol.hourglassCircle.rawValue
    case .incomplete:
      return RillSystemSymbol.exclamationmarkCircleFill.rawValue
    case .ready:
      break
    }

    return RillSystemSymbol.checkmarkCircle.rawValue
  }

  public var outputModeTitle: String {
    switch outputMode {
    case .pasteIntoApp:
      return L10n.string(.menuPasteIntoApp, language: language)
    case .saveToVoiceGroup:
      return L10n.string(.menuSaveToVoiceGroup, language: language)
    }
  }

  public var longRecordingModeTitle: String {
    longRecordingModeEnabled
      ? L10n.string(.menuLongRecordingToggle, language: language)
      : L10n.string(.menuLongRecordingToggleOff, language: language)
  }

  public var clipboardCaptureStatusTitle: String {
    guard systemClipboardCaptureEnabled else {
      return L10n.string(.menuClipboardCaptureOff, language: language)
    }
    return switch clipboardCaptureState {
    case .active:
      L10n.string(.menuClipboardCaptureActive, language: language)
    case .pausing, .paused, .resuming:
      L10n.string(.menuClipboardCaptureTurningOn, language: language)
    case .armingIgnoreNextExternalChange:
      L10n.string(.menuClipboardIgnoreNextArming, language: language)
    case .ignoringNextExternalChange:
      L10n.string(.menuClipboardIgnoreNextPending, language: language)
    }
  }

  public var clipboardMenuTitle: String {
    let key: L10n.Key
    if !systemClipboardCaptureEnabled {
      key = .menuClipboardOff
    } else {
      key =
        switch clipboardCaptureState {
        case .active: .menuClipboardOn
        case .pausing, .paused, .resuming: .menuClipboardStarting
        case .armingIgnoreNextExternalChange: .menuClipboardIgnorePreparing
        case .ignoringNextExternalChange: .menuClipboardIgnoringNext
        }
    }
    return L10n.string(key, language: language)
  }

  public var clipboardCaptureStatusSystemImage: String {
    guard systemClipboardCaptureEnabled else { return RillSystemSymbol.powerCircleFill.rawValue }
    return switch clipboardCaptureState {
    case .active:
      RillSystemSymbol.checkmarkShield.rawValue
    case .pausing, .paused, .resuming:
      RillSystemSymbol.playCircleFill.rawValue
    case .armingIgnoreNextExternalChange, .ignoringNextExternalChange:
      RillSystemSymbol.eyeSlashFill.rawValue
    }
  }

  public var clipboardCaptureToggleTitle: String {
    let key: L10n.Key =
      systemClipboardCaptureEnabled
      ? .menuTurnOffClipboardCapture
      : .menuTurnOnClipboardCapture
    return L10n.string(key, language: language)
  }

  public var clipboardCaptureToggleSystemImage: String {
    systemClipboardCaptureEnabled ? RillSystemSymbol.power.rawValue : RillSystemSymbol.playCircle.rawValue
  }

  public var canToggleClipboardCapture: Bool {
    clipboardSettingsAvailable
  }

  public var canIgnoreNextExternalCopy: Bool {
    clipboardSettingsAvailable
      && systemClipboardCaptureEnabled
      && clipboardCaptureState == .active
  }

  public var persistenceStatusTitle: String? {
    persistencePresentation?.menuTitle
  }

  public var persistenceStatusDetail: String? {
    persistencePresentation?.menuDetail
  }

  public var persistenceStatusSystemImage: String? {
    persistencePresentation == nil
      ? nil
      : RillSystemSymbol.externaldriveBadgeExclamationmark.rawValue
  }

  private var trimmedFailure: String? {
    trimmedNonEmpty(lastFailure)
  }

  private var persistencePresentation: LocalPersistenceStatusPresentation? {
    LocalPersistenceStatusPresentation.make(
      status: localPersistenceStatus,
      language: language
    )
  }

  private func trimmedNonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }
}

public struct MenuBarStatusView: View {
  @Bindable private var model: AppModel
  private let openMainWindow: () -> Void
  private let openAbout: () -> Void
  private let quitApplication: () -> Void

  public init(
    model: AppModel,
    openMainWindow: @escaping () -> Void = {},
    openAbout: @escaping () -> Void = {},
    quitApplication: @escaping () -> Void = {}
  ) {
    self.model = model
    self.openMainWindow = openMainWindow
    self.openAbout = openAbout
    self.quitApplication = quitApplication
  }

  public var body: some View {
    Group {
      statusHeader

      if !model.isApplicationShuttingDown {
        Divider()

        Button {
          model.recordWorkspace.buffers.openEditorAction()
        } label: {
          Label(
            L10n.string(.menuOpenDrafts, language: model.settings.language),
            systemImage: RillSystemSymbol.squareAndPencil.rawValue
          )
        }
        .accessibilityIdentifier("menu.open-drafts")

        Button {
          model.selectSidebarSection(.records)
          openMainWindow()
        } label: {
          Label(
            L10n.workspace(.allRecords, language: model.settings.language),
            systemImage: RillSystemSymbol.squareStack3dUp.rawValue
          )
        }
        .keyboardShortcut("b", modifiers: .command)
        .accessibilityIdentifier("menu.clipboard.open-history")

        Button {
          model.showRunHistory()
          openMainWindow()
        } label: {
          Label(
            L10n.text(.sidebarStream, language: model.settings.language),
            systemImage: RillSystemSymbol.clockArrowCirclepath.rawValue
          )
        }
        .accessibilityIdentifier("menu.open-activity")

        Divider()

        Button {
          copyLastCompletedText()
        } label: {
          Label(
            L10n.string(.menuCopyLastResult, language: model.settings.language),
            systemImage: RillSystemSymbol.docOnDoc.rawValue
          )
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!panelState.canCopyLastResult)
        .accessibilityIdentifier("menu.copy-last-transcription")

        Menu {
          voiceInputMenu
        } label: {
          Label(
            L10n.string(.menuVoiceInput, language: model.settings.language),
            systemImage: RillSystemSymbol.micFill.rawValue
          )
        }
        .accessibilityIdentifier("menu.voice-input")

        Menu {
          clipboardMenu
        } label: {
          Label(
            panelState.clipboardMenuTitle,
            systemImage: RillSystemSymbol.docOnClipboard.rawValue
          )
        }
        .accessibilityIdentifier("menu.clipboard")

        Menu {
          workflowMenu
        } label: {
          Label(
            L10n.string(.menuWorkflows, language: model.settings.language),
            systemImage: RillSystemSymbol.point3ConnectedTrianglepathDotted.rawValue
          )
        }
        .accessibilityIdentifier("menu.workflows")

        Divider()

        Button {
          openMainWindow()
        } label: {
          Label(
            L10n.string(.menuOpenMainWindow, language: model.settings.language),
            systemImage: RillSystemSymbol.macwindow.rawValue
          )
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button {
          model.presentSettings()
          openMainWindow()
        } label: {
          Label(L10n.text(.settingsTitle, language: model.settings.language), systemImage: RillSystemSymbol.gearshape.rawValue)
        }
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityIdentifier("menu.open-settings")

        Button {
          openAbout()
        } label: {
          Label(L10n.string(.menuAbout, language: model.settings.language), systemImage: RillSystemSymbol.infoCircle.rawValue)
        }

        Divider()

        Button(role: .destructive) {
          quitApplication()
        } label: {
          Label(L10n.string(.menuQuit, language: model.settings.language), systemImage: RillSystemSymbol.power.rawValue)
        }
        .keyboardShortcut("q", modifiers: .command)
      }
    }
    .labelStyle(.titleAndIcon)
  }

  @ViewBuilder
  private var statusHeader: some View {
    if model.isApplicationShuttingDown {
      Label(
        L10n.string(.applicationShutdownTitle, language: model.settings.language),
        systemImage: RillSystemSymbol.hourglassCircle.rawValue
      )
      .accessibilityIdentifier("menu.status.shutdown")

      MenuBarFixedWidthText(
        text: L10n.string(.applicationShutdownDetail, language: model.settings.language)
      )
      .accessibilityIdentifier("menu.status.shutdown-detail")
    } else if model.lastFailure != nil {
      Button {
        model.showRunHistory()
        openMainWindow()
      } label: {
        Label(panelState.statusTitle, systemImage: panelState.statusSystemImage)
      }
      .accessibilityIdentifier("menu.status.open-activity")
    } else if panelState.voiceSetupStatus == .ready || model.voice.isRunning {
      Label(panelState.statusTitle, systemImage: panelState.statusSystemImage)
        .accessibilityIdentifier("menu.status.summary")
    } else {
      Button {
        model.voiceSetupPresentation = .presented
        openMainWindow()
      } label: {
        Label(panelState.statusTitle, systemImage: panelState.statusSystemImage)
      }
      .accessibilityIdentifier("menu.status.open-setup")
    }

    if !model.isApplicationShuttingDown, let statusDetail = panelState.statusDetail {
      MenuBarFixedWidthText(text: statusDetail)
        .accessibilityIdentifier("menu.status.detail")
    }

    if let persistenceTitle = panelState.persistenceStatusTitle,
      let persistenceSystemImage = panelState.persistenceStatusSystemImage,
      let persistenceDetail = panelState.persistenceStatusDetail
    {
      Button {
        openStorageSettings()
      } label: {
        MenuBarFixedWidthLabel(title: persistenceTitle, systemImage: persistenceSystemImage)
      }
      .accessibilityIdentifier("menu.status.open-storage-settings")

      MenuBarFixedWidthText(text: persistenceDetail)
        .accessibilityIdentifier("menu.status.persistence-detail")
    }
  }

  func openStorageSettings() {
    openSettings(.storage)
  }

  private func openSettings(_ section: SettingsSection) {
    model.showSettings(section)
    openMainWindow()
  }

  private var panelState: MenuBarOperationPanelState {
    MenuBarOperationPanelState(
      language: model.settings.language,
      isRunning: model.voice.isRunning,
      activeStage: model.voice.activeStage,
      lastCompletedText: model.voice.lastCompletedText,
      lastFailure: model.lastFailure,
      recordCount: model.recordCount,
      canDeliverNextRecord: model.canDeliverNextRecord,
      preferredSpeechEngine: model.settings.preferredSpeechEngine,
      outputMode: model.settings.builtinPushToTalkOutputMode,
      longRecordingModeEnabled: model.settings.longRecordingModeEnabled,
      systemClipboardCaptureEnabled: model.settings.systemClipboardCaptureEnabled,
      clipboardSettingsAvailable: model.settings.canMutateScalarSettings(in: .systemClipboard),
      clipboardCaptureState: model.systemClipboardCaptureControlSnapshot.state,
      voiceSetupStatus: MenuBarVoiceSetupStatus(readiness: model.voiceSetupReadiness),
      localPersistenceStatus: model.localPersistenceStatus
    )
  }

  private func copyLastCompletedText() {
    guard let text = panelState.trimmedLastResult else { return }
    model.copyTextToClipboard(text)
  }

  @ViewBuilder
  private func scalarSettingsUnavailableNotice(
    _ domain: ScalarSettingsDomain
  ) -> some View {
    if model.settings.hasUnavailableScalarSettings(in: domain) {
      MenuBarFixedWidthLabel(
        title: domain.unavailableWarning(language: model.settings.language),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .accessibilityIdentifier("menu.settings-unavailable.\(domain.rawValue)")

      Divider()
    }
  }
}

private extension MenuBarStatusView {
  @ViewBuilder
  var voiceInputMenu: some View {
    scalarSettingsUnavailableNotice(.input)

    Picker(
      L10n.string(.menuRecordingMode, language: model.settings.language),
      selection: Binding(
        get: { model.settings.longRecordingModeEnabled },
        set: { model.setLongRecordingModeEnabled($0) }
      )
    ) {
      Text(L10n.string(.menuLongRecordingToggleOff, language: model.settings.language))
        .tag(false)
      Text(L10n.string(.menuLongRecordingToggle, language: model.settings.language))
        .tag(true)
    }
    .pickerStyle(.inline)
    .disabled(!model.settings.canMutateScalarSettings(in: .input))

    Divider()

    Picker(
      L10n.string(.menuTextOutput, language: model.settings.language),
      selection: Binding(
        get: { model.settings.builtinPushToTalkOutputMode },
        set: { model.setBuiltinPushToTalkOutputMode($0) }
      )
    ) {
      Text(L10n.string(.menuPasteIntoApp, language: model.settings.language))
        .tag(BuiltinPushToTalkOutputMode.pasteIntoApp)
      Text(L10n.string(.menuSaveToVoiceGroup, language: model.settings.language))
        .tag(BuiltinPushToTalkOutputMode.saveToVoiceGroup)
    }
    .pickerStyle(.inline)
    .disabled(!model.settings.canMutateScalarSettings(in: .input))

    Divider()

    Button {
      openSettings(.input)
    } label: {
      Label(
        L10n.string(.menuVoiceInputSettings, language: model.settings.language),
        systemImage: RillSystemSymbol.gearshape.rawValue
      )
    }
  }

  @ViewBuilder
  var clipboardMenu: some View {
    Label(
      panelState.clipboardCaptureStatusTitle,
      systemImage: panelState.clipboardCaptureStatusSystemImage
    )
    .accessibilityIdentifier("menu.status.clipboard-capture")

    if panelState.recordCount > 0 {
      MenuBarFixedWidthText(
        text: L10n.menuClipboardReadyStatus(panelState.recordCount, language: model.settings.language)
      )
      .accessibilityIdentifier("menu.clipboard.ready-count")
    }

    Divider()

    scalarSettingsUnavailableNotice(.systemClipboard)

    Button {
      model.toggleClipboardCaptureEnabled()
    } label: {
      Label(
        panelState.clipboardCaptureToggleTitle,
        systemImage: panelState.clipboardCaptureToggleSystemImage
      )
    }
    .disabled(!panelState.canToggleClipboardCapture)
    .accessibilityIdentifier("menu.clipboard.capture-toggle")

    Button {
      model.ignoreNextExternalClipboardChange()
    } label: {
      Label(
        L10n.string(.menuIgnoreNextExternalCopy, language: model.settings.language),
        systemImage: RillSystemSymbol.eyeSlash.rawValue
      )
    }
    .disabled(!panelState.canIgnoreNextExternalCopy)
    .accessibilityIdentifier("menu.clipboard.ignore-next")

    Button {
      model.deliverNextRecord()
    } label: {
      Label(
        L10n.string(.menuDeliverNextRecord, language: model.settings.language), systemImage: RillSystemSymbol.arrowDownDoc.rawValue)
    }
    .disabled(!panelState.canDeliverNextRecord)

    Divider()

    Button {
      openSettings(.recordPanel)
    } label: {
      Label(
        L10n.string(.menuClipboardSettings, language: model.settings.language),
        systemImage: RillSystemSymbol.gearshape.rawValue
      )
    }
  }

  @ViewBuilder
  var workflowMenu: some View {
    Menu {
      textStyleMenu
    } label: {
      Label(
        L10n.string(.menuTextStyles, language: model.settings.language),
        systemImage: RillSystemSymbol.wandAndStars.rawValue
      )
    }

    Menu {
      longRecordingWorkflowMenu
    } label: {
      Label(
        L10n.string(.menuLongRecording, language: model.settings.language),
        systemImage: RillSystemSymbol.recordCircle.rawValue
      )
    }

    Menu {
      manualWorkflowMenu
    } label: {
      Label(
        L10n.string(.menuManualWorkflows, language: model.settings.language),
        systemImage: RillSystemSymbol.squareStack3dUp.rawValue
      )
    }

    Divider()

    Button {
      model.openWorkflowEditor()
      openMainWindow()
    } label: {
      Label(
        L10n.text(.openWorkflowEditor, language: model.settings.language),
        systemImage: RillSystemSymbol.squareAndPencil.rawValue
      )
    }
  }

  @ViewBuilder
  var textStyleMenu: some View {
    if model.enabledTextStyleWorkflows.isEmpty {
      Text(L10n.string(.menuNoTextStyleWorkflows, language: model.settings.language))
    } else {
      ForEach(model.enabledTextStyleWorkflows) { workflow in
        Button {
          model.runWorkflow(workflow)
        } label: {
          let presentation = VoiceWorkflowPresentation(workflow: workflow)
          MenuBarFixedWidthLabel(
            title: presentation.menuTitle(
              workflowName: model.workflowMenuButtonTitle(for: workflow),
              language: model.settings.language
            ),
            systemImage: presentation.textStyle.systemImage
          )
        }
        .disabled(!model.canTriggerWorkflow(workflow))
      }
    }
  }

  @ViewBuilder
  var longRecordingWorkflowMenu: some View {
    if model.enabledLongRecordingWorkflows.isEmpty {
      Text(L10n.string(.menuNoLongRecordingWorkflows, language: model.settings.language))
    } else {
      ForEach(model.enabledLongRecordingWorkflows) { workflow in
        Button {
          model.runWorkflow(workflow)
        } label: {
          MenuBarFixedWidthLabel(
            title: model.workflowMenuButtonTitle(for: workflow),
            systemImage: RillSystemSymbol.resolvedName(workflow.ui.symbolName)
          )
        }
        .disabled(!model.canTriggerWorkflow(workflow))
      }
    }
  }

  @ViewBuilder
  var manualWorkflowMenu: some View {
    if model.enabledManualWorkflows.isEmpty {
      Text(L10n.string(.menuNoManualWorkflows, language: model.settings.language))
    } else {
      ForEach(model.enabledManualWorkflows) { workflow in
        Button {
          model.runWorkflow(workflow)
        } label: {
          MenuBarFixedWidthLabel(
            title: model.workflowMenuButtonTitle(for: workflow),
            systemImage: RillSystemSymbol.resolvedName(workflow.ui.symbolName)
          )
        }
        .disabled(!model.canTriggerWorkflow(workflow))
      }
    }
  }
}

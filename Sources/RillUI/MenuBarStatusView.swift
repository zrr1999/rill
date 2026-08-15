import Foundation
import SwiftUI
import RillCore

private struct RecordPanelKeyboardShortcutModifier: ViewModifier {
  let isVisible: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isVisible {
      content.keyboardShortcut("b", modifiers: .command)
    } else {
      content
    }
  }
}

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
      return L10n.string(.menuStatusRunning, language: language)
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

    if recordCount > 0 {
      return L10n.menuClipboardReadyStatus(recordCount, language: language)
    }

    return nil
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

    if recordCount > 0 {
      return RillSystemSymbol.squareStack3dUpFill.rawValue
    }

    return RillSystemSymbol.checkmarkCircle.rawValue
  }

  public var speechEngineTitle: String {
    L10n.string(.menuLocalEngine, language: language)
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
          openMainWindow()
        } label: {
          Label(
            L10n.string(.menuOpenMainWindow, language: model.language),
            systemImage: RillSystemSymbol.macwindow.rawValue
          )
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button {
          model.showRunHistory()
          openMainWindow()
        } label: {
          Label(
            UIStrings.text(.historyScopeAll, language: model.language),
            systemImage: RillSystemSymbol.clockArrowCirclepath.rawValue)
        }

        Button {
          model.selectSidebarSection(.records)
          openMainWindow()
        } label: {
          Label(
            UIStrings.text(.sidebarRecords, language: model.language),
            systemImage: RillSystemSymbol.squareStack3dUp.rawValue
          )
        }
        .modifier(
          RecordPanelKeyboardShortcutModifier(
            isVisible: RecordPanelShortcutPresentationPolicy.surfaceVisibility(
              systemClipboardCaptureEnabled: model.systemClipboardCaptureEnabled
            ).menuShortcutAnnotation
          )
        )
        .accessibilityIdentifier("menu.clipboard.open-history")

        Button {
          copyLastCompletedText()
        } label: {
          Label(
            L10n.string(.menuCopyLastResult, language: model.language), systemImage: RillSystemSymbol.docOnDoc.rawValue)
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!panelState.canCopyLastResult)

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
            L10n.string(.menuIgnoreNextExternalCopy, language: model.language),
            systemImage: RillSystemSymbol.eyeSlash.rawValue
          )
        }
        .disabled(!panelState.canIgnoreNextExternalCopy)
        .accessibilityIdentifier("menu.clipboard.ignore-next")

        Divider()

        Menu {
          languageMenu
        } label: {
          Label(L10n.string(.menuInterfaceLanguage, language: model.language), systemImage: RillSystemSymbol.globe.rawValue)
        }

        Menu {
          textStyleMenu
        } label: {
          Label(
            L10n.string(.menuTextStyles, language: model.language), systemImage: RillSystemSymbol.wandAndStars.rawValue)
        }

        Menu {
          textOutputMenu
        } label: {
          Label(L10n.string(.menuTextOutput, language: model.language), systemImage: RillSystemSymbol.textformat.rawValue)
        }

        Menu {
          longRecordingMenu
        } label: {
          Label(
            L10n.string(.menuLongRecording, language: model.language), systemImage: RillSystemSymbol.recordCircle.rawValue)
        }

        Menu {
          workflowMenu
        } label: {
          Label(
            L10n.string(.menuWorkflows, language: model.language),
            systemImage: RillSystemSymbol.squareStack3dUp.rawValue
          )
        }

        Divider()

        Button {
          model.selectSidebarSection(.settings)
          openMainWindow()
        } label: {
          Label(UIStrings.text(.settingsTitle, language: model.language), systemImage: RillSystemSymbol.gearshape.rawValue)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
          openAbout()
        } label: {
          Label(L10n.string(.menuAbout, language: model.language), systemImage: RillSystemSymbol.infoCircle.rawValue)
        }

        Divider()

        Button(role: .destructive) {
          quitApplication()
        } label: {
          Label(L10n.string(.menuQuit, language: model.language), systemImage: RillSystemSymbol.xmarkSquare.rawValue)
        }
        .keyboardShortcut("q", modifiers: .command)
      }
    }
  }

  @ViewBuilder
  private var statusHeader: some View {
    if model.isApplicationShuttingDown {
      Label(
        L10n.string(.applicationShutdownTitle, language: model.language),
        systemImage: RillSystemSymbol.hourglassCircle.rawValue
      )
      .accessibilityIdentifier("menu.status.shutdown")

      MenuBarFixedWidthText(
        text: L10n.string(.applicationShutdownDetail, language: model.language)
      )
      .accessibilityIdentifier("menu.status.shutdown-detail")
    } else if panelState.voiceSetupStatus == .ready || model.isRunning || model.lastFailure != nil {
      Label(panelState.statusTitle, systemImage: panelState.statusSystemImage)
        .accessibilityIdentifier("menu.status.summary")
    } else {
      Button {
        model.selectSidebarSection(.dashboard)
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

    Label(panelState.outputModeTitle, systemImage: RillSystemSymbol.textformat.rawValue)
      .accessibilityIdentifier("menu.status.output-mode")

    Label(panelState.longRecordingModeTitle, systemImage: RillSystemSymbol.recordCircle.rawValue)
      .accessibilityIdentifier("menu.status.long-recording")

    Label(
      panelState.clipboardCaptureStatusTitle,
      systemImage: panelState.clipboardCaptureStatusSystemImage
    )
    .accessibilityIdentifier("menu.status.clipboard-capture")
  }

  func openStorageSettings() {
    model.showSettings(.storage)
    openMainWindow()
  }


  private var panelState: MenuBarOperationPanelState {
    MenuBarOperationPanelState(
      language: model.language,
      isRunning: model.isRunning,
      lastCompletedText: model.lastCompletedText,
      lastFailure: model.lastFailure,
      recordCount: model.recordCount,
      canDeliverNextRecord: model.canDeliverNextRecord,
      preferredSpeechEngine: model.preferredSpeechEngine,
      outputMode: model.builtinPushToTalkOutputMode,
      longRecordingModeEnabled: model.longRecordingModeEnabled,
      systemClipboardCaptureEnabled: model.systemClipboardCaptureEnabled,
      clipboardSettingsAvailable: model.canMutateScalarSettings(in: .systemClipboard),
      clipboardCaptureState: model.systemClipboardCaptureControlSnapshot.state,
      voiceSetupStatus: MenuBarVoiceSetupStatus(readiness: model.voiceSetupReadiness),
      localPersistenceStatus: model.localPersistenceStatus
    )
  }

  private func copyLastCompletedText() {
    guard let text = panelState.trimmedLastResult else { return }
    model.copyTextToClipboard(text)
  }

  private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
    Label(
      title,
      systemImage: isSelected
        ? RillSystemSymbol.checkmark.rawValue
        : RillSystemSymbol.circle.rawValue
    )
  }

  @ViewBuilder
  private func scalarSettingsUnavailableNotice(
    _ domain: ScalarSettingsDomain
  ) -> some View {
    if model.hasUnavailableScalarSettings(in: domain) {
      MenuBarFixedWidthLabel(
        title: domain.unavailableWarning(language: model.language),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .accessibilityIdentifier("menu.settings-unavailable.\(domain.rawValue)")

      Divider()
    }
  }
}

extension MenuBarStatusView {
  @ViewBuilder
  var languageMenu: some View {
    scalarSettingsUnavailableNotice(.interface)

    ForEach(AppLanguage.allCases) { language in
      Button {
        model.setInterfaceLanguage(language)
      } label: {
        selectionLabel(language.displayName, isSelected: model.language == language)
      }
      .disabled(!model.canMutateScalarSettings(in: .interface))
    }
  }

  @ViewBuilder
  var textStyleMenu: some View {
    if model.enabledTextStyleWorkflows.isEmpty {
      Text(L10n.string(.menuNoTextStyleWorkflows, language: model.language))
    } else {
      ForEach(model.enabledTextStyleWorkflows) { workflow in
        Button {
          model.runWorkflow(workflow)
        } label: {
          let presentation = VoiceWorkflowPresentation(workflow: workflow)
          MenuBarFixedWidthLabel(
            title: presentation.menuTitle(
              workflowName: model.workflowMenuButtonTitle(for: workflow),
              language: model.language
            ),
            systemImage: presentation.textStyle.systemImage
          )
        }
        .disabled(!model.canTriggerWorkflow(workflow))
      }
    }

    Divider()

    Button {
      model.openWorkflowEditor()
    } label: {
      Label(
        UIStrings.text(.openWorkflowEditor, language: model.language),
        systemImage: RillSystemSymbol.squareAndPencil.rawValue)
    }
  }

  @ViewBuilder
  var textOutputMenu: some View {
    scalarSettingsUnavailableNotice(.input)

    Button {
      model.setBuiltinPushToTalkOutputMode(.pasteIntoApp)
    } label: {
      selectionLabel(
        L10n.string(.menuPasteIntoApp, language: model.language),
        isSelected: model.builtinPushToTalkOutputMode == .pasteIntoApp
      )
    }
    .disabled(!model.canMutateScalarSettings(in: .input))

    Button {
      model.setBuiltinPushToTalkOutputMode(.saveToVoiceGroup)
    } label: {
      selectionLabel(
        L10n.string(.menuSaveToVoiceGroup, language: model.language),
        isSelected: model.builtinPushToTalkOutputMode == .saveToVoiceGroup
      )
    }
    .disabled(!model.canMutateScalarSettings(in: .input))

    Divider()

    Button {
      copyLastCompletedText()
    } label: {
      Label(L10n.string(.menuCopyLastResult, language: model.language), systemImage: RillSystemSymbol.docOnDoc.rawValue)
    }
    .disabled(!panelState.canCopyLastResult)

    Button {
      model.deliverNextRecord()
    } label: {
      Label(
        L10n.string(.menuDeliverNextRecord, language: model.language), systemImage: RillSystemSymbol.arrowDownDoc.rawValue)
    }
    .disabled(!panelState.canDeliverNextRecord)
  }

  @ViewBuilder
  var longRecordingMenu: some View {
    scalarSettingsUnavailableNotice(.input)

    Button {
      model.setLongRecordingModeEnabled(!model.longRecordingModeEnabled)
    } label: {
      selectionLabel(
        L10n.string(.menuLongRecordingToggle, language: model.language),
        isSelected: model.longRecordingModeEnabled
      )
    }
    .disabled(!model.canMutateScalarSettings(in: .input))

    MenuBarFixedWidthText(
      text: L10n.string(.settingsLongRecordingModeDescription, language: model.language)
    )

    Divider()

    if model.enabledLongRecordingWorkflows.isEmpty {
      Text(L10n.string(.menuNoLongRecordingWorkflows, language: model.language))
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
  var workflowMenu: some View {
    if model.enabledManualWorkflows.isEmpty {
      Text(L10n.string(.menuNoManualWorkflows, language: model.language))
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

    Divider()

    Button {
      model.openWorkflowEditor()
    } label: {
      Label(
        UIStrings.text(.openWorkflowEditor, language: model.language),
        systemImage: RillSystemSymbol.squareAndPencil.rawValue)
    }
  }
}

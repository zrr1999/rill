import Foundation
import SwiftUI
import RillCore

private struct ClipboardHistoryKeyboardShortcutModifier: ViewModifier {
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
    clipboardCaptureEnabled: Bool,
    clipboardCaptureState: ClipboardCaptureControlState,
    stackCount: Int
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

    guard clipboardCaptureEnabled else {
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
      return stackCount > 0 ? .squareStack3dUpFill : .waveform
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
  public let stackCount: Int
  public let canDeliverTopOfStack: Bool
  public let preferredSpeechEngine: PreferredSpeechEngine
  public let outputMode: BuiltinPushToTalkOutputMode
  public let longRecordingModeEnabled: Bool
  public let clipboardCaptureEnabled: Bool
  public let clipboardSettingsAvailable: Bool
  public let clipboardCaptureState: ClipboardCaptureControlState
  public let voiceSetupStatus: MenuBarVoiceSetupStatus
  public let localPersistenceStatus: LocalPersistenceStatus

  public init(
    language: AppLanguage,
    isRunning: Bool,
    lastCompletedText: String? = nil,
    lastFailure: String? = nil,
    stackCount: Int,
    canDeliverTopOfStack: Bool,
    preferredSpeechEngine: PreferredSpeechEngine,
    outputMode: BuiltinPushToTalkOutputMode,
    longRecordingModeEnabled: Bool = false,
    clipboardCaptureEnabled: Bool = true,
    clipboardSettingsAvailable: Bool = true,
    clipboardCaptureState: ClipboardCaptureControlState = .active,
    voiceSetupStatus: MenuBarVoiceSetupStatus = .ready,
    localPersistenceStatus: LocalPersistenceStatus = .ready
  ) {
    self.language = language
    self.isRunning = isRunning
    self.lastCompletedText = lastCompletedText
    self.lastFailure = lastFailure
    self.stackCount = stackCount
    self.canDeliverTopOfStack = canDeliverTopOfStack
    self.preferredSpeechEngine = preferredSpeechEngine
    self.outputMode = outputMode
    self.longRecordingModeEnabled = longRecordingModeEnabled
    self.clipboardCaptureEnabled = clipboardCaptureEnabled
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
      return ClipboardTextFormatting.previewText(failure, limit: 96)
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

    if stackCount > 0 {
      return L10n.menuClipboardReadyStatus(stackCount, language: language)
    }

    return nil
  }

  public var statusSystemImage: String {
    if trimmedFailure != nil {
      return "exclamationmark.triangle.fill"
    }

    if isRunning {
      return "waveform.circle.fill"
    }

    switch voiceSetupStatus {
    case .loading:
      return "hourglass.circle"
    case .incomplete:
      return "exclamationmark.circle.fill"
    case .ready:
      break
    }

    if stackCount > 0 {
      return "square.stack.3d.up.fill"
    }

    return "checkmark.circle"
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
    guard clipboardCaptureEnabled else {
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
    guard clipboardCaptureEnabled else { return "power.circle.fill" }
    return switch clipboardCaptureState {
    case .active:
      "checkmark.shield"
    case .pausing, .paused, .resuming:
      "play.circle.fill"
    case .armingIgnoreNextExternalChange, .ignoringNextExternalChange:
      "eye.slash.fill"
    }
  }

  public var clipboardCaptureToggleTitle: String {
    let key: L10n.Key =
      clipboardCaptureEnabled
      ? .menuTurnOffClipboardCapture
      : .menuTurnOnClipboardCapture
    return L10n.string(key, language: language)
  }

  public var clipboardCaptureToggleSystemImage: String {
    clipboardCaptureEnabled ? "power" : "play.circle"
  }

  public var canToggleClipboardCapture: Bool {
    clipboardSettingsAvailable
  }

  public var canIgnoreNextExternalCopy: Bool {
    clipboardSettingsAvailable
      && clipboardCaptureEnabled
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
      : "externaldrive.badge.exclamationmark"
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
            systemImage: "macwindow"
          )
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button {
          model.showRunHistory()
          openMainWindow()
        } label: {
          Label(
            UIStrings.text(.historyScopeAll, language: model.language),
            systemImage: "clock.arrow.circlepath")
        }

        Button {
          model.showClipboardManagement()
          openMainWindow()
        } label: {
          Label(
            UIStrings.text(.clipboardTitle, language: model.language),
            systemImage: "doc.on.clipboard"
          )
        }
        .modifier(
          ClipboardHistoryKeyboardShortcutModifier(
            isVisible: ClipboardPanelShortcutPresentationPolicy.surfaceVisibility(
              clipboardCaptureEnabled: model.clipboardCaptureEnabled
            ).menuShortcutAnnotation
          )
        )
        .accessibilityIdentifier("menu.clipboard.open-history")

        Button {
          copyLastCompletedText()
        } label: {
          Label(
            L10n.string(.menuCopyLastResult, language: model.language), systemImage: "doc.on.doc")
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!panelState.canCopyLastResult)

        Divider()

        scalarSettingsUnavailableNotice(.clipboard)

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
            systemImage: "eye.slash"
          )
        }
        .disabled(!panelState.canIgnoreNextExternalCopy)
        .accessibilityIdentifier("menu.clipboard.ignore-next")

        Divider()

        Menu {
          languageMenu
        } label: {
          Label(L10n.string(.menuInterfaceLanguage, language: model.language), systemImage: "globe")
        }

        Menu {
          textStyleMenu
        } label: {
          Label(
            L10n.string(.menuTextStyles, language: model.language), systemImage: "wand.and.stars")
        }

        Menu {
          textOutputMenu
        } label: {
          Label(L10n.string(.menuTextOutput, language: model.language), systemImage: "textformat")
        }

        Menu {
          longRecordingMenu
        } label: {
          Label(
            L10n.string(.menuLongRecording, language: model.language), systemImage: "record.circle")
        }

        Menu {
          workflowMenu
        } label: {
          Label(
            L10n.string(.menuWorkflows, language: model.language),
            systemImage: "square.stack.3d.up"
          )
        }

        Divider()

        Button {
          model.selectSidebarSection(.settings)
          openMainWindow()
        } label: {
          Label(UIStrings.text(.settingsTitle, language: model.language), systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
          openAbout()
        } label: {
          Label(L10n.string(.menuAbout, language: model.language), systemImage: "info.circle")
        }

        Divider()

        Button(role: .destructive) {
          quitApplication()
        } label: {
          Label(L10n.string(.menuQuit, language: model.language), systemImage: "xmark.square")
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
        systemImage: "hourglass.circle"
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

    Label(panelState.outputModeTitle, systemImage: "textformat")
      .accessibilityIdentifier("menu.status.output-mode")

    Label(panelState.longRecordingModeTitle, systemImage: "record.circle")
      .accessibilityIdentifier("menu.status.long-recording")

    Label(
      panelState.clipboardCaptureStatusTitle,
      systemImage: panelState.clipboardCaptureStatusSystemImage
    )
    .accessibilityIdentifier("menu.status.clipboard-capture")
  }

  @ViewBuilder
  private var languageMenu: some View {
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
  private var textStyleMenu: some View {
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
        systemImage: "square.and.pencil")
    }
  }

  @ViewBuilder
  private var textOutputMenu: some View {
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
      Label(L10n.string(.menuCopyLastResult, language: model.language), systemImage: "doc.on.doc")
    }
    .disabled(!panelState.canCopyLastResult)

    Button {
      model.deliverTopOfStack()
    } label: {
      Label(
        L10n.string(.menuPasteTopOfStack, language: model.language), systemImage: "arrow.down.doc")
    }
    .disabled(!panelState.canDeliverTopOfStack)
  }

  func openStorageSettings() {
    model.showSettings(.storage)
    openMainWindow()
  }

  @ViewBuilder
  private var longRecordingMenu: some View {
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
  private var workflowMenu: some View {
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
        systemImage: "square.and.pencil")
    }
  }

  private var panelState: MenuBarOperationPanelState {
    MenuBarOperationPanelState(
      language: model.language,
      isRunning: model.isRunning,
      lastCompletedText: model.lastCompletedText,
      lastFailure: model.lastFailure,
      stackCount: model.stackCount,
      canDeliverTopOfStack: model.canDeliverTopOfStack,
      preferredSpeechEngine: model.preferredSpeechEngine,
      outputMode: model.builtinPushToTalkOutputMode,
      longRecordingModeEnabled: model.longRecordingModeEnabled,
      clipboardCaptureEnabled: model.clipboardCaptureEnabled,
      clipboardSettingsAvailable: model.canMutateScalarSettings(in: .clipboard),
      clipboardCaptureState: model.clipboardCaptureControlSnapshot.state,
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
        systemImage: "exclamationmark.triangle.fill"
      )
      .accessibilityIdentifier("menu.settings-unavailable.\(domain.rawValue)")

      Divider()
    }
  }
}

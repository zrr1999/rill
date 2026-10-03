import AppKit
import RillUI
import SwiftUI

@main
struct RillApplication: App {
  fileprivate static let mainWindowID = "main"

  @NSApplicationDelegateAdaptor(VoiceInputApplicationDelegate.self)
  private var applicationDelegate
  @State private var container: AppContainer
  private let recordPanelController: RecordPanelController
  private let liveSubtitlePanelController: LiveSubtitlePanelController

  @MainActor
  init() {
    let container = AppBootstrap.makeContainer()
    let recordPanelController: RecordPanelController = RecordPanelController()
    let liveSubtitlePanelController = LiveSubtitlePanelController()

    recordPanelController.configureDrafts(
      model: container.model, output: container.bufferOutput,
      editingActivity: container.setDraftEditorActive)
    let showPanel: (RecordPanelPresentation.Mode, Bool, Bool) -> Void = {
      [
        weak recordPanelController, weak model = container.model,
        delivery = container.systemClipboardCaptureController.recordDelivery
      ] mode, toggle, activate in
      guard let recordPanelController, let model else { return }
      recordPanelController.show(
        model: model, mode: mode, toggle: toggle, activate: activate,
        deliverSelection: { subject, target in
          await delivery.reuseRecord(
            subject,
            to: target
          )
        },
        copySelection: { subject in
          await delivery.reuseRecord(
            subject, copyOnly: true)
        },
        onDeliveryAbort: {
          await delivery.reportSelectedRecordDeliveryUnavailable()
        }
      )
    }
    container.model.installRecordPanelAction { showPanel(.collections, true, true) }
    container.model.recordWorkspace.buffers.openEditorAction = { showPanel(.drafts, false, true) }
    container.bufferOutput.presentStatus = { showPanel(.drafts, false, false) }
    recordPanelController.startCollectionObservation { showPanel(.drafts, false, false) }
    container.model.voice.installLiveSubtitlePanelAction {
      [liveSubtitlePanelController] snapshot, language in
      liveSubtitlePanelController.update(snapshot: snapshot, language: language)
    }
    container.model.voice.installLiveAudioCancellationAction(
      container.setLiveAudioEscapeCancellationRunID
    )
    liveSubtitlePanelController.installRemoveDurationLimitAction(
      container.removeLiveAudioDurationLimit
    )

    self._container = State(initialValue: container)
    self.recordPanelController = recordPanelController
    self.liveSubtitlePanelController = liveSubtitlePanelController
    let shutdown = container.shutdown
    applicationDelegate.installEscapeAction {
      container.model.voice.stopSpeechPlaybackIfActive()
    }
    applicationDelegate.installCleanupOperation {
      await recordPanelController.shutdown()
      await shutdown()
    }
  }

  var body: some Scene {
    Window(container.model.localizedWindowTitle, id: Self.mainWindowID) {
      MainShellView(model: container.model)
    }
    .defaultSize(width: 960, height: 720)
    .commands {
      RillGlobalSearchCommands(language: container.model.settings.language)
      RillSettingsCommands(model: container.model, language: container.model.settings.language)
    }

    MenuBarExtra {
      MenuBarContent(model: container.model)
    } label: {
      Label {
        Text(container.model.localizedMenuBarTitle)
      } icon: {
        RillMenuBarIcon.image(for: menuBarSystemSymbol)
      }
      .labelStyle(.iconOnly)
    }
    .menuBarExtraStyle(.menu)
  }

  private var menuBarSystemSymbol: RillSystemSymbol {
    MenuBarSystemSymbolPolicy.symbol(
      isVoiceRunActive: container.model.voice.isRunning,
      globalInputCapability: container.model.globalInputCapability,
      systemClipboardCaptureEnabled: container.model.settings.systemClipboardCaptureEnabled,
      clipboardCaptureState: container.model.systemClipboardCaptureControlSnapshot.state,
      recordCount: container.model.recordCount
    )
  }
}

private struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow

  let model: AppModel

  var body: some View {
    MenuBarStatusView(
      model: model,
      openMainWindow: openMainWindowFromMenu,
      openAbout: openAboutFromMenu,
      quitApplication: { NSApp.terminate(nil) }
    )
  }

  private func openMainWindowFromMenu() {
    NSApp.activate(ignoringOtherApps: true)

    if let existingWindow = NSApp.windows.first(where: { window in
      window.title == model.localizedWindowTitle && window.isVisible
    }) {
      existingWindow.makeKeyAndOrderFront(nil)
      return
    }

    openWindow(id: RillApplication.mainWindowID)
  }

  private func openAboutFromMenu() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
  }

}

private struct RillSettingsCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let model: AppModel
  let language: AppLanguage

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button(L10n.text(.settingsMenuCommand, language: language)) {
        model.presentSettings()
        openWindow(id: RillApplication.mainWindowID)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }
}

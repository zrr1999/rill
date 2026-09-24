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

        container.model.installRecordCopyAction { subject in
            await container.systemClipboardCaptureController.recordDelivery.reuseRecord(subject, copyOnly: true)
        }
        container.model.installRecordPanelAction { [recordPanelController, model = container.model] in
            recordPanelController.show(
                model: model,
                deliverSelection: { subject, target in
                    await container.systemClipboardCaptureController.recordDelivery.reuseRecord(
                        subject,
                        to: target
                    )
                },
                copySelection: { subject in
                    await container.systemClipboardCaptureController.recordDelivery.reuseRecord(
                        subject, copyOnly: true)
                },
                onDeliveryAbort: {
                    await container.systemClipboardCaptureController.recordDelivery
                        .reportSelectedRecordDeliveryUnavailable()
                }
            )
        }
        container.model.installSystemClipboardCaptureControlActions(
            setEnabled: container.setSystemClipboardCaptureEnabled,
            ignoreNextExternalChange: container.ignoreNextExternalClipboardChange
        )
        container.model.installRecordPanelHotkeyAction { binding in
            container.updateRecordPanelHotkey(binding)
        }
        container.model.installRecordPanelShortcutRecordingActions(
            begin: container.beginRecordPanelShortcutRecording,
            end: container.endRecordPanelShortcutRecording,
            commit: container.commitRecordPanelShortcutRecording
        )
        container.model.installLiveSubtitlePanelAction {
            [liveSubtitlePanelController] snapshot, language in
            let cancellableRunID = snapshot.flatMap { snapshot in
                LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: snapshot.phase)
                    ? snapshot.runID
                    : nil
            }
            container.setLiveAudioEscapeCancellationRunID(cancellableRunID)
            liveSubtitlePanelController.update(snapshot: snapshot, language: language)
        }
        liveSubtitlePanelController.installRemoveDurationLimitAction(
            container.removeLiveAudioDurationLimit
        )

        self._container = State(initialValue: container)
        self.recordPanelController = recordPanelController
        self.liveSubtitlePanelController = liveSubtitlePanelController
        let shutdown = container.shutdown
        applicationDelegate.installEscapeAction {
            container.model.stopSpeechPlaybackIfActive()
        }
        applicationDelegate.installCleanupOperation {
            await recordPanelController.shutdown()
            await shutdown()
        }
    }

    var body: some Scene {
        Window(container.model.localizedWindowTitle, id: Self.mainWindowID) {
            MainWindowContent(container: container)
        }
        .defaultSize(width: 960, height: 720)
        .commands {
            RillGlobalSearchCommands(language: container.model.language)
        }

        Settings {
            SettingsWindowView(model: container.model)
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
            isVoiceRunActive: container.model.isRunning,
            globalInputCapability: container.model.globalInputCapability,
            systemClipboardCaptureEnabled: container.model.systemClipboardCaptureEnabled,
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

private struct MainWindowContent: View {
    @Environment(\.openSettings) private var openSettings
    let container: AppContainer

    private func presentRequestedSettings() {
        if container.model.consumeSettingsPresentation() { openSettings() }
    }

    var body: some View {
        MainShellView(model: container.model)
            .onChange(of: container.model.settingsPresentationGeneration) { _, _ in presentRequestedSettings() }
            .onAppear { presentRequestedSettings() }
    }
}

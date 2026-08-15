import AppKit
import SwiftUI
import RillUI

@main
struct RillApplication: App {
    fileprivate static let mainWindowID = "main"
    fileprivate static let workflowEditorWindowID = "workflow-editor"

    @NSApplicationDelegateAdaptor(VoiceInputApplicationDelegate.self)
    private var applicationDelegate
    @State private var container: AppContainer
    private let recordPanelController: RecordPanelController
    private let liveSubtitlePanelController: LiveSubtitlePanelController

    @MainActor
    init() {
        let container = AppBootstrap.makeContainer()
        let recordPanelController = RecordPanelController()
        let liveSubtitlePanelController = LiveSubtitlePanelController()

        container.model.installRecordPanelAction { [recordPanelController, model = container.model] in
            recordPanelController.show(
                model: model,
                deliverSelection: { subject, target in
                    await container.systemClipboardCaptureController.deliverSelectedRecord(
                        subject,
                        to: target
                    )
                },
                onDeliveryAbort: {
                    await container.systemClipboardCaptureController
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
        container.model.installLiveSubtitlePanelAction { [liveSubtitlePanelController] snapshot, language in
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

        Window(container.model.localizedWorkflowWindowTitle, id: Self.workflowEditorWindowID) {
            WorkflowsView(model: container.model)
        }
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra(
            container.model.localizedMenuBarTitle,
            systemImage: menuBarSystemSymbol.rawValue
        ) {
            MenuBarContent(model: container.model)
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
        .onAppear {
            model.installOpenWorkflowEditorAction {
                openWindow(id: RillApplication.workflowEditorWindowID)
            }
        }
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
    @Environment(\.openWindow) private var openWindow

    let container: AppContainer

    var body: some View {
        MainShellView(model: container.model)
            .onAppear {
                container.model.installOpenWorkflowEditorAction {
                    openWindow(id: RillApplication.workflowEditorWindowID)
                }
            }
    }
}

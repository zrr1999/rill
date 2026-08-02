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
    private let clipboardPanelController: ClipboardPanelController
    private let liveSubtitlePanelController: LiveSubtitlePanelController

    @MainActor
    init() {
        let container = AppBootstrap.makeContainer()
        let clipboardPanelController = ClipboardPanelController()
        let liveSubtitlePanelController = LiveSubtitlePanelController()
        let useClipboardItem = container.useClipboardItem

        container.model.installClipboardPanelAction { [clipboardPanelController, model = container.model] in
            clipboardPanelController.show(model: model)
        }
        container.model.installClipboardCaptureControlActions(
            setEnabled: container.setClipboardCaptureEnabled,
            ignoreNextExternalChange: container.ignoreNextExternalClipboardChange
        )
        container.model.installClipboardPanelHotkeyAction { binding in
            container.updateClipboardPanelHotkey(binding)
        }
        container.model.installClipboardPanelShortcutRecordingActions(
            begin: container.beginClipboardPanelShortcutRecording,
            end: container.endClipboardPanelShortcutRecording,
            commit: container.commitClipboardPanelShortcutRecording
        )
        container.model.installUseClipboardItemAction { [clipboardPanelController, model = container.model] item in
            clipboardPanelController.useSelectedItem(
                { target in
                    await useClipboardItem(item, target)
                },
                onAbort: {
                    model.reportClipboardPanelPasteFailure()
                }
            )
        }
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
        self.clipboardPanelController = clipboardPanelController
        self.liveSubtitlePanelController = liveSubtitlePanelController
        let shutdown = container.shutdown
        applicationDelegate.installEscapeAction {
            container.model.stopSpeechPlaybackIfActive()
        }
        applicationDelegate.installCleanupOperation {
            await clipboardPanelController.shutdown()
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
            clipboardCaptureEnabled: container.model.clipboardCaptureEnabled,
            clipboardCaptureState: container.model.clipboardCaptureControlSnapshot.state,
            stackCount: container.model.stackCount
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

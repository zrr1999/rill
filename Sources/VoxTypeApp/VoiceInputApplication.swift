import SwiftUI
import VoxTypeUI

@main
struct VoxTypeApplication: App {
    fileprivate static let workflowEditorWindowID = "workflow-editor"

    @State private var container = AppBootstrap.makeContainer()
    private let clipboardPanelController = ClipboardPanelController()

    var body: some Scene {
        WindowGroup(container.model.localizedWindowTitle) {
            MainWindowContent(
                container: container,
                clipboardPanelController: clipboardPanelController
            )
        }
        .defaultSize(width: 960, height: 720)

        Window(container.model.localizedWorkflowWindowTitle, id: Self.workflowEditorWindowID) {
            WorkflowsView(model: container.model)
        }
        .defaultSize(width: 840, height: 760)

        MenuBarExtra(
            container.model.localizedMenuBarTitle,
            systemImage: container.model.stackCount > 0 ? "square.stack.3d.up.fill" : "waveform"
        ) {
            MenuBarStatusView(model: container.model)
        }
    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow

    let container: AppContainer
    let clipboardPanelController: ClipboardPanelController

    var body: some View {
        MainShellView(model: container.model)
            .onAppear {
                let useClipboardItem = container.useClipboardItem
                container.model.installClipboardPanelAction {
                    clipboardPanelController.show(model: container.model)
                }
                container.model.installClipboardPanelHotkeyAction { binding in
                    container.updateClipboardPanelHotkey(binding)
                }
                container.model.installOpenWorkflowEditorAction {
                    openWindow(id: VoxTypeApplication.workflowEditorWindowID)
                }
                container.model.installUseClipboardItemAction { item in
                    clipboardPanelController.useSelectedItem {
                        await MainActor.run {
                            useClipboardItem(item)
                        }
                    }
                }
            }
    }
}

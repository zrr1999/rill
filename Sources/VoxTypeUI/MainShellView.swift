import SwiftUI

public enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard
    case history
    case diagnostics
    case settings

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .history: return "clock.arrow.circlepath"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }

    public var titleKey: UIStrings.Key {
        switch self {
        case .dashboard: return .sidebarDashboard
        case .history: return .sidebarHistory
        case .diagnostics: return .sidebarDiagnostics
        case .settings: return .sidebarSettings
        }
    }
}

public struct MainShellView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selectedSidebarSection) { section in
                Label(
                    UIStrings.text(section.titleKey, language: model.language),
                    systemImage: section.symbolName
                )
                .tag(section)
                .accessibilityLabel(UIStrings.text(section.titleKey, language: model.language))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .navigationTitle(UIStrings.text(.appTitle, language: model.language))
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.runSelectedWorkflow()
                } label: {
                    Label(model.workflowRunButtonTitle(for: model.selectedWorkflow), systemImage: "play.fill")
                }
                .disabled(!model.canRunSelectedWorkflow)

                Button {
                    model.deliverTopOfStack()
                } label: {
                    Label(UIStrings.text(.pasteTopOfStack, language: model.language), systemImage: "doc.on.clipboard")
                }
                .disabled(!model.canDeliverTopOfStack)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.selectedSidebarSection {
        case .dashboard, .none:
            DashboardView(model: model)
        case .history:
            HistoryView(model: model)
        case .diagnostics:
            DiagnosticsView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}

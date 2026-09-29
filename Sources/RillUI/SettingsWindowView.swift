import SwiftUI

public struct SettingsWindowView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
      VStack(spacing: 0) {
        if model.comparisonReturn != nil {
            HStack {
                Button(L10n.jev(.returnToComparison, language: model.settings.language)) { model.resumeComparison() }
                    .accessibilityIdentifier("settings.jev.return")
                Spacer()
                Button(L10n.jev(.cancelReturn, language: model.settings.language)) { model.discardComparisonReturn() }
            }
            .padding()
            Divider()
        }
        NavigationSplitView {
            List(selection: Binding<SettingsPane?>(
                get: { model.selectedSettingsPane },
                set: { if let pane = $0 { model.selectedSettingsPane = pane } }
            )) {
                ForEach(SettingsPane.allCases) { pane in
                    Label {
                        Text(pane.title(language: model.settings.language))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: pane.symbolName)
                    }
                        .tag(pane)
                        .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 220)
        } detail: {
            ZStack {
                ForEach(SettingsPane.allCases) { pane in
                    SettingsView(model: model, pane: pane)
                        .opacity(model.selectedSettingsPane == pane ? 1 : 0)
                        .allowsHitTesting(model.selectedSettingsPane == pane)
                        .disabled(model.selectedSettingsPane != pane)
                        .accessibilityHidden(model.selectedSettingsPane != pane)
                }
            }
            .navigationTitle(model.selectedSettingsPane.title(language: model.settings.language))
        }
      }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 640)
        .background(SettingsWindowCloseObserver { model.discardComparisonReturn() })
        .onDisappear { model.discardComparisonReturn() }
    }
}

/// macOS may keep a Settings scene mounted after closing its window.
struct SettingsWindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void
    func makeNSView(context: Context) -> CloseView { CloseView(onClose: onClose) }
    func updateNSView(_ view: CloseView, context: Context) { view.onClose = onClose }

    final class CloseView: NSView {
        var onClose: @MainActor () -> Void
        init(onClose: @escaping @MainActor () -> Void) {
            self.onClose = onClose
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self)
            super.viewDidMoveToWindow()
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowClosed),
                    name: NSWindow.willCloseNotification, object: window)
            }
        }
        @objc private func windowClosed() { onClose() }
        isolated deinit { NotificationCenter.default.removeObserver(self) }
    }
}

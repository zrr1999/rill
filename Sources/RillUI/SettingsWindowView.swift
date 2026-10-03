import SwiftUI

struct SettingsDetailView: View {
  @Bindable private var model: AppModel

  init(model: AppModel) { self.model = model }

  var body: some View {
    VStack(spacing: 0) {
      if model.comparisonReturn != nil {
        HStack {
          Button(L10n.jev(.returnToComparison, language: model.settings.language)) {
            model.resumeComparison()
          }
          .accessibilityIdentifier("settings.jev.return")
          Spacer()
          Button(L10n.jev(.cancelReturn, language: model.settings.language)) {
            model.discardComparisonReturn()
          }
        }
        .padding()
        Divider()
      }
      ZStack {
        ForEach(SettingsPane.allCases) { pane in
          SettingsView(model: model, pane: pane)
            .opacity(model.selectedSettingsPane == pane ? 1 : 0)
            .allowsHitTesting(model.selectedSettingsPane == pane)
            .disabled(model.selectedSettingsPane != pane)
            .accessibilityHidden(model.selectedSettingsPane != pane)
        }
      }
    }
  }
}

/// macOS may keep a window mounted after it closes; comparison intent must not survive that.
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
        NotificationCenter.default.addObserver(
          self, selector: #selector(windowClosed),
          name: NSWindow.willCloseNotification, object: window)
      }
    }
    @objc private func windowClosed() { onClose() }
    isolated deinit { NotificationCenter.default.removeObserver(self) }
  }
}

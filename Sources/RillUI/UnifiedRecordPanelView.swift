import AppKit
import SwiftUI

/// Both panes stay mounted so switching modes preserves native text input and undo.
public struct UnifiedRecordPanelView<Records: View>: View {
  @Bindable private var presentation: RecordPanelPresentation
  @Bindable private var model: AppModel
  @State private var showsOutputReview = false
  private let records: Records
  private let onModeChange: (RecordPanelPresentation.Mode) -> Void
  private let onFinishEditing: () -> Void
  private let onInteractionChange: () -> Void

  public init(presentation: RecordPanelPresentation, model: AppModel,
              onModeChange: @escaping (RecordPanelPresentation.Mode) -> Void,
              onFinishEditing: @escaping () -> Void = {},
              onInteractionChange: @escaping () -> Void = {},
              @ViewBuilder records: () -> Records) {
    self.presentation = presentation
    self.model = model
    self.onModeChange = onModeChange
    self.onFinishEditing = onFinishEditing
    self.onInteractionChange = onInteractionChange
    self.records = records()
  }

  private var buffers: RecordBufferModel { model.recordWorkspace.buffers }
  private func panelText(_ key: RecordPanelText) -> String {
    L10n.recordPanel(key, language: model.settings.language)
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Picker(panelText(.panelContent), selection: Binding(
          get: { presentation.mode }, set: { onModeChange($0) })) {
          Text(panelText(.drafts) + " · \(buffers.snapshot?.remainingCount ?? 0)")
            .tag(RecordPanelPresentation.Mode.drafts)
          Text(panelText(.collections)).tag(RecordPanelPresentation.Mode.collections)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
        .disabled(buffers.editor.session?.hasMarkedText == true)
        .accessibilityIdentifier("record-panel.mode")
        Spacer(minLength: 8)
        Toggle(isOn: $presentation.isPinned) {
          Label(panelText(.keepOpen), systemImage: presentation.isPinned ? RillSystemSymbol.pinFill.rawValue : RillSystemSymbol.pin.rawValue)
        }
        .toggleStyle(.button).labelStyle(.iconOnly)
        .help(panelText(.keepOpenHelp))
        .accessibilityIdentifier("record-panel.pin")
      }
      .controlSize(.small).padding(.horizontal, 14).frame(height: 52)
      .rillFloatingControlSurface()
      notice
      ZStack {
        records
          .opacity(presentation.mode == .collections ? 1 : 0)
          .allowsHitTesting(presentation.mode == .collections)
          .disabled(presentation.mode != .collections || presentation.isCollapsed)
          .accessibilityHidden(presentation.mode != .collections || presentation.isCollapsed)
        RecordBufferDraftView(model: model, onFinishEditing: onFinishEditing)
          .opacity(presentation.mode == .drafts ? 1 : 0)
          .allowsHitTesting(presentation.mode == .drafts)
          .disabled(presentation.mode != .drafts || presentation.isCollapsed)
          .accessibilityHidden(presentation.mode != .drafts || presentation.isCollapsed)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("record-panel.unified")
    .onChange(of: presentation.isPinned) { _, _ in onInteractionChange() }
    .onChange(of: buffers.editor.session?.isFocused) { _, _ in onInteractionChange() }
    .onChange(of: buffers.editor.session?.hasMarkedText) { _, _ in onInteractionChange() }
    .sheet(isPresented: $showsOutputReview) {
      VStack(alignment: .leading, spacing: 16) {
        Text(panelText(.outputStatus)).font(.headline)
        outputFeedback
        HStack { Spacer(); Button(panelText(.done)) { showsOutputReview = false } }
      }.padding(20).frame(width: 420)
    }
  }

  private var notice: some View {
    HStack(spacing: 8) {
      Image(systemName: needsAttention ? RillSystemSymbol.exclamationmarkCircle.rawValue : RillSystemSymbol.checkmarkCircle.rawValue)
        .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
        .frame(width: 16)
      Text(noticeText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 0)
      Button(panelText(.review)) { showsOutputReview = true }
        .controlSize(.small)
        .opacity(needsAttention ? 1 : 0)
        .disabled(!needsAttention)
        .accessibilityHidden(!needsAttention)
        .accessibilityIdentifier("record-panel.review-output")
    }
    .padding(.horizontal, 14).frame(height: 36)
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityIdentifier("record-panel.output-status")
  }

  private var needsAttention: Bool { buffers.snapshot?.active != nil || buffers.message != nil }
  private var noticeText: String {
    if buffers.snapshot?.active != nil { return panelText(.previousOutputNeedsConfirmation) }
    return buffers.message ?? panelText(.localContent)
  }

  private var outputFeedback: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let active = buffers.snapshot?.active {
        Text(active.state == .delivered
             ? panelText(.deliveredButNotSaved)
             : panelText(.confirmInsertion))
        HStack {
          Button(active.state == .delivered ? panelText(.retrySave) : panelText(.inserted),
                 action: buffers.confirmAction)
          if active.state != .delivered {
            Button(panelText(.retryItem), action: buffers.retryAction)
          }
        }.disabled(buffers.isSending)
      }
      if let message = buffers.message {
        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .accessibilityIdentifier("record-panel.output-feedback")
  }
}

private struct FloatingControlSurface: ViewModifier {
  var cornerRadius: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    if reduceTransparency || contrast == .increased {
      content.background(Color(nsColor: .controlBackgroundColor))
    } else {
      content.background {
        RoundedRectangle(cornerRadius: cornerRadius)
          .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
      }
    }
  }
}

extension View {
  func rillFloatingControlSurface(cornerRadius: CGFloat = RillRadius.section) -> some View {
    modifier(FloatingControlSurface(cornerRadius: cornerRadius))
  }
}

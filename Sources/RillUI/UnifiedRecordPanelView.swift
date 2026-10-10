import AppKit
import SwiftUI

/// Both panes stay mounted so switching modes preserves native text input and undo.
public struct UnifiedRecordPanelView<Records: View>: View {
  @Bindable private var presentation: RecordPanelPresentation
  @Bindable private var model: AppModel
  @State private var showsOutputReview = false
  @Namespace private var modeGlass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let records: Records
  private let onModeChange: (RecordPanelPresentation.Mode) -> Void
  private let onFinishEditing: () -> Void
  private let onInteractionChange: () -> Void

  public init(
    presentation: RecordPanelPresentation, model: AppModel,
    onModeChange: @escaping (RecordPanelPresentation.Mode) -> Void,
    onFinishEditing: @escaping () -> Void = {},
    onInteractionChange: @escaping () -> Void = {},
    @ViewBuilder records: () -> Records
  ) {
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
    panel
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.ultraThinMaterial)
      .containerShape(RoundedRectangle(cornerRadius: RecordPanelAppearance.cornerRadius, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: RecordPanelAppearance.cornerRadius, style: .continuous))
      .accessibilityIdentifier("record-panel.unified")
      .onChange(of: presentation.isPinned) { _, _ in onInteractionChange() }
      .onChange(of: buffers.editor.session?.isFocused) { _, _ in onInteractionChange() }
      .onChange(of: buffers.editor.session?.hasMarkedText) { _, _ in onInteractionChange() }
      .sheet(isPresented: $showsOutputReview) {
        VStack(alignment: .leading, spacing: 16) {
          Text(panelText(.outputStatus)).font(.headline)
          outputFeedback
          HStack {
            Spacer()
            Button(panelText(.done)) { showsOutputReview = false }
          }
        }.padding(20).frame(width: 420)
      }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 12) {
          modeControl
          Spacer(minLength: 8)
          Toggle(isOn: $presentation.isPinned) {
            Label(panelText(.keepOpen), systemImage: presentation.isPinned ? RillSystemSymbol.pinFill.rawValue : RillSystemSymbol.pin.rawValue)
          }
          .toggleStyle(.button).labelStyle(.iconOnly).buttonStyle(.glass)
          .buttonBorderShape(.circle).buttonSizing(.flexible)
          .font(.system(size: 13)).frame(width: 30, height: 30)
          .help(panelText(.keepOpenHelp))
          .accessibilityIdentifier("record-panel.pin")
        }
        .controlSize(.regular).padding(.horizontal, 14).frame(height: 53)
      }
      notice
      // Both panes fill the available viewport; neither needs to determine the
      // other's ideal size during the window's initial layout.
      GeometryReader { viewport in
        ZStack {
          // Separate containers keep hidden panes out of the visible glass composite.
          GlassEffectContainer(spacing: 8) { records }
            .opacity(presentation.mode == .collections ? 1 : 0)
            .allowsHitTesting(presentation.mode == .collections)
            .disabled(presentation.mode != .collections || presentation.isCollapsed)
            .accessibilityHidden(presentation.mode != .collections || presentation.isCollapsed)
          GlassEffectContainer(spacing: 8) {
            RecordBufferDraftView(model: model, onFinishEditing: onFinishEditing)
          }
          .opacity(presentation.mode == .drafts ? 1 : 0)
          .allowsHitTesting(presentation.mode == .drafts)
          .disabled(presentation.mode != .drafts || presentation.isCollapsed)
          .accessibilityHidden(presentation.mode != .drafts || presentation.isCollapsed)
        }
        .frame(width: viewport.size.width, height: viewport.size.height)
      }
    }
  }

  private var modeControl: some View {
    HStack(spacing: 2) {
      ForEach(RecordPanelPresentation.Mode.allCases, id: \.self) { mode in
        let selected = presentation.mode == mode
        Button {
          onModeChange(mode)
        } label: {
          if selected {
            modeLabel(mode, selected: true)
              .rillGlass(in: Capsule(), interactive: true)
              .glassEffectID("mode-selection", in: modeGlass)
              .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
          } else {
            modeLabel(mode, selected: false)
          }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(3)
    .background(.thinMaterial, in: Capsule())
    .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: presentation.mode)
    .disabled(buffers.editor.session?.hasMarkedText == true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(panelText(.panelContent))
    .accessibilityIdentifier("record-panel.mode")
  }

  private func modeLabel(_ mode: RecordPanelPresentation.Mode, selected: Bool) -> some View {
    HStack(spacing: 5) {
      Text(panelText(mode == .drafts ? .drafts : .collections))
      if mode == .drafts {
        Text("\(buffers.snapshot?.remainingCount ?? 0)")
          .monospacedDigit().foregroundStyle(.secondary)
          .frame(width: 30).lineLimit(1).minimumScaleFactor(0.7)
      }
    }
    .font(.system(size: 12, weight: selected ? .medium : .regular))
    .foregroundStyle(selected ? Color.primary : Color.secondary)
    .frame(width: 92, height: 30)
    .contentShape(Capsule())
  }

  private var notice: some View {
    HStack(spacing: 8) {
      Image(systemName: needsAttention ? RillSystemSymbol.exclamationmarkCircle.rawValue : RillSystemSymbol.checkmarkCircle.rawValue)
        .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
        .font(.system(size: 13)).frame(width: 16)
      Text(noticeText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 0)
      Button(panelText(.review)) { showsOutputReview = true }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
        .frame(width: 48, height: 29)
        .opacity(needsAttention ? 1 : 0)
        .disabled(!needsAttention)
        .accessibilityHidden(!needsAttention)
        .accessibilityIdentifier("record-panel.review-output")
    }
    .padding(.horizontal, 16).frame(height: 36)
    .overlay(alignment: .top) { Divider().opacity(0.45) }
    .overlay(alignment: .bottom) { Divider().opacity(0.45) }
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
        Text(
          active.state == .delivered
            ? panelText(.deliveredButNotSaved)
            : panelText(.confirmInsertion))
        HStack {
          Button(
            active.state == .delivered ? panelText(.retrySave) : panelText(.inserted),
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

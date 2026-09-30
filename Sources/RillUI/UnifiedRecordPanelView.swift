import AppKit
import SwiftUI

/// Both panes stay mounted so switching modes preserves native text input and undo.
public struct UnifiedRecordPanelView<Records: View>: View {
  @Bindable private var presentation: RecordPanelPresentation
  @Bindable private var model: AppModel
  private let records: Records
  private let onModeChange: (RecordPanelPresentation.Mode) -> Void
  private let onCollapse: () -> Void
  private let onExpand: () -> Void
  private let onClose: () -> Void
  private let onNeedsAttention: () -> Void

  public init(presentation: RecordPanelPresentation, model: AppModel,
              onModeChange: @escaping (RecordPanelPresentation.Mode) -> Void,
              onCollapse: @escaping () -> Void, onExpand: @escaping () -> Void,
              onClose: @escaping () -> Void, onNeedsAttention: @escaping () -> Void = {},
              @ViewBuilder records: () -> Records) {
    self.presentation = presentation
    self.model = model
    self.onModeChange = onModeChange
    self.onCollapse = onCollapse
    self.onExpand = onExpand
    self.onClose = onClose
    self.onNeedsAttention = onNeedsAttention
    self.records = records()
  }

  private var buffers: RecordBufferModel { model.recordWorkspace.buffers }
  private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: model.settings.language) }

  public var body: some View {
    ZStack(alignment: .topLeading) {
      expandedContent
        .frame(width: presentation.isCollapsed ? presentation.expandedWidth : nil,
               height: presentation.isCollapsed ? presentation.expandedHeight : nil)
        .opacity(presentation.isCollapsed ? 0 : 1)
        .allowsHitTesting(!presentation.isCollapsed)
        .accessibilityHidden(presentation.isCollapsed)
      if presentation.isCollapsed { pendingStrip }
    }
    .frame(width: presentation.isCollapsed ? 320 : nil, height: presentation.isCollapsed ? 56 : nil,
           alignment: .topLeading)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipped()
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("record-panel.unified")
    .onChange(of: buffers.editor.failure) { _, failure in
      if failure != nil, presentation.isCollapsed { onNeedsAttention() }
    }
  }

  private var expandedContent: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Picker(text(.panelContent), selection: Binding(
          get: { presentation.mode }, set: { onModeChange($0) })) {
          Text(text(.collections)).tag(RecordPanelPresentation.Mode.collections)
          Text(text(.drafts) + " · \(buffers.snapshot?.remainingCount ?? 0)")
            .tag(RecordPanelPresentation.Mode.drafts)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
        .disabled(buffers.editor.session?.hasMarkedText == true)
        .accessibilityIdentifier("record-panel.mode")
        Spacer(minLength: 8)
        Toggle(isOn: $presentation.isPinned) {
          Label(text(.keepOpen), systemImage: presentation.isPinned ? RillSystemSymbol.pinFill.rawValue : RillSystemSymbol.pin.rawValue)
        }
        .toggleStyle(.button).labelStyle(.iconOnly)
        .help(text(.keepThePanelExpandedWhen))
        Button(action: onCollapse) { Image(systemName: RillSystemSymbol.rectangleCompressVertical.rawValue) }
          .accessibilityLabel(text(.collapseToPendingStrip))
          .help(text(.collapseToPendingStrip))
          .disabled(buffers.editor.session?.hasMarkedText == true)
        Button(action: onClose) { Image(systemName: RillSystemSymbol.xmark.rawValue) }
          .accessibilityLabel(text(.closePanel))
      }
      .controlSize(.small).padding(12)
      .rillFloatingControlSurface()
      ZStack {
        records
          .opacity(presentation.mode == .collections ? 1 : 0)
          .allowsHitTesting(presentation.mode == .collections)
          .disabled(presentation.mode != .collections || presentation.isCollapsed)
          .accessibilityHidden(presentation.mode != .collections)
        RecordBufferDraftView(model: model, embedded: true)
          .opacity(presentation.mode == .drafts ? 1 : 0)
          .allowsHitTesting(presentation.mode == .drafts)
          .disabled(presentation.mode != .drafts || presentation.isCollapsed)
          .accessibilityHidden(presentation.mode != .drafts)
      }
      if buffers.snapshot?.active != nil || buffers.message != nil {
        Divider()
        outputFeedback.padding(12)
      }
    }
  }

  private var pendingStrip: some View {
    HStack(spacing: 8) {
      Button(action: onExpand) {
        HStack(spacing: RillSpacing.dense) {
          Image(systemName: needsAttention ? "exclamationmark.circle" : "tray.full")
            .foregroundStyle(needsAttention ? Color.orange : Color.accentColor)
          VStack(alignment: .leading, spacing: 3) {
            Text(text(.drafts) + " · \(buffers.snapshot?.remainingCount ?? 0)")
              .font(.caption.weight(.semibold))
            Text(stripSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
          Image(systemName: RillSystemSymbol.arrowUpLeftAndArrowDownRight.rawValue).font(.caption)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("record-panel.expand")
      Button(action: onClose) { Image(systemName: RillSystemSymbol.xmark.rawValue).font(.caption) }
        .buttonStyle(.plain).accessibilityLabel(text(.closePendingStrip))
    }
    .padding(.horizontal, 12).frame(width: 320, height: 56)
    .rillFloatingControlSurface()
    .accessibilityIdentifier("record-panel.pending-strip")
  }

  private var needsAttention: Bool {
    buffers.editor.failure != nil || buffers.message != nil || buffers.snapshot?.active != nil
  }

  private var stripSummary: String {
    if buffers.editor.failure != nil { return text(.editsNeedAttention) }
    if buffers.snapshot?.active != nil { return text(.outputNeedsConfirmation) }
    if let message = buffers.message { return message }
    return buffers.snapshot?.nextHeader?.preview
      ?? (buffers.snapshot?.next == nil ? text(.nothingPending) : text(.processing))
  }

  private var outputFeedback: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let active = buffers.snapshot?.active {
        HStack {
          Text(active.state == .delivered
               ? text(.deliveredStateNotSaved)
               : text(.checkTheTargetBeforeConfirming))
            .font(.caption)
          Spacer()
          Button(active.state == .delivered ? text(.retrySave) : text(.inserted),
                 action: buffers.confirmAction)
          if active.state != .delivered {
            Button(text(.retryItem), action: buffers.retryAction)
          }
        }
        .disabled(buffers.isSending)
      }
      if let message = buffers.message {
        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .accessibilityIdentifier("record-panel.output-feedback")
  }
}

private struct FloatingControlSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    if reduceTransparency || contrast == .increased {
      content.background(Color(nsColor: .controlBackgroundColor))
    } else {
      content.background {
        RoundedRectangle(cornerRadius: RillRadius.section)
          .glassEffect(.regular, in: .rect(cornerRadius: RillRadius.section))
      }
    }
  }
}

extension View {
  func rillFloatingControlSurface() -> some View { modifier(FloatingControlSurface()) }
}

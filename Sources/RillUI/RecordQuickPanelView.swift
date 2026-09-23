import AppKit
import RillCore
import SwiftUI

public struct RecordCapacityView: View {
  public let capacity: RecordCapacity
  public let language: AppLanguage
  public let onCleanup: () -> Void

  public init(capacity: RecordCapacity, language: AppLanguage, onCleanup: @escaping () -> Void) {
    self.capacity = capacity
    self.language = language
    self.onCleanup = onCleanup
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(L10n.recordCapacity(capacity, language: language)).font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button(L10n.quickRecord(.cleanup, language: language), action: onCleanup)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("records.cleanup")
      }
      if capacity.isWarning || capacity.isCaptureLimited {
        Label(
          L10n.quickRecord(
            capacity.isCaptureLimited ? .capacityFull : .capacityWarning, language: language),
          systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
        )
        .font(.caption).foregroundStyle(capacity.isCaptureLimited ? Color.red : Color.orange)
        .accessibilityIdentifier("records.capacity-warning")
      }
    }
  }
}

public struct RecordCleanupSheet: View {
  @Bindable var model: RecordCleanupModel
  let language: AppLanguage

  public init(model: RecordCleanupModel, language: AppLanguage) {
    self.model = model
    self.language = language
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: RillSpacing.panel) {
      Text(L10n.quickRecord(.cleanupTitle, language: language)).font(.title2.weight(.semibold))
      Text(L10n.quickRecord(descriptionKey, language: language)).foregroundStyle(.secondary)
      if let plan = model.plan {
        LabeledContent(
          L10n.quickRecord(.delete, language: language), value: "\(plan.recordIDs.count)")
        LabeledContent(
          L10n.quickRecord(.memberships, language: language), value: "\(plan.membershipIDs.count)")
        LabeledContent(
          L10n.quickRecord(.protectedRecords, language: language), value: "\(plan.protectedCount)")
        LabeledContent(
          L10n.quickRecord(.freeSpace, language: language),
          value: ByteCountFormatter.string(
            fromByteCount: Int64(plan.byteCount), countStyle: .binary))
      }
      if let message = model.message {
        Text(L10n.quickRecord(message, language: language)).foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button(L10n.quickRecord(.cancel, language: language)) { model.cancel() }
          .keyboardShortcut(.cancelAction).disabled(model.isWorking)
        Button(L10n.quickRecord(.delete, language: language), role: .destructive) {
          Task { await model.confirm() }
        }
        .disabled(
          model.isWorking
            || (model.plan?.recordIDs.isEmpty != false
              && model.plan?.membershipIDs.isEmpty != false)
        )
      }
    }
    .padding(RillSpacing.panel)
    .frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled(model.isWorking)
  }
  private var descriptionKey: QuickRecordText {
    switch model.plan?.scope {
    case .record: .recordDeletion
    case .collection: .collectionDeletion
    case .membership: .membershipDeletion
    default: .cleanupDescription
    }
  }

}

enum RecordQuickPanelLayoutPolicy {
  static func usesSidePreview(width: CGFloat) -> Bool { width >= 760 }
}

public struct RecordQuickPanelView: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Bindable private var model: RecordQuickPanelModel
  private let language: AppLanguage
  private let onPaste: (RecordReuseSubject) -> Void
  private let onCopy: (RecordReuseSubject) -> Void
  private let onShowRecord: (RecordID) -> Void
  private let onClose: () -> Void
  private let capturePaused: Bool

  public init(
    model: RecordQuickPanelModel, language: AppLanguage, capturePaused: Bool,
    onPaste: @escaping (RecordReuseSubject) -> Void, onCopy: @escaping (RecordReuseSubject) -> Void,
    onShowRecord: @escaping (RecordID) -> Void, onClose: @escaping () -> Void
  ) {
    self.model = model
    self.language = language
    self.capturePaused = capturePaused
    self.onPaste = onPaste
    self.onCopy = onCopy
    self.onShowRecord = onShowRecord
    self.onClose = onClose
  }

  public var body: some View {
    VStack(spacing: 0) {
      RecordSearchField(
        text: $model.searchText, placeholder: text(.search), onMove: model.moveSelection,
        onSubmit: pasteSelection,
        onDigit: { index in
          guard let subject = model.subject(at: index) else { return }
          onPaste(subject)
        },
        onCancel: {
          if model.preview != nil { model.closePreview() } else { onClose() }
        }
      )
      .frame(height: 30)
      .padding(RillSpacing.panel)
      HStack(spacing: RillSpacing.row) {
        Toggle(text(.pinned), isOn: $model.pinnedOnly).toggleStyle(.button)
        Toggle(text(.currentApp), isOn: $model.currentAppOnly).toggleStyle(.button).disabled(
          !model.canFilterCurrentApp)
        Picker(text(.allTypes), selection: $model.kind) {
          Text(text(.allTypes)).tag(RecordPayloadKind?.none)
          Text(text(.text)).tag(RecordPayloadKind?.some(.text))
          Text(text(.image)).tag(RecordPayloadKind?.some(.image))
          Text(text(.files)).tag(RecordPayloadKind?.some(.files))
        }.labelsHidden().frame(width: 115)
        Spacer()
        if model.isSearching {
          ProgressView().controlSize(.small).accessibilityLabel(text(.searching))
        }
        Button(action: model.togglePreview) {
          Image(systemName: RillSystemSymbol.docTextMagnifyingglass.rawValue)
        }
        .help(text(.preview)).accessibilityLabel(text(.preview)).disabled(
          model.selectedRecord == nil)
        Button(action: onClose) { Image(systemName: RillSystemSymbol.xmarkCircleFill.rawValue) }
          .help(text(.close)).accessibilityLabel(text(.close))
      }
      .controlSize(.small)
      .padding(.horizontal, RillSpacing.panel)
      .padding(.bottom, RillSpacing.row)
      Divider()
      GeometryReader { geometry in
        if RecordQuickPanelLayoutPolicy.usesSidePreview(width: geometry.size.width), let preview = model.preview {
          HSplitView {
            resultList.frame(minWidth: 300, idealWidth: 360)
            RecordQuickPreview(record: preview.record, language: language)
              .padding(RillSpacing.panel).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
          }
        } else {
          VStack(spacing: 0) {
            resultList
            if let preview = model.preview {
              Divider()
              RecordQuickPreview(record: preview.record, language: language)
                .frame(maxHeight: 180).padding(RillSpacing.row)
            }
          }
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: RillSpacing.row) {
        if capturePaused { Text(text(.capturePaused)).font(.caption).foregroundStyle(.secondary) }
        if let message = model.cleanup.plan == nil
          ? (model.cleanup.message ?? model.message) : model.message
        {
          Text(text(message)).font(.caption).foregroundStyle(
            message == .copied ? Color.secondary : Color.orange)
        }
        HStack {
          Text("↑↓").foregroundStyle(.secondary).accessibilityHidden(true)
          Text(text(.paste) + " ↩").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(text(.copy)) {
            if let subject = model.selectedRecord?.reuseSubject { onCopy(subject) }
          }
          .disabled(model.selectedRecord == nil)
          Button(RecordDeliveryTitle.make(applicationName: model.pasteTargetName, language: language), action: pasteSelection).disabled(model.selectedRecord == nil)
        }
        .controlSize(.small)
        RecordCapacityView(capacity: model.capacity, language: language) {
          Task { await model.cleanup.request() }
        }
      }.padding(RillSpacing.panel)
    }
    .background {
      if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
      else { Rectangle().fill(.regularMaterial) }
    }
    .sheet(
      isPresented: Binding(
        get: { model.cleanup.plan != nil }, set: { if !$0 { model.cleanup.cancel() } })
    ) {
      RecordCleanupSheet(model: model.cleanup, language: language)
    }
    .accessibilityIdentifier("records.quick-panel")
  }

  private var resultList: some View {
      ScrollViewReader { proxy in
        List(selection: $model.selectedID) {
          ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
            row(item, index: index).tag(item.id).id(item.id)
              .onTapGesture(count: 2) { onPaste(item.reuseSubject) }
              .contextMenu {
                Button(text(.paste)) { onPaste(item.reuseSubject) }
                Button(text(.copy)) { onCopy(item.reuseSubject) }
                Button(text(item.metadata.isPinned ? .unpin : .pinned)) {
                  Task { await model.togglePin(item) }
                }
                Button(text(.showInRecords)) { onShowRecord(item.id) }
              }
          }
          if model.nextOffset != nil {
            Button(text(.loadMore)) { model.loadMore() }.disabled(model.isSearching)
          }
        }
        .listStyle(.inset)
        .overlay {
          if model.results.isEmpty && !model.isSearching {
            ContentUnavailableView(
              model.searchText.isEmpty ? text(.noRecords) : text(.noResults),
              systemImage: RillSystemSymbol.tray.rawValue)
          }
        }
        .onChange(of: model.selectedID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
  }

  private func text(_ key: QuickRecordText) -> String { L10n.quickRecord(key, language: language) }
  private func pasteSelection() {
    if let subject = model.selectedRecord?.reuseSubject { onPaste(subject) }
  }

  private func row(_ item: RecordSummary, index: Int) -> some View {
    HStack(spacing: RillSpacing.row) {
      Image(
        systemName: item.header.kind == .image
          ? RillSystemSymbol.photo.rawValue
          : (item.header.kind == .files
            ? RillSystemSymbol.docOnDoc.rawValue : RillSystemSymbol.textAlignLeft.rawValue)
      )
      .frame(width: 24).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(item.header.kind == .image ? text(.image) : item.header.preview).lineLimit(2)
        HStack(spacing: RillSpacing.row) {
          if item.metadata.isPinned { Image(systemName: RillSystemSymbol.pinFill.rawValue) }
          Text(item.header.provenance.sourceApplicationName ?? "").lineLimit(1)
          Text(item.header.createdAt, style: .relative)
        }.font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: RillSpacing.row)
      if index < 9 {
        Text("⌘\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAction(named: Text(text(.paste))) { onPaste(item.reuseSubject) }
  }
}

private struct RecordQuickPreview: View {
  let record: Record
  let language: AppLanguage
  var body: some View {
    ScrollView {
      switch record.payload {
      case .text(let text): RecordTextPreview(text: text, language: language)
      case .image(let data):
        RecordImagePreview(id: record.id, data: data)
      case .files(let urls):
        VStack(alignment: .leading) { ForEach(urls, id: \.self) { Text($0.lastPathComponent) } }
      }
    }
  }
}

struct RecordSearchField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let onMove: (Int) -> Void
  let onSubmit: () -> Void
  let onDigit: (Int) -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> SearchField {
    let field = SearchField()
    field.delegate = context.coordinator
    field.placeholderString = placeholder
    field.sendsSearchStringImmediately = true
    field.onDigit = onDigit
    field.setAccessibilityIdentifier("records.quick-search")
    return field
  }
  func updateNSView(_ field: SearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    field.placeholderString = placeholder
    field.onDigit = onDigit
  }
  final class SearchField: NSSearchField {
    var onDigit: ((Int) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { window.makeFirstResponder(self) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if (currentEditor() as? NSTextView)?.hasMarkedText() != true,
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
        let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit)
      {
        onDigit?(digit - 1)
        return true
      }
      return super.performKeyEquivalent(with: event)
    }
  }
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: RecordSearchField
    init(_ parent: RecordSearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      guard !textView.hasMarkedText() else { return false }
      switch selector {
      case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
      case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
      case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
      case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
      default: return false
      }
      return true
    }
  }
}

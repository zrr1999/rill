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

public struct RecordQuickPanelView: View {
  @State private var showsFilters = false
  @Bindable private var model: RecordQuickPanelModel
  private let language: AppLanguage
  private let onPaste: (RecordReuseSubject) -> Void
  private let onCopy: (RecordReuseSubject) -> Void
  private let onShowRecord: (RecordID) -> Void
  private let onClose: () -> Void
  private let onConfigureJev: (SettingsNavigationRequest) -> Void
  private let capturePaused: Bool

  public init(
    model: RecordQuickPanelModel, language: AppLanguage, capturePaused: Bool,
    onPaste: @escaping (RecordReuseSubject) -> Void, onCopy: @escaping (RecordReuseSubject) -> Void,
    onShowRecord: @escaping (RecordID) -> Void, onClose: @escaping () -> Void,
    onConfigureJev: @escaping (SettingsNavigationRequest) -> Void
  ) {
    self.model = model
    self.language = language
    self.capturePaused = capturePaused
    self.onPaste = onPaste
    self.onCopy = onCopy
    self.onShowRecord = onShowRecord
    self.onClose = onClose
    self.onConfigureJev = onConfigureJev
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: RecordPanelAppearance.paneInset) {
        VStack(spacing: 9) {
          HStack(spacing: 4) {
            Menu {
              Picker(
                panelText(.collection),
                selection: Binding(
                  get: { model.collectionID }, set: { model.setCollection($0) })
              ) {
                Text(panelText(.allRecords)).tag(RecordCollectionID?.none)
                ForEach(model.collections) { Text($0.name).tag(Optional($0.id)) }
              }.pickerStyle(.inline)
            } label: {
              Text(
                model.collections.first(where: { $0.id == model.collectionID })?.name
                  ?? panelText(.allRecords)
              ).lineLimit(1)
            }
            .menuStyle(.borderlessButton).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("quick-records.collection")
            Button {
              showsFilters = true
            } label: {
              Image(systemName: RillSystemSymbol.sliderHorizontal3.rawValue)
            }
            .buttonStyle(.borderless).font(.system(size: 12)).frame(width: 28, height: 28)
            .foregroundStyle(.secondary)
            .accessibilityLabel(panelText(.searchAndFilterOptions))
          }.controlSize(.small).frame(height: 25).padding(.horizontal, 13).padding(.top, 10)
          RecordSearchField(
            text: Binding(get: { model.searchText }, set: { model.setSearchText($0) }),
            placeholder: text(.search), onMove: model.moveSelection, onSubmit: pasteSelection,
            onDigit: { if let subject = model.subject(at: $0) { onPaste(subject) } }, onCancel: onClose
          )
          .padding(.horizontal, 6).recordPanelSearchSurface().padding(.horizontal, 9)
          resultList
        }.frame(width: RecordPanelAppearance.sidebarWidth)
          .recordPanelGlass(in: RecordPanelAppearance.paneShape)
        contentPreview
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(RecordPanelAppearance.paper)
          .clipShape(RecordPanelAppearance.paneShape)
      }
      .padding(RecordPanelAppearance.paneInset)
      HStack(spacing: 8) {
        Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 0)
        addToDrafts.frame(width: 88)
        Button(text(.copy)) {
          if let subject = model.selectedRecord?.reuseSubject { onCopy(subject) }
        }.buttonStyle(.glass).buttonBorderShape(.capsule).buttonSizing(.flexible)
          .frame(width: 60, height: 32).disabled(model.selectedRecord == nil)
          .accessibilityIdentifier("quick-records.copy")
        Button(action: pasteSelection) {
          Text(RecordDeliveryTitle.make(applicationName: model.pasteTargetName, language: language))
            .lineLimit(1)
        }
        .buttonStyle(.glassProminent).buttonBorderShape(.capsule).buttonSizing(.flexible)
        .tint(.accentColor).frame(width: 84, height: 32).disabled(model.selectedRecord == nil)
        .help(RecordDeliveryTitle.make(applicationName: model.pasteTargetName, language: language))
        .accessibilityIdentifier("quick-records.insert")
      }
      .font(.system(size: 12)).controlSize(.large)
      .padding(.horizontal, 15).frame(height: 56)
      .accessibilityIdentifier("quick-records.actions")
    }
    .onAppear { if !model.isPreviewVisible { model.togglePreview() } }
    .onChange(of: model.selectedID) { _, _ in if !model.isPreviewVisible { model.togglePreview() } }
    .sheet(
      isPresented: Binding(
        get: { showsFilters || model.jev?.isPresented == true },
        set: {
          if !$0 {
            showsFilters = false
            model.jev?.invalidate()
          }
        })
    ) {
      if let jev = model.jev, jev.isPresented {
        RecordJevSheet(
          model: jev, language: language, onSelect: model.selectJevCandidate,
          onConfigure: onConfigureJev, onRetry: model.compareWithJev)
      } else {
        filters
      }
    }
    .accessibilityIdentifier("records.quick-panel")
  }

  private var statusText: String {
    if let message = model.cleanup.plan == nil ? (model.cleanup.message ?? model.message) : model.message {
      return text(message)
    }
    if model.capacity.isCaptureLimited { return text(.capacityFull) }
    if model.capacity.isWarning { return text(.capacityWarning) }
    return capturePaused ? text(.capturePaused) : text(.paste) + " ↩"
  }

  private var addToDrafts: some View {
    Menu {
      ForEach(model.buffers.snapshot?.buffers ?? []) { summary in
        Button(summary.buffer.name) {
          if let id = model.selectedID { model.buffers.enqueue(id, bufferID: summary.id) }
        }
      }
    } label: {
      Text(panelText(.addToDrafts))
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden)
    .font(.system(size: 12)).foregroundStyle(Color.accentColor).frame(height: 32)
    .disabled(model.selectedID == nil)
    .accessibilityIdentifier("quick-records.add-to-drafts")
  }

  private var filters: some View {
    VStack(alignment: .leading, spacing: 16) {
      Toggle(text(.pinned), isOn: Binding(get: { model.pinnedOnly }, set: { model.setPinnedOnly($0) }))
      Toggle(text(.currentApp), isOn: Binding(get: { model.currentAppOnly }, set: { model.setCurrentAppOnly($0) }))
        .disabled(!model.canFilterCurrentApp)
      Picker(text(.allTypes), selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
        Text(text(.allTypes)).tag(RecordPayloadKind?.none)
        Text(text(.text)).tag(RecordPayloadKind?.some(.text))
        Text(text(.image)).tag(RecordPayloadKind?.some(.image))
        Text(text(.files)).tag(RecordPayloadKind?.some(.files))
      }
      if model.canSearchByMeaning { semanticControls }
      if model.jev != nil {
        Button(L10n.jev(.open, language: language)) { model.compareWithJev() }
          .disabled(!model.canCompareWithJev)
          .accessibilityIdentifier("records.jev-review")
      }
      RecordCapacityView(capacity: model.capacity, language: language) {
        Task { await model.cleanup.request() }
      }
      HStack {
        Spacer()
        Button(panelText(.done)) { showsFilters = false }
      }
    }.padding(20).frame(width: 440)
      .sheet(isPresented: Binding(get: { model.cleanup.plan != nil }, set: { if !$0 { model.cleanup.cancel() } })) {
        RecordCleanupSheet(model: model.cleanup, language: language)
      }
  }

  private var contentPreview: some View {
    Group {
      if let preview = model.preview {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 4) {
            Text(text(.preview)).font(.system(size: 17, weight: .medium)).lineLimit(1)
            HStack(spacing: 5) {
              if let application = preview.record.provenance.sourceApplicationName { Text(application) }
              Text(preview.record.createdAt, style: .relative)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
          }.padding(.horizontal, 22).padding(.top, 18).frame(height: 72, alignment: .top)
          ScrollView {
            RecordContentPreview(record: preview.record, language: language, imageHeight: 240)
              .font(.system(size: 14)).lineSpacing(7)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 22).padding(.bottom, 18)
          }
        }
      } else {
        VStack {
          Spacer()
          if model.isLoadingPreview || model.isSearching {
            ProgressView().controlSize(.small)
          } else {
            Text(text(.recordUnavailable)).font(.system(size: 12)).foregroundStyle(.secondary)
          }
          Spacer()
        }
      }
    }
  }

  private var resultList: some View {
    ScrollViewReader { proxy in
      List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
          selectableRow(item, index: index)
        }
        if model.nextOffset != nil {
          Button(text(.loadMore)) { model.loadMore() }.disabled(model.isSearching)
        }
        if !model.additionalSemanticResults.isEmpty {
          Section(text(.semanticCandidates)) {
            ForEach(Array(model.additionalSemanticResults.enumerated()), id: \.element.id) { index, item in
              selectableRow(item, index: model.results.count + index)
            }
          }
        }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .overlay {
        if model.selectableResults.isEmpty && !model.isSearching && model.semanticState != .working {
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

  private var semanticControls: some View {
    VStack(alignment: .leading, spacing: RillSpacing.row) {
      HStack {
        if model.semanticState == .working {
          ProgressView().controlSize(.small)
          Text(semanticProgressText).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(text(.cancel)) { model.cancelSemanticSearch() }
        } else {
          Button(text(model.semanticState == .needsModel ? .downloadSearchModel : .meaningSearch)) {
            model.searchByMeaning(downloadIfNeeded: model.semanticState == .needsModel)
          }.disabled(model.isSearching)
          Spacer()
        }
      }
      if let status = semanticStatus {
        Text(text(status)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .controlSize(.small)
    .padding(.horizontal, RillSpacing.panel)
    .padding(.bottom, RillSpacing.row)
    .accessibilityIdentifier("records.semantic-search")
  }

  private var semanticProgressText: String {
    switch model.semanticProgress {
    case .indexing(let completed, let total):
      language == .english ? "Preparing records \(completed) / \(total)" : "正在准备记录 \(completed) / \(total)"
    case .preparing(let fraction) where fraction > 0 && fraction < 1:
      language == .english ? "Downloading \(Int(fraction * 100))%" : "正在下载 \(Int(fraction * 100))%"
    default: text(.preparingSearchModel)
    }
  }

  private var semanticStatus: QuickRecordText? {
    switch model.semanticState {
    case .needsModel: .localSearchNotice
    case .failed: .semanticFailed
    case .changed: .semanticChanged
    case .invalidQuery: .semanticQueryTooLong
    case .ready:
      model.semanticLimitedRecordCount > 0 ? .semanticLimited : (model.additionalSemanticResults.isEmpty ? .semanticNoResults : nil)
    default: nil
    }
  }

  private func selectableRow(_ item: RecordSummary, index: Int) -> some View {
    row(item, index: index).tag(item.id).id(item.id)
      .listRowSeparator(.hidden)
      .onTapGesture(count: 2) { onPaste(item.reuseSubject) }
      .contextMenu {
        Button(text(.preview)) {
          model.select(item.id)
          if !model.isPreviewVisible { model.togglePreview() }
        }
        Button(text(.paste)) { onPaste(item.reuseSubject) }
        Button(text(.copy)) { onCopy(item.reuseSubject) }
        Button(text(item.metadata.isPinned ? .unpin : .pinned)) {
          Task { await model.togglePin(item) }
        }
        Button(text(.showInRecords)) { onShowRecord(item.id) }
      }
  }

  private func panelText(_ key: RecordPanelText) -> String { L10n.recordPanel(key, language: language) }
  private func text(_ key: QuickRecordText) -> String { L10n.quickRecord(key, language: language) }
  private func pasteSelection() {
    if let subject = model.selectedRecord?.reuseSubject { onPaste(subject) }
  }

  private func row(_ item: RecordSummary, index: Int) -> some View {
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 4) {
        Text(item.header.kind == .image ? text(.image) : item.header.preview)
          .font(.system(size: 12, weight: .medium)).lineLimit(1)
        HStack(spacing: 5) {
          if item.metadata.isPinned { Image(systemName: RillSystemSymbol.pinFill.rawValue) }
          Text(item.header.provenance.sourceApplicationName ?? "").lineLimit(1)
          Text(item.header.createdAt, style: .relative)
        }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if index < 9 {
        Text("⌘\(index + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .frame(minHeight: 43).padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAction(named: Text(text(.paste))) { onPaste(item.reuseSubject) }
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
    field.drawsBackground = false
    field.controlSize = .small
    field.font = .systemFont(ofSize: 12)
    field.onDigit = onDigit
    field.setAccessibilityIdentifier("records.quick-search")
    return field
  }
  func updateNSView(_ field: SearchField, context: Context) {
    context.coordinator.parent = self
    field.isEnabled = context.environment.isEnabled
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
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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

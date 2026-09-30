import RillCore
import SwiftUI

public struct RecordBufferSummaryView: View {
  @Bindable private var model: RecordBufferModel
  private let language: AppLanguage
  public init(model: RecordBufferModel, language: AppLanguage) {
    self.model = model
    self.language = language
  }
  private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(text(.outputNext)).font(.headline)
        Spacer()
        Text("\(model.snapshot?.remainingCount ?? 0)").monospacedDigit()
          .accessibilityLabel(text(.remainingCount))
      }
      if let header = model.snapshot?.nextHeader {
        Text(header.preview.isEmpty ? header.kind.rawValue : header.preview).lineLimit(2)
        Text(header.provenance.sourceApplicationName ?? "Rill").font(.caption).foregroundStyle(
          .secondary)
      } else {
        Text(
          model.snapshot?.next?.state == .preparing
            ? text(.processingStatus) : text(.nothingToOutput)
        )
        .foregroundStyle(.secondary)
      }
    }
  }
}

public struct RecordBufferStatusView: View {
  @Bindable private var model: RecordBufferModel
  private let language: AppLanguage
  public init(model: RecordBufferModel, language: AppLanguage) {
    self.model = model
    self.language = language
  }
  private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RecordBufferSummaryView(model: model, language: language)
      if let active = model.snapshot?.active {
        if active.state == .awaitingConfirmation || active.state == .delivering {
          Text(text(.confirmTheResult)).font(.headline)
          Text(
            text(.advanceOnlyAfterConfirmingInsertion)
          )
          .font(.caption)
          HStack {
            Button(text(.inserted), action: model.confirmAction)
            Button(text(.retryItem), action: model.retryAction)
          }.disabled(model.isSending)
        } else if active.state == .delivered {
          Text(text(.deliveredSettlementPending))
          Button(text(.retrySaving), action: model.confirmAction)
        }
      }
      if let message = model.message { Text(message).font(.caption) }
      HStack {
        Button(text(.openDrafts), action: model.openEditorAction)
        if model.snapshot?.active == nil {
          Text(text(.focusTheTargetAndPress))
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(text(.close), action: model.cancelAction)
      }
    }
    .padding(16)
    .frame(minWidth: 340, idealWidth: 390)
    .accessibilityIdentifier("record-buffer.next")
  }
}

struct RecordBufferToolbar: View {
  @Bindable var workspace: RecordWorkspaceModel
  let language: AppLanguage
  @State private var setEntries: [BufferEntry] = []
  @State private var selectedSet: RecordBufferID?
  private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }

  var body: some View {
    HStack {
      Button(action: workspace.buffers.openEditorAction) {
        HStack(spacing: 8) {
          Label(text(.drafts), systemImage: "tray")
            .fixedSize()
          Text("\(workspace.buffers.snapshot?.remainingCount ?? 0)").monospacedDigit().fixedSize()
          Text(workspace.buffers.snapshot?.nextHeader?.preview
            ?? (workspace.buffers.snapshot?.next == nil ? text(.empty) : text(.processingStatus)))
            .foregroundStyle(.secondary).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .buttonStyle(.borderless)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("records.open-drafts")
      Menu {
        ForEach(workspace.buffers.snapshot?.buffers ?? []) { summary in
          if summary.buffer.policy == .set {
            Button("{} \(summary.buffer.name) (\(summary.count))") {
              setEntries = []
              selectedSet = summary.id
              Task {
                let entries = await workspace.buffers.entries(in: summary.id)
                guard selectedSet == summary.id else { return }
                setEntries = entries
              }
            }
          } else {
            Toggle(
              "\(summary.buffer.policy == .stack ? "()" : "[]") \(summary.buffer.name) (\(summary.count))",
              isOn: Binding(
                get: { summary.buffer.isEnabled },
                set: { workspace.buffers.setEnabled($0, buffer: summary.buffer) }))
          }
        }
        Divider()
        if let recordID = workspace.selectedRecordID {
          ForEach(workspace.buffers.snapshot?.buffers ?? []) { summary in
            Button(text(.addTo) + summary.buffer.name) {
              workspace.buffers.enqueue(recordID, bufferID: summary.id)
            }
          }
        }
        Button(text(.newSet)) {
          workspace.buffers.createSet(name: text(.reusableItems))
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .help(text(.manageOutputBuffers))
      .accessibilityLabel(text(.manageOutputBuffers))
    }
    .padding(10)
    .task { workspace.buffers.start() }
    .popover(
      isPresented: Binding(get: { selectedSet != nil }, set: { if !$0 { selectedSet = nil } })
    ) {
      let headers = Dictionary(
        uniqueKeysWithValues: workspace.snapshot.records.map { ($0.id, $0.header) })
      ScrollView {
        LazyVStack(alignment: .leading) {
          ForEach(setEntries) { entry in
            let header = entry.recordID.flatMap { headers[$0] }
            Button(
              header?.preview.isEmpty == false ? header!.preview : header?.kind.rawValue ?? "Record"
            ) {
              selectedSet = nil
              workspace.buffers.outputAction(entry.id)
            }.lineLimit(2)
          }
          if setEntries.isEmpty { Text(text(.noItems)) }
        }
      }.padding().frame(width: 320, height: 320)
    }
  }
}

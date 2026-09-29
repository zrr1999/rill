import AppKit
import RillCore
import SwiftUI

struct CorpusRecordingArchiveSheet: View {
  @Bindable var model: CorpusRecordingArchiveModel
  let language: AppLanguage
  @Environment(\.dismiss) private var dismiss
  @State private var choosingDestination = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(text(.title)).font(.title2.bold())
      Text(text(.disclosure)).font(.callout).foregroundStyle(.secondary)
      if model.state == .loading {
        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
      } else if model.receipts.isEmpty {
        Text(text(.empty)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
      } else {
        HStack {
          Button(text(.selectAll)) { model.selection = Set(model.receipts.map(\.runID)) }
          Button(text(.selectNone)) { model.selection = [] }
          Spacer()
          Text("\(model.selection.count) / \(model.receipts.count)").monospacedDigit()
        }
        List(selection: $model.selection) {
          ForEach(model.receipts, id: \.runID) { receipt in
            HStack {
              VStack(alignment: .leading) {
                Text(receipt.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                Text(receipt.runID.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
              }
              Spacer()
              Text(Duration.seconds(receipt.durationSeconds).formatted(.time(pattern: .minuteSecond)))
              Text(text(outcomeKey(receipt.outcome))).foregroundStyle(.secondary)
            }.tag(receipt.runID)
          }
        }.frame(minHeight: 200)
      }
      HStack {
        Picker(text(.source), selection: $model.evidenceKind) {
          Text(text(.chooseSource)).tag(nil as CorpusEvidenceKind?)
          Text(text(.microphone)).tag(CorpusEvidenceKind.microphone as CorpusEvidenceKind?)
          Text(text(.synthetic)).tag(CorpusEvidenceKind.synthetic as CorpusEvidenceKind?)
          Text(text(.publicFixture)).tag(CorpusEvidenceKind.publicFixture as CorpusEvidenceKind?)
        }
        Picker(text(.split), selection: $model.split) {
          Text(text(.development)).tag(CorpusSplit.development)
          Text(text(.validation)).tag(CorpusSplit.validation)
        }
      }
      Toggle(text(.authorize), isOn: $model.authorizesPlaintextExport)
      if let error = model.error { Text(error).foregroundStyle(.red) }
      if let url = model.lastExportedURL {
        HStack {
          Text(text(.exported)).foregroundStyle(.secondary)
          Button(text(.showInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      }
      ForEach(model.cleanupPendingURLs, id: \.self) { url in
        HStack {
          Text(text(.cleanupPending)).foregroundStyle(.orange)
          Button(text(.showInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      }
      HStack {
        Button(text(.close)) { model.cancelSelection(); dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if model.state == .exporting { ProgressView().controlSize(.small) }
        Button(text(.exportSelection), action: chooseDestination)
          .disabled(!model.canExport || choosingDestination)
      }
    }
    .padding(24)
    .frame(width: 670, height: 590)
    .disabled(choosingDestination)
    .task { model.loadSelection() }
    .onDisappear { model.cancelSelection() }
  }

  private func text(_ key: CorpusArchiveTextKey) -> String { L10n.corpusArchive(key, language: language) }
  private func outcomeKey(_ outcome: CorpusRecordingOutcome) -> CorpusArchiveTextKey {
    switch outcome { case .completed: .completed; case .failed: .failed; case .cancelled: .cancelled }
  }

  private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = text(.exportSelection)
    choosingDestination = true
    panel.begin { response in
      choosingDestination = false
      if response == .OK, let url = panel.url { model.exportSelection(to: url) }
    }
  }
}

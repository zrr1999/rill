import RillCore
import SwiftUI

public struct RecordBufferSummaryView: View {
  @Bindable private var model: RecordBufferModel
  private let language: AppLanguage
  public init(model: RecordBufferModel, language: AppLanguage) {
    self.model = model
    self.language = language
  }
  private func text(_ zh: String, _ en: String) -> String {
    language == .simplifiedChinese ? zh : en
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(text("输出下一项", "Output Next")).font(.headline)
        Spacer()
        Text("\(model.snapshot?.remainingCount ?? 0)").monospacedDigit()
          .accessibilityLabel(text("剩余数量", "Remaining count"))
      }
      if let header = model.snapshot?.nextHeader {
        Text(header.preview.isEmpty ? header.kind.rawValue : header.preview).lineLimit(2)
        Text(header.provenance.sourceApplicationName ?? "Rill").font(.caption).foregroundStyle(
          .secondary)
      } else {
        Text(
          model.snapshot?.next?.state == .preparing
            ? text("处理中", "Processing") : text("没有待输出内容", "Nothing pending")
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
  private func text(_ zh: String, _ en: String) -> String {
    language == .simplifiedChinese ? zh : en
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RecordBufferSummaryView(model: model, language: language)
      if let active = model.snapshot?.active {
        if active.state == .awaitingConfirmation || active.state == .delivering {
          Text(text("结果待确认", "Confirm the result")).font(.headline)
          Text(
            text(
              "只有确认内容已插入，才会推进。部分输出时请先检查目标。",
              "Advance only after confirming insertion. Check the target after a partial output.")
          )
          .font(.caption)
          HStack {
            Button(text("已插入", "Inserted"), action: model.confirmAction)
            Button(text("重试此项", "Retry item"), action: model.retryAction)
          }.disabled(model.isSending)
        } else if active.state == .delivered {
          Text(text("已输出，等待保存状态", "Delivered; settlement pending"))
          Button(text("重试保存", "Retry saving"), action: model.confirmAction)
        }
      }
      if let message = model.message { Text(message).font(.caption) }
      HStack {
        if model.snapshot?.active == nil {
          Text(text("聚焦目标后按输出快捷键", "Focus the target and press the output shortcut"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(text("关闭", "Close"), action: model.cancelAction)
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
  private func text(_ zh: String, _ en: String) -> String {
    language == .simplifiedChinese ? zh : en
  }

  var body: some View {
    HStack {
      Label(text("下一项", "Next"), systemImage: "text.insert")
      Text(
        workspace.buffers.snapshot?.nextHeader?.preview
          ?? (workspace.buffers.snapshot?.next == nil
            ? text("空", "Empty") : text("处理中", "Processing"))
      )
      .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
      Text("\(workspace.buffers.snapshot?.remainingCount ?? 0)").monospacedDigit()
      Menu(text("待输出容器", "Output buffers")) {
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
            Button(text("加入 ", "Add to ") + summary.buffer.name) {
              workspace.buffers.enqueue(recordID, bufferID: summary.id)
            }
          }
        }
        Button(text("新建 Set", "New Set")) {
          workspace.buffers.createSet(name: text("手动取用", "Reusable items"))
        }
      }
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
          if setEntries.isEmpty { Text(text("暂无内容", "Empty")) }
        }
      }.padding().frame(width: 320, height: 320)
    }
  }
}

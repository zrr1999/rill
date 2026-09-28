import RillCore
import SwiftUI

public struct RecordBufferDraftView: View {
  @Bindable private var model: RecordBufferDraftModel
  @Bindable private var voice: VoiceRunModel
  private let language: AppLanguage
  private let embedded: Bool
  @State private var showsDiscard = false
  @State private var comparesRecognition = true

  public init(model: RecordBufferDraftModel, voice: VoiceRunModel, language: AppLanguage, embedded: Bool = false) {
    self.model = model
    self.voice = voice
    self.language = language
    self.embedded = embedded
  }

  private func text(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
  private var isRecording: Bool {
    if case .recording = voice.workflowAudioRunState { return true }
    return false
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        if !embedded {
          Text(text("待发区", "Drafts")).font(.headline)
          Text("\(model.items.count)").monospacedDigit().foregroundStyle(.secondary)
        }
        Spacer()
        Button { model.newItem() } label: {
          Label(text("新建", "New item"), systemImage: "square.and.pencil")
        }
        .accessibilityIdentifier("record-buffer.new")
        .disabled(model.session?.hasMarkedText == true)
        Button(action: model.dictateNewItem) {
          Label(isRecording ? text("结束录音", "Finish recording") : text("录音新建", "Record new item"),
                systemImage: isRecording ? "stop.circle" : "mic")
        }
        .disabled(voice.isRunning && !isRecording)
      }
      .disabled(model.isBusy)
      .padding(14)
      Divider()
      HSplitView {
        itemList.frame(minWidth: 180, idealWidth: 215, maxWidth: 300)
        editor.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      footer.padding(12)
    }
    .frame(minWidth: 580, minHeight: embedded ? 420 : 520)
    .background(.background)
    .accessibilityIdentifier("record-buffer.drafts")
    .alert(text("移除此待发项？", "Remove this pending item?"), isPresented: $showsDiscard) {
      Button(text("移除", "Remove"), role: .destructive) { model.discardSelected() }
      Button(text("取消", "Cancel"), role: .cancel) {}
    } message: {
      Text(text("草稿修改将被丢弃，原始记录仍保留。", "Draft edits will be discarded. The original record is retained."))
    }
  }

  private var itemList: some View {
    List(selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })) {
      ForEach(model.buffers) { summary in
        Section {
          let entries = model.items.filter { $0.id.bufferID == summary.id }
          ForEach(summary.buffer.policy == .stack ? entries.reversed() : entries) { item in
            VStack(alignment: .leading, spacing: 5) {
              Text(item.state == .preparing ? text("正在识别…", "Recognizing…")
                : preview(item))
                .lineLimit(3)
              if item.hasEdits || item.suggestionCount > 0 || item.state != .ready {
                Text(item.suggestionCount > 0 ? text("有待应用结果", "Result to review")
                  : item.hasEdits ? text("已编辑", "Edited") : text("处理中", "In progress"))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
            .tag(item.id)
          }
        } header: {
          Text(bufferName(summary.buffer) + " · " + policyName(summary.buffer.policy)
            + (summary.buffer.isEnabled ? "" : text(" · 已停用", " · Disabled")))
        }
      }
    }
    .listStyle(.sidebar)
    .onKeyPress(.return) { model.send(); return .handled }
    .disabled(model.isBusy || model.session?.hasMarkedText == true)
    .overlay {
      if model.items.isEmpty {
        Text(text("新建草稿，或将语音结果\n先收进待发区。", "Create a draft or collect\nvoice results here first."))
          .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
      }
    }
  }

  @ViewBuilder private var editor: some View {
    if let session = model.session {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(text("编辑内容", "Edit text")).font(.subheadline.weight(.medium))
          Spacer()
          Text(model.isSaving ? text("保存中…", "Saving…")
            : session.hasUnsavedChanges ? text("尚未保存", "Unsaved") : text("已保存", "Saved"))
            .font(.caption).foregroundStyle(.secondary)
          Button(action: model.dictateHere) {
            Label(text("在此听写", "Dictate here"), systemImage: "mic.badge.plus")
          }
          .disabled(model.isBusy || voice.isRunning || session.hasMarkedText)
        }.padding(12).fixedSize(horizontal: false, vertical: true)
        BufferDraftTextEditor(model: model, session: session,
                              accessibilityLabel: text("待发内容", "Pending text"))
          .id(session.id)
          .frame(minHeight: 140)
        Divider()
        ScrollView {
          draftDetails(session)
        }
        .frame(minHeight: 44, idealHeight: model.showsChanges || !session.saved.suggestions.isEmpty ? 200 : 44,
               maxHeight: model.showsChanges || !session.saved.suggestions.isEmpty ? 240 : 44)
      }
    } else {
      ContentUnavailableView {
        Label(text("选择待发项", "Select an item"), systemImage: "text.cursor")
      } description: {
        Text(text("文字可直接修改、选中和撤销。识别中的条目完成后即可编辑。", "Edit, select and undo text here. Pending recognition becomes editable when it finishes."))
      }
    }
  }

  private func draftDetails(_ session: BufferEditingSession) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if !session.saved.suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(text("语音结果尚未应用，可在当前选区插入。", "Speech results are ready to insert at your selected position."))
            .font(.caption).foregroundStyle(.secondary)
          ForEach(session.saved.suggestions) { suggestion in
            Text(suggestion.text).textSelection(.enabled).lineLimit(4)
            HStack {
              Button(text("插入选区", "Insert at selection")) { model.resolveSuggestion(suggestion, insert: true) }
              Button(text("忽略", "Dismiss")) { model.resolveSuggestion(suggestion, insert: false) }
            }.disabled(model.isBusy || session.hasMarkedText)
          }
        }.padding(12)
        Divider()
      }
      DisclosureGroup(text("查看修改差异", "Review changes"), isExpanded: $model.showsChanges) {
        if model.showsChanges {
          VStack(alignment: .leading, spacing: 8) {
            if session.saved.recognitionText != nil {
              Picker(text("对比原文", "Compare with"), selection: $comparesRecognition) {
                Text(text("识别原文", "Recognition")).tag(true)
                Text(text("进入草稿时", "Initial draft")).tag(false)
              }.pickerStyle(.segmented)
            }
            let original = comparesRecognition ? session.saved.recognitionText ?? session.saved.originalText : session.saved.originalText
            ScrollView {
              diffText(original: original, edited: session.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100)
            Text(text("删除带删除线，新增带下划线。改写不一定是识别错误，差异不会自动写入词库。",
                      "Deletions are struck through; additions are underlined. Rewrites are not necessarily recognition errors. No vocabulary is learned automatically."))
              .font(.caption).foregroundStyle(.secondary)
          }.padding(.top, 8)
        }
      }.padding(12)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let failure = model.failure {
        HStack {
          Text(failureText(failure)).font(.caption).foregroundStyle(.red)
          if failure == .saving { Button(text("重试保存", "Retry save"), action: model.retrySaving) }
          if failure == .changed { Button(text("另存新草稿", "Save as new draft"), action: model.saveAsNewItem) }
        }
      }
      HStack {
        Text(model.targetName.map { text("发送到 ", "Send to ") + $0 }
          ?? text("发送后可回到目标输入框，按输出快捷键取用。", "Focus the target and use the output shortcut after preparing the item."))
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        Button(role: .destructive) { showsDiscard = true } label: {
          Label(text("移除", "Remove"), systemImage: "trash")
        }.disabled(model.selectedID == nil || model.isBusy || model.session?.hasMarkedText == true)
        Button(text("关闭", "Close"), action: model.closeAction)
        Button(text("发送所选项", "Send selected"), action: model.send)
          .buttonStyle(.borderedProminent)
          .disabled(model.selectedID == nil || model.isBusy || model.session?.hasMarkedText == true)
          .help(text("编辑时按 ⌘Return 发送；Return 换行。", "⌘Return sends while editing; Return inserts a newline."))
          .accessibilityIdentifier("record-buffer.send")
      }
    }
  }

  private func diffText(original: String, edited: String) -> Text {
    BufferTextDiff(original: original, edited: edited).segments.reduce(Text("")) { result, segment in
      let part = Text(segment.text)
      let styled = segment.kind == .removed ? part.strikethrough().foregroundColor(.red)
        : segment.kind == .inserted ? part.underline().foregroundColor(.accentColor) : part
      return Text("\(result)\(styled)")
    }
  }

  private func bufferName(_ buffer: RecordBuffer) -> String {
    if buffer.id == RecordBuffer.speechID { return text("语音", "Speech") }
    if buffer.id == RecordBuffer.clipboardID { return text("剪贴板", "Clipboard") }
    return buffer.name
  }
  private func preview(_ item: BufferItemSummary) -> String {
    let preview = model.session?.entryID == item.id
      ? RecordTextFormatting.previewText(model.session?.text ?? "", limit: 160) : item.preview
    return preview.isEmpty ? text("空白草稿", "Empty draft") : preview
  }
  private func policyName(_ policy: RecordBuffer.Policy) -> String {
    switch policy {
    case .stack: text("后进先出", "Stack")
    case .queue: text("先进先出", "Queue")
    case .set: text("手动取用", "Reusable")
    }
  }
  private func failureText(_ failure: RecordBufferDraftModel.Failure) -> String {
    switch failure {
    case .capacity: text("草稿超出本地内容上限，请缩短后重试。", "The draft exceeds the local content limit. Shorten it and retry.")
    case .empty: text("先输入内容，再发送。", "Enter some text before sending.")
    case .loading: text("无法读取待发项，请重新打开面板。", "Could not load items. Reopen the panel to retry.")
    case .saving: text("修改尚未保存，请重试。当前编辑仍保留在面板中。", "Edits are not saved. Retry; your text is still in the editor.")
    case .changed: text("条目已变化，当前修改已保留，尚未发送。", "The item changed. Your edits are retained; nothing was sent.")
    case .recording: text("无法开始录音，请检查语音设置。", "Could not start recording. Check voice settings.")
    }
  }
}

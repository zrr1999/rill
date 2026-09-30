import RillCore
import SwiftUI

public struct RecordBufferDraftView: View {
  @Bindable private var model: RecordBufferDraftModel
  @Bindable private var voice: VoiceRunModel
  @Bindable private var settings: SettingsPersistenceModel
  private let setVoiceCollection: (Bool) -> Void
  private let setClipboardCollection: (Bool) -> Void
  private let onFinishEditing: () -> Void
  private let copyText: (String) -> Void
  private var language: AppLanguage { settings.language }
  @State private var showsDiscard = false
  @State private var comparesRecognition = true
  @State private var query = ""
  @State private var showsCollectionControls = false
  @State private var showsDetails = false
  @State private var showsFailure = false

  public init(model: AppModel, onFinishEditing: @escaping () -> Void = {}) {
    self.model = model.recordWorkspace.buffers.editor
    self.voice = model.voice
    self.settings = model.settings
    self.onFinishEditing = onFinishEditing
    copyText = { [weak model] in model?.copyTextToClipboard($0) }
    setVoiceCollection = { [weak model] enabled in
      model?.setBuiltinPushToTalkOutputMode(enabled ? .saveToVoiceGroup : .pasteIntoApp)
    }
    setClipboardCollection = { [weak model] enabled in
      model?.setSystemClipboardCaptureEnabled(enabled)
    }
  }

  private func text(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
  private var isRecording: Bool {
    if case .recording = voice.workflowAudioRunState { return true }
    return false
  }

  private func panelText(_ key: RecordPanelText) -> String {
    L10n.recordPanel(key, language: language)
  }

  public var body: some View {
    content
    .accessibilityIdentifier("record-buffer.drafts")
    .alert(text("移除此待发项？", "Remove this pending item?"), isPresented: $showsDiscard) {
      Button(text("移除", "Remove"), role: .destructive) { model.discardSelected() }
      Button(text("取消", "Cancel"), role: .cancel) {}
    } message: {
      Text(text("草稿修改将被丢弃，原始记录仍保留。", "Draft edits will be discarded. The original record is retained."))
    }
    .sheet(isPresented: $showsCollectionControls) {
      VStack(alignment: .leading, spacing: 16) {
        Text(panelText(.draftSources)).font(.headline)
        collectionControls
        HStack { Spacer(); Button(panelText(.done)) { showsCollectionControls = false } }
      }.padding(20).frame(width: 560)
    }
    .sheet(isPresented: $showsDetails) {
      VStack(alignment: .leading, spacing: 0) {
        if let session = model.session { ScrollView { draftDetails(session) } }
        HStack { Spacer(); Button(panelText(.done)) { showsDetails = false } }.padding(12)
      }.frame(width: 520, height: 340)
    }
    .sheet(isPresented: $showsFailure) {
      VStack(alignment: .leading, spacing: 16) {
        if let failure = model.failure {
          Text(failureText(failure))
          failureActions(failure)
        }
        HStack { Spacer(); Button(panelText(.done)) { showsFailure = false } }
      }.padding(20).frame(width: 440)
    }
  }

  private var content: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        VStack(spacing: 9) {
          HStack(spacing: 4) {
            Text(panelText(.draftList)).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { model.newItem() } label: {
              Label(panelText(.newItem), systemImage: RillSystemSymbol.plus.rawValue)
                .font(.system(size: 11))
            }
              .buttonStyle(.plain).foregroundStyle(.secondary)
              .help(panelText(.newDraft))
              .accessibilityLabel(panelText(.newDraft))
              .accessibilityIdentifier("record-buffer.new")
              .disabled(model.isBusy || model.session?.hasMarkedText == true)
            Menu {
              Button(isRecording ? text("结束录音", "Finish recording") : text("录音新建", "Record new item"),
                     action: model.dictateNewItem)
                .disabled(model.isBusy || model.session?.hasMarkedText == true || (voice.isRunning && !isRecording))
              Button(panelText(.configureDraftSources)) { showsCollectionControls = true }
              Divider()
              Button(text("移除此项", "Remove item"), role: .destructive) { showsDiscard = true }
                .disabled(model.selectedID == nil || model.isBusy || model.session?.hasMarkedText == true)
            } label: { Image(systemName: RillSystemSymbol.ellipsisCircle.rawValue) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            .foregroundStyle(.secondary)
            .accessibilityLabel(panelText(.draftOptions))
          }.controlSize(.small).frame(height: 25).padding(.horizontal, 13).padding(.top, 10)
          HStack(spacing: 5) {
            Image(systemName: RillSystemSymbol.magnifyingglass.rawValue)
              .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(panelText(.searchDrafts), text: $query)
              .textFieldStyle(.plain).font(.system(size: 12))
              .accessibilityIdentifier("record-buffer.search")
          }
          .padding(.horizontal, 8).recordPanelSearchSurface().padding(.horizontal, 9)
          itemList
        }.frame(width: RecordPanelAppearance.sidebarWidth)
        Divider().opacity(0.45)
        editor.frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(RecordPanelAppearance.paper)
      }
      Divider().opacity(0.45)
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if let failure = model.failure {
        Button { showsFailure = true } label: {
          Label(failureText(failure), systemImage: RillSystemSymbol.exclamationmarkCircle.rawValue).lineLimit(1)
        }.buttonStyle(.plain).foregroundStyle(.red).help(failureText(failure))
      } else {
        Text(model.targetName.map { text("发送到 ", "Send to ") + $0 }
          ?? panelText(.sendWhenReady))
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      Button(panelText(.doneEditing), action: onFinishEditing)
        .buttonStyle(RecordPanelActionStyle(role: .quiet))
        .frame(width: 88)
        .disabled(model.session == nil || model.session?.hasMarkedText == true)
        .accessibilityIdentifier("record-buffer.finish-editing")
      Button(panelText(.copy)) { if let session = model.session { copyText(session.text) } }
        .buttonStyle(RecordPanelActionStyle())
        .frame(width: 60)
        .disabled(model.session?.text.isEmpty != false || model.isBusy || model.session?.hasMarkedText == true)
        .accessibilityIdentifier("record-buffer.copy")
      Button(panelText(.send), action: model.send)
        .buttonStyle(RecordPanelActionStyle(role: .primary))
        .frame(width: 84)
        .disabled(model.selectedID == nil || model.isBusy || model.session?.hasMarkedText == true)
        .help(text("编辑时按 ⌘Return 发送；Return 换行。", "⌘Return sends while editing; Return inserts a newline."))
        .accessibilityIdentifier("record-buffer.send")
    }
    .controlSize(.small).padding(.horizontal, 15).frame(height: 56)
    .accessibilityIdentifier("record-buffer.actions")
  }

  private var collectionControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 24) {
        Toggle(text("语音进入待发区", "Collect voice in Drafts"), isOn: Binding(
          get: { settings.builtinPushToTalkOutputMode == .saveToVoiceGroup },
          set: { setVoiceCollection($0) }))
          .disabled(!settings.canMutateScalarSettings(in: .input))
          .help(text("关闭后，Fn 听写直接输入当前应用；“录音新建”仍会收进待发区。",
                     "When off, Fn dictation types into the current app. Record new item still collects here."))
          .accessibilityIdentifier("record-buffer.collect-voice")
        Toggle(text("剪贴板进入待发区", "Collect clipboard in Drafts"), isOn: Binding(
          get: { settings.systemClipboardCaptureEnabled },
          set: { setClipboardCollection($0) }))
          .disabled(!settings.canMutateScalarSettings(in: .systemClipboard))
          .help(text("收集开启后的新复制内容，并遵守隐私排除设置。",
                     "Collects new copies after enabling, subject to your privacy exclusions."))
          .accessibilityIdentifier("record-buffer.collect-clipboard")
        Spacer(minLength: 0)
      }
      .toggleStyle(.checkbox)
      Text(text("开启后自动显示，重启后保持；新内容不会打断当前编辑。",
                "Opens automatically, including after restart. New items keep your editing selection."))
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14).padding(.bottom, 12)
  }

  private var itemList: some View {
    List(selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })) {
      ForEach(model.buffers) { summary in
        let entries = visibleItems.filter { $0.id.bufferID == summary.id }
        if !entries.isEmpty {
          ForEach(summary.buffer.policy == .stack ? entries.reversed() : entries) { item in
            VStack(alignment: .leading, spacing: 5) {
              Text(item.state == .preparing ? text("正在识别…", "Recognizing…") : preview(item))
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
              Text(bufferName(summary.buffer) + " · " +
                (item.suggestionCount > 0 ? text("有待应用结果", "Result to review")
                 : item.hasEdits ? text("已编辑", "Edited")
                 : item.state != .ready ? text("处理中", "In progress") : policyName(summary.buffer.policy))
                + (summary.buffer.isEnabled ? "" : text(" · 已停用", " · Disabled")))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
            .padding(.vertical, 5)
            .tag(item.id)
            .listRowSeparator(.hidden)
          }
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .onKeyPress(.return) { model.send(); return .handled }
    .disabled(model.isBusy || model.session?.hasMarkedText == true)
    .overlay {
      if visibleItems.isEmpty {
        Text(query.isEmpty
             ? text("新建草稿，或将语音结果\n先收进待发区。", "Create a draft or collect\nvoice results here first.")
             : panelText(.noMatchingDrafts))
          .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
      }
    }
  }

  private var visibleItems: [BufferItemSummary] {
    query.isEmpty ? model.items : model.items.filter { preview($0).localizedStandardContains(query) }
  }

  @ViewBuilder private var editor: some View {
    if let session = model.session {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(text("编辑内容", "Edit text")).font(.system(size: 17, weight: .medium)).lineLimit(1)
            Text(model.buffers.first(where: { $0.id == session.entryID.bufferID }).map {
              bufferName($0.buffer) + " · " + policyName($0.buffer.policy)
            } ?? panelText(.drafts))
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
          Button(action: model.dictateHere) {
            Label(text("在此听写", "Dictate here"), systemImage: RillSystemSymbol.micBadgePlus.rawValue)
              .font(.system(size: 11))
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 4)
          .disabled(model.isBusy || voice.isRunning || session.hasMarkedText)
        }.padding(.horizontal, 22).padding(.top, 18).frame(height: 72, alignment: .top)
        BufferDraftTextEditor(model: model, session: session,
                              accessibilityLabel: text("待发内容", "Pending text"))
          .id(session.id)
          .frame(minHeight: 48)
        HStack {
          saveState(session)
          Spacer(minLength: 8)
          Text(L10n.recordPanelCharacterCount(session.text.count, language: language))
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
          Button(session.saved.suggestions.isEmpty ? panelText(.reviewEdits) : panelText(.reviewResults)) {
            model.showsChanges = true
            showsDetails = true
          }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.horizontal, 22).frame(height: 36)
      }
    } else {
      ContentUnavailableView {
        Label(text("选择待发项", "Select an item"), systemImage: RillSystemSymbol.textCursor.rawValue)
      } description: {
        Text(text("文字可直接修改、选中和撤销。识别中的条目完成后即可编辑。", "Edit, select and undo text here. Pending recognition becomes editable when it finishes."))
      }
    }
  }

  private func saveState(_ session: BufferEditingSession) -> some View {
    HStack(spacing: 4) {
      if !model.isSaving && !session.hasUnsavedChanges {
        Image(systemName: RillSystemSymbol.checkmark.rawValue)
      }
      Text(model.isSaving ? text("保存中…", "Saving…")
        : session.hasUnsavedChanges ? text("尚未保存", "Unsaved") : text("已保存", "Saved"))
    }.font(.system(size: 11)).foregroundStyle(.secondary)
  }

  @ViewBuilder private func failureActions(_ failure: RecordBufferDraftModel.Failure) -> some View {
    if failure == .saving { Button(panelText(.retrySave), action: model.retrySaving) }
    if failure == .changed { Button(text("另存新草稿", "Save as new draft"), action: model.saveAsNewItem) }
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

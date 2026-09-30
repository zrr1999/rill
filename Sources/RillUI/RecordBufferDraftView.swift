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

  private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }
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
    .alert(text(.removeThisPendingItem), isPresented: $showsDiscard) {
      Button(text(.remove), role: .destructive) { model.discardSelected() }
      Button(text(.cancel), role: .cancel) {}
    } message: {
      Text(text(.draftEditsWillBeDiscarded))
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
      HStack(spacing: RecordPanelAppearance.paneInset) {
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
              Button(isRecording ? text(.finishRecording) : text(.recordNewItem),
                     action: model.dictateNewItem)
                .disabled(model.isBusy || model.session?.hasMarkedText == true || (voice.isRunning && !isRecording))
              Button(panelText(.configureDraftSources)) { showsCollectionControls = true }
              Divider()
              Button(text(.remove), role: .destructive) { showsDiscard = true }
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
          .recordPanelGlass(in: RecordPanelAppearance.paneShape)
        editor.frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(RecordPanelAppearance.paper)
          .clipShape(RecordPanelAppearance.paneShape)
      }
      .padding(RecordPanelAppearance.paneInset)
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
        Text(model.targetName.map { text(.sendTo) + $0 }
          ?? panelText(.sendWhenReady))
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      Button(panelText(.doneEditing), action: onFinishEditing)
        .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
        .frame(width: 88, height: 32)
        .disabled(model.session == nil || model.session?.hasMarkedText == true)
        .accessibilityIdentifier("record-buffer.finish-editing")
      Button(panelText(.copy)) { if let session = model.session { copyText(session.text) } }
        .buttonStyle(.glass).buttonBorderShape(.capsule).buttonSizing(.flexible)
        .frame(width: 60, height: 32)
        .disabled(model.session?.text.isEmpty != false || model.isBusy || model.session?.hasMarkedText == true)
        .accessibilityIdentifier("record-buffer.copy")
      Button(panelText(.send), action: model.send)
        .buttonStyle(.glassProminent).buttonBorderShape(.capsule).buttonSizing(.flexible)
        .tint(.accentColor).frame(width: 84, height: 32)
        .disabled(model.selectedID == nil || model.isBusy || model.session?.hasMarkedText == true)
        .help(text(.returnSendsWhileEditingReturn))
        .accessibilityIdentifier("record-buffer.send")
    }
    .font(.system(size: 12)).controlSize(.large)
    .padding(.horizontal, 15).frame(height: 56)
    .accessibilityIdentifier("record-buffer.actions")
  }

  private var collectionControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 24) {
        Toggle(text(.collectVoiceInDrafts), isOn: Binding(
          get: { settings.builtinPushToTalkOutputMode == .saveToVoiceGroup },
          set: { setVoiceCollection($0) }))
          .disabled(!settings.canMutateScalarSettings(in: .input))
          .help(text(.whenOffFnDictationTypes))
          .accessibilityIdentifier("record-buffer.collect-voice")
        Toggle(text(.collectClipboardInDrafts), isOn: Binding(
          get: { settings.systemClipboardCaptureEnabled },
          set: { setClipboardCollection($0) }))
          .disabled(!settings.canMutateScalarSettings(in: .systemClipboard))
          .help(text(.collectsNewCopiesAfterEnabling))
          .accessibilityIdentifier("record-buffer.collect-clipboard")
        Spacer(minLength: 0)
      }
      .toggleStyle(.checkbox)
      Text(text(.opensAutomaticallyIncludingAfterRestart))
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
              Text(item.state == .preparing ? text(.recognizing) : preview(item))
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
              Text(bufferName(summary.buffer) + " · " +
                (item.suggestionCount > 0 ? text(.resultToReview)
                 : item.hasEdits ? text(.edited)
                 : item.state != .ready ? text(.inProgress) : policyName(summary.buffer.policy))
                + (summary.buffer.isEnabled ? "" : text(.disabledSuffix)))
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
             ? text(.createADraftOrCollect)
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
            Text(text(.editText)).font(.system(size: 17, weight: .medium)).lineLimit(1)
            Text(model.buffers.first(where: { $0.id == session.entryID.bufferID }).map {
              bufferName($0.buffer) + " · " + policyName($0.buffer.policy)
            } ?? panelText(.drafts))
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
          Button(action: model.dictateHere) {
            Label(text(.dictateHere), systemImage: RillSystemSymbol.micBadgePlus.rawValue)
              .font(.system(size: 11))
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 4)
          .disabled(model.isBusy || voice.isRunning || session.hasMarkedText)
        }.padding(.horizontal, 22).padding(.top, 18).frame(height: 72, alignment: .top)
        BufferDraftTextEditor(model: model, session: session,
                              accessibilityLabel: text(.pendingText))
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
        Label(text(.selectAnItem), systemImage: RillSystemSymbol.textCursor.rawValue)
      } description: {
        Text(text(.editSelectAndUndoText))
      }
    }
  }

  private func saveState(_ session: BufferEditingSession) -> some View {
    HStack(spacing: 4) {
      if !model.isSaving && !session.hasUnsavedChanges {
        Image(systemName: RillSystemSymbol.checkmark.rawValue)
      }
      Text(model.isSaving ? text(.saving)
        : session.hasUnsavedChanges ? text(.unsaved) : text(.saved))
    }.font(.system(size: 11)).foregroundStyle(.secondary)
  }

  @ViewBuilder private func failureActions(_ failure: RecordBufferDraftModel.Failure) -> some View {
    if failure == .saving { Button(panelText(.retrySave), action: model.retrySaving) }
    if failure == .changed { Button(text(.saveAsNewDraft), action: model.saveAsNewItem) }
  }

  private func draftDetails(_ session: BufferEditingSession) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if !session.saved.suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(text(.speechResultsAreReadyTo))
            .font(.caption).foregroundStyle(.secondary)
          ForEach(session.saved.suggestions) { suggestion in
            Text(suggestion.text).textSelection(.enabled).lineLimit(4)
            HStack {
              Button(text(.insertAtSelection)) { model.resolveSuggestion(suggestion, insert: true) }
              Button(text(.dismiss)) { model.resolveSuggestion(suggestion, insert: false) }
            }.disabled(model.isBusy || session.hasMarkedText)
          }
        }.padding(12)
        Divider()
      }
      DisclosureGroup(text(.reviewChanges), isExpanded: $model.showsChanges) {
        if model.showsChanges {
          VStack(alignment: .leading, spacing: 8) {
            if session.saved.recognitionText != nil {
              Picker(text(.compareWith), selection: $comparesRecognition) {
                Text(text(.recognition)).tag(true)
                Text(text(.initialDraft)).tag(false)
              }.pickerStyle(.segmented)
            }
            let original = comparesRecognition ? session.saved.recognitionText ?? session.saved.originalText : session.saved.originalText
            ScrollView {
              diffText(original: original, edited: session.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100)
            Text(text(.deletionsAreStruckThroughAdditions))
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
    if buffer.id == RecordBuffer.speechID { return text(.speech) }
    if buffer.id == RecordBuffer.clipboardID { return text(.clipboard) }
    return buffer.name
  }
  private func preview(_ item: BufferItemSummary) -> String {
    let preview = model.session?.entryID == item.id
      ? RecordTextFormatting.previewText(model.session?.text ?? "", limit: 160) : item.preview
    return preview.isEmpty ? text(.emptyDraft) : preview
  }
  private func policyName(_ policy: RecordBuffer.Policy) -> String {
    switch policy {
    case .stack: text(.stack)
    case .queue: text(.queue)
    case .set: text(.reusable)
    }
  }
  private func failureText(_ failure: RecordBufferDraftModel.Failure) -> String {
    switch failure {
    case .capacity: text(.theDraftExceedsTheLocal)
    case .empty: text(.enterSomeTextBeforeSending)
    case .loading: text(.couldNotLoadItemsReopen)
    case .saving: text(.editsAreNotSavedRetry)
    case .changed: text(.theItemChangedYourEdits)
    case .recording: text(.couldNotStartRecordingCheck)
    }
  }
}

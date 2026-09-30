import RillCore
import SwiftUI

public struct RecordBufferDraftView: View {
  @Bindable private var model: RecordBufferDraftModel
  @Bindable private var voice: VoiceRunModel
  @Bindable private var settings: SettingsPersistenceModel
  private let setVoiceCollection: (Bool) -> Void
  private let setClipboardCollection: (Bool) -> Void
  private let embedded: Bool
  private var language: AppLanguage { settings.language }
  @State private var showsDiscard = false
  @State private var comparesRecognition = true

  public init(model: AppModel, embedded: Bool = false) {
    self.model = model.recordWorkspace.buffers.editor
    self.voice = model.voice
    self.settings = model.settings
    self.embedded = embedded
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

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        if !embedded {
          Text(text(.draftsArea)).font(.headline)
          Text("\(model.items.count)").monospacedDigit().foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.newItem()
        } label: {
          Label(text(.newItem), systemImage: RillSystemSymbol.squareAndPencil.rawValue)
        }
        .accessibilityIdentifier("record-buffer.new")
        .disabled(model.session?.hasMarkedText == true)
        Button(action: model.dictateNewItem) {
          Label(
            isRecording ? text(.finishRecording) : text(.recordNewItem),
            systemImage: isRecording ? "stop.circle" : "mic")
        }
        .disabled(voice.isRunning && !isRecording)
      }
      .disabled(model.isBusy)
      .padding(14)
      collectionControls
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
    .alert(text(.removeThisPendingItem), isPresented: $showsDiscard) {
      Button(text(.remove), role: .destructive) { model.discardSelected() }
      Button(text(.cancel), role: .cancel) {}
    } message: {
      Text(text(.draftEditsWillBeDiscarded))
    }
  }

  private var collectionControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 24) {
        Toggle(
          text(.collectVoiceInDrafts),
          isOn: Binding(
            get: { settings.builtinPushToTalkOutputMode == .saveToVoiceGroup },
            set: { setVoiceCollection($0) })
        )
        .disabled(!settings.canMutateScalarSettings(in: .input))
        .help(text(.whenOffFnDictationTypes))
        .accessibilityIdentifier("record-buffer.collect-voice")
        Toggle(
          text(.collectClipboardInDrafts),
          isOn: Binding(
            get: { settings.systemClipboardCaptureEnabled },
            set: { setClipboardCollection($0) })
        )
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
        Section {
          let entries = model.items.filter { $0.id.bufferID == summary.id }
          ForEach(summary.buffer.policy == .stack ? entries.reversed() : entries) { item in
            VStack(alignment: .leading, spacing: 5) {
              Text(
                item.state == .preparing
                  ? text(.recognizing)
                  : preview(item)
              )
              .lineLimit(3)
              if item.hasEdits || item.suggestionCount > 0 || item.state != .ready {
                Text(
                  item.suggestionCount > 0
                    ? text(.resultToReview)
                    : item.hasEdits ? text(.edited) : text(.inProgress)
                )
                .font(.caption).foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
            .tag(item.id)
          }
        } header: {
          Text(
            bufferName(summary.buffer) + " · " + policyName(summary.buffer.policy)
              + (summary.buffer.isEnabled ? "" : text(.disabledSuffix)))
        }
      }
    }
    .listStyle(.inset)
    .onKeyPress(.return) {
      model.send()
      return .handled
    }
    .disabled(model.isBusy || model.session?.hasMarkedText == true)
    .overlay {
      if model.items.isEmpty {
        Text(text(.createADraftOrCollect))
          .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
      }
    }
  }

  @ViewBuilder private var editor: some View {
    if let session = model.session {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(text(.editText)).font(.subheadline.weight(.medium))
          Spacer()
          Text(
            model.isSaving
              ? text(.saving)
              : session.hasUnsavedChanges ? text(.unsaved) : text(.saved)
          )
          .font(.caption).foregroundStyle(.secondary)
          Button(action: model.dictateHere) {
            Label(text(.dictateHere), systemImage: RillSystemSymbol.micBadgePlus.rawValue)
          }
          .disabled(model.isBusy || voice.isRunning || session.hasMarkedText)
        }.padding(12).fixedSize(horizontal: false, vertical: true)
        BufferDraftTextEditor(
          model: model, session: session,
          accessibilityLabel: text(.pendingText)
        )
        .id(session.id)
        .frame(minHeight: 140)
        Divider()
        ScrollView {
          draftDetails(session)
        }
        .frame(
          minHeight: 44, idealHeight: model.showsChanges || !session.saved.suggestions.isEmpty ? 200 : 44,
          maxHeight: model.showsChanges || !session.saved.suggestions.isEmpty ? 240 : 44)
      }
    } else {
      ContentUnavailableView {
        Label(text(.selectAnItem), systemImage: RillSystemSymbol.textCursor.rawValue)
      } description: {
        Text(text(.editSelectAndUndoText))
      }
    }
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

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let failure = model.failure {
        HStack {
          Text(failureText(failure)).font(.caption).foregroundStyle(.red)
          if failure == .saving { Button(text(.retrySave), action: model.retrySaving) }
          if failure == .changed { Button(text(.saveAsNewDraft), action: model.saveAsNewItem) }
        }
      }
      HStack {
        Text(
          model.targetName.map { text(.sendTo) + $0 }
            ?? text(.focusTheTargetAndUse)
        )
        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        Button(role: .destructive) {
          showsDiscard = true
        } label: {
          Label(text(.remove), systemImage: RillSystemSymbol.trash.rawValue)
        }.disabled(model.selectedID == nil || model.isBusy || model.session?.hasMarkedText == true)
        Button(text(.hide), action: model.closeAction)
        Button(text(.sendSelected), action: model.send)
          .buttonStyle(.borderedProminent)
          .disabled(model.selectedID == nil || model.isBusy || model.session?.hasMarkedText == true)
          .help(text(.returnSendsWhileEditingReturn))
          .accessibilityIdentifier("record-buffer.send")
      }
    }
  }

  private func diffText(original: String, edited: String) -> Text {
    BufferTextDiff(original: original, edited: edited).segments.reduce(Text("")) { result, segment in
      let part = Text(segment.text)
      let styled =
        segment.kind == .removed
        ? part.strikethrough().foregroundColor(.red)
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
    let preview =
      model.session?.entryID == item.id
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

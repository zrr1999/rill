import Foundation
import Observation
import RillCore
import RillRecords

@MainActor @Observable
public final class BufferEditingSession: Identifiable {
  public let id: UUID
  public let entryID: BufferEntryID
  public fileprivate(set) var saved: BufferTextDraft
  public fileprivate(set) var text: String
  public var selection = BufferTextRange(location: 0)
  public var hasMarkedText = false
  public var isFocused = false

  init(id: UUID, entryID: BufferEntryID, draft: BufferTextDraft) {
    self.id = id
    self.entryID = entryID
    saved = draft
    text = draft.text
  }

  public var hasUnsavedChanges: Bool { text != saved.text }
}

/// Owns one editor and drains accepted writes independently of panel visibility.
@MainActor @Observable
public final class RecordBufferDraftModel {
  public enum Failure: Equatable { case loading, saving, changed, empty, recording, capacity }

  public private(set) var items: [BufferItemSummary] = []
  public private(set) var buffers: [RecordBufferSummary] = []
  public private(set) var session: BufferEditingSession?
  public private(set) var selectedID: BufferEntryID?
  public private(set) var failure: Failure?
  public private(set) var isBusy = false
  public private(set) var isSaving = false
  public private(set) var isVisible = false
  public var showsChanges = false
  public var targetName: String?
  public var sendAction: (BufferEntryID) -> Void = { _ in }
  public var dictationAction: (BufferSpeechInput) -> Void = { _ in }
  public var closeAction: () -> Void = {}

  private let store: RecordStore
  private var observation: Task<Void, Never>?
  private var observationDrain: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var closeTask: Task<Void, Never>?
  private var commandTask: Task<Void, Never>?
  private var isClosed = false
  private var listingRevision: UInt64?

  public init(store: RecordStore) { self.store = store }
  isolated deinit { observation?.cancel() }

  public func open() {
    guard !isClosed else { return }
    isVisible = true
    if observation == nil {
      observation = Task { [weak self, store] in
        do {
          for await snapshot in try await store.bufferStream() {
            guard !Task.isCancelled, let self else { break }
            self.buffers = snapshot.buffers
            let reloadItems = self.listingRevision != snapshot.listingRevision
            self.listingRevision = snapshot.listingRevision
            await self.refresh(reloadItems: reloadItems)
          }
        } catch { self?.failure = .loading }
      }
    }
    if let session {
      perform {
        _ = try await self.store.openBufferDraft(session.entryID, editingSessionID: session.id)
      }
    }
  }

  public func close() {
    isVisible = false
    listingRevision = nil
    let retired = observation
    retired?.cancel()
    observation = nil
    let previousObservation = observationDrain
    observationDrain = Task { await previousObservation?.value; await retired?.value }
    if let session { startSaving(session) }
    let previous = closeTask
    let pendingCommand = commandTask
    closeTask = Task {
      await previous?.value
      await pendingCommand?.value
      guard !isVisible, let session else { return }
      await store.closeBufferEditingSession(session.id)
    }
  }

  public func select(_ id: BufferEntryID) {
    guard (selectedID != id || session == nil), session?.hasMarkedText != true else { return }
    perform {
      try await self.flush()
      if let old = self.session { await self.store.closeBufferEditingSession(old.id) }
      self.selectedID = id
      self.session = nil
      guard self.items.first(where: { $0.id == id })?.state == .ready else { return }
      guard self.items.first(where: { $0.id == id })?.kind == .text else { return }
      let sessionID = UUID()
      let draft = try await self.store.openBufferDraft(id, editingSessionID: sessionID)
      self.session = BufferEditingSession(id: sessionID, entryID: id, draft: draft)
    }
  }

  public func newItem(in bufferID: RecordBufferID = RecordBuffer.speechID) {
    guard session?.hasMarkedText != true else { return }
    perform {
      try await self.flush()
      if let old = self.session { await self.store.closeBufferEditingSession(old.id) }
      let id = try await self.store.createBufferDraft(in: bufferID)
      let sessionID = UUID()
      let draft = try await self.store.openBufferDraft(id, editingSessionID: sessionID)
      self.selectedID = id
      self.session = BufferEditingSession(id: sessionID, entryID: id, draft: draft)
      await self.refresh()
    }
  }

  public func edit(_ text: String, sessionID: UUID) {
    guard !isBusy, !isClosed, let session, session.id == sessionID else { return }
    session.text = text
    if !session.hasMarkedText { startSaving(session) }
  }

  public func saveAsNewItem() {
    guard let session, !session.hasMarkedText else { return }
    let text = session.text
    perform {
      await self.saveTask?.value
      let id = try await self.store.createBufferDraft(text: text)
      let sessionID = UUID()
      let draft = try await self.store.openBufferDraft(id, editingSessionID: sessionID)
      self.session = BufferEditingSession(id: sessionID, entryID: id, draft: draft)
      self.selectedID = id
    }
  }

  public func retrySaving() {
    guard let session else { return }
    failure = nil
    startSaving(session)
  }

  public func send() {
    guard let id = selectedID, session?.hasMarkedText != true else { return }
    perform {
      try await self.flush()
      if let session = self.session {
        try await self.store.commitBufferDraft(id, draftID: session.saved.id,
                                               expectedRevision: session.saved.revision)
        await self.store.closeBufferEditingSession(session.id)
        if let draft = try await self.store.bufferDraft(for: id) { session.saved = draft }
      }
      self.sendAction(id)
    }
  }

  public func dictateHere() {
    guard let session, !session.hasMarkedText else { return }
    let selection = session.selection
    perform {
      try await self.flush()
      self.dictationAction(.draft(.init(entryID: session.entryID, draftID: session.saved.id,
        revision: session.saved.revision, selection: selection, editingSessionID: session.id)))
    }
  }

  public func dictateNewItem() { dictationAction(.newItem) }

  public func reportRecordingFailure() { failure = .recording }

  public func resolveSuggestion(_ suggestion: BufferDraftSuggestion, insert: Bool) {
    guard let session, !session.hasMarkedText else { return }
    let range = insert ? session.selection : nil
    perform {
      try await self.flush()
      let draft = try await self.store.resolveBufferSuggestion(suggestion.id, in: session.entryID,
        draftID: session.saved.id, expectedRevision: session.saved.revision, insertingAt: range)
      self.adopt(draft, in: session, selection: range.map {
        .init(location: $0.location + suggestion.text.utf16.count)
      })
    }
  }

  public func discardSelected() {
    guard let id = selectedID, session?.hasMarkedText != true else { return }
    perform {
      try await self.flush()
      try await self.store.discardBufferEntry(id)
      self.session = nil
      self.selectedID = nil
      await self.refresh()
    }
  }

  public func waitForPendingWrites() async {
    while commandTask != nil || saveTask != nil {
      await commandTask?.value
      await saveTask?.value
    }
    await closeTask?.value
  }

  public func shutdown() async {
    isClosed = true
    close()
    observation?.cancel()
    await commandTask?.value
    await saveTask?.value
    await observation?.value
    await closeTask?.value
    await observationDrain?.value
  }

  private func startSaving(_ session: BufferEditingSession) {
    guard saveTask == nil, session.hasUnsavedChanges, !session.hasMarkedText else { return }
    isSaving = true
    saveTask = Task {
      while session.hasUnsavedChanges, !session.hasMarkedText {
        let text = session.text
        do {
          session.saved = try await store.saveBufferDraft(session.entryID,
            draftID: session.saved.id, expectedRevision: session.saved.revision, text: text)
          failure = nil
        } catch {
          if let storageError = error as? RecordStoreError, storageError == .payloadLimitReached || storageError == .totalPayloadLimitReached {
            failure = .capacity
          } else { failure = error is BufferDraftError ? .changed : .saving }
          isSaving = false
          saveTask = nil
          return
        }
      }
      isSaving = false
      saveTask = nil
      await refresh(reloadItems: false)
    }
  }

  private func flush() async throws {
    guard let session else { return }
    startSaving(session)
    await saveTask?.value
    guard !session.hasUnsavedChanges, !session.hasMarkedText else { throw BufferDraftError.changed }
  }

  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isBusy, !isClosed else { return }
    isBusy = true
    let precedingClose = closeTask
    commandTask = Task {
      await precedingClose?.value
      do { try await operation(); failure = nil }
      catch BufferDraftError.empty { failure = .empty }
      catch BufferDraftError.changed { if failure == nil { failure = .changed } }
      catch { if failure == nil { failure = .saving } }
      isBusy = false
      commandTask = nil
      await refresh()
    }
  }

  public func refresh(reloadItems: Bool = true) async {
    guard !isClosed, isVisible else { return }
    do {
      if reloadItems {
        let items = try await store.bufferItems()
        guard !isClosed, isVisible else { return }
        self.items = items
      }
      guard let session else {
        if let selectedID, !isBusy, items.contains(where: { $0.id == selectedID && $0.state == .ready && $0.kind == .text }) {
          select(selectedID)
        }
        return
      }
      guard items.contains(where: { $0.id == session.entryID }) else {
        if !session.hasUnsavedChanges { self.session = nil; selectedID = nil }
        else { failure = .changed }
        return
      }
      guard !isBusy, saveTask == nil, !session.hasUnsavedChanges, !session.hasMarkedText,
        let draft = try await store.bufferDraft(for: session.entryID),
        self.session === session, !isBusy, saveTask == nil,
        !session.hasUnsavedChanges, !session.hasMarkedText
      else { return }
      adopt(draft, in: session)
      guard isVisible, session.isFocused, let suggestion = draft.suggestions.first,
        let intent = suggestion.intent, intent.editingSessionID == session.id,
        intent.draftID == draft.id, intent.revision == draft.revision
      else { return }
      // Lock the editor before crossing the store actor. Uncommitted IME text
      // and local keystrokes can therefore never race automatic insertion.
      perform {
        let updated = try await self.store.resolveBufferSuggestion(suggestion.id,
          in: session.entryID, draftID: draft.id, expectedRevision: draft.revision,
          insertingAt: intent.selection)
        self.adopt(updated, in: session,
          selection: .init(location: intent.selection.location + suggestion.text.utf16.count))
      }
    } catch { failure = .loading }
  }

  private func adopt(_ draft: BufferTextDraft, in session: BufferEditingSession,
                     selection: BufferTextRange? = nil) {
    session.saved = draft
    session.text = draft.text
    if let selection { session.selection = selection }
  }
}

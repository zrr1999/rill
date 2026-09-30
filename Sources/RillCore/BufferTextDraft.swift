import Foundation

/// Editable output belongs to one buffer position, never to the immutable Record.
public struct BufferTextDraft: Codable, Sendable, Equatable, Identifiable {
  /// Leaves room for the catalog's other encrypted metadata and JSON escaping.
  public static let maximumTotalTextByteCount = 16 * 1_024 * 1_024

  public let id: UUID
  public let originalText: String
  public let recognitionText: String?
  public var text: String
  public var revision: UInt64
  public var committedRevision: UInt64?
  public var suggestions: [BufferDraftSuggestion]
  public var receivedInputIDs: [UUID]

  public init(text: String, recognitionText: String? = nil, isCommitted: Bool = true) {
    id = UUID()
    originalText = text
    self.recognitionText = recognitionText
    self.text = text
    revision = 0
    committedRevision = isCommitted ? 0 : nil
    suggestions = []
    receivedInputIDs = []
  }

  public var needsCommit: Bool { revision != committedRevision }

  public var byteCount: Int {
    originalText.utf8.count + text.utf8.count + (recognitionText?.utf8.count ?? 0)
      + suggestions.reduce(0) { $0 + $1.text.utf8.count + $1.recognitionText.utf8.count }
  }
}

/// UTF-16 coordinates match NSTextView, including selection replacement and IME input.
public struct BufferTextRange: Codable, Sendable, Equatable {
  public var location: Int
  public var length: Int

  public init(location: Int, length: Int = 0) {
    self.location = location
    self.length = length
  }

  public func replacing(in text: String, with replacement: String) -> String? {
    guard location >= 0, length >= 0, location <= text.utf16.count,
      length <= text.utf16.count - location
    else { return nil }
    let start = text.utf16.index(text.utf16.startIndex, offsetBy: location)
    let end = text.utf16.index(start, offsetBy: length)
    guard let lower = String.Index(start, within: text), let upper = String.Index(end, within: text)
    else { return nil }
    return text.replacingCharacters(in: lower..<upper, with: replacement)
  }
}

/// Frozen before recording starts. It contains coordinates, not a live editor reference.
public struct BufferDraftInputIntent: Codable, Sendable, Equatable {
  public let entryID: BufferEntryID
  public let draftID: UUID
  public let revision: UInt64
  public let selection: BufferTextRange
  public let editingSessionID: UUID

  public init(
    entryID: BufferEntryID, draftID: UUID, revision: UInt64,
    selection: BufferTextRange, editingSessionID: UUID
  ) {
    self.entryID = entryID
    self.draftID = draftID
    self.revision = revision
    self.selection = selection
    self.editingSessionID = editingSessionID
  }
}

public enum BufferSpeechInput: Sendable, Equatable {
  case newItem
  case draft(BufferDraftInputIntent)

  public var draftIntent: BufferDraftInputIntent? {
    if case .draft(let intent) = self { return intent }
    return nil
  }
}

public struct BufferDraftSuggestion: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let text: String
  public let recognitionText: String
  public var intent: BufferDraftInputIntent?

  public init(id: UUID, text: String, recognitionText: String, intent: BufferDraftInputIntent? = nil) {
    self.id = id
    self.text = text
    self.recognitionText = recognitionText
    self.intent = intent
  }
}

public enum BufferDraftError: Error, Sendable, Equatable {
  case changed, notText, empty, suggestionLimit
}

public struct BufferItemSummary: Sendable, Equatable, Identifiable {
  public let id: BufferEntryID
  public let state: BufferEntry.State
  public let kind: RecordPayloadKind
  public let preview: String
  public let hasEdits: Bool
  public let suggestionCount: Int

  public init(entry: BufferEntry, header: RecordHeader?) {
    id = entry.id
    state = entry.state
    kind = header?.kind ?? .text
    preview =
      entry.draft.map { RecordTextFormatting.previewText($0.text, limit: 160) }
      ?? header?.preview ?? ""
    hasEdits = entry.draft?.needsCommit ?? false
    suggestionCount = entry.draft?.suggestions.count ?? 0
  }
}

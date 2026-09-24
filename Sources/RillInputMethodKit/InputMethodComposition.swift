import Foundation

/// Tracks the marked range owned by this input session, never the client's unrelated selection.
@MainActor
struct InputMethodComposition {
  private(set) var hasMarkedText = false

  mutating func update(
    commit: String?, preedit: String, caret: Int,
    insert: (String) -> Void,
    mark: (String, NSRange) -> Void
  ) {
    if let commit, !commit.isEmpty {
      insert(commit)
      hasMarkedText = false
    }
    if !preedit.isEmpty || hasMarkedText {
      mark(preedit, NSRange(location: min(max(0, caret), preedit.utf16.count), length: 0))
    }
    hasMarkedText = !preedit.isEmpty
  }
}

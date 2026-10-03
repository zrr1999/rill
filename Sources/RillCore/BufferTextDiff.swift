import Foundation

/// Exact text differences, without interpreting a rewrite as a recognition error.
public struct BufferTextDiff: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case unchanged, removed, inserted }
  public struct Segment: Sendable, Equatable {
    public let kind: Kind
    public var text: String
  }
  public let segments: [Segment]
  public let isCoarse: Bool

  public init(original: String, edited: String) {
    let before = Array(original), after = Array(edited)
    var start = 0
    while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
    var end = 0
    while end < min(before.count, after.count) - start,
      before[before.count - end - 1] == after[after.count - end - 1]
    { end += 1 }
    let left = Array(before[start..<(before.count - end)])
    let right = Array(after[start..<(after.count - end)])
    var result: [Segment] = []
    func append(_ kind: Kind, _ text: String) {
      guard !text.isEmpty else { return }
      if result.last?.kind == kind { result[result.count - 1].text += text } else { result.append(.init(kind: kind, text: text)) }
    }
    append(.unchanged, String(before.prefix(start)))
    isCoarse = left.count > 4096 || right.count > 4096 || left.count * right.count > 1_000_000
    if isCoarse {
      append(.removed, String(left))
      append(.inserted, String(right))
    } else {
      var removed = Set<Int>(), inserted = Set<Int>()
      for change in right.difference(from: left) {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
      }
      var i = 0, j = 0
      while i < left.count || j < right.count {
        if removed.contains(i), i < left.count {
          append(.removed, String(left[i]))
          i += 1
        } else if inserted.contains(j), j < right.count {
          append(.inserted, String(right[j]))
          j += 1
        } else if i < left.count, j < right.count {
          append(.unchanged, String(left[i]))
          i += 1
          j += 1
        }
      }
    }
    append(.unchanged, String(before.suffix(end)))
    segments = result
  }
}

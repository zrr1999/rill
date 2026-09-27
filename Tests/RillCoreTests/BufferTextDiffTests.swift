import RillCore
import Testing

struct BufferTextDiffTests {
  @Test(arguments: [
    ("去背景开会", "去北京开会"), ("", "新建\n内容"), ("删除", ""),
    ("👨‍👩‍👧‍👦 café", "家人 café"), ("unchanged", "unchanged"),
    ("abc", "xyz"),
  ])
  func changesReconstructBothInputs(_ input: (String, String)) {
    let diff = BufferTextDiff(original: input.0, edited: input.1)
    #expect(diff.segments.filter { $0.kind != .inserted }.map(\.text).joined() == input.0)
    #expect(diff.segments.filter { $0.kind != .removed }.map(\.text).joined() == input.1)
  }

  @Test func longChangesUseExactCoarseSegments() {
    let original = String(repeating: "a", count: 5000)
    let edited = String(repeating: "b", count: 5000)
    let diff = BufferTextDiff(original: original, edited: edited)
    #expect(diff.isCoarse)
    #expect(diff.segments.filter { $0.kind != .inserted }.map(\.text).joined() == original)
    #expect(diff.segments.filter { $0.kind != .removed }.map(\.text).joined() == edited)
  }

  @Test func selectionDoesNotSplitEmojiAndUsesUTF16() {
    #expect(BufferTextRange(location: 1, length: 2).replacing(in: "a😀b", with: "中") == "a中b")
    #expect(BufferTextRange(location: 2, length: 1).replacing(in: "a😀b", with: "中") == nil)
    #expect(BufferTextRange(location: Int.max, length: 1).replacing(in: "a", with: "中") == nil)
  }
}

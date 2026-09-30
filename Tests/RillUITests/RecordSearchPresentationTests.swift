import Foundation
import RillCore
import RillRecords
import Testing

@testable import RillUI

@MainActor
struct RecordSearchPresentationTests {
  @Test func quickPanelKeepsLiteralPrecedenceAndApproximatePagination() async throws {
    let store = RecordStore()
    func draft(_ text: String) -> RecordDraft {
      .init(payload: .text(text), provenance: .init(source: .init(kind: .systemClipboard)))
    }
    let exact = try await store.ingest(draft("jtb exact"), into: [])
    for index in 0..<125 {
      _ = try await store.ingest(draft("剪贴板 worktree \(index)"), into: [])
    }
    let workspace = RecordWorkspaceModel(store: store)
    let panel = workspace.makeQuickPanelModel()
    await workspace.refresh()
    panel.setSearchText("jtb")
    await panel.waitForSearch()
    #expect(panel.results.map(\.id) == [exact.id])

    panel.setSearchText("jtb worktere")
    await panel.waitForSearch()
    while panel.nextOffset != nil {
      panel.loadMore()
      await panel.waitForSearch()
    }
    #expect(panel.results.count == 125)
    await workspace.shutdown()
    await panel.shutdown()
  }
}

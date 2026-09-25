import Foundation
import Testing
import RillCore
@testable import RillUI

struct LiveSubtitleLayoutStateTests {
  @Test func textDisappearanceCannotCollapseSameRecording() {
    var layout = LiveSubtitleLayoutState()
    let id = UUID()
    layout.update(.init(runID: id, phase: .recording))
    #expect(!layout.isExpanded)
    layout.update(.init(runID: id, phase: .recording, hypothesisText: "Rill"))
    #expect(layout.isExpanded)
    layout.update(.init(runID: id, phase: .recording))
    #expect(layout.isExpanded)
    layout.update(.init(runID: id, phase: .finalizing))
    #expect(layout.isExpanded)
    layout.update(.init(runID: UUID(), phase: .recording))
    #expect(!layout.isExpanded)
    layout.update(nil)
    #expect(!layout.isExpanded)
  }
}

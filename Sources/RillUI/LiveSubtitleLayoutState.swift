import Foundation
import RillCore

/// Owns layout for one visible recording, independently of transient decoder text.
public struct LiveSubtitleLayoutState {
  public private(set) var isExpanded = false
  private var runID: UUID?

  public init() {}

  public mutating func update(_ snapshot: LiveSubtitleSnapshot?) {
    guard let snapshot, snapshot.isVisible else {
      runID = nil
      isExpanded = false
      return
    }
    if runID != snapshot.runID {
      runID = snapshot.runID
      isExpanded = false
    }
    isExpanded = isExpanded || LiveSubtitlePresentationPolicy.usesExpandedLayout(snapshot)
  }
}

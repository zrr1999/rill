import Foundation
import Observation

@MainActor @Observable
public final class RecordPanelPresentation {
  public enum Mode: String, CaseIterable { case drafts, collections }
  public var mode: Mode = .drafts
  public var isCollapsed = false
  public var isPinned = false

  public init() {}
}

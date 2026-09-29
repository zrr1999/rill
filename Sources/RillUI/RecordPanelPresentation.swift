import Foundation
import Observation

@MainActor @Observable
public final class RecordPanelPresentation {
  public enum Mode: String, CaseIterable { case collections, drafts }
  public var mode: Mode = .collections
  public var isCollapsed = false
  public var isPinned = false
  public var expandedWidth: CGFloat = 820
  public var expandedHeight: CGFloat = 600

  public init() {}
}

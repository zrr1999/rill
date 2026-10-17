import Foundation
import Observation

@MainActor @Observable
public final class RecordPanelPresentation {
  public enum Mode: String, CaseIterable { case drafts, collections }
  public var mode: Mode = .collections

  public init() {}
}

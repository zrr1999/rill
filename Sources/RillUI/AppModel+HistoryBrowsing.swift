import Foundation
import RillCore

extension AppModel {
  public func retryRunHistoryInitialLoad() {
    if history.usesPagedRunHistory { history.retryRunHistoryInitialLoad() } else { retryHistoryLoad() }
  }
  public func refreshNewestRunHistoryPage() {
    if history.usesPagedRunHistory { history.refreshNewestRunHistoryPage() } else { retryHistoryLoad() }
  }
}

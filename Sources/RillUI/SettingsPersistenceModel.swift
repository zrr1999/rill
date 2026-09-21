import Foundation
import Observation
import RillCore
import RillRuntime

@MainActor @Observable
public final class SettingsPersistenceModel {
  public internal(set) var isLoading = true
  public private(set) var saveState: SettingsSaveState = .saved
  let writes = PersistenceWriteCoordinator()
  private let store: (any SettingsStore)?
  private var failed: [AppSettingKey: RetryableSettingsStoreWrite] = [:]
  private var retrying: Set<AppSettingKey> = []
  var hasUnsavedWrites: Bool { !failed.isEmpty }

  init(store: (any SettingsStore)?) { self.store = store }

  func submit(
    key: AppSettingKey, category: SettingsSaveCategory, debounce: Duration,
    operation: @escaping SettingsStoreWriteOperation, onFailure: @escaping @MainActor () -> Void
  ) {
    schedule(
      .init(category: category, operation: operation), key: key, debounce: debounce,
      onFailure: onFailure)
  }

  func retry(onFailure: @escaping @MainActor () -> Void) {
    guard !failed.isEmpty else { return }
    for (key, write) in failed.sorted(by: { $0.key.rawValue < $1.key.rawValue })
    where !retrying.contains(key) {
      schedule(write, key: key, debounce: .zero, onFailure: onFailure)
    }
  }

  private func schedule(
    _ write: RetryableSettingsStoreWrite, key: AppSettingKey, debounce: Duration,
    onFailure: @escaping @MainActor () -> Void
  ) {
    guard let store else {
      failed[key] = write
      refreshState()
      onFailure()
      return
    }
    if failed[key] != nil {
      failed[key] = write
      retrying.insert(key)
      refreshState()
    }
    writes.replace(for: key, debounce: debounce) {
      try await write.operation(store)
    } completion: { [weak self] result in
      guard let self else { return }
      retrying.remove(key)
      switch result {
      case .success: failed.removeValue(forKey: key)
      case .failure(is CancellationError): break
      case .failure:
        failed[key] = write
        onFailure()
      }
      refreshState()
    }
  }

  private func refreshState() {
    guard !failed.isEmpty else {
      retrying.removeAll()
      saveState = .saved
      return
    }
    let summary = UnsavedSettingsSummary(
      affectedChangeCount: failed.count,
      categories: Set(failed.values.map(\.category)).sorted { $0.rawValue < $1.rawValue })
    saveState = retrying.isEmpty ? .unsaved(summary) : .retrying(summary)
  }
}

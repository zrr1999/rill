import Foundation
import RillInputMethodContracts
import RillInputMethodIPC

@MainActor
final class InputMethodAppearanceObserver: NSObject {
  static let shared = InputMethodAppearanceObserver()
  private(set) var appearance = InputMethodAppearance.defaults
  private let store = InputMethodAppearanceStore()

  private override init() {
    super.init()
    reload()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(appearanceChanged(_:)), name: InputMethodAppearanceStore.didChange,
      object: nil, suspensionBehavior: .deliverImmediately)
  }

  func reload() {
    if let current = try? store.load() { appearance = current }
  }

  @objc private func appearanceChanged(_ notification: Notification) { reload() }
}

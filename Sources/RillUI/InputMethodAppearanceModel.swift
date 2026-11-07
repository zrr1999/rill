import Foundation
import Observation
import RillInputMethodContracts
import RillInputMethodIPC

@MainActor
@Observable
final class InputMethodAppearanceModel {
  enum StorageError { case load, save }

  var draft = InputMethodAppearance.defaults
  private(set) var saved = InputMethodAppearance.defaults
  private(set) var storageError: StorageError?
  private var hasLoaded = false
  private let store: InputMethodAppearanceStore

  init(store: InputMethodAppearanceStore = InputMethodAppearanceStore()) {
    self.store = store
  }

  var validationError: InputMethodAppearance.ValidationError? {
    do {
      _ = try draft.validated()
      return nil
    } catch { return error as? InputMethodAppearance.ValidationError }
  }

  var canApply: Bool {
    validationError == nil && (draft != saved || storageError != nil)
  }

  func loadIfNeeded() {
    guard !hasLoaded else { return }
    hasLoaded = true
    do {
      saved = try store.load()
      draft = saved
      storageError = nil
    } catch { storageError = .load }
  }

  func apply() {
    guard validationError == nil else { return }
    do {
      try store.save(draft)
      saved = draft
      storageError = nil
    } catch { storageError = .save }
  }

  func reset() {
    draft = .defaults
    apply()
  }
}

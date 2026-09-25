import Foundation
import RillCore

public enum ComponentRegistrationError: Error, LocalizedError, Sendable, Equatable {
  case duplicateRecognizer(String)
  case duplicateTransformer(String)
  case duplicateTransformerKind(PostProcessStepKind)
  case duplicateOutput(String)

  public var errorDescription: String? {
    switch self {
    case .duplicateRecognizer(let id): "Duplicate speech recognizer: \(id)."
    case .duplicateTransformer(let id): "Duplicate text transformer: \(id)."
    case .duplicateTransformerKind(let kind): "Multiple transformers handle \(kind.rawValue)."
    case .duplicateOutput(let id): "Duplicate output action: \(id)."
    }
  }
}

/// A malformed registration stays unavailable until validation reports its
/// precise error. Never trap on duplicate keys or silently select one provider.
private struct ComponentIndex<Key: Hashable & Sendable, Value: Sendable>: Sendable {
  let result: Result<[Key: Value], ComponentRegistrationError>

  init(entries: [(Key, Value)], duplicate: (Key) -> ComponentRegistrationError) {
    var values: [Key: Value] = [:]
    for (key, value) in entries {
      guard values.updateValue(value, forKey: key) == nil else {
        result = .failure(duplicate(key))
        return
      }
    }
    result = .success(values)
  }

  subscript(key: Key) -> Value? { try? result.get()[key] }
  func validate() throws { _ = try result.get() }
}

public struct SpeechRecognizerRegistry: Sendable {
  private let index: ComponentIndex<String, any SpeechRecognizer>
  public init(recognizers: [any SpeechRecognizer]) {
    index = .init(entries: recognizers.map { ($0.id, $0) }, duplicate: ComponentRegistrationError.duplicateRecognizer)
  }
  public func validate() throws { try index.validate() }
  public func recognizer(for id: String) -> (any SpeechRecognizer)? { index[id] }
}

public struct TextTransformerRegistry: Sendable {
  private let identities: ComponentIndex<String, any TextTransformer>
  private let kinds: ComponentIndex<PostProcessStepKind, any TextTransformer>
  public init(transformers: [any TextTransformer]) {
    identities = .init(entries: transformers.map { ($0.id, $0) }, duplicate: ComponentRegistrationError.duplicateTransformer)
    kinds = .init(entries: transformers.flatMap { transformer in
      transformer.supportedKinds.map { ($0, transformer) }
    }, duplicate: ComponentRegistrationError.duplicateTransformerKind)
  }
  public func validate() throws {
    try identities.validate()
    try kinds.validate()
  }
  public func transformer(for kind: PostProcessStepKind) -> (any TextTransformer)? {
    guard (try? validate()) != nil else { return nil }
    return kinds[kind]
  }
}

public struct OutputActionRegistry: Sendable {
  private let index: ComponentIndex<String, any OutputAction>
  public init(actions: [any OutputAction]) {
    index = .init(entries: actions.map { ($0.id, $0) }, duplicate: ComponentRegistrationError.duplicateOutput)
  }
  public func validate() throws { try index.validate() }
  public func action(for id: String) -> (any OutputAction)? { index[id] }
}

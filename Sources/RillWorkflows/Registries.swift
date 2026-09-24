import RillCore

public struct SpeechRecognizerRegistry: Sendable {
    private let storage: [String: any SpeechRecognizer]

    public init(recognizers: [any SpeechRecognizer]) {
        self.storage = Dictionary(uniqueKeysWithValues: recognizers.map { ($0.id, $0) })
    }

    public func recognizer(for id: String) -> (any SpeechRecognizer)? {
        storage[id]
    }
}

public struct TextTransformerRegistry: Sendable {
    private let storage: [PostProcessStepKind: any TextTransformer]

    public init(transformers: [any TextTransformer]) {
        var mapped: [PostProcessStepKind: any TextTransformer] = [:]
        for transformer in transformers {
            for kind in transformer.supportedKinds {
                mapped[kind] = transformer
            }
        }
        self.storage = mapped
    }

    public func transformer(for kind: PostProcessStepKind) -> (any TextTransformer)? {
        storage[kind]
    }
}

public struct OutputActionRegistry: Sendable {
    private let storage: [String: any OutputAction]

    public init(actions: [any OutputAction]) {
        self.storage = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    }

    public func action(for id: String) -> (any OutputAction)? {
        storage[id]
    }
}

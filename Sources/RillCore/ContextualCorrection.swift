import Foundation

public extension WorkflowDefinition {
    var supportsVocabularyCorrection: Bool {
        id.uuidString == "D3E19A88-F9FB-4AB3-8444-CDBF7E215A88"
            && metadata[WorkflowMetadataKey.catalog] == BuiltinWorkflowRoutingValue.catalog
            && metadata[WorkflowMetadataKey.builtinKind] == "push-to-talk.polish"
            && supportsContextualCorrection
            && plan.process.allSteps.first { $0.kind == .llmRewrite }?.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines) == LLMTextProcessing.cleanupPrompt
    }

    var supportsContextualCorrection: Bool {
        speechMode != .voiceAssistant
            && !plan.process.allSteps.contains { $0.kind == .snippetReplacement }
            && plan.process.allSteps.filter { $0.kind == .llmRewrite || $0.kind == .llmAnswer }.map(\.kind) == [.llmRewrite]
    }
}

/// Ephemeral by construction: images and complete requests cannot enter Codable history.
public struct CorrectionReferenceImage: Sendable, Equatable {
    public let jpeg: Data
    public let width: Int
    public let height: Int

    public init(jpeg: Data, width: Int, height: Int) throws {
        guard !jpeg.isEmpty, jpeg.count <= 2 * 1_024 * 1_024,
              width > 0, height > 0, max(width, height) <= 2_560,
              jpeg.starts(with: [0xff, 0xd8]) else { throw ContextCorrectionError.invalidReference }
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }
}

public enum ContextCorrectionError: Error, Sendable {
    case invalidReference
    case authorizationChanged
    case staleSource
    case dailyBudgetExhausted
}

public struct ScreenReferenceSummary: Codable, Sendable, Equatable {
    public var terms: [String]
    public var observations: [String]

    public init(terms: [String], observations: [String]) {
        self.terms = terms
        self.observations = observations
    }

    public var isValid: Bool {
        terms.count <= 32 && observations.count <= 12
            && !(terms.isEmpty && observations.isEmpty)
            && (terms + observations).allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
            && (terms + observations).reduce(0) { $0 + $1.utf8.count } <= 4_096
    }
}

public struct CorrectionMemorySummary: Sendable, Equatable {
    public let memoryIDs: [UUID]
    public let terms: [String]
    public let corrections: [ConfirmedMemoryCorrection]

    public init(memoryIDs: [UUID], terms: [String], corrections: [ConfirmedMemoryCorrection]) throws {
        guard !memoryIDs.isEmpty, memoryIDs.count <= 5, Set(memoryIDs).count == memoryIDs.count,
              terms.count <= 32, corrections.count <= 16,
              terms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              corrections.allSatisfy(\.isValid),
              terms.reduce(0, { $0 + $1.utf8.count })
                + corrections.reduce(0, { $0 + $1.original.utf8.count + $1.corrected.utf8.count }) <= 4_096
        else { throw ContextCorrectionError.invalidReference }
        self.memoryIDs = memoryIDs
        self.terms = terms
        self.corrections = corrections
    }
}

public struct ContextualCorrectionRequest: Sendable, Equatable {
    public var transcript: String
    public var referenceImage: CorrectionReferenceImage?
    public var imageSummary: ScreenReferenceSummary?
    public var memorySummary: CorrectionMemorySummary?
    public var vocabularyReference: CorrectionVocabularyReference?

    public var hasCorrectionReferences: Bool {
        referenceImage != nil || imageSummary != nil || memorySummary != nil
            || vocabularyReference?.terms.isEmpty == false
    }
    public var authorization: ContextReferenceAuthorization?

    public init(
        transcript: String,
        referenceImage: CorrectionReferenceImage? = nil,
        imageSummary: ScreenReferenceSummary? = nil,
        memorySummary: CorrectionMemorySummary? = nil,
        authorization: ContextReferenceAuthorization? = nil,
        vocabularyReference: CorrectionVocabularyReference? = nil
    ) {
        self.transcript = transcript
        self.referenceImage = referenceImage
        self.imageSummary = imageSummary
        self.memorySummary = memorySummary
        self.authorization = authorization
        self.vocabularyReference = vocabularyReference
    }
}

/// Configuration changes revoke the same token observed by providers and storage.
public final class ContextReferenceAuthorization: @unchecked Sendable, Equatable {
    public let id: UUID
    public let providerFingerprint: String
    private let lock = NSLock()
    private let parent: ContextReferenceAuthorization?
    private var valid = true

    public init(id: UUID = UUID(), providerFingerprint: String) {
        self.id = id
        self.providerFingerprint = providerFingerprint
        parent = nil
    }

    public init(parent: ContextReferenceAuthorization) {
        id = parent.id
        providerFingerprint = parent.providerFingerprint
        self.parent = parent
    }

    public var isValid: Bool { lock.withLock { valid && parent?.isValid != false } }
    public func revoke() { lock.withLock { valid = false } }
    /// Linearizes a synchronous durable commit with revocation. No suspension is permitted here.
    public func whileAuthorized<Value>(_ operation: () throws -> Value) throws -> Value {
        try lock.withLock {
            guard valid else { throw ContextCorrectionError.authorizationChanged }
            if let parent { return try parent.whileAuthorized(operation) }
            return try operation()
        }
    }
    public static func == (lhs: ContextReferenceAuthorization, rhs: ContextReferenceAuthorization) -> Bool {
        lhs === rhs
    }
}

public final class CorrectionHistoryUpdate: Sendable, Equatable {
    private let action: @Sendable () async -> Void
    public init(action: @escaping @Sendable () async -> Void) { self.action = action }
    public func historySaved() async { await action() }
    public static func == (lhs: CorrectionHistoryUpdate, rhs: CorrectionHistoryUpdate) -> Bool { lhs === rhs }
}

public enum CorrectionReferenceStatus: String, Codable, Sendable, CaseIterable {
    case disabled, unavailable, timedOut, failed, pending, ready, sent, deliveryUnconfirmed, cancelled
}

/// A receipt reports references sent, never whether the model's correction was true.
public struct CorrectionReferenceReceipt: Codable, Sendable, Equatable {
    public var image: CorrectionReferenceStatus
    public var imageSummary: CorrectionReferenceStatus
    public var memorySummary: CorrectionReferenceStatus
    public var screenSummary: ScreenReferenceSummary?
    public var memoryIDs: [UUID]
    public var vocabulary: VocabularyReferenceReceipt?

    public init(
        image: CorrectionReferenceStatus = .disabled,
        imageSummary: CorrectionReferenceStatus = .disabled,
        memorySummary: CorrectionReferenceStatus = .disabled,
        screenSummary: ScreenReferenceSummary? = nil,
        memoryIDs: [UUID] = [],
        vocabulary: VocabularyReferenceReceipt? = nil
    ) {
        self.image = image
        self.imageSummary = imageSummary
        self.memorySummary = memorySummary
        self.screenSummary = screenSummary
        self.memoryIDs = memoryIDs
        self.vocabulary = vocabulary
    }
}

public struct ContextMemoryScope: Codable, Sendable, Equatable, Hashable {
    public var workflowID: UUID
    public var applicationBundleID: String?
    public var language: String?

    public init(workflowID: UUID, applicationBundleID: String?, language: String?) {
        self.workflowID = workflowID
        self.applicationBundleID = applicationBundleID
        self.language = language?.isEmpty == false ? language : nil
    }

    public func matches(_ scene: Self) -> Bool {
        workflowID == scene.workflowID && applicationBundleID == scene.applicationBundleID
            && language == scene.language
    }
}

public struct ContextFeatureSettings: Codable, Sendable, Equatable {
    public var screenContextEnabled = false
    public var memoryEnabled = false
    public var vocabularyCorrectionEnabled = false
    public var authorizedWorkflowIDs: Set<UUID> = []
    public var providerFingerprint: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case screenContextEnabled, memoryEnabled, vocabularyCorrectionEnabled, authorizedWorkflowIDs, providerFingerprint
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        screenContextEnabled = try values.decode(Bool.self, forKey: .screenContextEnabled)
        memoryEnabled = try values.decode(Bool.self, forKey: .memoryEnabled)
        vocabularyCorrectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .vocabularyCorrectionEnabled) ?? false
        authorizedWorkflowIDs = try values.decode(Set<UUID>.self, forKey: .authorizedWorkflowIDs)
        providerFingerprint = try values.decodeIfPresent(String.self, forKey: .providerFingerprint)
    }
}

public protocol ScreenContextCapturing: Sendable {
    func capture(focus: FocusSnapshot, excludingApplications: Set<String>) async throws -> CorrectionReferenceImage
}

public protocol CorrectionContextSummarizing: Sendable {
    func summarizeImage(_ image: CorrectionReferenceImage) async throws -> ScreenReferenceSummary
    func summarizeMemories(_ memories: [LongTermMemory]) async throws -> CorrectionMemorySummary
}

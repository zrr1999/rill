import Foundation

public enum VocabularyLibrarySourceError: Error, LocalizedError, Sendable, Equatable {
    case notReady
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notReady:
            return "Vocabulary rules are still loading."
        case .unavailable(let reason):
            return "Vocabulary rules are unavailable: \(reason)"
        }
    }
}

/// A process-wide, fail-closed snapshot of the vocabulary library.
///
/// Reads and updates are synchronous so a validated edit is visible to the next
/// recognition request before asynchronous persistence completes.
public final class VocabularyLibrarySource: @unchecked Sendable {
    private enum State {
        case loading
        case available([VocabularyCollection])
        case unavailable(String)
    }

    private let lock = NSLock()
    private var state: State
    private var legacyRulesSnapshot: [VocabularyRule]?

    /// Passing `nil` leaves the source loading. Passing an explicit empty array
    /// publishes an available personal collection containing no entries.
    public init(initialRules: [VocabularyRule]? = nil) {
        legacyRulesSnapshot = initialRules
        state = initialRules.map {
            State.available([
                .personal(entries: $0.map(VocabularyEntry.init(rule:))),
            ])
        } ?? .loading
    }

    public init(initialCollections: [VocabularyCollection]?) {
        legacyRulesSnapshot = initialCollections?.flatMap { collection in
            collection.entries.map { $0.legacyRule() }
        }
        state = initialCollections.map(State.available) ?? .loading
    }

    public func currentRules() throws -> [VocabularyRule] {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .loading:
            throw VocabularyLibrarySourceError.notReady
        case .available:
            return legacyRulesSnapshot ?? []
        case .unavailable(let reason):
            throw VocabularyLibrarySourceError.unavailable(reason)
        }
    }

    public func currentCollections() throws -> [VocabularyCollection] {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .loading:
            throw VocabularyRuleSourceError.notReady
        case .available(let collections):
            return collections
        case .unavailable(let reason):
            throw VocabularyRuleSourceError.unavailable(reason)
        }
    }

    public var hasAvailableRules: Bool {
        lock.lock()
        defer { lock.unlock() }

        if case .available = state {
            return true
        }
        return false
    }

    public func update(_ rules: [VocabularyRule]) {
        lock.lock()
        legacyRulesSnapshot = rules
        state = .available([
            .personal(entries: rules.map(VocabularyEntry.init(rule:))),
        ])
        lock.unlock()
    }

    public func updateCollections(_ collections: [VocabularyCollection]) {
        lock.lock()
        legacyRulesSnapshot = collections.flatMap { collection in
            collection.entries.map { $0.legacyRule() }
        }
        state = .available(collections)
        lock.unlock()
    }

    public func markUnavailable(reason: String) {
        lock.lock()
        legacyRulesSnapshot = nil
        state = .unavailable(reason)
        lock.unlock()
    }
}

public typealias VocabularyRuleSource = VocabularyLibrarySource
public typealias VocabularyRuleSourceError = VocabularyLibrarySourceError

public struct VocabularyRecognitionHintResolution: Sendable, Equatable {
    public var hints: RecognitionHints
    /// The number of valid, distinct keyterms before the provider-facing cap.
    public var validKeytermCount: Int
    /// The number of valid, distinct keyterms excluded by the cap.
    public var omittedKeytermCount: Int
    /// The number of applicable rules rejected for invalid pattern content.
    public var rejectedKeytermCount: Int

    public init(
        hints: RecognitionHints,
        validKeytermCount: Int,
        omittedKeytermCount: Int,
        rejectedKeytermCount: Int
    ) {
        self.hints = hints
        self.validKeytermCount = validKeytermCount
        self.omittedKeytermCount = omittedKeytermCount
        self.rejectedKeytermCount = rejectedKeytermCount
    }
}

public struct VocabularyRecognitionHintResolver: Sendable {
    public let maximumKeytermCount: Int

    public init(maximumKeytermCount: Int = 50) {
        self.maximumKeytermCount = max(0, maximumKeytermCount)
    }

    public func resolve(
        rules: [VocabularyRule],
        context: VocabularyRuleContext = .init()
    ) -> VocabularyRecognitionHintResolution {
        let applicableRules = rules
            .filter { rule in
                rule.enabled && rule.kind == .hotword && rule.scope.matches(context)
            }
            .sorted(by: Self.isOrderedBefore)

        var validKeyterms: [String] = []
        var seenKeyterms: Set<String> = []
        var rejectedKeytermCount = 0

        for rule in applicableRules {
            guard let keyterm = Self.validatedKeyterm(from: rule.pattern) else {
                rejectedKeytermCount += 1
                continue
            }
            guard seenKeyterms.insert(keyterm).inserted else {
                continue
            }
            validKeyterms.append(keyterm)
        }

        let emittedKeyterms = Array(validKeyterms.prefix(maximumKeytermCount))
        return VocabularyRecognitionHintResolution(
            hints: RecognitionHints(keyterms: emittedKeyterms),
            validKeytermCount: validKeyterms.count,
            omittedKeytermCount: validKeyterms.count - emittedKeyterms.count,
            rejectedKeytermCount: rejectedKeytermCount
        )
    }

    private static func isOrderedBefore(_ lhs: VocabularyRule, _ rhs: VocabularyRule) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func validatedKeyterm(from pattern: String) -> String? {
        guard !pattern.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
        }) else {
            return nil
        }

        let keyterm = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return keyterm.isEmpty ? nil : keyterm
    }
}

import Foundation

public enum VocabularyRuleSourceError: Error, LocalizedError, Sendable, Equatable {
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

/// A process-wide, fail-closed snapshot of vocabulary rules.
///
/// Reads and updates are synchronous so a validated edit is visible to the next
/// recognition request before asynchronous persistence completes.
public final class VocabularyRuleSource: @unchecked Sendable {
    private enum State {
        case loading
        case available([VocabularyRule])
        case unavailable(String)
    }

    private let lock = NSLock()
    private var state: State

    /// Passing `nil` leaves the source loading. Passing an explicit empty array
    /// publishes an available snapshot containing no rules.
    public init(initialRules: [VocabularyRule]? = nil) {
        state = initialRules.map(State.available) ?? .loading
    }

    public func currentRules() throws -> [VocabularyRule] {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .loading:
            throw VocabularyRuleSourceError.notReady
        case .available(let rules):
            return rules
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
        state = .available(rules)
        lock.unlock()
    }

    public func markUnavailable(reason: String) {
        lock.lock()
        state = .unavailable(reason)
        lock.unlock()
    }
}

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

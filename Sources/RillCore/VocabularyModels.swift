import Foundation

public enum VocabularyRuleKind: String, Codable, Sendable, Equatable {
    case mapping
    case hotword
}

public enum VocabularyMatchMode: String, Codable, Sendable, Equatable {
    case exactPhrase
    case wordBoundary
    case regex
}

public struct VocabularyRuleScope: Codable, Sendable, Equatable, Hashable {
    public var bundleIdentifier: String?
    public var clipboardGroupID: UUID?
    public var locale: String?

    public init(
        bundleIdentifier: String? = nil,
        clipboardGroupID: UUID? = nil,
        locale: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.clipboardGroupID = clipboardGroupID
        self.locale = locale
    }

    public func matches(_ context: VocabularyRuleContext) -> Bool {
        if let bundleIdentifier, bundleIdentifier != context.bundleIdentifier {
            return false
        }
        if let clipboardGroupID, clipboardGroupID != context.clipboardGroupID {
            return false
        }
        if let locale, locale != context.locale {
            return false
        }
        return true
    }
}

public struct VocabularyRule: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: VocabularyRuleKind
    public var enabled: Bool
    public var pattern: String
    public var replacement: String
    public var matchMode: VocabularyMatchMode
    public var caseSensitive: Bool
    public var scope: VocabularyRuleScope
    public var priority: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: VocabularyRuleKind = .mapping,
        enabled: Bool = true,
        pattern: String,
        replacement: String,
        matchMode: VocabularyMatchMode = .exactPhrase,
        caseSensitive: Bool = false,
        scope: VocabularyRuleScope = .init(),
        priority: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.pattern = pattern
        self.replacement = replacement
        self.matchMode = matchMode
        self.caseSensitive = caseSensitive
        self.scope = scope
        self.priority = priority
        self.createdAt = createdAt
    }
}

public struct VocabularyRuleContext: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    public var clipboardGroupID: UUID?
    public var locale: String?

    public init(
        bundleIdentifier: String? = nil,
        clipboardGroupID: UUID? = nil,
        locale: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.clipboardGroupID = clipboardGroupID
        self.locale = locale
    }

    public init(
        contextSnapshot: ContextSnapshot,
        clipboardGroupID: UUID? = nil,
        locale: String? = nil
    ) {
        self.init(
            bundleIdentifier: contextSnapshot.focus.bundleIdentifier,
            clipboardGroupID: clipboardGroupID,
            locale: locale
        )
    }
}

public enum VocabularyApplicationIssueKind: String, Codable, Sendable, Equatable {
    case emptyPattern
    case invalidRegex
}

public struct VocabularyApplicationIssue: Error, Codable, Sendable, Equatable {
    public var ruleID: UUID
    public var kind: VocabularyApplicationIssueKind
    public var message: String

    public init(ruleID: UUID, kind: VocabularyApplicationIssueKind, message: String) {
        self.ruleID = ruleID
        self.kind = kind
        self.message = message
    }
}

public struct VocabularyRuleApplication: Codable, Sendable, Equatable {
    public var ruleID: UUID
    public var pattern: String
    public var replacement: String
    public var matchCount: Int

    public init(ruleID: UUID, pattern: String, replacement: String, matchCount: Int) {
        self.ruleID = ruleID
        self.pattern = pattern
        self.replacement = replacement
        self.matchCount = matchCount
    }
}

public struct VocabularyApplicationResult: Codable, Sendable, Equatable {
    public var text: String
    public var applications: [VocabularyRuleApplication]
    public var issues: [VocabularyApplicationIssue]

    public init(
        text: String,
        applications: [VocabularyRuleApplication] = [],
        issues: [VocabularyApplicationIssue] = []
    ) {
        self.text = text
        self.applications = applications
        self.issues = issues
    }

    public var changed: Bool {
        applications.contains { $0.matchCount > 0 }
    }
}

public enum VocabularyRuleApplicator {
    public static func apply(
        text: String,
        rules: [VocabularyRule],
        context: VocabularyRuleContext = .init()
    ) -> VocabularyApplicationResult {
        var output = text
        var applications: [VocabularyRuleApplication] = []
        var issues: [VocabularyApplicationIssue] = []

        for rule in orderedApplicableRules(rules, context: context) {
            let replacement = replacing(in: output, with: rule)
            switch replacement {
            case .success(let result):
                output = result.text
                if result.matchCount > 0 {
                    applications.append(
                        VocabularyRuleApplication(
                            ruleID: rule.id,
                            pattern: rule.pattern,
                            replacement: rule.replacement,
                            matchCount: result.matchCount
                        )
                    )
                }
            case .failure(let issue):
                issues.append(issue)
            }
        }

        return VocabularyApplicationResult(text: output, applications: applications, issues: issues)
    }

    private static func orderedApplicableRules(
        _ rules: [VocabularyRule],
        context: VocabularyRuleContext
    ) -> [VocabularyRule] {
        rules
            .filter { rule in
                rule.enabled && rule.kind == .mapping && rule.scope.matches(context)
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func replacing(
        in text: String,
        with rule: VocabularyRule
    ) -> Result<(text: String, matchCount: Int), VocabularyApplicationIssue> {
        guard !rule.pattern.isEmpty else {
            return .failure(
                VocabularyApplicationIssue(
                    ruleID: rule.id,
                    kind: .emptyPattern,
                    message: "Vocabulary rule pattern is empty."
                )
            )
        }

        let pattern: String
        switch rule.matchMode {
        case .exactPhrase:
            pattern = NSRegularExpression.escapedPattern(for: rule.pattern)
        case .wordBoundary:
            pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.pattern))\\b"
        case .regex:
            pattern = rule.pattern
        }

        do {
            let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            guard !matches.isEmpty else {
                return .success((text, 0))
            }

            let mutable = NSMutableString(string: text)
            for match in matches.reversed() {
                mutable.replaceCharacters(in: match.range, with: rule.replacement)
            }
            return .success((String(mutable), matches.count))
        } catch {
            return .failure(
                VocabularyApplicationIssue(
                    ruleID: rule.id,
                    kind: .invalidRegex,
                    message: error.localizedDescription
                )
            )
        }
    }
}

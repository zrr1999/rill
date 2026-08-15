import Foundation

public enum VocabularyEntryContent: Codable, Sendable, Equatable {
    case hotword(phrase: String)
    case replacement(
        pattern: String,
        replacement: String,
        matchMode: VocabularyMatchMode,
        caseSensitive: Bool
    )

    public var kind: VocabularyRuleKind {
        switch self {
        case .hotword:
            return .hotword
        case .replacement:
            return .mapping
        }
    }
}

public struct VocabularyEntry: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var enabled: Bool
    public var content: VocabularyEntryContent
    public var priority: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        content: VocabularyEntryContent,
        priority: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.enabled = enabled
        self.content = content
        self.priority = priority
        self.createdAt = createdAt
    }

    public init(rule: VocabularyRule) {
        let content: VocabularyEntryContent
        switch rule.kind {
        case .hotword:
            content = .hotword(phrase: rule.pattern)
        case .mapping:
            content = .replacement(
                pattern: rule.pattern,
                replacement: rule.replacement,
                matchMode: rule.matchMode,
                caseSensitive: rule.caseSensitive
            )
        }
        self.init(
            id: rule.id,
            enabled: rule.enabled,
            content: content,
            priority: rule.priority,
            createdAt: rule.createdAt
        )
    }

    public func legacyRule(scope: VocabularyRuleScope = .init()) -> VocabularyRule {
        switch content {
        case .hotword(let phrase):
            return VocabularyRule(
                id: id,
                kind: .hotword,
                enabled: enabled,
                pattern: phrase,
                replacement: "",
                matchMode: .exactPhrase,
                caseSensitive: false,
                scope: scope,
                priority: priority,
                createdAt: createdAt
            )
        case .replacement(let pattern, let replacement, let matchMode, let caseSensitive):
            return VocabularyRule(
                id: id,
                kind: .mapping,
                enabled: enabled,
                pattern: pattern,
                replacement: replacement,
                matchMode: matchMode,
                caseSensitive: caseSensitive,
                scope: scope,
                priority: priority,
                createdAt: createdAt
            )
        }
    }
}

public struct VocabularyCollection: Identifiable, Codable, Sendable, Equatable {
    public static let personalID = UUID(uuidString: "E79EF7C7-8867-5D6C-8E88-1119C62B9702")!

    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var entries: [VocabularyEntry]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        entries: [VocabularyEntry] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func personal(entries: [VocabularyEntry] = []) -> VocabularyCollection {
        VocabularyCollection(id: personalID, name: "Personal Vocabulary", entries: entries)
    }
}

public struct VocabularyLibraryDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var collections: [VocabularyCollection]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        collections: [VocabularyCollection]
    ) {
        self.schemaVersion = schemaVersion
        self.collections = collections
    }
}

public struct WorkflowCustomization: Codable, Sendable, Equatable {
    public var workflowID: UUID
    public var vocabularyBindings: [VocabularyCollectionBinding]?

    public init(
        workflowID: UUID,
        vocabularyBindings: [VocabularyCollectionBinding]? = nil
    ) {
        self.workflowID = workflowID
        self.vocabularyBindings = vocabularyBindings
    }
}

public struct WorkflowLibraryDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var customWorkflows: [WorkflowDefinition]
    public var customizations: [WorkflowCustomization]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        customWorkflows: [WorkflowDefinition],
        customizations: [WorkflowCustomization] = []
    ) {
        self.schemaVersion = schemaVersion
        self.customWorkflows = customWorkflows
        self.customizations = customizations
    }
}

public struct ResolvedVocabularySnapshot: Sendable, Equatable {
    public var hotwordRules: [VocabularyRule]
    public var replacementRules: [VocabularyRule]
    public var activeCollectionCount: Int

    public init(
        hotwordRules: [VocabularyRule] = [],
        replacementRules: [VocabularyRule] = [],
        activeCollectionCount: Int = 0
    ) {
        self.hotwordRules = hotwordRules
        self.replacementRules = replacementRules
        self.activeCollectionCount = activeCollectionCount
    }
}

public enum VocabularyCollectionResolver {
    public static func resolve(
        bindings: [VocabularyCollectionBinding],
        collections: [VocabularyCollection],
        context: VocabularyRuleContext
    ) -> ResolvedVocabularySnapshot {
        let collectionsByID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        var activeCollectionIDs = Set<UUID>()
        var hotwordEntryIDs = Set<UUID>()
        var replacementEntryIDs = Set<UUID>()
        var hotwordRules: [VocabularyRule] = []
        var replacementRules: [VocabularyRule] = []

        for binding in bindings where binding.condition.matches(context) {
            guard let collection = collectionsByID[binding.collectionID], collection.enabled else {
                continue
            }
            activeCollectionIDs.insert(collection.id)
            for entry in collection.entries where entry.enabled {
                let rule = entry.legacyRule()
                switch entry.content {
                case .hotword
                    where binding.uses.contains(.recognitionHints)
                        && hotwordEntryIDs.insert(entry.id).inserted:
                    hotwordRules.append(rule)
                case .replacement
                    where binding.uses.contains(.textReplacement)
                        && replacementEntryIDs.insert(entry.id).inserted:
                    replacementRules.append(rule)
                case .hotword, .replacement:
                    break
                }
            }
        }

        return ResolvedVocabularySnapshot(
            hotwordRules: ordered(hotwordRules),
            replacementRules: ordered(replacementRules),
            activeCollectionCount: activeCollectionIDs.count
        )
    }

    private static func ordered(_ rules: [VocabularyRule]) -> [VocabularyRule] {
        rules.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

public struct VocabularyLegacyMigrationResult: Sendable, Equatable {
    public var collections: [VocabularyCollection]
    public var bindings: [VocabularyCollectionBinding]

    public init(
        collections: [VocabularyCollection],
        bindings: [VocabularyCollectionBinding]
    ) {
        self.collections = collections
        self.bindings = bindings
    }
}

public enum VocabularyLegacyMigrator {
    public static func migrate(_ rules: [VocabularyRule]) -> VocabularyLegacyMigrationResult {
        let grouped = Dictionary(grouping: rules, by: \.scope)
        var collections: [VocabularyCollection] = []
        var bindings: [VocabularyCollectionBinding] = []

        let scopes = grouped.keys.sorted { scopeKey($0) < scopeKey($1) }
        for scope in scopes {
            let scopedRules = grouped[scope, default: []].sorted(by: ruleOrder)
            let isGlobal = scope == VocabularyRuleScope()
            let collectionID = isGlobal
                ? VocabularyCollection.personalID
                : stableID(for: scopeKey(scope))
            let dates = scopedRules.map(\.createdAt)
            let createdAt = dates.min() ?? Date()
            let updatedAt = dates.max() ?? createdAt
            collections.append(
                VocabularyCollection(
                    id: collectionID,
                    name: isGlobal ? "Personal Vocabulary" : collectionName(for: scope),
                    entries: scopedRules.map(VocabularyEntry.init(rule:)),
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
            bindings.append(
                VocabularyCollectionBinding(
                    id: stableID(for: "binding:\(scopeKey(scope))"),
                    collectionID: collectionID,
                    condition: WorkflowBindingCondition(
                        bundleIdentifier: scope.bundleIdentifier,
                        recordCollectionID: scope.recordCollectionID,
                        locale: scope.locale
                    )
                )
            )
        }

        if collections.isEmpty {
            collections = [.personal()]
            bindings = [
                VocabularyCollectionBinding(
                    id: stableID(for: "binding:personal"),
                    collectionID: VocabularyCollection.personalID
                ),
            ]
        }
        return VocabularyLegacyMigrationResult(
            collections: collections,
            bindings: bindings
        )
    }

    private static func ruleOrder(_ lhs: VocabularyRule, _ rhs: VocabularyRule) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func scopeKey(_ scope: VocabularyRuleScope) -> String {
        [
            scope.bundleIdentifier ?? "*",
            scope.recordCollectionID?.uuidString ?? "*",
            scope.locale ?? "*",
        ].joined(separator: "\u{1F}")
    }

    private static func collectionName(for scope: VocabularyRuleScope) -> String {
        let parts = [
            scope.bundleIdentifier,
            scope.recordCollectionID.map { "Group \($0.uuidString.prefix(8))" },
            scope.locale,
        ].compactMap { $0 }
        return parts.isEmpty ? "Personal Vocabulary" : parts.joined(separator: " · ")
    }

    private static func stableID(for value: String) -> UUID {
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in value.utf8 {
            high ^= UInt64(byte)
            high &*= 0x100000001b3
            low ^= UInt64(byte) &+ 0x9e
            low &*= 0x100000001b3
        }
        let text = String(
            format: "%08X-%04X-5%03X-%04X-%012llX",
            UInt32(truncatingIfNeeded: high >> 32),
            UInt16(truncatingIfNeeded: high >> 16),
            UInt16(truncatingIfNeeded: high) & 0x0fff,
            (UInt16(truncatingIfNeeded: low >> 48) & 0x3fff) | 0x8000,
            low & 0x0000ffffffffffff
        )
        return UUID(uuidString: text)!
    }
}

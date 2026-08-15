import Foundation
import RillCore

/// Mutable presentation state for reviewing one recognition correction.
///
/// The draft never persists a rule. It requires the user to select one planner
/// option and explicitly confirm every unknown recognition scope as `Any`
/// before exposing a rule that can be saved.
public struct VocabularyCorrectionDraft: Sendable {
    public enum Status: Sendable, Equatable {
        case unchanged
        case invalid(VocabularyCorrectionInvalidReason)
        case optionsAvailable
    }

    public struct Option: Identifiable, Sendable, Equatable {
        public enum ID: String, Sendable, Equatable, Hashable {
            case mapping
            case hotword
        }

        public let id: ID
        public let kind: VocabularyRuleKind
        public let pattern: String
        public let replacement: String
        public let scope: VocabularyCorrectionScopeAssessment

        fileprivate init?(_ option: VocabularyCorrectionOption) {
            switch option {
            case .mapping(let pattern, let replacement, let scope):
                let normalizedPattern = Self.normalized(pattern)
                guard !normalizedPattern.isEmpty else { return nil }
                id = .mapping
                kind = .mapping
                self.pattern = normalizedPattern
                self.replacement = Self.normalized(replacement)
                self.scope = scope

            case .hotword(let term, let scope):
                let normalizedTerm = Self.normalized(term)
                guard !normalizedTerm.isEmpty else { return nil }
                id = .hotword
                kind = .hotword
                pattern = normalizedTerm
                replacement = ""
                self.scope = scope
            }
        }

        private static func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public let source: RecognitionCorrectionSource
    public private(set) var correctedText: String
    public private(set) var status: Status
    public private(set) var options: [Option]
    public private(set) var selectedOptionID: Option.ID?
    public private(set) var confirmedAnyScopeFields: Set<VocabularyCorrectionScopeField>

    private let planner: VocabularyCorrectionPlanner
    private let proposedRuleID: UUID
    private let proposedRuleCreatedAt: Date

    public static func isEligible(
        record: WorkflowResultRecord,
        privacyPreviewMode: PrivacyHistoryPreviewMode
    ) -> Bool {
        record.outcome == .completed
            && record.correctionSource != nil
            && privacyPreviewMode != .disabled
    }

    public init?(
        record: WorkflowResultRecord,
        privacyPreviewMode: PrivacyHistoryPreviewMode,
        planner: VocabularyCorrectionPlanner = .init()
    ) {
        guard Self.isEligible(record: record, privacyPreviewMode: privacyPreviewMode),
              let source = record.correctionSource else {
            return nil
        }
        self.init(source: source, planner: planner)
    }

    public init(
        source: RecognitionCorrectionSource,
        planner: VocabularyCorrectionPlanner = .init()
    ) {
        self.source = source
        self.planner = planner
        proposedRuleID = UUID()
        proposedRuleCreatedAt = Date()
        correctedText = source.preMappingText
        status = .unchanged
        options = []
        selectedOptionID = nil
        confirmedAnyScopeFields = []
    }

    public var originalText: String {
        source.preMappingText
    }

    public var selectedOption: Option? {
        guard let selectedOptionID else { return nil }
        return options.first { $0.id == selectedOptionID }
    }

    public var unknownScopeFields: Set<VocabularyCorrectionScopeField> {
        selectedOption?.scope.unknownFields ?? []
    }

    public var proposedRule: VocabularyRule? {
        guard let selectedOption,
              selectedOption.scope.unknownFields.isSubset(of: confirmedAnyScopeFields) else {
            return nil
        }

        return VocabularyRule(
            id: proposedRuleID,
            kind: selectedOption.kind,
            enabled: true,
            pattern: selectedOption.pattern,
            replacement: selectedOption.kind == .hotword ? "" : selectedOption.replacement,
            matchMode: .exactPhrase,
            caseSensitive: false,
            scope: selectedOption.scope.knownConstraints,
            createdAt: proposedRuleCreatedAt
        )
    }

    public mutating func updateCorrectedText(_ correctedText: String) {
        self.correctedText = correctedText
        resetSelection()

        switch planner.plan(source: source, correctedText: correctedText) {
        case .unchanged:
            status = .unchanged
            options = []

        case .invalid(let reason):
            status = .invalid(reason)
            options = []

        case .options(let plannedOptions):
            options = plannedOptions.compactMap(Option.init)
            if options.isEmpty {
                status = .invalid(.noUsableSuggestion)
            } else {
                status = .optionsAvailable
            }
        }
    }

    public mutating func selectOption(id: Option.ID) {
        guard options.contains(where: { $0.id == id }) else {
            resetSelection()
            return
        }
        selectedOptionID = id
        confirmedAnyScopeFields = []
    }

    public mutating func selectOption(at index: Int) {
        guard options.indices.contains(index) else {
            resetSelection()
            return
        }
        selectOption(id: options[index].id)
    }

    public mutating func setAnyScopeConfirmed(
        _ isConfirmed: Bool,
        for field: VocabularyCorrectionScopeField
    ) {
        guard unknownScopeFields.contains(field) else {
            confirmedAnyScopeFields.remove(field)
            return
        }

        if isConfirmed {
            confirmedAnyScopeFields.insert(field)
        } else {
            confirmedAnyScopeFields.remove(field)
        }
    }

    private mutating func resetSelection() {
        selectedOptionID = nil
        confirmedAnyScopeFields = []
    }
}

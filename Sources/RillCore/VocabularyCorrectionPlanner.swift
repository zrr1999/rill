import Foundation

public enum VocabularyCorrectionScopeField: String, CaseIterable, Sendable, Equatable, Hashable {
    case bundleIdentifier
    case clipboardGroupID
    case locale
}

/// Describes how much of the recognition-time scope can be reused safely.
///
/// A missing recognition context value is unknown, not evidence that the user
/// intended an unrestricted rule. Consumers must resolve every unknown field
/// explicitly before creating a rule.
public struct VocabularyCorrectionScopeAssessment: Sendable, Equatable {
    public var knownConstraints: VocabularyRuleScope
    public var unknownFields: Set<VocabularyCorrectionScopeField>

    public init(context: VocabularyRuleContext) {
        let bundleIdentifier = Self.nonempty(context.bundleIdentifier)
        let locale = Self.nonempty(context.locale)

        knownConstraints = VocabularyRuleScope(
            bundleIdentifier: bundleIdentifier,
            clipboardGroupID: context.clipboardGroupID,
            locale: locale
        )

        var unknownFields: Set<VocabularyCorrectionScopeField> = []
        if bundleIdentifier == nil {
            unknownFields.insert(.bundleIdentifier)
        }
        if context.clipboardGroupID == nil {
            unknownFields.insert(.clipboardGroupID)
        }
        if locale == nil {
            unknownFields.insert(.locale)
        }
        self.unknownFields = unknownFields
    }

    public var containsUnknownFields: Bool {
        !unknownFields.isEmpty
    }

    /// Returns a rule-ready scope only when every scope field was captured.
    /// A caller that wants to interpret unknown fields as Any must make that
    /// decision outside the planner and present it for explicit confirmation.
    public var confirmedRuleScope: VocabularyRuleScope? {
        containsUnknownFields ? nil : knownConstraints
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum VocabularyCorrectionInvalidReason: Sendable, Equatable {
    case textExceedsCharacterLimit(Int)
    case suggestionExceedsCharacterLimit(Int)
    case containsControlCharacters
    case multipleDisjointChanges
    case noUsableSuggestion
}

public enum VocabularyCorrectionOption: Sendable, Equatable {
    case mapping(
        pattern: String,
        replacement: String,
        scope: VocabularyCorrectionScopeAssessment
    )
    case hotword(
        term: String,
        scope: VocabularyCorrectionScopeAssessment
    )
}

public enum VocabularyCorrectionPlan: Sendable, Equatable {
    case unchanged
    case invalid(VocabularyCorrectionInvalidReason)
    case options([VocabularyCorrectionOption])
}

/// Produces conservative vocabulary-rule suggestions from one user edit.
///
/// The planner operates on extended grapheme clusters (`Character`) and only
/// accepts a single contiguous edit hunk. It never writes or persists a rule.
public struct VocabularyCorrectionPlanner: Sendable {
    public let maximumTextCharacterCount: Int
    public let maximumSuggestionCharacterCount: Int

    public init(
        maximumTextCharacterCount: Int = 2_048,
        maximumSuggestionCharacterCount: Int = 100
    ) {
        self.maximumTextCharacterCount = max(0, maximumTextCharacterCount)
        self.maximumSuggestionCharacterCount = max(0, maximumSuggestionCharacterCount)
    }

    public func plan(
        source: RecognitionCorrectionSource,
        correctedText: String
    ) -> VocabularyCorrectionPlan {
        let originalText = source.preMappingText
        guard originalText != correctedText else {
            return .unchanged
        }

        let originalCharacters = Array(originalText)
        let correctedCharacters = Array(correctedText)
        guard originalCharacters.count <= maximumTextCharacterCount,
              correctedCharacters.count <= maximumTextCharacterCount else {
            return .invalid(.textExceedsCharacterLimit(maximumTextCharacterCount))
        }
        guard !Self.containsControlCharacters(originalText),
              !Self.containsControlCharacters(correctedText) else {
            return .invalid(.containsControlCharacters)
        }

        guard let edit = Self.singleContiguousEdit(
            from: originalCharacters,
            to: correctedCharacters
        ) else {
            return .invalid(.multipleDisjointChanges)
        }

        let removedText = Self.trimmed(String(edit.removed))
        let insertedText = Self.trimmed(String(edit.inserted))
        guard !removedText.isEmpty || !insertedText.isEmpty else {
            return .invalid(.noUsableSuggestion)
        }
        guard removedText.count <= maximumSuggestionCharacterCount,
              insertedText.count <= maximumSuggestionCharacterCount else {
            return .invalid(
                .suggestionExceedsCharacterLimit(maximumSuggestionCharacterCount)
            )
        }

        let scope = VocabularyCorrectionScopeAssessment(context: source.context)
        switch (removedText.isEmpty, insertedText.isEmpty) {
        case (true, false):
            return .options([.hotword(term: insertedText, scope: scope)])
        case (false, true):
            return .options([
                .mapping(pattern: removedText, replacement: "", scope: scope),
            ])
        case (false, false):
            return .options([
                .mapping(pattern: removedText, replacement: insertedText, scope: scope),
                .hotword(term: insertedText, scope: scope),
            ])
        case (true, true):
            return .invalid(.noUsableSuggestion)
        }
    }

    private struct EditHunk {
        var removed: [Character] = []
        var inserted: [Character] = []
    }

    private static func singleContiguousEdit(
        from original: [Character],
        to corrected: [Character]
    ) -> EditHunk? {
        let difference = corrected.difference(from: original)
        var removalOffsets: Set<Int> = []
        var insertionOffsets: Set<Int> = []

        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removalOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertionOffsets.insert(offset)
            }
        }

        var originalOffset = 0
        var correctedOffset = 0
        var hunks: [EditHunk] = []
        var currentHunk: EditHunk?

        func finishCurrentHunk() {
            if let currentHunk {
                hunks.append(currentHunk)
            }
            currentHunk = nil
        }

        while originalOffset < original.count || correctedOffset < corrected.count {
            let isRemoval = originalOffset < original.count
                && removalOffsets.contains(originalOffset)
            let isInsertion = correctedOffset < corrected.count
                && insertionOffsets.contains(correctedOffset)

            if isRemoval || isInsertion {
                if currentHunk == nil {
                    currentHunk = EditHunk()
                }
                if isRemoval {
                    currentHunk?.removed.append(original[originalOffset])
                    originalOffset += 1
                }
                if isInsertion {
                    currentHunk?.inserted.append(corrected[correctedOffset])
                    correctedOffset += 1
                }
                continue
            }

            guard originalOffset < original.count,
                  correctedOffset < corrected.count,
                  original[originalOffset] == corrected[correctedOffset] else {
                return nil
            }
            finishCurrentHunk()
            guard hunks.count <= 1 else { return nil }
            originalOffset += 1
            correctedOffset += 1
        }

        finishCurrentHunk()
        guard hunks.count == 1 else { return nil }
        return hunks[0]
    }

    private static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

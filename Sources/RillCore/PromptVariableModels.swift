import Foundation

public enum PromptVariableKey: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case text
    case rawText
    case selected
    case clipboard
    case app
    case bundleID
    case group
}

/// Ephemeral prompt input. This type intentionally is not `Codable`: selected
/// text, clipboard text, and application context must not acquire an accidental
/// persistence path merely because the renderer needs them in memory.
public struct PromptVariableContext: Sendable, Equatable {
    public var text: String
    public var rawText: String
    public var selectedText: String
    public var clipboardText: String
    public var applicationName: String
    public var bundleIdentifier: String
    public var groupIdentifier: String

    public init(
        text: String,
        rawText: String? = nil,
        selectedText: String = "",
        clipboardText: String = "",
        applicationName: String = "",
        bundleIdentifier: String = "",
        groupIdentifier: String = ""
    ) {
        self.text = text
        self.rawText = rawText ?? text
        self.selectedText = selectedText
        self.clipboardText = clipboardText
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.groupIdentifier = groupIdentifier
    }

    public init(
        text: String,
        recognitionResult: RecognitionResult,
        contextSnapshot: ContextSnapshot,
        groupIdentifier: String = ""
    ) {
        self.init(
            text: text,
            rawText: recognitionResult.rawText,
            selectedText: contextSnapshot.focus.selectedText,
            clipboardText: contextSnapshot.clipboard.plainText,
            applicationName: contextSnapshot.focus.applicationName ?? "",
            bundleIdentifier: contextSnapshot.focus.bundleIdentifier ?? "",
            groupIdentifier: groupIdentifier
        )
    }

    public func value(for key: PromptVariableKey) -> String {
        switch key {
        case .text:
            return text
        case .rawText:
            return rawText
        case .selected:
            return selectedText
        case .clipboard:
            return clipboardText
        case .app:
            return applicationName
        case .bundleID:
            return bundleIdentifier
        case .group:
            return groupIdentifier
        }
    }
}

/// Ephemeral rendered content. Persist or diagnose `summary` instead of this
/// value so the rendered prompt and unknown user-authored tokens cannot leak.
public struct PromptRenderResult: Sendable, Equatable {
    public var renderedPrompt: String
    public var usedVariables: [PromptVariableKey]
    public var missingVariables: [PromptVariableKey]
    public var redactedVariables: [PromptVariableKey]
    public var unknownVariables: [String]

    public init(
        renderedPrompt: String,
        usedVariables: [PromptVariableKey] = [],
        missingVariables: [PromptVariableKey] = [],
        redactedVariables: [PromptVariableKey] = [],
        unknownVariables: [String] = []
    ) {
        self.renderedPrompt = renderedPrompt
        self.usedVariables = usedVariables
        self.missingVariables = missingVariables
        self.redactedVariables = redactedVariables
        self.unknownVariables = unknownVariables
    }

    public var summary: PromptRenderSummary {
        PromptRenderSummary(
            usedVariables: usedVariables,
            missingVariables: missingVariables,
            redactedVariables: redactedVariables,
            unknownVariableCount: unknownVariables.count
        )
    }
}

/// Content-free evidence safe for receipts, diagnostics, and dry-run state.
/// All known-variable subsets use `usedVariables` order as their canonical order.
public struct PromptRenderSummary: Codable, Sendable, Equatable {
    public static let maximumUnknownVariableCount = 32

    public let usedVariables: [PromptVariableKey]
    public let missingVariables: [PromptVariableKey]
    public let redactedVariables: [PromptVariableKey]
    public let unknownVariableCount: Int

    public init(
        usedVariables: [PromptVariableKey] = [],
        missingVariables: [PromptVariableKey] = [],
        redactedVariables: [PromptVariableKey] = [],
        unknownVariableCount: Int = 0
    ) {
        let usedVariables = Self.orderedUnique(usedVariables)
        let redactedSet = Set(redactedVariables)
        let missingSet = Set(missingVariables).union(redactedSet)
        self.usedVariables = usedVariables
        self.missingVariables = usedVariables.filter(missingSet.contains)
        self.redactedVariables = usedVariables.filter(redactedSet.contains)
        self.unknownVariableCount = min(
            max(0, unknownVariableCount),
            Self.maximumUnknownVariableCount
        )
    }

    private enum CodingKeys: String, CodingKey {
        case usedVariables
        case missingVariables
        case redactedVariables
        case unknownVariableCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let usedVariables = try container.decode([PromptVariableKey].self, forKey: .usedVariables)
        let missingVariables = try container.decode([PromptVariableKey].self, forKey: .missingVariables)
        let redactedVariables = try container.decode([PromptVariableKey].self, forKey: .redactedVariables)
        let unknownVariableCount = try container.decode(Int.self, forKey: .unknownVariableCount)
        let maximumKnownCount = PromptVariableKey.allCases.count
        let usedSet = Set(usedVariables)
        let missingSet = Set(missingVariables)
        let redactedSet = Set(redactedVariables)
        let canonicalMissingVariables = usedVariables.filter(missingSet.contains)
        let canonicalRedactedVariables = usedVariables.filter(redactedSet.contains)

        guard usedVariables.count <= maximumKnownCount,
              missingVariables.count <= maximumKnownCount,
              redactedVariables.count <= maximumKnownCount,
              usedSet.count == usedVariables.count,
              missingSet.count == missingVariables.count,
              redactedSet.count == redactedVariables.count,
              missingSet.isSubset(of: usedSet),
              redactedSet.isSubset(of: missingSet),
              missingVariables == canonicalMissingVariables,
              redactedVariables == canonicalRedactedVariables,
              (0...Self.maximumUnknownVariableCount).contains(unknownVariableCount) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Prompt render summary violates its content-free bounds."
                )
            )
        }

        self.usedVariables = usedVariables
        self.missingVariables = missingVariables
        self.redactedVariables = redactedVariables
        self.unknownVariableCount = unknownVariableCount
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usedVariables, forKey: .usedVariables)
        try container.encode(missingVariables, forKey: .missingVariables)
        try container.encode(redactedVariables, forKey: .redactedVariables)
        try container.encode(unknownVariableCount, forKey: .unknownVariableCount)
    }

    private static func orderedUnique(
        _ variables: [PromptVariableKey]
    ) -> [PromptVariableKey] {
        var seen: Set<PromptVariableKey> = []
        return variables.filter { seen.insert($0).inserted }
    }
}

public extension PromptVariableContext {
    func applying(_ decision: PrivacyPolicyDecision) -> PromptVariableContext {
        var context = self
        for variable in decision.redactedPromptVariables {
            switch variable {
            case .text:
                context.text = ""
            case .rawText:
                context.rawText = ""
            case .selected:
                context.selectedText = ""
            case .clipboard:
                context.clipboardText = ""
            case .app:
                context.applicationName = ""
            case .bundleID:
                context.bundleIdentifier = ""
            case .group:
                context.groupIdentifier = ""
            }
        }
        return context
    }
}

public enum PromptVariableRenderingError: Error, Sendable, Equatable {
    case templateTooLong
    case identifierTooLong
    case variableValueTooLong(PromptVariableKey)
    case tooManyUnknownVariables
    case renderedPromptTooLong
}

public enum PromptVariableRenderer {
    public static let maximumTemplateUTF8Count = 8_192
    public static let maximumIdentifierScalarCount = 64
    public static let maximumVariableValueUTF8Count = 32_768
    public static let maximumRenderedPromptUTF8Count = 65_536

    public static func render(
        prompt: String,
        context: PromptVariableContext,
        privacyDecision: PrivacyPolicyDecision? = nil
    ) throws -> PromptRenderResult {
        guard prompt.utf8.count <= maximumTemplateUTF8Count else {
            throw PromptVariableRenderingError.templateTooLong
        }
        let redactedVariables = privacyDecision?.redactedPromptVariables ?? []
        let context = privacyDecision.map { context.applying($0) } ?? context
        var rendered = ""
        rendered.reserveCapacity(prompt.utf8.count)
        var renderedUTF8Count = 0
        var usedVariables: [PromptVariableKey] = []
        var missingVariables: [PromptVariableKey] = []
        var unknownVariables: [String] = []
        var unknownVariableSet: Set<String> = []
        var variableName: String?
        var variableScalarCount = 0
        var cursor = prompt.unicodeScalars.startIndex

        func appendString(_ value: String) throws {
            let valueUTF8Count = value.utf8.count
            guard valueUTF8Count <= Self.maximumRenderedPromptUTF8Count,
                  renderedUTF8Count <= Self.maximumRenderedPromptUTF8Count - valueUTF8Count else {
                throw PromptVariableRenderingError.renderedPromptTooLong
            }
            rendered += value
            renderedUTF8Count += valueUTF8Count
        }

        func appendScalar(_ scalar: Unicode.Scalar) throws {
            let value = scalar.value
            let scalarUTF8Count: Int
            switch value {
            case 0...0x7F: scalarUTF8Count = 1
            case 0x80...0x7FF: scalarUTF8Count = 2
            case 0x800...0xFFFF: scalarUTF8Count = 3
            default: scalarUTF8Count = 4
            }
            guard renderedUTF8Count <= Self.maximumRenderedPromptUTF8Count - scalarUTF8Count else {
                throw PromptVariableRenderingError.renderedPromptTooLong
            }
            rendered.unicodeScalars.append(scalar)
            renderedUTF8Count += scalarUTF8Count
        }

        while cursor < prompt.unicodeScalars.endIndex {
            let scalar = prompt.unicodeScalars[cursor]
            let next = prompt.unicodeScalars.index(after: cursor)

            if var name = variableName {
                if scalar == "}" {
                    if name.isEmpty {
                        try appendString("{}")
                    } else if let key = PromptVariableKey(rawValue: name) {
                        appendUnique(key, to: &usedVariables)
                        let value = context.value(for: key)
                        guard value.utf8.count <= maximumVariableValueUTF8Count else {
                            throw PromptVariableRenderingError.variableValueTooLong(key)
                        }
                        if value.isEmpty {
                            appendUnique(key, to: &missingVariables)
                        }
                        try appendString(value)
                    } else {
                        if unknownVariableSet.insert(name).inserted {
                            guard unknownVariables.count < PromptRenderSummary.maximumUnknownVariableCount else {
                                throw PromptVariableRenderingError.tooManyUnknownVariables
                            }
                            unknownVariables.append(name)
                        }
                        try appendString("{\(name)}")
                    }
                    variableName = nil
                    variableScalarCount = 0
                    cursor = next
                    continue
                }

                let isValidScalar = name.isEmpty
                    ? isASCIILetter(scalar)
                    : isVariableContinuation(scalar)
                if isValidScalar {
                    variableScalarCount += 1
                    guard variableScalarCount <= maximumIdentifierScalarCount else {
                        throw PromptVariableRenderingError.identifierTooLong
                    }
                    name.unicodeScalars.append(scalar)
                    variableName = name
                    cursor = next
                    continue
                }

                try appendString("{\(name)")
                variableName = nil
                variableScalarCount = 0
                // Reprocess the invalid scalar as ordinary text so a nested
                // opening brace can still begin a valid variable.
                continue
            }

            if scalar == "{",
               next < prompt.unicodeScalars.endIndex,
               prompt.unicodeScalars[next] == "{" {
                try appendString("{")
                cursor = prompt.unicodeScalars.index(after: next)
                continue
            }

            if scalar == "}",
               next < prompt.unicodeScalars.endIndex,
               prompt.unicodeScalars[next] == "}" {
                try appendString("}")
                cursor = prompt.unicodeScalars.index(after: next)
                continue
            }

            if scalar == "{" {
                variableName = ""
                variableScalarCount = 0
                cursor = next
                continue
            }

            try appendScalar(scalar)
            cursor = next
        }

        if let variableName {
            try appendString("{\(variableName)")
        }

        return PromptRenderResult(
            renderedPrompt: rendered,
            usedVariables: usedVariables,
            missingVariables: missingVariables,
            redactedVariables: redactedVariables.filter { usedVariables.contains($0) },
            unknownVariables: unknownVariables
        )
    }

    private static func isVariableContinuation(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (scalar.value >= 48 && scalar.value <= 57) || scalar == "_"
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func appendUnique(_ key: PromptVariableKey, to keys: inout [PromptVariableKey]) {
        if !keys.contains(key) {
            keys.append(key)
        }
    }
}

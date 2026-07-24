import Foundation
import RillCore

public struct DeepgramHintDiagnosticReport: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case prerecorded
        case live
    }

    public enum Outcome: String, Sendable, Equatable {
        case noneRequested = "none-requested"
        case applied
        case partiallyApplied = "partially-applied"
        case unsupportedModel = "unsupported-model"
        case noValidKeyterms = "no-valid-keyterms"
    }

    public var source: Source
    public var outcome: Outcome
    public var count: Int
    public var omittedCount: Int

    public init(
        source: Source,
        outcome: Outcome,
        count: Int,
        omittedCount: Int
    ) {
        self.source = source
        self.outcome = outcome
        self.count = count
        self.omittedCount = omittedCount
    }
}

public typealias DeepgramHintDiagnosticReporter = @Sendable (DeepgramHintDiagnosticReport) async -> Void

struct DeepgramRequestPlan: Sendable, Equatable {
    let model: String
    let language: String?
    let keyterms: [String]
    let hintDiagnosticReport: DeepgramHintDiagnosticReport
}

enum DeepgramRequestPlanner {
    static let maximumKeytermCount = 50
    static let maximumKeytermScalarCount = 100
    static let maximumTotalKeytermScalarCount = 500

    private static let keytermModels: Set<String> = [
        "nova-3",
        "nova-3-general",
        "nova-3-medical",
    ]

    static func plan(
        options: SpeechRecognitionRequestOptions,
        workflow: WorkflowDefinition,
        configuration: DeepgramRecognizer.Configuration,
        source: DeepgramHintDiagnosticReport.Source
    ) -> DeepgramRequestPlan {
        let model = workflow.metadata[WorkflowMetadataKey.deepgramModelOverride]?.trimmedNonEmpty
            ?? configuration.model.trimmedNonEmpty
            ?? DeepgramRecognizer.Configuration().model
        let language = options.language?.trimmedNonEmpty
            ?? workflow.metadata[WorkflowMetadataKey.languageOverride]?.trimmedNonEmpty
            ?? configuration.language?.trimmedNonEmpty
        let requestedKeyterms = options.hints.keyterms

        guard !requestedKeyterms.isEmpty else {
            return DeepgramRequestPlan(
                model: model,
                language: language,
                keyterms: [],
                hintDiagnosticReport: DeepgramHintDiagnosticReport(
                    source: source,
                    outcome: .noneRequested,
                    count: 0,
                    omittedCount: 0
                )
            )
        }

        guard keytermModels.contains(model.lowercased()) else {
            return DeepgramRequestPlan(
                model: model,
                language: language,
                keyterms: [],
                hintDiagnosticReport: DeepgramHintDiagnosticReport(
                    source: source,
                    outcome: .unsupportedModel,
                    count: 0,
                    omittedCount: requestedKeyterms.count
                )
            )
        }

        var acceptedKeyterms: [String] = []
        var seenKeyterms: Set<String> = []
        var omittedCount = 0
        var acceptedScalarCount = 0

        for keyterm in requestedKeyterms {
            guard !keyterm.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                omittedCount += 1
                continue
            }
            guard let trimmedKeyterm = keyterm.trimmedNonEmpty else {
                omittedCount += 1
                continue
            }
            let scalarCount = trimmedKeyterm.unicodeScalars.count
            guard
                scalarCount <= maximumKeytermScalarCount,
                acceptedScalarCount + scalarCount <= maximumTotalKeytermScalarCount
            else {
                omittedCount += 1
                continue
            }
            guard seenKeyterms.insert(trimmedKeyterm).inserted else {
                omittedCount += 1
                continue
            }
            guard acceptedKeyterms.count < maximumKeytermCount else {
                omittedCount += 1
                continue
            }
            acceptedKeyterms.append(trimmedKeyterm)
            acceptedScalarCount += scalarCount
        }

        let outcome: DeepgramHintDiagnosticReport.Outcome
        if acceptedKeyterms.isEmpty {
            outcome = .noValidKeyterms
        } else if omittedCount > 0 {
            outcome = .partiallyApplied
        } else {
            outcome = .applied
        }

        return DeepgramRequestPlan(
            model: model,
            language: language,
            keyterms: acceptedKeyterms,
            hintDiagnosticReport: DeepgramHintDiagnosticReport(
                source: source,
                outcome: outcome,
                count: acceptedKeyterms.count,
                omittedCount: omittedCount
            )
        )
    }

    static func appendKeyterms(from plan: DeepgramRequestPlan, to queryItems: inout [URLQueryItem]) {
        queryItems.append(contentsOf: plan.keyterms.map { URLQueryItem(name: "keyterm", value: $0) })
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

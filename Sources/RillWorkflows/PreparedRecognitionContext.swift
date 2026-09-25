import Foundation
import RillCore

/// The capture and deferred final recognition share this value; no network work is awaited.
public struct PreparedRecognitionContext: Sendable {
  public let options: SpeechRecognitionRequestOptions
  public let plan: ResolvedWorkflowPlan
  public let hotwordPreparation: HotwordRankingPreparation?

  public init(options: SpeechRecognitionRequestOptions, plan: ResolvedWorkflowPlan,
    hotwordPreparation: HotwordRankingPreparation? = nil) {
    self.options = options
    self.plan = plan
    self.hotwordPreparation = hotwordPreparation
  }
}

public struct LiveRecognitionContextResolver: Sendable {
  private let compiler: WorkflowPlanCompiler
  private let collections: @Sendable () throws -> [VocabularyCollection]
  private let selection: HotwordSelection
  private let sanitize: @Sendable ([String]) -> [String]
  private let report: @Sendable (DiagnosticEvent) async -> Void

  public init(compiler: WorkflowPlanCompiler, collections: @escaping @Sendable () throws -> [VocabularyCollection],
    selection: HotwordSelection, sanitize: @escaping @Sendable ([String]) -> [String],
    report: @escaping @Sendable (DiagnosticEvent) async -> Void = { _ in }) {
    self.compiler = compiler
    self.collections = collections
    self.selection = selection
    self.sanitize = sanitize
    self.report = report
  }

  public func prepare(runID: UUID, workflow: WorkflowDefinition, context: ContextSnapshot,
    options: SpeechRecognitionRequestOptions, lifetime: AudioCaptureLifetime) async throws -> PreparedRecognitionContext {
    let vocabulary = workflow.plan.setup.vocabularyBindings.isEmpty ? [] : try collections()
    let scope = VocabularyRuleContext(contextSnapshot: context,
      recordCollectionID: workflow.legacyTargetRecordCollectionID,
      locale: options.language ?? workflow.plan.setup.speechRoute?.language
        ?? workflow.metadata[WorkflowMetadataKey.languageOverride])
    var plan = try compiler.compile(workflow: workflow, collections: vocabulary, context: scope)
    let candidates = plan.recognitionCandidates
    var frozenOptions = options
    var preparation: HotwordRankingPreparation?
    if plan.recognizerAcceptsHotwords, options.modelIdentifier != nil {
      let selected = (try? await selection.select(runID: runID, workflow: workflow, collections: vocabulary,
        context: context, options: options, candidates: candidates, lifetime: lifetime))
        ?? HotwordSelection.Selection(terms: plan.recognitionHints.keyterms, status: .unavailable, preparation: nil)
      plan.recognitionHints = RecognitionHints(keyterms: sanitize(selected.terms))
      preparation = selected.preparation
      await report(DiagnosticEvent(runID: runID, subsystem: .session, level: .debug,
        event: "hotword-ranking.selected", message: "Recognition hotwords frozen.",
        metadata: ["hotwordCache": selected.status.rawValue, "hotwordCandidateCount": String(candidates.count),
          "hotwordCount": String(plan.recognitionHints.keyterms.count)]))
    }
    frozenOptions.hints = plan.recognitionHints
    return PreparedRecognitionContext(options: frozenOptions, plan: plan, hotwordPreparation: preparation)
  }
}

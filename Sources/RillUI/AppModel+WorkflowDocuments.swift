import Foundation
import RillCore
import RillWorkflows
import RillRecords
import RillKnowledge
import RillSpeech

extension AppModel {
  func startWorkflowFileMonitoring() {
    guard self.workflowLibrary.workflowFileMonitorTask == nil, let workflowFileStore else { return }
    self.workflowLibrary.workflowFileMonitorTask = Task { @MainActor [weak self] in
      for await _ in await workflowFileStore.changes() {
        guard !Task.isCancelled, let self, !self.hasBegunApplicationShutdown else { return }
        await self.reloadWorkflowFiles()
      }
    }
  }

  public func workflowFileForEditing(_ workflow: WorkflowDefinition, duplicate: Bool = false) async -> URL? {
    guard !hasBegunApplicationShutdown, !self.settings.isLoading, isWorkflowLibraryAvailable,
      let workflowFileStore
    else { return nil }
    return await materializeWorkflowFile(workflow, duplicate: duplicate, store: workflowFileStore)
  }

  private func materializeWorkflowFile(_ workflow: WorkflowDefinition, duplicate: Bool = false, store workflowFileStore: any WorkflowFileStore) async -> URL? {
    if !duplicate, let fileURL = self.workflowLibrary.workflowFileURLsByID[workflow.id] { return fileURL }
    var definition = workflow
    definition.name = localizedWorkflowName(for: workflow)
    definition.titleKey = nil
    definition.properties.isBuiltin = false

    if duplicate {
      definition.id = UUID()
      definition.name += L10n.surface(.duplicateNameSuffix, language: self.settings.language)

      definition.properties.exclusiveGroup = nil
    }
    do {
      let document = WorkflowDocument(
        workflow: definition,
        isEnabled: duplicate ? false : isWorkflowEnabled(workflow)
      )
      let record = try await workflowFileStore.saveDocument(document, replacing: nil, expected: .missing)
      self.workflowLibrary.workflowFileURLsByID[definition.id] = record.fileURL
      self.workflowLibrary.workflowFileSourcesByID[definition.id] = record.source
      self.workflowLibrary.outputStatesByID[definition.id] = record.outputState
      self.workflowLibrary.outputStateSourcesByID[definition.id] = record.outputStateSource
      self.workflowLibrary.hasModifiedWorkflowLibrary = true
      await reloadWorkflowFiles()
      persistCustomWorkflows()
      return record.fileURL
    } catch {
      self.workflowLibrary.workflowLibraryErrorPresentation = { language in
        return L10n.workflowFileFailureDetail(error, language: language)
      }
      return nil
    }
  }

  public func isWorkflowOutputEnabled(_ action: OutputActionReference, index: Int, workflow: WorkflowDefinition) -> Bool {
    (workflowLibrary.outputStatesByID[workflow.id] ?? WorkflowOutputState(workflowID: workflow.id)).isEnabled(action, index: index)
  }

  public func setWorkflowOutputEnabled(_ enabled: Bool, action: OutputActionReference, index: Int, workflow: WorkflowDefinition) {
    guard action.optional, !hasBegunApplicationShutdown, let workflowFileStore,
      !workflowLibrary.savingOutputStates.contains(workflow.id),
      !workflowLibrary.invalidWorkflowFileIDs.contains(workflow.id)
    else { return }
    workflowLibrary.savingOutputStates.insert(workflow.id)
    let task = Task { [self] in
      await saveWorkflowOutputEnabled(enabled, action: action, index: index, workflow: workflow, store: workflowFileStore)
    }
    persistenceWrites.track(task)
  }

  private func saveWorkflowOutputEnabled(
    _ enabled: Bool, action: OutputActionReference, index: Int,
    workflow: WorkflowDefinition, store workflowFileStore: any WorkflowFileStore
  ) async {
    defer { workflowLibrary.savingOutputStates.remove(workflow.id) }
    guard let url = await materializeWorkflowFile(workflow, store: workflowFileStore) else { return }
    var state = workflowLibrary.outputStatesByID[workflow.id] ?? WorkflowOutputState(workflowID: workflow.id)
    state.outputs[action.documentID ?? "output-\(index + 1)"] = enabled
    do {
      let expected = workflowLibrary.outputStateSourcesByID[workflow.id].map(WorkflowFileExpectation.source) ?? .missing
      let documentSource: String
      if let source = workflowLibrary.workflowFileSourcesByID[workflow.id] {
        documentSource = source
      } else {
        documentSource = try await workflowFileStore.readSource(at: url)
      }
      _ = try await workflowFileStore.saveOutputState(state, for: url, expected: expected, expectedDocument: documentSource)
      await reloadWorkflowFiles()
    } catch {
      workflowLibrary.workflowLibraryErrorPresentation = { language in L10n.workflowFileFailureDetail(error, language: language) }
    }
  }

  func workflowApplyingOutputState(_ workflow: WorkflowDefinition) throws -> WorkflowDefinition {
    guard !workflowLibrary.invalidWorkflowFileIDs.contains(workflow.id) else {
      throw WorkflowDocumentError("state", "The workflow or output state is invalid.")
    }
    return try (workflowLibrary.outputStatesByID[workflow.id] ?? WorkflowOutputState(workflowID: workflow.id)).applying(to: workflow)
  }

  public func newWorkflowFile() async -> URL? {
    let workflow = WorkflowDefinition(
      name: L10n.surface(.newWorkflow, language: self.settings.language),
      trigger: .manual,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt, reasoning: .some(.none))
        ]),
        output: WorkflowOutputPhase(actions: [OutputActionReference(id: RecordActionID.systemClipboardCopy)])
      ),
      ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "blue")
    )
    self.workflowLibrary.workflowEnabledStates[workflow.id] = false
    return await workflowFileForEditing(workflow)
  }

  public func importWorkflowFile(from url: URL) async -> URL? {
    guard let workflowFileStore else { return nil }
    do {
      let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard properties.isRegularFile == true, properties.isSymbolicLink != true
      else {
        throw WorkflowFileStoreError.unsupportedFile
      }
      guard properties.fileSize ?? 0 <= 1_048_576 else { throw WorkflowFileStoreError.fileTooLarge }
      let document = try workflowFileStore.decodeDocument(String(contentsOf: url, encoding: .utf8))
      return await workflowFileForEditing(document.workflow, duplicate: true)
    } catch {
      self.workflowLibrary.workflowLibraryErrorPresentation = { language in
        return L10n.workflowFileFailureDetail(error, language: language)
      }
      return nil
    }
  }

  public func runWorkflowText(_ text: String, workflow saved: WorkflowDefinition) {
    guard !hasBegunApplicationShutdown, !self.settings.isLoading, !self.voice.isRunning, saved.inputKind != .record,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      isWorkflowEnabled(saved), !self.workflowLibrary.invalidWorkflowFileIDs.contains(saved.id),
      isWorkflowExecutionSupported(saved)
    else { return }
    guard var workflow = try? workflowApplyingOutputState(saved) else { return }
    workflow.declaredInputKind = .text
    workflow.plan = workflow.plan.acceptingTextInput()
    self.voice.isRunning = true
    self.voice.interactiveWorkflowTaskGeneration += 1
    let generation = self.voice.interactiveWorkflowTaskGeneration
    self.voice.pendingInteractiveWorkflowTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.finishInteractiveWorkflowTask(generation: generation) }
      do {
        try Task.checkCancellation()
        let authorization = try await self.authorizeWorkflowRunAction(workflow)
        try Task.checkCancellation()
        await self.sessionCoordinator.runRecognizedText(text, authorizedContext: authorization)
      } catch is CancellationError {
        self.voice.isRunning = false
      } catch {
        self.voice.isRunning = false
        self.lastFailureResource = L10n.modelServiceFailure(error) ?? L10n.resource("surface.theWorkflowCouldNotFinish")
      }
    }
  }
}

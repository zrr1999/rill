import Foundation
import RillCore

extension AppModel {
    func startWorkflowFileMonitoring() {
        guard workflowFileMonitorTask == nil, let workflowFileStore else { return }
        workflowFileMonitorTask = Task { @MainActor [weak self] in
            for await _ in await workflowFileStore.changes() {
                guard !Task.isCancelled, let self, !self.hasBegunApplicationShutdown else { return }
                await self.reloadWorkflowFiles()
            }
        }
    }

    public func workflowFileForEditing(_ workflow: WorkflowDefinition, duplicate: Bool = false) async -> URL? {
        guard !hasBegunApplicationShutdown, !isLoadingSettings, isWorkflowLibraryAvailable,
            let workflowFileStore else { return nil }
        if !duplicate, let fileURL = workflowFileURLsByID[workflow.id] { return fileURL }
        guard usesWorkflowFilesAsSource || customWorkflows.isEmpty else {
            workflowLibraryError = language == .simplifiedChinese
                ? "旧工作流尚未完成 TOML 迁移。请修复工作流目录并重新启动，再创建或打开文件；现有工作流已保留。"
                : "The legacy workflow library has not migrated to TOML. Repair the workflow directory and restart before creating or opening a file; existing workflows are preserved."
            return nil
        }
        var definition = workflow
        definition.name = localizedWorkflowName(for: workflow)
        definition.titleKey = nil
        definition.metadata.removeValue(forKey: WorkflowMetadataKey.catalog)
        definition.metadata["workflow.origin"] = "user"
        if duplicate {
            definition.id = UUID()
            definition.name += language == .simplifiedChinese ? " 副本" : " Copy"
            definition.metadata.removeValue(forKey: WorkflowMetadataKey.builtinKind)
            definition.metadata.removeValue(forKey: WorkflowMetadataKey.exclusiveGroup)
        }
        do {
            let document = WorkflowDocument(
                workflow: definition,
                isEnabled: duplicate ? false : isWorkflowEnabled(workflow)
            )
            let record = try await workflowFileStore.saveDocument(document, replacing: nil, expected: .missing)
            usesWorkflowFilesAsSource = true
            hasModifiedWorkflowLibrary = true
            await reloadWorkflowFiles()
            persistCustomWorkflows()
            return record.fileURL
        } catch {
            workflowLibraryError = error.localizedDescription
            return nil
        }
    }

    public func newWorkflowFile() async -> URL? {
        let workflow = WorkflowDefinition(
            name: language == .simplifiedChinese ? "新工作流" : "New workflow",
            trigger: .manual,
            plan: WorkflowPlan(
                setup: WorkflowSetupPhase(),
                process: WorkflowProcessPhase(steps: [
                    WorkflowProcessStep(kind: .llmRewrite, prompt: LLMTextProcessing.cleanupPrompt)
                ]),
                output: WorkflowOutputPhase(actions: [OutputActionReference(id: RecordActionID.systemClipboardCopy)])
            ),
            ui: WorkflowUIConfig(symbolName: "sparkles", accentColorName: "blue")
        )
        workflowEnabledStates[workflow.id] = false
        return await workflowFileForEditing(workflow)
    }

    public func importWorkflowFile(from url: URL) async -> URL? {
        guard let workflowFileStore else { return nil }
        do {
            let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                properties.fileSize ?? 0 <= 1_048_576 else {
                throw WorkflowDocumentError("import", "Choose a regular TOML file of at most 1 MiB.")
            }
            let document = try workflowFileStore.decodeDocument(String(contentsOf: url, encoding: .utf8))
            return await workflowFileForEditing(document.workflow, duplicate: true)
        } catch {
            workflowLibraryError = error.localizedDescription
            return nil
        }
    }

    public func runWorkflowText(_ text: String, workflow saved: WorkflowDefinition) {
        guard !hasBegunApplicationShutdown, !isLoadingSettings, !isRunning,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isWorkflowEnabled(saved), !invalidWorkflowFileIDs.contains(saved.id),
            isWorkflowExecutionSupported(saved) else { return }
        var workflow = saved
        workflow.declaredInputKind = .text
        workflow.plan = workflow.plan.acceptingTextInput()
        isRunning = true
        interactiveWorkflowTaskGeneration += 1
        let generation = interactiveWorkflowTaskGeneration
        pendingInteractiveWorkflowTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishInteractiveWorkflowTask(generation: generation) }
            do {
                try Task.checkCancellation()
                try await self.persistProviderSettingsForRun(workflow)
                let authorization = try await self.authorizeWorkflowRunAction(workflow)
                try Task.checkCancellation()
                await self.sessionCoordinator.runRecognizedText(text, authorizedContext: authorization)
            } catch is CancellationError {
                self.isRunning = false
            } catch {
                self.isRunning = false
                self.lastFailure = self.language == .simplifiedChinese
                    ? "工作流未能完成，请检查隐私和服务商设置。"
                    : "The workflow could not finish. Review Privacy and provider settings."
            }
        }
    }
}

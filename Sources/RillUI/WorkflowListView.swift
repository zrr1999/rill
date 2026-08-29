import SwiftUI
import RillCore

extension WorkflowsView {
    func workflowListSection(
        title: String,
        emptyTitle: String?,
        workflows: [WorkflowDefinition],
        isCustom: Bool,
        localizedWorkflowNames: [UUID: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if workflows.isEmpty, let emptyTitle {
                Text(emptyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(workflows) { workflow in
                        workflowRow(
                            workflow,
                            isCustom: isCustom,
                            localizedWorkflowNames: localizedWorkflowNames
                        )
                    }
                }
            }
        }
    }

    func workflowRow(
        _ workflow: WorkflowDefinition,
        isCustom: Bool,
        localizedWorkflowNames: [UUID: String]
    ) -> some View {
        let isSelected = selectedWorkflowID == workflow.id
        let conflictingWorkflowNames = (model.workflowConflictIDsByWorkflowID[workflow.id] ?? [])
            .compactMap { localizedWorkflowNames[$0] }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                workflowEditButton(workflow, isSelected: isSelected, isCustom: isCustom)
                workflowRowControls(workflow, isCustom: isCustom)
            }

            if !conflictingWorkflowNames.isEmpty {
                workflowConflictNotice(workflow, conflictingNames: conflictingWorkflowNames)
            }
        }
        .padding(14)
        .rillSelection(isSelected)
    }

    private func workflowEditButton(
        _ workflow: WorkflowDefinition,
        isSelected: Bool,
        isCustom: Bool
    ) -> some View {
        Button {
            beginEditing(workflow)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: RillSystemSymbol.resolvedName(workflow.ui.symbolName)
                )
                    .font(.title3)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(model.localizedWorkflowName(for: workflow))
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        if isSelected {
                            badge(
                                UIStrings.text(.workflowSelected, language: model.language),
                                tint: .accentColor
                            )
                        }
                    }

                    Text(VoiceWorkflowPresentation(workflow: workflow).detail(language: model.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        badge(
                            isCustom
                                ? UIStrings.text(.workflowCustom, language: model.language)
                                : UIStrings.text(.workflowBuiltIn, language: model.language),
                            tint: isCustom ? .accentColor : .secondary
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            UIStrings.targetedAccessibilityLabel(
                .workflowEdit,
                target: model.localizedWorkflowName(for: workflow),
                language: model.language
            )
        )
        .accessibilityValue(
            Text(workflowRowAccessibilityValue(isSelected: isSelected, isCustom: isCustom))
        )
        .accessibilityIdentifier("workflow.edit.\(workflow.id.uuidString)")
    }

    private func workflowRowControls(
        _ workflow: WorkflowDefinition,
        isCustom: Bool
    ) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Toggle(
                UIStrings.targetedAccessibilityLabel(
                    .workflowEnabled,
                    target: model.localizedWorkflowName(for: workflow),
                    language: model.language
                ),
                isOn: enabledBinding(for: workflow)
            )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)
                .accessibilityIdentifier("workflow.enabled.\(workflow.id.uuidString)")

            if isCustom {
                Button(role: .destructive) {
                    pendingWorkflowDeletion = workflow
                } label: {
                    Image(systemName: RillSystemSymbol.trash.rawValue)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)
                .accessibilityLabel(
                    UIStrings.targetedAccessibilityLabel(
                        .workflowDelete,
                        target: model.localizedWorkflowName(for: workflow),
                        language: model.language
                    )
                )
                .accessibilityIdentifier("workflow.delete.\(workflow.id.uuidString)")
            }
        }
    }

    private func workflowConflictNotice(
        _ workflow: WorkflowDefinition,
        conflictingNames: [String]
    ) -> some View {
        Label(
            UIStrings.workflowConflict(
                trigger: workflow.trigger,
                names: conflictingNames,
                language: model.language
            ),
            systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private func workflowRowAccessibilityValue(isSelected: Bool, isCustom: Bool) -> String {
        var values: [String] = []
        if isSelected {
            values.append(UIStrings.text(.workflowSelected, language: model.language))
        }
        values.append(
            UIStrings.text(isCustom ? .workflowCustom : .workflowBuiltIn, language: model.language)
        )
        return values.joined(separator: model.language == .english ? ", " : "，")
    }

    func deleteCustomWorkflow(_ workflow: WorkflowDefinition) {
        Task { @MainActor in
            await model.deleteCustomWorkflow(workflow)
            guard !model.customWorkflows.contains(where: { $0.id == workflow.id }) else {
                return
            }
            if selectedWorkflowID == workflow.id || editingWorkflowID == workflow.id {
                resetDraft()
            }
        }
    }
}

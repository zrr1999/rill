import AppKit
import SwiftUI
import RillCore

extension ClipboardView {
    var routingWorkspace: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 300),
                        spacing: ClipboardViewMetrics.splitSpacing,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: ClipboardViewMetrics.splitSpacing
            ) {
                groupsPanel
                appAssignmentsPanel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var groupsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(UIStrings.text(.clipboardGroups, language: model.language))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(UIStrings.stackCountSummary(displayedRoutingGroupSummaries.count, language: model.language))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(displayedRoutingGroupSummaries) { summary in
                    groupCard(summary)
                }
            }
        }
        .padding(ClipboardViewMetrics.cardPadding)
        .clipboardPanelCard()
    }

    func groupCard(_ summary: ClipboardGroupSummary) -> some View {
        let previewItems = groupPreviewItems(for: summary)
        let remainingCount = max(summary.count - previewItems.count, 0)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(groupName(for: summary.group.id))
                        .font(.callout.weight(.medium))
                    metadataPill(UIStrings.stackCountSummary(summary.count, language: model.language), tint: .secondary)
                }

                Spacer()

                Picker(
                    UIStrings.targetedAccessibilityLabel(
                        .clipboardPasteMode,
                        target: groupName(for: summary.group.id),
                        language: model.language
                    ),
                    selection: Binding(
                        get: { summary.group.mode },
                        set: { model.setClipboardMode($0, forGroup: summary.group.id) }
                    )
                ) {
                    ForEach(ClipboardPasteMode.allCases, id: \.self) { mode in
                        Text(UIStrings.clipboardMode(mode, language: model.language)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            if !isDefaultFallbackSummary(summary) {
                Toggle(
                    UIStrings.text(.clipboardCrossGroupFallback, language: model.language),
                    isOn: Binding(
                        get: { summary.group.allowsCrossGroupPaste },
                        set: { model.setClipboardAllowsCrossGroupPaste($0, forGroup: summary.group.id) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(UIStrings.text(.clipboardCrossGroupFallbackHint, language: model.language))
            }

            if summary.group.id == ClipboardGroup.voiceGroupID,
               let subtitle = model.liveSubtitleSnapshot,
               subtitle.isVisible,
               !subtitle.prefersCompactLayout {
                streamingSTTPreview(subtitle)
            }

            if previewItems.isEmpty {
                Text(summary.previewText ?? UIStrings.text(.clipboardGroupPreviewEmpty, language: model.language))
                    .font(.caption)
                    .foregroundStyle(summary.previewText == nil ? .tertiary : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(previewItems.enumerated()), id: \.element.id) { index, item in
                        groupPreviewRow(item, position: index + 1)
                    }

                    if remainingCount > 0 {
                        Text("+\(remainingCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func groupPreviewItems(for summary: ClipboardGroupSummary) -> [ClipboardHistoryItem] {
        let itemsByID = Dictionary(uniqueKeysWithValues: model.clipboardItems.map { ($0.id, $0) })
        return summary.previewItemIDs.compactMap { itemsByID[$0] }
    }

    func groupPreviewRow(_ item: ClipboardHistoryItem, position: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(position).")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .leading)

            thumbnail(for: item, size: 26)

            Text(primaryText(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func streamingSTTPreview(_ snapshot: LiveSubtitleSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VoiceActivityIndicator(
                levelMeter: snapshot.levelMeter,
                isActive: snapshot.phase == .transcribing ||
                    snapshot.phase == .recording ||
                    snapshot.phase == .listening ||
                    snapshot.phase == .preparing,
                accentColor: .primary,
                barCount: 8,
                barWidth: 3,
                minHeight: 5,
                maxHeight: 18
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    model.language == .english
                        ? "Live: \(streamingPhaseLabel(snapshot.phase))"
                        : "实时：\(streamingPhaseLabel(snapshot.phase))"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)

                if !snapshot.displayText.isEmpty {
                    (
                        Text(snapshot.confirmedText.trimmingCharacters(in: .whitespacesAndNewlines))
                            .foregroundStyle(.primary)
                        + Text(" ").foregroundStyle(.primary)
                        + Text(snapshot.hypothesisText.trimmingCharacters(in: .whitespacesAndNewlines))
                            .foregroundStyle(.secondary.opacity(0.6))
                    )
                    .font(.caption)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.12))
        )
    }

    func streamingPhaseLabel(_ phase: LiveSubtitlePhase) -> String {
        switch phase {
        case .hidden:
            return model.language == .english ? "Hidden" : "已隐藏"
        case .preparing:
            return model.language == .english ? "Preparing…" : "准备中…"
        case .recording, .listening:
            return model.language == .english ? "Listening…" : "聆听中…"
        case .transcribing:
            return model.language == .english ? "Transcribing…" : "转写中…"
        case .finalizing:
            return model.language == .english ? "Finalizing…" : "收尾中…"
        case .processing:
            return model.language == .english ? "Processing…" : "处理中…"
        case .failed:
            return model.language == .english ? "Unavailable" : "不可用"
        }
    }

    var appAssignmentsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(UIStrings.text(.clipboardAppAssignments, language: model.language))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(UIStrings.stackCountSummary(model.clipboardAppAssignments.count, language: model.language))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.clipboardAppAssignments.isEmpty {
                Text(UIStrings.text(.clipboardAppAssignmentsEmpty, language: model.language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.clipboardAppAssignments) { assignment in
                        appAssignmentRow(assignment)
                    }
                }
            }
        }
        .padding(ClipboardViewMetrics.cardPadding)
        .clipboardPanelCard()
    }

    func appAssignmentRow(_ assignment: ClipboardAppAssignment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(assignment.applicationName)
                        .font(.callout.weight(.medium))
                    Text(assignment.bundleIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Picker(
                    UIStrings.text(.clipboardAssignedGroup, language: model.language),
                    selection: Binding(
                        get: { assignment.groupID },
                        set: { model.assignApplication(assignment, toGroup: $0) }
                    )
                ) {
                    Text(UIStrings.text(.clipboardDefaultGroup, language: model.language))
                        .tag(Optional<UUID>.none)
                    ForEach(model.clipboardGroups) { group in
                        Text(group.group.name).tag(Optional(group.group.id))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            if allowsSheetPresentation {
                Button {
                    pendingGroupAssignment = assignment
                    newGroupName = assignment.applicationName
                    presentedSheet = .createGroup(UUID())
                } label: {
                    Label(UIStrings.text(.clipboardCreateGroup, language: model.language), systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var createGroupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(UIStrings.text(.clipboardCreateGroup, language: model.language))
                .font(.title3.weight(.semibold))
            TextField(
                UIStrings.text(.clipboardNewGroupName, language: model.language),
                text: $newGroupName
            )
            HStack {
                Spacer()
                Button(UIStrings.text(.dismiss, language: model.language)) {
                    pendingGroupAssignment = nil
                    presentedSheet = nil
                }
                Button(UIStrings.text(.clipboardCreate, language: model.language)) {
                    model.createClipboardGroup(
                        named: newGroupName,
                        assigning: pendingGroupAssignment
                    )
                    pendingGroupAssignment = nil
                    presentedSheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

}

import AppKit
import SwiftUI
import VoxTypeCore

private struct WorkflowMenuOption: Identifiable {
    let workflow: WorkflowDefinition
    let title: String

    var id: UUID { workflow.id }
}

private enum ClipboardPanelSection: String, CaseIterable, Identifiable {
    case history
    case routing

    var id: String { rawValue }

    var titleKey: UIStrings.Key {
        switch self {
        case .history:
            return .clipboardHistory
        case .routing:
            return .clipboardRouting
        }
    }
}

private enum ClipboardViewMetrics {
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let splitSpacing: CGFloat = 12
    static let outerPadding: CGFloat = 16
    static let thumbnailSize: CGFloat = 40
    static let detailThumbnailSize: CGFloat = 48
    static let detailPreviewMaxHeight: CGFloat = 280
    static let fileIconSize: CGFloat = 32
    static let rowPadding: CGFloat = 10
    static let rowCornerRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 6
}

public struct ClipboardView: View {
    @Bindable private var model: AppModel
    @State private var isPresentingCreateGroupSheet = false
    @State private var newGroupName = ""
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var selectedSection: ClipboardPanelSection = .history
    @State private var selectedEntryID: UUID?
    @State private var hoveredEntryID: UUID?
    @FocusState private var isSearchFieldFocused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        mainContent
            .sheet(isPresented: $isPresentingCreateGroupSheet) {
                createGroupSheet
            }
            .onChange(of: searchText) { _, newValue in
                scheduleSearchDebounce(for: newValue)
            }
            .onChange(of: filteredClipboardEntryIDs) { _, _ in
                syncSelectedEntry()
            }
            .onChange(of: selectedSection) { _, newValue in
                guard newValue == .history else {
                    isSearchFieldFocused = false
                    return
                }
                syncSelectedEntry()
                scheduleSearchFocusIfNeeded()
            }
            .onAppear {
                syncSelectedEntry()
                scheduleSearchFocusIfNeeded()
            }
            .onDisappear {
                searchDebounceTask?.cancel()
            }
            .onKeyPress(.upArrow) { navigateList(direction: -1) }
            .onKeyPress(.downArrow) { navigateList(direction: 1) }
            .onKeyPress(.return) { pasteSelectedItem() }
            .onKeyPress(.delete) { deleteSelectedItem() }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, ClipboardViewMetrics.outerPadding)
                .padding(.top, ClipboardViewMetrics.outerPadding)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, ClipboardViewMetrics.outerPadding)

            compactTabBar
                .padding(.horizontal, ClipboardViewMetrics.outerPadding)
                .padding(.vertical, 8)

            Group {
                switch selectedSection {
                case .history:
                    historyWorkspace
                case .routing:
                    routingWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, ClipboardViewMetrics.outerPadding)
            .padding(.bottom, ClipboardViewMetrics.outerPadding)
        }
    }

    // MARK: - Keyboard Navigation

    private func navigateList(direction: Int) -> KeyPress.Result {
        guard selectedSection == .history else { return .ignored }
        let entries = filteredClipboardEntries
        guard !entries.isEmpty else { return .ignored }

        let currentIndex = entries.firstIndex(where: { $0.id == selectedEntryID })
        let newIndex: Int
        if let currentIndex {
            newIndex = min(max(currentIndex + direction, 0), entries.count - 1)
        } else {
            newIndex = direction > 0 ? 0 : entries.count - 1
        }
        selectedEntryID = entries[newIndex].id
        return .handled
    }

    private func pasteSelectedItem() -> KeyPress.Result {
        guard selectedSection == .history,
              let selectedEntry,
              selectedEntry.representativeItem.supportsDirectPaste else {
            return .ignored
        }
        model.useClipboardItem(selectedEntry.representativeItem)
        return .handled
    }

    private func deleteSelectedItem() -> KeyPress.Result {
        guard selectedSection == .history, let selectedEntry else { return .ignored }
        model.deleteClipboardHistoryEntry(selectedEntry)
        return .handled
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField(
                UIStrings.text(.clipboardSearch, language: model.language),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($isSearchFieldFocused)
            .onSubmit {
                _ = pasteSelectedItem()
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var compactTabBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $selectedSection) {
                ForEach(ClipboardPanelSection.allCases) { section in
                    Text(UIStrings.text(section.titleKey, language: model.language)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            Spacer()

            if selectedSection == .history {
                Toggle(
                    UIStrings.text(.clipboardMergeSimilar, language: model.language),
                    isOn: $model.mergeSimilarClipboardItems
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(UIStrings.text(.clipboardMergeSimilarHint, language: model.language))

                Text(UIStrings.stackCountSummary(filteredClipboardEntries.count, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button(UIStrings.text(.clipboardCreateGroup, language: model.language)) {
                    newGroupName = ""
                    isPresentingCreateGroupSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - History

    private var historyWorkspace: some View {
        Group {
            if filteredClipboardEntries.isEmpty {
                emptyStateCard(
                    systemImage: "doc.on.clipboard",
                    title: UIStrings.text(.clipboardHistory, language: model.language),
                    message: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? UIStrings.text(.clipboardEmpty, language: model.language)
                        : UIStrings.text(.clipboardNoResults, language: model.language)
                )
            } else {
                HStack(alignment: .top, spacing: ClipboardViewMetrics.splitSpacing) {
                    historyListCard
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    detailCard
                        .frame(minWidth: 280, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var historyListCard: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredClipboardEntries) { entry in
                    historyListRow(entry)
                }
            }
            .padding(6)
        }
        .clipboardPanelCard()
    }

    private var detailCard: some View {
        Group {
            if let selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailHeader(for: selectedEntry)
                        actionBar(for: selectedEntry)
                        detailPreviewCard(for: selectedEntry.representativeItem)
                        detailMetadata(for: selectedEntry)

                        if !selectedEntry.alternatives.isEmpty {
                            detailChipSection(
                                title: UIStrings.text(.clipboardAlternatives, language: model.language),
                                values: selectedEntry.alternatives,
                                tint: .orange
                            )
                        }

                        if !selectedEntry.tags.isEmpty {
                            detailChipSection(
                                title: UIStrings.text(.clipboardTags, language: model.language),
                                values: selectedEntry.tags,
                                tint: .blue
                            )
                        }

                        if let latestError = selectedEntry.representativeItem.latestError {
                            Label(latestError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(ClipboardViewMetrics.cardPadding)
                }
            } else {
                emptyStateCard(
                    systemImage: "cursorarrow.rays",
                    title: UIStrings.text(.clipboardHistory, language: model.language),
                    message: UIStrings.text(.clipboardSelectItem, language: model.language)
                )
            }
        }
        .clipboardPanelCard()
    }

    // MARK: - History List Row

    private func historyListRow(_ entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem
        let isSelected = selectedEntryID == entry.id
        let isHovered = hoveredEntryID == entry.id

        return HStack(alignment: .top, spacing: 10) {
            thumbnail(for: item, size: ClipboardViewMetrics.thumbnailSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText(for: item))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(compactSourceLabel(for: item))
                    Text("·")
                    Text(item.createdAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                if entry.isMerged || entry.pasteCount > 0 || entry.includesSimilarText {
                    HStack(spacing: 4) {
                        metadataPill(groupName(for: item.groupID), tint: .green)

                        if entry.isMerged {
                            metadataPill("\(entry.copyCount)", systemImage: "doc.on.doc", tint: .orange)
                        }

                        if entry.pasteCount > 0 {
                            metadataPill("\(entry.pasteCount)", systemImage: "arrowshape.turn.up.right", tint: .blue)
                        }

                        if entry.includesSimilarText {
                            metadataPill(
                                UIStrings.text(.clipboardMergedSimilarBadge, language: model.language),
                                tint: .purple
                            )
                        }
                    }
                } else {
                    metadataPill(groupName(for: item.groupID), tint: .green)
                }
            }

            Spacer(minLength: 4)

            if item.latestError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(ClipboardViewMetrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            rowBackground(isSelected: isSelected, isHovered: isHovered),
            in: RoundedRectangle(cornerRadius: ClipboardViewMetrics.rowCornerRadius, style: .continuous)
        )
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: ClipboardViewMetrics.rowCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                : nil
        )
        .contentShape(RoundedRectangle(cornerRadius: ClipboardViewMetrics.rowCornerRadius, style: .continuous))
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : nil
        }
        .contextMenu {
            itemContextMenu(for: entry)
        }
        .onTapGesture {
            selectedEntryID = entry.id
        }
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        } else if isHovered {
            return Color.secondary.opacity(0.08)
        } else {
            return Color.clear
        }
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private func detailHeader(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        HStack(alignment: .top, spacing: 12) {
            thumbnail(for: item, size: ClipboardViewMetrics.detailThumbnailSize)

            VStack(alignment: .leading, spacing: 6) {
                Text(primaryText(for: item))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(sourceTitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func actionBar(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        return HStack(spacing: 8) {
            if item.supportsDirectPaste {
                Button {
                    model.useClipboardItem(item)
                } label: {
                    Label(UIStrings.text(.clipboardUseItem, language: model.language), systemImage: "arrowshape.turn.up.right.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if item.supportsWorkflowReplay {
                Menu {
                    workflowMenuButtons(for: item, replacingSourceItem: false)
                } label: {
                    actionMenuLabel(
                        UIStrings.text(.clipboardReplayWithWorkflow, language: model.language),
                        systemImage: "wand.and.stars"
                    )
                }

                Menu {
                    workflowMenuButtons(for: item, replacingSourceItem: true)
                } label: {
                    actionMenuLabel(
                        UIStrings.text(.clipboardReplaceWithWorkflow, language: model.language),
                        systemImage: "square.and.pencil"
                    )
                }
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                model.deleteClipboardHistoryEntry(entry)
            } label: {
                Label(UIStrings.text(.clipboardDeleteItem, language: model.language), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailPreviewCard(for item: ClipboardHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailPreview(for: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailMetadata(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        return VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    metadataPill(groupName(for: item.groupID), systemImage: "square.stack.3d.up", tint: .green)
                    metadataPill(tint: .secondary, systemImage: "clock") {
                        Text(item.createdAt, style: .relative)
                    }

                    if entry.isMerged {
                        metadataPill("\(entry.copyCount)", systemImage: "doc.on.doc", tint: .orange)
                    }

                    if entry.pasteCount > 0 {
                        metadataPill("\(entry.pasteCount)", systemImage: "arrowshape.turn.up.right", tint: .blue)
                    }

                    if let lastUsedAt = entry.lastUsedAt {
                        metadataPill(tint: .secondary, systemImage: "clock.arrow.circlepath") {
                            Text(lastUsedAt, style: .relative)
                        }
                    }

                    if entry.includesSimilarText {
                        metadataPill(
                            UIStrings.text(.clipboardMergedSimilarBadge, language: model.language),
                            tint: .purple
                        )
                    }
                }
            }
        }
    }

    private func detailChipSection(title: String, values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(tint)
                    }
                }
            }
        }
    }

    private var routingWorkspace: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: ClipboardViewMetrics.splitSpacing, alignment: .top)],
                alignment: .leading,
                spacing: ClipboardViewMetrics.splitSpacing
            ) {
                groupsPanel
                appAssignmentsPanel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var groupsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(UIStrings.text(.clipboardGroups, language: model.language))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(UIStrings.stackCountSummary(model.clipboardGroups.count, language: model.language))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.clipboardGroups.isEmpty {
                Text(UIStrings.text(.clipboardGroupsEmpty, language: model.language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.clipboardGroups) { summary in
                        groupCard(summary)
                    }
                }
            }
        }
        .padding(ClipboardViewMetrics.cardPadding)
        .clipboardPanelCard()
    }

    private func groupCard(_ summary: ClipboardGroupSummary) -> some View {
        let previewItems = groupPreviewItems(for: summary)
        let remainingCount = max(summary.count - previewItems.count, 0)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.group.name)
                        .font(.callout.weight(.medium))
                    metadataPill(UIStrings.stackCountSummary(summary.count, language: model.language), tint: .secondary)
                }

                Spacer()

                Picker("", selection: Binding(
                    get: { summary.group.mode },
                    set: { model.setClipboardMode($0, forGroup: summary.group.id) }
                )) {
                    ForEach(ClipboardPasteMode.allCases, id: \.self) { mode in
                        Text(UIStrings.clipboardMode(mode, language: model.language)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
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

    private func groupPreviewItems(for summary: ClipboardGroupSummary) -> [ClipboardHistoryItem] {
        let itemsByID = Dictionary(uniqueKeysWithValues: model.clipboardItems.map { ($0.id, $0) })
        return summary.previewItemIDs.compactMap { itemsByID[$0] }
    }

    private func groupPreviewRow(_ item: ClipboardHistoryItem, position: Int) -> some View {
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

    private var appAssignmentsPanel: some View {
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

    private func appAssignmentRow(_ assignment: ClipboardAppAssignment) -> some View {
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
                    ForEach(model.clipboardGroups) { group in
                        Text(group.group.name).tag(group.group.id)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            Button {
                newGroupName = assignment.applicationName
                isPresentingCreateGroupSheet = true
            } label: {
                Label(UIStrings.text(.clipboardCreateGroup, language: model.language), systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var createGroupSheet: some View {
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
                    isPresentingCreateGroupSheet = false
                }
                Button(UIStrings.text(.clipboardCreate, language: model.language)) {
                    model.createClipboardGroup(named: newGroupName)
                    isPresentingCreateGroupSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var workflowMenuOptions: [WorkflowMenuOption] {
        model.workflows.map { workflow in
            WorkflowMenuOption(
                workflow: workflow,
                title: model.localizedWorkflowName(for: workflow)
            )
        }
    }

    private var clipboardGroupNamesByID: [UUID: String] {
        Dictionary(uniqueKeysWithValues: model.clipboardGroups.map { ($0.group.id, $0.group.name) })
    }

    private var filteredClipboardEntries: [ClipboardHistoryEntry] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.clipboardHistoryEntries }

        return model.clipboardHistoryEntries.filter { entry in
            entry.matchesSearchQuery(query, groupName: groupName(for: entry.representativeItem.groupID))
        }
    }

    private var filteredClipboardEntryIDs: [UUID] {
        filteredClipboardEntries.map(\.id)
    }

    private var selectedEntry: ClipboardHistoryEntry? {
        guard let selectedEntryID else { return nil }
        return filteredClipboardEntries.first(where: { $0.id == selectedEntryID })
    }

    private func scheduleSearchDebounce(for query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                await MainActor.run {
                    debouncedSearchText = query
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    debouncedSearchText = query
                }
            }
        }
    }

    private func syncSelectedEntry() {
        guard selectedSection == .history else { return }
        guard !filteredClipboardEntries.isEmpty else {
            selectedEntryID = nil
            return
        }

        if let selectedEntryID, filteredClipboardEntries.contains(where: { $0.id == selectedEntryID }) {
            return
        }

        self.selectedEntryID = filteredClipboardEntries.first?.id
    }

    private func scheduleSearchFocusIfNeeded() {
        guard selectedSection == .history else {
            isSearchFieldFocused = false
            return
        }

        Task { @MainActor in
            await Task.yield()
            isSearchFieldFocused = true
        }
    }

    private func actionMenuLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.18), in: Capsule())
    }

    private func emptyStateCard(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .clipboardPanelCard()
    }

    @ViewBuilder
    private func itemContextMenu(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        if item.supportsDirectPaste {
            Button {
                model.useClipboardItem(item)
            } label: {
                Label(UIStrings.text(.clipboardUseItem, language: model.language), systemImage: "arrowshape.turn.up.right")
            }
        }

        if item.supportsWorkflowReplay {
            Menu(UIStrings.text(.clipboardReplayWithWorkflow, language: model.language)) {
                workflowMenuButtons(for: item, replacingSourceItem: false)
            }

            Menu(UIStrings.text(.clipboardReplaceWithWorkflow, language: model.language)) {
                workflowMenuButtons(for: item, replacingSourceItem: true)
            }
        }

        Button(role: .destructive) {
            model.deleteClipboardHistoryEntry(entry)
        } label: {
            Label(UIStrings.text(.clipboardDeleteItem, language: model.language), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func workflowMenuButtons(for item: ClipboardHistoryItem, replacingSourceItem: Bool) -> some View {
        ForEach(workflowMenuOptions) { option in
            Button(option.title) {
                model.replayClipboardItem(item, with: option.workflow, replacingSourceItem: replacingSourceItem)
            }
        }
    }

    private func metadataPill(_ text: String, systemImage: String? = nil, tint: Color) -> some View {
        metadataPill(tint: tint, systemImage: systemImage) {
            Text(text)
        }
    }

    private func metadataPill<Content: View>(
        tint: Color,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            content()
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .foregroundStyle(tint)
    }

    @ViewBuilder
    private func thumbnail(for item: ClipboardHistoryItem, size: CGFloat) -> some View {
        if item.contentKind == .image,
           let imagePNGData = item.imagePNGData,
           let nsImage = NSImage(data: imagePNGData) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if item.contentKind == .files,
                  item.fileURLs.count == 1,
                  let fileIcon = fileIcon(for: item.fileURLs[0]) {
            Image(nsImage: fileIcon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(thumbnailTint(for: item).opacity(0.12))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: icon(for: item))
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(thumbnailTint(for: item))
                }
        }
    }

    private func thumbnailTint(for item: ClipboardHistoryItem) -> Color {
        switch item.sourceKind {
        case .system:
            return item.contentKind == .files ? .orange : .blue
        case .voxtypeWorkflow:
            return .purple
        }
    }

    private func primaryText(for item: ClipboardHistoryItem) -> String {
        let normalized = ClipboardTextFormatting.summaryText(item.text)

        if !normalized.isEmpty {
            return normalized
        }

        switch item.contentKind {
        case .text:
            return UIStrings.text(.clipboardSystemSourceFallback, language: model.language)
        case .image:
            return sourceTitle(for: item)
        case .files:
            let names = item.fileURLs.map(\.lastPathComponent)
            return names.isEmpty ? sourceTitle(for: item) : names.joined(separator: ", ")
        }
    }

    private func compactSourceLabel(for item: ClipboardHistoryItem) -> String {
        switch item.sourceKind {
        case .system:
            return item.sourceApplicationName ?? UIStrings.text(.clipboardSystemSourceFallback, language: model.language)
        case .voxtypeWorkflow:
            if let workflow = item.workflow {
                return UIStrings.workflowName(workflow, language: model.language)
            }
            return UIStrings.text(.clipboardWorkflowSourceFallback, language: model.language)
        }
    }

    private func icon(for item: ClipboardHistoryItem) -> String {
        switch item.contentKind {
        case .text:
            switch item.sourceKind {
            case .system:
                return "doc.on.clipboard"
            case .voxtypeWorkflow:
                return "wand.and.stars"
            }
        case .image:
            return "photo"
        case .files:
            return "folder"
        }
    }

    private func sourceTitle(for item: ClipboardHistoryItem) -> String {
        switch item.sourceKind {
        case .system:
            if let applicationName = item.sourceApplicationName {
                return UIStrings.clipboardSystemSource(applicationName: applicationName, language: model.language)
            }
            return UIStrings.text(.clipboardSystemSourceFallback, language: model.language)
        case .voxtypeWorkflow:
            if let workflow = item.workflow {
                return UIStrings.clipboardWorkflowSource(workflow, language: model.language)
            }
            return UIStrings.text(.clipboardWorkflowSourceFallback, language: model.language)
        }
    }

    private func groupName(for groupID: UUID) -> String {
        clipboardGroupNamesByID[groupID] ?? UIStrings.text(.clipboardDefaultGroup, language: model.language)
    }

    @ViewBuilder
    private func detailPreview(for item: ClipboardHistoryItem) -> some View {
        switch item.contentKind {
        case .text:
            if let renderedMarkdown = ClipboardTextFormatting.renderedMarkdown(item.text) {
                Text(renderedMarkdown)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(item.text.isEmpty ? primaryText(for: item) : item.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .image:
            VStack(alignment: .leading, spacing: 12) {
                if let imagePNGData = item.imagePNGData, let nsImage = NSImage(data: imagePNGData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: ClipboardViewMetrics.detailPreviewMaxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .files:
            VStack(alignment: .leading, spacing: 10) {
                if let previewImage = filePreviewImage(for: item.fileURLs) {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: ClipboardViewMetrics.detailPreviewMaxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text(primaryText(for: item))
                    .font(.body.weight(.medium))

                ForEach(item.fileURLs, id: \.self) { fileURL in
                    filePreviewRow(for: fileURL)
                }
            }
        }
    }

    @ViewBuilder
    private func filePreviewRow(for fileURL: URL) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon = fileIcon(for: fileURL) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: ClipboardViewMetrics.fileIconSize, height: ClipboardViewMetrics.fileIconSize)
            } else {
                Image(systemName: "doc")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: ClipboardViewMetrics.fileIconSize, height: ClipboardViewMetrics.fileIconSize)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(fileURL.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                Text(fileURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func filePreviewImage(for fileURLs: [URL]) -> NSImage? {
        guard fileURLs.count == 1, let fileURL = fileURLs.first, fileURL.isFileURL else {
            return nil
        }
        return NSImage(contentsOf: fileURL)
    }

    private func fileIcon(for fileURL: URL) -> NSImage? {
        guard fileURL.isFileURL else { return nil }
        return NSWorkspace.shared.icon(forFile: fileURL.path)
    }
}

private extension View {
    func clipboardPanelCard() -> some View {
        self
            .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: ClipboardViewMetrics.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ClipboardViewMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.04))
            )
    }
}

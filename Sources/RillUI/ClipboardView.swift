import AppKit
import SwiftUI
import RillCore

public enum ClipboardViewSection: String, CaseIterable, Identifiable {
    case current
    case history
    case routing

    public var id: String { rawValue }

    var showsClipboardItems: Bool {
        self == .current || self == .history
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .current:
            return L10n.string(.clipboardCurrentTitle, language: language)
        case .history:
            return L10n.string(.clipboardHistoryTitle, language: language)
        case .routing:
            return L10n.string(.clipboardRoutingTitle, language: language)
        }
    }

    func description(language: AppLanguage) -> String {
        switch self {
        case .current:
            return L10n.string(.clipboardCurrentDescription, language: language)
        case .history:
            return L10n.string(.clipboardHistoryDescription, language: language)
        case .routing:
            return L10n.string(.clipboardRoutingDescription, language: language)
        }
    }
}

enum ClipboardViewMetrics {
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

struct ClipboardCaptureDisabledPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let actionTitle: String

    static func make(language: AppLanguage) -> Self {
        Self(
            title: UIStrings.text(.clipboardCaptureDisabledTitle, language: language),
            detail: UIStrings.text(.clipboardCaptureDisabledDescription, language: language),
            actionTitle: UIStrings.text(.clipboardCaptureEnable, language: language)
        )
    }
}

struct ClipboardHistorySectionModel: Identifiable, Equatable {
    let groupID: UUID
    let title: String
    let entries: [ClipboardHistoryEntry]

    var id: UUID { groupID }
}

enum ClipboardSheetDestination: Identifiable, Equatable {
    case createGroup(UUID)
    case dryRun(ClipboardItemDryRunSheetRequest)

    var id: UUID {
        switch self {
        case .createGroup(let id): id
        case .dryRun(let request): request.id
        }
    }
}

public struct ClipboardView: View {
    @Bindable var model: AppModel
    let previewContext: ClipboardRouteContext?
    let focusedGroupID: UUID?
    let preferredSection: ClipboardViewSection?
    let allowsSheetPresentation: Bool
    let allowsDryRunPreview: Bool
    let showsPersistenceWarning: Bool
    @State var presentedSheet: ClipboardSheetDestination?
    @State var newGroupName = ""
    @State var searchText = ""
    @State var debouncedSearchText = ""
    @State var searchDebounceTask: Task<Void, Never>?
    @State var cachedFilteredSections: [ClipboardHistorySectionModel] = []
    @State var selectedSection: ClipboardViewSection
    @State var selectedEntryID: UUID?
    @State var hoveredEntryID: UUID?
    @State var pendingDeletion: ClipboardHistoryEntry?
    @State var pendingGroupAssignment: ClipboardAppAssignment?
    @State var newTagText = ""
    @FocusState var focusedControl: ClipboardViewFocusTarget?

    public init(
        model: AppModel,
        previewContext: ClipboardRouteContext? = nil,
        focusedGroupID: UUID? = nil,
        preferredSection: ClipboardViewSection? = nil,
        allowsSheetPresentation: Bool = true,
        allowsDryRunPreview: Bool = true,
        showsPersistenceWarning: Bool = true
    ) {
        self.model = model
        self.previewContext = previewContext
        self.focusedGroupID = focusedGroupID
        self.preferredSection = preferredSection
        self.allowsSheetPresentation = allowsSheetPresentation
        self.allowsDryRunPreview = allowsSheetPresentation && allowsDryRunPreview
        self.showsPersistenceWarning = showsPersistenceWarning
        _selectedSection = State(initialValue: preferredSection ?? .current)
    }

    public var body: some View {
        interactionObservedContent
            .onKeyPress(.upArrow) { navigateList(direction: -1) }
            .onKeyPress(.downArrow) { navigateList(direction: 1) }
            .onKeyPress(.return) { pasteSelectedItem() }
            .onKeyPress(.delete) { deleteSelectedItem() }
    }

    private var presentationContent: some View {
        mainContent
            .sheet(item: presentedSheetBinding) { destination in
                switch destination {
                case .createGroup:
                    createGroupSheet
                case .dryRun(let request):
                    ClipboardItemDryRunSheet(model: model, request: request)
                }
            }
            .confirmationDialog(
                pendingDeletion.map {
                    UIStrings.clipboardDeleteConfirmationTitle(
                        itemCount: $0.mergedItemIDs.count,
                        language: model.language
                    )
                } ?? UIStrings.text(.clipboardDeleteItem, language: model.language),
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingDeletion = nil
                        }
                    }
                ),
                presenting: pendingDeletion
            ) { entry in
                Button(
                    UIStrings.text(.clipboardDeleteItem, language: model.language),
                    role: .destructive
                ) {
                    pendingDeletion = nil
                    model.deleteClipboardHistoryEntry(entry)
                }
                Button(
                    L10n.historySettingsText(.cancel, language: model.language),
                    role: .cancel
                ) {
                    pendingDeletion = nil
                }
            } message: { entry in
                Text(
                    UIStrings.clipboardDeleteConfirmationDescription(
                        itemCount: entry.mergedItemIDs.count,
                        language: model.language
                    )
                )
            }
    }

    private var modelObservedContent: some View {
        presentationContent
            .onChange(of: searchText) { _, newValue in
                scheduleSearchDebounce(for: newValue)
            }
            .onChange(of: filteredClipboardEntryIDs) { previousEntryIDs, _ in
                syncSelectedEntry(previousVisibleEntryIDs: previousEntryIDs)
            }
            .onChange(of: debouncedSearchText) { _, _ in
                recomputeFilteredSections()
            }
            .onChange(of: model.clipboardItems) { _, _ in
                recomputeFilteredSections()
            }
            .onChange(of: model.clipboardHistoryEntries) { _, _ in
                recomputeFilteredSections()
            }
            .onChange(of: model.mergeSimilarClipboardItems) { _, _ in
                recomputeFilteredSections()
            }
            .onChange(of: model.clipboardRemainingItemIDs) { _, _ in
                recomputeFilteredSections()
            }
            .onChange(of: model.clipboardGroups) { _, _ in
                recomputeFilteredSections()
            }
            .onChange(of: model.clipboardDefaultGroup) { _, _ in
                recomputeFilteredSections()
            }
            .onChange(of: model.clipboardAppAssignments) { _, _ in
                recomputeFilteredSections()
            }
    }

    private var interactionObservedContent: some View {
        modelObservedContent
            .onChange(of: selectedSection) { _, newValue in
                recomputeFilteredSections()
                focusedControl = ClipboardViewFocusPolicy.targetAfterSectionChange(
                    current: focusedControl,
                    section: newValue
                )
                if newValue.showsClipboardItems {
                    syncSelectedEntry()
                }
            }
            .onChange(of: focusedControl) { _, newTarget in
                guard case .entry(let entryID) = newTarget,
                      filteredClipboardEntryIDs.contains(entryID) else {
                    return
                }
                selectedEntryID = entryID
            }
            .onChange(of: focusedGroupID) { _, newValue in
                guard newValue != nil else { return }
                selectedSection = preferredSection ?? .routing
            }
            .onChange(of: preferredSection) { _, newValue in
                guard let newValue, selectedSection != newValue else { return }
                selectedSection = newValue
            }
            .onAppear {
                recomputeFilteredSections()
                syncSelectedEntry()
                if let preferredSection {
                    selectedSection = preferredSection
                }
            }
            .onDisappear {
                searchDebounceTask?.cancel()
            }
    }

    private var presentedSheetBinding: Binding<ClipboardSheetDestination?> {
        Binding(
            get: { allowsSheetPresentation ? presentedSheet : nil },
            set: { presentedSheet = allowsSheetPresentation ? $0 : nil }
        )
    }

    var mainContent: some View {
        VStack(spacing: 0) {
            if let presentation = captureDisabledPresentation {
                clipboardCaptureDisabledBanner(presentation)
                    .padding(.horizontal, ClipboardViewMetrics.outerPadding)
                    .padding(.top, ClipboardViewMetrics.outerPadding)
                    .padding(.bottom, 8)
            }

            if let warning = persistenceWarningPresentation {
                ClipboardPersistenceWarningBanner(
                    presentation: warning,
                    resetConfirmation: persistenceResetConfirmationPresentation,
                    resetCancelTitle: L10n.historySettingsText(.cancel, language: model.language),
                    isRetrying: model.isRetryingClipboardPersistence,
                    isResetting: model.isResettingClipboardPersistence,
                    retryFocus: $focusedControl,
                    retry: retryClipboardPersistence,
                    reset: resetClipboardPersistence
                )
                .padding(.horizontal, ClipboardViewMetrics.outerPadding)
                .padding(
                    .top,
                    captureDisabledPresentation == nil
                        ? ClipboardViewMetrics.outerPadding
                        : 0
                )
                .padding(.bottom, 8)
            }

            if let warning = storageWarningPresentation {
                ClipboardStorageWarningBanner(presentation: warning)
                    .padding(.horizontal, ClipboardViewMetrics.outerPadding)
                    .padding(
                        .top,
                        captureDisabledPresentation == nil
                            && persistenceWarningPresentation == nil
                            ? ClipboardViewMetrics.outerPadding
                            : 0
                    )
                    .padding(.bottom, 8)
            }

            if ClipboardViewFocusPolicy.showsSearch(in: selectedSection) {
                searchBar
                    .padding(.horizontal, ClipboardViewMetrics.outerPadding)
                    .padding(
                        .top,
                        captureDisabledPresentation == nil
                            && persistenceWarningPresentation == nil
                            && storageWarningPresentation == nil
                            ? ClipboardViewMetrics.outerPadding
                            : 0
                    )
                    .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, ClipboardViewMetrics.outerPadding)
            }

            compactTabBar
                .padding(.horizontal, ClipboardViewMetrics.outerPadding)
                .padding(.vertical, 8)

            Group {
                switch selectedSection {
                case .current, .history:
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

    private var captureDisabledPresentation: ClipboardCaptureDisabledPresentation? {
        guard !model.clipboardCaptureEnabled else { return nil }
        return .make(language: model.language)
    }

    private func clipboardCaptureDisabledBanner(
        _ presentation: ClipboardCaptureDisabledPresentation
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "power.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(presentation.actionTitle) {
                model.setClipboardCaptureEnabled(true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canMutateScalarSettings(in: .clipboard))
            .accessibilityIdentifier("clipboard.capture-enable")
        }
        .padding(12)
        .background(
            .orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard.capture-disabled")
    }

    private var persistenceWarningPresentation: ClipboardPersistenceWarningPresentation? {
        guard showsPersistenceWarning else { return nil }
        return ClipboardPersistenceWarningPresentation.make(
            availability: model.clipboardPersistenceAvailability,
            resetFailed: model.clipboardPersistenceResetFailed,
            language: model.language
        )
    }

    private var persistenceResetConfirmationPresentation: ClipboardPersistenceResetConfirmationPresentation {
        ClipboardPersistenceResetConfirmationPresentation.make(language: model.language)
    }

    private var storageWarningPresentation: ClipboardStorageWarningPresentation? {
        guard showsPersistenceWarning else { return nil }
        return ClipboardStorageWarningPresentation.make(
            reason: model.clipboardStorageRejection,
            context: model.clipboardStoragePressureContext,
            language: model.language
        )
    }

    private func retryClipboardPersistence() {
        focusedControl = ClipboardViewFocusPolicy.targetBeforePersistenceRetry(
            current: focusedControl,
            section: selectedSection
        )
        model.retryClipboardPersistenceNow()
    }

    private func resetClipboardPersistence() {
        focusedControl = ClipboardViewFocusPolicy.targetBeforePersistenceRetry(
            current: focusedControl,
            section: selectedSection
        )
        model.resetUnavailableClipboardPersistence()
    }

    // MARK: - Keyboard Navigation

    func navigateList(direction: Int) -> KeyPress.Result {
        guard ClipboardViewModalPolicy.allowsParentKeyboardAction(
            hasPresentedSheet: presentedSheet != nil,
            hasPendingDeletion: pendingDeletion != nil
        ) else { return .ignored }
        guard selectedSection.showsClipboardItems,
              let entryID = ClipboardViewFocusPolicy.entryIDByMovingFocus(
                  from: focusedControl,
                  direction: direction,
                  visibleEntryIDs: filteredClipboardEntryIDs
              ) else {
            return .ignored
        }
        selectedEntryID = entryID
        focusedControl = .entry(entryID)
        return .handled
    }

    func pasteSelectedItem() -> KeyPress.Result {
        guard ClipboardViewModalPolicy.allowsParentKeyboardAction(
            hasPresentedSheet: presentedSheet != nil,
            hasPendingDeletion: pendingDeletion != nil
        ) else { return .ignored }
        guard shouldHandleReturnAction() else { return .ignored }
        guard selectedSection.showsClipboardItems,
              let selectedEntry,
              selectedEntry.representativeItem.supportsDirectPaste else {
            return .ignored
        }
        model.useClipboardItem(selectedEntry.representativeItem)
        return .handled
    }

    func deleteSelectedItem() -> KeyPress.Result {
        guard ClipboardViewModalPolicy.allowsParentKeyboardAction(
            hasPresentedSheet: presentedSheet != nil,
            hasPendingDeletion: pendingDeletion != nil
        ) else { return .ignored }
        guard ClipboardInputMethodGuard.shouldHandleDelete(
            for: activeTextInputResponder
        ) else { return .ignored }
        guard selectedSection.showsClipboardItems, let selectedEntry else { return .ignored }
        requestDeletion(of: selectedEntry)
        return .handled
    }

    func requestDeletion(of entry: ClipboardHistoryEntry) {
        guard ClipboardViewModalPolicy.allowsDeletionRequest(
            hasPresentedSheet: presentedSheet != nil,
            hasPendingDeletion: pendingDeletion != nil
        ) else { return }
        pendingDeletion = entry
    }

    // MARK: - Search Bar

    var searchBar: some View {
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
            .focused($focusedControl, equals: .search)
            .accessibilityIdentifier("clipboard.search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(UIStrings.text(.clipboardClearSearch, language: model.language))
                .accessibilityIdentifier("clipboard.search.clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            .quaternary.opacity(0.15),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    focusedControl == .search ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: focusedControl)
    }

    var compactTabBar: some View {
        HStack(spacing: 10) {
            Picker(
                UIStrings.text(.clipboardSection, language: model.language),
                selection: $selectedSection
            ) {
                ForEach(ClipboardViewSection.allCases) { section in
                    Text(section.title(language: model.language)).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .focused($focusedControl, equals: .sectionPicker)
            .accessibilityIdentifier("clipboard.section-picker")

            Spacer()

            if selectedSection.showsClipboardItems {
                Text(selectedSection.description(language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(UIStrings.stackCountSummary(filteredClipboardEntries.count, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if allowsSheetPresentation {
                Button(UIStrings.text(.clipboardCreateGroup, language: model.language)) {
                    pendingGroupAssignment = nil
                    newGroupName = ""
                    presentedSheet = .createGroup(UUID())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

}

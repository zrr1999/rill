import AppKit
import SwiftUI
import RillCore

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case stream
    case workflows
    case records
    case diagnostics
    case settings

    public var id: String { rawValue }

    public var symbolName: String {
        symbol.rawValue
    }

    public var symbol: RillSystemSymbol {
        switch self {
        case .stream: return .waveform
        case .workflows: return .point3ConnectedTrianglepathDotted
        case .records: return .squareStack3dUp
        case .diagnostics: return .stethoscope
        case .settings: return .gearshape
        }
    }

    public var titleKey: UIStrings.Key {
        switch self {
        case .stream: return .sidebarStream
        case .workflows: return .sidebarWorkflows
        case .records: return .sidebarRecords
        case .diagnostics: return .sidebarDiagnostics
        case .settings: return .sidebarSettings
        }
    }
}

private struct SidebarFocusTaskIdentity: Hashable {
    let destination: SidebarDestination
    let typedDetailRequestID: UUID?
    let typedDetailOwnsFocus: Bool
}

struct GlobalHistorySearchTaskIdentity: Hashable {
    let isPresented: Bool
    let query: String
    let language: String
    let previewMode: String
    let retentionPeriod: String
    let workflowSearchSnapshot: [String]
    let retryGeneration: Int
}

enum GlobalHistorySearchRequestPolicy {
    struct RetryTransition: Equatable {
        let retryGeneration: Int
        let focusRequest: Int
    }

    static func nextRetryGeneration(
        currentGeneration: Int,
        isPresented: Bool,
        query: String,
        state: GlobalHistorySearchState
    ) -> Int? {
        guard isPresented,
            state == .failed,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return currentGeneration &+ 1
    }

    static func retryTransition(
        currentGeneration: Int,
        currentFocusRequest: Int,
        isPresented: Bool,
        query: String,
        state: GlobalHistorySearchState
    ) -> RetryTransition? {
        guard
            let retryGeneration = nextRetryGeneration(
                currentGeneration: currentGeneration,
                isPresented: isPresented,
                query: query,
                state: state
            )
        else {
            return nil
        }
        return RetryTransition(
            retryGeneration: retryGeneration,
            focusRequest: currentFocusRequest &+ 1
        )
    }

    static func canPublish(
        request: GlobalHistorySearchTaskIdentity,
        current: GlobalHistorySearchTaskIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && request == current
    }
}

struct GlobalSearchPresentationTransition: Equatable {
    let shouldInitializeSelection: Bool
    let focusRequest: Int
}

enum GlobalSearchPresentationPolicy {
    static func transition(
        isPresented: Bool,
        currentFocusRequest: Int
    ) -> GlobalSearchPresentationTransition {
        GlobalSearchPresentationTransition(
            shouldInitializeSelection: !isPresented,
            focusRequest: currentFocusRequest &+ 1
        )
    }
}

enum MainShellInteractionPolicy {
    static func allowsBackgroundInteraction(isGlobalSearchPresented: Bool) -> Bool {
        !isGlobalSearchPresented
    }

    static func allowsSidebarInteraction(isGlobalSearchPresented: Bool) -> Bool {
        allowsBackgroundInteraction(isGlobalSearchPresented: isGlobalSearchPresented)
    }

    static func allowsDetailInteraction(isGlobalSearchPresented: Bool) -> Bool {
        allowsBackgroundInteraction(isGlobalSearchPresented: isGlobalSearchPresented)
    }

    static func allowsToolbarInteraction(isGlobalSearchPresented: Bool) -> Bool {
        allowsBackgroundInteraction(isGlobalSearchPresented: isGlobalSearchPresented)
    }

    static func shouldRestoreSidebarFocus(
        isGlobalSearchPresented: Bool,
        detailOwnsFocus: Bool
    ) -> Bool {
        allowsSidebarInteraction(isGlobalSearchPresented: isGlobalSearchPresented)
            && !detailOwnsFocus
    }
}

enum SidebarAccessibilityFocusPolicy {
    static func destinationAfterKeyboardRepair<Destination>(
        currentSidebarDestination: Destination?,
        requestedDestination: Destination,
        didRestoreKeyboardFocus: Bool
    ) -> Destination? {
        guard didRestoreKeyboardFocus,
            currentSidebarDestination != nil
        else {
            return nil
        }
        return requestedDestination
    }
}

public struct MainShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var model: AppModel
    @AccessibilityFocusState private var accessibilityFocusedSidebarDestination: SidebarDestination?
    @State private var globalSearchText = ""
    @State private var isGlobalSearchPresented = false
    @State private var selectedGlobalSearchResultID: String?
    @State private var globalHistorySearchResults: [GlobalSearchResult] = []
    @State private var globalHistorySearchState: GlobalHistorySearchState = .idle
    @State private var globalHistorySearchRetryGeneration = 0
    @State private var globalSearchFocusRequest = 0
    @State private var sidebarFocusRequestGeneration = 0
    @State private var sidebarFocusCoordinator = SidebarFocusCoordinator()
    private let sidebarFocusTurnWaiter: @MainActor @Sendable () async -> Void
    private static let leadingSections: [SidebarSection] = [.stream]

    public init(model: AppModel) {
        self.model = model
        sidebarFocusTurnWaiter = {
            await waitForMainRunLoopDefaultMode()
        }
    }

    init(
        model: AppModel,
        sidebarFocusTurnWaiter: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.model = model
        self.sidebarFocusTurnWaiter = sidebarFocusTurnWaiter
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section {
                    ForEach(Self.leadingSections) { section in
                        sidebarSectionRow(section)
                    }
                }

                Section(UIStrings.text(.recordCollections, language: model.language)) {
                    ForEach(model.recordWorkspace.snapshot.collections) { collection in
                        sidebarCollectionRow(collection)
                            .tag(SidebarDestination.recordCollection(collection.id))
                            .accessibilityFocused(
                                $accessibilityFocusedSidebarDestination,
                                equals: .recordCollection(collection.id)
                            )
                    }
                }

                Section(UIStrings.text(.sidebarWorkflows, language: model.language)) {
                    ForEach(model.workflows) { workflow in
                        sidebarWorkflowRow(workflow)
                            .tag(SidebarDestination.workflow(workflow.id))
                            .accessibilityFocused(
                                $accessibilityFocusedSidebarDestination,
                                equals: .workflow(workflow.id)
                            )
                    }
                }
            }
            .background(SidebarFocusAnchor(coordinator: sidebarFocusCoordinator))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarSettingsFooter
            }
            .allowsHitTesting(
                MainShellInteractionPolicy.allowsSidebarInteraction(
                    isGlobalSearchPresented: isGlobalSearchPresented
                )
            )
            .accessibilityHidden(
                !MainShellInteractionPolicy.allowsSidebarInteraction(
                    isGlobalSearchPresented: isGlobalSearchPresented
                )
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .navigationTitle(UIStrings.text(.appTitle, language: model.language))
        } detail: {
            ZStack {
                VStack(spacing: 0) {
                    if let persistencePresentation =
                        LocalPersistenceStatusPresentation.make(
                            status: model.localPersistenceStatus,
                            language: model.language
                        )
                    {
                        LocalPersistenceStatusBanner(
                            presentation: persistencePresentation,
                            openStorageSettings: {
                                model.showSettings(
                                    LocalPersistenceBannerFocusPolicy.actionDestination
                                )
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }

                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .allowsHitTesting(
                    MainShellInteractionPolicy.allowsDetailInteraction(
                        isGlobalSearchPresented: isGlobalSearchPresented
                    )
                )
                .accessibilityHidden(
                    !MainShellInteractionPolicy.allowsDetailInteraction(
                        isGlobalSearchPresented: isGlobalSearchPresented
                    )
                )
                .background(DetailFocusAnchor(coordinator: sidebarFocusCoordinator))

                if isGlobalSearchPresented {
                    GlobalSearchResultsView(
                        query: $globalSearchText,
                        results: filteredGlobalSearchResults,
                        selectedResultID: selectedGlobalSearchResultID,
                        historySearchState: globalHistorySearchState,
                        historyFailureActionTitle:
                            globalHistoryLoadFailurePresentation.actionTitle,
                        language: model.language,
                        focusRequest: globalSearchFocusRequest,
                        onMoveSelection: { moveGlobalSearchSelection(by: $0) },
                        onSubmit: submitGlobalSearchSelection,
                        onCancel: dismissGlobalSearch,
                        onHistorySearchFailureAction:
                            performGlobalHistorySearchFailureAction,
                        onHighlight: { selectedGlobalSearchResultID = $0 },
                        onSelect: commitGlobalSearchDestination
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
        .overlay {
            if model.isApplicationShuttingDown {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(
                            L10n.string(
                                .applicationShutdownTitle,
                                language: model.language
                            )
                        )
                        .font(.headline)
                        Text(
                            L10n.string(
                                .applicationShutdownDetail,
                                language: model.language
                            )
                        )
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    }
                    .padding(32)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("application.shutdown-progress")
            }
        }
        .focusedSceneValue(
            \.rillGlobalSearchPresentationAction,
            GlobalSearchPresentationAction(presentGlobalSearch)
        )
        .toolbar {
            ToolbarItem {
                Button(action: presentGlobalSearch) {
                    Image(systemName: RillSystemSymbol.magnifyingglass.rawValue)
                }
                .help(GlobalSearchText.searchCommand(language: model.language))
                .accessibilityLabel(GlobalSearchText.searchCommand(language: model.language))
                .accessibilityIdentifier("global-search.open")
                .disabled(
                    !MainShellInteractionPolicy.allowsToolbarInteraction(
                        isGlobalSearchPresented: isGlobalSearchPresented
                    )
                )
                .accessibilityHidden(
                    !MainShellInteractionPolicy.allowsToolbarInteraction(
                        isGlobalSearchPresented: isGlobalSearchPresented
                    )
                )
            }
            ToolbarItem {
                Button {
                    model.openWorkflowEditor()
                } label: {
                    Image(systemName: RillSystemSymbol.squareAndPencil.rawValue)
                }
                .help(UIStrings.text(.openWorkflowEditor, language: model.language))
                .accessibilityLabel(UIStrings.text(.openWorkflowEditor, language: model.language))
                .disabled(
                    !MainShellInteractionPolicy.allowsToolbarInteraction(
                        isGlobalSearchPresented: isGlobalSearchPresented
                    )
                )
                .accessibilityHidden(
                    !MainShellInteractionPolicy.allowsToolbarInteraction(
                        isGlobalSearchPresented: isGlobalSearchPresented
                    )
                )
            }
        }
        .onAppear {
            model.refreshPermissions()
        }
        .task {
            // Sidebar collections are navigation, so load their projection
            // with the shell instead of waiting until a collection detail is
            // already open.
            await model.recordWorkspace.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshPermissions()
            }
        }
        .onChange(of: filteredGlobalSearchResults.map(\.id)) { _, _ in
            selectedGlobalSearchResultID = GlobalSearchSelection.reconcile(
                currentID: selectedGlobalSearchResultID,
                results: filteredGlobalSearchResults
            )
        }
        .task(id: globalHistorySearchTaskIdentity) {
            let request = globalHistorySearchTaskIdentity
            await updateGlobalHistorySearch(for: request)
        }
        .task(id: sidebarFocusRequestGeneration) {
            await restoreSidebarFocusForRequestGeneration()
        }
        .task(id: sidebarFocusTaskIdentity) {
            await restoreSidebarFocusForTaskIdentity()
        }
    }
}

extension MainShellView {
    @ViewBuilder
    private var detailContent: some View {
        switch model.selectedSidebarSection {
        case .stream:
            StreamView(model: model)
        case .workflows:
            WorkflowsView(model: model)
        case .records:
            RecordWorkspaceView(workspace: model.recordWorkspace, language: model.language)
        case .diagnostics:
            DiagnosticsView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: { currentSidebarDestination },
            set: { destination in
                guard let destination else {
                    // NavigationSplitView may transiently propose nil while
                    // replacing its detail. Preserve the last valid route so
                    // the sidebar and detail can never disagree.
                    return
                }
                // List selection is a sidebar-owned interaction. Claim the
                // native responder before changing the route so replacing the
                // detail cannot create even a transient responder vacuum.
                let routeFocusClaim = sidebarFocusCoordinator.claimSidebarFocusForRoute(
                    origin: .list,
                    destination: destination
                )
                switch destination {
                case .section(let section):
                    model.selectSidebarSection(section)
                case .recordCollection(let collectionID):
                    model.showRecordCollection(collectionID)
                case .workflow(let workflowID):
                    model.showWorkflow(workflowID)
                }
                guard let routeFocusClaim else { return }
                _ = sidebarFocusCoordinator.restoreFocus(
                    routeClaimID: routeFocusClaim,
                    phase: .routeReconciliation
                )
                sidebarFocusRequestGeneration &+= 1
                scheduleOnMainRunLoopInteractiveModes {
                    _ = sidebarFocusCoordinator.restoreFocus(
                        routeClaimID: routeFocusClaim,
                        phase: .protectNewFocus
                    )
                }
            }
        )
    }

    private var currentSidebarDestination: SidebarDestination {
        if model.selectedSidebarSection == .records,
            let collectionID = model.recordWorkspace.selectedCollectionID
        {
            return .recordCollection(collectionID)
        }
        if model.selectedSidebarSection == .workflows,
            let workflowID = model.workflowEditorNavigationRequest?.workflowID,
            model.workflows.contains(where: { $0.id == workflowID })
        {
            return .workflow(workflowID)
        }
        return .section(model.selectedSidebarSection)
    }

    private var sidebarFocusTaskIdentity: SidebarFocusTaskIdentity {
        let destination = currentSidebarDestination
        let typedDetailRequestID: UUID? =
            switch destination {
            case .section(.settings):
                model.settingsNavigationRequest?.id
            case .section(.stream):
                model.historyNavigationRequest?.id
            case .section, .recordCollection, .workflow:
                nil
            }
        return SidebarFocusTaskIdentity(
            destination: destination,
            typedDetailRequestID: typedDetailRequestID,
            typedDetailOwnsFocus: typedDetailOwnsFocus(for: destination)
        )
    }

    private var filteredGlobalSearchResults: [GlobalSearchResult] {
        GlobalSearchIndex.filter(
            GlobalSearchIndex.makeStaticResults(
                language: model.language,
                workflows: model.workflows
            ) + globalHistorySearchResults,
            query: globalSearchText
        )
    }

    private var globalHistorySearchTaskIdentity: GlobalHistorySearchTaskIdentity {
        GlobalHistorySearchTaskIdentity(
            isPresented: isGlobalSearchPresented,
            query: globalSearchText,
            language: model.language.rawValue,
            previewMode: model.privacyPolicySettings.historyPreviewMode.rawValue,
            retentionPeriod: model.runHistoryRetentionPeriod.rawValue,
            workflowSearchSnapshot: model.workflows.map {
                "\($0.id.uuidString):\(UIStrings.workflowName($0.presentation, language: model.language))"
            },
            retryGeneration: globalHistorySearchRetryGeneration
        )
    }

    private var selectedGlobalSearchResult: GlobalSearchResult? {
        guard let selectedGlobalSearchResultID else { return nil }
        return filteredGlobalSearchResults.first { $0.id == selectedGlobalSearchResultID }
    }

    private var globalHistoryLoadFailurePresentation: HistoryLoadFailurePresentation {
        HistoryLoadFailurePresentation.make(
            persistenceStatus: model.localPersistenceStatus,
            language: model.language
        )
    }

    private func presentGlobalSearch() {
        // Search becomes the exclusive interaction owner synchronously. Retire
        // any queued sidebar-route repair before its AppKit field is installed
        // so a later event-tracking callback cannot focus the hidden sidebar.
        sidebarFocusCoordinator.cancelActiveRouteFocusClaim()
        let transition = GlobalSearchPresentationPolicy.transition(
            isPresented: isGlobalSearchPresented,
            currentFocusRequest: globalSearchFocusRequest
        )
        if transition.shouldInitializeSelection {
            selectedGlobalSearchResultID = GlobalSearchSelection.reconcile(
                currentID: nil,
                results: filteredGlobalSearchResults
            )
            // The overlay's `.transition(.opacity)` needs an explicit
            // animation transaction; Reduce Motion presents it instantly.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isGlobalSearchPresented = true
            }
        }
        // The toolbar is intentionally unavailable while the overlay owns the
        // window, but the focused scene command remains installed. Repeated
        // Command-F requests therefore advance this generation and refocus the
        // existing search field without resetting its query or selection.
        globalSearchFocusRequest = transition.focusRequest
    }

    private func moveGlobalSearchSelection(by offset: Int) {
        guard isGlobalSearchPresented else { return }
        selectedGlobalSearchResultID = GlobalSearchSelection.move(
            currentID: selectedGlobalSearchResultID,
            offset: offset,
            results: filteredGlobalSearchResults
        )
    }

    private func submitGlobalSearchSelection() {
        guard let selectedGlobalSearchResult else { return }
        commitGlobalSearchDestination(selectedGlobalSearchResult.destination)
    }

    private func dismissGlobalSearch() {
        // Symmetric short fade matching the presentation transition; Reduce
        // Motion dismisses instantly.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            isGlobalSearchPresented = false
        }
        globalSearchText = ""
        selectedGlobalSearchResultID = nil
        globalHistorySearchResults = []
        globalHistorySearchState = .idle
        globalHistorySearchRetryGeneration = 0
        sidebarFocusRequestGeneration &+= 1
    }

    private func commitGlobalSearchDestination(_ destination: GlobalSearchDestination) {
        // Same dismissal fade as `dismissGlobalSearch`; Reduce Motion
        // dismisses instantly.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            isGlobalSearchPresented = false
        }
        globalSearchText = ""
        selectedGlobalSearchResultID = nil
        globalHistorySearchResults = []
        globalHistorySearchState = .idle
        globalHistorySearchRetryGeneration = 0
        switch destination {
        case .sidebar(let section):
            model.selectSidebarSection(section)
            // Selecting the current page does not change route identity, so
            // request the same post-event focus restoration used by dismissal.
            sidebarFocusRequestGeneration &+= 1
        case .workflow(let workflowID):
            model.showWorkflow(workflowID)
        case .history(let entryID):
            model.showHistoryEntry(entryID)
        case .settings(let section):
            model.showSettings(section)
        }
    }

    private func retryGlobalHistorySearch() {
        guard
            let transition = GlobalHistorySearchRequestPolicy.retryTransition(
                currentGeneration: globalHistorySearchRetryGeneration,
                currentFocusRequest: globalSearchFocusRequest,
                isPresented: isGlobalSearchPresented,
                query: globalSearchText,
                state: globalHistorySearchState
            )
        else {
            return
        }
        globalHistorySearchRetryGeneration = transition.retryGeneration
        // Retry replaces the focused failure action with transient loading UI.
        // Move first responder back to the stable search field in the same
        // accepted interaction so keyboard and assistive-technology users do
        // not lose focus when the Retry button leaves the hierarchy.
        globalSearchFocusRequest = transition.focusRequest
    }

    private func performGlobalHistorySearchFailureAction() {
        switch globalHistoryLoadFailurePresentation.action {
        case .retry:
            retryGlobalHistorySearch()
        case .viewStorageSettings:
            commitGlobalSearchDestination(.settings(.storage))
        }
    }

    private func updateGlobalHistorySearch(
        for request: GlobalHistorySearchTaskIdentity
    ) async {
        guard
            GlobalHistorySearchRequestPolicy.canPublish(
                request: request,
                current: globalHistorySearchTaskIdentity,
                isCancelled: Task.isCancelled
            )
        else {
            return
        }
        globalHistorySearchResults = []
        globalHistorySearchState = .idle
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.isPresented, !query.isEmpty else { return }

        do {
            try await Task.sleep(for: .milliseconds(250))
            guard
                GlobalHistorySearchRequestPolicy.canPublish(
                    request: request,
                    current: globalHistorySearchTaskIdentity,
                    isCancelled: Task.isCancelled
                )
            else {
                return
            }
            globalHistorySearchState = .searching
            let results = try await model.searchRunHistory(
                query: query,
                language: model.language,
                previewMode: model.privacyPolicySettings.historyPreviewMode
            )
            guard
                GlobalHistorySearchRequestPolicy.canPublish(
                    request: request,
                    current: globalHistorySearchTaskIdentity,
                    isCancelled: Task.isCancelled
                )
            else {
                return
            }
            globalHistorySearchResults = Array(
                results.prefix(GlobalSearchIndex.maximumHistoryResultCount)
            )
            globalHistorySearchState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard
                GlobalHistorySearchRequestPolicy.canPublish(
                    request: request,
                    current: globalHistorySearchTaskIdentity,
                    isCancelled: Task.isCancelled
                )
            else {
                return
            }
            globalHistorySearchResults = []
            globalHistorySearchState = .failed
        }
    }

    private func typedDetailOwnsFocus(for destination: SidebarDestination) -> Bool {
        switch destination {
        case .section(.settings):
            return model.settingsNavigationRequest != nil
        case .section(.stream):
            guard model.historyNavigationRequest != nil else { return false }
            switch model.runHistoryDeepLinkState {
            case .expired, .failed:
                return false
            case .idle, .resolving, .resolved:
                return true
            }
        case .section, .recordCollection, .workflow:
            return false
        }
    }

    private func restoreAccessibilitySidebarFocusIfOwned(
        _ requestedDestination: SidebarDestination,
        didRestoreKeyboardFocus: Bool
    ) {
        guard
            let destination = SidebarAccessibilityFocusPolicy.destinationAfterKeyboardRepair(
                currentSidebarDestination: accessibilityFocusedSidebarDestination,
                requestedDestination: requestedDestination,
                didRestoreKeyboardFocus: didRestoreKeyboardFocus
            )
        else {
            return
        }
        accessibilityFocusedSidebarDestination = destination
    }

    private func sidebarCollectionRow(_ collection: RecordCollection) -> some View {
        HStack(spacing: 10) {
            Label(collection.name, systemImage: RillSystemSymbol.squareStack3dUp.rawValue)
            Spacer(minLength: 8)
            Text("\(collectionRecordCount(collection.id))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                // RillCard subdued-tier fill; a Capsule chip cannot use rillCard itself.
                .background(.quaternary.opacity(0.2), in: Capsule())
        }
        .accessibilityLabel(collection.name)
        .accessibilityIdentifier("sidebar.record-collection.\(collection.id.rawValue.uuidString)")
    }

    private func sidebarWorkflowRow(_ workflow: WorkflowDefinition) -> some View {
        let name = model.localizedWorkflowName(for: workflow)
        let sourceBadge = sidebarWorkflowSourceBadge(for: workflow)
        return HStack(spacing: 8) {
            Label(
                name,
                systemImage: RillSystemSymbol.resolvedName(workflow.ui.symbolName)
            )
            if let sourceBadge {
                Spacer(minLength: 4)
                Text(sourceBadge.title)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sourceBadge.tint.opacity(0.12), in: Capsule())
                    .foregroundStyle(sourceBadge.tint)
            }
        }
        .accessibilityLabel(
            sourceBadge.map { "\(name), \($0.title)" } ?? name
        )
        .accessibilityIdentifier("sidebar.workflow.\(workflow.id.uuidString)")
    }

    /// Duplicate display names are real user data (two TOML workflows can
    /// share a name), so a duplicated row carries a small source badge to
    /// stay distinguishable. Unique names render exactly as before.
    private func sidebarWorkflowSourceBadge(
        for workflow: WorkflowDefinition
    ) -> (title: String, tint: Color)? {
        let name = model.localizedWorkflowName(for: workflow)
        guard duplicatedSidebarWorkflowNames.contains(
            WorkflowNameDuplicationPolicy.normalizedName(name)
        ) else {
            return nil
        }
        return model.isBuiltInWorkflow(workflow)
            ? (UIStrings.text(.workflowBuiltIn, language: model.language), .secondary)
            : (UIStrings.text(.workflowCustom, language: model.language), .accentColor)
    }

    private var duplicatedSidebarWorkflowNames: Set<String> {
        WorkflowNameDuplicationPolicy.duplicatedNames(
            in: model.workflows,
            language: model.language
        )
    }

    private func sidebarSectionRow(_ section: SidebarSection) -> some View {
        Label(
            UIStrings.text(section.titleKey, language: model.language),
            systemImage: section.symbolName
        )
        .tag(SidebarDestination.section(section))
        .accessibilityLabel(UIStrings.text(section.titleKey, language: model.language))
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
        .accessibilityFocused(
            $accessibilityFocusedSidebarDestination,
            equals: .section(section)
        )
    }

    /// Settings is a pinned utility destination, not scrollable content, so
    /// it lives below the list and stays visible while sections scroll.
    private var sidebarSettingsFooter: some View {
        let section = SidebarSection.settings
        let isSelected = model.selectedSidebarSection == section
        return VStack(spacing: 0) {
            Divider()
            Button(action: selectSettingsFromSidebarFooter) {
                Label(
                    UIStrings.text(section.titleKey, language: model.language),
                    systemImage: section.symbolName
                )
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rillSelection(isSelected, cornerRadius: RillRadius.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .accessibilityLabel(UIStrings.text(section.titleKey, language: model.language))
            .accessibilityIdentifier("sidebar.\(section.rawValue)")
            .accessibilityFocused(
                $accessibilityFocusedSidebarDestination,
                equals: .section(section)
            )
        }
    }

    private func selectSettingsFromSidebarFooter() {
        // Footer selection shares the List pipeline: claim the sidebar
        // responder before changing the route so replacing the detail cannot
        // strand keyboard focus.
        let routeFocusClaim = sidebarFocusCoordinator.claimSidebarFocusForRoute(
            origin: .list,
            destination: .section(.settings)
        )
        model.selectSidebarSection(.settings)
        guard let routeFocusClaim else { return }
        _ = sidebarFocusCoordinator.restoreFocus(
            routeClaimID: routeFocusClaim,
            phase: .routeReconciliation
        )
        sidebarFocusRequestGeneration &+= 1
        scheduleOnMainRunLoopInteractiveModes {
            _ = sidebarFocusCoordinator.restoreFocus(
                routeClaimID: routeFocusClaim,
                phase: .protectNewFocus
            )
        }
    }

    private func collectionRecordCount(_ collectionID: RecordCollectionID) -> Int {
        model.recordWorkspace.snapshot.records.reduce(into: 0) { count, record in
            if record.memberships.contains(where: { $0.collectionID == collectionID }) {
                count += 1
            }
        }
    }

    private func restoreSidebarFocusForRequestGeneration() async {

        guard sidebarFocusRequestGeneration > 0 else { return }
        let requestedDestination = currentSidebarDestination
        let routeFocusClaim = sidebarFocusCoordinator.activeRouteFocusClaim
        guard
            MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                isGlobalSearchPresented: isGlobalSearchPresented,
                detailOwnsFocus: typedDetailOwnsFocus(for: requestedDestination)
            )
        else {
            if let routeFocusClaim {
                sidebarFocusCoordinator.completeRouteFocusClaim(routeFocusClaim)
            }
            return
        }
        await sidebarFocusTurnWaiter()
        guard !Task.isCancelled,
            requestedDestination == currentSidebarDestination,
            MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                isGlobalSearchPresented: isGlobalSearchPresented,
                detailOwnsFocus: typedDetailOwnsFocus(for: requestedDestination)
            )
        else {
            if let routeFocusClaim {
                sidebarFocusCoordinator.completeRouteFocusClaim(routeFocusClaim)
            }
            return
        }
        let focusRestoration = sidebarFocusCoordinator.restoreFocus(
            routeClaimID: routeFocusClaim,
            phase: .protectNewFocus
        )
        restoreAccessibilitySidebarFocusIfOwned(
            requestedDestination,
            didRestoreKeyboardFocus: focusRestoration == .sidebar
        )
        if let routeFocusClaim {
            guard sidebarFocusCoordinator.activeRouteFocusClaim == routeFocusClaim else {
                return
            }
            // SwiftUI can still detach or clear the responder after the
            // first default-mode layout. Recheck a genuine focus vacuum
            // once, while preserving any live responder acquired after
            // the initial repair, and then retire this route claim.
            await sidebarFocusTurnWaiter()
            guard !Task.isCancelled,
                requestedDestination == currentSidebarDestination,
                MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                    isGlobalSearchPresented: isGlobalSearchPresented,
                    detailOwnsFocus: typedDetailOwnsFocus(for: requestedDestination)
                )
            else {
                sidebarFocusCoordinator.completeRouteFocusClaim(routeFocusClaim)
                return
            }
            _ = sidebarFocusCoordinator.restoreFocus(routeClaimID: routeFocusClaim)
            sidebarFocusCoordinator.completeRouteFocusClaim(routeFocusClaim)
        }

    }
    private func restoreSidebarFocusForTaskIdentity() async {

        let requestedDestination = currentSidebarDestination
        // A List-originated route has a stronger native responder claim
        // and is handled by sidebarFocusRequestGeneration. Avoid two
        // independent repair tasks racing over the same transition. A
        // claim for an older destination must not suppress this route.
        guard
            !sidebarFocusCoordinator.hasActiveListRouteFocusClaim(
                for: requestedDestination
            )
        else { return }
        let detailOwnsFocus = typedDetailOwnsFocus(for: requestedDestination)
        guard
            MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                isGlobalSearchPresented: isGlobalSearchPresented,
                detailOwnsFocus: detailOwnsFocus
            )
        else { return }

        // Claim the persistent sidebar before the old detail can detach.
        // Removing a no-longer-current responder cannot create a later
        // focus vacuum, so this is state ownership rather than a bounded
        // guess at how many layout turns an AppKit host may survive.
        let routeFocusClaim = sidebarFocusCoordinator.claimSidebarFocusForRoute(
            origin: .programmatic,
            destination: requestedDestination
        )
        defer {
            if let routeFocusClaim {
                sidebarFocusCoordinator.completeRouteFocusClaim(routeFocusClaim)
            }
        }
        if routeFocusClaim != nil {
            restoreAccessibilitySidebarFocusIfOwned(
                requestedDestination,
                didRestoreKeyboardFocus: true
            )
        }

        // SwiftUI may reconcile its responder once more when the new
        // detail commits. Repair only a vacuum; preserve any live focus
        // acquired in the committed detail while this task was waiting.
        await sidebarFocusTurnWaiter()
        guard !Task.isCancelled,
            requestedDestination == currentSidebarDestination,
            MainShellInteractionPolicy.shouldRestoreSidebarFocus(
                isGlobalSearchPresented: isGlobalSearchPresented,
                detailOwnsFocus: typedDetailOwnsFocus(for: requestedDestination)
            )
        else {
            return
        }
        let focusRestoration = sidebarFocusCoordinator.restoreFocus(
            routeClaimID: routeFocusClaim
        )
        restoreAccessibilitySidebarFocusIfOwned(
            requestedDestination,
            didRestoreKeyboardFocus: focusRestoration == .sidebar
        )
    }
}

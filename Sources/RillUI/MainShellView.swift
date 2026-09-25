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

    public var titleKey: L10n.InterfaceKey {
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
    var recordRevision: UInt64 = 0
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

/// Main-shell layout constants, following the `MenuBarLayoutMetrics`
/// precedent so the shell stops inventing its own numbers.
enum MainShellLayoutMetrics {
    static let sidebarColumnMinWidth: CGFloat = 180
    static let sidebarColumnIdealWidth: CGFloat = 200
    static let sidebarColumnMaxWidth: CGFloat = 260
    static let shutdownOverlaySpacing: CGFloat = RillSpacing.card
    static let shutdownOverlayMaxWidth: CGFloat = 420
    static let shutdownOverlayPadding: CGFloat = 32
    /// Footer-row insets mirror the List row insets above the footer, so the
    /// pinned Settings row aligns with the scrollable sidebar rows.
    static let sidebarFooterRowHorizontalPadding: CGFloat = 8
    static let sidebarFooterRowVerticalPadding: CGFloat = 6
}

public struct MainShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var model: AppModel
    @AccessibilityFocusState private var accessibilityFocusedSidebarDestination: SidebarDestination?
    @State private var search = GlobalSearchModel()
    @State private var isGlobalSearchPresented = false
    @State private var globalHistorySearchRetryGeneration = 0
    @State private var globalSearchFocusRequest = 0
    @State private var sidebarFocusRequestGeneration = 0
    @State private var sidebarFocusCoordinator = SidebarFocusCoordinator()
    private let sidebarFocusTurnWaiter: @MainActor @Sendable () async -> Void
    private static let leadingSections: [SidebarSection] = [.records]

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

                Section(L10n.text(.recordCollections, language: model.settings.language)) {
                    ForEach(model.recordWorkspace.snapshot.collections) { collection in
                        sidebarCollectionRow(collection)
                            .tag(SidebarDestination.recordCollection(collection.id))
                            .accessibilityFocused(
                                $accessibilityFocusedSidebarDestination,
                                equals: .recordCollection(collection.id)
                            )
                    }
                }

                Section {
                    sidebarSectionRow(.stream)
                    sidebarSectionRow(.workflows)
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
            .navigationSplitViewColumnWidth(
                min: MainShellLayoutMetrics.sidebarColumnMinWidth,
                ideal: MainShellLayoutMetrics.sidebarColumnIdealWidth,
                max: MainShellLayoutMetrics.sidebarColumnMaxWidth
            )
            .navigationTitle(L10n.text(.appTitle, language: model.settings.language))
        } detail: {
            ZStack {
                VStack(spacing: 0) {
                    if let persistencePresentation =
                        LocalPersistenceStatusPresentation.make(
                            status: model.localPersistenceStatus,
                            language: model.settings.language
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
                        .padding(.horizontal, RillSpacing.card)
                        .padding(.top, RillSpacing.card)
                        .padding(.bottom, RillSpacing.row)
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
                        query: $search.query,
                        results: filteredGlobalSearchResults,
                        selectedResultID: search.selectedID,
                        historySearchState: search.historyState,
                        recordSearchState: search.recordState,
                        hasMore: search.hasMoreRecords || search.hasMoreHistory,
                        onLoadMore: { search.showMore(); globalHistorySearchRetryGeneration &+= 1 },
                        onRecordRetry: { globalHistorySearchRetryGeneration &+= 1 },
                        historyFailureActionTitle:
                            globalHistoryLoadFailurePresentation.actionTitle,
                        language: model.settings.language,
                        focusRequest: globalSearchFocusRequest,
                        onMoveSelection: { moveGlobalSearchSelection(by: $0) },
                        onSubmit: submitGlobalSearchSelection,
                        onCancel: dismissGlobalSearch,
                        onHistorySearchFailureAction:
                            performGlobalHistorySearchFailureAction,
                        onHighlight: { search.selectedID = $0 },
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

                    VStack(spacing: MainShellLayoutMetrics.shutdownOverlaySpacing) {
                        ProgressView()
                            .controlSize(.large)
                        Text(
                            L10n.string(
                                .applicationShutdownTitle,
                                language: model.settings.language
                            )
                        )
                        .font(.headline)
                        Text(
                            L10n.string(
                                .applicationShutdownDetail,
                                language: model.settings.language
                            )
                        )
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: MainShellLayoutMetrics.shutdownOverlayMaxWidth)
                    }
                    .padding(MainShellLayoutMetrics.shutdownOverlayPadding)
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
            ToolbarItem(id: "rill.global-search") {
                Button(action: presentGlobalSearch) {
                    Image(systemName: RillSystemSymbol.magnifyingglass.rawValue)
                }
                .help(GlobalSearchText.searchCommand(language: model.settings.language))
                .accessibilityLabel(GlobalSearchText.searchCommand(language: model.settings.language))
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
            search.selectedID = GlobalSearchSelection.reconcile(
                currentID: search.selectedID,
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
            RecordWorkspaceView(workspace: model.recordWorkspace, language: model.settings.language, copySelection: model.copyRecord)
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
        return .section(model.selectedSidebarSection)
    }

    private var sidebarFocusTaskIdentity: SidebarFocusTaskIdentity {
        let destination = currentSidebarDestination
        let typedDetailRequestID: UUID? =
            switch destination {
            case .section(.settings):
                model.settingsNavigationRequest?.id
            case .section(.stream):
                model.history.historyNavigationRequest?.id
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
                language: model.settings.language,
                workflows: model.workflowLibrary.workflows
            ) + GlobalSearchIndex.collectionResults(model.recordWorkspace.snapshot.collections, language: model.settings.language)
                + search.results(matching: globalHistorySearchTaskIdentity),
            query: search.query
        )
    }

    private var globalHistorySearchTaskIdentity: GlobalHistorySearchTaskIdentity {
        GlobalHistorySearchTaskIdentity(
            isPresented: isGlobalSearchPresented,
            query: search.query,
            language: model.settings.language.rawValue,
            previewMode: model.privacyPolicySettings.historyPreviewMode.rawValue,
            retentionPeriod: model.runHistoryRetentionPeriod.rawValue,
            workflowSearchSnapshot: model.workflowLibrary.workflows.map {
                "\($0.id.uuidString):\(L10n.workflowName($0.presentation, language: model.settings.language))"
            },
            retryGeneration: globalHistorySearchRetryGeneration,
            recordRevision: model.recordWorkspace.snapshot.revision
        )
    }

    private var selectedGlobalSearchResult: GlobalSearchResult? {
        guard let selectedID = search.selectedID else { return nil }
        return filteredGlobalSearchResults.first { $0.id == selectedID }
    }

    private var globalHistoryLoadFailurePresentation: HistoryLoadFailurePresentation {
        HistoryLoadFailurePresentation.make(
            persistenceStatus: model.localPersistenceStatus,
            language: model.settings.language
        )
    }

    /// Single short fade for presenting and dismissing the search overlay;
    /// Reduce Motion presents and dismisses instantly.
    private static func searchOverlayAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
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
            search.selectedID = GlobalSearchSelection.reconcile(
                currentID: nil,
                results: filteredGlobalSearchResults
            )
            // The overlay's `.transition(.opacity)` needs an explicit
            // animation transaction; Reduce Motion presents it instantly.
            withAnimation(Self.searchOverlayAnimation(reduceMotion: reduceMotion)) {
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
        search.selectedID = GlobalSearchSelection.move(
            currentID: search.selectedID,
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
        withAnimation(Self.searchOverlayAnimation(reduceMotion: reduceMotion)) {
            isGlobalSearchPresented = false
        }
        search.reset()
        globalHistorySearchRetryGeneration = 0
        sidebarFocusRequestGeneration &+= 1
    }

    private func commitGlobalSearchDestination(_ destination: GlobalSearchDestination) {
        // Same dismissal fade as `dismissGlobalSearch`; Reduce Motion
        // dismisses instantly.
        withAnimation(Self.searchOverlayAnimation(reduceMotion: reduceMotion)) {
            isGlobalSearchPresented = false
        }
        search.reset()
        globalHistorySearchRetryGeneration = 0
        switch destination {
        case .record(let id):
            Task { await model.showRecord(id) }
        case .collection(let id):
            model.showRecordCollection(id)
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
                query: search.query,
                state: search.historyState
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

    private func updateGlobalHistorySearch(for request: GlobalHistorySearchTaskIdentity) async {
        await search.update(
            request: request,
            records: { query, limit in
                try await model.recordWorkspace.searchRecords(query, limit: limit)
            },
            history: { query, limit in
                try await model.history.searchRunHistory(
                    query: query, language: model.settings.language,
                    previewMode: model.privacyPolicySettings.historyPreviewMode, limit: limit
                )
            },
            language: model.settings.language
        )
    }

    private func typedDetailOwnsFocus(for destination: SidebarDestination) -> Bool {
        switch destination {
        case .section(.settings):
            return model.settingsNavigationRequest != nil
        case .section(.records):
            return model.recordWorkspace.revealedRecordID != nil
        case .section(.stream):
            guard model.history.historyNavigationRequest != nil else { return false }
            switch model.history.runHistoryDeepLinkState {
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
                .background(
                    .quaternary.opacity(RillCardProminence.subdued.fillOpacity),
                    in: Capsule()
                )
        }
        .accessibilityLabel(collection.name)
        .accessibilityIdentifier("sidebar.record-collection.\(collection.id.rawValue.uuidString)")
    }

    private func sidebarSectionRow(_ section: SidebarSection) -> some View {
        Label(
            (section == .records ? L10n.workspace(.allRecords, language: model.settings.language) : L10n.text(section.titleKey, language: model.settings.language)),
            systemImage: section.symbolName
        )
        .tag(SidebarDestination.section(section))
        .accessibilityLabel((section == .records ? L10n.workspace(.allRecords, language: model.settings.language) : L10n.text(section.titleKey, language: model.settings.language)))
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
        .accessibilityFocused(
            $accessibilityFocusedSidebarDestination,
            equals: .section(section)
        )
    }

    private var sidebarSettingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: selectSettingsFromSidebarFooter) {
                Label(L10n.text(.sidebarSettings, language: model.settings.language), systemImage: SidebarSection.settings.symbolName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MainShellLayoutMetrics.sidebarFooterRowHorizontalPadding)
                    .padding(.vertical, MainShellLayoutMetrics.sidebarFooterRowVerticalPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, MainShellLayoutMetrics.sidebarFooterRowHorizontalPadding)
            .padding(.vertical, MainShellLayoutMetrics.sidebarFooterRowVerticalPadding)
            .accessibilityIdentifier("sidebar.settings")
        }
    }

    private func selectSettingsFromSidebarFooter() {
        sidebarFocusCoordinator.cancelActiveRouteFocusClaim()
        model.presentSettings()
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

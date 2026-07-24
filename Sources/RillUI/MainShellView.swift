import AppKit
import SwiftUI
import RillCore

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case clipboard
    case history
    case diagnostics
    case settings

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .clipboard: return "doc.on.clipboard"
        case .history: return "clock.arrow.circlepath"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }

    public var titleKey: UIStrings.Key {
        switch self {
        case .dashboard: return .sidebarDashboard
        case .clipboard: return .sidebarClipboard
        case .history: return .sidebarHistory
        case .diagnostics: return .sidebarDiagnostics
        case .settings: return .sidebarSettings
        }
    }
}

private enum SidebarDestination: Hashable {
    case section(SidebarSection)
    case clipboardGroup(UUID)
}

private enum SidebarRouteFocusClaimOrigin {
    case list
    case programmatic
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
    private static let primarySections: [SidebarSection] = [
        .dashboard,
        .clipboard,
        .history,
        .diagnostics,
        .settings,
    ]

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
                    ForEach(Self.primarySections) { section in
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
                }

                Section(UIStrings.text(.clipboardGroups, language: model.language)) {
                    sidebarGroupRow(model.clipboardDefaultGroup)
                        .tag(SidebarDestination.clipboardGroup(model.clipboardDefaultGroup.group.id))
                        .accessibilityFocused(
                            $accessibilityFocusedSidebarDestination,
                            equals: .clipboardGroup(model.clipboardDefaultGroup.group.id)
                        )

                    ForEach(model.clipboardGroups) { group in
                        sidebarGroupRow(group)
                            .tag(SidebarDestination.clipboardGroup(group.group.id))
                            .accessibilityFocused(
                                $accessibilityFocusedSidebarDestination,
                                equals: .clipboardGroup(group.group.id)
                            )
                    }
                }
            }
            .background(SidebarFocusAnchor(coordinator: sidebarFocusCoordinator))
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
                    Image(systemName: "magnifyingglass")
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
                    Image(systemName: "square.and.pencil")
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
        .task(id: sidebarFocusTaskIdentity) {
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

    @ViewBuilder
    private var detailContent: some View {
        switch model.selectedSidebarSection {
        case .dashboard:
            DashboardView(model: model)
        case .clipboard:
            ClipboardView(
                model: model,
                focusedGroupID: model.selectedClipboardSidebarGroupID,
                preferredSection: model.selectedClipboardSidebarGroupID == nil ? .history : .routing
            )
        case .history:
            HistoryView(model: model)
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
                case .clipboardGroup(let groupID):
                    model.showClipboardManagement(groupID: groupID)
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
        if model.selectedSidebarSection == .clipboard,
            let groupID = model.selectedClipboardSidebarGroupID
        {
            return .clipboardGroup(groupID)
        }
        return .section(model.selectedSidebarSection)
    }

    private var sidebarFocusTaskIdentity: SidebarFocusTaskIdentity {
        let destination = currentSidebarDestination
        let typedDetailRequestID: UUID? =
            switch destination {
            case .section(.settings):
                model.settingsNavigationRequest?.id
            case .section(.history):
                model.historyNavigationRequest?.id
            case .section, .clipboardGroup:
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
            isGlobalSearchPresented = true
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
        isGlobalSearchPresented = false
        globalSearchText = ""
        selectedGlobalSearchResultID = nil
        globalHistorySearchResults = []
        globalHistorySearchState = .idle
        globalHistorySearchRetryGeneration = 0
        sidebarFocusRequestGeneration &+= 1
    }

    private func commitGlobalSearchDestination(_ destination: GlobalSearchDestination) {
        isGlobalSearchPresented = false
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
            model.openWorkflowEditor(workflowID: workflowID)
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
        case .section(.history):
            guard model.historyNavigationRequest != nil else { return false }
            switch model.runHistoryDeepLinkState {
            case .expired, .failed:
                return false
            case .idle, .resolving, .resolved:
                return true
            }
        case .section, .clipboardGroup:
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

    private func sidebarGroupRow(_ summary: ClipboardGroupSummary) -> some View {
        HStack(spacing: 10) {
            Label(groupTitle(for: summary), systemImage: "square.stack.3d.up")
            Spacer(minLength: 8)
            Text("\(summary.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.18), in: Capsule())
        }
        .accessibilityLabel(groupTitle(for: summary))
        .accessibilityIdentifier("sidebar.clipboard-group.\(summary.group.id.uuidString)")
    }

    private func groupTitle(for summary: ClipboardGroupSummary) -> String {
        summary.group.id == ClipboardGroup.defaultGroupID
            ? UIStrings.text(.clipboardDefaultGroup, language: model.language)
            : summary.group.name
    }
}

@MainActor
private final class SidebarFocusCoordinator {
    typealias RouteFocusClaim = UInt64

    enum FocusRestoration: Equatable {
        case none
        case sidebar
        case detail
    }

    enum RouteFocusRepairPhase: Equatable {
        case routeReconciliation
        case protectNewFocus
    }

    weak var anchorView: NSView?
    weak var detailAnchorView: NSView?
    private var nextRouteFocusClaim: RouteFocusClaim = 0
    private(set) var activeRouteFocusClaim: RouteFocusClaim?
    private var activeRouteFocusClaimOrigin: SidebarRouteFocusClaimOrigin?
    private var activeRouteFocusClaimDestination: SidebarDestination?

    func hasActiveListRouteFocusClaim(for destination: SidebarDestination) -> Bool {
        activeRouteFocusClaim != nil
            && activeRouteFocusClaimOrigin == .list
            && activeRouteFocusClaimDestination == destination
    }

    func claimSidebarFocusForRoute(
        origin: SidebarRouteFocusClaimOrigin,
        destination: SidebarDestination
    ) -> RouteFocusClaim? {
        guard let (window, sidebar) = sidebarContext() else { return nil }

        nextRouteFocusClaim &+= 1
        let claim = nextRouteFocusClaim
        activeRouteFocusClaim = claim
        activeRouteFocusClaimOrigin = origin
        activeRouteFocusClaimDestination = destination
        guard window.makeFirstResponder(sidebar) else {
            completeRouteFocusClaim(claim)
            return nil
        }
        return claim
    }

    @discardableResult
    func restoreFocus(
        routeClaimID: RouteFocusClaim? = nil,
        phase: RouteFocusRepairPhase = .protectNewFocus
    ) -> FocusRestoration {
        if let routeClaimID, activeRouteFocusClaim != routeClaimID {
            return .none
        }
        if let (window, sidebar) = sidebarContext() {
            if Self.isResponder(window.firstResponder, inside: sidebar) {
                return .sidebar
            }
            if phase == .routeReconciliation, routeClaimID != nil {
                // No independent detail interaction can legally occur inside the
                // same sidebar mouse-selection turn. Rehome unconditionally so a
                // departing detail responder cannot masquerade as newer focus.
                return window.makeFirstResponder(sidebar) ? .sidebar : .none
            }
            // A delayed post-route repair must never override a newer, valid user
            // focus in the committed detail (for example Clipboard search). Object
            // identity is deliberately irrelevant: a persistent control can be
            // focused again after the route commits, and that is a new interaction
            // even when it is the same responder seen before the route. Keep the
            // route claim alive for its bounded recheck; only a later detached or
            // empty responder state represents focus loss this coordinator owns.
            if phase == .protectNewFocus,
                Self.isLiveInteractiveResponder(window.firstResponder, in: window)
            {
                return .none
            }
            return window.makeFirstResponder(sidebar) ? .sidebar : .none
        }

        // A collapsed NavigationSplitView has no stable sidebar responder.
        // Repair only a genuine vacuum after the new detail has committed;
        // every live responder, including a field editor, represents newer
        // user/detail ownership and must win. The anchor is intentionally not
        // an accessibility element, so this keyboard fallback cannot move an
        // independent VoiceOver focus.
        guard phase == .protectNewFocus,
            let (window, detailAnchor) = detailContext(),
            Self.isKeyboardFocusVacuum(window.firstResponder, in: window)
        else {
            return .none
        }
        return window.makeFirstResponder(detailAnchor) ? .detail : .none
    }

    func completeRouteFocusClaim(_ claim: RouteFocusClaim) {
        guard activeRouteFocusClaim == claim else { return }
        activeRouteFocusClaim = nil
        activeRouteFocusClaimOrigin = nil
        activeRouteFocusClaimDestination = nil
    }

    func cancelActiveRouteFocusClaim() {
        guard let activeRouteFocusClaim else { return }
        completeRouteFocusClaim(activeRouteFocusClaim)
    }

    private func sidebarContext() -> (window: NSWindow, sidebar: NSTableView)? {
        guard let window = anchorView?.window,
            let contentView = window.contentView,
            let sidebar = Self.sidebarTable(anchor: anchorView, in: contentView),
            sidebar.window === window,
            !sidebar.isHiddenOrHasHiddenAncestor,
            !sidebar.visibleRect.isEmpty
        else {
            return nil
        }
        return (window, sidebar)
    }

    private func detailContext() -> (window: NSWindow, anchor: NSView)? {
        guard let detailAnchorView,
            let window = detailAnchorView.window,
            !detailAnchorView.isHiddenOrHasHiddenAncestor
        else {
            return nil
        }
        return (window, detailAnchorView)
    }

    private static func sidebarTable(anchor: NSView?, in root: NSView) -> NSTableView? {
        var ancestor = anchor
        while let view = ancestor {
            if let table = view as? NSTableView {
                return table
            }
            if let table = view.enclosingScrollView?.documentView as? NSTableView {
                return table
            }
            ancestor = view.superview
        }
        return descendantTables(in: root).min { lhs, rhs in
            let lhsFrame = lhs.convert(lhs.bounds, to: nil)
            let rhsFrame = rhs.convert(rhs.bounds, to: nil)
            if lhsFrame.minX != rhsFrame.minX {
                return lhsFrame.minX < rhsFrame.minX
            }
            return lhsFrame.height > rhsFrame.height
        }
    }

    private static func descendantTables(in root: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        if let table = root as? NSTableView {
            result.append(table)
        }
        for child in root.subviews {
            result.append(contentsOf: descendantTables(in: child))
        }
        return result
    }

    private static func isResponder(_ responder: NSResponder?, inside view: NSView) -> Bool {
        guard let responder = normalizedResponder(responder) else { return false }
        if responder === view { return true }
        guard let responderView = responder as? NSView else { return false }
        return responderView.isDescendant(of: view)
    }

    private static func normalizedResponder(_ responder: NSResponder?) -> NSResponder? {
        if let fieldEditor = responder as? NSTextView,
            fieldEditor.isFieldEditor,
            let control = fieldEditor.delegate as? NSResponder
        {
            return control
        }
        return responder
    }

    private static func isLiveInteractiveResponder(
        _ responder: NSResponder?,
        in window: NSWindow
    ) -> Bool {
        if let fieldEditor = responder as? NSTextView,
            fieldEditor.isFieldEditor,
            let control = fieldEditor.delegate as? NSView
        {
            return control.window === window && !control.isHiddenOrHasHiddenAncestor
        }
        guard let view = responder as? NSView,
            view.window === window,
            !view.isHiddenOrHasHiddenAncestor
        else {
            return false
        }
        return true
    }

    private static func isKeyboardFocusVacuum(
        _ responder: NSResponder?,
        in window: NSWindow
    ) -> Bool {
        guard let responder = normalizedResponder(responder) else { return true }
        if responder === window { return true }
        guard let responderView = responder as? NSView else { return false }
        return responderView.window !== window || responderView.isHiddenOrHasHiddenAncestor
    }
}

private struct SidebarFocusAnchor: NSViewRepresentable {
    let coordinator: SidebarFocusCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        coordinator.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        coordinator.anchorView = view
    }
}

private struct DetailFocusAnchor: NSViewRepresentable {
    let coordinator: SidebarFocusCoordinator

    func makeNSView(context: Context) -> DetailKeyboardFocusAnchorView {
        let view = DetailKeyboardFocusAnchorView(frame: .zero)
        coordinator.detailAnchorView = view
        return view
    }

    func updateNSView(_ view: DetailKeyboardFocusAnchorView, context: Context) {
        coordinator.detailAnchorView = view
    }
}

private final class DetailKeyboardFocusAnchorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("main-detail-focus-anchor")
        setAccessibilityElement(false)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        let unsupportedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard event.keyCode == 48, unsupportedModifiers.isEmpty, let window else {
            super.keyDown(with: event)
            return
        }

        let previousResponder = window.firstResponder
        window.recalculateKeyViewLoop()
        if event.modifierFlags.contains(.shift) {
            window.selectPreviousKeyView(self)
        } else {
            window.selectNextKeyView(self)
        }
        if window.firstResponder === previousResponder {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private func waitForMainRunLoopDefaultMode() async {
    let waiter = MainRunLoopTurnWaiter()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            waiter.install(continuation)
            scheduleOnMainRunLoopDefaultMode {
                waiter.resume()
            }
        }
    } onCancel: {
        waiter.resume()
    }
}

@MainActor
func scheduleOnMainRunLoopDefaultMode(
    _ operation: @escaping @MainActor @Sendable () -> Void
) {
    RunLoop.main.perform(inModes: [.default]) {
        MainActor.assumeIsolated {
            operation()
        }
    }
}

@MainActor
func scheduleOnMainRunLoopInteractiveModes(
    _ operation: @escaping @MainActor @Sendable () -> Void
) {
    RunLoop.main.perform(inModes: [.eventTracking, .common]) {
        MainActor.assumeIsolated {
            operation()
        }
    }
}

private final class MainRunLoopTurnWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isCompleted = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isCompleted {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

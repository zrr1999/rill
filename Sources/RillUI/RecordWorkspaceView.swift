import AppKit
import RillCore
import RillRuntime
import SwiftUI

enum RecordWorkspacePresentation: Equatable {
    case split
    case list
    case inspector
}

enum RecordWorkspaceLayoutPolicy {
    /// The split needs enough room for useful record rows and an inspector;
    /// below this width, keeping both visible makes neither pane usable.
    static let splitMinimumWidth: CGFloat = 700

    static func presentation(
        availableWidth: CGFloat,
        hasSelectedRecord: Bool
    ) -> RecordWorkspacePresentation {
        guard availableWidth >= splitMinimumWidth else {
            return hasSelectedRecord ? .inspector : .list
        }
        return .split
    }
}

private enum RecordWorkspaceViewMetrics {
    /// Square payload thumbnail at the leading edge of a record row.
    static let recordIconSize: CGFloat = 30
    /// Standard sheet width (create collection, membership picker).
    static let sheetWidth: CGFloat = 420
    /// Wider sheets that host an editor or impact list.
    static let wideSheetWidth: CGFloat = 520
    /// Collection list height inside the membership sheet.
    static let membershipListHeight: CGFloat = 260
    /// Editor height inside the replacement sheet.
    static let replacementEditorHeight: CGFloat = 220
}

private struct RecordDetailRequest: Equatable {
    let subject: RecordReuseSubject?
    let navigationGeneration: Int
}

public struct RecordWorkspaceView: View {
    @Bindable private var workspace: RecordWorkspaceModel
    private let language: AppLanguage
    private let deliverSelection: (@MainActor @Sendable (RecordDeliverySubject) -> Void)?
    /// Frontmost-application context captured when the floating panel was
    /// shown; nil in the main-window Records page.
    private let sourceAppContext: RecordRouteContext?

    @State private var isCreatingCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionPreset: RecordCollectionPreset = .stack
    @State private var collectionIDsToAdd: Set<RecordCollectionID> = []
    @State private var membershipRecordID: RecordID?
    @State private var replacementRecordID: RecordID?
    @State private var replacementText = ""
    @State private var replacesInAllCollections = false
    private let copySelection: (@MainActor (RecordReuseSubject) async -> RecordReuseOutcome)?
    @State private var showsCollectionSettings = false
    @State private var showsRules = false
    @State private var copyFeedback: QuickRecordText?
    @State private var isCopying = false
    @FocusState private var detailFocused: Bool
    @AccessibilityFocusState private var detailAccessibilityFocused: Bool
    @State private var showsCompactList = false
    @State private var selectedRecordDetail: RecordProjection?

    public init(
        workspace: RecordWorkspaceModel,
        language: AppLanguage,
        deliverSelection: (@MainActor @Sendable (RecordDeliverySubject) -> Void)? = nil,
        sourceAppContext: RecordRouteContext? = nil,
        copySelection: (@MainActor (RecordReuseSubject) async -> RecordReuseOutcome)? = nil
    ) {
        self.workspace = workspace
        self.language = language
        self.deliverSelection = deliverSelection
        self.sourceAppContext = sourceAppContext
        self.copySelection = copySelection
    }

    public var body: some View {
        VStack(spacing: 0) {
            recordsWorkspace
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .layoutPriority(1)
        }
        .navigationTitle(workspace.selectedCollection?.name ?? L10n.workspace(.allRecords, language: language))
        .toolbar { ToolbarItem { recordActionsMenu } }
        .sheet(isPresented: $showsCollectionSettings) {
            VStack(alignment: .leading, spacing: RillSpacing.panel) {
                Text(L10n.workspace(.collectionSettings, language: language)).font(.headline)
                if let collection = workspace.selectedCollection { collectionPolicyBar(collection) }
                HStack {
                    if let collection = workspace.selectedCollection {
                        Button(L10n.recordText(.deleteCollection, language: language), role: .destructive) {
                            showsCollectionSettings = false
                            Task { await workspace.requestCollectionDeletion(collection.id) }
                        }
                    }
                    Spacer()
                    Button(L10n.workspace(.done, language: language)) { showsCollectionSettings = false }
                        .keyboardShortcut(.cancelAction)
                }
            }.padding(RillSpacing.page).frame(width: 580)
        }
        .sheet(isPresented: $showsRules) {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.workspace(.recordRules, language: language)).font(.headline)
                    Spacer()
                    Button(L10n.workspace(.done, language: language)) { showsRules = false }
                        .keyboardShortcut(.cancelAction)
                }.padding()
                RecordRouteEditorView(workspace: workspace, language: language)
            }.frame(minWidth: 660, minHeight: 500)
        }
        .task { await workspace.refresh() }
        .task(id: RecordDetailRequest(subject: workspace.selectedVisibleRecord?.reuseSubject, navigationGeneration: workspace.navigationGeneration)) {
            selectedRecordDetail = nil
            guard let subject = workspace.selectedVisibleRecord?.reuseSubject else { return }
            let record = await workspace.loadRecord(subject.recordID)
            guard !Task.isCancelled, workspace.selectedVisibleRecord?.reuseSubject == subject else { return }
            selectedRecordDetail = record
            copyFeedback = nil
            if record != nil, workspace.revealedRecordID == record?.id {
                showsCompactList = false
                await waitForMainRunLoopDefaultMode()
                guard !Task.isCancelled, workspace.selectedVisibleRecord?.reuseSubject == subject else { return }
                detailFocused = true
                detailAccessibilityFocused = true
            }
        }
        .sheet(isPresented: $isCreatingCollection) { createCollectionSheet }
        .sheet(isPresented: membershipSheetIsPresented) { membershipSheet }
        .sheet(isPresented: replacementSheetIsPresented) { replacementSheet }
        .sheet(item: deletionImpactBinding) { impact in
            collectionDeletionImpactSheet(impact)
        }
        .sheet(isPresented: Binding(get: { workspace.cleanup.plan != nil }, set: { if !$0 { workspace.cleanup.cancel() } })) {
            RecordCleanupSheet(model: workspace.cleanup, language: language)
        }
        .alert(
            L10n.recordText(.recordsUpdateFailedTitle, language: language),
            isPresented: errorIsPresented
        ) {
            Button(L10n.recordText(.ok, language: language)) { dismissError() }
        } message: {
            // Friendly guidance first; the original error detail stays visible
            // below it for diagnostics.
            Text(L10n.recordText(.recordsUpdateFailedSuggestion, language: language))
            if let errorMessage = workspace.errorMessage, !errorMessage.isEmpty {
                Text(L10n.recordsUpdateFailureReason(errorMessage, language: language))
            }
            if let message = workspace.cleanup.message {
                Text(L10n.quickRecord(message, language: language))
            }
        }
    }

    private var recordActionsMenu: some View {
        Menu {
            Button(L10n.recordText(.newCollection, language: language)) { isCreatingCollection = true }
            if workspace.selectedCollection != nil {
                Button(L10n.workspace(.collectionSettings, language: language)) { showsCollectionSettings = true }
            }
            Button(L10n.workspace(.recordRules, language: language)) { showsRules = true }
        } label: {
            Label(L10n.presentation(.moreActions, language: language), systemImage: RillSystemSymbol.ellipsisCircle.rawValue)
        }
        .accessibilityIdentifier("records.actions")
    }

    private var recordsWorkspace: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                recordsContent(
                    RecordWorkspaceLayoutPolicy.presentation(
                        availableWidth: geometry.size.width,
                        hasSelectedRecord: selectedRecord != nil && !showsCompactList
                    ),
                    availableWidth: geometry.size.width
                )
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
            }
            .layoutPriority(1)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private func recordsContent(_ presentation: RecordWorkspacePresentation, availableWidth: CGFloat) -> some View {
        if workspace.visibleRecords.isEmpty {
            recordList
        } else {
        switch presentation {
        case .split:
            HSplitView {
                recordList
                    .frame(
                        minWidth: 300,
                        idealWidth: 360,
                        maxWidth: min(440, availableWidth - 360),
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                recordInspector
                    .frame(
                        minWidth: 340,
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .list:
            recordList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .inspector:
            compactRecordInspector
        }
        }
    }

    private var compactRecordInspector: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showsCompactList = true
                } label: {
                    Label(
                        workspace.selectedCollection?.name
                            ?? L10n.workspace(.allRecords, language: language),
                        systemImage: RillSystemSymbol.chevronLeft.rawValue
                    )
                }
                .buttonStyle(RecordWorkspaceHoverButtonStyle())
                .accessibilityIdentifier("records.back")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            recordInspector
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func collectionPolicyBar(_ collection: RecordCollection) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                collectionPresetPicker(collection)
                collectionSelectionPicker(collection)
                collectionConsumptionPicker(collection)
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 10) {
                collectionPresetPicker(collection)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 16) {
                    collectionSelectionPicker(collection)
                    collectionConsumptionPicker(collection)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(workspace.isMutating)
    }

    private func collectionPresetPicker(_ collection: RecordCollection) -> some View {
        Picker(L10n.recordText(.preset, language: language), selection: Binding(
            get: { collection.matchingPreset },
            set: { preset in
                guard let preset else { return }
                Task { await workspace.updateCollection(collection.id, preset: preset) }
            }
        )) {
            Text(L10n.recordText(.collectionPresetStack, language: language)).tag(Optional(RecordCollectionPreset.stack))
            Text(L10n.recordText(.collectionPresetQueue, language: language)).tag(Optional(RecordCollectionPreset.queue))
            Text(L10n.recordText(.collectionPresetList, language: language)).tag(Optional(RecordCollectionPreset.list))
            if collection.matchingPreset == nil {
                Text(UIStrings.text(.workflowCustom, language: language)).tag(Optional<RecordCollectionPreset>.none)
            }
        }
        .pickerStyle(.segmented)
    }

    private func collectionSelectionPicker(_ collection: RecordCollection) -> some View {
        Picker(L10n.recordText(.selectionPolicy, language: language), selection: Binding(
            get: { collection.selectionPolicy },
            set: { policy in
                Task { await workspace.updateCollection(collection.id, selectionPolicy: policy) }
            }
        )) {
            Text(L10n.recordText(.selectionNewest, language: language)).tag(RecordSelectionPolicy.newestFirst)
            Text(L10n.recordText(.selectionOldest, language: language)).tag(RecordSelectionPolicy.oldestFirst)
            Text(L10n.recordText(.selectionManual, language: language)).tag(RecordSelectionPolicy.manual)
        }
    }

    private func collectionConsumptionPicker(_ collection: RecordCollection) -> some View {
        Picker(L10n.recordText(.consumptionPolicy, language: language), selection: Binding(
            get: { collection.consumptionPolicy },
            set: { policy in
                Task { await workspace.updateCollection(collection.id, consumptionPolicy: policy) }
            }
        )) {
            Text(L10n.recordText(.consumptionRetain, language: language)).tag(RecordConsumptionPolicy.retain)
            Text(L10n.recordText(.consumptionConsume, language: language)).tag(RecordConsumptionPolicy.consumeAfterSuccessfulDelivery)
        }
    }

    private var hasRecordFilters: Bool {
        !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || workspace.showsPinnedOnly || workspace.sourceAppFilterBundleIdentifier != nil || workspace.payloadKindFilter != nil
    }

    private var recordSources: [(id: String, name: String)] {
        let names = workspace.snapshot.records.reduce(into: [String: String]()) { names, record in
            guard let id = record.header.provenance.sourceBundleIdentifier else { return }
            names[id] = record.header.provenance.sourceApplicationName ?? id
        }
        return names.map { (id: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var recordList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(L10n.workspace(.allTypes, language: language), selection: $workspace.payloadKindFilter) {
                    Text(L10n.workspace(.allTypes, language: language)).tag(Optional<RecordPayloadKind>.none)
                    Text(L10n.quickRecord(.text, language: language)).tag(Optional(RecordPayloadKind.text))
                    Text(L10n.recordText(.imagePayload, language: language)).tag(Optional(RecordPayloadKind.image))
                    Text(L10n.quickRecord(.files, language: language)).tag(Optional(RecordPayloadKind.files))
                }.labelsHidden()
                Spacer(minLength: 0)
                Toggle(isOn: $workspace.showsPinnedOnly) {
                    Image(systemName: RillSystemSymbol.pinFill.rawValue)
                }
                .toggleStyle(.button)
                .help(L10n.recordText(.pinnedOnly, language: language))
                .accessibilityLabel(L10n.recordText(.pinnedOnly, language: language))
                if deliverSelection != nil {
                    Toggle(sourceAppFilterTitle, isOn: sourceAppFilterBinding)
                        .toggleStyle(.button)
                        .disabled(sourceAppContext?.bundleIdentifier == nil)
                } else {
                    Picker(L10n.workspace(.source, language: language), selection: $workspace.sourceAppFilterBundleIdentifier) {
                        Text(L10n.workspace(.allSources, language: language)).tag(Optional<String>.none)
                        ForEach(recordSources, id: \.id) { source in
                            Text(source.name).tag(Optional(source.id))
                        }
                    }.labelsHidden()
                }
            }
            .padding(12)
            Divider()
            if workspace.unavailableRecordID != nil {
                Label(L10n.workspace(.recordUnavailable, language: language), systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
                    .font(.callout).padding()
            }
            if workspace.isLoading && workspace.snapshot.revision == 0 {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.visibleRecords.isEmpty {
                ContentUnavailableView(
                    hasRecordFilters ? L10n.presentation(.noMatchingRecords, language: language)
                        : L10n.recordText(.noRecordsTitle, language: language),
                    systemImage: RillSystemSymbol.tray.rawValue,
                    description: Text(hasRecordFilters
                        ? L10n.presentation(.noMatchingRecordsDetail, language: language)
                        : L10n.recordText(.noRecordsDescription, language: language))
                )
                if hasRecordFilters {
                    Button(L10n.presentation(.clearFilters, language: language)) {
                        workspace.searchText = ""
                        workspace.showsPinnedOnly = false
                        workspace.sourceAppFilterBundleIdentifier = nil
                        workspace.payloadKindFilter = nil
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, RillSpacing.panel)
                }
            } else {
                ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { workspace.selectedRecordID },
                    set: { workspace.selectedRecordID = $0; showsCompactList = false }
                )) {
                    ForEach(Array(workspace.visibleRecords.enumerated()), id: \.element.id) { index, projection in
                        recordRow(projection, index: index)
                            .onTapGesture {
                                workspace.selectedRecordID = projection.id
                                showsCompactList = false
                            }
                            .accessibilityAction {
                                workspace.selectedRecordID = projection.id
                                showsCompactList = false
                            }
                            .tag(projection.id)
                            .id(projection.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .onChange(of: workspace.navigationGeneration) { _, _ in
                    if let id = workspace.selectedRecordID { proxy.scrollTo(id) }
                }
                .onChange(of: workspace.selectedRecordID) { _, id in
                    if let id, workspace.revealedRecordID == id { proxy.scrollTo(id) }
                }
                .onAppear {
                    if let id = workspace.selectedRecordID { proxy.scrollTo(id) }
                }
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private func recordRow(_ projection: RecordSummary, index: Int? = nil) -> some View {
        HStack(alignment: .top, spacing: RillSpacing.row) {
            if deliverSelection != nil, let index, index < 9 {
                digitBadge(index + 1).frame(width: 20)
            }
            Image(systemName: projection.header.kind == .image ? RillSystemSymbol.photo.rawValue : (projection.header.kind == .files ? RillSystemSymbol.docOnDoc.rawValue : RillSystemSymbol.textAlignLeft.rawValue))
                .frame(
                    width: RecordWorkspaceViewMetrics.recordIconSize,
                    height: RecordWorkspaceViewMetrics.recordIconSize
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(projection.header.kind == .image ? L10n.recordText(.imagePayload, language: language) : projection.header.preview)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if projection.metadata.isPinned {
                        Image(systemName: RillSystemSymbol.pinFill.rawValue).foregroundStyle(Color.accentColor)
                    }

                }
                HStack(spacing: RillSpacing.row) {
                    Text(sourceName(projection.header.provenance)).lineLimit(1)
                    Text(projection.header.createdAt, style: .relative).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(projection.header.kind == .image ? L10n.recordText(.imagePayload, language: language) : projection.header.preview)
        .accessibilityValue(projection.memberships.map { workspace.collectionName($0.collectionID) }.joined(separator: ", "))
    }

    @ViewBuilder
    private var recordInspector: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(sourceName(record.record.provenance)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let copySelection {
                            Button {
                                guard !isCopying else { return }
                                isCopying = true
                                Task {
                                    let outcome = await copySelection(RecordReuseSubject(recordID: record.id, metadataRevision: record.metadata.revision))
                                    isCopying = false
                                    guard selectedRecord?.id == record.id else { return }
                                    copyFeedback = outcome.feedback
                                }
                            } label: {
                                Label(L10n.workspace(.copy, language: language), systemImage: RillSystemSymbol.docOnDoc.rawValue)
                            }
                            .disabled(isCopying)
                            .accessibilityIdentifier("records.copy")
                        }
                    }
                    if let copyFeedback {
                        Text(L10n.quickRecord(copyFeedback, language: language))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    payloadPreview(record.record)
                        .focusable().focused($detailFocused)
                        .accessibilityFocused($detailAccessibilityFocused)
                        .accessibilityIdentifier("records.detail")
                    if let deliverSelection,
                       let subject = workspace.selectedListDeliverySubject {
                        Button {
                            deliverSelection(subject)
                        } label: {
                            Label(
                                RecordDeliveryTitle.make(applicationName: sourceAppContext?.applicationName, language: language),
                                systemImage: RillSystemSymbol.textInsert.rawValue
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.isMutating)
                    }
                    HStack {
                        Button {
                            Task {
                                await workspace.updateMetadata(
                                    for: record,
                                    isPinned: !record.metadata.isPinned
                                )
                            }
                        } label: {
                            Label(
                                record.metadata.isPinned
                                    ? UIStrings.text(.clipboardUnpinItem, language: language)
                                    : UIStrings.text(.clipboardPinItem, language: language),
                                systemImage: record.metadata.isPinned
                                    ? RillSystemSymbol.pinSlash.rawValue
                                    : RillSystemSymbol.pin.rawValue
                            )
                        }
                        Button {
                            collectionIDsToAdd = []
                            membershipRecordID = record.id
                        } label: {
                            Label(L10n.recordText(.addToCollections, language: language), systemImage: RillSystemSymbol.rectangleStackBadgePlus.rawValue)
                        }
                    }
                    membershipInspector(record)
                    DisclosureGroup(L10n.presentation(.metadata, language: language)) {
                        metadataInspector(record)
                    }
                    if case .text(let textValue) = record.record.payload,
                       let membership = preferredMembership(for: record) {
                        Button(L10n.presentation(.editText, language: language)) {
                            replacementRecordID = record.id
                            replacementText = textValue
                            replacesInAllCollections = false
                        }
                        .disabled(membership.state != .active || workspace.isMutating)
                    }
                    Menu {
                        Button(role: .destructive) {
                            Task { await workspace.deleteRecord(record.id) }
                        } label: {
                            Label(L10n.recordText(.deleteRecordEverywhere, language: language), systemImage: RillSystemSymbol.trash.rawValue)
                        }
                    } label: {
                        Label(L10n.presentation(.moreActions, language: language), systemImage: RillSystemSymbol.ellipsisCircle.rawValue)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                L10n.recordText(.selectRecordPrompt, language: language),
                systemImage: RillSystemSymbol.docTextMagnifyingglass.rawValue
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func membershipInspector(_ record: RecordProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UIStrings.text(.recordCollections, language: language)).font(.headline)
            if record.memberships.isEmpty {
                Text(L10n.recordText(.noMembershipHint, language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(record.memberships) { membership in
                HStack {
                    membershipChip(workspace.collectionName(membership.collectionID))
                    Text(membership.state == .active
                        ? L10n.recordText(.membershipActive, language: language)
                        : L10n.recordText(.membershipConsumed, language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await workspace.removeMembership(membership) }
                    } label: {
                        Image(systemName: RillSystemSymbol.xmarkCircle.rawValue)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.recordText(.removeFromThisCollection, language: language))
                    .accessibilityLabel(L10n.removeFromCollection(
                        workspace.collectionName(membership.collectionID),
                        language: language
                    ))
                }
            }
        }
    }

    private func metadataInspector(_ record: RecordProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.recordText(.metadataTitle, language: language)).font(.headline)
            LabeledContent(L10n.recordText(.metadataSource, language: language)) {
                Text(sourceName(record.record.provenance))
            }
            LabeledContent(L10n.recordText(.metadataUses, language: language)) {
                Text("\(record.activity.useCount)")
            }
            LabeledContent(L10n.recordText(.metadataTags, language: language)) {
                Text(record.metadata.tags.isEmpty ? "—" : record.metadata.tags.joined(separator: ", "))
            }
        }
    }

    private var createCollectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.recordText(.newCollection, language: language)).font(.title2.weight(.semibold))
            TextField(L10n.recordText(.collectionNameField, language: language), text: $newCollectionName)
            Picker(L10n.recordText(.preset, language: language), selection: $newCollectionPreset) {
                Text(L10n.recordText(.collectionPresetStack, language: language)).tag(RecordCollectionPreset.stack)
                Text(L10n.recordText(.collectionPresetQueue, language: language)).tag(RecordCollectionPreset.queue)
                Text(L10n.recordText(.collectionPresetList, language: language)).tag(RecordCollectionPreset.list)
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button(L10n.recordText(.cancel, language: language)) { isCreatingCollection = false }
                Button(UIStrings.text(.clipboardCreate, language: language)) {
                    let name = newCollectionName
                    let preset = newCollectionPreset
                    isCreatingCollection = false
                    newCollectionName = ""
                    Task { await workspace.createCollection(name: name, preset: preset) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: RecordWorkspaceViewMetrics.sheetWidth)
    }

    private var membershipSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.recordText(.addToCollections, language: language)).font(.title2.weight(.semibold))
            List(workspace.snapshot.collections, selection: $collectionIDsToAdd) { collection in
                Text(collection.name).tag(collection.id)
            }
            .frame(height: RecordWorkspaceViewMetrics.membershipListHeight)
            HStack {
                Spacer()
                Button(L10n.recordText(.cancel, language: language)) { membershipRecordID = nil }
                Button(L10n.recordText(.add, language: language)) {
                    guard let recordID = membershipRecordID else { return }
                    let collectionIDs = Array(collectionIDsToAdd)
                    membershipRecordID = nil
                    Task { await workspace.addRecord(recordID, to: collectionIDs) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(collectionIDsToAdd.isEmpty)
            }
        }
        .padding(20)
        .frame(width: RecordWorkspaceViewMetrics.sheetWidth)
    }

    private var replacementSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.presentation(.editText, language: language))
                .font(.title2.weight(.semibold))
            Toggle(L10n.recordText(.replaceInAllCollections, language: language), isOn: $replacesInAllCollections)
                .disabled(selectedRecord.map { $0.memberships.count < 2 || preferredMembership(for: $0)?.state != .active } ?? true)
            TextEditor(text: $replacementText)
                .font(.body)
                .frame(height: RecordWorkspaceViewMetrics.replacementEditorHeight)
                .overlay(RoundedRectangle(cornerRadius: RillRadius.chip).stroke(.quaternary))
            Text(L10n.recordText(.replaceDescription, language: language))
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error = workspace.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(L10n.recordText(.cancel, language: language)) { replacementRecordID = nil }
                Button(L10n.recordText(.replace, language: language)) { performReplacement() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.isMutating)
            }
        }
        .padding(20)
        .frame(width: RecordWorkspaceViewMetrics.wideSheetWidth)
    }

    private func collectionDeletionImpactSheet(_ impact: RecordCollectionDeletionImpact) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.recordText(.collectionReferencesTitle, language: language)).font(.title2.weight(.semibold))
            Text(L10n.collectionReferencesUsage(
                captureRouteCount: impact.captureRuleIDs.count,
                deliveryRouteCount: impact.deliveryRuleIDs.count,
                language: language
            ))
            Text(L10n.recordText(.collectionReferencesHint, language: language))
            .foregroundStyle(.secondary)
            LabeledContent(L10n.quickRecord(.memberships, language: language), value: "\(impact.membershipCount)")
            Text(L10n.quickRecord(.collectionDeletion, language: language)).foregroundStyle(.secondary)
            if impact.hasRouteReferences {
            ForEach(workspace.snapshot.collections.filter { $0.id != impact.collectionID }) { collection in
                Button(L10n.replaceWithCollection(collection.name, language: language)) {
                    Task {
                        await workspace.confirmCollectionDeletion(
                            impact.collectionID,
                            resolution: .replace(with: collection.id)
                        )
                    }
                }
            }
            }
            Divider()
            HStack {
                Button(impact.hasRouteReferences ? L10n.recordText(.disableAffectedRoutes, language: language) : L10n.quickRecord(.delete, language: language), role: .destructive) {
                    Task {
                        await workspace.confirmCollectionDeletion(
                            impact.collectionID,
                            resolution: impact.hasRouteReferences ? .disableAffectedRoutes : nil
                        )
                    }
                }
                Spacer()
                Button(L10n.recordText(.cancel, language: language)) { workspace.cancelCollectionDeletion() }
            }
        }
        .padding(20)
        .frame(width: RecordWorkspaceViewMetrics.wideSheetWidth)
    }

    private var selectedRecord: RecordProjection? {
        guard let summary = workspace.selectedVisibleRecord, let selectedRecordDetail,
              selectedRecordDetail.id == summary.id,
              selectedRecordDetail.metadata.revision == summary.metadata.revision else { return nil }
        return selectedRecordDetail
    }

    private func preferredMembership(for record: RecordProjection) -> RecordMembership? {
        if let collectionID = workspace.selectedCollectionID,
           let membership = record.memberships.first(where: { $0.collectionID == collectionID }) {
            return membership
        }
        return record.memberships.first
    }

    private func performReplacement() {
        guard let record = selectedRecord, let membership = preferredMembership(for: record) else {
            replacementRecordID = nil
            return
        }
        let textValue = replacementText
        let all = replacesInAllCollections
        guard !workspace.isMutating else { return }
        Task {
            await workspace.replaceText(
                membership: membership,
                text: textValue,
                inAllCollections: all
            )
            if workspace.errorMessage == nil { replacementRecordID = nil }
        }
    }

    private func payloadTitle(_ payload: RecordPayload) -> String {
        switch payload {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.recordText(.emptyTextPayload, language: language) : trimmed
        case .image:
            return L10n.recordText(.imagePayload, language: language)
        case .files(let urls):
            return urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }

    @ViewBuilder
    private func payloadPreview(_ record: Record) -> some View {
        switch record.payload {
        case .text(let value):
            RecordTextPreview(text: value, language: language)
        case .image(let data):
            RecordImagePreview(id: record.id, data: data).frame(maxHeight: 280)
        case .files(let urls):
            VStack(alignment: .leading) {
                ForEach(urls, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: RillSystemSymbol.doc.rawValue)
                }
            }
        }
    }

    private func digitBadge(_ number: Int) -> some View {
        Text(number, format: .number)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: RillRadius.chip, style: .continuous))
            .help(L10n.recordText(.digitInsertHint, language: language))
    }

    private func membershipChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // RillCard regular-tier fill; a Capsule chip cannot use rillCard itself.
            .background(.quaternary.opacity(RillCardProminence.regular.fillOpacity), in: Capsule())
    }

    private func sourceName(_ provenance: RecordProvenance) -> String {
        provenance.sourceApplicationName
            ?? provenance.workflow?.fallbackName
            ?? provenance.source.kind.rawValue
    }

    private var membershipSheetIsPresented: Binding<Bool> {
        Binding(get: { membershipRecordID != nil }, set: { if !$0 { membershipRecordID = nil } })
    }

    private var sourceAppFilterTitle: String {
        if let applicationName = sourceAppContext?.applicationName {
            return L10n.onlyFromSourceApp(applicationName, language: language)
        }
        return L10n.recordText(.currentAppSourceOnly, language: language)
    }

    private var sourceAppFilterBinding: Binding<Bool> {
        Binding(
            get: { workspace.sourceAppFilterBundleIdentifier != nil },
            set: { isOn in
                workspace.sourceAppFilterBundleIdentifier = isOn ? sourceAppContext?.bundleIdentifier : nil
            }
        )
    }

    private var replacementSheetIsPresented: Binding<Bool> {
        Binding(get: { replacementRecordID != nil }, set: { if !$0 { replacementRecordID = nil } })
    }

    private var deletionImpactBinding: Binding<RecordCollectionDeletionImpact?> {
        Binding(
            get: { workspace.pendingCollectionDeletion },
            set: { if $0 == nil { workspace.cancelCollectionDeletion() } }
        )
    }


    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: {
                (workspace.errorMessage != nil && replacementRecordID == nil)
                    || (workspace.cleanup.plan == nil && workspace.cleanup.message != nil)
            },
            set: { if !$0 { dismissError() } }
        )
    }

    private func dismissError() {
        workspace.dismissError()
        if workspace.cleanup.plan == nil { workspace.cleanup.cancel() }
    }
}

/// Plain label buttons still need a pointer acknowledgement; this style tints
/// the label on hover and follows RillCardButtonStyle's Reduce Motion rule.
private struct RecordWorkspaceHoverButtonStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

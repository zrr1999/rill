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

public struct RecordWorkspaceView: View {
    private enum Pane: String, CaseIterable {
        case records
        case routes
    }

    @Bindable private var workspace: RecordWorkspaceModel
    private let language: AppLanguage
    private let deliverSelection: (@MainActor @Sendable (RecordDeliverySubject) -> Void)?

    @State private var isCreatingCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionPreset: RecordCollectionPreset = .stack
    @State private var collectionIDsToAdd: Set<RecordCollectionID> = []
    @State private var membershipRecordID: RecordID?
    @State private var replacementRecordID: RecordID?
    @State private var replacementText = ""
    @State private var replacesInAllCollections = false
    @State private var recordPendingGlobalDeletion: RecordID?
    @State private var pane: Pane = .records

    public init(
        workspace: RecordWorkspaceModel,
        language: AppLanguage,
        deliverSelection: (@MainActor @Sendable (RecordDeliverySubject) -> Void)? = nil
    ) {
        self.workspace = workspace
        self.language = language
        self.deliverSelection = deliverSelection
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch pane {
                case .records:
                    recordsWorkspace
                case .routes:
                    RecordRouteEditorView(workspace: workspace, language: language)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .layoutPriority(1)
        }
        .task { await workspace.refresh() }
        .sheet(isPresented: $isCreatingCollection) { createCollectionSheet }
        .sheet(isPresented: membershipSheetIsPresented) { membershipSheet }
        .sheet(isPresented: replacementSheetIsPresented) { replacementSheet }
        .sheet(item: deletionImpactBinding) { impact in
            collectionDeletionImpactSheet(impact)
        }
        .alert(
            L10n.recordText(.deleteRecordEverywhereConfirmationTitle, language: language),
            isPresented: globalDeletionAlertIsPresented,
            presenting: recordPendingGlobalDeletion
        ) { recordID in
            Button(L10n.recordText(.deleteRecord, language: language), role: .destructive) {
                Task { await workspace.deleteRecord(recordID) }
            }
            Button(L10n.recordText(.cancel, language: language), role: .cancel) {}
        } message: { _ in
            Text(L10n.recordText(.deleteRecordEverywhereDetail, language: language))
        }
        .alert(
            L10n.recordText(.recordsUpdateFailedTitle, language: language),
            isPresented: errorIsPresented
        ) {
            Button(L10n.recordText(.ok, language: language)) { workspace.dismissError() }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                headerSummary
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 16)
                panePicker
                recordHeaderActions
            }

            VStack(alignment: .leading, spacing: 12) {
                headerSummary
                HStack(spacing: 12) {
                    panePicker
                    Spacer(minLength: 0)
                    recordHeaderActions
                }
            }
        }
        .padding(16)
    }

    private var headerSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(pane == .routes
                    ? L10n.recordText(.recordRoutesTitle, language: language)
                    : workspace.selectedCollection?.name
                        ?? L10n.string(.clipboardHistoryTitle, language: language))
                    .font(.title2.weight(.semibold))
                if pane == .records {
                    Text("\(workspace.visibleRecords.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel(L10n.recordCount(
                            workspace.visibleRecords.count,
                            language: language
                        ))
                }
            }
            Text(pane == .routes
                ? L10n.recordText(.routesHeaderDetail, language: language)
                : L10n.recordText(.recordsHeaderDetail, language: language))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }

    private var panePicker: some View {
        Picker("", selection: $pane) {
            Text(L10n.recordText(.paneRecords, language: language)).tag(Pane.records)
            Text(L10n.recordText(.paneRoutes, language: language)).tag(Pane.routes)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 190)
    }

    @ViewBuilder
    private var recordHeaderActions: some View {
        if pane == .records {
            HStack(spacing: 8) {
                Button {
                    isCreatingCollection = true
                } label: {
                    Label(L10n.recordText(.newCollection, language: language), systemImage: RillSystemSymbol.plus.rawValue)
                }
                if let collection = workspace.selectedCollection {
                    Button(role: .destructive) {
                        Task { await workspace.requestCollectionDeletion(collection.id) }
                    } label: {
                        Image(systemName: RillSystemSymbol.trash.rawValue)
                    }
                    .help(L10n.recordText(.deleteCollection, language: language))
                    .accessibilityLabel(L10n.recordText(.deleteCollection, language: language))
                    .disabled(workspace.isMutating)
                }
            }
        }
    }

    private var recordsWorkspace: some View {
        VStack(spacing: 0) {
            if let collection = workspace.selectedCollection {
                collectionPolicyBar(collection)
                Divider()
            }
            GeometryReader { geometry in
                recordsContent(
                    RecordWorkspaceLayoutPolicy.presentation(
                        availableWidth: geometry.size.width,
                        hasSelectedRecord: selectedRecord != nil
                    )
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
    private func recordsContent(_ presentation: RecordWorkspacePresentation) -> some View {
        switch presentation {
        case .split:
            HSplitView {
                recordList
                    .frame(
                        minWidth: 300,
                        idealWidth: 360,
                        maxWidth: 440,
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

    private var compactRecordInspector: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    workspace.selectedRecordID = nil
                } label: {
                    Label(
                        workspace.selectedCollection?.name
                            ?? L10n.string(.clipboardHistoryTitle, language: language),
                        systemImage: RillSystemSymbol.chevronLeft.rawValue
                    )
                }
                .buttonStyle(.plain)
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
        .frame(width: 280)
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

    private var recordList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(UIStrings.text(.clipboardSearch, language: language), text: $workspace.searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: $workspace.showsPinnedOnly) {
                    Image(systemName: RillSystemSymbol.pinFill.rawValue)
                }
                .toggleStyle(.button)
                .help(L10n.recordText(.pinnedOnly, language: language))
                .accessibilityLabel(L10n.recordText(.pinnedOnly, language: language))
            }
            .padding(12)
            Divider()
            if workspace.isLoading && workspace.snapshot.revision == 0 {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.visibleRecords.isEmpty {
                ContentUnavailableView(
                    L10n.recordText(.noRecordsTitle, language: language),
                    systemImage: RillSystemSymbol.tray.rawValue,
                    description: Text(L10n.recordText(.noRecordsDescription, language: language))
                )
            } else {
                List(selection: $workspace.selectedRecordID) {
                    ForEach(workspace.visibleRecords) { projection in
                        recordRow(projection)
                            .tag(projection.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private func recordRow(_ projection: RecordProjection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            payloadIcon(projection.record.payload)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(payloadTitle(projection.record.payload))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if projection.metadata.isPinned {
                        Image(systemName: RillSystemSymbol.pinFill.rawValue).foregroundStyle(.orange)
                    }
                    if projection.memberships.isEmpty {
                        membershipChip(L10n.recordText(.noCollection, language: language))
                    } else {
                        ForEach(projection.memberships.prefix(3)) { membership in
                            membershipChip(workspace.collectionName(membership.collectionID))
                        }
                    }
                }
                Text(projection.record.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(payloadTitle(projection.record.payload))
        .accessibilityValue(projection.memberships.map { workspace.collectionName($0.collectionID) }.joined(separator: ", "))
    }

    @ViewBuilder
    private var recordInspector: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    payloadPreview(record.record.payload)
                    if let deliverSelection,
                       let subject = workspace.selectedListDeliverySubject {
                        Button {
                            deliverSelection(subject)
                        } label: {
                            Label(
                                L10n.recordText(.insertInPreviousApp, language: language),
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
                                systemImage: record.metadata.isPinned ? "pin.slash" : "pin"
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
                    metadataInspector(record)
                    if case .text(let textValue) = record.record.payload,
                       let membership = preferredMembership(for: record) {
                        Button(L10n.recordText(.replaceInCurrentCollection, language: language)) {
                            replacementRecordID = record.id
                            replacementText = textValue
                            replacesInAllCollections = false
                        }
                        Button(L10n.recordText(.replaceInAllCollections, language: language)) {
                            replacementRecordID = record.id
                            replacementText = textValue
                            replacesInAllCollections = true
                        }
                        .disabled(record.memberships.count < 2 || membership.state != .active)
                        .help(L10n.recordText(.replaceInAllCollectionsHint, language: language))
                    }
                    Divider()
                    Button(role: .destructive) {
                        recordPendingGlobalDeletion = record.id
                    } label: {
                        Label(L10n.recordText(.deleteRecordEverywhere, language: language), systemImage: RillSystemSymbol.trash.rawValue)
                    }
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
        .frame(width: 420)
    }

    private var membershipSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.recordText(.addToCollections, language: language)).font(.title2.weight(.semibold))
            List(workspace.snapshot.collections, selection: $collectionIDsToAdd) { collection in
                Text(collection.name).tag(collection.id)
            }
            .frame(height: 260)
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
        .frame(width: 420)
    }

    private var replacementSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(replacesInAllCollections
                ? L10n.recordText(.replaceInAllCollections, language: language)
                : L10n.recordText(.replaceInCurrentCollection, language: language))
                .font(.title2.weight(.semibold))
            TextEditor(text: $replacementText)
                .font(.body.monospaced())
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text(L10n.recordText(.replaceDescription, language: language))
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.recordText(.cancel, language: language)) { replacementRecordID = nil }
                Button(L10n.recordText(.replace, language: language)) { performReplacement() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
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
            Divider()
            HStack {
                Button(L10n.recordText(.disableAffectedRoutes, language: language), role: .destructive) {
                    Task {
                        await workspace.confirmCollectionDeletion(
                            impact.collectionID,
                            resolution: .disableAffectedRoutes
                        )
                    }
                }
                Spacer()
                Button(L10n.recordText(.cancel, language: language)) { workspace.cancelCollectionDeletion() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var selectedRecord: RecordProjection? {
        workspace.selectedRecordID.flatMap { id in workspace.snapshot.records.first { $0.id == id } }
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
        replacementRecordID = nil
        Task {
            await workspace.replaceText(
                membership: membership,
                text: textValue,
                inAllCollections: all
            )
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
    private func payloadIcon(_ payload: RecordPayload) -> some View {
        switch payload {
        case .text:
            Image(systemName: RillSystemSymbol.textAlignLeft.rawValue)
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: RillSystemSymbol.photo.rawValue)
            }
        case .files:
            Image(systemName: RillSystemSymbol.docOnDoc.rawValue)
        }
    }

    @ViewBuilder
    private func payloadPreview(_ payload: RecordPayload) -> some View {
        switch payload {
        case .text(let value):
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280)
            } else {
                Label(L10n.recordText(.imageUnavailable, language: language), systemImage: RillSystemSymbol.photoBadgeExclamationmark.rawValue)
            }
        case .files(let urls):
            VStack(alignment: .leading) {
                ForEach(urls, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: RillSystemSymbol.doc.rawValue)
                }
            }
        }
    }

    private func membershipChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // RillCard regular-tier fill; a Capsule chip cannot use rillCard itself.
            .background(.quaternary.opacity(0.35), in: Capsule())
    }

    private func sourceName(_ provenance: RecordProvenance) -> String {
        provenance.sourceApplicationName
            ?? provenance.workflow?.fallbackName
            ?? provenance.source.kind.rawValue
    }

    private var membershipSheetIsPresented: Binding<Bool> {
        Binding(get: { membershipRecordID != nil }, set: { if !$0 { membershipRecordID = nil } })
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

    private var globalDeletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { recordPendingGlobalDeletion != nil },
            set: { if !$0 { recordPendingGlobalDeletion = nil } }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.dismissError() } }
        )
    }
}

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
            text("Delete this record everywhere?", "在所有位置删除这条记录？"),
            isPresented: globalDeletionAlertIsPresented,
            presenting: recordPendingGlobalDeletion
        ) { recordID in
            Button(text("Delete Record", "删除记录"), role: .destructive) {
                Task { await workspace.deleteRecord(recordID) }
            }
            Button(text("Cancel", "取消"), role: .cancel) {}
        } message: { _ in
            Text(text(
                "This removes the immutable record and every collection membership.",
                "这会删除不可变记录及其在所有记录集中的成员关系。"
            ))
        }
        .alert(
            text("Records could not be updated", "无法更新记录"),
            isPresented: errorIsPresented
        ) {
            Button(text("OK", "好")) { workspace.dismissError() }
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
                    ? text("Record Routes", "记录路由")
                    : workspace.selectedCollection?.name ?? text("All Records", "所有记录"))
                    .font(.title2.weight(.semibold))
                if pane == .records {
                    Text("\(workspace.visibleRecords.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel(text(
                            "\(workspace.visibleRecords.count) records",
                            "\(workspace.visibleRecords.count) 条记录"
                        ))
                }
            }
            Text(pane == .routes
                ? text(
                    "Route captures into collections and deliver records to their destinations.",
                    "将采集内容路由到记录集，并把记录投递到目标。"
                )
                : text(
                    "Records are stored once and may belong to multiple collections.",
                    "记录只存储一次，并可同时属于多个记录集。"
                ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }

    private var panePicker: some View {
        Picker("", selection: $pane) {
            Text(text("Records", "记录")).tag(Pane.records)
            Text(text("Routes", "路由")).tag(Pane.routes)
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
                    Label(text("New Collection", "新建记录集"), systemImage: RillSystemSymbol.plus.rawValue)
                }
                if let collection = workspace.selectedCollection {
                    Button(role: .destructive) {
                        Task { await workspace.requestCollectionDeletion(collection.id) }
                    } label: {
                        Image(systemName: RillSystemSymbol.trash.rawValue)
                    }
                    .help(text("Delete Collection", "删除记录集"))
                    .accessibilityLabel(text("Delete Collection", "删除记录集"))
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
                        workspace.selectedCollection?.name ?? text("All Records", "所有记录"),
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
        Picker(text("Preset", "预设"), selection: Binding(
            get: { collection.matchingPreset },
            set: { preset in
                guard let preset else { return }
                Task { await workspace.updateCollection(collection.id, preset: preset) }
            }
        )) {
            Text("Stack").tag(Optional(RecordCollectionPreset.stack))
            Text("Queue").tag(Optional(RecordCollectionPreset.queue))
            Text("List").tag(Optional(RecordCollectionPreset.list))
            if collection.matchingPreset == nil {
                Text(text("Custom", "自定义")).tag(Optional<RecordCollectionPreset>.none)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
    }

    private func collectionSelectionPicker(_ collection: RecordCollection) -> some View {
        Picker(text("Selection", "选取"), selection: Binding(
            get: { collection.selectionPolicy },
            set: { policy in
                Task { await workspace.updateCollection(collection.id, selectionPolicy: policy) }
            }
        )) {
            Text(text("Newest", "最新优先")).tag(RecordSelectionPolicy.newestFirst)
            Text(text("Oldest", "最早优先")).tag(RecordSelectionPolicy.oldestFirst)
            Text(text("Manual", "手动")).tag(RecordSelectionPolicy.manual)
        }
    }

    private func collectionConsumptionPicker(_ collection: RecordCollection) -> some View {
        Picker(text("After Delivery", "投递后"), selection: Binding(
            get: { collection.consumptionPolicy },
            set: { policy in
                Task { await workspace.updateCollection(collection.id, consumptionPolicy: policy) }
            }
        )) {
            Text(text("Retain", "保留")).tag(RecordConsumptionPolicy.retain)
            Text(text("Consume", "消费")).tag(RecordConsumptionPolicy.consumeAfterSuccessfulDelivery)
        }
    }

    private var recordList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(text("Search records", "搜索记录"), text: $workspace.searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: $workspace.showsPinnedOnly) {
                    Image(systemName: RillSystemSymbol.pinFill.rawValue)
                }
                .toggleStyle(.button)
                .help(text("Pinned only", "仅显示置顶记录"))
            }
            .padding(12)
            Divider()
            if workspace.isLoading && workspace.snapshot.revision == 0 {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.visibleRecords.isEmpty {
                ContentUnavailableView(
                    text("No Records", "没有记录"),
                    systemImage: RillSystemSymbol.tray.rawValue,
                    description: Text(text(
                        "Captured and workflow-created records appear here.",
                        "采集和工作流创建的记录会显示在这里。"
                    ))
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
                        membershipChip(text("No Collection", "无记录集"))
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
                                text("Insert in Previous App", "输入到上一应用"),
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
                                record.metadata.isPinned ? text("Unpin", "取消置顶") : text("Pin", "置顶"),
                                systemImage: record.metadata.isPinned ? "pin.slash" : "pin"
                            )
                        }
                        Button {
                            collectionIDsToAdd = []
                            membershipRecordID = record.id
                        } label: {
                            Label(text("Add to Collections", "加入多个记录集"), systemImage: RillSystemSymbol.rectangleStackBadgePlus.rawValue)
                        }
                    }
                    membershipInspector(record)
                    metadataInspector(record)
                    if case .text(let textValue) = record.record.payload,
                       let membership = preferredMembership(for: record) {
                        Button(text("Replace in Current Collection", "在当前记录集中替换")) {
                            replacementRecordID = record.id
                            replacementText = textValue
                            replacesInAllCollections = false
                        }
                        Button(text("Replace in All Collections", "在所有记录集中替换")) {
                            replacementRecordID = record.id
                            replacementText = textValue
                            replacesInAllCollections = true
                        }
                        .disabled(record.memberships.count < 2 || membership.state != .active)
                    }
                    Divider()
                    Button(role: .destructive) {
                        recordPendingGlobalDeletion = record.id
                    } label: {
                        Label(text("Delete Record Everywhere", "全局删除记录"), systemImage: RillSystemSymbol.trash.rawValue)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                text("Select a Record", "选择一条记录"),
                systemImage: RillSystemSymbol.docTextMagnifyingglass.rawValue
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func membershipInspector(_ record: RecordProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("Collections", "记录集")).font(.headline)
            if record.memberships.isEmpty {
                Text(text(
                    "This record remains visible in All Records.",
                    "这条记录仍会显示在“所有记录”中。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(record.memberships) { membership in
                HStack {
                    membershipChip(workspace.collectionName(membership.collectionID))
                    Text(membership.state == .active ? text("Active", "有效") : text("Consumed", "已消费"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await workspace.removeMembership(membership) }
                    } label: {
                        Image(systemName: RillSystemSymbol.xmarkCircle.rawValue)
                    }
                    .buttonStyle(.plain)
                    .help(text("Remove from this collection", "从此记录集移除"))
                }
            }
        }
    }

    private func metadataInspector(_ record: RecordProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("Metadata", "元数据")).font(.headline)
            LabeledContent(text("Source", "来源")) {
                Text(sourceName(record.record.provenance))
            }
            LabeledContent(text("Uses", "使用次数")) {
                Text("\(record.activity.useCount)")
            }
            LabeledContent(text("Tags", "标签")) {
                Text(record.metadata.tags.isEmpty ? "—" : record.metadata.tags.joined(separator: ", "))
            }
        }
    }

    private var createCollectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(text("New Record Collection", "新建记录集")).font(.title2.weight(.semibold))
            TextField(text("Collection name", "记录集名称"), text: $newCollectionName)
            Picker(text("Preset", "预设"), selection: $newCollectionPreset) {
                Text("Stack").tag(RecordCollectionPreset.stack)
                Text("Queue").tag(RecordCollectionPreset.queue)
                Text("List").tag(RecordCollectionPreset.list)
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button(text("Cancel", "取消")) { isCreatingCollection = false }
                Button(text("Create", "创建")) {
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
            Text(text("Add to Collections", "加入多个记录集")).font(.title2.weight(.semibold))
            List(workspace.snapshot.collections, selection: $collectionIDsToAdd) { collection in
                Text(collection.name).tag(collection.id)
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button(text("Cancel", "取消")) { membershipRecordID = nil }
                Button(text("Add", "加入")) {
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
                ? text("Replace in All Collections", "在所有记录集中替换")
                : text("Replace in Current Collection", "在当前记录集中替换"))
                .font(.title2.weight(.semibold))
            TextEditor(text: $replacementText)
                .font(.body.monospaced())
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text(text(
                "Replace creates a derived immutable record; the original remains in All Records.",
                "替换会创建派生的不可变记录；原记录仍保留在“所有记录”中。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(text("Cancel", "取消")) { replacementRecordID = nil }
                Button(text("Replace", "替换")) { performReplacement() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func collectionDeletionImpactSheet(_ impact: RecordCollectionDeletionImpact) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("Collection References", "记录集引用影响")).font(.title2.weight(.semibold))
            Text(text(
                "This collection is used by \(impact.captureRuleIDs.count) capture routes and \(impact.deliveryRuleIDs.count) delivery routes.",
                "此记录集被 \(impact.captureRuleIDs.count) 条采集路由和 \(impact.deliveryRuleIDs.count) 条投递路由引用。"
            ))
            Text(text(
                "Choose a replacement collection, or explicitly disable routes that would become empty.",
                "请选择替代记录集，或明确禁用将变为空的路由。"
            ))
            .foregroundStyle(.secondary)
            ForEach(workspace.snapshot.collections.filter { $0.id != impact.collectionID }) { collection in
                Button(text("Replace with \(collection.name)", "替换为 \(collection.name)")) {
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
                Button(text("Disable Affected Routes", "禁用受影响路由"), role: .destructive) {
                    Task {
                        await workspace.confirmCollectionDeletion(
                            impact.collectionID,
                            resolution: .disableAffectedRoutes
                        )
                    }
                }
                Spacer()
                Button(text("Cancel", "取消")) { workspace.cancelCollectionDeletion() }
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
            return trimmed.isEmpty ? text("Empty Text", "空文本") : trimmed
        case .image:
            return text("Image", "图片")
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
                Label(text("Image unavailable", "图片不可用"), systemImage: RillSystemSymbol.photoBadgeExclamationmark.rawValue)
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
            .background(.quaternary.opacity(0.35), in: Capsule())
    }

    private func sourceName(_ provenance: RecordProvenance) -> String {
        provenance.sourceApplicationName
            ?? provenance.workflow?.fallbackName
            ?? provenance.source.kind.rawValue
    }

    private func text(_ english: String, _ simplifiedChinese: String) -> String {
        language == .simplifiedChinese ? simplifiedChinese : english
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

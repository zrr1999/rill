import RillCore
import SwiftUI

struct RecordRouteEditorView: View {
    @Bindable var workspace: RecordWorkspaceModel
    let language: AppLanguage

    @State private var captureDraft: CaptureRouteDraft?
    @State private var deliveryDraft: DeliveryRouteDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                routeSectionHeader(
                    title: text("Capture Routes", "采集路由"),
                    detail: text(
                        "Every matching rule contributes destinations; one capture still creates one Record.",
                        "所有命中规则的目标会取稳定并集；一次采集仍只创建一条记录。"
                    ),
                    action: { captureDraft = CaptureRouteDraft(collections: workspace.snapshot.collections) }
                )
                if workspace.snapshot.captureRules.isEmpty {
                    emptyRoutes(text("No capture routes. Unmatched records go to Inbox or Voice Input.", "没有采集路由。未匹配记录会进入收件箱或语音输入。"))
                } else {
                    ForEach(workspace.snapshot.captureRules) { rule in
                        captureRuleRow(rule)
                    }
                }

                Divider()

                routeSectionHeader(
                    title: text("Delivery Routes", "投递路由"),
                    detail: text(
                        "The highest-priority matching rule selects an ordered collection list and sink.",
                        "最高优先级的命中规则会选择有序来源记录集列表和输出端。"
                    ),
                    action: { deliveryDraft = DeliveryRouteDraft(collections: workspace.snapshot.collections) }
                )
                if workspace.snapshot.deliveryRules.isEmpty {
                    emptyRoutes(text("No delivery routes. Focused delivery reads Inbox.", "没有投递路由。当前应用投递默认读取收件箱。"))
                } else {
                    ForEach(sortedDeliveryRules) { rule in
                        deliveryRuleRow(rule)
                    }
                }
            }
            .padding(18)
        }
        .sheet(item: $captureDraft) { draft in
            CaptureRouteEditorSheet(
                draft: draft,
                collections: workspace.snapshot.collections,
                language: language,
                onCancel: { captureDraft = nil },
                onSave: { rule in
                    var rules = workspace.snapshot.captureRules
                    if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                        rules[index] = rule
                    } else {
                        rules.append(rule)
                    }
                    captureDraft = nil
                    Task { await workspace.replaceCaptureRules(rules) }
                }
            )
        }
        .sheet(item: $deliveryDraft) { draft in
            DeliveryRouteEditorSheet(
                draft: draft,
                collections: workspace.snapshot.collections,
                language: language,
                onCancel: { deliveryDraft = nil },
                onSave: { rule in
                    var rules = workspace.snapshot.deliveryRules
                    if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                        rules[index] = rule
                    } else {
                        rules.append(rule)
                    }
                    deliveryDraft = nil
                    Task { await workspace.replaceDeliveryRules(rules) }
                }
            )
        }
    }

    private var sortedDeliveryRules: [DeliveryRouteRule] {
        workspace.snapshot.deliveryRules.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.id.description < $1.id.description
        }
    }

    private func captureRuleRow(_ rule: CaptureRouteRule) -> some View {
        routeCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(captureMatcherSummary(rule.matcher)).font(.headline)
                    HStack(spacing: 6) {
                        ForEach(rule.destinationCollectionIDs) { id in
                            routeChip(workspace.collectionName(id))
                        }
                    }
                    Text(rule.isEnabled ? text("Enabled", "已启用") : text("Disabled", "已禁用"))
                        .font(.caption)
                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                }
                Spacer()
                Button(text("Edit", "编辑")) { captureDraft = CaptureRouteDraft(rule: rule) }
                Button(role: .destructive) {
                    Task {
                        await workspace.replaceCaptureRules(
                            workspace.snapshot.captureRules.filter { $0.id != rule.id }
                        )
                    }
                } label: { Image(systemName: RillSystemSymbol.trash.rawValue) }
            }
        }
    }

    private func deliveryRuleRow(_ rule: DeliveryRouteRule) -> some View {
        routeCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(deliveryMatcherSummary(rule.matcher)).font(.headline)
                    Text(text("Priority \(rule.priority)", "优先级 \(rule.priority)"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        ForEach(Array(rule.sourceCollectionIDs.enumerated()), id: \.element) { offset, id in
                            routeChip("\(offset + 1). \(workspace.collectionName(id))")
                        }
                        Image(systemName: RillSystemSymbol.arrowRight.rawValue)
                        routeChip(sinkName(rule))
                    }
                    Text(rule.isEnabled ? text("Enabled", "已启用") : text("Disabled", "已禁用"))
                        .font(.caption)
                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                }
                Spacer()
                Button(text("Edit", "编辑")) { deliveryDraft = DeliveryRouteDraft(rule: rule) }
                Button(role: .destructive) {
                    Task {
                        await workspace.replaceDeliveryRules(
                            workspace.snapshot.deliveryRules.filter { $0.id != rule.id }
                        )
                    }
                } label: { Image(systemName: RillSystemSymbol.trash.rawValue) }
            }
        }
    }

    private func routeSectionHeader(
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) { Label(text("Add Route", "添加路由"), systemImage: RillSystemSymbol.plus.rawValue) }
        }
    }

    private func emptyRoutes(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func routeCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func routeChip(_ value: String) -> some View {
        Text(value).font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary.opacity(0.35), in: Capsule())
    }

    private func captureMatcherSummary(_ matcher: CaptureRouteMatcher) -> String {
        var parts: [String] = []
        if !matcher.sourceKinds.isEmpty { parts.append(matcher.sourceKinds.map(\.rawValue).sorted().joined(separator: ", ")) }
        if !matcher.sourceBundleIdentifiers.isEmpty { parts.append(matcher.sourceBundleIdentifiers.sorted().joined(separator: ", ")) }
        if !matcher.workflowIDs.isEmpty { parts.append(text("\(matcher.workflowIDs.count) workflows", "\(matcher.workflowIDs.count) 个工作流")) }
        return parts.isEmpty ? text("Any record source", "任意记录来源") : parts.joined(separator: " · ")
    }

    private func deliveryMatcherSummary(_ matcher: DeliveryRouteMatcher) -> String {
        matcher.targetBundleIdentifiers.isEmpty
            ? text("Any focused application", "任意当前应用")
            : matcher.targetBundleIdentifiers.sorted().joined(separator: ", ")
    }

    private func sinkName(_ rule: DeliveryRouteRule) -> String {
        switch rule.sink {
        case .focusedApplication: text("Focused Application", "当前应用")
        case .systemClipboard: text("System Clipboard", "系统剪贴板")
        case .recordCollection:
            rule.sinkCollectionID.map(workspace.collectionName) ?? text("Collection", "记录集")
        }
    }

    private func text(_ english: String, _ simplifiedChinese: String) -> String {
        language == .simplifiedChinese ? simplifiedChinese : english
    }
}

private struct CaptureRouteDraft: Identifiable {
    var id: RecordRouteRuleID
    var sourceKind: RecordSourceKind?
    var sourceBundleIdentifier: String
    var workflowID: String
    var destinationCollectionIDs: Set<RecordCollectionID>
    var isEnabled: Bool
    var createdAt: Date

    init(collections: [RecordCollection]) {
        id = RecordRouteRuleID()
        sourceKind = .systemClipboard
        sourceBundleIdentifier = ""
        workflowID = ""
        destinationCollectionIDs = Set(collections.prefix(1).map(\.id))
        isEnabled = true
        createdAt = Date()
    }

    init(rule: CaptureRouteRule) {
        id = rule.id
        sourceKind = rule.matcher.sourceKinds.count == 1 ? rule.matcher.sourceKinds.first : nil
        sourceBundleIdentifier = rule.matcher.sourceBundleIdentifiers.sorted().joined(separator: ", ")
        workflowID = rule.matcher.workflowIDs.first?.uuidString ?? ""
        destinationCollectionIDs = Set(rule.destinationCollectionIDs)
        isEnabled = rule.isEnabled
        createdAt = rule.createdAt
    }
}

private struct DeliveryRouteDraft: Identifiable {
    var id: RecordRouteRuleID
    var targetBundleIdentifiers: String
    var priority: Int
    var sourceCollectionIDs: [RecordCollectionID]
    var sink: RecordSinkIdentity
    var sinkCollectionID: RecordCollectionID?
    var isEnabled: Bool
    var createdAt: Date

    init(collections: [RecordCollection]) {
        id = RecordRouteRuleID()
        targetBundleIdentifiers = ""
        priority = 0
        sourceCollectionIDs = Array(collections.prefix(1).map(\.id))
        sink = .focusedApplication
        sinkCollectionID = nil
        isEnabled = true
        createdAt = Date()
    }

    init(rule: DeliveryRouteRule) {
        id = rule.id
        targetBundleIdentifiers = rule.matcher.targetBundleIdentifiers.sorted().joined(separator: ", ")
        priority = rule.priority
        sourceCollectionIDs = rule.sourceCollectionIDs
        sink = rule.sink
        sinkCollectionID = rule.sinkCollectionID
        isEnabled = rule.isEnabled
        createdAt = rule.createdAt
    }
}

private struct CaptureRouteEditorSheet: View {
    @State var draft: CaptureRouteDraft
    let collections: [RecordCollection]
    let language: AppLanguage
    let onCancel: () -> Void
    let onSave: (CaptureRouteRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("Capture Route", "采集路由")).font(.title2.weight(.semibold))
            Picker(text("Source", "来源"), selection: $draft.sourceKind) {
                Text(text("Any Source", "任意来源")).tag(Optional<RecordSourceKind>.none)
                Text(text("System Clipboard", "系统剪贴板")).tag(Optional(RecordSourceKind.systemClipboard))
                Text(text("Voice Input", "语音输入")).tag(Optional(RecordSourceKind.voiceInput))
                Text(text("Workflow", "工作流")).tag(Optional(RecordSourceKind.workflow))
                Text(text("User", "用户")).tag(Optional(RecordSourceKind.user))
            }
            TextField(text("Source app bundle IDs (comma separated)", "来源应用 Bundle ID（逗号分隔）"), text: $draft.sourceBundleIdentifier)
            TextField(text("Workflow UUID (optional)", "工作流 UUID（可选）"), text: $draft.workflowID)
            Text(text("Destination Collections", "目标记录集")).font(.headline)
            List(collections, selection: $draft.destinationCollectionIDs) { collection in
                Text(collection.name).tag(collection.id)
            }
            .frame(height: 210)
            Toggle(text("Enabled", "启用"), isOn: $draft.isEnabled)
            HStack {
                Spacer()
                Button(text("Cancel", "取消"), action: onCancel)
                Button(text("Save", "保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.destinationCollectionIDs.isEmpty
                        || draft.destinationCollectionIDs.count > RecordGraphLimits.maximumRouteCollections
                        || (!draft.workflowID.isEmpty && UUID(uuidString: draft.workflowID) == nil))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        let bundles = commaSeparatedValues(draft.sourceBundleIdentifier)
        let workflowIDs = UUID(uuidString: draft.workflowID).map { Set([$0]) } ?? []
        let orderedDestinations = collections.map(\.id).filter(draft.destinationCollectionIDs.contains)
        onSave(CaptureRouteRule(
            id: draft.id,
            matcher: CaptureRouteMatcher(
                sourceKinds: draft.sourceKind.map { Set([$0]) } ?? [],
                sourceBundleIdentifiers: Set(bundles),
                workflowIDs: workflowIDs
            ),
            destinationCollectionIDs: orderedDestinations,
            isEnabled: draft.isEnabled,
            createdAt: draft.createdAt
        ))
    }

    private func text(_ english: String, _ simplifiedChinese: String) -> String {
        language == .simplifiedChinese ? simplifiedChinese : english
    }
}

private struct DeliveryRouteEditorSheet: View {
    @State var draft: DeliveryRouteDraft
    let collections: [RecordCollection]
    let language: AppLanguage
    let onCancel: () -> Void
    let onSave: (DeliveryRouteRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("Delivery Route", "投递路由")).font(.title2.weight(.semibold))
            TextField(text("Target app bundle IDs (comma separated)", "目标应用 Bundle ID（逗号分隔）"), text: $draft.targetBundleIdentifiers)
            Stepper(text("Priority: \(draft.priority)", "优先级：\(draft.priority)"), value: $draft.priority, in: -1_000...1_000)
            Picker(text("Sink", "输出端"), selection: $draft.sink) {
                Text(text("Focused Application", "当前应用")).tag(RecordSinkIdentity.focusedApplication)
                Text(text("System Clipboard", "系统剪贴板")).tag(RecordSinkIdentity.systemClipboard)
                Text(text("Record Collection", "记录集")).tag(RecordSinkIdentity.recordCollection)
            }
            if draft.sink == .recordCollection {
                Picker(text("Target Collection", "目标记录集"), selection: $draft.sinkCollectionID) {
                    Text(text("Choose Collection", "选择记录集")).tag(Optional<RecordCollectionID>.none)
                    ForEach(collections) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
            }
            Text(text("Source Collections (drag to order)", "来源记录集（拖动排序）")).font(.headline)
            List {
                ForEach(draft.sourceCollectionIDs) { id in
                    HStack {
                        Image(systemName: RillSystemSymbol.line3Horizontal.rawValue)
                        Text(collections.first(where: { $0.id == id })?.name ?? id.description)
                        Spacer()
                        Button { draft.sourceCollectionIDs.removeAll { $0 == id } } label: {
                            Image(systemName: RillSystemSymbol.xmarkCircle.rawValue)
                        }.buttonStyle(.plain)
                    }
                }
                .onMove { source, destination in
                    draft.sourceCollectionIDs.move(fromOffsets: source, toOffset: destination)
                }
            }
            .frame(height: 180)
            Menu(text("Add Source Collection", "添加来源记录集")) {
                ForEach(collections.filter { !draft.sourceCollectionIDs.contains($0.id) }) { collection in
                    Button(collection.name) { draft.sourceCollectionIDs.append(collection.id) }
                }
            }
            Toggle(text("Enabled", "启用"), isOn: $draft.isEnabled)
            HStack {
                Spacer()
                Button(text("Cancel", "取消"), action: onCancel)
                Button(text("Save", "保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.sourceCollectionIDs.isEmpty
                        || draft.sourceCollectionIDs.count > RecordGraphLimits.maximumRouteCollections
                        || (draft.sink == .recordCollection && draft.sinkCollectionID == nil))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func save() {
        onSave(DeliveryRouteRule(
            id: draft.id,
            matcher: DeliveryRouteMatcher(
                targetBundleIdentifiers: Set(commaSeparatedValues(draft.targetBundleIdentifiers))
            ),
            priority: draft.priority,
            sourceCollectionIDs: draft.sourceCollectionIDs,
            sink: draft.sink,
            sinkCollectionID: draft.sink == .recordCollection ? draft.sinkCollectionID : nil,
            isEnabled: draft.isEnabled,
            createdAt: draft.createdAt
        ))
    }

    private func text(_ english: String, _ simplifiedChinese: String) -> String {
        language == .simplifiedChinese ? simplifiedChinese : english
    }
}

private func commaSeparatedValues(_ rawValue: String) -> [String] {
    rawValue.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

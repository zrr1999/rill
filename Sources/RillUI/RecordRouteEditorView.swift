import RillCore
import SwiftUI

struct RecordRouteEditorView: View {
    @Bindable var workspace: RecordWorkspaceModel
    let language: AppLanguage

    @State private var captureDraft: CaptureRouteDraft?
    @State private var deliveryDraft: DeliveryRouteDraft?
    @State private var captureRulePendingDeletion: CaptureRouteRule?
    @State private var deliveryRulePendingDeletion: DeliveryRouteRule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                routeSectionHeader(
                    title: L10n.recordText(.captureRoutesTitle, language: language),
                    detail: L10n.recordText(.captureRoutesDetail, language: language),
                    action: { captureDraft = CaptureRouteDraft(collections: workspace.snapshot.collections) }
                )
                if workspace.snapshot.captureRules.isEmpty {
                    emptyRoutes(L10n.recordText(.captureRoutesEmpty, language: language))
                } else {
                    ForEach(workspace.snapshot.captureRules) { rule in
                        captureRuleRow(rule)
                    }
                }

                Divider()

                routeSectionHeader(
                    title: L10n.recordText(.deliveryRoutesTitle, language: language),
                    detail: L10n.recordText(.deliveryRoutesDetail, language: language),
                    action: { deliveryDraft = DeliveryRouteDraft(collections: workspace.snapshot.collections) }
                )
                if workspace.snapshot.deliveryRules.isEmpty {
                    emptyRoutes(L10n.recordText(.deliveryRoutesEmpty, language: language))
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
        .alert(
            L10n.recordText(.deleteCaptureRouteTitle, language: language),
            isPresented: Binding(
                get: { captureRulePendingDeletion != nil },
                set: { if !$0 { captureRulePendingDeletion = nil } }
            ),
            presenting: captureRulePendingDeletion
        ) { rule in
            Button(L10n.recordText(.deleteRoute, language: language), role: .destructive) {
                captureRulePendingDeletion = nil
                Task {
                    await workspace.replaceCaptureRules(
                        workspace.snapshot.captureRules.filter { $0.id != rule.id }
                    )
                }
            }
            Button(L10n.recordText(.cancel, language: language), role: .cancel) {}
        } message: { _ in
            Text(L10n.recordText(.deleteCaptureRouteDetail, language: language))
        }
        .alert(
            L10n.recordText(.deleteDeliveryRouteTitle, language: language),
            isPresented: Binding(
                get: { deliveryRulePendingDeletion != nil },
                set: { if !$0 { deliveryRulePendingDeletion = nil } }
            ),
            presenting: deliveryRulePendingDeletion
        ) { rule in
            Button(L10n.recordText(.deleteRoute, language: language), role: .destructive) {
                deliveryRulePendingDeletion = nil
                Task {
                    await workspace.replaceDeliveryRules(
                        workspace.snapshot.deliveryRules.filter { $0.id != rule.id }
                    )
                }
            }
            Button(L10n.recordText(.cancel, language: language), role: .cancel) {}
        } message: { _ in
            Text(L10n.recordText(.deleteDeliveryRouteDetail, language: language))
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
                    Text(rule.isEnabled
                        ? L10n.recordText(.enabledState, language: language)
                        : L10n.recordText(.disabledState, language: language))
                        .font(.caption)
                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                }
                Spacer()
                Button(L10n.recordText(.edit, language: language)) { captureDraft = CaptureRouteDraft(rule: rule) }
                Button(role: .destructive) {
                    captureRulePendingDeletion = rule
                } label: { Image(systemName: RillSystemSymbol.trash.rawValue) }
                    .help(L10n.recordText(.deleteRoute, language: language))
                    .accessibilityLabel(L10n.recordText(.deleteRoute, language: language))
            }
        }
    }

    private func deliveryRuleRow(_ rule: DeliveryRouteRule) -> some View {
        routeCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(deliveryMatcherSummary(rule.matcher)).font(.headline)
                    Text(L10n.routePriority(rule.priority, language: language))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        ForEach(Array(rule.sourceCollectionIDs.enumerated()), id: \.element) { offset, id in
                            routeChip("\(offset + 1). \(workspace.collectionName(id))")
                        }
                        Image(systemName: RillSystemSymbol.arrowRight.rawValue)
                        routeChip(sinkName(rule))
                    }
                    Text(rule.isEnabled
                        ? L10n.recordText(.enabledState, language: language)
                        : L10n.recordText(.disabledState, language: language))
                        .font(.caption)
                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                }
                Spacer()
                Button(L10n.recordText(.edit, language: language)) { deliveryDraft = DeliveryRouteDraft(rule: rule) }
                Button(role: .destructive) {
                    deliveryRulePendingDeletion = rule
                } label: { Image(systemName: RillSystemSymbol.trash.rawValue) }
                    .help(L10n.recordText(.deleteRoute, language: language))
                    .accessibilityLabel(L10n.recordText(.deleteRoute, language: language))
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
            Button(action: action) { Label(L10n.recordText(.addRoute, language: language), systemImage: RillSystemSymbol.plus.rawValue) }
        }
    }

    private func emptyRoutes(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .rillCard(.subdued, cornerRadius: 10, padding: 16)
    }

    private func routeCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func routeChip(_ value: String) -> some View {
        Text(value).font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
            // RillCard regular-tier fill; a Capsule chip cannot use rillCard itself.
            .background(.quaternary.opacity(0.35), in: Capsule())
    }

    private func captureMatcherSummary(_ matcher: CaptureRouteMatcher) -> String {
        var parts: [String] = []
        if !matcher.sourceKinds.isEmpty { parts.append(matcher.sourceKinds.map(\.rawValue).sorted().joined(separator: ", ")) }
        if !matcher.sourceBundleIdentifiers.isEmpty { parts.append(matcher.sourceBundleIdentifiers.sorted().joined(separator: ", ")) }
        if !matcher.workflowIDs.isEmpty { parts.append(L10n.routeWorkflowsCount(matcher.workflowIDs.count, language: language)) }
        return parts.isEmpty
            ? L10n.recordText(.anyRecordSource, language: language)
            : parts.joined(separator: " · ")
    }

    private func deliveryMatcherSummary(_ matcher: DeliveryRouteMatcher) -> String {
        matcher.targetBundleIdentifiers.isEmpty
            ? L10n.recordText(.anyFocusedApplication, language: language)
            : matcher.targetBundleIdentifiers.sorted().joined(separator: ", ")
    }

    private func sinkName(_ rule: DeliveryRouteRule) -> String {
        switch rule.sink {
        case .focusedApplication: L10n.recordText(.sinkFocusedApplication, language: language)
        case .systemClipboard: L10n.recordText(.sinkSystemClipboard, language: language)
        case .recordCollection:
            rule.sinkCollectionID.map(workspace.collectionName)
                ?? L10n.recordText(.sinkCollectionFallback, language: language)
        }
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
            Text(L10n.recordText(.captureRouteTitle, language: language)).font(.title2.weight(.semibold))
            Picker(L10n.recordText(.metadataSource, language: language), selection: $draft.sourceKind) {
                Text(L10n.recordText(.anySource, language: language)).tag(Optional<RecordSourceKind>.none)
                Text(L10n.recordText(.sinkSystemClipboard, language: language)).tag(Optional(RecordSourceKind.systemClipboard))
                Text(L10n.recordText(.sourceVoiceInput, language: language)).tag(Optional(RecordSourceKind.voiceInput))
                Text(L10n.recordText(.sourceWorkflow, language: language)).tag(Optional(RecordSourceKind.workflow))
                Text(L10n.recordText(.sourceUser, language: language)).tag(Optional(RecordSourceKind.user))
            }
            TextField(L10n.recordText(.sourceBundleIDsField, language: language), text: $draft.sourceBundleIdentifier)
            TextField(L10n.recordText(.workflowUUIDField, language: language), text: $draft.workflowID)
            Text(L10n.recordText(.destinationCollections, language: language)).font(.headline)
            List(collections, selection: $draft.destinationCollectionIDs) { collection in
                Text(collection.name).tag(collection.id)
            }
            .frame(height: 210)
            Toggle(L10n.recordText(.enabledToggle, language: language), isOn: $draft.isEnabled)
            HStack {
                Spacer()
                Button(L10n.recordText(.cancel, language: language), action: onCancel)
                Button(L10n.recordText(.save, language: language)) { save() }
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
}

private struct DeliveryRouteEditorSheet: View {
    @State var draft: DeliveryRouteDraft
    let collections: [RecordCollection]
    let language: AppLanguage
    let onCancel: () -> Void
    let onSave: (DeliveryRouteRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.recordText(.deliveryRouteTitle, language: language)).font(.title2.weight(.semibold))
            TextField(L10n.recordText(.targetBundleIDsField, language: language), text: $draft.targetBundleIdentifiers)
            Stepper(L10n.routePriorityLabel(draft.priority, language: language), value: $draft.priority, in: -1_000...1_000)
            Picker(L10n.recordText(.sinkLabel, language: language), selection: $draft.sink) {
                Text(L10n.recordText(.sinkFocusedApplication, language: language)).tag(RecordSinkIdentity.focusedApplication)
                Text(L10n.recordText(.sinkSystemClipboard, language: language)).tag(RecordSinkIdentity.systemClipboard)
                Text(L10n.recordText(.sinkRecordCollection, language: language)).tag(RecordSinkIdentity.recordCollection)
            }
            if draft.sink == .recordCollection {
                Picker(L10n.recordText(.targetCollection, language: language), selection: $draft.sinkCollectionID) {
                    Text(L10n.recordText(.chooseCollection, language: language)).tag(Optional<RecordCollectionID>.none)
                    ForEach(collections) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
            }
            Text(L10n.recordText(.sourceCollectionsLabel, language: language)).font(.headline)
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
            Menu(L10n.recordText(.addSourceCollection, language: language)) {
                ForEach(collections.filter { !draft.sourceCollectionIDs.contains($0.id) }) { collection in
                    Button(collection.name) { draft.sourceCollectionIDs.append(collection.id) }
                }
            }
            Toggle(L10n.recordText(.enabledToggle, language: language), isOn: $draft.isEnabled)
            HStack {
                Spacer()
                Button(L10n.recordText(.cancel, language: language), action: onCancel)
                Button(L10n.recordText(.save, language: language)) { save() }
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
}

private func commaSeparatedValues(_ rawValue: String) -> [String] {
    rawValue.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

import Foundation
import RillCore

extension L10n {
    static func recordText(_ key: RecordTextKey, language: AppLanguage) -> String {
        recordTextTable[key]?.string(for: language) ?? key.rawValue
    }

    static func recordCount(_ count: Int, language: AppLanguage) -> String {
        String(format: recordText(.recordCountFormat, language: language), count)
    }

    static func removeFromCollection(_ collectionName: String, language: AppLanguage) -> String {
        String(format: recordText(.removeFromCollectionFormat, language: language), collectionName)
    }

    static func collectionReferencesUsage(
        captureRouteCount: Int,
        deliveryRouteCount: Int,
        language: AppLanguage
    ) -> String {
        String(
            format: recordText(.collectionReferencesUsageFormat, language: language),
            captureRouteCount,
            deliveryRouteCount
        )
    }

    static func replaceWithCollection(_ collectionName: String, language: AppLanguage) -> String {
        String(format: recordText(.replaceWithFormat, language: language), collectionName)
    }

    static func routeWorkflowsCount(_ count: Int, language: AppLanguage) -> String {
        String(format: recordText(.workflowsCountFormat, language: language), count)
    }

    static func routePriority(_ priority: Int, language: AppLanguage) -> String {
        String(format: recordText(.priorityFormat, language: language), priority)
    }

    static func routePriorityLabel(_ priority: Int, language: AppLanguage) -> String {
        String(format: recordText(.priorityLabelFormat, language: language), priority)
    }

    private static let recordTextTable: [RecordTextKey: LocalizedText] = [
        .add: .init(english: "Add", simplifiedChinese: "加入"),
        .addRoute: .init(english: "Add Route", simplifiedChinese: "添加路由"),
        .addSourceCollection: .init(english: "Add Source Collection", simplifiedChinese: "添加来源记录集"),
        .addToCollections: .init(english: "Add to Collections", simplifiedChinese: "加入多个记录集"),
        .anyFocusedApplication: .init(english: "Any focused application", simplifiedChinese: "任意当前应用"),
        .anyRecordSource: .init(english: "Any record source", simplifiedChinese: "任意记录来源"),
        .anySource: .init(english: "Any Source", simplifiedChinese: "任意来源"),
        .cancel: .init(english: "Cancel", simplifiedChinese: "取消"),
        .captureRouteTitle: .init(english: "Capture Route", simplifiedChinese: "采集路由"),
        .captureRoutesDetail: .init(
            english: "Every matching rule contributes destinations; one capture still creates one Record.",
            simplifiedChinese: "所有命中规则的目标会取稳定并集；一次采集仍只创建一条记录。"
        ),
        .captureRoutesEmpty: .init(
            english: "No capture routes. Unmatched records go to Inbox or Voice Input.",
            simplifiedChinese: "没有采集路由。未匹配记录会进入收件箱或语音输入。"
        ),
        .captureRoutesTitle: .init(english: "Capture Routes", simplifiedChinese: "采集路由"),
        .chooseCollection: .init(english: "Choose Collection", simplifiedChinese: "选择记录集"),
        .collectionNameField: .init(english: "Collection name", simplifiedChinese: "记录集名称"),
        .collectionPresetList: .init(english: "List", simplifiedChinese: "列表"),
        .collectionPresetQueue: .init(english: "Queue", simplifiedChinese: "队列"),
        .collectionPresetStack: .init(english: "Stack", simplifiedChinese: "栈"),
        .collectionReferencesHint: .init(
            english: "Choose a replacement collection, or explicitly disable routes that would become empty.",
            simplifiedChinese: "请选择替代记录集，或明确禁用将变为空的路由。"
        ),
        .collectionReferencesTitle: .init(english: "Collection References", simplifiedChinese: "记录集引用影响"),
        .collectionReferencesUsageFormat: .init(
            english: "This collection is used by %d capture routes and %d delivery routes.",
            simplifiedChinese: "此记录集被 %d 条采集路由和 %d 条投递路由引用。"
        ),
        .consumptionConsume: .init(english: "Consume", simplifiedChinese: "消费"),
        .consumptionPolicy: .init(english: "After Delivery", simplifiedChinese: "投递后"),
        .consumptionRetain: .init(english: "Retain", simplifiedChinese: "保留"),
        .deleteCaptureRouteDetail: .init(
            english: "The route is removed permanently; newly captured records will no longer follow it.",
            simplifiedChinese: "路由将被永久删除，新采集的记录不再按此规则路由。"
        ),
        .deleteCaptureRouteTitle: .init(english: "Delete this capture route?", simplifiedChinese: "删除这条采集路由？"),
        .deleteCollection: .init(english: "Delete Collection", simplifiedChinese: "删除记录集"),
        .deleteDeliveryRouteDetail: .init(
            english: "The route is removed permanently; records will no longer be delivered by it.",
            simplifiedChinese: "路由将被永久删除，记录不再按此规则投递。"
        ),
        .deleteDeliveryRouteTitle: .init(english: "Delete this delivery route?", simplifiedChinese: "删除这条投递路由？"),
        .deleteRecord: .init(english: "Delete Record", simplifiedChinese: "删除记录"),
        .deleteRecordEverywhere: .init(english: "Delete Record Everywhere", simplifiedChinese: "全局删除记录"),
        .deleteRecordEverywhereConfirmationTitle: .init(
            english: "Delete this record everywhere?",
            simplifiedChinese: "在所有位置删除这条记录？"
        ),
        .deleteRecordEverywhereDetail: .init(
            english: "This removes the immutable record and every collection membership.",
            simplifiedChinese: "这会删除不可变记录及其在所有记录集中的成员关系。"
        ),
        .deleteRoute: .init(english: "Delete Route", simplifiedChinese: "删除路由"),
        .deliveryRouteTitle: .init(english: "Delivery Route", simplifiedChinese: "投递路由"),
        .deliveryRoutesDetail: .init(
            english: "The highest-priority matching rule selects an ordered collection list and sink.",
            simplifiedChinese: "最高优先级的命中规则会选择有序来源记录集列表和输出端。"
        ),
        .deliveryRoutesEmpty: .init(
            english: "No delivery routes. Focused delivery reads Inbox.",
            simplifiedChinese: "没有投递路由。当前应用投递默认读取收件箱。"
        ),
        .deliveryRoutesTitle: .init(english: "Delivery Routes", simplifiedChinese: "投递路由"),
        .destinationCollections: .init(english: "Destination Collections", simplifiedChinese: "目标记录集"),
        .disableAffectedRoutes: .init(english: "Disable Affected Routes", simplifiedChinese: "禁用受影响路由"),
        .disabledState: .init(english: "Disabled", simplifiedChinese: "已禁用"),
        .edit: .init(english: "Edit", simplifiedChinese: "编辑"),
        .emptyTextPayload: .init(english: "Empty Text", simplifiedChinese: "空文本"),
        .enabledState: .init(english: "Enabled", simplifiedChinese: "已启用"),
        .enabledToggle: .init(english: "Enabled", simplifiedChinese: "启用"),
        .imagePayload: .init(english: "Image", simplifiedChinese: "图片"),
        .imageUnavailable: .init(english: "Image unavailable", simplifiedChinese: "图片不可用"),
        .insertInPreviousApp: .init(english: "Insert in Previous App", simplifiedChinese: "输入到上一应用"),
        .membershipActive: .init(english: "Active", simplifiedChinese: "有效"),
        .membershipConsumed: .init(english: "Consumed", simplifiedChinese: "已消费"),
        .metadataSource: .init(english: "Source", simplifiedChinese: "来源"),
        .metadataTags: .init(english: "Tags", simplifiedChinese: "标签"),
        .metadataTitle: .init(english: "Metadata", simplifiedChinese: "元数据"),
        .metadataUses: .init(english: "Uses", simplifiedChinese: "使用次数"),
        .newCollection: .init(english: "New Record Collection", simplifiedChinese: "新建记录集"),
        .noCollection: .init(english: "No Collection", simplifiedChinese: "无记录集"),
        .noMembershipHint: .init(
            english: "This record remains visible in All Records.",
            simplifiedChinese: "这条记录仍会显示在“所有记录”中。"
        ),
        .noRecordsDescription: .init(
            english: "Captured and workflow-created records appear here.",
            simplifiedChinese: "采集和工作流创建的记录会显示在这里。"
        ),
        .noRecordsTitle: .init(english: "No Records", simplifiedChinese: "没有记录"),
        .ok: .init(english: "OK", simplifiedChinese: "好"),
        .paneRecords: .init(english: "Records", simplifiedChinese: "记录"),
        .paneRoutes: .init(english: "Routes", simplifiedChinese: "路由"),
        .pinnedOnly: .init(english: "Pinned only", simplifiedChinese: "仅显示置顶记录"),
        .preset: .init(english: "Preset", simplifiedChinese: "预设"),
        .priorityFormat: .init(english: "Priority %d", simplifiedChinese: "优先级 %d"),
        .priorityLabelFormat: .init(english: "Priority: %d", simplifiedChinese: "优先级：%d"),
        .recordCountFormat: .init(english: "%d records", simplifiedChinese: "%d 条记录"),
        .recordRoutesTitle: .init(english: "Record Routes", simplifiedChinese: "记录路由"),
        .recordsHeaderDetail: .init(
            english: "Records are stored once and may belong to multiple collections.",
            simplifiedChinese: "记录只存储一次，并可同时属于多个记录集。"
        ),
        .recordsUpdateFailedTitle: .init(english: "Records could not be updated", simplifiedChinese: "无法更新记录"),
        .removeFromCollectionFormat: .init(english: "Remove from %@", simplifiedChinese: "从 %@ 移除"),
        .removeFromThisCollection: .init(english: "Remove from this collection", simplifiedChinese: "从此记录集移除"),
        .replace: .init(english: "Replace", simplifiedChinese: "替换"),
        .replaceDescription: .init(
            english: "Replace creates a derived immutable record; the original remains in All Records.",
            simplifiedChinese: "替换会创建派生的不可变记录；原记录仍保留在“所有记录”中。"
        ),
        .replaceInAllCollections: .init(english: "Replace in All Collections", simplifiedChinese: "在所有记录集中替换"),
        .replaceInAllCollectionsHint: .init(
            english: "Available when the record actively belongs to at least two collections.",
            simplifiedChinese: "当该记录在至少两个记录集中处于有效状态时可用。"
        ),
        .replaceInCurrentCollection: .init(
            english: "Replace in Current Collection",
            simplifiedChinese: "在当前记录集中替换"
        ),
        .replaceWithFormat: .init(english: "Replace with %@", simplifiedChinese: "替换为 %@"),
        .routesHeaderDetail: .init(
            english: "Route captures into collections and deliver records to their destinations.",
            simplifiedChinese: "将采集内容路由到记录集，并把记录投递到目标。"
        ),
        .save: .init(english: "Save", simplifiedChinese: "保存"),
        .selectRecordPrompt: .init(english: "Select a Record", simplifiedChinese: "选择一条记录"),
        .selectionManual: .init(english: "Manual", simplifiedChinese: "手动"),
        .selectionNewest: .init(english: "Newest", simplifiedChinese: "最新优先"),
        .selectionOldest: .init(english: "Oldest", simplifiedChinese: "最早优先"),
        .selectionPolicy: .init(english: "Selection", simplifiedChinese: "选取"),
        .sinkCollectionFallback: .init(english: "Collection", simplifiedChinese: "记录集"),
        .sinkFocusedApplication: .init(english: "Focused Application", simplifiedChinese: "当前应用"),
        .sinkLabel: .init(english: "Sink", simplifiedChinese: "输出端"),
        .sinkRecordCollection: .init(english: "Record Collection", simplifiedChinese: "记录集"),
        .sinkSystemClipboard: .init(english: "System Clipboard", simplifiedChinese: "系统剪贴板"),
        .sourceBundleIDsField: .init(
            english: "Source app bundle IDs (comma separated)",
            simplifiedChinese: "来源应用 Bundle ID（逗号分隔）"
        ),
        .sourceCollectionsLabel: .init(
            english: "Source Collections (drag to order)",
            simplifiedChinese: "来源记录集（拖动排序）"
        ),
        .sourceUser: .init(english: "User", simplifiedChinese: "用户"),
        .sourceVoiceInput: .init(english: "Voice Input", simplifiedChinese: "语音输入"),
        .sourceWorkflow: .init(english: "Workflow", simplifiedChinese: "工作流"),
        .targetBundleIDsField: .init(
            english: "Target app bundle IDs (comma separated)",
            simplifiedChinese: "目标应用 Bundle ID（逗号分隔）"
        ),
        .targetCollection: .init(english: "Target Collection", simplifiedChinese: "目标记录集"),
        .workflowUUIDField: .init(english: "Workflow UUID (optional)", simplifiedChinese: "工作流 UUID（可选）"),
        .workflowsCountFormat: .init(english: "%d workflows", simplifiedChinese: "%d 个工作流"),
    ]
}

enum RecordTextKey: String, CaseIterable, Sendable {
    case add
    case addRoute
    case addSourceCollection
    case addToCollections
    case anyFocusedApplication
    case anyRecordSource
    case anySource
    case cancel
    case captureRouteTitle
    case captureRoutesDetail
    case captureRoutesEmpty
    case captureRoutesTitle
    case chooseCollection
    case collectionNameField
    case collectionPresetList
    case collectionPresetQueue
    case collectionPresetStack
    case collectionReferencesHint
    case collectionReferencesTitle
    case collectionReferencesUsageFormat
    case consumptionConsume
    case consumptionPolicy
    case consumptionRetain
    case deleteCaptureRouteDetail
    case deleteCaptureRouteTitle
    case deleteCollection
    case deleteDeliveryRouteDetail
    case deleteDeliveryRouteTitle
    case deleteRecord
    case deleteRecordEverywhere
    case deleteRecordEverywhereConfirmationTitle
    case deleteRecordEverywhereDetail
    case deleteRoute
    case deliveryRouteTitle
    case deliveryRoutesDetail
    case deliveryRoutesEmpty
    case deliveryRoutesTitle
    case destinationCollections
    case disableAffectedRoutes
    case disabledState
    case edit
    case emptyTextPayload
    case enabledState
    case enabledToggle
    case imagePayload
    case imageUnavailable
    case insertInPreviousApp
    case membershipActive
    case membershipConsumed
    case metadataSource
    case metadataTags
    case metadataTitle
    case metadataUses
    case newCollection
    case noCollection
    case noMembershipHint
    case noRecordsDescription
    case noRecordsTitle
    case ok
    case paneRecords
    case paneRoutes
    case pinnedOnly
    case preset
    case priorityFormat
    case priorityLabelFormat
    case recordCountFormat
    case recordRoutesTitle
    case recordsHeaderDetail
    case recordsUpdateFailedTitle
    case removeFromCollectionFormat
    case removeFromThisCollection
    case replace
    case replaceDescription
    case replaceInAllCollections
    case replaceInAllCollectionsHint
    case replaceInCurrentCollection
    case replaceWithFormat
    case routesHeaderDetail
    case save
    case selectRecordPrompt
    case selectionManual
    case selectionNewest
    case selectionOldest
    case selectionPolicy
    case sinkCollectionFallback
    case sinkFocusedApplication
    case sinkLabel
    case sinkRecordCollection
    case sinkSystemClipboard
    case sourceBundleIDsField
    case sourceCollectionsLabel
    case sourceUser
    case sourceVoiceInput
    case sourceWorkflow
    case targetBundleIDsField
    case targetCollection
    case workflowUUIDField
    case workflowsCountFormat
}

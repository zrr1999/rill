import Foundation
import RillCore

public enum QuickRecordText: CaseIterable {
  case meaningSearch, semanticCandidates, downloadSearchModel, localSearchNotice, preparingSearchModel
  case semanticFailed, semanticChanged, semanticQueryTooLong, semanticNoResults, semanticLimited
  case copied, unpin, recordInUse
  case targetUnavailable, permissionRequired, recordUnavailable, storageUnavailable
  case recordDeletion, collectionDeletion, membershipDeletion, memberships, expiredRecords
  case title, search, noResults, noRecords, searching, paste, copy, preview, showInRecords
  case pinned, currentApp, allTypes, text, image, files, cleanup, cleanupTitle, cleanupDescription
  case delete, cancel, protectedRecords, freeSpace, capacityWarning, capacityFull, cleanupChanged
  case failed, deliveryBlocked, deliveryFailed, outputCommitted, close, loadMore, capturePaused
}

extension L10n {
  public static func quickRecord(_ key: QuickRecordText, language: AppLanguage) -> String {
    switch (key, language) {
    case (.meaningSearch, .english): "Search by meaning"
    case (.meaningSearch, .simplifiedChinese): "按含义补充"
    case (.semanticCandidates, .english): "Semantic candidates"
    case (.semanticCandidates, .simplifiedChinese): "语义候选"
    case (.downloadSearchModel, .english): "Download search model (1.2 GB)"
    case (.downloadSearchModel, .simplifiedChinese): "下载搜索模型（1.2 GB）"
    case (.localSearchNotice, .english): "Queries and records stay on this Mac."
    case (.localSearchNotice, .simplifiedChinese): "查询和记录仅在本机处理。"
    case (.preparingSearchModel, .english): "Preparing search model…"
    case (.preparingSearchModel, .simplifiedChinese): "正在准备搜索模型…"
    case (.semanticFailed, .english): "Semantic search failed. Try again."
    case (.semanticFailed, .simplifiedChinese): "语义搜索失败，请重试。"
    case (.semanticChanged, .english): "Records changed. Search again."
    case (.semanticChanged, .simplifiedChinese): "记录已变化，请重新搜索。"
    case (.semanticQueryTooLong, .english): "Shorten the query and try again."
    case (.semanticQueryTooLong, .simplifiedChinese): "请缩短查询内容后重试。"
    case (.semanticNoResults, .english): "No additional candidates."
    case (.semanticNoResults, .simplifiedChinese): "没有更多候选记录。"
    case (.semanticLimited, .english): "Long records were searched in part."
    case (.semanticLimited, .simplifiedChinese): "较长记录仅搜索了部分内容。"
    case (.copied, .english): "Copied to the clipboard."
    case (.copied, .simplifiedChinese): "已复制到剪贴板。"
    case (.unpin, .english): "Unpin"
    case (.unpin, .simplifiedChinese): "取消置顶"
    case (.recordInUse, .english):
      "This record is being delivered. Wait for delivery to finish before deleting it."
    case (.recordInUse, .simplifiedChinese): "此记录正在投递，请在投递结束后删除。"
    case (.targetUnavailable, .english):
      "The target application changed or closed. Return to the intended app and open Clipboard again."
    case (.targetUnavailable, .simplifiedChinese): "目标应用已切换或关闭。请返回要粘贴的应用后重新唤起剪贴板。"
    case (.permissionRequired, .english):
      "Allow Accessibility access in System Settings to paste. You can still use Copy only."
    case (.permissionRequired, .simplifiedChinese): "请在系统设置中授予辅助功能权限后粘贴，当前仍可使用“仅复制”。"
    case (.recordUnavailable, .english):
      "This record changed or is no longer available. Select it again from the refreshed results."
    case (.recordUnavailable, .simplifiedChinese): "此记录已变化或失效，请从刷新后的结果中重新选择。"
    case (.storageUnavailable, .english):
      "The record could not be read from local storage. Check storage availability before trying again."
    case (.storageUnavailable, .simplifiedChinese): "无法从本地存储读取记录，请检查存储状态后重试。"
    case (.recordDeletion, .english):
      "Delete this record everywhere, including all of its collection memberships. This cannot be undone."
    case (.recordDeletion, .simplifiedChinese): "从所有位置删除此记录及其记录集成员关系。此操作无法撤销。"
    case (.collectionDeletion, .english):
      "Remove this collection and its memberships. The records themselves are kept."
    case (.collectionDeletion, .simplifiedChinese): "删除此记录集及其成员关系，保留记录正文。"
    case (.membershipDeletion, .english):
      "Remove this membership from its collection. The record itself is kept."
    case (.membershipDeletion, .simplifiedChinese): "从记录集中移除此成员关系，保留记录正文。"
    case (.memberships, .english): "Collection memberships removed"
    case (.memberships, .simplifiedChinese): "移除成员关系"
    case (.expiredRecords, .english): "Review expired history…"
    case (.expiredRecords, .simplifiedChinese): "查看到期历史…"
    case (.title, .english): "Clipboard"
    case (.title, .simplifiedChinese): "剪贴板"
    case (.search, .english): "Search records"
    case (.search, .simplifiedChinese): "搜索记录"
    case (.noResults, .english): "No matching records"
    case (.noResults, .simplifiedChinese): "没有匹配的记录"
    case (.noRecords, .english): "Copied content will appear here"
    case (.noRecords, .simplifiedChinese): "复制的内容会显示在这里"
    case (.searching, .english): "Searching…"
    case (.searching, .simplifiedChinese): "正在搜索…"
    case (.paste, .english): "Paste"
    case (.paste, .simplifiedChinese): "粘贴"
    case (.copy, .english): "Copy only"
    case (.copy, .simplifiedChinese): "仅复制"
    case (.preview, .english): "Preview"
    case (.preview, .simplifiedChinese): "预览"
    case (.showInRecords, .english): "Show in Records"
    case (.showInRecords, .simplifiedChinese): "在记录中查看"
    case (.pinned, .english): "Pinned"
    case (.pinned, .simplifiedChinese): "置顶"
    case (.currentApp, .english): "Current app"
    case (.currentApp, .simplifiedChinese): "当前应用"
    case (.allTypes, .english): "All types"
    case (.allTypes, .simplifiedChinese): "全部类型"
    case (.text, .english): "Text"
    case (.text, .simplifiedChinese): "文本"
    case (.image, .english): "Image"
    case (.image, .simplifiedChinese): "图片"
    case (.files, .english): "Files"
    case (.files, .simplifiedChinese): "文件"
    case (.cleanup, .english): "Review cleanup…"
    case (.cleanup, .simplifiedChinese): "查看并清理…"
    case (.cleanupTitle, .english): "Review records to delete"
    case (.cleanupTitle, .simplifiedChinese): "确认清理记录"
    case (.cleanupDescription, .english):
      "Deletes ordinary clipboard history, oldest first. Pinned, tagged, organized and in-use records are kept."
    case (.cleanupDescription, .simplifiedChinese): "按最旧优先清理普通剪贴板历史。置顶、带标签、已整理和正在使用的记录会保留。"
    case (.delete, .english): "Delete records"
    case (.delete, .simplifiedChinese): "删除记录"
    case (.cancel, .english): "Cancel"
    case (.cancel, .simplifiedChinese): "取消"
    case (.protectedRecords, .english): "Records kept"
    case (.protectedRecords, .simplifiedChinese): "保留记录"
    case (.freeSpace, .english): "Space to reclaim"
    case (.freeSpace, .simplifiedChinese): "预计释放空间"
    case (.capacityWarning, .english):
      "History has reached 50% of its capacity. You can review cleanup at any time."
    case (.capacityWarning, .simplifiedChinese): "历史用量已达到容量的 50%，可随时查看并清理。"
    case (.capacityFull, .english): "History is full. Review cleanup to resume saving new records."
    case (.capacityFull, .simplifiedChinese): "历史容量已满，确认清理后可继续保存新记录。"
    case (.cleanupChanged, .english):
      "Records changed. Review the updated cleanup before confirming again."
    case (.cleanupChanged, .simplifiedChinese): "记录已变化，请查看更新后的清理范围并重新确认。"
    case (.failed, .english): "Records could not be updated. Try again."
    case (.failed, .simplifiedChinese): "记录更新失败，请重试。"
    case (.deliveryBlocked, .english):
      "Paste was stopped. Check the target app and Accessibility permission, then try again."
    case (.deliveryBlocked, .simplifiedChinese): "粘贴已停止。请检查目标应用和辅助功能权限后重试。"
    case (.deliveryFailed, .english): "The record could not be delivered. Try again."
    case (.deliveryFailed, .simplifiedChinese): "记录投递失败，请重试。"
    case (.outputCommitted, .english):
      "Content may already be pasted. Local recovery is pending; do not paste it again."
    case (.outputCommitted, .simplifiedChinese): "内容可能已粘贴，本地恢复尚未完成；请勿重复粘贴。"
    case (.close, .english): "Close"
    case (.close, .simplifiedChinese): "关闭"
    case (.loadMore, .english): "Load more"
    case (.loadMore, .simplifiedChinese): "加载更多"
    case (.capturePaused, .english): "Clipboard capture is paused. Saved records remain available."
    case (.capturePaused, .simplifiedChinese): "剪贴板采集已暂停，仍可使用已保存的记录。"
    }
  }

  public static func recordCapacity(_ capacity: RecordCapacity, language: AppLanguage) -> String {
    let count =
      language == .english
      ? "\(capacity.count) / \(capacity.maximumCount) records"
      : "\(capacity.count) / \(capacity.maximumCount) 条"
    let used = Double(capacity.byteCount) / 1_048_576
    let total = capacity.maximumByteCount / 1_048_576
    return "\(count) · \(String(format: "%.1f", used)) / \(total) MiB"
  }
}


extension RecordReuseOutcome {
  var feedback: QuickRecordText? {
    switch self {
    case .delivered: nil
    case .copied: .copied
    case .blocked: .deliveryBlocked
    case .targetUnavailable: .targetUnavailable
    case .permissionRequired: .permissionRequired
    case .recordUnavailable: .recordUnavailable
    case .storageUnavailable: .storageUnavailable
    case .failed: .deliveryFailed
    case .outputCommittedWithIssue: .outputCommitted
    }
  }
}

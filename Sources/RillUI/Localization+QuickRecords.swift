import Foundation
import RillCore

public enum QuickRecordText: CaseIterable {
  case advancedSearch
  case expandImage, imageUnavailable, fileUnavailable, previousFile, nextFile
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
    switch key {
    case .advancedSearch: return catalogString("quickRecord.advancedSearch", language: language)
    case .expandImage: return catalogString("quickRecord.expandImage", language: language)
    case .imageUnavailable: return catalogString("quickRecord.imageUnavailable", language: language)
    case .fileUnavailable: return catalogString("quickRecord.fileUnavailable", language: language)
    case .previousFile: return catalogString("quickRecord.previousFile", language: language)
    case .nextFile: return catalogString("quickRecord.nextFile", language: language)
    case .meaningSearch: return catalogString("quickRecord.meaningSearch", language: language)
    case .semanticCandidates: return catalogString("quickRecord.semanticCandidates", language: language)
    case .downloadSearchModel: return catalogString("quickRecord.downloadSearchModel", language: language)
    case .localSearchNotice: return catalogString("quickRecord.localSearchNotice", language: language)
    case .preparingSearchModel: return catalogString("quickRecord.preparingSearchModel", language: language)
    case .semanticFailed: return catalogString("quickRecord.semanticFailed", language: language)
    case .semanticChanged: return catalogString("quickRecord.semanticChanged", language: language)
    case .semanticQueryTooLong: return catalogString("quickRecord.semanticQueryTooLong", language: language)
    case .semanticNoResults: return catalogString("quickRecord.semanticNoResults", language: language)
    case .semanticLimited: return catalogString("quickRecord.semanticLimited", language: language)
    case .copied: return catalogString("quickRecord.copied", language: language)
    case .unpin: return catalogString("quickRecord.unpin", language: language)
    case .recordInUse: return catalogString("quickRecord.recordInUse", language: language)
    case .targetUnavailable: return catalogString("quickRecord.targetUnavailable", language: language)
    case .permissionRequired: return catalogString("quickRecord.permissionRequired", language: language)
    case .recordUnavailable: return catalogString("quickRecord.recordUnavailable", language: language)
    case .storageUnavailable: return catalogString("quickRecord.storageUnavailable", language: language)
    case .recordDeletion: return catalogString("quickRecord.recordDeletion", language: language)
    case .collectionDeletion: return catalogString("quickRecord.collectionDeletion", language: language)
    case .membershipDeletion: return catalogString("quickRecord.membershipDeletion", language: language)
    case .memberships: return catalogString("quickRecord.memberships", language: language)
    case .expiredRecords: return catalogString("quickRecord.expiredRecords", language: language)
    case .title: return catalogString("quickRecord.title", language: language)
    case .search: return catalogString("quickRecord.search", language: language)
    case .noResults: return catalogString("quickRecord.noResults", language: language)
    case .noRecords: return catalogString("quickRecord.noRecords", language: language)
    case .searching: return catalogString("quickRecord.searching", language: language)
    case .paste: return catalogString("quickRecord.paste", language: language)
    case .copy: return catalogString("quickRecord.copy", language: language)
    case .preview: return catalogString("quickRecord.preview", language: language)
    case .showInRecords: return catalogString("quickRecord.showInRecords", language: language)
    case .pinned: return catalogString("quickRecord.pinned", language: language)
    case .currentApp: return catalogString("quickRecord.currentApp", language: language)
    case .allTypes: return catalogString("quickRecord.allTypes", language: language)
    case .text: return catalogString("quickRecord.text", language: language)
    case .image: return catalogString("quickRecord.image", language: language)
    case .files: return catalogString("quickRecord.files", language: language)
    case .cleanup: return catalogString("quickRecord.cleanup", language: language)
    case .cleanupTitle: return catalogString("quickRecord.cleanupTitle", language: language)
    case .cleanupDescription: return catalogString("quickRecord.cleanupDescription", language: language)
    case .delete: return catalogString("quickRecord.delete", language: language)
    case .cancel: return catalogString("quickRecord.cancel", language: language)
    case .protectedRecords: return catalogString("quickRecord.protectedRecords", language: language)
    case .freeSpace: return catalogString("quickRecord.freeSpace", language: language)
    case .capacityWarning: return catalogString("quickRecord.capacityWarning", language: language)
    case .capacityFull: return catalogString("quickRecord.capacityFull", language: language)
    case .cleanupChanged: return catalogString("quickRecord.cleanupChanged", language: language)
    case .failed: return catalogString("quickRecord.failed", language: language)
    case .deliveryBlocked: return catalogString("quickRecord.deliveryBlocked", language: language)
    case .deliveryFailed: return catalogString("quickRecord.deliveryFailed", language: language)
    case .outputCommitted: return catalogString("quickRecord.outputCommitted", language: language)
    case .close: return catalogString("quickRecord.close", language: language)
    case .loadMore: return catalogString("quickRecord.loadMore", language: language)
    case .capturePaused: return catalogString("quickRecord.capturePaused", language: language)
    }
  }

  public static func recordCapacity(_ capacity: RecordCapacity, language: AppLanguage) -> String {
    let count =
      L10n.resource(
        "Localization.QuickRecords.records", defaultValue: "\(String(describing: capacity.count)) / \(String(describing: capacity.maximumCount)) records"
      ).string(for: language)
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

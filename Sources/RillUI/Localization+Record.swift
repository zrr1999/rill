import Foundation
import RillCore

extension L10n {
  static func recordText(_ key: RecordTextKey, language: AppLanguage) -> String {
    catalogString("record.\(key.rawValue)", language: language)
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

  static func onlyFromSourceApp(_ applicationName: String, language: AppLanguage) -> String {
    String(format: recordText(.currentAppSourceOnlyFormat, language: language), applicationName)
  }

  static func recordsUpdateFailureReason(_ detail: String, language: AppLanguage) -> String {
    String(format: recordText(.recordsUpdateFailedReasonFormat, language: language), detail)
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
  case currentAppSourceOnly
  case currentAppSourceOnlyFormat
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
  case digitInsertHint
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
  case metadataCopies
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
  case panePickerLabel
  case paneRecords
  case paneRoutes
  case pinnedOnly
  case preset
  case priorityFormat
  case priorityLabelFormat
  case recordCountFormat
  case recordRoutesTitle
  case recordsHeaderDetail
  case recordsUpdateFailedReasonFormat
  case recordsUpdateFailedSuggestion
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

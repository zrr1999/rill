import Foundation

enum WorkspaceText: CaseIterable {
  case allRecords
  case collectionSettings
  case recordRules
  case general
  case input
  case voiceModels
  case vocabularyMemory
  case privacy
  case data
  case contextMemory
  case contextMemorySummary
  case diagnosticsSummary
  case recordsSearching
  case recordsUnavailable
  case recordUnavailable
  case loadMore
  case searchRill
  case done
  case copy
  case collections
  case records
  case selectWorkflow
  case searchEverywhere
  case showDetails
  case allTypes
  case source
  case allSources
}

extension L10n {
  static func workspace(_ key: WorkspaceText, language: AppLanguage) -> String {
    switch key {
    case .allRecords: return catalogString("workspace.allRecords", language: language)
    case .collectionSettings: return catalogString("workspace.collectionSettings", language: language)
    case .recordRules: return catalogString("workspace.recordRules", language: language)
    case .general: return catalogString("workspace.general", language: language)
    case .input: return catalogString("workspace.input", language: language)
    case .voiceModels: return catalogString("workspace.voiceModels", language: language)
    case .vocabularyMemory: return catalogString("workspace.vocabularyMemory", language: language)
    case .privacy: return catalogString("workspace.privacy", language: language)
    case .data: return catalogString("workspace.data", language: language)
    case .contextMemory: return catalogString("workspace.contextMemory", language: language)
    case .contextMemorySummary: return catalogString("workspace.contextMemorySummary", language: language)
    case .diagnosticsSummary: return catalogString("workspace.diagnosticsSummary", language: language)
    case .recordsSearching: return catalogString("workspace.recordsSearching", language: language)
    case .recordsUnavailable: return catalogString("workspace.recordsUnavailable", language: language)
    case .recordUnavailable: return catalogString("workspace.recordUnavailable", language: language)
    case .loadMore: return catalogString("workspace.loadMore", language: language)
    case .searchRill: return catalogString("workspace.searchRill", language: language)
    case .done: return catalogString("workspace.done", language: language)
    case .copy: return catalogString("workspace.copy", language: language)
    case .collections: return catalogString("workspace.collections", language: language)
    case .records: return catalogString("workspace.records", language: language)
    case .selectWorkflow: return catalogString("workspace.selectWorkflow", language: language)
    case .searchEverywhere: return catalogString("workspace.searchEverywhere", language: language)
    case .showDetails: return catalogString("workspace.showDetails", language: language)
    case .allTypes: return catalogString("workspace.allTypes", language: language)
    case .source: return catalogString("workspace.source", language: language)
    case .allSources: return catalogString("workspace.allSources", language: language)
    }
  }
}

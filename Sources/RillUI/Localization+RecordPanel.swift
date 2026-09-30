import Foundation
import RillCore

enum RecordPanelText: CaseIterable {
  case drafts
  case collections
  case panelContent
  case keepOpen
  case keepOpenHelp
  case outputStatus
  case done
  case review
  case previousOutputNeedsConfirmation
  case localContent
  case deliveredButNotSaved
  case confirmInsertion
  case retrySave
  case inserted
  case retryItem
  case moveAndOpen
  case needsAttention
  case closeFloatingWindow
  case draftSources
  case configureDraftSources
  case draftList
  case newDraft
  case draftOptions
  case searchDrafts
  case sendWhenReady
  case doneEditing
  case copy
  case send
  case noMatchingDrafts
  case reviewEdits
  case reviewResults
  case collection
  case allRecords
  case searchAndFilterOptions
  case addToDrafts
}

extension L10n {
  static func recordPanel(_ key: RecordPanelText, language: AppLanguage) -> String {
    switch (key, language) {
    case (.drafts, .english): "Drafts"
    case (.drafts, .simplifiedChinese): "待发"
    case (.collections, .english): "Collections"
    case (.collections, .simplifiedChinese): "记录集"
    case (.panelContent, .english): "Panel content"
    case (.panelContent, .simplifiedChinese): "面板内容"
    case (.keepOpen, .english): "Keep open"
    case (.keepOpen, .simplifiedChinese): "保持显示"
    case (.keepOpenHelp, .english): "Keep this page open when the pointer leaves or you switch apps"
    case (.keepOpenHelp, .simplifiedChinese): "鼠标移出或切换应用时保持页面展开"
    case (.outputStatus, .english): "Output status"
    case (.outputStatus, .simplifiedChinese): "输出状态"
    case (.done, .english): "Done"
    case (.done, .simplifiedChinese): "完成"
    case (.review, .english): "Review"
    case (.review, .simplifiedChinese): "查看"
    case (.previousOutputNeedsConfirmation, .english): "Previous output needs confirmation"
    case (.previousOutputNeedsConfirmation, .simplifiedChinese): "上一条输出结果待确认"
    case (.localContent, .english): "Content stays on this Mac"
    case (.localContent, .simplifiedChinese): "内容保存在本机"
    case (.deliveredButNotSaved, .english): "Delivered; state not saved"
    case (.deliveredButNotSaved, .simplifiedChinese): "已输出，状态尚未保存"
    case (.confirmInsertion, .english): "Check the target before confirming insertion."
    case (.confirmInsertion, .simplifiedChinese): "检查目标中的内容，再确认输出结果。"
    case (.retrySave, .english): "Retry save"
    case (.retrySave, .simplifiedChinese): "重试保存"
    case (.inserted, .english): "Inserted"
    case (.inserted, .simplifiedChinese): "已插入"
    case (.retryItem, .english): "Retry item"
    case (.retryItem, .simplifiedChinese): "重试此项"
    case (.moveAndOpen, .english): "Drafts. Drag to move; hover to open."
    case (.moveAndOpen, .simplifiedChinese): "待发，拖动以移动，停留以展开"
    case (.needsAttention, .english): "Needs attention"
    case (.needsAttention, .simplifiedChinese): "有内容待处理"
    case (.closeFloatingWindow, .english): "Close floating window"
    case (.closeFloatingWindow, .simplifiedChinese): "关闭悬浮窗"
    case (.draftSources, .english): "Draft sources"
    case (.draftSources, .simplifiedChinese): "待发来源"
    case (.configureDraftSources, .english): "Draft sources…"
    case (.configureDraftSources, .simplifiedChinese): "待发来源…"
    case (.draftList, .english): "Drafts"
    case (.draftList, .simplifiedChinese): "待发列表"
    case (.newDraft, .english): "New draft"
    case (.newDraft, .simplifiedChinese): "新建草稿"
    case (.draftOptions, .english): "Draft options"
    case (.draftOptions, .simplifiedChinese): "待发选项"
    case (.searchDrafts, .english): "Search drafts"
    case (.searchDrafts, .simplifiedChinese): "搜索待发"
    case (.sendWhenReady, .english): "Send when ready"
    case (.sendWhenReady, .simplifiedChinese): "准备好后发送"
    case (.doneEditing, .english): "Done editing"
    case (.doneEditing, .simplifiedChinese): "完成编辑"
    case (.copy, .english): "Copy"
    case (.copy, .simplifiedChinese): "复制"
    case (.send, .english): "Send"
    case (.send, .simplifiedChinese): "发送"
    case (.noMatchingDrafts, .english): "No matching drafts"
    case (.noMatchingDrafts, .simplifiedChinese): "没有匹配的待发项"
    case (.reviewEdits, .english): "Review edits"
    case (.reviewEdits, .simplifiedChinese): "查看差异"
    case (.reviewResults, .english): "Review results"
    case (.reviewResults, .simplifiedChinese): "有结果待应用"
    case (.collection, .english): "Collection"
    case (.collection, .simplifiedChinese): "记录集"
    case (.allRecords, .english): "All Records"
    case (.allRecords, .simplifiedChinese): "全部记录"
    case (.searchAndFilterOptions, .english): "Search and filter options"
    case (.searchAndFilterOptions, .simplifiedChinese): "搜索与筛选选项"
    case (.addToDrafts, .english): "Add to Drafts"
    case (.addToDrafts, .simplifiedChinese): "加入待发"
    }
  }
}

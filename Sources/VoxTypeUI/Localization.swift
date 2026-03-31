import Foundation
import VoxTypeCore

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english
    case simplifiedChinese

    public var id: String { rawValue }

    public static var preferred: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    public var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "中文"
        }
    }
}

public struct EventFeedEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let english: String
    public let simplifiedChinese: String

    public init(id: UUID = UUID(), english: String, simplifiedChinese: String) {
        self.id = id
        self.english = english
        self.simplifiedChinese = simplifiedChinese
    }

    public func text(for language: AppLanguage) -> String {
        switch language {
        case .english:
            return english
        case .simplifiedChinese:
            return simplifiedChinese
        }
    }
}

public enum UIStrings {
    public enum Key {
        case appTitle
        case menuBarLabel
        case appSubtitle
        case workflow
        case language
        case runSelectedWorkflow
        case running
        case workflowRecordAndRun
        case workflowStopAndTranscribe
        case workflowTranscribing
        case pasteTopOfStack
        case deliveryStack
        case latestOutput
        case eventFeed
        case eventFeedEmpty
        case stackEmpty
        case noCompletedOutput
        case noRecentFailure
        case permissions
        case permissionHint
        case refreshPermissions
        case accessibility
        case microphone
        case requestAccess
        case openSettings
        case appNotListedHint
        case commandVHint
        case candidateResolution
        case candidateResolutionHint
        case selectReplacement
        case ambiguousText
        case resolvedPreview
        case applySelection
        case useDefaults
        case dismiss
        case copy
        case sidebarDashboard
        case sidebarWorkflows
        case sidebarClipboard
        case sidebarHistory
        case sidebarDiagnostics
        case sidebarSettings
        case openWorkflowEditor
        case settingsTitle
        case settingsDescription
        case historyEmpty
        case historyTitle
        case historyDescription
        case historyStackBadge
        case clipboardTitle
        case clipboardDescription
        case clipboardGroups
        case clipboardGroupsEmpty
        case clipboardGroupPreviewEmpty
        case clipboardAppAssignments
        case clipboardAppAssignmentsEmpty
        case clipboardAssignedGroup
        case clipboardCreateGroup
        case clipboardNewGroupName
        case clipboardCreate
        case clipboardDefaultGroup
        case clipboardHistory
        case clipboardRouting
        case clipboardMergeSimilar
        case clipboardMergeSimilarHint
        case clipboardMergedSimilarBadge
        case clipboardEmpty
        case clipboardNoResults
        case clipboardSelectItem
        case clipboardReplayWithWorkflow
        case clipboardReplaceWithWorkflow
        case clipboardUseItem
        case clipboardDeleteItem
        case clipboardSearch
        case clipboardAlternatives
        case clipboardTags
        case clipboardSystemSourceFallback
        case clipboardWorkflowSourceFallback
        case settingsLanguage
        case settingsLanguageDescription
        case settingsClipboardPanel
        case settingsClipboardPanelDescription
        case clipboardPanelHotkeyRecord
        case clipboardPanelHotkeyRecording
        case clipboardPanelHotkeyReset
        case clipboardPanelHotkeyHint
        case clipboardPanelHotkeyDefault
        case settingsStackDelivery
        case settingsStackDescription
        case settingsStackStatus
        case settingsDiagnostics
        case settingsDiagnosticsDescription
        case refreshDiagnostics
        case diagnosticsEmpty
        case settingsDeepgram
        case settingsDeepgramDescription
        case settingsSpeechEngine
        case settingsSpeechEngineDescription
        case settingsWhisperKit
        case settingsWhisperKitDescription
        case whisperKitModel
        case whisperKitDownloadedModels
        case whisperKitDownloaded
        case whisperKitNotDownloaded
        case whisperKitCustomModel
        case whisperKitCustomModelHint
        case whisperKitCustomModelRequired
        case whisperKitModelRepo
        case whisperKitModelToken
        case whisperKitModelFolder
        case whisperKitLanguage
        case whisperKitAutoDownload
        case whisperKitPrewarm
        case whisperKitPrepare
        case whisperKitPreparing
        case whisperKitPreparationReady
        case whisperKitPreparationHint
        case deepgramAPIKey
        case deepgramBaseURL
        case deepgramModel
        case deepgramLanguage
        case deepgramTestHint
        case deepgramRecordTest
        case deepgramStopAndTest
        case deepgramTesting
        case deepgramLastTranscript
        case deepgramNoTranscript
        case deepgramMicrophoneRequired
        case settingsWorkflows
        case settingsWorkflowsDescription
        case stackPasteRequiresAccessibility
        case diagnosticsTitle
        case diagnosticsDescription
        case diagnosticsSpeechCheck
        case diagnosticsSpeechCheckDescription
        case diagnosticsTimeline
        case diagnosticsManageProviderSettings
        case diagnosticsOpenSettings
        case workflowsTitle
        case workflowsDescription
        case workflowEditor
        case workflowLibrary
        case workflowNew
        case workflowSave
        case workflowReset
        case workflowNameField
        case workflowRecognizer
        case workflowDestination
        case workflowTrigger
        case workflowLocalModel
        case workflowGlobalModelDefault
        case workflowNormalizeWhitespace
        case workflowExcludeFromCapture
        case workflowExcludeFromCaptureHint
        case workflowBuiltIn
        case workflowCustom
        case workflowSelected
        case workflowEdit
        case workflowDelete
        case workflowUse
        case workflowEnabled
        case workflowCustomEmpty
    }

    public static func text(_ key: Key, language: AppLanguage) -> String {
        switch (language, key) {
        case (.english, .appTitle):
            return "VoxType"
        case (.simplifiedChinese, .appTitle):
            return "VoxType"
        case (.english, .menuBarLabel):
            return "VoxType"
        case (.simplifiedChinese, .menuBarLabel):
            return "VoxType"
        case (.english, .appSubtitle):
            return "Hands-free writing with voice workflows, clipboard history, and fast replay."
        case (.simplifiedChinese, .appSubtitle):
            return "用语音工作流、剪贴板历史和快速重放来更高效地输入内容。"
        case (.english, .workflow):
            return "Current Workflow"
        case (.simplifiedChinese, .workflow):
            return "当前工作流"
        case (.english, .language):
            return "Language"
        case (.simplifiedChinese, .language):
            return "界面语言"
        case (.english, .runSelectedWorkflow):
            return "Start Workflow"
        case (.simplifiedChinese, .runSelectedWorkflow):
            return "开始工作流"
        case (.english, .running):
            return "Running..."
        case (.simplifiedChinese, .running):
            return "运行中..."
        case (.english, .workflowRecordAndRun):
            return "Record and Run"
        case (.simplifiedChinese, .workflowRecordAndRun):
            return "录音并运行"
        case (.english, .workflowStopAndTranscribe):
            return "Stop and Transcribe"
        case (.simplifiedChinese, .workflowStopAndTranscribe):
            return "停止并转写"
        case (.english, .workflowTranscribing):
            return "Transcribing..."
        case (.simplifiedChinese, .workflowTranscribing):
            return "转写中..."
        case (.english, .pasteTopOfStack):
            return "Paste Next Clipboard Item"
        case (.simplifiedChinese, .pasteTopOfStack):
            return "粘贴下一个剪贴板条目"
        case (.english, .deliveryStack):
            return "Clipboard Queue"
        case (.simplifiedChinese, .deliveryStack):
            return "剪贴板队列"
        case (.english, .latestOutput):
            return "Last Result"
        case (.simplifiedChinese, .latestOutput):
            return "最近结果"
        case (.english, .eventFeed):
            return "Activity"
        case (.simplifiedChinese, .eventFeed):
            return "活动"
        case (.english, .eventFeedEmpty):
            return "No events yet. Run a workflow to see activity here."
        case (.simplifiedChinese, .eventFeedEmpty):
            return "暂无事件。运行工作流后，活动将显示在此处。"
        case (.english, .stackEmpty):
            return "Clipboard queue is empty"
        case (.simplifiedChinese, .stackEmpty):
            return "剪贴板队列为空"
        case (.english, .noCompletedOutput):
            return "No results yet"
        case (.simplifiedChinese, .noCompletedOutput):
            return "还没有结果"
        case (.english, .noRecentFailure):
            return "No recent issues"
        case (.simplifiedChinese, .noRecentFailure):
            return "最近没有问题"
        case (.english, .permissions):
            return "Permissions"
        case (.simplifiedChinese, .permissions):
            return "权限"
        case (.english, .permissionHint):
            return "Accessibility is required to paste into other apps. Microphone access is required for voice capture and speech checks."
        case (.simplifiedChinese, .permissionHint):
            return "辅助功能权限用于把文本输入到其他应用；麦克风权限用于录音和语音测试。"
        case (.english, .refreshPermissions):
            return "Refresh"
        case (.simplifiedChinese, .refreshPermissions):
            return "刷新状态"
        case (.english, .accessibility):
            return "Accessibility"
        case (.simplifiedChinese, .accessibility):
            return "辅助功能"
        case (.english, .microphone):
            return "Microphone"
        case (.simplifiedChinese, .microphone):
            return "麦克风"
        case (.english, .requestAccess):
            return "Request Access"
        case (.simplifiedChinese, .requestAccess):
            return "请求授权"
        case (.english, .openSettings):
            return "Open Settings"
        case (.simplifiedChinese, .openSettings):
            return "打开设置"
        case (.english, .appNotListedHint):
            return "If the app is not listed in Privacy settings yet, click Request Access once first. The system only adds it after an authorization prompt has been requested."
        case (.simplifiedChinese, .appNotListedHint):
            return "如果你还没在隐私权限列表里看到这个应用，请先点一次“请求授权”。系统通常会在触发授权提示后才把它加入列表。"
        case (.english, .commandVHint):
            return "When the clipboard queue has pending items, Command-V pastes the next one. Double-tap Command to open the clipboard panel."
        case (.simplifiedChinese, .commandVHint):
            return "当剪贴板队列里还有待处理条目时，Command-V 会粘贴下一个。双击 Command 可以打开剪贴板面板。"
        case (.english, .candidateResolution):
            return "Candidate Resolution"
        case (.simplifiedChinese, .candidateResolution):
            return "候选词消歧"
        case (.english, .candidateResolutionHint):
            return "Review ambiguous spans before the workflow continues."
        case (.simplifiedChinese, .candidateResolutionHint):
            return "在工作流继续之前，请先确认这些存在歧义的词。"
        case (.english, .selectReplacement):
            return "Select the most likely replacement for this span."
        case (.simplifiedChinese, .selectReplacement):
            return "为这个歧义片段选择最可能的替换结果。"
        case (.english, .ambiguousText):
            return "Ambiguous text"
        case (.simplifiedChinese, .ambiguousText):
            return "歧义文本"
        case (.english, .resolvedPreview):
            return "Resolved Preview"
        case (.simplifiedChinese, .resolvedPreview):
            return "解析预览"
        case (.english, .applySelection):
            return "Apply Selection"
        case (.simplifiedChinese, .applySelection):
            return "应用当前选择"
        case (.english, .useDefaults):
            return "Use Defaults"
        case (.simplifiedChinese, .useDefaults):
            return "使用默认候选"
        case (.english, .dismiss):
            return "Dismiss"
        case (.simplifiedChinese, .dismiss):
            return "取消"
        case (.english, .copy):
            return "Copy"
        case (.simplifiedChinese, .copy):
            return "复制"
        case (.english, .sidebarDashboard):
            return "Dashboard"
        case (.simplifiedChinese, .sidebarDashboard):
            return "仪表盘"
        case (.english, .sidebarWorkflows):
            return "Workflows"
        case (.simplifiedChinese, .sidebarWorkflows):
            return "工作流"
        case (.english, .sidebarClipboard):
            return "Clipboard"
        case (.simplifiedChinese, .sidebarClipboard):
            return "剪贴板"
        case (.english, .sidebarHistory):
            return "Run History"
        case (.simplifiedChinese, .sidebarHistory):
            return "运行历史"
        case (.english, .sidebarDiagnostics):
            return "Diagnostics"
        case (.simplifiedChinese, .sidebarDiagnostics):
            return "诊断"
        case (.english, .sidebarSettings):
            return "Settings"
        case (.simplifiedChinese, .sidebarSettings):
            return "设置"
        case (.english, .openWorkflowEditor):
            return "Open Workflow Editor"
        case (.simplifiedChinese, .openWorkflowEditor):
            return "打开工作流编辑器"
        case (.english, .settingsTitle):
            return "Settings"
        case (.simplifiedChinese, .settingsTitle):
            return "设置"
        case (.english, .settingsDescription):
            return "Manage interface preferences, permissions, and cloud speech configuration."
        case (.simplifiedChinese, .settingsDescription):
            return "管理界面偏好、权限和云端语音配置。"
        case (.english, .historyEmpty):
            return "No runs yet. Run a workflow to see results here."
        case (.simplifiedChinese, .historyEmpty):
            return "还没有运行记录。运行一个工作流后结果会显示在这里。"
        case (.english, .historyTitle):
            return "Run History"
        case (.simplifiedChinese, .historyTitle):
            return "运行历史"
        case (.english, .historyDescription):
            return "Review completed runs, failures, and the latest text each workflow produced."
        case (.simplifiedChinese, .historyDescription):
            return "查看每次运行的结果、失败原因和最终文本。"
        case (.english, .historyStackBadge):
            return "Clipboard"
        case (.simplifiedChinese, .historyStackBadge):
            return "剪贴板"
        case (.english, .clipboardTitle):
            return "Clipboard History"
        case (.simplifiedChinese, .clipboardTitle):
            return "剪贴板历史"
        case (.english, .clipboardDescription):
            return "Review clipboard groups, assign apps into a single group, and replay any item through a workflow."
        case (.simplifiedChinese, .clipboardDescription):
            return "查看剪贴板分组，把应用归入唯一分组，并把任意条目重新交给工作流处理。"
        case (.english, .clipboardGroups):
            return "Groups"
        case (.simplifiedChinese, .clipboardGroups):
            return "分组"
        case (.english, .clipboardGroupsEmpty):
            return "No groups yet."
        case (.simplifiedChinese, .clipboardGroupsEmpty):
            return "还没有分组。"
        case (.english, .clipboardGroupPreviewEmpty):
            return "No pending item in this group."
        case (.simplifiedChinese, .clipboardGroupPreviewEmpty):
            return "这个分组里还没有待粘贴的条目。"
        case (.english, .clipboardAppAssignments):
            return "App Assignments"
        case (.simplifiedChinese, .clipboardAppAssignments):
            return "应用归组"
        case (.english, .clipboardAppAssignmentsEmpty):
            return "No app assignments yet."
        case (.simplifiedChinese, .clipboardAppAssignmentsEmpty):
            return "还没有应用归组。"
        case (.english, .clipboardAssignedGroup):
            return "Assigned Group"
        case (.simplifiedChinese, .clipboardAssignedGroup):
            return "所属分组"
        case (.english, .clipboardCreateGroup):
            return "New Group"
        case (.simplifiedChinese, .clipboardCreateGroup):
            return "新建分组"
        case (.english, .clipboardNewGroupName):
            return "Group name"
        case (.simplifiedChinese, .clipboardNewGroupName):
            return "分组名称"
        case (.english, .clipboardCreate):
            return "Create"
        case (.simplifiedChinese, .clipboardCreate):
            return "创建"
        case (.english, .clipboardDefaultGroup):
            return "Default"
        case (.simplifiedChinese, .clipboardDefaultGroup):
            return "默认组"
        case (.english, .clipboardHistory):
            return "Items"
        case (.simplifiedChinese, .clipboardHistory):
            return "条目"
        case (.english, .clipboardRouting):
            return "Routing"
        case (.simplifiedChinese, .clipboardRouting):
            return "路由"
        case (.english, .clipboardMergeSimilar):
            return "Merge similar text"
        case (.simplifiedChinese, .clipboardMergeSimilar):
            return "合并相似文本"
        case (.english, .clipboardMergeSimilarHint):
            return "When enabled, nearby text variants with small spacing, case, or punctuation differences are shown as one history entry."
        case (.simplifiedChinese, .clipboardMergeSimilarHint):
            return "开启后，只有大小写、空格或标点差异的文本会合并显示为一条历史记录。"
        case (.english, .clipboardMergedSimilarBadge):
            return "Similar"
        case (.simplifiedChinese, .clipboardMergedSimilarBadge):
            return "相似合并"
        case (.english, .clipboardEmpty):
            return "Clipboard history is empty."
        case (.simplifiedChinese, .clipboardEmpty):
            return "剪贴板历史为空。"
        case (.english, .clipboardNoResults):
            return "No clipboard items match this search."
        case (.simplifiedChinese, .clipboardNoResults):
            return "没有匹配当前搜索的剪贴板条目。"
        case (.english, .clipboardSelectItem):
            return "Select an item to preview it, run a workflow, or paste it."
        case (.simplifiedChinese, .clipboardSelectItem):
            return "选择一个条目即可预览、运行工作流或直接粘贴。"
        case (.english, .clipboardReplayWithWorkflow):
            return "Replay with Workflow"
        case (.simplifiedChinese, .clipboardReplayWithWorkflow):
            return "用工作流重放"
        case (.english, .clipboardReplaceWithWorkflow):
            return "Replace with Workflow"
        case (.simplifiedChinese, .clipboardReplaceWithWorkflow):
            return "用工作流覆盖"
        case (.english, .clipboardUseItem):
            return "Paste"
        case (.simplifiedChinese, .clipboardUseItem):
            return "粘贴"
        case (.english, .clipboardDeleteItem):
            return "Delete"
        case (.simplifiedChinese, .clipboardDeleteItem):
            return "删除"
        case (.english, .clipboardSearch):
            return "Search clipboard"
        case (.simplifiedChinese, .clipboardSearch):
            return "搜索剪贴板"
        case (.english, .clipboardAlternatives):
            return "Related Variants"
        case (.simplifiedChinese, .clipboardAlternatives):
            return "相关变体"
        case (.english, .clipboardTags):
            return "Tags"
        case (.simplifiedChinese, .clipboardTags):
            return "标签"
        case (.english, .clipboardSystemSourceFallback):
            return "System clipboard"
        case (.simplifiedChinese, .clipboardSystemSourceFallback):
            return "系统剪贴板"
        case (.english, .clipboardWorkflowSourceFallback):
            return "VoxType workflow"
        case (.simplifiedChinese, .clipboardWorkflowSourceFallback):
            return "VoxType 工作流"
        case (.english, .settingsLanguage):
            return "Language"
        case (.simplifiedChinese, .settingsLanguage):
            return "界面语言"
        case (.english, .settingsLanguageDescription):
            return "Switch the app interface between English and Simplified Chinese."
        case (.simplifiedChinese, .settingsLanguageDescription):
            return "在英文和简体中文之间切换应用界面。"
        case (.english, .settingsClipboardPanel):
            return "Clipboard Panel Shortcut"
        case (.simplifiedChinese, .settingsClipboardPanel):
            return "剪切板页面快捷键"
        case (.english, .settingsClipboardPanelDescription):
            return "Use the default double-Command gesture or record a dedicated shortcut to open the clipboard panel."
        case (.simplifiedChinese, .settingsClipboardPanelDescription):
            return "可以继续使用默认的双击 Command，也可以录制一个单独的快捷键来打开剪切板页面。"
        case (.english, .clipboardPanelHotkeyRecord):
            return "Record Shortcut"
        case (.simplifiedChinese, .clipboardPanelHotkeyRecord):
            return "录制快捷键"
        case (.english, .clipboardPanelHotkeyRecording):
            return "Press shortcut..."
        case (.simplifiedChinese, .clipboardPanelHotkeyRecording):
            return "请按下快捷键…"
        case (.english, .clipboardPanelHotkeyReset):
            return "Use Double Command"
        case (.simplifiedChinese, .clipboardPanelHotkeyReset):
            return "改回双击 Command"
        case (.english, .clipboardPanelHotkeyHint):
            return "Recording requires at least one modifier. Press Esc to cancel."
        case (.simplifiedChinese, .clipboardPanelHotkeyHint):
            return "录制时至少需要一个修饰键。按 Esc 取消。"
        case (.english, .clipboardPanelHotkeyDefault):
            return "Double Command"
        case (.simplifiedChinese, .clipboardPanelHotkeyDefault):
            return "双击 Command"
        case (.english, .settingsStackDelivery):
            return "Clipboard Delivery"
        case (.simplifiedChinese, .settingsStackDelivery):
            return "剪贴板投递"
        case (.english, .settingsStackDescription):
            return "Workflow output and external clipboard copies flow into clipboard groups. Each app belongs to one group, every group keeps an independent stack/queue/list state, and the active routed item is mirrored to the clipboard."
        case (.simplifiedChinese, .settingsStackDescription):
            return "工作流输出和外部复制的内容都会进入剪贴板分组。每个应用都归属于唯一分组，每个分组都有独立的栈 / 队列 / 列表状态，当前路由命中的条目会被镜像到系统剪贴板。"
        case (.english, .settingsStackStatus):
            return "Current routed item count:"
        case (.simplifiedChinese, .settingsStackStatus):
            return "当前路由条目数："
        case (.english, .settingsDiagnostics):
            return "Diagnostics"
        case (.simplifiedChinese, .settingsDiagnostics):
            return "诊断信息"
        case (.english, .settingsDiagnosticsDescription):
            return "Recent persisted runtime diagnostics from the local repository."
        case (.simplifiedChinese, .settingsDiagnosticsDescription):
            return "这里显示最近持久化到本地仓库的运行诊断事件。"
        case (.english, .refreshDiagnostics):
            return "Refresh Diagnostics"
        case (.simplifiedChinese, .refreshDiagnostics):
            return "刷新诊断"
        case (.english, .diagnosticsEmpty):
            return "No persisted diagnostics yet."
        case (.simplifiedChinese, .diagnosticsEmpty):
            return "还没有持久化诊断信息。"
        case (.english, .settingsDeepgram):
            return "Deepgram Cloud"
        case (.simplifiedChinese, .settingsDeepgram):
            return "Deepgram 云端识别"
        case (.english, .settingsSpeechEngine):
            return "Speech Engine"
        case (.simplifiedChinese, .settingsSpeechEngine):
            return "语音引擎"
        case (.english, .settingsSpeechEngineDescription):
            return "Choose the default engine for new workflows and the standard dictation templates."
        case (.simplifiedChinese, .settingsSpeechEngineDescription):
            return "为新建工作流和标准听写模板选择默认语音引擎。"
        case (.english, .settingsWhisperKit):
            return "WhisperKit Local"
        case (.simplifiedChinese, .settingsWhisperKit):
            return "WhisperKit 本地识别"
        case (.english, .settingsWhisperKitDescription):
            return "Runs on device and keeps audio local. Pick a model below and VoxType downloads it automatically."
        case (.simplifiedChinese, .settingsWhisperKitDescription):
            return "在本机上运行，音频不会离开设备。你只需要在下面选择模型，VoxType 会自动下载。"
        case (.english, .whisperKitModel):
            return "Local Model"
        case (.simplifiedChinese, .whisperKitModel):
            return "本地模型"
        case (.english, .whisperKitDownloadedModels):
            return "Downloaded Models"
        case (.simplifiedChinese, .whisperKitDownloadedModels):
            return "已下载模型"
        case (.english, .whisperKitDownloaded):
            return "Downloaded"
        case (.simplifiedChinese, .whisperKitDownloaded):
            return "已下载"
        case (.english, .whisperKitNotDownloaded):
            return "Not downloaded"
        case (.simplifiedChinese, .whisperKitNotDownloaded):
            return "未下载"
        case (.english, .whisperKitCustomModel):
            return "Custom Model ID"
        case (.simplifiedChinese, .whisperKitCustomModel):
            return "自定义模型 ID"
        case (.english, .whisperKitCustomModelHint):
            return "Use any WhisperKit variant from the current catalog, then press prepare to download it."
        case (.simplifiedChinese, .whisperKitCustomModelHint):
            return "可以输入当前模型目录里的任意 WhisperKit variant，然后点击准备开始下载。"
        case (.english, .whisperKitCustomModelRequired):
            return "Enter a custom WhisperKit model ID first."
        case (.simplifiedChinese, .whisperKitCustomModelRequired):
            return "请先输入自定义 WhisperKit 模型 ID。"
        case (.english, .whisperKitModelRepo):
            return "Model Repository"
        case (.simplifiedChinese, .whisperKitModelRepo):
            return "模型仓库"
        case (.english, .whisperKitModelToken):
            return "Access Token"
        case (.simplifiedChinese, .whisperKitModelToken):
            return "访问令牌"
        case (.english, .whisperKitModelFolder):
            return "Model Folder"
        case (.simplifiedChinese, .whisperKitModelFolder):
            return "模型目录"
        case (.english, .whisperKitLanguage):
            return "Default Language"
        case (.simplifiedChinese, .whisperKitLanguage):
            return "默认语言"
        case (.english, .whisperKitAutoDownload):
            return "Download model automatically when needed"
        case (.simplifiedChinese, .whisperKitAutoDownload):
            return "在需要时自动下载模型"
        case (.english, .whisperKitPrewarm):
            return "Prewarm model after loading"
        case (.simplifiedChinese, .whisperKitPrewarm):
            return "加载后立即预热模型"
        case (.english, .whisperKitPrepare):
            return "Prepare Local Model"
        case (.simplifiedChinese, .whisperKitPrepare):
            return "准备本地模型"
        case (.english, .whisperKitPreparing):
            return "Downloading and preparing local model..."
        case (.simplifiedChinese, .whisperKitPreparing):
            return "正在下载并准备本地模型..."
        case (.english, .whisperKitPreparationReady):
            return "Selected model is ready"
        case (.simplifiedChinese, .whisperKitPreparationReady):
            return "所选模型已就绪"
        case (.english, .whisperKitPreparationHint):
            return "This list is maintained from WhisperKit's current downloadable catalog. Preset selections download automatically, and you can enter a custom variant ID when you need something else."
        case (.simplifiedChinese, .whisperKitPreparationHint):
            return "这个列表来自 WhisperKit 当前可下载模型目录。选择预设模型会自动下载；如果需要其他 variant，也可以手动输入自定义 ID。"
        case (.english, .settingsDeepgramDescription):
            return "Uses your Deepgram account for cloud transcription. Add API settings here, then use Diagnostics to run a speech check."
        case (.simplifiedChinese, .settingsDeepgramDescription):
            return "使用你的 Deepgram 账号进行云端转写。先在这里填写 API 信息，再去诊断页做语音检查。"
        case (.english, .deepgramAPIKey):
            return "API Key"
        case (.simplifiedChinese, .deepgramAPIKey):
            return "API Key"
        case (.english, .deepgramBaseURL):
            return "Base URL"
        case (.simplifiedChinese, .deepgramBaseURL):
            return "Base URL"
        case (.english, .deepgramModel):
            return "Model"
        case (.simplifiedChinese, .deepgramModel):
            return "模型"
        case (.english, .deepgramLanguage):
            return "Language"
        case (.simplifiedChinese, .deepgramLanguage):
            return "语言"
        case (.english, .deepgramTestHint):
            return "Record a short sample to verify your microphone, API key, and cloud transcription setup."
        case (.simplifiedChinese, .deepgramTestHint):
            return "录一小段样本，检查麦克风、API Key 和云端转写配置是否正常。"
        case (.english, .deepgramRecordTest):
            return "Record Test Sample"
        case (.simplifiedChinese, .deepgramRecordTest):
            return "录制测试样本"
        case (.english, .deepgramStopAndTest):
            return "Stop and Transcribe"
        case (.simplifiedChinese, .deepgramStopAndTest):
            return "停止并转写"
        case (.english, .deepgramTesting):
            return "Transcribing..."
        case (.simplifiedChinese, .deepgramTesting):
            return "转写中..."
        case (.english, .deepgramLastTranscript):
            return "Latest Speech Check"
        case (.simplifiedChinese, .deepgramLastTranscript):
            return "最近一次语音检查"
        case (.english, .deepgramNoTranscript):
            return "No speech check has completed yet."
        case (.simplifiedChinese, .deepgramNoTranscript):
            return "还没有完成过语音检查。"
        case (.english, .deepgramMicrophoneRequired):
            return "Grant microphone access before recording a speech check sample."
        case (.simplifiedChinese, .deepgramMicrophoneRequired):
            return "请先授予麦克风权限，再录制语音检查样本。"
        case (.english, .settingsWorkflows):
            return "Workflows"
        case (.simplifiedChinese, .settingsWorkflows):
            return "工作流"
        case (.english, .settingsWorkflowsDescription):
            return "Registered demo workflows and their pipeline configuration."
        case (.simplifiedChinese, .settingsWorkflowsDescription):
            return "已注册的演示工作流及其管线配置。"
        case (.english, .stackPasteRequiresAccessibility):
            return "Grant Accessibility access before injecting clipboard items."
        case (.simplifiedChinese, .stackPasteRequiresAccessibility):
            return "请先授予辅助功能权限，再执行剪贴板条目注入。"
        case (.english, .diagnosticsTitle):
            return "Diagnostics"
        case (.simplifiedChinese, .diagnosticsTitle):
            return "诊断"
        case (.english, .diagnosticsDescription):
            return "Validate your speech setup and inspect recent runtime events."
        case (.simplifiedChinese, .diagnosticsDescription):
            return "检查语音配置是否正常，并查看最近的运行事件。"
        case (.english, .diagnosticsSpeechCheck):
            return "Speech Check"
        case (.simplifiedChinese, .diagnosticsSpeechCheck):
            return "语音检查"
        case (.english, .diagnosticsSpeechCheckDescription):
            return "Use this check after updating your microphone permission or Deepgram settings."
        case (.simplifiedChinese, .diagnosticsSpeechCheckDescription):
            return "更新麦克风权限或 Deepgram 配置后，可以在这里做一次快速检查。"
        case (.english, .diagnosticsTimeline):
            return "Runtime Timeline"
        case (.simplifiedChinese, .diagnosticsTimeline):
            return "运行时间线"
        case (.english, .diagnosticsManageProviderSettings):
            return "Manage Deepgram credentials in Settings before running a cloud speech check."
        case (.simplifiedChinese, .diagnosticsManageProviderSettings):
            return "在运行云端语音检查前，请先到设置页管理 Deepgram 凭据。"
        case (.english, .diagnosticsOpenSettings):
            return "Open Settings"
        case (.simplifiedChinese, .diagnosticsOpenSettings):
            return "前往设置"
        case (.english, .workflowsTitle):
            return "Workflow Editor"
        case (.simplifiedChinese, .workflowsTitle):
            return "工作流编辑器"
        case (.english, .workflowsDescription):
            return "Create reusable voice workflows, choose how they trigger, and decide where the final text should go."
        case (.simplifiedChinese, .workflowsDescription):
            return "创建可复用的语音工作流，配置触发方式，并决定最终文本的去向。"
        case (.english, .workflowEditor):
            return "Create or Edit Workflow"
        case (.simplifiedChinese, .workflowEditor):
            return "创建或编辑工作流"
        case (.english, .workflowLibrary):
            return "Workflow Library"
        case (.simplifiedChinese, .workflowLibrary):
            return "工作流库"
        case (.english, .workflowNew):
            return "New Workflow"
        case (.simplifiedChinese, .workflowNew):
            return "新建工作流"
        case (.english, .workflowSave):
            return "Save Workflow"
        case (.simplifiedChinese, .workflowSave):
            return "保存工作流"
        case (.english, .workflowReset):
            return "Reset"
        case (.simplifiedChinese, .workflowReset):
            return "重置"
        case (.english, .workflowNameField):
            return "Workflow Name"
        case (.simplifiedChinese, .workflowNameField):
            return "工作流名称"
        case (.english, .workflowRecognizer):
            return "Speech Engine"
        case (.simplifiedChinese, .workflowRecognizer):
            return "语音引擎"
        case (.english, .workflowDestination):
            return "Output Destination"
        case (.simplifiedChinese, .workflowDestination):
            return "输出位置"
        case (.english, .workflowTrigger):
            return "Trigger"
        case (.simplifiedChinese, .workflowTrigger):
            return "触发方式"
        case (.english, .workflowLocalModel):
            return "Local Model Override"
        case (.simplifiedChinese, .workflowLocalModel):
            return "本地模型覆盖"
        case (.english, .workflowGlobalModelDefault):
            return "Use global default"
        case (.simplifiedChinese, .workflowGlobalModelDefault):
            return "使用全局默认"
        case (.english, .workflowNormalizeWhitespace):
            return "Clean up spacing before delivery"
        case (.simplifiedChinese, .workflowNormalizeWhitespace):
            return "输出前整理空格与换行"
        case (.english, .workflowExcludeFromCapture):
            return "Exclude clipboard output from workflow capture"
        case (.simplifiedChinese, .workflowExcludeFromCapture):
            return "让剪贴板输出不被工作流再次捕获"
        case (.english, .workflowExcludeFromCaptureHint):
            return "Turn this off if you want clipboard-based workflow chaining."
        case (.simplifiedChinese, .workflowExcludeFromCaptureHint):
            return "关闭后，基于剪贴板的工作流链式触发会继续生效。"
        case (.english, .workflowBuiltIn):
            return "Built-in"
        case (.simplifiedChinese, .workflowBuiltIn):
            return "内置"
        case (.english, .workflowCustom):
            return "Custom"
        case (.simplifiedChinese, .workflowCustom):
            return "自定义"
        case (.english, .workflowSelected):
            return "Current"
        case (.simplifiedChinese, .workflowSelected):
            return "当前"
        case (.english, .workflowEdit):
            return "Edit"
        case (.simplifiedChinese, .workflowEdit):
            return "编辑"
        case (.english, .workflowDelete):
            return "Delete"
        case (.simplifiedChinese, .workflowDelete):
            return "删除"
        case (.english, .workflowUse):
            return "Use"
        case (.simplifiedChinese, .workflowUse):
            return "使用"
        case (.english, .workflowEnabled):
            return "Enabled"
        case (.simplifiedChinese, .workflowEnabled):
            return "启用"
        case (.english, .workflowCustomEmpty):
            return "No custom workflows yet. Create one above to get started."
        case (.simplifiedChinese, .workflowCustomEmpty):
            return "还没有自定义工作流。先在上方创建一个。"
        }
    }

    public static func stackPending(_ count: Int, language: AppLanguage) -> String {
        switch language {
        case .english:
            return count == 0 ? "Route empty" : "\(count) item(s) pending"
        case .simplifiedChinese:
            return count == 0 ? "路由为空" : "待投递 \(count) 项"
        }
    }

    public static func stackCountSummary(_ count: Int, language: AppLanguage) -> String {
        switch language {
        case .english:
            return "\(count) item(s)"
        case .simplifiedChinese:
            return "\(count) 项"
        }
    }

    public static func permissionState(_ state: PermissionState, language: AppLanguage) -> String {
        switch (language, state) {
        case (.english, .granted):
            return "Granted"
        case (.simplifiedChinese, .granted):
            return "已授权"
        case (.english, .denied):
            return "Denied"
        case (.simplifiedChinese, .denied):
            return "未授权"
        case (.english, .unknown):
            return "Unknown"
        case (.simplifiedChinese, .unknown):
            return "未知"
        }
    }

    public static func workflowName(_ workflow: WorkflowPresentation, language: AppLanguage) -> String {
        guard let titleKey = workflow.titleKey else {
            return workflow.fallbackName
        }
        switch (titleKey, language) {
        case (.ambiguousDemoStack, .english):
            return "Guided Capture"
        case (.ambiguousDemoStack, .simplifiedChinese):
            return "确认后保存"
        case (.directDemoClipboard, .english):
            return "Capture Selection"
        case (.directDemoClipboard, .simplifiedChinese):
            return "收进剪贴板组"
        case (.rewriteDemoStack, .english):
            return "Polish Draft"
        case (.rewriteDemoStack, .simplifiedChinese):
            return "润色成稿"
        case (.pushToTalkCapture, .english):
            return "Fn Dictation"
        case (.pushToTalkCapture, .simplifiedChinese):
            return "Fn 按住听写"
        case (.localDictation, .english):
            return "Local Dictation"
        case (.localDictation, .simplifiedChinese):
            return "本地听写"
        case (.cloudDictation, .english):
            return "Cloud Dictation"
        case (.cloudDictation, .simplifiedChinese):
            return "云端听写"
        case (.stackDelivery, .english):
            return "Clipboard Delivery"
        case (.stackDelivery, .simplifiedChinese):
            return "剪贴板投递"
        }
    }

    public static func candidateModeSummary(
        mode: ResolutionMode,
        timeoutSeconds: Int,
        language: AppLanguage
    ) -> String {
        switch language {
        case .english:
            return "Mode: \(resolutionMode(mode, language: language)) · Timeout: \(timeoutSeconds)s"
        case .simplifiedChinese:
            return "模式：\(resolutionMode(mode, language: language)) · 超时：\(timeoutSeconds) 秒"
        }
    }

    public static func resolutionMode(_ mode: ResolutionMode, language: AppLanguage) -> String {
        switch (language, mode) {
        case (.english, .blocking):
            return "Blocking"
        case (.simplifiedChinese, .blocking):
            return "阻塞"
        case (.english, .nonBlocking):
            return "Non-blocking"
        case (.simplifiedChinese, .nonBlocking):
            return "非阻塞"
        case (.english, .off):
            return "Off"
        case (.simplifiedChinese, .off):
            return "关闭"
        }
    }

    public static func spanSummary(lowerBound: Int, upperBound: Int, language: AppLanguage) -> String {
        switch language {
        case .english:
            return "Span \(lowerBound)-\(upperBound)"
        case .simplifiedChinese:
            return "范围 \(lowerBound)-\(upperBound)"
        }
    }

    public static func candidateSource(_ source: CandidateSource, language: AppLanguage) -> String {
        switch (language, source) {
        case (_, .asr):
            return "ASR"
        case (_, .llm):
            return "LLM"
        case (.english, .heuristic):
            return "HEURISTIC"
        case (.simplifiedChinese, .heuristic):
            return "规则"
        case (.english, .user):
            return "USER"
        case (.simplifiedChinese, .user):
            return "用户"
        }
    }

    public static func subsystem(_ subsystem: SubsystemTag, language: AppLanguage) -> String {
        switch (language, subsystem) {
        case (.english, .session):
            return "Session"
        case (.simplifiedChinese, .session):
            return "会话"
        case (.english, .stack):
            return "Queue"
        case (.simplifiedChinese, .stack):
            return "队列"
        case (.english, .clipboard):
            return "Clipboard"
        case (.simplifiedChinese, .clipboard):
            return "剪贴板"
        case (.english, .resolver):
            return "Resolution"
        case (.simplifiedChinese, .resolver):
            return "消歧"
        case (.english, .platform):
            return "Platform"
        case (.simplifiedChinese, .platform):
            return "平台"
        case (.english, .providers):
            return "Speech"
        case (.simplifiedChinese, .providers):
            return "语音服务"
        case (.english, .ui):
            return "Interface"
        case (.simplifiedChinese, .ui):
            return "界面"
        }
    }

    public static func workflowDetail(_ workflow: WorkflowDefinition, language: AppLanguage) -> String {
        let trigger = workflowTrigger(workflow.trigger, metadata: workflow.metadata, language: language)
        let recognizer = recognizerName(workflow.pipeline.recognizerID, language: language)
        let outputs = workflow.pipeline.outputActions.map { actionName($0.id, language: language) }.joined(separator: ", ")
        switch language {
        case .english:
            return "Trigger: \(trigger) · Speech: \(recognizer) · Output: \(outputs)"
        case .simplifiedChinese:
            return "触发方式：\(trigger) · 识别：\(recognizer) · 输出：\(outputs)"
        }
    }

    public static func workflowConflict(
        trigger: TriggerBinding,
        names: [String],
        language: AppLanguage
    ) -> String {
        let triggerName = workflowTrigger(trigger, language: language)
        let joinedNames = names.joined(separator: ", ")
        switch language {
        case .english:
            return "Conflict: \(triggerName) is also enabled for \(joinedNames)."
        case .simplifiedChinese:
            return "冲突：\(triggerName) 也被以下工作流启用了：\(joinedNames)。"
        }
    }

    public static func workflowEnableConflict(
        trigger: TriggerBinding,
        names: [String],
        language: AppLanguage
    ) -> String {
        let triggerName = workflowTrigger(trigger, language: language)
        let joinedNames = names.joined(separator: ", ")
        switch language {
        case .english:
            return "Cannot enable this workflow. \(triggerName) is already in use by \(joinedNames)."
        case .simplifiedChinese:
            return "无法启用这个工作流。\(triggerName) 已被以下工作流占用：\(joinedNames)。"
        }
    }

    public static func diagnosticLevel(_ level: DiagnosticLevel, language: AppLanguage) -> String {
        switch (language, level) {
        case (.english, .debug):
            return "DEBUG"
        case (.simplifiedChinese, .debug):
            return "调试"
        case (.english, .info):
            return "INFO"
        case (.simplifiedChinese, .info):
            return "信息"
        case (.english, .warning):
            return "WARNING"
        case (.simplifiedChinese, .warning):
            return "警告"
        case (.english, .error):
            return "ERROR"
        case (.simplifiedChinese, .error):
            return "错误"
        }
    }

    public static func clipboardMode(_ mode: ClipboardPasteMode, language: AppLanguage) -> String {
        switch (language, mode) {
        case (.english, .stack):
            return "Stack"
        case (.simplifiedChinese, .stack):
            return "栈"
        case (.english, .queue):
            return "Queue"
        case (.simplifiedChinese, .queue):
            return "队列"
        case (.english, .list):
            return "List"
        case (.simplifiedChinese, .list):
            return "列表"
        }
    }

    public static func clipboardSystemSource(
        applicationName: String,
        language: AppLanguage
    ) -> String {
        switch language {
        case .english:
            return "Copied from \(applicationName)"
        case .simplifiedChinese:
            return "来自 \(applicationName) 的复制"
        }
    }

    public static func clipboardWorkflowSource(
        _ workflow: WorkflowPresentation,
        language: AppLanguage
    ) -> String {
        switch language {
        case .english:
            return "Produced by \(workflowName(workflow, language: language))"
        case .simplifiedChinese:
            return "由 \(workflowName(workflow, language: language)) 产生"
        }
    }

    public static func deepgramTestButtonTitle(_ state: DeepgramAudioTestState, language: AppLanguage) -> String {
        switch state {
        case .idle:
            return text(.deepgramRecordTest, language: language)
        case .recording:
            return text(.deepgramStopAndTest, language: language)
        case .transcribing:
            return text(.deepgramTesting, language: language)
        }
    }

    public static func workflowTrigger(
        _ trigger: TriggerBinding,
        metadata: [String: String] = [:],
        language: AppLanguage
    ) -> String {
        switch (language, trigger) {
        case (.english, .manual):
            return "Manual"
        case (.simplifiedChinese, .manual):
            return "手动"
        case (.english, .menuBar):
            return "Menu Bar"
        case (.simplifiedChinese, .menuBar):
            return "菜单栏"
        case (.english, .hotkey):
            return metadata["trigger.gesture"] ?? "Hotkey"
        case (.simplifiedChinese, .hotkey):
            return metadata["trigger.gesture"] ?? "快捷键"
        case (.english, .wakeWord):
            return "Wake Word"
        case (.simplifiedChinese, .wakeWord):
            return "唤醒词"
        }
    }

    public static func recognizerName(_ id: String, language: AppLanguage) -> String {
        switch (language, id) {
        case (.english, "whisperkit.local"):
            return "Local Speech"
        case (.simplifiedChinese, "whisperkit.local"):
            return "本地识别"
        case (.english, "deepgram.prerecorded"):
            return "Deepgram Cloud"
        case (.simplifiedChinese, "deepgram.prerecorded"):
            return "Deepgram 云端识别"
        case (.english, "demo.direct"):
            return "Instant Capture"
        case (.simplifiedChinese, "demo.direct"):
            return "即时捕获"
        case (.english, "demo.ambiguous"):
            return "Guided Capture"
        case (.simplifiedChinese, "demo.ambiguous"):
            return "确认捕获"
        default:
            return id
        }
    }

    public static func actionName(_ id: String, language: AppLanguage) -> String {
        switch (language, id) {
        case (.english, "inject.text"):
            return "Paste into App"
        case (.simplifiedChinese, "inject.text"):
            return "输入到当前应用"
        case (.english, "clipboard.copy"):
            return "Copy to Clipboard"
        case (.simplifiedChinese, "clipboard.copy"):
            return "复制到剪贴板"
        case (.english, "stack.push"):
            return "Save to Queue"
        case (.simplifiedChinese, "stack.push"):
            return "保存到队列"
        default:
            return id
        }
    }

    public static func editorRecognizer(
        _ recognizer: WorkflowEditorDraft.RecognizerChoice,
        language: AppLanguage
    ) -> String {
        switch (language, recognizer) {
        case (.english, .localSpeech):
            return "Local Speech"
        case (.simplifiedChinese, .localSpeech):
            return "本地识别"
        case (.english, .cloudSpeech):
            return "Deepgram Cloud"
        case (.simplifiedChinese, .cloudSpeech):
            return "Deepgram 云端识别"
        }
    }

    public static func editorDestination(
        _ destination: WorkflowEditorDraft.DestinationChoice,
        language: AppLanguage
    ) -> String {
        switch (language, destination) {
        case (.english, .pasteIntoApp):
            return "Paste into Active App"
        case (.simplifiedChinese, .pasteIntoApp):
            return "输入到当前应用"
        case (.english, .copyToClipboard):
            return "Copy to Clipboard"
        case (.simplifiedChinese, .copyToClipboard):
            return "复制到剪贴板"
        case (.english, .saveToQueue):
            return "Save to Clipboard Queue"
        case (.simplifiedChinese, .saveToQueue):
            return "保存到剪贴板队列"
        }
    }

    public static func speechEngine(_ engine: PreferredSpeechEngine, language: AppLanguage) -> String {
        switch (language, engine) {
        case (.english, .local):
            return "Local"
        case (.simplifiedChinese, .local):
            return "本地"
        case (.english, .cloud):
            return "Cloud"
        case (.simplifiedChinese, .cloud):
            return "云端"
        }
    }

    public static func whisperKitModelOption(
        _ option: WhisperKitModelOption,
        language: AppLanguage
    ) -> String {
        switch language {
        case .english:
            switch option {
            case .automatic:
                return "Automatic (Recommended)"
            case .custom:
                return "Custom"
            default:
                return option.modelIdentifier ?? option.rawValue
            }
        case .simplifiedChinese:
            switch option {
            case .automatic:
                return "自动选择（推荐）"
            case .custom:
                return "自定义"
            default:
                return option.modelIdentifier ?? option.rawValue
            }
        }
    }
}

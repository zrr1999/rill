import Foundation
import RillCore

extension L10n {
    static func workflowText(_ key: WorkflowTextKey, language: AppLanguage) -> String {
        workflowTextTable[key]?.string(for: language) ?? key.rawValue
    }

    static func workflowOpenAIModelHint(_ model: String, language: AppLanguage) -> String {
        String(format: workflowText(.workflowOpenAIModelHintFormat, language: language), model)
    }

    static func workflowUnsupportedStepError(_ stepKind: String, language: AppLanguage) -> String {
        String(format: workflowText(.workflowUnsupportedStepFormat, language: language), stepKind)
    }

    static func workflowVocabularySummary(
        hotwordCount: Int,
        replacementCount: Int,
        language: AppLanguage
    ) -> String {
        String(
            format: workflowText(.workflowVocabularySummaryFormat, language: language),
            hotwordCount,
            replacementCount
        )
    }

    static func workflowWakePhraseValidationError(
        englishDescription: String,
        language: AppLanguage
    ) -> String {
        switch language {
        case .english:
            englishDescription
        case .simplifiedChinese:
            workflowText(.workflowWakePhraseInvalid, language: language)
        }
    }

    private static let workflowTextTable: [WorkflowTextKey: LocalizedText] = [
        .workflowActionPromptPlaceholder: .init(
            english: "LLM prompt (e.g. polish text)…",
            simplifiedChinese: "LLM 提示词（如润色文本）…"
        ),
        .workflowAddEntry: .init(english: "Add Entry", simplifiedChinese: "添加词条"),
        .workflowAddStep: .init(english: "Add Step", simplifiedChinese: "添加步骤"),
        .workflowAnyCollection: .init(english: "Any collection", simplifiedChinese: "任意记录集"),
        .workflowApplyVocabularyHint: .init(
            english: "Apply matching replacement entries before normalization and LLM rewriting.",
            simplifiedChinese: "在空白规范化和 LLM 改写之前应用匹配的替换词。"
        ),
        .workflowApplyVocabularyLabel: .init(english: "Apply Vocabulary", simplifiedChinese: "应用替换词"),
        .workflowBindingConditionLabel: .init(
            english: "Applies when (all fields match)",
            simplifiedChinese: "生效条件（字段之间为 AND）"
        ),
        .workflowBuiltinOverrideHint: .init(
            english: "Changes are saved as a TOML override for this built-in workflow. Restore Defaults removes the override.",
            simplifiedChinese: "修改会保存为此内置工作流的 TOML 覆盖；“恢复默认”会移除该覆盖。"
        ),
        .workflowBundleIDAnyPlaceholder: .init(
            english: "App bundle ID · any",
            simplifiedChinese: "App Bundle ID · 任意"
        ),
        .workflowConditionNodeTitle: .init(english: "Condition", simplifiedChinese: "条件"),
        .workflowCreateItem: .init(english: "Create Item", simplifiedChinese: "创建条目"),
        .workflowDefaultRouting: .init(english: "Default routing", simplifiedChinese: "默认路由"),
        .workflowDefaultTTSModel: .init(english: "Default enabled model", simplifiedChinese: "默认已启用模型"),
        .workflowDeleteCollectionDetail: .init(
            english: "The collection and its workflow bindings will be removed.",
            simplifiedChinese: "该词库及其工作流绑定都会被移除。"
        ),
        .workflowDeleteCollectionTitle: .init(english: "Delete collection?", simplifiedChinese: "删除词库？"),
        .workflowEditItem: .init(english: "Edit Item", simplifiedChinese: "编辑条目"),
        .workflowEditTOML: .init(english: "Edit TOML", simplifiedChinese: "编辑 TOML"),
        .workflowEditorSubtitleBuiltin: .init(
            english: "Edit this built-in workflow directly, or restore its bundled defaults later.",
            simplifiedChinese: "直接编辑这个内置工作流；之后也可以恢复到应用内置默认值。"
        ),
        .workflowEditorSubtitleEditing: .init(
            english: "Edit the selected voice mode, text style, and output destination.",
            simplifiedChinese: "编辑当前语音模式、文字风格和输出位置。"
        ),
        .workflowEditorSubtitleNew: .init(
            english: "Create a reusable voice mode with a text style and output destination.",
            simplifiedChinese: "创建可复用的语音模式，配置文字风格和输出位置。"
        ),
        .workflowEventNodeTitle: .init(english: "Event", simplifiedChinese: "事件"),
        .workflowExcludePolishItems: .init(
            english: "Exclude polish-generated items",
            simplifiedChinese: "排除润色生成的条目"
        ),
        .workflowHotwordSkippedHint: .init(
            english: "The current engine skips recognition hotwords; replacements still run after recognition.",
            simplifiedChinese: "当前识别引擎会跳过识别热词；替换词仍会在识别后执行。"
        ),
        .workflowHotwordSupportedHint: .init(
            english: "Recognition hotwords are supported by the current engine; replacements run after recognition.",
            simplifiedChinese: "当前识别引擎支持热词；替换词会在识别后执行。"
        ),
        .workflowLLMInstructionRequired: .init(
            english: "Enter an instruction for every LLM rewrite step.",
            simplifiedChinese: "请为每个大模型改写步骤填写指令。"
        ),
        .workflowLLMPromptPlaceholder: .init(english: "LLM prompt…", simplifiedChinese: "LLM 提示词…"),
        .workflowLanguageAnyPlaceholder: .init(english: "Language · any", simplifiedChinese: "语言 · 任意"),
        .workflowLivePreviewToggle: .init(english: "Live preview", simplifiedChinese: "实时预览"),
        .workflowModeOutputNodeTitle: .init(english: "Mode & Output", simplifiedChinese: "模式与输出"),
        .workflowNewCollectionPlaceholder: .init(english: "New collection", simplifiedChinese: "新词库名称"),
        .workflowNoAdditionalConditions: .init(
            english: "No additional conditions for this trigger type.",
            simplifiedChinese: "该触发类型无额外条件。"
        ),
        .workflowNoVocabularyCollections: .init(
            english: "No collections available.",
            simplifiedChinese: "暂无可用词库。"
        ),
        .workflowNotEditableError: .init(
            english: "This workflow cannot be edited in the current editor.",
            simplifiedChinese: "当前编辑器暂不支持编辑这个工作流。"
        ),
        .workflowOnDeviceBadge: .init(english: "On-device", simplifiedChinese: "设备端"),
        .workflowOpenAIModelHintFormat: .init(
            english: "OpenAI model: %@. Change it in Settings → Speech Engine.",
            simplifiedChinese: "OpenAI 模型：%@。可在“设置 → 语音引擎”中切换。"
        ),
        .workflowOpenFolder: .init(english: "Open Folder", simplifiedChinese: "打开目录"),
        .workflowOrderedActionsHint: .init(
            english: "For fully ordered output.actions, edit the workflow TOML and reload.",
            simplifiedChinese: "如需自由编排多个 output.actions，可直接编辑工作流 TOML 后重新加载。"
        ),
        .workflowOutputPhaseSubtitle: .init(
            english: "Choose a primary destination and optionally add speech playback.",
            simplifiedChinese: "选择主要输出目标，并可追加语音朗读。"
        ),
        .workflowPhrasePlaceholder: .init(english: "Phrase", simplifiedChinese: "原词"),
        .workflowPreviewCursor: .init(english: "Cursor", simplifiedChinese: "光标"),
        .workflowPreviewLocationLabel: .init(english: "Preview location", simplifiedChinese: "预览位置"),
        .workflowPreviewOverlay: .init(english: "Overlay", simplifiedChinese: "浮层"),
        .workflowProcessPhaseSubtitle: .init(
            english: "Recognize audio, apply vocabulary, then run text transforms in order.",
            simplifiedChinese: "识别音频、应用词库，再按顺序执行文本处理。"
        ),
        .workflowPromptLabel: .init(english: "Prompt", simplifiedChinese: "提示词"),
        .workflowReadAloudToggle: .init(english: "Read the final result aloud", simplifiedChinese: "朗读最终结果"),
        .workflowRecognizeSpeechHint: .init(
            english: "Audio → text using the frozen Setup route and supported hotword hints.",
            simplifiedChinese: "使用 Setup 中冻结的路由和引擎支持的热词提示，将音频转换为文本。"
        ),
        .workflowRecognizeSpeechLabel: .init(english: "Recognize Speech", simplifiedChinese: "识别语音"),
        .workflowRecordCollectionPickerLabel: .init(english: "Record collection", simplifiedChinese: "记录集"),
        .workflowRecordEventUnavailable: .init(
            english: "Record collection event workflows are unavailable until production actions and receipts are implemented.",
            simplifiedChinese: "旧版记录集事件工作流已停用；生产投递请使用记录路由。"
        ),
        .workflowReload: .init(english: "Reload", simplifiedChinese: "重新加载"),
        .workflowRemoveItem: .init(english: "Remove Item", simplifiedChinese: "移除条目"),
        .workflowReplacementKindOption: .init(english: "Replacement", simplifiedChinese: "替换词"),
        .workflowReplacementPlaceholder: .init(english: "Replacement", simplifiedChinese: "替换为"),
        .workflowRestoreDefaults: .init(english: "Restore Defaults", simplifiedChinese: "恢复默认"),
        .workflowSetupPhaseSubtitle: .init(
            english: "Resolve speech resources and freeze vocabulary for this run.",
            simplifiedChinese: "解析语音资源，并为本次运行冻结词库快照。"
        ),
        .workflowSpeakPrimaryHint: .init(
            english: "Speech is the primary output for this workflow.",
            simplifiedChinese: "朗读是此工作流的主要输出。"
        ),
        .workflowSpeakResultLabel: .init(english: "Speak Result", simplifiedChinese: "朗读结果"),
        .workflowSpeechRecognitionHint: .init(
            english: "Uses the local engine and model selected in Voice settings unless a model override is set below.",
            simplifiedChinese: "默认使用语音设置中选择的本地引擎和模型；也可在下方为此工作流指定模型。"
        ),
        .workflowSpeechRecognitionLabel: .init(english: "Speech Recognition", simplifiedChinese: "语音识别"),
        .workflowStepLLMAnswer: .init(english: "LLM Answer", simplifiedChinese: "LLM 回答"),
        .workflowStepLLMRewrite: .init(english: "LLM Polish / Rewrite", simplifiedChinese: "LLM 润色 / 改写"),
        .workflowStepNormalizeWhitespace: .init(english: "Normalize Whitespace", simplifiedChinese: "标准化空白"),
        .workflowStepSnippetReplacement: .init(english: "Snippet Replacement", simplifiedChinese: "片段替换"),
        .workflowStreamingStyleLabel: .init(english: "Streaming style", simplifiedChinese: "流式风格"),
        .workflowTOMLSourceOfTruthHint: .init(
            english: "TOML files are the source of truth. This window is a visual editor for them.",
            simplifiedChinese: "TOML 文件是唯一事实来源；此窗口只是它们的可视化编辑器。"
        ),
        .workflowTriggerHotkey: .init(english: "⌨ Hotkey", simplifiedChinese: "⌨ 快捷键"),
        .workflowTriggerManual: .init(english: "👆 Manual", simplifiedChinese: "👆 手动"),
        .workflowTriggerMenuBar: .init(english: "☰ Menu Bar", simplifiedChinese: "☰ 菜单栏"),
        .workflowTriggerTypeLabel: .init(english: "Trigger Type", simplifiedChinese: "触发类型"),
        .workflowTriggerWakeWord: .init(english: "◉ Wake Word", simplifiedChinese: "◉ 唤醒词"),
        .workflowTTSModelLabel: .init(english: "Workflow TTS model", simplifiedChinese: "工作流 TTS 模型"),
        .workflowTTSSavedHint: .init(
            english: "The TTS model and voice are saved in this workflow. Settings only controls which models are available and resident.",
            simplifiedChinese: "TTS 模型与音色均保存在此 workflow 中；设置页只控制模型是否可用及是否常驻。"
        ),
        .workflowUnsupportedStepFormat: .init(
            english: "The %@ step is not available without a configured production transformer.",
            simplifiedChinese: "尚未配置生产级 transformer，不能使用 %@ 步骤。"
        ),
        .workflowVocabularyCollectionsLabel: .init(
            english: "Vocabulary Collections",
            simplifiedChinese: "词库集合"
        ),
        .workflowVocabularyLibraryHint: .init(
            english: "Reusable hotwords and replacements attached in workflow Setup.",
            simplifiedChinese: "在工作流 Setup 中复用的热词与替换词集合。"
        ),
        .workflowVocabularySummaryFormat: .init(
            english: "%d hotwords · %d replacements",
            simplifiedChinese: "%d 个热词 · %d 个替换词"
        ),
        .workflowVoiceLabel: .init(english: "Workflow voice", simplifiedChinese: "工作流音色"),
        .workflowWakePhraseInvalid: .init(
            english: "Wake phrases must contain 1–4 unique valid phrases.",
            simplifiedChinese: "唤醒词必须包含 1–4 个不重复的有效短语。"
        ),
        .workflowWakePhrasesHint: .init(
            english: "Local listening is off by default. Prepare the selected local Qwen ASR in Voice settings before enabling this workflow.",
            simplifiedChinese: "本地监听默认关闭；启用此工作流前，请先在语音设置中准备当前本地 Qwen ASR。"
        ),
        .workflowWakePhrasesLabel: .init(english: "Wake phrases", simplifiedChinese: "唤醒短语"),
        .workflowWakePhrasesPlaceholder: .init(
            english: "One phrase per line (1–4)",
            simplifiedChinese: "每行一个短语（1–4 个）"
        ),
    ]
}

enum WorkflowTextKey: String, CaseIterable, Sendable {
    case workflowActionPromptPlaceholder
    case workflowAddEntry
    case workflowAddStep
    case workflowAnyCollection
    case workflowApplyVocabularyHint
    case workflowApplyVocabularyLabel
    case workflowBindingConditionLabel
    case workflowBuiltinOverrideHint
    case workflowBundleIDAnyPlaceholder
    case workflowConditionNodeTitle
    case workflowCreateItem
    case workflowDefaultRouting
    case workflowDefaultTTSModel
    case workflowDeleteCollectionDetail
    case workflowDeleteCollectionTitle
    case workflowEditItem
    case workflowEditTOML
    case workflowEditorSubtitleBuiltin
    case workflowEditorSubtitleEditing
    case workflowEditorSubtitleNew
    case workflowEventNodeTitle
    case workflowExcludePolishItems
    case workflowHotwordSkippedHint
    case workflowHotwordSupportedHint
    case workflowLLMInstructionRequired
    case workflowLLMPromptPlaceholder
    case workflowLanguageAnyPlaceholder
    case workflowLivePreviewToggle
    case workflowModeOutputNodeTitle
    case workflowNewCollectionPlaceholder
    case workflowNoAdditionalConditions
    case workflowNoVocabularyCollections
    case workflowNotEditableError
    case workflowOnDeviceBadge
    case workflowOpenAIModelHintFormat
    case workflowOpenFolder
    case workflowOrderedActionsHint
    case workflowOutputPhaseSubtitle
    case workflowPhrasePlaceholder
    case workflowPreviewCursor
    case workflowPreviewLocationLabel
    case workflowPreviewOverlay
    case workflowProcessPhaseSubtitle
    case workflowPromptLabel
    case workflowReadAloudToggle
    case workflowRecognizeSpeechHint
    case workflowRecognizeSpeechLabel
    case workflowRecordCollectionPickerLabel
    case workflowRecordEventUnavailable
    case workflowReload
    case workflowRemoveItem
    case workflowReplacementKindOption
    case workflowReplacementPlaceholder
    case workflowRestoreDefaults
    case workflowSetupPhaseSubtitle
    case workflowSpeakPrimaryHint
    case workflowSpeakResultLabel
    case workflowSpeechRecognitionHint
    case workflowSpeechRecognitionLabel
    case workflowStepLLMAnswer
    case workflowStepLLMRewrite
    case workflowStepNormalizeWhitespace
    case workflowStepSnippetReplacement
    case workflowStreamingStyleLabel
    case workflowTOMLSourceOfTruthHint
    case workflowTriggerHotkey
    case workflowTriggerManual
    case workflowTriggerMenuBar
    case workflowTriggerTypeLabel
    case workflowTriggerWakeWord
    case workflowTTSModelLabel
    case workflowTTSSavedHint
    case workflowUnsupportedStepFormat
    case workflowVocabularyCollectionsLabel
    case workflowVocabularyLibraryHint
    case workflowVocabularySummaryFormat
    case workflowVoiceLabel
    case workflowWakePhraseInvalid
    case workflowWakePhrasesHint
    case workflowWakePhrasesLabel
    case workflowWakePhrasesPlaceholder
}

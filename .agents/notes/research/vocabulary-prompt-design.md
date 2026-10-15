# 词汇管理与 Prompt 变量架构

> 来源：`docs/competitive-research.md` 的 P0 建议。
> 目标：用小而清晰的 core model 提升语音输入成功率，不把通用规则模型绑死在某个 ASR 或 LLM provider 上。本文同时记录当前实现与尚未进入生产链路的设计。

## 1. 设计目标

竞品共同经验是：语音输入产品必须能记住用户自己的词汇、项目名、人名和固定替换习惯；Prompt 也必须能显式引用当前上下文，而不是依赖隐式魔法。

Rill 当前已有合适的接入点：

- `RecognitionResult.rawText / bestText / metadata`
- `ContextSnapshot.focus.selectedText`
- `ContextSnapshot.clipboard.plainText`
- `WorkflowDefinition.pipeline.postProcessSteps`
- `PostProcessStep.prompt`
- `TransformContext`

因此建议把能力拆成两个独立机制：

1. **VocabularyRule**：规则化词汇/映射词系统，先在本地纯函数运行。
2. **PromptVariableContext**：把 workflow prompt 中的变量解析成显式上下文。

## 2. VocabularyRule

### 2.1 概念分层

| 层级 | 作用 | provider 依赖 | 当前状态 |
|---|---|---:|---|
| 映射词 mapping | ASR 后处理，把识别结果中的错词/口令替换成目标文本 | 否 | 已接入生产运行时 |
| 热词 hotword | 传给支持的 ASR provider，提高识别概率 | 是 | 已接入本地 Qwen 最终转写路径 |
| 禁用词/敏感词 guard | 阻止某些文本进入历史或云端处理 | 否 | 可后续并入隐私任务 |

**mapping** 仍是默认优先机制，因为它可测试、可解释、能立即改善 Type4Me/Wispr Flow 类场景：

- `Web coding` → `Vibe Coding`
- `我的邮箱地址` → `name@example.com`
- `派命令` → `/pi`
- 项目名、人名、产品名纠错

### 2.2 建议 core model

```swift
public enum VocabularyRuleKind: String, Codable, Sendable, Equatable {
    case mapping
    case hotword
}

public enum VocabularyMatchMode: String, Codable, Sendable, Equatable {
    case exactPhrase
    case wordBoundary
    case regex
}

public struct VocabularyRuleScope: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    public var clipboardGroupID: UUID?
    public var locale: String?
}

public struct VocabularyRule: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: VocabularyRuleKind
    public var enabled: Bool
    public var pattern: String
    public var replacement: String
    public var matchMode: VocabularyMatchMode
    public var caseSensitive: Bool
    public var scope: VocabularyRuleScope
    public var priority: Int
}
```

### 2.3 应用顺序

建议把 mapping 放在 `RecognitionResult.bestText` 生成后、LLM rewrite 前：

```text
ASR result -> vocabulary mapping -> normalizeWhitespace -> llmRewrite -> outputActions
```

这样做的好处：

- LLM 看到的是更正确的专业词汇。
- mapping 仍可独立测试，不依赖 LLM。
- 用户可从诊断中看到「哪条规则改了什么」。

### 2.4 规则选择

规则命中应遵循稳定顺序：

1. `enabled == true`
2. scope 匹配当前 `ContextSnapshot`：
   - `bundleIdentifier == nil || bundleIdentifier == focus.bundleIdentifier`
   - `clipboardGroupID == nil || clipboardGroupID == current route/group`
   - `locale == nil || locale == workflow/recognizer locale`
3. `priority` 从高到低。
4. 创建时间或 UUID 作为最终稳定 tie-breaker。

### 2.5 诊断与可观察性

每次替换建议生成轻量诊断 metadata：

```text
vocabulary.rulesApplied = <count>
vocabulary.ruleIDs = <comma-separated uuids>
vocabulary.changed = true|false
```

若 regex 无效或规则过宽，不应静默失败；保存 `DiagnosticEvent(subsystem: .providers 或 .session, level: .warning)`。

### 2.6 架构方案比较

| 方案 | 优点 | 主要问题 | 结论 |
|---|---|---|---|
| 只在 `SessionCoordinator` 识别前解析热词 | 改动最少，靠近录后 recognizer | 实时 WebSocket 在协调器识别阶段之前已经建立；实时和录后路径可能拿到不同规则 | 不采用 |
| provider 直接读取设置与词汇库 | provider 可自行处理限制 | 反向依赖 UI/持久化；每个 provider 重复 scope 与隐私逻辑；难以证明确认前没有读取 | 不采用 |
| 把热词写入 workflow metadata | 复用现有持久化字段 | 会把动态、可能敏感的会话上下文固化到工作流；类型与容量约束不明确 | 不采用 |
| 隐私授权后生成 typed options snapshot | 单一 scope resolver；实时/录后一致；provider 只做能力收窄；易于测试 | 需要贯穿 capture、queue 和 coordinator 的显式参数 | **采用** |

选择依据不是代码行数，而是三条不可妥协的产品性质：确认前不读取云端请求上下文、同一次录音的所有识别路径一致、provider 不知道设置存储。

### 2.7 Hotword 请求合同

Hotword 不复用 workflow metadata，也不让 provider 读取设置。当前链路使用 typed snapshot：

```text
VocabularyRuleSource
  -> privacy authorization
  -> VocabularyRecognitionHintResolver(App / group / language)
  -> SpeechRecognitionRequestOptions
  -> AudioCaptureRequest
  -> live recognition + captured-audio queue
  -> RecognitionRequest
```

关键约束：

- `SpeechRecognizerCapabilities` 显式声明是否支持 `.keyterm`；不支持的 recognizer 在协调层收到空 hints。
- 规则只在隐私授权后读取；用户拒绝云端处理时不会解析或发送热词。
- 录音开始时冻结语言和 hints，同一会话的实时识别、队列和录后 fallback 使用同一份快照，设置中途变化只影响下一次会话。
- 只选择启用且 scope 匹配的 hotword，按优先级、创建时间、UUID 稳定排序，精确去重；空值、换行和控制字符被拒绝。
- 通用 resolver 最多输出 50 个候选；本地 Qwen adapter 会进一步执行自己的数量、长度与字符预算。
- 本地 Qwen 会复用同一份作用域快照，但进一步清洗为最多 16 个、合计最多 48 UTF-8 字节且不含逗号或控制字符的热词。sherpa-onnx Qwen 以逐请求 hotwords 传入，MLX Qwen 以有界 context 传入；两者都只是概率提示，不保证命中。
- 诊断仅记录 source、outcome、采用数、省略数和拒绝数，不记录规则文本、请求 URL、转写原文或 provider 响应正文。
- `SpeechRecognitionRequestOptions` 故意不实现 `Codable`，避免把会话级热词意外写入历史或设置。

## 3. PromptVariableContext

### 3.1 支持变量

第一阶段建议只支持最小但高价值的变量：

| 变量 | 来源 | 缺失时 |
|---|---|---|
| `{text}` | 当前 post-process 输入文本 | 空字符串不应发生；发生则 warning |
| `{rawText}` | `RecognitionResult.rawText` | fallback 到 `{text}` |
| `{selected}` | `ContextSnapshot.focus.selectedText` | 空字符串，并记录 unavailable reason |
| `{clipboard}` | `ContextSnapshot.clipboard.plainText` | 空字符串 |
| `{app}` | `focus.applicationName` | 空字符串 |
| `{bundleID}` | `focus.bundleIdentifier` | 空字符串 |
| `{group}` | 当前剪贴板 route/group 名称或 ID | 空字符串，直到 route context 可用 |

暂不支持任意表达式、循环、条件模板；避免把 prompt 变量做成小语言。

### 3.2 建议 core model

```swift
public enum PromptVariableKey: String, Codable, CaseIterable, Sendable, Equatable {
    case text
    case rawText
    case selected
    case clipboard
    case app
    case bundleID
    case group
}

public struct PromptVariableContext: Codable, Sendable, Equatable {
    public var text: String
    public var rawText: String
    public var selectedText: String
    public var clipboardText: String
    public var applicationName: String
    public var bundleIdentifier: String
    public var groupIdentifier: String
}

public struct PromptRenderResult: Codable, Sendable, Equatable {
    public var renderedPrompt: String
    public var usedVariables: [PromptVariableKey]
    public var missingVariables: [PromptVariableKey]
}
```

### 3.3 解析规则

- 只识别 `{identifier}`，未知变量保留原样并产生 warning。
- 支持转义：`{{text}}` 输出字面量 `{text}`。
- 不做 shell/env interpolation，避免安全歧义。
- Prompt 渲染发生在 transformer 内部调用 LLM 前，不改变 workflow manifest 中的原始 prompt。

### 3.4 与 `PostProcessStep.prompt` 的关系

当前 `PostProcessStep.prompt` 是 `String?`，可以不改 schema，先增加一个渲染 helper：

```text
PostProcessStep.prompt
  -> PromptVariableRenderer.render(prompt, context)
  -> renderedPrompt passed to LLM transformer
```

这样旧 workflow 不需要迁移；新 UI 只是在编辑器中展示可插入变量。

## 4. 当前实现与下一接线点

已完成：

1. `VocabularyModels`、`VocabularyRuleApplicator`、`PromptVariableModels` 和 `PromptVariableRenderer` 的纯模型与测试。
2. mapping 在 `SessionCoordinator` 的识别后、post-process 前运行，支持 App、目标剪贴板组和语言作用域。
3. Settings 中的词汇规则管理，以及 mapping / hotword 不同语义的界面表达。
4. typed recognition options、provider capability、捕获时快照，以及 sherpa-onnx Qwen hotwords 和 MLX Qwen context adapter；同一运行的实时与录后请求共用冻结后的 options 快照。
5. 对规则加载失败、provider 不支持、模型不支持、容量省略和非法 keyterm 的无内容诊断。
6. 一步纠错闭环已进入真实历史路径：用户编辑原识别结果后可从保守 planner 生成的 mapping / hotword 建议中显式选择；缺失作用域必须逐项人工确认，冲突规则不会覆盖已有配置。

尚未完成：

1. `PromptVariableRenderer` 尚未接入真实生产 transformer；当前没有可用的 LLM transformer，因此 UI 不应宣传语音命令已可用。
2. 本地 Qwen 热词与纠错建议的真实效果仍需在授权设备上用真人语料 dogfood；现有自动化验收覆盖请求规划、隐私顺序、快照传递、建议约束和敏感内容不落盘，不等于准确率或日常纠错成本验证。

## 5. 暂不做

- 不做跨设备词典同步。
- 不做条件模板语言。
- 不让 LLM 自动学习并写入词典；最多后续做「建议规则」，需要用户确认。
- 不把 Whisper prompt、LLM vocabulary、确定性 mapping 和 ASR keyterm 合并成一个含糊的“词典”开关。
- 不为不支持 keyterm 的 provider 静默映射为其他机制；新增能力必须扩展显式 capability 与 provider planner。

## 6. 对现有架构的影响

这套设计保持当前 provider seam：

- ASR provider 仍只负责 `RecognitionRequest -> RecognitionResult`，并从 request options 读取已授权的会话快照。
- 词汇 mapping 是 provider-independent post-process。
- 热词不进入 workflow metadata；Core 定义通用 hints 与 capability，具体 provider 只负责将其收窄为受支持的请求参数。
- Prompt 变量只影响 transformer prompt，不污染 core workflow 定义。

下一步不是扩展第二个热词 adapter，而是先完成真实 Qwen3-ASR dogfood 和首次启动 readiness；只有数据证明专业词仍是主要编辑成本时，再实现“用户修正 → 建议规则 → 人工确认作用域”的闭环。

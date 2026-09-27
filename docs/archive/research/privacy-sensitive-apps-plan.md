# 隐私与敏感 App 排除计划

> 历史材料，保留原始研究、计划或验收范围；不代表当前功能或发布结论。
> 归档基线：main `9e786a6`。当前使用说明见 [用户指南](../../usage.md)。

> 来源：同类工具研究中 Raycast Clipboard、Superwhisper、open-wispr、Wispr Flow 等产品的隐私/上下文经验。
> 目标：让用户清楚知道 Rill 何时捕获剪贴板、何时保存历史、何时调用云端 provider，并能安全排除敏感 App。

> 实施状态（2026-07-31）：核心运行时闸门、无确认副作用的动态隐私解释、系统保护 pasteboard 检测、Secure Input、可选云端文本确认、sherpa-onnx 固定归档准备与离线识别披露、历史与活动流三态预览、Keychain 凭据与 Webhook 配置迁移、自定义敏感 App 管理、暂停捕获、忽略下一次复制、隐私设置原子快照、本地历史/诊断留存、本地静态加密、可选失败录音恢复、临时音频安全清理，以及来源 App 感知的剪贴板 Replay/Replace 授权均已完成。云端 ASR 已移除。

## 1. 当前基础

代码中已有可复用能力：

- `FocusTracker.captureCurrent()` 能获得前台应用名、bundle id、选中文本和 focused role。
- `ClipboardSnapshot` 保存 plain text、图片、文件、changeCount 和 `captureTags`。
- `ClipboardCaptureTag` 已有 `excludeFromWorkflowCapture` 与 `polishGenerated`。
- `PasteboardController` 能写入自定义 pasteboard metadata，用于识别 Rill 自己写入的剪贴板内容。
- `SettingsView` 已有权限与本地语音引擎、模型设置入口；不再提供云端语音设置。
- `ClipboardHistoryItem` 已保存 source app、bundle id、content kind 和 tags。

当前已落地：

1. 推荐敏感 App 规则与自定义规则管理，支持 bundle ID 校验、可选名称、增改删、启用/禁用、大小写去重和推荐默认值恢复；策略覆盖剪贴板历史、工作流捕获、selected text 和云端处理。
2. `FocusSnapshot.secureInput` 使用系统 Secure Event Input 状态，并在读取 selected text 前执行保守判定。
3. 剪贴板先读 descriptor/保护标签，再做 policy，授权后才读取文本、图片或文件；策略读取失败时阻断捕获。
4. 本地语音路径披露，以及可选云端文本工作流的运行前确认。旧 Webhook 端点与请求头会先写入 Keychain 并精确回读，再以引用原子替换 SQLite 明文并清理 DB/WAL 残留；迁移失败时只隔离自定义工作流。Webhook 在发布版本仍隐藏且不注册。
5. 历史 full/restricted/disabled 预览已进入 UI；该设置只控制显示，不宣称删除本地记录。
6. 隐私设置通过单次 SQLite 事务提交完整快照，AppModel 严格串行保存；UI 与运行时闸门读取同一进程内策略源，因此有效修改会立即生效。隐私数据损坏不会阻断语言、工作流、provider 或凭据等其他设置加载；隐私运行时单独 fail-closed。保存失败时本次会话继续使用新策略，并在设置页持续提示“重启后丢失”与重试入口。
7. 菜单栏支持暂停剪贴板捕获与忽略下一次外部复制，恢复时不回填暂停期间内容。
8. 剪贴板历史与运行历史默认各保留 30 天，可独立调整或清理；诊断跟随运行历史策略。活动 Stack / Queue / List 项受保护；运行历史、收据与诊断的清除意图持久化同一 CAS generation transition，旧 generation 晚写固定拒绝且不会再被公共读路径展示，新 generation 不受系统时钟回拨影响。删除意图可在跨表部分完成或崩溃后重放，逻辑删除后会清理 SQLite/WAL 残留。失败录音恢复默认关闭，此时 Rill 管理的临时音频在成功、失败和取消后清理。显式开启后，仅合格的投递前失败录音会加密短期保留；手动重试在解密前 claim 当前 provider/隐私授权，解密后、provider 前 final revalidate，启动不会自动识别或联网。最终拒绝会删除明文并恢复 retry attempt；关闭设置、清除失败录音或清除运行历史都会移除对应恢复数据。重试明文正常路径立即删除，崩溃遗留在启动时立即回收；若明文清理暂时失败，运行时会退避重试，并在确认清理完成前阻止新的恢复请求。
9. UI 中复制诊断、失败原因或历史文本时统一通过共享 pasteboard 控制器登记应用自有 changeCount；剪贴板监听器不会把这类应用内复制再次写入历史。
10. 运行前解释与真实授权共用 closed destination classifier 和同一 `PrivacyPolicy.evaluate` 语义。解释只返回 fixed-enum `PrivacyRunEvaluation`，不会弹出云端确认或携带 context/metadata；未知目的地与设置读取失败均 fail-closed。真实授权在确认或返回前二次读取设置，并在完整 context 捕获后第三次重算 decision，避免确认或采集期间策略变严格后继续使用旧授权。生产运行只接受 Runtime 创建、绑定 exact workflow 的 opaque authorized-context capability；UI 无法读取或伪造其中正文。
11. 延迟音频使用不可读、一次性的 run/workflow-bound lease：解析前 claim，解析后、recognizer 前 final revalidate。语音只交给本地 recognizer；输入停止后的所有权转移继续保证取消、失败和退出能够清理托管临时音频。
12. 剪贴板临时替换在 MainActor 上同步完成 descriptor/保护标记、保留 payload、最终 change count 和写入；其他进程仍可在 macOS 系统边界竞态，因为 `NSPasteboard` 不提供跨进程 CAS。浮动面板在隐藏前锁定 PID/bundle，恢复后若当前焦点不再匹配，text/rich 均不会投递或标记已用。
13. 剪贴板 Replay/Replace 授权由 `DeliveryStack` 原子解析 exact item subject 与来源 App identity；来源侧 workflow/cloud 限制会在目标授权前后复核，不能通过切换当前前台 App 绕过。组事件的 non-interactive preflight 使用同一来源语义，但绝不弹出确认，也不发执行 capability；需要确认、来源未知、目的地未知或设置不可用时均 fail-closed。

仍需补齐：

1. 可选的“将当前前台 App 加入规则”快捷入口。

## 2. 用户可理解的隐私模式

建议设置页新增「隐私与安全」section，用用户语言表达三类开关：

| 设置 | 默认 | 作用 |
|---|---:|---|
| 敏感 App 排除 | 开 | 在密码管理器、银行、2FA、系统钥匙串等 App 中不捕获剪贴板/选中文本，不触发工作流 |
| 云端文本处理确认 | 开 | 使用可选云端 LLM 前显示本次文本会离开本机；麦克风音频不发送给云端 ASR |
| 历史、Dashboard 与活动流预览 | 受限 | 正文进入视觉与 AX 前截断为最多 96 个字符；全文预览需用户显式开启，禁用时视觉与 AX 均不接收正文 |
| Secure input 保守模式 | 开 | 无法判断输入区域是否安全时，不读取 selected text，不自动粘贴敏感内容 |

## 3. 建议 core model

```swift
public enum PrivacyDecision: String, Codable, Sendable, Equatable {
    case allow
    case redactContext
    case skipClipboardCapture
    case skipWorkflowCapture
    case requireCloudConfirmation
    case blockCloudProcessing
}

public enum PrivacyReason: String, Codable, Sendable, Equatable {
    case sensitiveApplication
    case secureInput
    case userDisabledClipboardHistory
    case cloudProviderSelected
    case itemTaggedExcludeFromWorkflowCapture
    case unknownFocusContext
}

public struct SensitiveAppRule: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var bundleIdentifier: String
    public var applicationName: String
    public var blocksClipboardHistory: Bool
    public var blocksWorkflowCapture: Bool
    public var blocksSelectedText: Bool
    public var blocksCloudProcessing: Bool
    public var enabled: Bool
}

public struct PrivacyPolicyDecision: Codable, Sendable, Equatable {
    public var decisions: [PrivacyDecision]
    public var reasons: [PrivacyReason]
    public var redactedContext: ContextSnapshot?
    public var metadata: [String: String]
}
```

第一阶段也可以更小：先只加 `SensitiveAppRule` 和一个纯函数：

```swift
PrivacyPolicy.evaluate(context:clipboard:settings:) -> PrivacyPolicyDecision
```

## 4. 默认敏感 App 建议

初始内置规则不应过宽，但应覆盖高风险类别：

- Password managers: 1Password, Bitwarden, iCloud Keychain/Passwords, KeePassXC
- Browsers 的密码/支付页面无法稳定识别时，不默认排除整个浏览器；改用用户自定义规则和 secure input 检测。
- 2FA / authenticator apps
- Banking/finance apps（用户自行添加为主）
- Terminal/IDE 不应默认排除；开发者经常需要语音输入和剪贴板路由。

建议内置规则是「推荐列表 + 可禁用」，不是不可见黑名单。

## 5. 云端 provider 路径提示

在 Settings 的 speech engine section 中，建议明确展示当前路径：

- local speech：16 GB 默认 Qwen3-ASR 0.6B INT8 使用 sherpa-onnx；Apple Silicon 可选 Qwen3-ASR 1.7B 8bit 使用原生 mlx-audio-swift / MLX/Metal GPU。前者从受限 GitHub release-asset host 下载并校验精确 archive，后者由受监管的 Swift 辅助进程从精确 Hugging Face commit 准备，不需要 Python 或 `uv`。模型准备不发送麦克风音频或识别文本，完成后的转写离线运行。SenseVoiceSmall 只保留固定的内部兼容/未来评估身份，在产品与法律审核完成前不进入公开设置、下载或推荐路径。
- local speech：音频只交给本机已选的 sherpa-onnx 或 MLX recognizer；作用域热词只在本机处理。
- 未来云端 LLM：文本、选中文本、剪贴板上下文是否发送，取决于 prompt 变量和工作流配置。

UI 文案建议：

```text
当前路径：云端识别
录音音频与匹配当前作用域的热词只交给本机语音引擎；识别结果会按你设置的留存期限保存在本机。可选文本润色可能在单独确认后发送最终转写正文，但不会发送音频。敏感排除规则命中时不会捕获对应剪贴板或选中文本。
```

工作流编辑器也应在使用 `{selected}` / `{clipboard}` 且 action/provider 是云端时显示警告。

## 6. 剪贴板捕获规则

建议按以下顺序做隐私判断：

```text
pasteboard change
  -> is Rill-owned change? skip or tag
  -> captureTags contains excludeFromWorkflowCapture? skip workflow capture
  -> focus app matches SensitiveAppRule? skip/redact
  -> content kind allowed? text/image/files
  -> save history / trigger group event
```

`excludeFromWorkflowCapture` 不仅阻止工作流捕获，也必须在工作流 context 中固定清空
clipboard payload；否则后续 prompt 或 context recognizer 仍可能读取被标签排除的内容。无法识别当前
前台 App 或处于 conservative Secure Input 时，策略同时跳过 clipboard history/workflow capture 并清空
selected/clipboard；云端路径额外阻断处理。

对于敏感 App：

- 不保存 plain text preview。
- 不触发 group workflow。
- 可记录一条摘要诊断：`clipboard.capture.skipped`，metadata 包含 bundle id 和 reason，不包含内容。

## 7. 与 Prompt 变量的关系

`docs/vocabulary-prompt-design.md` 中的 prompt 变量必须经过隐私策略过滤：

| 变量 | 敏感 App 中建议 |
|---|---|
| `{text}` | 本次语音识别文本，可用；若云端 LLM 则需要确认 |
| `{selected}` | 默认置空 |
| `{clipboard}` | 默认置空 |
| `{app}` / `{bundleID}` | 可用，但可只给 bundle/app 摘要 |
| `{group}` | 可用 |

渲染结果应返回 missing/redacted variables，供 dry-run 和 diagnostics 展示。

## 8. 与工作流可观测性的关系

`docs/workflow-observability-plan.md` 中的 `WorkflowRunRecord` 应记录隐私决策摘要：

```text
privacy.decisions=redactContext,requireCloudConfirmation
privacy.reasons=sensitiveApplication,cloudProviderSelected
privacy.redactedVariables=selected,clipboard
```

不要把被 redacted 的原文写进 metadata。

## 9. 最小实现顺序

1. 增加 settings key：
   - `privacy.sensitive-app-rules`
   - `privacy.cloud-confirmation-required`
   - `privacy.history-preview-mode`
2. 增加 `SensitiveAppRule` 和 `PrivacyPolicyDecision` core model。
3. 在 context capture 或 prompt rendering 前应用 policy，先 redacts selected/clipboard。
4. 在 clipboard capture path 中对敏感 App 跳过 history/workflow capture。
5. Settings UI 增加「隐私与安全」section：
   - 当前前台 App 一键加入排除列表。
   - 展示默认推荐规则。
   - 展示本地/云端路径说明。
6. Diagnostics 记录 skipped/redacted 原因。

## 10. 测试建议

- 敏感 bundle id 命中时，clipboard history 不保存文本。
- 敏感 bundle id 命中时，prompt `{selected}` / `{clipboard}` 被置空。
- `excludeFromWorkflowCapture` tag 会跳过 workflow capture，但不误删普通历史策略。
- 本地语音识别不返回 `requireCloudConfirmation`；只有实际声明云端文本目的地的工作流才需要相应确认。
- 诊断 metadata 不包含敏感文本。
- 非敏感 Terminal/IDE 默认不被排除。

## 11. 非目标

- 不做浏览器页面级密码字段识别作为第一阶段承诺。
- 不做跨设备隐私同步。
- 不默认拦截所有浏览器或所有开发工具。
- 不把隐私策略隐藏在 provider 内部；它应是 runtime/UI 都能解释的独立决策。

## 12. 推荐实现切片

最小有价值切片：

1. `SensitiveAppRule` + settings persistence。
2. Prompt variable rendering 前 redacts `{selected}` / `{clipboard}`。
3. Clipboard capture 对敏感 App 记录 `clipboard.capture.skipped`。
4. Settings UI 显示「当前路径：本地/云端」。

这能直接回应竞品中的隐私叙事，同时保护 Rill 独有的剪贴板和工作流能力不变成用户不敢开启的黑盒。

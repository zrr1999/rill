# Rill

User workflows are standard TOML files under
`$XDG_CONFIG_HOME/rill/workflows` (defaulting to
`$HOME/.config/rill/workflows`). The separate Workflow window is a visual
editor for those files; see [the workflow TOML specification](docs/workflow-toml.md).

**本地优先的语音输入 + 剪贴板路由工作站** — 一款原生 macOS 应用，将语音识别、应用级剪贴板分组和可观察语音工作流合为一体。

> 🎙 按住 Fn 说话，松开即输入 · 📋 剪贴板分组路由 · ⚡ 可观察语音工作流 · 🔄 语音状态浮窗

---

## ✨ 核心特性

### 🎤 语音转文字

- **统一本地语音边界** — 稳定的 `local-speech` recognizer 由独立 worker 中的原生 [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) 实现；默认启用并常驻 Qwen3-ASR 0.6B 8bit，也可在模型池加入 1.7B 8bit。Qwen v5 流式结果只用于预览，封口 WAV 的离线结果始终是正式文本
- **按住说话（Push-to-Talk）** — 按住 `Fn` 开始录音，松开自动识别并输入
- **本地语音端点** — 主窗口和菜单栏触发的单次听写使用固定 revision/hash 的 MLX Silero VAD v6 判断语音起止；`Fn` 按住说话仍由松键结束，切换式录音由第二次按键结束
- **按需采集前端** — 唤醒词使用可与其他 App 共存的 input-only 原始前端；只有实际识别运行才切换到 Apple Voice Processing 和自动增益，并在结束后完整释放 VPIO。模型预加载不会预配置或占用麦克风
- **稳定尺寸的语音状态浮窗** — 本地路径以固定标准/紧凑尺寸显示录音、音量和处理状态；增长中的实时 hypothesis 只保留最新两行，不会按正文长度不断撑大窗口。停止或自动端点后再由所选档位模型生成最终转写
- **中英文支持** — 界面和识别均支持中文/英文双语切换
- **作用域热词** — Qwen 路径只接收清洗并设有数量/长度上限的热词，通过 Qwen3-ASR 的有界 context 传入
- **OpenAI-compatible 文本工作流（BYOK）** — 内置预设和自定义语音工作流的 `llmRewrite` 步骤使用 MacPaw/OpenAI 0.5.1 的 Responses API，只把当前最终转写正文发送到用户配置的 endpoint；API Key 保存在 macOS Keychain。默认使用官方 OpenAI `/v1` 与 `gpt-5.6-terra`，也可选择 Sol / Luna 或填写自定义 Base URL 和模型 ID；配置缺失、云端拒绝或请求失败时不会注入原文或部分结果
- **延迟音频双阶段授权** — 录音与 exact workflow/run 绑定一次性 lease；队列在解析音频前 claim，解析后、识别前再次检查设置与目的地。等待期间收紧策略会阻止后续识别或投递
- **明确且可停止的实时状态** — 活动录音按钮会真正停止对应 run，而不是只隐藏窗口。停止输入后，控制器与后台队列通过原子所有权转移避免重复处理或遗留音频；App 退出会等待录音、手动工作流、音频队列与剪贴板监听清理。清理超时会取消本次退出而不取消清理；事件排空和持久化先于可能较慢的模型卸载
- **有界本地录音** — 同一份 16 kHz 单声道 PCM 同时送往 v5 流式预览和权限为 `0600` 的受管 WAV；实时层只保留有界 PCM/音量状态。流式失败只关闭预览，正常停止会排空尾帧并继续离线 final，异常、取消或超时会先关闭文件再清理
- **失败录音恢复（可选）** — 默认关闭；符合条件的投递前失败录音可加密保留最多 24 小时，并从历史页手动重试或删除。重试在解密前和解密后、provider 调用前都重新检查当前隐私与配置，只生成新的运行历史，不重复输出动作。App 退出会拒绝新重试、取消并等待所有活动重试恢复 durable receipt，并执行最终全局恢复明文 sweep；无法证明全部托管明文已清理时会阻止本次退出，让清理继续完成

### 📋 剪贴板管理系统

- **默认不监听** — 新安装默认关闭系统剪贴板捕获和浮动面板全局快捷键；只有用户在设置或菜单栏明确开启后才建立新的捕获基线，关闭期间的变化不会在重新开启时补录
- **分组路由** — 为不同应用分配独立的剪贴板组（Stack / Queue / List 三种模式）
- **置顶与快速检索** — 正文、来源 App、标签和分组支持多关键词联合搜索；合并条目可原子置顶并一键只看置顶内容。置顶只影响历史展示、自动留存和容量逐出，不会伪装成 Stack / Queue / List 活动项；显式删除或“清除历史”仍按用户命令执行
- **语音识别组** — 可将语音识别结果保存到专属组，每个条目可打标签
- **跨组回退** — 当当前组为空时自动从优先级更高的组获取内容
- **智能粘贴** — `Cmd-V` 自动感知当前应用所属组，递送对应内容
- **历史记录** — 捕获允许保存的文本、图片和文件；跳过系统保护内容与敏感 App，支持回放、搜索和独立留存策略。运行历史以 receipt 为主时间线，用同一 SQLite 快照和稳定 keyset 分页浏览全部留存记录；Dashboard 仍只保留轻量最近投影。文件条目通过历史或浮动面板手动回放，不进入 Stack / Queue 自动消费
- **有界且原子的本地存储** — schema 8 将受保护 metadata 与 immutable image blobs 分离，并最多保留 1000 个活动项、每组 500 个活动项和 500 个仅历史项；单项文本上限 1 MiB、图片上限 32 MiB，全部条目的内容总量上限 64 MiB；自定义组最多 256 个、App 路由最多 1024 条，名称、Bundle ID、capture tag 和来源元数据也在编码前校验。超限时只逐出最旧的仅历史项；活动项或已取得粘贴租约的条目不会被静默丢弃，App 分配与新建组在完整校验后原子提交，失败不会产生半移动、幽灵组或把已消费条目重新激活
- **竞态安全的捕获与镜像** — Secure Input 与未知焦点会遮蔽选区和剪贴板输入，排除工作流捕获的标签只遮蔽工作流可见的剪贴板；Stack 路由预览与外部剪贴板捕获会在载荷读取和条件镜像写入前后复核焦点、Secure Input、设置与 change count，边界变化时 fail-closed 且不覆盖外部新剪贴板
- **有界富内容投递** — 临时替换系统剪贴板前，Rill 最多保存 128 个 item、每项 32 个 representation、总计 256 个 representation / 64 MiB；任一表示不可读或超限都会在替换前失败。图片的 ImageIO 解码、完整性检查和 TIFF → PNG 转换在主线程外 single-flight 串行执行，并在提交前复核 change count。精确写回失败会保留原 archive，只重试恢复而不重复粘贴；退出会排空内外两层临时事务，无法证明恢复完成时拒绝本次正常退出
- **安全清理** — 剪贴板、运行历史及相关诊断默认保留 30 天，可按域设为 1 天 / 1 周 / 30 天 / 1 年 / 永久；自动清理不会误删已置顶或仍在 Stack / Queue / List 中待使用的内容，Rill 遗留临时音频也会在启动和周期维护时回收
- **可恢复的状态持久化** — 分组、路由规则和历史记录跨重启保持；schema 7 图片会原子迁移到 schema 8 metadata/blob graph。不可读、损坏或超出 schema 8 边界的状态进入 `loadUnavailable`，保留原始存储且不以空状态覆盖。主窗口 Clipboard 提供明确、不可撤销的 Reset Storage 确认，用于同时删除受保护旧状态和本次会话的条目、分组与 App 路由；取消或删除失败不会产生半重置
- **本地静态数据保护** — 运行正文、纠错来源、剪贴板状态、设置和导出元数据使用 Keychain 根密钥与 AES-256-GCM 保护；错误或缺失密钥会 fail-closed

### ⚡ 可观察工作流

- **可视化编辑器** — 配置触发方式、识别路径、确定性文本处理和输出位置
- **真实能力优先** — 任何包含 `llmRewrite` 的内置或自定义语音工作流只在 OpenAI 凭据可读取时可启用；Snippet 与组事件动作仍不会出现在生产入口中
- **多种触发方式** — 快捷键、菜单栏和手动触发
- **失败可见** — 缺失 recognizer、transformer 或 action 时明确失败，不静默跳过
- **内容无关的运行前解释** — Workflows 页可预览已保存且没有未保存改动的工作流，查看当前触发、输入类别、处理步骤、输出效果、数据目的地和固定隐私原因；收据不包含正文、prompt、路径、端点或凭据
- **预览与授权分离** — 预览只读取不含正文的隐私快照，不显示云端确认，也不是执行凭证；真实运行会用同一目的地分类器重新检查焦点、剪贴板与隐私设置。语音、非音频工作流和剪贴板重放均须先取得与具体工作流绑定的运行时授权；重放/替换还会同时评估 exact 条目来源 App 与当前动作目标，来源侧的云端禁用规则不会因切换前台 App 而失效
- **Prompt 变量安全基础** — `{text}`、`{selected}`、`{clipboard}` 等 Core 模型使用单遍、有硬上限、非递归的渲染器；运行正文和上下文不可序列化，只有满足 canonical 子集/顺序约束的 content-free summary 可进入收据或诊断。OpenAI transformer 可服务内置与自定义语音工作流，但只能取得当前转写正文，选区、剪贴板、App 名和 bundle ID 不进入请求
- **Durable 运行收据** — Runtime 直接记录真实触发、分桶耗时、动作固定结果和完成/部分完成/失败/取消/跳过终态；输出动作取消会写入固定 `cancelled` 结果，首个动作取消与已有副作用后的取消分别成为 cancelled 与 partially-completed，不会伪装成失败。加密落库后只发送仓库失效通知，历史时间线必须回读 durable truth。剪贴板/堆栈运行不会二次保存或展示正文，收据本身不含正文、名称、错误字符串、精确长度或正文指纹
- **剪贴板零副作用预演** — 当前/历史条目可从详情或右键菜单打开 `Paste / Replay / Replace` 影响预演，查看固定的读取类别、处理步骤、潜在副作用、目的地、替换计划与隐私条件；界面只有刷新和关闭，不提供运行入口。Runtime 以 per-item generation + revision 原子解析精确条目，replay/replace 与真实授权共用 invocation-aware 目的地分类；同类型正文漂移、分组/标签变化和删除后同 ID 重建都会使旧结果失效

### 🖥 桌面体验

- **原生 macOS 应用** — SwiftUI + AppKit，系统级集成
- **菜单栏常驻** — 状态指示 + 快捷操作，不占 Dock 空间
- **浮动剪贴板面板** — 独立窗口，可边工作边管理剪贴板
- **全局搜索** — `Cmd-F` 或工具栏按钮打开 MainShell 自己持有的搜索浮层；AppKit `NSSearchField` bridge 在 macOS 14 上确定性处理首次与重复 `Cmd-F` 聚焦、方向键选择、`Return` 打开和 `Esc` 关闭/恢复侧栏。页面、工作流和设置结果即时可用；运行历史在 250 ms 防抖后按同一快照以每批最多 50 条扫描全部留存记录，支持取消且最多返回 20 项。历史正文只按当前 `full / restricted / disabled` 预览策略进入索引：受限模式最多使用同一份 96 字符预览，禁用时不读取或索引正文；历史仓库故障不会让静态导航结果消失
- **精确结果跳转** — Dashboard、Diagnostics 与全局搜索使用 typed 请求进入工作流、历史条目及语言、剪贴板面板、权限、隐私、存储、语音、词汇或输入设置；目标页面拥有滚动和详情焦点，MainShell 不会在跳转后把焦点抢回侧栏
- **准备清单** — Dashboard 按当前默认听写路径展示全局输入、麦克风、辅助功能、模型/provider 与隐私状态；只有共享事件监听真正安装成功才算全局输入就绪，权限只在用户点击时请求
- **可预测的主窗口焦点** — 侧栏统一拥有普通跨页导航焦点；进入剪贴板不会自动聚焦搜索框，鼠标事件完成后会把键盘焦点恢复到新选中的侧栏项。Dashboard → Clipboard 的键盘、List selection、`NSEventTrackingRunLoopMode`、快速连续路由及 typed Settings / History 详情所有权均有 AppKit 托管回归；真实鼠标与完整 VoiceOver 仍按发布 QA 清单验收
- **启动设置不丢修改** — 初始持久化快照返回前，标量设置按 key 保留用户的新选择；工作流、词汇和已下载模型等整表集合暂时禁用 mutation，避免用不完整内存状态覆盖旧库。加载完成后再恢复编辑与模型准备
- **焦点绑定的文字注入** — 直接输入会绑定开始运行时的目标 App；浮动剪贴板面板在隐藏前锁定 PID/bundle，恢复后只有同一目标仍在前台才会投递。粘贴或每个键盘分块前会再复核；目标不可验证或中途变化时停止输入并条件恢复剪贴板，诊断不记录目标标识或正文

---

## 🆚 与同类应用对比

以下是截至 2026-07-18 的 Rill 公开能力快照，不把未核验或路线图能力写成现状。Type4Me 一栏仍以 2026-07-11 固定 commit 的 [README 与 provider registry](https://github.com/joewongjc/type4me/tree/5a899d9cdad89a9ee47c53f01edaa701d385b17b) 为依据。

| 功能 | Rill | Type4Me |
| ------ | --------- | --------- |
| 本地 ASR | 原生 MLX Swift Qwen3-ASR 0.6B 默认 + 1.7B 可选 | SenseVoice + Qwen3-ASR 校准 |
| 云端 ASR | 不提供 | 多家；以当前 provider registry 为准 |
| **剪贴板路由模型** | App / 组路由 + Stack / Queue / List | 本次源码快照未见同类路由模型 |
| **可观察工作流** | 内容无关运行前解释 + 运行时重新授权 | 模式、Prompt 与快捷键配置 |
| **工作流配置** | 三节点可视化配置 | 模式与 Prompt 配置 |
| **语音状态浮窗** | ✅；Qwen v5 confirmed/provisional 流式预览 | ✅ |
| **组标签系统** | ✅ | 本次源码快照未见 |
| 确定性映射词 | ✅ App / 组 / 语言作用域 | ✅ |
| 一步纠错闭环 | ✅ 人工确认建议与作用域 | 热词/片段管理工具 |
| 本地历史留存 | ✅ 剪贴板与运行域独立配置、可清理 | 识别历史 + CSV 导出 |
| ASR 热词 | ✅ Qwen 有界热词，支持 App / 组 / 语言作用域 | ✅ |
| Prompt 变量 | 🧪 有界单遍模型与 content-free summary 已完成，尚未接入生产变换器 | ✅ |
| 本地 LLM | 🔜 Provider / model 待选；Ollama 仅为候选 | ✅ Ollama |

---

## 🚀 快速开始

### 系统要求

- macOS 14.0 (Sonoma) 或更高版本，仅支持 Apple Silicon（arm64）；发布产物必须是单一 arm64 slice
- 原生 MLX 本地 runtime 随 arm64 App 提供；每个候选版本必须在声明支持的 Apple Silicon 硬件上完成录音、模型准备和转写验收
- 可选的 Qwen3-ASR 1.7B 8bit 使用随辅助进程编译的原生 mlx-audio-swift 0.1.3 与 MLX/Metal GPU；用户无需安装 Python 或 `uv`，该路径不使用 ANE/NPU

源码开发还需要：

- Xcode 26 或更高版本，并选择包含 Swift 6.2+ 的 Command Line Tools；本地
  默认开发工具链为 Xcode 27
- 从源码生成发布包还需要与当前 Xcode 兼容的独立 Metal Toolchain；可用 `xcodebuild -downloadComponent MetalToolchain` 安装，并用 `xcrun metal -v` 验证。不要强制 `--toolchain XcodeDefault`，否则 `xcrun` 会排除已下载并挂载的 Metal Toolchain。若组件下载后仍失败，请用 `DEVELOPER_DIR` 临时选择一个验证通过的并存 Xcode，不要修改 Xcode.app 内部文件
- Git、`codesign` 与 macOS 标准发布工具，以及 [uv](https://docs.astral.sh/uv/guides/scripts/)；发布脚本通过 PEP 723 单文件脚本模式运行 Python 3.11 或更高版本

### 从源码验证

仓库当前尚未发布可验证的公开安装包。开发者可以先运行与发布流程相同的预检：

```bash
cd /path/to/rill
tool_dir="$HOME/.local/share/rill/bin"
bash scripts/install_gitleaks.sh --destination "$tool_dir"
export PATH="$tool_dir:$PATH"
gitleaks version
bash scripts/preflight.sh
```

安装脚本只接受 Gitleaks 8.30.1 的受审 macOS 资产，并在安装前校验当前架构对应的固定 SHA-256。`Package.resolved` 固定 mlx-audio-swift 及其完整 SwiftPM 依赖图；预检会把锁定图与第三方许可证清单、离线 advisory baseline 和 CI 的实时 OSV 查询对照。随后它检查发布脚本语法与生成产物、执行 arm64 Release 构建和 App 装配，验证主 App 与语音 worker 都只有 arm64 slice，且 `LC_BUILD_VERSION` 的 macOS `minos` 精确为 14.0。最后运行完整测试并检查补丁空白错误。这个 Mach-O 门禁不能替代在 Sonoma 的 Apple Silicon 真机上运行最终公证包。

本地语音保持稳定的 `local-speech` recognizer 边界。一个 ASR worker 可缓存多个已启用 Qwen 模型，但所有 Qwen decode 经过同一串行通道；独立 TTS worker 可与 ASR、LLM、录音并行。模型和 Silero VAD v6 均固定到精确 Hugging Face revision，并在发布本地目录前校验受审文件的大小与 SHA-256。主 App 不链接 MLX，模型预加载也不会初始化麦克风。

SwiftPM 依赖采用可复现的兼容组合：上层 `mlx-audio-swift` 固定为最新稳定版
0.1.3，底层 `mlx-swift` 暂固定为 0.31.4。0.31.5/0.31.6 给跨平台
`Cmlx` target 无条件附加 `CudaBuild` 插件，会使当前 Xcode package graph 丢失
plugin target GUID；消费方没有关闭传递插件的开关。上游修复发布前，不要只为追逐
底层版本绕过锁文件或修改 checkout。

| model ID | 角色 / 后端 | 固定来源 | 大小 / 固定身份 |
| --- | --- | --- | --- |
| `qwen3-asr-0.6b-mlx-8bit` | 默认最终模型与流式预览；Apple Silicon；MLX/Metal GPU | [`mlx-community/Qwen3-ASR-0.6B-8bit`](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit) | 约 1.01 GB；commit `89e96d92ba34aca20b3e29fb10cc284097d1219f` |
| `qwen3-asr-1.7b-mlx-8bit` | 可选较大最终模型；Apple Silicon；MLX/Metal GPU | [`mlx-community/Qwen3-ASR-1.7B-8bit`](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | 约 2.46 GB；commit `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` |

流式预览准备或推理失败时只退化为录音音量/状态显示，不改变受管 WAV 与离线最终识别。

内置目录只保留两条基础链路：`语音识别` 使用 Fn 触发，按当前语音路由选择最终
STT 模型，在识别阶段提供个人词库热词提示，并在识别后执行确定性替换，再输出文字；
`语音助手` 使用 `Hey Rill` 唤醒，依次执行 STT、词汇处理、OpenAI-compatible
Responses LLM 回答和 automatic/Vivian TTS。语音助手默认停用，用户需要先配置
OpenAI API Key，并在设置中主动启用唤醒监听。设置页会在启用前汇总检查麦克风、
当前本地 ASR、LLM 配置、云端隐私策略与语音输出；已知无效或验证失败的 LLM 配置
不会启动连续监听。两条链路共用现有 recognizer、transformer 和 action 流水线，
但使用独立运行通道；Fn/交互识别在共享麦克风入口拥有高于环境唤醒的优先级，助手的
LLM/TTS 后处理不会占住实时识别通道。ASR 与 TTS 也使用独立 worker supervisor，
捕获层不会直接依赖文字注入或语音播放。

完整模型身份、来源 revision 与哈希入口见 [LOCAL_MODEL_NOTICES.md](LOCAL_MODEL_NOTICES.md)。

仓库通过 `justfile`、`prek.toml` 和 GitHub Actions 共享同一组门禁。
安装 `just`、`uv` 后，可安装 pre-commit/commit-msg hooks 并运行完整检查：

```bash
just install
just ci
```

`.github/renovate.json` 复用 `github>zrr1999/renovate-config`，统一安排 Swift 与 GitHub Actions 更新。共享 preset 会分组非 major 更新，并仅在全部必需检查通过后 squash 自动合并；major 更新仍保持独立 PR。所有依赖变更继续经过同一套锁文件、OSV、NOTICE 与 CI 门禁。

### 构建 macOS 应用

`swift build` 只生成命令行构建产物，不会创建带权限声明的 `.app`。本地安装需要可用的 Apple 代码签名身份：

```bash
SIGN_IDENTITY="Apple Development" bash scripts/release.sh --install
```

发布脚本默认把 App、DMG 和可能生成的校验 sidecar 写入仓库内的 `.artifacts/release/`。它在昂贵构建前先使旧 App/DMG/sidecar 失效，再在输出目录所在文件系统的私有 staging 中生成并验证新产物，成功后才原子替换。仓库内输出必须位于 `.artifacts/`，路径会解析到物理祖先并把公证快照 capability 绑定到物理输出位置，因此不能用 traversal 或 symlink 绕过；仓库外目录仍可显式指定。预检会拒绝遗留在仓库根目录的发布产物；完整发布策略测试覆盖这些边界、App-only SwiftPM 产品面、本地 ASR 生产接线、arm64-only 产物与失败不遗留旧产物的行为。

使用默认隔离目录验证完整签名与 DMG 流程：

```bash
SIGN_IDENTITY="Apple Development" bash scripts/release.sh
```

如需使用仓库外目录：

```bash
RELEASE_OUTPUT_DIR="$(mktemp -d)/rill-release" \
  SIGN_IDENTITY="Apple Development" \
  bash scripts/release.sh
```

当前发布链路已用真实 Apple Development 身份验证过 arm64 App、hardened runtime、签名 entitlement 与 DMG 完整性。分发模式会先生成并签名最终 DMG，再把该外层容器提交公证、装订票据并执行 Gatekeeper 复验；自动化测试只用假工具验证顺序。仓库尚未用 Developer ID 和真实 notary profile 跑通这条路径，因此不能把当前产物表述为已公证。

真实公证与 Gatekeeper 复验全部通过后，发布脚本才会在最终 DMG 同目录原子生成标准 `Rill.dmg.sha256`；未公证的本地签名 DMG 不生成正式发布 sidecar。校验和证明下载字节一致，不替代 Developer ID、Apple 公证或可信下载渠道。

本地构建只有在工作树干净、当前 `HEAD` 精确且唯一地标记 `vMAJOR.MINOR.PATCH` 时才沿用该版本号；其他来源统一使用数值版本 `0.0.0`，并在 App 元数据中写入 `0.0.0-dev+<commit>[.dirty]`、完整 commit 与 dirty 状态，避免标签后的代码冒充旧 release。

分发版本还需要 Developer ID 签名与公证。先用 `notarytool store-credentials` 在 Keychain 中创建 profile；默认名称为 `Rill`，也可通过 `NOTARY_PROFILE` 指定其他名称：

```bash
xcrun notarytool store-credentials Rill \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID"

SIGN_IDENTITY="Developer ID Application" bash scripts/release.sh --notarize
```

公证模式会在构建前 fail-closed：工作树（含未跟踪文件）必须干净，并且当前 `HEAD` 必须精确且唯一地标记一个 `vMAJOR.MINOR.PATCH` 标签；只有声明了 SwiftPM 源码依赖时才要求将真实 `Package.resolved` 纳入版本控制。脚本随后从该 commit 创建临时 detached worktree，用全新的依赖 checkout 构建，并在签名与公证提交前再次核对 commit、tree，以及存在时的锁文件。普通本地签名和安装仍可在开发工作树中使用。

### 首次使用

1. 打开 Rill，按 Dashboard 的“完成语音设置”清单授权 **输入监控** 与 **麦克风**；只有事件监听真正启动后，`Fn` 和全局剪贴板快捷键才会显示就绪；使用直接输入时还需授权 **辅助功能**
2. 在 Settings 选择本地语音模型或使用硬件推荐。1.7B 选项仅在 Apple Silicon 可见，不需要额外 Python 环境；首次准备需要联网，之后本地转写离线运行。App 不会回退到未知模型、内部预览或未固定来源
3. 按住 `Fn` 开始说话，松开后文字按当前输出模式输入活动 App 或保存到语音剪贴板组

---

## 📖 使用指南

### 语音输入

| 操作 | 说明 |
| ------ | ------ |
| 按住 `Fn` | 开始录音；浮窗显示录音状态、音量和本地实时 partial text |
| 松开 `Fn` | 停止录音，识别结果自动输入到当前应用 |
| `Cmd-F` | 搜索页面、工作流、运行历史和设置分区 |

### 剪贴板分组

- **默认组** — 所有未分配的应用共享此组
- **语音识别组** — 语音识别结果自动进入此组
- **自定义组** — 为特定应用创建专属组，支持 Stack（后进先出）、Queue（先进先出）、List（持久列表）三种模式

从详情、右键菜单或 Delete 删除剪贴板条目都会先确认；合并展示的条目会明确实际删除数量和不可撤销性。文本框或输入法仍在编辑、已有 sheet 或删除确认显示期间，页面级 Delete 与其他快捷键不会越过当前交互。

### 工作流

内置两个生产可用工作流：

1. **语音识别** — `Fn` 按住说话 → STT → 热词与替换词 → 输出文字
2. **语音助手** — `Hey Rill` → STT → 热词与替换词 → LLM 回答 → TTS

语音助手默认停用；启用前需要准备当前本地 Qwen ASR 并配置 OpenAI-compatible LLM。
空闲监听只运行本地 VAD，完整语音段才交给 Qwen 检查唤醒短语；同一句中的后续命令会
直接进入工作流，不再重复 STT。TTS 默认使用 automatic provider：Qwen3-TTS 可用时
使用 Vivian，否则回退系统语音。助手设置中的就绪检查会阻止在麦克风未授权、本地
ASR 未准备、LLM 配置无效或云端隐私策略不可用时开启监听；LLM 已配置但尚未主动验证
时会明确提示验证建议，而不会把未验证状态伪装成已验证。

设置中的“提供商与模型”只管理共享的 STT、LLM 和 TTS 资源；音色保存在各自 workflow
的输出步骤中。环境唤醒与交互识别是两个显式音频通道：开始 Fn/交互录音时会立即取消
唤醒候选，录音结束后恢复环境监听，而已经启动的助手 LLM/TTS 会在独立通道继续运行。

你也可以创建自定义语音工作流，选择本地/云端识别、输出目标和确定性文本处理。
保存工作流且当前编辑草稿与已保存版本一致后，可在 Workflows 页选择“运行前解释”。预览会按当前路由和隐私设置显示 `ready`、`requires confirmation` 或 `blocked`；它不会读取选区/剪贴板正文，也不会替代运行时的重新检查与云端确认。

剪贴板条目详情与右键菜单提供只读“预览影响”：生成预演不会粘贴、修改、发送、运行自动化、写入文件、更新历史或请求确认；实际运行仍会重新检查精确条目、工作流、隐私、权限、凭据与目标位置，且当前预演不提供 Run / Apply / Replace 执行按钮。

真实条目使用与预演凭证彼此独立：每个运行授权只能消费一次；文字和富内容粘贴会原子 claim 预览对应的 exact generation/revision；来源替换使用 CAS，条目删除、内容漂移或同 ID 重建时不会覆盖或复活旧版本。Replay/Replace 的来源身份由 `DeliveryStack` 与 exact item subject 一起原子解析，不进入 dry-run 收据或组 scheduler descriptor。

“最近结果”与“运行历史”已合并为同一页面：侧栏只保留“运行历史”，可在“最近运行 / 最近结果”之间切换，并明确显示当前已加载条数；菜单栏和仪表盘的“最近结果”入口会直接打开结果筛选。正文资格绑定运行时持久化的 closed trigger，并与同 run receipt 交叉验证；来源缺失或冲突时 fail-closed，不再根据当前工作流配置猜测。Dashboard、历史页和活动流共用 `full / restricted / disabled` 正文预览策略；受限内容传给界面与辅助功能树前已在 presentation 层截断为最多 96 个字符，禁用时活动项只保留无正文状态。筛选只改变展示范围，不改变本地留存、清理或隐私策略。

旧版剪贴板组事件配置会经过严格、无正文的调度决策，并可在 History 中查看 unsupported、excluded 或 loop-prevented 等固定原因；只有执行能力存在但被用户停用时才会显示 disabled。descriptor 现绑定 exact item generation/revision，并携带只在内存中流转的 root lineage、已访问 workflow 路径和 8-hop 上限；重复 workflow 或超限链在任何执行能力判断前固定阻断。Runtime 另有来源 App 感知、绝不弹确认的非交互隐私 preflight，但它只返回判定，不发执行 capability。组事件动作仍未开放；缺少 revision-bound 持久授权与 one-shot group action lease 时，不会在后台读取正文、执行文本处理或调用输出动作。

---

## 🏗 架构

```
RillCore        — 领域模型和服务协议
RillPlatform    — macOS 系统集成（焦点追踪、剪贴板控制、权限、文字注入）
RillProviders   — 稳定 ASR/TTS 合同、Speech Worker v5、确定性文本处理与输出动作
RillMLXRuntime  — 仅由语音辅助进程链接的原生 MLX/Metal 推理实现
RillRuntime     — 事件总线、剪贴板存储、候选解析、会话协调器
RillPersistence — 数据持久化
RillUI          — SwiftUI 视图和 AppModel
RillApp         — 组合根和应用入口
```

这些 target 是 App 内部实现边界，不构成对外 Swift SDK；Swift Package 只发布 `RillApp` 可执行产品。

---

## 🗺 路线图

- [x] **确定性映射词** — 识别后按 App、剪贴板组和语言作用域替换，可解释、可测试
- [x] **历史留存与清理** — 默认 30 天、分域配置与清理、保护活动剪贴板项；运行历史、收据与诊断使用持久 CAS generation 阻止旧写复活，读路径只承认当前 generation，并清除 SQLite / WAL 残留
- [x] **ASR 热词** — 显式 provider 能力合同；Qwen 本地路径接收清洗且有界的热词
- [x] **一步纠错闭环** — 从真实识别历史生成保守 mapping/hotword 建议，未知作用域必须人工确认
- [x] **本地静态数据保护** — Keychain 根密钥、AES-256-GCM、可恢复 SQLite v8 迁移、加密运行收据、权威运行来源、逻辑清除 generation 与物理残留清理
- [x] **Durable 运行收据** — 内容无关的真实 trigger、动作终态、耗时分桶与 receipt-first 历史时间线
- [x] **组事件可解释性** — 无正文 exact-item descriptor、有界背压、退出排空、严格配置解析、固定 skip/loop 收据、lineage/8-hop 阻断与双语 History 原因；动作仍关闭
- [x] **失败录音恢复** — 显式 opt-in、Keychain/AES-GCM、硬 TTL 与容量上限、一次性当前策略重试及独立删除/清空
- [x] **运行前解释** — 已保存工作流的动态、内容无关隐私预览；执行时重新检查并使用与工作流绑定的授权
- [x] **云端转写润色** — OpenAI-compatible BYOK、Keychain 凭据、自定义 endpoint / 模型、云端确认与失败不投递
- [ ] **Prompt 变量** — `{text}` `{selected}` `{clipboard}` 让语音输入升级为语音命令
- [ ] **更多云端引擎** — 火山（豆包语音）、Soniox、AssemblyAI
- [x] **Toggle 录音模式** — 按一下开始，再按一下停止
- [ ] **历史记录导出** — CSV 格式导出所有识别记录
- [ ] **本地 LLM** — 在真实隐私、延迟与质量基准后选择 provider/model；Ollama 目前仅为本地候选

---

## 📄 技术文档

- 贡献与本地验证指南：[CONTRIBUTING.md](CONTRIBUTING.md)
- 技术选型记录：[docs/technology-selection.md](docs/technology-selection.md)
- 技术隐私与数据流说明：[PRIVACY.md](PRIVACY.md)；发布装配会把同一文件原样放入 App，并在预检中逐字节校验
- 维护者发布步骤、版本规则和升级边界：[docs/releasing.md](docs/releasing.md)
- 最终包人工验收记录模板：[docs/release-qa-checklist.md](docs/release-qa-checklist.md)

## 📜 许可证

仓库当前尚未包含 `LICENSE` 文件。在维护者正式选择并加入许可证前，源码不应被描述为 MIT 授权。

锁定依赖的许可证与 NOTICE 证据由 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 单独记录，并会随 macOS App 一起打包；这些第三方条款不构成 Rill 自身的许可证。

## 🔐 安全报告

仓库当前尚未包含 `SECURITY.md`，也没有正式的私密漏洞报告渠道。在维护者发布正式渠道前，请勿在公开 issue 中披露敏感漏洞细节；本说明不构成或暗示已有可用的私密联系方式。

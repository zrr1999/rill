# Rill

**本地优先的语音输入 + 剪贴板路由工作站** — 一款原生 macOS 应用，将语音识别、应用级剪贴板分组和可观察语音工作流合为一体。

> 🎙 按住 Fn 说话，松开即输入 · 📋 剪贴板分组路由 · ⚡ 可观察语音工作流 · 🔄 语音状态浮窗

---

## ✨ 核心特性

### 🎤 语音转文字
- **多后端边界** — 云端 [Deepgram](https://deepgram.com)、本地 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 与 Apple Silicon 可选的原生 [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) 已接入；16 GB 默认仍是 Qwen3-ASR 0.6B INT8，也可选择经 MLX/Metal GPU 运行的 Qwen3-ASR 1.7B 8bit；流式预览固定使用轻量中英双语 Streaming Zipformer
- **按住说话（Push-to-Talk）** — 按住 `Fn` 开始录音，松开自动识别并输入
- **本地语音端点** — 主窗口和菜单栏触发的单次听写用随 App 固定捆绑的 Silero VAD v4 判断语音起止：持续语音达到 300 ms 后进入说话态，随后 1.4 秒静音自动收尾，起始 12 秒没有语音则取消空录音。`Fn` 按住说话仍由松键结束，切换式录音由第二次按键结束
- **采集前端处理** — 本地与 Deepgram 采集会启用 Apple Voice Processing 和自动增益，并在运行时验证没有被旁路；它们不是独立的宽带降噪器，当前文档不承诺量化降噪效果
- **语音状态浮窗** — 所有路径都会显示录音、音量和处理状态；Deepgram 显示联网 partial text，本地路径由固定 Streaming Zipformer 生成实时 hypothesis，停止或自动端点后再由所选档位模型生成最终转写
- **中英文支持** — 界面和识别均支持中文/英文双语切换
- **作用域热词** — Deepgram Nova-3 接收筛选后的 keyterms；sherpa 与 MLX Qwen 路径只接收清洗并设有数量/长度上限的热词，MLX 后端通过 Qwen3-ASR 的有界 context 传入
- **Deepgram Speech Check** — 录音前先校验已持久化并回读的 provider 配置与当前隐私策略；录音结束后、音频真正外发前再次授权。录音收尾、最终授权、识别与临时文件清理由同一个 run-scoped Task 持有；取消或退出会等待它完整结束，不会留下已落盘音频
- **延迟音频双阶段授权** — 录音与 exact workflow/run 绑定一次性 lease；队列在解析音频前 claim，解析后、识别前再次检查设置与目的地。等待期间收紧策略会阻止录后云端上传和实时失败后的整段重传
- **可撤销的云端实时会话** — Deepgram 每次连接、启动和音频发送都需要 run-scoped 原子 permit；录音期间持续检查当前焦点与最新隐私设置，进入敏感/未知焦点、Secure Input 或策略不可用时立即按 runID 关流并丢弃缓冲尾部。停止输入后再次 seal，未 seal 或已撤销的录音不能进入录后 fallback
- **明确且可停止的实时状态** — 字幕浮窗区分“本机处理”和“Cloud · Deepgram”；活动录音按钮会真正停止对应 run，而不是只隐藏窗口。停止输入后，控制器与后台队列通过原子所有权转移避免重复处理或遗留音频；App 退出会等待录音、手动工作流、音频队列、Deepgram Speech Check 与剪贴板监听清理。清理超时会取消本次退出而不取消清理；事件排空和持久化先于可能较慢的模型卸载
- **有界实时背压** — Deepgram 音频缓冲固定上限；网络无法及时消费时会 fail-closed，立即撤销外发权限、断开 WebSocket、停止采集并删除临时音频，不会无界占用内存或静默丢音后继续识别
- **有界本地录音** — 本地 sherpa-onnx 模型对所有录音模式采用 20 秒 provider 上限并自动停止；采集层只额外接受 3.0 秒启动检测窗口和单个 0.1 秒 PCM 块的有界余量。Deepgram 等其他识别器遵从各自上限。本地采集只在实时层保留 32 个 PCM chunk 和 20 个音量样本，由非实时 consumer 增量写入权限为 `0600` 的 16 kHz WAV；正常停止会排空所有已接纳尾帧，异常、取消或超时会先关闭文件再清理，不在 Core Audio 回调累计整段录音
- **失败录音恢复（可选）** — 默认关闭；符合条件的投递前失败录音可加密保留最多 24 小时，并从历史页手动重试或删除。重试在解密前和解密后、provider 调用前都重新检查当前隐私与配置，只生成新的运行历史，不重复输出动作。App 退出会拒绝新重试、取消并等待所有活动重试恢复 durable receipt，并执行最终全局恢复明文 sweep；无法证明全部托管明文已清理时会阻止本次退出，让清理继续完成

### 📋 剪贴板管理系统
- **默认不监听** — 新安装默认关闭系统剪贴板捕获和浮动面板全局快捷键；只有用户在设置或菜单栏明确开启后才建立新的捕获基线，关闭期间的变化不会在重新开启时补录
- **分组路由** — 为不同应用分配独立的剪贴板组（Stack / Queue / List 三种模式）
- **语音识别组** — 可将语音识别结果保存到专属组，每个条目可打标签
- **跨组回退** — 当当前组为空时自动从优先级更高的组获取内容
- **智能粘贴** — `Cmd-V` 自动感知当前应用所属组，递送对应内容
- **历史记录** — 捕获允许保存的文本、图片和文件；跳过系统保护内容与敏感 App，支持回放、搜索和独立留存策略。运行历史以 receipt 为主时间线，用同一 SQLite 快照和稳定 keyset 分页浏览全部留存记录；Dashboard 仍只保留轻量最近投影。文件条目通过历史或浮动面板手动回放，不进入 Stack / Queue 自动消费
- **有界且原子的本地存储** — schema 8 将受保护 metadata 与 immutable image blobs 分离，并最多保留 1000 个活动项、每组 500 个活动项和 500 个仅历史项；单项文本上限 1 MiB、图片上限 32 MiB，全部条目的内容总量上限 64 MiB；自定义组最多 256 个、App 路由最多 1024 条，名称、Bundle ID、capture tag 和来源元数据也在编码前校验。超限时只逐出最旧的仅历史项；活动项或已取得粘贴租约的条目不会被静默丢弃，App 分配与新建组在完整校验后原子提交，失败不会产生半移动、幽灵组或把已消费条目重新激活
- **竞态安全的捕获与镜像** — Secure Input 与未知焦点会遮蔽选区和剪贴板输入，排除工作流捕获的标签只遮蔽工作流可见的剪贴板；Stack 路由预览与外部剪贴板捕获会在载荷读取和条件镜像写入前后复核焦点、Secure Input、设置与 change count，边界变化时 fail-closed 且不覆盖外部新剪贴板
- **有界富内容投递** — 临时替换系统剪贴板前，Rill 最多保存 128 个 item、每项 32 个 representation、总计 256 个 representation / 64 MiB；任一表示不可读或超限都会在替换前失败。图片的 ImageIO 解码、完整性检查和 TIFF → PNG 转换在主线程外 single-flight 串行执行，并在提交前复核 change count。精确写回失败会保留原 archive，只重试恢复而不重复粘贴；退出会排空内外两层临时事务，无法证明恢复完成时拒绝本次正常退出
- **安全清理** — 剪贴板、运行历史及相关诊断默认保留 30 天，可按域设为 1 天 / 1 周 / 30 天 / 1 年 / 永久；清理不会误删 Stack / Queue / List 中仍待使用的内容，Rill 遗留临时音频也会在启动和周期维护时回收
- **可恢复的状态持久化** — 分组、路由规则和历史记录跨重启保持；schema 7 图片会原子迁移到 schema 8 metadata/blob graph。不可读、损坏或超出 schema 8 边界的状态进入 `loadUnavailable`，保留原始存储且不以空状态覆盖。主窗口 Clipboard 提供明确、不可撤销的 Reset Storage 确认，用于同时删除受保护旧状态和本次会话的条目、分组与 App 路由；取消或删除失败不会产生半重置
- **本地静态数据保护** — 运行正文、纠错来源、剪贴板状态、设置和导出元数据使用 Keychain 根密钥与 AES-256-GCM 保护；错误或缺失密钥会 fail-closed

### ⚡ 可观察工作流
- **可视化编辑器** — 配置触发方式、识别路径、确定性文本处理和输出位置
- **真实能力优先** — 未配置生产 provider 的 LLM、Snippet 和组事件动作不会出现在新建入口中
- **多种触发方式** — 快捷键、菜单栏和手动触发
- **失败可见** — 缺失 recognizer、transformer 或 action 时明确失败，不静默跳过
- **内容无关的运行前解释** — Workflows 页可预览已保存且没有未保存改动的工作流，查看当前触发、输入类别、处理步骤、输出效果、数据目的地和固定隐私原因；收据不包含正文、prompt、路径、端点或凭据
- **预览与授权分离** — 预览只读取不含正文的隐私快照，不显示云端确认，也不是执行凭证；真实运行会用同一目的地分类器重新检查焦点、剪贴板与隐私设置。语音、非音频工作流和剪贴板重放均须先取得与具体工作流绑定的运行时授权；重放/替换还会同时评估 exact 条目来源 App 与当前动作目标，来源侧的云端禁用规则不会因切换前台 App 而失效
- **Prompt 变量安全基础** — `{text}`、`{selected}`、`{clipboard}` 等 Core 模型使用单遍、有硬上限、非递归的渲染器；运行正文和上下文不可序列化，只有满足 canonical 子集/顺序约束的 content-free summary 可进入收据或诊断。生产 transformer 尚未接线，因此新建工作流不会把这项基础能力伪装成可运行功能
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
|------|---------|---------|
| 本地 ASR | sherpa-onnx 0.6B 默认 + Apple Silicon 原生 MLX Swift 1.7B 可选 | SenseVoice + Qwen3-ASR 校准 |
| 云端 ASR | Deepgram | 多家；以当前 provider registry 为准 |
| **剪贴板路由模型** | App / 组路由 + Stack / Queue / List | 本次源码快照未见同类路由模型 |
| **可观察工作流** | 内容无关运行前解释 + 运行时重新授权 | 模式、Prompt 与快捷键配置 |
| **工作流配置** | 三节点可视化配置 | 模式与 Prompt 配置 |
| **语音状态浮窗** | ✅；Deepgram 与固定本地 Streaming Zipformer 均提供 partial text | ✅ |
| **组标签系统** | ✅ | 本次源码快照未见 |
| 确定性映射词 | ✅ App / 组 / 语言作用域 | ✅ |
| 一步纠错闭环 | ✅ 人工确认建议与作用域 | 热词/片段管理工具 |
| 本地历史留存 | ✅ 剪贴板与运行域独立配置、可清理 | 识别历史 + CSV 导出 |
| ASR 热词 | ✅ Deepgram keyterms + Qwen 有界热词，支持 App / 组 / 语言作用域 | ✅ |
| Prompt 变量 | 🧪 有界单遍模型与 content-free summary 已完成，尚未接入生产变换器 | ✅ |
| 本地 LLM | 🔜 Provider / model 待选；Ollama 仅为候选 | ✅ Ollama |

---

## 🚀 快速开始

### 系统要求
- macOS 14.0 (Sonoma) 或更高版本，仅支持 Apple Silicon（arm64）；发布产物必须是单一 arm64 slice
- sherpa-onnx 与 MLX 本地 runtime 均随 arm64 App 提供；每个候选版本必须在声明支持的 Apple Silicon 硬件上完成录音、模型准备和转写验收
- 可选的 Qwen3-ASR 1.7B 8bit 使用随辅助进程编译的原生 mlx-audio-swift 0.1.3 与 MLX/Metal GPU；用户无需安装 Python 或 `uv`，该路径不使用 ANE/NPU
- Xcode 26 或更高版本，并选择包含 Swift 6.2+ 的 Command Line Tools；本地
  默认开发工具链为 Xcode 27
- 从源码生成发布包还需要与当前 Xcode 兼容的独立 Metal Toolchain；可用 `xcodebuild -downloadComponent MetalToolchain` 安装，并用 `xcrun metal -v` 验证。不要强制 `--toolchain XcodeDefault`，否则 `xcrun` 会排除已下载并挂载的 Metal Toolchain。若组件下载后仍失败，请用 `DEVELOPER_DIR` 临时选择一个验证通过的并存 Xcode，不要修改 Xcode.app 内部文件
- Git、`codesign` 与 macOS 标准发布工具，以及 Python 3.11 或更高版本

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

安装脚本只接受 Gitleaks 8.30.1 的受审 macOS 资产，并在安装前校验当前架构对应的固定 SHA-256。`Package.resolved` 固定 mlx-audio-swift 及其完整 SwiftPM 依赖图；预检会把锁定图与第三方许可证清单、离线 advisory baseline 和 CI 的实时 OSV 查询对照，并继续校验 vendored sherpa-onnx、ONNX Runtime、Silero VAD 的来源与精确字节。随后它用 stdlib Python 3.11+ 执行离线安全策略，检查发布脚本语法与生成产物、执行 arm64 Release 构建和 App 装配，验证产物只含 arm64，并检查 `LC_BUILD_VERSION` 的 macOS `minos` 精确为 14.0；语音 worker 还必须静态包含 sherpa-onnx 的 ASR 与 VAD 入口并拒绝链接 Piper/eSpeak 实现。最后运行完整测试并检查补丁空白错误。凭据扫描会拒绝源码 symlink/非普通文件，并在扫描后重新枚举源文件集、逐字节比对扫描快照，任何扫描期间的增删改都会 fail-closed 并要求重试。这个 Mach-O 门禁不能替代在 Sonoma 的 Apple Silicon 真机上运行最终公证包。

本地语音保持一个稳定 recognizer 边界，按精确模型 ID 路由到同一受监管辅助进程中的 sherpa 与 MLX 服务。默认 Qwen3-ASR 0.6B INT8 使用静态链接的 sherpa-onnx 1.13.4 / ONNX Runtime；仓库中的 XCFramework 由固定 commit 以 `EIGEN_MPL2_ONLY`、TTS/说话人分离/PortAudio 关闭的配置构建，只合并明确的 ASR/VAD archive allowlist，[构建来源、工具链和 Source Code Form 链接](vendor/sherpa-onnx-v1.13.4/BUILD_PROVENANCE.md)均可复核。Apple Silicon 还可选择 Qwen3-ASR 1.7B 8bit：辅助进程原生链接 mlx-audio-swift 0.1.3，并把 Hugging Face 模型固定到精确 commit；0.1.3 直接从 Rill 验证后的本地目录加载，支持自动语言检测和有界 keyterm context。主 App 不链接 MLX，切换最终模型会终止共享 worker、释放前一个后端，避免两套模型同时常驻。ASR 权重不随 App 捆绑，完成准备后的识别不联网。用于自动端点的 Silero VAD v4 模型随 App 捆绑，启动时和发布装配时都按固定大小与 SHA-256 校验；缺失或漂移会使本地语音能力 fail-closed，而不会退回 RMS 猜测。

SwiftPM 依赖采用可复现的兼容组合：上层 `mlx-audio-swift` 固定为最新稳定版
0.1.3，底层 `mlx-swift` 暂固定为 0.31.4。0.31.5/0.31.6 给跨平台
`Cmlx` target 无条件附加 `CudaBuild` 插件，会使当前 Xcode package graph 丢失
plugin target GUID；消费方没有关闭传递插件的开关。上游修复发布前，不要只为追逐
底层版本绕过锁文件或修改 checkout。

| model ID | 角色 / 后端 | 固定来源 | 大小 / 固定身份 |
|---|---|---|---|
| `qwen3-asr-0.6b-int8` | 默认最终模型；中文均衡；16 GB；sherpa-onnx | [Qwen3-ASR 0.6B INT8 archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2) | `878702423` bytes；SHA-256 `393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96` |
| `qwen3-asr-1.7b-mlx-8bit` | 可选较大最终模型；Apple Silicon；MLX/Metal GPU | [`mlx-community/Qwen3-ASR-1.7B-8bit`](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | 约 2.46 GB；commit `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` |
| `streaming-zipformer-small-bilingual-zh-en-preview-int8` | 固定流式预览；不出现在档位选择器；sherpa-onnx | [Streaming Zipformer bilingual INT8 archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16.tar.bz2) | `458187351` bytes；SHA-256 `2b7c63322b32e5e0f2526043a1103366119ca58dd615cd7105a37c01db9553d7` |

Omnilingual 300M/1B 已降为候选档位，公开安装器、最终识别器和设置均拒绝它们；候选理由与重新准入条件见 [本地模型候选清单](docs/local-model-candidates.md)。Fun-ASR Nano INT8/FP16 与已退役 Cohere 的固定 trust anchor 和解码实现仍保留，仅用于旧安装识别、迁移和内部 benchmark；它们同样不进入公开产品面。流式预览模型
准备失败时只退化为录音音量/状态显示，不改变最终档位模型的可用性。

内置语音预设把执行策略放在工作流声明中：`流式直出` 在结束时直接复用固定
Streaming Zipformer 的最终 hypothesis，不再做离线二次转写；`精准转写` 使用所选
最终档位；`转写 + 大模型润色` 已声明 `llmRewrite` 步骤但标记为 planned，在生产级
LLM transformer 接入前保持禁用。三者共用现有 recognizer、transformer 和 action
流水线，捕获层不会直接依赖文本注入。

Qwen archive 的 README 将 ONNX 导出追溯到 ModelScope `zengshuishui/Qwen3-ASR-onnx`、`Wasser1462/Qwen3-ASR-onnx` 与上游 Qwen3-ASR；ModelScope 导出和上游 Qwen 均声明 Apache-2.0。2026-07-18，当前 arm64 Mac 已用严格 source-built runtime 和生产 `SherpaOfflineRecognizer` 在 6.761 秒内跑通 archive 自带的 16 kHz 单声道 `cantonese.wav`，结果保留粤语中文及 `My Princess`；同一生产 provider 又在 2.830 秒内跑通 `codeswitch.wav`，结果保留 `alone, all by myself`。archive 的参考文本表明后者是英、法、意、西语切换，并非中英混合。两者都只是离线技术 fixture，不是真人麦克风、简体中文 + 英文验收或 GA 证据，也不能替代生产录音链路验收。

源码和本地 runtime 仍保留固定的 SenseVoiceSmall 身份，供内部兼容与未来评估使用；它不属于当前公开产品目录，不会出现在公开设置、下载或推荐路径中。只有产品与法律审核均通过后，才会重新评估其公开分发资格。完整 archive 身份、来源链、风险说明以及 FunASR 1.1 英中正文见 [LOCAL_MODEL_NOTICES.md](LOCAL_MODEL_NOTICES.md)。

仓库通过 `justfile`、`prek.toml` 和 GitHub Actions 共享同一组门禁。
安装 `just`、`uv` 后，可安装 pre-commit/commit-msg hooks 并运行完整检查：

```bash
just install
just ci
```

`.github/dependabot.yml` 会每周分组检查 Swift 与 GitHub Actions 更新；自动依赖 PR 仍必须经过同一套锁文件、CI 和人工审核门禁。

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
2. 在 Settings 选择本地语音模型或使用硬件推荐。1.7B 选项仅在 Apple Silicon 可见，不需要额外 Python 环境；首次准备需要联网，之后本地转写离线运行。App 不会回退到未知模型、内部预览或未固定来源。选择 Deepgram 时，请在 Diagnostics 完成本次会话的 Speech Check；检查前会执行隐私 preflight，录音结束后会在音频外发前再次授权
3. 按住 `Fn` 开始说话，松开后文字按当前输出模式输入活动 App 或保存到语音剪贴板组

---

## 📖 使用指南

### 语音输入
| 操作 | 说明 |
|------|------|
| 按住 `Fn` | 开始录音；浮窗显示录音状态和音量，Deepgram 路径还会显示实时 partial text |
| 松开 `Fn` | 停止录音，识别结果自动输入到当前应用 |
| `Cmd-F` | 搜索页面、工作流、运行历史和设置分区 |

### 剪贴板分组
- **默认组** — 所有未分配的应用共享此组
- **语音识别组** — 语音识别结果自动进入此组
- **自定义组** — 为特定应用创建专属组，支持 Stack（后进先出）、Queue（先进先出）、List（持久列表）三种模式

从详情、右键菜单或 Delete 删除剪贴板条目都会先确认；合并展示的条目会明确实际删除数量和不可撤销性。文本框或输入法仍在编辑、已有 sheet 或删除确认显示期间，页面级 Delete 与其他快捷键不会越过当前交互。

### 工作流
内置两个生产可用工作流：
1. **语音转文字** — `Fn` 按住说话 → 识别 → 输入（快捷键触发）
2. **原样输入** — 手动录音 → 原样转写 → 保存到剪贴板组

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
RillProviders   — ASR 合同与路由（sherpa-onnx、原生 MLX Swift、Deepgram）、确定性文本处理与输出动作
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
- [x] **ASR 热词** — 显式 provider 能力合同；Deepgram 接收作用域 keyterms，Qwen 本地路径接收清洗且有界的热词
- [x] **一步纠错闭环** — 从真实识别历史生成保守 mapping/hotword 建议，未知作用域必须人工确认
- [x] **本地静态数据保护** — Keychain 根密钥、AES-256-GCM、可恢复 SQLite v8 迁移、加密运行收据、权威运行来源、逻辑清除 generation 与物理残留清理
- [x] **Durable 运行收据** — 内容无关的真实 trigger、动作终态、耗时分桶与 receipt-first 历史时间线
- [x] **组事件可解释性** — 无正文 exact-item descriptor、有界背压、退出排空、严格配置解析、固定 skip/loop 收据、lineage/8-hop 阻断与双语 History 原因；动作仍关闭
- [x] **失败录音恢复** — 显式 opt-in、Keychain/AES-GCM、硬 TTL 与容量上限、一次性当前策略重试及独立删除/清空
- [x] **运行前解释** — 已保存工作流的动态、内容无关隐私预览；执行时重新检查并使用与工作流绑定的授权
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
- 最终包人工验收记录模板：[docs/release-qa-checklist.md](docs/release-qa-checklist.md)

## 📜 许可证

仓库当前尚未包含 `LICENSE` 文件。在维护者正式选择并加入许可证前，源码不应被描述为 MIT 授权。

锁定依赖的许可证与 NOTICE 证据由 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 单独记录，并会随 macOS App 一起打包；这些第三方条款不构成 Rill 自身的许可证。

## 🔐 安全报告

仓库当前尚未包含 `SECURITY.md`，也没有正式的私密漏洞报告渠道。在维护者发布正式渠道前，请勿在公开 issue 中披露敏感漏洞细节；本说明不构成或暗示已有可用的私密联系方式。

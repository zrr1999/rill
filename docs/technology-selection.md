# 技术选型说明

## 状态

这是一份当前阶段的技术选型记录，目标是先明确主路径，同时为后续替换 provider、切换模型和增加云端能力保留空间。

当前结论是：

- 本地 ASR 主方案：[`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx)
- 云端实时扩展方案：[`Deepgram`](https://developers.deepgram.com/)
- 语音后处理 / 会议洞察候选：[`AssemblyAI`](https://www.assemblyai.com/docs)（未接入）
- 本地持久化：[`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html)（直接使用系统 SQLite3）
- LLM provider：**待定（TBD）**
- LLM model：**待定（TBD）**

> 说明：
> - 这里的 `sherpa-onnx + Deepgram` 是当前主路线。
> - `AssemblyAI` 仅是后续摘要、说话人能力、批处理洞察和会议场景的调研候选；当前代码、发布能力与隐私说明都不应声称已支持。
> - provider 和 model 选型暂不锁死，避免过早绑定具体厂商和模型规格。

## 当前选型摘要

| 领域 | 当前选型 | 状态 | 备注 |
|---|---|---|---|
| 本地语音识别 | [`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx) | 已选 | 本地优先主路径；模型准备后离线运行 |
| 云端实时识别扩展 | [`Deepgram`](https://developers.deepgram.com/) | 已选 | 为低延迟、复杂场景和后续扩展预留 |
| 云端语音洞察扩展 | [`AssemblyAI`](https://www.assemblyai.com/docs) | 候选，未接入 | 只在真实会议/批处理需求成立后重新评估 |
| 数据库存储 | [`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html) | 已选 | 本地历史、配置、诊断数据 |
| LLM provider | TBD | 待定 | 通过 provider seam 保持替换能力 |
| LLM model | TBD | 待定 | 在具体场景和 benchmark 后再定 |
| sherpa-onnx 最终转写模型 | Qwen3-ASR 0.6B INT8 | 已选 | 当前只公开推荐 16 GB Mac 的单一模型；其他容量只进入候选清单 |
| sherpa-onnx 流式预览 | Streaming Zipformer small bilingual INT8 | 已选 | 固定中英双语增量模型，不随最终档位切换；失败时退化为音量状态 |
| Deepgram 具体模型 SKU | `Nova-3` 默认，可按工作流覆盖 | 已实现 | keyterm 只对明确支持的 Nova-3 型号生效 |

## 选型目标

本次选型优先满足以下目标：

1. **macOS 原生 Swift 应用优先**：避免一开始就走过重的跨语言或服务化路线。
2. **本地优先**：模型准备后离线可用、隐私友好、网络不稳定时也能工作。
3. **可扩展到云端**：当场景复杂、精度和实时性要求更高时，能平滑接入云端。
4. **保持 provider 和模型可替换**：当前不锁 LLM 厂商、不锁最终模型。
5. **数据层简单透明**：先用本地数据库把历史、配置、诊断能力打稳。

## 架构方案对比

Rill 当前选择“分层的模块化单体”：同一 macOS 进程中按 `Core / Platform / Providers / Runtime / Persistence / UI / App` 分层，用 Swift actor 隔离会话、录音、队列和剪贴板状态，由 `RillApp` 统一组装具体 provider。

| 方案 | 优点 | 主要代价 | 当前结论 |
|---|---|---|---|
| 单模块 App | 最少样板和构建配置 | UI、系统 API、provider 与存储容易相互渗透，隐私闸门难以全局审计 | 不采用 |
| 模块化单体 | 原生集成直接，运行和调试简单，provider 可替换，权限与本地数据不需跨进程搬运 | 需要严格维护模块依赖和不可绕过的授权边界 | **当前方案** |
| XPC / 本地守护进程 | 可隔离模型资源、崩溃域或高风险解码 | 序列化、版本协议、重连、权限传递和发布签名显著变复杂 | 只在实测证明模型内存/稳定性已成为主要瓶颈时考虑 |
| 云后端 / 微服务 | 可集中代管 token、团队策略和同步 | 引入账户、运维、服务端数据责任与持续网络依赖，与本地优先定位冲突 | 不作为核心转写路径；仅在明确的团队/同步产品需求下单独立项 |

当前方案的关键不是目录数量，而是可执行的边界：

1. `Core` 定义领域模型和服务合同，不依赖 AppKit 或具体 ASR SDK。
2. 工作流解析、隐私目的地分类和真实执行共用同一语义；未知组件不作乐观猜测。
3. 进入识别器或输出 action 前必须持有与确切 workflow/run 绑定的不透明授权；延迟音频在真正处理前再次验证。
4. `App` 是唯一组合根，UI 不直接持有 provider 密钥、端点或可读的授权上下文。
5. 若未来拆分 XPC 或后端，先把这些合同变成有版本的消息边界，不让跨进程类型直接泄漏到 UI。

## 1. 本地 ASR 选型：为什么是 sherpa-onnx

### 结论

当前本地 ASR 默认路径选择
[`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx)，Apple Silicon 另提供原生
[`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift) 可选后端。sherpa 路径固定使用
1.13.4 的 source-built macOS 静态 XCFramework：构建关闭 TTS、说话人分离和
PortAudio，全局启用 `EIGEN_MPL2_ONLY`，最终只合并受审的 ASR archive allowlist。
小型 C/Swift adapter 对外暴露离线识别合同；Core、Runtime 和 UI 不依赖 sherpa
专有返回结构。完整 source graph、工具链和二进制摘要见
[`BUILD_PROVENANCE.md`](../vendor/sherpa-onnx-v1.13.4/BUILD_PROVENANCE.md)。

模型权重不随 App 捆绑。公开构建首次准备最终模型和固定流式预览时需要联网；
sherpa 下载器只接受目录中的固定 archive 身份，MLX worker 则原生链接固定的
mlx-audio-swift 0.1.3，并下载精确 Hugging Face commit；模型由受审目录直接加载，
自动语言识别和有界 keyterm context 也在同一 worker 边界内完成。准备完成后的识别
完全从本地目录运行，不需要网络或 Python 环境。底层 `mlx-swift` 暂固定在 0.31.4，
避开 0.31.5/0.31.6 的 `CudaBuild` Xcode package graph 回归。

| model ID | 角色 | 固定 archive | bytes | SHA-256 |
|---|---|---|---:|---|
| `qwen3-asr-0.6b-int8` | 默认公开最终模型；中文均衡；16 GB | [Qwen3-ASR 0.6B INT8](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2) | `878702423` | `393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96` |
| `qwen3-asr-1.7b-mlx-8bit` | Apple Silicon 可选较大最终模型；建议 24 GB | [MLX community model](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | 约 `2460000000` | commit `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` |
| `streaming-zipformer-small-bilingual-zh-en-preview-int8` | 固定流式预览；不参与最终档位选择 | [Streaming Zipformer bilingual INT8](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16.tar.bz2) | `458187351` | `2b7c63322b32e5e0f2526043a1103366119ca58dd615cd7105a37c01db9553d7` |

sherpa-onnx API 接受 ONNX Runtime 的 `coreml` execution provider，Core ML 可把兼容
子图调度到 Apple GPU/ANE，但这不是一种独立的 Metal 模型。当前 Rill C adapter
仍明确传入 `cpu`。1.7B 可选后端使用 MLX/Metal GPU，但不使用 ANE/NPU；在真人
中英评测、冷热延迟和峰值内存完成前，不把依赖安装成功表述为性能结论。

这里的“默认”是公开产品目录角色，不等于 GA。2026-07-18，当前
arm64 Mac 已通过生产 `SherpaOfflineRecognizer` 在 6.761 秒内转写 Qwen archive
自带的 16 kHz 单声道 `cantonese.wav`，输出保留粤语中文及 `My Princess`。这是离线
技术 fixture；同一生产 provider 又在 2.830 秒内转写 `codeswitch.wav`，输出保留
`alone, all by myself`，但 archive 参考文本表明该样本是英、法、意、西语切换，并非
中英混合。两者都不是简体中文 + 英文真人麦克风、支持机型矩阵或质量阈值证据。

Qwen archive 自带 README 将导出追溯到 ModelScope
`zengshuishui/Qwen3-ASR-onnx`、`Wasser1462/Qwen3-ASR-onnx` 和上游
Qwen3-ASR；ModelScope 导出与上游模型均声明 Apache-2.0。源码和 runtime 仍保留
SenseVoiceSmall 的固定来源身份，仅供内部兼容与未来评估；公开构建不会暴露、
选择、推荐或下载它。其 archive 的 `LICENSE` 只动态指向 FunASR 模型协议，当前
1.1 协议含署名/模型名保留、行为导致许可终止及自动修订条款。任何公开提案都必须
先通过产品与法律审核。精确历史、摘要和完整英中条款见
[`LOCAL_MODEL_NOTICES.md`](../LOCAL_MODEL_NOTICES.md)。

### 选择理由

1. **稳定 recognizer ID，精确模型 ID 选择后端**
   - Qwen3-ASR 0.6B INT8 是 16 GB 默认；Qwen3-ASR 1.7B 8bit 是 Apple Silicon 可选档位；Omnilingual 300M/1B 和 MiMo 仍只记录在候选清单。
   - Streaming Zipformer 可只承担实时 hypothesis，也可在“流式直出”预设中直接提供封口后的最终文本。
   - Fun-ASR/FP16/Cohere 只保留 trust anchor 与旧安装迁移兼容，不进入公开安装器或设置表面。

2. **离线边界清楚**
   - 网络只用于用户显式触发的最终档位与固定预览模型准备；转写阶段不联网。
   - sherpa 使用 URL、字节数、SHA-256 和文件清单；MLX 使用精确模型 commit 与 `Package.resolved`。未知 ID 或不匹配来源直接失败。

3. **平台与模型的耦合更低**
   - 同一 C API adapter 服务当前唯一受支持的 arm64 App slice。
   - 后续更换 sherpa 支持的 ONNX 模型时，可复用下载、生命周期和 provider 边界；不必把新模型的专有结构扩散到 UI 或工作流。

### 语音工作流预设

识别时机、转写模型和输出方式被声明在工作流数据中，而不是写死在录音层：

1. `streaming-direct`：固定 Streaming Zipformer 在捕获期间增量解码，结束时直接复用最终 hypothesis，不启动离线二次转写。
2. `dedicated-transcription`：录音结束后使用所选最终档位模型，再执行轻量文本规范化。
3. `transcription-with-rewrite`：在专用转写之后追加 `llmRewrite` transformer；当前标记为 `planned`，缺少生产 transformer 时保持禁用。

三个预设继续通过同一 `recognizer -> transformer -> action` 执行合同。流式捕获不直接调用文本注入，避免把 provider 和 UI/系统输出耦合在一起。

### 对比备选方案

| 方案 | 项目链接 | 当前结论 |
|---|---|---|
| `Speech.framework` | <https://developer.apple.com/documentation/speech> | Apple 原生、维护成本最低，但本地可用性与模型身份受系统控制，不满足固定模型和可复现 archive 的产品边界 |
| `WhisperKit` | <https://github.com/argmaxinc/argmax-oss-swift> | Apple/Core ML 集成直接，但当前简中/英文混输默认模型与轻量模型会形成另一套 Whisper 专用模型信任、tokenizer 和加载面；迁移后不再是生产主路线 |
| `mlx-audio-swift` | <https://github.com/Blaizzy/mlx-audio-swift> | 已作为窄范围原生 Swift 可选后端接入，只承载固定 Qwen3-ASR 1.7B 8bit；与 Python `mlx-audio` 是受其启发的独立实现，不是绑定层，也不扩展为通用模型插件系统 |
| `Vosk` | <https://alphacephei.com/vosk/> | 小模型、CPU-only、动态词表不错，但质量上限和现代模型选择不匹配当前默认质量目标 |

### 这里的取舍

sherpa-onnx 增加了 ONNX Runtime 二进制体积和 C ABI 维护责任，但换来一个同时覆盖
默认质量档与轻量档、离线边界明确且不绑定 Core ML 模型布局的 runtime。当前不再
并行维护 WhisperKit 生产路径；只有实测证明 sherpa 无法满足明确场景时，才重新
评估第二套本地引擎。

## 2. 云端识别扩展：为什么选 Deepgram

### 结论

当前云端实时扩展方案选择 [`Deepgram`](https://developers.deepgram.com/)。

### 选择理由

1. **实时导向更明确**
   - `Deepgram` 的产品和文档明显更偏低延迟实时场景，适合未来做 voice agent、实时字幕、复杂噪声环境兜底。

2. **更适合和本地 ASR 形成“本地优先 + 云端增强”组合**
   - 默认本地走 `sherpa-onnx` + Qwen3-ASR 0.6B INT8
   - 当遇到复杂场景、远场、强噪声、多说话人、在线模式时，再切换或补充 `Deepgram`

3. **对原生客户端扩展比较自然**
   - 当前已同时接入录后 HTTP 识别和 WebSocket 实时路径，两者共用安全端点校验、模型/语言规划与隐私确认语义。
   - WebSocket 路径使用 run-scoped 可撤销 lifetime：每次发送前取得原子 permit，焦点或设置变为受限时关流；输入停止后只有通过 seal 的同一 lease 才能进入录后兜底，因此实时故障不会放宽云端授权。

### 与云端其他备选的关系

| 方案 | 项目链接 | 当前定位 |
|---|---|---|
| `Deepgram` | <https://developers.deepgram.com/> | **当前主选的云端实时扩展方案** |
| `AssemblyAI` | <https://www.assemblyai.com/docs> | 会议纪要、摘要、speaker/intelligence 的调研候选，尚未接入 |
| `OpenAI Speech API` | <https://developers.openai.com/api/docs/guides/speech-to-text> | 暂不作为云端主选；后续如果整体 LLM 平台集中到 OpenAI，再重新评估 |

### 为什么不是直接选 AssemblyAI 做云端主路径

`AssemblyAI` 很强，尤其在后处理、摘要、speech understanding、speaker/intelligence 方面更完整；但当前我们优先考虑的是：

- 实时链路扩展
- 低延迟能力
- 和本地语音主路径形成互补

因此当前阶段把 `Deepgram` 放在已交付的云端主扩展位，把 `AssemblyAI` 保留在分析/洞察候选位更合理。

## 3. 语音洞察扩展：为什么只把 AssemblyAI 作为候选

### 结论

当前只把 [`AssemblyAI`](https://www.assemblyai.com/docs) 记为调研候选，不是已选组件，也不进入默认实时热路径。

### 选择理由

1. **适合后处理和会议场景**
   - 纪要
   - 摘要
   - Speaker 相关能力
   - 实体、主题、情绪等后续 speech intelligence

2. **候选不等于预先建造**
   - 当前只维持通用 provider 边界，不为尚未验证的会议产品线增加 AssemblyAI 专用字段、账户或后端。
   - 只有当真实语料证明摘要、说话人或批处理洞察是主要用户需求时，才重新比较 provider、数据处理条款、延迟与成本。

3. **和 Deepgram 形成互补**
   - `Deepgram` 偏实时主路径
   - `AssemblyAI` 偏后处理、纪要、分析能力

这两者不是互斥关系，但当前只有 Deepgram 是已交付能力。

## 4. 数据层：为什么是 SQLite3 C API

### 结论

本地数据层选择 [`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html)，直接通过 Swift 的 `import SQLite3` 调用系统自带的 SQLite 库。

### 选择理由

1. **本地桌面应用很适合 SQLite**
   - 无需单独数据库服务
   - 部署简单
   - 数据可本地持久化
   - 易于做历史、配置、诊断导出

2. **直接使用 SQLite3 C API 减少外部依赖**
   - macOS/iOS 系统自带 SQLite3，无需引入第三方库
   - 完全透明地操作 SQL 和数据库，控制力最强
   - 通过自行封装 `sqlite3_*` 函数，保持对数据层行为的完整掌控

3. **比一开始引入更重的数据框架更合适**
   - 当前项目阶段更适合轻量、透明、可控的数据层，而不是过早引入更重的对象图方案。

### 对比备选

| 方案 | 项目链接 | 为什么不是当前主选 |
|---|---|---|
| `GRDB` | <https://github.com/groue/GRDB.swift> | 提供 migration、observation、record layer 等便利，但引入了额外第三方依赖；当前阶段直接用 C API 已满足需求 |
| `Core Data` | <https://developer.apple.com/documentation/coredata> | 对当前阶段来说偏重，且不如直接操作 SQLite 透明 |

## 5. 哪些 provider 和 model 决策仍待定

### 当前决定

以下内容明确标记为 **待定（TBD）**：

- LLM provider
- LLM model
- sherpa-onnx 本地路径的真人质量阈值与支持机型范围

Deepgram 不再属于这个列表：当前默认是 `Nova-3`，并支持按工作流覆盖。本地默认已经确定为 sherpa-onnx + Qwen3-ASR 0.6B INT8，Apple Silicon 可选 mlx-audio-swift + Qwen3-ASR 1.7B 8bit；待定的是两个档位的同语料真人 benchmark 和支持机型门禁。SenseVoiceSmall 只是固定的内部兼容/未来评估身份。

### 原因

1. **当前先锁“方向”，不锁“最终型号”**
   - 先明确本地和云端的技术路线
   - 再通过真实业务场景和 benchmark 定具体厂商/模型档位

2. **避免过早绑定**
   - 如果过早锁定某个 provider/model，后续可能会为了配合某个厂商重写接口和流程
   - 当前架构更适合先把边界和抽象做好

3. **需要真实压测再定**
   - Qwen 默认档能否通过真人编辑成本、延迟与支持机型门禁
   - SenseVoiceSmall 是否值得在产品与法律审核后进入独立内部评估
   - LLM 侧到底接哪家 provider、哪类模型
   - 这些都应该在产品场景更明确、性能基线更稳定后定

## 6. 这套组合如何提供扩展性

当前组合的核心价值不是“现在就把所有能力一次选死”，而是：

### 1. 本地优先

- 默认识别路径走 `sherpa-onnx` + Qwen3-ASR 0.6B INT8
- 保证离线、隐私和基础体验

### 2. 云端可增强

- 当本地场景不够用时，可接 `Deepgram`
- 当真实需求转向摘要、纪要、speaker/intelligence 时，重新评估 `AssemblyAI` 等候选

### 3. provider / model 可替换

- 已交付的 Deepgram 默认型号仍是可配置策略；未交付的 LLM provider/model 保持 TBD
- 后续通过 provider seam 替换，不让 UI 和 workflow 直接绑定厂商特性

### 4. 数据层可长期承载

- `SQLite3 C API` 能承接历史记录、设置、调试日志、诊断导出
- 这部分不依赖某个具体语音或模型厂商

## 7. 对项目实现的具体约束

为了让这份选型真正可落地，后续实现建议遵守以下约束：

1. **在 provider 层保留本地 / 云端 recognizer 的抽象边界**
   - 不要让运行时和 UI 直接依赖 `sherpa-onnx` 或 `Deepgram` 的专有返回结构。

2. **让云端能力以“可选增强”而不是“默认强依赖”方式接入**
   - 第一阶段默认不要求联网。

3. **把 AssemblyAI 当调研候选，而不是现在的主链路依赖**
   - 避免在第一阶段把热路径变得过于复杂。

4. **把 provider/model 决策放到 benchmark 之后**
   - 不在当前阶段锁死具体 LLM 厂商和模型。

## 8. 最终结论

当前阶段的推荐组合是：

- **本地 ASR 默认路径**：[`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx) + Qwen3-ASR 0.6B INT8；Apple Silicon 可选原生 mlx-audio-swift + Qwen3-ASR 1.7B 8bit
- **云端实时扩展**：[`Deepgram`](https://developers.deepgram.com/)
- **语音洞察候选**：[`AssemblyAI`](https://www.assemblyai.com/docs)（未接入）
- **本地数据层**：[`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html)
- **LLM provider / LLM model**：**待定（TBD）**

一句话总结：

> 用 `sherpa-onnx + Qwen3-ASR 0.6B INT8` 保持 16 GB 默认，以窄范围原生 `mlx-audio-swift + Qwen3-ASR 1.7B 8bit` 提供 Apple Silicon 大档位，并保留 `Deepgram Nova-3` 云端扩展；SenseVoiceSmall 继续只作内部兼容身份。

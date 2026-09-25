# 技术选型说明

> 历史材料，保留原始研究、计划或验收范围；不代表当前功能或发布结论。
> 归档基线：main `9e786a6`。当前使用说明见 [用户指南](../../usage.md)。

## 状态

这是一份当前阶段的技术选型记录，目标是先明确本地语音主路径，同时为后续替换本地引擎和切换模型保留空间。

当前结论是：

- 本地 ASR 主方案：原生 [`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift)
- 语音后处理 / 会议洞察候选：[`AssemblyAI`](https://www.assemblyai.com/docs)（未接入）
- 本地持久化：[`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html)（直接使用系统 SQLite3）
- 云端文本润色：OpenAI-compatible Responses API；[`MacPaw/OpenAI`](https://github.com/MacPaw/OpenAI) 0.5.1
- 默认润色模型：`gpt-5.6-terra`；提供 Terra / Sol / Luna 快捷项及自定义模型 ID

> 说明：
> - 语音识别只走本地引擎；当前不提供云端 ASR。
> - `AssemblyAI` 仅是后续摘要、说话人能力、批处理洞察和会议场景的调研候选；当前代码、发布能力与隐私说明都不应声称已支持。
> - 润色使用 BYOK，支持内置及自定义语音工作流和自定义 OpenAI-compatible endpoint；provider seam 仍保持窄边界，替换实现不要求 Core、Runtime 或 UI 依赖 SDK 类型。

## 当前选型摘要

| 领域 | 当前选型 | 状态 | 备注 |
|---|---|---|---|
| 本地语音识别 | 原生 [`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift) | 已选 | Apple Silicon 默认主路径；独立 worker，模型准备后离线运行 |
| 云端实时识别扩展 | 不提供 | 已移除 | 麦克风音频不发送到云端 ASR |
| 云端语音洞察扩展 | [`AssemblyAI`](https://www.assemblyai.com/docs) | 候选，未接入 | 只在真实会议/批处理需求成立后重新评估 |
| 数据库存储 | [`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html) | 已选 | 本地历史、配置、诊断数据 |
| 云端文本工作流 | OpenAI-compatible Responses API + MacPaw/OpenAI 0.5.1 | 已选 | 内置与自定义语音工作流、可配置 endpoint、用户自带 Key |
| 润色模型 | `gpt-5.6-terra` 默认，Terra / Sol / Luna 快捷项或自定义 ID | 已选 | 非流式、reasoning `none`、`store: false` |
| MLX 最终转写模型 | Qwen3-ASR 0.6B 8bit | 已选 | 默认并常驻；1.7B 8bit 是用户可选的大档位 |
| MLX 流式预览 | Qwen3-ASR v5 streaming | 已选 | 只产生预览；封口 WAV 的离线 decode 裁决正式文本 |

## 选型目标

本次选型优先满足以下目标：

1. **macOS 原生 Swift 应用优先**：避免一开始就走过重的跨语言或服务化路线。
2. **本地优先**：模型准备后离线可用、隐私友好、网络不稳定时也能工作。
3. **本地引擎可替换**：保持窄边界，不把 Core、Runtime 或 UI 绑定到单一本地实现。
4. **保持 provider 和模型可替换**：首版落地 OpenAI，但 SDK 只存在于 Providers，领域接口不绑定厂商类型。
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

## 1. 本地 ASR 选型：为什么默认是原生 MLX Swift

### 结论

当前公开产品默认路径是 Apple Silicon 上的原生
[`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift)：Qwen3-ASR 0.6B 8bit
默认并常驻，1.7B 8bit 可选。ASR 位于独立 worker，Core、Runtime、UI 和 workflow
只依赖稳定的 `local-speech` 合同，不依赖 MLX 的专有返回结构。仓库中的 sherpa-onnx
adapter 和固定制品只服务旧数据兼容与历史评测，不再是默认产品路径。

模型权重不随 App 捆绑。公开构建首次准备模型时需要联网；MLX worker 原生链接固定的
mlx-audio-swift 0.1.3，并下载精确 Hugging Face commit；模型由受审目录直接加载，
自动语言识别和有界 keyterm context 也在同一 worker 边界内完成。准备完成后的识别
完全从本地目录运行，不需要网络或 Python 环境。底层 `mlx-swift` 暂固定在 0.31.4，
避开 0.31.5/0.31.6 的 `CudaBuild` Xcode package graph 回归。

| model ID | 角色 | 固定 archive | bytes | SHA-256 |
|---|---|---|---:|---|
| `qwen3-asr-0.6b-int8` | sherpa 兼容与历史评测身份 | [Qwen3-ASR 0.6B INT8](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2) | `878702423` | `393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96` |
| `qwen3-asr-0.6b-mlx-8bit` | Apple Silicon 默认最终模型与流式预览；建议 16 GB | [MLX community model](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit) | `1010771234` | commit `89e96d92ba34aca20b3e29fb10cc284097d1219f` |
| `qwen3-asr-1.7b-mlx-8bit` | Apple Silicon 可选较大最终模型；建议 24 GB | [MLX community model](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | 约 `2460000000` | commit `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` |
| `streaming-zipformer-small-bilingual-zh-en-preview-int8` | sherpa 兼容与历史评测身份 | [Streaming Zipformer bilingual INT8](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2) | `511274346` | `27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8` |

Rill 使用 mlx-audio-swift 的 Qwen3-ASR v5 流式状态生成 confirmed / provisional
预览；流式结果不直接进入输出 action。录音封口后，同一模型档位对完整受管 WAV
执行离线 decode 并裁决正式文本。流式失败只降级预览，不改变最终识别路径。

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
[`LOCAL_MODEL_NOTICES.md`](../../../LOCAL_MODEL_NOTICES.md)。

### 选择理由

1. **稳定 recognizer ID，精确模型 ID 选择档位**
   - Qwen3-ASR 0.6B 8bit 是 16 GB 默认；Qwen3-ASR 1.7B 8bit 是 Apple Silicon 可选档位；Omnilingual 300M/1B 和 MiMo 仍只记录在候选清单。
   - Qwen v5 streaming 只承担实时 hypothesis；最终文本由同一档位的封口 WAV 离线 decode 生成。
   - Fun-ASR/FP16/Cohere 只保留 trust anchor 与旧安装迁移兼容，不进入公开安装器或设置表面。

2. **离线边界清楚**
   - 网络只用于用户显式触发的模型准备；转写阶段不联网。
   - MLX 使用精确模型 commit、文件大小 / SHA-256 inventory 与 `Package.resolved`。未知 ID 或不匹配来源直接失败。

3. **平台与模型的耦合更低**
   - 独立 worker 服务当前唯一受支持的 arm64 App slice。
   - 后续更换 MLX 模型时复用下载、生命周期和 provider 边界，不把新模型的专有结构扩散到 UI 或 workflow。

### 语音工作流预设

识别时机、转写模型和输出方式被声明在工作流数据中，而不是写死在录音层：

1. `streaming-direct`：Qwen v5 在捕获期间增量预览，录音结束后仍由封口 WAV 离线 decode 生成正式文本。
2. `dedicated-transcription`：录音结束后使用所选 Qwen 档位，再执行轻量文本规范化。
3. `transcription-with-rewrite`：在专用转写之后追加 OpenAI `llmRewrite` transformer；预设已开放但默认禁用，只有 Keychain 凭据可读取且模型设置有效时才可选择。

三个预设继续通过同一 `recognizer -> transformer -> action` 执行合同。流式捕获不直接调用文本注入，避免把 provider 和 UI/系统输出耦合在一起。

### 对比备选方案

| 方案 | 项目链接 | 当前结论 |
|---|---|---|
| `Speech.framework` | <https://developer.apple.com/documentation/speech> | Apple 原生、维护成本最低，但本地可用性与模型身份受系统控制，不满足固定模型和可复现 archive 的产品边界 |
| `WhisperKit` | <https://github.com/argmaxinc/argmax-oss-swift> | Apple/Core ML 集成直接，但当前简中/英文混输默认模型与轻量模型会形成另一套 Whisper 专用模型信任、tokenizer 和加载面；迁移后不再是生产主路线 |
| `mlx-audio-swift` | <https://github.com/Blaizzy/mlx-audio-swift> | 当前原生 Swift 默认后端；产品目录固定 Qwen3-ASR 0.6B / 1.7B 8bit，不扩展为通用模型插件系统 |
| `Vosk` | <https://alphacephei.com/vosk/> | 小模型、CPU-only、动态词表不错，但质量上限和现代模型选择不匹配当前默认质量目标 |

### 这里的取舍

MLX 路径与 Apple Silicon 发布范围一致，避免默认 App 同时承担 ONNX Runtime 与
MLX 两套生产引擎的体积、生命周期和质量矩阵。独立 worker 隔离模型资源，稳定
recognizer 合同隔离模型专有结构；只有实测证明现役 MLX 档位无法满足明确场景时，
才重新评估第二套生产引擎。

## 2. 云端识别：当前不提供

### 结论

Rill 已移除云端 ASR。当前生产识别由 Apple Silicon 上的原生 MLX Swift worker 完成。

这项边界不影响可选的 OpenAI-compatible 文本润色：文本工作流只在用户显式配置并授权后发送最终转写正文，不发送麦克风音频。

## 3. 云端文本润色：为什么先选 MacPaw/OpenAI

### 结论

`llmRewrite` 使用 OpenAI-compatible Responses API，并把
[`MacPaw/OpenAI`](https://github.com/MacPaw/OpenAI) 精确固定在 0.5.1。它只作为
`RillProviders` 的实现依赖；Core、Runtime、UI 与工作流声明只看到现有窄
transformer 合同。用户提供自己的 API Key，Key 只存入 macOS Keychain。

请求边界固定为非流式、60 秒超时、`store: false`、`maxOutputTokens: 4096` 和
reasoning `none`。最终转写正文进入 `input`，固定数据边界合同与工作流步骤 prompt
进入 `instructions`。内置与自定义语音工作流复用同一 transformer；首版不渲染或发送
选区、剪贴板、App 名与 bundle ID。设置可提供自定义 Base URL 与模型 ID，但不支持
自定义请求头、provider fallback 或失败时原文回退；HTTPS 是默认边界，明文 HTTP
只允许回环地址。

### 选择理由

1. **最小可验证切片**：Responses API 覆盖当前纯文本润色需求，MacPaw SDK 提供原生
   Swift async 调用和 URLSession 取消链路，不需要引入本地服务或跨语言运行时。
2. **依赖方向受控**：具体 SDK、HTTP 状态和响应结构都收敛在 Providers 内部 adapter；
   设置与运行时只传递本项目定义的 `OpenAISettings` 和 transformer 协议。
3. **隐私和失败语义明确**：运行前继续复用 `.cloudText` 隐私门；只有 completed 且非空
   的纯文本结果才能进入 delivery。拒绝、不完整、空输出、网络错误或取消均失败，
   不注入原始或部分文本。
4. **升级路径清楚**：OpenAI-compatible endpoint 复用同一 Responses adapter；只有出现
   不兼容协议、共享额度或统一鉴权需求时，才新增 adapter 或后端代理。

## 4. 语音洞察扩展：为什么只把 AssemblyAI 作为候选

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

3. **不预建云端语音路径**
   - `AssemblyAI` 只保留为后处理、纪要和分析能力的调研记录，不进入当前产品或发布范围。

## 5. 数据层：为什么是 SQLite3 C API

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

## 6. 哪些 provider 和 model 决策仍待定

### 当前决定

以下内容明确标记为 **待定（TBD）**：

- 未来是否增加其他 LLM provider 或自定义 OpenAI-compatible endpoint
- 是否提供共享额度；若需要，必须单独设计后端代理
- sherpa-onnx 本地路径的真人质量阈值与支持机型范围

本地默认已经确定为 mlx-audio-swift + Qwen3-ASR 0.6B 8bit，1.7B 8bit 是 Apple Silicon 可选大档位；待定的是两个现役档位的同语料真人 benchmark 和支持机型门禁。sherpa 与 SenseVoiceSmall 只保留兼容和历史评测身份。

### 原因

1. **当前先锁“方向”，不锁“最终型号”**
   - 先明确本地技术路线
   - 再通过真实业务场景和 benchmark 定具体厂商/模型档位

2. **避免过早绑定**
   - 如果过早锁定某个 provider/model，后续可能会为了配合某个厂商重写接口和流程
   - 当前架构更适合先把边界和抽象做好

3. **需要真实压测再定**
   - Qwen 默认档能否通过真人编辑成本、延迟与支持机型门禁
   - SenseVoiceSmall 是否值得在产品与法律审核后进入独立内部评估
   - Terra / Sol / Luna 在真实中英润色上的质量、成本和延迟档位
   - 这些都应该在产品场景更明确、性能基线更稳定后定

## 7. 这套组合如何提供扩展性

当前组合的核心价值不是“现在就把所有能力一次选死”，而是：

### 1. 本地优先

- 默认识别路径走 `mlx-audio-swift` + Qwen3-ASR 0.6B 8bit
- 保证离线、隐私和基础体验

### 2. 云端语音不进入当前范围

- 当本地场景不够用时，先用同语料数据判断是模型、前端处理还是端点问题，不自动引入音频外发路径
- 当真实需求转向摘要、纪要、speaker/intelligence 时，另立产品与隐私评审，不复用当前语音识别路径

### 3. provider / model 可替换

- OpenAI 的具体 SDK 留在 Providers；Core、Runtime 和 UI 不暴露 SDK 类型
- 后续通过 provider seam 替换，不让 UI 和 workflow 直接绑定厂商特性

### 4. 数据层可长期承载

- `SQLite3 C API` 能承接历史记录、设置、调试日志、诊断导出
- 这部分不依赖某个具体语音或模型厂商

## 8. 对项目实现的具体约束

为了让这份选型真正可落地，后续实现建议遵守以下约束：

1. **在 provider 层保留本地 recognizer 的抽象边界**
   - 不要让运行时和 UI 直接依赖 `sherpa-onnx` 或 MLX 的专有返回结构。

2. **让云端能力以“可选增强”而不是“默认强依赖”方式接入**
   - 第一阶段默认不要求联网。

3. **把 AssemblyAI 当调研候选，而不是现在的主链路依赖**
   - 避免在第一阶段把热路径变得过于复杂。

4. **OpenAI-compatible 配置保持全局且可验证**
   - 支持内置与自定义语音工作流中的 `llmRewrite` 步骤、全局 Base URL、快捷或自定义模型 ID 和 transcript-only input；工作流级模型覆盖或共享额度需单独评审。

## 9. 最终结论

当前阶段的推荐组合是：

- **本地 ASR 默认路径**：原生 [`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift) + Qwen3-ASR 0.6B 8bit；Apple Silicon 可选 1.7B 8bit
- **云端 ASR**：不提供
- **语音洞察候选**：[`AssemblyAI`](https://www.assemblyai.com/docs)（未接入）
- **本地数据层**：[`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html)
- **云端文本润色**：OpenAI Responses API + MacPaw/OpenAI 0.5.1，默认 `gpt-5.6-terra`

一句话总结：

> 用原生 `mlx-audio-swift + Qwen3-ASR 0.6B 8bit` 保持 16 GB 默认，以同一 worker 边界提供 1.7B 8bit 大档位，不提供云端 ASR，并用隔离在 Providers 内的 MacPaw/OpenAI adapter 落地可选的 BYOK 转写润色。

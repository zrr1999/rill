# 技术选型说明

## 状态

这是一份当前阶段的技术选型记录，目标是先明确主路径，同时为后续替换 provider、切换模型和增加云端能力保留空间。

当前结论是：

- 本地 ASR 主方案：[`WhisperKit`](https://github.com/argmaxinc/WhisperKit)
- 云端实时扩展方案：[`Deepgram`](https://developers.deepgram.com/)
- 语音后处理 / 会议洞察扩展：[`AssemblyAI`](https://www.assemblyai.com/docs)
- 本地持久化：[`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html)（直接使用系统 SQLite3）
- LLM provider：**待定（TBD）**
- LLM model：**待定（TBD）**

> 说明：
> - 这里的 `WhisperKit + Deepgram` 是当前主路线。
> - `AssemblyAI` 不是当前默认的实时热路径，而是作为后续摘要、说话人能力、批处理洞察和会议场景扩展的预留方案。
> - provider 和 model 选型暂不锁死，避免过早绑定具体厂商和模型规格。

## 当前选型摘要

| 领域 | 当前选型 | 状态 | 备注 |
|---|---|---|---|
| 本地语音识别 | [`WhisperKit`](https://github.com/argmaxinc/WhisperKit) | 已选 | 本地优先主路径 |
| 云端实时识别扩展 | [`Deepgram`](https://developers.deepgram.com/) | 已选 | 为低延迟、复杂场景和后续扩展预留 |
| 云端语音洞察扩展 | [`AssemblyAI`](https://www.assemblyai.com/docs) | 已选 | 作为纪要、摘要、speaker/intelligence 扩展 |
| 数据库存储 | [`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html) | 已选 | 本地历史、配置、诊断数据 |
| LLM provider | TBD | 待定 | 通过 provider seam 保持替换能力 |
| LLM model | TBD | 待定 | 在具体场景和 benchmark 后再定 |
| WhisperKit 具体模型档位 | TBD | 待定 | 如 `small / medium / large-v3-turbo` 待压测 |
| Deepgram 具体模型 SKU | TBD | 待定 | 如 `Flux / Nova-3` 待按实时需求确认 |

## 选型目标

本次选型优先满足以下目标：

1. **macOS 原生 Swift 应用优先**：避免一开始就走过重的跨语言或服务化路线。
2. **本地优先**：默认离线可用、隐私友好、网络不稳定时也能工作。
3. **可扩展到云端**：当场景复杂、精度和实时性要求更高时，能平滑接入云端。
4. **保持 provider 和模型可替换**：当前不锁 LLM 厂商、不锁最终模型。
5. **数据层简单透明**：先用本地数据库把历史、配置、诊断能力打稳。

## 1. 本地 ASR 选型：为什么是 WhisperKit

### 结论

当前本地 ASR 主路径选择 [`WhisperKit`](https://github.com/argmaxinc/WhisperKit)。

### 选择理由

1. **最符合 Swift/macOS App 的集成方式**
   - `WhisperKit` 是面向 Apple 平台产品集成的 Swift framework，而不是单纯的运行时或 Python 工具。
   - 相比 `MLX Whisper`、`Sherpa-ONNX`、`Vosk`，它更像“可以直接嵌进 App 的 SDK”。

2. **本地多语、实时、词级时间戳能力更均衡**
   - 相比 `Speech.framework`，它在多语、词级时间戳、模型可控性上更强。
   - 相比 `Vosk`，它的质量上限更高。
   - 相比 `MLX Whisper`，它不是“自己做一层框架”，而是已经是框架。

3. **保留未来扩展空间**
   - 如果后续真的要更硬核的流式架构，可以并行引入 [`Sherpa-ONNX`](https://github.com/k2-fsa/sherpa-onnx)。
   - 如果后续要更强说话人分离，本地可继续沿着 `SpeakerKit` 方向补能力，云端也能引入 `AssemblyAI`。

### 对比备选方案

| 方案 | 项目链接 | 为什么不是当前主选 |
|---|---|---|
| `Speech.framework` | <https://developer.apple.com/documentation/speech> | Apple 原生、维护成本最低，但离线能力是条件成立才成立；有 1 分钟/request、无 diarization、模型不可控等限制 |
| `Sherpa-ONNX` | <https://github.com/k2-fsa/sherpa-onnx> | 真流式能力很强，但工程复杂度更高，当前阶段不作为默认主路线 |
| `MLX Whisper` | <https://pypi.org/project/mlx-whisper/> / <https://github.com/ml-explore/mlx-swift> | 更适合 Mac 侧研究、内部工具和自建 runtime，不是现成 Apple App SDK |
| `Vosk` | <https://alphacephei.com/vosk/> | 小模型、CPU-only、动态词表不错，但质量上限和现代 Apple 平台集成体验都偏弱 |

### 这里的取舍

我们不是在追求“理论上最低延迟”或“最少依赖”单一目标，而是在追求：

- Swift 原生集成成本可控
- 本地效果足够好
- 后面能继续往流式、说话人、云端扩展

在这个目标组合下，`WhisperKit` 是当前最均衡的起点。

## 2. 云端识别扩展：为什么选 Deepgram

### 结论

当前云端实时扩展方案选择 [`Deepgram`](https://developers.deepgram.com/)。

### 选择理由

1. **实时导向更明确**
   - `Deepgram` 的产品和文档明显更偏低延迟实时场景，适合未来做 voice agent、实时字幕、复杂噪声环境兜底。

2. **更适合和本地 ASR 形成“本地优先 + 云端增强”组合**
   - 默认本地走 `WhisperKit`
   - 当遇到复杂场景、远场、强噪声、多说话人、在线模式时，再切换或补充 `Deepgram`

3. **对原生客户端扩展比较自然**
   - `Deepgram` 的 token + WebSocket 路线适合未来接入实时云路径。
   - 这比一开始就让应用强绑定更重的实时链路更稳妥。

### 与云端其他备选的关系

| 方案 | 项目链接 | 当前定位 |
|---|---|---|
| `Deepgram` | <https://developers.deepgram.com/> | **当前主选的云端实时扩展方案** |
| `AssemblyAI` | <https://www.assemblyai.com/docs> | 保留为后续纪要、摘要、speaker/intelligence 扩展 |
| `OpenAI Speech API` | <https://developers.openai.com/api/docs/guides/speech-to-text> | 暂不作为云端主选；后续如果整体 LLM 平台集中到 OpenAI，再重新评估 |

### 为什么不是直接选 AssemblyAI 做云端主路径

`AssemblyAI` 很强，尤其在后处理、摘要、speech understanding、speaker/intelligence 方面更完整；但当前我们优先考虑的是：

- 实时链路扩展
- 低延迟能力
- 和本地语音主路径形成互补

因此当前阶段把 `Deepgram` 放在云端主扩展位，把 `AssemblyAI` 放在分析/洞察扩展位更合理。

## 3. 语音洞察扩展：为什么保留 AssemblyAI

### 结论

当前把 [`AssemblyAI`](https://www.assemblyai.com/docs) 记为已选扩展组件，而不是默认实时热路径。

### 选择理由

1. **适合后处理和会议场景**
   - 纪要
   - 摘要
   - Speaker 相关能力
   - 实体、主题、情绪等后续 speech intelligence

2. **为后续能力升级预留条件**
   - 即使当前第一阶段只做“本地转写 + 云端扩展兜底”，也希望后续不用重做整体架构，就能把会议洞察加进去。
   - 提前把 `AssemblyAI` 放进选型文档，有利于接口设计时预留对应字段和流程。

3. **和 Deepgram 形成互补**
   - `Deepgram` 偏实时主路径
   - `AssemblyAI` 偏后处理、纪要、分析能力

这两者不是互斥关系，而是职责不同。

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

## 5. provider 和 model 为什么标为待定

### 当前决定

以下内容明确标记为 **待定（TBD）**：

- LLM provider
- LLM model
- WhisperKit 具体模型档位
- Deepgram 具体模型 SKU

### 原因

1. **当前先锁“方向”，不锁“最终型号”**
   - 先明确本地和云端的技术路线
   - 再通过真实业务场景和 benchmark 定具体厂商/模型档位

2. **避免过早绑定**
   - 如果过早锁定某个 provider/model，后续可能会为了配合某个厂商重写接口和流程
   - 当前架构更适合先把边界和抽象做好

3. **需要真实压测再定**
   - `WhisperKit` 具体选 `small`、`medium` 还是 `large-v3-turbo`
   - `Deepgram` 具体用 `Flux` 还是 `Nova-3`
   - LLM 侧到底接哪家 provider、哪类模型
   - 这些都应该在产品场景更明确、性能基线更稳定后定

## 6. 这套组合如何提供扩展性

当前组合的核心价值不是“现在就把所有能力一次选死”，而是：

### 1. 本地优先

- 默认识别路径走 `WhisperKit`
- 保证离线、隐私和基础体验

### 2. 云端可增强

- 当本地场景不够用时，可接 `Deepgram`
- 当需要摘要、纪要、speaker/intelligence 时，可接 `AssemblyAI`

### 3. provider / model 可替换

- 当前明确把 provider 和 model 标为 TBD
- 后续通过 provider seam 替换，不让 UI 和 workflow 直接绑定厂商特性

### 4. 数据层可长期承载

- `SQLite3 C API` 能承接历史记录、设置、调试日志、诊断导出
- 这部分不依赖某个具体语音或模型厂商

## 7. 对项目实现的具体约束

为了让这份选型真正可落地，后续实现建议遵守以下约束：

1. **在 provider 层保留本地 / 云端 recognizer 的抽象边界**
   - 不要让运行时和 UI 直接依赖 `WhisperKit` 或 `Deepgram` 的专有返回结构。

2. **让云端能力以“可选增强”而不是“默认强依赖”方式接入**
   - 第一阶段默认不要求联网。

3. **把 AssemblyAI 当扩展能力，而不是现在的主链路依赖**
   - 避免在第一阶段把热路径变得过于复杂。

4. **把 provider/model 决策放到 benchmark 之后**
   - 不在当前阶段锁死具体 LLM 厂商和模型。

## 8. 最终结论

当前阶段的推荐组合是：

- **本地 ASR 主路径**：[`WhisperKit`](https://github.com/argmaxinc/WhisperKit)
- **云端实时扩展**：[`Deepgram`](https://developers.deepgram.com/)
- **语音洞察扩展**：[`AssemblyAI`](https://www.assemblyai.com/docs)
- **本地数据层**：[`SQLite3 C API`](https://www.sqlite.org/c3ref/intro.html)
- **LLM provider / LLM model**：**待定（TBD）**

一句话总结：

> 先用 `WhisperKit + Deepgram` 站稳“本地优先、云端可扩展”的主路线，  
> 用 `AssemblyAI` 为后续摘要和会议洞察预留能力，  
> 用 `SQLite3 C API` 打稳本地数据基础，  
> 同时把 provider 和模型选择继续保持为待定，避免过早锁厂商和锁模型。

# ASR Dogfood Benchmark 计划

> 来源：`docs/competitive-research.md` 与 `docs/technology-selection.md`。
> 目标：用小样本、低成本的真实使用数据，帮助 Rill 决定本地 ASR 引擎与模型优先级。

## 1. 为什么需要 benchmark

Rill 的当前架构是本地多后端（sherpa-onnx + Apple Silicon 可选原生 mlx-audio-swift），不提供云端 ASR。16 GB 默认仍是 Qwen3-ASR 0.6B INT8；24 GB 及以上可对照 Qwen3-ASR 1.7B 8bit。ASR 模型权重不随 App 捆绑，首次准备是明确的联网边界，准备后的识别离线运行；用于自动端点的固定 Silero VAD v4 模型随 App 捆绑并按 SHA-256 校验。两个 Qwen 档位都尚未通过本计划要求的真人编辑成本、自动停录、噪声、延迟阈值与支持机型矩阵，因此不能称为 GA。SenseVoiceSmall INT8 只在源码中保留固定的内部预览身份，不属于公开候选版的设置、下载或推荐路径。竞品 Type4Me、Superwhisper、Wispr Flow、VoiceInk/open-wispr 的经验说明：

- 用户感知不只取决于最终准确率，还取决于首字延迟、最终延迟和是否需要手工编辑。
- 中英混合、专有名词、人名、项目名、命令式短句往往比普通英文句子更能暴露问题。
- 不同本地引擎和模型档位需要有明确切换依据，而不是只凭体感。

因此 benchmark 的目标不是学术评测，而是回答：

1. Qwen 0.6B 默认档能否达到真人编辑成本、自动停止和延迟门禁，1.7B 的质量增益能否抵偿额外内存与最终延迟？
2. 1.7B MLX 档位在哪些设备和场景中值得推荐？
3. SenseVoiceSmall 是否在产品与法律审核后值得进入独立内部评估，以及是否需要 Soniox/火山等新 provider？
4. 词汇管理和 Prompt 变量能减少多少手工编辑？

## 2. 候选对象

### 必测

每个候选版必须测试其实际启用的识别路径。两个 Qwen 档位不能用单元测试、依赖安装或 archive 自带 fixture 代替真人麦克风 dogfood。SenseVoiceSmall 不进入公开候选版对照；只有产品所有者和法律人员先批准独立内部评估后，才可在非公开构建中测试。

| 对象 | 路径 | 说明 |
|---|---|---|
| Rill + sherpa-onnx / Qwen3-ASR 0.6B INT8 | 本地 | 默认路径；每个候选版必测 |
| Rill + mlx-audio-swift / Qwen3-ASR 1.7B 8bit | 本地 Apple Silicon | 启用该档位的候选版必测；同一录音与 0.6B 做质量、RTF、峰值内存对照 |
| macOS 系统听写 | 系统 | 用户天然对照组 |

### 可选参考

| 对象 | 目的 |
|---|---|
| Type4Me | 对比中文、热词/映射词、SenseVoice/Qwen3-ASR 组合 |
| Superwhisper | 对比离线模式、mode/prompt 体验 |
| Wispr Flow | 对比云端低摩擦和上下文感知体验 |
| VoiceInk/open-wispr/Fisper | 对比开源本地 whisper.cpp/Metal 路线 |
| MacWhisper dictation | 对比成熟 Whisper/Parakeet 模型选择 |

## 3. 指标定义

| 指标 | 记录方式 | 目的 |
|---|---|---|
| 首字延迟 | 松开/开始后到看到第一段文本的秒数 | 体感流畅度 |
| 最终延迟 | 停止说话到最终文本稳定的秒数 | 是否打断输入节奏 |
| 原始准确性 | 是否出现错词、漏词、多词 | ASR 本体质量 |
| 编辑次数 | 为得到可发送文本需要多少次人工改动 | 用户成本，最关键 |
| 专有词成功率 | 人名/项目名/API 名是否正确 | 词汇管理价值 |
| 标点/格式质量 | 是否需要重排标点、分点、大小写 | Prompt/mode 价值 |
| 失败类型 | 噪声、停顿截断、中英混合、专有词、幻觉等 | 指导 provider/模型选择 |
| 隐私路径 | 本地/云端/混合 | UI 提示与默认策略 |

推荐主指标：**编辑次数 + 最终延迟**。准确率如果不能转化为少编辑，对用户价值有限。

## 4. 样本句设计

每轮 benchmark 使用 20 条短句，覆盖日常真实场景。每条说 2 次，取较稳定一次或记录两次差异。

### 4.1 普通输入

1. 今天下午三点我们同步一下 Rill 的工作流设计。
2. Please turn this note into a concise GitHub issue comment.
3. 我等一下把这个想法整理到 README 里。
4. The benchmark should measure latency, edit distance, and user effort.

### 4.2 中英混合与技术词

5. 把 sherpa-onnx 和 MLX 的 provider seam 保持干净。
6. 这个 Pull Request 先不要引入 Core Data。
7. 我们需要一个 PromptVariableContext 来渲染 selected 和 clipboard。
8. Run swift test after updating the VocabularyRule applicator.

### 4.3 专有名词/项目名

9. Rill 的语音识别组应该支持 Stack 和 Queue 两种模式。
10. Type4Me 的热词和映射词体验值得参考。
11. Wispr Flow 的 dictionary 能处理 Adithya 这种人名。
12. Superwhisper custom mode 可以读取 clipboard context。

### 4.4 命令式/符号输入

13. 新建一个 TODO，内容是实现 dry-run workflow preview。
14. 记下邮箱 zhan@example.com，后面不要把它发到云端。
15. 输入 slash pi status，然后换行。
16. 把 snake case 的 workflow_run_record 改成 camel case。

### 4.5 长停顿与自我修正

17. 我们先做本地映射词，嗯不对，应该说先做 provider independent mapping。
18. 今天先不做跨设备同步，停顿一下，先做敏感 App 排除。
19. The first version should be small, wait, smaller than a full macro system.
20. 如果识别到 polish generated tag，就不要再次触发自动润色。

## 5. 记录表模板

建议保存为 CSV 或 Markdown 表：

```text
case_id,tool,engine,local_or_cloud,first_token_s,final_s,edit_count,proprietary_terms_ok,format_ok,failure_type,notes
01,Rill,Qwen3-ASR-0.6B-int8,local,0.8,2.1,1,true,true,,
01,Rill,Qwen3-ASR-1.7B-8bit,local-mlx,0.4,1.0,0,true,true,,
```

Markdown 版：

| case | tool/engine | path | first token | final | edits | terms ok | format ok | failure | notes |
|---|---|---|---:|---:|---:|---|---|---|---|
| 01 | Rill / Qwen3-ASR 0.6B INT8 | local |  |  |  |  |  |  |  |

## 6. 30 分钟执行流程

1. **准备（5 分钟）**
   - 关闭无关噪音源。
   - 确认每个工具的语言/模型设置。
   - 打开同一个文本编辑器作为输入目标。
2. **基线（10 分钟）**
   - 先跑 Rill Qwen3-ASR 0.6B INT8 与 1.7B 8bit，各 10 条。
   - 记录延迟、编辑次数和明显失败。
3. **竞品对照（10 分钟）**
   - 选择 1-2 个竞品跑同样 10 条。
   - 优先 Type4Me 或 Superwhisper，因为它们和 Rill roadmap 最接近。
4. **复盘（5 分钟）**
   - 标出最高频失败类型。
   - 判断是 ASR 问题、词汇问题、prompt 问题，还是 UI/流程问题。

### 6.1 sherpa-onnx 本地验收边界

本地 benchmark 必须使用候选版实际安装的生产路径与固定模型身份。Qwen archive
固定为 `878702423` bytes、SHA-256
`393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96`。
完整 URL、来源与许可证证据见
[`LOCAL_MODEL_NOTICES.md`](../LOCAL_MODEL_NOTICES.md)。模型准备应在计时前完成；
计时与录音阶段禁网，以免把下载或云端 fallback 混入本地结果。

当前有两条技术 fixture 证据：2026-07-18，当前 arm64 Mac 上的生产
`SherpaOfflineRecognizer` 在 6.761 秒内转写了官方 Qwen archive 自带的 16 kHz
单声道 `cantonese.wav`，输出保留粤语中文及 `My Princess`。这能证明固定 archive
可以经当前 runtime 完成一次混合语言离线解码。同一生产 provider 又在 2.830 秒内
转写了 `codeswitch.wav`，输出保留 `alone, all by myself`；archive 参考文本表明它是
英、法、意、西语切换，并非中英混合。两条结果都不是简体中文 + 英文或人类同意的
麦克风语料，不覆盖录音/自动停止/抗噪链路，也不能作为 GA 质量证据。

迁移前的 `ASRDogfoodWhisperKitHarnessTests` 与 `scripts/run_asr_dogfood.sh` 不再是
当前生产路径的发布证据。新的 sherpa dogfood 记录至少必须：

1. 使用 `./scripts/release.sh --install` 安装的候选 App 和真实麦克风。
2. 对本节 20 条语句记录两次原始结果、自动停止结果、最终延迟和编辑次数。
3. 固定 model ID、archive SHA-256、App commit、Mac 架构与 macOS 版本。
4. 使用获明确同意的真人语料；合成或上游 fixture 必须单独标记，不能混算。
5. 证明两个现役档位的转写阶段均无网络。
6. 在声明支持的 arm64 候选机上完成；没有 Apple Silicon 真机证据时保持未验收。

SenseVoiceSmall 只允许在产品与法律审核先行批准的非公开构建中运行独立对照；
内部结果不能充当当前公开候选版的发布证据，也不能因下载更小就绕过分发门禁。
结果 artifact 不保存凭据或绝对路径；若保存参考/识别正文，必须按语料同意范围
加密保留并设置清理期限。

## 7. 决策规则

本文尚未定义经产品负责人批准的定量发布阈值。在开始候选版 dogfood 前，必须先固定该候选版的识别范围、语料、主指标和可接受上限；运行后再根据结果补写阈值不构成发布证据。

| 观察 | 决策倾向 |
|---|---|
| Qwen 延迟可接受但专有词错多 | 优先改进 VocabularyRule / 有界热词，而不是换 provider |
| Qwen 长停顿截断或不能自动停止 | 先修录音能量与 endpointing，再比较 ASR 模型 |
| 内部 SenseVoiceSmall 评估更快且质量相近 | 产品与法律审核后，才讨论是否提案进入公开目录 |
| Type4Me 中文明显更好 | 先核对同语料、同设备与词汇配置，再评估火山/Soniox adapter |
| Superwhisper mode 减少编辑 | 优先做用户模式和 Prompt 变量 UI |
| 所有工具都在同类专有词失败 | 词汇/映射词是最优先投资 |

## 8. 与现有计划的关系

- `docs/vocabulary-prompt-design.md`：benchmark 中的专有词错误会直接转化为 `VocabularyRule` 测试样例。
- `docs/privacy-sensitive-apps-plan.md`：benchmark 必须记录实际本地引擎和模型路径，避免混淆下载联网边界与离线识别边界。
- `docs/workflow-observability-plan.md`：每次 benchmark run 后应能看到 recognizer、model、duration 和 post-process steps。

## 9. 最小产出

一次有效 benchmark 至少产出：

1. 10 条样本 × 2 个 engine 的记录。
2. Top 5 失败类型。
3. 3 个真实词汇规则候选。
4. 一个 provider/model 调整建议。
5. 一个 UI/工作流体验调整建议。

## 10. 非目标

- 不做大规模 WER 学术评测。
- 不追求跨所有语言、所有噪声环境的结论。
- 不在没有 dogfood 数据前锁死新增 provider。
- 不用 benchmark 代替用户体验判断；它只是减少主观偏差。

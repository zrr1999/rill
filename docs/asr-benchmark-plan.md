# ASR 质量与延迟验收

本方案以 `main@0fe5834` 为改进前基线。语音最终结果仍来自完整 WAV 的离线识别；流式输出只作预览。本文件描述可复现方法与缺失证据，不承诺未经测量的收益。

## 当前证据

仓库包含 Release worker 回放工具 `scripts/asr_replay.py`、比较工具 `scripts/asr_benchmark.py` 和 120 个采集槽位
`Benchmarks/ASR/collection-plan.json`，**不包含 120 条已录制、已授权的音频**。
槽位分为 72 条开发集和 48 条保留验收集；参考文本当前为空，不能直接通过评分。
填写参考文本前，应听取实际录音并人工复核；提示用户朗读的句子不能直接当作真值。
Release 合成音频的 worker 与隔离宿主生命周期结果见 [验证记录](quality-improvement-validation.md)。
真人语料配对、连续取消压测、原生交互和跨设备验收仍缺失，不默认启用实验性能策略。

## 数据与隐私

1. 只使用获授权音频。Rill 的 benchmark 录音归档仍是用户主动启用、独立加密的本地归档；保留现有关闭与清除入口。
2. 记录来源为 `microphone`、`synthetic` 或 `public_fixture`，三者分别报告。合成音频不能代替真人麦克风验收。
3. 同一音频字节用于基线与候选；以 SHA-256 校验身份。固定开发集和验收集，不能按结果重分组。
4. 语音、参考文本、识别结果和凭据不提交仓库。每轮原始结果存于本机私有目录；比较报告只包含标识、计数和统计，输出权限为 `0600`。
5. 每个条件至少重复三次，保留失败、取消和全部重复结果，不选择最好一次。

## 清单与结果格式

把采集清单复制到私有目录，完成每个槽位的录音、授权记录和人工转写。
`references` 分别是 `raw`（原始 ASR 真值）、`vocabulary`（确定性词汇处理期望）和
`final`（产品最终文本期望）；未评估的阶段省略该键，不写空字符串冒充缺测。
静音的真实期望才是 `""`。`required_terms` 标记专名、数字、否定词，
`forbidden_terms` 标记不应插入的热词；两者按完整 token 序列匹配。
这些词表不能代替人工检查整段遗漏、尾音截断与编辑成本。

每个结果文件是 JSONL。第一行是运行身份：

```json
{"schema_version":1,"run_id":"unique-run-id","source_revision":"full-git-sha","source_digest":"source-content-sha256","model_id":"exact-model-id","model_revision":"exact-model-revision","configuration_digest":"configuration-sha256","device":"chip-memory-input-device","os_version":"exact-system-build","evidence_kind":"microphone"}
```

后续每行是一条重复结果：

```json
{"case_id":"chinese-01","cache_state":"warm","repetition":1,"audio_sha256":"64-lowercase-hex-characters","status":"ok","texts":{"raw":"实际输出","vocabulary":"词汇处理输出","final":"最终输出"},"metrics":{"release_to_final_ms":340,"release_to_saved_ms":355,"release_to_paste_posted_ms":370,"peak_memory_bytes":123456789}}
```

示例数值仅说明格式。未知测量应省略字段，不能填 `0`。
状态是 `ok`、`failed`、`cancelled`。缓存条件是 `cold_process`、`cold_model`、
`first_inference`、`warm`、`idle_recovery`；不同条件分别比较。
运行身份中的配置摘要应包括语言、词库内容版本、热词策略、预览 profile、模型驻留、
预热、后处理和输出配置；任何一个配置变化都是单独的实验。

## 时间口径

所有耗时使用单调时钟。采集端记录以下指标，并经已有诊断清洗通道发布：

- `firstPreviewObservedMillis`：采集源启动至宿主首次观察到可展示的非空预览。
- `stablePreviewObservedMillis`：同一时间原点至宿主首次观察到 worker 的 confirmed 文本。
  不以“连续两次相同文本”冒充模型确认；未出现则缺测。
- `captureStopMillis`、`captureDrainMillis`、`capturePreviewRetireMillis`、`captureFinalizeMillis`：各收尾阶段耗时。
- `captureTailSampleCount`：收尾排空时写入 WAV 的样本数；`previewDeliveredSampleCount`：实际交给预览会话的总样本数。
  预览尚未就绪、失败或丢弃有界预缓存时，两者不能据此推断相等或完整覆盖。

端到端实验分别记录 `first_preview_ms`、`stable_preview_ms`、
`release_to_final_ms`、`release_to_saved_ms`、`release_to_paste_posted_ms`。
首次预览的采集原点与 Fn 按下原点必须注明，不能混合比较。
粘贴派发只表示宿主派发，不能推断目标应用已显示。现有分段耗时不能相加冒充未采集的端到端时间。
峰值内存需声明进程范围（App、worker 或两者）并保持两组一致。

## 比较命令

```bash
uv run --script scripts/asr_benchmark.py \
  --corpus /private/asr/corpus.json \
  --baseline /private/asr/baseline.jsonl \
  --candidate /private/asr/candidate.jsonl \
  --output /private/asr/report.json \
  --purpose quality --split validation
```

性能实验改用 `--purpose performance --target release_to_final_ms`。
只有 `eligible` 返回 `0`；退化为 `reject`，证据不齐为 `incomplete`，均返回 `2`。
`eligible` 只代表本次已提供数据的自动比较门槛，**不代表完整产品或发布验收**。

评分保留大小写和标点、只做 NFC 正规化；CER 忽略空白，WER 将中文单字、英文词和标点作为 token。
报告汇总及每个场景的样本量、CER/WER、关键内容错误、静音幻觉，以及按录音分组重采样的原始 CER 差值 95% 区间。
同录音重复结果不视为独立语料。缺少两个独立非静音样本时不生成可信区间。

质量门槛要求汇总和主要场景不退化，不能用别的样本改善掩盖新增关键内容错误或静音幻觉。
性能实验要求目标 P95 至少改善 10%，其他已测关键延迟和峰值内存不得恶化超过 5%。
这些数字是实验准入值，不是已获得的收益；缺少目标耗时或内存测量不能通过。
同时人工审核整段遗漏、尾音、误改及编辑成本；独立记录 Fn、权限、焦点、IME、VoiceOver 等原生验收。

## Release worker 回放

`EncryptedBenchmarkRecordingArchiveStore` 提供独立的只读评测接口，逐条校验 receipt、
音频认证与长度，拒绝符号链接；不会在应用启动时解密整个归档。在“设置 → 存储”中可选择归档录音、
声明麦克风/合成/公开 fixture 来源、选择开发集或保留验收集，并明确授权导出到本地私有目录。
导出只包含选中的 WAV、SHA256、待填写参考文本的 corpus 和说明文件；不填虚假的空白参考。
目录权限为 0700，文件为 0600；取消/失败清理暂存目录，无法清理时显示剩余目录并提供 Finder 入口。
该剩余目录提示保留在本次应用会话中。导出不上传；仍需本人听取并标注参考文本。
已有获授权 PCM WAV 也可以使用下面的工具。

```sh
scripts/swift_locked.sh release --result-file /private/path/release.json
uv run --script scripts/asr_replay.py --build-receipt /private/path/release.json \
  --corpus /private/path/corpus.json --configuration /private/path/configuration.json \
  --cache-state cold_process --repetitions 3 --output /private/path/cold.jsonl
```

corpus 顶层须指定 `evidence_kind`；每条音频增加 `consent: "authorized"`、
`audio_path`（相对 corpus 文件）及 `audio_sha256`。输入必须是 16 kHz 单声道 PCM16 WAV。
configuration 指定 `model_id`、仓库锁定的 `model_revision`、可选 `language` 与 `keyterms`。
工具校验 Release 构建收据、源代码指纹和二进制摘要；worker 返回的模型 revision 必须匹配。
模型须事先安装；回放不会下载模型、访问麦克风、生成历史或执行输出动作。

工具支持进程冷启动、已运行进程内的冷模型、显式加载后的首次推理和热推理。
热模式在每个 worker 的首次计分前执行一次清单内音频的非计分推理。失败行保留，失败退出码为 2；
输出独占创建且为 0600，不覆盖已有结果；临时音频在请求成功、失败或取消时删除。

`worker_request_ms` 从发送请求前到收到结果，包含该请求引起的加载与排队；
`worker_inference_ms` 由 worker 报告。两者都不是松键到文本显示的延迟。
预览配置可测 worker 原始候选时间，并记录该 worker 的进程峰值内存，详见下文。
它不测用户可见字幕、保存、粘贴、完整模型池闲置恢复或 App+worker 总峰值内存；
缺失项保持缺失，因此单靠回放报告不能通过完整产品性能门槛。词汇与 LLM 阶段也不由此工具代跑。

## 实验顺序与尚缺证据

先补同录音回放与完整端到端时间采集，再比较公开流式 profile、驻留、一次性合成音频预热及缓存回收。
预热只能复用已有资源队列，不读取麦克风、不自动下载、不产生历史。
先在 M5 Pro / 64 GB 建基线，再覆盖低内存 Apple Silicon 与最低支持系统。
目前没有本轮真人 ASR 对照、Release 连续取消压测或上述跨设备性能结论。

流式热词、可靠取消退出屏障、窗口结果复用和选择性大模型复核的重启条件，统一维护在
[改进计划](improvement-plan.md)。250 ms 保护等待在公开接口没有可靠退出保证前保留。


回放也接受 `preview_profile: "realtime" | "agent" | "subtitle"`，以真实时间发送
100 ms PCM 帧，保留不足一帧的尾部；完成预览后仍用同一完整 WAV 离线识别。
`worker_first_hypothesis_ms` 和 `worker_first_confirmed_ms` 从 worker started 后开始发送 PCM 计时，
它们可能包含控制标记，是原始 worker 候选时间，不是用户可见字幕或 Fn 时间；`stream_prepare_ms`、`preview_retire_ms` 单独报告。
流式热词仍标记 unsupported。profile 失败保留为失败结果，不改走无预览冒充成功。

`--cache-state idle_recovery --idle-seconds 30` 测量 worker 模型驻留后的闲置恢复；
配置 `idle_release_model: true` 通过现有公开 release 请求比较释放策略。
这不是 App 自动闲置策略的验收。warm/idle 每个 worker 先做一次明示的未计分推理，
只使用清单内获授权音频。cold_model 测量释放后包含加载的识别请求，first_inference
则先单独记录 `model_prepare_ms`，再测首次推理。cold_process 包含 worker 首次请求等待，
不将进程创建 API 返回时间当作模型已就绪。

`peak_memory_bytes` 来自 Darwin `getrusage(RUSAGE_SELF).ru_maxrss`，单位为 bytes，
范围是该 worker 进程生命周期的最大 RSS，包含模型加载；不是 App+worker 总峰值。
比较器拒绝不同测量范围的配对。生命周期/合成音频实验只报告原始结果，
不能越过真人语料和产品路径门槛启用新默认策略。

## Release 宿主处理路径

`scripts/product_path_benchmark.py` 通过生产 SessionCoordinator、真实 Release worker、词汇处理、
空白规范化、加密 SQLite 提交和隔离输出端运行清单。它不访问麦克风、不粘贴、不下载模型，
也不写入用户数据库。配置中的 `replacements` 是 `pattern` / `replacement` 对；没有 LLM 步骤。

```sh
uv run --script scripts/product_path_benchmark.py --build-receipt /private/path/release.json \
  --corpus /private/path/corpus.json --configuration /private/path/configuration.json \
  --cache-state warm --repetitions 3 --output /private/path/host-warm.jsonl
```

该工具使用同一 manifest 的 Release 领域测试构建范围，Debug/Release 缓存分别隔离。
完整 CI 仍构建全部生产目标、运行全量测试。`first_inference` 在每个计分请求前显式释放和加载模型；
`warm` 先运行一条独立留存的非计分热身，然后重复完整清单。热身失败会中止运行。
`host_replay_to_final_ms`、`host_replay_to_saved_ms` 和 `host_replay_to_isolated_dispatch_ms`
从宿主准入前开始计时；后两者仅在实际保存/派发时存在，不等同于松键或真实应用粘贴。
识别得到无语音时，验证本次没有 Record 提交和输出，只记录真实 raw 及识别耗时；不伪造后处理或保存结果。

结果核对实际 worker 模型与 revision，结果音频摘要必须匹配当前 corpus；源码/产物在前后校验均有效才标为
`evidence_validation: passed`。中断、构建失败或身份失效的报告不能用于比较；完整行集含运行失败时返回非零。
各阶段正文和热身结果只保留在私有报告，不进入诊断或仓库。合成录音、缺少人工标注或缺少总峰值内存时，
宿主报告仍不能通过完整质量与性能准入门槛。

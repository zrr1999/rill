# Rill 改进项目计划

> 目标：寻找同类工具，学习经验，改善我们。
> 当前主线：把竞品研究结论转化为 Rill 的可执行产品/架构改进。

## 架构、ASR 与产品质量改进（2026-09-25）

基线：`main@0fe5834`。质量不退化后再降低延迟；只使用固定依赖的公开接口。
内部接口允许收敛，Record、设置、词库与工作流保留升级路径。以下状态是实施进度，
不是产品验收结论；旧章节保留为历史背景。

| 工作包 | 状态 | 完成条件 |
| --- | --- | --- |
| P0-1 评测与测量 | 实施中 | 同录音回放、分层评分、身份坐标与至少 120 条获授权录音；真实语料尚待采集/确认 |
| P0-2 正确性 | 代码与定向回归完成，待完整门禁 | 多键写入排序、失败重试与退出排空；配置校验共源；单向输出接口 |
| P1-1 应用状态 | 已删除 40 个状态转发属性，完整迁移待继续 | 功能模型拥有状态和任务；显式命令；完整生产依赖；组合根只组装 |
| P1-2 运行时 | 快照、最小请求、输出执行器与录音控制迁移已实现 | 识别快照、最小请求、录音状态、输出执行与资源所有权 |
| P1-3 ASR 质量 | tokenizer 预算、能力状态、尾部 PCM 回归已实现；真人验收待做 | 提示词预算、能力声明、尾部 PCM 一致性；完整 WAV 保持最终权威 |
| P1-4 状态与恢复 | 去向文案与稳定字幕布局已实现；恢复界面待继续 | 数据去向与健康状态分离；稳定字幕布局；按实际结果恢复 |
| P2-1 Record/SQLite | 单一图值和同 actor 拆分已实现；定向回归通过 | 单一图状态、提交后发布、同一连接不可悬停事务、迁移边界 |
| P2-2 公共机制 | 重复注册校验和只读请求投影已实现；其余待继续 | 组件能力、模型文件机制、系统适配、类型化请求/错误/诊断 |
| P2-3 查询与面板 | 共享 revision 查询、固定详情工具栏和高级选项后置已实现；原生验收待做 | 共用查询会话，主操作清楚，有界只读预览 |
| P2-4 延迟 | 待实施 | 冷热分层、公开参数对照；没有证据不改变默认策略 |
| P2-5 纠错与设置 | 待实施 | 本次修正与显式记忆分开，原始内容保留，设置突出阻塞项 |
| P3 门禁 | 全 target 导入检查与隔离领域测试已实现；完整门禁待跑 | 确定性测试、全模块边界、产品基准、隔离快速测试与完整 CI |

依赖：P0 → 识别快照 → ASR 参数与延迟实验；运行状态 → 状态展示；
Record 合同 → 查询 → 面板。结构与行为分开提交，每个切片完成即删除旧路径。

验收方法和指标见 [ASR 基准](asr-benchmark-plan.md)，原生验收见
[发布 QA](release-qa-checklist.md)。本地检查、Hosted CI、真实安装与其他机型分别记录。

### 公开接口缺口 TODO

- **流式热词**：当前固定 `StreamingConfig` 不接收上下文。等待公开接口支持后，
  通过热词命中和未说热词反例，再接入冻结快照。宿主传递字段不能当成模型已经应用。
- **推理退出屏障**：当前 `cancel()` 不 join 底层任务。等待真实退出和清理保证，
  通过 Release 连续取消/复用/退出验证后才能移除 250 ms 保护；协议 ACK 不算退出。
- **最终窗口复用**：公开 `stop()` 已有收尾，但仍需可靠退出、完整样本覆盖和同录音
  质量证据。此前完整 WAV 离线识别保持最终权威，不把显示预览升级为最终结果。
- **选择性大模型复核/额外降噪**：先证明明确场景收益；质量、延迟、内存未通过时
  保留现有策略，不新增默认开启的处理层。

## 项目意图

围绕 Rill 的同类语音输入、剪贴板管理和桌面自动化工具做持续研究，提炼可落地经验，并优先改善：

1. 日常语音输入成功率。
2. 工作流自动化的可解释性与可调试性。
3. 本地/云端路径、敏感剪贴板内容等隐私安全体验。
4. Rill 相比单一 dictation 或 clipboard 工具的差异化表达。

## 初始任务

### 1. competitive-research：整理同类工具研究结论

- 状态：已完成初稿。
- 产物：`docs/competitive-research.md`
- 步骤：
  1. 阅读 README 和 `docs/technology-selection.md`，明确现有定位与 roadmap。
  2. 调研 Wispr Flow、Superwhisper、Type4Me、MacWhisper、VoiceInk/open-wispr、Raycast Clipboard、Keyboard Maestro 等工具。
  3. 提炼 Rill 的定位、差异化、P0/P1/P2 改进方向。
- 验证：文档包含参考来源、竞品表、关键经验和可执行近期任务。

### 2. vocabulary-and-prompt-design：设计词汇管理与 Prompt 变量方案

- 依赖：`competitive-research`
- 状态：确定性映射词与本地 Qwen 热词链路已接入生产运行时；Prompt 变量生产接线待完成。
- 目标：把竞品中的 dictionary/custom vocabulary/prompt context 经验转化为 Rill 的核心模型。
- 步骤：
  1. 梳理现有识别结果、上下文和工作流模型。
  2. 设计 `VocabularyRule`：区分 provider-independent 映射词与 provider-specific 热词。
  3. 设计 `PromptVariableContext`：支持 `{text}`、`{selected}`、`{clipboard}`、`{app}`、`{group}`。
  4. 定义缺失变量、权限失败、空上下文的错误/诊断表示。
- 验证：能用纯函数测试覆盖映射词替换、作用域选择和变量解析。

### 3. workflow-observability-plan：规划工作流可观测性改进

- 依赖：`competitive-research`
- 状态：静态与动态 content-free Explain、typed durable run receipt、receipt-first timeline、clipboard item dry-run 产品 UI 与 invocation-aware 真实授权已完成；Replay/Replace 会同时评估 exact 条目来源 App 与当前目标。group 调度层现使用无正文 exact-item descriptor、有界背压 FIFO、严格配置解析、lineage/8-hop hard stop 和 durable fixed skip/loop receipt，History 可显示具体双语原因。execution surface、运行能力与用户停用状态分离；来源感知的 non-interactive preflight 永不弹确认且不发 capability。退出会先停生产者，再等待 sink 摘除屏障并排空已接纳判定。条目预演保持只读，组 action 仍保持关闭。
- 目标：让自动润色和组事件触发不再是黑盒。
- 步骤：
  1. 梳理 `EventBus`、workflow runtime、diagnostics 和 persistence 的现有边界。
  2. 设计 `WorkflowRunRecord` 字段：触发事件、输入摘要、动作结果、耗时、错误、防循环原因。
  3. 规划 dry-run、重放和一键暂停入口。
- 验证：能解释一次组事件为何触发/为何跳过/为何失败。

### 4. privacy-and-sensitive-apps：规划隐私与敏感 App 排除

- 依赖：`competitive-research`
- 状态：敏感 App、Secure Input、未知焦点、保护标签、云端确认与主要运行入口已接入统一隐私策略；真实安装账户的交互验收待完成。
- 目标：学习 Raycast 等工具对密码管理器和敏感内容的处理经验。
- 步骤：
  1. 设计敏感 App 排除列表与默认建议。
  2. 明确剪贴板捕获、语音结果入组、云端 provider 调用的用户提示。
  3. 设计本地/云端路径状态文案。
- 验证：用户能在 UI 中看懂哪些内容会被保存、哪些内容会离开本机。

### 5. asr-benchmark-plan：制定本地/云端 ASR dogfood benchmark

- 依赖：`competitive-research`
- 目标：在锁定更多 provider 前，用小样本真实数据比较准确率、延迟和编辑成本。
- 步骤：
  1. 准备中英混合短句样本。
  2. 定义指标：首字延迟、最终延迟、人工编辑次数、失败类型、云端/本地路径。
  3. 设计 30 分钟手动 dogfood 流程。
- 验证：benchmark 不要求重工程实现，但能产生 provider/model 决策依据。

## 当前优先级

### 已完成的本轮切片（2026-07-10 至 2026-07-13）

- 刷新语音输入、开源 ASR、剪贴板与自动化竞品雷达。
- 区分 ASR hints、Whisper prompt、LLM vocabulary 与确定性 mapping，避免产品命名混淆。
- 把确定性映射词接入 `SessionCoordinator`：识别完成后、post-process 前执行，遵守 App / 目标剪贴板组 / 语言作用域。
- 规则加载失败时保留原始识别结果，并写入不含原文的诊断。
- 设置页默认创建已生效的 mapping；hotword 已接入本地 Qwen 最终转写路径，并在界面中明确区分模型 context 与确定性 mapping。
- 将隐私策略接入两阶段剪贴板读取、Secure Input、录音启动和手动音频工作流；策略不可用时 fail-closed。
- 识别 concealed / transient / auto-generated pasteboard 内容，保护内容不进入历史，也不会被队列粘贴拦截覆盖。
- 移除生产可见的伪 LLM、硬编码 snippet 和组事件动作；内建目录只保留两个真实工作流，并建立 TOML → JSON/Swift 的只读漂移检查。
- Webhook 动作实现具备最小文本载荷、隐私授权和 HTTPS 策略；发布版本仍从新建入口与生产 registry 隔离，导入和旧执行 fail-closed。旧端点/请求头现会先写 Keychain 并精确回读，再用稳定引用原子替换 SQLite 明文，执行 `secure_delete`/WAL 截断/`VACUUM` 后才标记完成；冲突或失败时隔离工作流但不阻断其他设置。
- 失败录音恢复默认关闭时，临时音频成功、失败、取消均按显式所有权清理。正常处理完成后的托管 WAV 删除也复用队列退避清理所有者，瞬时 unlink 失败会持续重试并纳入 run cancel / App shutdown 屏障。启动和周期维护会回收普通遗留文件，并避免跟随符号链接或递归删除目录。
- 剪贴板捕获支持暂停与忽略下一次外部复制；敏感 App 支持自定义规则增改删、校验去重和推荐默认恢复。隐私设置由 UI 与运行时共享同一会话策略源，四项设置严格串行并在单次 SQLite 事务中提交；加载失败 fail-closed，保存失败保留会话内策略并提供可见重试。
- 新增统一 preflight 与最小权限 GitHub Actions，提交 `Package.resolved` 作为可复现依赖基线。
- 剪贴板历史与运行历史默认各保留 30 天，可独立选择 1 天、1 周、30 天、1 年或永久，并可分别清理；诊断跟随运行历史留存与清理。初始设置快照读取完成前，UI 与 AppModel 都拒绝留存期修改，避免晚到旧策略覆盖用户选择并触发不可逆清理。清理协议先持久化可重放意图，保护 Stack / Queue / List 与租约中的活动项，完成逻辑删除后清理 SQLite/WAL 残留；启动、策略缩短和每日周期维护共用同一入口。
- 建立 `SpeechRecognizerCapabilities` 与不可持久化的 `SpeechRecognitionRequestOptions`；词汇规则在隐私授权后按 App / 组 / 语言解析为录音时快照，经实时和录后路径传递。本地 Qwen 路径执行有界 hotword/context 适配，其他模型显式忽略；诊断只记录结果与计数，不记录热词内容。
- Dashboard 增加默认听写路径 readiness 清单，按输出模式准确判断辅助功能是否必需；权限只在用户操作时请求，App 返回前台会刷新。本地模型只有当前会话真实加载成功才算就绪，配置变化会使验证失效。
- AppModel 的所有“复制”动作统一经共享 `PasteboardController` 写入并登记 owned change，避免诊断或历史复制被监听器再次捕获。
- 手动录音工作流增加 UI `preparing` 状态；只有 capture 真正启动后才显示 recording，准备期间二次点击不会提前调用 finish，启动失败回到 idle。
- 发布脚本支持隔离输出，且已用真实 Apple Development 身份完成端到端本地发布验收：454 项测试全部通过，`x86_64 + arm64` App 具备 hardened runtime、可信时间戳与麦克风 entitlement，DMG 校验通过。验收同时修正了 `plutil` 将 entitlement 点号误解为层级路径造成的假失败；这不替代 Developer ID 公证。
- 完成一步纠错闭环：正常语音运行在 mapping/transform 前记录最小 correction provenance，历史页允许用户编辑原识别并从保守 planner 的 mapping/hotword 建议中显式选择；App、分组、语言任一上下文缺失都必须逐项确认“任意”，冲突不会覆盖已有规则，重放/剪贴板投递不产生学习来源。SQLite v3 迁移可恢复，旧记录保持无来源；本轮全量 502 项测试通过。
- 修复文字注入的数据损失边界：临时 pasteboard 写入在成功、失败和取消时都执行基于 change count 的条件恢复；用户期间主动复制不会被覆盖，并发临时注入会在写入前拒绝。纯文本、富内容、失败、取消、外部复制与并发均有回归测试。
- 完成本地静态数据保护：Keychain 持有不可变 32-byte 根密钥，Core 使用带 typed AAD 的 AES-256-GCM envelope；当前 SQLite v8 在 v4 数据保护基线上继续保护运行历史、纠错来源、全部设置/剪贴板状态、导出元数据和 v5 运行收据，v7 为正文历史增加 nullable closed trigger，v8 为 History、receipt 与 diagnostic 增加持久 write generation 和可重放 CAS clear transition。旧行不会被猜测性回填；错误密钥、损坏数据、generation 冲突和 trigger 冲突均 fail-closed，durable cleanup marker 会在崩溃或 WAL busy 后重试 checkpoint / `VACUUM`。
- 完成失败录音恢复：默认关闭，只有投递前的非取消失败和 Rill 管理文件可进入 Keychain/AES-GCM 加密缓存；硬 TTL 为 24 小时，最多 3 条、单条 16 MiB、总计 32 MiB。手动重试重新执行当前 preflight、隐私确认和识别选项，只生成历史；attempt 状态在解密前持久化，中断或清理失败不会重复 provider 请求。开启、关闭与 preserve 共享 generation actor；崩溃后超配额会收敛，损坏索引不会阻塞其他到期清理，恢复明文启动即清理，失败后退避重试且完成前禁止新的恢复请求。终止屏障还会执行最终全局明文 sweep；无法证明所有托管恢复临时文件已删除时阻止当前退出，清理任务本身不被取消。
- 完成发布供应链与许可归因闭环：所有 Swift 构建和测试强制使用 `Package.resolved`，公证发布只接受唯一语义版本标签和干净、无隐藏索引标志的来源，并在一次性 capability 约束的 detached worktree 中构建；签名与提交公证前再次校验 commit、tree 和 lock blob。8 个锁定依赖的许可、NOTICE、来源 revision 与证据 SHA-256 由生成器严格核对并装入 App，26 项发布策略与 9 项第三方归因测试通过。
- 把 WhisperKit dogfood harness 改为可验证的离线证据链：目标 XCTest 在读取配置前自行应用内核 `no-network` profile，wrapper 的构建与执行环境均从 `env -i` 开始；受信 Ed25519 attester 对 schema 2 语料 manifest 与 consent-evidence hash 签名。corpus、model、tokenizer 在沙箱内通过 dirfd / `openat(O_NOFOLLOW)`、同一 source fd 哈希与 clone/copy 建立随机 `0700` 快照，拒绝 symlink、hardlink、inode 替换和运行期漂移。公开 schema 4 结果不保存参考/识别正文及其无盐 hash，只保留固定分类、计数、距离、时延和输入/模型哈希。
- 建立工作流执行与解释的单一 resolved-plan 语义：生产 AppModel 与 content-free Explain 共用同一个 resolver，按实际 invocation binding 解析 automatic recognizer 与内建 push-to-talk output；本地 required audio、conditional hints、conditional vocabulary mapping、多效果 action 和来源 action index 都可静态说明。隐私动态评估未完成时收据固定 blocked；旧剪贴板事件工作流在 preflight、上下文、录音、解密、识别和 action 前统一拒绝，拒绝音频的明文清理失败会指数退避重试而不进入处理或恢复。最新完整 preflight 通过 `x86_64 + arm64` Release 构建、App 装配与临时严格签名；全量 630 项、1 项 expected skip、0 失败。
- 完成动态、内容无关的 Explain UI：只允许解释已保存且当前草稿无未保存改动的工作流；预览按真实手动 invocation、当前 recognizer 和内建 output route 解析，只读取 privacy-safe identity/descriptor 快照，并显示 fixed-enum 输入、处理、输出、目的地、隐私原因和 `ready` / `requiresConfirmation` / `blocked`。预览不调用确认、provider 或完整上下文读取，不保存正文、prompt、URL、路径、凭据或底层错误；路由/隐私设置变化会使结果失效，真实运行仍重新采集和授权。
- 将 destination classification 收敛为 Explain 与 live gate 共享的 closed classifier；未知组件或目的地 fail-closed。Runtime 对外只接受与 exact workflow 绑定的 opaque `AuthorizedWorkflowRunContext`，raw context 执行 API 保持 module-internal；非音频工作流和剪贴板 replay 也必须先完成 preflight、隐私授权和 options 快照，授权失败时 coordinator、recognizer 与 action 调用均为 0。
- 收紧策略 redaction：Secure Input 与未知焦点会遮蔽 selection/clipboard 并停止剪贴板与工作流捕获，未知焦点的云端路径额外阻断；`excludeFromWorkflowCapture` 标签允许合规历史捕获但会遮蔽工作流可见 clipboard。授权在返回前重读设置和目的地分类，云端确认后若策略变化会 fail-closed。
- 对 StackPaste 的 preview mirror 与 external capture 增加完整竞态复核：payload 读取前后及 mirror 写入后比较 pasteboard descriptor/change count、焦点身份、Secure Input、策略结果和 capture-control revision；焦点切换、设置收紧、暂停/ignore-next 或 ownership 变化会丢弃 payload、恢复仍由 Rill 持有的原剪贴板并关闭拦截。
- `finishing` Task 按 run/operation 精确覆盖 capture finish、本地 recognizer 与托管临时音频清理，UI 取消和 App shutdown 都会等待整条链退出。TextInjection 绑定运行开始时的 bundle/PID 最小焦点身份，尝试恢复并在粘贴或键盘分块前复核；失败时不发送或条件恢复剪贴板，诊断不含目标身份和正文。
- 延迟/录后音频改用 exact workflow/run 绑定的一次性两阶段 lease：队列在解析 `DeferredCapturedAudio` 前 claim，在 WAV finalize 后、recognizer 前 final revalidate；失败录音重试也在解密前 claim，解密后再复核并在拒绝时删除明文、恢复 attempt。新增 block/redaction/设置/目的地漂移均不进入 provider；确认仅在首次新增要求时发生一次。
- Runtime 对手动、按住说话和长录音持续重验焦点/设置，输入停止后 sink-adjacent seal。`sealed → queueOwned` 是同步原子转移；转移前由控制器撤销，转移后由队列按 runID 取消 pending/active 工作。终态 shutdown 拒绝新 enqueue、向底层 deferred Task 传播取消、收束 drain/清理任务并唤醒并发 waiter；Stop→新 run→旧 finish 恢复也不能清除新 run。浮窗显示本机处理来源并提供真正的 run-scoped 停止；App 退出同时等待 capture controller、音频队列和 StackPaste 清理。
- 剪贴板临时写入收紧为 MainActor 同步条件事务，在保护标记、payload 快照和最终 change count 之间不再 suspension；Stack mirror 使用同样的条件写入。浮动面板在隐藏前锁定 content-free PID/bundle 目标，并将它贯穿 panel、AppContainer、Bootstrap、Coordinator 与 TextInjection；恢复后被其他 App 抢焦点时 text/rich 都零投递。文件项保持历史/面板手动回放，不进入 Stack/Queue 自动消费。
- 被策略拒绝的 deferred capture 只解析一次：永久 resolution failure 按 capture-service 所有权合同记一次净化终止诊断并收敛；只有已转移所有权后的明文删除失败才持续退避重试，避免永久失败 Task 无界常驻与重复诊断。
- 手动与热键录音的 deferred finalize 也由 `runID + operationID` 精确持有；cancel/shutdown 会先撤销所有权与 lifetime、执行 run-scoped provider/queue 取消，再等待旧 Task 删除已转移的 managed WAV。旧完成不能清除新 run。CI 固定 `prek` action commit 与工具版本并执行完整配置；preflight 在构建前检查全脚本语法，App 装配与 preflight 共用 Universal verifier。本地包只有干净、唯一 HEAD semver tag 才沿用发布版本，否则写入明确的 dev label、commit 与 dirty metadata。
- 完成内容无关的动态运行收据：Runtime 直接构造 versioned terminal receipt，SQLite 独立加密存储；真实 trigger、分桶耗时、最多 32 条动作固定结果及 completed/partial/failed/cancelled/skipped 均可追踪。写入失败复用冻结终态做有界重试并进入有界 dead-letter；坏 payload 按行隔离且不占查询 limit。fan-out 只发送 content-free repository invalidation，AppModel 先移除旧投影再精确回读，insert-return → clear → notify 与 reload failure 都不会复活旧收据。完成摘要同样携带真实 closed trigger，只有 voice-capture trigger 可二次保存或展示正文；Stack/剪贴板/失败尝试保持 receipt-only。
- 完成 decision-only 剪贴板组调度：DeliveryStack 只提交无正文、绑定 item generation/revision 的 descriptor，并按提交 revision 串行发布；scheduler 以有界背压、稳定 workflow 顺序和 bounded event-ID 去重生成固定 skipped 收据。transient lineage 保存 root 与已访问 workflow 顺序，重复进入或达到 8-hop 上限统一在执行能力判断前记录 `loopPrevented`，且不会把 lineage ID/path 写入收据或诊断。query/insert 失败时不发布 matched/skipped，生产环境明确报告 unsupported，而不是借用户 disabled 掩盖执行能力缺失。退出先并发停所有生产者，再等待 sink 摘除写屏障，最后 drain 已接纳事件；`historyOnly` 不进入调度或 group-event fan-out。
- clipboard item dry-run 已形成完整只读产品路径：持久化条目采用 generation + revision 的 exact version（旧 schema 自动升级），Runtime 从 DeliveryStack 原子解析 content-free subject，privacy-only preparer 使用 clipboard invocation 分类后再次复核版本；UI 的状态、任务与有界 latest-pending 队列归每个 sheet 所有。`Paste / Replay / Replace` 只展示固定中英文类别，不保存正文、路径、端点、凭据或底层错误；没有 Run / Apply / Replace 执行按钮。文本 replay 不会误报 cloud speech；受保护 Webhook reference 无需读取 Keychain 正文即可显示结构化配置状态。
- 真实剪贴板运行入口已补 one-shot capability、exact use lease 与 source replacement CAS：复制 capability 仍共享同一个消耗状态，只有一次调用可进入任何副作用；直接文字/富内容粘贴只消费授权后原子 claim 的版本，Stack mirror 绑定同一 subject，较新条目到达不会形成“预览 A、消费 B”；Replace 只有精确来源仍存在且未变化时才写回，删除、漂移或 ABA 都不会复活或覆盖条目。live Replace 与 dry-run 共用“恰好一个来源替换 action”的封闭基数规则。Replay/Replace 授权还从 DeliveryStack 原子取得不含正文、不可序列化的来源 App identity，并在任何云确认前及目标授权后分别复核来源策略；来源 App 的 cloud/workflow block 不能被当前前台 App 替代。
- 合并重复的“最近结果”与“运行历史”导航：侧栏只保留单一运行历史页，页面内以“最近运行 / 最近结果”分段筛选同一份已加载本地记录与 content-free receipt；菜单栏和 Dashboard 的“最近结果”仍直达结果筛选。最近运行保留失败、取消、跳过、剪贴板与 Stack receipt-only 记录，最近结果只展示 record closed trigger 与同 run receipt 一致的成功语音正文；工作流删除、旧 group metadata、来源缺失或冲突都不能解锁正文。Dashboard 与历史页共用正文预览隐私策略，不改变留存、清理或隐私边界。
- 桌面与发布收口已完成：主窗口改为单实例，失败录音逐条删除和全部清除均有准确确认；普通剪贴板条目的详情、右键与 Delete 入口也统一经过不可绕过的确认，合并条目明确实际删除数量和不可撤销性，文本/输入法编辑与任一 modal 期间父页面快捷键不会外溢。Dashboard VoiceOver 与快捷键限制完整双语化。全局快捷键要求至少两个修饰键并统一拒绝系统/Rill 保留组合，按键 latch 吞掉 autorepeat 和修饰键漂移后的尾部。浮动面板取消后的延迟 auto-hide 任务会立即停止，不再吞掉 cancellation 后继续隐藏；粘贴请求在淡出动画前登记 reservation，动画失效或 shutdown 会恰好一次 abort，已开始的目标恢复/粘贴则由退出屏障排空，重复提交不能落入无结果空窗。统一 modal feature policy 在完整 attached-sheet 验收前关闭 dry-run 与新建分组等全部 SwiftUI sheet 入口。组合根持有全部启动任务；退出先取消并排空启动工作，再把录音与失败音频恢复置为不可逆终止态，随后停生产者和 scheduler、排空事件并 flush 设置、Keychain 凭据、隐私写与 DeliveryStack 状态，最后才等待可能较慢的 WhisperKit 卸载；15 秒超时只取消本次退出，不取消关键清理，晚到回调不能补写或重新启动生产者。App 包含 1024 px 原创图标、完整 ICNS 尺寸和中英文 `InfoPlist.strings`。最终 DMG 在生成后签名并作为外层容器提交公证、staple/validate，再执行 Gatekeeper 复验；测试全程使用假工具，不冒充真实公证。
- 发布门禁会分别检查 Universal executable 的 `x86_64` / `arm64` `LC_BUILD_VERSION`，要求 platform 为 macOS 且 `minos` 精确为 14.0；这不替代 Sonoma 真机运行。只有最终 DMG 的真实公证、staple、validate 与 Gatekeeper 复验全部成功后，脚本才原子生成标准 `Rill.dmg.sha256`，未公证本地包不发布正式 sidecar。Renovate 通过共享 preset 统一更新 Swift 与 GitHub Actions 依赖；非 major 更新只有在锁文件、OSV、NOTICE 与 CI 门禁全部通过后才允许 squash 自动合并。
- 合并页后的隐私与生命周期复审已收口：历史、Dashboard 与活动流共用三态 presentation；受限正文在进入视觉与 AX 前截断为最多 96 个字符，禁用时活动项仅暴露无正文状态。范围改为不夸大完整性的“最近运行”，显示已加载数量、切换后回顶并聚焦摘要，空态可返回 Dashboard。双语技术隐私说明成为仓库与 App 内的同一字节源，装配缺失或漂移会阻断 preflight。EventBus 在构造时同步保留单一 lifecycle stream，AppModel 退出以共享 barrier task 排空初始化后零等待的终态事件，再等待纳入统一 flush 的历史写入；并发 drain 不会悬挂。CandidateResolver 取消、event-tap 中断时 PTT release 和 WhisperKit 跨配置 A/B/A load ownership 也已封闭。
- 主窗口把普通页面切换焦点统一归 MainShell：Dashboard 通过侧栏进入 Clipboard 时，详情页不再在 `onAppear` 抢占搜索焦点，页面也不再拦截 Tab；只有明确点击搜索框才显示强调色焦点。Shell 观察 section/group route；普通路由先清除 stale `FocusState`，再跨到主 RunLoop default mode，避开 mouse tracking 结束后的 AppKit first-responder 覆盖，最后把键盘与辅助功能焦点落到最终侧栏行。相同 route 不抢走详情控件，快速连续 route 只允许最终目的地提交；typed Settings / History 请求仍由目标页聚焦 exact 标题或行。hosted AppKit tests 覆盖向下键、List selection、`NSEventTrackingRunLoopMode` 下主动丢失 first responder、详情焦点回收、相同 route 与连续 route；真实鼠标与完整 VoiceOver 保留在发布 QA。顶层 Clipboard 选择同时清除旧 group 子路由，避免路由回跳伪装成焦点丢失。
- 输出动作取消不再伪装成处理失败：Runtime 以 typed `WorkflowRunCancelledSummary` 贯穿普通运行、Stack、直接 Clipboard 与 Clipboard Replay；正在执行的 action receipt 固定写入 `cancelled`。首个 action 取消产生 `.cancelled(stage: .delivering)`，已有成功副作用后取消产生 `.partiallyCompleted(code: .cancelled)`；Stack/Clipboard lease 以无错误状态归还。生命周期只发布 `runCancelled` 与 info 级、内容无关的 `session.cancelled`，不会发布 `runFailed`、失败 stage 或 `session.failure`。AppModel 清理 active/pending/resolution 而不设置 `lastFailure` 或创建失败历史；失败录音重试会先清理恢复明文并恢复可重试 receipt，再继续传播 `CancellationError`。History 对 action 取消提供固定中英文文案，发布 QA 另覆盖 Shortcuts/Markdown 的成功、失败、取消、退出与临时文件边界。
- 主窗口全局搜索已从宣传项接入真实 shell：`Cmd-F`、菜单命令和工具栏按钮共用 shell-local overlay；AppKit `NSSearchField` bridge 在 macOS 14 上确定性拥有首次/重复 `Cmd-F` 聚焦、方向键选择、`Return` 打开与 `Esc` 关闭/侧栏恢复，不依赖 SwiftUI `.searchable` 的 presentation 和 field-editor 时序。索引稳定覆盖页面、工作流、receipt-first 运行历史与设置分区；多词查询要求全部命中，空查询只展示页面和设置快捷目的地。历史正文索引复用 `HistoryPreviewPresentation`，`full` 使用可见全文、`restricted` 只使用同一份最多 96 字符预览、`disabled` 完全不把正文加入结果。结果选择通过 typed workflow/history/settings request 精确进入工作流编辑器、历史条目或设置分区；Dashboard 与 Diagnostics 的设置入口也改用同一分区路由。
- 失败录音恢复重试现由 AppModel 按 receipt ID 持有 Task：终止开始后拒绝新重试，取消并等待所有活动重试。即使 provider 忽略 cancellation，Task 也会在返回后再次检查取消，不能发布晚到成功；Runtime 会先恢复 durable receipt 并删除解密明文。共享终止屏障随后反复执行全局恢复临时文件 sweep，直到能够证明清理完成；直接删除和 janitor sweep 都失败时，本次 quit 被拒绝而清理继续，不允许把未确认的明文留给进程退出。
- 发布产物改为显式隔离：`scripts/release.sh` 默认输出到 `.artifacts/release/`，并在任何昂贵步骤前失效旧 App/DMG/sidecar；新产物在输出目录同文件系统的私有 `.rill-release.*` staging 中生成、验证，成功后才原子替换。仓库内逻辑路径必须在 `.artifacts/`，解析最近存在祖先后的物理路径也必须留在该边界；公证 snapshot capability 绑定物理输出位置，不能通过 symlink 或替换绕过。preflight 与 prek 执行根目录 hygiene，当前 38 项 release policy tests 覆盖越界、stale artifact、失败清理、staging、物理 symlink/capability、App-only SwiftPM 产品面、WhisperKit 生产信任接线和 arm64 最低系统 witness。
- Secret 扫描除固定 Gitleaks 与双域策略外，还拒绝源码 symlink/非普通文件，在快照外保留 NUL 文件清单；扫描结束后重新枚举 tracked + untracked(nonignored) 源文件并逐字节比对快照，文件集或内容在扫描期间漂移即 fail-closed，必须重试。
- 依赖安全从“有 lockfile”收敛为离线与在线两层：`Package.resolved` 已把 `swift-crypto` 提升到修复 CVE-2026-28815 的 4.3.1；uv 管理的 Python 3.11+ checker 严格解析 lock 与受审 JSON baseline，离线拒绝 `>=4.0.0,<4.3.1`，并用 policy tests 固定边界、malformed/duplicate 处理和当前仓库状态。CI 的 `--live-osv` 对每个 exact lock commit 调官方 `querybatch`，保持顺序映射并只重发带 token 的分页项；网络、重定向、响应/分页漂移或任一 advisory 都 fail-closed。解释器已经在 uv 缓存时，本地 preflight/prek 保持无网可复现；首次缺失时由 uv 按脚本声明准备，不把在线服务可用性伪装成离线构建条件。
- Prompt 变量基础合同已收紧：正文、选区、剪贴板和 App 上下文只存在于不可序列化的瞬态 `PromptVariableContext` / `PromptRenderResult`；渲染器改为单遍 Unicode-scalar 状态机，保持非递归替换和转义语义，并分别限制模板、标识符、变量值、未知变量数与最终输出。可持久化的 `PromptRenderSummary` 只保留 known key 与计数，以模板首次使用顺序作为唯一 canonical 顺序，严格满足 `redacted ⊆ missing ⊆ used` 并拒绝重复、乱序、越界或不可能的 JSON。生产 transformer 仍未接线，不改变功能开放状态。
- 初始设置快照与 UI 修改之间的覆盖竞态已收口：语言、语音参数等标量由 per-key dirty 集合保护，晚到旧快照不能覆盖当前会话选择；工作流库、启用状态、词汇规则和已下载模型属于整表集合，在首次读取完成前同时由 AppModel 与 UI 拒绝 mutation，手动准备和后台预热也不写入不完整清单。派生的 WhisperKit model option 即使 backing string 未变化也会显式持久化；失败录音恢复、留存策略继续在加载期间 fail-closed。
- 全局双 Command 触发改为纯状态识别器：左右或混合 Command 都按“单次按住不超过 350 ms、前次释放到下次按下不超过 350 ms”组成唯一一对；Fn、其他修饰键/按键、鼠标点击、滚轮和 tap 中断都会重置，完成的一对不会与第三次按压重叠。产品入口仍需在 Sonoma Apple Silicon/Intel、两种输入法与 VoiceOver 下完成最终人工证据。
- 模型供应链已升级为多来源 schema v2 fail-closed 合同：每个 Core ML/tokenizer source 独立绑定 HTTPS endpoint、仓库、exact 40-hex revision、许可证表达式、同 revision 证据 URL/hash；manifest 还固定受审的 multilingual logits 大小，layout 与文件分别绑定 source path 和唯一 artifact path。production resolver 只下载 validated manifest 列出的 exact-revision 字节，磁盘流式传输在写入过程中执行上限；来源 host 使用精确白名单，跨来源 redirect 默认拒绝且显式允许时也剥离凭据。单次 DNS 公共地址检查只作为纵深防护，不宣称绑定 URLSession 实际 peer。
- resolver 从 `/` 的 dirfd 开始逐级 `openat(O_NOFOLLOW)` 打开目标根，拒绝祖先链接、宽松权限与扩展 ACL；根目录 `flock` 覆盖回收、容量判断、下载和发布。同一规范化 manifest 复用内容寻址候选；全局最多保留三个候选，24 小时交付宽限期内不删除，容量满则在首个 fetch 前 fail-closed，超期非当前候选按 identity-safe rename 清理，崩溃留下的 partial/quarantine 在持锁后回收。候选随后只按清单复制到当前用户私有、内容寻址、无链接、只读且原子发布的快照；有效快照先离线验证，损坏快照隔离并只重建一次。`openat` / `fstatat` / `O_NOFOLLOW` / `O_NONBLOCK` 拒绝程序化路径穿越、symlink、hardlink、FIFO、额外/缺失文件与 size/hash 漂移。
- verifier 在同一安全读取中保留 `tokenizer_config.json` / `tokenizer.json` 字节；严格本地 tokenizer 只从这些字节构造，不调用 pathname、pretrained 或 Hub fallback。除 manifest / Core ML / 完整 tokenizer ID 空间三方相等外，还固定两种受审 multilingual vocabulary 的 special token、99/100 个语言 token 顺序、全部 printable byte token、空格 ID，以及 OpenAI exact revision 对应的完整 tokenizer/config SHA-256 身份。非 actor-isolated worker 持有 resolve → materialize → verify → tokenizer → runtime 全链，目录与读块都可响应取消；retired generation、缓存替换和 shutdown 共用 drain/disposal barrier。单个等待者可立即取消而不杀死共享加载，runtime lease 会等活动转写释放后再显式 `unloadModels()`。相同规范化 manifest 复用已加载 runtime，避免每次识别重哈整树。manifest bytes 由 release-owned SHA-256 在解析前锚定；production factory 立即验证锚、source/license key set 与 host allowlist，再把 resolver、私有候选和可信快照接到 App 组合根。当前 Apple Silicon 目录固定包含 Breeze ASR 25 与粤语 Distil Whisper Small 两个受信技术预览模型；Settings/工作流只接受这两个精确 ID，历史自定义 repo、token、folder 或不匹配返回身份均 fail-closed。新账户仍默认云端，用户须显式选择本地预览；x86_64 在完成真机验收前保持 unavailable。custom/legacy loader 只保留显式开发 opt-in。
- WhisperKit SDK 已从旧版升级并 exact 固定到 Argmax OSS 1.0.0；arm64 Release 必须在 `ArgmaxCore` 内定义 `Float16 : BNNSScalar` 与 `Float16 : MLShapedArrayScalar` witness，不允许弱链接到 macOS 14 不具备的系统实现。上游两份 manifest 的重复 CLI alias 会触发 SwiftPM Xcode adapter 错误，发布 wrapper 只在核对 exact commit 和原始/补丁后 SHA-256 后临时移除该 alias，构建返回前反向恢复并确认 checkout 干净。上游当前仍产生 BNNS 与 `String(cString:)` deprecation warning；它们不再是最低系统可用性错误，但在官方修复发布后应连同 manifest-only 兼容层一起移除。
- 继续红队修复了静默完整性问题：SQLite v8 的 clear intent 先持久化 `previous → next + intentID` transition，再由三个仓库在 `BEGIN IMMEDIATE` 内 CAS 推进并删除旧 generation。旧 token 即使携带未来时间也被拒绝，新 token 在系统时钟回拨后仍可写入；同 intent 重放幂等，冲突或旧 intent fail-closed，schema 4 pending intent 通过一次性 timestamp promotion 安全桥接。History、receipt 和 diagnostic 的全量与 exact-ID 读路径只承认当前 generation，因此跨表部分完成或崩溃重启时，尚未物理删除的旧代行也不可见；查询同时逐行隔离损坏数据，坏行不占用 limit。Stack 程序化粘贴和本地模型 loader/preload 都成为 terminal shutdown 所有权，退出会等待已开始操作并拒绝新入口。
- trusted loader 已形成稳定产品错误合同：缺少 release trust material、trust root、resolution、integrity、tokenizer 与 runtime 在各自所有权边界映射为固定无 payload 错误，模型词表不匹配归 integrity；取消继续传播为取消，resolver/tokenizer/第三方 runtime 的路径、摘要、令牌与底层消息不会进入 UI 或持久化。预加载失败不再被 `try?` 吞掉，只上报 allowlisted 阶段和固定事件名；token 或 download policy 变化会退休旧 resolution，不能复用过期授权。production App 已接入两个受信技术预览模型；它们已完成当前 Apple Silicon 机器的冷加载和禁网技术转写，但真人阈值、完整人工 provenance/归因与支持机型验收仍阻断 GA。
- 最后一轮产品边界复审补齐了四类易被自动化遗漏的合同：Dashboard、Clipboard、Workflows 与 Settings 的非文本控件使用明确且非空的双语辅助功能标签；历史维护完成后产生的投影读取纳入退出排空，终止开始后不得再启动投影或周期维护；SwiftPM 对外只保留 `RillApp` 可执行产品；WhisperKit 损坏快照最多执行一次受权修复，身份在修复前漂移时不隔离新发布对象。上述项目均有确定性测试，完整 VoiceOver 朗读与真实最低系统行为仍属于人工验收。
- `Append to Markdown` 改为 actor 串行的同目录事务：原文件和临时文件描述符保持到发布结束，现有文件用单次 `RENAME_SWAP`，新文件用排他发布；复制 mode、owner、flags、birthtime 与扩展属性后再刷新 mtime，并对 UTF-8、64 MiB、祖先/最终 symlink、hardlink 和特殊文件 fail-closed。SWAP 后不回滚；可见目标尚未验证为本次完整写入时返回可操作的 publication-indeterminate 并保留两侧现场；一旦目标已通过 descriptor 验证，后续换出名称异常只记固定、无路径的 committed cleanup-indeterminate，绝不诱导用户再次 append。提交后换出旧 inode 的清理由持有父目录与旧文件描述符的 coordinator 接管；瞬时 unlink 或目录 fsync 失败会返回 `committedCleanupPending` 并在调用 Task 取消后继续 identity-safe 重试。生产 coordinator 在 shutdown 起点 seal，并于 event/persistence 屏障前排空。macOS 14 使用不依赖现代 unique flags 的兼容路径；同 UID 且可写父目录的主动命名空间攻击不在当前桌面产品威胁模型承诺内，保留为明确边界。
- Dashboard 的全局输入 readiness 不再把 TCC preflight 当成可用事实：共享 active event tap 的真实安装结果由 StackPasteController 桥接到 AppModel；失败会同时说明 Fn、面板快捷键与 Command-V 均不可用，并在用户授权或返回前台后显式重装。临时粘贴另用独立 raw pasteboard 事务逐 item 保存全部 type/data/order，RTF、自定义 UTI 与多 item 在成功、失败、取消后均无损恢复；Stack mirror 多次替换预览时仍持有首次复制前的 exact archive，停止、暂停或策略变化后恢复原始多 item 表示，用户期间的新复制仍由 change count 优先。History 与 Diagnostics 使用 typed loading/failed/loaded 状态，repository 故障不再伪装成普通空数据，并提供持久双语重试入口。
- 普通 SettingsStore 写入统一归 `SettingsSaveState`：语言、剪贴板、语音、输入、词汇与工作流的标量/集合失败会在 Settings 顶部持续显示受影响分类和数量，固定文案不含底层错误、key 或设置值；内存中的最新 exact 写入可重试，只有成功后才清除。读取改为 per-key 隔离快照：SQLite 解密或损坏只标记对应 key unavailable，完好设置继续恢复且损坏行不改写；隐私、词汇、留存与本地模型准备分别按自身边界 fail-closed，不再由单个坏值把整份设置伪装成默认。隐私、留存与凭据继续保留各自专用状态。菜单栏纯状态项改为静态 Label/Text，不再伪装成禁用按钮。AppModel 的八个剪贴板 mutation 入口由单一任务 owner 同步准入；退出先不可逆 seal，再排空已接受写入，随后才关闭 scheduler、listener 与 persistence，避免 flush 后晚到修改丢失。
- 运行历史从独立的“最近 50 条正文 + 最近 100 条收据”投影升级为单一 `RunHistoryBrowsing` 边界：SQLite v9 为 HistoryRecord 与 receipt 分配共享单调 ordinal，首屏冻结 generation、最大 ordinal、留存 cutoff、scope 与正文访问级别，后续按 `timestamp DESC, entryID ASC` keyset 分页且每页最多 50 条。receipt 仍是主时间线，只有 trigger 一致的语音记录可打开正文；metadata-only 不解密正文/纠错来源，restricted 只返回同一份最多 96 字符预览。清除会使旧 cursor 失效，runID 与 recordID 深链都规范化到可见行；分页失败保留当前页。全局搜索以 250 ms 防抖、50 条批次、20 项上限和 cancellation 扫描完整留存快照，历史故障不影响静态导航结果。
- WhisperKit 手动准备与后台预热统一归进程级任务 owner：用户取消会立即回到 idle，但 provider 即使忽略 cancellation，active 与 retired Task 仍被持有直到真实返回；晚到 progress、model ID、已下载清单或事件不能覆盖 replacement。设置重置、重新准备和 shutdown 都复用同一代际/所有权判断，退出会 cancel 并 drain 全部准备任务；第三方永不返回时按终止策略拒绝本次退出而不是静默遗失任务。
- 用户可见错误与持久诊断继续收口为封闭合同：剪贴板 `latestError` 中央编码为固定错误码并在读取旧状态时重写；Stack Paste、失败录音、实时字幕、Workflow Audio、Captured Audio、隐私规则和持久化 fallback 不再携带 raw `Error`、路径或 payload。临时粘贴已完成投递但 exact clipboard restore 写失败时，固定提示明确“已投递、不要重试”，诊断只记录 `deliveryCompleted=true` / `retrySafe=false`，History sanitizer 不会把它泛化成诱导重复输出的通用重试错误。允许保留的 `localizedDescription` 仅来自封闭枚举，或在进入 UI/History/Diagnostic repository 前再经过对应 sanitizer；未知错误统一映射为固定双语类别。
- 主窗口 Dashboard → Clipboard 的焦点合同完成收口：跨页普通路由继续由 MainShell 持有侧栏 first responder，Clipboard 不在出现时抢占 Search；只有用户主动进入页面内控件时，页内 `FocusState` 才接管。路由替换、mouse-event tracking、连续侧栏方向键和 typed detail 的 hosted AppKit 回归共同固定这一边界，避免把详情页重建误判为用户焦点意图。
- DeliveryStack 的剪贴板状态持久化改为显式可用性合同：不可读、损坏或坐标重复的初始状态 fail-closed，既不采用部分数据，也不覆盖原文件；保存失败保留最新会话状态并进入有上限的退避自动重试，立即重试与后台重试共用同一 authoritative snapshot。退出先 seal 剪贴板 mutation，再排空已接纳操作并执行专用 persistence drain。只有主窗口 Clipboard 显示固定双语 banner：`loadUnavailable` 明确本次会话不持久化，并提供有不可撤销范围说明的 Reset Storage；删除失败时受保护旧行和完整会话状态不变，成功后才原子清空会话图并恢复可用。save failed 继续提供单飞的“立即重试”；浮动 panel 不重复展示。
- Settings 持久化按 collection/scalar domain 分离 fail-closed：集合域在对应读取完成前拒绝 mutation，标量域逐 key 保留 unavailable/dirty 所有权，单个坏值不能把完好设置伪装成默认或触发回写覆盖。设置读取由独立 task owner 追踪 active/retired 工作，终止开始后拒绝新读取并排空既有读取；设置保存同样在 shutdown barrier 前 seal、等待当前 exact 写入与可重试失败状态落定，随后才允许应用退出。
- 全局运行历史搜索失败提供显式 Retry：每次接受重试都会推进 request generation，query、语言、隐私预览、留存和 workflow snapshot 共同构成发布身份；取消、旧 query 或旧 retry generation 均不能发布晚到结果。Retry 从失败态进入 idle/searching 并移除瞬态按钮时，first responder 明确回到全局搜索框，静态页面/工作流/设置结果始终可用。对应 DeliveryStack persistence、Clipboard persistence presentation、Settings domain/scalar/save/read-owner、GlobalSearch retry 与 MainShell focus 的 focused suites 及最终完整 preflight 均已通过。
- 本轮后续审计继续收口了跨表面一致性：菜单栏、Settings 和 Dashboard 的语言/语音路由/输出/长录音写入共用带 scalar-domain 可用性与 shutdown 检查的 AppModel commands，损坏域不再出现会话内变更但无法落盘的假成功。collection 恢复与 privacy 恢复也进入同一 settings-read owner，退出会取消并真实排空它们；隐私恢复不能在终止屏障后重新打开 runtime gate。History 初始加载 Retry 按键消失前按键盘/VoiceOver 通道分别迁往稳定 scope picker；Global Search overlay 同时移除 sidebar/detail/toolbar 的背景交互与 AX，重复 `Cmd-F` 仍只重新聚焦现有搜索框。
- 剪贴板跨组回退不再忽略已保存优先级：Runtime 与 UI 预览共用 Core 排序合同，较小的正数 `fallbackPriority` 先于候选时间，assigned/default 主组仍先于所有跨组回退。持久状态在 actor 任何赋值前验证完整引用图：未知组、缺失条目、跨组重复成员、item/entry 组不一致、悬空 App assignment 及非正/重复优先级全部 fail-closed，不创建 `Recovered Group`、不覆盖原始字节。持久化 debounce 的关键取消测试改为可控 sleeper，不再依赖固定 350 ms 猜测时序。
- 2026-07-13 的官方竞品复核补齐剪贴板容量基线：Raycast 与 Alfred 以按时间留存为主，Paste 让未置顶历史按时间老化且保护 pinned/Pinboards，Maccy 默认按 200 个未置顶条目、界面最多 999 个控制历史规模。Rill 保留既有时间留存，同时把“条目数”和“真实字节/活动语义”分开：schema 7 明确限制 1000 个活动项、每组 500 个活动项、500 个仅历史项、单项文本 1 MiB、图片 32 MiB、编码总量 64 MiB、256 个自定义组和 1024 条 App 路由；非文本条目的隐藏文本、capture tag、工作流/来源/分组/应用元数据同样先做原始形状校验，再进行 JSON/Base64 编码，避免拒绝路径本身放大内存。
- 容量回收只按稳定顺序逐出最旧的仅历史项；活动项与粘贴 lease 从不静默丢弃。App assignment 和带 assignment 的新建组先构造完整非变更 plan，统一校验目标组、总量和受影响租约后再原子提交；失败不会半移动、创建幽灵组或重新激活已消费的历史条目。不可读或超限的持久状态继续保留原始受保护行并进入 `loadUnavailable`，主窗口以明确的 destructive Reset Storage 处理；取消、删除失败、并发 capture/lease 和重复 reset 都有线性化边界。
- 临时富剪贴板 archive 现在按 item、representation、类型名、单表示、单 item 与总字节预算 fail-closed；ImageIO 图片解码/校验及 TIFF → PNG 转换移出 MainActor，同一 controller 只允许一个 worker，同 change count 复用 single-flight，不同 generation 串行等待并在返回后再次核对 change count。精确恢复失败携带新的条件重试坐标并保留唯一 archive；TextInjection 只重试恢复、不重复 `Command-V`，退出先排空内层事务，再停止 StackPaste 并恢复外层镜像。EventBus 使用 head-index 摊销 O(1) 出队，剪贴板快照及其 debug diagnostic 在语义屏障之间各自 latest-wins；StackPaste 只订阅 `bufferingNewest(1)` 的 content-free revision，字幕和其他高频状态投影不跨诊断、终态、receipt 或生命周期屏障。
- 上述新增边界已有 Core/Runtime/App/UI/Platform/Providers 针对性测试。2026-07-13 的最终完整 preflight 已通过固定 Gitleaks 扫描、38/38 发布策略、Universal Release 构建与 App 装配、ad-hoc 签名/资源 App bundle smoke、9/9 NOTICE/归因测试和预检内全量 1439/1439；独立 `swift test --parallel` 同为 1439/1439。`prek validate-config prek.toml` 与 `prek -c prek.toml run --all-files` 均通过。hosted AppKit 回归覆盖主窗口侧栏 Dashboard → Clipboard → History 的连续方向键导航、List selection 与 mouse-event-tracking 时序；修复后的真实鼠标路径、纯修饰键双击、attached sheet、Intel/macOS 14 真实行为与完整 VoiceOver 朗读顺序仍保留人工验收。CI 另在 macOS 14 + Xcode 16.2 运行锁定测试；[GitHub 已宣布 Sonoma runner 将于 2026 年 11 月 2 日停止支持](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-Readme.md)，届时需迁到可证明最低系统兼容性的受支持或自托管 runner。
- 剪贴板持久化 schema 8 已把图片字节从 metadata JSON 拆成受保护的 immutable blob graph；schema 7 图片会原子迁移，metadata 不再包含图片原文或 Base64，重启与 metadata-only 更新保持同一 blob 身份。迁移、完整图校验、容量、lease、原始坏行保留和显式 reset 合同均有 SQLite 集成测试，因此不再把 blob 拆分列为发布前待办。
- 剪贴板置顶已作为独立留存策略接入，而不是复制 Stack / Queue / List 的活动语义：合并条目批量原子置顶，旧持久化状态默认未置顶；自动保留期清理和容量逐出跳过置顶历史，显式删除/清空仍按用户命令执行。主窗口提供置顶/取消置顶、只看置顶、稳定前置展示，以及跨正文、来源 App、标签和分组的多关键词联合搜索；搜索索引固定 16K 字符上限，避免合并历史放大 UI 内存。

### 接下来

当前工作源码面向 `cloud + trusted sherpa-onnx local preview`。公开构建只发布
`arm64` App，并且只暴露/下载 Qwen3-ASR 0.6B INT8；vendored sherpa-onnx/ONNX
Runtime 归档仍保留既有 Universal 来源身份，但其 x86_64 slice 不进入发布产物。固定
Silero VAD v4 已接入单次听写自动端点，确定性白噪声与 Qwen 官方语音 fixture 均通过；当前
Apple Silicon 机器也已完成固定 Qwen archive 的离线技术转写。2026-07-24，系统默认 Xcode 27
从清理后的构建树完成 arm64-only Release；App 与 worker 均只有 arm64 slice、`minos` 为 14.0，
worker 的 ASR/VAD 静态符号门禁通过。2026-07-18 的 Universal 安装仅保留为旧支持范围的历史证据，
不满足当前 arm64-only 候选门禁。后续录音审计又把本地实时层的整段 PCM 累积替换为 consumer-side 增量 WAV：
32-chunk 队列继续 fail-closed，RMS 状态固定为 20 项，正常 finish 排空全部已接纳尾帧，权限等待取消、
readiness 提交竞态和所有 partial-file 失败路径均由 generation/cleanup owner 收口。录音、快捷键、
状态机与焦点联合回归通过 210 项，相关 160 项 Thread Sanitizer 回归无报告，生产 Qwen provider 也再次
跑通固定中英混合 fixture。先前精确 `./scripts/release.sh --install` 的 46 项发布策略、23 项安全、
12 项 NOTICE、1,731 项 XCTest 与 17 项 Swift Testing 全部通过；该旧 Universal 安装
可执行文件 SHA-256 为 `be13eedde7f581ed5abe08ac15fe8f61996dfac055f743ca72cc596c4bf070e3`。启动诊断确认
Qwen/Silero 可用、剪贴板捕获暂停、面板快捷键按偏好关闭而 Fn push-to-talk 保持 active。离线识别阶段仍受
369,600 frame（20 秒请求上限 + 3.1 秒启动容差）硬上限约束并一次加载完整样本；它不再
放大实时/finish 内存，但也不宣称原生 offline API 是恒定内存。已安装 App 的真实麦克风语音检测与自动停止、受控噪声、
实体 Fn 和最终主窗口焦点路径仍须按发布 QA 清单分别验收。新用户仍须显式选择本地
路径。只有适用于该候选 scope 的未完成项才阻断发布，关闭的扩展功能不以未实现状态冒充当前产品缺陷。

1. **公开发布决策与公证验收（P0）**：确定 Rill 自身许可证、公开仓库/下载渠道和可用的私密安全报告路径，取得 Developer ID Application 身份；用真实凭据执行已固定顺序的最终 DMG 签名、公证、装订与干净账户安装验收。本地 Apple Development 与假工具顺序门禁已通过，但不替代真实公证。
2. **真实设备与候选范围 ASR dogfood（P0）**：每个候选只验收实际启用并宣称支持的识别路径。当前公开范围必须完成 sherpa Qwen3-ASR 0.6B INT8 与 MLX Qwen3-ASR 1.7B 8bit 的中文、英文和中英混合 dogfood，并在干净 macOS 账户验证安装、权限、离线重启、自动停止和失败录音恢复。SenseVoiceSmall 不进入公开候选对照；只有产品与法律审核先行批准后，才可在非公开构建中独立评估。
3. **sherpa-onnx 本地预览 -> GA 门禁（P0）**：公开构建的 Qwen3-ASR archive 已固定 URL、字节数、SHA-256 和完整安装 inventory；当前 Apple Silicon 机器已用生产 `SherpaOfflineRecognizer` 完成 Qwen 官方 fixture 技术转写。转为 GA 前仍须完成预先批准的真人多语阈值、真实麦克风/端点/噪声验收、完整人工 license/NOTICE/derivative/base-model provenance 审核、所有声明支持架构与最低系统实机验收，以及模型存储/删除限制的明确产品决策。SenseVoice 只保留固定来源的内部兼容/未来评估身份，在产品与法律审核完成前不得进入公开设置、下载、推荐或发布证据。
4. **唤醒词与 TTS 候选验收（P0）**：生产路径已经改为共享麦克风上的常驻 Silero VAD 与当前本地 Qwen ASR 短语门，不再下载或发行独立 KWS 模型，因此旧 KWS 归档的许可/NOTICE 不再阻断当前候选。共享入口现在显式区分环境唤醒与 Fn/交互识别，后者会立即抢占音频帧并取消唤醒候选；录音结束即恢复环境监听，不再等待 STT、LLM、TTS 或 delivery 终态。助手与实时识别拥有独立协调器和音频处理队列，ASR 与 TTS 也使用独立 worker supervisor，因此助手后处理不会占住下一次 STT。唤醒 ASR 忙时只保留一个最新完整候选并清理被替换的受管 WAV，避免界面显示监听中却整段丢掉下一次唤醒；pre-roll 扩为 0.5 秒以保护首音节。同一语音段若包含“唤醒短语 + 命令”，命令文本会作为一次性内存载荷继续进入同一工作流，跳过第二次 STT；只有唤醒短语时仍播放提示音并进入现有自动录音端点。候选语音使用受管临时 WAV，匹配失败、成功、取消和退出都必须清理且不得进入历史。设置页已增加麦克风、本地 ASR、LLM、云端隐私与语音输出的统一就绪投影；共享 STT/LLM/TTS 资源统一归入“提供商与模型”，音色继续保存在 workflow 输出步骤。已知无效/验证失败的 LLM 配置、未授权麦克风、未准备 ASR 或不可用隐私策略会 fail-closed，缺少本地 TTS 则保留明确的系统语音回退。发布候选仍须完成安静/日常噪声首次检测率、8 小时负样本误唤醒、30 次连续普通 Fn 不误触发助手、30 次连续“唤醒词+命令”、助手 LLM pending 时并发 Fn 识别、ASR 背压下的连续候选、空闲 VAD CPU/内存、每个语音段触发 Qwen 的延迟与功耗，以及真实扬声器、耳机、内建麦克风和最低 macOS 验收；TTS 还须在人耳确认中英文音色、停止、失败不重复朗读和临时 WAV 清理。
5. **组执行扩展（feature-off P1 backlog）**：content-free scheduler、严格 legacy parser、fixed receipt/History 原因、exact item revision、lineage/8-hop cap、execution-surface policy、来源感知且零确认的 non-interactive preflight、one-shot item lease 与 replacement CAS 已完成；生产 `isExecutionSupported` 仍固定为 false。主窗口只读 dry-run 可以使用，但浮动面板入口和所有执行按钮保持关闭。只有完成 workflow-revision-bound 持久 grant、one-shot group action lease、副作用前最终复核与对应人工验收后，才能另行启用；它不阻断当前 feature-off 候选。
6. **最低系统 CI 迁移（P1 deadline debt）**：在 GitHub Sonoma runner 退役前，把 macOS 14 运行验收迁到受支持的等价 runner 或受控自托管机器；arm64 编译不能替代最低系统上的真实运行测试。若届时无法提供 macOS 14 候选实机证据，本项升级为发布 blocker。
7. **Rill -> Spark 远程交互（P1 backlog）**：在当前本地唤醒/STT/TTS 切片通过 dogfood 后，以统一、版本化且传输无关的 `interaction.v0` 把文本任务发往同机或异机 Spark，并消费 Spark/Home Assistant 返回的文本结果或托管语音资源。Rill 继续拥有边缘音频、STT、工作流和播放；Spark 拥有会话、路由、审批与 HA 集成，HA 凭据不得进入 Rill。先证明文本最小闭环，再评估 Omni 音频或 MCP；协议工作跟踪现有 [Spark issue #32](https://github.com/zendev-lab/spark/issues/32)，不创建重复 issue。
8. **Swift 格式门禁（P2 maintenance）**：当前仓库以 4-space 为主但没有受审 formatter 配置，且生成器也固定输出 4-space。本轮功能工作树不做全量机械格式化；后续独立提交应固定 `xcrun swift-format` 与 Xcode 版本，采用明确的 4-space/120-column 配置和按文件 legacy manifest，让所有新文件先进入严格 gate，再分批清空旧清单。不要同时引入重叠的 SwiftLint 维护面。

每次只实现一个可验证切片；完成后更新 `docs/competitive-research.md` 的迭代表，再从官方 release radar 重新评估下一项，而不是按固定功能清单机械推进。

# Rill UI 方向：围绕 Record 流的一体化设计

> 创建：2026-08-15
> 状态：方向已确认；阶段一已实施
> 输入：`SPARK.md`（最终形态边界）、`docs/competitive-radar.md`、`docs/competitive-research.md`、竞品官方文档与当前源码
> 事实优先级：当前源码与测试 > 竞品官方文档 > 产品营销页

## 1. 设计目标

SPARK.md 把最终形态定义为「原生 macOS 边缘语音与剪贴板工作站」：语音识别、
剪贴板采集、跨应用投递和可观察工作流统一为**一条 Record 流**。本轮 UI 设计
的唯一目标，是让界面结构与这条概念主线对齐，而不是继续按工具类型分页。

三条设计原则（每条都有竞品或用户反馈证据）：

1. **听写主循环住在环境层，不住在主窗口。** Wispr Flow 的主界面是浮条；
   Superwhisper 把状态放进菜单栏图标与录音窗；VoiceInk 用 mini recorder。
   主窗口在这些产品里只承担历史、词汇、模式与设置。Rill 已有
   LiveSubtitle 浮窗、RecordPanel 与菜单栏面板，保持这一分层。
2. **主窗口按 Record 流的生命周期组织，而不是按工具类型。** 合并前
   Dashboard / Records / History / Diagnostics 四个页面分别在讲同一条流
   的不同片段，用户已实际反馈过「运行历史」与「最近结果」语义重复
   （见 competitive-research 2026-07-12 行）。
3. **可解释性是 UI 主叙事，不是附属页。** 每次运行能回答「用了什么上下文、
   是否离机、为什么触发/跳过、文本去了哪里」——这是竞品都没有做成主界面
   叙事的能力，也是 Rill 的差异化（competitive-radar 产品判断）。

## 2. 竞品 UI 模式（2026-08-15 核验）

| 模式 | 证据 | 对 Rill 的含义 |
|---|---|---|
| 听写产品的主循环在浮层与菜单栏，主窗口是管理面 | [Wispr Flow 是什么](https://docs.wisprflow.ai/articles/2772472373-what-is-flow)、[Superwhisper 菜单栏图标](https://superwhisper.com/docs/get-started/interface-menu-bar)、[VoiceInk 文档](https://tryvoiceink.com/docs/mode-settings) | 环境层保持现状分层；主窗口不为「开始说话」服务，为「理解与恢复」服务 |
| 用户看到的是任务名，不是引擎 | Superwhisper Modes（Message/Email/Note/Meeting）、Typeless Dictate/Translate/Ask | 侧栏与页面标题使用用户语言（活动/记录/工作流），引擎概念留在设置与工作流编辑器内 |
| 历史是资产，不是只读列表 | [Superwhisper 从历史重处理](https://superwhisper.com/docs/get-started/transcribe-history)、MacWhisper 来源保留、Wispr 失败重试 | 运行时间线继续承担纠错、重试与失败恢复入口；与就绪清单位于同一首页 |
| 剪贴板复用走光标旁短闭环 | [CleanClip](https://cleanclip.cc/)（⌘; 唤起、数字直贴、跟随前台 App）、Paste、Raycast | RecordPanel 的短闭环增强是独立后续阶段，不与主窗口重组混在一起 |
| 状态永远可见 | Superwhisper 菜单栏状态点、各家录音浮窗 | 就绪、失败与进行中状态在首页、菜单栏、浮窗三处语义一致 |

共同信号（与 competitive-radar 结论一致）：用户感知到的完成度来自「开始
可靠、状态明确、结果可恢复、术语命中、输出正确」，而不是入口或模型数量。

## 3. 目标信息架构

### 3.1 三层表面

| 层 | 成员 | 职责 |
|---|---|---|
| 环境层 | LiveSubtitle 浮窗、RecordPanel、菜单栏面板 | 主循环：按住说话、状态可见、记录短闭环复用 |
| 工作站主窗口 | 活动、记录、工作流、设置 | 理解流：就绪、最近活动、路由与回执的解释与恢复 |
| 全局搜索 | `Cmd-F` 浮层 | 贯穿索引页面、工作流、运行条目与设置分区 |

### 3.2 主窗口目标侧栏

```text
活动            ← 合并原 Dashboard + 运行历史：就绪清单 + 实时动态 + 回执时间线
记录集…         ← 对象列表（不变）
工作流…         ← 对象列表（不变）
设置            ← 诊断降为设置内入口打开的高级页
```

- **活动**是 Record 流的用户面：就绪（未就绪时）、失败横幅、待消歧、
  实时动态（transient event feed）与 durable 回执时间线自上而下排列；
  时间线继续提供 scope 切换、搜索、分页、纠错与失败录音恢复。
- **诊断**不再占一级导航。它是 allowlist 清洗后的技术事件页，竞品均不把
  诊断放一级；用户面的「为什么触发/跳过」已由回执时间线承担。诊断页本身
  保留，经设置内入口与全局搜索到达。
- 语音助手（SPARK.md 当前切片）不获得独立顶级页面：它保持为内置工作流，
  其就绪状态并入活动页的就绪清单，资源管理留在设置。这避免重蹈竞品的
  「模式帝国」，也符合 SPARK 的能力边界。

## 4. 统一设计语言（主窗口 + 环境层）

| 决策 | 约定 |
|---|---|
| 卡片分级 | 沿用 `RillCard` 三档（prominent/regular/subdued），不新增第四档；prominent 只用于要求行动的就绪清单与失败横幅。手写 `.quaternary.opacity(...)` 必须就近收敛到 0.2/0.35/0.45 三档并注明档位 |
| 选中态 | 统一用 `rillSelection` 修饰器（`RillSelection.swift`：accent 0.12 填充 + 1pt accent 0.5 描边）；不再各处手写 fill/stroke 参数 |
| 圆角 | 统一走 `RillRadius`（`RillSelection.swift`：card 14 / badge 8 / chip 6 / panel 16），不引入新档位 |
| 状态色语义 | green=就绪、orange=需要注意、red=失败、secondary=中性；环境层浮窗的音量/状态色与主窗口共用同一语义，不另立色板（联网指示：online=green、offline=orange、unknown=secondary）。例外：工作流编辑器节点 tint（事件 orange / 条件 teal / 输出 green）是分类语义，不占状态色 |
| 图标 | 只使用 `RillSystemSymbol` 闭目录；新符号先入目录再用 |
| 动效 | 用户可感知的状态动画一律 spring：默认 `.spring(response: 0.3–0.35, dampingFraction: 1.0)` 无过冲，按压等带用户动量的交互允许 `dampingFraction: 0.8` 轻回弹；装饰性动画必须读 `\.accessibilityReduceMotion` 降级；scrollTo 导航定位保留固定时长 easing；AppKit 浮窗显隐须经 `reduceMotionProvider` 门控 |
| 空态 | 空态大图标统一 `.font(.largeTitle)` + `.imageScale(.large)`，随 Dynamic Type 缩放，不用固定 pt 尺寸 |
| 强调色 | 跟随系统 `accentColor`，不引入品牌主题引擎；品牌色（深墨绿/珊瑚路由节点）只出现在 App 图标与营销面 |
| 双语与无障碍 | 所有用户可见字符串走 `UIStrings`/`L10n` 双语；领域子表按表面拆分：`Localization+Record.swift`、`Localization+HistoryRun.swift`、`Localization+Workflows.swift`、`Localization+Settings.swift`、`Localization+Overlays.swift`、`Localization+RunStatus.swift`（AppModel 层状态/错误文案），不再使用视图内私有双语 helper 或 `language == .english` 行内三元；各子表 key 穷举测试保证「加 key 必须双语填表」；非文本控件的非空 AX 标签由既有 L10n 测试约束；新页面必须维持 shell 持有的跨页焦点合同 |
| 密度 | 环境层 glanceable（一瞥可读）；主窗口 management density（卡片+列表，行内动作优先于浮层） |

## 5. 分阶段计划

### 阶段一（已完成）：活动页合并 + 诊断降级

- 侧栏 `Dashboard` 与 `运行历史` 合并为 `活动`（`StreamView`）：
  就绪清单、失败横幅、待消歧面板、记录状态卡、实时动态、完整回执时间线
  共用一个 `ScrollView`；原 Dashboard 的「最近运行」预览卡删除（与时间线
  重复），历史空态的「回到仪表盘」按钮删除（就绪清单就在同页上方）。
- `HistoryView` 改为可嵌入的 `HistoryTimelineView`：不再持有独立
  `ScrollView`/导航标题，深链滚动由宿主 `ScrollViewReader` 代理完成；
  scope、分页、纠错、失败恢复行为不变。
- 诊断从侧栏移除，设置页底部新增「诊断」入口；活动页的失败横幅与实时
  动态头部保留直达诊断的链接。全局搜索的页面索引同步更新。
- 验证：`MainShellFocusIntegrationTests`、`GlobalSearchTests`、
  `AppModelTests` 的导航与焦点合同改到 `活动` 路由后全绿；完整
  `just test` 通过。

### 阶段二（候选，需数据触发；截至 2026-08-30 门槛未满足）

- 实时动态与回执时间线的去重：先用 dogfood 记录二者的信息重叠度，再决定
  是否把 transient event feed 折叠进时间线的「进行中」区。（仓内无该
  重叠度数据，维持现状。）
- Records 工作区增强（置顶/重命名/`Paste as…`）继续按 competitive-radar
  的条件式 P2 门槛，用复用率与格式失败计数决定。
- 模式模板（原样/干净/正式/翻译）按 competitive-research 3.1 评估，只包装
  已有工作流机制。

### 阶段三

- RecordPanel 光标旁短闭环增强（已完成 2026-08-30）：数字键 1–9 直贴对应
  可见记录（经 `RecordPanelDigitShortcutPolicy` + `useSelectedItem` 既有
  目标锁定链；搜索框聚焦时数字键天然进搜索框），列表行带序号角标；工具条
  新增「仅当前 App」来源过滤（按采集时的 `sourceBundleIdentifier` 匹配
  show 时锁定的前台 App）。仅浮窗模式启用，主窗口 Records 页不变。
- 语音助手状态在浮窗与活动页的呈现（随 SPARK 当前切片验收后评估）。

## 6. 非目标

- 不把主窗口做成 launcher 网格或命令面板；全局搜索保持为浮层。
- 不为语音助手、翻译等建独立「模式」一级页面（避免模式帝国）。
- 本轮不改 Records / Workflows 页面内部的信息架构。
- 不引入品牌主题引擎、自定义配色系统或图标体系之外的视觉资产。
- 不为追平竞品入口数量而增加顶级导航项。

## 7. 参考来源

- Wispr Flow：<https://docs.wisprflow.ai/articles/2772472373-what-is-flow>
- Superwhisper 界面与历史：<https://superwhisper.com/docs/get-started/interface-menu-bar>、<https://superwhisper.com/docs/get-started/transcribe-history>
- VoiceInk 模式设置：<https://tryvoiceink.com/docs/mode-settings>
- CleanClip：<https://cleanclip.cc/>
- 仓内：`docs/competitive-radar.md`、`docs/competitive-research.md` 第 6/9 节、`SPARK.md`

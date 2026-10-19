# 竞品研究保留结论

历史调研：2026-06-17 至 2026-08-12。仅保留当时的产品取舍，具体能力与政策需在
再次决策时重新核验；不以此维护当前功能状态或实现队列。

- 优先改善可靠启停、术语命中、输出正确和失败恢复，以编辑成本与真实复用结果衡量。
- 语音识别、后处理、热词提示、确定性替换和上下文授权各自表达，不合成含糊开关。
- 上下文显式选择；“隐私模式”、本地历史和云端转写属于不同边界。
- Record 复用与可解释路由优先；会议套件、启动器、跨端同步、屏幕 OCR 和通用宏
  不因竞品提供就进入范围。新增能力需有可复现痛点与可度量收益。

少量原始参考入口：

| 来源 | 当时用于研究的问题 |
| --- | --- |
| [Wispr Flow](https://wisprflow.ai/features)、[失败恢复](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions) | 听写主循环与失败后恢复 |
| [Superwhisper 历史重处理](https://superwhisper.com/docs/get-started/transcribe-history) | 同一来源的显式重试 |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | 本地路径、模式与词汇机制的区分 |
| [Alfred Debugger](https://www.alfredapp.com/help/workflows/advanced/debugger/)、[Keyboard Maestro Debugger](https://wiki.keyboardmaestro.com/manual/Macro_Debugger) | 触发原因、执行路径与停止位置 |
| [Paste 留存](https://pasteapp.io/help/control-history-retention)、[Maccy 固定源码](https://github.com/p0deje/Maccy/tree/3fe63ec3a0eabf6605d40c48b3c85b7bf555c86a) | 时间留存、容量与置顶的不同语义 |

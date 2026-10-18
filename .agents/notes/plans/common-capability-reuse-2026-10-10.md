# 通用组件暂缓替换的依据（2026-10-10）

历史检查基线：`main@8ee18d2`。当时约定保持行为、只使用公开 API；不满足
契约的组件暂缓，不依赖内部通知、反射或 fork。以下不是对新版本的评估。

- **快捷键录制**：[KeyboardShortcuts 3.1.0 Recorder](https://github.com/sindresorhus/KeyboardShortcuts/blob/3.1.0/Sources/KeyboardShortcuts/Recorder.swift)
  与 [RecorderCocoa](https://github.com/sindresorhus/KeyboardShortcuts/blob/3.1.0/Sources/KeyboardShortcuts/RecorderCocoa.swift)
  对应提交 `772133d9dbe800fdac0473226822994c5c162c58`。公开 `onChange` 只报告
  保存/清除；取消、失焦与录制开始/结束通过内部通知表达。成功键在 keyDown
  保存并失焦，没有公开 keyUp 控制，无法保证提交按键全部释放前持有全局手势
  暂停 lease。等待公开的完整录制生命周期及释放控制后再评估。
- **文件预览**：[quickLookPreview(_:in:)](https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:in:))
  当时没有公开的禁止媒体自动播放配置，也未保证不自动播放，因此保留
  `RecordQuickLookView` 与公开的 [QLPreviewView.autostarts](https://developer.apple.com/documentation/quicklookui/qlpreviewview/autostarts)
  设为 false。等待公开策略或明确行为保证后再评估。

重新评估仍需验证 Fn/IME、取消/失焦、提交释放、预览切换、Esc、权限生命周期及
输出目标保持；源码检查不代表这些物理交互已经通过。其余已完成的本地化与数据库
工作以 [架构](../../../docs/architecture.md) 和当前源码为准。

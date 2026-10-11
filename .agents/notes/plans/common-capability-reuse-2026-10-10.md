# 通用能力复用：2026-10-10 续接

本记录对应当前聊天确认的四阶段计划：保持行为，只使用公开 API；不符合契约的候选
暂缓替换，不使用内部通知、反射或 fork。交付为 Draft PR 和验证证据，不包含安装、
合并或发布。下面是对 `main@8ee18d2` 的检查结果，后续以实时源码为准。

## 本地化

[#86](https://github.com/zrr1999/rill/pull/86) 已合并，包含 String Catalog、语言资源、
打包和脱离构建目录的验证。本轮保留这些实现，收敛 `EventFeedEntry` 的双语字符串
存储为 `LocalizedStringResource`，让活动记录在展示时解析语言。隐私正文仍单独保存，
模式无关的文案与辅助功能入口只返回不含正文的摘要。

原 `workflowRunError` 的语言参数未被使用，两份活动记录文案都取当前设置语言。
本轮改为保留资源，补充从真实工作流拒绝入口生成事件后切换语言的回归。
保留参数顺序、原有复数规则、不分组的计数和字符串中的百分号。
外部错误详情、用户命名及可信模型清单中的中英文元数据仍属于各自的数据所有者，
不把动态数据伪装成新的固定翻译。AppLanguage 的资源选择不是可删除的文案分支。

## 快捷键录制：暂缓

重新读取 [KeyboardShortcuts 3.1.0 Recorder](https://github.com/sindresorhus/KeyboardShortcuts/blob/3.1.0/Sources/KeyboardShortcuts/Recorder.swift)
（tag 指向 `772133d9dbe800fdac0473226822994c5c162c58`）
及 [RecorderCocoa](https://github.com/sindresorhus/KeyboardShortcuts/blob/3.1.0/Sources/KeyboardShortcuts/RecorderCocoa.swift)。
Binding、`shortcutValidation` 和冲突策略能接入现有存储与校验，但不能满足录制生命周期：

- 录制开始与结束仅通过内部 `recorderActiveStatusDidChange` 通知发布；`onChange` 只报告
  保存或清除，取消和失焦不改变绑定。`RecorderCocoa` 是 final，不能通过子类补生命周期。
- 成功按键在 keyDown 时保存并 blur；事件监视器未包含 keyUp。公开接口无法表达提交
  按键全部释放前继续持有 Rill 的全局手势暂停 lease。
- 用外层点击、焦点猜测或整个设置页的 onAppear/onDisappear 替代精确录制状态，会改变
  键盘进入、取消、设置仍打开时全局手势恢复的契约。

结论基于公开 API 和固定版本源码，未把实际 Fn/IME 验收记为通过，未引入生产依赖或
原型。重新评估条件是上游公开同步录制开始、取消、失焦、结束及提交释放控制接口，
随后再验证完整焦点与手势矩阵。

## 文件预览：暂缓

Apple 的 [quickLookPreview(_:in:)](https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:in:))
公开接口提供选中 URL Binding 和 URL 集合，没有媒体自动播放配置，也没有提供可设置
该策略的底层预览视图。文档未保证媒体不自动播放，因此不能通过计划的硬门槛。
本轮保留 `RecordQuickLookView` 和公开的
[QLPreviewView.autostarts](https://developer.apple.com/documentation/quicklookui/qlpreviewview/autostarts)
设为 false 的实现。没有加入第二条预览路径。

重新评估条件是 SwiftUI 预览提供公开的禁止自动播放策略，或 Apple 明确保证该行为。
之后仍需验证主窗口/悬浮工作区、多文件切换、连续 Esc、访问权限生命周期、缩略图取消、
父窗口及输出目标保持。此次未运行替换原型，未声称这些实机项目已通过。

## 数据库

[#87](https://github.com/zrr1999/rill/pull/87) 已合并，使用固定 GRDB 7.11.1 的单连接
DatabaseQueue。本轮从 main 独立补充提交前取消回归，复用已保存的测试补丁和加密屏障，
检查取消错误、原始密文不变、重启读回不变及同一连接的后续写入成功。
不修改生产事务实现、schema、加密格式、Keychain 身份、依赖或安全基线。

## 验证边界

本次检查时 Mac 锁屏；已安装 `/Applications/Rill.app`（build 104）的签名完整性验证
通过，但它不是本轮候选产物。不会为本任务重新请求钥匙链或安装候选。
Swift 构建与测试沿用共享 `run-exclusive.py` 串行锁。各 PR 记录实际本地检查和当前提交
托管 CI；完整本地门禁的桌面失败必须保留。真实 Fn、IME、VoiceOver、预览交互、
多显示器和最低 macOS 26 的候选实机验收仍未完成。

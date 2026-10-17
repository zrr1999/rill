# 统一服务与 Workflow v1 验证（2026-10-17）

## 范围与环境

- 独立 worktree：`codex/unified-services-workflow-v1`，基准 `18b1263e41d21968ab819f036f8663712a27d21d`。
- macOS / Apple Silicon；Swift 6.4、Xcode 27。所有 Swift 构建与测试通过仓库 `scripts/preflight.sh` 包装器。
- 本轮完整替换旧 Workflow 格式与执行入口，不升级旧用户文件。原有历史、音频与回执不由格式切换清理。

## 已执行证据

- 完整领域测试通过；覆盖严格 codec、内置资源、三档能力、旧配置拒绝、冻结绑定、运行与 Record 事务。
- 受控用例验证输出全关、部分成功、可选 LLM 跳过、可选 Decision 缺失、状态文件身份与冲突、文本输入与 Record 输入入口隔离。
- `just check`（prek）与 `just docs` 通过。
- 中英文、明暗与紧凑设置/输出选择截图导出到本 worktree 忽略目录 `.artifacts/ui-workflow-v1/`。截图只证明渲染状态，不证明物理交互。
- 独立只读复核发现并修复了输出选择重复应用、启用状态落盘、实时隐私门控、兼容端点能力准入与 Record 输入源错误等问题。

- 完整 `RILL_RECORD_STRESS=1 just ci` 的仓库与领域阶段通过；原生阶段发现旧标题预期与锁屏依赖失败。旧标题/排序预期随后修正并复测通过。
- 复用 preflight 的原始 `run_performance_swift_tests` 与 `check_release` 阶段单独执行：一万条记录存储与面板验证通过（40 秒），Release 构建、真实 App 内置资源加载、签名结构与输入法产物检查通过（186 秒）。这些分段结果不代表完整 CI 已通过。
- TTS 的系统路径与本地模型选择以类型化绑定冻结；受控测试确认 system 绑定不尝试当前本地模型，可选 LLM 与关闭的 speak 输出不阻止唤醒就绪。
- 外部 AX 树与面板焦点用例归入 `testDesktop`，保留全部断言并加入独立桌面先决探针；完整 CI 仍执行该组，锁屏是失败而非跳过。

- 最后一轮完整门禁通过仓库（62 秒）、领域（60 秒）、原生（116 秒）与压力（35 秒）阶段；桌面组 8 个用例均在锁屏先决探针失败，完整命令退出 1。没有将其记录为完整 CI 通过。

- PR 首轮 Sonar 报告一处重复 locale 合并分支与迁移测试的重复率问题。删除无效分支，提取 112 处相同的三步音频夹具和五个诊断 double 的维护拒绝实现；独立逐项展开复核确认行为及断言等价。模块边界、完整领域与原生测试随后再次通过，未调整质量门禁阈值。

## 原生验收边界

2026-10-17 原生测试首次运行时，电脑控制工具明确返回 Mac 已锁定；辅助功能窗口枚举无窗口，桌面先决探针无法取得焦点，待发面板测试同样出现焦点相关失败。该轮不计为桌面验收通过。需要在解锁、无竞争 UI 自动化的桌面重跑。

下列物理用例仍需在目标产物上人工确认：

1. Fn 按住/松开及取消；ASR 与可选 Decision 缺失时的真实录音流程。
2. 中文 IME 组合输入期间的焦点、编辑与投递。
3. 跨应用插入的目标冻结、焦点切换、已保存后插入失败的部分成功回执。
4. VoiceOver 对四类服务与自动/可选输出开关的实际朗读与键盘顺序。
5. 本地 TTS 的真实可听输出；本地构建不等同于发布产物签名、公证与 Gatekeeper 验收。

不使用真实供应商凭据执行外部模型请求；请求参数与能力错误通过受控 transport 验证。

## 后续确认：单字段版本头与完整窗口

- 用户确认新 TOML 只使用 `schema_version = 1`，替换此前的 `format` / `version` 双字段；旧 pipeline、版本 2/3、缺失或错误类型的版本头仍拒绝执行。内置资源、模板、Schema 和文档同步修改。
- 定向 codec、文件存储与输出状态测试通过（9 个 XCTest、20 个 Swift Testing 用例）；`just check` 和 `just docs` 通过。此前 `408aa71` 已在解锁桌面完整通过 `RILL_RECORD_STRESS=1 just ci`，包括 8 个桌面用例；后续 head 的完整门禁以 PR 当前检查为准。
- 通过仓库包装器构建 Release App，父提交 `408aa71`，工作树含本次格式修改；构建回执源码指纹为 `c1d418014c5c5d95c313d959d826f20a15e4825979b036f960f98de2240834e9`。截图来自这个真实运行的 App，而非单独控件的渲染。
- 使用本机既有 Apple Development 身份签名测试副本，未安装。仅在副本 Info.plist 设置 `CFFIXED_USER_HOME` 与 XDG 配置/状态目录，数据库、模型缓存和工作流均实际落在 `.artifacts/schema-version-1-native/profile/`。未修改凭据或系统授权，未执行云端配置验证。
- 实际打开设置和工作流页；关闭可选的直接输入输出后，两处 UI 均显示关闭，自动保存输出仍不可关闭。检查测试目录生成的 TOML 为 `schema_version = 1`，相邻状态文件的 `outputs.deliver` 为 false。
- 完整窗口截图保存在 `.github/pr-screenshots/workflow-v1/`：`settings-services-zh.png` 展示四类服务及侧栏；`settings-output-choices-zh.png` 展示 Fn 输出设置；`workflow-detail-zh.png` 展示工作流列表、处理步骤和输出状态。均为未裁切、未拼接的电脑控制工具截图；凭据字段保持掩码，画面不含私人记录。
- 截图前退出原安装版，截图后退出测试副本与 worker，再恢复 `/Applications/Rill.app`，回到原先的语音与模型设置页。物理 Fn、IME、跨应用投递、实际 VoiceOver 和可听 TTS 仍未在此轮验证。

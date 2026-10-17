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
- 此轮三张完整窗口截图随后由下述独立服务页的实拍替换。截图不裁切、不拼接，凭据字段保持掩码，画面不含私人记录。
- 截图前退出原安装版，截图后退出测试副本与 worker，再恢复 `/Applications/Rill.app`，回到原先的语音与模型设置页。物理 Fn、IME、跨应用投递、实际 VoiceOver 和可听 TTS 仍未在此轮验证。


## 后续确认：四个同级服务页面

- 用户指出原 UI 分类仍与引用方案不同；设置从“语音与模型”长表单改为“模型服务”分组下的 ASR、Decision、LLM、TTS 四个同级页面。唤醒监听与语音助手就绪检查归入“输入”，服务设置继续共享原 AppModel 与持久化所有者。
- 搜索、Jev 凭据与助手配置动作各自进入 Decision / LLM 页面；删除旧导航枚举和标签。DESIGN.md、UI 方向、用户指南、位置参考与原生验收清单同步修改。
- 外部 AX 树回归捕获隐藏页面仍暴露控件的问题；明确包含当前页面子元素、忽略隐藏页面子元素后，中英文四页隔离测试通过。保留真实窗口焦点断言，未删除或放宽桌面先决检查。
- 仓库包装器构建的 Release App 以 `42c5864` 为父提交，工作树包含本次 UI 修正，源码指纹为 `801e973cc8ae51adfabd7cba322b8291257c47e1bc3aaf8bac26b12f4513e0b3`。签名与独立目录做法同上，实际配置与 SQLite 均位于 `.artifacts/model-service-navigation-native/profile/`。
- 实际点击四个侧栏入口、助手“配置并验证 LLM”、⌘[ 返回和 ⌘, 重开；英文与中文标签完整。关闭直接输入后，设置与工作流页都显示同一状态，自动保存保持启用且不可关闭；相邻状态文件仅存 `outputs.deliver = false`，TOML 使用单字段 `schema_version = 1`。
- 新实拍位于 `.github/pr-screenshots/workflow-v1/`：`settings-asr-zh.png`、`settings-decision-zh.png`、`settings-llm-zh.png`、`settings-tts-zh.png`、`settings-tts-en.png`、`settings-output-choices-zh.png` 和 `workflow-detail-zh.png`。七张均包含完整窗口、侧栏、标题和用户当前可见内容，未裁切、未拼接。另有中英文、明暗与紧凑的受控渲染证据；其性质与真实 App 实拍分开记录。
- 测试副本和 worker 已退出，原安装版已重新启动并恢复到原模型设置位置。没有安装新产物、变更凭据或系统授权，也没有执行云端验证请求。物理 Fn、IME、跨应用投递、实际 VoiceOver 和可听 TTS 的未验证边界保持不变。
- 当前代码的完整 `RILL_RECORD_STRESS=1 just ci` 及托管门禁按后续提交的实际结果记录于 PR；此前 head 的绿色检查不作为本次修正的验收。

## 桌面测试宿主隔离修复

- `e617323` 的完整门禁通过仓库、领域、原生和压力阶段，桌面组 8 个通过，输出开关用例的普通面板先决检查失败；该轮不记为完整通过。
- 桌面仍可由电脑控制工具正常读取。按“词库窗口 → 输出开关”稳定复现，诊断发现测试主动切换 XCTest 宿主的 activation policy 后，前一窗口关闭使宿主从 active 变为 inactive；后一普通面板可见且可成为 key，却未取得焦点。
- 删除测试对宿主 activation policy 的修改，保留外部 AX 所需的 `finishLaunching()`，并让输出开关用例独立初始化 AppKit。四类服务、词库窗口和输出开关三个用例按原顺序通过。临时诊断输出已移除；未修改先决探针、超时或任何焦点/AX 断言。
- `just test-desktop` 完整 9 个用例通过，包含四类服务隔离、词库确认、输出开关与真实面板焦点。完整预检继续在修复后的提交验证，以 PR 最终 head 的实际结果为准。此修复仅影响测试宿主，服务页面与实拍中的产品代码不变。

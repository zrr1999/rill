# 工作流

工作流把触发、输入、处理和输出组织成可复用配置。基本听写无需自行编写工作流；
需要调整输出或组合步骤时，再从内建模式或模板开始。

## 启用与编辑

“工作流”页可以启用、停用、新建、导入和打开文件。Rill 使用外部文本编辑器维护 TOML，
不提供内置源码编辑器。新建和导入的文件默认停用，检查步骤与输出目标后再启用。

默认文件位置为 ~/.config/rill/workflows/，备份为 ~/.local/state/rill/workflows/。
如配置了有效的 XDG_CONFIG_HOME 或 XDG_STATE_HOME，使用相应目录下的 rill/workflows/。

保存有效文件后，下一次运行使用新配置；正在运行的任务保持原配置。
无效文件会显示错误并阻止对应工作流运行，修正后再试。需要恢复时，
用外部编辑器核对备份内容；恢复内建预设会移除该预设的自定义覆盖。

## 运行与输出

音频工作流从配置的触发器或运行按钮启动。文本工作流的“运行剪贴板文本”
是一次显式读取，仍会经过隐私检查及需要的云端确认。

步骤按 TOML 顺序执行，输出也按顺序执行。建议先保存记录，再复制、输入或朗读：
后续输出失败时，先前成功保存的内容仍可找回。失败会停止后续输出，
不会自动重放已经完成的复制、输入或外部动作。

内建听写和智能整理已采用先保存、再输入；语音助手先保存回答、再朗读。

## 示例：整理空白并复制

把下面的内容保存为一个 .toml 文件，然后导入或放入工作流目录。先保持停用并检查内容。
复制成另一个工作流时，用 uuidgen 生成不同的 id。

~~~toml
schema_version = 2
id = "54B31E01-96AC-4A0F-BB82-0A8CB12DD629"
name = "整理并复制"
enabled = false

[trigger]
kind = "manual"

[input]
kind = "text"

[[process]]
id = "clean"
kind = "normalize-whitespace"

[output]
strategy = "immediate"

[[output.actions]]
id = "save"
kind = "record.store"

[[output.actions]]
id = "copy"
kind = "system-clipboard.copy"
~~~

## 深入配置

[工作流 TOML 参考](workflow-toml.md)解释字段、条件、处理步骤和输出。
也可以下载[条件示例](examples/conditional-workflow.toml)和
[JSON Schema](schemas/workflow-v2.schema.json)。

运行详情显示本次使用的步骤与结果。record_duration 可选择计时；
没有测量的数据不应当作零耗时或估算值。错误恢复见[排查问题](troubleshooting.md)。

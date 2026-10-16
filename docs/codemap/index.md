# 交互式代码地图

[打开 Rill 代码地图](codemap.html) · [结构数据](codemap.json) · [证据锁定清单](codemap.lock)

地图按 19 个源码模块与一个外部依赖组组织，首屏不展开底层文件。
选择模块查看职责、上游、依赖、下游影响、源码和相关测试声明。搜索支持模块名和文件路径；
切换“Runtime data flow / Build dependencies”区分运行数据流与编译依赖。

## 从任务理解边界

- **本地模型听写到输入**：麦克风与授权 → 工作流 → 独立语音进程 → 保存记录 → 目标应用。
- **复制到复用**：被动剪贴板观察 → Record 图与持久化 → 显式投递。
- **智能整理**：已授权工作流 → 配置的 LLM 服务 → 终态回执与历史。
- **独立输入法**：输入源进程 → Rime → 组合与提交；不依赖主 App 运行。

关系箭头表示明确标注的调用或数据方向，不代表所有箭头都是 Swift import。
SQLite 的连接与事务归 RillPersistence，图与成员关系归 RecordStore；注入由 AppBootstrap 完成。

## 本地使用与证据

直接用浏览器打开仓库中的 `docs/codemap/codemap.html`，无需服务器、网络或安装依赖。
若宿主禁止 file URL，使用已有浏览器手动打开文件；不关闭安全保护。
本地文件视图给出仓库相对链接与 commit 固定的 GitHub 链接；文档站只显示后者，避免链接到未发布的源码。源码必须与 lock 中 hash 相符，
否则只能作为历史参考。测试列表是实际声明索引，不是测试通过记录。校验还覆盖完整 Tests 文件清单，新增、删除或修改测试文件都会使旧 lock 失效。

使用“View selected module details”可直接跳到详情；从流程或关系跳转模块会清除搜索过滤并将键盘焦点移到详情。

在仓库根目录运行：

```sh
python3 scripts/codemap.py check
# 审核并更新 JSON、模板或源码证据之后重新生成
python3 scripts/codemap.py build
```

维护实现见 [架构文档](https://github.com/zrr1999/rill/blob/main/docs/architecture.md)与
[文档站维护](https://github.com/zrr1999/rill/blob/main/docs/documentation.md)。
麦克风、Fn、粘贴、VoiceOver 和输入法真实验收仍按仓库发布检查表执行。

这两个开发文档按站点收录边界保留在仓库，网页链接查看 main 版本。

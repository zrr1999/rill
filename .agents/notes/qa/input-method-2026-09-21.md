# 输入法迁移一致性记录（2026-09-21）

历史开发产物源码树：`9456c431488695007981602537c16bb900b46026`；冻结基线树：
`17fad434074215af2b22406899dba3a03cea997b`。以下仅证明该候选与样本的迁移一致性。

Squirrel 暂停 0.27 秒以复制快照，随后恢复；部署和回放均使用私有副本，未改动
实时源目录或输入源选择。两路都使用打包的 Rime 1.16.0；导入副本重新部署。

| 比较 | 结果 |
| --- | --- |
| 完整 userdb | 8 个文件，前后 SHA-256 相同 |
| 读音/词条行与 `c`、`d`、`t` 值 | 46,176 行一致，45,895 个不同词条 |
| 固定输入的候选顺序、preedit 和上屏文本 | 8/8 一致 |
| 比较后冻结输入副本 | 未变化 |

输入：`nihao`、`shurufa`、`jianqieban`、`yuyinshibie`、`gongzuoliu`、`zhongwen`、`ceshi`、`rill`。
本地结果：`.artifacts/input-method/profile-validation/migration-report.json`。

后来仅使用 Rill 打包共享数据的导入复测也得到相同文件、行与回放结果，见
`.artifacts/input-method/independent-validation/migration-report.json`；这不证明
轻量默认词库与个人词库的排序相同，也不证明任意输入或当前候选均等价。
复现入口与物理 IMK 验收见 [输入法工程](../../../docs/input-method-development.md)。
此处没有真人热词质量、跨应用输入、VoiceOver 或发布信任验收结论。

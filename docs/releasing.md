# 发布 Rill

Rill 的正式版本由 Git 标签决定。开发构建使用 `0.0.0-dev+<commit>[.dirty]`；
只有干净源码的 HEAD 精确对应唯一 `vMAJOR.MINOR.PATCH` 标签时，打包脚本才使用
该版本号。更新开发工具或依赖版本不会自动发布新的 App 版本。

## 准备候选版本

1. 将候选功能通过 PR 合入 `main`，确认不存在尚未纳入的工作区改动。
2. 明确版本号、支持的 macOS/硬件、启用的语音模型以及已知限制。
3. 确认许可证、安全报告渠道和 GitHub Actions 均可用。启用主分支保护，要求
   `Required CI`、`PR message`、`Commit messages`，并限制直接推送和绕过。
4. 从候选提交运行 `just ci`、`bash scripts/check_commit_messages.sh` 和
   `uv run --script scripts/check_dependency_security.py --live-osv`。
   保存日志、版本信息和预期跳过项，并确认该提交的 GitHub CI 通过。
5. 维护者授权发布后，为该提交创建并推送唯一的语义版本标签。

如果 GitHub Actions 因账单或额度未启动，或者当前计划无法启用主分支保护，
先处理账户条件并复核实际运行结果。仓库中的 YAML 文件本身不证明服务端门禁生效。

## 签名、公证和验收

在维护者 Mac 上使用 Developer ID Application 证书和 Keychain 中的 notary profile：

```bash
SIGN_IDENTITY="Developer ID Application" \
  NOTARY_PROFILE="Rill" \
  bash scripts/release.sh --notarize
```

脚本会从标签提交创建隔离源码快照，完成预检、构建、签名、DMG 公证、staple 和
Gatekeeper 复验。成功后在 `.artifacts/release/` 产生最终 DMG 和
`Rill.dmg.sha256`。凭据只保存在维护者 Keychain 或发布环境的 secret 存储中。

复制 [发布验收清单](release-qa-checklist.md)，记录同一最终包在最低支持系统、
当前支持系统和干净账户上的结果。验收包含真实下载后的 Gatekeeper、权限拒绝和
恢复、物理 Fn、中文输入法、跨应用文本/图片/文件投递、VoiceOver、模型离线使用、
数据迁移及退出排空。每次重新构建、签名或更换模型后重新确认包身份和受影响项。

## 对外发布

验收通过后，由维护者创建对应标签的 GitHub Release，上传最终 DMG 和校验文件。
Release notes 应说明新增行为、最低系统、模型下载需求、升级限制、已知问题和
安全报告入口，并链接该候选的验证记录。下载入口应指向已发布的实际产物。

首次发布前不要把 Apple Development/ad-hoc 签名的本地包描述为已公证安装包。
此仓库尚未实现自动更新；升级由用户下载新的受信任安装包完成。

## 升级、迁移和卸载

- 升级前退出 Rill，保留需要的数据，再安装经过签名和公证的新版本。
- 数据库迁移以候选版本的源码和测试为准；已经迁移的数据不承诺能被旧版 App
  读取。撤回下载与代码回滚不等于持久数据可以降级，Release notes 必须说明边界。
- 卸载 App 不会自动清理全部历史、模型或 Keychain 条目。先使用设置中的分类
  清理和凭据控制，再退出并移除 App；具体数据行为见 [PRIVACY.md](../PRIVACY.md)。
- 发现发布缺陷时先停止推荐受影响版本、明确影响范围和恢复方式，再验证替代包。
  保留原标签与校验记录，不用覆盖历史产物隐藏版本差异。

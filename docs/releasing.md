# 发布 Rill

Rill 的正式版本由 Git 标签决定。开发构建使用 `0.0.0-dev+<commit>[.dirty]`；
只有干净源码的 HEAD 精确对应唯一 `vMAJOR.MINOR.PATCH` 标签时，打包脚本才使用
该版本号。更新开发工具或依赖版本不会自动发布新的 App 版本。

## 准备候选版本

1. 将候选功能通过 PR 合入 `main`，确认不存在尚未纳入的工作区改动。
2. 明确版本号、支持的 macOS/硬件、启用的语音模型以及已知限制。
3. 确认 [AGPL-3.0-only 许可证](../LICENSE) 和对应源码交付准备完毕，
   [SECURITY.md](../SECURITY.md) 中的私密报告渠道已可用，GitHub Actions 实际运行成功。
   启用主分支保护，要求
   `Required CI`、`PR message`、`Commit messages`，并限制直接推送和绕过。
4. 从候选提交运行 `just ci-clean`、`bash scripts/check_commit_messages.sh` 和
   `uv run --script scripts/check_dependency_security.py --live-osv`。
   保存日志、版本信息和预期跳过项，并确认该提交的 GitHub CI 通过。
5. 维护者授权发布后，为该提交创建并推送唯一的语义版本标签。

如果 GitHub Actions 因账单或额度未启动，或者当前计划无法启用主分支保护，
先处理账户条件并复核实际运行结果。仓库中的 YAML 文件本身不证明服务端门禁生效。

## 签名、公证和验收

在维护者 Mac 上使用 Developer ID Application 证书和 Keychain 中的 notary profile：

首次配置时，通过交互式命令将公证凭据保存在 Keychain：

```bash
xcrun notarytool store-credentials Rill \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID"
```

然后从已授权的版本标签构建：

```bash
SIGN_IDENTITY="Developer ID Application" \
  NOTARY_PROFILE="Rill" \
  bash scripts/release.sh --notarize
```

脚本会从标签提交创建隔离源码快照，关闭 worker 缓存并执行干净预检；装配前的
增量复核保留已验证的 Release 产物，再完成签名、DMG 公证、staple 和
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

同时提供与该版本一致的完整对应源码、锁定依赖及构建安装说明，在二进制下载入口
清楚标注源码获取方式，并确认下载者无需私有仓库权限即可取得。
仅给出当前私有仓库的链接不满足这个交付步骤；GitHub 自动生成的源码归档也需要
核对是否包含构建所需的文件以及依赖源码的获取信息。
App 装配会原样附带 `LICENSE`、包含版权与许可声明的 `README.md`、隐私说明和
第三方 notices；预检会检查实际装配结果。

首次发布前不要把 Apple Development/ad-hoc 签名的本地包描述为已公证安装包。

## 迁移与撤回

- 用户升级和卸载说明集中在 [README](../README.md#升级与卸载)，有变化时同步更新。
- 数据库迁移以候选版本的源码和测试为准；已经迁移的数据不承诺能被旧版 App
  读取。撤回下载与代码回滚不等于持久数据可以降级，Release notes 必须说明边界。
- 发现发布缺陷时先停止推荐受影响版本、明确影响范围和恢复方式，再验证替代包。
  保留原标签与校验记录，不用覆盖历史产物隐藏版本差异。

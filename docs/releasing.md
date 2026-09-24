# 发布 Rill

Rill 的正式版本由 Git 标签决定。开发构建使用 `0.0.0-dev+<commit>[.dirty]`；
只有干净源码的 HEAD 精确对应唯一 `vMAJOR.MINOR.PATCH` 标签时，打包脚本才使用
该版本号。更新开发工具或依赖版本不会自动发布新的 App 版本。

## 准备候选版本

1. 将候选功能通过 PR 合入 `main`，确认不存在尚未纳入的工作区改动。
2. 明确版本号、支持的 macOS/硬件、启用的语音模型以及已知限制。
3. 确认 [AGPL-3.0-only 许可证](../LICENSE) 和对应源码交付准备完毕，
   [SECURITY.md](../SECURITY.md) 中的私密报告渠道已可用，GitHub Actions 实际运行成功。
   按[贡献约定](../CONTRIBUTING.md#提交与-pull-request)核对仓库 rules 中的检查要求，
   并限制直接推送和绕过。
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

## GitHub Release 草稿

维护者本机是当前发布入口：Apple 签名和公证凭据留在 Keychain，GitHub CLI
负责上传。暂不复制一套云端构建或自动导入证书的流程。参考
[Spark 的草稿发布流程](https://github.com/zendev-lab/spark/blob/main/.github/workflows/cd-publish.yml)
与 [Cue 的版本准备流程](https://github.com/zendev-lab/cue/blob/main/.github/workflows/cd-release.yml)，
Rill 将候选构建、草稿上传和人工公开发布分开；版本仍以现有 Git 标签为准。

安装 `gh` 并登录有仓库 release 写权限的账号。把[发布说明模板](release-notes-template.md)
复制到仓库外或被忽略的 `.artifacts/` 中，填写版本变化、限制和待完成的验收项。
确认当前检出已推送的版本标签后，运行（版本号和路径替换为本次候选）：

```bash
SIGN_IDENTITY="Developer ID Application" NOTARY_PROFILE="Rill" \
  just release-github v1.2.3 /absolute/path/release-notes.md
```

此命令会实际提交 Apple 公证并写入 GitHub，只有维护者授权本次候选后才执行。
它先核对干净 HEAD、本地标签与 GitHub 标签的 commit，拒绝已有 Release，
随后调用 `scripts/release.sh --notarize` 完成现有全量预检、构建、签名与公证。
上传前再次核对 HEAD、远端标签与 SHA-256；[GitHub CLI](https://cli.github.com/manual/gh_release_create)
的 `--verify-tag --draft` 确保不自动造标签、不直接公开发布。
目标仓库明确为 `zrr1999/rill`，fork 维护者需要先修改脚本中的目标。

每次构建保存在独立的 `.artifacts/release/github-<tag>.<suffix>/`，包含本次
`release-notes.md`、`Rill.dmg` 与 `Rill.dmg.sha256`。测试通过不代表已经跑过
真实 Developer ID 公证；本入口尚需维护者用真实凭据验证。

### 上传失败与重试

失败时保留候选目录。先在 GitHub 检查该标签是否留下草稿及已上传的文件；
不要直接覆盖资产或删掉已公开的版本。若只有上传失败，可在核对草稿的标签、
本地 DMG 校验和以及已有资产一致后，用 `gh release upload` 补传缺失文件，
不要使用 `--clobber`。如果创建草稿本身失败，可用 `gh release create` 的
`--verify-tag --draft --notes-file` 上传同一候选，避免为网络失败重新公证。
若需要重新构建，应先由维护者处理旧草稿，再重新验收新产物。

## 对外发布

从草稿下载同一 DMG 和校验文件，在下载目录运行 `shasum -a 256 --check Rill.dmg.sha256`。
完成上述真机验收后，补齐草稿中的证据链接和升级限制，再由维护者在 GitHub
点击 Publish release。草稿生成不会代替这一步。
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

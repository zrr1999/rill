# 构建性能历史测量（2026-09-21）

Mac17,9 / 64 GiB，macOS 27.0 26A428，Xcode 27.0 27A5228h / Swift 6.4。
源码基线 `cb5bff3`，干净门禁在 `c900a1a` 运行；随后 `94432e2` 收紧缓存输入复核，
其间未改 Swift 源码、Package 或锁文件。此记录不代表当前构建速度。

| 场景 | 总耗时 | Release 耗时 | Release 编译任务 | worker/MLX 任务 |
| --- | ---: | ---: | ---: | ---: |
| `just ci-clean`，worker 缓存关闭 | 402.8 s | 214.36 s | 686 | 204 |
| 随后源码无变化的 `just ci` | 104.4 s | 2.52 s | 0 | 0 |
| 新 worktree 修改 UI/App 资源，worker 命中 | 99.0 s | 72.69 s | 12 | 0 |
| 同 worktree 再修改 UI，worker 命中 | 50.6 s | 40.23 s | 2 | 0 |

冷构建仅清当前 worktree 产物，保留依赖下载缓存；样本只有一轮，且有其他构建竞争，
不能承诺稳定加速比例或 GitHub CI 收益。任务数统计 CompileC、CompileMetalFile、
SwiftDriver Compilation，排除 Compilation Requirements；不是源文件数。

真实 worker 缓存条目 109,597,296 bytes；独立分项测量：输入身份计算 0.7225 s、
完整性校验 0.0465 s、依赖 checkout 核验 0.7514 s。分项不等于完整命令开销。
两个同键 worktree 同时命中，worker SHA-256 相同、App 各自构建；修改后的 App/资源
通过回执逐字节核对。原始日志与 JSON：`.artifacts/build-performance/`。

当时本地开发签名 App/DMG 的 `release.sh --preflight` 用时 133.6 s，Release
编译任务为零；未安装或公证。现行构建命令、缓存失效与并发约束见
[开发参考](../../../docs/development.md)。

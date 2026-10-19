# ASR 与 Record 历史测量（2026-09-25）

设备：M5 Pro / 64 GiB，macOS 27.0（26A428），本机 Qwen3-ASR 0.6B 8-bit。
3 条合成录音（英文、中文、静音），各重复 3 次；未用麦克风、云服务或真实粘贴。

## Release worker

每条件 n=9；P50/P95 为 worker 请求 ms，RSS 为该进程生命周期最大值。

| 条件 | P50 | P95 | RSS MiB |
| --- | ---: | ---: | ---: |
| cold-model | 916.2 | 1013.5 | 1397.0 |
| cold-process | 987.7 | 4335.4 | 1108.6 |
| first-inference | 110.7 | 137.8 | 1391.7 |
| idle-released | 901.9 | 927.2 | 1398.0 |
| idle-retained | 110.0 | 143.4 | 1108.9 |
| preview-agent | 116.8 | 134.5 | 1212.5 |
| preview-realtime | 115.7 | 141.8 | 1212.9 |
| preview-subtitle | 101.0 | 133.6 | 1212.3 |
| warm | 91.2 | 103.6 | 1108.7 |

81/81 成功，27 次最终静音结果均为空。idle 仅测 5 秒闲置后的显式驻留/释放，
预览时间为原始 worker 事件。源为 `8a1dce29d0fabea7b72a03b5e442382109f9c5c5`
后的工作快照，指纹 `fb679fea8120660562f88fe8f60325316b7a994abaa9ba81f1fd3ef7a399bdad`；
私有原始报告与收据：`.artifacts/asr-lifecycle-2026-09-25/`。

## 最后一次宿主与 Record 测量

候选 `7d5bf87086dccb24714a95b3fcb709e8c507998c`，源码指纹
`d042b6ffecae606dac1a23f0eef05376ea7adcbc0669a84c158cd19e8c1574ab`。
18 次计分成功，另留 1 次热身；12 次有语音保存后派发至隔离端，6 次静音无提交/输出。
下表为 P50 / P95（ms）；原点是宿主准入，first-inference 在模型加载后计时。

| 条件 | 最终 ASR（n=9） | 保存（n=6） | 隔离输出派发（n=6） |
| --- | ---: | ---: | ---: |
| warm | 99.3 / 176.4 | 100.9 / 114.9 | 100.9 / 115.0 |
| first-inference | 125.1 / 153.0 | 135.6 / 155.6 | 135.7 / 155.6 |

warm run：`a6783c88-0c71-4a09-937a-9a43c7db5126`；first run：`b67e52d8-356f-43fc-95e7-61dc876af0a1`。
私有原始报告、热身与收据：`.artifacts/asr-host-final-7d5bf87/`。不同指标样本集不同，不能相减推导阶段耗时。
同候选 Debug Record fixture：10,000 条、520,813,484 bytes；30 次热运行 P95 为
目录快照 10.17 ms、搜索首屏 0.26 ms、面板就绪 55.00 ms；冷目录重建单次 364.86 ms。

以上没有配对质量基线、真人编辑成本或 App+worker 总峰值内存，不能证明性能收益、
用户可见端到端延迟或新默认策略可用。现行方法与缺失证据见 [ASR 评测](../../../docs/asr-evaluation.md)。

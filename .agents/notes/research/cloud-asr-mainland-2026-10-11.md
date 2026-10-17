# 大陆直连云端 ASR 接入调研（2026-10-11）

用户确认：中国大陆直连，优先中文与中英混合；只有一个全局 ASR 类别，现有本地 ASR 保留。
本次比较基于官方协议文档，没有使用用户录音，也未做付费请求或网络质量实测。

| 候选 | 已核对的能力与接入差异 | 对 Rill 的判断 |
| --- | --- | --- |
| 阿里云百炼 Qwen-ASR Realtime，北京区域 | WebSocket + JSON 事件；16 kHz PCM/Opus，手动提交或服务端 VAD；支持中文、英语及多语种；会话完成有明确 finished 事件 | 建议第一候选。事件协议容易接入现有采集生命周期，选北京工作空间和同区域 Key，按热词、代码标识和中英混合样本验收 |
| 火山引擎豆包大模型 ASR | 双向流式尽快返回字符，流式输入可在最后包/超过 15 秒后返回；官方建议 100–200 ms 音频包，双向优化模式 200 ms；中文与英文受支持 | 中文实时体验的重要对照。使用自己的二进制帧/鉴权协议，接入与取消路径需单独验证 |

建议先接百炼北京区域，再用同一离线清单评估豆包。该结论是协议适配成本判断，不能证明
稳定性、速度或准确率谁更好。真实选型应比较：大陆多网络连接/重连、首字时间、松键到最终文本
p50/p95、中文 CER、英文 WER、专名/代码标识、中英切换、超时/取消、每段实际计费。

此次模型重构只保留本地 ASR 实现，移除 workflow 模型覆盖；云端 ASR 仍需独立实现与实际平台
凭据验收。新增时由全局 ASR 设置唯一选择平台和模型，workflow 无需改动，也不增加 ASR 档位。

官方来源（读取日期同上）：

- [Qwen-ASR WebSocket 模型入口](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-model-access)
- [Qwen-ASR 客户端事件](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-client-events)
- [Qwen-ASR 非实时指南与区域](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide)
- [豆包大模型流式 ASR API](https://docs.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh)

分类模型另已核对 [Clef](https://developers.cloudflare.com/workers-ai/models/clef/) 的
[input schema](https://developers.cloudflare.com/workers-ai/models/clef/schema-input.json) 和
[output schema](https://developers.cloudflare.com/workers-ai/models/clef/schema-output.json)：score 问题支持对象 instructions、
有序 criteria、概率分布及 token 用量，与既有 Jev 评分合同可以共用。HTTP 路由、账户 ID、模型名与
Cloudflare success/result/errors 外层独立验证。

# 大陆直连云端 ASR 调研（2026-10-11）

当时用户约束：中国大陆直连，优先中文与中英混合；保留本地 ASR，只有一个全局
ASR 类别。此记录仅保存协议调研，没有真实网络、录音质量或付费请求证据。

| 候选 | 当时核对的协议差异 |
| --- | --- |
| 阿里云百炼 Qwen-ASR Realtime，北京区域 | WebSocket/JSON，16 kHz PCM/Opus，手动提交或服务端 VAD，明确的 finished 事件 |
| 火山引擎豆包大模型 ASR | 自有二进制帧与鉴权；官方建议 100–200 ms 音频包，双向优化模式 200 ms |

当时建议先实测百炼北京，再以同一录音对照豆包；依据是协议适配成本，未决定质量优劣。
重新选型须核对现行协议，并比较大陆多网络连接/重连、首字及松键到最终文本 p50/p95、
中文 CER/英文 WER、专名与中英切换、超时/取消和实际计费。此记录不代表已接通云端 ASR。

官方来源（读取于上述日期）：

- [Qwen-ASR WebSocket](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-model-access)、[客户端事件](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-client-events)
- [Qwen-ASR 区域说明](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide)
- [豆包流式 ASR API](https://docs.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh)

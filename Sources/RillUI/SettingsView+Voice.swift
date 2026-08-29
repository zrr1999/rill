import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var voiceAssistantResourcesSection: some View {
    settingsDisclosure(.voiceAssistant) {
      voiceAssistantSetupOverview

      Divider()

      LabeledContent(
        model.language == .english ? "Wake-word listener" : "唤醒词监听"
      ) {
        Text(wakeWordRuntimeStatusText)
          .foregroundStyle(wakeWordRuntimeStatusColor)
      }

      voiceResourceStatus(
        state: model.wakeWordResourceState,
        readyText:
          model.language == .english
          ? "Selected local ASR is ready"
          : "当前本地语音模型已就绪"
      )

      if voiceAssistantActionVisibility.showsWakeWordPreparation {
        Button(
          resourcePreparationButtonTitle(
            state: model.wakeWordResourceState,
            englishName: "local ASR",
            simplifiedChineseName: "本地语音模型"
          )
        ) {
          model.prepareWakeWordModel()
        }
        .accessibilityIdentifier("settings.wake-word.prepare")
      }

      Toggle(
        model.language == .english
          ? "Enable wake-word listening"
          : "启用唤醒词监听",
        isOn: Binding(
          get: { wakeListeningDraftEnabled },
          set: { requestWakeWordListening($0) }
        )
      )
      .disabled(
        isApplyingWakeWordSettings
          || (!wakeListeningDraftEnabled
            && !model.voiceAssistantReadiness.canEnableListening)
      )
      .accessibilityIdentifier("settings.wake-word.enabled")

      VStack(alignment: .leading, spacing: 5) {
        Text(model.language == .english ? "Wake phrases" : "唤醒短语")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        TextField(
          model.language == .english
            ? "One phrase per line (1–4)"
            : "每行一个短语（1–4 个）",
          text: $wakePhrasesText,
          axis: .vertical
        )
        .lineLimit(1...4)
        .textFieldStyle(.roundedBorder)
        .focused($wakePhrasesFieldFocused)
        .disabled(isApplyingWakeWordSettings)
        .accessibilityIdentifier("settings.wake-word.phrases")

        HStack(spacing: 8) {
          Button(model.language == .english ? "Save phrases" : "保存短语") {
            applyWakeWordSettings(
              enableListening: wakeListeningDraftEnabled
            )
          }
          .disabled(isApplyingWakeWordSettings || !wakeWordModelIsReady)
          .accessibilityIdentifier("settings.wake-word.save")

          if isApplyingWakeWordSettings {
            ProgressView()
              .controlSize(.small)
          }

          Spacer()

          if let workflowName = model.wakeWordSettingsSnapshot.workflowName {
            Text(
              model.language == .english
                ? "Workflow: \(workflowName)"
                : "工作流：\(workflowName)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }

      if let wakeWordSettingsError {
        Label(wakeWordSettingsError, systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Text(
        model.language == .english
          ? "This edits the ambient wake trigger only. Fn and other interactive recognition take microphone priority immediately; "
            + "LLM and speech output continue on the assistant lane without blocking the next recognition."
          : "这里仅编辑环境唤醒触发。Fn 和其他交互识别会立即取得麦克风优先级；LLM 与语音输出在独立助手通道继续处理，不阻塞下一次识别。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Text(
        model.language == .english
          ? "Idle listening runs only local VAD. Complete candidates are checked locally and discarded unless they begin with a configured wake phrase."
          : "空闲监听只运行本地 VAD；完整候选会在本地检查，不以已配置唤醒短语开头时立即丢弃。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .onChange(of: model.wakeWordSettingsSnapshot) { _, snapshot in
      guard !isApplyingWakeWordSettings else { return }
      wakeListeningDraftEnabled = snapshot.isEnabled
      if !wakePhrasesFieldFocused {
        wakePhrasesText = snapshot.phrases.joined(separator: "\n")
      }
    }
  }

  @ViewBuilder
  func voiceResourceStatus(
    state: VoiceAssistantResourceState,
    readyText: String
  ) -> some View {
    switch state {
    case .notInstalled:
      Text(model.language == .english ? "Not installed" : "尚未安装")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .preparing(let progress):
      if let progress, progress > 0 {
        HStack(spacing: 8) {
          ProgressView(value: progress)
          Text(progress, format: .percent.precision(.fractionLength(0)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 34, alignment: .trailing)
        }
      } else {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(model.language == .english ? "Preparing download…" : "正在准备下载…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    case .ready:
      Label(readyText, systemImage: RillSystemSymbol.checkmarkCircleFill.rawValue)
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
        .font(.caption)
        .foregroundStyle(.red)
    case .unavailable(let reason):
      Label(
        voiceResourceUnavailableText(reason),
        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
      )
      .font(.caption)
      .foregroundStyle(.orange)
    }
  }

  var voiceAssistantActionVisibility: VoiceAssistantSettingsActionVisibility {
    VoiceAssistantSettingsActionVisibility(
      wakeWordState: model.wakeWordResourceState,
      ttsState: model.ttsResourceState,
      isSpeechPlaybackActive: model.isSpeechPlaybackActive
    )
  }

  var voiceAssistantSetupOverview: some View {
    let readiness = model.voiceAssistantReadiness
    return VStack(alignment: .leading, spacing: 10) {
      Label(
        readiness.canEnableListening
          ? (model.language == .english
            ? "Assistant setup is ready"
            : "语音助手已准备就绪")
          : (model.language == .english
            ? "Complete assistant setup"
            : "请完成语音助手设置"),
        systemImage: readiness.canEnableListening
          ? "checkmark.seal.fill"
          : "checklist"
      )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(readiness.canEnableListening ? .green : .primary)

      voiceAssistantReadinessRow(
        title: model.language == .english ? "Microphone" : "麦克风",
        detail: microphoneReadinessDetail(readiness.microphone),
        isReady: readiness.microphone == .granted
      )
      voiceAssistantReadinessRow(
        title: model.language == .english ? "Local recognition" : "本地识别",
        detail: localSpeechReadinessDetail(readiness.localSpeech),
        isReady: readiness.isLocalSpeechReady
      )
      voiceAssistantReadinessRow(
        title: model.language == .english ? "LLM answer" : "LLM 回答",
        detail: llmReadinessDetail(readiness.llm),
        isReady: readiness.llm.permitsListening
      )
      voiceAssistantReadinessRow(
        title: model.language == .english ? "Cloud privacy" : "云端隐私",
        detail: privacyReadinessDetail(readiness.privacy),
        isReady: readiness.privacy.permitsListening
      )
      voiceAssistantReadinessRow(
        title: model.language == .english ? "Speech output" : "语音输出",
        detail: speechOutputReadinessDetail(readiness.speechOutput),
        isReady: true
      )

      HStack(spacing: 8) {
        if readiness.microphone != .granted {
          Button(model.language == .english ? "Review permissions" : "检查权限") {
            model.showSettings(.permissions)
          }
          .accessibilityIdentifier("settings.voice-assistant.review-permissions")
        }
        if readiness.llm != .notRequired,
          readiness.llm != .verified
        {
          Button(model.language == .english ? "Configure & verify LLM" : "配置并验证 LLM") {
            model.showSettings(.speech)
          }
          .accessibilityIdentifier("settings.voice-assistant.configure-llm")
        }
        if readiness.privacy == .unavailable {
          Button(model.language == .english ? "Repair privacy settings" : "修复隐私设置") {
            model.showSettings(.privacy)
          }
          .accessibilityIdentifier("settings.voice-assistant.repair-privacy")
        }
      }
      .buttonStyle(.bordered)
    }
    .padding(10)
    // RillCard prominent-tier fill; custom corner radius keeps this manual.
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  func voiceAssistantReadinessRow(
    title: String,
    detail: String,
    isReady: Bool
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: isReady ? RillSystemSymbol.checkmarkCircleFill.rawValue : RillSystemSymbol.circleDashed.rawValue)
        .foregroundStyle(isReady ? .green : .orange)
        .accessibilityHidden(true)
      Text(title)
        .font(.caption.weight(.medium))
      Spacer(minLength: 12)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  func microphoneReadinessDetail(_ state: PermissionState) -> String {
    switch (model.language, state) {
    case (.english, .granted): "Ready"
    case (.simplifiedChinese, .granted): "已就绪"
    case (.english, .unknown): "Permission not checked"
    case (.simplifiedChinese, .unknown): "尚未检查权限"
    case (.english, .denied): "Permission required"
    case (.simplifiedChinese, .denied): "需要授权"
    }
  }

  func localSpeechReadinessDetail(
    _ state: VoiceAssistantResourceState
  ) -> String {
    switch (model.language, state) {
    case (.english, .ready): "Selected Qwen ASR is ready"
    case (.simplifiedChinese, .ready): "当前 Qwen ASR 已就绪"
    case (.english, .preparing): "Preparing model"
    case (.simplifiedChinese, .preparing): "正在准备模型"
    case (.english, .notInstalled): "Model required"
    case (.simplifiedChinese, .notInstalled): "需要准备模型"
    case (.english, .failed): "Preparation failed"
    case (.simplifiedChinese, .failed): "模型准备失败"
    case (.english, .unavailable): "Unavailable in this build"
    case (.simplifiedChinese, .unavailable): "当前版本不可用"
    }
  }

  func llmReadinessDetail(_ state: VoiceAssistantLLMReadiness) -> String {
    switch (model.language, state) {
    case (.english, .notRequired): "Not used by this workflow"
    case (.simplifiedChinese, .notRequired): "当前工作流不使用"
    case (.english, .loading): "Loading secure settings"
    case (.simplifiedChinese, .loading): "正在读取安全设置"
    case (.english, .credentialMissing): "API key required"
    case (.simplifiedChinese, .credentialMissing): "需要 API Key"
    case (.english, .credentialInaccessible): "Keychain unavailable"
    case (.simplifiedChinese, .credentialInaccessible): "无法访问钥匙串"
    case (.english, .configurationInvalid): "Endpoint or model ID is invalid"
    case (.simplifiedChinese, .configurationInvalid): "地址或模型 ID 无效"
    case (.english, .configured): "Configured; verification recommended"
    case (.simplifiedChinese, .configured): "已配置；建议验证"
    case (.english, .verifying): "Verifying"
    case (.simplifiedChinese, .verifying): "正在验证"
    case (.english, .verified): "Verified"
    case (.simplifiedChinese, .verified): "验证通过"
    case (.english, .verificationFailed): "Verification failed"
    case (.simplifiedChinese, .verificationFailed): "验证失败"
    }
  }

  func privacyReadinessDetail(
    _ state: VoiceAssistantPrivacyReadiness
  ) -> String {
    switch (model.language, state) {
    case (.english, .notRequired): "No cloud step"
    case (.simplifiedChinese, .notRequired): "没有云端步骤"
    case (.english, .loading): "Loading policy"
    case (.simplifiedChinese, .loading): "正在读取策略"
    case (.english, .unavailable): "Policy unavailable"
    case (.simplifiedChinese, .unavailable): "策略不可用"
    case (.english, .ready(cloudConfirmationRequired: true)):
      "Confirmation required per run"
    case (.simplifiedChinese, .ready(cloudConfirmationRequired: true)):
      "每次运行需要确认"
    case (.english, .ready(cloudConfirmationRequired: false)):
      "Policy ready"
    case (.simplifiedChinese, .ready(cloudConfirmationRequired: false)):
      "策略已就绪"
    }
  }

  func speechOutputReadinessDetail(
    _ state: VoiceAssistantSpeechOutputReadiness
  ) -> String {
    switch (model.language, state) {
    case (.english, .notRequired): "Not used by this workflow"
    case (.simplifiedChinese, .notRequired): "当前工作流不使用"
    case (.english, .localVoice): "Local Qwen voice"
    case (.simplifiedChinese, .localVoice): "本地 Qwen 音色"
    case (.english, .preparingLocalVoice): "System voice until ready"
    case (.simplifiedChinese, .preparingLocalVoice): "准备期间使用系统语音"
    case (.english, .systemFallback): "System voice fallback ready"
    case (.simplifiedChinese, .systemFallback): "系统语音回退已就绪"
    }
  }

  var wakeWordModelIsReady: Bool {
    if case .ready = model.wakeWordResourceState {
      return true
    }
    return false
  }

  var wakePhraseDraftValues: [String] {
    wakePhrasesText
      .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" })
      .map(String.init)
      .map(WakeWordConfiguration.normalizedPhrase)
      .filter { !$0.isEmpty }
  }

  func requestWakeWordListening(_ enabled: Bool) {
    wakeListeningDraftEnabled = enabled
    wakeWordSettingsError = nil
    if enabled {
      applyWakeWordSettings(enableListening: true)
    } else {
      model.disableWakeWordListening()
    }
  }

  func applyWakeWordSettings(enableListening: Bool) {
    guard !isApplyingWakeWordSettings else { return }
    isApplyingWakeWordSettings = true
    wakeWordSettingsError = nil
    let phrases = wakePhraseDraftValues
    Task { @MainActor in
      let result = await model.updateWakeWordSettings(
        phrases: phrases,
        enableListening: enableListening
      )
      isApplyingWakeWordSettings = false
      switch result {
      case .saved:
        let snapshot = model.wakeWordSettingsSnapshot
        wakeListeningDraftEnabled = snapshot.isEnabled
        wakePhrasesText = snapshot.phrases.joined(separator: "\n")
      case .failed(let message):
        wakeListeningDraftEnabled = model.wakeWordSettingsSnapshot.isEnabled
        wakeWordSettingsError = message
      }
    }
  }

  func resourcePreparationButtonTitle(
    state: VoiceAssistantResourceState,
    englishName: String,
    simplifiedChineseName: String
  ) -> String {
    if case .failed = state {
      return model.language == .english
        ? "Retry \(englishName)"
        : "重试\(simplifiedChineseName)"
    }
    return model.language == .english
      ? "Download \(englishName)"
      : "下载\(simplifiedChineseName)"
  }

  func voiceResourceUnavailableText(
    _ reason: VoiceAssistantResourceUnavailableReason
  ) -> String {
    switch reason {
    case .distributionLicenseUnverified:
      return model.language == .english
        ? "This local speech model is unavailable in the current distribution."
        : "当前发行版本不提供此本地语音模型。"
    }
  }

  var wakeWordRuntimeStatusText: String {
    switch model.wakeWordRuntimeState {
    case .disabled:
      model.language == .english ? "Disabled" : "已停用"
    case .modelMissing:
      model.language == .english ? "Model required" : "需要模型"
    case .starting:
      model.language == .english ? "Starting" : "正在启动"
    case .listening:
      model.language == .english ? "Listening locally" : "正在本地监听"
    case .suspended(let reason):
      (model.language == .english ? "Paused: " : "已暂停：")
        + wakeWordSuspensionReasonText(reason)
    case .failed:
      model.language == .english ? "Unavailable" : "不可用"
    }
  }

  func wakeWordSuspensionReasonText(_ reason: String) -> String {
    switch (model.language, reason) {
    case (.english, "interactiveRecognition"):
      "interactive recognition has priority"
    case (.simplifiedChinese, "interactiveRecognition"):
      "交互识别优先"
    case (.english, "speechPlayback"):
      "speech playback"
    case (.simplifiedChinese, "speechPlayback"):
      "正在播放语音"
    case (.english, "microphonePermission"):
      "microphone permission"
    case (.simplifiedChinese, "microphonePermission"):
      "麦克风权限"
    case (.english, "inputDeviceChanged"):
      "input device changed"
    case (.simplifiedChinese, "inputDeviceChanged"):
      "输入设备已变化"
    case (.english, "busy"):
      "assistant workflow is running"
    case (.simplifiedChinese, "busy"):
      "助手工作流正在运行"
    default:
      reason
    }
  }

  var wakeWordRuntimeStatusColor: Color {
    switch model.wakeWordRuntimeState {
    case .listening:
      .green
    case .failed:
      .red
    case .starting, .suspended:
      .orange
    case .disabled, .modelMissing:
      .secondary
    }
  }

}

import SwiftUI
import RillCore

private enum SettingsDestructiveConfirmation: Sendable {
  case clipboardHistory
  case runHistory
  case failedAudioRecovery
}

private enum SettingsSheetDestination: Identifiable {
  case privacyNotice(PrivacyNoticeDocument)

  var id: String {
    switch self {
    case .privacyNotice:
      return "privacy-notice"
    }
  }
}

private enum OpenAIModelSelection: String, CaseIterable, Identifiable {
  case luna
  case terra
  case sol
  case custom

  var id: String { rawValue }

  var modelIdentifier: String? {
    switch self {
    case .luna:
      OpenAIModelOption.luna.rawValue
    case .terra:
      OpenAIModelOption.terra.rawValue
    case .sol:
      OpenAIModelOption.sol.rawValue
    case .custom:
      nil
    }
  }

  init(modelIdentifier: String) {
    switch modelIdentifier {
    case OpenAIModelOption.luna.rawValue:
      self = .luna
    case OpenAIModelOption.terra.rawValue:
      self = .terra
    case OpenAIModelOption.sol.rawValue:
      self = .sol
    default:
      self = .custom
    }
  }
}

struct VoiceAssistantSettingsActionVisibility: Equatable {
  let showsWakeWordPreparation: Bool
  let showsTTSPreparation: Bool
  let showsStopPlayback: Bool

  init(
    wakeWordState: VoiceAssistantResourceState,
    ttsState: VoiceAssistantResourceState,
    isSpeechPlaybackActive: Bool
  ) {
    showsWakeWordPreparation = Self.showsPreparation(for: wakeWordState)
    showsTTSPreparation = Self.showsPreparation(for: ttsState)
    showsStopPlayback = isSpeechPlaybackActive
  }

  private static func showsPreparation(
    for state: VoiceAssistantResourceState
  ) -> Bool {
    switch state {
    case .notInstalled, .failed:
      true
    case .preparing, .ready, .unavailable:
      false
    }
  }
}

enum SettingsPermissionAction: Equatable {
  case none
  case request
  case openSettings
}

enum SettingsPermissionTone: Equatable {
  case success
  case secondary
  case warning
  case error
}

struct SettingsPermissionPresentation: Equatable {
  let detail: String
  let tone: SettingsPermissionTone
  let action: SettingsPermissionAction

  static func make(
    state: PermissionState,
    isRequired: Bool,
    optionalDetail: String?,
    language: AppLanguage
  ) -> Self {
    if state == .granted {
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .success,
        action: .none
      )
    }
    if !isRequired {
      return Self(
        detail: optionalDetail
          ?? UIStrings.permissionState(state, language: language),
        tone: .secondary,
        action: .none
      )
    }
    switch state {
    case .granted:
      preconditionFailure("Granted permissions are handled above")
    case .unknown:
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .warning,
        action: .request
      )
    case .denied:
      return Self(
        detail: UIStrings.permissionState(state, language: language),
        tone: .error,
        action: .openSettings
      )
    }
  }
}

public struct SettingsView: View {
  @Bindable private var model: AppModel
  private let privacyNoticeDocument: PrivacyNoticeDocument?
  @State private var vocabularyKind: VocabularyRuleKind = .mapping
  @State private var vocabularyPattern = ""
  @State private var vocabularyReplacement = ""
  @State private var vocabularyMatchMode: VocabularyMatchMode = .exactPhrase
  @State private var vocabularyCaseSensitive = false
  @State private var vocabularyBundleIdentifier = ""
  @State private var vocabularyGroupID: UUID?
  @State private var vocabularyLocale = ""
  @State private var vocabularyPriority = 0
  @State private var sensitiveAppBundleIdentifier = ""
  @State private var sensitiveAppApplicationName = ""
  @State private var editingSensitiveAppRuleID: UUID?
  @State private var sensitiveAppRuleError: String?
  @State private var destructiveConfirmation: SettingsDestructiveConfirmation?
  @State private var presentedSheet: SettingsSheetDestination?
  @State private var expandedSettingsSections: Set<SettingsSection> = [.permissions]
  @State private var wakePhrasesText: String
  @State private var wakeListeningDraftEnabled: Bool
  @State private var isApplyingWakeWordSettings = false
  @State private var wakeWordSettingsError: String?
  @FocusState private var focusedSettingsSection: SettingsSection?
  @FocusState private var wakePhrasesFieldFocused: Bool
  @AccessibilityFocusState private var accessibilityFocusedSettingsSection: SettingsSection?

  public init(
    model: AppModel,
    privacyNoticeDocument: PrivacyNoticeDocument? = PrivacyNoticeDocument.bundled
  ) {
    self.model = model
    self.privacyNoticeDocument = privacyNoticeDocument
    let wakeWordSettings = model.wakeWordSettingsSnapshot
    _wakePhrasesText = State(
      initialValue: wakeWordSettings.phrases.joined(separator: "\n")
    )
    _wakeListeningDraftEnabled = State(
      initialValue: wakeWordSettings.isEnabled
    )
  }

  public var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          Text(UIStrings.text(.settingsDescription, language: model.language))
            .foregroundStyle(.secondary)
        }

        if let unsavedSummary = model.settingsSaveState.unsavedSummary {
          settingsSaveFailureSection(unsavedSummary)
        }

        Section {
          permissionsSection
          speechEngineSection
          builtinPushToTalkSection
          voiceAssistantResourcesSection
        } header: {
          settingsGroupHeader(
            model.language == .english ? "Voice & Models" : "语音与模型",
            systemImage: "waveform"
          )
        }

        Section {
          clipboardPanelSection
          vocabularySection
          languageSection
        } header: {
          settingsGroupHeader(
            model.language == .english ? "Features & Personalization" : "功能与个性化",
            systemImage: "slider.horizontal.3"
          )
        }

        Section {
          privacySection
          localDataAndRetentionSection
        } header: {
          settingsGroupHeader(
            model.language == .english ? "Privacy & Data" : "隐私与数据",
            systemImage: "lock.shield"
          )
        }
      }
      .formStyle(.grouped)
      .task(id: model.settingsNavigationRequest?.id) {
        guard let request = model.settingsNavigationRequest else { return }
        await positionSettingsSection(request, proxy: proxy)
      }
    }
    .navigationTitle(UIStrings.text(.settingsTitle, language: model.language))
    .sheet(item: $presentedSheet) { destination in
      switch destination {
      case .privacyNotice(let document):
        PrivacyNoticeSheet(document: document, language: model.language)
      }
    }
    .confirmationDialog(
      destructiveConfirmationTitle,
      isPresented: Binding(
        get: { destructiveConfirmation != nil },
        set: { isPresented in
          if !isPresented {
            destructiveConfirmation = nil
          }
        }
      ),
      presenting: destructiveConfirmation
    ) { confirmation in
      Button(destructiveConfirmationActionTitle(confirmation), role: .destructive) {
        destructiveConfirmation = nil
        performDestructiveConfirmation(confirmation)
      }
      Button(
        L10n.historySettingsText(.cancel, language: model.language),
        role: .cancel
      ) {
        destructiveConfirmation = nil
      }
    } message: { confirmation in
      Text(destructiveConfirmationDetail(confirmation))
    }
  }

  private var permissionsSection: some View {
    settingsDisclosure(.permissions) {
      HStack {
        Spacer()
        Button(UIStrings.text(.refreshPermissions, language: model.language)) {
          model.refreshPermissions()
        }
      }

      globalInputPermissionRow(model.globalInputCapability)

      permissionRow(
        title: UIStrings.text(.accessibility, language: model.language),
        state: model.permissionSnapshot.accessibility,
        isRequired: model.voiceSetupReadiness.accessibilityRequired,
        optionalDetail: UIStrings.text(
          .voiceSetupAccessibilityOptional,
          language: model.language
        ),
        requestAction: model.requestAccessibilityPermission,
        openSettingsAction: model.openAccessibilitySettings
      )

      permissionRow(
        title: UIStrings.text(.microphone, language: model.language),
        state: model.permissionSnapshot.microphone,
        requestAction: model.requestMicrophonePermission,
        openSettingsAction: model.openMicrophoneSettings
      )

      if model.voiceSetupReadiness.accessibilityRequired,
        model.permissionSnapshot.accessibility != .granted
      {
        Text(UIStrings.text(.appNotListedHint, language: model.language))
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Text(UIStrings.text(.permissionHint, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var voiceAssistantResourcesSection: some View {
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
        Label(wakeWordSettingsError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }

      Text(
        model.language == .english
          ? "This edits the ambient wake trigger only. Fn and other interactive recognition take microphone priority immediately; LLM and speech output continue on the assistant lane without blocking the next recognition."
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
  private func voiceResourceStatus(
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
      Label(readyText, systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
    case .unavailable(let reason):
      Label(
        voiceResourceUnavailableText(reason),
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.caption)
      .foregroundStyle(.orange)
    }
  }

  private var voiceAssistantActionVisibility: VoiceAssistantSettingsActionVisibility {
    VoiceAssistantSettingsActionVisibility(
      wakeWordState: model.wakeWordResourceState,
      ttsState: model.ttsResourceState,
      isSpeechPlaybackActive: model.isSpeechPlaybackActive
    )
  }

  private var voiceAssistantSetupOverview: some View {
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
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  private func voiceAssistantReadinessRow(
    title: String,
    detail: String,
    isReady: Bool
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
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

  private func microphoneReadinessDetail(_ state: PermissionState) -> String {
    switch (model.language, state) {
    case (.english, .granted): "Ready"
    case (.simplifiedChinese, .granted): "已就绪"
    case (.english, .unknown): "Permission not checked"
    case (.simplifiedChinese, .unknown): "尚未检查权限"
    case (.english, .denied): "Permission required"
    case (.simplifiedChinese, .denied): "需要授权"
    }
  }

  private func localSpeechReadinessDetail(
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

  private func llmReadinessDetail(_ state: VoiceAssistantLLMReadiness) -> String {
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

  private func privacyReadinessDetail(
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

  private func speechOutputReadinessDetail(
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

  private var wakeWordModelIsReady: Bool {
    if case .ready = model.wakeWordResourceState {
      return true
    }
    return false
  }

  private var wakePhraseDraftValues: [String] {
    wakePhrasesText
      .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" })
      .map(String.init)
      .map(WakeWordConfiguration.normalizedPhrase)
      .filter { !$0.isEmpty }
  }

  private func requestWakeWordListening(_ enabled: Bool) {
    wakeListeningDraftEnabled = enabled
    wakeWordSettingsError = nil
    if enabled {
      applyWakeWordSettings(enableListening: true)
    } else {
      model.disableWakeWordListening()
    }
  }

  private func applyWakeWordSettings(enableListening: Bool) {
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

  private func resourcePreparationButtonTitle(
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

  private func voiceResourceUnavailableText(
    _ reason: VoiceAssistantResourceUnavailableReason
  ) -> String {
    switch reason {
    case .distributionLicenseUnverified:
      return model.language == .english
        ? "This local speech model is unavailable in the current distribution."
        : "当前发行版本不提供此本地语音模型。"
    }
  }

  private var wakeWordRuntimeStatusText: String {
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

  private func wakeWordSuspensionReasonText(_ reason: String) -> String {
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

  private var wakeWordRuntimeStatusColor: Color {
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

  private var clipboardPanelSection: some View {
    settingsDisclosure(.clipboardPanel) {
      if model.hasUnavailableScalarSettings(in: .clipboard) {
        unavailableScalarSettingsWarning(.clipboard)
      }

      Toggle(
        UIStrings.text(
          .settingsClipboardCaptureEnabled,
          language: model.language
        ),
        isOn: Binding(
          get: { model.clipboardCaptureEnabled },
          set: { model.setClipboardCaptureEnabled($0) }
        )
      )
      .disabled(!model.canMutateScalarSettings(in: .clipboard))
      .accessibilityIdentifier("settings.clipboard.capture-enabled")

      Text(
        UIStrings.text(
          .settingsClipboardCaptureEnabledDescription,
          language: model.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if ClipboardPanelShortcutPresentationPolicy.surfaceVisibility(
        clipboardCaptureEnabled: model.clipboardCaptureEnabled
      ).settingsRecorder {
        Divider()

        HotkeyRecorderView(
          binding: model.clipboardPanelHotkeyBinding,
          language: model.language,
          beginClipboardPanelShortcutRecording: {
            model.beginClipboardPanelShortcutRecording()
          },
          endClipboardPanelShortcutRecording: { suspensionID in
            model.endClipboardPanelShortcutRecording(suspensionID)
          },
          commitClipboardPanelShortcutRecording: { suspensionID, keyCode in
            model.commitClipboardPanelShortcutRecording(
              suspensionID,
              keyCode: keyCode
            )
          },
          onRecord: { shortcut in
            model.setClipboardPanelHotkeyShortcut(shortcut)
          },
          onReset: {
            model.resetClipboardPanelHotkeyBinding()
          }
        )
        .disabled(model.hasUnavailableScalarSettings(in: .clipboard))
      }

      Text(UIStrings.text(.settingsClipboardPanelDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var languageSection: some View {
    settingsDisclosure(.language) {
      if model.hasUnavailableScalarSettings(in: .interface) {
        unavailableScalarSettingsWarning(.interface)
      }

      Picker(
        UIStrings.text(.language, language: model.language),
        selection: Binding(
          get: { model.language },
          set: { model.setInterfaceLanguage($0) }
        )
      ) {
        ForEach(AppLanguage.allCases) { language in
          Text(language.displayName).tag(language)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 260)
      .disabled(!model.canMutateScalarSettings(in: .interface))

      Text(UIStrings.text(.settingsLanguageDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func settingsSectionHeader(_ section: SettingsSection) -> some View {
    Label(section.title(language: model.language), systemImage: section.symbolName)
      .accessibilityFocused(
        $accessibilityFocusedSettingsSection,
        equals: section
      )
      .accessibilityIdentifier("settings.section.\(section.rawValue)")
  }

  private func settingsGroupHeader(
    _ title: String,
    systemImage: String
  ) -> some View {
    Label(title, systemImage: systemImage)
      .font(.headline)
      .foregroundStyle(.primary)
  }

  private func settingsDisclosure<Content: View>(
    _ section: SettingsSection,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    DisclosureGroup(isExpanded: settingsDisclosureBinding(for: section)) {
      VStack(alignment: .leading, spacing: 12) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        settingsSectionHeader(section)
        Text(settingsSectionSummary(section))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 2)
    }
    .focusable()
    .focused($focusedSettingsSection, equals: section)
    .focusEffectDisabled()
    .id(section)
  }

  private func settingsDisclosureBinding(
    for section: SettingsSection
  ) -> Binding<Bool> {
    Binding(
      get: { expandedSettingsSections.contains(section) },
      set: { isExpanded in
        if isExpanded {
          expandedSettingsSections.insert(section)
        } else {
          expandedSettingsSections.remove(section)
        }
      }
    )
  }

  private func settingsSectionSummary(_ section: SettingsSection) -> String {
    switch (section, model.language) {
    case (.permissions, .english):
      "Microphone, global shortcuts, and system access"
    case (.permissions, .simplifiedChinese):
      "麦克风、全局快捷键与系统访问"
    case (.speech, .english):
      "Provider configuration and available model pool"
    case (.speech, .simplifiedChinese):
      "提供商配置与可用模型池"
    case (.input, .english):
      "Recording behavior, duration, and output"
    case (.input, .simplifiedChinese):
      "录音方式、时长与输出"
    case (.voiceAssistant, .english):
      "Readiness, wake listening, LLM answers, and speech output"
    case (.voiceAssistant, .simplifiedChinese):
      "就绪检查、唤醒监听、LLM 回答与语音输出"
    case (.clipboardPanel, .english):
      "Clipboard capture and panel shortcut"
    case (.clipboardPanel, .simplifiedChinese):
      "剪贴板捕获与面板快捷键"
    case (.vocabulary, .english):
      "Hotwords, replacements, and scoped corrections"
    case (.vocabulary, .simplifiedChinese):
      "热词、替换与限定范围的纠正"
    case (.language, .english):
      "Display language"
    case (.language, .simplifiedChinese):
      "界面显示语言"
    case (.privacy, .english):
      "Cloud confirmation and sensitive-app safeguards"
    case (.privacy, .simplifiedChinese):
      "云端确认与敏感应用保护"
    case (.storage, .english):
      "Retention, recovery, and local cleanup"
    case (.storage, .simplifiedChinese):
      "保留期限、恢复与本地清理"
    }
  }

  private func positionSettingsSection(
    _ request: SettingsNavigationRequest,
    proxy: ScrollViewProxy
  ) async {
    await Task.yield()
    guard model.selectedSidebarSection == .settings,
      model.settingsNavigationRequest?.id == request.id
    else {
      return
    }
    expandedSettingsSections.insert(request.section)
    await Task.yield()
    withAnimation(.easeInOut(duration: 0.2)) {
      proxy.scrollTo(request.section, anchor: .top)
    }
    await Task.yield()
    guard model.settingsNavigationRequest?.id == request.id else { return }
    focusedSettingsSection = request.section
    accessibilityFocusedSettingsSection = request.section
  }

  private var destructiveConfirmationTitle: String {
    guard let destructiveConfirmation else { return "" }
    return switch destructiveConfirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboardConfirmation, language: model.language)
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmation, language: model.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmation,
        language: model.language
      )
    }
  }

  private func destructiveConfirmationActionTitle(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(.clearClipboard, language: model.language)
    case .runHistory:
      L10n.historySettingsText(.clearRun, language: model.language)
    case .failedAudioRecovery:
      L10n.string(.settingsFailedAudioRecoveryClear, language: model.language)
    }
  }

  private func destructiveConfirmationDetail(
    _ confirmation: SettingsDestructiveConfirmation
  ) -> String {
    return switch confirmation {
    case .clipboardHistory:
      L10n.historySettingsText(
        .clearClipboardConfirmationDetail,
        language: model.language
      )
    case .runHistory:
      L10n.historySettingsText(.clearRunConfirmationDetail, language: model.language)
    case .failedAudioRecovery:
      L10n.string(
        .settingsFailedAudioRecoveryClearConfirmationDetail,
        language: model.language
      )
    }
  }

  private func performDestructiveConfirmation(
    _ confirmation: SettingsDestructiveConfirmation
  ) {
    switch confirmation {
    case .clipboardHistory:
      model.clearClipboardHistory()
    case .runHistory:
      model.clearRunHistory()
    case .failedAudioRecovery:
      model.clearFailedAudioRecoveries()
    }
  }

  private func permissionRow(
    title: String,
    state: PermissionState,
    isRequired: Bool = true,
    optionalDetail: String? = nil,
    requestAction: @escaping () -> Void,
    openSettingsAction: @escaping () -> Void
  ) -> some View {
    let presentation = SettingsPermissionPresentation.make(
      state: state,
      isRequired: isRequired,
      optionalDetail: optionalDetail,
      language: model.language
    )
    return HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(presentation.detail)
          .font(.caption)
          .foregroundStyle(permissionColor(presentation.tone))
      }
      Spacer()
      switch presentation.action {
      case .none:
        EmptyView()
      case .request:
        Button(UIStrings.text(.requestAccess, language: model.language)) {
          requestAction()
        }
      case .openSettings:
        Button(UIStrings.text(.openSettings, language: model.language)) {
          openSettingsAction()
        }
      }
    }
  }

  private func settingsSaveFailureSection(
    _ summary: UnsavedSettingsSummary
  ) -> some View {
    Section {
      Label(
        UIStrings.text(.settingsSaveFailedTitle, language: model.language),
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
      .accessibilityIdentifier("settings.unsaved.title")

      Text(UIStrings.settingsSaveFailureDescription(summary, language: model.language))
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("settings.unsaved.description")

      HStack {
        Spacer()
        Button {
          model.retryUnsavedSettingsSave()
        } label: {
          if model.settingsSaveState.isRetrying {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(UIStrings.text(.settingsSaveRetrying, language: model.language))
            }
          } else {
            Text(UIStrings.text(.settingsSaveRetry, language: model.language))
          }
        }
        .disabled(model.settingsSaveState.isRetrying)
        .accessibilityIdentifier("settings.unsaved.retry")
      }
    }
  }

  private func unavailableScalarSettingsWarning(
    _ domain: ScalarSettingsDomain
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        domain.unavailableWarning(language: model.language),
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .foregroundStyle(.orange)

      HStack {
        Spacer()
        Button {
          model.retryUnavailableScalarSettings(in: domain)
        } label: {
          if model.isRetryingUnavailableScalarSettings(in: domain) {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text(model.language == .english ? "Retrying…" : "正在重试…")
            }
          } else {
            Text(model.language == .english ? "Retry Loading" : "重试加载")
          }
        }
        .disabled(model.isRetryingUnavailableScalarSettings(in: domain))
        .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue).retry")
      }
    }
    .accessibilityIdentifier("settings.scalar-unavailable.\(domain.rawValue)")
  }

  @ViewBuilder
  private func globalInputPermissionRow(_ capability: GlobalInputCapability) -> some View {
    let title = UIStrings.text(.globalInput, language: model.language)
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(globalInputPermissionDetail(capability))
          .font(.caption)
          .foregroundStyle(globalInputPermissionColor(capability))
      }
      Spacer()
      switch capability {
      case .checking, .available:
        EmptyView()
      case .permissionRequired:
        Button(UIStrings.text(.requestAccess, language: model.language)) {
          model.requestGlobalInputPermission()
        }
        .accessibilityIdentifier("settings.global-input.request")
      case .installationFailed:
        Button(UIStrings.text(.retryGlobalInput, language: model.language)) {
          model.retryGlobalInputInstallation()
        }
        .accessibilityIdentifier("settings.global-input.retry")
      }
    }
    .accessibilityIdentifier("settings.global-input.status")
  }

  private func globalInputPermissionDetail(_ capability: GlobalInputCapability) -> String {
    let key: UIStrings.Key =
      switch capability {
      case .checking:
        .voiceSetupGlobalInputChecking
      case .available:
        ClipboardPanelShortcutPresentationPolicy.globalInputReadyDetail(
          clipboardCaptureEnabled: model.clipboardCaptureEnabled
        )
      case .permissionRequired:
        .voiceSetupGlobalInputPermissionNeeded
      case .installationFailed:
        .voiceSetupGlobalInputInstallationFailed
      }
    return UIStrings.text(key, language: model.language)
  }

  private func globalInputPermissionColor(_ capability: GlobalInputCapability) -> Color {
    switch capability {
    case .checking:
      .secondary
    case .available:
      .green
    case .permissionRequired:
      .orange
    case .installationFailed:
      .red
    }
  }

  private var speechEngineSection: some View {
    settingsDisclosure(.speech) {
      ForEach(
        [
          ScalarSettingsDomain.speechRoute,
          .localSpeech,
        ].filter { model.hasUnavailableScalarSettings(in: $0) }
      ) { domain in
        unavailableScalarSettingsWarning(domain)
      }

      if !model.localSpeechAvailability.isAvailable {
        Label(
          UIStrings.localSpeechAvailabilityDescription(
            model.localSpeechAvailability,
            language: model.language
          ),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("settings.local-speech-unavailable")
      }

      Text(
        model.language == .english
          ? "Models are enabled here; each workflow chooses its STT model, TTS model, voice, language, prompt, and streaming style."
          : "在这里启用模型；每个 workflow 独立选择 STT 模型、TTS 模型、音色、语言、提示词和流式风格。"
      )
        .font(.caption)
        .foregroundStyle(.secondary)

      if let metadataError = model.downloadedLocalSpeechModelsError {
        settingsDomainLoadFailure(
          message: metadataError,
          retryIdentifier: "settings.local-speech-metadata.retry"
        )
      }

      VStack(alignment: .leading, spacing: 8) {
          Text(UIStrings.text(.settingsLocalSpeech, language: model.language))
            .font(.subheadline.weight(.medium))

          if model.localSpeechTrustMaterialAvailable {
            Text(
              UIStrings.localSpeechAvailabilityDescription(
                model.localSpeechAvailability,
                language: model.language
              )
            )
            .foregroundStyle(.secondary)

            speechModelPoolSettings

            if model.speechModelResourceCatalog.isEmpty {
            if !model.trustedLocalSpeechModels.isEmpty {
              Picker(
                UIStrings.text(.localSpeechModel, language: model.language),
                selection: Binding(
                  get: { model.selectedTrustedLocalSpeechModelIdentifier },
                  set: { _ = model.setPreferredLocalSpeechModel($0) }
                )
              ) {
                ForEach(modelsForSelectedLocalSpeechEngine) { descriptor in
                  Text(
                    model.language == .english
                      ? descriptor.englishName
                      : descriptor.simplifiedChineseName
                  )
                  .tag(descriptor.id)
                }
              }
              .pickerStyle(.menu)
              .disabled(
                model.isLoadingSettings
                  || !model.canMutateScalarSettings(in: .localSpeech)
              )
              .accessibilityIdentifier("settings.local-speech.model")

              if let descriptor = modelsForSelectedLocalSpeechEngine.first(where: {
                $0.id == model.selectedTrustedLocalSpeechModelIdentifier
              }) {
                Text(
                  model.language == .english
                    ? descriptor.englishDetail
                    : descriptor.simplifiedChineseDetail
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.local-speech.trusted-model-detail")
                Text(model.localSpeechModelHardwareDescription(descriptor))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier(
                    "settings.local-speech.trusted-model-hardware"
                  )
                if model.recommendedLocalSpeechModelIdentifier != descriptor.id {
                  Button(
                    model.language == .english
                      ? "Use hardware recommendation"
                      : "使用硬件推荐"
                  ) {
                    model.selectRecommendedLocalSpeechModel()
                  }
                  .controlSize(.small)
                  .disabled(model.isLoadingSettings)
                  .accessibilityIdentifier(
                    "settings.local-speech.use-hardware-recommendation"
                  )
                }
                Text(
                  model.language == .english
                    ? "Live preview uses the workflow's Qwen model; the sealed WAV is always recognized offline for the authoritative final text."
                    : "实时预览使用 workflow 选择的 Qwen 模型；录音封口后始终以 WAV 离线识别生成唯一正式文本。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.local-speech.streaming-preview-model")
              }
            } else {
              Picker(
                UIStrings.text(.localSpeechModel, language: model.language),
                selection: $model.localSpeechModelOption
              ) {
                ForEach(LegacyWhisperModelOption.allCases) { option in
                  Text(model.localSpeechModelOptionLabel(option))
                    .tag(option)
                }
              }
              .pickerStyle(.menu)
            }

            }

            if model.trustedLocalSpeechModels.isEmpty {
              if !model.downloadedLocalSpeechModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                  Text(UIStrings.text(.localSpeechDownloadedModels, language: model.language))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                  ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                      ForEach(model.downloadedLocalSpeechModels, id: \.self) { modelIdentifier in
                        Button(
                          model.localSpeechModelDisplayName(modelIdentifier, includeStatus: true)
                        ) {
                          model.useDownloadedLocalSpeechModel(modelIdentifier)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isLoadingSettings)
                      }
                    }
                  }
                }
              }

              if model.localSpeechModelOption == .custom {
                VStack(alignment: .leading, spacing: 8) {
                  TextField(
                    UIStrings.text(.legacyWhisperKitCustomModel, language: model.language),
                    text: $model.legacyWhisperKitCustomModel
                  )
                  .textFieldStyle(.roundedBorder)
                  .onSubmit {
                    model.prepareLocalSpeechModel()
                  }

                  HStack(alignment: .center, spacing: 12) {
                    Text(UIStrings.text(.legacyWhisperKitCustomModelHint, language: model.language))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Spacer()
                    Button(UIStrings.text(.localSpeechPrepare, language: model.language)) {
                      model.prepareLocalSpeechModel()
                    }
                    .disabled(model.isLoadingSettings)
                  }
                }
              }
            }

            if model.localSpeechPreparationState == .preparing {
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(
                    UIStrings.text(
                      model.localSpeechPreparationProgress >= 1
                        ? .localSpeechFinalizing
                        : .localSpeechPreparing,
                      language: model.language
                    )
                  )
                  .foregroundStyle(.secondary)
                  Spacer()
                  if model.localSpeechPreparationProgress < 1 {
                    Text(
                      model.localSpeechPreparationProgress,
                      format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                  }
                  Button(UIStrings.text(.localSpeechCancelPreparation, language: model.language)) {
                    model.cancelLocalSpeechModelPreparation()
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .accessibilityIdentifier("settings.local-speech.cancel-preparation")
                }
                if model.localSpeechPreparationProgress >= 1 {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  ProgressView(value: model.localSpeechPreparationProgress, total: 1)
                    .controlSize(.small)
                    .progressViewStyle(.linear)
                }
              }
            } else if model.localSpeechPreparationState == .ready {
              VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Label(
                    UIStrings.text(.localSpeechPreparationReady, language: model.language),
                    systemImage: "checkmark.circle.fill"
                  )
                  .foregroundStyle(.green)

                  Spacer()

                  Button(
                    UIStrings.text(.localSpeechReleaseMemory, language: model.language)
                  ) {
                    model.releaseLocalSpeechModelMemory()
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                  .help(
                    UIStrings.text(
                      .localSpeechReleaseMemoryHint,
                      language: model.language
                    )
                  )
                  .accessibilityIdentifier("settings.local-speech.release-memory")
                }

                if let preparedModel = model.localSpeechPreparedModelIdentifier {
                  Text(preparedModel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
              }
            }

            if let testWorkflow = model.localSpeechTestWorkflow {
              VStack(alignment: .leading, spacing: 4) {
                Button(model.workflowRunButtonTitle(for: testWorkflow)) {
                  model.runWorkflow(testWorkflow)
                }
                .disabled(
                  !model.canTriggerWorkflow(testWorkflow)
                    || model.localSpeechPreparationState == .preparing
                )
                .accessibilityIdentifier("settings.local-speech.record-test")

                Text(UIStrings.text(.localSpeechLocalTestHint, language: model.language))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            Text(
              UIStrings.text(
                model.trustedLocalSpeechModels.isEmpty
                  ? .localSpeechPreparationHint
                  : .localSpeechTrustedCatalogHint,
                language: model.language
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = model.localSpeechPreparationError, !error.isEmpty {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        }
      .disabled(model.hasUnavailableScalarSettings(in: .localSpeech))

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        Text(L10n.string(.settingsOpenAITitle, language: model.language))
          .font(.subheadline.weight(.medium))
        Text(L10n.string(.settingsOpenAIDescription, language: model.language))
          .foregroundStyle(.secondary)

        switch model.openAICredentialAvailability {
        case .loading:
          ProgressView(UIStrings.text(.voiceSetupLoading, language: model.language))
            .controlSize(.small)
        case .saving:
          ProgressView(L10n.string(.settingsOpenAISaving, language: model.language))
            .controlSize(.small)
        case .missing:
          Label(
            L10n.string(.settingsOpenAIMissing, language: model.language),
            systemImage: "key.slash"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        case .available:
          Label(
            L10n.string(.settingsOpenAIAvailable, language: model.language),
            systemImage: "checkmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(.green)
        case .inaccessible:
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(
              L10n.string(.settingsOpenAIInaccessible, language: model.language),
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
            Spacer()
            Button(UIStrings.text(.retryCredentialLoad, language: model.language)) {
              model.retryOpenAICredentialLoad()
            }
          }
        }

        providerInputRow(L10n.string(.settingsOpenAIAPIKey, language: model.language)) {
          SecureField("", text: $model.openAIAPIKey)
            .textFieldStyle(.roundedBorder)
            .disabled(model.openAICredentialAvailability == .inaccessible)
            .accessibilityIdentifier("settings.openai.api-key")
        }

        providerInputRow(L10n.string(.settingsOpenAIBaseURL, language: model.language)) {
          TextField("", text: $model.openAIBaseURL)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("settings.openai.base-url")
        }

        Text(L10n.string(.settingsOpenAIEndpointHint, language: model.language))
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker(
          L10n.string(.settingsOpenAIModel, language: model.language),
          selection: openAIModelSelection
        ) {
          ForEach(OpenAIModelSelection.allCases) { selection in
            Text(openAIModelLabel(selection)).tag(selection)
          }
        }
        .pickerStyle(.menu)
        .disabled(model.hasUnavailableScalarSettings(in: .openAI))
        .accessibilityIdentifier("settings.openai.model")

        Text(
          model.language == .english
            ? "Model ID: \(model.openAIModel)"
            : "模型 ID：\(model.openAIModel)"
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

        if openAIModelSelection.wrappedValue == .custom {
          providerInputRow(
            L10n.string(.settingsOpenAICustomModel, language: model.language)
          ) {
            TextField("", text: $model.openAIModel)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("settings.openai.custom-model")
          }
        }

        HStack(spacing: 10) {
          Button(L10n.string(.settingsOpenAIVerify, language: model.language)) {
            model.verifyOpenAIConfiguration()
          }
          .disabled(!model.canVerifyOpenAIConfiguration)
          .accessibilityIdentifier("settings.openai.verify")

          switch model.openAIConfigurationVerificationState {
          case .idle:
            EmptyView()
          case .verifying:
            ProgressView(L10n.string(.settingsOpenAIVerifying, language: model.language))
              .controlSize(.small)
          case .verified:
            Label(
              L10n.string(.settingsOpenAIVerificationSucceeded, language: model.language),
              systemImage: "checkmark.seal.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
          case .failed:
            Label(
              openAIVerificationFailureMessage,
              systemImage: "xmark.octagon.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
          }
        }

        if usesThirdPartyOpenAIEndpoint {
          Text(thirdPartyOpenAICompatibilityHint)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text(L10n.string(.settingsOpenAITranscriptOnlyHint, language: model.language))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .disabled(model.openAIConfigurationVerificationState == .verifying)

      Text(UIStrings.text(.settingsSpeechEngineDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var openAIModelSelection: Binding<OpenAIModelSelection> {
    Binding(
      get: { OpenAIModelSelection(modelIdentifier: model.openAIModel) },
      set: { selection in
        if let modelIdentifier = selection.modelIdentifier {
          model.openAIModel = modelIdentifier
        } else if OpenAIModelOption(rawValue: model.openAIModel) != nil {
          model.openAIModel = ""
        }
      }
    )
  }

  private func openAIModelLabel(_ selection: OpenAIModelSelection) -> String {
    switch selection {
    case .luna:
      model.language == .english
        ? "Luna — high volume (gpt-5.6-luna)"
        : "Luna — 高吞吐 (gpt-5.6-luna)"
    case .terra:
      model.language == .english
        ? "Terra — balanced (gpt-5.6-terra)"
        : "Terra — 均衡 (gpt-5.6-terra)"
    case .sol:
      model.language == .english
        ? "Sol — highest capability (gpt-5.6-sol)"
        : "Sol — 最高能力 (gpt-5.6-sol)"
    case .custom:
      model.language == .english ? "Custom model ID" : "自定义模型 ID"
    }
  }

  private var usesThirdPartyOpenAIEndpoint: Bool {
    guard let host = URLComponents(string: model.openAIBaseURL)?.host?.lowercased() else {
      return false
    }
    return host != "api.openai.com"
  }

  private var thirdPartyOpenAICompatibilityHint: String {
    switch model.language {
    case .english:
      "Verification uses the exact model ID shown above. Third-party providers must expose gpt-5.6-luna for the Luna preset to succeed."
    case .simplifiedChinese:
      "验证会使用上方显示的准确模型 ID。使用 Luna 预设时，第三方服务必须实际开放 gpt-5.6-luna。"
    }
  }

  private var openAIVerificationFailureMessage: String {
    switch (model.language, model.openAIVerificationFailure) {
    case (.english, .credentialUnavailable):
      "The saved API key could not be loaded."
    case (.simplifiedChinese, .credentialUnavailable):
      "无法读取已保存的 API Key。"
    case (.english, .configurationInvalid):
      "The endpoint rejected this request or model ID. Check the exact model available from the provider."
    case (.simplifiedChinese, .configurationInvalid):
      "该地址拒绝了当前请求或模型 ID。请核对服务商实际开放的模型 ID。"
    case (.english, .authenticationFailed):
      "Authentication failed. Check whether the API key belongs to this endpoint."
    case (.simplifiedChinese, .authenticationFailed):
      "身份验证失败。请确认 API Key 属于当前服务地址。"
    case (.english, .rateLimited):
      "The account is rate limited or has insufficient quota. Check the provider account and retry."
    case (.simplifiedChinese, .rateLimited):
      "账号受到限流或额度不足。请检查服务商账号后重试。"
    case (.english, .timedOut):
      "The verification request timed out."
    case (.simplifiedChinese, .timedOut):
      "验证请求超时。"
    case (.english, .networkFailed):
      "The endpoint could not be reached. Check the network and Base URL."
    case (.simplifiedChinese, .networkFailed):
      "无法连接该地址。请检查网络和 Base URL。"
    case (.english, .refused):
      "The model refused the verification request."
    case (.simplifiedChinese, .refused):
      "模型拒绝了验证请求。"
    case (.english, .incomplete):
      "The endpoint returned an incomplete response."
    case (.simplifiedChinese, .incomplete):
      "服务返回了不完整响应。"
    case (.english, .invalidResponse):
      "The endpoint returned empty content or an unrecognized Responses API payload."
    case (.simplifiedChinese, .invalidResponse):
      "服务返回了空内容或无法识别的 Responses API 响应。"
    case (.english, .unknown), (.english, nil):
      L10n.string(.settingsOpenAIVerificationFailed, language: .english)
    case (.simplifiedChinese, .unknown), (.simplifiedChinese, nil):
      L10n.string(.settingsOpenAIVerificationFailed, language: .simplifiedChinese)
    }
  }

  private func providerInputRow<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      content()
        .environment(\.layoutDirection, .leftToRight)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var localDataAndRetentionSection: some View {
    settingsDisclosure(.storage) {
      Picker(
        L10n.historySettingsText(.clipboardRetention, language: model.language),
        selection: Binding(
          get: { model.clipboardHistoryRetentionPeriod },
          set: { model.setClipboardHistoryRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Picker(
        L10n.historySettingsText(.runRetention, language: model.language),
        selection: Binding(
          get: { model.runHistoryRetentionPeriod },
          set: { model.setRunHistoryRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Divider()

      Toggle(
        L10n.string(.settingsFailedAudioRecovery, language: model.language),
        isOn: Binding(
          get: { model.failedAudioRecoveryEnabled },
          set: { model.setFailedAudioRecoveryEnabled($0) }
        )
      )
      .disabled(
        model.isLoadingSettings
          || model.isUpdatingFailedAudioRecovery
          || !model.retryingFailedAudioRecoveryIDs.isEmpty
      )

      Text(
        L10n.string(
          .settingsFailedAudioRecoveryDescription,
          language: model.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Button(
          L10n.string(
            .settingsFailedAudioRecoveryClear,
            language: model.language
          ),
          role: .destructive
        ) {
          destructiveConfirmation = .failedAudioRecovery
        }
        .disabled(
          model.failedAudioRecoveryReceipts.isEmpty
            || model.isUpdatingFailedAudioRecovery
            || !model.retryingFailedAudioRecoveryIDs.isEmpty
        )
        Spacer()
        if !model.failedAudioRecoveryReceipts.isEmpty {
          Text(
            model.language == .english
              ? "\(model.failedAudioRecoveryReceipts.count) encrypted"
              : "已加密 \(model.failedAudioRecoveryReceipts.count) 条"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      if let error = model.failedAudioRecoveryError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button(
            L10n.historySettingsText(.clearClipboard, language: model.language),
            role: .destructive
          ) {
            destructiveConfirmation = .clipboardHistory
          }
          .disabled(
            localHistoryControlsDisabled || !model.isLocalHistoryMaintenanceAvailable
          )
          Spacer()
        }
        Text(
          L10n.historySettingsText(
            .preservedClipboardDetail,
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button(
            L10n.historySettingsText(.clearRun, language: model.language),
            role: .destructive
          ) {
            destructiveConfirmation = .runHistory
          }
          .disabled(!model.canClearRunHistory || !model.isLocalHistoryMaintenanceAvailable)
          Spacer()
        }
        Text(
          L10n.historySettingsText(
            .preservedRunDetail,
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.hasActiveOrQueuedVoiceRun {
          Text(L10n.historySettingsText(.runActiveHint, language: model.language))
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      if let error = model.historyRetentionSettingsError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      if model.isLocalHistoryMaintenanceRunning {
        Label(
          L10n.historySettingsText(.maintenanceRunning, language: model.language),
          systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if let pendingReason = model.localHistoryMaintenancePendingReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(pendingReason, systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.orange)
          retryLocalHistoryMaintenanceButton
        }
      } else if let blockedReason = model.localHistoryMaintenanceBlockedReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(blockedReason, systemImage: "exclamationmark.octagon")
            .font(.caption)
            .foregroundStyle(.red)
          retryLocalHistoryMaintenanceButton
        }
      } else if model.lastLocalHistoryRemovedCount > 0
        || model.lastPreservedActiveClipboardCount > 0
      {
        Label(
          L10n.historyMaintenanceResult(
            removedCount: model.lastLocalHistoryRemovedCount,
            preservedActiveClipboardCount: model.lastPreservedActiveClipboardCount,
            language: model.language
          ),
          systemImage: "checkmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Text(L10n.historySettingsText(.description, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var localHistoryControlsDisabled: Bool {
    model.isLoadingSettings || model.isUpdatingHistoryRetentionSettings
      || model.isLocalHistoryMaintenanceRunning
  }

  private var retryLocalHistoryMaintenanceButton: some View {
    Button(L10n.historySettingsText(.retry, language: model.language)) {
      model.retryPendingLocalHistoryMaintenance()
    }
    .buttonStyle(.bordered)
    .disabled(
      localHistoryControlsDisabled || !model.isLocalHistoryMaintenanceAvailable
    )
  }

  private var availableLocalSpeechEngines: [LocalSpeechEngine] {
    LocalSpeechEngine.allCases.filter { engine in
      model.trustedLocalSpeechModels.contains(where: { $0.engine == engine })
    }
  }

  private var selectedLocalSpeechEngine: LocalSpeechEngine? {
    model.trustedLocalSpeechModels.first(where: {
      $0.id == model.selectedTrustedLocalSpeechModelIdentifier
    })?.engine ?? availableLocalSpeechEngines.first
  }

  private var modelsForSelectedLocalSpeechEngine: [LocalSpeechModelDescriptor] {
    guard let selectedLocalSpeechEngine else { return [] }
    return model.trustedLocalSpeechModels.filter {
      $0.engine == selectedLocalSpeechEngine
    }
  }

  private var privacySection: some View {
    settingsDisclosure(.privacy) {
      if model.isLoadingPrivacySettings {
        Label(
          L10n.privacyText(.loading, language: model.language),
          systemImage: "hourglass"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if let loadError = model.privacySettingsLoadError {
        VStack(alignment: .leading, spacing: 6) {
          Label(loadError, systemImage: "exclamationmark.shield")
            .font(.caption)
            .foregroundStyle(.red)
          HStack {
            Button(L10n.privacyText(.retryLoad, language: model.language)) {
              model.retryPrivacySettingsLoad()
            }
            Button(
              L10n.privacyText(.resetSafeDefaults, language: model.language),
              role: .destructive
            ) {
              model.resetPrivacySettingsToSafeDefaults()
            }
          }
          .buttonStyle(.bordered)
          .disabled(model.isLoadingPrivacySettings)
        }
      }

      if let saveError = model.privacySettingsSaveError {
        VStack(alignment: .leading, spacing: 6) {
          Label(saveError, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
          Button(L10n.privacyText(.retrySave, language: model.language)) {
            model.retryPrivacySettingsSave()
          }
          .buttonStyle(.bordered)
        }
      } else if model.isSavingPrivacySettings {
        Label(
          L10n.privacyText(.saving, language: model.language),
          systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text(L10n.privacyText(PrivacySettingsTextKey.description, language: model.language))
        .font(.callout)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        Button {
          guard let privacyNoticeDocument else { return }
          presentedSheet = .privacyNotice(privacyNoticeDocument)
        } label: {
          Label(
            L10n.privacyText(.technicalNotice, language: model.language),
            systemImage: "hand.raised.square"
          )
        }
        .disabled(privacyNoticeDocument == nil)
        .accessibilityIdentifier("settings.privacy.technical-notice")

        Text(
          L10n.privacyText(
            privacyNoticeDocument == nil
              ? .technicalNoticeUnavailable
              : .technicalNoticeDescription,
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(privacyNoticeDocument == nil ? .red : .secondary)
      }

      Toggle(
        L10n.privacyText(PrivacySettingsTextKey.cloudConfirmation, language: model.language),
        isOn: Binding(
          get: { model.privacyPolicySettings.cloudConfirmationRequired },
          set: { model.setPrivacyCloudConfirmationRequired($0) }
        )
      )
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(
          PrivacySettingsTextKey.cloudConfirmationDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if !model.privacyPolicySettings.cloudProcessingAuthorizations.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(
              L10n.privacyText(.cloudAlwaysAllowed, language: model.language)
            )
            .font(.callout.weight(.medium))
            Spacer()
            Button(
              L10n.privacyText(.revokeAllAuthorizations, language: model.language)
            ) {
              model.revokeAllCloudProcessingAuthorizations()
            }
            .disabled(privacySettingsControlsDisabled)
          }

          ForEach(
            model.privacyPolicySettings.cloudProcessingAuthorizations.sorted {
              $0.grantedAt > $1.grantedAt
            }
          ) { authorization in
            HStack {
              Label(authorization.workflowName, systemImage: "cloud")
                .lineLimit(1)
              Spacer()
              Button(
                L10n.privacyText(.revokeAuthorization, language: model.language)
              ) {
                model.revokeCloudProcessingAuthorization(authorization.id)
              }
              .buttonStyle(.borderless)
              .disabled(privacySettingsControlsDisabled)
            }
          }

          Text(
            L10n.privacyText(.cloudAlwaysAllowedDescription, language: model.language)
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      }

      Toggle(
        L10n.privacyText(
          PrivacySettingsTextKey.secureInputConservativeMode, language: model.language),
        isOn: Binding(
          get: { model.privacyPolicySettings.secureInputConservativeMode },
          set: { model.setPrivacySecureInputConservativeMode($0) }
        )
      )
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(
          PrivacySettingsTextKey.secureInputConservativeDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Picker(
        L10n.privacyText(PrivacySettingsTextKey.historyPreviewMode, language: model.language),
        selection: Binding(
          get: { model.privacyPolicySettings.historyPreviewMode },
          set: { model.setPrivacyHistoryPreviewMode($0) }
        )
      ) {
        ForEach(PrivacyHistoryPreviewMode.allCases, id: \.rawValue) { mode in
          Text(L10n.privacySettingsHistoryPreviewMode(mode, language: model.language)).tag(mode)
        }
      }
      .pickerStyle(.menu)
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(PrivacySettingsTextKey.historyPreviewDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(L10n.privacyText(PrivacySettingsTextKey.sensitiveApps, language: model.language))
            .font(.subheadline.weight(.medium))
          Spacer()
          Button(L10n.privacyText(.restoreRecommended, language: model.language)) {
            restoreRecommendedSensitiveAppRules()
          }
          .buttonStyle(.bordered)
          .disabled(privacySettingsControlsDisabled)
        }
        Text(
          L10n.privacyText(
            PrivacySettingsTextKey.sensitiveAppsDescription, language: model.language)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      sensitiveAppRuleEditor
        .disabled(privacySettingsControlsDisabled)

      ForEach(model.privacyPolicySettings.sensitiveAppRules) { rule in
        sensitiveAppRuleRow(rule)
          .disabled(privacySettingsControlsDisabled)
      }
    }
  }

  private var privacySettingsControlsDisabled: Bool {
    model.isLoadingPrivacySettings || model.privacySettingsLoadError != nil
  }

  private var sensitiveAppRuleEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        L10n.privacyText(.bundleIdentifier, language: model.language),
        text: $sensitiveAppBundleIdentifier
      )
      .textFieldStyle(.roundedBorder)

      TextField(
        L10n.privacyText(.applicationNameOptional, language: model.language),
        text: $sensitiveAppApplicationName
      )
      .textFieldStyle(.roundedBorder)

      if let sensitiveAppRuleError {
        Label(sensitiveAppRuleError, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        if editingSensitiveAppRuleID != nil {
          Button(L10n.privacyText(.cancelEdit, language: model.language)) {
            resetSensitiveAppRuleEditor()
          }
        }
        Button(
          L10n.privacyText(
            editingSensitiveAppRuleID == nil ? .addRule : .saveRule,
            language: model.language
          )
        ) {
          saveSensitiveAppRule()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 4)
  }

  private func sensitiveAppRuleRow(_ rule: SensitiveAppRule) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        L10n.privacyText(PrivacySettingsTextKey.ruleEnabled, language: model.language),
        isOn: Binding(
          get: { sensitiveAppRule(rule.id)?.enabled ?? rule.enabled },
          set: { model.setSensitiveAppRuleEnabled(rule.id, isEnabled: $0) }
        )
      )
      .font(.subheadline.weight(.medium))

      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(rule.displayName)
            .font(.subheadline.weight(.medium))
          Text(rule.bundleIdentifier)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
        if rule.isRecommended {
          Text(L10n.privacyText(.recommendedRule, language: model.language))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Button(L10n.privacyText(.editRule, language: model.language)) {
            beginEditingSensitiveAppRule(rule)
          }
          .buttonStyle(.borderless)
          Button(role: .destructive) {
            deleteSensitiveAppRule(rule)
          } label: {
            Text(L10n.privacyText(.deleteRule, language: model.language))
          }
          .buttonStyle(.borderless)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksClipboard, language: model.language),
          isOn: Binding(
            get: {
              sensitiveAppRule(rule.id)?.blocksClipboardHistory ?? rule.blocksClipboardHistory
            },
            set: { model.setSensitiveAppRuleBlocksClipboardHistory(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksWorkflow, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksWorkflowCapture ?? rule.blocksWorkflowCapture },
            set: { model.setSensitiveAppRuleBlocksWorkflowCapture(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksSelectedText, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksSelectedText ?? rule.blocksSelectedText },
            set: { model.setSensitiveAppRuleBlocksSelectedText(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksCloud, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksCloudProcessing ?? rule.blocksCloudProcessing },
            set: { model.setSensitiveAppRuleBlocksCloudProcessing(rule.id, blocks: $0) }
          )
        )
      }
      .toggleStyle(.checkbox)
      .font(.caption)
    }
    .padding(.vertical, 4)
  }

  private func sensitiveAppRule(_ ruleID: UUID) -> SensitiveAppRule? {
    model.privacyPolicySettings.sensitiveAppRules.first { $0.id == ruleID }
  }

  private func saveSensitiveAppRule() {
    do {
      let name = trimmedOptional(sensitiveAppApplicationName)
      if let editingSensitiveAppRuleID {
        try model.editSensitiveAppRule(
          editingSensitiveAppRuleID,
          bundleIdentifier: sensitiveAppBundleIdentifier,
          applicationName: name
        )
      } else {
        try model.addSensitiveAppRule(
          bundleIdentifier: sensitiveAppBundleIdentifier,
          applicationName: name
        )
      }
      resetSensitiveAppRuleEditor()
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  private func beginEditingSensitiveAppRule(_ rule: SensitiveAppRule) {
    editingSensitiveAppRuleID = rule.id
    sensitiveAppBundleIdentifier = rule.bundleIdentifier
    sensitiveAppApplicationName = rule.applicationName ?? ""
    sensitiveAppRuleError = nil
  }

  private func deleteSensitiveAppRule(_ rule: SensitiveAppRule) {
    do {
      try model.deleteSensitiveAppRule(rule.id)
      if editingSensitiveAppRuleID == rule.id {
        resetSensitiveAppRuleEditor()
      }
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  private func restoreRecommendedSensitiveAppRules() {
    do {
      try model.restoreRecommendedSensitiveAppRules()
      sensitiveAppRuleError = nil
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  private func resetSensitiveAppRuleEditor() {
    editingSensitiveAppRuleID = nil
    sensitiveAppBundleIdentifier = ""
    sensitiveAppApplicationName = ""
    sensitiveAppRuleError = nil
  }

  private func localizedSensitiveAppRuleError(_ error: Error) -> String {
    guard let validationError = error as? SensitiveAppRuleValidationError else {
      return model.language == .english
        ? "The privacy rule could not be updated. Review the rule and retry."
        : "无法更新隐私规则。请检查规则后重试。"
    }
    let key: PrivacySettingsTextKey
    switch validationError {
    case .missingBundleIdentifier:
      key = .missingBundleIdentifier
    case .invalidBundleIdentifier:
      key = .invalidBundleIdentifier
    case .duplicateBundleIdentifier, .duplicateRuleIdentifier:
      key = .duplicateBundleIdentifier
    case .recommendedRuleCannotBeEdited:
      key = .recommendedRuleCannotBeEdited
    case .ruleNotFound:
      key = .ruleNotFound
    }
    return L10n.privacyText(key, language: model.language)
  }

  private var vocabularySection: some View {
    settingsDisclosure(.vocabulary) {
      if let vocabularyRulesError = model.vocabularyRulesError {
        settingsDomainLoadFailure(
          message: vocabularyRulesError,
          retryIdentifier: "settings.vocabulary.retry"
        )
      }

      VStack(alignment: .leading, spacing: 10) {
        Text(
          model.language == .english
            ? "Hotwords and replacements now live in reusable collections attached to workflow Setup."
            : "热词与替换词现在位于可复用词库中，并在工作流 Setup 阶段绑定。"
        )
          .font(.callout)
          .foregroundStyle(.secondary)

        ForEach(model.vocabularyCollections) { collection in
          HStack {
            Label(
              collection.name,
              systemImage: collection.enabled
                ? "text.book.closed.fill"
                : "text.book.closed"
            )
            Spacer()
            Text("\(collection.entries.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }

        Button {
          model.selectSidebarSection(.workflows)
        } label: {
          Label(
            model.language == .english
              ? "Manage Collections and Workflow Bindings"
              : "管理词库与工作流绑定",
            systemImage: SidebarSection.workflows.symbolName
          )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.vocabulary.open-workflows")
      }
      .disabled(!model.areVocabularyRulesAvailable)
    }
    .disabled(model.isLoadingSettings)
  }

  private func settingsDomainLoadFailure(
    message: String,
    retryIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.orange)
      Button(L10n.historySettingsText(.retry, language: model.language)) {
        model.retryUnavailableStoredSettingsDomains()
      }
      .buttonStyle(.bordered)
      .disabled(model.isRetryingUnavailableSettingsDomains)
      .accessibilityIdentifier(retryIdentifier)
    }
  }

  private var vocabularyRuleKinds: [VocabularyRuleKind] {
    [.hotword, .mapping]
  }

  private var vocabularyMatchModes: [VocabularyMatchMode] {
    [.exactPhrase, .wordBoundary, .regex]
  }

  private var vocabularyGroupChoices: [ClipboardGroupSummary] {
    var summaries = [model.clipboardDefaultGroup]
    summaries.append(
      contentsOf: model.clipboardGroups.filter {
        $0.group.id != model.clipboardDefaultGroup.group.id
      })
    return summaries
  }

  private func vocabularyRuleRow(_ rule: VocabularyRule) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        UIStrings.targetedAccessibilityLabel(
          .vocabularyRule,
          target: vocabularyRuleTitle(rule),
          language: model.language
        ),
        isOn: Binding(
          get: { rule.enabled },
          set: { model.setVocabularyRuleEnabled(rule.id, isEnabled: $0) }
        )
      )
      .labelsHidden()
      .accessibilityIdentifier("vocabulary.rule.\(rule.id.uuidString).enabled")

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(L10n.vocabularyRuleKind(rule.kind, language: model.language))
            .font(.caption.weight(.semibold))
          if rule.kind == .mapping {
            Text(L10n.vocabularyMatchMode(rule.matchMode, language: model.language))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text(vocabularyRuleTitle(rule))
          .font(.subheadline.weight(.medium))

        Text(vocabularyScopeSummary(rule.scope))
          .font(.caption)
          .foregroundStyle(.secondary)

        if rule.kind == .hotword {
          Text(L10n.string(.vocabularyHotwordBehavior, language: model.language))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Button(role: .destructive) {
        model.deleteVocabularyRule(rule.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        UIStrings.targetedAccessibilityLabel(
          .vocabularyDeleteRule,
          target: vocabularyRuleTitle(rule),
          language: model.language
        )
      )
      .accessibilityIdentifier("vocabulary.rule.\(rule.id.uuidString).delete")
    }
  }

  private func vocabularyRuleTitle(_ rule: VocabularyRule) -> String {
    if rule.kind == .mapping, !rule.replacement.isEmpty {
      return "\(rule.pattern) → \(rule.replacement)"
    }
    return rule.pattern
  }

  private func vocabularyScopeSummary(_ scope: VocabularyRuleScope) -> String {
    L10n.vocabularyScopeSummary(
      scope,
      groupName: vocabularyGroupName(scope.clipboardGroupID),
      language: model.language
    )
  }

  private func vocabularyGroupName(_ groupID: UUID?) -> String? {
    guard let groupID else { return nil }
    return vocabularyGroupChoices.first(where: { $0.group.id == groupID })?.group.name
  }

  private func addVocabularyRule() {
    model.addVocabularyRule(
      kind: vocabularyKind,
      pattern: vocabularyPattern,
      replacement: vocabularyKind == .mapping ? vocabularyReplacement : "",
      matchMode: vocabularyMatchMode,
      caseSensitive: vocabularyCaseSensitive,
      scope: VocabularyRuleScope(
        bundleIdentifier: trimmedOptional(vocabularyBundleIdentifier),
        clipboardGroupID: vocabularyGroupID,
        locale: trimmedOptional(vocabularyLocale)
      ),
      priority: vocabularyPriority
    )
    vocabularyPattern = ""
    vocabularyReplacement = ""
    vocabularyPriority = 0
  }

  private func trimmedOptional(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var builtinPushToTalkSection: some View {
    settingsDisclosure(.input) {
      if model.hasUnavailableScalarSettings(in: .input) {
        unavailableScalarSettingsWarning(.input)
      }

      Toggle(
        L10n.string(.settingsLongRecordingMode, language: model.language),
        isOn: Binding(
          get: { model.longRecordingModeEnabled },
          set: { model.setLongRecordingModeEnabled($0) }
        )
      )
      .disabled(!model.canMutateScalarSettings(in: .input))

      Text(L10n.string(.settingsLongRecordingModeDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker(
        L10n.string(.settingsRecordingDurationLimit, language: model.language),
        selection: Binding(
          get: { model.recordingDurationLimit },
          set: { _ = model.setRecordingDurationLimit($0) }
        )
      ) {
        ForEach(RecordingDurationLimit.allCases) { limit in
          Text(UIStrings.recordingDurationLimit(limit, language: model.language)).tag(limit)
        }
      }
      .pickerStyle(.menu)
      .disabled(!model.canMutateScalarSettings(in: .input))

      Text(L10n.string(.settingsRecordingDurationLimitDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker(
        UIStrings.text(.builtinPushToTalkOutputMode, language: model.language),
        selection: Binding(
          get: { model.builtinPushToTalkOutputMode },
          set: { model.setBuiltinPushToTalkOutputMode($0) }
        )
      ) {
        ForEach(BuiltinPushToTalkOutputMode.allCases) { mode in
          Text(UIStrings.builtinPushToTalkOutputMode(mode, language: model.language)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .disabled(!model.canMutateScalarSettings(in: .input))
      Text(UIStrings.text(.settingsBuiltinPushToTalkDescription, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var speechModelPoolSettings: some View {
    if !model.speechModelResourceCatalog.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(model.language == .english ? "Available model pool" : "可用模型池")
          .font(.caption.weight(.semibold))
        Text(
          model.language == .english
            ? "Workflows choose models and voices. Enable models here, then optionally keep frequently used models resident."
            : "模型和音色由各 workflow 选择。这里仅启用可用模型，并可选择让常用模型常驻。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.speechModelPoolDegradedByMemoryPressure {
          Label(
            model.language == .english
              ? "Memory pressure unloaded resident models; they will reload on demand."
              : "因系统内存压力，常驻模型已临时卸载；下次使用时会按需重载。",
            systemImage: "memorychip"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("settings.speech-model-pool.degraded")
        }

        ForEach(model.speechModelResourceCatalog) { descriptor in
          VStack(alignment: .leading, spacing: 5) {
            Toggle(
              isOn: Binding(
                get: { model.enabledSpeechModelIDs.contains(descriptor.id) },
                set: { model.setSpeechModelEnabled(descriptor.id, enabled: $0) }
              )
            ) {
              Text(speechModelDisplayName(descriptor))
            }
            .disabled(model.isLoadingSettings)

            Toggle(
              model.language == .english ? "Keep resident" : "保持常驻",
              isOn: Binding(
                get: { model.residentSpeechModelIDs.contains(descriptor.id) },
                set: { model.setSpeechModelResident(descriptor.id, resident: $0) }
              )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(
              model.isLoadingSettings
                || !model.enabledSpeechModelIDs.contains(descriptor.id)
            )
          }
          .padding(.vertical, 2)
        }

        if let budget = model.pendingResidentSpeechModelBudget {
          VStack(alignment: .leading, spacing: 6) {
            Label(
              model.language == .english
                ? "Estimated resident memory exceeds 20%"
                : "预计常驻内存超过整机内存的 20%",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            Text(
              String(
                format: model.language == .english
                  ? "Estimated %.2f GB (%.1f%%): %@"
                  : "预计 %.2f GB（%.1f%%）：%@",
                Double(budget.estimatedPeakByteCount) / 1_073_741_824,
                budget.estimatedFraction * 100,
                budget.models.map(\.id).joined(separator: ", ")
              )
            )
            .font(.caption)
            HStack {
              Button(model.language == .english ? "Enable anyway" : "仍然启用") {
                model.confirmPendingResidentSpeechModels()
              }
              Button(model.language == .english ? "Cancel" : "取消", role: .cancel) {
                model.cancelPendingResidentSpeechModels()
              }
            }
            .controlSize(.small)
          }
          .padding(8)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      .accessibilityIdentifier("settings.speech-model-pool")
    }
  }

  private func speechModelDisplayName(
    _ descriptor: SpeechModelResourceDescriptor
  ) -> String {
    let capability = descriptor.capability == .speechToText ? "STT" : "TTS"
    let size = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: descriptor.downloadByteCount),
      countStyle: .file
    )
    return "\(capability) · \(descriptor.id) · \(size)"
  }

  private func permissionColor(_ tone: SettingsPermissionTone) -> Color {
    switch tone {
    case .success: return .green
    case .secondary: return .secondary
    case .warning: return .orange
    case .error: return .red
    }
  }
}

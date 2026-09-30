import RillCore

extension L10n {
  public static func cloudPrivacyTitle(language: AppLanguage) -> String {
    switch language {
    case .english: "Allow cloud processing?"
    case .simplifiedChinese: "允许云端处理？"
    }
  }

  public static func cloudPrivacyAllowAndRemember(language: AppLanguage) -> String {
    switch language {
    case .english: "Allow and Remember"
    case .simplifiedChinese: "允许并记住"
    }
  }

  public static func cloudPrivacyAllowOnce(language: AppLanguage) -> String {
    switch language {
    case .english: "Allow Once"
    case .simplifiedChinese: "仅这一次"
    }
  }

  public static func cloudPrivacyCancel(language: AppLanguage) -> String {
    switch language {
    case .english: "Cancel"
    case .simplifiedChinese: "取消"
    }
  }

  public static func cloudPrivacyAuthorization(language: AppLanguage) -> String {
    switch language {
    case .english:
      "Choose “Allow and Remember” to skip this prompt for this workflow and cloud-service configuration, including after restarting Rill. Revoke it anytime in Settings > Privacy, or choose “Allow Once”."
    case .simplifiedChinese:
      "选择“允许并记住”后，此工作流及云端服务配置不变时不再询问，重启 Rill 后仍然有效。可随时在“设置 > 隐私”中撤销，或选择“仅这一次”。"
    }
  }

  public static func cloudPrivacyProcessing(
    workflowName: String, sendsSpeech: Bool, sendsText: Bool, language: AppLanguage
  ) -> String {
    switch (language, sendsSpeech, sendsText) {
    case (.english, true, false):
      "The workflow “\(workflowName)” will stream microphone audio and any matching cloud-recognition terms to its cloud speech service while recording. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
    case (.simplifiedChinese, true, false):
      "工作流“\(workflowName)”会在录音期间，将麦克风音频以及范围匹配的云端识别术语流式发送到云端语音服务。Rill 会持续检查当前焦点与隐私设置；一旦变为受限状态，就会停止本次运行。本次内容尚未离开本机。"
    case (.english, false, true):
      "The workflow “\(workflowName)” will send its final transcript to the configured cloud text service for rewriting. Nothing from this run has left this Mac yet."
    case (.simplifiedChinese, false, true):
      "工作流“\(workflowName)”会将最终转写发送到已配置的云端文本服务进行润色。本次内容尚未离开本机。"
    case (.english, true, true):
      "The workflow “\(workflowName)” will stream microphone audio and matching cloud-recognition terms while recording, then send its final transcript to the configured cloud text service for rewriting. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
    case (.simplifiedChinese, true, true):
      "工作流“\(workflowName)”会在录音期间流式发送麦克风音频和范围匹配的云端识别术语，随后将最终转写发送到已配置的云端文本服务进行润色。Rill 会持续检查当前焦点与隐私设置；一旦变为受限状态，就会停止本次运行。本次内容尚未离开本机。"
    case (.english, false, false):
      "The workflow “\(workflowName)” requested cloud processing, but its cloud destination could not be classified. Cancel unless this is expected. Nothing from this run has left this Mac yet."
    case (.simplifiedChinese, false, false):
      "工作流“\(workflowName)”请求了云端处理，但无法对云端目的地进行分类。如非预期，请取消。本次内容尚未离开本机。"
    }
  }
}

import RillCore

enum JevText: CaseIterable {
  case title, open, disclosure, saveKey, clearKey, keyReady, keyNotice, fragment, candidate, score
  case select, rubric, working, close, send
  case credentialTitle, polishingTitle, returnToComparison, cancelReturn, retryPreview, privacySettings
  case providersTitle, settingsDescription, configureNotice, openSettings, invalidKey
}

extension L10n {
  static func jev(_ key: JevText, language: AppLanguage) -> String {
    switch (key, language) {
    case (.credentialTitle, .english): "Jev API Key"
    case (.credentialTitle, .simplifiedChinese): "Jev API 密钥"
    case (.polishingTitle, .english): "Jev polishing prediction"
    case (.polishingTitle, .simplifiedChinese): "Jev 润色判断"
    case (.returnToComparison, .english): "Return to candidate review"
    case (.returnToComparison, .simplifiedChinese): "返回候选比较"
    case (.cancelReturn, .english): "Cancel return"
    case (.cancelReturn, .simplifiedChinese): "取消返回"
    case (.retryPreview, .english): "Prepare a new preview"
    case (.retryPreview, .simplifiedChinese): "重新准备预览"
    case (.privacySettings, .english): "Review privacy settings…"
    case (.privacySettings, .simplifiedChinese): "查看隐私设置…"
    case (.providersTitle, .english): "API Providers"
    case (.providersTitle, .simplifiedChinese): "API 服务"
    case (.settingsDescription, .english): "One session key serves Jev candidate scoring and polishing prediction. Candidate scoring requires confirmation each time; automatic polishing prediction has a separate switch below."
    case (.settingsDescription, .simplifiedChinese): "本次会话的 Key 供候选评分与润色判断共用。候选评分每次发送前须确认；自动润色判断需单独开启下方开关。"
    case (.configureNotice, .english): "Add a Jev key in Settings → Voice & Models → API Providers."
    case (.configureNotice, .simplifiedChinese): "请在设置 → 语音与模型 → API 服务中配置 Jev Key。"
    case (.openSettings, .english): "Configure Jev API…"
    case (.openSettings, .simplifiedChinese): "配置 Jev API…"
    case (.invalidKey, .english): "Enter a TypeSafe API key with 8–512 visible ASCII characters and no spaces."
    case (.invalidKey, .simplifiedChinese): "请输入 8–512 个可见 ASCII 字符的 TypeSafe API Key，中间不能包含空格。"
    case (.title, .english): "Review with Jev"
    case (.title, .simplifiedChinese): "使用 Jev 比较候选"
    case (.open, .english): "Compare with Jev…"
    case (.open, .simplifiedChinese): "用 Jev 比较…"
    case (.disclosure, .english): "Send this query and up to 10 displayed text excerpts or file names to TypeSafe (api.typesafe.ai) for paid scoring. File contents, images, tags and source apps are not sent. Nothing is sent until you confirm below."
    case (.disclosure, .simplifiedChinese): "将此查询和最多 10 条展示的文字片段或文件名发送给 TypeSafe（api.typesafe.ai）付费评分。不发送文件内容、图片、标签和来源应用。点击下方发送按钮前不会调用云端。"
    case (.saveKey, .english): "Use this key"
    case (.saveKey, .simplifiedChinese): "暂存 Key"
    case (.clearKey, .english): "Clear key"
    case (.clearKey, .simplifiedChinese): "清除 Key"
    case (.keyReady, .english): "Key stored for this app session only; availability is checked on a real request."
    case (.keyReady, .simplifiedChinese): "Key 仅保留到退出 App；有效性在实际调用时验证。"
    case (.keyNotice, .english): "Enter a key for this session. It is not written to settings or logs."
    case (.keyNotice, .simplifiedChinese): "请输入本次使用的 Key，不写入设置或日志。"
    case (.fragment, .english): "Text excerpt (truncated)"
    case (.fragment, .simplifiedChinese): "文字片段（已截短）"
    case (.candidate, .english): "Candidate"
    case (.candidate, .simplifiedChinese): "候选内容"
    case (.score, .english): "Relevance score out of 2"
    case (.score, .simplifiedChinese): "相关程度，满分 2"
    case (.select, .english): "Select this record"
    case (.select, .simplifiedChinese): "选择此记录"
    case (.rubric, .english): "0: unrelated · 1: partly relevant · 2: directly useful. Scores are not correctness probabilities. Selection does not paste or change local order."
    case (.rubric, .simplifiedChinese): "0 不相关 · 1 部分相关 · 2 直接满足需求。分数不是正确概率；选择后不会自动粘贴，也不改变本地次序。"
    case (.working, .english): "Working… Close to cancel. A sent request may still incur usage."
    case (.working, .simplifiedChinese): "正在处理…关闭可取消。已经发出的请求仍可能计费。"
    case (.close, .english): "Close"
    case (.close, .simplifiedChinese): "关闭"
    case (.send, .english): "Send these candidates to Jev"
    case (.send, .simplifiedChinese): "发送这些候选给 Jev"
    }
  }

  static func jevError(_ error: RecordRankingError, language: AppLanguage) -> String {
    switch (error, language) {
    case (.privacyBlocked, .english): "Current privacy rules or an unknown source block cloud processing."
    case (.privacyBlocked, .simplifiedChinese): "当前隐私规则或未知来源阻止了云端处理。"
    case (.changed, .english): "The preview expired, authorization changed or records changed. Prepare a new preview."
    case (.changed, .simplifiedChinese): "预览已过期、授权或记录已变化，请重新准备预览。"
    case (.missingKey, .english): "Enter an API key first."
    case (.missingKey, .simplifiedChinese): "请先填写 API Key。"
    case (.unauthorized, .english): "TypeSafe rejected this key. Check your account and prepare a new review."
    case (.unauthorized, .simplifiedChinese): "TypeSafe 拒绝了此 Key，请检查账户后重新准备。"
    case (.invalidInput, .english): "Check the key format and query length, and select text or file-name candidates."
    case (.invalidInput, .simplifiedChinese): "请检查 Key 格式、查询长度，并选择文字或文件名候选。"
    case (.busy, .english): "The previous Jev request is still finishing. Try again after it ends."
    case (.busy, .simplifiedChinese): "上一条 Jev 请求仍在结束处理中，请稍后重试。"
    case (.rateLimited, .english): "Jev is busy or rate limited. No automatic retry was made."
    case (.rateLimited, .simplifiedChinese): "Jev 过载或限流，未自动重试。"
    case (.invalidResponse, .english): "Jev returned an invalid score response. No ranking was applied."
    case (.invalidResponse, .simplifiedChinese): "Jev 返回了无效评分，未应用结果。"
    case (.unavailable, .english): "Could not complete the Jev request. Check the network or account; it may still incur usage. No automatic retry was made."
    case (.unavailable, .simplifiedChinese): "无法完成 Jev 请求，请检查网络或账户；本次可能已产生用量，未自动重试。"
    }
  }
}

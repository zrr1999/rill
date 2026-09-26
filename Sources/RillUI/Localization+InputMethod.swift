import RillCore
import RillInputMethodContracts

enum InputMethodText {
  case description, install, repair, installing, importProfile, importNotice, importPanel
  case activationHelp, openSettings
}

extension L10n {
  static func inputMethod(_ key: InputMethodText, language: AppLanguage) -> String {
    switch (key, language) {
    case (.description, .simplifiedChinese): "自带轻量全拼词库，独立保存配置与个人词库。普通安装和修复无需退出鼠须管。"
    case (.description, .english):
      "Includes a compact Pinyin dictionary and keeps its own settings and vocabulary. Squirrel can keep running during installation or repair."
    case (.install, .simplifiedChinese): "安装 Rill 输入法"
    case (.install, .english): "Install Rill Input Method"
    case (.repair, .simplifiedChinese): "修复安装（保留词库）"
    case (.repair, .english): "Repair Installation (Keep Vocabulary)"
    case (.installing, .simplifiedChinese): "正在安装…"
    case (.installing, .english): "Installing…"
    case (.importProfile, .simplifiedChinese): "从鼠须管导入并安装…"
    case (.importProfile, .english): "Import from Squirrel and Install…"
    case (.importNotice, .simplifiedChinese):
      "仅首次安装可导入已有方案和完整个人词库。复制词库前需退出鼠须管，避免数据库仍在写入。原目录保留，之后两者可独立使用。"
    case (.importNotice, .english):
      "On first installation, you can import an existing profile and its full personal dictionary. Quit Squirrel before copying to avoid concurrent database writes. The original stays intact; both input methods can then run independently."
    case (.importPanel, .simplifiedChinese):
      "仅导入词库需要切换到 ABC 并退出鼠须管，以免复制正在写入的数据库。选择 Rime 配置目录，原目录会保留。"
    case (.importPanel, .english):
      "For dictionary import, switch to ABC and quit Squirrel to avoid copying an active database. Select the Rime profile folder; the original will be preserved."
    case (.activationHelp, .simplifiedChinese):
      "在系统设置 → 键盘 → 文字输入 → 编辑中，点 + 搜索并添加 Rill。如果搜不到，请注销并重新登录后再添加，无需重复安装。"
    case (.activationHelp, .english):
      "In System Settings → Keyboard → Text Input → Edit, click + and add Rill. If Rill is missing, log out and back in, then add it. No reinstallation is needed."
    case (.openSettings, .simplifiedChinese): "打开系统输入法设置"
    case (.openSettings, .english): "Open System Input Source Settings"
    }
  }

  static func inputMethodState(_ state: InputMethodInstallationState, language: AppLanguage)
    -> String
  {
    switch (state, language) {
    case (.notInstalled, .simplifiedChinese): "尚未安装"
    case (.notInstalled, .english): "Not installed"
    case (.needsRepair, .simplifiedChinese): "安装未完成，请修复安装。现有词库会保留。"
    case (.needsRepair, .english):
      "Installation is incomplete. Repair it to continue; your vocabulary will be preserved."
    case (.registrationPending, .simplifiedChinese): "组件已安装，等待系统识别；请注销并重新登录。"
    case (.registrationPending, .english): "Component installed; log out and back in for macOS to recognize it."
    case (.registered, .simplifiedChinese): "已安装，待添加到系统输入源"
    case (.registered, .english): "Installed; add Rill to system input sources"
    case (.enabled, .simplifiedChinese): "已添加到系统输入源，可在菜单栏选择 Rill"
    case (.enabled, .english): "Added to system input sources; select Rill in the menu bar"
    case (.selected, .simplifiedChinese): "正在使用 Rill 输入法"
    case (.selected, .english): "Rill is the current input source"
    }
  }
}

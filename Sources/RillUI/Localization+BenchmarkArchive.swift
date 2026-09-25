import RillCore

enum BenchmarkArchiveTextKey: String, CaseIterable {
  case title, disclosure, empty, selectAll, selectNone, source, chooseSource
  case microphone, synthetic, publicFixture, split, development, validation
  case cleanupPending, authorize, exported, showInFinder, close, exportSelection, completed, failed, cancelled
}

extension L10n {
  static func benchmarkArchive(_ key: BenchmarkArchiveTextKey, language: AppLanguage) -> String {
    benchmarkArchiveTable[key]?.string(for: language) ?? key.rawValue
  }

  private static let benchmarkArchiveTable: [BenchmarkArchiveTextKey: LocalizedText] = [
    .cleanupPending: .init(english: "Incomplete plaintext export could not be removed. Delete the folder after resolving the storage problem.", simplifiedChinese: "未完成的明文导出无法清理。请解决存储问题后删除该目录。"),
    .title: .init(english: "Export evaluation recordings", simplifiedChinese: "导出评测录音"),
    .disclosure: .init(english: "Selected recordings will be decrypted to local WAV files. Nothing is uploaded. Keep the folder private. Listen and add human reference text before comparing recognition quality; a missing reference is not silence.", simplifiedChinese: "选中的录音将解密为本地 WAV 文件，不会上传。请妥善保管目录，并在比较识别质量前听取录音、填写人工参考文本；缺失标注不代表静音。"),
    .empty: .init(english: "No readable archived recordings.", simplifiedChinese: "没有可读取的归档录音。"),
    .selectAll: .init(english: "Select all", simplifiedChinese: "全选"),
    .selectNone: .init(english: "Clear selection", simplifiedChinese: "取消选择"),
    .source: .init(english: "Audio source", simplifiedChinese: "录音来源"),
    .chooseSource: .init(english: "Choose source", simplifiedChinese: "请选择来源"),
    .microphone: .init(english: "Microphone", simplifiedChinese: "真实麦克风"),
    .synthetic: .init(english: "Synthetic audio", simplifiedChinese: "合成音频"),
    .publicFixture: .init(english: "Public fixture", simplifiedChinese: "公开样本"),
    .split: .init(english: "Dataset", simplifiedChinese: "数据集"),
    .development: .init(english: "Development", simplifiedChinese: "开发集"),
    .validation: .init(english: "Held-out validation", simplifiedChinese: "保留验收集"),
    .authorize: .init(english: "I authorize plaintext export of the selected recordings and confirm their source.", simplifiedChinese: "我授权导出所选录音的明文文件，并确认其来源。"),
    .exported: .init(english: "Exported. Reference text still needs annotation.", simplifiedChinese: "已导出，参考文本仍待人工标注。"),
    .showInFinder: .init(english: "Show in Finder", simplifiedChinese: "在访达中显示"),
    .close: .init(english: "Close", simplifiedChinese: "关闭"),
    .exportSelection: .init(english: "Export selected…", simplifiedChinese: "导出所选录音…"),
    .completed: .init(english: "Completed", simplifiedChinese: "已完成"),
    .failed: .init(english: "Failed", simplifiedChinese: "失败"),
    .cancelled: .init(english: "Cancelled", simplifiedChinese: "已取消"),
  ]
}

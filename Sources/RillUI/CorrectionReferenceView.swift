import RillCore
import SwiftUI

struct CorrectionReferenceView: View {
    let receipt: CorrectionReferenceReceipt
    let language: AppLanguage

    private func text(_ english: String, _ chinese: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    var body: some View {
        DisclosureGroup(text("Correction references", "纠错参考")) {
            LabeledContent(text("Pre-recording image", "录音前参考图"), value: status(receipt.image))
            LabeledContent(text("Image summary", "图片摘要"), value: status(receipt.imageSummary))
            LabeledContent(text("Memory summary", "记忆摘要"), value: status(receipt.memorySummary))
            if let vocabulary = receipt.vocabulary {
                LabeledContent(text("Vocabulary", "词库"), value: status(vocabulary.status))
                Text(text("Applicable: ", "适用：") + "\(vocabulary.eligibleCount) · "
                    + text("Included: ", "装入：") + "\(vocabulary.includedCount) · "
                    + text("Omitted by budget: ", "预算省略：") + "\(vocabulary.omittedCount) · "
                    + "\(vocabulary.encodedByteCount) bytes")
            }
            Text(text("Sent references are evidence offered to the model, not verified corrections. Images and temporary memory summaries are not saved.",
                      "已发送参考表示向模型提供了依据，不代表已确认纠正成功。原图和临时记忆摘要不保存。"))
                .foregroundStyle(.secondary)
            if let summary = receipt.screenSummary {
                Text(text("Screen observation (not a personal fact)", "屏幕观察（不代表用户事实）")).fontWeight(.medium)
                Text((summary.terms + summary.observations).joined(separator: "\n")).textSelection(.enabled)
                if receipt.imageSummary == .pending {
                    Text(text("This summary arrived after inputs were frozen and was saved to history only.",
                              "此摘要在主请求冻结后到达，仅补入历史，没有修改输出。"))
                        .foregroundStyle(.secondary)
                }
            }
            if !receipt.memoryIDs.isEmpty {
                Text(text("Related memories: ", "相关记忆：") + "\(receipt.memoryIDs.count)")
            }
        }.font(.caption)
    }

    private func status(_ value: CorrectionReferenceStatus) -> String {
        switch value {
        case .disabled: text("Off", "未开启")
        case .unavailable: text("Unavailable / skipped", "不可用，已跳过")
        case .timedOut: text("Timed out / skipped", "超时，已跳过")
        case .failed: text("Failed / skipped", "失败，已跳过")
        case .pending: text("Not ready at freeze / omitted", "冻结时未就绪，未携带")
        case .ready: text("Prepared", "已准备")
        case .sent: text("Sent as reference", "已作为参考发送")
        case .deliveryUnconfirmed: text("Request failed; delivery unconfirmed", "请求未完成，是否送达不可确认")
        case .cancelled: text("Cancelled", "已取消")
        }
    }
}

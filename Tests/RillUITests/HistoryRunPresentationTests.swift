import XCTest
@testable import RillCore
@testable import RillUI

final class HistoryRunPresentationTests: XCTestCase {
    func testEveryActionResultHasFixedBilingualCopy() {
        let expected: [WorkflowActionResultCode: (english: String, chinese: String)] = [
            .injected: ("Inserted", "已输入"),
            .copiedToClipboard: ("Copied", "已复制"),
            .pushedToStack: ("Saved to stack", "已存入堆栈"),
            .externalOutput: ("External output completed", "外部输出已完成"),
            .skipped: ("Skipped", "已跳过"),
            .cancelled: ("Cancelled", "已取消"),
            .failed: ("Failed", "失败"),
        ]

        XCTAssertEqual(Set(expected.keys), Set(WorkflowActionResultCode.allCases))
        for result in WorkflowActionResultCode.allCases {
            let copy = expected[result]
            XCTAssertEqual(
                L10n.workflowActionResult(result, language: .english),
                copy?.english
            )
            XCTAssertEqual(
                L10n.workflowActionResult(result, language: .simplifiedChinese),
                copy?.chinese
            )
        }
    }

    func testEverySkipReasonHasFixedBilingualCopy() {
        let expected: [WorkflowRunSkipCode: (english: String, chinese: String)] = [
            .workflowDisabled: ("Workflow is disabled", "工作流已停用"),
            .busy: ("Rill is busy", "Rill 正忙"),
            .unsupported: ("Workflow is not supported", "当前不支持此工作流"),
            .privacyBlocked: ("Blocked by privacy settings", "已被隐私设置阻止"),
            .eventKindMismatch: ("Event type did not match", "事件类型不匹配"),
            .sourceGroupMismatch: ("Source group did not match", "来源分组不匹配"),
            .excludedByCaptureTag: ("Excluded by capture tag", "已被捕获标签排除"),
            .conditionFailed: ("Trigger condition did not match", "触发条件不匹配"),
            .itemMissing: ("Clipboard item is no longer available", "剪贴板条目已不可用"),
            .itemChanged: ("Clipboard item changed before it could run", "剪贴板条目在运行前已发生变化"),
            .loopPrevented: ("Automation loop prevented", "已阻止自动化循环"),
            .allActionsSkipped: ("All actions were skipped", "所有动作均已跳过"),
            .unclassified: ("Skip reason is unavailable", "跳过原因不可用"),
        ]

        XCTAssertEqual(Set(expected.keys), Set(WorkflowRunSkipCode.allCases))
        for reason in WorkflowRunSkipCode.allCases {
            let copy = expected[reason]
            XCTAssertEqual(
                L10n.workflowRunSkipReason(reason, language: .english),
                copy?.english
            )
            XCTAssertEqual(
                L10n.workflowRunSkipReason(reason, language: .simplifiedChinese),
                copy?.chinese
            )
        }
    }

    func testEverySkippedTerminationIncludesItsSpecificReasonInReceiptDetails() {
        for reason in WorkflowRunSkipCode.allCases {
            let englishReason = L10n.workflowRunSkipReason(reason, language: .english)
            let chineseReason = L10n.workflowRunSkipReason(reason, language: .simplifiedChinese)
            XCTAssertEqual(
                L10n.workflowRunTermination(.skipped(reason: reason), language: .english),
                "Skipped — \(englishReason)"
            )
            XCTAssertEqual(
                L10n.workflowRunTermination(
                    .skipped(reason: reason),
                    language: .simplifiedChinese
                ),
                "已跳过 — \(chineseReason)"
            )
        }
    }

    func testSkippedReasonIsIncludedInAccessibilityLabel() {
        for reason in WorkflowRunSkipCode.allCases {
            XCTAssertEqual(
                L10n.historyRunAccessibilityLabel(
                    status: "Skipped",
                    title: "Clipboard event",
                    termination: .skipped(reason: reason),
                    language: .english
                ),
                "Skipped: Clipboard event, "
                    + L10n.workflowRunSkipReason(reason, language: .english)
            )
            XCTAssertEqual(
                L10n.historyRunAccessibilityLabel(
                    status: "已跳过",
                    title: "剪贴板事件",
                    termination: .skipped(reason: reason),
                    language: .simplifiedChinese
                ),
                "已跳过: 剪贴板事件, "
                    + L10n.workflowRunSkipReason(reason, language: .simplifiedChinese)
            )
        }
    }

    func testNonSkippedAccessibilityLabelRemainsConcise() {
        XCTAssertEqual(
            L10n.historyRunAccessibilityLabel(
                status: "Completed",
                title: "Dictation",
                termination: .completed,
                language: .english
            ),
            "Completed: Dictation"
        )
    }
}

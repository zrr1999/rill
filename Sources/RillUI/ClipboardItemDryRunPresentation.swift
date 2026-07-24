import RillCore

struct ClipboardItemDryRunPresentationRow: Sendable, Equatable {
    let title: String
    let detail: String
}

struct ClipboardItemDryRunPresentation: Sendable, Equatable {
    let status: ClipboardItemDryRunStatus
    let statusTitle: String
    let statusDetail: String
    let reads: [ClipboardItemDryRunPresentationRow]
    let transforms: [ClipboardItemDryRunPresentationRow]
    let effects: [ClipboardItemDryRunPresentationRow]
    let destinations: [ClipboardItemDryRunPresentationRow]
    let replacement: [ClipboardItemDryRunPresentationRow]
    let privacyConditions: [ClipboardItemDryRunPresentationRow]
    let issues: [ClipboardItemDryRunPresentationRow]

    static func make(
        receipt: ClipboardItemDryRunReceipt,
        language: AppLanguage
    ) -> ClipboardItemDryRunPresentation {
        ClipboardItemDryRunPresentation(
            status: receipt.status,
            statusTitle: UIStrings.clipboardItemDryRunStatusTitle(
                receipt.status,
                language: language
            ),
            statusDetail: UIStrings.clipboardItemDryRunStatusDetail(
                receipt,
                language: language
            ),
            reads: receipt.reads.map { read in
                ClipboardItemDryRunPresentationRow(
                    title: UIStrings.clipboardItemDryRunRead(read.category, language: language),
                    detail: UIStrings.clipboardItemDryRunUsage(read.usage, language: language)
                )
            },
            transforms: receipt.transforms.map { transform in
                ClipboardItemDryRunPresentationRow(
                    title: UIStrings.workflowExplanationTransform(
                        transform.kind,
                        language: language
                    ),
                    detail: UIStrings.workflowExplanationTransformDetail(
                        transform,
                        language: language
                    )
                )
            },
            effects: receipt.actionEffects.map { effect in
                ClipboardItemDryRunPresentationRow(
                    title: UIStrings.clipboardItemDryRunEffect(
                        effect.effect,
                        language: language
                    ),
                    detail: [
                        UIStrings.clipboardItemDryRunUsage(effect.usage, language: language),
                        UIStrings.clipboardItemDryRunConfiguration(
                            effect.configurationState,
                            language: language
                        ),
                        UIStrings.workflowExplanationDestination(
                            effect.processingDestination,
                            language: language
                        ),
                    ].joined(separator: " • ")
                )
            },
            destinations: receipt.processingDestinations.map { destination in
                ClipboardItemDryRunPresentationRow(
                    title: UIStrings.workflowExplanationDestination(
                        destination,
                        language: language
                    ),
                    detail: ""
                )
            },
            replacement: [
                ClipboardItemDryRunPresentationRow(
                    title: UIStrings.clipboardItemDryRunReplacement(
                        receipt.sourceReplacementPlan,
                        language: language
                    ),
                    detail: ""
                ),
            ],
            privacyConditions: privacyRows(receipt: receipt, language: language),
            issues: receipt.issues.map { issue in
                ClipboardItemDryRunPresentationRow(
                    title: UIStrings.clipboardItemDryRunIssue(issue, language: language),
                    detail: ""
                )
            }
        )
    }

    private static func privacyRows(
        receipt: ClipboardItemDryRunReceipt,
        language: AppLanguage
    ) -> [ClipboardItemDryRunPresentationRow] {
        var rows = UIStrings.workflowExplanationPrivacyReasons(
            receipt.privacyReasons,
            language: language
        ).map {
            ClipboardItemDryRunPresentationRow(title: $0, detail: "")
        }
        for category in receipt.redactedInputCategories {
            let title: String
            switch (language, category) {
            case (.english, .focusedSelection):
                title = "A future run would redact the focused selection."
            case (.simplifiedChinese, .focusedSelection):
                title = "未来运行将隐去当前选区。"
            case (.english, .clipboardText):
                title = "A future run would redact current clipboard text."
            case (.simplifiedChinese, .clipboardText):
                title = "未来运行将隐去当前剪贴板文本。"
            }
            if !rows.contains(where: { $0.title == title }) {
                rows.append(ClipboardItemDryRunPresentationRow(title: title, detail: ""))
            }
        }
        return rows
    }
}

import SwiftUI
import RillCore

public struct CandidatePanelView: View {
    let candidateCase: CandidateResolutionCase
    let language: AppLanguage
    let onApply: ([UUID: UUID]) -> Void
    let onDismiss: () -> Void

    @State private var selections: [UUID: UUID] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        candidateCase: CandidateResolutionCase,
        language: AppLanguage,
        onApply: @escaping ([UUID: UUID]) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.candidateCase = candidateCase
        self.language = language
        self.onApply = onApply
        self.onDismiss = onDismiss
        _selections = State(initialValue: candidateCase.defaultSelections())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UIStrings.text(.candidateResolution, language: language))
                .font(.title3.weight(.semibold))
            Text(UIStrings.text(.candidateResolutionHint, language: language))
                .foregroundStyle(.secondary)
            Text(
                UIStrings.candidateModeSummary(
                    mode: candidateCase.policy.mode,
                    timeoutSeconds: Int(candidateCase.policy.timeoutSeconds),
                    language: language
                )
            )
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(candidateCase.recognitionResult.candidateSets) { candidateSet in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(candidateSet.surfaceText)
                            .font(.headline)
                        Text(
                            UIStrings.spanSummary(
                                lowerBound: candidateSet.range.lowerBound,
                                upperBound: candidateSet.range.upperBound,
                                language: language
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(UIStrings.text(.selectReplacement, language: language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(UIStrings.text(.ambiguousText, language: language))
                        .font(.subheadline.weight(.medium))
                    Text(candidateSet.surfaceText)
                        .textSelection(.enabled)
                    FlowLayout(spacing: 10) {
                        ForEach(candidateSet.candidates) { candidate in
                            let isSelected = currentSelection(for: candidateSet) == candidate.id
                            Button {
                                selections[candidateSet.id] = candidate.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.text)
                                        .font(.body.weight(.medium))
                                    Text(
                                        "\(Int(candidate.confidence * 100))% · "
                                            + UIStrings.candidateSource(candidate.source, language: language)
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .rillSelection(isSelected, cornerRadius: 12)
                                .animation(
                                    reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1.0),
                                    value: isSelected
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .rillCard(.subdued, padding: 14)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(UIStrings.text(.resolvedPreview, language: language))
                    .font(.headline)
                Text(resolvedPreview)
                    .textSelection(.enabled)
                    .rillCard(.subdued, cornerRadius: 12, padding: 12)
            }

            HStack {
                Button(UIStrings.text(.applySelection, language: language)) {
                    onApply(mergedSelections())
                }
                .keyboardShortcut(.defaultAction)

                Button(UIStrings.text(.useDefaults, language: language)) {
                    onApply(candidateCase.defaultSelections())
                }

                Button(UIStrings.text(.dismiss, language: language), role: .cancel) {
                    onDismiss()
                }
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: RillRadius.panel, style: .continuous))
    }

    private func currentSelection(for set: CandidateSet) -> UUID? {
        selections[set.id] ?? set.defaultCandidate?.id
    }

    private func mergedSelections() -> [UUID: UUID] {
        var output = candidateCase.defaultSelections()
        for (setID, candidateID) in selections {
            output[setID] = candidateID
        }
        return output
    }

    private var resolvedPreview: String {
        candidateCase.recognitionResult.applyingSelections(mergedSelections()).bestText
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX + size.width > maxWidth, cursorX > 0 {
                cursorX = 0
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: cursorX, y: cursorY))
            rowHeight = max(rowHeight, size.height)
            cursorX += size.width + spacing
            maxX = max(maxX, cursorX - spacing)
        }

        return (positions, CGSize(width: maxX, height: cursorY + rowHeight))
    }
}

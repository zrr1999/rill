import RillCore
import SwiftUI

struct RecordJevSheet: View {
  @Bindable var model: RecordJevPanelModel
  let language: AppLanguage
  let onSelect: (RecordID) -> Void
  let onConfigure: (SettingsNavigationRequest) -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(text(.title)).font(.title2.weight(.semibold))
      Text(text(.disclosure)).font(.callout).foregroundStyle(.secondary)
      HStack {
        Text(text(model.isConfigured ? .keyReady : .configureNotice))
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(text(.openSettings)) {
          onConfigure(.init(section: .providers, item: .jevCredential))
        }
        .disabled(model.isWorking)
        .accessibilityIdentifier("records.jev-settings")
      }
      if let review = model.review {
        ScrollView {
          VStack(alignment: .leading, spacing: RillSpacing.row) {
            Text(review.query).font(.headline).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, RillSpacing.row)
            ForEach(model.result?.orderedIndices ?? Array(review.candidates.indices), id: \.self) { index in
              let candidate = review.candidates[index]
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(candidate.isTruncated ? text(.fragment) : text(.candidate)).font(.caption).foregroundStyle(.secondary)
                  Spacer()
                  if let result = model.result {
                    Text(result.response.scores[index], format: .number.precision(.fractionLength(2)))
                      .monospacedDigit().accessibilityLabel(text(.score))
                      .accessibilityValue(result.response.scores[index].formatted(.number.precision(.fractionLength(2))))
                    Text("/ 2").foregroundStyle(.secondary)
                    Button(text(.select)) { onSelect(candidate.id); model.invalidate() }
                  }
                }
                Text(candidate.text).font(.system(.body, design: .monospaced))
                  .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              }
              Divider()
            }
          }
        }.frame(minHeight: 100, maxHeight: 280)
        Text(text(.rubric)).font(.caption).foregroundStyle(.secondary)
      }
      if let result = model.result {
        Text("\(result.response.model) · \(Int(result.elapsedMilliseconds)) ms · \(result.response.inputTokens) in / \(result.response.outputTokens) out tokens")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      if case .failed(let error) = model.state {
        Text(L10n.jevError(error, language: language)).foregroundStyle(.orange)
          .accessibilityIdentifier("records.jev-error")
        if error == .privacyBlocked {
          Button(text(.privacySettings)) { onConfigure(.init(section: .privacy)) }
        } else if error == .missingKey || error == .unauthorized {
          Button(text(.openSettings)) { onConfigure(.init(section: .providers, item: .jevCredential)) }
        }
        Button(text(.retryPreview), action: onRetry)
          .accessibilityIdentifier("records.jev-retry")
      }
      HStack {
        if model.isWorking { ProgressView().controlSize(.small); Text(text(.working)).font(.caption) }
        Spacer()
        Button(text(.close)) { model.invalidate() }.keyboardShortcut(.cancelAction)
        if model.state == .review {
          Button(text(.send)) { model.confirm() }
            .disabled(!model.isConfigured).buttonStyle(.borderedProminent)
            .accessibilityIdentifier("records.jev-send")
        }
      }
    }
    .padding(RillSpacing.panel).frame(width: 540)
    .background(Color(nsColor: .windowBackgroundColor))
    .onDisappear { model.invalidate() }
  }

  private func text(_ key: JevText) -> String { L10n.jev(key, language: language) }
}

import RillCore
import SwiftUI

struct RecordJevSheet: View {
  @Bindable var model: RecordJevPanelModel
  let language: AppLanguage
  let onSelect: (RecordID) -> Void
  @State private var apiKey = ""
  @FocusState private var isEditingKey: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(text(.title)).font(.title2.weight(.semibold))
      Text(text(.disclosure)).font(.callout).foregroundStyle(.secondary)
      HStack {
        SecureField("TypeSafe API Key", text: $apiKey)
          .textFieldStyle(.roundedBorder).focused($isEditingKey).accessibilityIdentifier("records.jev-key")
        Button(text(.saveKey)) {
          isEditingKey = false
          model.setKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
          apiKey = ""
        }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button(text(.clearKey)) { model.setKey(""); apiKey = "" }.disabled(!model.isConfigured)
      }.disabled(model.isWorking)
      Text(text(model.isConfigured ? .keyReady : .keyNotice)).font(.caption).foregroundStyle(.secondary)
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
      }
      HStack {
        if model.isWorking { ProgressView().controlSize(.small); Text(text(.working)).font(.caption) }
        Spacer()
        Button(text(.close)) { model.invalidate() }.keyboardShortcut(.cancelAction)
        if model.state == .review {
          Button(text(.send)) { isEditingKey = false; apiKey = ""; model.confirm() }
            .disabled(!model.isConfigured).buttonStyle(.borderedProminent)
            .accessibilityIdentifier("records.jev-send")
        }
      }
    }
    .padding(RillSpacing.panel).frame(width: 540)
    .background(Color(nsColor: .windowBackgroundColor))
    .onDisappear { apiKey = ""; model.invalidate() }
  }

  private func text(_ key: JevText) -> String { L10n.jev(key, language: language) }
}

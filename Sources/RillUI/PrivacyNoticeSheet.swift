import SwiftUI

struct PrivacyNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let language: AppLanguage
    private let renderedDocument: AttributedString

    init(document: PrivacyNoticeDocument, language: AppLanguage) {
        self.language = language
        renderedDocument = (try? AttributedString(
            markdown: document.markdown,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(document.markdown)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(renderedDocument)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(24)
            }
            .navigationTitle(
                L10n.privacyText(.technicalNotice, language: language)
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        L10n.historySettingsText(.cancel, language: language)
                    ) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .accessibilityIdentifier("privacy.technical-notice")
    }
}

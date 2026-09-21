import SwiftUI

struct PrivacyNoticeSheet: View {
    // Sheet minimums: wide enough for the rendered markdown document and
    // tall enough to avoid immediate scrolling on common display sizes.
    private static let minimumWidth: CGFloat = 520
    private static let minimumHeight: CGFloat = 420

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
                    .padding(RillSpacing.page)
            }
            .navigationTitle(
                L10n.privacyText(.technicalNotice, language: language)
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        L10n.string(.close, language: language)
                    ) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        .accessibilityIdentifier("privacy.technical-notice")
    }
}

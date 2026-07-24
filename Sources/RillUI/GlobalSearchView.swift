import AppKit
import SwiftUI

struct GlobalSearchResultsView: View {
    @AccessibilityFocusState private var accessibilityFocusedResultID: String?
    @Binding var query: String
    let results: [GlobalSearchResult]
    let selectedResultID: String?
    let historySearchState: GlobalHistorySearchState
    let historyFailureActionTitle: String
    let language: AppLanguage
    let focusRequest: Int
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onHistorySearchFailureAction: () -> Void
    let onHighlight: (String) -> Void
    let onSelect: (GlobalSearchDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                GlobalSearchField(
                    text: $query,
                    prompt: GlobalSearchText.searchPrompt(language: language),
                    focusRequest: focusRequest,
                    onMoveSelection: onMoveSelection,
                    onSubmit: onSubmit,
                    onCancel: onCancel
                )
                .frame(minHeight: 28)

                Button(GlobalSearchText.cancel(language: language), action: onCancel)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("global-search.cancel")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if historySearchState == .searching {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(GlobalSearchText.historySearching(language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("global-search.history.loading")
            } else if historySearchState == .failed {
                HStack(spacing: 12) {
                    Label(
                        GlobalSearchText.historyUnavailable(language: language),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    Spacer(minLength: 12)

                    Button(
                        historyFailureActionTitle,
                        action: onHistorySearchFailureAction
                    )
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("global-search.history.retry")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .accessibilityIdentifier("global-search.history.error")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if results.isEmpty {
                        ContentUnavailableView(
                            GlobalSearchText.noResultsTitle(language: language),
                            systemImage: "magnifyingglass",
                            description: Text(
                                GlobalSearchText.noResultsDescription(language: language)
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .accessibilityIdentifier("global-search.empty")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(GlobalSearchText.quickDestinations(language: language))
                                    .font(.title2.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                            }

                            ForEach(GlobalSearchResultCategory.allCases, id: \.rawValue) { category in
                                let categoryResults = results.filter { $0.category == category }
                                if !categoryResults.isEmpty {
                                    resultSection(category, results: categoryResults)
                                }
                            }
                        }
                        .padding(24)
                    }
                }
                .accessibilityIdentifier("global-search.results")
                .onChange(of: selectedResultID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
        .background(.background)
        .onChange(of: selectedResultID) { _, selectedID in
            accessibilityFocusedResultID = selectedID
        }
    }

    private func resultSection(
        _ category: GlobalSearchResultCategory,
        results: [GlobalSearchResult]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(category.title(language: language))
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            ForEach(results) { result in
                GlobalSearchResultRow(
                    result: result,
                    isSelected: result.id == selectedResultID,
                    onHighlight: onHighlight,
                    onSelect: onSelect
                )
                .id(result.id)
                .accessibilityFocused(
                    $accessibilityFocusedResultID,
                    equals: result.id
                )
            }
        }
    }
}

private struct GlobalSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focusRequest: Int
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> KeyRoutingSearchField {
        let field = KeyRoutingSearchField()
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setAccessibilityIdentifier("global-search.field")
        return field
    }

    func updateNSView(_ field: KeyRoutingSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = prompt
        field.onMoveSelection = onMoveSelection
        field.onSubmit = onSubmit
        field.onCancelSearch = onCancel
        field.requestFocus(focusRequest)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: GlobalSearchField

        init(parent: GlobalSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class KeyRoutingSearchField: NSSearchField {
    var onMoveSelection: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancelSearch: (() -> Void)?
    private var requestedFocus = 0
    private var appliedFocus = 0

    func requestFocus(_ generation: Int) {
        requestedFocus = generation
        applyRequestedFocusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRequestedFocusIfPossible()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            onMoveSelection?(1)
        case 126:
            onMoveSelection?(-1)
        case 36, 76:
            onSubmit?()
        case 53:
            onCancelSearch?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelSearch?()
    }

    private func applyRequestedFocusIfPossible() {
        guard requestedFocus != appliedFocus, let window else { return }
        guard window.makeFirstResponder(self) else { return }
        appliedFocus = requestedFocus
    }
}

private struct GlobalSearchResultRow: View {
    let result: GlobalSearchResult
    let isSelected: Bool
    let onHighlight: (String) -> Void
    let onSelect: (GlobalSearchDestination) -> Void

    var body: some View {
        Button {
            onSelect(result.destination)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.symbolName)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail = result.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let preview = result.preview {
                        Text(preview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)
                Image(systemName: "arrow.forward")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.7) : Color.clear,
                    lineWidth: 1.5
                )
        }
        .onHover { isHovered in
            if isHovered {
                onHighlight(result.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(
            isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits()
        )
        .accessibilityIdentifier("global-search.result.\(result.id)")
    }
}

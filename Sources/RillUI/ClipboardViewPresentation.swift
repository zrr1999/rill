import AppKit
import SwiftUI
import RillCore

enum ClipboardDeliveryFailurePresentation {
    static func message(language: AppLanguage) -> String {
        switch language {
        case .english:
            return "This clipboard item could not be delivered. Return to the target app and retry."
        case .simplifiedChinese:
            return "无法投递此剪贴板条目。请返回目标 App 后重试。"
        }
    }
}

extension ClipboardView {
    func emptyStateCard(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .clipboardPanelCard()
    }

    @ViewBuilder
    func itemContextMenu(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        if item.supportsDirectPaste {
            Button {
                model.useClipboardItem(item)
            } label: {
                Label(UIStrings.text(.clipboardUseItem, language: model.language), systemImage: "arrowshape.turn.up.right")
            }
        }

        if allowsDryRunPreview {
            Button {
                presentDryRun(for: item)
            } label: {
                Label(
                    UIStrings.clipboardItemDryRunCopy(.button, language: model.language),
                    systemImage: "eye"
                )
            }
        }

        Button(role: .destructive) {
            requestDeletion(of: entry)
        } label: {
            Label(UIStrings.text(.clipboardDeleteItem, language: model.language), systemImage: "trash")
        }
    }

    func presentDryRun(for item: ClipboardHistoryItem) {
        guard allowsDryRunPreview else { return }
        presentedSheet = .dryRun(
            ClipboardItemDryRunSheetRequest(
                itemID: item.id,
                initialOperation: .use
            )
        )
    }

    func metadataPill(_ text: String, systemImage: String? = nil, tint: Color) -> some View {
        metadataPill(tint: tint, systemImage: systemImage) {
            Text(text)
        }
    }

    func metadataPill<Content: View>(
        tint: Color,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            content()
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .foregroundStyle(tint)
    }

    @ViewBuilder
    func thumbnail(for item: ClipboardHistoryItem, size: CGFloat) -> some View {
        if item.contentKind == .image,
           let imagePNGData = item.imagePNGData,
           let nsImage = NSImage(data: imagePNGData) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if item.contentKind == .files,
                  item.fileURLs.count == 1,
                  let fileIcon = fileIcon(for: item.fileURLs[0]) {
            Image(nsImage: fileIcon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(thumbnailTint(for: item).opacity(0.12))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: systemSymbol(for: item).rawValue)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(thumbnailTint(for: item))
                }
        }
    }

    func thumbnailTint(for item: ClipboardHistoryItem) -> Color {
        switch item.sourceKind {
        case .system:
            return item.contentKind == .files ? .orange : .blue
        case .rillWorkflow:
            return .purple
        }
    }

    func primaryText(for item: ClipboardHistoryItem) -> String {
        let normalized = ClipboardTextFormatting.summaryText(item.text)

        if !normalized.isEmpty {
            return normalized
        }

        switch item.contentKind {
        case .text:
            return UIStrings.text(.clipboardSystemSourceFallback, language: model.language)
        case .image:
            return sourceTitle(for: item)
        case .files:
            let names = item.fileURLs.map(\.lastPathComponent)
            return names.isEmpty ? sourceTitle(for: item) : names.joined(separator: ", ")
        }
    }

    func compactSourceLabel(for item: ClipboardHistoryItem) -> String {
        switch item.sourceKind {
        case .system:
            return item.sourceApplicationName ??
                UIStrings.text(.clipboardSystemSourceFallback, language: model.language)
        case .rillWorkflow:
            if let workflow = item.workflow {
                return UIStrings.workflowName(workflow, language: model.language)
            }
            return UIStrings.text(.clipboardWorkflowSourceFallback, language: model.language)
        }
    }

    func systemSymbol(for item: ClipboardHistoryItem) -> RillSystemSymbol {
        switch item.contentKind {
        case .text:
            switch item.sourceKind {
            case .system:
                return .docOnClipboard
            case .rillWorkflow:
                return .wandAndStars
            }
        case .image:
            return .photo
        case .files:
            return .folder
        }
    }

    func sourceTitle(for item: ClipboardHistoryItem) -> String {
        switch item.sourceKind {
        case .system:
            if let applicationName = item.sourceApplicationName {
                return UIStrings.clipboardSystemSource(
                    applicationName: applicationName,
                    language: model.language
                )
            }
            return UIStrings.text(.clipboardSystemSourceFallback, language: model.language)
        case .rillWorkflow:
            if let workflow = item.workflow {
                return UIStrings.clipboardWorkflowSource(workflow, language: model.language)
            }
            return UIStrings.text(.clipboardWorkflowSourceFallback, language: model.language)
        }
    }

    func groupName(for groupID: UUID) -> String {
        clipboardGroupNamesByID[groupID] ?? UIStrings.text(.clipboardDefaultGroup, language: model.language)
    }

    func isDefaultFallbackSummary(_ summary: ClipboardGroupSummary) -> Bool {
        summary.group.isReserved
    }

    func historySectionHeader(_ section: ClipboardHistorySectionModel) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            metadataPill(
                UIStrings.stackCountSummary(section.entries.count, language: model.language),
                tint: .secondary
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    @ViewBuilder
    func detailPreview(for item: ClipboardHistoryItem) -> some View {
        switch item.contentKind {
        case .text:
            if let renderedMarkdown = ClipboardTextFormatting.renderedMarkdown(item.text) {
                Text(renderedMarkdown)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(item.text.isEmpty ? primaryText(for: item) : item.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .image:
            VStack(alignment: .leading, spacing: 12) {
                if let imagePNGData = item.imagePNGData, let nsImage = NSImage(data: imagePNGData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: ClipboardViewMetrics.detailPreviewMaxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .files:
            VStack(alignment: .leading, spacing: 10) {
                if let previewImage = filePreviewImage(for: item.fileURLs) {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: ClipboardViewMetrics.detailPreviewMaxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text(primaryText(for: item))
                    .font(.body.weight(.medium))

                ForEach(item.fileURLs, id: \.self) { fileURL in
                    filePreviewRow(for: fileURL)
                }
            }
        }
    }

    @ViewBuilder
    func filePreviewRow(for fileURL: URL) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon = fileIcon(for: fileURL) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: ClipboardViewMetrics.fileIconSize, height: ClipboardViewMetrics.fileIconSize)
            } else {
                Image(systemName: "doc")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: ClipboardViewMetrics.fileIconSize, height: ClipboardViewMetrics.fileIconSize)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(fileURL.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                Text(fileURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func filePreviewImage(for fileURLs: [URL]) -> NSImage? {
        guard fileURLs.count == 1, let fileURL = fileURLs.first, fileURL.isFileURL else {
            return nil
        }
        return NSImage(contentsOf: fileURL)
    }

    func fileIcon(for fileURL: URL) -> NSImage? {
        guard fileURL.isFileURL else { return nil }
        return NSWorkspace.shared.icon(forFile: fileURL.path)
    }
}

extension View {
    func clipboardPanelCard() -> some View {
        self
            .background(
                .quaternary.opacity(0.16),
                in: RoundedRectangle(
                    cornerRadius: ClipboardViewMetrics.cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClipboardViewMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.04))
            )
    }
}

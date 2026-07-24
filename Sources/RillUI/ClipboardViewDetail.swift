import AppKit
import SwiftUI
import RillCore

extension ClipboardView {
    // MARK: - Detail Pane

    @ViewBuilder
    func detailHeader(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        HStack(alignment: .top, spacing: 12) {
            thumbnail(for: item, size: ClipboardViewMetrics.detailThumbnailSize)

            VStack(alignment: .leading, spacing: 6) {
                Text(primaryText(for: item))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(sourceTitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    func actionBar(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        return HStack(spacing: 8) {
            if item.supportsDirectPaste {
                Button {
                    model.useClipboardItem(item)
                } label: {
                    Label(
                        UIStrings.text(.clipboardUseItem, language: model.language),
                        systemImage: "arrowshape.turn.up.right.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("clipboard.preview-effects")
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                requestDeletion(of: entry)
            } label: {
                Label(UIStrings.text(.clipboardDeleteItem, language: model.language), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    func detailPreviewCard(for item: ClipboardHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailPreview(for: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func detailMetadata(for entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem

        return VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    metadataPill(groupName(for: item.groupID), systemImage: "square.stack.3d.up", tint: .green)
                    metadataPill(tint: .secondary, systemImage: "clock") {
                        Text(item.createdAt, style: .relative)
                    }

                    metadataPill("\(entry.copyCount)", systemImage: "doc.on.doc", tint: .orange)
                    metadataPill("\(entry.pasteCount)", systemImage: "arrowshape.turn.up.right", tint: .blue)

                    if let lastUsedAt = entry.lastUsedAt {
                        metadataPill(tint: .secondary, systemImage: "clock.arrow.circlepath") {
                            Text(lastUsedAt, style: .relative)
                        }
                    }

                    if entry.includesSimilarText {
                        metadataPill(
                            UIStrings.text(.clipboardMergedSimilarBadge, language: model.language),
                            tint: .purple
                        )
                    }
                }
            }
        }
    }

    func detailChipSection(title: String, values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(tint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func editableTagsSection(for entry: ClipboardHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UIStrings.text(.clipboardTags, language: model.language))
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(entry.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.caption.weight(.medium))
                            Button {
                                var updatedTags = entry.tags
                                updatedTags.removeAll { $0 == tag }
                                model.setClipboardItemTags(updatedTags, forItem: entry.representativeItem.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                UIStrings.targetedAccessibilityLabel(
                                    .clipboardRemoveTag,
                                    target: tag,
                                    language: model.language
                                )
                            )
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(.blue)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(
                    model.language == .english ? "Add tag…" : "添加标签…",
                    text: $newTagText
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    addTag(to: entry)
                }

                Button {
                    addTag(to: entry)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(UIStrings.text(.clipboardAddTag, language: model.language))
                .accessibilityIdentifier("clipboard.tag.add")
            }
        }
    }

    func addTag(to entry: ClipboardHistoryEntry) {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updatedTags = entry.tags
        if !updatedTags.contains(trimmed) {
            updatedTags.append(trimmed)
        }
        model.setClipboardItemTags(updatedTags, forItem: entry.representativeItem.id)
        newTagText = ""
    }

}

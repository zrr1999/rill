import AppKit
import SwiftUI
import RillCore

extension ClipboardView {
    // MARK: - History

    var historyWorkspace: some View {
        Group {
            if filteredClipboardEntries.isEmpty {
                emptyStateCard(
                    systemImage: "doc.on.clipboard",
                    title: selectedSection.title(language: model.language),
                    message: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? selectedSection.description(language: model.language)
                        : UIStrings.text(.clipboardNoResults, language: model.language)
                )
            } else {
                HStack(alignment: .top, spacing: ClipboardViewMetrics.splitSpacing) {
                    historyListCard
                        .frame(
                            minWidth: 260,
                            idealWidth: 300,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                    detailCard
                        .frame(
                            minWidth: 280,
                            idealWidth: 360,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var historyListCard: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredClipboardSections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            historySectionHeader(section)

                            LazyVStack(spacing: 2) {
                                ForEach(section.entries) { entry in
                                    historyListRow(entry)
                                        .id(entry.id)
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: focusedControl) { _, target in
                guard case .entry(let entryID) = target else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(entryID, anchor: .center)
                }
            }
        }
        .clipboardPanelCard()
    }

    var detailCard: some View {
        Group {
            if let selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailHeader(for: selectedEntry)
                        actionBar(for: selectedEntry)
                        detailPreviewCard(for: selectedEntry.representativeItem)
                        detailMetadata(for: selectedEntry)

                        if !selectedEntry.alternatives.isEmpty {
                            detailChipSection(
                                title: UIStrings.text(.clipboardAlternatives, language: model.language),
                                values: selectedEntry.alternatives,
                                tint: .orange
                            )
                        }

                        editableTagsSection(for: selectedEntry)

                        if selectedEntry.representativeItem.latestError != nil {
                            Label(
                                ClipboardDeliveryFailurePresentation.message(
                                    language: model.language
                                ),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    .red.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                    }
                    .padding(ClipboardViewMetrics.cardPadding)
                }
            } else {
                emptyStateCard(
                    systemImage: "cursorarrow.rays",
                    title: selectedSection.title(language: model.language),
                    message: UIStrings.text(.clipboardSelectItem, language: model.language)
                )
            }
        }
        .clipboardPanelCard()
    }

    // MARK: - History List Row

    func historyListRow(_ entry: ClipboardHistoryEntry) -> some View {
        let item = entry.representativeItem
        let isSelected = selectedEntryID == entry.id
        let isHovered = hoveredEntryID == entry.id

        return HStack(alignment: .top, spacing: 10) {
            thumbnail(for: item, size: ClipboardViewMetrics.thumbnailSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText(for: item))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(compactSourceLabel(for: item))
                    Text("·")
                    Text(item.createdAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                HStack(spacing: 4) {
                    metadataPill(groupName(for: item.groupID), tint: .green)

                    if selectedSection == .history || entry.isMerged {
                        metadataPill("\(entry.copyCount)", systemImage: "doc.on.doc", tint: .orange)
                    }

                    if selectedSection == .history || entry.pasteCount > 0 {
                        metadataPill("\(entry.pasteCount)", systemImage: "arrowshape.turn.up.right", tint: .blue)
                    }

                    if selectedSection == .history, let lastUsedAt = entry.lastUsedAt {
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

            Spacer(minLength: 4)

            if item.latestError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(ClipboardViewMetrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            rowBackground(isSelected: isSelected, isHovered: isHovered),
            in: RoundedRectangle(cornerRadius: ClipboardViewMetrics.rowCornerRadius, style: .continuous)
        )
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: ClipboardViewMetrics.rowCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                : nil
        )
        .contentShape(RoundedRectangle(cornerRadius: ClipboardViewMetrics.rowCornerRadius, style: .continuous))
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : nil
        }
        .contextMenu {
            itemContextMenu(for: entry)
        }
        .onTapGesture {
            selectedEntryID = entry.id
            focusedControl = .entry(entry.id)
        }
        .focusable()
        .focused($focusedControl, equals: .entry(entry.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(primaryText(for: item))
        .accessibilityValue(
            UIStrings.clipboardEntryAccessibilityValue(
                copyCount: entry.copyCount,
                groupName: groupName(for: item.groupID),
                language: model.language
            )
        )
        .accessibilityHint(
            UIStrings.clipboardEntryAccessibilityHint(
                supportsDirectPaste: item.supportsDirectPaste,
                language: model.language
            )
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            selectedEntryID = entry.id
            focusedControl = .entry(entry.id)
        }
        .accessibilityIdentifier("clipboard.entry.\(entry.id.uuidString)")
    }

    func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        } else if isHovered {
            return Color.secondary.opacity(0.08)
        } else {
            return Color.clear
        }
    }

}

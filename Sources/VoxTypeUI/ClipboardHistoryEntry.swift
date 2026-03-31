import Foundation
import VoxTypeCore

struct ClipboardHistoryEntry: Identifiable, Equatable, Sendable {
    let representativeItem: ClipboardHistoryItem
    let mergedItemIDs: [UUID]
    let copyCount: Int
    let pasteCount: Int
    let lastUsedAt: Date?
    let alternatives: [String]
    let tags: [String]
    let searchIndexText: String
    let includesSimilarText: Bool

    var id: UUID { representativeItem.id }
    var isMerged: Bool { copyCount > 1 }

    func matchesSearchQuery(_ query: String, groupName: String) -> Bool {
        let normalizedQuery = Self.normalizeSearchText(query)
        guard !normalizedQuery.isEmpty else { return true }

        if searchIndexText.contains(normalizedQuery) {
            return true
        }

        return Self.normalizeSearchText(groupName).contains(normalizedQuery)
    }

    static func normalizeSearchText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

enum ClipboardHistoryEntryBuilder {
    static func build(
        from items: [ClipboardHistoryItem],
        mergeSimilarText: Bool
    ) -> [ClipboardHistoryEntry] {
        var orderedKeys: [GroupingKey] = []
        var buckets: [GroupingKey: Bucket] = [:]

        for item in items {
            let key = GroupingKey(item: item, mergeSimilarText: mergeSimilarText)
            if var bucket = buckets[key] {
                bucket.add(item)
                buckets[key] = bucket
            } else {
                orderedKeys.append(key)
                buckets[key] = Bucket(seed: item)
            }
        }

        return orderedKeys.compactMap { buckets[$0]?.build(mergeSimilarText: mergeSimilarText) }
    }

    private enum GroupingKey: Hashable {
        case text(groupID: UUID, signature: String)
        case files(groupID: UUID, paths: [String])
        case unique(UUID)

        init(item: ClipboardHistoryItem, mergeSimilarText: Bool) {
            switch item.contentKind {
            case .text:
                if mergeSimilarText, let signature = Self.similarTextSignature(for: item.text) {
                    self = .text(groupID: item.groupID, signature: "similar:\(signature)")
                } else {
                    self = .text(groupID: item.groupID, signature: "exact:\(item.text)")
                }
            case .files:
                self = .files(groupID: item.groupID, paths: item.fileURLs.map(\.path))
            case .image:
                self = .unique(item.id)
            }
        }

        private static func similarTextSignature(for text: String) -> String? {
            let collapsed = collapseWhitespace(in: ClipboardHistoryEntry.normalizeSearchText(text))
            guard collapsed.count >= 8 else { return nil }

            let strippedScalars = collapsed.unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
            }
            let stripped = collapseWhitespace(in: String(String.UnicodeScalarView(strippedScalars)))
            guard stripped.count >= 8 else { return nil }
            return stripped
        }

        private static func collapseWhitespace(in value: String) -> String {
            value
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
    }

    private struct Bucket {
        private(set) var representativeItem: ClipboardHistoryItem
        private(set) var mergedItemIDs: [UUID]
        private(set) var copyCount: Int
        private(set) var pasteCount: Int
        private(set) var lastUsedAt: Date?
        private(set) var alternatives: [String]
        private(set) var tags: [String]
        private(set) var searchTokens: [String]
        private(set) var distinctRawTexts: Set<String>

        init(seed item: ClipboardHistoryItem) {
            representativeItem = item
            mergedItemIDs = [item.id]
            copyCount = 1
            pasteCount = item.useCount
            lastUsedAt = item.lastUsedAt
            alternatives = item.alternatives
            tags = item.tags
            searchTokens = Self.searchTokens(for: item)
            distinctRawTexts = item.contentKind == .text ? Set([item.text]) : []
        }

        mutating func add(_ item: ClipboardHistoryItem) {
            mergedItemIDs.append(item.id)
            copyCount += 1
            pasteCount += item.useCount

            if representativeItem.createdAt < item.createdAt {
                representativeItem = item
            }

            if let lastUsedAt = item.lastUsedAt {
                self.lastUsedAt = max(self.lastUsedAt ?? lastUsedAt, lastUsedAt)
            }

            appendUnique(item.alternatives, into: &alternatives)
            appendUnique(item.tags, into: &tags)
            appendUnique(Self.searchTokens(for: item), into: &searchTokens)

            if item.contentKind == .text {
                distinctRawTexts.insert(item.text)
            }
        }

        func build(mergeSimilarText: Bool) -> ClipboardHistoryEntry {
            ClipboardHistoryEntry(
                representativeItem: representativeItem,
                mergedItemIDs: mergedItemIDs,
                copyCount: copyCount,
                pasteCount: pasteCount,
                lastUsedAt: lastUsedAt,
                alternatives: alternatives,
                tags: tags,
                searchIndexText: ClipboardHistoryEntry.normalizeSearchText(searchTokens.joined(separator: "\n")),
                includesSimilarText: mergeSimilarText && distinctRawTexts.count > 1
            )
        }

        private static func searchTokens(for item: ClipboardHistoryItem) -> [String] {
            var tokens = [item.text]
            tokens.append(contentsOf: item.alternatives)
            tokens.append(contentsOf: item.tags)

            if let sourceApplicationName = item.sourceApplicationName {
                tokens.append(sourceApplicationName)
            }

            if let workflowName = item.workflow?.fallbackName {
                tokens.append(workflowName)
            }

            return tokens
        }

        private func appendUnique(_ values: [String], into target: inout [String]) {
            for value in values where !target.contains(value) {
                target.append(value)
            }
        }
    }
}

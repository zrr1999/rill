import Foundation
import RillCore

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
    private static let exactGroupingInlineLength = 256
    private static let exactGroupingEdgeLength = 96
    private static let maxIndexedSearchLength = 2_048
    private static let maxSimilarTextLength = 4_096

    static func build(
        from items: [ClipboardHistoryItem],
        mergeSimilarText: Bool
    ) -> [ClipboardHistoryEntry] {
        buildEntries(from: items, mergeSimilarText: mergeSimilarText)
    }

    static func buildCurrent(
        from items: [ClipboardHistoryItem],
        remainingItemIDs: Set<UUID>,
        mergeSimilarText: Bool
    ) -> [ClipboardHistoryEntry] {
        buildEntries(
            from: items.filter { remainingItemIDs.contains($0.id) },
            mergeSimilarText: mergeSimilarText
        )
    }

    private static func buildEntries(
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
                    self = .text(
                        groupID: item.groupID,
                        signature: ClipboardHistoryEntryBuilder.exactTextSignature(for: item.text)
                    )
                }
            case .files:
                self = .files(groupID: item.groupID, paths: item.fileURLs.map(\.path))
            case .image:
                self = .unique(item.id)
            }
        }

        private static func similarTextSignature(for text: String) -> String? {
            guard text.count <= ClipboardHistoryEntryBuilder.maxSimilarTextLength else { return nil }
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
        private(set) var distinctTextSignatures: Set<String>

        init(seed item: ClipboardHistoryItem) {
            representativeItem = item
            mergedItemIDs = [item.id]
            copyCount = 1
            pasteCount = item.useCount
            lastUsedAt = item.lastUsedAt
            alternatives = item.alternatives
            tags = item.tags
            searchTokens = Self.searchTokens(for: item)
            distinctTextSignatures = item.contentKind == .text
                ? Set([ClipboardHistoryEntryBuilder.exactTextSignature(for: item.text)])
                : []
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
                distinctTextSignatures.insert(ClipboardHistoryEntryBuilder.exactTextSignature(for: item.text))
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
                includesSimilarText: mergeSimilarText && distinctTextSignatures.count > 1
            )
        }

        private static func searchTokens(for item: ClipboardHistoryItem) -> [String] {
            var tokens = [ClipboardHistoryEntryBuilder.limitedSearchToken(item.text)]
            tokens.append(contentsOf: item.alternatives.map(ClipboardHistoryEntryBuilder.limitedSearchToken))
            tokens.append(contentsOf: item.tags.map(ClipboardHistoryEntryBuilder.limitedSearchToken))

            if let sourceApplicationName = item.sourceApplicationName {
                tokens.append(ClipboardHistoryEntryBuilder.limitedSearchToken(sourceApplicationName))
            }

            if let workflowName = item.workflow?.fallbackName {
                tokens.append(ClipboardHistoryEntryBuilder.limitedSearchToken(workflowName))
            }

            return tokens
        }

        private func appendUnique(_ values: [String], into target: inout [String]) {
            for value in values where !target.contains(value) {
                target.append(value)
            }
        }
    }

    private static func exactTextSignature(for text: String) -> String {
        guard text.count > exactGroupingInlineLength else {
            return "exact:\(text)"
        }
        let prefix = String(text.prefix(exactGroupingEdgeLength))
        let suffix = String(text.suffix(exactGroupingEdgeLength))
        return "exact:\(text.count):\(fnv1a64Hex(for: text)):\(prefix):\(suffix)"
    }

    private static func limitedSearchToken(_ value: String) -> String {
        let token = String(value.prefix(maxIndexedSearchLength))
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fnv1a64Hex(for text: String) -> String {
        let hash = text.utf8.reduce(UInt64(0xcbf29ce484222325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16, uppercase: false)
    }
}

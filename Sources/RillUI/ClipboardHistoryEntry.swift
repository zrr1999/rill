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
    let isPinned: Bool

    var id: UUID { representativeItem.id }
    var isMerged: Bool { copyCount > 1 }

    func matchesSearchQuery(_ query: String, groupName: String) -> Bool {
        let normalizedQuery = Self.normalizeSearchText(query)
        guard !normalizedQuery.isEmpty else { return true }

        let searchableText = searchIndexText
            + "\n"
            + Self.normalizeSearchText(groupName)
        return normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .allSatisfy { searchableText.contains($0) }
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
    private static let maxSearchIndexLength = 16_384
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

        let entries = orderedKeys.compactMap {
            buckets[$0]?.build(mergeSimilarText: mergeSimilarText)
        }
        return entries.filter(\.isPinned) + entries.filter { !$0.isPinned }
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
        private(set) var searchIndex: SearchIndexAccumulator
        private(set) var distinctTextSignatures: Set<String>
        private(set) var isPinned: Bool

        init(seed item: ClipboardHistoryItem) {
            representativeItem = item
            mergedItemIDs = [item.id]
            copyCount = 1
            pasteCount = item.useCount
            lastUsedAt = item.lastUsedAt
            alternatives = item.alternatives
            tags = item.tags
            searchIndex = SearchIndexAccumulator(item: item)
            distinctTextSignatures = item.contentKind == .text
                ? Set([ClipboardHistoryEntryBuilder.exactTextSignature(for: item.text)])
                : []
            isPinned = item.isPinned
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
            searchIndex.append(item: item)
            isPinned = isPinned || item.isPinned

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
                searchIndexText: searchIndex.value,
                includesSimilarText: mergeSimilarText && distinctTextSignatures.count > 1,
                isPinned: isPinned
            )
        }

        private func appendUnique(_ values: [String], into target: inout [String]) {
            for value in values where !target.contains(value) {
                target.append(value)
            }
        }
    }

    private struct SearchIndexAccumulator {
        private var tokens: [String] = []
        private var seenTokens: Set<String> = []
        private var remainingCharacterCapacity = ClipboardHistoryEntryBuilder.maxSearchIndexLength

        init(item: ClipboardHistoryItem) {
            append(item: item)
        }

        var value: String {
            tokens.joined(separator: "\n")
        }

        mutating func append(item: ClipboardHistoryItem) {
            var values = [item.text]
            values.append(contentsOf: item.alternatives)
            values.append(contentsOf: item.tags)
            values.append(contentsOf: item.fileURLs.map(\.lastPathComponent))
            if let sourceApplicationName = item.sourceApplicationName {
                values.append(sourceApplicationName)
            }
            if let sourceBundleIdentifier = item.sourceBundleIdentifier {
                values.append(sourceBundleIdentifier)
            }
            if let workflowName = item.workflow?.fallbackName {
                values.append(workflowName)
            }
            append(values)
        }

        private mutating func append(_ values: [String]) {
            for value in values where remainingCharacterCapacity > 0 {
                let normalized = ClipboardHistoryEntryBuilder.limitedSearchToken(value)
                guard !normalized.isEmpty, seenTokens.insert(normalized).inserted else {
                    continue
                }
                let separatorCost = tokens.isEmpty ? 0 : 1
                guard remainingCharacterCapacity > separatorCost else { return }
                let token = String(
                    normalized.prefix(remainingCharacterCapacity - separatorCost)
                )
                guard !token.isEmpty else { return }
                tokens.append(token)
                remainingCharacterCapacity -= separatorCost + token.count
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
        return ClipboardHistoryEntry.normalizeSearchText(token)
    }

    private static func fnv1a64Hex(for text: String) -> String {
        let hash = text.utf8.reduce(UInt64(0xcbf29ce484222325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16, uppercase: false)
    }
}

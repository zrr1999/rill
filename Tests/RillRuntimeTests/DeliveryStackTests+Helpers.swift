import XCTest
@testable import RillCore
@testable import RillRuntime

extension DeliveryStack {
    func captureSystemClipboard(
        snapshot: ClipboardSnapshot,
        context: ClipboardRouteContext,
        alternatives: [String] = []
    ) async {
        _ = await captureSystemClipboard(
            snapshot: snapshot,
            context: context,
            alternatives: alternatives,
            disposition: .historyAndWorkflows
        )
    }

    func groupEntryIDsForTesting(in groupID: UUID) -> [UUID] {
        groupEntries[groupID, default: []]
    }
}

extension DeliveryStackTests {
    static func waitForSnapshot(
        from stack: DeliveryStack,
        until predicate: (ClipboardStoreSnapshot) -> Bool
    ) async throws -> ClipboardStoreSnapshot {
        for _ in 0..<50 {
            let snapshot = await stack.clipboardSnapshot()
            if predicate(snapshot) {
                return snapshot
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        return await stack.clipboardSnapshot()
    }

    static func waitForPersistedState(
        in settingsStore: RuntimeTestSettingsStore,
        until predicate: (String) -> Bool
    ) async throws -> String {
        for _ in 0..<80 {
            if let rawState = try await settingsStore.string(forKey: .clipboardPersistedState), predicate(rawState) {
                return rawState
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        let rawState = try await settingsStore.string(forKey: .clipboardPersistedState)
        return try XCTUnwrap(rawState)
    }

    static func nextClipboardUpdate(
        from stream: AsyncStream<RillEvent>,
        until predicate: @escaping @Sendable (ClipboardStoreSnapshot) -> Bool = { _ in true }
    ) async throws -> ClipboardStoreSnapshot {
        try await withThrowingTaskGroup(of: ClipboardStoreSnapshot.self) { group in
            group.addTask {
                for await event in stream {
                    if case .clipboardUpdated(let snapshot) = event, predicate(snapshot) {
                        return snapshot
                    }
                }
                throw CancellationError()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw CancellationError()
            }

            let nextSnapshot = try await group.next()
            let snapshot = try XCTUnwrap(nextSnapshot)
            group.cancelAll()
            return snapshot
        }
    }

    func previewTexts(
        in summary: ClipboardGroupSummary?,
        from snapshot: ClipboardStoreSnapshot
    ) -> [String] {
        guard let summary else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        return summary.previewItemIDs.compactMap { itemsByID[$0]?.text }
    }
}

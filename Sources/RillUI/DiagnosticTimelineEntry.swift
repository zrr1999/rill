import Foundation
import RillCore

struct DiagnosticTimelineEntry: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        fileprivate let event: EventIdentity
        fileprivate let occurrence: Int
    }

    fileprivate struct EventIdentity: Hashable, Sendable {
        struct MetadataEntry: Hashable, Sendable {
            let key: String
            let value: String
        }

        let timestamp: Date
        let runID: UUID?
        let subsystem: String
        let level: String
        let eventCode: String
        let message: String
        let metadata: [MetadataEntry]

        init(event: DiagnosticEvent) {
            self.timestamp = event.timestamp
            self.runID = event.runID
            self.subsystem = event.subsystem.rawValue
            self.level = event.level.rawValue
            self.eventCode = event.event
            self.message = event.message
            self.metadata = event.metadata
                .map { MetadataEntry(key: $0.key, value: $0.value) }
                .sorted {
                    if $0.key == $1.key {
                        return $0.value < $1.value
                    }
                    return $0.key < $1.key
                }
        }
    }

    let id: ID
    let event: DiagnosticEvent
    let position: Int

    func copyAccessibilityLabel(language: AppLanguage) -> String {
        switch language {
        case .english:
            return "Copy diagnostic entry \(position)"
        case .simplifiedChinese:
            return "复制第 \(position) 条诊断记录"
        }
    }

    static func build(from events: [DiagnosticEvent], limit: Int) -> [Self] {
        var occurrenceCounts: [EventIdentity: Int] = [:]

        return events.prefix(limit).enumerated().map { offset, event in
            let identity = EventIdentity(event: event)
            let occurrence = occurrenceCounts[identity, default: 0]
            occurrenceCounts[identity] = occurrence + 1
            return Self(
                id: ID(event: identity, occurrence: occurrence),
                event: event,
                position: offset + 1
            )
        }
    }
}

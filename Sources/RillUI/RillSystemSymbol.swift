import AppKit

/// Application-owned SF Symbols used through computed or conditional UI paths.
///
/// Direct `Image` and `Label` literals are audited separately. Dynamic producers
/// use this catalog unless their closed state space is exhaustively exercised by
/// producer tests, so every possible value remains enumerable and testable.
public enum RillSystemSymbol: String, CaseIterable, Sendable {
    private static let maximumCachedCandidates = 256

    @MainActor
    private static var cachedAvailability: [String: Bool] = [:]

    case arrowClockwise = "arrow.clockwise"
    case arrowRightCircleFill = "arrow.right.circle.fill"
    case boltBadgeAutomatic = "bolt.badge.automatic"
    case boltFill = "bolt.fill"
    case checkmark = "checkmark"
    case checkmarkCircleFill = "checkmark.circle.fill"
    case checkmarkShield = "checkmark.shield"
    case circle = "circle"
    case cloudFill = "cloud.fill"
    case docOnClipboard = "doc.on.clipboard"
    case exclamationmarkCircleFill = "exclamationmark.circle.fill"
    case exclamationmarkShieldFill = "exclamationmark.shield.fill"
    case eyeSlashFill = "eye.slash.fill"
    case folder = "folder"
    case forwardEnd = "forward.end"
    case laptopcomputer = "laptopcomputer"
    case largecircleFillCircle = "largecircle.fill.circle"
    case lockShieldFill = "lock.shield.fill"
    case menubarRectangle = "menubar.rectangle"
    case micFill = "mic.fill"
    case noteText = "note.text"
    case pauseCircleFill = "pause.circle.fill"
    case photo = "photo"
    case playCircleFill = "play.circle.fill"
    case point3ConnectedTrianglepathDotted = "point.3.connected.trianglepath.dotted"
    case questionmarkBubble = "questionmark.bubble"
    case slashCircleFill = "slash.circle.fill"
    case squareStack3dUp = "square.stack.3d.up"
    case squareStack3dUpFill = "square.stack.3d.up.fill"
    case stopFill = "stop.fill"
    case textAlignLeft = "text.alignleft"
    case textCursor = "text.cursor"
    case textInsert = "text.insert"
    case wandAndStars = "wand.and.stars"
    case waveform = "waveform"
    case xmark = "xmark"
    case xmarkCircleFill = "xmark.circle.fill"
    case xmarkShield = "xmark.shield"

    @MainActor
    public static func resolvedName(
        _ candidate: String,
        fallback: RillSystemSymbol = .waveform
    ) -> String {
        let isAvailable: Bool
        if let cached = cachedAvailability[candidate] {
            isAvailable = cached
        } else {
            isAvailable = NSImage(
                systemSymbolName: candidate,
                accessibilityDescription: nil
            ) != nil
            if cachedAvailability.count >= maximumCachedCandidates {
                cachedAvailability.removeAll(keepingCapacity: true)
            }
            cachedAvailability[candidate] = isAvailable
        }

        guard isAvailable else {
            return fallback.rawValue
        }
        return candidate
    }
}

extension HistoryTimelineStatus {
    var systemSymbol: RillSystemSymbol {
        switch self {
        case .completed: .checkmarkCircleFill
        case .partiallyCompleted: .exclamationmarkCircleFill
        case .failed: .xmarkCircleFill
        case .cancelled: .slashCircleFill
        case .skipped: .arrowRightCircleFill
        }
    }
}

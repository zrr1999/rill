import AppKit

/// Application-owned SF Symbols used by static and computed UI paths.
///
/// Keeping this as a closed catalog makes symbol ownership a compile-time
/// contract. User-provided workflow symbols remain open input and go through
/// ``resolvedName(_:fallback:)`` before presentation.
public enum RillSystemSymbol: String, CaseIterable, Sendable {
    private static let maximumCachedCandidates = 256

    @MainActor
    private static var cachedAvailability: [String: Bool] = [:]

    case arrowClockwise = "arrow.clockwise"
    case arrowClockwiseCircle = "arrow.clockwise.circle"
    case arrowDown = "arrow.down"
    case arrowDownCircleFill = "arrow.down.circle.fill"
    case arrowDownDoc = "arrow.down.doc"
    case arrowForward = "arrow.forward"
    case arrowRight = "arrow.right"
    case arrowRightCircle = "arrow.right.circle"
    case arrowRightCircleFill = "arrow.right.circle.fill"
    case arrowTriangle2Circlepath = "arrow.triangle.2.circlepath"
    case arrowUp = "arrow.up"
    case boltBadgeAutomatic = "bolt.badge.automatic"
    case boltCircleFill = "bolt.circle.fill"
    case boltFill = "bolt.fill"
    case boltHorizontalCircle = "bolt.horizontal.circle"
    case checklist = "checklist"
    case checkmark = "checkmark"
    case checkmarkCircle = "checkmark.circle"
    case checkmarkCircleFill = "checkmark.circle.fill"
    case checkmarkSealFill = "checkmark.seal.fill"
    case checkmarkShield = "checkmark.shield"
    case chevronLeft = "chevron.left"
    case chevronRight = "chevron.right"
    case circle = "circle"
    case circleDashed = "circle.dashed"
    case clock = "clock"
    case clockArrowCirclepath = "clock.arrow.circlepath"
    case clockBadgeCheckmark = "clock.badge.checkmark"
    case clockBadgeExclamationmark = "clock.badge.exclamationmark"
    case cloud = "cloud"
    case cloudFill = "cloud.fill"
    case doc = "doc"
    case docOnClipboard = "doc.on.clipboard"
    case docOnDoc = "doc.on.doc"
    case docText = "doc.text"
    case docTextMagnifyingglass = "doc.text.magnifyingglass"
    case ellipsisCircle = "ellipsis.circle"
    case exclamationmarkCircle = "exclamationmark.circle"
    case exclamationmarkCircleFill = "exclamationmark.circle.fill"
    case exclamationmarkOctagon = "exclamationmark.octagon"
    case exclamationmarkShield = "exclamationmark.shield"
    case exclamationmarkShieldFill = "exclamationmark.shield.fill"
    case exclamationmarkTriangle = "exclamationmark.triangle"
    case exclamationmarkTriangleFill = "exclamationmark.triangle.fill"
    case externaldrive = "externaldrive"
    case externaldriveBadgeExclamationmark = "externaldrive.badge.exclamationmark"
    case eyeSlash = "eye.slash"
    case eyeSlashFill = "eye.slash.fill"
    case folder = "folder"
    case forwardEnd = "forward.end"
    case gearshape = "gearshape"
    case globe = "globe"
    case globeAsiaAustralia = "globe.asia.australia"
    case handRaised = "hand.raised"
    case handRaisedSquare = "hand.raised.square"
    case hourglass = "hourglass"
    case hourglassCircle = "hourglass.circle"
    case infinity = "infinity"
    case infoCircle = "info.circle"
    case keySlash = "key.slash"
    case laptopcomputer = "laptopcomputer"
    case largecircleFillCircle = "largecircle.fill.circle"
    case line3Horizontal = "line.3.horizontal"
    case line3HorizontalDecreaseCircleFill = "line.3.horizontal.decrease.circle.fill"
    case lockCircle = "lock.circle"
    case lockFill = "lock.fill"
    case lockShield = "lock.shield"
    case lockShieldFill = "lock.shield.fill"
    case lockTrianglebadgeExclamationmark = "lock.trianglebadge.exclamationmark"
    case macwindow = "macwindow"
    case magnifyingglass = "magnifyingglass"
    case memorychip = "memorychip"
    case menubarRectangle = "menubar.rectangle"
    case micBadgePlus = "mic.badge.plus"
    case micFill = "mic.fill"
    case minusCircle = "minus.circle"
    case network = "network"
    case noteText = "note.text"
    case pauseCircleFill = "pause.circle.fill"
    case pencil = "pencil"
    case photo = "photo"
    case photoBadgeExclamationmark = "photo.badge.exclamationmark"
    case pin = "pin"
    case pinFill = "pin.fill"
    case pinSlash = "pin.slash"
    case playCircle = "play.circle"
    case playCircleFill = "play.circle.fill"
    case plus = "plus"
    case plusCircle = "plus.circle"
    case power = "power"
    case powerCircleFill = "power.circle.fill"
    case point3ConnectedTrianglepathDotted = "point.3.connected.trianglepath.dotted"
    case questionmark = "questionmark"
    case questionmarkBubble = "questionmark.bubble"
    case questionmarkCircleFill = "questionmark.circle.fill"
    case recordCircle = "record.circle"
    case rectangleStackBadgePlus = "rectangle.stack.badge.plus"
    case slashCircleFill = "slash.circle.fill"
    case sliderHorizontal3 = "slider.horizontal.3"
    case sparkles = "sparkles"
    case speakerWave2 = "speaker.wave.2"
    case stethoscope = "stethoscope"
    case squareAndPencil = "square.and.pencil"
    case squareStack3dUp = "square.stack.3d.up"
    case squareStack3dUpFill = "square.stack.3d.up.fill"
    case stopFill = "stop.fill"
    case terminal = "terminal"
    case textAlignLeft = "text.alignleft"
    case textBadgeCheckmark = "text.badge.checkmark"
    case textBookClosed = "text.book.closed"
    case textBookClosedFill = "text.book.closed.fill"
    case textBubble = "text.bubble"
    case textCursor = "text.cursor"
    case textInsert = "text.insert"
    case textQuote = "text.quote"
    case textformat = "textformat"
    case trash = "trash"
    case tray = "tray"
    case wandAndStars = "wand.and.stars"
    case waveform = "waveform"
    case waveformBadgeMic = "waveform.badge.mic"
    case waveformBadgePlus = "waveform.badge.plus"
    case waveformCircleFill = "waveform.circle.fill"
    case waveformPathEcg = "waveform.path.ecg"
    case xmark = "xmark"
    case xmarkCircle = "xmark.circle"
    case xmarkCircleFill = "xmark.circle.fill"
    case xmarkOctagonFill = "xmark.octagon.fill"
    case xmarkShield = "xmark.shield"
    case xmarkSquare = "xmark.square"

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

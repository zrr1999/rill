import Foundation

public enum ClipboardCaptureTag: String, Codable, Sendable, Equatable {
    case excludeFromWorkflowCapture = "exclude-from-workflow-capture"
}

public struct ClipboardSnapshot: Codable, Sendable, Equatable {
    public var plainText: String
    public var imagePNGData: Data?
    public var fileURLs: [URL]
    public var changeCount: Int
    public var captureTags: [ClipboardCaptureTag]

    public init(
        plainText: String,
        imagePNGData: Data? = nil,
        fileURLs: [URL] = [],
        changeCount: Int,
        captureTags: [ClipboardCaptureTag] = []
    ) {
        self.plainText = plainText
        self.imagePNGData = imagePNGData
        self.fileURLs = fileURLs
        self.changeCount = changeCount
        self.captureTags = captureTags
    }
}

public struct FocusSnapshot: Codable, Sendable, Equatable {
    public var applicationName: String?
    public var bundleIdentifier: String?
    public var processIdentifier: Int32?
    public var focusedRole: String?
    public var selectedText: String
    public var secureInput: Bool
    public var capturedAt: Date

    public init(
        applicationName: String?,
        bundleIdentifier: String?,
        processIdentifier: Int32?,
        focusedRole: String?,
        selectedText: String,
        secureInput: Bool,
        capturedAt: Date = Date()
    ) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.focusedRole = focusedRole
        self.selectedText = selectedText
        self.secureInput = secureInput
        self.capturedAt = capturedAt
    }
}

public struct ContextSnapshot: Codable, Sendable, Equatable {
    public var focus: FocusSnapshot
    public var clipboard: ClipboardSnapshot

    public init(focus: FocusSnapshot, clipboard: ClipboardSnapshot) {
        self.focus = focus
        self.clipboard = clipboard
    }
}

public extension ContextSnapshot {
    static let empty = ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: nil,
            bundleIdentifier: nil,
            processIdentifier: nil,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
        ),
        clipboard: ClipboardSnapshot(plainText: "", changeCount: 0)
    )
}

public extension ClipboardSnapshot {
    var hasTransferableContent: Bool {
        !plainText.isEmpty || imagePNGData != nil || !fileURLs.isEmpty
    }

    var excludesWorkflowCapture: Bool {
        captureTags.contains(.excludeFromWorkflowCapture)
    }

    func appendingCaptureTags(_ tags: [ClipboardCaptureTag]) -> ClipboardSnapshot {
        var snapshot = self
        for tag in tags where !snapshot.captureTags.contains(tag) {
            snapshot.captureTags.append(tag)
        }
        return snapshot
    }

    func removingCaptureTags(_ tags: [ClipboardCaptureTag]) -> ClipboardSnapshot {
        var snapshot = self
        snapshot.captureTags.removeAll(where: { tags.contains($0) })
        return snapshot
    }
}

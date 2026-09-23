import AppKit
import ApplicationServices
import Carbon
import Foundation
import RillCore

public protocol CursorTextPreviewTarget: Sendable {
    func isFocused() -> Bool
    func supportsSelectedTextReplacement() -> Bool
    func selectedRange() -> NSRange?
    func selectedText(in range: NSRange) -> String?
    func replaceText(in range: NSRange, with text: String, selection: NSRange) -> Bool
}

public enum CursorTextPreviewCommitResult: Sendable, Equatable {
    case committed
    case useStandardInjection
    case blocked(reason: String)
}

public struct CursorTextPreviewDiagnostic: Sendable, Equatable {
    public var runID: UUID
    public var resultCode: String
    public var textLength: Int
    public var reason: String?

    public init(runID: UUID, resultCode: String, textLength: Int, reason: String? = nil) {
        self.runID = runID
        self.resultCode = resultCode
        self.textLength = textLength
        self.reason = reason
    }
}

/// Owns the single uncommitted Accessibility text range allowed in the app.
/// All state is run-scoped; preview text and replaced text never leave this actor.
public actor CursorTextPreviewCoordinator {
    public typealias TargetProvider = @Sendable () -> (any CursorTextPreviewTarget)?
    public typealias DiagnosticReporter = @Sendable (CursorTextPreviewDiagnostic) async -> Void

    private struct Transaction {
        let runID: UUID
        let target: any CursorTextPreviewTarget
        let originalRange: NSRange
        let originalText: String
        var previewRange: NSRange
        var previewText: String
        var expectedSelection: NSRange
        var lastWriteAt: Date?
    }

    private let accessibilityChecker: @Sendable () -> Bool
    private let secureInputChecker: @Sendable () -> Bool
    private let targetProvider: TargetProvider
    private let diagnosticReporter: DiagnosticReporter
    private let now: @Sendable () -> Date
    private let minimumWriteInterval: TimeInterval
    private var transaction: Transaction?
    private var overlayRuns: Set<UUID> = []
    private var blockedRuns: [UUID: String] = [:]
    private var closedRuns: [UUID] = []

    public init(
        accessibilityChecker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        secureInputChecker: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        targetProvider: TargetProvider? = nil,
        minimumWriteInterval: TimeInterval = 0.075,
        now: @escaping @Sendable () -> Date = Date.init,
        diagnosticReporter: @escaping DiagnosticReporter = { _ in }
    ) {
        self.accessibilityChecker = accessibilityChecker
        self.secureInputChecker = secureInputChecker
        self.targetProvider = targetProvider ?? { SystemCursorTextPreviewTarget.capture() }
        self.minimumWriteInterval = minimumWriteInterval
        self.now = now
        self.diagnosticReporter = diagnosticReporter
    }

    /// Freezes the effective placement into the published snapshot. When the
    /// cursor transaction cannot be proven safe, only this run is downgraded.
    public func project(_ snapshot: LiveSubtitleSnapshot) async -> LiveSubtitleSnapshot {
        guard snapshot.livePreviewPlacement == .cursor else { return snapshot }
        var projected = snapshot
        let runID = snapshot.runID

        guard !closedRuns.contains(runID) else {
            projected.livePreviewPlacement = .overlay
            return projected
        }
        if overlayRuns.contains(runID) || blockedRuns[runID] != nil {
            projected.livePreviewPlacement = .overlay
            return projected
        }

        if transaction?.runID != runID {
            guard transaction == nil else {
                overlayRuns.insert(runID)
                projected.livePreviewPlacement = .overlay
                await report(runID: runID, code: "fallback", length: 0, reason: "overlapping-run")
                return projected
            }
            guard await beginTransaction(runID: runID) else {
                projected.livePreviewPlacement = .overlay
                return projected
            }
        }

        let text = snapshot.displayText
        guard !text.isEmpty else { return projected }
        guard await updatePreview(runID: runID, text: text) else {
            projected.livePreviewPlacement = .overlay
            return projected
        }
        return projected
    }

    public func commit(runID: UUID, finalText: String) async -> CursorTextPreviewCommitResult {
        defer { close(runID: runID) }
        if let reason = blockedRuns.removeValue(forKey: runID) {
            await report(runID: runID, code: "blocked", length: finalText.count, reason: reason)
            return .blocked(reason: reason)
        }
        if overlayRuns.remove(runID) != nil {
            return .useStandardInjection
        }
        guard let current = transaction, current.runID == runID else {
            return .useStandardInjection
        }
        guard !current.previewText.isEmpty else {
            transaction = nil
            return .useStandardInjection
        }
        guard current.target.isFocused(),
              current.target.selectedRange() == current.expectedSelection,
              current.target.selectedText(in: current.previewRange) == current.previewText
        else {
            let outcome = await rollbackCurrent(reason: "target-moved-before-commit")
            if outcome == .conflict {
                return .blocked(reason: "target-content-changed")
            }
            return .useStandardInjection
        }
        let finalSelection = NSRange(
            location: current.previewRange.location + finalText.utf16.count,
            length: 0
        )
        guard current.target.replaceText(
            in: current.previewRange,
            with: finalText,
            selection: finalSelection
        ) else {
            blockedRuns[runID] = "final-replacement-failed"
            await report(
                runID: runID,
                code: "blocked",
                length: finalText.count,
                reason: "final-replacement-failed"
            )
            return .blocked(reason: "final-replacement-failed")
        }
        transaction = nil
        await report(runID: runID, code: "committed", length: finalText.count)
        return .committed
    }

    /// Ends a non-direct, failed, or cancelled run without retaining preview text.
    public func finish(runID: UUID) async {
        if transaction?.runID == runID {
            _ = await rollbackCurrent(reason: "run-finished-without-commit")
        }
        overlayRuns.remove(runID)
        blockedRuns.removeValue(forKey: runID)
        close(runID: runID)
    }

    public func shutdown() async {
        if transaction != nil {
            _ = await rollbackCurrent(reason: "application-shutdown")
        }
        overlayRuns.removeAll()
        blockedRuns.removeAll()
    }

    private enum RollbackOutcome {
        case restored
        case conflict
    }

    private func beginTransaction(runID: UUID) async -> Bool {
        guard accessibilityChecker() else {
            overlayRuns.insert(runID)
            await report(runID: runID, code: "fallback", length: 0, reason: "permission-missing")
            return false
        }
        guard !secureInputChecker() else {
            overlayRuns.insert(runID)
            await report(runID: runID, code: "fallback", length: 0, reason: "secure-input")
            return false
        }
        guard let target = targetProvider(), target.isFocused(),
              target.supportsSelectedTextReplacement(),
              let selectedRange = target.selectedRange(),
              let selectedText = target.selectedText(in: selectedRange)
        else {
            overlayRuns.insert(runID)
            await report(runID: runID, code: "fallback", length: 0, reason: "unsupported-target")
            return false
        }
        transaction = Transaction(
            runID: runID,
            target: target,
            originalRange: selectedRange,
            originalText: selectedText,
            previewRange: selectedRange,
            previewText: "",
            expectedSelection: selectedRange,
            lastWriteAt: nil
        )
        await report(runID: runID, code: "armed", length: selectedText.count)
        return true
    }

    private func updatePreview(runID: UUID, text: String) async -> Bool {
        guard var current = transaction, current.runID == runID else { return false }
        if let lastWriteAt = current.lastWriteAt,
           now().timeIntervalSince(lastWriteAt) < minimumWriteInterval {
            return true
        }

        if current.previewText.isEmpty {
            guard current.target.isFocused(),
                  current.target.selectedRange() == current.originalRange,
                  current.target.selectedText(in: current.originalRange) == current.originalText
            else {
                return await downgradeCurrent(reason: "selection-moved-before-insert")
            }
            let selection = NSRange(
                location: current.originalRange.location + text.utf16.count,
                length: 0
            )
            guard current.target.replaceText(
                in: current.originalRange,
                with: text,
                selection: selection
            ) else {
                return await downgradeCurrent(reason: "initial-write-failed")
            }
            current.previewText = text
            current.previewRange = NSRange(
                location: current.originalRange.location,
                length: text.utf16.count
            )
            current.expectedSelection = selection
            current.lastWriteAt = now()
            transaction = current
            return true
        }

        guard current.target.isFocused(),
              current.target.selectedRange() == current.expectedSelection
        else {
            return await downgradeCurrent(reason: "focus-or-selection-moved")
        }
        guard current.target.selectedText(in: current.previewRange) == current.previewText else {
            blockedRuns[runID] = "target-content-changed"
            transaction = nil
            await report(
                runID: runID,
                code: "blocked",
                length: current.previewText.count,
                reason: "target-content-changed"
            )
            return false
        }

        let prefixLength = Self.commonPrefixUTF16Length(current.previewText, text)
        let replacedSuffixRange = NSRange(
            location: current.previewRange.location + prefixLength,
            length: current.previewRange.length - prefixLength
        )
        let replacementSuffix = Self.utf16Suffix(text, from: prefixLength)
        let selection = NSRange(
            location: current.previewRange.location + text.utf16.count,
            length: 0
        )
        guard current.target.replaceText(
            in: replacedSuffixRange,
            with: replacementSuffix,
            selection: selection
        ) else {
            return await downgradeCurrent(reason: "tail-write-failed")
        }
        current.previewText = text
        current.previewRange.length = text.utf16.count
        current.expectedSelection = selection
        current.lastWriteAt = now()
        transaction = current
        return true
    }

    private func downgradeCurrent(reason: String) async -> Bool {
        guard let current = transaction else { return false }
        let runID = current.runID
        let outcome = await rollbackCurrent(reason: reason)
        switch outcome {
        case .restored:
            overlayRuns.insert(runID)
            return false
        case .conflict:
            blockedRuns[runID] = "target-content-changed"
            return false
        }
    }

    private func rollbackCurrent(reason: String) async -> RollbackOutcome {
        guard let current = transaction else { return .restored }
        transaction = nil
        if current.previewText.isEmpty {
            await report(runID: current.runID, code: "rolled-back", length: 0, reason: reason)
            return .restored
        }
        guard current.target.selectedText(in: current.previewRange) == current.previewText else {
            await report(
                runID: current.runID,
                code: "blocked",
                length: current.previewText.count,
                reason: "target-content-changed"
            )
            return .conflict
        }
        let restoredSelection = NSRange(
            location: current.originalRange.location,
            length: current.originalText.utf16.count
        )
        guard current.target.replaceText(
            in: current.previewRange,
            with: current.originalText,
            selection: restoredSelection
        ) else {
            await report(
                runID: current.runID,
                code: "blocked",
                length: current.previewText.count,
                reason: "rollback-failed"
            )
            return .conflict
        }
        await report(
            runID: current.runID,
            code: "rolled-back",
            length: current.previewText.count,
            reason: reason
        )
        return .restored
    }

    private func report(runID: UUID, code: String, length: Int, reason: String? = nil) async {
        await diagnosticReporter(
            CursorTextPreviewDiagnostic(
                runID: runID,
                resultCode: code,
                textLength: length,
                reason: reason
            )
        )
    }

    private func close(runID: UUID) {
        if transaction?.runID == runID { transaction = nil }
        overlayRuns.remove(runID)
        blockedRuns.removeValue(forKey: runID)
        closedRuns.append(runID)
        if closedRuns.count > 64 {
            closedRuns.removeFirst(closedRuns.count - 64)
        }
    }

    static func commonPrefixUTF16Length(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        while let leftCharacter = left.next(), let rightCharacter = right.next(),
              leftCharacter == rightCharacter {
            length += String(leftCharacter).utf16.count
        }
        return length
    }

    static func utf16Suffix(_ text: String, from offset: Int) -> String {
        let units = Array(text.utf16)
        guard offset < units.count else { return "" }
        return String(decoding: units[offset...], as: UTF16.self)
    }
}

final class SystemCursorTextPreviewTarget: CursorTextPreviewTarget, @unchecked Sendable {
    private let element: AXUIElement
    private let processIdentifier: pid_t

    private init(element: AXUIElement, processIdentifier: pid_t) {
        self.element = element
        self.processIdentifier = processIdentifier
    }

    static func capture() -> (any CursorTextPreviewTarget)? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else { return nil }
        let subrole = copyString(kAXSubroleAttribute as CFString, from: element)
        guard subrole != "AXSecureTextField" else { return nil }
        return SystemCursorTextPreviewTarget(
            element: element,
            processIdentifier: processIdentifier
        )
    }

    func isFocused() -> Bool {
        var focusedAttributeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            &focusedAttributeValue
        ) == .success,
        let isFocused = focusedAttributeValue as? Bool {
            return isFocused
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var currentPID: pid_t = 0
        guard AXUIElementGetPid(focused, &currentPID) == .success,
              currentPID == processIdentifier
        else { return false }
        return CFEqual(focused, element)
    }

    func supportsSelectedTextReplacement() -> Bool {
        var rangeSettable = DarwinBoolean(false)
        var textSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeSettable
        ) == .success
            && rangeSettable.boolValue
            && AXUIElementIsAttributeSettable(
                element,
                kAXSelectedTextAttribute as CFString,
                &textSettable
            ) == .success
            && textSettable.boolValue
    }

    func selectedRange() -> NSRange? {
        Self.copyRange(kAXSelectedTextRangeAttribute as CFString, from: element)
    }

    func selectedText(in range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }

        var cfRange = CFRange(location: range.location, length: range.length)
        if let rangeValue = AXValueCreate(.cfRange, &cfRange) {
            var rangedValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &rangedValue
            ) == .success,
            let rangedText = rangedValue as? String {
                return rangedText
            }
        }

        if let fullText = Self.copyString(kAXValueAttribute as CFString, from: element),
           let rangedText = Self.utf16Substring(fullText, in: range) {
            return rangedText
        }

        guard selectedRange() == range else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    func replaceText(in range: NSRange, with text: String, selection: NSRange) -> Bool {
        guard setSelectedRange(range),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
              ) == .success
        else { return false }
        return setSelectedRange(selection)
    }

    private func setSelectedRange(_ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func copyRange(_ attribute: CFString, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func copyString(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func utf16Substring(_ text: String, in range: NSRange) -> String? {
        let units = Array(text.utf16)
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= units.count
        else { return nil }
        return String(
            decoding: units[range.location..<(range.location + range.length)],
            as: UTF16.self
        )
    }
}

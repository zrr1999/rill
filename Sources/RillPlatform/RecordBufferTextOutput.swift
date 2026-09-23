import AppKit
import ApplicationServices
import Carbon
import RillCore

/// Explicit output only. No pasteboard port, paste shortcut, or restoration path.
@MainActor
public final class RecordBufferTextOutput {
  public struct Target {
    let element: any CursorTextPreviewTarget
    let isCurrent: @MainActor () -> Bool
    let post: @MainActor ([UInt16]) -> Bool

    public init(
      element: any CursorTextPreviewTarget, isCurrent: @escaping @MainActor () -> Bool,
      post: @escaping @MainActor ([UInt16]) -> Bool
    ) {
      self.element = element
      self.isCurrent = isCurrent
      self.post = post
    }
  }

  private let capture: @MainActor () -> Target?
  private let modifiersHeld: @MainActor () -> Bool
  private let isSecure: @MainActor () -> Bool

  public init(
    capture: (@MainActor () -> Target?)? = nil,
    modifiersHeld: (@MainActor () -> Bool)? = nil,
    isSecure: (@MainActor () -> Bool)? = nil
  ) {
    self.capture =
      capture ?? {
        guard AXIsProcessTrusted(), let element = SystemCursorTextPreviewTarget.capture(),
          let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let pid = app.processIdentifier
        return Target(
          element: element,
          isCurrent: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && element.isFocused()
          },
          post: { chunk in
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.postToPid(pid)
            up.postToPid(pid)
            return true
          })
      }
    self.modifiersHeld =
      modifiersHeld ?? {
        !CGEventSource.flagsState(.combinedSessionState).intersection([
          .maskCommand, .maskShift, .maskControl, .maskAlternate,
        ]).isEmpty
          || CGEventSource.keyState(.combinedSessionState, key: 9)
      }
    self.isSecure = isSecure ?? { IsSecureEventInputEnabled() }
  }

  public func captureTarget() -> Target? { isSecure() ? nil : capture() }

  public func insert(_ text: String, into target: Target) async -> BufferTextResult {
    guard !text.isEmpty, !isSecure(), target.isCurrent() else { return .rejected }
    // Never type while the triggering command/shift chord is physically held.
    let deadline = ContinuousClock.now + .seconds(2)
    while modifiersHeld() {
      guard ContinuousClock.now < deadline, !Task.isCancelled, !isSecure(), target.isCurrent()
      else { return .rejected }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return .rejected }
    }
    guard !Task.isCancelled, !isSecure(), target.isCurrent() else { return .rejected }
    let range = target.element.selectedRange()
    if target.element.supportsSelectedTextReplacement(), let range {
      let end = NSRange(location: range.location + text.utf16.count, length: 0)
      // A failed AX write may already have changed text or selection. Do not fall through.
      guard target.element.replaceText(in: range, with: text, selection: end) else {
        return .unconfirmed
      }
      return target.isCurrent() && target.element.selectedRange() == end
        && target.element.selectedText(
          in: NSRange(location: range.location, length: text.utf16.count)) == text
        ? .verified : .unconfirmed
    }
    var sent = false
    for chunk in Self.utf16Chunks(text) {
      guard !Task.isCancelled, !isSecure(), target.isCurrent(), !modifiersHeld() else {
        return sent ? .unconfirmed : .rejected
      }
      guard target.post(chunk) else { return sent ? .unconfirmed : .rejected }
      sent = true
      do { try await Task.sleep(for: .milliseconds(5)) } catch { return .unconfirmed }
    }
    // The receiver may ignore Unicode event text. Posting events is not delivery evidence.
    return .unconfirmed
  }

  public static func utf16Chunks(_ text: String, limit: Int = 20) -> [[UInt16]] {
    precondition(limit >= 2)
    var result: [[UInt16]] = []
    var chunk: [UInt16] = []
    for scalar in text.unicodeScalars {
      let units = Array(String(scalar).utf16)
      if chunk.count + units.count > limit {
        result.append(chunk)
        chunk = []
      }
      chunk += units
    }
    if !chunk.isEmpty { result.append(chunk) }
    return result
  }
}

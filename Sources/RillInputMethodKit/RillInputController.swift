import AppKit
import CRime
import Carbon
import InputMethodKit
import RillInputMethodContracts
import RillInputMethodIPC

@MainActor
@objc(RillInputController)
public final class RillInputController: IMKInputController {
  public static var engine: RimeEngine?
  public static var learning: InputMethodLearningClient?
  private var session: RimeSession?
  private var inputClient: (any IMKTextInput)?
  private let candidates = CandidateWindow()
  private var shiftPressed = false
  private var composition = InputMethodComposition()

  public override func activateServer(_ sender: Any!) {
    nonisolated(unsafe) let owner = self
    nonisolated(unsafe) let sender = sender
    MainActor.assumeIsolated { owner.activate(sender) }
  }

  private func activate(_ sender: Any!) {
    guard Self.engine != nil else { return }
    if let session { rill_rime_clear(session.id) }
    composition = InputMethodComposition()
    inputClient = sender as? any IMKTextInput
    session = RimeSession()
    candidates.selected = { [weak self] index in
      guard let self, let session = self.session, let client = self.inputClient else { return }
      if rill_rime_select(session.id, Int32(index)) != 0 { self.update(client) }
    }
  }

  public override func deactivateServer(_ sender: Any!) {
    nonisolated(unsafe) let owner = self
    nonisolated(unsafe) let sender = sender
    MainActor.assumeIsolated { owner.deactivate(sender) }
  }

  private func deactivate(_ sender: Any!) {
    commit(sender)
    candidates.hide()
    inputClient = nil
    session = nil
    shiftPressed = false
    composition = InputMethodComposition()
  }

  public override func recognizedEvents(_ sender: Any!) -> Int {
    Int(
      NSEvent.EventTypeMask([
        .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      ]).rawValue)
  }

  public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    nonisolated(unsafe) let owner = self
    nonisolated(unsafe) let sender = sender
    nonisolated(unsafe) let event = event
    return MainActor.assumeIsolated { owner.handleKey(event, client: sender) }
  }

  private func handleKey(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event, let client = sender as? any IMKTextInput, let session, session.id != 0 else {
      return false
    }
    if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
      commit(sender)
      return false
    }
    if let previous = inputClient, (previous as AnyObject) !== (client as AnyObject) {
      rill_rime_clear(session.id)
      composition = InputMethodComposition()
      candidates.hide()
    }
    inputClient = client
    if event.modifierFlags.contains(.command) {
      commit(sender)
      return false
    }
    var modifiers: Int32 = 0
    if event.modifierFlags.contains(.shift) { modifiers |= 1 }
    if event.modifierFlags.contains(.capsLock) { modifiers |= 2 }
    if event.modifierFlags.contains(.control) { modifiers |= 4 }
    if event.modifierFlags.contains(.option) { modifiers |= 8 }
    if event.type == .flagsChanged {
      let pressed = event.modifierFlags.contains(.shift)
      guard pressed != shiftPressed else { return false }
      shiftPressed = pressed
      _ = rill_rime_process_key(session.id, 0xffe1, pressed ? modifiers : modifiers | (1 << 30))
      update(client)
      return false
    }
    let special: [UInt16: Int32] = [
      36: 0xff0d, 76: 0xff0d, 48: 0xff09, 51: 0xff08, 53: 0xff1b,
      117: 0xffff, 123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52,
      115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56,
    ]
    let key: Int32
    if let mapped = special[event.keyCode] {
      key = mapped
    } else if let character = event.charactersIgnoringModifiers?.unicodeScalars.first {
      key = Int32(character.value < 256 ? character.value : character.value | 0x0100_0000)
    } else {
      return false
    }
    let handled = rill_rime_process_key(session.id, key, modifiers) != 0
    update(client)
    return handled
  }

  public override func commitComposition(_ sender: Any!) {
    nonisolated(unsafe) let owner = self
    nonisolated(unsafe) let sender = sender
    MainActor.assumeIsolated { owner.commit(sender) }
  }

  private func commit(_ sender: Any!) {
    guard let session, let client = inputClient else { return }
    rill_rime_commit_composition(session.id)
    update(client)
    rill_rime_clear(session.id)
    candidates.hide()
  }

  private func update(_ client: any IMKTextInput) {
    guard let session else { return }
    let committed = session.takeCommit()
    let snapshot = session.snapshot()
    composition.update(
      commit: committed, preedit: snapshot?.preedit ?? "", caret: snapshot?.caretUTF16 ?? 0,
      insert: { text in
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        if !IsSecureEventInputEnabled(), let bundle = client.bundleIdentifier() {
          Self.learning?.committed(text, application: bundle)
        }
      },
      mark: { text, selection in
        client.setMarkedText(
          text, selectionRange: selection,
          replacementRange: NSRange(location: NSNotFound, length: 0))
      })
    guard let snapshot else {
      candidates.hide()
      return
    }
    var caret = NSRect.zero
    let marked = client.markedRange()
    let selected = client.selectedRange()
    let index = marked.location != NSNotFound ? marked.location : selected.location
    _ = client.attributes(
      forCharacterIndex: index == NSNotFound ? 0 : index, lineHeightRectangle: &caret)
    candidates.show(snapshot, at: caret)
  }
}

@MainActor
public final class InputMethodLearningClient {
  private let channel: LocalInputMethodChannel
  private var policy: InputMethodLearningPolicy?
  private var heartbeat: Timer?

  public init() throws {
    channel = try LocalInputMethodChannel(host: false)
    channel.receive = { [weak self] message, sender in
      guard sender == LocalInputMethodChannel.hostPath, case .policy(let policy) = message.payload
      else { return }
      self?.policy = policy
    }
    channel.didConnect = { [weak self] _ in self?.hello() }
    channel.didDisconnect = { [weak self] _ in self?.policy = nil }
    heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.hello() }
    }
    hello()
  }

  private func hello() {
    if !channel.send(InputMethodMessage(.hello), to: LocalInputMethodChannel.hostPath) {
      policy = nil
    }
  }

  public func committed(_ text: String, application: String) {
    guard let policy, policy.permits(application), text.utf8.count <= 2_048 else { return }
    let commit = InputMethodCommit(
      policyRevision: policy.revision, application: application, text: text)
    if !channel.send(InputMethodMessage(.commit(commit)), to: LocalInputMethodChannel.hostPath) {
      self.policy = nil
    }
  }

  public func shutdown() {
    heartbeat?.invalidate()
    heartbeat = nil
    policy = nil
    channel.shutdown()
  }
}

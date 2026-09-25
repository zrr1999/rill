import CRime
import Darwin
import Foundation

@MainActor
public final class RimeEngine {
  public enum EngineError: Error { case dataUnavailable, alreadyRunning, libraryUnavailable }
  private let lockDescriptor: Int32

  public init(library: URL, directory: URL) throws {
    guard
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("default.yaml").path)
    else {
      throw EngineError.dataUnavailable
    }
    lockDescriptor = open(
      directory.appendingPathComponent("engine.lock").path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else { throw EngineError.dataUnavailable }
    guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(lockDescriptor)
      throw EngineError.alreadyRunning
    }
    guard rill_rime_open(library.path, directory.path) != 0 else {
      close(lockDescriptor)
      throw EngineError.libraryUnavailable
    }
  }

  public func shutdown() {
    rill_rime_close()
    // Held until process exit so a late IMK callback cannot race a deployment.
  }
}

@MainActor
final class RimeSession {
  struct Candidate {
    let text: String
    let comment: String
  }
  struct Snapshot {
    let preedit: String
    let caretUTF16: Int
    let candidates: [Candidate]
    let selected: Int
  }
  let id = rill_rime_create_session()
  deinit { if id != 0 { rill_rime_destroy_session(id) } }

  func snapshot() -> Snapshot? {
    guard id != 0, let pointer = rill_rime_state(id) else { return nil }
    defer { rill_rime_free_state(pointer) }
    let state = pointer.pointee
    let text = state.preedit.map { String(cString: $0) } ?? ""
    let prefix = String(decoding: text.utf8.prefix(max(0, Int(state.cursor))), as: UTF8.self)
    let candidates = (0..<Int(state.count)).map { index -> Candidate in
      let candidate = state.candidates[index]
      return Candidate(
        text: String(cString: candidate.text), comment: String(cString: candidate.comment))
    }
    return Snapshot(
      preedit: text, caretUTF16: prefix.utf16.count, candidates: candidates,
      selected: Int(state.selected))
  }

  func takeCommit() -> String? {
    guard id != 0, let pointer = rill_rime_take_commit(id) else { return nil }
    defer { rill_rime_free_text(pointer) }
    return String(cString: pointer)
  }
}

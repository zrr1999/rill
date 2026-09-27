import CRime
import Foundation

/// Deterministic replay for a copied profile. The caller owns and discards that copy.
@MainActor
public enum RimeProfileProbe {
  public struct Result: Codable {
    public let input: String
    public let preedit: String
    public let candidates: [String]
    public let committed: String?
  }

  public static func replay(library: URL, directory: URL, inputs: [String]) throws -> [Result] {
    guard inputs.count <= 32, inputs.allSatisfy({ $0.utf8.count <= 256 }) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let engine = try RimeEngine(library: library, directory: directory)
    defer { engine.shutdown() }
    return inputs.map { input in
      let session = RimeSession()
      for key in input.unicodeScalars {
        _ = rill_rime_process_key(
          session.id, Int32(key.value < 256 ? key.value : key.value | 0x0100_0000), 0)
      }
      let snapshot = session.snapshot()
      rill_rime_commit_composition(session.id)
      return Result(
        input: input, preedit: snapshot?.preedit ?? "",
        candidates: snapshot?.candidates.map(\.text) ?? [], committed: session.takeCommit())
    }
  }
}

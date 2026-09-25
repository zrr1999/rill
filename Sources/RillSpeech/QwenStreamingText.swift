import Foundation

enum QwenStreamingText {
  /// Qwen's automatic-language streaming path currently decodes its response
  /// envelope as ordinary text (`language None<asr_text>`). The offline API
  /// parses that envelope, but the upstream incremental session does not. Keep
  /// protocol markers out of the user-visible projection, including a second
  /// partial envelope emitted while a window is being restarted.
  static func sanitize(_ rawCandidate: String) -> String {
    let trimmedRawCandidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isIncompleteQwenLanguageEnvelope(trimmedRawCandidate) else { return "" }

    var candidate = trimmedRawCandidate
    var removedEnvelope = false
    let completeEnvelope = try? NSRegularExpression(
      pattern: #"(?i)(?:^|\s)language\s+[^<\r\n]{0,64}<asr_text>"#
    )
    if let completeEnvelope {
      let range = NSRange(candidate.startIndex..., in: candidate)
      if completeEnvelope.firstMatch(in: candidate, range: range) != nil {
        removedEnvelope = true
        candidate = completeEnvelope.stringByReplacingMatches(
          in: candidate,
          range: range,
          withTemplate: " "
        )
      }
    }

    if candidate.contains("<asr_text>") {
      removedEnvelope = true
      candidate = candidate.replacingOccurrences(of: "<asr_text>", with: " ")
    }
    if let specialToken = try? NSRegularExpression(
      pattern: #"<\|[^|\r\n]{1,64}\|>"#
    ) {
      let range = NSRange(candidate.startIndex..., in: candidate)
      candidate = specialToken.stringByReplacingMatches(
        in: candidate,
        range: range,
        withTemplate: " "
      )
    }

    if removedEnvelope,
      let partialEnvelope = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\s)language(?:\s+[^<\r\n]{0,64})?$"#
      )
    {
      let range = NSRange(candidate.startIndex..., in: candidate)
      candidate = partialEnvelope.stringByReplacingMatches(
        in: candidate,
        range: range,
        withTemplate: ""
      )
    }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(
      of: #"(?i)^language\s+(?:none|auto|chinese|english|cantonese)$"#,
      options: .regularExpression
    ) != nil {
      return ""
    }
    return trimmed
  }

  /// Incremental decoding exposes the automatic-language response envelope one
  /// token at a time: `language`, `language Chi`, then
  /// `language Chinese<asr_text>`. Until the marker is complete, none of that
  /// prefix is transcript text. Bound the hold to the envelope's 64-character
  /// language field so a genuine longer utterance cannot be hidden forever if
  /// an upstream decoder stops emitting the protocol marker.
  private static func isIncompleteQwenLanguageEnvelope(_ candidate: String) -> Bool {
    guard candidate.count <= 96 else { return false }
    guard candidate.range(
      of: #"(?i)^language(?:\s|$)"#,
      options: .regularExpression
    ) != nil else {
      return false
    }
    return candidate.range(
      of: #"(?i)<asr_text>"#,
      options: .regularExpression
    ) == nil
  }

}

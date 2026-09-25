import RillSpeechContracts

struct RecognitionPromptBudget {
  let context: String
  let tokenCount: Int
  let includedCount: Int
  let omittedCount: Int

  static func resolve(
    keyterms: [String], maximumTokens: Int,
    countTokens: (String) -> Int
  ) -> Self {
    // Preserve the established sanitization and byte ceiling until corpus
    // evidence permits expanding the candidate prompt.
    let candidates = LocalSpeechRecognitionPolicy.sanitizedQwenHotwords(keyterms)
    var selected: [String] = []
    var context = ""
    var tokens = 0
    for term in candidates {
      let proposed = "Keywords: \((selected + [term]).joined(separator: ", "))."
      let count = countTokens(proposed)
      guard count >= 0, count <= maximumTokens else { continue }
      selected.append(term)
      context = proposed
      tokens = count
    }
    return Self(
      context: context, tokenCount: tokens, includedCount: selected.count,
      omittedCount: keyterms.count - selected.count)
  }
}

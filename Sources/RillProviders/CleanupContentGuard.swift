import Foundation

/// Conservative literal checks, not a proof that the model preserved meaning.
enum CleanupContentGuard {
  static func accepts(transcript: String, proposed: String) -> Bool {
    let source = Snapshot(transcript)
    let result = Snapshot(proposed)
    return source.quantities == result.quantities && source.urls == result.urls
      && preservesCode(source.code, in: proposed)
      && containsInOrder(source.negativeSentences, in: result.normalized)
      && containsInOrder(result.negativeSentences, in: source.normalized)
  }

  private struct Literal {
    let text: String
    let range: NSRange
    let needsIdentifierBoundary: Bool
  }

  private struct Snapshot {
    let quantities: [String]
    let urls: [String]
    let code: [Literal]
    let negativeSentences: [String]
    let normalized: String

    init(_ text: String) {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      let links = linkDetector.matches(in: text, range: range).filter {
        ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "")
      }
      urls = links.map { (text as NSString).substring(with: $0.range) }
      let quoted = quotedCode.matches(in: text, range: range)
      let identifierText = masking(text, ranges: (links + quoted).map(\.range))
      let numericRanges = numbers.matches(in: identifierText, range: range).map(\.range)
      let identifiers = codeIdentifiers.matches(in: identifierText, range: range).filter { match in
        // A quantity unit such as MiB can have the same spelling as a code identifier.
        let value = (text as NSString).substring(with: match.range)
        return !asciiUnits.contains(value)
          || !numericRanges.contains {
            NSIntersectionRange($0, match.range) == match.range
          }
      }
      code =
        (quoted.map { Literal(text: (text as NSString).substring(with: $0.range), range: $0.range, needsIdentifierBoundary: false) }
        + identifiers.map { Literal(text: (text as NSString).substring(with: $0.range), range: $0.range, needsIdentifierBoundary: true) })
        .sorted { $0.range.location < $1.range.location }

      let markers = listMarkers.matches(in: text, range: range).map(\.range).filter { marker in
        !quoted.contains { NSIntersectionRange(marker, $0.range).length > 0 }
      }
      let quantityText = masking(text, ranges: links.map(\.range) + code.map(\.range))
      let withoutMarkers = masking(text, ranges: markers)
      let numberText = masking(quantityText, ranges: markers)
      quantities = numbers.matches(in: numberText, range: range).map {
        (numberText as NSString).substring(with: $0.range).filter { !$0.isWhitespace }
      }
      normalized = normalize(withoutMarkers)
      let negationText = masking(withoutMarkers, ranges: links.map(\.range) + code.map(\.range))
      negativeSentences = Self.negativeSentences(in: withoutMarkers, detectingIn: negationText)
    }

    private static func negativeSentences(in text: String, detectingIn detectionText: String) -> [String] {
      let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
      let boundaries = sentenceBoundaries.matches(in: detectionText, range: fullRange).map(\.range)
      var cursor = 0
      var sentences: [String] = []
      for boundary in boundaries + [NSRange(location: fullRange.length, length: 0)] {
        let range = NSRange(location: cursor, length: boundary.location - cursor)
        if negation.firstMatch(in: detectionText, range: range) != nil {
          let sentence = normalize((text as NSString).substring(with: range))
          if !sentence.isEmpty { sentences.append(sentence) }
        }
        cursor = NSMaxRange(boundary)
      }
      return sentences
    }
  }

  private static func normalize(_ text: String) -> String {
    let ignored = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
    return String(text.unicodeScalars.filter { !ignored.contains($0) }).lowercased()
  }

  private static func containsInOrder(_ pieces: [String], in text: String) -> Bool {
    var cursor = text.startIndex
    for piece in pieces {
      guard let match = text.range(of: piece, range: cursor..<text.endIndex) else { return false }
      cursor = match.upperBound
    }
    return true
  }

  private static func preservesCode(_ literals: [Literal], in text: String) -> Bool {
    var cursor = text.startIndex
    for literal in literals {
      var found = false
      while let match = text.range(of: literal.text, options: .literal, range: cursor..<text.endIndex) {
        cursor = match.upperBound
        let prefixIsIdentifier = match.lowerBound > text.startIndex && isIdentifierCharacter(text[text.index(before: match.lowerBound)])
        let suffixIsIdentifier = match.upperBound < text.endIndex && isIdentifierCharacter(text[match.upperBound])
        if !literal.needsIdentifierBoundary || (!prefixIsIdentifier && !suffixIsIdentifier) {
          found = true
          break
        }
      }
      guard found else { return false }
    }
    return true
  }

  private static func isIdentifierCharacter(_ character: Character) -> Bool {
    guard let value = character.asciiValue else { return false }
    return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) || value == 36 || value == 95
  }

  private static func masking(_ text: String, ranges: [NSRange]) -> String {
    let result = NSMutableString(string: text)
    for range in ranges.sorted(by: { $0.location > $1.location }) {
      result.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
    }
    return String(result)
  }

  // These fixed patterns are programmer-owned; invalid syntax is a programming error.
  private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  private static let quotedCode = try! NSRegularExpression(pattern: #"```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\r\n]+`"#)
  private static let listMarkers = try! NSRegularExpression(pattern: #"(?m)^ {0,3}[0-9]{1,9}[.)][\t ]+(?=\S)"#)
  private static let codeIdentifiers = try! NSRegularExpression(
    pattern: #"""
      (?<![A-Za-z0-9_$])(?:
        --[A-Za-z][A-Za-z0-9_-]*(?:=[^\s,;。！？]+)?
        | [A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*\([^()\r\n]*\)
        | [A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)+
        | [A-Za-z_$][A-Za-z0-9_$]*_[A-Za-z0-9_$]+
        | [a-z][A-Za-z0-9_$]*[A-Z][A-Za-z0-9_$]*
        | [A-Z][a-z0-9_$]+[A-Z][A-Za-z0-9_$]*
        | [A-Z]{2,}[a-z][A-Za-z0-9_$]*
        | [A-Za-z_$][A-Za-z0-9_$]*[0-9][A-Za-z0-9_$]*
        | [A-Za-z_$][A-Za-z0-9_$]*(?=\()
      )(?![A-Za-z0-9_$])
      """#,
    options: .allowCommentsAndWhitespace)
  private static let asciiUnitPattern = "ns|µs|μs|ms|kg|km|cm|mm|KiB|MiB|GiB|MB|GB|KB|Hz|s|g|m|L"
  private static let asciiUnits = Set(asciiUnitPattern.components(separatedBy: "|"))
  private static let numbers = try! NSRegularExpression(
    pattern: #"""
      (?:<=|>=|[<>=≤≥≈~～])? [+\-−±]? \s*
      (?:(?:人民币|美元|欧元|英镑|日元|[$€£¥￥])\s*)?
      (?:正负|[+\-−±负正])? \s*
      (?:
        [0-9０-９]+(?:,[0-9０-９]{3})*(?:[.．][0-9０-９]+)*(?:[eE][+\-]?[0-9]+)?[十百千万亿]?
        | (?:百分之|千分之)?[零〇一二两三四五六七八九十百千万亿半壹贰叁肆伍陆柒捌玖拾佰仟萬億]+(?:点[零〇一二两三四五六七八九半]+)?
      )
      (?:
        [A-Za-zµμ]+
        | \s+(?:\#(asciiUnitPattern))(?![A-Za-z_])
        | \s*(?:[%％‰℃]|°[CF]|人民币|美元|欧元|英镑|日元|万元|亿元|元|毫秒|分钟|小时|秒|分|点|个月|月|年|日|天|公里|厘米|毫米|米|千克|公斤|克|毫升|升|个|次|人|件)
      )?
      """#,
    options: .allowCommentsAndWhitespace)
  private static let negation = try! NSRegularExpression(
    pattern: #"[不没无勿]|未(?!来)|(?<![特区类])别|非(?!常)|禁止|\b(?:no|not|never|none|nothing|neither|nor|without|cannot)\b|\b[A-Za-z]+n['’]t\b"#,
    options: .caseInsensitive)
  private static let sentenceBoundaries = try! NSRegularExpression(pattern: #"[。！？!?；;\r\n]+|\.(?=\s|$)"#)
}

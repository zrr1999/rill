import Foundation

public struct InputMethodAppearance: Codable, Sendable, Equatable {
  public enum ValidationError: Error, Equatable {
    case unsupportedVersion, numberFormat, fontName, fontSize
  }

  public static let defaults = InputMethodAppearance()
  public static let fontSizes: ClosedRange<Double> = 10...48
  public var version = 1
  public var showsNumbers = true
  public var numberFormat = "{n}"
  public var fontName: String?
  public var fontSize = 20.0

  public init() {}

  public func validated() throws -> Self {
    guard version == 1 else { throw ValidationError.unsupportedVersion }
    guard numberFormat.count <= 32,
      numberFormat.components(separatedBy: "{n}").count == 2,
      numberFormat.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    else { throw ValidationError.numberFormat }
    if let fontName {
      guard !fontName.isEmpty, fontName.utf8.count <= 256,
        fontName.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw ValidationError.fontName }
    }
    guard fontSize.isFinite, Self.fontSizes.contains(fontSize) else {
      throw ValidationError.fontSize
    }
    return self
  }

  public func candidateLabel(at index: Int) -> String? {
    showsNumbers ? numberFormat.replacingOccurrences(of: "{n}", with: String(index + 1)) : nil
  }

  public func candidateTitle(at index: Int, text: String, comment: String) -> String {
    [candidateLabel(at: index), text, comment]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
  }
}

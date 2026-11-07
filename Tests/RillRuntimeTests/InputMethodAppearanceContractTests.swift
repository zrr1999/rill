import Foundation
import RillInputMethodContracts
import Testing

struct InputMethodAppearanceContractTests {
  @Test func labelsCanBeHiddenOrFormattedWithoutChangingCandidateText() throws {
    var appearance = InputMethodAppearance.defaults
    #expect(appearance.candidateTitle(at: 0, text: "你好", comment: "ni hao") == "1  你好  ni hao")
    appearance.numberFormat = "({n})."
    #expect(try appearance.validated().candidateTitle(at: 5, text: "世界", comment: "") == "(6).  世界")
    appearance.showsNumbers = false
    #expect(appearance.candidateTitle(at: 5, text: "世界", comment: "") == "世界")
  }

  @Test(arguments: ["", "1.", "{n}{n}", "{n}\n", "{n}\u{2028}", String(repeating: "x", count: 33) + "{n}"])
  func invalidTemplatesAreRejected(_ format: String) {
    var appearance = InputMethodAppearance.defaults
    appearance.numberFormat = format
    #expect(throws: InputMethodAppearance.ValidationError.numberFormat) { try appearance.validated() }
  }

  @Test(arguments: ["", "font\nname", String(repeating: "字", count: 86)])
  func invalidFontNamesAreRejected(_ name: String) {
    var appearance = InputMethodAppearance.defaults
    appearance.fontName = name
    #expect(throws: InputMethodAppearance.ValidationError.fontName) { try appearance.validated() }
  }

  @Test(arguments: [0.0, 9.0, 49.0, Double.infinity, Double.nan])
  func invalidFontSizesAreRejected(_ size: Double) {
    var appearance = InputMethodAppearance.defaults
    appearance.fontSize = size
    #expect(throws: InputMethodAppearance.ValidationError.fontSize) { try appearance.validated() }
  }

  @Test func versionedAppearanceRoundTripsAndRejectsUnknownVersions() throws {
    var appearance = InputMethodAppearance.defaults
    appearance.showsNumbers = false
    appearance.numberFormat = "{n}."
    appearance.fontName = "Helvetica-Bold"
    appearance.fontSize = 48
    let data = try JSONEncoder().encode(appearance)
    let decoded = try JSONDecoder().decode(InputMethodAppearance.self, from: data)
    #expect(try decoded.validated() == appearance)
    appearance.version = 99
    #expect(throws: InputMethodAppearance.ValidationError.unsupportedVersion) { try appearance.validated() }
  }
}

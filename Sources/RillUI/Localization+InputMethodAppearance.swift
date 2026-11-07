import Foundation
import RillInputMethodContracts

enum InputMethodAppearanceText: String, CaseIterable {
  case title, showNumbers, numberFormat, numberFormatHelp, font, systemFont, chooseFont
  case fontSize, preview, reset, apply, loadError, saveError
}

extension L10n {
  static func inputMethodAppearance(_ key: InputMethodAppearanceText, language: AppLanguage) -> String {
    catalogString("inputMethodAppearance.\(key.rawValue)", language: language)
  }

  static func inputMethodAppearanceFontSize(_ size: Double, language: AppLanguage) -> String {
    let number = size.formatted(.number.precision(.fractionLength(0...1)).locale(language.formattingLocale))
    return String(format: catalogString("inputMethodAppearance.pointSize", language: language), number)
  }

  static func inputMethodAppearanceValidationError(
    _ error: InputMethodAppearance.ValidationError, language: AppLanguage
  ) -> String {
    let key: String
    switch error {
    case .unsupportedVersion: key = "unsupportedVersion"
    case .numberFormat: key = "invalidNumberFormat"
    case .fontName: key = "invalidFont"
    case .fontSize: key = "invalidFontSize"
    }
    return catalogString("inputMethodAppearance.\(key)", language: language)
  }
}

import Foundation

extension AppLanguage {
  var locale: Locale {
    Locale(identifier: self == .english ? "en" : "zh-Hans")
  }

  var localizationBundle: Bundle {
    switch self {
    case .english: CatalogBundles.english
    case .simplifiedChinese: CatalogBundles.simplifiedChinese
    }
  }
}

private enum CatalogBundles {
  static let english = bundle(for: "en")
  static let simplifiedChinese = bundle(for: "zh-Hans")

  private static func bundle(for language: String) -> Bundle {
    guard let url = Bundle.module.url(forResource: language, withExtension: "lproj"),
      let bundle = Bundle(url: url)
    else {
      preconditionFailure("Missing RillUI localization resources: \(language)")
    }
    return bundle
  }
}

extension L10n {
  // Keep the original ungrouped integer display while Foundation selects the
  // catalog's plural variant. Resource interpolation localizes numeric grouping.
  static func pluralString(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
    let format = language.localizationBundle.localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, arguments: arguments)
  }

  static func resource(_ key: String) -> LocalizedStringResource {
    LocalizedStringResource(String.LocalizationValue(key), bundle: .atURL(Bundle.module.bundleURL))
  }

  static func resource(_ key: StaticString, defaultValue: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, defaultValue: defaultValue, bundle: .atURL(Bundle.module.bundleURL))
  }

  // Select the bundle explicitly: locale controls formatting, while the selected
  // app language must also control lookup independently of the system language.
  static func catalogString(_ key: String, language: AppLanguage) -> String {
    String(
      localized: String.LocalizationValue(key),
      bundle: language.localizationBundle,
      locale: language.locale
    )
  }
}

extension LocalizedStringResource {
  public func string(for language: AppLanguage) -> String {
    var resource = self
    resource.locale = language.locale
    return String(localized: resource)
  }

  public var english: String { string(for: .english) }
  public var simplifiedChinese: String { string(for: .simplifiedChinese) }
}

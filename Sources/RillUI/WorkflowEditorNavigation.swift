import Foundation

internal enum RecordDeliveryTitle {
    static func make(applicationName: String?, language: AppLanguage) -> String {
        guard let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return L10n.recordText(.insertInPreviousApp, language: language)
        }
        return String(format: L10n.presentation(.insertInto, language: language), name)
    }
}

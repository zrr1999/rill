import XCTest
@testable import RillCore

final class SettingsModelsTests: XCTestCase {
    func testWhisperKitDefaultsAllowExplicitDownloadWithoutBackgroundPrewarm() {
        let settings = LocalSpeechSettings()

        XCTAssertTrue(settings.downloadIfNeeded)
        XCTAssertFalse(settings.prewarm)
    }

    func testSpeechModelBudgetCountsUniqueModelsAndUsesConservativeFallbacks() {
        let fallback = SpeechModelResourceDescriptor(
            id: "fallback",
            capability: .speechToText,
            downloadByteCount: 2_000
        )
        let calibrated = SpeechModelResourceDescriptor(
            id: "calibrated",
            capability: .textToSpeech,
            downloadByteCount: 8_000,
            conservativeRuntimePeakByteCount: 5_000,
            measuredPeakByteCount: 4_000
        )
        let budget = SpeechModelResourceBudget(
            residentModelIDs: ["fallback", "calibrated"],
            catalog: [fallback, fallback, calibrated],
            physicalMemoryByteCount: 100_000
        )

        XCTAssertEqual(budget.models.map(\.id), ["calibrated", "fallback"])
        XCTAssertEqual(budget.estimatedPeakByteCount, 7_000)
        XCTAssertEqual(budget.estimatedFraction, 0.07, accuracy: 0.000_001)
        XCTAssertFalse(budget.requiresConfirmation)
    }

    func testSpeechModelBudgetWarnsOnlyAboveTwentyPercent() {
        let model = SpeechModelResourceDescriptor(
            id: "qwen",
            capability: .speechToText,
            downloadByteCount: 1,
            conservativeRuntimePeakByteCount: 2_001
        )
        let budget = SpeechModelResourceBudget(
            residentModelIDs: [model.id],
            catalog: [model],
            physicalMemoryByteCount: 10_000
        )

        XCTAssertTrue(budget.requiresConfirmation)
        XCTAssertGreaterThan(budget.estimatedFraction, SpeechModelResourceBudget.warningFraction)
    }

    func testSpeechModelBudgetConfirmationFingerprintChangesWithModelSet() {
        let first = SpeechModelResourceDescriptor(
            id: "first",
            capability: .speechToText,
            downloadByteCount: 2_000
        )
        let second = SpeechModelResourceDescriptor(
            id: "second",
            capability: .textToSpeech,
            downloadByteCount: 3_000
        )
        let initial = SpeechModelResourceBudget(
            residentModelIDs: [first.id],
            catalog: [first, second],
            physicalMemoryByteCount: 10_000
        )
        let changed = SpeechModelResourceBudget(
            residentModelIDs: [first.id, second.id],
            catalog: [first, second],
            physicalMemoryByteCount: 10_000
        )

        XCTAssertNotEqual(initial.confirmationFingerprint, changed.confirmationFingerprint)
    }
}

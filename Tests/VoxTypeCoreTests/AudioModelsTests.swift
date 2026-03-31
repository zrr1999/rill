import Foundation
import XCTest
@testable import VoxTypeCore

final class AudioModelsTests: XCTestCase {
    func testCapturedAudioRejectsMissingPayload() {
        XCTAssertThrowsError(
            try CapturedAudio(
                durationSeconds: 1.2,
                format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16)
            )
        ) { error in
            XCTAssertEqual(error as? CapturedAudio.ValidationError, .missingPayload)
        }
    }

    func testCapturedAudioAllowsInlinePayload() throws {
        let audio = try CapturedAudio(
            durationSeconds: 1.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([0x00, 0x01, 0x02])
        )

        XCTAssertEqual(audio.inlineData, Data([0x00, 0x01, 0x02]))
        XCTAssertNil(audio.fileURL)
    }
}

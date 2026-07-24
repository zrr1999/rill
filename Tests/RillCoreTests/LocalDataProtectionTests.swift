import Foundation
import XCTest
@testable import RillCore

final class LocalDataProtectionTests: XCTestCase {
    private let context = LocalDataProtectionContext(
        namespace: "history",
        recordID: "record-123",
        field: "final-text"
    )

    func testRoundTripUsesVersionedEnvelope() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x11))
        let plaintext = Data("Rill 本地数据".utf8)

        let envelope = try protector.seal(plaintext, context: context)

        XCTAssertTrue(envelope.hasPrefix("rill:v1:"))
        XCTAssertEqual(try protector.open(envelope, context: context), plaintext)
        XCTAssertNotEqual(envelope, String(decoding: plaintext, as: UTF8.self))
    }

    func testRepeatedSealUsesRandomNonce() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x22))
        let plaintext = Data("same plaintext".utf8)

        let first = try protector.seal(plaintext, context: context)
        let second = try protector.seal(plaintext, context: context)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try protector.open(first, context: context), plaintext)
        XCTAssertEqual(try protector.open(second, context: context), plaintext)
    }

    func testBinaryRoundTripAvoidsBase64ExpansionAndUsesRandomNonce() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x23))
        let plaintext = Data(repeating: 0xF3, count: 4_096)

        let first = try protector.sealBinary(plaintext, context: context)
        let second = try protector.sealBinary(plaintext, context: context)
        let textEnvelope = try protector.seal(plaintext, context: context)

        XCTAssertNotEqual(first, second)
        XCTAssertLessThan(first.count, textEnvelope.utf8.count)
        XCTAssertEqual(try protector.openBinary(first, context: context), plaintext)
        XCTAssertEqual(try protector.openBinary(second, context: context), plaintext)
    }

    func testBinaryEnvelopeIsBoundToContextAndRejectsTampering() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x24))
        var envelope = try protector.sealBinary(Data("binary secret".utf8), context: context)
        let wrongContext = LocalDataProtectionContext(
            namespace: context.namespace,
            recordID: "other-record",
            field: context.field
        )

        assertProtectionError(.authenticationFailed) {
            _ = try protector.openBinary(envelope, context: wrongContext)
        }

        envelope[envelope.index(before: envelope.endIndex)] ^= 0x01
        assertProtectionError(.authenticationFailed) {
            _ = try protector.openBinary(envelope, context: context)
        }
    }

    func testInvalidBinaryPrefixVersionAndPayloadAreRejected() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x25))

        assertProtectionError(.invalidEnvelopePrefix) {
            _ = try protector.openBinary(Data("plaintext".utf8), context: context)
        }
        assertProtectionError(.unsupportedEnvelopeVersion("v2")) {
            _ = try protector.openBinary(Data("rill\0v2\0payload".utf8), context: context)
        }
        assertProtectionError(.malformedSealedBox) {
            _ = try protector.openBinary(Data("rill\0v1\0x".utf8), context: context)
        }
    }

    func testWrongKeyFailsAuthenticationWithoutPlaintextFallback() throws {
        let writer = try AESGCMDataProtector(key: key(byte: 0x33))
        let reader = try AESGCMDataProtector(key: key(byte: 0x44))
        let envelope = try writer.seal(Data("secret".utf8), context: context)

        assertProtectionError(.authenticationFailed) {
            _ = try reader.open(envelope, context: context)
        }
    }

    func testWrongAssociatedDataFailsAuthentication() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x55))
        let envelope = try protector.seal(Data("secret".utf8), context: context)
        let wrongContext = LocalDataProtectionContext(
            namespace: context.namespace,
            recordID: context.recordID,
            field: "correction-source"
        )

        assertProtectionError(.authenticationFailed) {
            _ = try protector.open(envelope, context: wrongContext)
        }
    }

    func testTamperedAuthenticationTagIsRejected() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x66))
        let envelope = try protector.seal(Data("secret".utf8), context: context)
        var combined = try XCTUnwrap(combinedData(from: envelope))
        combined[combined.index(before: combined.endIndex)] ^= 0x01
        let tampered = "rill:v1:\(combined.base64EncodedString())"

        assertProtectionError(.authenticationFailed) {
            _ = try protector.open(tampered, context: context)
        }
    }

    func testInvalidPrefixVersionEncodingAndSealedBoxAreRejected() throws {
        let protector = try AESGCMDataProtector(key: key(byte: 0x77))

        assertProtectionError(.invalidEnvelopePrefix) {
            _ = try protector.open("plaintext", context: context)
        }
        assertProtectionError(.invalidEnvelopePrefix) {
            _ = try protector.open("other:v1:AAAA", context: context)
        }
        assertProtectionError(.unsupportedEnvelopeVersion("v2")) {
            _ = try protector.open("rill:v2:AAAA", context: context)
        }
        assertProtectionError(.invalidEnvelopeEncoding) {
            _ = try protector.open("rill:v1:not-base64!", context: context)
        }
        assertProtectionError(.invalidEnvelopeEncoding) {
            _ = try protector.open("rill:v1:AA==\n", context: context)
        }
        assertProtectionError(.malformedSealedBox) {
            _ = try protector.open(
                "rill:v1:\(Data([0x00]).base64EncodedString())",
                context: context
            )
        }
    }

    func testInvalidKeyLengthsAreRejected() {
        for length in [0, 16, 31, 33, 64] {
            assertProtectionError(
                .invalidKeyLength(expected: AESGCMDataProtector.keyByteCount, actual: length)
            ) {
                _ = try AESGCMDataProtector(key: Data(repeating: 0, count: length))
            }
        }
    }

    func testAssociatedDataIsStableAndComponentBoundariesAreUnambiguous() {
        let sameContext = LocalDataProtectionContext(
            namespace: "history",
            recordID: "record-123",
            field: "final-text"
        )
        let firstBoundary = LocalDataProtectionContext(
            namespace: "ab",
            recordID: "c",
            field: "d"
        )
        let secondBoundary = LocalDataProtectionContext(
            namespace: "a",
            recordID: "bc",
            field: "d"
        )

        XCTAssertEqual(context.associatedData(), sameContext.associatedData())
        XCTAssertNotEqual(firstBoundary.associatedData(), secondBoundary.associatedData())
    }

    private func key(byte: UInt8) -> Data {
        Data(repeating: byte, count: AESGCMDataProtector.keyByteCount)
    }

    private func combinedData(from envelope: String) -> Data? {
        let components = envelope.split(
            separator: ":",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return nil }
        return Data(base64Encoded: String(components[2]))
    }

    private func assertProtectionError(
        _ expected: LocalDataProtectionError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("Expected local data protection to fail.", file: file, line: line)
        } catch let error as LocalDataProtectionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

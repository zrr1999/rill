import Foundation
import XCTest
@testable import RillCore

final class SecureTransportPolicyTests: XCTestCase {
    func testAllowsHTTPSWithAHost() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1"))

        XCTAssertTrue(SecureTransportPolicy.allowsSensitiveHTTPURL(url))
    }

    func testRejectsPlainHTTPOutsideLoopback() throws {
        let url = try XCTUnwrap(URL(string: "http://api.example.com/v1"))

        XCTAssertFalse(SecureTransportPolicy.allowsSensitiveHTTPURL(url))
    }

    func testAllowsPlainHTTPOnLoopbackAddresses() throws {
        for rawURL in [
            "http://localhost:8787/v1",
            "http://127.0.0.1:8787/v1",
            "http://[::1]:8787/v1",
        ] {
            let url = try XCTUnwrap(URL(string: rawURL))
            XCTAssertTrue(SecureTransportPolicy.allowsSensitiveHTTPURL(url), rawURL)
        }
    }

    func testRejectsUnsupportedSchemesAndMissingHosts() throws {
        XCTAssertFalse(
            SecureTransportPolicy.allowsSensitiveHTTPURL(
                try XCTUnwrap(URL(string: "ftp://api.example.com/v1"))
            )
        )
        XCTAssertFalse(
            SecureTransportPolicy.allowsSensitiveHTTPURL(
                try XCTUnwrap(URL(string: "https:///v1"))
            )
        )
    }
}

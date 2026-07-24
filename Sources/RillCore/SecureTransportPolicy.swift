import Foundation

/// Shared trust boundary for endpoints that receive credentials or user content.
public enum SecureTransportPolicy {
    /// Allows HTTPS everywhere and plain HTTP only on the local loopback interface.
    public static func allowsSensitiveHTTPURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = normalizedHost(url.host)

        if scheme == "https" {
            return !host.isEmpty
        }
        return scheme == "http" && isLoopbackHost(host)
    }

    public static func isLoopbackHost(_ host: String?) -> Bool {
        switch normalizedHost(host) {
        case "localhost", "127.0.0.1", "::1":
            return true
        default:
            return false
        }
    }

    private static func normalizedHost(_ host: String?) -> String {
        let normalized = host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}

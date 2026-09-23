import Foundation
import MLX

public enum SpeechWorkerMLXCachePolicy {
  public static let environmentKey = "RILL_MLX_CACHE_LIMIT_BYTES"
  public static let defaultLimitBytes = 256 * 1_024 * 1_024
  public static let maximumLimitBytes = 1_024 * 1_024 * 1_024

  public static func resolvedLimit(environment: [String: String]) -> Int {
    guard let rawValue = environment[environmentKey],
      let requested = Int64(rawValue), requested >= 0
    else { return defaultLimitBytes }
    return Int(min(requested, Int64(maximumLimitBytes)))
  }

  public static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) {
    Memory.cacheLimit = resolvedLimit(environment: environment)
  }
}

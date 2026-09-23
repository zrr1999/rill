public enum JevAPIKey {
  public static func isValid(_ key: String) -> Bool {
    (8...512).contains(key.utf8.count) && key.utf8.allSatisfy { (33...126).contains($0) }
  }
}

import Foundation
import RillCore

/// Pure graph checks. `RecordStore` remains the only owner that commits them.
enum RecordGraphRules {
  static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen: Set<T> = []
    return values.filter { seen.insert($0).inserted }
  }

  static func normalizedTags(_ tags: [String]) -> [String] {
    stableUnique(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
  }

  static func isValidDeliveryRule(
    _ rule: DeliveryRouteRule, collectionIDs: Set<RecordCollectionID>
  ) -> Bool {
    guard rule.sourceCollectionIDs.count <= RecordGraphLimits.maximumRouteCollections,
      stableUnique(rule.sourceCollectionIDs) == rule.sourceCollectionIDs,
      rule.sourceCollectionIDs.allSatisfy(collectionIDs.contains)
    else { return false }
    guard rule.sink == .recordCollection else { return rule.sinkCollectionID == nil }
    if let destination = rule.sinkCollectionID { return collectionIDs.contains(destination) }
    // Deleting a target preserves a disabled rule that can be repaired in the editor.
    return !rule.isEnabled
  }
}

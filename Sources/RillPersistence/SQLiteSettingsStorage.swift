import Foundation
import GRDB
import RillCore

private struct AppSettingRecord: Decodable, FetchableRecord, Sendable {
  var key: String
  var value: String?
}

extension SQLitePersistenceSession {
  func string(forKey key: AppSettingKey) throws -> String? {
    guard
      let record = try AppSettingRecord.fetchOne(
        database,
        sql: "SELECT key, value FROM app_settings WHERE key = ?;",
        arguments: [key.rawValue]
      )
    else { return nil }
    guard let protectedValue = record.value else {
      throw SQLitePersistenceError.decodingRow("A setting row was missing its value.")
    }
    return try openString(protectedValue, context: settingsProtectionContext(keyRawValue: key.rawValue))
  }

  func strings(forKeys keys: [AppSettingKey]) throws -> [AppSettingKey: String] {
    let uniqueKeys = Array(Set(keys))
    guard !uniqueKeys.isEmpty else { return [:] }
    let placeholders = Array(repeating: "?", count: uniqueKeys.count).joined(separator: ", ")
    let records = try AppSettingRecord.fetchAll(
      database,
      sql: "SELECT key, value FROM app_settings WHERE key IN (\(placeholders));",
      arguments: StatementArguments(uniqueKeys.map(\.rawValue))
    )
    var values: [AppSettingKey: String] = [:]
    for record in records {
      guard let key = AppSettingKey(rawValue: record.key), let protectedValue = record.value else { continue }
      values[key] = try openString(protectedValue, context: settingsProtectionContext(keyRawValue: key.rawValue))
    }
    return values
  }

  func settingsSnapshot(forKeys keys: [AppSettingKey]) throws -> SettingsStoreReadSnapshot {
    let uniqueKeys = Array(Set(keys)).sorted { $0.rawValue < $1.rawValue }
    guard !uniqueKeys.isEmpty else { return .empty }
    let placeholders = Array(repeating: "?", count: uniqueKeys.count).joined(separator: ", ")
    let records = try AppSettingRecord.fetchAll(
      database,
      sql: "SELECT key, value FROM app_settings WHERE key IN (\(placeholders));",
      arguments: StatementArguments(uniqueKeys.map(\.rawValue))
    )
    var values: [AppSettingKey: String] = [:]
    var unavailableKeys: Set<AppSettingKey> = []
    for record in records {
      guard let key = AppSettingKey(rawValue: record.key) else { continue }
      guard let protectedValue = record.value else {
        unavailableKeys.insert(key)
        continue
      }
      do {
        values[key] = try openString(protectedValue, context: settingsProtectionContext(keyRawValue: key.rawValue))
      } catch {
        unavailableKeys.insert(key)
      }
    }
    return SettingsStoreReadSnapshot(values: values, unavailableKeys: unavailableKeys)
  }

  func setString(_ value: String, forKey key: AppSettingKey) throws {
    try upsertString(value, forKey: key, updatedAt: Date().timeIntervalSince1970)
  }

  func setStringsAtomically(_ values: [AppSettingKey: String]) throws {
    guard !values.isEmpty else { return }
    try withImmediateTransaction {
      let updatedAt = Date().timeIntervalSince1970
      for key in values.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        guard let value = values[key] else { continue }
        try upsertString(value, forKey: key, updatedAt: updatedAt)
      }
    }
  }

  private func upsertString(_ value: String, forKey key: AppSettingKey, updatedAt: TimeInterval) throws {
    let protectedValue = try protectString(value, context: settingsProtectionContext(keyRawValue: key.rawValue))
    try database.execute(
      sql: """
        INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
        """, arguments: [key.rawValue, protectedValue, updatedAt])
  }

  func removeValue(forKey key: AppSettingKey) throws {
    try database.execute(sql: "DELETE FROM app_settings WHERE key = ?;", arguments: [key.rawValue])
    if key == .openAIAPIKey || key == .legacyWhisperKitModelToken {
      // Legacy credentials can remain in old WAL frames after secure deletion.
      try truncateWriteAheadLog()
    }
  }
}

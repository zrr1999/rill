import Foundation
import RillCore
import SQLite3

extension SQLitePersistenceStore: SensitiveSettingsStore {
  public func string(forKey key: AppSettingKey) async throws -> String? {
    let statement = try prepare(
      """
      SELECT value
      FROM app_settings
      WHERE key = ?;
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(key.rawValue)], to: statement)

    let rc = sqlite3_step(statement)
    if rc == SQLITE_DONE {
      return nil
    }
    guard rc == SQLITE_ROW else {
      throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
    }

    guard let protectedValue = textColumn(in: statement, index: 0) else {
      throw SQLitePersistenceError.decodingRow("A setting row was missing its value.")
    }
    return try openString(
      protectedValue,
      context: settingsProtectionContext(keyRawValue: key.rawValue)
    )
  }

  public func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
    let uniqueKeys = Array(Set(keys))
    guard !uniqueKeys.isEmpty else { return [:] }

    let placeholders = Array(repeating: "?", count: uniqueKeys.count).joined(separator: ", ")
    let statement = try prepare(
      """
      SELECT key, value
      FROM app_settings
      WHERE key IN (\(placeholders));
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind(uniqueKeys.map { .text($0.rawValue) }, to: statement)

    var values: [AppSettingKey: String] = [:]
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE {
        break
      }
      guard rc == SQLITE_ROW else {
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }

      guard
        let keyText = textColumn(in: statement, index: 0),
        let key = AppSettingKey(rawValue: keyText),
        let protectedValue = textColumn(in: statement, index: 1)
      else {
        continue
      }

      values[key] = try openString(
        protectedValue,
        context: settingsProtectionContext(keyRawValue: key.rawValue)
      )
    }

    return values
  }

  public func settingsSnapshot(
    forKeys keys: [AppSettingKey]
  ) async throws -> SettingsStoreReadSnapshot {
    let uniqueKeys = Array(Set(keys)).sorted { $0.rawValue < $1.rawValue }
    guard !uniqueKeys.isEmpty else { return .empty }

    let placeholders = Array(repeating: "?", count: uniqueKeys.count).joined(separator: ", ")
    let statement = try prepare(
      """
      SELECT key, value
      FROM app_settings
      WHERE key IN (\(placeholders));
      """
    )
    defer { sqlite3_finalize(statement) }
    try bind(uniqueKeys.map { .text($0.rawValue) }, to: statement)

    var values: [AppSettingKey: String] = [:]
    var unavailableKeys: Set<AppSettingKey> = []
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE {
        break
      }
      guard rc == SQLITE_ROW else {
        throw SQLitePersistenceError.steppingStatement(lastErrorMessage())
      }

      guard
        let keyText = textColumn(in: statement, index: 0),
        let key = AppSettingKey(rawValue: keyText)
      else {
        continue
      }
      guard let protectedValue = textColumn(in: statement, index: 1) else {
        unavailableKeys.insert(key)
        continue
      }

      do {
        values[key] = try openString(
          protectedValue,
          context: settingsProtectionContext(keyRawValue: key.rawValue)
        )
      } catch {
        unavailableKeys.insert(key)
      }
    }

    return SettingsStoreReadSnapshot(
      values: values,
      unavailableKeys: unavailableKeys
    )
  }

  public func setString(_ value: String, forKey key: AppSettingKey) async throws {
    try upsertString(value, forKey: key, updatedAt: Date().timeIntervalSince1970)
  }

  public func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
    guard !values.isEmpty else { return }
    try withImmediateTransaction {
      let updatedAt = Date().timeIntervalSince1970
      for key in values.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        guard let value = values[key] else { continue }
        try upsertString(value, forKey: key, updatedAt: updatedAt)
      }
    }
  }

  private func upsertString(
    _ value: String,
    forKey key: AppSettingKey,
    updatedAt: TimeInterval
  ) throws {
    let protectedValue = try protectString(
      value,
      context: settingsProtectionContext(keyRawValue: key.rawValue)
    )
    let statement = try prepare(
      """
      INSERT INTO app_settings (key, value, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
          value = excluded.value,
          updated_at = excluded.updated_at;
      """
    )
    defer { sqlite3_finalize(statement) }

    try bind(
      [
        .text(key.rawValue),
        .text(protectedValue),
        .double(updatedAt),
      ],
      to: statement
    )

    try step(statement, expecting: SQLITE_DONE)
  }

  public func removeValue(forKey key: AppSettingKey) async throws {
    do {
      let statement = try prepare("DELETE FROM app_settings WHERE key = ?;")
      defer { sqlite3_finalize(statement) }
      try bind([.text(key.rawValue)], to: statement)
      try step(statement, expecting: SQLITE_DONE)
    }

    if key == .openAIAPIKey || key == .legacyWhisperKitModelToken {
      // Legacy credentials may still exist in an older WAL frame. Apply the
      // secure deletion to the main database, then truncate those frames.
      try truncateWriteAheadLog()
    }
  }

}

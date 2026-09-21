import Foundation
import RillCore
import SQLite3

extension SQLitePersistenceStore: RecordCatalogPersistenceStore {
  public func loadRecordCatalog() async throws -> RecordCatalogRead? {
    try withDeferredTransaction { try readRecordCatalog() }
  }

  private func readRecordCatalog() throws -> RecordCatalogRead? {
    guard let stored = try storedRecordGraphMetadata() else { return nil }
    let data = try localDataProtector.openBinary(
      stored.protectedGraph, context: Self.recordGraphProtectionContext)
    guard let manifest = try? JSONDecoder().decode(RecordCatalogManifest.self, from: data),
      manifest.schemaVersion == 2
    else {
      return nil
    }
    try validateCatalogManifest(manifest)
    let statement = try prepare(
      "SELECT key, kind, identifier, payload FROM record_catalog_nodes ORDER BY key;")
    defer { sqlite3_finalize(statement) }
    var nodes: [RecordCatalogNode] = []
    var byteCount = 0
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      guard nodes.count < RecordGraphLimits.maximumMemberships + 40_000,
        let key = textColumn(in: statement, index: 0),
        let rawKind = textColumn(in: statement, index: 1),
        let kind = RecordCatalogNode.Kind(rawValue: rawKind),
        let id = textColumn(in: statement, index: 2),
        let sealed = try dataColumn(in: statement, index: 3, maximumByteCount: 4 * 1_024 * 1_024)
      else { throw SQLitePersistenceError.clipboardPersistenceUnavailable }
      let value = try localDataProtector.openBinary(sealed, context: Self.catalogNodeContext(key))
      byteCount += value.count
      guard byteCount <= 256 * 1_024 * 1_024 else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      let node = RecordCatalogNode(kind: kind, id: id, value: value)
      guard node.key == key else { throw SQLitePersistenceError.clipboardPersistenceUnavailable }
      nodes.append(node)
    }
    let references = try catalogPayloadReferences()
    guard Set(references.map(\.recordID)) == Set(manifest.recordOrder) else {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
    return RecordCatalogRead(
      revision: stored.revision, manifest: manifest, nodes: nodes, references: references)
  }

  public func loadRecordPayload(_ reference: RecordGraphPersistenceBlobReference) async throws
    -> Data
  {
    try readRecordPayload(reference)
  }

  private func readRecordPayload(_ reference: RecordGraphPersistenceBlobReference) throws -> Data {
    let statement = try prepare(
      "SELECT record_id, payload_kind, plaintext_size, payload FROM record_payload_blobs WHERE blob_id = ?;"
    )
    defer { sqlite3_finalize(statement) }
    try bind([.text(reference.blobID.uuidString)], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
      textColumn(in: statement, index: 0) == reference.recordID.rawValue.uuidString,
      textColumn(in: statement, index: 1) == reference.kind.rawValue,
      sqlite3_column_int64(statement, 2) == reference.byteCount,
      let sealed = try dataColumn(in: statement, index: 3, maximumByteCount: 128 * 1_024 * 1_024)
    else { throw SQLitePersistenceError.clipboardPersistenceUnavailable }
    let value = try localDataProtector.openBinary(
      sealed, context: Self.recordPayloadProtectionContext(reference: reference))
    guard value.count == reference.byteCount else {
      throw SQLitePersistenceError.clipboardPersistenceUnavailable
    }
    return value
  }

  public func commitRecordCatalog(_ mutation: RecordCatalogMutation) async throws -> Int64 {
    try validateCatalogManifest(mutation.manifest)
    guard Set(mutation.upserts.map(\.key)).count == mutation.upserts.count,
      Set(mutation.removedKeys).isDisjoint(with: mutation.upserts.map(\.key))
    else {
      throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
    }
    return try withImmediateTransaction {
      let storedRevision = try storedRecordGraphRevision()
      guard storedRevision == mutation.expectedRevision, (storedRevision ?? 0) < Int64.max else {
        throw SQLitePersistenceError.clipboardPersistenceRevisionConflict
      }
      let wasCatalog: Bool
      if let stored = try storedRecordGraphMetadata() {
        let data = try localDataProtector.openBinary(
          stored.protectedGraph, context: Self.recordGraphProtectionContext)
        wasCatalog =
          (try? JSONDecoder().decode(RecordCatalogManifest.self, from: data).schemaVersion) == 2
      } else {
        wasCatalog = false
      }
      let nextRevision = (storedRevision ?? 0) + 1
      let manifestData = try JSONEncoder().encode(mutation.manifest)
      let sealedManifest = try localDataProtector.sealBinary(
        manifestData, context: Self.recordGraphProtectionContext)
      try upsertRecordGraphMetadata(protectedGraph: sealedManifest, revision: nextRevision)
      for key in mutation.removedKeys {
        let statement = try prepare("DELETE FROM record_catalog_nodes WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        try bind([.text(key)], to: statement)
        try step(statement, expecting: SQLITE_DONE)
      }
      for node in mutation.upserts {
        guard node.id.utf8.count <= 128, node.value.count <= 2 * 1_024 * 1_024 else {
          throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
        }
        let sealed = try localDataProtector.sealBinary(
          node.value, context: Self.catalogNodeContext(node.key))
        let statement = try prepare(
          """
          INSERT INTO record_catalog_nodes (key, kind, identifier, payload) VALUES (?, ?, ?, ?)
          ON CONFLICT(key) DO UPDATE SET payload = excluded.payload;
          """)
        defer { sqlite3_finalize(statement) }
        try bind(
          [.text(node.key), .text(node.kind.rawValue), .text(node.id), .blob(sealed)], to: statement
        )
        try step(statement, expecting: SQLITE_DONE)
        let readback = try prepare(
          "SELECT payload FROM record_catalog_nodes WHERE key = ? AND kind = ? AND identifier = ?;")
        defer { sqlite3_finalize(readback) }
        try bind([.text(node.key), .text(node.kind.rawValue), .text(node.id)], to: readback)
        guard sqlite3_step(readback) == SQLITE_ROW,
          let persisted = try dataColumn(
            in: readback, index: 0, maximumByteCount: 4 * 1_024 * 1_024),
          try localDataProtector.openBinary(persisted, context: Self.catalogNodeContext(node.key))
            == node.value
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
      }
      for id in mutation.removedPayloadBlobIDs { try deleteRecordPayloadBlob(blobID: id) }
      for blob in mutation.newPayloadBlobs {
        guard blob.payload.count == blob.reference.byteCount else {
          throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
        }
        let sealed = try localDataProtector.sealBinary(
          blob.payload, context: Self.recordPayloadProtectionContext(reference: blob.reference))
        try insertRecordPayloadBlob(
          PreparedRecordPayloadBlob(reference: blob.reference, protectedPayload: sealed))
        guard try readRecordPayload(blob.reference) == blob.payload else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
      }
      guard let persistedManifest = try storedRecordGraphMetadata(),
        persistedManifest.revision == nextRevision,
        try localDataProtector.openBinary(
          persistedManifest.protectedGraph, context: Self.recordGraphProtectionContext)
          == manifestData
      else {
        throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
      let references = try catalogPayloadReferences()
      guard Set(references.map(\.recordID)) == Set(mutation.manifest.recordOrder) else {
        throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
      }
      if !wasCatalog {
        // A format transition verifies every retained payload before the old graph is retired.
        for reference in references { _ = try readRecordPayload(reference) }
        guard let readback = try readRecordCatalog(), readback.manifest == mutation.manifest else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        try execute("DELETE FROM clipboard_image_blobs;")
        try execute("DELETE FROM clipboard_metadata WHERE id = 1;")
        try deleteLegacyClipboardRow()
      }
      return nextRevision
    }
  }

  private func catalogPayloadReferences() throws -> [RecordGraphPersistenceBlobReference] {
    let statement = try prepare(
      "SELECT blob_id, record_id, payload_kind, plaintext_size FROM record_payload_blobs ORDER BY blob_id;"
    )
    defer { sqlite3_finalize(statement) }
    let limits = RecordStorageLimits.productDefault
    var result: [RecordGraphPersistenceBlobReference] = []
    var bytes = 0
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE: return result
      case SQLITE_ROW:
        guard result.count < limits.maximumRecordCount,
          let blobID = textColumn(in: statement, index: 0).flatMap(UUID.init(uuidString:)),
          let recordID = textColumn(in: statement, index: 1).flatMap(UUID.init(uuidString:)),
          let kind = textColumn(in: statement, index: 2).flatMap(RecordPayloadKind.init(rawValue:))
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        let size = sqlite3_column_int64(statement, 3)
        let maximum: Int
        switch kind {
        case .text: maximum = limits.maximumTextUTF8ByteCount
        case .image: maximum = limits.maximumImageByteCount
        case .files:
          maximum = limits.maximumTotalFileURLUTF8ByteCount * 6 + limits.maximumFileURLCount * 3 + 2
        }
        guard size > 0, size <= maximum, bytes <= limits.maximumTotalPayloadByteCount - Int(size)
        else {
          throw SQLitePersistenceError.clipboardPersistenceUnavailable
        }
        bytes += Int(size)
        result.append(
          .init(blobID: blobID, recordID: RecordID(recordID), kind: kind, byteCount: Int(size)))
      default: throw SQLitePersistenceError.clipboardPersistenceUnavailable
      }
    }
  }

  private func validateCatalogManifest(_ manifest: RecordCatalogManifest) throws {
    guard manifest.schemaVersion == 2, manifest.nextMembershipOrdinal > 0,
      manifest.recordOrder.count <= RecordStorageLimits.productDefault.maximumRecordCount,
      Set(manifest.recordOrder).count == manifest.recordOrder.count,
      manifest.collectionOrder.count <= RecordStorageLimits.productDefault.maximumCollectionCount,
      Set(manifest.collectionOrder).count == manifest.collectionOrder.count
    else {
      throw SQLitePersistenceError.clipboardPersistenceInvalidWriteSnapshot
    }
  }

  private static func catalogNodeContext(_ key: String) -> LocalDataProtectionContext {
    LocalDataProtectionContext(namespace: "record_catalog_nodes", recordID: key, field: "payload")
  }
}

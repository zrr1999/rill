import Foundation
import RillCore

actor WorkflowFileWriter {
    func save(source: String, to url: URL, expected: WorkflowFileExpectation, historyDirectory: URL)
        throws
    {
        try prepare(url.deletingLastPathComponent())
        let previous = try existingSource(url)
        switch expected {
        case .missing: guard previous == nil else { throw WorkflowFileConflict.changed }
        case .source(let source):
            guard previous == source else { throw WorkflowFileConflict.changed }
        case .overwrite: break
        }
        if let previous, previous != source {
            try prepare(historyDirectory)
            let version = historyDirectory.appendingPathComponent("\(UUID().uuidString).toml")
            try replace(Data(previous.utf8), at: version)
        }
        guard try existingSource(url) == previous else { throw WorkflowFileConflict.changed }
        try replace(Data(source.utf8), at: url)
        // Maintenance failure must not turn a committed save into a reported failure.
        if let history = try? versions(in: historyDirectory) {
            for version in history.dropFirst(20) {
                try? FileManager.default.removeItem(at: version.id)
            }
        }
    }

    func versions(in directory: URL) throws -> [WorkflowFileVersion] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .creationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ], options: .skipsHiddenFiles)
        return try files.filter { $0.pathExtension == "toml" }.compactMap { url in
            let properties = try url.resourceValues(forKeys: [
                .creationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                properties.fileSize ?? 0 <= XDGWorkflowFileStore.maximumFileSize
            else { return nil }
            return try WorkflowFileVersion(
                id: url, date: properties.creationDate ?? .distantPast,
                source: String(contentsOf: url, encoding: .utf8))
        }.sorted { $0.date > $1.date }
    }

    private func existingSource(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let properties = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw WorkflowFileStoreError.unsupportedFile
        }
        guard properties.fileSize ?? 0 <= XDGWorkflowFileStore.maximumFileSize else {
            throw WorkflowFileStoreError.fileTooLarge
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func prepare(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw WorkflowFileStoreError.configurationPathIsNotDirectory
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    private func replace(_ data: Data, at destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

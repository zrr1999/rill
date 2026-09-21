import Foundation

/// Watches directory replacement and in-place file edits, including creation of an absent XDG directory.
@MainActor
final class WorkflowDirectoryObserver {
    private let directory: URL
    private let continuation: AsyncStream<Void>.Continuation
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: Task<Void, Never>?
    private var stopped = false

    private init(directory: URL, continuation: AsyncStream<Void>.Continuation) {
        self.directory = directory
        self.continuation = continuation
        watch()
    }

    static func changes(in directory: URL) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let observer = WorkflowDirectoryObserver(directory: directory, continuation: continuation)
        continuation.onTermination = { _ in Task { @MainActor in observer.stop() } }
        return stream
    }

    private func watch() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        var ancestor = directory
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        var urls = [ancestor]
        if ancestor == directory {
            urls.append(directory.deletingLastPathComponent())
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))
                ?? []
            urls += children.filter { $0.pathExtension.lowercased() == "toml" }.sorted {
                $0.path < $1.path
            }.prefix(XDGWorkflowFileStore.maximumFileCount)
        }
        for url in urls {
            let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.changed() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func changed() {
        guard !stopped else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !stopped else { return }
            watch()
            continuation.yield(())
        }
    }

    private func stop() {
        stopped = true
        debounce?.cancel()
        debounce = nil
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }
}

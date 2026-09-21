import RillSpeechContracts
import Darwin
import Foundation
import RillMLXRuntime

@main
enum RillSpeechWorkerMain {
  static func main() async {
    guard let standardIO = WorkerStandardIO() else {
      exit(EX_OSERR)
    }
    guard CommandLine.arguments.count == 1 else {
      log("invalid_arguments", to: standardIO.diagnosticOutput)
      exit(EX_USAGE)
    }
    SpeechWorkerMLXCachePolicy.apply()
    let status = await run(standardIO: standardIO)
    exit(status)
  }

  private static func run(standardIO: WorkerStandardIO) async -> Int32 {
    let reader = SpeechWorkerBoundedLineReader(fileHandle: .standardInput)
    let service = RoutedSpeechWorkerService()
    let protocolWriter = WorkerProtocolOutputWriter(
      output: standardIO.protocolOutput
    )
    let requestTaskRegistry = WorkerRequestTaskRegistry()

    while true {
      let line: Data
      do {
        guard
          let nextLine = try reader.readLine(
            maximumByteCount: SpeechWorkerProtocol.maximumRequestByteCount
          )
        else {
          await requestTaskRegistry.cancelAll()
          return 0
        }
        line = nextLine
      } catch {
        log("input_protocol_failure", to: standardIO.diagnosticOutput)
        return EX_DATAERR
      }

      let frame: SpeechWorkerFrame
      do {
        frame = try SpeechWorkerFrameCodec.decodeCommandLine(line)
      } catch {
        log("request_rejected", to: standardIO.diagnosticOutput)
        return EX_DATAERR
      }

      if case .command = frame.body {
        if case .command(.cancelRequest(let requestID)) = frame.body {
          await requestTaskRegistry.cancel(requestID: requestID)
          continue
        }
        await service.handleStreamingFrame(frame) { event in
          do {
            let encoded = try SpeechWorkerFrameCodec.encodeEventLine(event)
            _ = protocolWriter.write(encoded)
          } catch {
            protocolWriter.markFailed()
          }
        }
        guard !protocolWriter.hasFailed else {
          log("parent_connection_lost", to: standardIO.diagnosticOutput)
          return EX_IOERR
        }
        continue
      }

      guard case .request(let payload) = frame.body else {
        log("request_kind_rejected", to: standardIO.diagnosticOutput)
        return EX_DATAERR
      }
      let request = SpeechWorkerRequest(
        protocolVersion: frame.protocolVersion,
        requestID: frame.requestID,
        generation: frame.generation,
        payload: payload
      )
      let diagnosticOutput = standardIO.diagnosticOutput
      let didStart = await requestTaskRegistry.start(requestID: request.requestID) {
        await handleUnaryRequest(
          request,
          service: service,
          protocolWriter: protocolWriter,
          diagnosticOutput: diagnosticOutput
        )
      }
      guard didStart else {
        log("duplicate_request_id", to: standardIO.diagnosticOutput)
        await requestTaskRegistry.cancelAll()
        return EX_DATAERR
      }
    }
  }

  private static func handleUnaryRequest(
    _ request: SpeechWorkerRequest,
    service: RoutedSpeechWorkerService,
    protocolWriter: WorkerProtocolOutputWriter,
    diagnosticOutput: FileHandle
  ) async {
    let responseSequence = WorkerResponseSequence()
    let response = await service.handle(request) { progress in
      do {
        var response = SpeechWorkerResponse.progress(request: request, update: progress)
        response.sequence = responseSequence.next()
        let frame = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
        _ = protocolWriter.write(frame)
      } catch {
        protocolWriter.markFailed()
      }
    }
    guard !protocolWriter.hasFailed else {
      log("parent_connection_lost", to: diagnosticOutput)
      return
    }
    let encoded: Data
    do {
      var response = response
      response.sequence = responseSequence.next()
      encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
    } catch {
      var boundedFailure = SpeechWorkerResponse.failure(
        request: request,
        code: .recognitionFailed
      )
      boundedFailure.sequence = responseSequence.next()
      do {
        encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(boundedFailure)
      } catch {
        log("response_encoding_failure", to: diagnosticOutput)
        protocolWriter.markFailed()
        return
      }
    }

    guard protocolWriter.write(encoded) else {
      log("parent_connection_lost", to: diagnosticOutput)
      return
    }
  }

  /// Worker diagnostics are fixed tokens only. Audio paths and transcripts are
  /// never written to stderr, while stdout remains exclusively protocol frames.
  private static func log(_ event: StaticString, to output: FileHandle) {
    let data = Data("RillSpeechWorker: \(event)\n".utf8)
    try? output.write(contentsOf: data)
  }
}

private final class WorkerResponseSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0

  func next() -> UInt64 {
    lock.withLock {
      let current = value
      value &+= 1
      return current
    }
  }
}

private actor WorkerRequestTaskRegistry {
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func start(
    requestID: UUID,
    operation: @escaping @Sendable () async -> Void
  ) -> Bool {
    guard tasks[requestID] == nil else { return false }
    tasks[requestID] = Task { [weak self] in
      await operation()
      await self?.remove(requestID: requestID)
    }
    return true
  }

  func cancel(requestID: UUID) {
    tasks[requestID]?.cancel()
  }

  func cancelAll() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }

  private func remove(requestID: UUID) {
    tasks.removeValue(forKey: requestID)
  }
}

private final class WorkerProtocolOutputWriter: @unchecked Sendable {
  private let output: FileHandle
  private let lock = NSLock()
  private var failed = false

  init(output: FileHandle) {
    self.output = output
  }

  var hasFailed: Bool {
    lock.withLock { failed }
  }

  func markFailed() {
    lock.withLock {
      failed = true
    }
  }

  func write(_ data: Data) -> Bool {
    lock.withLock {
      guard !failed else { return false }
      do {
        try output.write(contentsOf: data)
        return true
      } catch {
        failed = true
        return false
      }
    }
  }
}

/// Keeps the parent's two observable pipes reserved for Rill's bounded
/// protocol and fixed diagnostics. Native libraries continue to see stdout and
/// stderr, but those descriptors point at `/dev/null`; they cannot corrupt a
/// response frame or leak recognition content. CLOEXEC also prevents any future
/// utility process from extending the lifetime of the parent's pipes.
private final class WorkerStandardIO {
  let protocolOutput: FileHandle
  let diagnosticOutput: FileHandle

  init?() {
    let protocolDescriptor = dup(STDOUT_FILENO)
    guard protocolDescriptor >= 0 else { return nil }
    let diagnosticDescriptor = dup(STDERR_FILENO)
    guard diagnosticDescriptor >= 0 else {
      _ = close(protocolDescriptor)
      return nil
    }
    let nullDescriptor = open("/dev/null", O_WRONLY)
    guard nullDescriptor >= 0 else {
      _ = close(protocolDescriptor)
      _ = close(diagnosticDescriptor)
      return nil
    }
    defer { _ = close(nullDescriptor) }

    guard dup2(nullDescriptor, STDOUT_FILENO) >= 0,
      dup2(nullDescriptor, STDERR_FILENO) >= 0,
      fcntl(protocolDescriptor, F_SETFD, FD_CLOEXEC) >= 0,
      fcntl(diagnosticDescriptor, F_SETFD, FD_CLOEXEC) >= 0
    else {
      _ = close(protocolDescriptor)
      _ = close(diagnosticDescriptor)
      return nil
    }
    self.protocolOutput = FileHandle(
      fileDescriptor: protocolDescriptor,
      closeOnDealloc: true
    )
    self.diagnosticOutput = FileHandle(
      fileDescriptor: diagnosticDescriptor,
      closeOnDealloc: true
    )
  }
}

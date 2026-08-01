import Darwin
import Foundation
import RillMLXRuntime
import RillProviders

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
    let status = await run(standardIO: standardIO)
    exit(status)
  }

  private static func run(standardIO: WorkerStandardIO) async -> Int32 {
    let reader = SpeechWorkerBoundedLineReader(fileHandle: .standardInput)
    let service = RoutedSpeechWorkerService()
    let protocolWriter = WorkerProtocolOutputWriter(
      output: standardIO.protocolOutput
    )

    while true {
      let line: Data
      do {
        guard
          let nextLine = try reader.readLine(
            maximumByteCount: SpeechWorkerProtocol.maximumRequestByteCount
          )
        else {
          return 0
        }
        line = nextLine
      } catch {
        log("input_protocol_failure", to: standardIO.diagnosticOutput)
        return EX_DATAERR
      }

      let request: SpeechWorkerRequest
      do {
        request = try SpeechWorkerProtocolCodec.decodeRequestLine(line)
      } catch {
        log("request_rejected", to: standardIO.diagnosticOutput)
        return EX_DATAERR
      }

      let response = await service.handle(request) { progress in
        do {
          let frame = try SpeechWorkerProtocolCodec.encodeResponseLine(
            .progress(request: request, update: progress)
          )
          _ = protocolWriter.write(frame)
        } catch {
          protocolWriter.markFailed()
        }
      }
      guard !protocolWriter.hasFailed else {
        log("parent_connection_lost", to: standardIO.diagnosticOutput)
        return EX_IOERR
      }
      let encoded: Data
      do {
        encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(response)
      } catch {
        let boundedFailure = SpeechWorkerResponse.failure(
          request: request,
          code: .recognitionFailed
        )
        do {
          encoded = try SpeechWorkerProtocolCodec.encodeResponseLine(boundedFailure)
        } catch {
          log("response_encoding_failure", to: standardIO.diagnosticOutput)
          return EX_SOFTWARE
        }
      }

      guard protocolWriter.write(encoded) else {
        log("parent_connection_lost", to: standardIO.diagnosticOutput)
        return EX_IOERR
      }
    }
  }

  /// Worker diagnostics are fixed tokens only. Audio paths and transcripts are
  /// never written to stderr, while stdout remains exclusively protocol frames.
  private static func log(_ event: StaticString, to output: FileHandle) {
    let data = Data("RillSpeechWorker: \(event)\n".utf8)
    try? output.write(contentsOf: data)
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

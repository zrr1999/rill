import Darwin
import Foundation
import RillInputMethodContracts
@testable import RillInputMethodIPC
import Testing

@MainActor
struct LocalInputMethodChannelTests {
  @Test func authenticatedStreamsBoundPayloadsAndSurvivePeerExit() async throws {
    let directory = "/tmp/rill-test-\(UUID().uuidString.prefix(8))"
    let host = try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in true })
    let client = try LocalInputMethodChannel(host: false, directory: directory, authenticate: { _, _ in true })
    defer {
      host.shutdown()
      client.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }
    var received = false
    host.receive = { message, sender in
      if case .hello = message.payload { received = sender == client.path }
    }
    client.didConnect = { _ in #expect(client.send(InputMethodMessage(.hello), to: host.path)) }
    #expect(!client.send(InputMethodMessage(.hello), to: host.path))
    for _ in 0..<100 where !received { try await Task.sleep(for: .milliseconds(10)) }
    #expect(received)
    let large = InputMethodCommit(
      policyRevision: UUID(), application: "editor", text: String(repeating: "x", count: 9_000))
    #expect(!client.send(InputMethodMessage(.commit(large)), to: host.path))
    var disconnected = false
    client.didDisconnect = { _ in disconnected = true }
    host.shutdown()
    for _ in 0..<100 where !disconnected { try await Task.sleep(for: .milliseconds(10)) }
    #expect(disconnected)
    #expect(!client.send(InputMethodMessage(.hello), to: host.path))
    let restarted = try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in true })
    restarted.shutdown()
  }

  @Test(arguments: [true, false])
  func eitherPeerCanRefuseTheConnection(refuseHost: Bool) async throws {
    let directory = "/tmp/rill-refuse-\(UUID().uuidString.prefix(8))"
    let host = try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in !refuseHost })
    let client = try LocalInputMethodChannel(host: false, directory: directory, authenticate: { _, _ in refuseHost })
    defer { host.shutdown(); client.shutdown(); try? FileManager.default.removeItem(atPath: directory) }
    var disconnected = false
    host.receive = { _, _ in Issue.record("Refused connection delivered a message") }
    client.receive = { _, _ in Issue.record("Refused connection delivered a message") }
    client.didConnect = { _ in _ = client.send(InputMethodMessage(.hello), to: host.path) }
    client.didDisconnect = { _ in disconnected = true }
    _ = client.send(InputMethodMessage(.hello), to: host.path)
    for _ in 0..<100 where !disconnected { try await Task.sleep(for: .milliseconds(10)) }
    #expect(disconnected)
  }

  @Test func productionAuthenticatorRejectsTestExecutables() async throws {
    let directory = "/tmp/rill-identity-\(UUID().uuidString.prefix(8))"
    let host = try LocalInputMethodChannel(host: true, directory: directory)
    let client = try LocalInputMethodChannel(host: false, directory: directory)
    defer { host.shutdown(); client.shutdown(); try? FileManager.default.removeItem(atPath: directory) }
    var disconnected = false
    client.didConnect = { _ in Issue.record("Test executable accepted as a signed Rill peer") }
    host.didConnect = { _ in Issue.record("Test executable accepted as a signed Rill peer") }
    client.didDisconnect = { _ in disconnected = true }
    _ = client.send(InputMethodMessage(.hello), to: host.path)
    for _ in 0..<100 where !disconnected { try await Task.sleep(for: .milliseconds(10)) }
    #expect(disconnected)
  }

  @Test func batchesKeepEveryFrameAndShutdownCancelsPendingAuthentication() async throws {
    let directory = "/tmp/rill-batch-\(UUID().uuidString.prefix(8))"
    let entered = AsyncStream<Void>.makeStream()
    let gate = DispatchSemaphore(value: 0)
    let host = try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in
      entered.continuation.yield(())
      return gate.wait(timeout: .now() + 5) == .success
    })
    let client = try LocalInputMethodChannel(host: false, directory: directory, authenticate: { _, _ in true })
    defer { gate.signal(); host.shutdown(); client.shutdown(); try? FileManager.default.removeItem(atPath: directory) }
    var accepted = false
    host.didConnect = { _ in accepted = true }
    _ = client.send(InputMethodMessage(.hello), to: host.path)
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    host.shutdown()
    gate.signal()
    let restarted = try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in true })
    defer { restarted.shutdown() }
    var received = 0
    restarted.receive = { _, _ in received += 1 }
    client.didConnect = { _ in
      for _ in 0..<40 { #expect(client.send(InputMethodMessage(.hello), to: restarted.path)) }
    }
    for _ in 0..<100 where received == 0 {
      _ = client.send(InputMethodMessage(.hello), to: restarted.path)
      try await Task.sleep(for: .milliseconds(10))
    }
    // One heartbeat may accompany the 40-frame batch.
    #expect(received >= 40)
    #expect(!accepted)
  }

  @Test func streamReassemblesFragmentsAndRejectsOversizedFrames() async throws {
    let directory = "/tmp/rill-frames-\(UUID().uuidString.prefix(8))"
    let host = try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in true })
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    defer { close(descriptor); host.shutdown(); try? FileManager.default.removeItem(atPath: directory) }
    var noSignal: Int32 = 1
    #expect(setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4) == 0)
    #expect(withAddress(directory + "/fixture.sock") { Darwin.bind(descriptor, $0, $1) } == 0)
    #expect(withAddress(host.path) { Darwin.connect(descriptor, $0, $1) } == 0)
    var connected = false
    var disconnected = false
    var received = 0
    host.didConnect = { _ in connected = true }
    host.didDisconnect = { _ in disconnected = true }
    host.receive = { _, _ in received += 1 }
    for _ in 0..<100 where !connected { try await Task.sleep(for: .milliseconds(10)) }
    #expect(connected)
    let bytes = try JSONEncoder().encode(InputMethodMessage(.hello))
    let length = UInt32(bytes.count)
    let header = Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
    #expect(Data(header.prefix(2)).withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) } == 2)
    try await Task.sleep(for: .milliseconds(10))
    #expect(received == 0)
    let tail = Data(header.suffix(2)) + bytes
    #expect(tail.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) } == tail.count)
    for _ in 0..<100 where received == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(received == 1)
    let oversized = Data([0, 0, 32, 1])
    #expect(oversized.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) } == 4)
    for _ in 0..<100 where !disconnected { try await Task.sleep(for: .milliseconds(10)) }
    #expect(disconnected)
    #expect(received == 1)
  }

  private func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
  }

  @Test func refusesSharedDirectoriesAndConcurrentHosts() throws {
    let directory = "/tmp/rill-test-\(UUID().uuidString.prefix(8))"
    let host = try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in true })
    defer {
      host.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }
    #expect(throws: (any Error).self) {
      try LocalInputMethodChannel(host: true, directory: directory, authenticate: { _, _ in true })
    }
    #expect(FileManager.default.fileExists(atPath: host.path))
    #expect(chmod(directory, 0o755) == 0)
    #expect(throws: (any Error).self) {
      try LocalInputMethodChannel(host: false, directory: directory, authenticate: { _, _ in true })
    }
  }
}

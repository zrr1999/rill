import Darwin
import Foundation
import RillInputMethodContracts

/// Learning uses authenticated, nonblocking local connections. Unavailable or full peers
/// drop the event; typed content is never queued for a later connection.
@MainActor
public final class LocalInputMethodChannel {
  public enum ChannelError: Error {
    case invalidDirectory, pathTooLong
    case unavailable(Int32)
  }
  public static var directory: String { "/tmp/dev.zrr.Rill-\(getuid())" }
  public static var hostPath: String { directory + "/host.sock" }
  public let path: String
  public var receive: ((InputMethodMessage, String) -> Void)?
  public var didConnect: ((String) -> Void)?
  public var didDisconnect: ((String) -> Void)?

  private static let authenticationQueue = DispatchQueue(label: "dev.zrr.Rill.input-method-auth")
  private let host: Bool
  private let directoryPath: String
  private let authenticate: @Sendable (Data, Bool) -> Bool
  private var listener: DispatchSourceRead?
  private var lockDescriptor: Int32 = -1
  private var stopped = false
  private var ownsPath = false
  private var connections: [String: Connection] = [:]

  @MainActor private final class Connection {
    let id = UUID()
    let descriptor: Int32
    let token: Data
    var reader: DispatchSourceRead?
    var authenticated = false
    var bytes = Data()

    init(descriptor: Int32, token: Data) {
      self.descriptor = descriptor
      self.token = token
    }

    func close() {
      if let reader {
        reader.cancel()
        self.reader = nil
      } else {
        Darwin.close(descriptor)
      }
    }
  }

  public convenience init(host: Bool, directory: String = LocalInputMethodChannel.directory) throws {
    try self.init(host: host, directory: directory, authenticate: LocalInputMethodPeerIdentity.validate)
  }

  init(host: Bool, directory: String, authenticate: @escaping @Sendable (Data, Bool) -> Bool) throws {
    self.host = host
    self.authenticate = authenticate
    directoryPath = URL(fileURLWithPath: directory).standardizedFileURL.path
    if mkdir(directoryPath, 0o700) != 0 && errno != EEXIST { throw ChannelError.unavailable(errno) }
    var info = stat()
    guard lstat(directoryPath, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700
    else { throw ChannelError.invalidDirectory }
    path = directoryPath + (host ? "/host.sock" : "/ime-\(getpid())-\(UUID().uuidString.prefix(8)).sock")
    if host {
      lockDescriptor = open(directoryPath + "/host.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard lockDescriptor >= 0 else { throw ChannelError.unavailable(errno) }
      guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno
        close(lockDescriptor)
        lockDescriptor = -1
        throw ChannelError.unavailable(code)
      }
      unlink(path)
      do {
        let descriptor = try Self.makeSocket(boundTo: path)
        ownsPath = true
        guard Darwin.listen(descriptor, 8) == 0 else {
          let code = errno
          close(descriptor)
          throw ChannelError.unavailable(code)
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        reader.setEventHandler { [weak self] in
          MainActor.assumeIsolated { self?.acceptConnections(descriptor) }
        }
        reader.setCancelHandler { close(descriptor) }
        listener = reader
        reader.resume()
      } catch {
        close(lockDescriptor)
        lockDescriptor = -1
        unlink(path)
        throw error
      }
    }
  }

  isolated deinit { shutdown() }

  @discardableResult
  public func send(_ message: InputMethodMessage, to destination: String) -> Bool {
    guard !stopped, isLocal(destination), let payload = try? JSONEncoder().encode(message),
      payload.count <= 8_192
    else { return false }
    guard let connection = connections[destination] else {
      if !host, destination == directoryPath + "/host.sock" { connect(destination) }
      return false
    }
    guard connection.authenticated else { return false }
    guard LocalInputMethodPeerIdentity.token(for: connection.descriptor) == connection.token else {
      disconnect(destination)
      return false
    }
    let count = UInt32(payload.count)
    let frame = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + payload
    let sent = frame.withUnsafeBytes { Darwin.send(connection.descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
    if sent == frame.count { return true }
    // A partial frame cannot be abandoned and followed by another frame on this stream.
    if sent >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
      disconnect(destination)
    }
    return false
  }

  public func shutdown() {
    guard !stopped else { return }
    stopped = true
    receive = nil
    didConnect = nil
    didDisconnect = nil
    for connection in connections.values { connection.close() }
    connections.removeAll()
    listener?.cancel()
    listener = nil
    if ownsPath { unlink(path); ownsPath = false }
    if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
  }

  private func connect(_ destination: String) {
    if ownsPath { unlink(path); ownsPath = false }
    guard let descriptor = try? Self.makeSocket(boundTo: path) else { return }
    ownsPath = true
    // A busy local listener is retried on the next heartbeat, without retaining this event.
    guard (try? Self.withAddress(destination) { Darwin.connect(descriptor, $0, $1) }) == 0 else {
      close(descriptor)
      unlink(path)
      ownsPath = false
      return
    }
    authenticateConnection(descriptor, peer: destination)
  }

  private func acceptConnections(_ descriptor: Int32) {
    guard !stopped else { return }
    for _ in 0..<16 {
      var address = sockaddr_un()
      var length = socklen_t(MemoryLayout<sockaddr_un>.size)
      let accepted = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(descriptor, $0, &length) }
      }
      guard accepted >= 0 else { return }
      let peer = withUnsafeBytes(of: address.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      guard address.sun_family == AF_UNIX, isLocal(peer), connections[peer] == nil,
        connections.count < 16, Self.configure(accepted)
      else { close(accepted); continue }
      authenticateConnection(accepted, peer: peer)
    }
  }

  private func authenticateConnection(_ descriptor: Int32, peer: String) {
    guard let token = LocalInputMethodPeerIdentity.token(for: descriptor) else { close(descriptor); return }
    let connection = Connection(descriptor: descriptor, token: token)
    connections[peer] = connection
    let id = connection.id
    let authenticate = authenticate
    let host = host
    Self.authenticationQueue.async { [weak self] in
      let accepted = authenticate(token, host)
      Task { @MainActor [weak self] in
        guard let self, !self.stopped, let connection = self.connections[peer], connection.id == id else { return }
        guard accepted, LocalInputMethodPeerIdentity.token(for: connection.descriptor) == token else {
          self.disconnect(peer)
          return
        }
        connection.authenticated = true
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        reader.setEventHandler { [weak self] in
          MainActor.assumeIsolated { self?.drain(peer, id: id) }
        }
        reader.setCancelHandler { close(descriptor) }
        connection.reader = reader
        reader.resume()
        self.didConnect?(peer)
      }
    }
  }

  private func drain(_ peer: String, id: UUID) {
    guard !stopped, let connection = connections[peer], connection.id == id else { return }
    guard LocalInputMethodPeerIdentity.token(for: connection.descriptor) == connection.token else {
      disconnect(peer)
      return
    }
    for _ in 0..<32 {
      if connection.bytes.count >= 4 {
        let length = connection.bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 8_192 else { disconnect(peer); return }
        if connection.bytes.count >= length + 4 {
          let payload = Data(connection.bytes.dropFirst(4).prefix(length))
          connection.bytes.removeFirst(length + 4)
          guard let message = try? JSONDecoder().decode(InputMethodMessage.self, from: payload), message.version == 1 else {
            disconnect(peer)
            return
          }
          receive?(message, peer)
          guard !stopped, connections[peer]?.id == id else { return }
          continue
        }
      }
      var bytes = [UInt8](repeating: 0, count: 8_196 - connection.bytes.count)
      let received = recv(connection.descriptor, &bytes, bytes.count, MSG_DONTWAIT)
      if received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
      if received < 0 && errno == EINTR { continue }
      guard received > 0 else { disconnect(peer); return }
      connection.bytes.append(contentsOf: bytes.prefix(received))
    }
    // Bound each callback, including messages already buffered in user space.
    Task { [weak self] in
      await Task.yield()
      self?.drain(peer, id: id)
    }
  }

  private func disconnect(_ peer: String) {
    guard let connection = connections.removeValue(forKey: peer) else { return }
    connection.close()
    didDisconnect?(peer)
  }

  private func isLocal(_ peer: String) -> Bool {
    URL(fileURLWithPath: peer).deletingLastPathComponent().standardizedFileURL.path == directoryPath
  }

  private static func configure(_ descriptor: Int32) -> Bool {
    var one: Int32 = 1
    return fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
      && fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
      && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
  }

  private static func makeSocket(boundTo path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ChannelError.unavailable(errno) }
    do {
      guard configure(descriptor), try withAddress(path, { Darwin.bind(descriptor, $0, $1) }) == 0,
        chmod(path, 0o600) == 0
      else { throw ChannelError.unavailable(errno) }
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ChannelError.pathTooLong }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
  }
}

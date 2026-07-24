/// App-wide availability of durable local persistence.
///
/// The status intentionally carries only a stable, non-sensitive reason. Raw
/// errors, database paths, and stored content must remain inside the storage
/// boundary and must never reach presentation state.
public enum LocalPersistenceStatus: Sendable, Equatable {
  public enum ReadyNotice: Sendable, Equatable {
    /// More than one immutable root key exists. Rill keeps every key so a
    /// concurrent or older writer can never lose the only key for its data.
    case alternateDataProtectionKeyRetained
  }

  public enum SessionOnlyReason: Sendable, Equatable {
    case persistentStorageUnavailable
    case keychainTemporarilyUnavailable
  }

  case ready
  case readyWithNotice(ReadyNotice)
  case sessionOnly(reason: SessionOnlyReason)

  public var isSessionOnly: Bool {
    if case .sessionOnly = self {
      return true
    }
    return false
  }
}

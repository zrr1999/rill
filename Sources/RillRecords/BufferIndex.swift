import RillCore

/// Actor-owned links support FIFO/LIFO selection and cancellation in constant time.
struct BufferIndex {
  struct Links {
    var previous: UInt64?
    var next: UInt64?
  }
  var links: [UInt64: Links] = [:]
  var first: UInt64?
  var last: UInt64?
  var count: Int { links.count }
  var records: [RecordID: UInt64] = [:]

  mutating func append(_ sequence: UInt64) {
    guard links[sequence] == nil else { return }
    links[sequence] = Links(previous: last)
    if let last { links[last]?.next = sequence } else { first = sequence }
    last = sequence
  }

  mutating func remove(_ sequence: UInt64) {
    guard let link = links.removeValue(forKey: sequence) else { return }
    if let previous = link.previous { links[previous]?.next = link.next } else { first = link.next }
    if let next = link.next { links[next]?.previous = link.previous } else { last = link.previous }
  }
}

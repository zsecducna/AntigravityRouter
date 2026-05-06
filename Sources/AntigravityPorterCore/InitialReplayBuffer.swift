import Foundation

/// Wraps bytes consumed from the initial connection read so they can be
/// prepended to future stream data exactly once, without duplication.
///
/// **Invariant**: every byte in `buffered` appears in downstream output
/// exactly once. After `drain()` or the first `prepend(to:)` call the
/// buffer is empty; subsequent calls return only the argument unchanged.
public struct InitialReplayBuffer: Sendable {

    private let buffered: Data
    private var handed: Bool = false

    /// - Parameter buffered: The bytes already consumed by the initial read
    ///   that must be replayed into the downstream path.
    public init(buffered: Data) {
        self.buffered = buffered
    }

    /// Returns `buffered ++ next` the first time; returns `next` thereafter.
    ///
    /// Use for paths that receive ongoing stream data and need the initial
    /// bytes prepended to the first chunk.
    public mutating func prepend(to next: Data) -> Data {
        if handed { return next }
        handed = true
        return buffered + next
    }

    /// Returns the buffered bytes and marks the buffer as drained.
    ///
    /// Use for paths that only consume the initial bytes (e.g. replay buffer
    /// is the entire first write to a downstream connection).
    public mutating func drain() -> Data {
        if handed { return Data() }
        handed = true
        return buffered
    }

    /// True after `drain()` or the first `prepend(to:)` call.
    public var isDrained: Bool { handed }

    /// Number of buffered bytes (unchanged after drain).
    public var count: Int { buffered.count }
}

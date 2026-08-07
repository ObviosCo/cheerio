/// Carries a non-Sendable value across an isolation boundary that region
/// isolation can't reason about on its own.
///
/// Sound only when the value is provably unshared. The audio path qualifies:
/// a buffer is deep-copied, handed off exactly once, and never touched again
/// by the sender.
struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
}

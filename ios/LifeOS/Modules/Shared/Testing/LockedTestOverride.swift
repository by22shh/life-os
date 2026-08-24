// MARK: - Thread-Safe Test Override Container
// Replaces `nonisolated(unsafe) static var` pattern with lock-protected storage.
// Prevents data races when tests run in parallel via `swift test --parallel`.
//
// Usage (production code):
//   #if DEBUG
//   static let testOverrideMyAction = LockedTestOverride<@Sendable () async -> Void>()
//   #endif
//
//   func doSomething() {
//       #if DEBUG
//       if let override = Self.testOverrideMyAction.value {
//           override()
//           return
//       }
//       #endif
//       // real implementation
//   }
//
// Usage (test code):
//   SomeType.testOverrideMyAction.value = { ... }
//   defer { SomeType.testOverrideMyAction.value = nil }

#if DEBUG
import Foundation

final class LockedTestOverride<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    init() {}

    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
#endif

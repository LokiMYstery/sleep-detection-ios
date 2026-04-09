import Foundation

/// A thread-safe wrapper for arbitrary values, including framework reference types.
final class ThreadSafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        self.storage = value
    }

    /// Read-only access to the protected value
    func read<R>(_ operation: (T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return operation(storage)
    }

    /// Mutable access to the protected value
    func write<R>(_ operation: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return operation(&storage)
    }

    /// Backward-compatible API for existing call sites that mutate under the lock.
    func withLock<R>(_ operation: (inout T) -> R) -> R {
        write(operation)
    }

    /// Get a copy of the current value
    var value: T {
        read { $0 }
    }
}

/// A thread-safe array wrapper with bounded size support
final class ThreadSafeArray<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T]
    private let maxSize: Int?

    init(maxSize: Int? = nil) {
        self.storage = []
        self.maxSize = maxSize
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.isEmpty
    }

    func append(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
        if let maxSize = maxSize, storage.count > maxSize {
            storage.removeFirst(storage.count - maxSize)
        }
    }

    func append(contentsOf elements: [T]) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(contentsOf: elements)
        if let maxSize = maxSize, storage.count > maxSize {
            storage.removeFirst(storage.count - maxSize)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    func drain() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let copy = storage
        storage.removeAll()
        return copy
    }

    /// Get a copy of all elements without draining
    func allElements() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage)
    }

    /// Access elements with a closure (read-only)
    func read<R>(_ operation: ([T]) -> R) -> R {
        let snapshot = allElements()
        return operation(snapshot)
    }
}

/// A circular buffer implementation for efficient sensor data processing
/// This avoids O(n) operations when removing oldest elements
final class CircularBuffer<T>: @unchecked Sendable where T: Sendable {
    private let lock = NSLock()
    private var buffer: [T?]
    private var head = 0
    private var tail = 0
    private var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }

    var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == capacity
    }

    var currentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func append(_ element: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < capacity else {
            return false
        }
        buffer[tail] = element
        tail = (tail + 1) % capacity
        count += 1
        return true
    }

    /// Append element, overwriting oldest if full (circular behavior)
    func appendOverwrite(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        buffer[tail] = element
        tail = (tail + 1) % capacity
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
    }

    func removeFirst() -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let element = buffer[head]
        buffer[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return element
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<capacity {
            buffer[i] = nil
        }
        head = 0
        tail = 0
        count = 0
    }

    /// Get all elements in order (oldest first) without removing
    func allElements() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var result: [T] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let index = (head + i) % capacity
            if let element = buffer[index] {
                result.append(element)
            }
        }
        return result
    }

    /// Access elements with a closure
    func read<R>(_ operation: ([T]) -> R) -> R {
        operation(allElements())
    }

    /// Get the last n elements in order
    func last(_ n: Int) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        let takeCount = min(n, count)
        var result: [T] = []
        result.reserveCapacity(takeCount)

        for i in 0..<takeCount {
            let offset = takeCount - 1 - i
            let index = (head + count - 1 - offset) % capacity
            if let element = buffer[index] {
                result.append(element)
            }
        }
        return result
    }
}

// MARK: - Unsafe Transfer for Non-Sendable Types (Use with Caution)

/// A wrapper for non-Sendable types that need to cross isolation boundaries
/// This is marked as unchecked Sendable - you must ensure thread safety externally
final class UnsafeSendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        self.storage = value
    }

    func withLock<R>(_ operation: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return operation(&storage)
    }

    func read<R>(_ operation: (T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return operation(storage)
    }
}

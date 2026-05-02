import Atomics
import Foundation

final class AtomicInt64 {
    private let storage: ManagedAtomic<Int64>

    init(_ initialValue: Int64) {
        storage = ManagedAtomic(initialValue)
    }

    @inline(__always)
    func load() -> Int64 {
        storage.load(ordering: .acquiring)
    }

    @inline(__always)
    func store(_ value: Int64) {
        storage.store(value, ordering: .releasing)
    }

    @inline(__always)
    func add(_ amount: Int64) {
        storage.wrappingIncrement(by: amount, ordering: .relaxed)
    }
}

final class AtomicFloat {
    private let storage: ManagedAtomic<Int32>

    init(_ initialValue: Float) {
        storage = ManagedAtomic(Self.bitPattern(for: initialValue))
    }

    @inline(__always)
    func load() -> Float {
        let bits = storage.load(ordering: .relaxed)
        return Float(bitPattern: UInt32(bitPattern: bits))
    }

    @inline(__always)
    func store(_ value: Float) {
        storage.store(Self.bitPattern(for: value), ordering: .relaxed)
    }

    @inline(__always)
    func storeMax(_ value: Float) {
        var currentBits = storage.load(ordering: .relaxed)

        while value > Float(bitPattern: UInt32(bitPattern: currentBits)) {
            let result = storage.compareExchange(
                expected: currentBits,
                desired: Self.bitPattern(for: value),
                ordering: .relaxed
            )

            if result.exchanged {
                return
            }

            currentBits = result.original
        }
    }

    @inline(__always)
    private static func bitPattern(for value: Float) -> Int32 {
        Int32(bitPattern: value.bitPattern)
    }
}

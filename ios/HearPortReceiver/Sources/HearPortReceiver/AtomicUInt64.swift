import Foundation
import HearPortAtomics

final class AtomicUInt64: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<UInt64>

    init(_ initialValue: UInt64 = 0) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: initialValue)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func load() -> UInt64 {
        hearport_atomic_load_u64(storage)
    }

    @discardableResult
    func increment(by amount: UInt64 = 1) -> UInt64 {
        hearport_atomic_fetch_add_u64(storage, amount) + amount
    }

    @discardableResult
    func exchange(_ replacement: UInt64) -> UInt64 {
        hearport_atomic_exchange_u64(storage, replacement)
    }
}

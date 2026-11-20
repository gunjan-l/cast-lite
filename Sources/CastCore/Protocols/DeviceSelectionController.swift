import Foundation

/// Applies a device selection and keeps only the latest in flight.
/// Re-selecting the device that is already selected does nothing.
/// A new selection cancels the previous work and waits for it to unwind before starting.
public final class DeviceSelectionController: @unchecked Sendable {
    private let lock = NSLock()
    private var currentID: String?
    private var task: Task<Void, Never>?
    private let perform: @Sendable (DiscoveredDevice?) async -> Void

    public init(perform: @escaping @Sendable (DiscoveredDevice?) async -> Void) {
        self.perform = perform
    }

    public func select(_ device: DiscoveredDevice?) {
        lock.lock()
        defer { lock.unlock() }
        guard device?.id != currentID else { return }
        currentID = device?.id
        let previous = task
        previous?.cancel()
        let perform = self.perform
        task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await perform(device)
        }
    }

    public func waitUntilIdle() async {
        lock.lock()
        let current = task
        lock.unlock()
        await current?.value
    }
}

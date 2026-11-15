import Foundation

/// All preview state and writes belong to one utility queue. Never caches a failed write.
final class PreviewWorkQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "henge.preview", qos: .utility)
    private var last: (path: String, frame: UInt64)?

    func beginSession() { queue.async { self.last = nil } }
    func save(path: String, frame: @escaping @Sendable () -> UInt64,
              write: @escaping @Sendable () -> Bool) {
        queue.async {
            let current = frame()
            if let previous = self.last, previous.path == path, previous.frame == current { return }
            if write() { self.last = (path, current) }
        }
    }
    func finish(write: @Sendable () -> Bool) {
        queue.sync { _ = write(); last = nil }
    }
    func drain() { queue.sync {} }
}

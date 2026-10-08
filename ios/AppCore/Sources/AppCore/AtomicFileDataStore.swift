import Foundation
import SecurityCore

/// App-support JSON storage with bounded reads and atomic replacement in one directory.
public final class AppSupportAtomicDataStore: AtomicDataStore, @unchecked Sendable {
    private let url: URL
    private let maximumSize: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(filename: String, maximumSize: Int = 512 * 1024, fileManager: FileManager = .default) throws {
        guard !filename.isEmpty, !filename.contains("/") && maximumSize > 0 else { throw InventoryError.storageFailure }
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw InventoryError.storageFailure }
        let appDirectory = directory.appendingPathComponent("SSHepherd", isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        self.url = appDirectory.appendingPathComponent(filename, isDirectory: false)
        self.maximumSize = maximumSize
        self.fileManager = fileManager
    }

    public func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumSize else { throw InventoryError.corruptData }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    public func replace(with data: Data) throws {
        guard data.count <= maximumSize else { throw InventoryError.storageFailure }
        lock.lock(); defer { lock.unlock() }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw InventoryError.storageFailure
        }
    }
}

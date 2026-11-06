import Foundation

/// Rolls back all related artifacts if any write fails. Individual replacements are atomic.
/// Callers serialize commits on ScanLibrary's actor; background workers never change live files.
enum ScanArtifactTransaction {
    static func replace(_ updates: [(URL, Data?)]) throws {
        let manager = FileManager.default
        // Read every backup before modifying anything, including metadata and removed assets.
        let backups: [(URL, Data?)] = try updates.map { url, _ in
            (url, manager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
        }
        do {
            for (url, data) in updates {
                if let data {
                    try data.write(to: url, options: .atomic)
                } else if manager.fileExists(atPath: url.path) {
                    try manager.removeItem(at: url)
                }
            }
        } catch {
            for (url, data) in backups {
                if let data {
                    try? data.write(to: url, options: .atomic)
                } else if manager.fileExists(atPath: url.path) {
                    try? manager.removeItem(at: url)
                }
            }
            throw error
        }
    }
}

import Foundation

enum RecentCommandsStore {
    static var file: URL { ConfigStore.file.deletingLastPathComponent().appendingPathComponent("recent-commands.json") }
    static func read() throws -> [String] {
        try ConfigStore.withLock {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            let data = try Data(contentsOf: file)
            guard data.count <= 100_000 else { throw ConfigError.io("Recent commands are too large.") }
            let values = try JSONDecoder().decode([String].self, from: data)
            guard values.count <= 50, values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw ConfigError.io("Invalid recent commands.") }
            return values
        }
    }
    static func save(_ values: [String]) throws {
        try ConfigStore.withLock { try privateAtomicWrite(JSONEncoder().encode(values), to: file) }
    }
}

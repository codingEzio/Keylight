import Foundation
import Darwin

struct SearchHistory: Codable, Equatable {
    struct Query: Codable, Equatable {
        var text: String
        // Oldest first; a short rolling window lets a change in habit win.
        var apps: [String]
    }
    static let maxQueries = 100
    static let maxSelections = 8
    var version = 1
    var queries: [Query] = []

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    mutating func record(query: String, app: String) {
        let text = Self.normalized(query)
        guard !text.isEmpty, text.utf8.count <= 128, app.hasPrefix("/"), app.utf8.count <= 1024 else { return }
        let index = queries.firstIndex { $0.text == text }
        var entry = index.map { queries.remove(at: $0) } ?? Query(text: text, apps: [])
        entry.apps.append(app)
        if entry.apps.count > Self.maxSelections { entry.apps.removeFirst(entry.apps.count - Self.maxSelections) }
        queries.append(entry)
        if queries.count > Self.maxQueries { queries.removeFirst(queries.count - Self.maxQueries) }
    }
    func preference(for query: String) -> [String: Int] {
        guard let apps = queries.first(where: { $0.text == Self.normalized(query) })?.apps else { return [:] }
        var counts: [String: Int] = [:], recent: [String: Int] = [:]
        for (index, app) in apps.enumerated() { counts[app, default: 0] += 1; recent[app] = index }
        let ordered = counts.keys.sorted {
            counts[$0] == counts[$1] ? recent[$0, default: 0] > recent[$1, default: 0] : counts[$0, default: 0] > counts[$1, default: 0]
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
    }
    func validate() throws {
        guard version == 1, queries.count <= Self.maxQueries,
              Set(queries.map(\.text)).count == queries.count,
              queries.allSatisfy({ !$0.text.isEmpty && $0.text == Self.normalized($0.text) && $0.text.utf8.count <= 128 && !$0.apps.isEmpty && $0.apps.count <= Self.maxSelections && $0.apps.allSatisfy { $0.hasPrefix("/") && $0.utf8.count <= 1024 } }) else {
            throw ConfigError.io(NSLocalizedString("Invalid search learning data. Reset search learning to continue.", comment: ""))
        }
    }
}

enum SearchHistoryStore {
    static var file: URL { ConfigStore.file.deletingLastPathComponent().appendingPathComponent(ConfigStore.file.lastPathComponent + ".search-history.json") }
    private static let maxBytes = 1_000_000

    private static func readUnlocked() throws -> SearchHistory {
        guard FileManager.default.fileExists(atPath: file.path) else { return SearchHistory() }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard let size, size.int64Value <= Int64(maxBytes) else { throw ConfigError.io(NSLocalizedString("Invalid search learning data. Reset search learning to continue.", comment: "")) }
        let data = try Data(contentsOf: file)
        guard data.count <= maxBytes else { throw ConfigError.io(NSLocalizedString("Invalid search learning data. Reset search learning to continue.", comment: "")) }
        let history: SearchHistory
        do { history = try JSONDecoder().decode(SearchHistory.self, from: data) }
        catch { throw ConfigError.io(NSLocalizedString("Invalid search learning data. Reset search learning to continue.", comment: "")) }
        try history.validate()
        return history
    }
    static func read() throws -> SearchHistory { try ConfigStore.withLock { try readUnlocked() } }
    private static func writeUnlocked(_ history: SearchHistory) throws {
        try history.validate()
        let data = try JSONEncoder().encode(history)
        guard data.count <= maxBytes else { throw ConfigError.io(NSLocalizedString("Search learning data is too large.", comment: "")) }
        let temp = file.deletingLastPathComponent().appendingPathComponent(".search-history-\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io(NSLocalizedString("Cannot create search learning data.", comment: "")) }
        defer { close(fd); unlink(temp.path) }
        try ConfigStore.requireNoACL(fd)
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, rename(temp.path, file.path) == 0 else { throw ConfigError.io(NSLocalizedString("Cannot save search learning data.", comment: "")) }
    }
    @discardableResult static func record(query: String, app: String) throws -> SearchHistory {
        let history = try ConfigStore.withLock {
            var history = try readUnlocked()
            let normalized = SearchHistory.normalized(query)
            guard !normalized.isEmpty, normalized.utf8.count <= 128, app.hasPrefix("/"), app.utf8.count <= 1024 else { return history }
            history.record(query: query, app: app)
            // Keep storage bounded even for unusually long app paths.
            while try JSONEncoder().encode(history).count > maxBytes && history.queries.count > 1 { history.queries.removeFirst() }
            try writeUnlocked(history)
            return history
        }
        ConfigStore.notify()
        return history
    }
    @discardableResult static func reset() throws -> SearchHistory {
        let history = SearchHistory()
        try ConfigStore.withLock { try writeUnlocked(history) }
        ConfigStore.notify()
        return history
    }
}

enum Search {
    static func ordered<T>(_ items: [T], query: String, name: (T) -> String, aliases: (T) -> [String], identity: (T) -> String, history: SearchHistory = SearchHistory()) -> [T] {
        guard !query.isEmpty else { return items }
        let preference = history.preference(for: query)
        let defaults = ["cal": "/System/Applications/Calendar.app", "clc": "/System/Applications/Calculator.app"]
        let preferredDefault = defaults[SearchHistory.normalized(query)]
        let matched = items.enumerated().compactMap { index, item -> (Int, T, Int, Int)? in
            guard let rank = rank(query, name: name(item), aliases: aliases(item)) else { return nil }
            let id = identity(item)
            // A real selection overrides the built-in Calendar default; unmatched items never enter the list.
            let learned = preference[id] ?? (id == preferredDefault ? preference.count : Int.max)
            return (index, item, learned, rank)
        }
        return matched.sorted {
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            if $0.3 != $1.3 { return $0.3 < $1.3 }
            return $0.0 < $1.0
        }.map { $0.1 }
    }
    static func range(_ query: String, in text: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        return Range((text as NSString).localizedStandardRange(of: query), in: text)
    }
    static func rank(_ query: String, name: String, aliases: [String]) -> Int? {
        if query.isEmpty { return 0 }
        let texts = [name] + aliases
        let ranges = texts.compactMap { text -> Bool? in
            guard let match = range(query, in: text) else { return nil }
            return match.lowerBound == text.startIndex
        }
        if ranges.contains(true) { return 0 }
        if !ranges.isEmpty { return 1 }
        let needle = Array(SearchHistory.normalized(query))
        guard !needle.isEmpty else { return nil }
        for text in texts {
            var matched = 0
            for character in SearchHistory.normalized(text) where character == needle[matched] {
                matched += 1
                if matched == needle.count { return 2 }
            }
        }
        return nil
    }
}

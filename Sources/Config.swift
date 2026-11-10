import Foundation
import Darwin

struct KeylightConfig: Codable {
    var version = 1
    var theme = "Liquid Glass"
    var modifier = "⌘"
    var key = "Space"
    var folders = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications", NSHomeDirectory() + "/Applications/Chrome Apps.localized"]
    var excluded: [String] = []
    var scripts = ""
    var aliases: [String: [String]] = [:]
    var iconStyle = "Original"
    var requests = RequestSettings()
    // These default folders may legitimately not exist on a new macOS account.
    // Keep them configured so they are scanned if the user creates them later.
    static func missingOptionalDefaultFolder(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path == home + "/Applications" || path == home + "/Applications/Chrome Apps.localized" else { return false }
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }
    private enum CodingKeys: String, CodingKey { case version, theme, modifier, key, folders, excluded, scripts, aliases, iconStyle, requests }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        theme = try c.decode(String.self, forKey: .theme)
        modifier = try c.decode(String.self, forKey: .modifier)
        key = try c.decode(String.self, forKey: .key)
        folders = try c.decode([String].self, forKey: .folders)
        excluded = try c.decode([String].self, forKey: .excluded)
        scripts = try c.decode(String.self, forKey: .scripts)
        aliases = try c.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? [:]
        iconStyle = try c.decodeIfPresent(String.self, forKey: .iconStyle) ?? "Original"
        requests = try c.decodeIfPresent(RequestSettings.self, forKey: .requests) ?? RequestSettings()
    }
    func validate() throws {
        try requests.validate()
        guard version == 1,
              ["Liquid Glass", "Cyberpunk 2077", "Windows XP", "Nothing"].contains(theme),
              ["⌘", "⌥", "⌃", "⌘ ⇧", "⌘ ⌥", "⌃ ⌥", "⌘ ⌥ ⇧"].contains(modifier),
              (["Space"] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)).contains(key),
              folders.count <= 100, excluded.count <= 2000, aliases.count <= 2000,
              ["Original", "System"].contains(iconStyle),
              aliases.allSatisfy({ path, values in path.hasPrefix("/") && path.utf8.count <= 4096 && values.count <= 30 && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 } }),
              folders.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 }),
              excluded.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 }),
              scripts.isEmpty || (scripts.hasPrefix("/") && scripts.utf8.count <= 4096)
        else { throw ConfigError.invalid }
    }
}
enum ConfigError: LocalizedError {
    case invalid, io(String)
    var errorDescription: String? { switch self { case .invalid: return "Invalid Keylight configuration."; case .io(let s): return s } }
}
struct ConfigStore {
    static var file: URL { if let custom = ProcessInfo.processInfo.environment["KEYLIGHT_CONFIG"], !custom.isEmpty { return URL(fileURLWithPath: custom) }; return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Keylight/config.json") }
    static func requirePrivateDirectory(_ dir: URL) throws {
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ConfigError.io("Cannot open a private configuration directory.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw ConfigError.io("Configuration directory must be owned by the current user and not writable by others.")
        }
        try requireNoACL(fd)
    }
    static func requireNoACL(_ fd: Int32) throws {
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            throw ConfigError.io("Configuration path has an ACL; use a private directory without an ACL.")
        }
        guard errno == ENOENT else { throw ConfigError.io("Cannot verify configuration ACL.") }
    }
    static func withLock<T>(_ body: () throws -> T) throws -> T {
        let dir = file.deletingLastPathComponent(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requirePrivateDirectory(dir)
        let fd = open(dir.appendingPathComponent("config.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io("Cannot open configuration lock.") }; defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ConfigError.io("Cannot lock configuration.") }
        return try body()
    }
    static func readUnlocked() throws -> KeylightConfig {
        guard FileManager.default.fileExists(atPath: file.path) else { return KeylightConfig() }
        let data = try Data(contentsOf: file); guard data.count <= 1_000_000 else { throw ConfigError.invalid }
        let c = try JSONDecoder().decode(KeylightConfig.self, from: data); try c.validate(); return c
    }
    static func read() throws -> KeylightConfig { try withLock { try readUnlocked() } }
    static func encode(_ c: KeylightConfig) throws -> Data { try c.validate(); let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(c) }
    static func writeUnlocked(_ c: KeylightConfig) throws {
        let data = try encode(c)
        let temp = file.deletingLastPathComponent().appendingPathComponent(".config-\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io("Cannot create configuration.") }
        defer { close(fd); unlink(temp.path) }
        try requireNoACL(fd)
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, rename(temp.path, file.path) == 0 else { throw ConfigError.io("Cannot save configuration.") }
    }
    static func replace(_ c: KeylightConfig) throws { try withLock { try writeUnlocked(c) }; notify() }
    static func update(_ edit: (inout KeylightConfig) -> Void) throws { try withLock { var c = try readUnlocked(); edit(&c); try writeUnlocked(c) }; notify() }
    static func decode(_ data: Data) throws -> KeylightConfig { guard data.count <= 1_000_000 else { throw ConfigError.invalid }; let c = try JSONDecoder().decode(KeylightConfig.self, from: data); try c.validate(); return c }
    static func notify() { DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.alex.Keylight.configChanged"), object: nil, userInfo: nil, deliverImmediately: true) }
}

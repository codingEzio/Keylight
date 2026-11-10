import Foundation
import Darwin
import CryptoKit

struct QueuedRequest: Codable, Identifiable, Sendable {
    let id: String
    let file: String
    let projectID: String?
    let projectPath: String?
    let title: String
    let updatedAt: Date
    let unconfirmed: Bool
    var receipt: RequestReceipt { RequestReceipt(id: id, file: file) }
}
struct RequestPoolSnapshot: Sendable { let entries: [QueuedRequest]; let unreadable: [String] }

enum RequestPool {
    private static let maximumFile = 1_100_000
    private static func root(_ folder: String) throws -> URL {
        guard folder.hasPrefix("/") else { throw ConfigError.io("Choose a request folder in Settings.") }
        if let canonical = realpath(folder, nil) {
            defer { free(canonical) }
            return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        }
        guard errno == ENOENT else { throw ConfigError.io("Cannot read queued request.") }
        return URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
    }
    private static func checkedFile(_ file: String, folder: String) throws -> URL {
        let base = try root(folder), source = URL(fileURLWithPath: file)
        let parent = try root(source.deletingLastPathComponent().path), url = parent.appendingPathComponent(source.lastPathComponent)
        guard url.path.hasPrefix(base.path + "/"), parent.deletingLastPathComponent().path == base.path else { throw ConfigError.io("Invalid queued request path.") }
        try ConfigStore.requirePrivateDirectory(base)
        try ConfigStore.requirePrivateDirectory(url.deletingLastPathComponent())
        return url
    }
    private static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ConfigError.io("Cannot read queued request.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= maximumFile else { throw ConfigError.io("Invalid queued request file.") }
        return try handle.read(upToCount: limit) ?? Data()
    }
    private static func document(_ data: Data, preview: Bool = false) throws -> DevelopmentRequest {
        guard data.starts(with: Data("---\n".utf8)),
              let boundary = data.range(of: Data("\n---\n\n".utf8)),
              let header = String(data: data.subdata(in: 4..<boundary.lowerBound), encoding: .utf8) else { throw ConfigError.io("Invalid queued request file.") }
        var values: [String: Any] = [:]
        for line in header.split(separator: "\n") {
            guard let split = line.range(of: ": ") else { throw ConfigError.io("Invalid queued request file.") }
            let key = String(line[..<split.lowerBound]), raw = Data(line[split.upperBound...].utf8)
            guard values[key] == nil else { throw ConfigError.io("Invalid queued request file.") }
            if key == "schema" { values[key] = String(line[split.upperBound...]) }
            else { values[key] = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) }
        }
        guard values["schema"] as? String == "keylight.request/v1", let stamp = values["created_at"] as? String,
              let created = ISO8601DateFormatter().date(from: stamp) else { throw ConfigError.io("Invalid queued request file.") }
        let zone: TimeZone
        if stamp.hasSuffix("Z") { zone = TimeZone(secondsFromGMT: 0)! }
        else {
            let suffix = Array(stamp.suffix(6))
            guard suffix.count == 6, ["+", "-"].contains(suffix[0]), suffix[3] == ":",
                  let hour = Int(String(suffix[1...2])), let minute = Int(String(suffix[4...5])),
                  let offset = TimeZone(secondsFromGMT: (hour * 3600 + minute * 60) * (suffix[0] == "-" ? -1 : 1)) else { throw ConfigError.io("Invalid queued request file.") }
            zone = offset
        }
        let body = data.subdata(in: boundary.upperBound..<data.count)
        let text: String
        if preview { text = String(decoding: body, as: UTF8.self) }
        else { guard let value = String(data: body, encoding: .utf8) else { throw ConfigError.io("Invalid queued request file.") }; text = value }
        var encoded: [String: Any] = ["id": values["id"] ?? NSNull(), "createdAt": created.timeIntervalSinceReferenceDate,
            "timeZoneIdentifier": zone.identifier, "projectID": values["project_id"] ?? NSNull(), "projectName": values["project_name"] ?? NSNull(),
            "projectPath": values["project_path"] ?? NSNull(), "model": values["model"] ?? NSNull(),
            "reasoningEffort": values["reasoning_effort"] ?? NSNull(), "text": text]
        encoded["permissionsProfile"] = values["permission_profile"] ?? NSNull()
        let request = try JSONDecoder().decode(DevelopmentRequest.self, from: JSONSerialization.data(withJSONObject: encoded))
        var settings = RequestSettings(); settings.model = request.model; settings.reasoningEffort = request.reasoningEffort; settings.permissionsProfile = request.permissionsProfile ?? "Development"
        try settings.validate()
        guard request.text.utf8.count <= 1_000_000 else { throw ConfigError.io("Enter a request of up to 1 MB.") }
        return request
    }
    static func load(_ entry: QueuedRequest, folder: String) throws -> DevelopmentRequest {
        let url = try checkedFile(entry.file, folder: folder)
        let data = try read(url, limit: maximumFile + 1), request = try document(data)
        guard request.id.uuidString.lowercased() == entry.id, request.data == data else { throw ConfigError.io("Invalid queued request file.") }
        return request
    }
    static func locate(file: String, folder: String) throws -> QueuedRequest {
        let path = try checkedFile(file, folder: folder).path
        guard let entry = try scan(folder: folder).entries.first(where: { $0.file == path }) else { throw ConfigError.io("Queued request is unavailable.") }
        return entry
    }
    static func scan(folder: String) throws -> RequestPoolSnapshot {
        let base = try root(folder)
        guard FileManager.default.fileExists(atPath: base.path) else { return RequestPoolSnapshot(entries: [], unreadable: []) }
        try ConfigStore.requirePrivateDirectory(base)
        var entries: [QueuedRequest] = [], unreadable: [String] = []
        for directory in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            do {
                try ConfigStore.requirePrivateDirectory(directory)
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) where file.lastPathComponent == "request.md" || (file.lastPathComponent.hasPrefix("request-") && file.pathExtension == "md") {
                    do {
                        let request = try document(read(file, limit: 32768), preview: true)
                        let receipt = RequestReceipt(id: request.id.uuidString.lowercased(), file: file.path)
                        let state = try ChatLaunchSession.readState(receipt)
                        if state?.phase == .sent { continue }
                        let line = request.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                        entries.append(QueuedRequest(id: receipt.id, file: file.path, projectID: request.projectID, projectPath: request.projectPath,
                            title: String(line.prefix(100)), updatedAt: try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? request.createdAt,
                            unconfirmed: state?.phase == .dispatching))
                    } catch { unreadable.append(file.lastPathComponent) }
                }
            } catch { unreadable.append(directory.lastPathComponent) }
        }
        return RequestPoolSnapshot(entries: entries.sorted { $0.updatedAt == $1.updatedAt ? $0.file < $1.file : $0.updatedAt > $1.updatedAt }, unreadable: unreadable)
    }
    private static func projectFolder(_ id: String) -> String {
        if id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$", options: .regularExpression) != nil { return id }
        return "~" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func filename(_ request: DevelopmentRequest, attempt: Int) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: request.timeZoneIdentifier); format.dateFormat = "yyMMdd'at'HHmmss"
        let seed: [UInt8]
        if attempt == 0 { var bytes = request.id.uuid; seed = withUnsafeBytes(of: &bytes) { Array($0.prefix(4)) } }
        else { seed = Array(SHA256.hash(data: Data((request.id.uuidString + String(attempt)).utf8)).prefix(4)) }
        let suffix = String(bytes: seed.map { 97 + $0 % 26 }, encoding: .utf8)!
        return "request-" + format.string(from: request.createdAt) + "-" + suffix + ".md"
    }
    static func save(_ request: DevelopmentRequest, folder: String) throws -> RequestReceipt {
        guard let projectID = request.projectID, request.projectPath != nil else { throw ConfigError.io("Choose a project first.") }
        guard folder.hasPrefix("/") else { throw ConfigError.io("Choose a request folder in Settings.") }
        // Foundation may canonicalize /private/tmp differently before and after
        // creation. Normalize only after the root exists so retry receipts agree.
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let base = try root(folder), directory = base.appendingPathComponent(projectFolder(projectID), isDirectory: true)
        try ConfigStore.requirePrivateDirectory(base)
        let fd = open(base.appendingPathComponent(".queue.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io("Cannot lock request folder.") }; defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConfigError.io("Cannot lock request folder.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ConfigStore.requirePrivateDirectory(directory)
        for attempt in 0..<32 {
            let file = directory.appendingPathComponent(filename(request, attempt: attempt))
            if FileManager.default.fileExists(atPath: file.path) {
                let old = try read(file, limit: maximumFile + 1)
                if try document(old).id != request.id { continue }
                guard old == request.data else { throw ConfigError.io("Request ID already exists with different content.") }
            } else {
                let candidate = RequestReceipt(id: request.id.uuidString.lowercased(), file: file.path)
                // A missing document may leave a live lock or delivery receipt.
                // Reserve that name rather than attach a new request to it.
                var info = stat()
                if lstat(ChatLaunchSession.stateFile(candidate).path, &info) == 0 || lstat(ChatLaunchSession.lockFile(candidate).path, &info) == 0 { continue }
                try privateAtomicWrite(request.data, to: file)
            }
            guard try read(file, limit: maximumFile + 1) == request.data else { throw ConfigError.io("Request readback failed.") }
            try syncRequestDirectory(base)
            return RequestReceipt(id: request.id.uuidString.lowercased(), file: file.path)
        }
        throw ConfigError.io("Cannot allocate a unique request filename.")
    }
    static func append(_ addition: String, to original: DevelopmentRequest, entry: QueuedRequest, folder: String) throws -> (DevelopmentRequest, RequestReceipt) {
        let file = try checkedFile(entry.file, folder: folder), receipt = entry.receipt
        let fd = open(ChatLaunchSession.lockFile(receipt).path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io("Cannot lock chat request.") }; defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConfigError.io("This request is already being sent.") }
        if let state = try ChatLaunchSession.readState(receipt), state.phase != .prepared { throw ConfigError.io("This request is already sent or needs delivery review.") }
        let updated = try original.appending(addition), data = try read(file, limit: maximumFile + 1)
        // Recover a saved append after a crash/lost acknowledgement without appending twice.
        if data != updated.data {
            guard data == original.data else { throw ConfigError.io("The request changed. Reload it before sending.") }
            try privateAtomicWrite(updated.data, to: file)
        }
        guard try read(file, limit: maximumFile + 1) == updated.data else { throw ConfigError.io("Request readback failed.") }
        return (updated, receipt)
    }
}

import Foundation
import Darwin

struct RequestSettings: Codable, Equatable, Sendable {
    static let categoryOptions = ["joboss", "oss", "private", "privateoss", "abandoned", "unclassified"]
    static let effortOptions = ["low", "medium", "high", "xhigh"]
    var projectRoot = ""
    var catalogURL = ""
    var queueFolder = ""
    var categories = ["joboss", "oss", "private"]
    var pinnedProjects: [String] = []
    var model = "gpt-6.1-terra"
    var reasoningEffort = "high"

    func validate() throws {
        guard [projectRoot, queueFolder].allSatisfy({ $0.isEmpty || ($0.hasPrefix("/") && $0.utf8.count <= 4096) }),
              catalogURL.isEmpty || Self.validURL(catalogURL),
              categories.count <= Self.categoryOptions.count, Set(categories).count == categories.count,
              categories.allSatisfy(Self.categoryOptions.contains), pinnedProjects.count <= 500,
              Set(pinnedProjects).count == pinnedProjects.count,
              pinnedProjects.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              !model.isEmpty, model.utf8.count <= 128,
              model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) }),
              Self.effortOptions.contains(reasoningEffort) else { throw ConfigError.invalid }
    }
    private static func validURL(_ value: String) -> Bool {
        guard value.utf8.count <= 4096, let url = URL(string: value) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }
}

struct CatalogProject: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let category: String
    let paths: [String]
}
struct ProjectSnapshot: Codable, Sendable {
    let source: String
    let fetchedAt: Date
    let projects: [CatalogProject]
}
struct LocalProject: Codable, Identifiable, Sendable {
    let project: CatalogProject
    let path: String?
    var id: String { project.id + "|" + (path ?? "") }
}

enum ProjectCatalog {
    private final class Download: @unchecked Sendable { var result: Result<ProjectSnapshot, Error>? }
    private struct Checkout: Decodable { let path: String; let state: String }
    private struct Repository: Decodable { let role: String; let checkouts: [Checkout] }
    private struct Item: Decodable {
        let id: String; let name: String; let summary: String?; let category: String?
        let repositories: [Repository]; let project_checkouts: [Checkout]
    }
    private struct Envelope: Decodable { let schema: String; let items: [Item]; let total: Int }
    static var cacheURL: URL { ConfigStore.file.appendingPathExtension("projects.json") }
    static func decode(_ data: Data, source: String, now: Date = Date()) throws -> ProjectSnapshot {
        guard data.count <= 4_000_000 else { throw ConfigError.io("Project catalog is too large.") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schema == "godspeed.project-groups/v1", envelope.total == envelope.items.count,
              envelope.items.count <= 5000, Set(envelope.items.map(\.id)).count == envelope.items.count else { throw ConfigError.io("Invalid project catalog.") }
        let projects = try envelope.items.map { item -> CatalogProject in
            guard !item.id.isEmpty, item.id.utf8.count <= 256, !item.name.isEmpty, item.name.utf8.count <= 1024 else { throw ConfigError.io("Invalid project identity.") }
            // Historical repositories and former checkouts never become development targets.
            let checkouts = item.project_checkouts + item.repositories.filter { ["current", "canonical"].contains($0.role) }.flatMap(\.checkouts)
            let paths = Set(checkouts.filter { $0.state == "observed" && $0.path.hasPrefix("/") && $0.path.utf8.count <= 4096 }.map(\.path)).sorted()
            return CatalogProject(id: item.id, name: item.name, summary: item.summary ?? "", category: item.category ?? "unclassified", paths: paths)
        }
        return ProjectSnapshot(source: source, fetchedAt: now, projects: projects)
    }
    static func load(source: String) throws -> ProjectSnapshot? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        let data = try Data(contentsOf: cacheURL)
        guard data.count <= 4_000_000 else { throw ConfigError.io("Project cache is too large.") }
        let cache = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        return cache.source == source ? cache : nil
    }
    static func save(_ snapshot: ProjectSnapshot) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try ConfigStore.withLock { try privateAtomicWrite(encoder.encode(snapshot), to: cacheURL) }
    }
    static func fetch(source: String) async throws -> ProjectSnapshot {
        guard let url = URL(string: source) else { throw ConfigError.invalid }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8; config.urlCache = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ConfigError.io("Project source did not return HTTP 200.") }
        return try decode(data, source: source)
    }
    static func fetchBlocking(source: String) throws -> ProjectSnapshot {
        guard let url = URL(string: source) else { throw ConfigError.invalid }
        let box = Download(), semaphore = DispatchSemaphore(value: 0)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8; config.urlCache = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        session.dataTask(with: url) { data, response, error in
            box.result = Result {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else { throw ConfigError.io("Project source did not return HTTP 200.") }
                return try decode(data, source: source)
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 10) == .success, let result = box.result else { throw ConfigError.io("Project source timed out.") }
        return try result.get()
    }
    static func localProjects(_ snapshot: ProjectSnapshot?, settings: RequestSettings, query: String = "") -> [LocalProject] {
        guard let snapshot, snapshot.source == settings.catalogURL, !settings.projectRoot.isEmpty else { return [] }
        let root = URL(fileURLWithPath: settings.projectRoot).resolvingSymlinksInPath().standardizedFileURL
        let pins = Dictionary(uniqueKeysWithValues: settings.pinnedProjects.enumerated().map { ($1, $0) })
        let matching = snapshot.projects.filter { settings.categories.contains($0.category) && (query.isEmpty || ($0.name + " " + $0.id + " " + $0.summary).localizedStandardContains(query)) }
        return matching.flatMap { project -> [LocalProject] in
            let paths = Set(project.paths.compactMap { path -> String? in
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                var directory: ObjCBool = false
                guard url.deletingLastPathComponent() == root, !url.lastPathComponent.hasPrefix("."), !url.lastPathComponent.hasPrefix("_"), !url.lastPathComponent.hasSuffix("-worktrees"),
                      FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
                return url.path
            }).sorted()
            return paths.isEmpty ? [LocalProject(project: project, path: nil)] : paths.map { LocalProject(project: project, path: $0) }
        }.sorted {
            let a = pins[$0.project.id] ?? Int.max, b = pins[$1.project.id] ?? Int.max
            if a != b { return a < b }
            let order = $0.project.name.localizedStandardCompare($1.project.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

// Caller owns the private parent directory and any lock. Publish only after fsync.
func privateAtomicWrite(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".keylight-" + UUID().uuidString)
    let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw ConfigError.io("Cannot create request file.") }
    defer { close(fd); unlink(temporary.path) }
    try ConfigStore.requireNoACL(fd)
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
    guard fsync(fd) == 0, rename(temporary.path, destination.path) == 0 else { throw ConfigError.io("Cannot persist request file.") }
    try syncRequestDirectory(destination.deletingLastPathComponent())
}
private func syncRequestDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw ConfigError.io("Cannot open request directory.") }; defer { close(fd) }
    guard fsync(fd) == 0 else { throw ConfigError.io("Cannot persist request directory.") }
}

struct DevelopmentRequest: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let timeZoneIdentifier: String
    let projectID: String?
    let projectName: String?
    let projectPath: String?
    let model: String
    let reasoningEffort: String
    let text: String
    init(text: String, project: LocalProject?, settings: RequestSettings, id: UUID = UUID(), createdAt: Date = Date()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_000_000 else { throw ConfigError.io("Enter a request of up to 1 MB.") }
        try settings.validate()
        if let project, project.path == nil { throw ConfigError.io("This project has no local checkout.") }
        self.id = id; self.createdAt = createdAt; self.timeZoneIdentifier = TimeZone.current.identifier; self.projectID = project?.project.id; self.projectName = project?.project.name; self.projectPath = project?.path
        self.model = settings.model; self.reasoningEffort = settings.reasoningEffort; self.text = text
    }
    var folderName: String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: timeZoneIdentifier); format.dateFormat = "yyyy-MM-dd_HHmmss"
        return format.string(from: createdAt) + "-" + id.uuidString.lowercased()
    }
    var data: Data {
        func value(_ string: String?) -> String { guard let string else { return "null" }; return String(decoding: try! JSONEncoder().encode(string), as: UTF8.self) }
        let format = ISO8601DateFormatter(); format.timeZone = TimeZone(identifier: timeZoneIdentifier)
        let header = "---\nschema: keylight.request/v1\nid: \(value(id.uuidString.lowercased()))\ncreated_at: \(value(format.string(from: createdAt)))\nproject_id: \(value(projectID))\nproject_name: \(value(projectName))\nproject_path: \(value(projectPath))\nmodel: \(value(model))\nreasoning_effort: \(value(reasoningEffort))\n---\n\n"
        return Data((header + text).utf8)
    }
}
struct RequestReceipt: Codable, Sendable { let id: String; let file: String }
enum RequestQueue {
    static func save(_ request: DevelopmentRequest, folder: String) throws -> RequestReceipt {
        guard folder.hasPrefix("/") else { throw ConfigError.io("Choose a request folder in Settings.") }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ConfigStore.requirePrivateDirectory(root)
        let fd = open(root.appendingPathComponent(".queue.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io("Cannot lock request folder.") }; defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ConfigError.io("Cannot lock request folder.") }
        let destination = root.appendingPathComponent(request.folderName, isDirectory: true)
        let file = destination.appendingPathComponent("request.md")
        let data = request.data
        // Retrying the same request ID confirms its existing file, never duplicates it.
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: file) == data else { throw ConfigError.io("Request ID already exists with different content.") }
        } else {
            let staging = root.appendingPathComponent(".pending-" + request.id.uuidString, isDirectory: true)
            if !FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try ConfigStore.requirePrivateDirectory(staging)
            let stagedFile = staging.appendingPathComponent("request.md")
            if FileManager.default.fileExists(atPath: stagedFile.path), try Data(contentsOf: stagedFile) != data { throw ConfigError.io("Pending request has different content.") }
            try privateAtomicWrite(data, to: staging.appendingPathComponent("request.md"))
            guard try Data(contentsOf: staging.appendingPathComponent("request.md")) == data else { throw ConfigError.io("Request readback failed.") }
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        try syncRequestDirectory(root)
        guard try Data(contentsOf: file) == data else { throw ConfigError.io("Request readback failed.") }
        return RequestReceipt(id: request.id.uuidString.lowercased(), file: file.path)
    }
}

import Foundation
import Darwin

@main struct RequestsSmoke {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("keylight-requests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        setenv("KEYLIGHT_CONFIG", temporary.appendingPathComponent("settings/config.json").path, 1)
        let root = temporary.appendingPathComponent("Projects")
        let project = root.appendingPathComponent("X-Example")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let retired = root.appendingPathComponent("_abandoned/X-Old")
        try fm.createDirectory(at: retired, withIntermediateDirectories: true)
        var settings = RequestSettings(); settings.projectRoot = root.path; settings.catalogURL = "http://localhost:1/api/projects?group=all"; settings.queueFolder = temporary.appendingPathComponent("Queue").path
        let input: [String: Any] = ["schema": "godspeed.project-groups/v1", "total": 3, "items": [
            ["id": "example", "name": "Example", "summary": "fixture", "category": "oss", "project_checkouts": [], "repositories": [["role": "canonical", "checkouts": [["state": "observed", "path": project.path]]]]],
            ["id": "old", "name": "Old", "category": "private", "project_checkouts": [], "repositories": [["role": "historical", "checkouts": [["state": "observed", "path": project.path], ["state": "observed", "path": retired.path]]]]],
            ["id": "excluded", "name": "Excluded", "category": "privateoss", "project_checkouts": [], "repositories": []]
        ]]
        let snapshot = try ProjectCatalog.decode(JSONSerialization.data(withJSONObject: input), source: settings.catalogURL)
        try ProjectCatalog.save(snapshot)
        let cache = try ProjectCatalog.load(source: settings.catalogURL)
        require(cache?.projects.count == 3, "cache readback")
        require(try ProjectCatalog.load(source: "http://different.invalid") == nil, "source isolation")
        let choices = ProjectCatalog.localProjects(cache, settings: settings)
        require(choices.count == 2 && choices[0].project.id == "example" && choices[0].path == project.path, "scope and checkout")
        require(choices[1].path == nil, "historical checkout must stay unavailable")
        settings.pinnedProjects = ["old"]
        require(ProjectCatalog.localProjects(cache, settings: settings).first?.project.id == "old", "pin ordering")
        settings.categories = ["privateoss"]
        require(ProjectCatalog.localProjects(cache, settings: settings).map(\.project.id) == ["excluded"], "scope change")
        settings.categories = ["oss", "private"]
        let text = "  修正搜尋 🧩\n\n保留空白與標點。\n"
        let request = try DevelopmentRequest(text: text, project: choices[0], settings: settings)
        let restored = try JSONDecoder().decode(DevelopmentRequest.self, from: JSONEncoder().encode(request))
        require(restored.data == request.data && restored.folderName == request.folderName, "restart identity")
        let receipt = try RequestQueue.save(request, folder: settings.queueFolder)
        let data = try Data(contentsOf: URL(fileURLWithPath: receipt.file))
        require(data == request.data && String(decoding: data, as: UTF8.self).hasSuffix(text), "exact request body")
        let fileMode = try fm.attributesOfItem(atPath: receipt.file)[.posixPermissions] as? Int
        let directoryMode = try fm.attributesOfItem(atPath: URL(fileURLWithPath: receipt.file).deletingLastPathComponent().path)[.posixPermissions] as? Int
        require(fileMode == 0o600 && directoryMode == 0o700, "private file permissions")
        let failureLock = NSLock(); var failures = [String]()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do { _ = try RequestQueue.save(restored, folder: settings.queueFolder) }
            catch { failureLock.lock(); failures.append(error.localizedDescription); failureLock.unlock() }
        }
        require(failures.isEmpty, "concurrent retry")
        require(try fm.contentsOfDirectory(atPath: settings.queueFolder).filter { !$0.hasPrefix(".") }.count == 1, "no duplicate requests")
        let interrupted = try DevelopmentRequest(text: "recover", project: nil, settings: settings)
        let staging = URL(fileURLWithPath: settings.queueFolder).appendingPathComponent(".pending-" + interrupted.id.uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try privateAtomicWrite(interrupted.data, to: staging.appendingPathComponent("request.md"))
        _ = try RequestQueue.save(interrupted, folder: settings.queueFolder)
        require(!fm.fileExists(atPath: staging.path), "interrupted request recovered")
        let collision = try DevelopmentRequest(text: "changed", project: choices[0], settings: settings, id: request.id, createdAt: request.createdAt)
        do { _ = try RequestQueue.save(collision, folder: settings.queueFolder); fatalError("collision accepted") } catch {}
        require(try Data(contentsOf: URL(fileURLWithPath: receipt.file)) == data, "collision preserved original")
        do { _ = try DevelopmentRequest(text: " \n", project: nil, settings: settings); fatalError("empty accepted") } catch {}
        do { _ = try DevelopmentRequest(text: String(repeating: "a", count: 1_000_001), project: nil, settings: settings); fatalError("oversize accepted") } catch {}
        let blocked = temporary.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        do { _ = try RequestQueue.save(request, folder: blocked.path); fatalError("invalid destination accepted") } catch {}
        print("PASS: catalog scope/cache, pins, exact body, private persistence, restart/concurrent retry, interruption and collision")
    }
}

import Foundation
import Darwin

@main struct RequestPoolSmoke {
    static func fail(_ message: String) -> Never { fputs("FAIL: \(message)\n", stderr); exit(1) }
    static func require(_ value: Bool, _ message: String) { if !value { fail(message) } }
    static func main() { do { try run() } catch { fail(error.localizedDescription) } }
    static func run() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/keylight-pool-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var passed = false
        defer { if passed { try? fm.removeItem(at: base) } else { print("Retained fixture: " + base.path) } }
        var settings = RequestSettings(); settings.queueFolder = base.appendingPathComponent("Requests").path
        let a = LocalProject(project: CatalogProject(id: "example", name: "Example", summary: "", category: "oss", paths: [base.path]), path: base.path)
        let b = LocalProject(project: CatalogProject(id: "other", name: "Other", summary: "", category: "private", paths: [base.path]), path: base.path)
        let text = "  修正搜尋 🧩\n保留空白。\n"
        let first = try DevelopmentRequest(text: text, project: a, settings: settings, id: UUID(uuidString: "00000000-0000-7000-8000-000000000001")!)
        let second = try DevelopmentRequest(text: "second", project: a, settings: settings, id: UUID(uuidString: "00000000-0000-7000-8000-000000000002")!, createdAt: first.createdAt)
        let one = try RequestPool.save(first, folder: settings.queueFolder)
        let collision = try RequestPool.save(second, folder: settings.queueFolder)
        require(one.file != collision.file, "filename collision overwrote request")
        require(URL(fileURLWithPath: one.file).lastPathComponent.range(of: "^request-[0-9]{6}at[0-9]{6}-[a-z]{4}\\.md$", options: .regularExpression) != nil, "filename contract")
        let retry = try RequestPool.save(first, folder: settings.queueFolder)
        require(retry.file == one.file, "retry file aliases: \(one.file) | \(retry.file)")
        let other = try DevelopmentRequest(text: "other project", project: b, settings: settings)
        let two = try RequestPool.save(other, folder: settings.queueFolder)
        require(URL(fileURLWithPath: one.file).deletingLastPathComponent() != URL(fileURLWithPath: two.file).deletingLastPathComponent(), "project folders mixed")
        let legacy = try DevelopmentRequest(text: "legacy pending", project: a, settings: settings)
        let legacyReceipt = try RequestQueue.save(legacy, folder: settings.queueFolder)
        var snapshot = try RequestPool.scan(folder: settings.queueFolder)
        require(snapshot.entries.count == 4 && snapshot.unreadable.isEmpty, "restart/legacy listing")
        guard let entry = snapshot.entries.first(where: { $0.file == one.file }) else { fail("saved receipt not listed: \(one.file) | \(snapshot.entries.map(\.file))") }
        let restored = try RequestPool.load(entry, folder: settings.queueFolder)
        require(restored.data == first.data, "document roundtrip/timezone")
        let addition = "第二段\n  additional detail\n"
        let appended = try RequestPool.append(addition, to: restored, entry: entry, folder: settings.queueFolder)
        require(appended.1.file == one.file && appended.0.text == text + "\n\n" + addition, "append changed identity or body")
        _ = try RequestPool.append(addition, to: restored, entry: entry, folder: settings.queueFolder)
        require(try Data(contentsOf: URL(fileURLWithPath: one.file)) == appended.0.data, "lost append acknowledgement duplicated content")
        do { _ = try RequestPool.append("stale update", to: restored, entry: entry, folder: settings.queueFolder); fail("stale writer accepted") } catch {}
        let sent = ChatLaunchState(threadID: UUID().uuidString, phase: .sent, turnID: "accepted")
        try privateAtomicWrite(JSONEncoder().encode(sent), to: ChatLaunchSession.stateFile(one))
        snapshot = try RequestPool.scan(folder: settings.queueFolder)
        require(!snapshot.entries.contains { $0.file == one.file } && snapshot.entries.contains { $0.file == two.file }, "consumption crossed files/projects")
        require(try Data(contentsOf: URL(fileURLWithPath: one.file)) == appended.0.data, "consumption deleted original")
        do { _ = try RequestPool.append("late", to: appended.0, entry: entry, folder: settings.queueFolder); fail("consumed request changed") } catch {}
        let uncertain = ChatLaunchState(threadID: UUID().uuidString, phase: .dispatching)
        try privateAtomicWrite(JSONEncoder().encode(uncertain), to: ChatLaunchSession.stateFile(two))
        snapshot = try RequestPool.scan(folder: settings.queueFolder)
        require(snapshot.entries.first(where: { $0.file == two.file })?.unconfirmed == true, "unconfirmed request disappeared")
        require(snapshot.entries.contains { $0.id == legacyReceipt.id }, "legacy request hidden")
        let corrupted = URL(fileURLWithPath: one.file).deletingLastPathComponent().appendingPathComponent("request-corrupt.md")
        try Data("unreadable original".utf8).write(to: corrupted)
        snapshot = try RequestPool.scan(folder: settings.queueFolder)
        require(snapshot.unreadable == [corrupted.lastPathComponent] && fm.fileExists(atPath: corrupted.path), "corrupt source lost")
        let mode = try fm.attributesOfItem(atPath: one.file)[.posixPermissions] as? Int
        require(mode == 0o600, "file not private")
        let orphanProject = LocalProject(project: CatalogProject(id: "orphan", name: "Orphan fixture", summary: "", category: "oss", paths: [base.path]), path: base.path)
        let orphan = try DevelopmentRequest(text: "old", project: orphanProject, settings: settings, id: first.id, createdAt: first.createdAt)
        let old = try RequestPool.save(orphan, folder: settings.queueFolder)
        try privateAtomicWrite(JSONEncoder().encode(sent), to: ChatLaunchSession.stateFile(old))
        try fm.removeItem(atPath: old.file)
        let replacement = try DevelopmentRequest(text: "new", project: orphanProject, settings: settings, id: second.id, createdAt: first.createdAt)
        let fresh = try RequestPool.save(replacement, folder: settings.queueFolder)
        require(fresh.file != old.file, "orphan receipt attached to a new request")
        passed = true
        print("PASS: project grouping, filenames/collision/retry, document restart, exact append/idempotence/conflict, consumed/unconfirmed/legacy visibility, corrupt preservation")
    }
}

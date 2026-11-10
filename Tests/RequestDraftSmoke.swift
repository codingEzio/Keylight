import Foundation
import Darwin

@main struct RequestDraftSmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("keylight-draft-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        setenv("KEYLIGHT_CONFIG", root.appendingPathComponent("settings/config.json").path, 1)
        let blocked = root.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let projects = root.appendingPathComponent("Projects")
        let checkout = projects.appendingPathComponent("X-Example")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        var config = KeylightConfig(); config.requests.queueFolder = blocked.path
        config.requests.projectRoot = projects.path
        config.requests.catalogURL = "http://localhost:1/projects"
        let catalogProject = CatalogProject(id: "example", name: "Example", summary: "", category: "oss", paths: [checkout.path])
        let selected = LocalProject(project: catalogProject, path: checkout.path)
        try ProjectCatalog.save(ProjectSnapshot(source: config.requests.catalogURL, fetchedAt: Date(), projects: [catalogProject]))
        try ConfigStore.replace(config)
        let model = RequestModel(); model.text = "keep this request\n"
        model.activate("add")
        guard model.choosingProject, model.selectedProject == nil else { fatalError("ADD skipped project selection") }
        await model.submit()
        guard model.error != nil, model.receipt == nil else { fatalError("missing project accepted") }
        model.selectedProject = selected; model.choosingProject = false
        await model.submit()
        guard model.receipt == nil, model.error != nil, model.text == "keep this request\n" else { fatalError("failed write discarded draft") }
        let restarted = RequestModel()
        guard restarted.text == model.text, restarted.selectedProject?.id == selected.id, restarted.error == nil else { fatalError("restart lost pending request") }
        config.requests.queueFolder = root.appendingPathComponent("Queue").path
        guard restarted.saveSettings(config.requests) else { fatalError("settings") }
        await restarted.submit()
        guard let receipt = restarted.receipt, restarted.text.isEmpty,
              String(decoding: try Data(contentsOf: URL(fileURLWithPath: receipt.file)), as: UTF8.self).hasSuffix("keep this request\n") else { fatalError("retry did not persist") }
        guard RequestModel().text.isEmpty else { fatalError("saved request reappeared as draft") }
        let savedRequest = try DevelopmentRequest(text: "check delivery", project: selected, settings: config.requests)
        let savedReceipt = try RequestQueue.save(savedRequest, folder: config.requests.queueFolder)
        let uncertain = ChatLaunchState(threadID: UUID().uuidString, phase: .dispatching)
        try privateAtomicWrite(JSONEncoder().encode(uncertain), to: ChatLaunchSession.stateFile(savedReceipt))
        let pendingDraft: [String: Any] = ["project": try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)), "pending": try JSONSerialization.jsonObject(with: JSONEncoder().encode(savedRequest)), "receipt": try JSONSerialization.jsonObject(with: JSONEncoder().encode(savedReceipt))]
        try privateAtomicWrite(JSONSerialization.data(withJSONObject: pendingDraft), to: ConfigStore.file.appendingPathExtension("request-draft.json"))
        let review = RequestModel(); review.activate("proj")
        guard review.receipt?.id == savedReceipt.id, review.chatURL == uncertain.url else { fatalError("unconfirmed send not recovered") }
        await review.submit(command: "proj")
        guard review.receipt?.id == savedReceipt.id else { fatalError("uncertain request was resent") }
        review.startNew()
        guard review.text.isEmpty, review.choosingProject, review.receipt == nil,
              try Data(contentsOf: URL(fileURLWithPath: savedReceipt.file)) == savedRequest.data,
              try ChatLaunchSession.readState(savedReceipt)?.phase == .dispatching else { fatalError("new request discarded old delivery evidence") }
        // A valid 1 MB body may occupy 6 MB when JSON escapes control characters.
        let maximum = String(repeating: "\0", count: 1_000_000)
        let large = RequestModel(); large.text = maximum; large.persistDraft()
        let restored = RequestModel()
        guard restored.error == nil, restored.text == maximum else { fatalError("maximum-size draft lost") }
        let draft = ConfigStore.file.appendingPathExtension("request-draft.json")
        let corrupt = Data("unreadable draft".utf8); try corrupt.write(to: draft)
        let unread = RequestModel(); unread.persistDraft()
        guard unread.error != nil, try Data(contentsOf: draft) == corrupt else { fatalError("unread draft overwritten") }
        print("PASS: failed-write/restart/retry, unconfirmed send/new request preservation, saved draft clearing, 1 MB escaped body and unread original preservation")
    }
}

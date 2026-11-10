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
        var config = KeylightConfig(); config.requests.queueFolder = blocked.path
        try ConfigStore.replace(config)
        let model = RequestModel(); model.text = "keep this request\n"
        await model.submit()
        guard model.receipt == nil, model.error != nil, model.text == "keep this request\n" else { fatalError("failed write discarded draft") }
        let restarted = RequestModel()
        guard restarted.text == model.text, restarted.error == nil else { fatalError("restart lost pending request") }
        config.requests.queueFolder = root.appendingPathComponent("Queue").path
        guard restarted.saveSettings(config.requests) else { fatalError("settings") }
        await restarted.submit()
        guard let receipt = restarted.receipt, restarted.text.isEmpty,
              String(decoding: try Data(contentsOf: URL(fileURLWithPath: receipt.file)), as: UTF8.self).hasSuffix("keep this request\n") else { fatalError("retry did not persist") }
        guard RequestModel().text.isEmpty else { fatalError("saved request reappeared as draft") }
        // A valid 1 MB body may occupy 6 MB when JSON escapes control characters.
        let maximum = String(repeating: "\0", count: 1_000_000)
        let large = RequestModel(); large.text = maximum; large.persistDraft()
        let restored = RequestModel()
        guard restored.error == nil, restored.text == maximum else { fatalError("maximum-size draft lost") }
        let draft = ConfigStore.file.appendingPathExtension("request-draft.json")
        let corrupt = Data("unreadable draft".utf8); try corrupt.write(to: draft)
        let unread = RequestModel(); unread.persistDraft()
        guard unread.error != nil, try Data(contentsOf: draft) == corrupt else { fatalError("unread draft overwritten") }
        print("PASS: failed-write/restart/retry, saved draft clearing, 1 MB escaped body and unread original preservation")
    }
}

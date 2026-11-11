import AppKit
import Darwin

@main struct ClipboardSmoke {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--worker" {
            let store = ClipboardStore(directory: URL(fileURLWithPath: CommandLine.arguments[2]), limit: 5_000_000)
            for index in 0..<10 { _ = try store.save("worker-\(CommandLine.arguments[3])-\(index)") }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keylight-clipboard-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var passed = false
        defer { if passed { try? FileManager.default.removeItem(at: root) } else { print("Retained fixture: \(root.path)") } }
        let cap: Int64 = 512_000
        let folder = root.appendingPathComponent("limited")
        let store = ClipboardStore(directory: folder, limit: cap)
        func measured() throws -> Int64 {
            var total: Int64 = 0
            for url in [folder] + (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) {
                var info = stat(); precondition(lstat(url.path, &info) == 0)
                total += max(Int64(info.st_size), Int64(info.st_blocks) * 512)
            }
            return total
        }
        var evicted = false
        for index in 0..<45 {
            evicted = try store.save("record-\(index)-" + String(repeating: "x", count: 16_000)) || evicted
            let used = try measured(); precondition(used <= cap, "storage limit exceeded")
        }
        precondition(evicted, "expected bounded eviction")
        let restarted = ClipboardStore(directory: folder, limit: cap)
        let latest = try restarted.page()
        precondition(latest.first?.1.hasPrefix("record-44-") == true, "restart must preserve newest")
        let foreign = folder.appendingPathComponent("user-owned.txt")
        try Data(repeating: 7, count: 64_000).write(to: foreign)
        _ = try restarted.save("after-foreign")
        precondition(FileManager.default.fileExists(atPath: foreign.path), "unowned file must be retained")
        let afterForeign = try measured(); precondition(afterForeign <= cap, "hidden files count against cap")

        // Exercise the actual 2 GB boundary with a sparse fixture; this does not
        // consume 2 GB of physical disk space.
        let fullFolder = root.appendingPathComponent("real-limit")
        try FileManager.default.createDirectory(at: fullFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sparse = fullFolder.appendingPathComponent(".reserved-foreign")
        precondition(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let sparseHandle = try FileHandle(forWritingTo: sparse)
        try sparseHandle.truncate(atOffset: UInt64(ClipboardStore.limit - 1_000))
        try sparseHandle.close()
        var rejected = false
        do { _ = try ClipboardStore(directory: fullFolder).save("must not overwrite") } catch { rejected = true }
        precondition(rejected && FileManager.default.fileExists(atPath: sparse.path), "2 GB limit must reject without deleting foreign data")

        let concurrentFolder = root.appendingPathComponent("concurrent")
        var workers: [Process] = []
        for index in 0..<2 {
            let worker = Process(); worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            worker.arguments = ["--worker", concurrentFolder.path, String(index)]
            try worker.run(); workers.append(worker)
        }
        for worker in workers { worker.waitUntilExit(); precondition(worker.terminationStatus == 0, "concurrent writer failed") }
        let shared = try ClipboardStore(directory: concurrentFolder, limit: 5_000_000).page()
        precondition(shared.count == 20, "concurrent writers lost records")

        let board = NSPasteboard(name: NSPasteboard.Name("org.keylight.fixture." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(store: ClipboardStore(directory: root.appendingPathComponent("queue"), limit: 5_000_000), pasteboard: board)
        history.start()
        for index in 0..<12 {
            board.clearContents(); precondition(board.setString("queue-\(index)", forType: .string)); history.poll()
        }
        history.load()
        let deadline = Date().addingTimeInterval(10)
        while history.items.count < 12 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(history.items.count == 12, "queue lost a polled clipboard item")
        board.clearContents(); _ = board.setString("unseen", forType: .string)
        board.clearContents(); _ = board.setString("seen", forType: .string)
        history.poll()
        precondition(history.error?.contains("missed") == true, "must report overwritten clipboard changes")
        for index in 0..<18 {
            board.clearContents(); _ = board.setString("overflow-\(index)", forType: .string); history.poll()
        }
        precondition(history.error?.contains("queue is full") == true, "bounded queue must report overflow")
        history.finish()
        let drained = try ClipboardStore(directory: root.appendingPathComponent("queue"), limit: 5_000_000).page()
        precondition(drained.count == 28, "accepted items must persist before termination")
        board.clearContents(); _ = board.setString("while-disabled", forType: .string)
        history.poll(); history.start(); history.poll(); history.finish()
        let afterOptIn = try ClipboardStore(directory: root.appendingPathComponent("queue"), limit: 5_000_000).page()
        precondition(afterOptIn.count == 28, "disabled or pre-consent clipboard must not be captured")
        print("PASS: measured cap, real 2 GB boundary, eviction, restart, foreign file accounting, concurrent writers, queued captures, termination drain, opt-in boundary, overflow and missed-change warnings")
        passed = true
    }
}

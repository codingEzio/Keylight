import Foundation
import Darwin

@main struct ChatLaunchSmoke {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/keylight-chat-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var passed = false
        defer { if passed { try? fm.removeItem(at: base) } else { print("Retained fixture: " + base.path) } }
        let fixture = URL(fileURLWithPath: "Tests/ChatLaunchFixture.py").standardizedFileURL
        let executable = base.appendingPathComponent("app-server")
        try fm.copyItem(at: fixture, to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var settings = RequestSettings(); settings.queueFolder = base.appendingPathComponent("Queue").path
        let project = LocalProject(project: CatalogProject(id: "example", name: "Example", summary: "", category: "oss", paths: [base.path]), path: base.path)
        let request = try DevelopmentRequest(text: "  exact request 🧩\n", project: project, settings: settings)
        let receipt = try RequestQueue.save(request, folder: settings.queueFolder)
        let stateFile = ChatLaunchSession.stateFile(receipt)
        var session: ChatLaunchSession? = try ChatLaunchSession(request: request, receipt: receipt, executable: executable, socketPath: base.appendingPathComponent("desktop.sock").path)
        require(session?.state.phase == .prepared, "thread not prepared")
        do { _ = try ChatLaunchSession(request: request, receipt: receipt, executable: executable, socketPath: "unused"); fatalError("concurrent send accepted") } catch {}
        for dropAck in [false, true] {
            if dropAck {
                session = nil
                try fm.removeItem(at: stateFile)
                try Data().write(to: base.appendingPathComponent("drop-ack"))
                session = try ChatLaunchSession(request: request, receipt: receipt, executable: executable, socketPath: base.appendingPathComponent("desktop.sock").path)
            }
            let server = Process(); server.executableURL = executable; server.arguments = ["desktop"]; server.currentDirectoryURL = base
            server.standardOutput = FileHandle.nullDevice
            try server.run()
            defer { if server.isRunning { server.terminate() } }
            let ready = base.appendingPathComponent("ready")
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !fm.fileExists(atPath: ready.path), ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            require(fm.fileExists(atPath: ready.path), "fixture did not start")
            if dropAck {
                do { _ = try session!.send(); fatalError("lost acknowledgement accepted") } catch {}
                require(try ChatLaunchSession.readState(receipt)?.phase == .dispatching, "unconfirmed state not durable")
                session = nil
                session = try ChatLaunchSession(request: request, receipt: receipt, executable: executable, socketPath: "must-not-reconnect")
                do { _ = try session!.send(); fatalError("uncertain send repeated") } catch {}
            } else {
                require(try session!.send().phase == .sent, "send did not complete")
                session = nil
                session = try ChatLaunchSession(request: request, receipt: receipt, executable: executable, socketPath: "must-not-reconnect")
                require(try session!.send().turnID == "fixture-turn", "restart lost receipt")
            }
            server.waitUntilExit()
            require(server.terminationStatus == 0, "fixture rejected the contract")
            try fm.removeItem(at: ready); try fm.removeItem(at: base.appendingPathComponent("desktop.sock"))
        }
        let calls = try String(contentsOf: base.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        require(calls.filter { $0["desktop"] as? String == "thread-follower-start-turn" }.count == 2, "duplicate dispatch")
        require(try Data(contentsOf: URL(fileURLWithPath: receipt.file)) == request.data, "request changed")
        session = nil
        try fm.removeItem(at: stateFile)
        try Data().write(to: base.appendingPathComponent("deny-profile"))
        do { _ = try ChatLaunchSession(request: request, receipt: receipt, executable: executable, socketPath: "unused"); fatalError("unavailable profile accepted") } catch {}
        require(!fm.fileExists(atPath: stateFile.path), "unavailable profile created a chat")
        passed = true
        print("PASS: prepare/preset/cwd, desktop dispatch/exact input, restart receipt, concurrent lock, lost acknowledgement/no resend, unavailable profile")
    }
}

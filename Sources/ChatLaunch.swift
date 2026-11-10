import Foundation
import Darwin

// The desktop owns the conversation and approvals. The short-lived app-server
// only prepares an empty thread; no turn is run by Keylight's helper process.
struct ChatLaunchState: Codable, Sendable {
    enum Phase: String, Codable { case prepared, dispatching, sent }
    let threadID: String
    var phase: Phase
    var turnID: String?
    var url: URL { URL(string: "codex://threads/" + threadID)! }
}

final class ChatLaunchSession: @unchecked Sendable {
    private let lock: FileHandle
    private let stateURL: URL
    private(set) var state: ChatLaunchState
    private let request: DevelopmentRequest
    private let socketPath: String

    static func stateFile(_ receipt: RequestReceipt) -> URL {
        URL(fileURLWithPath: receipt.file).deletingLastPathComponent().appendingPathComponent("chat.json")
    }
    static func readState(_ receipt: RequestReceipt) throws -> ChatLaunchState? {
        let file = stateFile(receipt)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 8192 else { throw ConfigError.io("Invalid chat receipt.") }
        let state = try JSONDecoder().decode(ChatLaunchState.self, from: data)
        guard UUID(uuidString: state.threadID) != nil else { throw ConfigError.io("Invalid chat receipt.") }
        return state
    }
    init(request: DevelopmentRequest, receipt: RequestReceipt, executable: URL, socketPath: String) throws {
        guard let path = request.projectPath, FileManager.default.fileExists(atPath: path),
              try Data(contentsOf: URL(fileURLWithPath: receipt.file)) == request.data else { throw ConfigError.io("Project checkout is unavailable or outside the selected scope.") }
        self.request = request; self.socketPath = socketPath; stateURL = Self.stateFile(receipt)
        let fd = open(stateURL.deletingLastPathComponent().appendingPathComponent(".chat.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io("Cannot lock chat request.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ConfigError.io("This request is already being sent.") }
        lock = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            if let saved = try Self.readState(receipt) { state = saved; return }
            let server = try LocalAppServer(executable: executable, directory: path)
            defer { server.close() }
            let profile = request.permissionsProfile ?? "Development"
            var cursor: String?
            var available = false
            for _ in 0..<10 {
                var params: [String: Any] = ["cwd": path, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let result = try server.call("permissionProfile/list", params)
                available = available || (result["data"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == profile && $0["allowed"] as? Bool == true }
                cursor = result["nextCursor"] as? String
                if available || cursor == nil { break }
            }
            guard available else { throw ConfigError.io("The requested permission preset is unavailable. Check ChatGPT Settings.") }
            let result = try server.call("thread/start", ["cwd": path, "runtimeWorkspaceRoots": [path], "model": request.model,
                "permissions": profile, "config": ["model_reasoning_effort": request.reasoningEffort],
                "allowProviderModelFallback": false, "serviceName": "keylight", "threadSource": "user", "historyMode": "paginated"])
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String, UUID(uuidString: id) != nil,
                  result["cwd"] as? String == path, result["model"] as? String == request.model,
                  result["reasoningEffort"] as? String == request.reasoningEffort,
                  (result["activePermissionProfile"] as? [String: Any])?["id"] as? String == profile else { throw ConfigError.io("ChatGPT did not confirm the requested folder or preset.") }
            // Naming an empty thread materializes it. A metadata read then
            // confirms it exists before another process attempts to resume it.
            let line = request.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
            _ = try server.call("thread/name/set", ["threadId": id, "name": String(((request.projectName ?? "Keylight") + " · " + line).prefix(100))])
            let persisted = try server.call("thread/read", ["threadId": id, "includeTurns": false])
            guard (persisted["thread"] as? [String: Any])?["id"] as? String == id else { throw ConfigError.io("Invalid chat receipt.") }
            state = ChatLaunchState(threadID: id, phase: .prepared)
            try privateAtomicWrite(JSONEncoder().encode(state), to: stateURL)
        } catch { throw error }
    }

    func send() throws -> ChatLaunchState {
        if state.phase == .sent { return state }
        guard state.phase == .prepared else { throw ConfigError.io("Sending could not be confirmed. Open the chat before sending again.") }
        let desktop = try DesktopChatConnection(path: socketPath)
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var owner: String?
        while owner == nil, ProcessInfo.processInfo.systemUptime < deadline {
            let reply = try desktop.request("thread-owner-discovery", ["hostId": "local", "conversationId": state.threadID], version: 1, timeout: 1)
            if reply["resultType"] as? String == "success" { owner = reply["handledByClientId"] as? String }
            if owner == nil { desktop.channel.waitForInput(milliseconds: 150) }
        }
        guard let owner else { throw ConfigError.io("ChatGPT has not opened this chat yet. The request is saved; try again.") }
        let settings: [String: Any] = ["cwd": request.projectPath!, "model": request.model, "effort": request.reasoningEffort, "permissions": request.permissionsProfile ?? "Development"]
        let updated = try desktop.follower("thread-follower-update-thread-settings", ["conversationId": state.threadID, "threadSettings": settings], version: 2, owner: owner)
        guard updated["applied"] as? Bool == true else { throw ConfigError.io("ChatGPT did not confirm the requested folder or preset.") }
        // Once a send may have reached the desktop, never repeat it automatically.
        // A crash or lost acknowledgement leaves a reviewable, durable receipt.
        state.phase = .dispatching
        try privateAtomicWrite(JSONEncoder().encode(state), to: stateURL)
        var turn = settings
        turn["threadId"] = state.threadID
        turn["clientUserMessageId"] = request.id.uuidString.lowercased()
        turn["input"] = [["type": "text", "text": request.text, "text_elements": []] as [String: Any]]
        let started = try desktop.follower("thread-follower-start-turn", ["conversationId": state.threadID, "turnStart": ["request": turn]], version: 2, owner: owner)
        guard let result = started["result"] as? [String: Any], let returnedTurn = result["turn"] as? [String: Any],
              let id = returnedTurn["id"] as? String, !id.isEmpty else { throw ConfigError.io("Sending could not be confirmed. Open the chat before sending again.") }
        state.turnID = id; state.phase = .sent
        try privateAtomicWrite(JSONEncoder().encode(state), to: stateURL)
        return state
    }
}

// Bounded native transports: newline JSON-RPC for app-server; length-prefixed
// JSON for the desktop's local IPC. Neither transport invokes a shell.
final class ChatJSONChannel {
    enum Framing { case line, frame }
    let input: Int32
    let output: Int32
    private let framing: Framing
    private var buffered = Data()
    init(input: Int32, output: Int32, framing: Framing) {
        self.input = input; self.output = output; self.framing = framing
        _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
        _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
    }
    func waitForInput(milliseconds: Int32) {
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        _ = poll(&descriptor, 1, milliseconds)
    }
    func write(_ value: [String: Any], timeout: TimeInterval = 10) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 8_000_000 else { throw ConfigError.io("Chat request is too large.") }
        switch framing {
        case .line: data.append(10)
        case .frame:
            var length = UInt32(data.count).littleEndian
            data = withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var offset = 0
        while offset < data.count {
            try ready(output, POLLOUT, deadline)
            let count = data.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if errno != EINTR && errno != EAGAIN { throw ConfigError.io("Chat connection closed.") }
        }
    }
    func read(deadline: TimeInterval) throws -> [String: Any] {
        while true {
            var range: Range<Int>?
            var consumed = 0
            switch framing {
            case .line:
                if let end = buffered.firstIndex(of: 10) { range = 0..<end; consumed = end + 1 }
            case .frame:
                if buffered.count >= 4 {
                    let size = buffered.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
                    guard size > 0, size <= 8_000_000 else { throw ConfigError.io("Invalid chat response.") }
                    if buffered.count >= size + 4 { range = 4..<(size + 4); consumed = size + 4 }
                }
            }
            if let range {
                let data = buffered.subdata(in: range); buffered = Data(buffered.dropFirst(consumed))
                guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigError.io("Invalid chat response.") }
                return result
            }
            guard buffered.count <= 8_000_004 else { throw ConfigError.io("Invalid chat response.") }
            try ready(input, POLLIN, deadline)
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(input, &bytes, bytes.count)
            if count > 0 { buffered.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 || (errno != EINTR && errno != EAGAIN) { throw ConfigError.io("Chat connection closed.") }
        }
    }
    private func ready(_ fd: Int32, _ event: Int32, _ deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ConfigError.io("Chat connection timed out.") }
            var descriptor = pollfd(fd: fd, events: Int16(event), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 30_000)))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw ConfigError.io("Chat connection closed.") }
        }
    }
}

final class LocalAppServer {
    struct Failure: LocalizedError {
        let method: String
        let code: Int?
        let detail: String?
        var errorDescription: String? { "ChatGPT could not prepare this chat. Check its sign-in and preset." }
    }
    private let process = Process()
    private let incoming = Pipe()
    private let outgoing = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private var nextID = 0
    private let channel: ChatJSONChannel
    init(executable: URL, directory: String) throws {
        process.executableURL = executable; process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = outgoing; process.standardOutput = incoming; process.standardError = FileHandle.nullDevice
        let signal = exited
        process.terminationHandler = { _ in signal.signal() }
        channel = ChatJSONChannel(input: incoming.fileHandleForReading.fileDescriptor, output: outgoing.fileHandleForWriting.fileDescriptor, framing: .line)
        try process.run()
        do {
            _ = try call("initialize", ["clientInfo": ["name": "keylight", "version": "0.2.2"], "capabilities": ["experimentalApi": true]])
            try channel.write(["method": "initialized", "params": [:]])
        } catch { close(); throw error }
    }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1; let id = nextID
        try channel.write(["id": id, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while true {
            let message = try channel.read(deadline: deadline)
            guard message["id"] as? Int == id else { continue }
            guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                let failure = message["error"] as? [String: Any]
                throw Failure(method: method, code: failure?["code"] as? Int, detail: failure?["message"] as? String)
            }
            return result
        }
    }
    func close() {
        try? outgoing.fileHandleForWriting.close()
        if process.isRunning, exited.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? incoming.fileHandleForReading.close()
    }
    deinit { close() }
}

final class DesktopChatConnection {
    let channel: ChatJSONChannel
    private let socket: FileHandle
    private var clientID = "initializing-client"
    init(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw ConfigError.io("ChatGPT desktop connection is unavailable.") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ConfigError.io("ChatGPT desktop connection is unavailable.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConfigError.io("ChatGPT desktop connection is unavailable.") }
        let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard connected == 0, getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { Darwin.close(fd); throw ConfigError.io("ChatGPT desktop connection is unavailable.") }
        socket = FileHandle(fileDescriptor: fd, closeOnDealloc: true); channel = ChatJSONChannel(input: fd, output: fd, framing: .frame)
        let result = try request("initialize", ["clientType": "keylight"], version: 0)
        guard let id = (result["result"] as? [String: Any])?["clientId"] as? String else { throw ConfigError.io("Invalid chat response.") }
        clientID = id
    }
    func request(_ method: String, _ params: [String: Any], version: Int, owner: String? = nil, timeout: TimeInterval = 20) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID, "version": version, "method": method, "params": params, "timeoutMs": Int(timeout * 1000)]
        if let owner { message["targetClientId"] = owner }
        try channel.write(message)
        // The desktop router discovers a recipient before its request timer
        // starts. Its discovery handshake has a separate ten-second bound.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout + (method == "initialize" ? 1 : 11)
        while true {
            let reply = try channel.read(deadline: deadline)
            if reply["type"] as? String == "client-discovery-request", let discoveryID = reply["requestId"] as? String {
                try channel.write(["type": "client-discovery-response", "requestId": discoveryID, "response": ["canHandle": false]])
                continue
            }
            if reply["requestId"] as? String == id { return reply }
        }
    }
    func follower(_ method: String, _ params: [String: Any], version: Int, owner: String) throws -> [String: Any] {
        let reply = try request(method, params, version: version, owner: owner)
        guard reply["resultType"] as? String == "success", let result = reply["result"] as? [String: Any] else { throw ConfigError.io("ChatGPT could not accept this request. Open the chat to check its status.") }
        return result
    }
}

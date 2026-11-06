import Foundation
import Darwin

@main struct SearchLearningSmoke {
    struct Item { let name: String; let id: String; var aliases: [String] = [] }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keylight-learning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let previousMask = umask(0)
        defer { _ = umask(previousMask) }
        setenv("KEYLIGHT_CONFIG", root.appendingPathComponent("config.json").path, 1)
        var config = KeylightConfig()
        config.aliases = ["/Applications/Ghostty.app": ["term"]]
        config.excluded = ["/Applications/Hidden.app"]
        try Data("{}".utf8).write(to: ConfigStore.file)
        guard chmod(ConfigStore.file.path, 0o666) == 0 else { fatalError("Fixture chmod failed") }
        try ConfigStore.replace(config)
        let configMode = try FileManager.default.attributesOfItem(atPath: ConfigStore.file.path)[.posixPermissions] as? NSNumber
        precondition(configMode?.intValue == 0o600, "Replaced settings must use POSIX mode 0600")
        let reloadedConfig = try ConfigStore.read()
        precondition(reloadedConfig.aliases == config.aliases, "Private settings must remain readable")
        let beforeUnsafe = try Data(contentsOf: ConfigStore.file)
        guard chmod(root.path, 0o777) == 0 else { fatalError("Fixture chmod failed") }
        do { try ConfigStore.replace(config); fatalError("Shared writable directory must be rejected") } catch {}
        let afterShared = try Data(contentsOf: ConfigStore.file)
        precondition(afterShared == beforeUnsafe, "Rejected save must preserve settings")
        guard chmod(root.path, 0o700) == 0 else { fatalError("Fixture chmod failed") }
        let acl = Process(); acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "group:everyone allow read,file_inherit", root.path]
        try acl.run(); acl.waitUntilExit(); precondition(acl.terminationStatus == 0, "ACL fixture setup failed")
        let aclFile = root.appendingPathComponent("inherited-acl-fixture")
        let aclFD = open(aclFile.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard aclFD >= 0 else { fatalError("ACL file fixture failed") }
        do { try ConfigStore.requireNoACL(aclFD); fatalError("Inherited file ACL must be rejected") } catch {}
        var aclInfo = stat(); precondition(fstat(aclFD, &aclInfo) == 0 && aclInfo.st_size == 0, "Rejected file must stay empty")
        close(aclFD)
        do { try ConfigStore.replace(config); fatalError("ACL directory must be rejected") } catch {}
        do { _ = try SearchHistoryStore.record(query: "test", app: "/fixture"); fatalError("ACL learning directory must be rejected") } catch {}
        let afterACL = try Data(contentsOf: ConfigStore.file)
        precondition(afterACL == beforeUnsafe, "ACL rejection must preserve settings")
        let clearACL = Process(); clearACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        clearACL.arguments = ["-N", root.path]
        try clearACL.run(); clearACL.waitUntilExit(); precondition(clearACL.terminationStatus == 0, "ACL fixture cleanup failed")
        let blocked = root.appendingPathComponent("blocked-config")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let sentinel = blocked.appendingPathComponent("preserved")
        try Data("fixture".utf8).write(to: sentinel)
        setenv("KEYLIGHT_CONFIG", blocked.path, 1)
        do { try ConfigStore.replace(config); fatalError("Directory destination must fail") } catch {}
        let retained = try Data(contentsOf: sentinel)
        precondition(retained == Data("fixture".utf8), "Failure must preserve destination data")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(!leftovers.contains(where: { $0.hasPrefix(".config-") }), "Failure must remove temporary settings")
        setenv("KEYLIGHT_CONFIG", root.appendingPathComponent("config.json").path, 1)
        let originalConfig = try Data(contentsOf: ConfigStore.file)

        let calculator = Item(name: "Calculator", id: "/System/Applications/Calculator.app")
        let calendar = Item(name: "Calendar", id: "/System/Applications/Calendar.app")
        let calmer = Item(name: "CalmBar", id: "/Applications/CalmBar.app")
        let terminal = Item(name: "Ghostty", id: "/Applications/Ghostty.app", aliases: ["term"])
        let items = [calculator, calendar, calmer, terminal]
        func results(_ query: String, _ history: SearchHistory = SearchHistory()) -> [String] {
            Search.ordered(items, query: query, name: { $0.name }, aliases: { $0.aliases }, identity: { $0.id }, history: history).map(\.name)
        }
        precondition(results("CAL").first == "Calendar")
        precondition(results("clc").first == "Calculator")
        precondition(results("tm").contains("Ghostty"), "Existing aliases also support abbreviations")
        precondition(results("not-a-match").isEmpty)

        var history = try SearchHistoryStore.record(query: "CAL", app: calculator.id)
        precondition(results("cal", history).first == "Calculator", "A deliberate choice overrides the default")
        let reloaded = try SearchHistoryStore.read()
        precondition(reloaded == history, "Learning survives a new read")
        precondition(results("clc", history).first == "Calculator", "Learning is scoped to the query")
        for _ in 0..<5 { history = try SearchHistoryStore.record(query: "cal", app: calendar.id) }
        precondition(results("cal", history).first == "Calendar", "Repeated changed choices adjust ranking")
        for _ in 0..<10 { history = try SearchHistoryStore.record(query: "cal", app: calmer.id) }
        precondition(history.queries.first?.apps.count == SearchHistory.maxSelections)
        precondition(results("cal", history).first == "CalmBar", "The rolling window forgets old choices")

        for n in 0..<105 { _ = try SearchHistoryStore.record(query: "query\(n)", app: terminal.id) }
        let bounded = try SearchHistoryStore.read()
        precondition(bounded.queries.count == SearchHistory.maxQueries)
        let mode = try FileManager.default.attributesOfItem(atPath: SearchHistoryStore.file.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600, "Learning data must be private")
        let configAfterLearning = try Data(contentsOf: ConfigStore.file)
        precondition(configAfterLearning == originalConfig, "Learning must not modify settings")

        try Data("invalid".utf8).write(to: SearchHistoryStore.file)
        do { _ = try SearchHistoryStore.read(); fatalError("Corrupt history must report an error") } catch {}
        _ = try SearchHistoryStore.reset()
        let reset = try SearchHistoryStore.read()
        precondition(reset.queries.isEmpty)
        precondition(results("cal", reset).first == "Calendar")
        let configAfterReset = try Data(contentsOf: ConfigStore.file)
        precondition(configAfterReset == originalConfig, "Reset must preserve settings")
        print("PASS: CAL/CLC defaults, aliases, query-specific adaptation, rolling bounds, private persistence and reset")
    }
}

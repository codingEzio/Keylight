import AppKit
import Foundation

@main struct SearchLaunchSmoke {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = root.appendingPathComponent("Fixture Calculator.app")
        setenv("KEYLIGHT_CONFIG", root.appendingPathComponent("config.json").path, 1)
        var config = KeylightConfig()
        config.folders = [root.path]
        config.aliases = [app.path: ["fixture"]]
        try ConfigStore.replace(config)
        let original = try Data(contentsOf: ConfigStore.file)
        _ = NSApplication.shared
        let model = Model()
        model.query = "cal"
        model.run(Entry(id: app.path, name: "Fixture Calculator", url: app, icon: NSImage(), isAction: false))
        func wait(_ label: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            precondition(condition(), "Timed out: \(label); error: \(model.error ?? "none")")
            print("PASS: \(label)")
        }
        wait("successful app open records the original query") { model.searchHistory.preference(for: "cal")[app.path] == 0 }
        let saved = try SearchHistoryStore.read()
        precondition(saved.preference(for: "cal")[app.path] == 0)
        model.resetSearchLearning()
        wait("reset clears persisted learning") { model.searchHistory.queries.isEmpty }
        let cleared = try SearchHistoryStore.read()
        let configAfter = try Data(contentsOf: ConfigStore.file)
        precondition(cleared.queries.isEmpty && configAfter == original)
        wait("fixture app exits") { NSRunningApplication.runningApplications(withBundleIdentifier: "test.keylight.learningfixture").isEmpty }
        print("PASS: app launch to durable learning and reset without changing settings")
    }
}

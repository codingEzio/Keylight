import Foundation

@main struct FirstRunSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keylight-first-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Fresh Home")
        let systemApps = root.appendingPathComponent("System Apps")
        func app(_ name: String, in directory: URL) throws {
            let contents = directory.appendingPathComponent(name + ".app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": name], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try app("Preview", in: systemApps)
        var config = KeylightConfig()
        config.folders = [systemApps.path, home.path + "/Applications", home.path + "/Applications/Chrome Apps.localized"]
        let initial = try CLI.items(config, includeCommands: false, home: home.path)
        precondition(initial.map(\.name).contains("Preview"), "A missing optional folder must not hide system apps")

        try app("Local", in: home.appendingPathComponent("Applications"))
        let afterCreation = try CLI.items(config, includeCommands: false, home: home.path)
        precondition(afterCreation.map(\.name).contains("Local"), "A later-created default folder must be scanned")

        config.folders.append(root.appendingPathComponent("Missing Custom").path)
        do {
            _ = try CLI.items(config, includeCommands: false, home: home.path)
            fatalError("A missing custom folder must still report an error")
        } catch ConfigError.io(let message) {
            precondition(message.contains("Missing Custom"))
        }
        print("PASS: first-run search, later-created default folder, missing custom folder")
    }
}

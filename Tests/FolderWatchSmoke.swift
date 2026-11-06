import Foundation

@main struct FolderWatchSmoke {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("keylight-watch-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let apps = root.appendingPathComponent("Apps")
        let future = root.appendingPathComponent("Future/Apps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        setenv("KEYLIGHT_CONFIG", root.appendingPathComponent("config.json").path, 1)
        var config = KeylightConfig(); config.folders = [apps.path, future.path]; config.scripts = ""
        try ConfigStore.encode(config).write(to: ConfigStore.file)
        let delegate = AppDelegate()
        let model = delegate.model
        model.refresh()
        func wait(_ label: String, _ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            precondition(predicate(), "Timed out: \(label)")
            print("PASS: \(label)")
        }
        func createApp(_ name: String, in folder: URL) throws {
            let contents = folder.appendingPathComponent(name + ".app/Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": name], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        func contains(_ name: String) -> Bool { model.entries.contains { $0.name == name } }
        wait("initial scan") { !model.isScanning }
        try createApp("Later", in: apps)
        wait("automatic addition") { contains("Later") }
        try fm.moveItem(at: apps.appendingPathComponent("Later.app"), to: apps.appendingPathComponent("Renamed.app"))
        wait("automatic rename") { !contains("Later") && contains("Renamed") }
        try fm.removeItem(at: apps.appendingPathComponent("Renamed.app"))
        wait("automatic removal") { !contains("Renamed") }
        try createApp("CreatedFolder", in: future)
        wait("previously missing nested folder") { contains("CreatedFolder") }
        try fm.removeItem(at: apps)
        wait("watched folder removal") { !contains("Renamed") && model.unavailableFolders.contains(apps.path) }
        try createApp("Restored", in: apps)
        wait("watched folder restoration") { contains("Restored") }
        try createApp("Manual", in: apps)
        delegate.refreshApps()
        wait("manual refresh menu action") { contains("Manual") }
        print("PASS: model updates on filesystem events and manual refresh")
    }
}

import Foundation
import Darwin

enum CLI {
    static let help = """
    Keylight — local launcher
    Usage:
      Keylight search [TEXT]            List matching apps and commands
      Keylight apps [all|background|installers] [TEXT]
      Keylight run NAME                 Open an exact app or run a command
      Keylight config show              Print current settings as JSON
      Keylight config export FILE       Export settings to FILE
      Keylight config import FILE       Validate and replace settings from FILE
      Keylight config theme THEME       Set search theme
      Keylight config shortcut MOD KEY  Set shortcut (for example: '⌘' Space)
      Keylight config folder add|remove PATH
      Keylight config exclude add|remove APP_PATH
      Keylight config scripts PATH|clear
      Keylight config icons Original|System
      Keylight config alias add|remove APP_PATH ALIAS
      Keylight config learning reset    Reset learned search ranking
      Keylight --help                   Show this help
    KEYLIGHT_CONFIG overrides the settings file path.
    """
    struct Item { let name: String; let path: String; let command: Bool; var aliases: [String] = []; var visible = true; var backgroundOnly = false; var installerName = false }
    static func items(_ c: KeylightConfig, includeExcluded: Bool = false, includeCommands: Bool = true, home: String = NSHomeDirectory()) throws -> [Item] {
        var out: [Item] = [], seen = Set<String>(), failures: [String] = []; let exclusions = Set(c.excluded.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        for path in c.folders {
            if KeylightConfig.missingOptionalDefaultFolder(path, home: home) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path), let it = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [.skipsPackageDescendants], errorHandler: { _, _ in if !failures.contains(path) { failures.append(path) }; return true }) else { failures.append(path); continue }
            for case let url as URL in it where url.pathExtension.lowercased() == "app" {
                let p = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(p).inserted else { continue }
                let visible = !exclusions.contains(p)
                guard visible || includeExcluded else { continue }
                let name = FileManager.default.displayName(atPath: p).replacingOccurrences(of: ".app", with: "")
                out.append(Item(name: name, path: p, command: false, visible: visible, backgroundOnly: AppClassification.backgroundOnly(path: p), installerName: AppClassification.installerName(name)))
            }
        }
        if includeCommands && !c.scripts.isEmpty {
            do { let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: c.scripts), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]); for url in urls where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && FileManager.default.isExecutableFile(atPath: url.path) { out.append(Item(name: url.deletingPathExtension().lastPathComponent, path: url.path, command: true)) } }
            catch { failures.append(c.scripts) }
        }
        if includeCommands { out.append(contentsOf: SystemSettings.destinations.map { Item(name: $0.name, path: $0.id, command: true, aliases: $0.aliases) }) }
        guard failures.isEmpty else { throw ConfigError.io("Cannot read configured folders: " + failures.joined(separator: ", ")) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(); let path = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/toggle-dark-mode.sh").path
        if includeCommands && FileManager.default.isExecutableFile(atPath: path) { out.append(Item(name: "Toggle Dark Mode", path: path, command: true)) }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func run(_ args: [String]) -> Int32 {
        do {
            if args == ["--help"] || args == ["help"] { print(help); return 0 }
            if args.first == "config" {
                if args == ["config", "learning", "reset"] { try SearchHistoryStore.reset(); return 0 }
                if args.count == 2 && args[1] == "show" { print(String(decoding: try ConfigStore.encode(ConfigStore.read()), as: UTF8.self)); return 0 }
                if args.count == 3 && args[1] == "export" { let c = try ConfigStore.read(); try ConfigStore.encode(c).write(to: URL(fileURLWithPath: args[2]), options: .atomic); return 0 }
                if args.count == 3 && args[1] == "import" { let data = try Data(contentsOf: URL(fileURLWithPath: args[2])); try ConfigStore.replace(ConfigStore.decode(data)); return 0 }
                if args.count == 5 && args[1] == "alias" && ["add", "remove"].contains(args[2]) {
                    let path = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath().standardizedFileURL.path
                    let value = args[4].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { throw ConfigError.invalid }
                    try ConfigStore.update { c in
                        var values = c.aliases[path] ?? []
                        if args[2] == "add" { if !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { values.append(value) } }
                        else { values.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame } }
                        if values.isEmpty { c.aliases.removeValue(forKey: path) } else { c.aliases[path] = values }
                    }; return 0
                }
                if args.count == 3 && args[1] == "icons" { try ConfigStore.update { $0.iconStyle = args[2] }; return 0 }
                if args.count == 3 && args[1] == "theme" { try ConfigStore.update { $0.theme = args[2] }; return 0 }
                if args.count == 4 && args[1] == "shortcut" { try ConfigStore.update { $0.modifier = args[2]; $0.key = args[3] }; return 0 }
                if args.count == 3 && args[1] == "scripts" { let path = args[2] == "clear" ? "" : URL(fileURLWithPath: args[2]).standardizedFileURL.path; try ConfigStore.update { $0.scripts = path }; return 0 }
                if args.count == 4 && ["folder", "exclude"].contains(args[1]) && ["add", "remove"].contains(args[2]) {
                    let path = URL(fileURLWithPath: args[3]).standardizedFileURL.path
                    try ConfigStore.update { c in
                        var list = args[1] == "folder" ? c.folders : c.excluded
                        if args[2] == "add" { if !list.contains(path) { list.append(path) } } else { list.removeAll { $0 == path } }
                        if args[1] == "folder" { c.folders = list } else { c.excluded = list }
                    }; return 0
                }
            }
            if args.first == "apps", args.count <= 3 {
                let category = args.count >= 2 ? args[1] : "all"
                guard ["all", "background", "installers"].contains(category) else { throw ConfigError.io(help) }
                let query = args.count == 3 ? args[2] : ""
                let entries = try items(ConfigStore.read(), includeExcluded: true, includeCommands: false)
                for item in entries where !item.command && (query.isEmpty || item.name.localizedStandardContains(query)) && (category == "all" || (category == "background" && item.backgroundOnly) || (category == "installers" && item.installerName)) {
                    print("\(item.visible ? "show" : "hide")\t\(item.name)\t\(item.path)")
                }
                return 0
            }
            if args.first == "search", args.count <= 2 {
                let q = (args.count == 2 ? args[1] : "").trimmingCharacters(in: .whitespacesAndNewlines); let config = try ConfigStore.read()
                let results = Search.ordered(try items(config), query: q, name: { $0.name }, aliases: { $0.command ? $0.aliases : (config.aliases[$0.path] ?? []) }, identity: { $0.path }, history: try SearchHistoryStore.read())
                for item in results { print("\(item.name)\t\(item.command ? "command" : "app")\t\(item.path)") }; return 0
            }
            if args.count == 2, args[0] == "run" {
                let config = try ConfigStore.read(); let results = try items(config).filter { $0.name.caseInsensitiveCompare(args[1]) == .orderedSame || (!$0.command && (config.aliases[$0.path] ?? []).contains { $0.caseInsensitiveCompare(args[1]) == .orderedSame }) }
                guard results.count == 1, let item = results.first else { throw ConfigError.io(results.isEmpty ? "No exact match." : "Multiple exact matches; choose a unique name.") }
                let setting = SystemSettings.find(item.path)
                let p = Process(); p.executableURL = URL(fileURLWithPath: item.command && setting == nil ? item.path : "/usr/bin/open"); if let setting { p.arguments = [setting.url.absoluteString] } else if !item.command { p.arguments = [item.path] }; try p.run(); p.waitUntilExit(); return p.terminationStatus
            }
            throw ConfigError.io(help)
        } catch { fputs("Keylight: \(error.localizedDescription)\n", stderr); return 1 }
    }
}

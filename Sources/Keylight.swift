import AppKit
import SwiftUI
import Carbon
import Combine
import CoreText
import Darwin

struct Entry: Identifiable {
    let id: String
    let name: String
    let url: URL?
    let icon: NSImage
    let isAction: Bool
    var backgroundOnly = false
    var installerName = false
}

@MainActor final class Model: ObservableObject {
    @Published var theme = "Liquid Glass" { didSet { save(\.theme, theme) } }
    @Published var modifier = "⌘" { didSet { save(\.modifier, modifier); if ready && !reloading { registerHotKey() } } }
    @Published var key = "Space" { didSet { save(\.key, key); if ready && !reloading { registerHotKey() } } }
    @Published var folderJSON = "" { didSet { if let a = try? JSONDecoder().decode([String].self, from: Data(folderJSON.utf8)) { save(\.folders, a) }; if ready && !reloading { refresh() } } }
    @Published var excludeJSON = "[]" { didSet { if let a = try? JSONDecoder().decode([String].self, from: Data(excludeJSON.utf8)) { save(\.excluded, a) }; if ready && !reloading { refresh() } } }
    @Published var scripts = "" { didSet { save(\.scripts, scripts); if ready && !reloading { refresh() } } }
    @Published var iconStyle = "Original" { didSet { save(\.iconStyle, iconStyle); if ready && !reloading { refresh() } } }
    @Published var aliases: [String: [String]] = [:]
    @Published private(set) var searchHistory = SearchHistory()
    @Published private(set) var learningError: String?
    private var ready = false
    private var reloading = false
    private var observer: NSObjectProtocol?
    private var configWatcher: DispatchSourceFileSystemObject?
    private lazy var appFolderWatcher = AppFolderWatcher { [weak self] rewatch in
        guard let self else { return }
        if rewatch { self.watchAppFolders() }
        self.refresh()
    }
    init() {
        loadSettings()
        ready = true
        watchAppFolders()
        let fd = open(ConfigStore.file.deletingLastPathComponent().path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.loadSettings() } }
            source.setCancelHandler { close(fd) }; source.resume(); configWatcher = source
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.alex.Keylight.configChanged"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.loadSettings() } }
    }
    private func save<T>(_ path: WritableKeyPath<KeylightConfig, T>, _ value: T) {
        guard ready, !reloading else { return }
        do { try ConfigStore.update { $0[keyPath: path] = value } } catch { self.error = error.localizedDescription }
    }
    func loadSettings() {
        do {
            let c = try ConfigStore.read(); let wasReady = ready; let shortcutChanged = modifier != c.modifier || key != c.key; let scanChanged = folderJSON != encode(c.folders) || excludeJSON != encode(c.excluded) || scripts != c.scripts || iconStyle != c.iconStyle; reloading = true
            if theme != c.theme { theme = c.theme }; if modifier != c.modifier { modifier = c.modifier }; if key != c.key { key = c.key }
            let foldersValue = encode(c.folders), excludedValue = encode(c.excluded)
            if folderJSON != foldersValue { folderJSON = foldersValue }; if excludeJSON != excludedValue { excludeJSON = excludedValue }; if scripts != c.scripts { scripts = c.scripts }; if iconStyle != c.iconStyle { iconStyle = c.iconStyle }; if aliases != c.aliases { aliases = c.aliases }
            reloading = false
            if wasReady && shortcutChanged { registerHotKey() }; if wasReady && scanChanged { watchAppFolders(); refresh() }
        } catch { reloading = false; self.error = error.localizedDescription }
        do {
            let history = try SearchHistoryStore.read()
            applySearchHistory(history)
            learningError = nil
        } catch { learningError = error.localizedDescription }
    }
    private func watchAppFolders() {
        if !appFolderWatcher.watch(folders + (scripts.isEmpty ? [] : [scripts])) {
            error = NSLocalizedString("Automatic app updates unavailable; use Refresh Apps.", comment: "")
        }
    }
    @Published var query = ""
    @Published var selected = 0
    @Published var entries: [Entry] = []
    @Published var allApps: [Entry] = []
    @Published var isScanning = false
    @Published var unavailableFolders: [String] = []
    @Published var error: String?
    var hotkey: EventHotKeyRef?
    private var refreshVersion = 0
    private let scanQueue = DispatchQueue(label: "local.keylight.scan", qos: .userInitiated)
    private let learningQueue = DispatchQueue(label: "local.keylight.search-learning", qos: .utility)
    private var pendingScan: DispatchWorkItem?
    var launch: (() -> Void)?
    var defaults: [String] { ["/Applications", "/System/Applications", NSHomeDirectory()+"/Applications", NSHomeDirectory()+"/Applications/Chrome Apps.localized"] }
    var folders: [String] { (try? JSONDecoder().decode([String].self, from: Data(folderJSON.utf8))) ?? defaults }
    var excluded: [String] { (try? JSONDecoder().decode([String].self, from: Data(excludeJSON.utf8))) ?? [] }
    func encode(_ a: [String]) -> String { String(data: (try? JSONEncoder().encode(a)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    var matches: [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return Search.ordered(entries, query: q, name: { $0.name }, aliases: { SystemSettings.find($0.id)?.aliases ?? ($0.isAction ? [] : (aliases[$0.id] ?? [])) }, identity: { $0.id }, history: searchHistory)
    }
    func refresh() {
        refreshVersion += 1
        isScanning = true
        let version = refreshVersion
        let folders = self.folders, excluded = Set(self.excluded.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }), scripts = self.scripts, iconStyle = self.iconStyle
        pendingScan?.cancel()
        let work = DispatchWorkItem {
            var found: [Entry] = []; var allApps: [Entry] = []; var seen = Set<String>(); var unavailable: [String] = []
            for path in folders {
                if KeylightConfig.missingOptionalDefaultFolder(path) { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                      let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants], errorHandler: { _, _ in if !unavailable.contains(path) { unavailable.append(path) }; return true }) else { unavailable.append(path); continue }
                for case let url as URL in e where url.pathExtension.lowercased() == "app" {
                    let p = url.resolvingSymlinksInPath().standardizedFileURL.path
                    guard seen.insert(p).inserted else { continue }
                    let name = FileManager.default.displayName(atPath: p).replacingOccurrences(of: ".app", with: "")
                    let background = AppClassification.backgroundOnly(path: p)
                    let installer = AppClassification.installerName(name)
                    let item = Entry(id: p, name: name, url: url, icon: AppIcons.load(path: p, style: iconStyle), isAction: false, backgroundOnly: background, installerName: installer)
                    allApps.append(item)
                    if !excluded.contains(p) { found.append(item) }
                }
            }
            if !scripts.isEmpty, let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: scripts), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for u in urls where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && FileManager.default.isExecutableFile(atPath: u.path) {
                    found.append(Entry(id: u.path, name: u.deletingPathExtension().lastPathComponent, url: u, icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!, isAction: true))
                }
            }
            found.append(contentsOf: SystemSettings.destinations.map { Entry(id: $0.id, name: $0.name, url: $0.url, icon: NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil)!, isAction: true) })
            found.append(Entry(id: "system-theme", name: NSLocalizedString("Toggle Dark Mode", comment: ""), url: nil, icon: NSImage(systemSymbolName: "moon", accessibilityDescription: nil)!, isAction: true))
            let result = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                guard version == self.refreshVersion else { return }
                let oldMatches = self.matches
                let previousIndex = self.selected
                let previousID = oldMatches.indices.contains(previousIndex) ? oldMatches[previousIndex].id : nil
                self.entries = result
                let newMatches = self.matches
                self.selected = previousID.flatMap { id in newMatches.firstIndex { $0.id == id } } ?? min(previousIndex, max(0, newMatches.count - 1))
                self.allApps = allApps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.unavailableFolders = unavailable; self.isScanning = false
            }
        }
        pendingScan = work; scanQueue.async(execute: work)
    }
    @discardableResult func setAppVisible(path: String, visible: Bool) -> Bool {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        do {
            try ConfigStore.update { config in
                config.excluded.removeAll { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == canonical }
                if !visible { config.excluded.append(canonical) }
            }
            loadSettings()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func excludeSelectedApp(undoManager: UndoManager?) {
        let results = matches
        guard results.indices.contains(selected), !results[selected].isAction else { return }
        let entry = results[selected]
        let previousIndex = selected
        guard setAppVisible(path: entry.id, visible: false) else {
            let alert = NSAlert(); alert.messageText = NSLocalizedString("Couldn’t exclude app", comment: ""); alert.informativeText = error ?? ""; alert.runModal()
            return
        }
        entries.removeAll { $0.id == entry.id }
        selected = min(previousIndex, max(0, matches.count - 1))
        undoManager?.registerUndo(withTarget: self) { model in model.restoreExcludedApp(entry) }
    }
    private func restoreExcludedApp(_ entry: Entry) {
        guard excluded.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == entry.id }) else { return }
        guard setAppVisible(path: entry.id, visible: true) else {
            let alert = NSAlert(); alert.messageText = NSLocalizedString("Couldn’t restore app", comment: ""); alert.informativeText = error ?? ""; alert.runModal()
            return
        }
        if let app = allApps.first(where: { $0.id == entry.id }), !entries.contains(where: { $0.id == entry.id }) {
            entries.append(app)
            entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if let index = matches.firstIndex(where: { $0.id == entry.id }) { selected = index }
    }
    func changeAlias(path: String, alias: String, add: Bool) {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try ConfigStore.update { config in
                var values = config.aliases[path] ?? []
                if add { if !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { values.append(value) } }
                else { values.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame } }
                if values.isEmpty { config.aliases.removeValue(forKey: path) } else { config.aliases[path] = values }
            }
            loadSettings()
        } catch { self.error = error.localizedDescription }
    }
    private var commandRunning = false
    private func applySearchHistory(_ history: SearchHistory) {
        guard searchHistory != history else { return }
        let previous = matches
        let selectedID = previous.indices.contains(selected) ? previous[selected].id : nil
        searchHistory = history
        if let selectedID, let index = matches.firstIndex(where: { $0.id == selectedID }) { selected = index }
    }
    private func rememberSearch(query: String, app: String) {
        guard !SearchHistory.normalized(query).isEmpty else { return }
        learningQueue.async { [weak self] in
            do {
                let history = try SearchHistoryStore.record(query: query, app: app)
                DispatchQueue.main.async { self?.applySearchHistory(history); self?.learningError = nil }
            } catch {
                DispatchQueue.main.async { self?.learningError = error.localizedDescription }
            }
        }
    }
    func resetSearchLearning() {
        learningQueue.async { [weak self] in
            do {
                let history = try SearchHistoryStore.reset()
                DispatchQueue.main.async { self?.applySearchHistory(history); self?.learningError = nil }
            } catch {
                DispatchQueue.main.async { self?.learningError = error.localizedDescription }
            }
        }
    }
    private func report(_ text: String) {
        error = text
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = NSLocalizedString("Command failed", comment: ""); alert.informativeText = text; alert.runModal()
    }
    func run(_ e: Entry) {
        if !e.isAction, let u = e.url {
            let selectedQuery = query
            let appID = e.id
            NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                DispatchQueue.main.async {
                    if let err { self.report(err.localizedDescription) }
                    else { self.rememberSearch(query: selectedQuery, app: appID) }
                }
            }
            return
        }
        if let setting = SystemSettings.find(e.id) {
            if !NSWorkspace.shared.open(setting.url) { report(NSLocalizedString("Couldn’t open System Settings.", comment: "")) }
            return
        }
        guard !commandRunning else { report(NSLocalizedString("A command is already running.", comment: "")); return }
        let executable = e.id == "system-theme" ? Bundle.main.url(forResource: "toggle-dark-mode", withExtension: "sh") : e.url
        guard let executable else { report(NSLocalizedString("Command not found.", comment: "")); return }
        let process = Process(); process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.commandRunning = false
                if p.terminationStatus != 0 { self.report(String(format: NSLocalizedString("Command exited with status %d.", comment: ""), p.terminationStatus)) }
            }
        }
        do { commandRunning = true; try process.run() } catch { commandRunning = false; report(error.localizedDescription) }
    }
    func registerHotKey() {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        let keys: [String: UInt32] = ["Space":49,"A":0,"B":11,"C":8,"D":2,"E":14,"F":3,"G":5,"H":4,"I":34,"J":38,"K":40,"L":37,"M":46,"N":45,"O":31,"P":35,"Q":12,"R":15,"S":1,"T":17,"U":32,"V":9,"W":13,"X":7,"Y":16,"Z":6]
        let mods: [String: UInt32] = ["⌘":UInt32(cmdKey), "⌥":UInt32(optionKey), "⌃":UInt32(controlKey), "⌘ ⇧":UInt32(cmdKey | shiftKey), "⌘ ⌥":UInt32(cmdKey | optionKey), "⌃ ⌥":UInt32(controlKey | optionKey), "⌘ ⌥ ⇧":UInt32(cmdKey | optionKey | shiftKey)]
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keys[key] ?? 49, mods[modifier] ?? UInt32(cmdKey), EventHotKeyID(signature: 0x4B4C4954, id: 1), GetApplicationEventTarget(), 0, &ref)
        hotkey = ref
        if status == noErr { error = nil }
        if status != noErr { error = "Shortcut unavailable (\(status)). Choose another shortcut or change Spotlight in System Settings." }
    }
}

struct SearchView: View {
    @ObservedObject var model: Model
    let close: () -> Void
    let resize: (Int) -> Void
    @FocusState private var focus: Bool
    @State private var clickedID: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var isDark: Bool { colorScheme == .dark }
    var cyber: Bool { model.theme == "Cyberpunk 2077" }
    var nothing: Bool { model.theme == "Nothing" }
    var xp: Bool { model.theme == "Windows XP" }
    var foreground: Color {
        if cyber || nothing || xp { return isDark ? .white : .black }
        return .primary
    }
    var selectedBackground: Color {
        if cyber { return isDark ? Color(red: 0.36, green: 0.34, blue: 0.20) : Color(red: 0.80, green: 0.76, blue: 0.59) }
        if nothing { return isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.16) }
        if xp { return isDark ? Color(red: 0.15, green: 0.30, blue: 0.53) : Color(red: 0.78, green: 0.86, blue: 0.97) }
        return Color.accentColor.opacity(0.2)
    }
    func rowForeground(selected: Bool) -> Color {
        if cyber { return isDark ? Color(red: 1, green: 0.48, blue: 0.48) : Color(red: 0.55, green: 0.04, blue: 0.08) }
        return foreground
    }
    var customBackground: Color {
        if cyber { return isDark ? Color(red: 0.055, green: 0.055, blue: 0.065) : Color(red: 0.96, green: 0.94, blue: 0.90) }
        if nothing { return isDark ? Color(red: 0.055, green: 0.055, blue: 0.06) : Color(red: 0.96, green: 0.96, blue: 0.95) }
        return isDark ? Color(red: 0.12, green: 0.15, blue: 0.20) : Color(red: 0.94, green: 0.95, blue: 0.98)
    }
    var font: Font { cyber ? .custom("AvenirNextCondensed-DemiBold", size: 18) : nothing ? .custom("Doto-Black", size: 17) : xp ? .custom("Tahoma", size: 16) : .system(size: 17, weight: .medium) }
    var searchFont: Font { cyber ? .custom("AvenirNextCondensed-DemiBold", size: 23) : nothing ? .custom("Doto-Black", size: 22) : xp ? .custom("Tahoma", size: 21) : .system(size: 22) }
    func matchText(_ name: String) -> Text {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = Search.range(query, in: name) else { return Text(name) }
        let before = String(name[..<range.lowerBound]), after = String(name[range.upperBound...])
        let match = Text(String(name[range])).underline()
        return Text("\(before)\(match)\(after)")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20))
                TextField("", text: $model.query).textFieldStyle(.plain).font(searchFont).foregroundColor(xp ? .white : foreground).accessibilityLabel(Text("Search"))
                    .overlay(alignment: .leading) { if model.query.isEmpty { Text("Search").font(searchFont).foregroundColor(xp ? .white.opacity(0.9) : foreground.opacity(0.65)).allowsHitTesting(false) } }
                    .focused($focus).onChange(of: model.query) { _,_ in model.selected = 0; clickedID = nil }
                    .contextMenu {
                        Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                        Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        Divider()
                        Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    }
            }.padding(18).foregroundStyle(xp ? Color.white : foreground).background(xp ? Color(red: 0.16, green: 0.25, blue: 0.39) : .clear)
            Divider()
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 2) {
                if model.matches.isEmpty { Text(LocalizedStringKey(model.isScanning ? "Searching…" : "No results")).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding() }
                ForEach(Array(model.matches.enumerated()), id: \.element.id) { i, e in
                    Button {
                        if clickedID == e.id && model.selected == i { model.run(e); close() }
                        else { model.selected = i; clickedID = e.id; focus = true }
                    } label: {
                        HStack(spacing: 12) { Image(nsImage: e.icon).renderingMode(e.isAction ? .template : .original).resizable().frame(width: 29, height: 29); matchText(e.name).font(font); Spacer(); if i == model.selected { Text("↵").font(.system(size: 16)) } }
                            .foregroundStyle(rowForeground(selected: i == model.selected))
                            .padding(.horizontal, 12).frame(height: 45).background(i == model.selected ? selectedBackground : .clear).clipShape(RoundedRectangle(cornerRadius: xp ? 2 : cyber ? 3 : 9))
                    }.buttonStyle(.plain).id(e.id)
                }
                }.padding(8)
              }.frame(maxHeight: 350).onChange(of: model.selected) { _, value in if model.matches.indices.contains(value) { proxy.scrollTo(model.matches[value].id, anchor: .center) } }
            }
        }.foregroundStyle(foreground)
        .background { if cyber || nothing || xp { Rectangle().fill(.ultraThinMaterial).overlay(customBackground.opacity(reduceTransparency ? 1 : 0.82)) } else { Rectangle().fill(.clear).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18)) } }
        .clipShape(RoundedRectangle(cornerRadius: xp ? 6 : cyber ? 5 : 18)).overlay(RoundedRectangle(cornerRadius: xp ? 6 : cyber ? 5 : 18).stroke(cyber ? Color.red.opacity(0.45) : xp ? Color.blue.opacity(0.45) : .white.opacity(0.3), lineWidth: xp ? 2 : 1))
        .onAppear { focus = true; resize(model.matches.count) }.onChange(of: model.matches.count) { _, count in resize(count) }.onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.downArrow) { clickedID = nil; model.selected = min(model.selected+1, max(0, model.matches.count-1)); return .handled }
        .onKeyPress(.upArrow) { clickedID = nil; model.selected = max(0, model.selected-1); return .handled }
        .onKeyPress(.return) { if model.matches.indices.contains(model.selected) { model.run(model.matches[model.selected]); close() }; return .handled }
    }
}

struct AppVisibilitySection: View {
    @ObservedObject var model: Model
    let chooseExcluded: () -> Void
    @State private var query = ""
    @State private var category = 0
    var body: some View {
        let excluded = Set(model.excluded.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        let available = Set(model.allApps.map(\.id))
        let duplicateNames = Set(Dictionary(grouping: model.allApps, by: { $0.name.lowercased() }).filter { $0.value.count > 1 }.keys)
        let orphaned = model.excluded.filter { !available.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path) }
        let matches = model.allApps.filter { app in
            (query.isEmpty || app.name.localizedStandardContains(query)) && (category == 0 || (category == 1 && app.backgroundOnly) || (category == 2 && app.installerName))
        }
        return Section("Search apps") {
            TextField("Find apps", text: $query).textFieldStyle(.roundedBorder)
            Picker("Preview", selection: $category) {
                Text("All").tag(0); Text("Background only").tag(1); Text("Installer names").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.isScanning && model.allApps.isEmpty { Text("Searching…").foregroundStyle(.secondary) }
                    else if matches.isEmpty { Text("No apps found").foregroundStyle(.secondary) }
                    ForEach(matches) { app in
                        Toggle(isOn: Binding(get: { !excluded.contains(app.id) }, set: { model.setAppVisible(path: app.id, visible: $0) })) {
                            HStack(spacing: 8) {
                                Image(nsImage: app.icon).renderingMode(.original).resizable().frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).lineLimit(1)
                                    if duplicateNames.contains(app.name.lowercased()) { Text(URL(fileURLWithPath: app.id).deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }
                                Spacer(minLength: 8)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.toggleStyle(.switch).controlSize(.small).frame(maxWidth: .infinity).accessibilityLabel(Text(app.name)).help(app.id)
                    }
                }.padding(.vertical, 3)
            }.frame(height: 160)
            Button("Exclude another app…", action: chooseExcluded)
            if !model.isScanning && !orphaned.isEmpty {
                Text("Excluded outside search folders").font(.caption).foregroundStyle(.secondary)
                ForEach(orphaned, id: \.self) { path in
                    HStack { Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent).help(path); Spacer(); Button("Restore") { model.setAppVisible(path: path, visible: true) } }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var aliasPath = ""
    @State private var aliasText = ""
    @State private var confirmResetLearning = false
    private enum Page: Hashable { case general, apps, aliases, configuration }
    @State private var page: Page? = .general
    func chooseFolder() { let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false; if p.runModal() == .OK, let u = p.url, !model.folders.contains(u.path) { model.folderJSON = model.encode(model.folders + [u.path]) } }
    func chooseExcluded() { let p = NSOpenPanel(); p.canChooseDirectories = false; p.canChooseFiles = true; p.allowedContentTypes = [.applicationBundle]; if p.runModal() == .OK, let u = p.url, !model.excluded.contains(u.path) { model.excludeJSON = model.encode(model.excluded + [u.path]) } }
    func chooseAliasApp() {
        let p = NSOpenPanel(); p.canChooseDirectories = false; p.canChooseFiles = true; p.allowedContentTypes = [.applicationBundle]
        if p.runModal() == .OK, let url = p.url { aliasPath = url.resolvingSymlinksInPath().standardizedFileURL.path }
    }
    func chooseScripts() { let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; if p.runModal() == .OK, let u = p.url { model.scripts = u.path } }
    func importSettings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { do { let config = try ConfigStore.decode(Data(contentsOf: url)); try ConfigStore.replace(config); model.loadSettings() } catch { model.error = error.localizedDescription } }
    }
    func exportSettings() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Keylight.json"
        if panel.runModal() == .OK, let url = panel.url { do { try ConfigStore.encode(ConfigStore.read()).write(to: url, options: .atomic) } catch { model.error = error.localizedDescription } }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("General", systemImage: "gearshape").tag(Page.general)
                Label("Search apps", systemImage: "app.badge.checkmark").tag(Page.apps)
                Label("App aliases", systemImage: "text.badge.plus").tag(Page.aliases)
                Label("Configuration", systemImage: "folder").tag(Page.configuration)
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 230)
        } detail: {
          Form {
            if page == .general {
            Section("General") {
                HStack { Text("Shortcut"); Spacer(); Picker("", selection: $model.modifier) { ForEach(["⌘","⌥","⌃","⌘ ⇧","⌘ ⌥","⌃ ⌥","⌘ ⌥ ⇧"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 100); Picker("", selection: $model.key) { ForEach(["Space"] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init), id: \.self) { Text($0) } }.labelsHidden().frame(width: 110) }
                Picker("Search theme", selection: $model.theme) { ForEach(["Liquid Glass", "Cyberpunk 2077", "Windows XP", "Nothing"], id: \.self) { Text($0) } }
                Picker("App icons", selection: $model.iconStyle) { Text("Original (when available)").tag("Original"); Text("System").tag("System") }
                if model.modifier == "⌘" && model.key == "Space" { Text("Spotlight may use this shortcut.").foregroundStyle(.secondary).font(.caption) }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            Section("Keylight") { HStack { Button("Refresh Apps") { model.refresh() }; Button("Quit Keylight") { NSApp.terminate(nil) } } }
            }
            if page == .apps {
            Section("App folders") {
                ForEach(model.folders, id: \.self) { path in HStack { Image(systemName:"folder"); Text(path.replacingOccurrences(of:NSHomeDirectory(), with:"~")).lineLimit(1).truncationMode(.middle); Spacer(); Button { model.folderJSON = model.encode(model.folders.filter { $0 != path }) } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless) } }
                Button("Add folder…", action: chooseFolder)
                if !model.unavailableFolders.isEmpty { Text("Some folders could not be read.").foregroundStyle(.orange).font(.caption) }
            }
            AppVisibilitySection(model: model, chooseExcluded: chooseExcluded)
            }
            if page == .aliases {
            Section("Search learning") {
                Text("Keylight learns from apps opened for each search. Learning stays on this Mac.").font(.caption).foregroundStyle(.secondary)
                if let error = model.learningError { Text(error).foregroundStyle(.red).font(.caption) }
                Button("Reset Search Learning…") { confirmResetLearning = true }
                    .accessibilityIdentifier("settings.resetSearchLearning")
                    .confirmationDialog("Reset Search Learning?", isPresented: $confirmResetLearning) {
                        Button("Reset", role: .destructive) { model.resetSearchLearning() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("Learned rankings will be removed. Aliases and other settings will stay unchanged.") }
            }
            Section("App aliases") {
                ForEach(model.aliases.keys.sorted(), id: \.self) { path in
                    ForEach(model.aliases[path] ?? [], id: \.self) { alias in
                        HStack { Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent); Text("→").foregroundStyle(.secondary); Text(alias); Spacer(); Button { model.changeAlias(path: path, alias: alias, add: false) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel(Text("Remove alias")) }
                    }
                }
                HStack {
                    Button(action: chooseAliasApp) { if aliasPath.isEmpty { Text("Choose App…") } else { Text(URL(fileURLWithPath: aliasPath).deletingPathExtension().lastPathComponent) } }
                    TextField("Alias", text: $aliasText)
                    Button("Add") { model.changeAlias(path: aliasPath, alias: aliasText, add: true); aliasText = "" }.disabled(aliasPath.isEmpty || aliasText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            }
            if page == .configuration {
            Section("Configuration") { HStack { Button("Import…", action: importSettings); Button("Export…", action: exportSettings) } }
            Section("Commands") { HStack { if model.scripts.isEmpty { Text("No folder selected") } else { Text(model.scripts.replacingOccurrences(of:NSHomeDirectory(), with:"~")).lineLimit(1) }; Spacer(); Button("Choose…", action: chooseScripts) } }
            }
          }.formStyle(.grouped)
        }
        .frame(minWidth: 650, minHeight: 480)
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var showSettings: (() -> Void)?
    var excludeSelected: ((UndoManager?) -> Void)?
    var refreshApps: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleEditingKey(event) { return }
        if event.type == .rightMouseDown, let editor = firstResponder as? NSTextView,
           editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) {
            let menu = NSMenu()
            for (title, action) in [("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))), ("Paste", #selector(NSText.paste(_:))), ("Select All", #selector(NSText.selectAll(_:)))] {
                let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: "")
                item.target = editor
                menu.addItem(item)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: editor)
            return
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleEditingKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    private func handleEditingKey(_ event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == ",", event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            showSettings?(); return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "q", event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            NSApp.terminate(nil); return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "r", event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            refreshApps?(); return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "m", event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            excludeSelected?(firstResponder?.undoManager); return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z", event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let manager = firstResponder?.undoManager, manager.canUndo {
            manager.undo(); return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let editor = firstResponder as? NSTextView {
            let action: Selector?
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            default: action = nil
            }
            if let action, editor.tryToPerform(action, with: nil) { return true }
        }
        return false
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model(); var eventHandler: EventHandlerRef?; var panel: NSPanel?; var settings: NSWindow?
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--preview-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let url = Bundle.main.url(forResource: "Doto", withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _,event,ctx in guard let event, let ctx else { return OSStatus(eventNotHandledErr) }; var id = EventHotKeyID(); let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id); guard result == noErr, id.signature == 0x4B4C4954, id.id == 1 else { return OSStatus(eventNotHandledErr) }; let app = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue(); DispatchQueue.main.async { app.toggle() }; return noErr }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if handlerStatus != noErr { model.error = "Shortcut event handler failed (\(handlerStatus))." }; model.registerHotKey(); model.refresh()
        if CommandLine.arguments.contains("--preview-search") { DispatchQueue.main.async { self.toggle() } }
        if CommandLine.arguments.contains("--preview-settings") { DispatchQueue.main.async { self.openSettings() } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if panel?.isVisible != true { toggle() }
        return false
    }
    @objc func openSearch() { toggle() }
    @objc func refreshApps() { model.refresh() }
    func toggle() {
        if let p = panel, p.isVisible {
            let wasKey = p.isKeyWindow
            p.orderOut(nil)
            if wasKey { return }
        }
        model.query = ""; model.selected = 0
        let content = SearchView(model: model, close: { [weak self] in self?.panel?.orderOut(nil) }, resize: { [weak self] count in self?.resizePanel(count) })
        let p = KeyPanel(contentRect: NSRect(x: 0,y: 0,width: 560,height: 440), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.refreshApps = { [weak self] in self?.model.refresh() }
        p.showSettings = { [weak self] in self?.panel?.orderOut(nil); self?.openSettings() }
        p.excludeSelected = { [weak self] manager in self?.model.excludeSelectedApp(undoManager: manager) }
        p.isFloatingPanel = true; p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.hidesOnDeactivate = !CommandLine.arguments.contains("--preview-fixed"); p.contentView = NSHostingView(rootView: content); p.center(); panel = p; NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil)
    }
    func resizePanel(_ count: Int) {
        guard let p = panel else { return }
        let height = CGFloat(90 + max(1, min(count, 7)) * 47)
        var frame = p.frame; frame.origin.y += frame.height - height; frame.size.height = height
        if abs(p.frame.height - height) > 1 { p.setFrame(frame, display: true) }
    }
    @objc func openSettings() {
        if settings == nil { let w = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:600), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered,defer:false); w.title = NSLocalizedString("Settings", comment: ""); w.isReleasedWhenClosed = false; w.contentView = NSHostingView(rootView: SettingsView(model:model)); w.center(); settings = w }
        NSApp.activate(ignoringOtherApps:true); settings?.makeKeyAndOrderFront(nil)
    }
}
#if !KEYLIGHT_FIXTURE
@main struct KeylightMain { @MainActor static func main() { let args = Array(CommandLine.arguments.dropFirst()); if let first = args.first, !first.hasPrefix("--preview-") && !first.hasPrefix("-psn_") { exit(CLI.run(args)) }; let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } } }

#endif

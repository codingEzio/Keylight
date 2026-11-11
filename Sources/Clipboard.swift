import AppKit
import SwiftUI
import Darwin

// A private directory of durable UTF-8 records. The cap includes the directory,
// every entry and interrupted temporary files using allocated or logical bytes,
// whichever is larger. Filesystem-internal metadata outside the directory is
// not exposed by macOS and cannot be counted here.
struct ClipboardEvictionError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

final class ClipboardStore: @unchecked Sendable {
    static let limit: Int64 = 2_000_000_000
    static let maxItemBytes = 16_000_000
    let directory: URL
    let limit: Int64
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Keylight/Clipboard", isDirectory: true), limit: Int64 = ClipboardStore.limit) { self.directory = directory; self.limit = limit }
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ConfigStore.requirePrivateDirectory(directory)
        let path = directory.appendingPathComponent(".clipboard.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ConfigError.io("Cannot open clipboard storage lock.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw ConfigError.io("Invalid clipboard storage lock.") }
        try ConfigStore.requireNoACL(fd)
        guard flock(fd, LOCK_EX) == 0 else { throw ConfigError.io("Cannot lock clipboard storage.") }
        return try body()
    }
    private func inventory() throws -> ([(URL, Int64)], Int64, Int64) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ConfigStore.requirePrivateDirectory(directory)
        var fs = statfs()
        guard statfs(directory.path, &fs) == 0 else { throw ConfigError.io("Cannot measure clipboard storage.") }
        let block = max(Int64(fs.f_bsize), 4096)
        func charge(_ url: URL, requireDirectory: Bool) throws -> Int64 {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
                  (info.st_mode & S_IFMT) == (requireDirectory ? S_IFDIR : S_IFREG), info.st_size >= 0, info.st_blocks >= 0 else {
                throw ConfigError.io("Cannot safely measure clipboard storage.")
            }
            return max(Int64(info.st_size), Int64(info.st_blocks) * 512)
        }
        var total = try charge(directory, requireDirectory: true)
        var entries: [(URL, Int64)] = []
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in urls {
            let bytes = try charge(url, requireDirectory: false)
            guard total <= Int64.max - bytes else { throw ConfigError.io("Clipboard storage size overflow.") }
            total += bytes
            // Only entries created by Keylight may be evicted or shown.
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-", maxSplits: 1)
            if url.pathExtension == "txt", parts.count == 2, parts[0].utf8.count == 20,
               parts[0].utf8.allSatisfy({ (48...57).contains($0) }), UUID(uuidString: String(parts[1])) != nil {
                entries.append((url, bytes))
            }
        }
        entries.sort { $0.0.lastPathComponent < $1.0.lastPathComponent }
        return (entries, total, block)
    }
    func save(_ text: String) throws -> Bool { try withLock { try saveUnlocked(text) } }
    private func saveUnlocked(_ text: String) throws -> Bool {
        guard text.utf8.count <= Self.maxItemBytes else { throw ConfigError.io(NSLocalizedString("Clipboard text exceeds 16 MB and was not saved.", comment: "")) }
        let data = Data(text.utf8)
        var (entries, used, block) = try inventory()
        guard limit > 0, block <= 1_048_576 else { throw ConfigError.io("Unsupported clipboard storage capacity.") }
        let charge = ((Int64(data.count) + block - 1) / block) * block
        // Reserve a block for directory growth and enough room for the next item.
        // The cap is enforced before the temporary file is created.
        let overhead = min(block * 16, limit / 4)
        let maxItemCharge = ((Int64(Self.maxItemBytes) + block - 1) / block) * block
        let maxNext = min(maxItemCharge + overhead, max(limit / 2, block * 2))
        let reserve = min(maxNext, limit / 2)
        guard charge + overhead <= limit else { throw ConfigError.io(NSLocalizedString("Clipboard storage is full; the item was not saved.", comment: "")) }
        var removed = false
        do {
        while used > limit - charge - overhead, !entries.isEmpty {
            let first = entries.removeFirst(); try FileManager.default.removeItem(at: first.0)
            (entries, used, _) = try inventory(); removed = true
        }
        guard used <= limit - charge - overhead else { throw ConfigError.io(NSLocalizedString("Clipboard storage is full; the item was not saved.", comment: "")) }
        let name = String(format: "%020llu", UInt64(Date().timeIntervalSince1970 * 1_000_000)) + "-" + UUID().uuidString + ".txt"
        let destination = directory.appendingPathComponent(name)
        try privateAtomicWrite(data, to: destination)
        var (afterEntries, after, _) = try inventory()
        // If the filesystem allocates unexpectedly more than estimated, reject
        // this new record rather than retain a directory above its stated cap.
        if after > limit {
            try FileManager.default.removeItem(at: destination)
            throw ConfigError.io(NSLocalizedString("Clipboard storage is full; the item was not saved.", comment: ""))
        }
        while after > limit - reserve, afterEntries.count > 1 {
            let first = afterEntries.removeFirst()
            guard first.0 != destination else { break }
            try FileManager.default.removeItem(at: first.0)
            after -= first.1; removed = true
        }
        return removed
        } catch {
            if removed { throw ClipboardEvictionError(underlying: error) }
            throw error
        }
    }
    func page(before: String? = nil) throws -> [(String, String)] { try withLock { try pageUnlocked(before: before) } }
    private func pageUnlocked(before: String?) throws -> [(String, String)] {
        let selected = try inventory().0.reversed().filter { before == nil || $0.0.lastPathComponent < before! }.prefix(100)
        return try selected.map { (url, _) in
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 1024) ?? Data()
            return (url.lastPathComponent, String(decoding: prefix, as: UTF8.self).replacingOccurrences(of: "\n", with: " "))
        }
    }
    func read(_ name: String) throws -> String {
        try withLock {
            guard !name.contains("/"), !name.hasPrefix("."), name.hasSuffix(".txt") else { throw ConfigError.invalid }
            let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw ConfigError.io("Cannot read clipboard history entry.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= Self.maxItemBytes else { throw ConfigError.io("Invalid clipboard history entry.") }
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else { throw ConfigError.io("Invalid clipboard history entry.") }
            return text
        }
    }
}

@MainActor final class ClipboardHistory: ObservableObject {
    struct Item: Identifiable { let id: String; let preview: String }
    @Published var items: [Item] = []
    @Published var error: String?
    @Published var limitNotice = false
    @Published private(set) var recording = false
    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private let queue = DispatchQueue(label: "com.alex.Keylight.clipboard", qos: .utility)
    private var timer: Timer?
    private var change: Int
    private var lastText: String?
    private var pendingCount = 0
    private var pendingBytes = 0
    private let maxPendingCount = 16
    private let maxPendingBytes = 64_000_000
    init(store: ClipboardStore = ClipboardStore(), pasteboard: NSPasteboard = .general) {
        self.store = store; self.pasteboard = pasteboard; self.change = pasteboard.changeCount
    }
    func start() {
        guard timer == nil else { return }
        // Do not capture a clipboard value copied before recording was enabled.
        change = pasteboard.changeCount; lastText = nil; recording = true
        limitNotice = UserDefaults.standard.bool(forKey: "clipboardLimitNotice")
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func poll() {
        guard recording else { return }
        let board = pasteboard
        guard board.changeCount != change else { return }
        let delta = board.changeCount - change
        change = board.changeCount
        if delta > 1 { error = NSLocalizedString("Some clipboard changes may have been missed before they could be read.", comment: "") }
        // Respect the conventional sensitive/transient pasteboard markers.
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !blocked.contains(where: { board.types?.contains(NSPasteboard.PasteboardType($0)) == true }),
              board.types?.contains(.fileURL) != true, board.types?.contains(.png) != true, board.types?.contains(.tiff) != true,
              let text = board.string(forType: .string), !text.isEmpty, text != lastText else { return }
        let bytes = text.utf8.count
        guard bytes <= ClipboardStore.maxItemBytes else { error = NSLocalizedString("Clipboard text exceeds 16 MB and was not saved.", comment: ""); return }
        guard pendingCount < maxPendingCount, pendingBytes <= maxPendingBytes - bytes else {
            error = NSLocalizedString("Clipboard history queue is full; an item was not saved.", comment: ""); return
        }
        pendingCount += 1; pendingBytes += bytes; lastText = text
        queue.async { [store] in
            let result = Result { try store.save(text) }
            DispatchQueue.main.async {
                self.pendingCount -= 1; self.pendingBytes -= bytes
                switch result { case .success(let removed): if removed { self.limitNotice = true; UserDefaults.standard.set(true, forKey: "clipboardLimitNotice") }; case .failure(let failure):
                    if failure is ClipboardEvictionError { self.limitNotice = true; UserDefaults.standard.set(true, forKey: "clipboardLimitNotice") }
                    self.lastText = nil; self.error = failure.localizedDescription }
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; recording = false }
    func finish() {
        stop()
        // Drain already accepted records before the process exits.
        queue.sync {}
    }
    func dismissNotice() { limitNotice = false; UserDefaults.standard.set(false, forKey: "clipboardLimitNotice") }
    func load(more: Bool = false) {
        let before = more ? items.last?.id : nil
        queue.async { [store] in
            let result = Result { try store.page(before: before) }
            DispatchQueue.main.async {
                switch result { case .success(let rows): let values = rows.map { Item(id: $0.0, preview: $0.1) }; self.items = more ? self.items + values : values
                case .failure(let failure): self.error = failure.localizedDescription }
            }
        }
    }
    func copy(_ item: Item, completion: @escaping () -> Void) {
        queue.async { [store] in
            let result = Result { try store.read(item.id) }
            DispatchQueue.main.async {
                switch result { case .success(let text): let board = self.pasteboard; board.clearContents(); guard board.setString(text, forType: .string) else { self.error = NSLocalizedString("Could not copy to the clipboard.", comment: ""); return }; self.change = board.changeCount; self.lastText = text; completion()
                case .failure(let failure): self.error = failure.localizedDescription }
            }
        }
    }
}

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    let appearance: LauncherAppearance
    let back: () -> Void
    let close: () -> Void
    @State private var selected = 0
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            LauncherHeader(appearance: appearance, showSearchIcon: false) { HStack { Button(action: back) { Image(systemName: "chevron.left").font(.system(size: 15, weight: .medium)) }.buttonStyle(.plain).accessibilityLabel(Text("Back to search")); Text("Clipboard History").font(appearance.rowFont); Spacer(); Text("↵ Copy · ⌘V Paste").font(.caption).foregroundStyle(.secondary) } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !history.recording { Text("Clipboard recording is off. Enable it in Settings.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
                        if let error = history.error { Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
                        if history.items.isEmpty { Text("No clipboard history").foregroundStyle(.secondary).padding() }
                        ForEach(Array(history.items.enumerated()), id: \.element.id) { index, item in
                            Button { history.copy(item, completion: close) } label: {
                                Text(item.preview).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(index == selected ? appearance.selection : .clear).clipShape(RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
                            }.buttonStyle(.plain).id(item.id)
                        }
                        if history.items.count >= 100 { Button("Load more") { history.load(more: true) }.padding(8) }
                    }.padding(8)
                }.frame(height: LauncherAppearance.resultsHeight).onChange(of: selected) { _, value in if history.items.indices.contains(value) { proxy.scrollTo(history.items[value].id) } }
            }
        }.focusable().focusEffectDisabled().focused($focused).onAppear { history.load(); DispatchQueue.main.async { focused = true } }
            .onKeyPress(.escape) { back(); return .handled }
            .onKeyPress(.downArrow) { if selected == history.items.count - 1 && history.items.count >= 100 { history.load(more: true) }; selected = min(selected + 1, max(0, history.items.count - 1)); return .handled }
            .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            .onKeyPress(.return) { if history.items.indices.contains(selected) { history.copy(history.items[selected], completion: close) }; return .handled }
    }
}

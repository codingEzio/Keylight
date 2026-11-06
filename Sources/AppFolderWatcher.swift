import CoreServices
import Foundation

// Watches configured trees without polling. FSEvents may coalesce changes;
// each notification schedules one complete background refresh.
final class AppFolderWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let onChange: (Bool) -> Void
    private var needsRewatch = false
    private var targets: [String] = []

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    deinit { stop() }

    @discardableResult func watch(_ folders: [String]) -> Bool {
        stop()
        targets = folders.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        guard !targets.isEmpty else { return true }
        let roots = Set(targets.map { path -> String in
            var url = URL(fileURLWithPath: path, isDirectory: true)
            var directory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) || !directory.boolValue {
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { break }
                url = parent
            }
            return url.path
        })
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<AppFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changes = unsafeBitCast(paths, to: NSArray.self)
            for index in 0..<count {
                guard let rawPath = changes[index] as? String else { continue }
                let path = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL.path
                let event = flags[index]
                let rootChanged = (event & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0
                let dropped = (event & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)) != 0
                if rootChanged || dropped || watcher.targets.contains(where: { target in
                    path == target || target == "/" || path == "/" || path.hasPrefix(target + "/") || target.hasPrefix(path + "/")
                }) {
                    watcher.scheduleRefresh(rewatch: rootChanged)
                }
            }
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, Array(roots) as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)) else { return false }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else { stop(); return false }
        return true
    }

    private func scheduleRefresh(rewatch: Bool) {
        needsRewatch = needsRewatch || rewatch
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let rewatch = self.needsRewatch
            self.needsRewatch = false
            self.onChange(rewatch)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func stop() {
        pending?.cancel(); pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

import AppKit
import SwiftUI
import Combine

@MainActor final class RequestModel: ObservableObject {
    @Published private(set) var settings = RequestSettings()
    @Published private(set) var snapshot: ProjectSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published var catalogError: String?
    @Published var error: String?
    @Published var text = ""
    @Published var selectedProject: LocalProject?
    @Published var choosingProject = false
    @Published var browsingRequests = false
    @Published private(set) var poolEntries: [QueuedRequest] = []
    @Published private(set) var poolLoading = false
    @Published private(set) var poolError: String?
    @Published private(set) var selectedEntry: QueuedRequest?
    @Published private(set) var selectedRequest: DevelopmentRequest?
    @Published var receipt: RequestReceipt?
    @Published private(set) var chatURL: URL?
    @Published private(set) var delivery = "Saved locally"
    private var pending: DevelopmentRequest?
    private var pendingReceipt: RequestReceipt?
    private var unreadDraft = false
    private struct Draft: Codable {
        let text: String?; let project: LocalProject?; let pending: DevelopmentRequest?; let receipt: RequestReceipt?
        var entry: QueuedRequest?; var base: DevelopmentRequest?
    }
    private var draftURL: URL { ConfigStore.file.appendingPathExtension("request-draft.json") }

    init() {
        do {
            settings = try ConfigStore.read().requests
        } catch { self.error = NSLocalizedString(error.localizedDescription, comment: "") }
        do { snapshot = try ProjectCatalog.load(source: settings.catalogURL) }
        catch { catalogError = NSLocalizedString(error.localizedDescription, comment: "") }
        do {
            if FileManager.default.fileExists(atPath: draftURL.path) {
                let data = try Data(contentsOf: draftURL)
                // JSON can escape one byte into six; the request body is stored only once.
                guard data.count <= 12_200_000 else { throw ConfigError.invalid }
                let draft = try JSONDecoder().decode(Draft.self, from: data)
                text = draft.text ?? draft.pending?.text ?? ""; selectedProject = draft.project; pending = draft.pending; pendingReceipt = draft.receipt
                selectedEntry = draft.entry; selectedRequest = draft.base
            }
        } catch { unreadDraft = true; self.error = NSLocalizedString("The existing draft could not be read and has been preserved.", comment: "") }
    }
    func apply(_ value: RequestSettings) {
        guard settings != value else { return }
        let changedSource = settings.catalogURL != value.catalogURL
        if settings.queueFolder != value.queueFolder { poolEntries = []; poolError = nil }
        settings = value
        if changedSource {
            snapshot = nil
            do { snapshot = try ProjectCatalog.load(source: value.catalogURL) } catch { catalogError = NSLocalizedString(error.localizedDescription, comment: "") }
        }
    }
    func saveSettings(_ value: RequestSettings) -> Bool {
        do { try value.validate(); try ConfigStore.update { $0.requests = value }; apply(value); error = nil; return true }
        catch { self.error = NSLocalizedString(error.localizedDescription, comment: ""); return false }
    }
    var projects: [LocalProject] { ProjectCatalog.localProjects(snapshot, settings: settings) }
    var queuedRequests: [QueuedRequest] {
        guard let project = selectedProject else { return [] }
        return poolEntries.filter { $0.projectID == project.project.id && $0.projectPath == project.path }
    }
    func queuedCount(_ project: LocalProject) -> Int { poolEntries.filter { $0.projectID == project.project.id && $0.projectPath == project.path }.count }
    func refreshPool() async {
        guard !poolLoading else { return }
        guard !settings.queueFolder.isEmpty else { poolEntries = []; poolError = NSLocalizedString("Choose a request folder in Settings.", comment: ""); return }
        poolLoading = true; defer { poolLoading = false }
        let folder = settings.queueFolder
        do {
            let value = try await Task.detached(priority: .utility) { try RequestPool.scan(folder: folder) }.value
            guard settings.queueFolder == folder else { return }
            poolEntries = value.entries
            poolError = value.unreadable.isEmpty ? nil : NSLocalizedString("Some requests could not be read. Original files are preserved.", comment: "") + " " + value.unreadable.joined(separator: ", ")
        } catch { if settings.queueFolder == folder { poolError = NSLocalizedString(error.localizedDescription, comment: "") } }
    }
    func chooseProject(_ project: LocalProject, command: String) {
        guard !saving, project.path != nil else { return }
        if selectedProject?.id != project.id { selectedEntry = nil; selectedRequest = nil; pendingReceipt = nil; pending = nil }
        selectedProject = project; choosingProject = false
        browsingRequests = command == "add" && selectedEntry == nil && text.isEmpty
        error = nil; persistDraft()
    }
    func chooseRequest(_ entry: QueuedRequest) async {
        guard !saving else { return }
        saving = true; defer { saving = false }
        let folder = settings.queueFolder
        do {
            let request = try await Task.detached(priority: .userInitiated) { try RequestPool.load(entry, folder: folder) }.value
            guard settings.queueFolder == folder, selectedProject?.project.id == request.projectID, selectedProject?.path == request.projectPath else { throw ConfigError.io("Project checkout is unavailable or outside the selected scope.") }
            if pending?.id == request.id, pending?.text == text { text = "" }
            selectedEntry = entry; selectedRequest = request; pending = nil; pendingReceipt = nil
            receipt = nil; chatURL = nil; browsingRequests = false; error = nil; persistDraft()
            if let state = try ChatLaunchSession.readState(entry.receipt), state.phase != .prepared {
                pendingReceipt = entry.receipt; receipt = entry.receipt; chatURL = state.url
                delivery = state.phase == .sent ? "Sent to ChatGPT" : "Sending could not be confirmed. Open the chat before sending again."
                persistDraft()
            }
        } catch { self.error = NSLocalizedString(error.localizedDescription, comment: "") }
    }
    func showRequests() {
        guard !saving else { return }
        receipt = nil; chatURL = nil; browsingRequests = true; choosingProject = selectedProject == nil
        persistDraft()
    }
    func composeNew() {
        guard !saving else { return }
        selectedEntry = nil; selectedRequest = nil; pendingReceipt = nil; pending = nil; receipt = nil; chatURL = nil
        browsingRequests = false; choosingProject = selectedProject == nil; error = nil; persistDraft()
    }
    func refresh() async {
        guard !loading, !settings.catalogURL.isEmpty else { return }
        loading = true; defer { loading = false }
        let source = settings.catalogURL
        do {
            let fetched = try await ProjectCatalog.fetch(source: source)
            try await Task.detached(priority: .utility) { try ProjectCatalog.save(fetched) }.value
            guard settings.catalogURL == source else { return }
            snapshot = fetched; catalogError = nil
        } catch { if settings.catalogURL == source { catalogError = NSLocalizedString(error.localizedDescription, comment: "") } }
    }
    func activate(_ command: String) {
        receipt = nil; error = nil; chatURL = nil; delivery = "Saved locally"
        choosingProject = selectedProject == nil || text.isEmpty
        browsingRequests = false
        if let pendingReceipt {
            do {
                if let state = try ChatLaunchSession.readState(pendingReceipt), state.phase != .prepared {
                    receipt = pendingReceipt; chatURL = state.url
                    delivery = state.phase == .sent ? "Sent to ChatGPT" : "Sending could not be confirmed. Open the chat before sending again."
                    if state.phase == .sent { clearDraft(keepingProject: command == "add") }
                    return
                }
            } catch { self.error = NSLocalizedString(error.localizedDescription, comment: "") }
        }
        if command == "proj", selectedEntry != nil { selectedEntry = nil; selectedRequest = nil; pendingReceipt = nil }
    }
    func persistDraft() {
        do { try writeDraft() } catch { self.error = NSLocalizedString(error.localizedDescription, comment: "") }
    }
    private func writeDraft() throws {
        guard !unreadDraft else { throw ConfigError.io(NSLocalizedString("The existing draft could not be read and has been preserved.", comment: "")) }
        let storedProject = selectedProject.map { project in
            LocalProject(project: CatalogProject(id: project.project.id, name: project.project.name, summary: "", category: project.project.category, paths: project.path.map { [$0] } ?? []), path: project.path)
        }
        let storedPending = selectedEntry == nil && pending?.text == text ? pending : nil
        let data = try JSONEncoder().encode(Draft(text: storedPending == nil ? text : nil, project: storedProject, pending: storedPending, receipt: storedPending == nil && selectedEntry == nil ? nil : pendingReceipt, entry: selectedEntry, base: selectedRequest))
        try ConfigStore.withLock { try privateAtomicWrite(data, to: draftURL) }
    }
    private func clearDraft(keepingProject: Bool = false) {
        text = ""; pending = nil; pendingReceipt = nil; selectedEntry = nil; selectedRequest = nil
        if !keepingProject { selectedProject = nil }
        persistDraft()
    }
    func startNew() {
        guard !saving else { return }
        error = nil; clearDraft()
        receipt = nil; chatURL = nil; delivery = "Saved locally"; choosingProject = true
    }
    private func openChat(_ url: URL, app: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func reopenChat() {
        guard let chatURL else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { error = NSLocalizedString("Install ChatGPT to start this chat. The request is saved locally.", comment: ""); return }
        Task { do { try await openChat(chatURL, app: app) } catch { self.error = error.localizedDescription } }
    }
    func submit(command: String = "add", consume: Bool = false) async {
        guard !saving else { return }
        do {
            if let pendingReceipt, let state = try ChatLaunchSession.readState(pendingReceipt), state.phase != .prepared {
                activate(command); return
            }
            guard let project = selectedProject,
                  projects.contains(where: { $0.id == project.id && $0.path == project.path && $0.path != nil }) else { throw ConfigError.io(NSLocalizedString("Project checkout is unavailable or outside the selected scope.", comment: "")) }
            let request: DevelopmentRequest
            if let selectedRequest, selectedEntry != nil {
                guard selectedRequest.projectID == project.project.id, selectedRequest.projectPath == project.path else { throw ConfigError.io("Project checkout is unavailable or outside the selected scope.") }
                request = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && consume ? selectedRequest : try selectedRequest.appending(text)
            } else if let pending, pending.text == text, pending.projectID == selectedProject?.project.id, pending.projectPath == selectedProject?.path, pending.model == settings.model, pending.reasoningEffort == settings.reasoningEffort, (pending.permissionsProfile ?? "Development") == settings.permissionsProfile { request = pending }
            else { request = try DevelopmentRequest(text: text, project: selectedProject, settings: settings); pending = request; pendingReceipt = nil }
            try writeDraft()
            saving = true; defer { saving = false }
            let folder = settings.queueFolder
            let result: RequestReceipt
            if let selectedEntry, let original = selectedRequest {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result = selectedEntry.receipt }
                else {
                    let addition = text
                    let saved = try await Task.detached(priority: .userInitiated) { try RequestPool.append(addition, to: original, entry: selectedEntry, folder: folder) }.value
                    result = saved.1; selectedRequest = saved.0; text = ""
                }
                pendingReceipt = result; try writeDraft()
            } else if let pendingReceipt { result = pendingReceipt }
            else {
                result = try await Task.detached(priority: .userInitiated) { try command == "add" ? RequestPool.save(request, folder: folder) : RequestQueue.save(request, folder: folder) }.value
                pendingReceipt = result; try writeDraft()
            }
            if command == "proj" || consume {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { throw ConfigError.io("Install ChatGPT to start this chat. The request is saved locally.") }
                let executable = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
                let session = try await Task.detached(priority: .userInitiated) { try ChatLaunchSession(request: request, receipt: result, executable: executable, socketPath: codexHome + "/ipc/ipc.sock") }.value
                chatURL = session.state.url
                try await openChat(session.state.url, app: app)
                _ = try await Task.detached(priority: .userInitiated) { try session.send() }.value
                delivery = "Sent to ChatGPT"
            } else { delivery = "Saved locally" }
            receipt = result; error = nil; clearDraft(keepingProject: command == "add")
            await refreshPool()
        } catch {
            self.error = NSLocalizedString(error.localizedDescription, comment: "")
            if let pendingReceipt, let state = try? ChatLaunchSession.readState(pendingReceipt), state.phase == .dispatching {
                receipt = pendingReceipt; chatURL = state.url; delivery = "Sending could not be confirmed. Open the chat before sending again."
            }
        }
    }
}

func projectCategoryName(_ value: String) -> String {
    switch value {
    case "joboss": return "JobOSS"
    case "oss": return "OSS"
    case "private": return NSLocalizedString("Private", comment: "")
    case "privateoss": return NSLocalizedString("Private OSS", comment: "")
    case "abandoned": return NSLocalizedString("Abandoned", comment: "")
    default: return NSLocalizedString("Unclassified", comment: "")
    }
}
func requestEffortName(_ value: String) -> String {
    NSLocalizedString(value.prefix(1).uppercased() + value.dropFirst(), comment: "")
}

struct RequestComposerView: View {
    @ObservedObject var model: RequestModel
    let command: String
    let appearance: LauncherAppearance
    let back: () -> Void
    let close: () -> Void
    let setBackspace: ((() -> Bool)?) -> Void
    @State private var filter = ""
    @State private var index = 0
    private enum Field: Hashable { case project, request }
    @FocusState private var focus: Field?
    var results: [LocalProject] { ProjectCatalog.localProjects(model.snapshot, settings: model.settings, query: filter) }
    private var requestResults: [QueuedRequest] { model.queuedRequests.filter { filter.isEmpty || $0.title.localizedStandardContains(filter) || URL(fileURLWithPath: $0.file).lastPathComponent.localizedStandardContains(filter) } }
    private var picking: Bool { model.choosingProject || model.browsingRequests }
    private var chipFill: Color { appearance.xp ? appearance.headerForeground.opacity(0.14) : appearance.selection }
    private var selectable: [Int] { model.browsingRequests && !model.choosingProject ? Array(0...requestResults.count) : results.indices.filter { results[$0].path != nil } }
    private func move(_ direction: Int) {
        let choices = selectable
        if let next = direction > 0 ? choices.first(where: { $0 > index }) : choices.last(where: { $0 < index }) { index = next }
    }
    private func pick(_ project: LocalProject) {
        model.chooseProject(project, command: command); filter = ""; index = 0
    }
    private func pickRequest(_ position: Int) {
        if position == 0 { model.composeNew() }
        else if requestResults.indices.contains(position - 1) {
            let entry = requestResults[position - 1]
            Task { await model.chooseRequest(entry) }
        }
    }
    private func goBack() {
        if model.saving { return }
        if model.browsingRequests { model.browsingRequests = false; model.choosingProject = true; filter = "" }
        else if !model.choosingProject && command == "add", model.selectedProject != nil { model.showRequests(); filter = ""; Task { await model.refreshPool() } }
        else if !model.choosingProject && model.receipt == nil { model.choosingProject = true; filter = "" }
        else { model.persistDraft(); back() }
    }
    private var header: some View {
        LauncherHeader(appearance: appearance) {
            Button(action: { model.persistDraft(); back() }) {
                Text(command.uppercased()).font(.system(size: 14, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(chipFill, in: RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
            }.buttonStyle(.plain).foregroundStyle(appearance.xp ? appearance.headerForeground : appearance.accent)
                .frame(minHeight: 44).accessibilityLabel(Text("Back to search"))
            if let project = model.selectedProject, !model.choosingProject {
                Button { model.choosingProject = true; model.browsingRequests = false; filter = "" } label: {
                    Text(project.project.name).font(appearance.rowFont).lineLimit(1)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(chipFill, in: RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
                }.buttonStyle(.plain).frame(maxWidth: 160, minHeight: 44).accessibilityLabel(Text("Choose another project"))
            }
            if picking {
                TextField(LocalizedStringKey(model.choosingProject ? "Find projects" : "Find requests"), text: $filter, prompt: Text(LocalizedStringKey(model.choosingProject ? "Find projects" : "Find requests")).font(appearance.placeholderFont).foregroundColor(appearance.placeholderColor)).textFieldStyle(.plain).focused($focus, equals: .project)
                    .accessibilityIdentifier("requests.projectSearch")
                    .onChange(of: filter) { _, _ in index = selectable.first ?? 0 }
            } else { Spacer(minLength: 0) }
            if model.loading || model.saving || model.poolLoading { ProgressView().controlSize(.small) }
        }.disabled(model.saving)
    }
    private var projectResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if results.isEmpty {
                        Text(LocalizedStringKey(model.settings.catalogURL.isEmpty || model.settings.projectRoot.isEmpty ? "Set a project source and root in Settings." : model.loading ? "Loading projects…" : "No projects in this scope")).foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, project in
                        Button { pick(project) } label: {
                            HStack(spacing: 12) {
                                if appearance.nothing { Circle().fill(i == index ? appearance.accent : .clear).frame(width: 6, height: 6) }
                                Image(systemName: model.settings.pinnedProjects.contains(project.project.id) ? "pin.fill" : "folder").font(.system(size: 22)).frame(width: 29)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.project.name).font(appearance.rowFont).lineLimit(1)
                                    Text(project.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? NSLocalizedString("No checkout in project root", comment: "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if command == "add", model.queuedCount(project) > 0 { Text(model.queuedCount(project), format: .number).font(.caption.monospacedDigit()).foregroundStyle(appearance.accent) }
                                Text(projectCategoryName(project.project.category)).font(.caption2).foregroundStyle(.secondary)
                                if i == index && project.path != nil { Text("↵").foregroundStyle(appearance.nothing ? appearance.accent : appearance.rowForeground) }
                            }.foregroundStyle(appearance.rowForeground).padding(.horizontal, 12).frame(height: 45).frame(maxWidth: .infinity, alignment: .leading)
                                .background(i == index ? appearance.selection : .clear, in: RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
                        }.buttonStyle(.plain).disabled(project.path == nil).id(project.id).help(project.path ?? NSLocalizedString("No checkout in project root", comment: ""))
                    }
                }.padding(8)
            }.frame(maxHeight: .infinity)
                .onChange(of: index) { _, value in if results.indices.contains(value) { proxy.scrollTo(results[value].id, anchor: .center) } }
        }
    }
    private var queuedResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    Button { pickRequest(0) } label: {
                        Label("New request", systemImage: "plus").font(appearance.rowFont).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 45)
                            .background(index == 0 ? appearance.selection : .clear, in: RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
                    }.buttonStyle(.plain).accessibilityIdentifier("requests.new").id(0)
                    ForEach(Array(requestResults.enumerated()), id: \.element.file) { i, entry in
                        Button { pickRequest(i + 1) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.unconfirmed ? "questionmark.circle" : "doc.text").frame(width: 25)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title.isEmpty ? URL(fileURLWithPath: entry.file).lastPathComponent : entry.title).font(appearance.rowFont).lineLimit(1)
                                    Text(URL(fileURLWithPath: entry.file).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.foregroundStyle(appearance.rowForeground).padding(.horizontal, 12).frame(height: 49).frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == i + 1 ? appearance.selection : .clear, in: RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
                        }.buttonStyle(.plain).id(i + 1).accessibilityIdentifier("requests.queued.\(i)")
                    }
                    if requestResults.isEmpty {
                        Text(LocalizedStringKey(model.poolLoading ? "Loading requests…" : model.poolError != nil ? "Requests unavailable" : filter.isEmpty ? "No pending requests" : "No matching requests")).font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }.padding(8)
            }.onChange(of: index) { _, value in proxy.scrollTo(value, anchor: .center) }
        }.frame(maxHeight: .infinity)
    }
    private var resultContent: some View {
        VStack(spacing: 0) {
            if let receipt = model.receipt {
                VStack(alignment: .leading, spacing: 10) {
                    Label(LocalizedStringKey(model.delivery), systemImage: model.delivery == "Saved locally" || model.delivery == "Sent to ChatGPT" ? "checkmark.circle" : "questionmark.circle").font(appearance.rowFont)
                    Text(receipt.file.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if model.chatURL != nil { Button("Open chat") { model.reopenChat() } }
                        Button("Reveal request") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.file)]) }
                        if command == "add" {
                            Button("Requests") { model.showRequests(); filter = ""; index = 0; Task { await model.refreshPool() } }.keyboardShortcut(.return, modifiers: [])
                            Button("Done", action: close)
                        } else {
                            Button("New request") { model.startNew(); filter = ""; index = selectable.first ?? 0 }
                            Button("Done", action: close).keyboardShortcut(.return, modifiers: [])
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Spacer(minLength: 0)
            } else if model.choosingProject {
                projectResults
            } else if model.browsingRequests {
                queuedResults
            } else {
                if let existing = model.selectedRequest {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(existing.text.prefix(8000))).font(appearance.rowFont).textSelection(.enabled)
                            if existing.text.count > 8000 {
                                Text("Preview truncated. The full request is saved.").font(.caption).foregroundStyle(.secondary)
                                if let entry = model.selectedEntry { Button("Reveal request") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.file)]) } }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
                    }.padding(.top, 10).frame(maxHeight: .infinity)
                    Divider().padding(.horizontal, 18)
                }
                TextField(LocalizedStringKey(model.selectedEntry == nil ? "What would you like to change?" : "Append more details"), text: $model.text, prompt: Text(LocalizedStringKey(model.selectedEntry == nil ? "What would you like to change?" : "Append more details")).font(appearance.placeholderFont).foregroundColor(appearance.foreground.opacity(0.55)), axis: .vertical)
                    .textFieldStyle(.plain).font(appearance.inputFont).lineLimit(model.selectedEntry == nil ? 3...7 : 1...3)
                    .focused($focus, equals: .request).padding(.horizontal, 18).padding(.top, 10)
                    .accessibilityIdentifier("requests.text").disabled(model.saving)
                if model.selectedEntry == nil { Spacer(minLength: 0) }
                HStack {
                    Text(model.selectedRequest.map { $0.permissionsProfile ?? "Development" } ?? model.settings.permissionsProfile).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text((model.selectedRequest?.model ?? model.settings.model) + " · " + requestEffortName(model.selectedRequest?.reasoningEffort ?? model.settings.reasoningEffort)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
            if command == "add", picking, let error = model.poolError {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if model.choosingProject {
                if let error = model.catalogError {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(model.snapshot == nil ? "Project source unavailable." : "Using cached projects."))
                        Text(error).lineLimit(2).help(error)
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
                }
                HStack {
                    if let snapshot = model.snapshot { Text(snapshot.fetchedAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(); Button("Refresh Projects") { Task { await model.refresh() } }.disabled(model.loading)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Text(LocalizedStringKey(model.receipt != nil ? (command == "add" ? "Return Requests" : "Esc Back") : picking ? "↑ ↓ Select · Return Choose" : model.selectedEntry == nil ? "Shift Return New line" : "Return Append · ⌘ Return Start chat")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.browsingRequests && !model.choosingProject {
                    Button("Refresh requests") { Task { await model.refreshPool() } }.disabled(model.poolLoading).accessibilityIdentifier("requests.refreshPool")
                } else if !model.choosingProject && model.receipt == nil {
                    if model.selectedEntry != nil {
                        Button("Start chat") { Task { await model.submit(command: command, consume: true) } }.disabled(model.saving).accessibilityIdentifier("requests.consume")
                    }
                    Button(LocalizedStringKey(command == "proj" ? "Start chat" : model.selectedEntry == nil ? "Save request" : "Append")) { Task { await model.submit(command: command) } }.buttonStyle(.borderedProminent)
                        .disabled(model.saving || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("requests.save")
                } else { Text("Esc Back").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).frame(height: 44)
        }.frame(height: LauncherAppearance.resultsHeight, alignment: .top)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            resultContent
        }
            .onAppear {
                model.activate(command); index = selectable.first ?? 0
                setBackspace {
                    guard !model.saving, model.receipt == nil,
                          picking ? filter.isEmpty : model.text.isEmpty else { return false }
                    goBack(); return true
                }
                // The old search field resigns during the view swap. Focus after it is detached.
                DispatchQueue.main.async { focus = picking ? .project : .request }
            }
            .task { await model.refreshPool(); await model.refresh() }
            .onDisappear { setBackspace(nil); model.persistDraft() }
            .onChange(of: model.choosingProject) { _, choosing in
                index = selectable.first ?? 0
                DispatchQueue.main.async { focus = picking ? .project : .request }
            }
            .onChange(of: model.browsingRequests) { _, _ in
                index = selectable.first ?? 0
                DispatchQueue.main.async { focus = picking ? .project : .request }
            }
            .onChange(of: model.poolEntries.count) { _, _ in index = selectable.first ?? 0 }
            .onChange(of: model.settings.queueFolder) { _, _ in Task { await model.refreshPool() } }
            .onChange(of: model.snapshot?.fetchedAt) { _, _ in index = selectable.first ?? 0 }
            .onKeyPress(.escape) { goBack(); return .handled }
            .onKeyPress(.downArrow) { guard picking else { return .ignored }; move(1); return .handled }
            .onKeyPress(.upArrow) { guard picking else { return .ignored }; move(-1); return .handled }
            .onKeyPress(keys: [.return], phases: .down) { press in
                if model.saving { return .handled }
                let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                if editor?.hasMarkedText() == true { return .ignored }
                if press.modifiers.contains(.shift) {
                    guard !picking, model.receipt == nil, focus == .request, let editor, editor.isEditable else { return .ignored }
                    // NSTextField otherwise commits/selects all on Shift Return.
                    editor.insertText("\n", replacementRange: editor.selectedRange())
                    model.text = editor.string
                    return .handled
                }
                if model.receipt != nil { if command == "add", model.selectedProject != nil { goBack() } else { close() } }
                else if model.choosingProject { if results.indices.contains(index) { pick(results[index]) } }
                else if model.browsingRequests { pickRequest(index) }
                else if press.modifiers.contains(.command), model.selectedEntry != nil { Task { await model.submit(command: command, consume: true) } }
                else if !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Task { await model.submit(command: command) } }
                return .handled
            }
    }
}

struct RequestSettingsView: View {
    @ObservedObject var model: RequestModel
    @State private var value = RequestSettings()
    @State private var find = ""
    @State private var saved = false
    private func choose(_ key: WritableKeyPath<RequestSettings, String>) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { value[keyPath: key] = url.path; saved = false }
    }
    var body: some View {
      Group {
        Section("Request queue") {
            HStack { Text("Request folder"); Spacer(); Text(value.queueFolder.isEmpty ? NSLocalizedString("Not configured", comment: "") : value.queueFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle); Button("Choose…") { choose(\.queueFolder) } }
            TextField("Default model", text: $value.model).accessibilityIdentifier("requests.model")
            Picker("Reasoning effort", selection: $value.reasoningEffort) { ForEach(RequestSettings.effortOptions, id: \.self) { Text(requestEffortName($0)).tag($0) } }
            TextField("Permission preset", text: $value.permissionsProfile).accessibilityIdentifier("requests.permissions")
            Text("ADD saves locally. PROJ starts a ChatGPT chat with these presets.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Projects") {
            HStack { Text("Project root"); Spacer(); Text(value.projectRoot.isEmpty ? NSLocalizedString("Not configured", comment: "") : value.projectRoot.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle); Button("Choose…") { choose(\.projectRoot) } }
            TextField("Godspeed Projects URL", text: $value.catalogURL).accessibilityIdentifier("requests.source")
            ForEach(RequestSettings.categoryOptions, id: \.self) { category in
                Toggle(projectCategoryName(category), isOn: Binding(get: { value.categories.contains(category) }, set: { enabled in if enabled { value.categories.append(category) } else { value.categories.removeAll { $0 == category } }; saved = false }))
            }
        }
        Section("Pinned projects") {
            TextField("Find projects", text: $find).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(ProjectCatalog.localProjects(model.snapshot, settings: value, query: find)) { project in
                        HStack {
                            Toggle(project.project.name, isOn: Binding(get: { value.pinnedProjects.contains(project.project.id) }, set: { pin in value.pinnedProjects.removeAll { $0 == project.project.id }; if pin { value.pinnedProjects.append(project.project.id) }; saved = false }))
                            Spacer()
                            if let index = value.pinnedProjects.firstIndex(of: project.project.id), index > 0 {
                                Button { value.pinnedProjects.swapAt(index, index - 1); saved = false } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).accessibilityLabel(Text("Move pin up"))
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(height: 145)
        }
        Section {
            HStack {
                Button("Apply") { saved = model.saveSettings(value); if saved { Task { await model.refresh() } } }.accessibilityIdentifier("requests.apply")
                Button("Refresh Projects") { Task { await model.refresh() } }.disabled(model.loading)
                if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary) }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            if let error = model.catalogError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
      }
        .onAppear { value = model.settings }
    }
}

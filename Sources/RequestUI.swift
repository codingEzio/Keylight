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
    @Published var receipt: RequestReceipt?
    @Published private(set) var chatURL: URL?
    @Published private(set) var delivery = "Saved locally"
    private var pending: DevelopmentRequest?
    private var pendingReceipt: RequestReceipt?
    private var unreadDraft = false
    private struct Draft: Codable { let text: String?; let project: LocalProject?; let pending: DevelopmentRequest?; let receipt: RequestReceipt? }
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
                guard data.count <= 6_100_000 else { throw ConfigError.invalid }
                let draft = try JSONDecoder().decode(Draft.self, from: data)
                text = draft.text ?? draft.pending?.text ?? ""; selectedProject = draft.project; pending = draft.pending; pendingReceipt = draft.receipt
            }
        } catch { unreadDraft = true; self.error = NSLocalizedString("The existing draft could not be read and has been preserved.", comment: "") }
    }
    func apply(_ value: RequestSettings) {
        guard settings != value else { return }
        let changedSource = settings.catalogURL != value.catalogURL
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
        if let pendingReceipt {
            do {
                if let state = try ChatLaunchSession.readState(pendingReceipt), state.phase != .prepared {
                    receipt = pendingReceipt; chatURL = state.url
                    delivery = state.phase == .sent ? "Sent to ChatGPT" : "Sending could not be confirmed. Open the chat before sending again."
                    if state.phase == .sent { clearDraft() }
                }
            } catch { self.error = NSLocalizedString(error.localizedDescription, comment: "") }
        }
    }
    func persistDraft() {
        do { try writeDraft() } catch { self.error = NSLocalizedString(error.localizedDescription, comment: "") }
    }
    private func writeDraft() throws {
        guard !unreadDraft else { throw ConfigError.io(NSLocalizedString("The existing draft could not be read and has been preserved.", comment: "")) }
        let storedProject = selectedProject.map { project in
            LocalProject(project: CatalogProject(id: project.project.id, name: project.project.name, summary: "", category: project.project.category, paths: project.path.map { [$0] } ?? []), path: project.path)
        }
        let storedPending = pending?.text == text ? pending : nil
        let data = try JSONEncoder().encode(Draft(text: storedPending == nil ? text : nil, project: storedProject, pending: storedPending, receipt: storedPending == nil ? nil : pendingReceipt))
        try ConfigStore.withLock { try privateAtomicWrite(data, to: draftURL) }
    }
    private func clearDraft() {
        text = ""; pending = nil; pendingReceipt = nil; selectedProject = nil
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
    func submit(command: String = "add") async {
        guard !saving else { return }
        do {
            if let pendingReceipt, let state = try ChatLaunchSession.readState(pendingReceipt), state.phase != .prepared {
                activate(command); return
            }
            guard let project = selectedProject,
                  projects.contains(where: { $0.id == project.id && $0.path == project.path && $0.path != nil }) else { throw ConfigError.io(NSLocalizedString("Project checkout is unavailable or outside the selected scope.", comment: "")) }
            let request: DevelopmentRequest
            if let pending, pending.text == text, pending.projectID == selectedProject?.project.id, pending.projectPath == selectedProject?.path, pending.model == settings.model, pending.reasoningEffort == settings.reasoningEffort, (pending.permissionsProfile ?? "Development") == settings.permissionsProfile { request = pending }
            else { request = try DevelopmentRequest(text: text, project: selectedProject, settings: settings); pending = request; pendingReceipt = nil }
            try writeDraft()
            saving = true; defer { saving = false }
            let folder = settings.queueFolder
            let result: RequestReceipt
            if let pendingReceipt { result = pendingReceipt }
            else { result = try await Task.detached(priority: .userInitiated) { try RequestQueue.save(request, folder: folder) }.value; pendingReceipt = result; try writeDraft() }
            if command == "proj" {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { throw ConfigError.io("Install ChatGPT to start this chat. The request is saved locally.") }
                let executable = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
                let session = try await Task.detached(priority: .userInitiated) { try ChatLaunchSession(request: request, receipt: result, executable: executable, socketPath: codexHome + "/ipc/ipc.sock") }.value
                chatURL = session.state.url
                try await openChat(session.state.url, app: app)
                _ = try await Task.detached(priority: .userInitiated) { try session.send() }.value
                delivery = "Sent to ChatGPT"
            } else { delivery = "Saved locally" }
            receipt = result; error = nil; clearDraft()
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
    private var selectable: [Int] { results.indices.filter { results[$0].path != nil } }
    private func move(_ direction: Int) {
        let choices = selectable
        if let next = direction > 0 ? choices.first(where: { $0 > index }) : choices.last(where: { $0 < index }) { index = next }
    }
    private func pick(_ project: LocalProject) {
        guard project.path != nil else { return }
        model.selectedProject = project; model.choosingProject = false; model.error = nil; model.persistDraft()
    }
    private func goBack() {
        if model.saving { return }
        if !model.choosingProject && model.receipt == nil { model.choosingProject = true; filter = "" }
        else { model.persistDraft(); back() }
    }
    private var header: some View {
        LauncherHeader(appearance: appearance) {
            Button(action: { model.persistDraft(); back() }) {
                Text(command.uppercased()).font(.system(size: 14, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(appearance.selection, in: RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
            }.buttonStyle(.plain).foregroundStyle(appearance.xp ? appearance.headerForeground : appearance.accent)
                .frame(minHeight: 44).accessibilityLabel(Text("Back to search"))
            if let project = model.selectedProject, !model.choosingProject {
                Button { model.choosingProject = true; filter = "" } label: {
                    Text(project.project.name).font(appearance.rowFont).lineLimit(1)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(appearance.selection, in: RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
                }.buttonStyle(.plain).frame(maxWidth: 160, minHeight: 44).accessibilityLabel(Text("Choose another project"))
            }
            if model.choosingProject {
                TextField("Find projects", text: $filter, prompt: Text("Find projects").font(appearance.placeholderFont).foregroundColor(appearance.headerForeground.opacity(0.55))).textFieldStyle(.plain).focused($focus, equals: .project)
                    .accessibilityIdentifier("requests.projectSearch")
                    .onChange(of: filter) { _, _ in index = selectable.first ?? 0 }
            } else { Spacer(minLength: 0) }
            if model.loading || model.saving { ProgressView().controlSize(.small) }
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
    private var resultContent: some View {
        VStack(spacing: 0) {
            if let receipt = model.receipt {
                VStack(alignment: .leading, spacing: 10) {
                    Label(LocalizedStringKey(model.delivery), systemImage: model.delivery == "Saved locally" || model.delivery == "Sent to ChatGPT" ? "checkmark.circle" : "questionmark.circle").font(appearance.rowFont)
                    Text(receipt.file.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if model.chatURL != nil { Button("Open chat") { model.reopenChat() } }
                        Button("Reveal request") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.file)]) }
                        Button("New request") { model.startNew(); filter = ""; index = selectable.first ?? 0 }
                        Button("Done", action: close).keyboardShortcut(.return, modifiers: [])
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Spacer(minLength: 0)
            } else if model.choosingProject {
                projectResults
            } else {
                TextField("What would you like to change?", text: $model.text, prompt: Text("What would you like to change?").font(appearance.placeholderFont).foregroundColor(appearance.foreground.opacity(0.55)), axis: .vertical)
                    .textFieldStyle(.plain).font(appearance.inputFont).lineLimit(3...7)
                    .focused($focus, equals: .request).padding(.horizontal, 18).padding(.top, 10)
                    .accessibilityIdentifier("requests.text").disabled(model.saving)
                Spacer(minLength: 0)
                HStack {
                    Text(model.settings.permissionsProfile).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.settings.model + " · " + requestEffortName(model.settings.reasoningEffort)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.horizontal, 18).padding(.vertical, 10)
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
                Text(LocalizedStringKey(model.choosingProject ? "↑ ↓ Select · Return Choose" : "Shift Return New line")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.choosingProject && model.receipt == nil {
                    Button(LocalizedStringKey(command == "proj" ? "Start chat" : "Save request")) { Task { await model.submit(command: command) } }.buttonStyle(.borderedProminent)
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
                          model.choosingProject ? filter.isEmpty : model.text.isEmpty else { return false }
                    goBack(); return true
                }
                // The old search field resigns during the view swap. Focus after it is detached.
                DispatchQueue.main.async { focus = model.choosingProject ? .project : .request }
            }
            .task { await model.refresh() }
            .onDisappear { setBackspace(nil); model.persistDraft() }
            .onChange(of: model.choosingProject) { _, choosing in
                index = selectable.first ?? 0
                DispatchQueue.main.async { focus = choosing ? .project : .request }
            }
            .onChange(of: model.snapshot?.fetchedAt) { _, _ in index = selectable.first ?? 0 }
            .onKeyPress(.escape) { goBack(); return .handled }
            .onKeyPress(.downArrow) { guard model.choosingProject else { return .ignored }; move(1); return .handled }
            .onKeyPress(.upArrow) { guard model.choosingProject else { return .ignored }; move(-1); return .handled }
            .onKeyPress(keys: [.return], phases: .down) { press in
                if model.saving { return .handled }
                let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                if editor?.hasMarkedText() == true { return .ignored }
                if press.modifiers.contains(.shift) {
                    guard !model.choosingProject, model.receipt == nil, let editor else { return .ignored }
                    // NSTextField otherwise commits/selects all on Shift Return.
                    editor.insertText("\n", replacementRange: editor.selectedRange())
                    model.text = editor.string
                    return .handled
                }
                if model.receipt != nil { close() }
                else if model.choosingProject { if results.indices.contains(index) { pick(results[index]) } }
                else { Task { await model.submit(command: command) } }
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

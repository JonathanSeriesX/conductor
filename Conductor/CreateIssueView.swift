import SwiftUI

struct ProjectChoice: Hashable {
    let project: Project
    let accountID: UUID
}

/// What a New Issue window opens with: the list's project, or an issue's project and key for a subtask.
struct CreateRequest: Hashable, Codable {
    var accountID: UUID?
    var projectKey: String?
    var parentKey: String?
}

@MainActor @Observable
final class CreateIssueModel {
    var choice: ProjectChoice?
    var state: AccountState?
    var project: Project? { choice?.project }
    var types: [IssueType] = []
    var type: IssueType?
    var fields: [CreateField] = []
    var summary = ""
    var text = ""
    var mentions: [String: String] = [:]
    var assignee: JiraUser?
    var priority: Priority?
    var labels: [String] = []
    var parentKey = ""
    var error: String?
    var isWorking = false
    var isLoadingMeta = false

    /// Fields this window knows how to fill.
    private static let handled: Set<String> = [
        "project", "issuetype", "summary", "description", "assignee", "priority", "labels", "parent", "reporter",
    ]

    var priorities: [Priority] {
        fields.first { $0.fieldId == "priority" }?.allowedValues?.compactMap { v in
            guard let o = v.object, let id = o["id"]?.string, let name = o["name"]?.string else { return nil }
            return Priority(id: id, name: name, iconUrl: o["iconUrl"]?.string.flatMap(URL.init))
        } ?? []
    }
    /// Before the create screen is known the usual fields are assumed, so the window opens at its full height
    /// rather than growing as they arrive.
    func has(_ id: String) -> Bool { fields.isEmpty || fields.contains { $0.fieldId == id } }
    var parentRequired: Bool { type?.isSubtask == true || fields.first { $0.fieldId == "parent" }?.required == true }
    /// Required fields on this site that the window cannot fill; creation would be rejected.
    var unsupportedRequired: [String] {
        fields.filter { $0.required && !Self.handled.contains($0.fieldId) }.map(\.name)
    }
    /// Jira's limit, checked here so a long summary never goes out to come back as an error.
    var summaryTooLong: Bool { summary.count > 255 }

    var canSubmit: Bool {
        project != nil && type != nil && !summary.trimmingCharacters(in: .whitespaces).isEmpty && !summaryTooLong
            && unsupportedRequired.isEmpty
            && (!parentRequired || !parentKey.trimmingCharacters(in: .whitespaces).isEmpty)
            && !isWorking && !isLoadingMeta
    }

    /// The project's issue types, from the account's cache at once and from the network behind it.
    func loadTypes(_ st: AccountState) async {
        guard let p = project else { return }
        let (c, key) = (st.client, p.key)
        let (now, fresh) = st.memo("createmeta-\(key)") { try await c.createIssueTypes(project: key) }
        isLoadingMeta = now == nil
        if let now { await setTypes(now, st) }
        if let list = await fresh.value, project?.key == key { await setTypes(list, st) }
        isLoadingMeta = false
    }

    private func setTypes(_ list: [IssueType], _ st: AccountState) async {
        if types != list { types = list }
        let before = type?.id
        if !types.contains(where: { $0.id == type?.id }) {
            let candidates = types.filter { parentKey.isEmpty ? !$0.isSubtask : $0.isSubtask }
            // Task is the everyday default; Epic is rarely what someone means by ⌘N.
            type =
                candidates.first { $0.name.caseInsensitiveCompare("Task") == .orderedSame }
                ?? candidates.first { $0.name.caseInsensitiveCompare("Epic") != .orderedSame } ?? candidates.first
                ?? types.first
        }
        // A changed type loads its fields through the window's onChange; an unchanged one is asked for here.
        if type?.id == before { await loadFields(st) }
    }

    /// The fields of the chosen type, cached the same way.
    func loadFields(_ st: AccountState) async {
        guard let p = project, let t = type else {
            isLoadingMeta = false
            return
        }
        let (c, key, typeID) = (st.client, p.key, t.id)
        let (now, fresh) = st.memo("createmeta-\(key)-\(typeID)") {
            try await c.createFields(project: key, issueType: typeID)
        }
        if let now { setFields(now) } else { isLoadingMeta = true }
        if let list = await fresh.value {
            if type?.id == typeID { setFields(list) }
        } else if fields.isEmpty, type?.id == typeID, !Connectivity.shared.isOffline {
            // `has` assumes the usual fields while none are known, which would hide a create screen that failed to load.
            error = String(localized: "Couldn't load the fields for \(t.name).")
        }
        isLoadingMeta = false
    }

    private func setFields(_ list: [CreateField]) {
        if fields != list { fields = list }
        if let pr = priority, !priorities.contains(pr) { priority = nil }
    }

    func payload() throws -> [String: JSONValue] {
        var f: [String: JSONValue] = [
            "project": .object(["key": .string(project!.key)]),
            "issuetype": .object(["id": .string(type!.id)]),
            "summary": .string(summary.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, has("description") {
            f["description"] = try JSONValue(ADFNode.document(markdown: text, mentions: mentions))
        }
        if let a = assignee, has("assignee") { f["assignee"] = .object(["accountId": .string(a.accountId)]) }
        if let p = priority, has("priority") { f["priority"] = .object(["id": .string(p.id)]) }
        if !labels.isEmpty, has("labels") { f["labels"] = .array(labels.map(JSONValue.string)) }
        let parent = parentKey.trimmingCharacters(in: .whitespaces).uppercased()
        if !parent.isEmpty { f["parent"] = .object(["key": .string(parent)]) }
        return f
    }
}

struct CreateIssueView: View {
    let request: CreateRequest
    @Environment(Session.self) private var session
    /// The NSWindow, from the close-button hook. Closed directly: SwiftUI's dismiss() presses the close button,
    /// which the hook routes back here, and the two recursed until the stack ran out.
    @State private var window: NSWindow?
    @Environment(\.openWindow) private var openWindow
    @State private var m = CreateIssueModel()
    @State private var showAssign = false
    @State private var showParent = false
    @State private var labelDraft = ""
    /// Every label on the site, for suggestions under the field.
    @State private var allLabels: [String] = []
    @FocusState private var summaryFocused: Bool
    @State private var showClone = false
    private var parentKey: String? { request.parentKey }
    private var hasDraft: Bool { !m.summary.isEmpty || !m.text.isEmpty }
    private var labelMatches: [String] {
        let q = labelDraft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allLabels.filter { $0.lowercased().contains(q) && !m.labels.contains($0) }.prefix(6).map { $0 }
    }
    /// One line in the footer: the summary limit before the request, else what Jira answered. It takes no
    /// room of its own, so the window keeps its height.
    private var footerError: String? {
        m.summaryTooLong
            ? String(localized: "A summary can be 255 characters at most; this one is \(m.summary.count).") : m.error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(parentKey == nil ? "New Issue" : "New Subtask of \(parentKey!)").font(.title2.weight(.semibold))
                Spacer()
                Picker("Project", selection: $m.choice) {
                    ForEach(session.states) { st in
                        Section(session.states.count > 1 ? st.title : "") {
                            ForEach(st.projects) { p in
                                Text(p.name).tag(Optional(ProjectChoice(project: p, accountID: st.id)))
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(parentKey != nil)
            }

            HStack(spacing: 10) {
                Picker("Type", selection: $m.type) {
                    ForEach(m.types) { t in
                        Label {
                            Text(t.name)
                        } icon: {
                            RemoteImage(url: t.iconUrl).frame(width: 14, height: 14)
                        }.tag(Optional(t))
                    }
                }
                .labelsHidden()
                .fixedSize()
                if m.isLoadingMeta { ProgressView().controlSize(.small) }
                Spacer()
                // Start from an issue of yours: its type, summary, description, assignee, priority, labels and parent.
                Button("Clone from an issue…", systemImage: "doc.on.doc") { showClone = true }
                    .buttonStyle(.link)
                    .disabled(m.project == nil)
                    .popover(isPresented: $showClone, arrowEdge: .bottom) {
                        ParentPicker(
                            current: nil,
                            jql:
                                "project = \"\(m.project?.key ?? "")\" AND reporter = currentUser() ORDER BY created DESC",
                            title: "Clone", verb: "Clone"
                        ) { picked in
                            showClone = false
                            if let picked { clone(picked) }
                        }
                        .environment(\.jira, m.state)
                    }
            }

            TextField("Summary", text: $m.summary, axis: .vertical)
                .font(.title3)
                .textFieldStyle(.plain)
                .focused($summaryFocused)
                .lineLimit(1...3)
                .padding(10)
                // The padding is part of the field: a click anywhere in the box focuses it.
                .background {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                        .onTapGesture { summaryFocused = true }
                }
                // The same ring the description gets, so the focus is always visible.
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(summaryFocused ? 0.5 : 0), lineWidth: 3)
                        .padding(-1.5)
                )
                .animation(.easeOut(duration: 0.1), value: summaryFocused)

            if m.has("description") {
                Composer(text: $m.text, mentions: $m.mentions, placeholder: "Description", minHeight: 120)
                    .environment(\.jira, m.state)
            }

            HStack(alignment: .top, spacing: 18) {
                if m.has("assignee") {
                    field("Assignee") {
                        Button {
                            showAssign = true
                        } label: {
                            HStack(spacing: 6) {
                                Avatar(user: m.assignee, size: 18)
                                Text(m.assignee?.displayName ?? String(localized: "Unassigned")).foregroundStyle(
                                    m.assignee == nil ? .secondary : .primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showAssign, arrowEdge: .bottom) {
                            PeoplePicker(scope: .project(m.project?.key ?? ""), current: m.assignee) {
                                m.assignee = $0
                                showAssign = false
                            }
                            .environment(\.jira, m.state)
                        }
                    }
                    // Room for a name, so the columns after it stay put when "Unassigned" becomes one.
                    .frame(minWidth: 180, alignment: .leading)
                }
                if m.has("priority"), !m.priorities.isEmpty {
                    field("Priority") {
                        Picker("Priority", selection: $m.priority) {
                            Text("Default").tag(Optional<Priority>.none)
                            ForEach(m.priorities, id: \.id) { p in Text(p.name).tag(Optional(p)) }
                        }
                        .labelsHidden().frame(maxWidth: 160)
                    }
                }
                if m.has("parent") || m.parentRequired {
                    field(m.parentRequired ? "Parent (required)" : "Parent / Epic") {
                        Button {
                            showParent = true
                        } label: {
                            Text(m.parentKey.isEmpty ? String(localized: "None") : m.parentKey)
                                .foregroundStyle(m.parentKey.isEmpty ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(parentKey != nil)
                        .popover(isPresented: $showParent, arrowEdge: .bottom) {
                            ParentPicker(current: m.parentKey.isEmpty ? nil : m.parentKey, jql: parentJQL) { new in
                                showParent = false
                                m.parentKey = new ?? ""
                            }
                            .environment(\.jira, m.state)
                        }
                    }
                }
            }

            if m.has("labels") {
                field("Labels") {
                    Wrap {
                        ForEach(m.labels, id: \.self) { l in Chip(text: l) { m.labels.removeAll { $0 == l } } }
                        TextField("Add label", text: $labelDraft)
                            .textFieldStyle(.plain).font(.caption).frame(width: 110)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary.opacity(0.3), in: .capsule)
                            .onSubmit { addLabel() }
                            // ⌫ in the empty field takes the last chip back, as in Mail's address field.
                            .onKeyPress(.delete) {
                                guard labelDraft.isEmpty, !m.labels.isEmpty else { return .ignored }
                                m.labels.removeLast()
                                return .handled
                            }
                    }
                    ForEach(labelMatches, id: \.self) { l in
                        Button {
                            m.labels.append(l)
                            labelDraft = ""
                        } label: {
                            Text(l).font(.callout).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }
                        .buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 2)
                    }
                }
            }

            if !m.unsupportedRequired.isEmpty {
                Label(
                    "This type also requires \(m.unsupportedRequired.formatted(.list(type: .and))), which Conductor can't fill yet. Create it in the browser.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout).foregroundStyle(.orange)
            }

            HStack {
                if let e = footerError {
                    Text(e).font(.callout).foregroundStyle(.red).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // No Escape shortcut: a window of its own closes with ⌘W, Cancel or the close button, never a key
                // that also leaves text fields and dismisses popovers.
                Button("Cancel") { requestClose() }.glassButton()
                Button(action: create) {
                    if m.isWorking {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Text("Create").frame(width: 60)
                    }
                }
                .glassButton(prominent: true)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!m.canSubmit)
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(Backdrop())
        .writingToolsBehavior(.disabled)  // macOS 27 pins a Siri button beside every text view otherwise
        .navigationTitle(parentKey == nil ? "New Issue" : "New Subtask of \(parentKey!)")
        .background(CloseButtonHook(onWindow: { window = $0 }, close: requestClose))
        // Signed out of every account, with or without a draft: there is nothing to create an issue in.
        .task(id: [session.isRestoring, session.isSignedIn, window != nil]) {
            if !session.isRestoring, !session.isSignedIn { window?.close() }
        }
        .background(
            WindowEventMonitor(mask: .keyDown) { e in
                // Escape only leaves the field it is in; ⌘W, Cancel and the close button close the window, asking
                // first when there is a draft.
                let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if e.keyCode == 53, mods.isEmpty, e.window?.firstResponder is NSTextView {
                    e.window?.makeFirstResponder(nil)
                    return nil
                }
                if mods == .command, e.charactersIgnoringModifiers == "w" {
                    requestClose(e.window)
                    return nil
                }
                return e
            }
        )
        .focusSoon($summaryFocused)
        .task {
            let last = UserDefaults.standard.string(forKey: "lastCreateProject")
            // The request's project, else the one used last time, else a starred one, else the first.
            if let id = request.accountID, let st = session.state(id),
                let p = st.projects.first(where: { $0.key == request.projectKey })
            {
                m.choice = ProjectChoice(project: p, accountID: st.id)
            } else if let last, let st = session.states.first(where: { last.hasPrefix("\($0.id)|") }),
                let p = st.projects.first(where: { "\(st.id)|\($0.key)" == last })
            {
                m.choice = ProjectChoice(project: p, accountID: st.id)
            } else if let st = session.states.first(where: { !$0.starredProjects.isEmpty }),
                let p = st.starredProjects.first
            {
                m.choice = ProjectChoice(project: p, accountID: st.id)
            } else if let st = session.states.first, let p = st.projects.first {
                m.choice = ProjectChoice(project: p, accountID: st.id)
            }
            m.parentKey = parentKey ?? ""
            syncState()
            if let st = m.state { await m.loadTypes(st) }
        }
        .onChange(of: m.choice) {
            syncState()
            if let st = m.state { Task { await m.loadTypes(st) } }
        }
        .onChange(of: m.type) { if let st = m.state { Task { await m.loadFields(st) } } }
        .task(id: m.state?.id) {
            guard let st = m.state else { return }
            let c = st.client
            let (now, fresh) = st.memo("labels") { try await c.labels() }
            if let now { allLabels = now }
            if let list = await fresh.value { allLabels = list }
        }
        // The assignee popover opens on this list from memory rather than after its own request.
        .task(id: m.project?.key) {
            guard let st = m.state, let key = m.project?.key else { return }
            let c = st.client
            _ = st.memo("assignable-\(key)") { try await c.assignableUsers(project: key, query: "") }
        }
        // A fixed field loses its error.
        .onChange(of: m.summary) { m.error = nil }
        .onChange(of: m.parentKey) { m.error = nil }
    }

    private func syncState() { m.state = m.choice.flatMap { session.state($0.accountID) } }

    /// Closes at once without a draft; with one, asks first. An AppKit sheet answers after it is gone, so the
    /// window closes cleanly (the SwiftUI dialog's Discard raced its own dismissal and did nothing).
    private func requestClose(_ from: NSWindow? = nil) {
        guard let window = from ?? window ?? NSApp.keyWindow else { return }
        guard hasDraft else {
            window.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard this issue?")
        alert.addButton(withTitle: String(localized: "Keep Editing"))
        alert.addButton(withTitle: String(localized: "Discard")).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { window.close() } }
    }

    /// Fills the form from an existing issue.
    private func clone(_ key: String) {
        guard let c = m.state?.client else { return }
        Task {
            let i: Issue
            do { i = try await c.issue(key) } catch {
                m.error = error.localizedDescription
                return
            }
            if let t = m.types.first(where: { $0.id == i.fields.issuetype.id }) { m.type = t }
            m.summary = i.fields.summary
            var mentions: [String: String] = [:]
            m.text = i.fields.description?.markdown(mentions: &mentions) ?? ""
            m.mentions = mentions
            m.assignee = i.fields.assignee
            m.priority = m.priorities.first { $0.id == i.fields.priority?.id }
            m.labels = i.fields.labels ?? []
            if parentKey == nil { m.parentKey = i.fields.parent?.key ?? "" }
        }
    }

    /// Parents one level up in the same project: standard issues for a subtask, epics for the rest.
    private var parentJQL: String {
        let level = m.type?.isSubtask == true ? 0 : (m.type?.hierarchyLevel ?? 0) + 1
        return "project = \"\(m.project?.key ?? "")\" AND hierarchyLevel = \(level) ORDER BY updated DESC"
    }

    private func addLabel() {
        let l = labelDraft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !l.isEmpty else { return }
        if !m.labels.contains(l) { m.labels.append(l) }
        labelDraft = ""
    }

    private func create() {
        guard let st = m.state, m.canSubmit else { return }
        let c = st.client
        addLabel()
        m.isWorking = true
        m.error = nil
        Task {
            defer { m.isWorking = false }
            do {
                let created = try await c.createIssue(fields: try m.payload())
                UserDefaults.standard.set("\(st.id)|\(m.project?.key ?? "")", forKey: "lastCreateProject")
                session.reloadTick += 1  // the lists, and the parent's subtasks
                (window ?? NSApp.keyWindow)?.close()
                openWindow(id: "issue", value: IssueTarget(accountID: st.id, key: created.key))
            } catch { m.error = error.localizedDescription }
        }
    }
}

/// Routes the window's close button through `close`, so a draft can ask before it goes. ⌘W and Escape reach the
/// same place through the key monitor; SwiftUI offers no windowShouldClose.
private struct CloseButtonHook: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    let close: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.onWindow = onWindow
        view.close = close
    }

    final class Probe: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }
        var close: (NSWindow?) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            let window = window
            DispatchQueue.main.async { self.onWindow(window) }  // not inside SwiftUI's update
            guard let button = window?.standardWindowButton(.closeButton) else { return }
            button.target = self
            button.action = #selector(tap)
        }
        @objc private func tap() { close(window) }
    }
}

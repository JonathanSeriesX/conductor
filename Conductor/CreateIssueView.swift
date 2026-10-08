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
    func has(_ id: String) -> Bool { fields.contains { $0.fieldId == id } }
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

    func loadTypes(_ c: JiraClient) async {
        guard let p = project else { return }
        isLoadingMeta = true
        types = (try? await c.createIssueTypes(project: p.key)) ?? []
        if !types.contains(where: { $0.id == type?.id }) {
            let candidates = types.filter { parentKey.isEmpty ? !$0.isSubtask : $0.isSubtask }
            // Task is the everyday default; Epic is rarely what someone means by ⌘N.
            type =
                candidates.first { $0.name.caseInsensitiveCompare("Task") == .orderedSame }
                ?? candidates.first { $0.name.caseInsensitiveCompare("Epic") != .orderedSame } ?? candidates.first
                ?? types.first
        }
        await loadFields(c)
    }

    func loadFields(_ c: JiraClient) async {
        guard let p = project, let t = type else {
            isLoadingMeta = false
            return
        }
        isLoadingMeta = true
        fields = (try? await c.createFields(project: p.key, issueType: t.id)) ?? []
        if let pr = priority, !priorities.contains(pr) { priority = nil }
        isLoadingMeta = false
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var m = CreateIssueModel()
    @State private var showAssign = false
    @State private var showParent = false
    @State private var labelDraft = ""
    /// Every label on the site, for suggestions under the field.
    @State private var allLabels: [String] = []
    @FocusState private var summaryFocused: Bool
    @State private var confirmDiscard = false
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
            }

            TextField("Summary", text: $m.summary, axis: .vertical)
                .font(.title3)
                .textFieldStyle(.plain)
                .focused($summaryFocused)
                .lineLimit(1...3)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
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
                    labeled("Assignee") {
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
                    labeled("Priority") {
                        Picker("Priority", selection: $m.priority) {
                            Text("Default").tag(Optional<Priority>.none)
                            ForEach(m.priorities, id: \.id) { p in Text(p.name).tag(Optional(p)) }
                        }
                        .labelsHidden().frame(maxWidth: 160)
                    }
                }
                if m.has("parent") || m.parentRequired {
                    labeled(m.parentRequired ? "Parent (required)" : "Parent / Epic") {
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
                labeled("Labels") {
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
                Button("Cancel") { if hasDraft { confirmDiscard = true } else { dismiss() } }.glassButton()
                    .keyboardShortcut(.cancelAction)
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
        .confirmationDialog("Discard this issue?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .task {
            DispatchQueue.main.async { summaryFocused = true }
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
            if let c = m.state?.client { await m.loadTypes(c) }
        }
        .onChange(of: m.choice) {
            syncState()
            if let c = m.state?.client { Task { await m.loadTypes(c) } }
        }
        .onChange(of: m.type) { if let c = m.state?.client { Task { await m.loadFields(c) } } }
        .task(id: m.state?.id) { allLabels = (try? await m.state?.client.labels()) ?? [] }
        // A fixed field loses its error.
        .onChange(of: m.summary) { m.error = nil }
        .onChange(of: m.parentKey) { m.error = nil }
    }

    private func syncState() { m.state = m.choice.flatMap { session.state($0.accountID) } }

    /// Parents one level up in the same project: standard issues for a subtask, epics for the rest.
    private var parentJQL: String {
        let level = m.type?.isSubtask == true ? 0 : (m.type?.hierarchyLevel ?? 0) + 1
        return "project = \"\(m.project?.key ?? "")\" AND hierarchyLevel = \(level) ORDER BY updated DESC"
    }

    private func labeled<V: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            content()
        }
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
                dismiss()
                openWindow(id: "issue", value: IssueTarget(accountID: st.id, key: created.key))
            } catch { m.error = error.localizedDescription }
        }
    }
}

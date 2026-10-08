import SwiftUI

struct ProjectChoice: Hashable {
    let project: Project
    let accountID: UUID
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

    /// Fields this sheet knows how to fill.
    private static let handled: Set<String> = ["project", "issuetype", "summary", "description", "assignee", "priority", "labels", "parent", "reporter"]

    var priorities: [Priority] {
        fields.first { $0.fieldId == "priority" }?.allowedValues?.compactMap { v in
            guard let o = v.object, let id = o["id"]?.string, let name = o["name"]?.string else { return nil }
            return Priority(id: id, name: name, iconUrl: o["iconUrl"]?.string.flatMap(URL.init))
        } ?? []
    }
    func has(_ id: String) -> Bool { fields.contains { $0.fieldId == id } }
    var parentRequired: Bool { type?.isSubtask == true || fields.first { $0.fieldId == "parent" }?.required == true }
    /// Required fields on this site that the sheet cannot fill; creation would be rejected.
    var unsupportedRequired: [String] { fields.filter { $0.required && !Self.handled.contains($0.fieldId) }.map(\.name) }

    var canSubmit: Bool {
        project != nil && type != nil && !summary.trimmingCharacters(in: .whitespaces).isEmpty
            && unsupportedRequired.isEmpty && (!parentRequired || !parentKey.trimmingCharacters(in: .whitespaces).isEmpty)
            && !isWorking && !isLoadingMeta
    }

    func loadTypes(_ c: JiraClient) async {
        guard let p = project else { return }
        isLoadingMeta = true
        types = (try? await c.createIssueTypes(project: p.key)) ?? []
        if !types.contains(where: { $0.id == type?.id }) {
            let candidates = types.filter { parentKey.isEmpty ? !$0.isSubtask : $0.isSubtask }
            // Task is the everyday default; Epic is rarely what someone means by ⌘N.
            type = candidates.first { $0.name.caseInsensitiveCompare("Task") == .orderedSame }
                ?? candidates.first { $0.name.caseInsensitiveCompare("Epic") != .orderedSame } ?? candidates.first ?? types.first
        }
        await loadFields(c)
    }

    func loadFields(_ c: JiraClient) async {
        guard let p = project, let t = type else { isLoadingMeta = false; return }
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
    var defaultProject: (Project, AccountState)?
    var parentKey: String?
    var onCreated: (IssueTarget) -> Void
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var m = CreateIssueModel()
    @State private var showAssign = false
    @State private var labelDraft = ""
    @FocusState private var summaryFocused: Bool
    @State private var confirmDiscard = false
    private var hasDraft: Bool { !m.summary.isEmpty || !m.text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(parentKey == nil ? "New Issue" : "New Subtask of \(parentKey!)").font(.title2.weight(.semibold))
                Spacer()
                Picker("Project", selection: $m.choice) {
                    ForEach(session.states) { st in
                        Section(session.states.count > 1 ? st.title : "") {
                            ForEach(st.projects) { p in Text(p.name).tag(Optional(ProjectChoice(project: p, accountID: st.id))) }
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
                        Label { Text(t.name) } icon: { RemoteImage(url: t.iconUrl).frame(width: 14, height: 14) }.tag(Optional(t))
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

            if m.has("description") {
                Composer(text: $m.text, mentions: $m.mentions, placeholder: "Description", minHeight: 120)
                    .environment(\.jira, m.state)
            }

            HStack(alignment: .top, spacing: 18) {
                if m.has("assignee") {
                    labeled("Assignee") {
                        Button { showAssign = true } label: {
                            HStack(spacing: 6) {
                                Avatar(user: m.assignee, size: 18)
                                Text(m.assignee?.displayName ?? String(localized: "Unassigned")).foregroundStyle(m.assignee == nil ? .secondary : .primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showAssign, arrowEdge: .bottom) {
                            PeoplePicker(scope: .project(m.project?.key ?? ""), current: m.assignee) { m.assignee = $0; showAssign = false }
                                .environment(\.jira, m.state)
                        }
                    }
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
                        TextField("KEY-123", text: $m.parentKey)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                            .disabled(parentKey != nil)
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
                    }
                }
            }

            if !m.unsupportedRequired.isEmpty {
                Label("This type also requires \(m.unsupportedRequired.formatted(.list(type: .and))), which Conductor can't fill yet. Create it in the browser.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let e = m.error { Text(e).font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancel") { if hasDraft { confirmDiscard = true } else { dismiss() } }.glassButton().keyboardShortcut(.cancelAction)
                Button(action: create) {
                    if m.isWorking { ProgressView().controlSize(.small).frame(width: 60) } else { Text("Create").frame(width: 60) }
                }
                .glassButton(prominent: true)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!m.canSubmit)
            }
        }
        .padding(22)
        .frame(width: 640)
        .interactiveDismissDisabled(hasDraft)
        .confirmationDialog("Discard this issue?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .task {
            DispatchQueue.main.async { summaryFocused = true }
            let last = UserDefaults.standard.string(forKey: "lastCreateProject")
            // The list's project, else the one used last time, else a starred one, else the first. An issue's
            // own project record lacks fields the picker's entries have, so the catalog's copy stands in.
            if let (p, st) = defaultProject {
                m.choice = ProjectChoice(project: st.projects.first { $0.key == p.key } ?? p, accountID: st.id)
            } else if let last, let st = session.states.first(where: { last.hasPrefix("\($0.id)|") }),
                      let p = st.projects.first(where: { "\(st.id)|\($0.key)" == last }) {
                m.choice = ProjectChoice(project: p, accountID: st.id)
            } else if let st = session.states.first(where: { !$0.starredProjects.isEmpty }), let p = st.starredProjects.first {
                m.choice = ProjectChoice(project: p, accountID: st.id)
            } else if let st = session.states.first, let p = st.projects.first {
                m.choice = ProjectChoice(project: p, accountID: st.id)
            }
            m.parentKey = parentKey ?? ""
            syncState()
            if let c = m.state?.client { await m.loadTypes(c) }
        }
        .onChange(of: m.choice) { syncState(); if let c = m.state?.client { Task { await m.loadTypes(c) } } }
        .onChange(of: m.type) { if let c = m.state?.client { Task { await m.loadFields(c) } } }
    }

    private func syncState() { m.state = m.choice.flatMap { session.state($0.accountID) } }

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
                session.listTick += 1
                dismiss()
                onCreated(IssueTarget(accountID: st.id, key: created.key))
            } catch { m.error = error.localizedDescription }
        }
    }
}

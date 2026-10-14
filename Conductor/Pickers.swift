import SwiftUI

struct ReminderView: View {
    let url: URL
    let key: String
    let summary: String
    var done: () -> Void
    @State private var date = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
    @State private var existing: Date?
    @State private var error: String?

    private var presets: [(String, Date)] {
        let cal = Calendar.current
        let tomorrow9 = cal.date(
            bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: .now)!)!
        let monday9 = cal.nextDate(
            after: .now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
        let at = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        return [
            (String(localized: "In 1 Hour"), .now.addingTimeInterval(3600)),
            (String(localized: "Tomorrow at \(at(tomorrow9))"), tomorrow9),
            (String(localized: "Next Monday at \(at(monday9))"), monday9),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remind Me").font(.headline)
            if let existing {
                HStack {
                    Label(existing.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill").font(
                        .callout)
                    Spacer()
                    Button("Remove") {
                        Notifier.cancelReminder(for: url)
                        done()
                    }
                }
            }
            ForEach(presets, id: \.0) { title, at in
                Button(title) { set(at) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            Divider()
            HStack {
                DatePicker("At", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Button("Set") { set(date) }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 280)
        .task { existing = await Notifier.reminder(for: url) }
    }

    private func set(_ at: Date) {
        Task {
            do {
                try await Notifier.remind(url, key: key, summary: summary, at: at)
                done()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Jira due dates are plain calendar days, read and written in the local calendar.
enum DueDate {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func parse(_ s: String) -> Date? { format.date(from: s) }
    static func string(_ d: Date) -> String { format.string(from: d) }
}

struct DueDatePicker: View {
    @State private var date: Date
    private let hadDate: Bool
    var onSave: (Date?) -> Void

    init(date: Date?, onSave: @escaping (Date?) -> Void) {
        _date = State(initialValue: date ?? .now)
        hadDate = date != nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Due date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
                .focusEffectDisabled()  // the thick square ring around the whole calendar
            HStack {
                Button("Clear") { onSave(nil) }.glassButton().disabled(!hadDate)
                Spacer()
                Button("Save") { onSave(date) }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

/// The label rules both label editors follow: the issue page's and the New Issue window's.
enum Labels {
    /// Up to six of the site's labels holding the draft, leaving out the ones already chosen: first those starting with
    /// it, then those with a word starting with it (after a "-", "_", "." or space), then the rest, each run in
    /// alphabetical order. A label listed twice is offered once.
    static func matches(_ draft: String, in all: [String], excluding chosen: [String]) -> [String] {
        let q = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        let ranked = all.compactMap { label -> (Int, String, String)? in
            let l = label.lowercased()
            guard l.contains(q), !chosen.contains(label), seen.insert(label).inserted else { return nil }
            let rank = l.hasPrefix(q) ? 0 : "-_. ".contains { l.contains("\($0)\(q)") } ? 1 : 2
            return (rank, l, label)
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(6).map { $0.2 }
    }

    /// Server's labels starting with the draft, after a pause in typing; nil keeps the last answer. Server's `labels()`
    /// holds only its most used ones, so the rest come from here; Cloud lists them all and is never asked.
    static func fetch(_ draft: String, on client: JiraClient?) async -> [String]? {
        guard let client, client.account.isServer else { return nil }
        let q = draft.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return nil }
        let found = try? await client.labelSuggestions(q)
        return Task.isCancelled ? nil : found ?? []
    }

    /// The labels typed in a draft: a comma ends each, and a space becomes a dash, since a label has none.
    static func parse(_ draft: String) -> [String] {
        draft.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-") }
            .filter { !$0.isEmpty }
    }
}

extension Optional where Wrapped == Int {
    /// ↓ or ↑ in a list of `count` rows: one row on, held at the ends; nil stands before the first row.
    mutating func step(_ by: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        self = max(0, min(count - 1, (self ?? -1) + by))
        return .handled
    }
}

struct LabelsEditor: View {
    @State var labels: [String]
    /// Every label on the site; the ones matching the draft are offered below the field.
    var suggestions: [String] = []
    var onSave: ([String]) -> Void
    @Environment(\.jira) private var jira
    @State private var draft = ""
    /// Server's labels starting with the draft, which `suggestions` may lack there.
    @State private var fetched: [String] = []
    /// The match ↓ and ↑ walked to, which ↩ adds.
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private var matches: [String] { Labels.matches(draft, in: suggestions + fetched, excluding: labels) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels").font(.headline)
            if labels.isEmpty { Text("No labels").foregroundStyle(.tertiary).font(.callout) }
            Wrap { ForEach(labels, id: \.self) { l in Chip(text: l) { labels.removeAll { $0 == l } } } }
            TextField("New label · ↩ to add · ⌘↩ to save", text: $draft).textFieldStyle(.roundedBorder)
                .onSubmit(add).focused($focused)
                .onKeyPress(.downArrow) { highlighted.step(1, count: matches.count) }
                .onKeyPress(.upArrow) { highlighted.step(-1, count: matches.count) }
                // A comma ends a label, so several can be typed or pasted in one go.
                .onChange(of: draft) {
                    highlighted = nil
                    if draft.contains(",") { add() }
                }
            ForEach(Array(matches.enumerated()), id: \.element) { i, m in
                Button {
                    labels.append(m)
                    draft = ""
                } label: {
                    Text(m).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 3)
                .background(i == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Save") {
                    add()
                    onSave(labels)
                }.glassButton(prominent: true).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .frame(width: 280)
        .focusSoon($focused)
        .task(id: draft) { if let found = await Labels.fetch(draft, on: jira?.client) { fetched = found } }
    }

    private func add() {
        if let h = highlighted, matches.indices.contains(h) {
            labels.append(matches[h])
        } else {
            for l in Labels.parse(draft) where !labels.contains(l) { labels.append(l) }
        }
        draft = ""
    }
}

/// A bin icon that deletes at once and asks nothing: what it deletes lands in the Bin (Window menu) to be put back.
struct DeleteButton: View {
    let help: LocalizedStringKey
    let perform: () -> Void

    var body: some View {
        Button(action: perform) { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help(help)
    }
}

/// A popover of choices with the current one ticked, for what a key opens.
/// ponytail: Tab moves between rows; arrow keys and a type-to-find would be the next step.
struct PickList: View {
    let items: [(id: String, title: String, selected: Bool)]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.id) { item in
                Button {
                    pick(item.id)
                } label: {
                    HStack(spacing: 8) {
                        Text(item.title)
                        Spacer()
                        if item.selected { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(minWidth: 200)
    }
}

/// Who watches the issue, with the watch toggle under the list.
struct WatchersView<Toggle: View>: View {
    let key: String
    @ViewBuilder var toggle: Toggle
    @Environment(\.jira) private var jira
    @State private var users: [JiraUser]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Watchers").font(.headline)
            if let users {
                ForEach(users) { u in
                    HStack(spacing: 6) {
                        Avatar(user: u, size: 20)
                        Text(u.displayName)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            toggle.glassButton()
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
        .task { users = (try? await jira?.client.watchers(key)) ?? [] }
    }
}

/// Sets or clears the parent: a key typed or picked from the search.
struct ParentPicker: View {
    /// The issue being re-parented, left out of the results; nil while creating one.
    var key: String?
    let current: String?
    /// Scope of the search: the same project, one hierarchy level up.
    var jql: String
    /// "Clone" when the New Issue window borrows the picker to copy an issue.
    var title: LocalizedStringKey = "Parent"
    var verb: LocalizedStringKey = "Set"
    var onSave: (String?) -> Void
    @Environment(\.jira) private var jira
    @State private var query = ""
    @State private var results: [IssuePickerResult.Item] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Key or search", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                // ↩ takes the typed key when the search found it, else the first result; an ineligible key stays put.
                .onSubmit {
                    let k = query.trimmingCharacters(in: .whitespaces).uppercased()
                    if let r = results.first(where: { $0.key == k }) ?? results.first { onSave(r.key) }
                }
            List(results) { r in
                Button {
                    onSave(r.key)
                } label: {
                    HStack(spacing: 8) {
                        Text(r.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(r.summaryText ?? "").lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain).scrollContentBackground(.hidden).frame(height: 160)
            HStack {
                if current != nil { Button("Clear") { onSave(nil) }.glassButton() }
                Spacer()
                Button(verb) { if let r = results.first { onSave(r.key) } }.glassButton(prominent: true)
                    .disabled(results.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .focusSoon($focused)
        .task(id: query) {
            guard let c = jira?.client else { return }
            if query.isEmpty {
                // The picker answers nothing to an empty query; the scope's own search lists the candidates.
                let page = try? await c.search(jql: jql)
                results = (page?.issues ?? []).filter { $0.key != key }
                    .map { IssuePickerResult.Item(key: $0.key, summaryText: $0.fields.summary) }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = ((try? await c.pickIssues(query: query, excluding: key, jql: jql)) ?? []).filter { $0.key != key }
        }
    }
}

struct LinkIssueView: View {
    let key: String
    let types: [LinkType]
    var onLink: (_ type: String, _ outward: String, _ inward: String) -> Void
    @Environment(\.jira) private var jira
    @State private var relation: String = ""
    @State private var query = ""
    @State private var results: [IssuePickerResult.Item] = []
    @State private var picked: IssuePickerResult.Item?
    @FocusState private var linkFocused: Bool

    /// Every link type offers both directions, worded from this issue's side; once when both wordings are identical.
    var relations: [(id: String, label: String, type: LinkType, outward: Bool)] {
        types.flatMap { t in [(t.id + ">", t.outward, t, true), (t.id + "<", t.inward, t, false)] }
            .filter { $0.outward || $0.type.inward != $0.type.outward }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link \(key)").font(.headline)
            Picker("This issue", selection: $relation) {
                ForEach(relations, id: \.id) { Text($0.label).tag($0.id) }
            }
            TextField("Search issues by key or text", text: $query).textFieldStyle(.roundedBorder).focused($linkFocused)
                .onSubmit {
                    if picked == nil { picked = results.first }
                    link()
                }
                // ↓ and ↑ walk the results from the field, so ↩ links the one that is highlighted.
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
            // Buttons rather than list selection: a click in a popover's List does not reliably select its row.
            List(results) { r in
                Button {
                    picked = r
                } label: {
                    HStack(spacing: 8) {
                        Text(r.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(r.summaryText ?? "").lineLimit(1)
                        Spacer()
                        if picked == r { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(picked == r ? Color.accentColor.opacity(0.15) : .clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Link") { link() }
                    .glassButton(prominent: true)
                    .disabled(picked == nil || relation.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { if relation.isEmpty { relation = relations.first?.id ?? "" } }
        .focusSoon($linkFocused)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = jira?.client else { return }
            results = ((try? await c.pickIssues(query: query, excluding: key)) ?? []).filter { $0.key != key }
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        let i = picked.flatMap(results.firstIndex) ?? -1
        picked = results[max(0, min(results.count - 1, i + by))]
        return .handled
    }

    /// "This issue blocks X": the link runs from this issue to X.
    private func link() {
        guard let r = relations.first(where: { $0.id == relation }), let p = picked else { return }
        onLink(r.type.name, r.outward ? key : p.key, r.outward ? p.key : key)
    }
}

struct LogWorkView: View {
    var onSubmit: (_ seconds: Int, _ comment: String, _ started: Date) -> Void
    @State private var duration = ""
    @State private var started = Date()
    @State private var comment = ""

    private var seconds: Int? { Self.parseDuration(duration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log Work").font(.headline)
            TextField("Time spent, e.g. 1h 30m", text: $duration).textFieldStyle(.roundedBorder).onSubmit(log)
            DatePicker("Started", selection: $started)
            TextField("Comment (optional)", text: $comment).textFieldStyle(.roundedBorder).onSubmit(log)
            HStack {
                if !duration.isEmpty, seconds == nil { Text("Use w, d, h, m").font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Log", action: log)
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(seconds == nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// Return in either field logs too: a field's own Return never reaches the default button.
    private func log() {
        if let s = seconds { onSubmit(s, comment, started) }
    }

    /// "1w 2d 3h 30m" → seconds (Jira's 8h day, 5d week). Bare numbers mean minutes.
    /// Seconds → "1d 7h", as Jira writes time: 8-hour days, 5-day weeks.
    nonisolated static func format(_ seconds: Int) -> String {
        var m = seconds / 60
        var parts: [String] = []
        for (unit, size) in [("w", 5 * 8 * 60), ("d", 8 * 60), ("h", 60), ("m", 1)] where m >= size {
            parts.append("\(m / size)\(unit)")
            m %= size
        }
        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }

    nonisolated static func parseDuration(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if let n = Double(t) { return n > 0 ? Int(n * 60) : nil }
        var total = 0.0
        var matched = false
        for m in t.matches(of: /(\d+(?:\.\d+)?)\s*([wdhm])/) {
            matched = true
            let n = Double(m.1) ?? 0
            switch m.2 {
            case "w": total += n * 5 * 8 * 3600
            case "d": total += n * 8 * 3600
            case "h": total += n * 3600
            default: total += n * 60
            }
        }
        let leftovers = t.replacing(/(\d+(?:\.\d+)?)\s*[wdhm]/, with: "").trimmingCharacters(in: .whitespaces)
        return matched && leftovers.isEmpty && total > 0 ? Int(total) : nil
    }
}

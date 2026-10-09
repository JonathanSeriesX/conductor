import SwiftUI

/// Markdown text editor with a formatting bar, @mention autocomplete and a preview of what Jira will
/// show. `mentions` collects display name → accountId so the converter can turn "@Name" into real
/// mention nodes. With `uploadImage`, pasting an image uploads it and inserts a link to it.
struct Composer: View {
    @Binding var text: String
    @Binding var mentions: [String: String]
    var placeholder: LocalizedStringKey = "Write something…"
    var minHeight: CGFloat = 60
    var maxHeight: CGFloat = 260
    /// Uploads pasted image data as an attachment and returns its URL.
    var uploadImage: ((Data, String) async throws -> URL)?
    /// Lets the owner move focus into the editor, e.g. from the Add Comment menu item.
    var focus: FocusState<Bool>.Binding?
    /// Where the click that opened this editor landed, relative to the text it replaced (top-left origin):
    /// the caret starts at the same spot in the editor rather than at the end.
    var caret: CGPoint?
    /// The owner's Save or Comment buttons, on the format bar's right, so nothing moves when editing starts.
    var actions: AnyView = AnyView(EmptyView())
    @FocusState private var ownFocus: Bool
    @Environment(\.jira) private var jira
    @State private var candidates: [JiraUser] = []
    @State private var query = ""
    @State private var preview = false
    @State private var uploading = false
    @State private var error: String?
    /// Row of the suggestion list the arrow keys point at.
    @State private var highlighted = 0
    private var isFocused: Bool { focus?.wrappedValue ?? ownFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if preview {
                ADFView(node: .document(markdown: text, mentions: mentions))
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                    .padding(10)
                    .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
            } else {
                editor
                    // The suggestions float above the box, as Slack's do, and take no room: nothing below moves.
                    // Above rather than below, since whatever is above was drawn first and cannot cover them.
                    // Hung from a zero-height line on the box's top edge; an alignment guide on the list itself
                    // was ignored inside the conditional.
                    .overlay(alignment: .top) {
                        Color.clear.frame(height: 0).overlay(alignment: .bottomLeading) {
                            if !candidates.isEmpty { suggestions.padding(.bottom, 4) }
                        }
                    }
            }
            formatBar
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: isFocused) { _, on in
            guard on else { return }
            tune()
            if let caret { placeCaret(at: caret) }
        }
        .onChange(of: text) { _, new in
            // A trailing "@name" drives the suggestion list; anything else dismisses it. A name just accepted
            // from the list (followed by its space) is complete and must not open the list again.
            if let m = new.firstMatch(of: /@([\p{L}\p{N}][\p{L}\p{N} .'-]{0,30})$/),
                !mentions.keys.contains(where: { String(m.1).hasPrefix($0 + " ") || String(m.1) == $0 })
            {
                query = String(m.1)
            } else {
                query = ""
                candidates = []
            }
        }
        .task(id: query) {
            guard !query.isEmpty, let c = jira?.client else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = (try? await c.users(matching: query)) ?? []
            highlighted = 0
            withAnimation(.easeOut(duration: 0.15)) {
                candidates = Array(found.filter { $0.active != false }.prefix(5))
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { i, u in
                Button {
                    accept(u)
                } label: {
                    HStack(spacing: 8) {
                        Avatar(user: u, size: 18)
                        Text(u.displayName)
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(i == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 260)
        .glassPane(cornerRadius: 10)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .transition(.opacity)
    }

    // MARK: Formatting

    private var formatBar: some View {
        HStack(spacing: 2) {
            // Shortcuts only while this editor has focus: an issue page can hold several composers.
            tool("bold", "Bold (⌘B)", key: "b") { wrap("**", "**") }
            tool("italic", "Italic (⌘I)", key: "i") { wrap("*", "*") }
            tool("chevron.left.forwardslash.chevron.right", "Code") { wrap("`", "`") }
            tool("link", "Link (⌘K)", key: "k") { wrap("[", "](https://)") }
            tool("list.bullet", "Bulleted list") { prefixLine("- ") }
            tool("text.quote", "Quote") { prefixLine("> ") }
            tool("at", "Mention someone") { wrap("@", "") }
            Toggle(isOn: $preview) { Label("Preview", systemImage: preview ? "eye.fill" : "eye") }
                .toggleStyle(.button).buttonStyle(.plain).labelStyle(.iconOnly)
                .foregroundStyle(preview ? Color.accentColor : .secondary)
                .help("Preview as Jira will show it")
                .padding(.leading, 6)
            if uploading { ProgressView().controlSize(.mini).padding(.leading, 6) }
            Spacer()
            actions
        }
        .font(.callout)
    }

    private func tool(
        _ symbol: String, _ help: LocalizedStringKey, key: KeyEquivalent? = nil, _ action: @escaping () -> Void
    ) -> some View {
        // A Label, so VoiceOver reads "Quote" rather than the symbol's own name ("Lyrics").
        Button(action: action) {
            Label(help, systemImage: symbol).labelStyle(.iconOnly).frame(width: 24, height: 20).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .keyboardShortcut(isFocused ? key.map { KeyboardShortcut($0) } : nil)
        .disabled(preview)
    }

    /// The editor's text view while it has the focus. The selection is read and set on it directly: a SwiftUI
    /// selection binding re-applied its stale value whenever the page re-rendered mid-typing, reversing the text.
    private var textView: NSTextView? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, !tv.isFieldEditor, tv.string == text else {
            return nil
        }
        return tv
    }

    /// The selected range, or the caret, or the end of the text when the editor never had focus.
    private var range: Range<String.Index> {
        if let tv = textView, let r = Range(tv.selectedRange(), in: text) { return r }
        return text.endIndex..<text.endIndex
    }

    /// Selects `r` once the text view shows `newText`, which SwiftUI hands it a moment after the binding changed.
    private func select(_ r: Range<String.Index>, in newText: String, attempt: Int = 0) {
        focusEditor()
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) {
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.string == newText else {
                if attempt < 10 { select(r, in: newText, attempt: attempt + 1) }
                return
            }
            tv.setSelectedRange(NSRange(r, in: newText))
        }
    }

    /// Wraps the selection in `left`/`right`, or inserts both with the caret between them.
    private func wrap(_ left: String, _ right: String) {
        let r = range
        let start = text.distance(from: text.startIndex, to: r.lowerBound)
        let inner = String(text[r])
        text.replaceSubrange(r, with: left + inner + right)
        let from = text.index(text.startIndex, offsetBy: start + left.count)
        select(from..<text.index(from, offsetBy: inner.count), in: text)
    }

    /// Puts `marker` at the start of the line holding the caret.
    private func prefixLine(_ marker: String) {
        let r = range
        let caret = text.distance(from: text.startIndex, to: r.lowerBound)
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        text.insert(contentsOf: marker, at: lineStart)
        let at = text.index(text.startIndex, offsetBy: caret + marker.count)
        select(at..<at, in: text)
    }

    private func focusEditor() {
        if let focus { focus.wrappedValue = true } else { ownFocus = true }
    }

    /// The text view's own switches, set once it is first responder: no Writing Tools (and no Siri button beside
    /// the caret, which macOS 27 adds with them whatever the SwiftUI environment says), no smart quotes or dashes,
    /// which would corrupt code and tables.
    private func tune(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, !tv.isFieldEditor else {
                if attempt < 10 { tune(attempt: attempt + 1) }
                return
            }
            tv.writingToolsBehavior = .none
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
        }
    }

    /// The character under `point`, asked of the text view once AppKit has made it first responder.
    private func placeCaret(at point: CGPoint, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.string == text else {
                if attempt < 10 { placeCaret(at: point, attempt: attempt + 1) }
                return
            }
            // The text view is flipped, so the rendered text's top-left offset maps straight onto it.
            let local = NSPoint(x: point.x + tv.textContainerInset.width, y: point.y + tv.textContainerInset.height)
            let utf16 = min(tv.characterIndexForInsertion(at: local), text.utf16.count)
            tv.setSelectedRange(NSRange(location: utf16, length: 0))
        }
    }

    private var editor: some View {
        // A TextEditor inside a ScrollView sizes itself unpredictably, which left the bottom of the comment
        // box unreachable. A hidden Text with the same content sets the height; the editor is an overlay,
        // so it never takes part in layout. Past maxHeight the editor scrolls on its own.
        Text(text.isEmpty ? " " : text).font(.body).padding(.horizontal, 5).padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)  // ignore whatever height the page proposes
            .hidden()
            .overlay {
                TextEditor(text: $text)
                    .focused(focus ?? $ownFocus)
                    .font(.body)
                    .scrollContentBackground(.hidden)
            }
            .padding(6)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 0.5 : 0), lineWidth: 3)
                    .padding(-1.5)
            )
            .animation(.easeOut(duration: 0.1), value: isFocused)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            // ⌘V with files or an image on the pasteboard: upload them and link them here, instead of
            // letting the text view paste the file paths.
            .background(
                WindowEventMonitor(mask: .keyDown) { e in
                    guard isFocused else { return e }
                    // `tune`'s switches again, for a text view it missed.
                    if let tv = e.window?.firstResponder as? NSTextView,
                        tv.isAutomaticQuoteSubstitutionEnabled || tv.isAutomaticDashSubstitutionEnabled
                    {
                        tv.isAutomaticQuoteSubstitutionEnabled = false
                        tv.isAutomaticDashSubstitutionEnabled = false
                        tv.isAutomaticTextReplacementEnabled = false
                    }
                    // While the mention list shows, the arrows, ↩ and Tab pick from it; Esc dismisses it.
                    // Arrows carry the function and numeric-pad flags, so only the real modifiers count.
                    let plain = e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                    if !candidates.isEmpty, plain {
                        switch e.keyCode {
                        case 125:
                            highlighted = min(highlighted + 1, candidates.count - 1)
                            return nil
                        case 126:
                            highlighted = max(highlighted - 1, 0)
                            return nil
                        case 36, 48:
                            accept(candidates[highlighted])
                            return nil
                        case 53:
                            candidates = []
                            return nil
                        default: break
                        }
                    }
                    if e.keyCode == 36, plain, let tv = e.window?.firstResponder as? NSTextView, continueList(in: tv) {
                        return nil
                    }
                    guard let uploadImage, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                        e.charactersIgnoringModifiers == "v"
                    else { return e }
                    if let files = PastedImage.readFiles() {
                        for f in files { pasteImage(f, uploadImage) }
                        return nil
                    }
                    guard let image = PastedImage.read() else { return e }
                    pasteImage(image, uploadImage)
                    return nil
                })
    }

    /// ↩ on a list line starts the next item ("- ", "2. ", "- [ ] "); on an empty item it ends the list instead.
    /// Typed through the text view, so ⌘Z takes it back like any other keystroke.
    private func continueList(in tv: NSTextView) -> Bool {
        let s = tv.string as NSString
        let caret = tv.selectedRange()
        guard caret.length == 0 else { return false }
        let lineStart = s.lineRange(for: NSRange(location: caret.location, length: 0)).location
        let line = s.substring(with: NSRange(location: lineStart, length: caret.location - lineStart))
        guard let m = line.firstMatch(of: /^(\s*)(?:([-*+])|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?(.*)$/) else {
            return false
        }
        if m.7.isEmpty {
            tv.insertText("", replacementRange: NSRange(location: lineStart, length: caret.location - lineStart))
            return true
        }
        let marker = m.2.map(String.init) ?? "\((Int(m.3!) ?? 0) + 1)\(m.4!)"
        tv.insertText("\n\(m.1)\(marker)\(m.5)\(m.6 == nil ? "" : "[ ] ")", replacementRange: caret)
        return true
    }

    private func pasteImage(_ image: (data: Data, name: String), _ upload: @escaping (Data, String) async throws -> URL)
    {
        uploading = true
        error = nil
        Task {
            defer { uploading = false }
            do {
                let url = try await upload(image.data, image.name)
                wrap("[\(image.name)](\(url.absoluteString))", "")
            } catch { self.error = String(localized: "Couldn't upload the image: \(error.localizedDescription)") }
        }
    }

    private func accept(_ user: JiraUser) {
        guard let r = text.range(of: "@" + query, options: .backwards) else { return }
        mentions[user.displayName] = user.accountId  // before the text change, so onChange knows the name is complete
        let inserted = "@\(user.displayName) "
        let start = text.distance(from: text.startIndex, to: r.lowerBound)
        text.replaceSubrange(r, with: inserted)
        candidates = []
        query = ""
        // The caret goes past the name.
        let at = text.index(text.startIndex, offsetBy: start + inserted.count)
        select(at..<at, in: text)
    }
}

/// An image on the general pasteboard with no text alongside, as PNG with a dated name.
enum PastedImage {
    /// Files copied in the Finder, read into memory with their own names.
    @MainActor static func readFiles() -> [(data: Data, name: String)]? {
        let urls =
            (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL]) ?? []
        let files = urls.compactMap { url -> (Data, String)? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (data, url.lastPathComponent)
        }
        return files.isEmpty ? nil : files
    }

    @MainActor static func read() -> (data: Data, name: String)? {
        let pb = NSPasteboard.general
        guard pb.string(forType: .string) == nil,
            let image = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let f = DateFormatter()  // local time; POSIX so a forced 12-hour clock cannot rewrite the pattern
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return (png, String(localized: "Pasted image \(f.string(from: .now)).png"))
    }
}

/// Lays children out left to right, wrapping like text.
struct Wrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct Chip: View {
    let text: String
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(text)")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// Searchable list of people assignable to an issue or within a project.
struct PeoplePicker: View {
    enum Scope {
        case issue(String)
        case project(String)
    }
    let scope: Scope
    let current: JiraUser?
    var onPick: (JiraUser?) -> Void
    @Environment(\.jira) private var jira
    @State private var query = ""
    @State private var users: [JiraUser] = []

    /// Rows on offer: me, Unassigned, and the matches. The list's height follows, since a popover sizes itself
    /// to its content and a scroll view has no height of its own.
    private var rowCount: Int {
        users.count + (jira?.me != nil && jira?.me?.accountId != current?.accountId ? 1 : 0) + (current != nil ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search people", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let me = jira?.me, me.accountId != current?.accountId {
                        row {
                            onPick(me)
                        } label: {
                            Label("Assign to me", systemImage: "person.fill.checkmark")
                        }
                    }
                    if current != nil {
                        row {
                            onPick(nil)
                        } label: {
                            Label("Unassigned", systemImage: "person.slash")
                        }
                    }
                    ForEach(users) { u in
                        row {
                            onPick(u)
                        } label: {
                            Avatar(user: u, size: 20)
                            Text(u.displayName)
                            Spacer()
                            if u.accountId == current?.accountId {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(height: min(320, CGFloat(max(rowCount, 1)) * 32))
        }
        .padding(10)
        .frame(width: 280)
        .task(id: query) {
            guard let st = jira else { return }
            let (c, q) = (st.client, query)
            let name: String
            let fetch: @Sendable () async throws -> [JiraUser]
            switch scope {
            case .issue(let key):
                name = "assignable-issue-\(key)"
                fetch = { try await c.assignableUsers(key, query: q) }
            case .project(let key):
                name = "assignable-\(key)"
                fetch = { try await c.assignableUsers(project: key, query: q) }
            }
            if q.isEmpty {
                // The list a picker opens with comes from the cache and corrects itself behind; typing searches the site.
                let (now, fresh) = st.memo(name, fetch: fetch)
                if let now { users = now }
                if let list = await fresh.value, query.isEmpty { users = list }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            users = (try? await fetch()) ?? []
        }
    }

    /// One pick, the full width of the popover, with no list box around it.
    private func row<V: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> V) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { label() }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

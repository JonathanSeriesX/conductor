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
    @FocusState private var ownFocus: Bool
    @Environment(\.jira) private var jira
    @State private var candidates: [JiraUser] = []
    @State private var query = ""
    @State private var selection: TextSelection?
    @State private var preview = false
    @State private var uploading = false
    @State private var error: String?
    /// Row of the suggestion list the arrow keys point at.
    @State private var highlighted = 0
    private var isFocused: Bool { focus?.wrappedValue ?? ownFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            formatBar
            if preview {
                ADFView(node: .document(markdown: text, mentions: mentions))
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                    .padding(10)
                .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
            } else {
                editor
            }
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { i, u in
                        Button { accept(u) } label: {
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
                .glassPane(cornerRadius: 10)
                .transition(.opacity)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: isFocused) { _, on in if on, let caret { placeCaret(at: caret) } }
        .onChange(of: text) { _, new in
            // A trailing "@name" drives the suggestion list; anything else dismisses it. A name just accepted
            // from the list (followed by its space) is complete and must not open the list again.
            if let m = new.firstMatch(of: /@([\p{L}\p{N}][\p{L}\p{N} .'-]{0,30})$/),
               !mentions.keys.contains(where: { String(m.1).hasPrefix($0 + " ") || String(m.1) == $0 }) { query = String(m.1) }
            else { query = ""; candidates = [] }
        }
        .task(id: query) {
            guard !query.isEmpty, let c = jira?.client else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = (try? await c.users(matching: query)) ?? []
            highlighted = 0
            withAnimation(.easeOut(duration: 0.15)) { candidates = Array(found.filter { $0.active != false }.prefix(5)) }
        }
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
            if uploading { ProgressView().controlSize(.mini).padding(.leading, 6) }
            Spacer()
            Toggle(isOn: $preview) { Label("Preview", systemImage: preview ? "eye.fill" : "eye") }
                .toggleStyle(.button).buttonStyle(.plain).labelStyle(.iconOnly)
                .foregroundStyle(preview ? Color.accentColor : .secondary)
                .help("Preview as Jira will show it")
        }
        .font(.callout)
    }

    private func tool(_ symbol: String, _ help: LocalizedStringKey, key: KeyEquivalent? = nil, _ action: @escaping () -> Void) -> some View {
        // A Label, so VoiceOver reads "Quote" rather than the symbol's own name ("Lyrics").
        Button(action: action) { Label(help, systemImage: symbol).labelStyle(.iconOnly).frame(width: 24, height: 20).contentShape(.rect) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
            .keyboardShortcut(isFocused ? key.map { KeyboardShortcut($0) } : nil)
            .disabled(preview)
    }

    /// The selected range, or the caret, or the end of the text when the editor never had focus.
    private var range: Range<String.Index> {
        if case .selection(let r) = selection?.indices, r.upperBound <= text.endIndex { return r }
        return text.endIndex..<text.endIndex
    }

    /// Wraps the selection in `left`/`right`, or inserts both with the caret between them.
    private func wrap(_ left: String, _ right: String) {
        let r = range
        let start = text.distance(from: text.startIndex, to: r.lowerBound)
        let inner = String(text[r])
        text.replaceSubrange(r, with: left + inner + right)
        let from = text.index(text.startIndex, offsetBy: start + left.count)
        selection = TextSelection(range: from..<text.index(from, offsetBy: inner.count))
        focusEditor()
    }

    /// Puts `marker` at the start of the line holding the caret.
    private func prefixLine(_ marker: String) {
        let r = range
        let caret = text.distance(from: text.startIndex, to: r.lowerBound)
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        text.insert(contentsOf: marker, at: lineStart)
        let at = text.index(text.startIndex, offsetBy: caret + marker.count)
        selection = TextSelection(insertionPoint: at)
        focusEditor()
    }

    private func focusEditor() {
        if let focus { focus.wrappedValue = true } else { ownFocus = true }
    }

    /// The character under `point`, asked of the text view once AppKit has made it first responder, then set
    /// through the selection binding: SwiftUI owns the selection and would undo a direct change.
    private func placeCaret(at point: CGPoint, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.string == text else {
                if attempt < 10 { placeCaret(at: point, attempt: attempt + 1) }
                return
            }
            // The text view is flipped, so the rendered text's top-left offset maps straight onto it.
            let local = NSPoint(x: point.x + tv.textContainerInset.width, y: point.y + tv.textContainerInset.height)
            let utf16 = min(tv.characterIndexForInsertion(at: local), text.utf16.count)
            selection = TextSelection(insertionPoint: text.utf16.index(text.utf16.startIndex, offsetBy: utf16))
        }
    }

    private var editor: some View {
        // A TextEditor inside a ScrollView sizes itself unpredictably, which left the bottom of the comment
        // box unreachable. A hidden Text with the same content sets the height; the editor is an overlay,
        // so it never takes part in layout. Past maxHeight the editor scrolls on its own.
        Text(text.isEmpty ? " " : text).font(.body).padding(.horizontal, 5).padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)   // ignore whatever height the page proposes
                .hidden()
                .overlay {
                    TextEditor(text: $text, selection: $selection)
                        .focused(focus ?? $ownFocus)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                }
                .padding(6)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                // ⌘V with files or an image on the pasteboard: upload them and link them here, instead of
                // letting the text view paste the file paths.
                .background(WindowEventMonitor(mask: .keyDown) { e in
                    guard isFocused else { return e }
                    // Smart quotes and dashes would corrupt code and tables; the text view is only reachable here.
                    if let tv = e.window?.firstResponder as? NSTextView, tv.isAutomaticQuoteSubstitutionEnabled || tv.isAutomaticDashSubstitutionEnabled {
                        tv.isAutomaticQuoteSubstitutionEnabled = false
                        tv.isAutomaticDashSubstitutionEnabled = false
                        tv.isAutomaticTextReplacementEnabled = false
                    }
                    // While the mention list shows, the arrows, ↩ and Tab pick from it; Esc dismisses it.
                    if !candidates.isEmpty, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                        switch e.keyCode {
                        case 125: highlighted = min(highlighted + 1, candidates.count - 1); return nil
                        case 126: highlighted = max(highlighted - 1, 0); return nil
                        case 36, 48: accept(candidates[highlighted]); return nil
                        case 53: candidates = []; return nil
                        default: break
                        }
                    }
                    guard let uploadImage, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          e.charactersIgnoringModifiers == "v" else { return e }
                    if let files = PastedImage.readFiles() {
                        for f in files { pasteImage(f, uploadImage) }
                        return nil
                    }
                    guard let image = PastedImage.read() else { return e }
                    pasteImage(image, uploadImage)
                    return nil
                })
    }

    private func pasteImage(_ image: (data: Data, name: String), _ upload: @escaping (Data, String) async throws -> URL) {
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
        mentions[user.displayName] = user.accountId   // before the text change, so onChange knows the name is complete
        let inserted = "@\(user.displayName) "
        let start = text.distance(from: text.startIndex, to: r.lowerBound)
        text.replaceSubrange(r, with: inserted)
        // The caret stays where the "@" was unless it is moved past the name.
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: start + inserted.count))
        candidates = []
        query = ""
        focusEditor()
    }
}

/// An image on the general pasteboard with no text alongside, as PNG with a dated name.
enum PastedImage {
    /// Files copied in the Finder, read into memory with their own names.
    @MainActor static func readFiles() -> [(data: Data, name: String)]? {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
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
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let f = DateFormatter()   // local time; POSIX so a forced 12-hour clock cannot rewrite the pattern
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
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
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
    enum Scope { case issue(String), project(String) }
    let scope: Scope
    let current: JiraUser?
    var onPick: (JiraUser?) -> Void
    @Environment(\.jira) private var jira
    @State private var query = ""
    @State private var users: [JiraUser] = []

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search people", text: $query).textFieldStyle(.roundedBorder)
            List {
                if let me = jira?.me, me.accountId != current?.accountId {
                    Button { onPick(me) } label: { Label("Assign to me", systemImage: "person.fill.checkmark") }
                }
                if current != nil {
                    Button { onPick(nil) } label: { Label("Unassigned", systemImage: "person.slash") }
                }
                ForEach(users) { u in
                    Button { onPick(u) } label: {
                        HStack { Avatar(user: u, size: 20); Text(u.displayName); Spacer()
                            if u.accountId == current?.accountId { Image(systemName: "checkmark").foregroundStyle(.secondary) } }
                    }
                }
            }
            .buttonStyle(.plain)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)   // the list's own white would hide the popover material
        }
        .padding(10)
        .frame(width: 280, height: 320)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = jira?.client else { return }
            switch scope {
            case .issue(let key): users = (try? await c.assignableUsers(key, query: query)) ?? []
            case .project(let key): users = (try? await c.assignableUsers(project: key, query: query)) ?? []
            }
        }
    }
}

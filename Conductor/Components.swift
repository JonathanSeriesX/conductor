import SwiftUI

// MARK: - Liquid Glass with a Sequoia fallback
//
// Every macOS 26 effect the app uses goes through one of these, so on 26 the app looks exactly as designed and
// on macOS 15 it falls back to the standard control of the day. Nothing else in the app is version-specific.

extension View {
    /// `.glass` / `.glassProminent` on macOS 26; `.bordered` / `.borderedProminent` on Sequoia.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A glass pane on macOS 26; the regular material on Sequoia.
    @ViewBuilder func glassPane(cornerRadius r: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: r))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: r))
        }
    }

    /// Blurs what scrolls under a transparent toolbar. Sequoia's toolbar has an opaque background already.
    @ViewBuilder func softScrollEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }

    /// A bottom bar that the system blurs on macOS 26; on Sequoia an inset with the `.bar` backing, so rows
    /// don't scroll through it.
    @ViewBuilder func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar().background(.bar) }
        }
    }
}

extension CustomizableToolbarContent {
    /// The issue title sits straight on the toolbar on macOS 26, with no capsule behind it and the buttons pushed
    /// to the trailing end. Sequoia's toolbar draws no capsules and groups by placement on its own.
    @ToolbarContentBuilder func glassTitle() -> some CustomizableToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            self
        }
    }
}

extension ToolbarContent {
    /// The same for a toolbar that cannot be customized: the issue page's, which comes and goes in the preview column.
    @ToolbarContentBuilder func glassTitle() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            self
        }
    }
}

/// Lets neighbouring glass panes blend on macOS 26; plain content on Sequoia.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// The window background, so glass panes sit on the system colour in light and dark mode.
struct Backdrop: View {
    var body: some View { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
}

@MainActor enum ImageCache {
    static let shared = NSCache<NSURL, NSImage>()
}

/// Image that goes through the Jira client so site-hosted avatars and thumbnails get auth.
struct RemoteImage: View {
    let url: URL?
    var placeholder: String = "photo"
    @Environment(Session.self) private var session
    @State private var loaded: NSImage?

    // Memory and disk hits resolve in `body`, so a cached icon draws in the first frame instead of after a task hop.
    private var image: NSImage? {
        if let loaded { return loaded }
        guard let url else { return nil }
        if let hit = ImageCache.shared.object(forKey: url as NSURL) { return hit }
        guard let data = DiskCache.imageDataNow(for: url), let img = NSImage(data: data) else { return nil }
        ImageCache.shared.setObject(img, forKey: url as NSURL)
        return img
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: placeholder).resizable().scaledToFit().padding(2).foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            guard let client = session.client(for: url), let data = try? await client.data(for: url),
                let img = await DiskCache.decodeImage(data, maxPixels: 256)
            else { return }
            DiskCache.saveImage(data, for: url)
            ImageCache.shared.setObject(img, forKey: url as NSURL)
            loaded = img
        }
    }
}

struct Avatar: View {
    let user: JiraUser?
    var size: CGFloat = 22
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if let user {
                RemoteImage(url: user.avatar, placeholder: "person.crop.circle.fill")
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").resizable().scaledToFit().foregroundStyle(
                    .tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        // A ring on a selected row, so an orange avatar still reads on the orange selection.
        .overlay { if prominence == .increased { Circle().stroke(.white.opacity(0.9), lineWidth: 1.5) } }
        .help(user?.displayName ?? String(localized: "Unassigned"))
        .accessibilityLabel(user?.displayName ?? String(localized: "Unassigned"))
    }
}

extension StatusCategory {
    var color: Color {
        switch key {
        case "done": .green
        case "indeterminate": .blue
        default: .secondary
        }
    }
}

struct StatusPill: View {
    let status: Status
    /// `.increased` inside a selected list row, where the accent colour is the background.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let tint: Color = prominence == .increased ? .white : status.statusCategory.color
        Text(status.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(prominence == .increased ? 0.28 : 0.16), in: .capsule)
    }
}

/// Jira's coloured priority SVG, given a light disc when sitting on a selection colour.
struct PriorityIcon: View {
    let priority: Priority
    var size: CGFloat = 14
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        RemoteImage(url: priority.iconUrl, placeholder: "minus")
            .accessibilityLabel(priority.name)
            .frame(width: size, height: size)
            .padding(2)  // constant so the glyph does not shift when the disc appears
            .background(prominence == .increased ? .white.opacity(0.9) : .clear, in: .circle)
            .help(priority.name)
    }
}

struct GlassCard<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frosted(cornerRadius: 20)
    }
}

extension View {
    /// White on white (black on black in dark mode): the window background at partial opacity with a hairline,
    /// like a Tahoe sidebar. Materials carry a grey tint, and lensing glass is too busy for text.
    func frosted(cornerRadius r: CGFloat, opacity: Double = 0.7) -> some View {
        background(.background.opacity(opacity), in: .rect(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(.quaternary.opacity(0.6), lineWidth: 1))
    }
}

/// "1 issue", "2 issues", "50+ issues" for subtitles; the plural forms live in the string catalog.
func issues(_ n: Int, more: Bool = false) -> String {
    more ? String(localized: "\(n)+ issues") : String(localized: "\(n) issues")
}

extension View {
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })
        ) {
            Button("OK") { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

/// Sees events of `mask` aimed at the window this view sits in, before any view handles them; return nil to swallow one.
/// Invisible to clicks. SwiftUI has no modifier for a key press outside a focused view.
struct WindowEventMonitor: NSViewRepresentable {
    let mask: NSEvent.EventTypeMask
    let handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> MonitorView { MonitorView(mask: mask) }
    func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }

    final class MonitorView: NSView {
        let mask: NSEvent.EventTypeMask
        var handler: (NSEvent) -> NSEvent? = { $0 }
        private var monitor: Any?

        init(mask: NSEvent.EventTypeMask) {
            self.mask = mask
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
                guard let self, e.window === self.window else { return e }
                return self.handler(e)
            }
        }
    }
}

extension NSWindow {
    /// Puts the keyboard on the issue list (the window's table), or on nothing when there is none.
    func focusList() {
        func table(in v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for s in v.subviews { if let t = table(in: s) { return t } }
            return nil
        }
        makeFirstResponder(contentView.flatMap(table))
    }
}

/// A closed popover leaves the keyboard on the window's first key view when it had a text field of its own: the
/// search field in the list window, the comment box in an issue window. The list, or nothing, is where it came from.
@MainActor enum PopoverFocusReturn {
    static func install() {
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) {
            _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let w = NSApp.keyWindow, w.firstResponder is NSTextView else { return }
                    w.focusList()
                }
            }
        }
    }
}

extension View {
    /// Marks a value the user can change: it lights up under the pointer, as a field does on the web. Read-only
    /// values stay plain, so the two can be told apart. Off, it changes nothing.
    func editable(_ on: Bool = true) -> some View { modifier(Editable(on: on)) }
}

private struct Editable: ViewModifier {
    let on: Bool
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hover && on ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
            .padding(.horizontal, -6).padding(.vertical, -3)  // the highlight draws outside; nothing moves
            .onHover { hover = $0 }
    }
}

/// AppKit swallows the click that dismisses a menu. Here it goes on to whatever it landed on, so a right-click
/// on a project followed by a click on the disclosure beside it needs no third click.
@MainActor enum MenuClickThrough {
    static func install() {
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
            note in
            // Chip menus hop to the chip under the mouse on their own (ChipMenuController).
            let chip = (note.object as? NSMenu)?.identifier?.rawValue == "chip"
            MainActor.assumeIsolated {
                // Tracking ends on the mouse-up of the click that closed the menu. A click on an item ends
                // over the menu's own window; one outside ends over whatever is under the mouse.
                guard !chip, let e = NSApp.currentEvent, e.type == .leftMouseUp || e.type == .rightMouseUp
                else { return }
                let at = NSEvent.mouseLocation
                let top = NSWindow.windowNumber(at: at, belowWindowWithWindowNumber: 0)
                guard let window = NSApp.window(withWindowNumber: top), !window.className.contains("Menu")
                else { return }
                let down: NSEvent.EventType = e.type == .leftMouseUp ? .leftMouseDown : .rightMouseDown
                let local = window.convertPoint(fromScreen: at)
                DispatchQueue.main.async {
                    for type in [down, e.type] {
                        guard
                            let replay = NSEvent.mouseEvent(
                                with: type, location: local, modifierFlags: e.modifierFlags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: top, context: nil,
                                eventNumber: 0, clickCount: 1, pressure: 1)
                        else { continue }
                        window.sendEvent(replay)
                    }
                }
            }
        }
    }
}

extension Binding where Value: Sendable {
    /// `Binding($optional)` force-unwraps on every read, and SwiftUI reads a child's bindings once more after
    /// the value went nil (Save sets the draft to nil while the editor is still on screen), which crashed.
    /// This one hands back `fallback` instead.
    init(_ source: Binding<Value?>, or fallback: Value) {
        // Writes after the draft went nil are the field's own echo of its last text; taking them would reopen it.
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { if source.wrappedValue != nil { source.wrappedValue = $0 } })
    }
}

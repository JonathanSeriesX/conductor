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
    /// `band`: inside a split-view column (the main window's preview) AppKit never activates the scroll view's
    /// pocket, so nothing blurs under the toolbar; there the column draws the window toolbar's band itself, once
    /// content has scrolled under it.
    @ViewBuilder func softScrollEdge(band: Bool? = nil) -> some View {
        if #available(macOS 26, *) {
            if let band {
                scrollEdgeEffectStyle(.soft, for: .top).overlay(alignment: .top) { ToolbarBand(visible: band) }
            } else {
                scrollEdgeEffectStyle(.soft, for: .top)
            }
        } else {
            self
        }
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
            // Sequoia has no ToolbarSpacer; a Spacer item is its flexible space, and pushes the buttons trailing.
            ToolbarItem(id: "flex") { Spacer() }
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
            ToolbarItem { Spacer() }
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
    /// The whole image inside the frame (a thumbnail) rather than the frame filled with it (an avatar, an icon).
    var fit = false
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
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill).inactiveDim()
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

extension View {
    /// Greys a coloured element while its window is inactive, as the system does with sidebar icons and the
    /// selection. Text stays as it is; pills, badges and every remote image (icons, avatars) lose their colour.
    func inactiveDim() -> some View { modifier(InactiveDim()) }
}

private struct InactiveDim: ViewModifier {
    @Environment(\.appearsActive) private var active
    func body(content: Content) -> some View { content.grayscale(active ? 0 : 1).opacity(active ? 1 : 0.6) }
}

/// "Today", "Yesterday", "In 3 days", "Next month": whole days from today, in the user's language, as Mail dates
/// its rows. Within two weeks the count is exact; "next week" alone would cover 6 to 13 days.
@MainActor func relativeDay(_ date: Date) -> String {
    let cal = Calendar.current
    let day = cal.startOfDay(for: date)
    let today = cal.startOfDay(for: .now)
    let days = cal.dateComponents([.day], from: today, to: day).day ?? 0
    if days == 0 { return String(localized: "Today") }  // the formatter would say "Now"
    if abs(days) > 1, abs(days) <= 13 { return relativeDayFormatter.localizedString(from: DateComponents(day: days)) }
    return relativeDayFormatter.localizedString(for: day, relativeTo: today)
}

@MainActor private let relativeDayFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.dateTimeStyle = .named
    f.unitsStyle = .full
    f.formattingContext = .beginningOfSentence
    return f
}()

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
            .inactiveDim()
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
    /// "• M to add", faint, after the title: the key that acts on the card.
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                // The gap before the bullet equals the space after it.
                HStack(spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.secondary)
                    if let hint { Text(hint).font(.subheadline).foregroundStyle(.secondary) }
                }
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

/// A small-caps caption over a value: the issue page's fields and the New Issue window's.
@MainActor func field<V: View>(_ name: LocalizedStringKey, hint: String? = nil, @ViewBuilder _ value: () -> V)
    -> some View
{
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 2) {
            Text(name).textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let hint { Text(hint).font(.caption2).foregroundStyle(.secondary) }  // "• A or ⌘⇧A to assign"
        }
        value()
    }
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

    /// Puts the keyboard in `focus` as the view appears. Focus set in the same pass that creates the field is
    /// lost; one turn of the run loop later it sticks.
    func focusSoon(_ focus: FocusState<Bool>.Binding) -> some View {
        task { DispatchQueue.main.async { focus.wrappedValue = true } }
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

/// Lays the window's toolbar out before a frame is committed whenever a SwiftUI toolbar item has changed width (the
/// list's count arriving, a longer title). AppKit's own pass cannot: an item that grows during the toolbar's layout
/// re-requests one that is dropped when the pass returns, and a change SwiftUI applies inside the commit comes after
/// every pass. Either way the frame would show the new content centred in the old item viewer, the list title over
/// the sidebar toggle, until the next pass.
struct ToolbarRelayout: NSViewRepresentable {
    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) {}

    final class Watcher: NSView {
        nonisolated(unsafe) private var observer: CFRunLoopObserver?
        private var widths: [ObjectIdentifier: CGFloat] = [:]
        /// Found once per window: the search walked the whole window tree on every run-loop pass, which kept a
        /// core a third busy while any other window turned the loop.
        private weak var cachedToolbar: NSView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
            cachedToolbar = nil
            guard window != nil else { return }
            // CoreAnimation commits at order 2_000_000; this runs just before, after AppKit's and SwiftUI's passes.
            observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999
            ) {
                [weak self] _, _ in
                MainActor.assumeIsolated { self?.relayoutIfChanged() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        deinit { if let observer { CFRunLoopObserverInvalidate(observer) } }

        /// A window's first content is laid out and flushed inside the call that orders it on screen, with no
        /// run-loop turn in between; this is the one hook after that layout and before the flush.
        override func viewWillDraw() {
            super.viewWillDraw()
            relayoutIfChanged()
        }

        private func relayoutIfChanged() {
            guard let window, window.isVisible, window.occlusionState.contains(.visible), let toolbar = toolbarView,
                let items = window.toolbar?.items
            else { return }
            var changed = toolbar.needsLayout
            for v in items.compactMap(\.view) where String(describing: type(of: v)).contains("Hosting") {
                // Measured only once SwiftUI has marked the item dirty, or the first time: a fitting size costs a
                // constraint pass, and other windows turn the run loop all the time (a board, an animation).
                let key = ObjectIdentifier(v)
                guard widths[key] == nil || v.needsLayout || v.needsUpdateConstraints else { continue }
                let width = v.fittingSize.width  // asking applies a pending SwiftUI change now, before the commit
                if widths.updateValue(width, forKey: key) != width { changed = true }
            }
            guard changed else { return }
            toolbar.needsLayout = true
            toolbar.layoutSubtreeIfNeeded()
        }

        /// The toolbar view lays its items out on its own layout pass; nothing public asks for one. It sits two
        /// levels under the titlebar container, so the search walks the titlebar's siblings of the content view.
        private var toolbarView: NSView? {
            if let cachedToolbar, cachedToolbar.window === window { return cachedToolbar }
            func find(_ v: NSView) -> NSView? {
                if String(describing: type(of: v)) == "NSToolbarView" { return v }
                for s in v.subviews where s !== window?.contentView { if let t = find(s) { return t } }
                return nil
            }
            cachedToolbar = window?.contentView?.superview.flatMap(find)
            return cachedToolbar
        }
    }
}

/// The first table (a SwiftUI List) under a view, depth first.
@MainActor func firstTable(in v: NSView) -> NSTableView? {
    if let t = v as? NSTableView { return t }
    for s in v.subviews { if let t = firstTable(in: s) { return t } }
    return nil
}

extension NSWindow {
    /// Puts the keyboard on the issue list (the window's table), or on nothing when there is none.
    func focusList() { makeFirstResponder(contentView.flatMap(firstTable)) }
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

/// A reader's right-click on selectable text: with a selection, a menu with Copy alone; without one, nothing.
/// SwiftUI's selectable text would otherwise hand the click to the system's text menu (Cut, Paste, Font,
/// Spelling…, drawn out of process), which an app can neither trim nor replace with `.contextMenu`. So the click
/// is taken first: this view sits under the text and marks its area for the monitor `ReaderMenus.install`.
struct ReaderMenu: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderMenuArea { ReaderMenuArea() }
    func updateNSView(_ view: ReaderMenuArea, context: Context) {}
}

final class ReaderMenuArea: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // the text above takes every click
}

@MainActor enum ReaderMenus {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { e in
            guard let w = e.window, let root = w.contentView else { return e }
            let at = root.convert(e.locationInWindow, from: nil)
            // Only marked text: editors (the composer, a summary or comment being edited) are never marked, so
            // they keep their own menu. SwiftUI's selectable text is a text view that calls itself editable too,
            // so that cannot tell them apart.
            guard let area = areas(in: root).last(where: { $0.convert($0.bounds, to: root).contains(at) }) else {
                return e
            }
            // A selection in this text: SwiftUI's text interaction view holds it and has the keyboard, and says
            // whether Copy has anything to copy, as it does for the Edit menu. Anything else: no menu.
            let rect = area.convert(area.bounds, to: root)
            let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
            if let holder = w.firstResponder as? NSView, holder.convert(holder.bounds, to: root).intersects(rect),
                holder.responds(to: #selector(NSText.copy(_:))),
                (holder as? NSMenuItemValidation)?.validateMenuItem(copy)
                    ?? (holder as? NSUserInterfaceValidations)?.validateUserInterfaceItem(copy) ?? true
            {
                copy.target = holder
                let menu = NSMenu()
                menu.autoenablesItems = false  // validation would look for a target from the area, and grey it
                menu.addItem(copy)
                NSMenu.popUpContextMenu(menu, with: e, for: area)
            }
            return nil
        }
    }

    /// Every marked area in the window, outermost first, so the innermost one under the pointer wins.
    private static func areas(in view: NSView) -> [ReaderMenuArea] {
        guard !view.isHidden else { return [] }
        var out: [ReaderMenuArea] = []
        if let a = view as? ReaderMenuArea { out.append(a) }
        for sub in view.subviews { out += areas(in: sub) }
        return out
    }
}

/// The window toolbar's background, drawn: a blur washed nearly white (black in dark mode) over the toolbar's
/// height, ending at the system's hairline. Shown only while content is under it, as the window's own is.
struct ToolbarBand: View {
    let visible: Bool

    var body: some View {
        GeometryReader { g in
            band.frame(height: g.safeAreaInsets.top).offset(y: -g.safeAreaInsets.top)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible)
        .allowsHitTesting(false)
    }

    /// The bar material is the titlebar's; the hairline is the one the window draws under its toolbar.
    private var band: some View {
        Rectangle().fill(.bar).overlay(alignment: .bottom) { Divider() }
    }
}


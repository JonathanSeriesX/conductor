import SwiftUI

/// What sits behind the glass panes. Chosen in Settings; "plain" follows the window appearance.
struct Backdrop: View {
    @AppStorage("backdrop") private var stored = "mesh"
    @Environment(\.backdropOverride) private var override
    private var style: String { override ?? stored }

    var body: some View {
        Group {
            switch style {
            case "plain":
                Color(nsColor: .windowBackgroundColor)
            case "muted":
                mesh.opacity(0.1)
            case "dusk":
                MeshGradient(width: 3, height: 3, points: Self.points,
                             colors: [.orange, .pink, .purple, .red, .purple, .indigo, .brown, .indigo, .blue]).opacity(0.2)
            case "forest":
                MeshGradient(width: 3, height: 3, points: Self.points,
                             colors: [.mint, .green, .teal, .green, .teal, .cyan, .yellow, .mint, .blue]).opacity(0.2)
            default:
                mesh.opacity(0.22)
            }
        }
        .ignoresSafeArea()
    }

    private static let points: [SIMD2<Float>] = [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]]

    private var mesh: some View {
        MeshGradient(width: 3, height: 3, points: Self.points,
                     colors: [.indigo, .blue, .cyan, .purple, .blue, .teal, .pink, .indigo, .mint])
    }
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

    // Memory hits resolve in `body`, so a cached icon draws in the first frame instead of after a task hop.
    private var image: NSImage? { loaded ?? url.flatMap { ImageCache.shared.object(forKey: $0 as NSURL) } }

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
            if let data = await DiskCache.imageData(for: url), let img = await DiskCache.decodeImage(data, maxPixels: 256) {
                ImageCache.shared.setObject(img, forKey: url as NSURL)
                loaded = img
                return
            }
            guard let client = session.client(for: url), let data = try? await client.data(for: url),
                  let img = await DiskCache.decodeImage(data, maxPixels: 256) else { return }
            DiskCache.saveImage(data, for: url)
            ImageCache.shared.setObject(img, forKey: url as NSURL)
            loaded = img
        }
    }
}

struct Avatar: View {
    let user: JiraUser?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let user {
                RemoteImage(url: user.avatar, placeholder: "person.crop.circle.fill")
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").resizable().scaledToFit().foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .help(user?.displayName ?? "Unassigned")
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
            .frame(width: size, height: size)
            .padding(2) // constant so the glyph does not shift when the disc appears
            .background(prominence == .increased ? .white.opacity(0.9) : .clear, in: .circle)
            .help(priority.name)
    }
}

struct GlassCard<Content: View>: View {
    var title: String?
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
    /// The sidebar-style frosted surface with a hairline: calmer than lensing glass for content that is read.
    func frosted(cornerRadius r: CGFloat) -> some View {
        background(.regularMaterial, in: .rect(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(.quaternary, lineWidth: 1))
    }
}

extension View {
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert("Something went wrong", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
            Button("OK") { error.wrappedValue = nil }
        } message: { Text(error.wrappedValue ?? "") }
    }
}

extension EnvironmentValues {
    /// Lets a preview swatch show a style other than the one in Settings.
    @Entry var backdropOverride: String? = nil
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

        init(mask: NSEvent.EventTypeMask) { self.mask = mask; super.init(frame: .zero) }
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

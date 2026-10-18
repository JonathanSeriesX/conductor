import AppKit

/// With CONDUCTOR_MARKS set: named points of the launch on stderr, as ms since the process was
/// started and as host uptime, so an outside judge (a window poller, a screen recorder) lines up with them. With
/// CONDUCTOR_SNAP set too, the main window's content is rendered to PNG and written base64 on stderr at the first
/// frame that had rows and three seconds later, for a pixel comparison between builds. With CONDUCTOR_SNAP_EVERY=<s>
/// (marks or not), it is rendered every s seconds of the first minute, on the same beat from the process start in
/// every build and labelled with the elapsed seconds, so a scripted interaction compares state by state.
@MainActor enum LaunchProbe {
    static let enabled = ProcessInfo.processInfo.environment["CONDUCTOR_MARKS"] != nil
    private static var done: Set<String> = []
    private static var tickers: [Ticker] = []

    /// When the process started, in wall-clock and host-uptime seconds, from the kernel's record of it.
    private static let start: (wall: Double, uptime: Double) = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let nowWall = Date().timeIntervalSince1970
        let nowUp = ProcessInfo.processInfo.systemUptime
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return (nowWall, nowUp) }
        let tv = info.kp_proc.p_starttime
        let wall = Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
        return (wall, nowUp - (nowWall - wall))
    }()

    static func mark(_ name: String) {
        guard enabled else { return }
        let up = ProcessInfo.processInfo.systemUptime
        let ms = (up - start.uptime) * 1000
        FileHandle.standardError.write(String(format: "MARK %@ %.1f up=%.4f\n", name, ms, up).data(using: .utf8)!)
    }

    /// `mark` on every call, numbered, for the first 60 calls of a name: how often a body runs during launch.
    private static var ticks: [String: Int] = [:]
    static func tick(_ name: String) {
        guard enabled else { return }
        let n = ticks[name, default: 0] + 1
        ticks[name] = n
        if n <= 60 { mark("\(name)#\(n)") }
        if name == "detail.body", n == 1 { watchVsync("vsync.page") }
    }

    /// `mark`, the first time only; `when` false leaves it for a later call.
    static func once(_ name: String, when: Bool = true) {
        guard enabled, when, !done.contains(name) else { return }
        done.insert(name)
        mark(name)
        if name == "list.rows" { watchVsync("vsync.rows") }
    }

    /// Every stretch the main run loop spends busy (from waking to the next wait) over 4 ms, for the first 4 s:
    /// where the main thread is blocked, as opposed to waiting on the disk or the network.
    private static var woke: Double = 0
    private static func watchBusy() {
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) {
            _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            guard now - start.uptime < 3 else { return }
            let name: String
            switch activity {
            case .entry: name = "entry"
            case .beforeTimers: name = "timers"
            case .beforeSources: name = "sources"
            case .beforeWaiting: name = "sleep"
            case .afterWaiting: name = "wake"
            case .exit: name = "exit"
            default: name = "?"
            }
            if activity == .afterWaiting { woke = now }
            if activity == .beforeWaiting, woke > 0, now - woke > 0.004 {
                FileHandle.standardError.write(
                    String(format: "BUSY %.1f %.1f\n", (woke - start.uptime) * 1000, (now - start.uptime) * 1000)
                        .data(using: .utf8)!)
            }
            if activity != .beforeTimers {
                FileHandle.standardError.write(
                    String(format: "RL %@ %.1f\n", name, (now - start.uptime) * 1000).data(using: .utf8)!)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }

    static func install() {
        if let every = ProcessInfo.processInfo.environment["CONDUCTOR_SNAP_EVERY"].flatMap(Double.init), every > 0 {
            snapEvery(every)
        }
        guard enabled else { return }
        once("app.init")
        watchBusy()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { once("app.launched") } }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            _ in MainActor.assumeIsolated { once("window.key") }
        }
    }

    /// The first display-link tick after the list's rows were built: the pass that built them has committed and the
    /// screen has refreshed since, so the rows are on glass (give or take one refresh).
    /// "vsync.page": the same after the preview's first pass with the issue's content.
    private static func watchVsync(_ label: String) {
        let t = Ticker(label)
        tickers.append(t)
        NSScreen.screens[0].displayLink(target: t, selector: #selector(Ticker.tick)).add(to: .main, forMode: .common)
    }

    private final class Ticker: NSObject {
        let label: String
        init(_ label: String) { self.label = label }
        @objc func tick(_ l: CADisplayLink) {
            l.invalidate()
            let label = label
            MainActor.assumeIsolated {
                once(label)
                guard label == "vsync.rows", ProcessInfo.processInfo.environment["CONDUCTOR_SNAP"] != nil else {
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { snap("first") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { snap("settled") }
            }
        }
    }

    /// A snapshot at each multiple of `every` seconds after the process started, for the first minute.
    private static func snapEvery(_ every: Double) {
        let up = ProcessInfo.processInfo.systemUptime - start.uptime
        let next = ((up / every).rounded(.down) + 1) * every
        guard next <= 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (next - up)) {
            snap(String(format: "t%04.1f", next))
            snapEvery(every)
        }
    }

    /// The main window's content view rendered offscreen, as PNG, base64 on one stderr line.
    private static func snap(_ label: String) {
        guard
            let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }),
            let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)
        else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        FileHandle.standardError.write("SNAP \(label) \(png.base64EncodedString())\n".data(using: .utf8)!)
    }
}

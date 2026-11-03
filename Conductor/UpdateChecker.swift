import AppKit

/// Compares the running version with the latest GitHub release. Quiet unless asked or newer.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private let releases = URL(string: "https://api.github.com/repos/JonathanSeriesX/conductor/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
    }

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Daily check driven by the launch; skipped when turned off in Settings.
    func checkIfDue() {
        guard UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(interactive: false)
    }

    func check(interactive: Bool) {
        Task {
            do {
                var req = URLRequest(url: releases)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 404: the repository has no release yet, so nothing is newer than this build.
                guard status == 200 || status == 404 else {
                    if interactive {
                        alert(
                            String(localized: "Couldn't check for updates"),
                            String(localized: "GitHub returned HTTP \(status)."))
                    }
                    return
                }
                let r = status == 200 ? try JSONDecoder().decode(Release.self, from: data) : nil
                // Stamped only once GitHub answered: a launch without network checks again next time.
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                let latest = r?.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) ?? current
                if let r, Self.isNewer(latest, than: current) {
                    if UserDefaults.standard.string(forKey: "skippedVersion") == latest, !interactive { return }
                    offer(latest, url: r.html_url, notes: r.body)
                } else if interactive {
                    alert(
                        String(localized: "You're up to date"),
                        String(localized: "Conductor \(current) is the latest version."))
                }
            } catch {
                if interactive {
                    alert(
                        String(localized: "Couldn't check for updates"),
                        String(localized: "GitHub didn't answer: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// "1.2.10" > "1.2.9"; missing components count as zero.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func offer(_ version: String, url: String, notes: String?) {
        let a = NSAlert()
        a.messageText = String(localized: "Conductor \(version) is available")
        a.informativeText =
            (notes?.isEmpty == false ? notes! : String(localized: "You have \(current).")).prefix(600).description
        a.addButton(withTitle: String(localized: "Download"))
        a.addButton(withTitle: String(localized: "Later"))
        a.addButton(withTitle: String(localized: "Skip This Version"))
        switch a.runModal() {
        case .alertFirstButtonReturn: if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .alertThirdButtonReturn: UserDefaults.standard.set(version, forKey: "skippedVersion")
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

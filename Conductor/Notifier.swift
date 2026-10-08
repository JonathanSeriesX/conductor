import AppKit
import UserNotifications

/// Polls every account for things worth a banner: assignments to you, status changes and new
/// comments on issues you're involved in. Jira Cloud has no push feed, so this is the honest option.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private weak var session: Session?
    private var task: Task<Void, Never>?
    private var lastPoll: [UUID: Date] = [:]
    private var meIDs: [UUID: String] = [:]
    private var seenComments: Set<String> = []
    /// Assignment and status banners already shown, keyed by issue and its `updated` stamp: the poll
    /// windows overlap by a minute, so the same change comes back once more.
    private var announced: Set<String> = []
    private var unread = 0

    func start(_ session: Session) {
        self.session = session
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Notifier.shared.clearBadge() }
        }
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let minutes = UserDefaults.standard.integer(forKey: "pollMinutes")
                try? await Task.sleep(for: .seconds(max(1, minutes == 0 ? 3 : minutes) * 60))
            }
        }
    }

    private var enabled: Bool { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true }

    private func poll() async {
        guard enabled, let session, session.isSignedIn else { return }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        for account in session.accounts {
            await poll(account)
        }
    }

    private func poll(_ account: Account) async {
        let client = JiraClient(account: account)
        let host = account.site.host() ?? ""
        let now = Date()
        guard let since = lastPoll[account.id] else {
            // First pass only seeds the clock; nothing from before launch is news.
            lastPoll[account.id] = now
            return
        }
        lastPoll[account.id] = now
        let minutes = max(1, Int(now.timeIntervalSince(since) / 60) + 1)
        if meIDs[account.id] == nil {
            if let cached = session?.state(account.id)?.me?.accountId { meIDs[account.id] = cached }
            else { meIDs[account.id] = try? await client.myself().accountId }
        }
        guard let me = meIDs[account.id] else { return }
        let involved = "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser())"

        if let page = try? await client.search(jql: "assignee CHANGED TO currentUser() AFTER -\(minutes)m AND NOT assignee CHANGED BY currentUser() AFTER -\(minutes)m ORDER BY updated DESC") {
            for i in page.issues where announced.insert("\(host)|\(i.key)|assigned|\(i.fields.updated?.timeIntervalSince1970 ?? 0)").inserted {
                notify(String(localized: "Assigned to you"), "\(i.key)  \(i.fields.summary)", host: host, key: i.key)
            }
        }
        if let page = try? await client.search(jql: "\(involved) AND status CHANGED AFTER -\(minutes)m AND NOT status CHANGED BY currentUser() AFTER -\(minutes)m ORDER BY updated DESC") {
            for i in page.issues where announced.insert("\(host)|\(i.key)|status|\(i.fields.status.id)").inserted {
                notify(String(localized: "\(i.key) is now \(i.fields.status.name)"), i.fields.summary, host: host, key: i.key)
            }
        }
        if let page = try? await client.search(jql: "\(involved) AND updated >= -\(minutes)m ORDER BY updated DESC", fields: "summary,comment") {
            for i in page.issues {
                for c in i.fields.comment?.comments ?? [] where c.created > since && c.author?.accountId != me {
                    let id = "\(host)|\(c.id)"
                    guard seenComments.insert(id).inserted else { continue }
                    let text = c.body.plainText.replacingOccurrences(of: "\n", with: " ")
                    notify(String(localized: "\(c.author?.displayName ?? String(localized: "Someone")) commented on \(i.key)"), String(text.prefix(140)), host: host, key: i.key)
                }
            }
        }
    }

    private func notify(_ title: String, _ body: String, host: String, key: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": "https://\(host)/browse/\(key)"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        if !NSApp.isActive {
            unread += 1
            NSApp.dockTile.badgeLabel = "\(unread)"
        }
    }

    private func clearBadge() {
        unread = 0
        NSApp.dockTile.badgeLabel = nil
    }

    // MARK: Reminders

    private static func reminderID(_ url: URL) -> String { "remind|" + url.absoluteString }

    /// One reminder per issue: setting another replaces it. Clicking the banner opens the issue.
    static func remind(_ url: URL, key: String, summary: String, at date: Date) async throws {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: String(localized: "Notifications are off for Conductor. Turn them on in System Settings › Notifications.")])
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Reminder: \(key)")
        content.body = summary
        content.sound = .default
        content.userInfo = ["url": url.absoluteString]
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try await center.add(UNNotificationRequest(identifier: reminderID(url), content: content, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
    }

    static func reminder(for url: URL) async -> Date? {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return (pending.first { $0.identifier == reminderID(url) }?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
    }

    static func cancelReminder(for url: URL) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderID(url)])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) else { return }
        await MainActor.run { Notifier.shared.session?.open(url: url) }
    }
}

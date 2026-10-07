# Conductor

A native Mac app for Jira Cloud. Built with SwiftUI and Liquid Glass for macOS 26 Tahoe, no Electron, no web views, no dependencies.

Jira's own Mac app was discontinued. Conductor is what it should have become: every account signed in at once, your lists in the sidebar like mailboxes, an issue page that opens instantly, and boards you can drag cards across.

## Highlights

- **All your Jira sites in one window.** Personal and work accounts stay signed in together. An All Accounts section unifies Assigned to Me, Reported by Me and Watching across sites, each row tagged with the account's colour. Every account also has its own section with the same lists, favourite filters, starred projects and all projects. Every sidebar entry is a preset of the one list: pick one, narrow it with the chips, and save the result as a sidebar filter of your own.
- **Instant.** Everything you have seen is cached on disk. Launch, lists and issues appear at once and refresh in the background.
- **A real issue page.** Description, attachments, subtasks, child issues, linked issues, work log and comments. Edit the summary, description, priority, labels, sprint, assignee and status inline. Comments and descriptions are written in Markdown with @mention suggestions.
- **Attachments the Mac way.** Drop files onto the issue, paste a screenshot, Quick Look anything with a click.
- **Boards.** Each project's board in its own window, with sprint selection and drag between columns to transition.
- **Search that understands you.** Type words, an issue key, raw JQL with field and value suggestions, or paste a Jira link. Chips for account, project, scope (recently viewed, watching), status, assignee, reporter, type and recency, and a sort order. Save any combination as a sidebar filter.
- **Notifications.** Assignments, status changes and new comments on issues you are involved in, on every account, with a dock badge.
- **Spotlight.** Every issue you have seen is indexed. Search "ES-123" or a summary from anywhere and land in Conductor.
- **Mac details.** ⌘N new issue, ⌘F find, ⌘1 to ⌘4 for your lists, ⌘0 back to the list window, ⌘R reload, `conductor://issue/KEY` links, window restoration.

## Requirements

- macOS 26 Tahoe or later
- A Jira Cloud account and an API token from <https://id.atlassian.com/manage-profile/security/api-tokens>

Jira Server and Data Center are not supported.

## Install

Download the latest release from the Releases page, unzip and move Conductor to Applications. Or build it yourself: open `Conductor.xcodeproj` in Xcode 26 and run.

## Sign in

Enter your site (`yourteam` or `yourteam.atlassian.net`), your Atlassian email and an API token. Tokens are stored in the macOS Keychain and sent only to that site. Add more accounts from the sidebar footer.

Right-click an account's section title to rename it, pick its colour or sign out.

## Keyboard

| Shortcut | Action |
|---|---|
| ⌘N | New issue |
| ⌘F | Find issues |
| ⌘1 ⌘2 ⌘3 ⌘4 | Assigned to Me, Reported by Me, Recently Viewed, Watching |
| ⌘S | Save the current chips and search as a sidebar filter |
| Double-click a row | Open the issue in its own window |
| ⌘0 | The list window, when only issue windows are open |
| ⌘R | Reload the list |
| ⌘[ | Back to the previous issue in an issue window |
| ⌘⇧R | Refresh the issue |
| ⌘⇧C | Copy the issue link |
| ⌘⇧O | Open the issue in the browser |
| ⌘↩ | Send a comment or save an edit |
| Click the title or description | Edit it |

## Privacy

Conductor talks only to your Jira sites. There is no account, no server and no analytics. Credentials live in the Keychain; cached issues live in your Library folder and can be cleared from Settings.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout, debug switches, tests and releases. Issues and pull requests are welcome.

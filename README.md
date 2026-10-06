# Conductor

A native macOS client for Jira Cloud. SwiftUI, Liquid Glass, zero dependencies.
Requires macOS 26 (Tahoe) or later and Xcode 26+.

## Build

Open `Conductor.xcodeproj` and run the `Conductor` scheme. No extra tools needed.

The project file is checked in, but it is generated from `project.yml`. If you add files or
change settings, edit `project.yml` and run `xcodegen generate` (`brew install xcodegen`) so the
two stay in sync.

## Sign in

Site (`yourteam` or `yourteam.atlassian.net`), your Atlassian email, and an API token from
<https://id.atlassian.com/manage-profile/security/api-tokens>. Credentials live in the Keychain only.

Several accounts (say, personal and work Jira) stay signed in at once. The sidebar shows an
All Accounts section with unified Assigned to Me, Reported by Me, Recently Viewed and Watching
lists, then a section per account with its own lists, favourite filters, starred projects and a
collapsed All Projects. Right-click a section title to rename it or sign out.

## Dev shortcuts (Debug builds only)

Set these environment variables in the scheme or shell to skip the login form and jump to an issue:

| Variable | Effect |
|---|---|
| `CONDUCTOR_SITE`, `CONDUCTOR_EMAIL`, `CONDUCTOR_TOKEN` | Sign in without touching the Keychain; add `_2`, `_3` suffixes for more accounts |
| `CONDUCTOR_OPEN=KEY-123` | Open that issue at launch |
| `CONDUCTOR_SCROLL=comments` | Scroll the opened issue to its comments |
| `CONDUCTOR_SHOW=create` / `addAccount` / `board:KEY` | Open that sheet or window at launch |

## Layout

| File | Role |
|---|---|
| `Models.swift` | Codable Jira types; sprint custom field resolved at runtime |
| `JiraClient.swift` | REST v3 calls, auth, error parsing, Keychain |
| `ADF.swift` | Atlassian Document Format → SwiftUI |
| `Session.swift` | Sign-in state, project and filter catalog |
| `SidebarView.swift` | Smart lists, favourite filters, projects; JQL builder |
| `IssueListView.swift` | Paginated search with text or raw JQL |
| `IssueDetailView.swift` | Issue page: editing, attachments, links, work log, comments |
| `CreateIssueView.swift` | New Issue / Subtask sheet from create metadata |
| `ADFMarkdown.swift`, `Composer.swift` | Markdown ⇄ ADF and the editor with mention autocomplete |
| `BoardView.swift` | Board window (Agile API) |
| `Notifier.swift` | Polling notifications and dock badge |
| `UpdateChecker.swift` | GitHub Releases update check |

## Releases

Push a `v*` tag; `.github/workflows/release.yml` builds, zips and publishes the app. Add the
Developer ID secrets named in that file to get a signed and notarized build.

## What it does

- Sidebar: Assigned to me, Reported by me, Recently viewed, Watching, favourite filters, starred and all projects
- Issue list with filter chips, free text / issue key / raw JQL search with field and value suggestions,
  recent searches, Save as Filter, and pasting a Jira link to jump to it (switching account by site)
- Issue page: Markdown-editable summary and description, attachments (drop, paste, Quick Look), subtasks,
  child issues, linked issues, work log, comments with @mentions and edit/delete, transitions, assignee,
  priority, labels, sprint, watch
- New Issue (⌘N) and Create Subtask, driven by the site's create metadata
- Boards: a per-project board window with drag-and-drop between columns
- Notifications for assignments, status changes and comments on every account, with a dock badge
- `conductor://issue/KEY` and `conductor://open?url=…` deep links
- Go menu: ⌘1–4 smart lists, ⌥⌘F search, ⌘R reload; Settings for defaults, notifications and updates

## Tests

`⌘U` in Xcode, or `xcodebuild -scheme Conductor test`. The live write test is skipped unless
`TEST_RUNNER_CONDUCTOR_SITE`, `_EMAIL`, `_TOKEN` and `_TEST_ISSUE` are set; it comments on, assigns
and transitions that issue and puts everything back.

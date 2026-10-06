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

## Dev shortcuts (Debug builds only)

Set these environment variables in the scheme or shell to skip the login form and jump to an issue:

| Variable | Effect |
|---|---|
| `CONDUCTOR_SITE`, `CONDUCTOR_EMAIL`, `CONDUCTOR_TOKEN` | Sign in without touching the Keychain |
| `CONDUCTOR_OPEN=KEY-123` | Open that issue at launch |
| `CONDUCTOR_SCROLL=comments` | Scroll the opened issue to its comments |

## Layout

| File | Role |
|---|---|
| `Models.swift` | Codable Jira types; sprint custom field resolved at runtime |
| `JiraClient.swift` | REST v3 calls, auth, error parsing, Keychain |
| `ADF.swift` | Atlassian Document Format → SwiftUI |
| `Session.swift` | Sign-in state, project and filter catalog |
| `SidebarView.swift` | Smart lists, favourite filters, projects; JQL builder |
| `IssueListView.swift` | Paginated search with text or raw JQL |
| `IssueDetailView.swift` | Issue page: description, attachments, subtasks, comments, transitions, assignee |

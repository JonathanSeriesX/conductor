# Contributing

## Build

Open `Conductor.xcodeproj` in Xcode 26 and run the `Conductor` scheme. The project file is checked in but generated from `project.yml`: when you add files or change settings, edit `project.yml` and run `xcodegen generate` (`brew install xcodegen`).

Swift 6 language mode with strict concurrency, macOS 26 deployment target, no dependencies.

## Layout

| File | Role |
|---|---|
| `Session.swift` | Accounts (`AccountState` per signed-in site), navigation requests, deep links |
| `JiraClient.swift` | REST v3 and Agile API calls, auth, error parsing, Keychain |
| `Models.swift` | Codable Jira types; the sprint custom field is resolved per site at runtime |
| `Cache.swift` | Disk cache per account, image cache, Spotlight indexing |
| `ADF.swift`, `ADFMarkdown.swift` | Atlassian Document Format → SwiftUI, and Markdown ⇄ ADF |
| `SidebarView.swift` | `Source`, `Smart`, `ListFilters`, the sidebar |
| `IssueListView.swift` | List store (single and unified), filter chips, search assist |
| `IssueDetailView.swift` | Issue page: editing, attachments, links, work log, comments |
| `CreateIssueView.swift` | New Issue / Subtask sheet from create metadata |
| `Composer.swift` | Markdown editor with mention autocomplete, `PeoplePicker`, `Wrap`, `Chip` |
| `BoardView.swift` | Board window (Agile API) |
| `Notifier.swift` | Polling notifications and dock badge |
| `UpdateChecker.swift` | GitHub Releases update check |
| `SettingsView.swift`, `LoginView.swift`, `Components.swift` | Settings, sign-in card, shared views |

## Debug switches

Environment variables honoured by Debug builds, handy in the scheme's Run arguments:

| Variable | Effect |
|---|---|
| `CONDUCTOR_SITE`, `CONDUCTOR_EMAIL`, `CONDUCTOR_TOKEN` | Sign in without touching the Keychain; add `_2`, `_3` suffixes for more accounts |
| `CONDUCTOR_OPEN=KEY-123` | Open that issue (first account) at launch |
| `CONDUCTOR_SCROLL=comments` | Scroll the opened issue to its comments |
| `CONDUCTOR_SHOW=create` / `addAccount` / `settings` / `board:KEY` | Open that sheet or window at launch |

From a shell, launch through LaunchServices so the app gets its icon and bundle identity:

```bash
open -a build/Build/Products/Debug/Conductor.app --env CONDUCTOR_SITE=… --env CONDUCTOR_EMAIL=… --env CONDUCTOR_TOKEN=…
```

## Tests

`⌘U` in Xcode, or `xcodebuild -scheme Conductor test`. The live write test is skipped unless `TEST_RUNNER_CONDUCTOR_SITE`, `_EMAIL`, `_TOKEN` and `_TEST_ISSUE` are set in the environment; it comments on, assigns and transitions that issue and puts everything back, so point it at a throwaway issue.

## Releases

Push a `v*` tag; `.github/workflows/release.yml` builds, zips and publishes the app. Add the Developer ID secrets named in that file to get a signed and notarized build. CI builds and tests every push.

## Jira API notes

- Search uses `/search/jql` with page tokens; the old `/search` returns 410.
- Project keys are quoted in JQL because keys like `IN` are reserved words.
- Project stars can be read (`expand=favourite`) but not written through the public API, so Conductor keeps its own per account.
- Media nodes in descriptions carry a media-services id with no public mapping to attachments, so inline images match on filename.

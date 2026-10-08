# AGENTS.md

- During testing, pls never trigger Keychain or admin-password prompts.
- Test only on the Personal account (Jira project CON). The Work account stays read-only.
- After a build, quit every running Conductor (`pkill -x Conductor`; one Xcode launched ignores signals while debugged, so `osascript -e 'tell application "Xcode" to stop workspace document 1'`) and start the new one with `open -n build/Build/Products/Debug/Conductor.app`, so the user is never left with a stale build. Find windows with their CGWindow ids and `screencapture -l` instead of clicking around.

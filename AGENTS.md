# AGENTS.md

- During testing, pls never trigger Keychain or admin-password prompts.
- Test only on the Personal account (Jira project CON). The Work account stays read-only.
- After a build, quit every running Conductor (`pkill -x Conductor`, including the one Xcode launched) and start the new one with `open -n build/Build/Products/Debug/Conductor.app`, so the user is never left with a stale build. Find windows with their CGWindow ids and `screencapture -l` instead of clicking around.

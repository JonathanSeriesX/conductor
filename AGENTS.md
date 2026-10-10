# AGENTS.md

- During testing, pls never trigger Keychain or admin-password prompts.
- Test only on the Personal account, in Jira project QA (QA Scratch). CON tracks Conductor's real work (open and close this repo's issues there) and ST (Sample Tasks) holds showcase data: don't test there. The Work account stays read-only.
- After a build, quit every running Conductor (`pkill -x Conductor`; one Xcode launched ignores signals while debugged, so `osascript -e 'tell application "Xcode" to stop workspace document 1'`) and start the new one with `open -n build/Build/Products/Debug/Conductor.app`, so the user is never left with a stale build. Find windows with their CGWindow ids and `screencapture -l` instead of clicking around.
- When the user reports a bug that no existing check covers, add a check for it to the "Regression watchlist" in `qa/QA-SPEC-FULL.md` (the full QA run; all testing files and reports live in the git-ignored `qa/` folder), so every later full run tests it.

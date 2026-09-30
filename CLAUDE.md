# CLAUDE.md

給在這個 repo 工作的 Claude Code 看的規則。

## 檔案放哪

Hangar 用到的東西一律放在 repo 資料夾底下，**不要散在 home 目錄**，也不要在 repo 旁邊另開 `Hangar-xxx` 這類同層資料夾。筆電（`~/Projects/hangar`）和 mini（`~/Projects/Hangar`）都一樣。

- 備份（例如改 `~/Library/LaunchAgents/com.hangar.hub.plist`、`~/.config/hangar/profiles/*.conf` 之前的備份）、診斷輸出、暫時的工作目錄，都放 repo 裡的 `.local/`（已在 `.gitignore`，不會進版控）。
- 要另開 worktree 編 APK 時，用 `git worktree add .local/worktrees/<名稱> <分支>`。
- 用完就清掉：worktree 用 `git worktree remove`，不要直接 `rm`。
- 回報時說清楚留了什麼、放在哪、什麼時候可以刪。
- 備份的 profile 裡有 `AGENT_TOKEN`，不需要時就刪掉。

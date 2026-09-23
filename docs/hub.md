# hub（裝置牆網頁）

一台常駐機器跑 `hub/hangar_hub.py`，定期問 hangar 三件事，然後把結果合成一頁
裝置牆：

```
hangar list --json --probe   已經設定過的手機：adb 狀態、機型、電量
hangar scan --json           區網上看得到的所有東西：IP、MAC、廠商、5555
hangar usb  --json           插在 hub 這台機器上的 USB 裝置（含未授權的）
```

三份資料用 `DEVICE_SERIAL` > MAC > IP 的順序合併，所以同一支手機不會變成三張卡。

> **第三份為什麼需要**：一支剛到的手機插著 USB、偵錯開了、`adb devices` 也是
> `device`，在牆上卻是匿名的一列 —— 因為 `list` 只看 profile，而 `scan` 探的是
> TCP 5555，那要 `hangar setup` 才會打開。**授權的是 USB 那把金鑰，跟 5555 是
> 兩件不相干的事。** 沒有這一份的話，「我明明都開好了」會讓人往錯的方向查很久。
>
> 看得到的是**插在 hub 那台機器上**的 USB，不是插在每個人筆電上的 —— 跟掃描
> 是同一個視角問題（掃的也一直是 hub 所在的網段）。

```bash
hangar wall                               # 只綁 127.0.0.1:8787
hangar wall --bind 0.0.0.0 --port 8787    # 要給同事看才這樣開
./hub/hangar_hub.py                       # 同一支；wall 只是轉發過去
```

`hangar wall` 跟直接跑 `hub/hangar_hub.py` 是同一支程式、同一組參數 —— 它只負責
從 symlink 一路找回 repo 再 `exec` 過去，這樣不必記得 repo 放在哪。

用的是 Python 3 的標準函式庫，**沒有任何套件要裝** —— 常駐機器上不該為了看一頁
網頁而先裝一套生態系，跟 `hangar` 自己是一支無相依 bash script 是同一個理由。

| 參數 | 預設 | |
|---|---|---|
| `--hangar` | repo 裡那支 | hangar 執行檔的路徑 |
| `--bind` / `--port` | `127.0.0.1` / `8787` | 預設只有本機看得到 |
| `--list-interval` | 30 秒 | 多久問一次 `hangar list` |
| `--scan-interval` | 300 秒 | 多久掃一次區網（ping 整個 /24 不便宜） |
| `--usb-interval` | 15 秒 | 多久問一次本機 USB（只問本機 adb，很便宜） |
| `--subnet` | 自動偵測 | 同 `hangar scan --subnet` |
| `--no-scan` | | 完全不掃區網，只看已設定的手機 |
| `--no-usb` | | 不回報這台機器上 USB 接著的裝置 |
| `--no-helper` | | 不要把 helper 一起帶起來（見下面） |
| `--helper-port` | `8788` | 內嵌 helper 的埠（`0` = 隨便挑） |
| `--no-auto-pair` | | 不把鑰匙交給這一頁，改用啟動時印出來的連結 |
| `--helper-token-file` | `~/.config/hangar/helper.token` | helper 的鑰匙放哪 |
| `--new-helper-token` | | 換一把新的（舊的連結就失效了） |
| `--hub` | | 額外的 Origin，走反向代理之類的情況才需要 |

端點：`/`（裝置牆）、`/api/devices`（合併後的 JSON）、`/api/helper`（見下面）、
`/api/refresh`（POST，見下面）、`/healthz`。

## helper 跟著一起起來

裝置牆上的動作按鈕（投影、響鈴、切偵錯、入伍）從來不是 hub 在做 —— 那些事得發生
在**按按鈕的那台電腦**上，所以做事的一直是 [helper](wall-actions.md)。但最常見的
情形是 hub 跟 helper 在同一台（自己的筆電），那時候「兩個 process」只剩成本：兩個
終端機、`--hub` 要跟網址列一字不差、還要去開那個帶鑰匙的連結。

所以 hub 預設會把 helper 帶進**同一個 process**。要注意的是它**不是同一個
listener**：

- helper 照樣自己綁 `127.0.0.1`，hub 的 `--bind` 不會傳給它
- Origin 白名單與 token 那三道鎖原封不動
- **hub 這一邊仍然一個會動到手機的端點都沒有** —— `POST /mirror` 打到 hub 是 404

Origin 白名單不必再自己打：hub 知道自己聽哪個埠，會把 `127.0.0.1`、`localhost`、
主機名與這台機器對外那個位址都算進去。那正是獨立跑 helper 時最常打錯的地方
（差一個字就是 403，而且錯誤發生在瀏覽器裡）。

推導出來的位址只有**主要那一張網卡**的。這條路上刻意一個名字解析都不做 ——
它跑在 hub 綁好、但還沒開始服務的那一小段，卡住的話整個 hub 會看起來像死了
（反向解析很慢的機器上真的發生過）。多網卡的機器要從第二張的位址開這一頁的話，
用 `--hub` 補上去：

```bash
hangar wall --bind 0.0.0.0 --hub http://10.1.2.3:8787
```

鑰匙走 `GET /api/helper`，而它**只回答 loopback**：

```bash
curl -s http://127.0.0.1:8787/api/helper
{"ok": true, "port": 8788, "token": "…"}

curl -s http://192.168.1.5:8787/api/helper     # 同事從區網打同一個端點
{"ok": false, "reason": "動作按鈕只在跑 hub 的那台機器上按得動", "hint": "…"}
```

所以同事從區網開同一頁，行為跟以前完全一樣：他那台要自己跑一支 helper。

> **多人共用的機器要關掉自動配對。** 這個端點等於把 helper 的鑰匙交給「任何能從
> loopback 打到 hub 的東西」，繞過了鑰匙檔那個 `0600`。在自己的筆電上這不是新
> 風險（本來就是同一個人），但在多人共用帳號的機器上是 —— 那種機器要帶
> `--no-auto-pair`（鑰匙只走啟動時印出來的那個連結）或乾脆 `--no-helper`。

helper 起不來（最常見的是 8788 已經有一支獨立的 helper 在用）不會把 hub 一起拖
下水：hub 照常是一頁看得到的裝置牆，原因印在啟動訊息裡，牆上那行字也會講出來。

## 多久更新一次

三層，各自獨立：

| | 預設 | |
|---|---|---|
| `hangar list --probe` | 30 秒 | 已設定手機的狀態與電量 |
| `hangar scan` | 300 秒 | 區網上還有什麼（ping 整個 /24 不便宜，所以慢） |
| 網頁重抓 `/api/devices` | 10 秒 | 純讀 hub 的快取，不會去碰手機 |

所以牆上的東西最舊會是「間隔 + 10 秒」前的。不想等的話按頁面上的**立即更新**，
或直接打：

```bash
curl -X POST 'http://127.0.0.1:8787/api/refresh?what=all'   # 或 what=list / what=scan
```

它只是把輪詢**提早叫醒**，不是另外開一條路去問手機 —— 跑的還是同樣那兩個
`hangar` 指令，一樣不帶 `--fix-ip`。

有最小間隔擋著：`list` 5 秒、`scan` 30 秒（掃描會對 254 個位址各送一個封包，
按住不放不該變成洗 ping）。太快就回 `429` 並告訴你還要等幾秒：

```json
{ "ok": false, "refreshed": [], "throttled": [ { "source": "scan", "retry_after_s": 22.0 } ] }
```

`GET /api/refresh` 是 404 —— 觸發器不該掛在 GET 上，不然任何會預抓網址的東西
都會去戳一次手機。

## 起不來的時候

最常見的是埠被自己上一個 hub 佔著：

```
127.0.0.1:8787 已經有人在用了
  多半是另一個 hangar hub 還在跑：
    pgrep -fl hangar_hub.py       # 看是不是它
    pkill -f hangar_hub.py        # 收掉
  或者換一個埠：--port 8788
```

`--port 80` 這種 1024 以下的埠會說是權限問題，`--bind` 給了這台機器上沒有的
位址則會說是位址問題 —— 三件事分開講，因為要做的事完全不同。

## 那頁上的狀態是什麼意思

| | |
|---|---|
| `ready` | adb 是 `device`，可以 build 也可以投影 |
| `no_adb` | 連得到，但 adb 不是 `device` —— 幾乎都是手機重開機把 5555 弄丟了 |
| `unauthorized` | 這台 hub 還沒被那支手機授權過（要有人在手機上按允許） |
| `offline` | 手機不在線上 |
| `unknown` | 只從掃描看到它，`hangar list` 那邊沒資料（那次輪詢多半失敗了） |
| `unmanaged` | 掃得到但沒設定過。沒開偵錯的手機 adb 完全碰不到，所以只有 IP、MAC、廠商 |

另外有一種不是狀態、而是疊在上面的警示：**偵錯關著，agent 也沒回話**。卡片會
加紅色粗框和一行橫幅，排在整面牆的最前面，頂端計數多一句「N 台要有人走過去」。
切偵錯沒有自動復原，關掉之後唯一開得回來的路就是 agent；agent 也叫不動，遠端
就沒有路了。`/api/devices` 裡是每張卡的 `stranded`（`null`，或
`{"adb_seen_off_at": <時間>}`）。

agent 叫不動的那一輪本來就問不到偵錯開關，所以這裡看的是 hub **最後一次看到**
的值（list 問到的、或主動回報帶來的）。這份記憶只放在 hub 的記憶體裡：hub 重開
之後，要等那支手機的 agent 再答一次話才知道 —— 在那之前不會誤報，但也不會警示。
adb 此刻是通的（網路或 USB）就一定開著，不算。

同一支手機在兩份資料裡會合成同一張卡，合併的主鍵是 `DEVICE_SERIAL`，沒有序號
才退回 MAC、再退回 IP —— 跟 `hangar scan` 認人用的是同一套順序
（見[區網掃描](scan.md)）。所以手機換了 IP，裝置牆不會多出一台幽靈。

## 跨網段：主動回報（check-in）

hub 看到的手機預設都是「hub 這台問得到的」：掃描只掃 hub 所在的網段，list 要連
得進手機。手機在路由器後面（另一個 VLAN、只放單向的防火牆）時，兩條都斷。

反方向常常是通的，所以可以讓手機自己來報到：

```bash
hangar wall --checkin 0.0.0.0:8789                 # 另開一個埠收回報
hangar enroll -p work --hub http://10.0.1.5:8789   # 告訴手機往哪裡送（已入伍的只改這一項）
hangar enroll -p work --no-hub                     # 不要再回報了
```

- 手機每 60 秒送一次（網路一換馬上送），內容跟 agent 的 `/status` 一樣，再加上
  它現在所有的 IPv4。
- 卡片上多一格「主動回報」與「N 秒前」。list 問不到、但回報是新鮮的（3 分鐘內）→
  狀態是 `agent_only`，電量與機型用回報的補；手機報的位址裡沒有 profile 那個 IP →
  標「profile 指著舊 IP」。
- **收得到回報不代表按鈕按得動**：投影、響鈴、切偵錯都是 helper → CLI → 手機，
  那是反方向。卡片會直接講「hub 連不到這支手機，只收得到它主動送來的回報」。
- 驗的是入伍時的 token：hub 啟動時跑一次 `hangar agent-tokens --json`，之後遇到
  不認得的序號（剛入伍的）最多每 10 秒重讀一次。所以 **hub 要跟入伍那台是同一個
  使用者、讀得到同一份 profile**。
- 回報那個埠是**另一個 listener**，上面只有 `POST /api/checkin`；`--bind` 仍然
  決定裝置牆給不給別人看，兩件事分開。

多個網段也可以一起掃：`--subnet` 給好幾次，不在 hub 網段上的會逐台探埠（見
[區網掃描](scan.md#跨網段)），逾時會按網段數放大。

## 這一版是唯讀的

裝置牆不會去動手機，也不會去改設定檔：輪詢只跑 `list` 與 `scan`，**刻意不帶
`--fix-ip`**（那會寫 profile，固定輪詢的程式無條件帶著它跑遲早出事）。profile
指著舊 IP 時它只會在那張卡上說一句，要修還是你自己去跑 `hangar scan --fix-ip`。

牆上的**投影、響鈴、切偵錯按鈕也沒有破壞這件事**：它們叫的不是 hub，而是你
自己那台電腦上的 helper（見[從裝置牆上按投影](wall-actions.md)）。helper
再呼叫 CLI，CLI 才去碰手機裡的 agent。hub 這一側仍然只有唯讀資料與輪詢喚醒
端點；沒有任何 `/api/*` 寫入手機的路。`--checkin` 收到的回報也只放在記憶體，
不寫 profile。

在卡片上，響鈴只對「agent 可達且宣告 `can.ring`」的手機啟用；偵錯只對宣告
`can.toggle_adb` 且回報了 `adb.enabled` 的手機啟用。helper 沒有啟動時，按鈕會
改成複製 `hangar ring`／`hangar adb` 指令。**在瀏覽器裡直接看到畫面（網頁投影
串流）仍然是遠期目標** —— 投影本身維持走 CLI 的 scrcpy，那顆按鈕省的是打字，
不是換掉投影的方式。

## 換一台 hub

hub 本身是**無狀態的** —— 它把看到的東西放在記憶體裡，重開就重新問一次 hangar。
所以「搬 hub」實際上搬的是三樣東西，而且只有一樣會痛。

| 要搬的 | 怎麼搬 | 痛不痛 |
|---|---|---|
| `~/.config/hangar/`（profiles、預設值） | `scp -r` 或 `rsync` | 不痛 |
| 常駐設定（launchd plist／systemd unit） | 照上面重寫一份 | 不痛 |
| **手機對這台電腦的 adb 授權** | 見下面 | **會痛** |

### 會痛的那一樣

adb 的授權綁在每台電腦自己的金鑰（`~/.android/adbkey`）上。新的 hub 是一把新
金鑰，所有手機都會把它當陌生人 —— 每一支都要有人在手機螢幕上按一次「一律允許」。
十支手機就是十次。

**agent 那條路不受影響**：`AGENT_TOKEN` 在 profile 裡，profile 搬過去，新 hub
就問得到入伍過的手機。所以入伍過的手機在搬 hub 時是「電量與機型照樣看得到，
只是 adb 進不去」。這也是 agent 在這件事上的實際價值。

### 如果是「汰換」而不是「多一台」

舊機器要退役的話，把金鑰一起搬過去是合理的 —— 你搬的是同一個身分，不是複製
一份出來：

```bash
# 在新機器上
scp 舊hub:~/.android/adbkey     ~/.android/
scp 舊hub:~/.android/adbkey.pub ~/.android/
adb kill-server

# 確認新機器接手了
hangar list

# 然後把舊機器上的那把砍掉 —— 這一步不做，你就是把完整裝置控制權複製了一份
ssh 舊hub 'rm -f ~/.android/adbkey ~/.android/adbkey.pub && adb kill-server'
```

> 這跟[多台電腦共用同一支手機](multi-host.md)裡「**不要把 `adbkey` 複製到別台
> 電腦**」不衝突：那條講的是同時存在的多台電腦（複製＝多一份完整控制權）。
> 汰換是搬移，前提是**舊的那份要刪掉**。
> 做不到「確定刪掉」的話，就老老實實一支一支按。

### 搬完檢查這幾件事

```bash
hangar list                      # 每一支的狀態都對嗎
hangar scan --fix-ip             # 新機器可能在不同網段，順便把換過的 IP 修對
curl -s localhost:8787/healthz   # hub 起來了嗎
curl -s localhost:8787/api/devices | jq '.errors'   # 有沒有藏著的錯誤
```

還有三件容易忘的：

- **Tailscale**：新機器要加進 tailnet，而且 ACL 的 `src` 要有它（打 `tag:devbox`
  的話就不用改 ACL）。
- **網址變了**：有人把舊 hub 的位址加了書籤的話要通知。
- **`~/.config/hangar/` 現在可能有祕密**：入伍過的手機 profile 裡有 `AGENT_TOKEN`。
  用 `scp`／`rsync` 搬沒問題（走加密通道），但別丟進共用雲端硬碟。

## 讓它開機就自己跑

macOS（launchd，存成 `~/Library/LaunchAgents/com.hangar.hub.plist`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.hangar.hub</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/你/Hangar/hub/hangar_hub.py</string>
    <string>--hangar</string><string>/usr/local/bin/hangar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
```
```bash
launchctl load ~/Library/LaunchAgents/com.hangar.hub.plist
```

Linux（systemd user unit，存成 `~/.config/systemd/user/hangar-hub.service`）：

```ini
[Unit]
Description=Hangar hub
[Service]
ExecStart=/usr/bin/python3 %h/Hangar/hub/hangar_hub.py --hangar /usr/local/bin/hangar
Restart=always
[Install]
WantedBy=default.target
```
```bash
systemctl --user enable --now hangar-hub
```

> 常駐機器上的 `hangar` 要先自己跑得起來（`hangar list` / `hangar scan` 有東西），
> hub 只是把它們的 `--json` 接起來。掃描需要 `ping` 與 `arp`／`ip`，`--probe`
> 要電量則需要 adb —— 但 hub 本身不需要 scrcpy。

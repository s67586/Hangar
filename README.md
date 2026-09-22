# Hangar

一整隊 Android 測試機的停放、維護與調度。

主場是**同一個區網**：掃得出網段上有哪些裝置、用 **scrcpy** 投影畫面，並且管得到
那些**沒開偵錯、adb 碰不到**的手機。

手機不在同一個區網時（4G/5G、在別的網段、在公司 NAT 後面），加上 **Tailscale**
就照樣投得到 —— 那是**建議的加值選項，不是前提**。裝置牆的掃描（ARP）與 agent 的
mDNS 廣播則本來就只在區網成立。

| | |
|---|---|
| [`hangar`](hangar) | CLI（bash，無外部相依）：投影、設定、掃描、入伍。也是另外兩個元件的資料來源 |
| [`hub/`](hub) | 常駐服務 + 裝置牆網頁（Python 3 標準函式庫，零套件） |
| [`helper/`](helper) | 跑在**你自己那台電腦**上的小服務：讓裝置牆的投影、響鈴、偵錯按鈕能動。`hangar wall` 會連它一起帶起來 |
| [`agent/`](agent) | 手機端 app（Kotlin）：不需要 adb 就回報得了電量與機型 |

> **[📖 使用手冊（一頁可讀版）](https://claude.ai/artifact/WyegAVdz2UzVitcvwB5kZ8)**
> —— 這份 README 連同 `docs/` 那幾份整理成一頁，適合傳給同事。頁尾蓋著來源的
> sha256，對不上就是那一頁落後了；**內容以 repo 裡的 Markdown 為準**。
> 連結預設是私人的，要給別人看得先在那一頁上分享。

> 專案方向、程式分層、測試涵蓋範圍與待確認清單見 [ROADMAP.md](ROADMAP.md)。

```
hangar setup --name work    # 初始化一支手機（要同區網或插 USB）
hangar                      # 之後隨時投影
hangar -p test              # 投影另一支
hangar all                  # 全部一起開
hangar scan                 # 這個區網上有哪些裝置（不限已設定的）
hangar usb                  # 這台電腦上 USB 接著的（含沒按授權的）
hangar enroll -p work       # 用 USB 或網路 ADB 安裝並入伍 agent
hangar ring -p work         # 讓 work 響鈴 30 秒，按手機通知或 --stop 停止
hangar adb -p work --off    # 關閉偵錯，關掉就一直關著（不會自己開回來）
hangar wall                 # 裝置牆：http://127.0.0.1:8787/（動作按鈕直接可用）
```

`setup` 預設建立的是**區網直連**的 profile。手機要拿去別的網段、4G/5G 或 NAT
後面才需要 Tailscale：

```bash
hangar setup --transport tailscale --name work
```

兩者的差別見「[兩種連線方式](#兩種連線方式)」。

---

## 這份文件怎麼讀

README 走的是**裝起來 → 設定一支手機 → 每天投影**這條路，從頭讀到尾就夠用了：

[它解決了什麼](#它解決了什麼) · [安裝](#安裝) · [環境前提](#環境前提) ·
[使用](#使用) · [多台手機](#多台手機) · [手機重開機後](#手機重開機後) ·
[疑難排解](#疑難排解)

每個題目再往下挖的部分放在 [`docs/`](docs)，一份一個題目，需要時再跳過去：

| | 什麼時候看 |
|---|---|
| [區網掃描](docs/scan.md) | `hangar scan` 的完整說明：怎麼認出哪一台是哪支手機、`--fix-ip`、掃描拿不到什麼 |
| [機器可讀的輸出（`--json`）](docs/json.md) | `list` / `status` / `scan` 的 schema 與 error code。要拿 hangar 當資料來源就看這份 |
| [多台電腦共用同一支手機](docs/multi-host.md) | 第二台電腦怎麼接上同一支手機，RD 怎麼把 app build 進去 |
| [手機端 agent](docs/agent.md) | 讓**沒開偵錯**的手機也回報得了電量與機型的那支 app：入伍、升級、限制 |
| [hub（裝置牆網頁）](docs/hub.md) | 常駐服務與那頁裝置牆：參數、更新頻率、狀態的意思、換一台 hub |
| [從裝置牆上按投影](docs/wall-actions.md) | 牆上那幾顆按鈕（投影、響鈴、切偵錯、入伍）怎麼運作，以及 helper 的三道鎖 |
| [Tailscale ACL](docs/tailscale.md) | 走 Tailscale 時**強烈建議**設的白名單 |
| [密碼頁面投影全黑](docs/flag-secure.md) | 投影某些畫面時整片黑掉（`FLAG_SECURE`）的處理方式 |

---

## 它解決了什麼

`adb` 本來只能走 USB 或同一個區網。就算只在自己的區網裡用，狀態也一堆要處理；
跨網路再多兩條。下面這張表預設講的是區網，標**（跨網路）**的那兩列只有走
Tailscale 時才碰得到：

| 問題 | Hangar 的處理 |
|---|---|
| `adb tcpip 5555` 必須先有一條既有連線 | `setup` 會先找 USB，沒有就帶你走無線偵錯配對 |
| **（跨網路）**無線偵錯的 port 是隨機的、mDNS 不穿 Tailscale | `setup` 明講必須在同區網做一次，之後就不用了 |
| 手機重開機後 5555 消失 | 連不上時直接告訴你「手機重開過，請重跑 setup」，不是丟原始 adb 錯誤 |
| **（跨網路）**走 DERP relay 時很卡 | 自動偵測 direct / relay，relay 時降到低頻寬參數並警告 |
| adb 卡在 `offline` | 自動 disconnect + reconnect 重試 |
| adb 顯示 `unauthorized` | 提示去手機上按「一律允許」 |
| 重複執行累積殘留視窗 | 啟動前先清掉同一支手機的舊 scrcpy process |

---

## 安裝

### 1. 相依套件

```bash
brew install --cask android-platform-tools
brew install scrcpy jq
```

同區網的手機這三個就夠了。`TRANSPORT=lan` 的 profile 改用 `nc` 測 5555 埠通不通
—— macOS 內建，通常不用管。

**要跨網路才需要 Tailscale**（選配）：

```bash
brew install tailscale
```

也可以用 Mac App Store 版的 Tailscale.app，Hangar 會自動找到
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`。
裝在其他地方的話，用 `HANGAR_TAILSCALE=/path/to/tailscale` 指定。

`hangar setup` 只有在你加了 `--transport tailscale` 時才會要求 `tailscale` CLI，
區網的手機不必裝 —— 見「[兩種連線方式](#兩種連線方式)」。

`hangar scan`（區網掃描）用的是 `ping` 與 `arp`，兩個都是系統內建。想讓它顯示
裝置廠商就要有一份 OUI 資料庫，裝 `nmap` 或 `arp-scan` 任一個就有：

```bash
brew install nmap        # 選配，只影響 scan 的「廠商」那一欄
```

### 2. 安裝 Hangar

```bash
./hangar_install.sh
```

會把 `hangar` symlink 到 `/usr/local/bin`（需要時自動 sudo）。
想裝到別的地方：

```bash
PREFIX=~/.local ./hangar_install.sh
```

移除：

```bash
./hangar_install.sh --uninstall
```

---

## 環境前提

- 開發機：macOS（Apple Silicon / Intel 都可以）
- 手機：Android 11 以上，已開啟「開發人員選項」
- 電腦與手機在**同一個區網**，而且 AP 沒有開 client isolation

手機要跨網路用（`TRANSPORT=tailscale`）再加兩條：

- 兩邊都登入**同一個 tailnet**
- 手機端 Tailscale App 保持連線

---

## 使用

### 兩種連線方式

**預設是同一個區網直連**（`TRANSPORT=lan`）：手機跟電腦連著同一個 Wi-Fi，
`hangar setup` 不用加任何參數。這種 profile 不需要 `tailscale` CLI，改用 `nc`
測 5555 埠通不通（macOS 內建）。

手機要拿去別的網段、4G/5G 或公司 NAT 後面，才改走 **Tailscale**：
`hangar setup --transport tailscale`。

> 位址是 `100.64.0.0/10` 開頭的話，`setup` 會自己判定成 Tailscale —— 那一段是
> Tailscale 發給節點的位址，區網不會用（RFC 6598）。所以
> `hangar setup 100.77.7.104` 不必再多打 `--transport tailscale`；真的要當區網
> 直連就加 `--lan`。舊 profile 若寫著 `TRANSPORT="lan"` 卻配著 `100.x` 的位址，
> 下次執行任何指令時會被就地更正（那種檔案連得上，但顯示與診斷訊息全指向區網）。

| | `lan`（預設） | `tailscale` |
|---|---|---|
| 什麼時候用 | 手機跟電腦在同一個 Wi-Fi | 手機會離開這個網路 |
| 需要的工具 | `nc`（macOS 內建） | `tailscale` |
| `setup` 怎麼拿到位址 | 問手機自己，挑同網段的那個 IPv4 | 從 `tailscale status` 挑節點 |
| 連線路徑 | 一律當 direct，所以預設走高畫質 | `tailscale ping` 判斷 direct / relay |
| 節點名 | 沒有，`PHONE_HOST` 留空 | 有，`PHONE_HOST` 用得到 |
| 位址會不會變 | DHCP 換位址就要改 `PHONE_IP`，建議在路由器上綁固定 IP。`hangar scan` 靠 MAC 認得出換過位址的手機，`hangar scan --fix-ip` 直接改好 | Tailscale IP 基本上不變 |
| 手機重開機後 | 一樣要重下一次 `adb tcpip 5555` | 一樣要重跑 `setup`（5555 消失） |
| `hangar scan` 看得到嗎 | 看得到 | 手機不在這個網段時看不到 —— 掃描走 ARP，只在區網成立 |

> **區網直連沒有 ACL 這層保護。** `adb tcpip 5555` 在區網上是全開的，
> 同一個 Wi-Fi 下的任何人都連得到你手機的 adb，而 adb 等於完整的裝置控制權。
> 只在自己信得過的網路用；公司、咖啡廳、公共 Wi-Fi 請一律走 Tailscale 並設
> [ACL](docs/tailscale.md)。

兩種可以混用：每支手機一份 profile，各自記著自己的 `TRANSPORT`。選哪一種都不
影響日常用法 —— `hangar -p`、`status`、`list`、`reset`、`all` 完全一樣，只有訊息
裡的措辭會換成「區網」或 tailnet。

### 初始化（每支手機做一次，需同區網或插 USB）

#### 手機上要先開好的東西

`setup` 只能對「已經下得了 adb 指令」的手機動作，所以下面這幾步要先在**手機上**
做完（每支手機一次）：

1. **開發人員選項**：設定 → 關於手機 → 連點「版本號碼」7 次
2. **USB 偵錯**：設定 → 系統 → 開發人員選項 → USB 偵錯（打開）
3. **無線偵錯**：同一頁往下打開 —— 只有走配對碼流程（手邊沒有 USB 線）時才需要
4. **Tailscale App**：登入同一個 tailnet 並保持連線 —— 只有走 Tailscale
   （`--transport tailscale`）時才需要

插 USB 的話，第一次接上這台電腦時手機會跳「允許 USB 偵錯」，勾**「一律允許透過
這台電腦」**再按允許。沒按這個，`setup` 會停在 `unauthorized`。

#### 跑 setup（區網 —— 預設）

```bash
hangar setup --name deskphone
```

流程：

1. 檢查 adb / scrcpy / jq / `nc`（**不查 `tailscale`**）
2. 找 USB 裝置（插了多支會讓你選）
3. 沒有 USB 就走「無線偵錯 → 使用配對碼配對裝置」，依提示輸入 `IP:PORT` 與 6 位數配對碼
4. `adb tcpip 5555`，讓 adbd 改在 `0.0.0.0:5555` 監聽
5. **問手機要它的區網 IP** —— 手機上所有 IPv4 裡，挑落在**這台電腦同一個 /24**
   的那一個
6. 寫入 profile（`TRANSPORT="lan"`），並實際連一次驗證

第 5 步刻意不用 `ip route get`：手機開著行動網路時那條路會回答 4G 的位址，而那個
位址在這台電腦上連不到 —— 寫進 profile 之後每次投影都會失敗，錯誤訊息還會指向手機。

位址也可以直接給，省掉問手機那一步：

```bash
hangar setup 192.168.1.50 --name deskphone
```

不加 `--name` 的話，profile 名稱預設取位址的最後一段（`192.168.1.50` →
`phone-50`）—— 區網沒有節點名可以借。

#### 改走 Tailscale（手機會離開這個網路時）

```bash
hangar setup --transport tailscale
```

只有第 1 步與第 5 步不一樣 —— 它不問手機，改去 tailnet 挑節點：

1. 檢查 adb / scrcpy / jq / **`tailscale`**
2. 找 USB 裝置（插了多支會讓你選）
3. 沒有 USB 就走「無線偵錯 → 使用配對碼配對裝置」
4. `adb tcpip 5555`，adbd 在 `0.0.0.0:5555` 監聽（包含 Tailscale 的 tun 介面）
5. 從 `tailscale status` 找出這支手機的節點，取 Tailscale IP
6. 寫入 profile（`TRANSPORT="tailscale"`），並用 Tailscale IP 實際連一次驗證

指定節點名稱可以跳過選單：

```bash
hangar setup --transport tailscale pixel-7 --name work
```

不加 `--name` 的話，profile 名稱取自節點名。走這條**記得設
[Tailscale ACL](docs/tailscale.md)**：`adb tcpip 5555` 會讓 adbd 在所有介面
上監聽，而 tailnet 預設是全通的。

#### 這支手機已經由別台電腦設定過

5555 已經開著的話，這台電腦不需要 USB，也不用再跑 `adb tcpip`：

```bash
hangar setup --existing 192.168.1.50                     # 區網
hangar setup --transport tailscale --existing pixel-4    # Tailscale
```

區網這條沒有 adb 可以問位址，所以不給 IP 的話 `setup` 會跑一次 `hangar scan`，
把區網上看得到的裝置列出來讓你挑。

細節見「[多台電腦共用同一支手機](docs/multi-host.md)」。

### 日常投影

```bash
hangar                  # 預設手機
hangar -p work          # 指定手機
hangar --hq             # 強制高畫質
hangar --lq             # 強制低頻寬
hangar --screen-on      # 不要關掉手機自己的螢幕
hangar -- --window-x=100    # 額外參數直接傳給 scrcpy
```

**投影時手機自己的螢幕預設是關掉的**（`--turn-screen-off`）。省電、也不會讓旁邊
的人看到你在手機上做什麼，畫面只出現在電腦上。手機並沒有鎖住，仍然可以從電腦端
正常操作（`--stay-awake` 也一直帶著，不會中途睡著）。

> scrcpy 關掉之後，手機螢幕會維持關著——按一下手機電源鍵就回來，這是 scrcpy 的行為。
> 不想關螢幕就加 `--screen-on`，`hangar all --screen-on` 也吃這個旗標。

走 Tailscale 的 profile 會先 `tailscale ping -c 3` 判斷路徑，再決定參數；
區網 profile 一律當 direct，直接走下面第一列：

| 路徑 | scrcpy 參數 |
|---|---|
| direct | `--max-size=1280 --video-bit-rate=8M --max-fps=60 --stay-awake --turn-screen-off --no-audio` |
| DERP relay | `--max-size=1024 --video-bit-rate=3M --max-fps=30 --stay-awake --turn-screen-off --no-audio --video-codec=h265` |

`--hq` / `--lq` 可以覆寫自動判斷；`--screen-on` 拿掉 `--turn-screen-off`。

### 其他指令

```bash
hangar status           # Tailscale 路徑、adb 狀態、機型、Android 版本、電量
hangar status -p work
hangar list             # 所有手機 + 即時狀態 + 電量
hangar use work         # 設定預設手機
hangar reset            # 連線卡死時重建 adb 連線
hangar forget work      # 刪掉該手機的設定
hangar all              # 同時投影所有手機
hangar all --screen-on  # 同上，但不關手機螢幕
hangar scan             # 掃描區網，列出看得到的裝置
hangar usb              # 這台電腦上 USB 接著的裝置（含 unauthorized）
hangar enroll           # 用 USB 或網路 ADB 安裝並入伍 agent
hangar enroll -p work --reinstall   # 只換一支新版 APK（升級舊版 agent）
hangar enroll -p work --takeover    # 手機已入伍、但這台電腦沒有它的 token
hangar ring -p work     # 響鈴識別一支在線上的手機
hangar adb -p work --off  # 關閉偵錯（要開回來就 --on，沒有人按就不會變）
```

```bash
hangar --version        # 或 -V
hangar help             # 或 -h / --help
```

指令別名：`status` = `st`、`list` = `ls`、`forget` = `rm`。

吃 `-p` 的只有投影、`status`、`reset` 這三個；`list` / `all` 本來就是看全部，
`use` / `forget` 則是把手機名稱當第一個參數（`hangar use work`）。
名稱支援唯一前綴：`-p wo` 等同 `-p work`。

幾個指令自己有一份完整說明：`scan` 見[區網掃描](docs/scan.md)，`--json` 見
[機器可讀的輸出](docs/json.md)，`enroll` / `ring` / `adb` 見
[手機端 agent](docs/agent.md)。

### 結束投影

scrcpy 視窗關掉就結束了（`hangar` 是前景執行，終端機按 `Ctrl-C` 也可以）。
`hangar all` 開的視窗是背景執行的，要一次收掉：

```bash
pkill -f 'scrcpy .*:5555'
```

投影中的操作 —— 複製貼上、傳檔案、全螢幕、模擬實體按鍵 —— 都是 scrcpy 自己的
功能，Hangar 沒有另外包裝，快捷鍵見 scrcpy 的 `doc/shortcuts.md`
（[Genymobile/scrcpy](https://github.com/Genymobile/scrcpy)）。
需要額外參數就用 `--` 直接傳過去：

```bash
hangar -p work -- --window-x=100 --window-y=60   # 指定視窗位置
hangar -p work -- --record=demo.mp4              # 錄影
```

### 電量

`list` 和 `status` 都會顯示電量。低於 20%（而且不在充電）會標紅並加上 `!`：

```
     名稱             IP                連線         adb           電量       節點
  ────────────────────────────────────────────────────────────────────────────────────
     test             100.101.102.110   online       device        78%        zenfone
  *  work             100.101.102.103   online       device        12% !      pixel
```

電量只在 adb 已經連著的手機上取得（`dumpsys battery`，一次很短的往返）。
沒連線的顯示 `-` —— `list` 不會為了拿電量而硬去建立連線，那會讓它變得很慢。

狀態是 Android 自己的分類（`dumpsys battery` 的 `status`）。`not_charging` 刻意
不照字面翻成「未充電」——那會被讀成「沒插電」，而那是 `discharging`：

| | 中文 | 意思 |
|---|---|---|
| `charging` | 充電中 | 插著，而且電在進去 |
| `discharging` | 放電中 | 沒插電 |
| `not_charging` | 插著沒在充 | **插著，但電沒有在進去** |
| `full` | 已充滿 | |

`not_charging` 是測試機最容易長期停在的那一個：插著線但系統決定不充——溫度
太高、充電保護（很多機型會刻意停在 80% 左右）、或是那個 USB 孔／線供電不夠。
它跟 `discharging` 要分開看：一支停在 `not_charging` 80% 的手機是健康的，
停在 `not_charging` 9% 的手機是**插著線卻在往下掉**，那條線或那個孔有問題。

低電量提醒把 `not_charging` 算成「要充電」（只有 `charging` 與 `full` 不提醒）
—— 電沒有在進去就是沒有在進去。

---

## 多台手機

每支手機一份 profile，存在：

```
~/.config/hangar/
├── default                 # 預設 profile 名稱
└── profiles/
    ├── work.conf
    └── test.conf
```

每個 `.conf` 長這樣：

```sh
PHONE_HOST="pixel-7"           # Tailscale 節點名
PHONE_IP="100.x.y.z"           # Tailscale IP
TRANSPORT="tailscale"          # 連線方式（tailscale / lan）
DEVICE_SERIAL="1A2B3C4D"       # 硬體序號，跨 IP / 跨連線方式都不變
PHONE_MAC="a4:03:e7:01:02:03"  # 區網 MAC，由 hangar scan 記下來（見 docs/scan.md）
AGENT_TOKEN="…64 個十六進位字元…"  # 手機端 agent 的 token，由 hangar enroll 寫入
AGENT_PORT="5599"              # agent 聽的埠
```

區網的 profile 最少只要兩行（`PHONE_HOST` 是 Tailscale 節點名，區網用不到）：

```sh
PHONE_IP="192.168.1.50"
TRANSPORT="lan"
```

> **有 `AGENT_TOKEN` 的 profile 是有祕密的檔案。** 那組 token 等於「可以問這支
> 手機的狀態、之後還能切它的偵錯開關」。檔案權限是 600，不要隨手貼給別人，也
> 不要丟進版控。沒入伍過的手機沒有這一行，那種 profile 仍然只是幾行純文字。

`PHONE_IP` 以外都是可選的，`DEVICE_SERIAL` 與 `PHONE_MAC` 讀不到就當空的。

`TRANSPORT` 是唯一有遷移動作的欄位。**沒有這一行的 profile 一律當
`tailscale`** —— 那些檔案都是 `lan` backend 出現以前建的，那時 `setup` 只做得出
Tailscale profile；現在預設值是 `lan`，讓它們跟著預設值走等於靜默改掉語意。
所以 hangar 會在下次執行時就地把 `TRANSPORT="tailscale"` 補進那些檔案，讓檔案
自己講清楚（檔案唯讀就跳過，讀進記憶體時仍然當 tailscale）。`PHONE_MAC` 是 `hangar scan` 第一次用 IP 對上這支手機時
自己補上去的，你不用手寫；重跑 `setup` 而 IP 沒變的話也會留著。

### 典型流程

```bash
# 兩支手機各插一次 USB（或各自在同區網配對一次）
hangar setup --name work
hangar setup --name test

hangar list
#   * work    100.101.102.103   online   device       78%   pixel-7
#     test    100.101.102.110   online   未連線        -     zenfone

hangar use work     # 設為預設
hangar              # 直接投 work
hangar -p test      # 投 test
hangar all          # 兩支一起開，視窗標題各是 work / test
```

名稱支援唯一前綴，`hangar -p te` 等同 `hangar -p test`。

### 設計上的幾個重點

- **不會互相干擾**：每支手機的 adb serial 是各自的 `<tailscale-ip>:5555`，
  adb 本來就支援同時連多台；`reset` 和「清除殘留 scrcpy」都只作用在指定的那一支。
- **視窗標題**：`--window-title=<profile 名稱>`，多開時一眼分辨（你自己傳 `--window-title` 的話會以你的為準）。
- **只有一支時完全不用管 profile**：不用 `-p`，跟單機模式一樣。
- **多支但沒設定預設**：會列出來讓你選，並提示 `hangar use <名稱>` 可以固定下來。
- **從舊版升級**：舊的 `~/.config/hangar/config` 會自動轉成 profile，原檔改名為 `config.migrated`。

---

## 手機重開機後

**這是 adb over TCP 的硬限制，不是 bug。**

`adb tcpip 5555` 是讓 adbd 重啟並改用 TCP 模式，這個狀態**不會持久化**。
手機一重開機，adbd 就回到 USB 模式，5555 埠消失。非 root 無法繞過。

所以重開機後必須：

1. 把那支手機接回 USB，或讓它回到跟電腦同一個 Wi-Fi
2. 重跑 `hangar setup --name <該手機>`

hangar 偵測到這個情況時會直接講清楚，不會讓你對著原始 adb 錯誤訊息猜：

```
 xx  無法連上 100.101.102.103:5555（work）
     adb: failed to connect to '100.101.102.103:5555': Connection refused
 xx  手機上的 adb 5555 埠沒在聽 —— 通常代表手機重開機過（非 root 無法持久化）。
     請把這支手機接回 USB 或回到同一區網，重跑：hangar setup --name work
```

> 如果手機有 root，可以用 `setprop persist.adb.tcp.port 5555` 讓它開機就監聽。
> 但那等於把 adb 永久開在所有網路介面上，請務必搭配
> [Tailscale ACL](docs/tailscale.md) 一起用。

---

<!-- manual:docs —— 產生使用手冊時，docs/ 那幾份會接在這裡（tools/make_manual.py） -->

## 疑難排解

| 症狀 | 原因 / 解法 |
|---|---|
| `Tailscale 目前是 Stopped` | `tailscale up` |
| `手機不在 tailnet 上` | 手機端 Tailscale App 沒開，或被系統省電關掉 |
| `無法連上 …:5555` + Connection refused | 手機重開機過 → 重跑 `hangar setup` |
| `adb 狀態為 unauthorized` | 手機上會跳「允許 USB 偵錯」，勾「一律允許」再按允許 |
| `adb 狀態為 offline` | Hangar 會自動重試一次；還是不行就 `hangar reset` |
| 一直走 DERP relay | 兩端的 UDP 打洞被防火牆擋住。公司網路常見，`tailscale netcheck` 可以看細節 |
| 畫面很卡但顯示 direct | 手機在弱訊號的行動網路，試 `hangar --lq` |
| `hangar all` 只開起來一部分 | 看訊息裡哪一支失敗，通常是那支不在 tailnet 或重開過 |
| 密碼頁 / 銀行 App / 鎖定畫面全黑 | App 加了 `FLAG_SECURE`，系統層擋掉擷取，見「[密碼頁面投影全黑](docs/flag-secure.md)」 |
| `cannot connect to daemon at tcp:5037` | 本機 adb server 掛了（`adb tcpip` 之後偶爾會）。Hangar 會自動 `start-server` 重試一次；還是不行就 `adb kill-server && adb start-server` |
| 想看 scrcpy 實際參數 | Hangar 啟動前會把完整指令印出來 |

連線卡死的萬用手法：

```bash
hangar reset
```

還是不行就殺掉 adb server 重來：

```bash
adb kill-server && hangar
```

---

## 參與開發

程式碼分層、測試怎麼跑、專案往哪走，都在 [ROADMAP.md](ROADMAP.md)。

---

## 授權

[MIT License](LICENSE) — Copyright (c) 2026 Alan Lai

Hangar 本身不包含任何第三方程式碼，只在執行期呼叫下列工具，
這些工具需要你自行安裝，各自維持原本的授權：

| 工具 | 授權 |
|---|---|
| [scrcpy](https://github.com/Genymobile/scrcpy) | Apache-2.0 |
| [tailscale](https://github.com/tailscale/tailscale) | BSD-3-Clause |
| [jq](https://github.com/jqlang/jq) | MIT |
| `adb`（Android SDK Platform-Tools） | Android SDK License Agreement |

Android 與 Tailscale 為各自權利人之商標。本專案與 Google、Tailscale Inc.
及 scrcpy 專案均無關聯，亦未獲其背書。

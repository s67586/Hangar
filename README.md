# Hangar

一整隊 Android 測試機的停放、維護與調度。

透過 **Tailscale** 遠端連到手機、用 **scrcpy** 投影畫面（手機在 4G/5G、在別的網段、
在公司 NAT 後面都能投），並且管得到那些**沒開偵錯、adb 碰不到**的手機。

| | |
|---|---|
| [`hangar`](hangar) | CLI（bash，無外部相依）：投影、設定、掃描、入伍。也是另外兩個元件的資料來源 |
| [`hub/`](hub) | 常駐服務 + 裝置牆網頁（Python 3 標準函式庫，零套件） |
| [`helper/`](helper) | 跑在**你自己那台電腦**上的小服務：讓裝置牆的投影、響鈴、偵錯按鈕能動 |
| [`agent/`](agent) | 手機端 app（Kotlin）：不需要 adb 就回報得了電量與機型 |

> **[📖 使用手冊（一頁可讀版）](https://claude.ai/artifact/WyegAVdz2UzVitcvwB5kZ8)**
> —— 這份 README 的內容整理成一頁，適合傳給同事。頁尾有它對應的 commit，
> 落後了看得出來；**內容以這份 README 為準**。
> 連結預設是私人的，要給別人看得先在那一頁上分享。

> 專案方向、程式分層、測試涵蓋範圍與待確認清單見 [ROADMAP.md](ROADMAP.md)。

```
hangar setup --name work    # 初始化一支手機（要同區網或插 USB）
hangar                      # 之後隨時投影
hangar -p test              # 投影另一支
hangar all                  # 全部一起開
hangar scan                 # 這個區網上有哪些裝置（不限已設定的）
hangar enroll -p work       # 用 USB 或網路 ADB 安裝並入伍 agent
hangar ring -p work         # 讓 work 響鈴 30 秒，按手機通知或 --stop 停止
hangar adb -p work --off    # 關閉偵錯，關掉就一直關著（不會自己開回來）
./hub/hangar_hub.py         # 裝置牆：http://127.0.0.1:8787/
./helper/hangar_helper.py --hub http://裝置牆的網址    # 牆上的動作按鈕要按得動
```

---

## 它解決了什麼

`adb` 本來只能走 USB 或同一個區網。要跨網路投影，得處理一堆狀態問題：

| 問題 | Hangar 的處理 |
|---|---|
| `adb tcpip 5555` 必須先有一條既有連線 | `setup` 會先找 USB，沒有就帶你走無線偵錯配對 |
| 無線偵錯的 port 是隨機的、mDNS 不穿 Tailscale | `setup` 明講必須在同區網做一次，之後就不用了 |
| 手機重開機後 5555 消失 | 連不上時直接告訴你「手機重開過，請重跑 setup」，不是丟原始 adb 錯誤 |
| 走 DERP relay 時很卡 | 自動偵測 direct / relay，relay 時降到低頻寬參數並警告 |
| adb 卡在 `offline` | 自動 disconnect + reconnect 重試 |
| adb 顯示 `unauthorized` | 提示去手機上按「一律允許」 |
| 重複執行累積殘留視窗 | 啟動前先清掉同一支手機的舊 scrcpy process |

---

## 安裝

### 1. 相依套件

```bash
brew install --cask android-platform-tools
brew install scrcpy jq
brew install tailscale
```

`tailscale` 也可以用 Mac App Store 版的 Tailscale.app，Hangar 會自動找到
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`。
裝在其他地方的話，用 `HANGAR_TAILSCALE=/path/to/tailscale` 指定。

`tailscale` 只有 `TRANSPORT=tailscale` 的手機需要。純用 `TRANSPORT=lan`
（同區網直連）的話不必裝，改成需要 `nc`——macOS 內建，通常不用管。
用法見「[同區網直連](#同區網直連不經-tailscale)」。

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
- 兩邊都登入**同一個 tailnet**
- 手機端 Tailscale App 保持連線

---

## 使用

### 初始化（每支手機做一次，需同區網或插 USB）

#### 手機上要先開好的東西

`setup` 只能對「已經下得了 adb 指令」的手機動作，所以下面這幾步要先在**手機上**
做完（每支手機一次）：

1. **開發人員選項**：設定 → 關於手機 → 連點「版本號碼」7 次
2. **USB 偵錯**：設定 → 系統 → 開發人員選項 → USB 偵錯（打開）
3. **無線偵錯**：同一頁往下打開 —— 只有走配對碼流程（手邊沒有 USB 線）時才需要
4. **Tailscale App**：登入同一個 tailnet 並保持連線，`setup` 才找得到這個節點

插 USB 的話，第一次接上這台電腦時手機會跳「允許 USB 偵錯」，勾**「一律允許透過
這台電腦」**再按允許。沒按這個，`setup` 會停在 `unauthorized`。

#### 跑 setup

```bash
hangar setup
```

流程：

1. 檢查 adb / scrcpy / jq / tailscale 是否都在
2. 找 USB 裝置（插了多支會讓你選）
3. 沒有 USB 就走「無線偵錯 → 使用配對碼配對裝置」，依提示輸入 `IP:PORT` 與 6 位數配對碼
4. `adb tcpip 5555`，讓 adbd 改在 `0.0.0.0:5555` 監聽（包含 Tailscale 的 tun 介面）
5. 從 `tailscale status` 找出這支手機的節點，取 Tailscale IP
6. 寫入 profile，並用 Tailscale IP 實際連一次驗證

指定節點名稱可以跳過選單：

```bash
hangar setup pixel-7
```

自訂 profile 名稱（多台手機時很有用）：

```bash
hangar setup --name work
```

如果這支手機已經由**別台電腦**設定過（5555 已經開著），這台電腦不需要 USB：

```bash
hangar setup --existing pixel-4
```

細節見下面「[多台電腦共用同一支手機](#多台電腦共用同一支手機)」。

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

hangar 會先 `tailscale ping -c 3` 判斷路徑，再決定參數：

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
hangar enroll           # 用 USB 或網路 ADB 安裝並入伍 agent
hangar enroll -p work --reinstall   # 只換一支新版 APK（升級舊版 agent）
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

### 區網掃描

`list` 只看得到**已經設定過**的手機。`hangar scan` 反過來：不管有沒有設定、
有沒有開偵錯，只回答「這個區網上現在有哪些東西」。

```bash
hangar scan                        # 掃預設路由所在的那個 /24
hangar scan --subnet 192.168.1     # 指定網段（也吃 192.168.1.0/24 或網段內任一 IP）
hangar scan --no-ping              # 不做 ping sweep，只讀現有的 ARP 表（快很多）
hangar scan --no-probe             # 不去測每台的 5555
hangar scan --fix-ip               # 把「認得出、但 profile 指著舊 IP」的那幾支修好
hangar scan --json
```

```
  IP                MAC                 adb      agent   身分         廠商
  ────────────────────────────────────────────────────────────────────
  192.168.1.1       3c:37:86:aa:bb:cc   closed   -       閘道器       Netgear
  192.168.1.77      a4:03:e7:01:02:03   open     有      work         宏達電子
  192.168.1.90      de:ad:be:ef:00:01   closed   有      -            隨機 MAC

  共 3 台，其中 1 台的 5555 是開著的（可以 adb 進去）
  其中 2 台裝了 agent，那幾台不開偵錯也看得到機型與電量
```

找 agent 有兩條路。有 `dns-sd`（macOS 內建）或 `avahi-browse`（Linux）就先問
mDNS —— agent 會自己廣播 `_hangar-agent._tcp`，一次多播就知道哪幾台有，而且它的
TXT 裡直接帶著**序號與機型**，那台手機就算沒在這台電腦上設定過也認得出是誰。
問不到、或這台機器兩個工具都沒有，就退回逐台探 5599：慢一點，但功能不會不見。
AP 開了 client isolation 會擋掉多播，所以 mDNS 不能當唯一的路。

它怎麼做到的：先對整個 /24 各送一個 ping 把核心的 ARP 表填起來，再讀 `arp -an`
（沒有 `arp` 就用 `ip neigh`），最後對每個找到的 IP 測一次 5555。ARP 表裡的廣播
與多播位址（`ff:ff:…`、mDNS 的 `01:00:5e:…`）會濾掉 —— 那些背後沒有一台機器。

`身分` 那一欄回答的是「這台對我們來說是什麼」：已經設定過的手機叫什麼名字、
是不是這個網段的**閘道器**、還是完全不認識（`-`）。閘道器每次掃描都會出現而且
絕對不是測試機，標出來才不用每次重新想一次「192.168.1.1 是什麼」。

> 閘道位址是問**掃描用的那張介面**拿到的（macOS 問 DHCP 給的 router，Linux 問
> 那張介面的預設路由），不是問「預設路由的 gateway」—— 跑 Tailscale 的機器上
> 預設路由是點對點通道，根本沒有閘道那一欄。問不到就不標，不會亂猜一台。

#### `身分` 那欄怎麼認出是哪一支手機

只比 IP 是不夠的：DHCP 換一次位址，同一支手機就會變成「另一台」；更糟的是
舊 IP 被分給別的機器時，只比 IP 會把那台**誤認**成你的手機。所以識別碼的可靠度
由高到低是：

| | 穩定度 | 掃描拿得到嗎 |
|---|---|---|
| `DEVICE_SERIAL` | 跨 IP、跨連線方式都不變 | 拿不到（要 adb 連上才有） |
| MAC | 同一個 SSID 下穩定 | 拿得到 |
| IP | 隨時會變 | 拿得到 |

掃描碰不到 adb，所以它能用的最好的東西是 MAC：**第一次靠 IP 對上時，把那台的
MAC 記進 profile 的 `PHONE_MAC`，之後就改用 MAC 認人。**

```
  記住了「work」的 MAC（a4:03:e7:01:02:03）—— 之後這支手機換 IP 也認得出來
```

記過之後手機換了位址，`已設定` 那欄照樣標得出來，而且會提醒你 profile 過期了：

```
 !!  「work」就是 192.168.1.90 這台（MAC 一樣），但 profile 還指著 192.168.1.77
    hangar scan --fix-ip 直接改掉，或在路由器上把這支手機綁固定 IP
```

`--fix-ip` 就是照著做：把那幾支的 `PHONE_IP` 改成現在的位址。

```
 ok  「work」的 PHONE_IP 已更新：192.168.1.77 → 192.168.1.90
```

它只動 MAC 對得上的那幾支 —— 那代表這支手機已經被正面認出來，改 IP 是把 profile
修對而不是猜。第一次靠 IP 對上的（`matched_by` 是 `ip`）本來就沒有東西可修，
`tailscale` profile 存的 100.x 也不會被改成區網位址。沒有 `--fix-ip` 的話
`hangar scan` 除了補記 `PHONE_MAC` 之外不會動你的設定檔。

反過來，IP 對得上但 MAC 跟記住的不一樣時，那台**不會**被算成你的手機 ——
那個位址現在是別台機器的。`hangar scan --json` 裡的 `matched_by` 就是在講
這一台是靠什麼對上的（`mac` 比 `ip` 可信）。

`DEVICE_SERIAL` 掃描自己拿不到，但 profile 裡有，所以對上之後會一起附在
`--json` 輸出裡 —— 那是 hub 把 `scan` 與 `list` 兩份資料合起來時該用的主鍵。

需要知道的限制：

- **拿不到機型，也拿不到電量。** 沒開偵錯的手機 adb 完全碰不到，網路層只給得出
  IP 與 MAC。這一欄要補齊得等手機端的 agent app（見 [ROADMAP](ROADMAP.md)）。
- **隨機 MAC 查不到廠商。** Android 10+ / iOS 14+ 對每個 SSID 用一組隨機 MAC，
  `廠商` 會直接寫「隨機 MAC」而不是亂猜一個牌子。它在同一個 SSID 底下仍然穩定，
  所以照樣拿來認人；但使用者「忘記網路」再重連就會換一組，那時會退回比 IP，
  然後把新的那組重新記起來。
- **tailscale profile 也認得出來，但不會說它的 IP 過期。** 那種 profile 存的是
  100.x 的 tailnet 位址，跟區網 IP 本來就不一樣，拿來比沒有意義。
- **廠商要靠系統上現成的 OUI 資料庫。** 裝了 `nmap` 或 `arp-scan` 就有；沒有的話
  這一欄一律是 `?`。hangar 不內建自己的表 —— 完整的表好幾萬筆，只抄一小份會把
  不認得的廠商全部誤判成不知名。要指定自己的表：`HANGAR_OUI_FILE=/path/to/oui`。
- **只掃 /24。** 更大的網段逐台 ping 不現實，偵測到 `/16` 這種會直接要你用
  `--subnet` 指定。網段比 `/24` 小（`/28` 之類）則是掃包住它的那個 `/24`。
- **`scan` 不需要 adb 也不需要 scrcpy。** 它只用到 `ping`、`arp`／`ip`、`nc`，
  在一台只裝了網路工具的常駐機器上也跑得動 —— 之後 hub 就是那種機器。

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

### 機器可讀的輸出（--json）

`list` 和 `status` 都支援 `--json`，給程式讀用的：

```bash
hangar status --json
hangar list --json              # 只出便宜的欄位（快）
hangar list --json --probe      # 連線路徑、機型、電量一起取（慢）
```

```json
{
  "schema": 4,
  "devices": [
    {
      "profile": "work",
      "default": true,
      "transport": "tailscale",
      "host": "pixel-7",
      "ip": "100.101.102.103",
      "adb_serial": "100.101.102.103:5555",
      "device_serial": "1A2B3C4D",
      "reachability": "online",
      "adb_state": "device",
      "path": { "kind": "direct", "latency_ms": 12 },
      "model": "Pixel 7",
      "mac": { "address": "f0:5c:77:df:c7:43", "randomized": false,
               "vendor": null, "ssid": "Cathay" },
      "android": { "release": "14", "sdk": 34 },
      "battery": { "level": 78, "status": "discharging", "temperature_c": 27.5,
                   "source": "adb" },
      "agent": {
        "reachable": true, "version": "0.1.2", "enrolled": true,
        "can": { "ring": true, "toggle_adb": true, "toggle_wifi_adb": false },
        "adb": { "enabled": true, "wifi_enabled": null, "wifi_port": null }
      },
      "scrcpy_pids": [12345],
      "errors": []
    }
  ]
}
```

幾個重點：

- **`errors` 帶 code，不只帶訊息。** 「手機重開機了」這種判斷不能只活在印給人看的
  中文句子裡，不然程式沒辦法據以決策。目前的 code：

  | code | 意思 |
  |---|---|
  | `transport_down` | 傳輸層本身沒通（例如 Tailscale 沒開） |
  | `peer_not_found` | 連線方式裡找不到這台裝置 |
  | `peer_offline` | 找得到但離線 |
  | `adb_port_closed` | **連得到機器但 5555 不通 → 通常是手機重開過** |
  | `adb_unreachable` | 上層就不通了，adb 自然連不上（不是重開機） |
  | `unauthorized` | 這台電腦還沒被手機授權 |
  | `adb_offline` | adb 卡在 offline |

  `adb_port_closed` 只在「連得到機器但埠不通」時才出現。傳輸層整個沒通的時候
  不會一起報它 —— 否則讀 code 的人會去叫使用者插 USB，方向完全錯了。

- **慢欄位預設略過。** `path` 要跑一次 `tailscale ping`，`model` / `battery` / `mac`
  各要一次 adb 往返。十支手機全取會跑很久，所以 `list --json` 預設把它們留成
  `null`，要完整資料才加 `--probe`。`status --json` 只有一支，一律完整探測。

- **`--json` 時 stdout 只有 JSON。** 所有給人看的訊息都轉到 stderr，
  所以 `hangar list --json 2>/dev/null | jq .` 一定解析得過。

- **`battery.source` 與 `agent` 是 schema 2 加的，`agent.can` / `agent.adb` 是 schema 4 加的。** 前者說這筆電量是誰量的
  （`adb` 還是 `agent`），後者在沒入伍也叫不動時是 `null` —— 細節見
  [手機端 agent](#手機端-agent)。

- **`mac` 是 schema 3 加的，跟 `scan` 那份不是同一個來源。** 這裡的 MAC 是
  `adb shell cmd wifi status` 問手機自己要的，所以走 tailscale 或人在別的 Wi-Fi
  上的手機也有 —— `hangar scan` 是對某個網段送 ARP，那些手機它永遠對不上。
  （不讀 `/sys/class/net/wlan0/address` 或 `ip link` 是因為 Android 11 起這兩條路
  對 shell 使用者都是 `Permission denied`。）

  `randomized` 為 `true` 表示這是 Android 10+ 每個 SSID 一組的隨機 MAC，換個
  Wi-Fi 就換一組 —— `ssid` 記的就是「這組 MAC 屬於哪個網路」。**別拿它當長期
  識別碼**，那是 `device_serial` 的工作。兩邊都有 MAC 時 hub 用 `scan` 那一份：
  ARP 換來的才是 hub 實際看到的那張網卡。

- **`device_serial` 是穩定識別碼。** IP 會變、連線方式會換，硬體序號不會。
  這是日後要認出「同一支手機」時唯一可靠的欄位。

- **退出碼不代表手機的狀態。** `list --json` / `status --json` 只要指令本身跑完
  就回 `0`，即使手機離線、adb 連不上也一樣 —— 那些是 `errors` 裡的內容，
  不是「指令失敗」。要判斷一支手機現在能不能用，請讀 JSON：

  ```bash
  hangar status --json -p work 2>/dev/null \
    | jq -e '.devices[0].adb_state == "device"' >/dev/null && echo 可用
  ```

  會回非 0 的是「這件事做不到」：參數寫錯、profile 不存在、缺相依工具，
  以及投影類指令（`hangar`、`hangar all`）真的沒開起來（`all` 只要有一支失敗就非 0）。

- **`--probe` 只對 `--json` 有作用。** 人類版 `list` 的欄位是固定的，
  加了會警告並忽略。

`scan --json` 是另一份文件（描述的是網段，不是 profile），所以 schema 號碼自己算：

```json
{
  "schema": 7,
  "subnet": "192.168.1.0/24",
  "hosts": [
    {
      "ip": "192.168.1.77",
      "mac": "a4:03:e7:01:02:03",
      "vendor": "宏達電子",
      "mac_randomized": false,
      "adb_port": "open",
      "profile": "work",
      "matched_by": "mac",
      "device_serial": "R58M12345AB",
      "profile_ip_stale": false,
      "profile_ip_fixed": false,
      "agent": { "version": "0.1.2", "enrolled": true,
                  "model": "Pixel 7 Pro", "discovered_by": "mdns" },
      "is_gateway": false
    }
  ],
  "errors": []
}
```

`agent` 在那台有 agent 在聽 5599 時才不是 `null`。`agent.enrolled` 是 agent 回報的
入伍狀態；舊版 agent 或拿不到欄位時為 `null`。`is_gateway` 是「這台是這個
網段的閘道器」。`agent.discovered_by` 說的是怎麼找到它的：

| | |
|---|---|
| `mdns` | agent 自己用 mDNS 報名的。這條路連 `model` 與序號都拿得到 |
| `probe` | 逐台探 5599 探出來的。只拿得到版本，`model` 是 `null` |

`adb_port` 是 `open` / `closed` / `unknown`（`--no-probe` 或這台
機器沒有 `nc`）。
`profile` 對不上任何已設定的手機時是 `null`，`matched_by` 與 `device_serial`
也跟著是 `null`。`subnet` 是實際掃過的範圍。

`matched_by` 是「這台是靠什麼認出來的」：`mac`（可信）或 `ip`（第一次，還沒記過
MAC）。`device_serial` 來自對上的那個 profile，是跨 IP、跨連線方式都不變的主鍵。
`profile_ip_stale` 為 `true` 表示 MAC 認得出是同一支手機，但那個 profile 的
`PHONE_IP` 已經是舊的了 —— 投影會連到錯的地方。加上 `--fix-ip` 的話這種會被
就地改好，那一台的 `profile_ip_fixed` 會是 `true`、`profile_ip_stale` 回到
`false`。**要注意 `--fix-ip` 會寫設定檔**，所以固定輪詢 `scan --json` 的程式
（例如之後的 hub）別無條件帶著它跑。
scan 自己的 error code：

| code | 意思 |
|---|---|
| `scan_unavailable` | 這台電腦上缺工具（讀不到 ARP 表） |
| `subnet_unknown` | 測不出預設路由的網段，要用 `--subnet` 指定 |
| `subnet_too_big` | 偵測到的網段比 `/24` 大，掃不動 |
| `subnet_invalid` | `--subnet` 給的值看不懂 |

「缺工具」跟「區網上沒東西」分成兩件事報，跟 `transport_unavailable` 是同一個
道理：前者要修的是這台電腦，後者才該去看裝置。

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
PHONE_MAC="a4:03:e7:01:02:03"  # 區網 MAC，由 hangar scan 記下來（見上面的區網掃描）
AGENT_TOKEN="…64 個十六進位字元…"  # 手機端 agent 的 token，由 hangar enroll 寫入
AGENT_PORT="5599"              # agent 聽的埠
```

> **有 `AGENT_TOKEN` 的 profile 是有祕密的檔案。** 那組 token 等於「可以問這支
> 手機的狀態、之後還能切它的偵錯開關」。檔案權限是 600，不要隨手貼給別人，也
> 不要丟進版控。沒入伍過的手機沒有這一行，那種 profile 仍然只是幾行純文字。

前兩行以外都是可選的。舊版只有兩行的 profile 照樣能用，讀不到時
`TRANSPORT` 當作 `tailscale`、`DEVICE_SERIAL` 與 `PHONE_MAC` 當作空的，
不需要做任何轉換。`PHONE_MAC` 是 `hangar scan` 第一次用 IP 對上這支手機時
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

## 多台電腦共用同一支手機

**關鍵：手機的 5555 一旦開著，第二台電腦不需要 USB，也不用再跑 `adb tcpip`。**
`adb tcpip` 是手機端的狀態，跟哪台電腦設定的無關。第二台電腦要的只有兩件事：
一份設定檔，以及手機對這台電腦的授權。

### 在第二台電腦上

```bash
# 1. 裝相依套件 + hangar
brew install --cask android-platform-tools
brew install scrcpy jq
git clone <這個 repo> && cd hangar && ./hangar_install.sh

# 2. 建立設定（不需要 USB）
hangar setup --existing pixel-4
```

第一次一定會停在這裡：

```
 xx  狀態 unauthorized
     這台電腦還沒被手機授權過（換電腦第一次連都會這樣，是正常的）。
     手機畫面上會跳出「允許 USB 偵錯」，勾「一律允許透過這台電腦」再按允許，
     然後重跑一次這個指令。
```

手機上按完「一律允許」，再跑一次 `hangar setup --existing pixel-4` 就好了。
之後這台電腦就跟第一台一樣用。

> 授權是綁在**每台電腦自己的 adb 金鑰**（`~/.android/adbkey`）上的，
> 所以每台電腦都要在手機上按一次允許。
> **不要把 `adbkey` 複製到別台電腦** —— 那等同於把手機的完整控制權複製過去。

### 也可以直接複製設定檔

**沒入伍過的** profile 就是幾行純文字、沒有祕密（IP、序號、MAC，沒有金鑰），
直接抄過去也行：

```bash
scp ~/.config/hangar/profiles/pixel-4.conf 另一台:~/.config/hangar/profiles/
```

一樣要在手機上授權那台電腦。

入伍過的手機（profile 裡有 `AGENT_TOKEN`）抄過去等於把 token 也給了對方 ——
那組 token 可以問這支手機的狀態、之後還能切偵錯。要給就是有意識地給，
不要因為「只是一個設定檔」就順手 `scp`。

### ACL 要記得加新電腦

如果你照前面設了 ACL，`src` 只寫了第一台電腦的話，第二台會連不上。
建議把電腦也打 tag：

```json
{
  "tagOwners": {
    "tag:phone":  ["autogroup:admin"],
    "tag:devbox": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["tag:devbox"], "dst": ["tag:phone:5555"] }
  ]
}
```

之後每台新電腦打上 `tag:devbox` 就好，ACL 不用再改。

### 在那台電腦上 build app 進手機

**hangar 不在 build 的路徑上，hub 也不在。** `adb tcpip 5555` 是手機端的狀態，
手機的 5555 開著之後，任何到得了它的電腦都可以直接 `adb connect`、直接安裝 ——
不需要經過設定這支手機的那台電腦，也不需要經過之後的 hub。

RD 那台要的東西跟投影完全一樣（網路到得了、手機授權過），差別只在最後要把
build 指向這支手機：

```bash
hangar status -p pixel-4                     # 先確認 adb 是 device
export ANDROID_SERIAL=100.x.y.z:5555         # 或區網的 192.168.1.77:5555
./gradlew installDebug
```

`ANDROID_SERIAL` 是 adb 自己的環境變數，Gradle 與 `adb install` 都吃它。
不設的話，同時連著多支手機時 Gradle 會不知道要裝哪一支而停下來。手機的
serial 就是 `hangar list` 裡的 IP 加 `:5555`，或直接從 `--json` 拿：

```bash
export ANDROID_SERIAL="$(hangar status --json -p pixel-4 2>/dev/null | jq -r '.devices[0].adb_serial')"
```

Android Studio 走的是它自己啟動的 adb server，要它看到這支手機，最省事的方式
是在開 Studio 之前先 `adb connect <ip>:5555`（`hangar status` 會順手做掉），
裝置選單裡就會出現。

幾個實際會踩到的：

- **手機重開機後 5555 會消失**，RD 那台自己救不回來 —— 要有人把手機接 USB 或在
  同區網重跑一次 `hangar setup`。這是[專案方向](ROADMAP.md)裡 agent app 要解決的
  問題之一。
- **多個人同時裝同一支手機會互相蓋掉。** 目前沒有任何佔用／排隊機制，只能靠講。
- **QA 在測加固版時偵錯是關著的**，那時候誰都 build 不進去。這是 ROADMAP 的 M4。

### 幾件事先講清楚

| | |
|---|---|
| 可以同時投嗎 | 可以。adbd 支援多個連線，兩台電腦各開各的 scrcpy 視窗互不干擾 |
| build 要經過 hub 嗎 | 不用。adb 本來就是網路協定，RD 的電腦直接連手機的 5555 |
| 手機重開機後怎麼辦 | 只要**任一台**接得到 USB／同區網的電腦重跑 `hangar setup`，其他電腦就自動恢復（授權還在，不用再按一次） |
| 第二台電腦能自己救嗎 | 不行。`adb tcpip` 需要一條既有的 USB 或同區網連線，遠端做不到 |
| profile 名稱要一致嗎 | 不用。每台電腦各自取名，`--name` 想叫什麼都行 |

---

## 手機端 agent

`hangar scan` 看得到區網上有哪些裝置，但**沒開偵錯的手機 adb 完全碰不到** ——
拿得到 IP、MAC、廠商，拿不到機型，更拿不到電量。唯一的破口是在手機裡放一支
常駐的 app：它自己回報，不需要 adb。

程式在 [`agent/`](agent/)，協定寫在 [ROADMAP](ROADMAP.md) 的「M3 協定」。

### 入伍：一次性 ADB（USB 或網路）

```bash
cd agent && ./gradlew assembleDebug     # 先 build 出 APK
cd .. && hangar enroll -p work          # USB，或已經通得到的網路／Tailscale ADB
```

`hangar enroll` 做五件事：裝 APK、授予 `WRITE_SECURE_SETTINGS`、把這台電腦上的
profile 名字連同裝置序號與一組隨機 token 交給 agent、把 app 叫到前景、再直接問一次
agent 確認活著。成功之後 token 寫進 profile，手機上的 agent 頁面會把 profile 名字
大字顯示；如果走的是網路 ADB，整個流程不需要插 USB。

```
==> 1/5 安裝 agent
 ok  安裝完成
==> 2/5 授予 WRITE_SECURE_SETTINGS
 ok  已授予
==> 3/5 交出 profile 名字、裝置序號與 token
 ok  序號 R58M12345AB，token 已寫進 ~/.config/hangar/profiles/work.conf
==> 4/5 把 agent 叫起來
==> 5/5 驗證：直接問 agent
 ok  agent 0.1.2 回應正常
     機型  Pixel 7 Pro
     電量  78%  放電中  27.5°C
```

`--apk` 可以指定別的檔案；不給的話會找這個 repo 裡 build 出來的那份。

**一台手機只入伍一次。** 已經入伍過的會直接拒絕，要重來得先
`adb shell pm clear com.hangar.agent` —— 那本來就需要 adb。理由見
[agent/README.md](agent/README.md)。

### 升級舊版 agent：`--reinstall`

手機上那支 agent 還在、也還入伍著，只是版本太舊 —— 例如裝置牆說「這支 agent
沒宣告 `ring` 能力」。這種時候要的不是重新入伍，是換一支新的 APK：

```bash
cd agent && ./gradlew assembleDebug
cd .. && hangar enroll -p work --reinstall
```

```
==> 1/4 換上新版 agent（保留入伍狀態）
 ok  安裝完成
==> 2/4 重新授予 WRITE_SECURE_SETTINGS
 ok  已授予
==> 3/4 把 agent 叫起來
==> 4/4 驗證：用原本那組 token 問一次
 ok  agent 0.1.2 回應正常
     機型  Pixel 7 Pro
     能力  響鈴、切偵錯、切無線偵錯

 ok  agent 更新完成。token 沒有變，牆上那張卡不用重新入伍。
```

`adb install -r` 是**就地升級**，app 的資料不會被清掉 —— 所以 token 還在手機裡，
這台電腦的 profile 不用動。這一點是刻意的：token 是每台電腦各自保管的，
`pm clear` 之後其他也入伍過這支手機的電腦會全部被鎖在門外，而升級不該有這種代價。

順手處理的兩件事：

- **權限**：第二步會再授予一次 `WRITE_SECURE_SETTINGS`。上次入伍時這一步失敗
  （手機沒解鎖、被 OEM 擋掉）的手機，升級之後就切得動偵錯了。
- **入伍資料不見了**：如果新裝上去的 agent 說自己沒入伍（有人 `pm clear` 過，或
  app 曾被解除安裝），這時候手上還有 adb，指令會直接補一次完整入伍並寫一組新
  token，不會丟一個錯誤要你再跑一次別的指令。

裝得上去、但新版不認這台電腦的 token（手機上那支是別台電腦入伍的），指令會停下來
講清楚，不會假裝成功。這種情況只能 `pm clear` 之後重新入伍，代價就是上面那句。

### 入伍之後有什麼不一樣

| | 沒有 agent | 有 agent |
|---|---|---|
| 手機重開機後（5555 沒了） | `list` 只剩「連不上」 | 機型、電量照樣看得到 |
| 沒開偵錯時 | 只有 IP / MAC / 廠商 | 完整裝置資訊 |
| 電量 | 要 adb 進得去才拿得到 | agent 直接回報 |

`hangar list --json --probe` 的 `battery.source` 會告訴你這筆電量是誰量的
（`adb` 還是 `agent`），`agent` 物件則說得出 agent 在不在：

```json
{ "battery": { "level": 42, "status": "discharging", "source": "agent" },
  "agent":   { "reachable": true, "version": "0.1.2", "enrolled": true } }
```

`agent.reachable` 是 `false` 而 profile 又有 token，意思是**這支手機入伍過但
agent 現在叫不動** —— 現在可能還沒事（adb 還通），但下次重開機就會失聯。
裝置牆會把這件事標出來。

`hangar scan` 也會順手探每台的 5599：探得到就在 `agent` 欄標「有」。它先用
`nc` 測埠、只對有回應的發 HTTP —— 一個 /24 上大多數東西沒有 agent，每台都等
逾時的話掃描會從幾秒變成幾分鐘。

### 限制

- **需要 `curl`**（macOS 內建）。沒有的話只是問不到 agent，掃描與其他功能照常。
- **agent 拿不到自己的 MAC**（Android 6+ 對一般 app 回傳假的
  `02:00:00:00:00:00`），所以 agent 回報的資料裡沒有這一欄。MAC 由另外兩條路
  取得：`hangar scan` 從 ARP 表學，或 `hangar list --probe` 用
  `adb shell cmd wifi status` 問 —— 後者連 adb 通得到但不在同一段區網的手機
  也拿得到。
- **agent 也拿不到硬體序號**（Android 10+ 要特權權限），所以序號是入伍時由電腦
  這一側寫進去的 —— 兩邊因此一定是同一個字串。
- **切偵錯已由 agent 實作，而且是全手動的。** `POST /hangar/v1/adb` 支援雙向
  切換，CLI 是 `hangar adb -p work --off` / `--on`。偵錯的開關**只會因為有人按
  了才改變**：agent 不排鬧鐘、不在開機時改它，關掉之後就一直關著。能力不足的
  裝置會明確回報，不會把「不能寫」誤當成成功。
- **響鈴已由 agent 實作。** `hangar ring -p work --seconds 30` 走 alarm stream、
  震動與高優先度通知，最長 120 秒；`--stop` 或手機通知上的「找到了」都能停止。

---

## hub（裝置牆網頁）

一台常駐機器跑 `hub/hangar_hub.py`，定期問 hangar 兩件事，然後把結果合成一頁
裝置牆：

```
hangar list --json --probe   已經設定過的手機：adb 狀態、機型、電量
hangar scan --json           區網上看得到的所有東西：IP、MAC、廠商、5555
```

```bash
./hub/hangar_hub.py                       # 只綁 127.0.0.1:8787
./hub/hangar_hub.py --bind 0.0.0.0 --port 8787   # 要給同事看才這樣開
```

用的是 Python 3 的標準函式庫，**沒有任何套件要裝** —— 常駐機器上不該為了看一頁
網頁而先裝一套生態系，跟 `hangar` 自己是一支無相依 bash script 是同一個理由。

| 參數 | 預設 | |
|---|---|---|
| `--hangar` | repo 裡那支 | hangar 執行檔的路徑 |
| `--bind` / `--port` | `127.0.0.1` / `8787` | 預設只有本機看得到 |
| `--list-interval` | 30 秒 | 多久問一次 `hangar list` |
| `--scan-interval` | 300 秒 | 多久掃一次區網（ping 整個 /24 不便宜） |
| `--subnet` | 自動偵測 | 同 `hangar scan --subnet` |
| `--no-scan` | | 完全不掃區網，只看已設定的手機 |

端點：`/`（裝置牆）、`/api/devices`（合併後的 JSON）、`/api/refresh`（POST，見下面）、`/healthz`。

### 多久更新一次

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

### 起不來的時候

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

### 那頁上的狀態是什麼意思

| | |
|---|---|
| `ready` | adb 是 `device`，可以 build 也可以投影 |
| `no_adb` | 連得到，但 adb 不是 `device` —— 幾乎都是手機重開機把 5555 弄丟了 |
| `unauthorized` | 這台 hub 還沒被那支手機授權過（要有人在手機上按允許） |
| `offline` | 手機不在線上 |
| `unknown` | 只從掃描看到它，`hangar list` 那邊沒資料（那次輪詢多半失敗了） |
| `unmanaged` | 掃得到但沒設定過。沒開偵錯的手機 adb 完全碰不到，所以只有 IP、MAC、廠商 |

同一支手機在兩份資料裡會合成同一張卡，合併的主鍵是 `DEVICE_SERIAL`，沒有序號
才退回 MAC、再退回 IP —— 跟 `hangar scan` 認人用的是同一套順序（見上面的
[區網掃描](#區網掃描)）。所以手機換了 IP，裝置牆不會多出一台幽靈。

### 這一版是唯讀的

裝置牆不會去動手機，也不會去改設定檔：輪詢只跑 `list` 與 `scan`，**刻意不帶
`--fix-ip`**（那會寫 profile，固定輪詢的程式無條件帶著它跑遲早出事）。profile
指著舊 IP 時它只會在那張卡上說一句，要修還是你自己去跑 `hangar scan --fix-ip`。

牆上的**投影、響鈴、切偵錯按鈕也沒有破壞這件事**：它們叫的不是 hub，而是你
自己那台電腦上的 helper（見[從裝置牆上按投影](#從裝置牆上按投影)）。helper
再呼叫 CLI，CLI 才去碰手機裡的 agent。hub 這一側仍然只有唯讀資料與輪詢喚醒
端點；沒有任何 `/api/*` 寫入手機的路。

在卡片上，響鈴只對「agent 可達且宣告 `can.ring`」的手機啟用；偵錯只對宣告
`can.toggle_adb` 且回報了 `adb.enabled` 的手機啟用。helper 沒有啟動時，按鈕會
改成複製 `hangar ring`／`hangar adb` 指令。**在瀏覽器裡直接看到畫面（網頁投影
串流）仍然是遠期目標** —— 投影本身維持走 CLI 的 scrcpy，那顆按鈕省的是打字，
不是換掉投影的方式。

### 換一台 hub

hub 本身是**無狀態的** —— 它把看到的東西放在記憶體裡，重開就重新問一次 hangar。
所以「搬 hub」實際上搬的是三樣東西，而且只有一樣會痛。

| 要搬的 | 怎麼搬 | 痛不痛 |
|---|---|---|
| `~/.config/hangar/`（profiles、預設值） | `scp -r` 或 `rsync` | 不痛 |
| 常駐設定（launchd plist／systemd unit） | 照上面重寫一份 | 不痛 |
| **手機對這台電腦的 adb 授權** | 見下面 | **會痛** |

#### 會痛的那一樣

adb 的授權綁在每台電腦自己的金鑰（`~/.android/adbkey`）上。新的 hub 是一把新
金鑰，所有手機都會把它當陌生人 —— 每一支都要有人在手機螢幕上按一次「一律允許」。
十支手機就是十次。

**agent 那條路不受影響**：`AGENT_TOKEN` 在 profile 裡，profile 搬過去，新 hub
就問得到入伍過的手機。所以入伍過的手機在搬 hub 時是「電量與機型照樣看得到，
只是 adb 進不去」。這也是 agent 在這件事上的實際價值。

#### 如果是「汰換」而不是「多一台」

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

> 這跟前面「**不要把 `adbkey` 複製到別台電腦**」不衝突：那條講的是同時存在的
> 多台電腦（複製＝多一份完整控制權）。汰換是搬移，前提是**舊的那份要刪掉**。
> 做不到「確定刪掉」的話，就老老實實一支一支按。

#### 搬完檢查這幾件事

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

### 讓它開機就自己跑

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

---

## 從裝置牆上按投影

裝置牆上每張已設定的手機卡片都有一顆投影按鈕。按下去，scrcpy 開在**按按鈕的
那台電腦**上。

要理解它為什麼長這樣，先看一個限制：**網頁啟動不了本機程式**。所以按鈕不能
直接叫 hub —— hub 在角落那台常駐機器上，它跑起來的視窗開在那台機器的螢幕上，
沒有人看得到。要按的那台電腦得自己跑一支小服務，網頁再去叫它：

```bash
./helper/hangar_helper.py --hub http://192.168.1.5:8787
```

`--hub` 要跟你**瀏覽器網址列上的那一串一模一樣**（只有那一頁叫得動 helper）。
它起來之後會印一個帶鑰匙的連結：

```
hangar helper: http://127.0.0.1:8788/（只有這台電腦連得到）
在這台電腦的瀏覽器開這個連結一次，裝置牆就記得住這台電腦了：
  http://192.168.1.5:8787/#helper=ab12…&port=8788
（鑰匙在 # 後面，不會送到 hub 那邊去）
```

在那台電腦上開一次那個連結，牆上的按鈕就活了。鑰匙存在那台瀏覽器裡，之後
直接開裝置牆就好。

除了投影，這個 helper 也承接兩個不應由 hub 直接發出的動作：

```bash
hangar ring -p work --seconds 30             # 用聲音、震動與通知識別手機
hangar ring -p work --stop                   # 立刻停止
hangar adb -p work --off                     # 關閉偵錯（QA 測加固版的常態）
hangar adb -p work --on                      # 重新開啟偵錯（RD 要 build 進去）
```

這三個動作共用 helper 的 localhost、Origin 與 token 三道鎖。響鈴會自己停（最長
由 agent 夾到 120 秒），因為一支在抽屜裡響一整天的手機是災難。**偵錯剛好相反：
它是一個狀態，不是一個動作，所以沒有任何東西會自動把它改回去** —— 機房的常態
就是關著測加固版，一顆半小時後把偵錯開回來的鬧鐘等於在長測中途偷改條件。

代價要講清楚：偵錯關著的時候，手機上那支 agent 的 HTTP 端點是唯一回得去的路。
agent 掛了就得有人拿著手機處理。這個代價是選的，不是忘的 —— 用自動復原去換它
並不划算，因為那只是每隔一段時間開一扇隨機的窗，並沒有讓那條路變可靠。

### 從裝置牆自動入伍

如果某張卡的 ADB 狀態是 `device`，但還沒有能回應的 agent，卡片會在投影按鈕右邊顯示
「註冊 agent」。如果 profile 還留著舊 token、但手機上的 APK 已被解除安裝，這顆按鈕
也會出現，讓它用同一條 ADB 路徑補裝。按下去後，**按按鈕的這台電腦**上的 helper
會透過 profile 的 USB 或網路／Tailscale ADB 執行：

```bash
hangar enroll -p <這台電腦上的 profile>
```

它使用的仍然是 CLI 原本的 enrollment 流程：安裝 APK、授予
`WRITE_SECURE_SETTINGS`、寫入 profile 名字、序號與 token，再驗證 agent。hub 不會直接執行這個
指令，也不會代替 helper 操作手機；因此這台電腦仍然必須先有可用的 ADB 連線與
profile。若 agent 其實還在手機上、只是暫時沒有回應，Android 端會拒絕重複入伍並提示
先清除 app 狀態，不會默默覆蓋原本的 token。

如果 helper 沒有啟動，按鈕會改成「複製註冊指令」，讓你貼到終端機執行。入伍需要
安裝好的 agent APK；找不到 APK 時，helper 會把 CLI 的 build 提示帶回裝置牆。

### 從裝置牆升級舊版 agent

入伍過的手機也可能停在舊版：裝置牆會把低於目前標準 `0.1.2` 的 agent 標出來。
這時候卡片會多一顆**「更新agent」**，按下去等於在這台電腦上執行：

```bash
hangar enroll -p <這台電腦上的 profile> --reinstall
```

判斷「是不是舊版」看的是 agent 回報的數字版號，並以目前標準 `0.1.2` 做比較：
`0.1.1` 會被視為舊版，`0.1.2` 以及更高版本不會被降版。`can.ring` 只代表
響鈴能力，不再拿來推測 APK 版本；`can.toggle_adb` 也不能拿來判斷，因為
`WRITE_SECURE_SETTINGS` 沒授予時它本來就可能是 `false`。

這顆按鈕只在 ADB 狀態是 `device` 時出現：沒有 ADB 就沒有路把 APK 送上去，卡片
會直接說明原因，不留一顆按下去一定失敗的按鈕。helper 沒連上時它一樣退成
「複製更新指令」。

換版**不會動到入伍狀態，token 也不會變**，所以其他也入伍過這支手機的電腦不會
因此被鎖在門外；理由見上面的 [`--reinstall`](#升級舊版-agent--reinstall)。
hub 這一側沒有新增任何會動手機的端點 —— 按鈕走的仍然是 helper 的 `/enroll`，
只是 body 多一個 `reinstall`。

### 每台電腦要先做的事

| | 為什麼 |
|---|---|
| 裝好 `hangar` + `adb` + `scrcpy`（[安裝](#安裝)那一節） | 按鈕跑的就是 `hangar -p <名稱>`，它省的是打字，不是省掉這些 |
| 跑過一次 `hangar setup` | **這一步躲不掉**：adb 授權綁的是每台電腦自己的金鑰，要有人在手機上按「一律允許」。任何按鈕都繞不過它 |
| 跑著 `hangar_helper.py` | 網頁啟動不了本機程式 |

沒 setup 過的手機按下去，按鈕會照實說：

```
這台電腦上沒有這支手機（work）—— 先在這台電腦跑一次 hangar setup
```

牆上的名字是 **hub 那台機器**取的，同一支手機在你的電腦上可以叫別的名字：
按鈕會連**序號**一起送，helper 優先用序號去對，對到了會告訴你它在這台電腦上
叫什麼。這跟 `hangar scan` 認人用的是同一套順序。

### 它會回答你，不是丟出去就算

按下去之後 helper 會等到其中一件事發生才回話：

| 發生的事 | 牆上顯示 |
|---|---|
| process 變成 scrcpy 了 | `投影視窗開了（你的電腦名）` |
| `hangar` 中途失敗 | 它自己的錯誤與提示，例如 `手機不在線上 —— 去看看它有沒有開機` |
| 等超過 `--grace`（預設 30 秒） | `還在跑，但等了 30 秒沒看到 scrcpy 接手` |

「真的起來了」判斷的是 `hangar` 最後那一步 `exec scrcpy` 把 process 換掉 ——
不是解析任何訊息文字，也不是「叫過了就算成功」。

> [!NOTE]
> 卡片上的「這支手機的畫面正開在 <hub 的機器名> 上」講的是 **hub 那一台電腦**，
> 不是你（hub 剛好就是你這台時會多寫一句「你這台電腦」）。
> 同事在自己電腦上按的投影，牆上看不到 —— 那個欄位是 `hangar list` 在 hub 上
> `pgrep` 出來的。誰在用哪一支還沒有任何佔用機制，三個人同時按同一支會各投各的。

### 三道鎖

「網頁叫得動本機程式」本來就是要小心的事：

| | |
|---|---|
| 只綁 `127.0.0.1` | 別台電腦連不到。**沒有 `--bind` 可以改** |
| Origin 白名單 | 只有 `--hub` 給的那些網址上的頁面叫得動。Origin 是瀏覽器自己填的，頁面上的 JS 偽造不了 |
| token | 擋掉這台電腦上其他不是從那頁來的呼叫。放在 `~/.config/hangar/helper.token`（0600），換一把用 `--new-token` |

hub 那一側**什麼都沒有多**：沒有新端點，也沒有任何會動到手機的路。按下去走的
是「你的瀏覽器 → 你自己電腦上的 helper」，hub 全程不知情。

| 參數 | 預設 | |
|---|---|---|
| `--hub` | 無（必填） | 裝置牆的網址，可以給多次 |
| `--hangar` | repo 裡那支 | hangar 執行檔的路徑 |
| `--port` | `8788` | 只在 `127.0.0.1` 上聽 |
| `--grace` | 30 秒 | 等投影起來的上限 |
| `--enroll-timeout` | 180 秒 | 等 agent 入伍（或更新）完成的上限 |
| `--new-token` | | 換一把新鑰匙（舊連結失效） |

### 按不動的時候

牆上那一行會講是哪一種：

| 牆上寫的 | 多半是 |
|---|---|
| 這台電腦得先跑一支 helper | 還沒開過那個帶鑰匙的連結 |
| 叫不動這台電腦的 helper | helper 沒在跑，**或者 `--hub` 跟這一頁的網址對不起來**（`localhost` 與 `192.168.x.x` 是不同的來源），也可能是瀏覽器不讓網頁連本機 |
| helper 在跑，但這一頁沒有它的鑰匙 | 換過 token 了，再開一次那個連結 |

> [!IMPORTANT]
> 瀏覽器對「區網上的頁面連 127.0.0.1」還有自己的一關（Chrome 的 Private
> Network Access／Local Network Access），新版可能會跳一次權限詢問。helper
> 該給的標頭都給了，但那個詢問是瀏覽器的 UI，程式這邊關不掉也繞不過。
> **這一關還沒有在各家瀏覽器的新版上實測過**，第一個試的人請回報。

按不動也不會卡住：helper 不在的時候投影按鈕會變成**複製指令**；如果手機符合
自動入伍條件，註冊按鈕也會變成複製 `hangar enroll -p <名稱>`，舊版 agent 的
更新按鈕則變成複製 `hangar enroll -p <名稱> --reinstall`。貼到終端機的
結果完全一樣。

### 讓 helper 開機就自己跑

macOS（launchd，存成 `~/Library/LaunchAgents/com.hangar.helper.plist`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.hangar.helper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/你/Hangar/helper/hangar_helper.py</string>
    <string>--hangar</string><string>/usr/local/bin/hangar</string>
    <string>--hub</string><string>http://192.168.1.5:8787</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
```

`PATH` 那一段不能省：launchd 給的環境很乾淨，`adb` 與 `scrcpy` 在 Homebrew
底下，找不到的話按鈕會說投影沒起來。

## 同區網直連（不經 Tailscale）

手機跟電腦本來就在同一個區網、不需要跨網路時，可以不走 Tailscale ——
profile 裡把 `TRANSPORT` 寫成 `lan` 就好。這種 profile 不需要 `tailscale` CLI，
改用 `nc` 測 5555 埠通不通（macOS 內建）。

**`hangar setup` 目前只會產生 `tailscale` 的 profile**，所以 lan 的要自己寫一份
（`hangar scan` 已經列得出區網上有哪些裝置，但還沒有「從掃描結果直接建 profile」
這條路）：

```bash
# 1. 手機插 USB（或已經在同一區網、adb 連得到），把 adbd 切到 TCP 模式
adb tcpip 5555

# 2. 查手機的區網 IP：設定 → 關於手機 → 狀態資訊 → IP 位址

# 3. 寫 profile
mkdir -p ~/.config/hangar/profiles
cat > ~/.config/hangar/profiles/deskphone.conf <<'EOF'
PHONE_HOST=""
PHONE_IP="192.168.1.50"
TRANSPORT="lan"
EOF
chmod 600 ~/.config/hangar/profiles/deskphone.conf
```

之後 `hangar -p deskphone`、`status`、`list`、`reset`、`all` 全部照常用，
訊息裡的措辭會自動換成「區網」而不是 tailnet。

| | `tailscale` | `lan` |
|---|---|---|
| 需要的工具 | `tailscale` | `nc`（macOS 內建） |
| 連線路徑 | `tailscale ping` 判斷 direct / relay | 一律當 direct，所以預設走高畫質 |
| 節點名 | 有，`PHONE_HOST` 用得到 | 沒有，`PHONE_HOST` 留空即可 |
| 位址會不會變 | Tailscale IP 基本上不變 | DHCP 換位址就要改 `PHONE_IP`，建議在路由器上綁固定 IP。`hangar scan` 靠 MAC 認得出換過位址的手機，`hangar scan --fix-ip` 直接改好 |
| 手機重開機後 | 一樣要重跑 `setup`（5555 消失） | 一樣要重下一次 `adb tcpip 5555` |

> **區網直連沒有 ACL 這層保護。** `adb tcpip 5555` 在區網上是全開的，
> 同一個 Wi-Fi 下的任何人都連得到你手機的 adb，而 adb 等於完整的裝置控制權。
> 只在自己信得過的網路用；公司、咖啡廳、公共 Wi-Fi 請一律走 Tailscale 並設
> [ACL](#tailscale-acl強烈建議)。

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
> 但那等於把 adb 永久開在所有網路介面上，請務必搭配下面的 ACL 一起用。

---

## Tailscale ACL（強烈建議）

`adb tcpip 5555` 會讓 adbd listen 在 `0.0.0.0:5555` —— **包含 Tailscale 介面在內的所有介面**。
預設的 tailnet ACL 是全通的，意思是 tailnet 裡任何一台裝置都能連你手機的 adb，
而 adb 等於完整的裝置控制權。

請到 admin console（https://login.tailscale.com/admin/acls）限制成只有你的開發機能碰 5555。

### 步驟

1. 幫手機打上 tag。在 ACL 檔加入：

```json
{
  "tagOwners": {
    "tag:phone": ["autogroup:admin"]
  }
}
```

然後在 admin console 的機器列表把手機設成 `tag:phone`
（或在手機上 `tailscale up --advertise-tags=tag:phone`）。

2. 加上 ACL 規則：

```json
{
  "tagOwners": {
    "tag:phone": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["<你的電腦>"],
      "dst": ["tag:phone:5555"]
    }
  ]
}
```

`<你的電腦>` 可以是：

- 你的 Tailscale 帳號：`"your-email@example.com"`（該帳號下所有裝置）
- 特定裝置的 tag：`"tag:devbox"`
- 特定裝置名稱：`"macbook"`

多支手機都打同一個 `tag:phone` 就好，規則不用改。

3. 記得 ACL 一旦寫了 `acls` 區塊就變成白名單，其他原本能通的流量會被擋掉。
   如果你 tailnet 裡還有別的服務，要一併補上規則，例如：

```json
{
  "tagOwners": {
    "tag:phone": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"] },
    { "action": "accept", "src": ["<你的電腦>"],        "dst": ["tag:phone:5555"] }
  ]
}
```

改完按 **Preview** 確認沒把自己鎖在外面，再 Save。

---

## 密碼頁面投影全黑（FLAG_SECURE）

**這不是 Hangar 或 scrcpy 的問題，是 Android 系統層的設計。**

App 可以在視窗上加 `WindowManager.LayoutParams.FLAG_SECURE`，被標記的視窗會從
**所有**螢幕擷取管道中排除 —— 截圖、螢幕錄影、投影一律變黑。
鎖定畫面（keyguard）、銀行 / 支付 App、密碼管理器、Netflix 之類的 DRM 內容，
還有很多 App 的密碼輸入頁，都會加這個旗標。

### 先確認是不是這個原因

```bash
adb -s <tailscale-ip>:5555 shell screencap -p /sdcard/t.png
adb -s <tailscale-ip>:5555 shell ls -l /sdcard/t.png
```

在那個頁面截圖，如果拉回來也是全黑，就確定是 FLAG_SECURE。
換 scrcpy 版本、調 bitrate、換 codec 都不會有任何差別。

也可以直接看目前前景視窗的旗標：

```bash
adb -s <tailscale-ip>:5555 shell dumpsys window | grep -iE 'mCurrentFocus|SECURE'
```

### 可行的做法

**1. 看不到，但打得進去**

畫面是黑的，但**輸入完全正常**。scrcpy 的鍵盤轉發照樣送得到那個欄位，
所以「遠端登入一下」這種需求，通常直接盲打就解決了。

也可以從電腦端直接送：

```bash
adb -s <ip>:5555 shell input text 'mypassword'
adb -s <ip>:5555 shell input keyevent 66        # Enter
```

> `input text` 不吃空白（要用 `%s`）也不吃中文，只適合純 ASCII。

解鎖畫面同理：

```bash
adb -s <ip>:5555 shell input keyevent 224       # 喚醒
adb -s <ip>:5555 shell input swipe 500 1500 500 300   # 上滑
adb -s <ip>:5555 shell input text '123456'
adb -s <ip>:5555 shell input keyevent 66
```

**2. 如果是你自己的 App（開發測試情境）**

FLAG_SECURE 通常是在 `Activity.onCreate()` 裡加的：

```kotlin
window.setFlags(
    WindowManager.LayoutParams.FLAG_SECURE,
    WindowManager.LayoutParams.FLAG_SECURE
)
```

把它包在 build type 判斷裡，debug build 就不會擋投影：

```kotlin
if (!BuildConfig.DEBUG) {
    window.setFlags(
        WindowManager.LayoutParams.FLAG_SECURE,
        WindowManager.LayoutParams.FLAG_SECURE
    )
}
```

這是遠端測試最乾淨的解法 —— release 版該擋的照擋，debug 版看得到畫面。

**3. 有 root 的機器**

LSPosed / Xposed 有現成模組可以 hook 掉 `setFlags`，全系統停用 FLAG_SECURE。
需要解鎖 bootloader，正式機不建議。

### 不會有用的做法

| 試過的做法 | 為什麼沒用 |
|---|---|
| 升級 scrcpy / 換版本 | 擷取是系統擋的，跟 scrcpy 無關 |
| `--video-codec` / 調 bitrate / 調解析度 | 送過來的畫面本來就是黑的 |
| scrcpy 3.x 的 `--new-display` 虛擬顯示器 | shell 權限開不出「secure display」，FLAG_SECURE 視窗一樣會被塗黑 |
| 改 Tailscale / adb 設定 | 跟傳輸層完全無關 |

---

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
| 密碼頁 / 銀行 App / 鎖定畫面全黑 | App 加了 `FLAG_SECURE`，系統層擋掉擷取，見上面「[密碼頁面投影全黑](#密碼頁面投影全黑flag_secure)」 |
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

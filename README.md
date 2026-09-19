# Hangar

透過 **Tailscale** 遠端連到 Android 手機，用 **scrcpy** 投影畫面。
手機在 4G/5G、在別的網段、在公司 NAT 後面都能投，不需要 VPN 以外的任何設定。

支援多支手機（每支一份 profile）。

> 目前是一支單機 CLI。長期目標是做成**網頁形式的手機裝置管理平台**，
> 連線方式也不會只綁 Tailscale——路線圖見 [ROADMAP.md](ROADMAP.md)。

```
hangar setup --name work    # 初始化一支手機（要同區網或插 USB）
hangar                      # 之後隨時投影
hangar -p test              # 投影另一支
hangar all                  # 全部一起開
hangar scan                 # 這個區網上有哪些裝置（不限已設定的）
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
hangar scan --json
```

```
  IP                MAC                 adb      已設定       廠商
  ────────────────────────────────────────────────────────────
  192.168.1.1       3c:37:86:aa:bb:cc   closed   -            Netgear
  192.168.1.77      a4:03:e7:01:02:03   open     work         宏達電子
  192.168.1.90      de:ad:be:ef:00:01   closed   -            隨機 MAC

  共 3 台，其中 1 台的 5555 是開著的（可以 adb 進去）
```

它怎麼做到的：先對整個 /24 各送一個 ping 把核心的 ARP 表填起來，再讀 `arp -an`
（沒有 `arp` 就用 `ip neigh`），最後對每個找到的 IP 測一次 5555。ARP 表裡的廣播
與多播位址（`ff:ff:…`、mDNS 的 `01:00:5e:…`）會濾掉 —— 那些背後沒有一台機器。
`已設定` 那欄會把 IP 對得上的 profile 名稱標出來，方便對照哪幾台已經入伍了。

需要知道的限制：

- **拿不到機型，也拿不到電量。** 沒開偵錯的手機 adb 完全碰不到，網路層只給得出
  IP 與 MAC。這一欄要補齊得等手機端的 agent app（見 [ROADMAP](ROADMAP.md)）。
- **隨機 MAC 查不到廠商，也不能當識別碼。** Android 10+ / iOS 14+ 對每個 SSID
  用一組隨機 MAC，`廠商` 會直接寫「隨機 MAC」而不是亂猜一個牌子。
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

### 機器可讀的輸出（--json）

`list` 和 `status` 都支援 `--json`，給程式讀用的：

```bash
hangar status --json
hangar list --json              # 只出便宜的欄位（快）
hangar list --json --probe      # 連線路徑、機型、電量一起取（慢）
```

```json
{
  "schema": 1,
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
      "android": { "release": "14", "sdk": 34 },
      "battery": { "level": 78, "status": "discharging", "temperature_c": 27.5 },
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

- **慢欄位預設略過。** `path` 要跑一次 `tailscale ping`，`model` / `battery` 各要一次
  adb 往返。十支手機全取會跑很久，所以 `list --json` 預設把它們留成 `null`，
  要完整資料才加 `--probe`。`status --json` 只有一支，一律完整探測。

- **`--json` 時 stdout 只有 JSON。** 所有給人看的訊息都轉到 stderr，
  所以 `hangar list --json 2>/dev/null | jq .` 一定解析得過。

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
  "schema": 1,
  "subnet": "192.168.1.0/24",
  "hosts": [
    {
      "ip": "192.168.1.77",
      "mac": "a4:03:e7:01:02:03",
      "vendor": "宏達電子",
      "mac_randomized": false,
      "adb_port": "open",
      "profile": "work"
    }
  ],
  "errors": []
}
```

`adb_port` 是 `open` / `closed` / `unknown`（`--no-probe` 或這台機器沒有 `nc`）。
`profile` 對不上任何已設定的手機時是 `null`。`subnet` 是實際掃過的範圍。
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
PHONE_HOST="pixel-7"        # Tailscale 節點名
PHONE_IP="100.x.y.z"        # Tailscale IP
TRANSPORT="tailscale"       # 連線方式（tailscale / lan）
DEVICE_SERIAL="1A2B3C4D"    # 硬體序號，跨 IP / 跨連線方式都不變
```

後兩行是可選的。舊版只有兩行的 profile 照樣能用，讀不到時
`TRANSPORT` 當作 `tailscale`、`DEVICE_SERIAL` 當作空的，不需要做任何轉換。

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

profile 只有兩行、沒有任何祕密，直接抄過去也行：

```bash
scp ~/.config/hangar/profiles/pixel-4.conf 另一台:~/.config/hangar/profiles/
```

一樣要在手機上授權那台電腦。

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

### 幾件事先講清楚

| | |
|---|---|
| 可以同時投嗎 | 可以。adbd 支援多個連線，兩台電腦各開各的 scrcpy 視窗互不干擾 |
| 手機重開機後怎麼辦 | 只要**任一台**接得到 USB／同區網的電腦重跑 `hangar setup`，其他電腦就自動恢復（授權還在，不用再按一次） |
| 第二台電腦能自己救嗎 | 不行。`adb tcpip` 需要一條既有的 USB 或同區網連線，遠端做不到 |
| profile 名稱要一致嗎 | 不用。每台電腦各自取名，`--name` 想叫什麼都行 |

---

## 同區網直連（不經 Tailscale）

手機跟電腦本來就在同一個區網、不需要跨網路時，可以不走 Tailscale ——
profile 裡把 `TRANSPORT` 寫成 `lan` 就好。這種 profile 不需要 `tailscale` CLI，
改用 `nc` 測 5555 埠通不通（macOS 內建）。

**`hangar setup` 目前只會產生 `tailscale` 的 profile**（區網掃描還沒實作），
所以 lan 的要自己寫一份：

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
| 位址會不會變 | Tailscale IP 基本上不變 | DHCP 換位址就要改 `PHONE_IP`，建議在路由器上綁固定 IP |
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

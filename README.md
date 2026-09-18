# Hangar

透過 **Tailscale** 遠端連到 Android 手機，用 **scrcpy** 投影畫面。
手機在 4G/5G、在別的網段、在公司 NAT 後面都能投，不需要 VPN 以外的任何設定。

支援多支手機（每支一份 profile）。

> 目前是一支單機 CLI。長期目標是做成**網頁形式的手機裝置管理平台**，
> 連線方式也不會只綁 Tailscale——見 [專案方向](#專案方向)。

```
hangar setup --name work    # 初始化一支手機（要同區網或插 USB）
hangar                      # 之後隨時投影
hangar -p test              # 投影另一支
hangar all                  # 全部一起開
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

### 2. 安裝 Hangar

```bash
./install.sh
```

會把 `hangar` symlink 到 `/usr/local/bin`（需要時自動 sudo）。
想裝到別的地方：

```bash
PREFIX=~/.local ./install.sh
```

移除：

```bash
./install.sh --uninstall
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
hangar status           # Tailscale 路徑、adb 狀態、機型、Android 版本
hangar status -p work
hangar list             # 所有手機 + 即時狀態
hangar use work         # 設定預設手機
hangar reset            # 連線卡死時重建 adb 連線
hangar forget work      # 刪掉該手機的設定
hangar all              # 同時投影所有手機
hangar all --screen-on  # 同上，但不關手機螢幕
```

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

每個 `.conf` 只有兩行：

```sh
PHONE_HOST="pixel-7"        # Tailscale 節點名
PHONE_IP="100.x.y.z"        # Tailscale IP
```

### 典型流程

```bash
# 兩支手機各插一次 USB（或各自在同區網配對一次）
hangar setup --name work
hangar setup --name test

hangar list
#   * work    100.101.102.103   online   device       pixel-7
#     test    100.101.102.110   online   未連線        zenfone

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
git clone <這個 repo> && cd hangar && ./install.sh

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

## 專案方向

專案原本叫 `pmirror`（phone mirror），名字把自己限縮成「投影工具」了。改名為
**Hangar**（機庫＝一整隊裝置停放、維護、調度的地方）就是因為要往下面這個方向走。

### 現在

- 一支 bash script，跑在你自己的電腦上
- **唯一**的連線方式是 Tailscale + `adb over TCP`
- 唯一的功能是 scrcpy 投影
- 「裝置」＝ `~/.config/hangar/profiles/` 底下的一個 `.conf` 檔

### 要往哪走

| 面向 | 現在 | 目標 |
|---|---|---|
| 介面 | 終端機指令 | **網頁 console**——一個地方看到所有裝置、直接操作 |
| 連線 | 寫死 Tailscale | 可抽換：同區網直連、自架 WireGuard、reverse tunnel、中繼伺服器…… |
| 定位 | 投影工具 | **裝置管理**：狀態、批次操作、投影只是其中一項能力 |
| 裝置狀態 | 印給人看的表格 | 結構化、可被程式讀取 |

### 這對現在的程式碼意味著什麼

在 web 版出現以前，`hangar` 這支 script 還是主要的東西，但新功能盡量守著兩件事：

1. **不要把 Tailscale 的假設散出去。** 取 IP、判斷 direct/relay 這些邏輯集中在一處，
   之後多一種連線方式時是「加一個 backend」，不是整份 script 重寫。
2. **裝置狀態要能被程式讀，不只給人看。** 現在 `hangar list` / `status` 只輸出對齊好的
   表格；之後 web 後端會需要同一份資料的結構化版本（例如 `--json`）。

### 還沒決定

後端用什麼寫、web 版出來之後 CLI 是保留還是收掉、要不要支援多使用者與權限——
這些都還開放。

---

## 專案結構

```
hangar/
├── hangar               # 主 script（bash，無外部相依）
├── README.md
├── install.sh           # symlink 到 /usr/local/bin
└── tests/
    ├── run.sh           # 跑全部測試
    ├── test_core.sh     # 核心流程與錯誤分支
    ├── test_multi.sh    # 多台手機
    ├── test_adb_race.sh # adb server 競態、欄位對齊
    ├── test_multihost.sh # 第二台電腦（--existing）
    └── mockbin/         # 假的 adb / tailscale / scrcpy
```

設定檔在 `~/.config/hangar/`（`XDG_CONFIG_HOME` 有設就跟著走）。

## 測試

```bash
./tests/run.sh
```

用 mock 的 `adb` / `tailscale` / `scrcpy` 跑，**不會碰到真的手機**，
設定檔也是寫在 `$TMPDIR/hangar-test` 底下，不會動到 `~/.config/hangar`。

涵蓋範圍：

| Suite | 內容 |
|---|---|
| `test_core.sh` | direct/relay 參數、`--hq`/`--lq` 覆寫、手機重開機提示、`unauthorized`、`offline` 自動重試、Tailscale 未連線、手機不在 tailnet、`status` 區分 direct/relay、`reset`、重複執行不殘留 scrcpy |
| `test_multi.sh` | `list` / `use` / `forget`、`-p` 指定與前綴比對、名稱打錯、多台沒設預設、一台離線不影響另一台、`reset` 只作用在指定那台、`all` 同時開多台與部分失敗、視窗標題、setup 覆蓋提醒 |
| `test_adb_race.sh` | adb server 重啟競態的自動重試、本機 adb 問題與手機重開機的區分、setup 的 `start-server`、中文欄位對齊 |
| `test_multihost.sh` | `setup --existing`（第二台電腦）、unauthorized 的說明、連不上時的提示方向、`--name` 別名 |

測試裡所有的 `pgrep` / `pkill` 都限定在 mock 使用的 `100.101.102.x`，
不會誤傷你真正在跑的 scrcpy。

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

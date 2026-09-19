# Hangar 專案方向

> 這份是給改程式的人看的：專案要往哪走、程式怎麼分層、測試涵蓋什麼。
> 安裝與使用看 [README](README.md)。

專案原本叫 `pmirror`（phone mirror），名字把自己限縮成「投影工具」了。改名為
**Hangar**（機庫＝一整隊裝置停放、維護、調度的地方）就是因為要往下面這個方向走。

## 目標的樣子

- 管理**所有**測試手機，不管它有沒有開啟偵錯模式
- 只要在同一個區網底下，就要在網頁上看得到
- 網頁上可以**切換偵錯功能**：RD 需要開著才能 build app 進去，
  QA 需要關著才能測加固／混淆過的正式版
- 顯示電量，低電量時提醒充電
- 不限 Android / iOS，目前以 Android 為主

## 關鍵結論：手機端 agent app 是中心，不是加分項

沒開偵錯模式的手機，adb 完全碰不到。這時候只能靠網路層（ARP / mDNS）知道
「有這麼一台裝置」，拿得到 IP、MAC、廠商，拿不到機型、拿不到電量，
**也開不起偵錯** —— 開 `adb_enabled` 需要 `WRITE_SECURE_SETTINGS` 權限，
而要取得這個權限得先有 adb，雞生蛋蛋生雞。

破口是：這個權限可以用 adb 一次性授予給一個常駐的 app，**而且重開機後仍然有效**。

```bash
adb shell pm grant com.hangar.agent android.permission.WRITE_SECURE_SETTINGS
```

每支測試機「入伍」時插一次 USB 裝上 agent，之後它就能常駐回報電量、
在區網廣播自己、並**雙向**切換偵錯開關。四個需求一次解決：

| | 沒有 agent | 有 agent |
|---|---|---|
| 沒開偵錯時看得到什麼 | 只有 IP / MAC / 廠商 | 完整裝置資訊 |
| 電量 | 拿不到 | 常駐回報 |
| 網頁切偵錯 | 只能關，開不回來 | 雙向 |
| 重開機後 5555 消失 | 要人去插 USB | agent 自己把無線偵錯打開（Android 11+，**不是** 5555 —— 見下面的 M3 協定） |

## 已經確定的事

| 項目 | 決定 |
|---|---|
| 手機端 agent | 要裝（一次性 adb 授權，不走 Device Owner） |
| hub 後端 | Python 3 標準函式庫，零外部相依（跟 hangar 是無相依 bash script 同一個理由） |
| hub 部署形態 | 一台常駐機器，接在測試機的同一個區網 |
| 加固 app 實際擋什麼 | 還不知道，要先實測（實測 protocol 另存於專案外部） |

## 里程碑

| | 內容 | 狀態 |
|---|---|---|
| M1 | CLI 結構化：`--json`、transport 抽象層、裝置序號、電量 | **已完成** |
| M2a | 區網掃描：`hangar scan`、`scan_*` 層、lan backend 的候選清單、MAC／序號識別合併、`--fix-ip` | **已完成** |
| M2b | hub 骨架：常駐服務 + 唯讀裝置牆網頁 | **已完成**（Python 3 標準函式庫） |
| M3a | agent 骨架：enroll（裝 APK、授權、寫序號與 token）、`/hello` 與 `/status`、`hangar` 這側接上 | |
| M3b | mDNS 廣播 + `hangar scan` 找得到 agent（找不到就退回探 5599） | |
| M3c | 重開機後自己打開無線偵錯（**不是** 5555，Android 11+ 才有） | 待實測那幾條先確認 |
| M4 | 網頁切換偵錯（RD 開 / QA 關） | 需要 M3 + 加固實測結果 |
| M5 | 網頁投影串流；iOS 唯讀 | |

## 幾個要記住的現實限制

- **MAC randomization**：Android 10+ / iOS 14+ 對每個 SSID 使用隨機但穩定的 MAC。
  同一個 SSID 下可以拿它當識別碼，但使用者「忘記網路再重連」就會換一個。
  所以裝置識別不能只靠 MAC，要能跟 `DEVICE_SERIAL` 合併。
- **adb 授權是綁在「每台電腦的金鑰」上的，而且 agent app 解不掉**：手機信任哪些
  電腦，存在 `/data/misc/adb/adb_keys`，那是 root／system 的檔案。agent app 拿到的
  `WRITE_SECURE_SETTINGS` 只能寫 `Settings.Secure` / `Settings.Global`，碰不到它；
  而那個「允許 USB 偵錯」對話框是 SystemUI 的，一般 app 點不到（Android 特地對這個
  對話框做過防疊加／防自動點擊的保護，那本來就是要擋自動化的安全設計）。
  Android 11+ 的無線偵錯配對碼一樣要人在裝置上操作。
  **結論：只要那台電腦用自己的金鑰直連手機，第一次就一定要有人在手機上按允許。**
  這件事 agent app 幫不上忙 —— 下面「hub 當 adb server」那條路才是繞開它的方式。
- **iOS 做不到對等**：Developer Mode（iOS 16+）必須人在裝置上開啟並重開機，
  無法遠端切換；電量與裝置資訊要靠 `libimobiledevice`，而且得先在 hub 上 USB 配對過。
  iOS 這條線現實的目標是「看得到、知道電量」，不是「管得動」。

## 這對現在的程式碼意味著什麼

在 web 版出現以前，`hangar` 這支 script 還是主要的東西。M1 與 M2a 已經把地基打好：

1. **Tailscale 的假設收在一層後面了。** 所有「怎麼連到這支手機」的知識都在
   `transport_*` 介面後面，`cmd_*` 層不直接呼叫 `ts_*`。多一種連線方式是加一個
   backend（目前除了 `tailscale` 還有一個很薄的 `lan`），不是整份 script 重寫。
2. **裝置狀態已經可以被程式讀。** `--json` 是之後 hub 讀 hangar 的介面，
   schema 有變動就把 `schema` 號碼往上加。
3. **「看得到但管不動」的裝置已經列得出來了。** `scan_*` 這一層跟 profile 無關，
   `hangar scan --json` 回答的是網段而不是某一支手機，所以它有自己的 schema 號碼。
   hub 的裝置牆就是 `list --json` 加 `scan --json` 兩份資料合出來的。
4. **兩份資料合得起來了。** 掃描碰不到 adb，拿不到 `DEVICE_SERIAL`，所以它改用
   MAC 認人：第一次靠 IP 對上時把 MAC 記進 profile 的 `PHONE_MAC`，之後手機換
   IP 也認得出來，而舊 IP 被別台機器拿走時不會誤認。對上 profile 的主機會把
   `device_serial` 附在 `scan --json` 裡 —— 那就是 hub 合併兩份資料的主鍵。
   這也是上面「MAC randomization」那條限制實際落地的地方。認出來之後 profile
   指著舊 IP 的，`hangar scan --fix-ip` 會就地改好 —— 但掃描預設仍然是唯讀的，
   要寫設定檔得明講。

## M3 協定：agent 跟另外兩邊怎麼講話

寫程式之前先把這份定下來，因為 M3／M4 的每一次變動都會**同時**碰到三個元件
（agent 廣播什麼、`hangar` 怎麼問、hub 怎麼顯示）。下面每一條都標了是「已經
確定」還是「待實測」—— Android 這一側有幾個限制會直接改變協定的長相，猜錯的話
是整段重寫。

### 先講三個把設計逼成這樣的限制

| 限制 | 後果 |
|---|---|
| **Android 10+ 的一般 app 拿不到硬體序號**（`Build.getSerial()` 要 `READ_PRIVILEGED_PHONE_STATE`） | 序號不能由 agent 自己去問系統，要在 **enroll 時從 adb 那一側寫進去** |
| **Android 6+ 的一般 app 拿不到自己的 Wi-Fi MAC**（回傳 `02:00:00:00:00:00`） | MAC 仍然只能由 `hangar scan` 從 ARP 表學（就是現在 `PHONE_MAC` 那套），agent 不回報 MAC |
| **`service.adb.tcp.port` 這個系統屬性只有 shell／root 設得動** | agent **開不回 5555**。它能做的是 Android 11+ 的無線偵錯（`Settings.Global.adb_wifi_enabled`），而那個埠是隨機的 |

第三條很重要，因為它推翻了這份 ROADMAP 原本的假設。原本寫的是「重開機後 agent
自己重開 5555」—— 那做不到。做得到的是「重開機後自己把無線偵錯打開」，而且埠是
隨機的、要另外找。上面的表格與里程碑都已經照這個改過，下面的設計也照後者寫。

### 誰問誰：一律由電腦端拉，agent 不主動推

```
hub ──讀 --json──> hangar ──HTTP──> agent（手機上）
```

agent 不需要知道 hub 在哪，也就不需要任何手機端設定。代價是 hub 與手機要能互通
（跨網段就不行）—— 真的需要跨網段再加 push，現在不做。

**hub 不直接跟 agent 講話。** M2b 立的規矩要維持：hub 對手機的所有知識都來自
`hangar --json`，所以「怎麼問 agent」這件事歸 `hangar`，hub 只是多讀幾個欄位。

### agent 的介面

固定埠 **5599/tcp**，純 HTTP（不是 HTTPS，理由見下面的安全那段），路徑帶大版本：

| | | |
|---|---|---|
| `GET /hangar/v1/hello` | 不需要 token | 只回「我是 hangar agent、schema 幾號、版本幾號」。給掃描用的 |
| `GET /hangar/v1/status` | 要 token | 裝置資訊、電量、偵錯開關現在的狀態 |
| `POST /hangar/v1/adb` | 要 token | 切偵錯（M4 才實作） |

`status` 的形狀刻意跟 `hangar --json` 對齊，hub 合併時才不用翻譯：

```json
{
  "schema": 1,
  "agent":  { "version": "0.1.0", "uptime_s": 86400 },
  "device_serial": "R58M12345AB",
  "model": "Pixel 7 Pro",
  "android": { "release": "14", "sdk": 34 },
  "battery": { "level": 78, "status": "discharging", "temperature_c": 27.5 },
  "adb": { "enabled": true, "wifi_enabled": true, "wifi_port": 37219 },
  "can": { "toggle_adb": true, "toggle_wifi_adb": true }
}
```

- `device_serial` 是 enroll 時寫進去的那個，跟 `hangar` 從 `ro.serialno` 拿到的
  **一定是同一個字串** —— 這是 hub 把 agent、`list`、`scan` 三份資料合成一張卡的主鍵。
- `adb.wifi_port` 是無線偵錯當下的埠（隨機，重開機會變）。agent 讀得到就填，
  讀不到填 `null`，讓電腦端退回用 mDNS 找。
- `can` 是**能力宣告**：Android 10 的機器 `toggle_wifi_adb` 就是 `false`。介面一致、
  能力不一致，比「同一個端點在不同機器上有不同行為」好除錯。
- 沒有 `mac`、沒有 `authorized_hosts` —— 前者拿不到，後者是 `/data/misc/adb/adb_keys`，
  一般 app 讀不到（見上面「幾個要記住的現實限制」）。

### 入伍（enroll）：那唯一一次 USB

```bash
hangar setup --enroll [--apk agent.apk]
```

1. `adb install -r <APK>`
2. `adb shell pm grant com.hangar.agent android.permission.WRITE_SECURE_SETTINGS`
3. `DEVICE_SERIAL=$(adb shell getprop ro.serialno)` —— 這一步 `hangar setup` 現在就在做
4. 電腦端產生一組隨機 token（32 bytes hex）
5. 把序號與 token 交給 agent：
   ```bash
   adb shell am broadcast -n com.hangar.agent/.EnrollReceiver \
     -a com.hangar.agent.ENROLL --es serial "$DEVICE_SERIAL" --es token "$TOKEN"
   ```
   指定 component（`-n`）是因為 Android 8+ 擋隱式廣播。
6. 把 `AGENT_TOKEN` / `AGENT_PORT` 寫進 profile
7. 驗證：打一次 `GET /hangar/v1/status`，拿得到東西才算成功

**agent 自己不產生 token。** 產生的一方是電腦端，因為那時候 adb 通道已經是信任的；
讓 agent 產生再由電腦來讀，多一個「誰先信任誰」的問題。

### 找得到 agent：mDNS 是加速器，不是必要條件

廣播 `_hangar-agent._tcp`，instance 名稱 `hangar-<序號後六碼>`，TXT：

```
v=1  serial=R58M12345AB  model=Pixel+7+Pro
```

**TXT 裡不放 token** —— mDNS 是整個區網都聽得到的明文廣播。

但 mDNS 不能當唯一的路：AP 的 client isolation 會擋掉多播，各家 ROM 的
`NsdManager` 穩定度也不一。所以 `hangar scan` 的規矩是：

1. 有 `dns-sd`（macOS 內建）或 `avahi-browse`（Linux）就先問 mDNS —— 快，而且直接
   給得出序號
2. 沒有、或問不到，就退回現在這條路：ARP 表列出主機，然後對每台**多探一個 5599**

第 2 條讓 mDNS 完全失效時功能只是變慢，不是不能用 —— 跟 OUI 資料庫查不到就寫 `?`
是同一個態度：**少一個系統工具只該少一點資訊，不該整個功能不見**。

### 安全：跟現在比是變好，但不是變安全

| | 今天（`adb tcpip 5555`） | 有 agent 之後 |
|---|---|---|
| 誰連得到 | 同區網任何人，完整裝置控制權 | agent 端點要 token；5555 仍然是全開的（沒變） |
| 傳輸 | 明文 | 明文 HTTP，token 會被同網段的人嗅到 |

所以 agent **沒有讓區網變安全**，只是沒有再多開一個無認證的控制面。真正的解法是
TLS 或只在 tailnet 上開放，那是之後要決定的事，先寫在「還沒決定」裡。

M4 要關偵錯時還有一個更實際的風險：**偵錯關掉之後，agent 的 HTTP 端點是唯一
回得去的路**。agent 掛了就要人拿著手機處理。所以切偵錯的介面要帶一個自動復原：

```json
POST /hangar/v1/adb   { "enabled": false, "revert_after_s": 1800 }
```

時間到就自己開回來。QA 測加固版是有限時間的事，這個代價划算。

### 版本規矩

- 路徑帶大版本（`/hangar/v1/`），不相容才動它
- body 的 `schema` 是小版本：加欄位可以，改意思要往上加
- **兩邊都必須忽略不認得的欄位** —— agent 跟 hub 的更新節奏本來就不會一致
- `hangar` 的 `list --json` / `scan --json` 各自有自己的 schema 號碼，跟這份無關

### agent 不做的事

| | 為什麼 |
|---|---|
| 不碰 adb 授權金鑰 | `/data/misc/adb/adb_keys` 是 root／system 的（見上面的限制） |
| 不代理 adb 流量 | build 還是電腦直連手機，agent 不在那條路上 |
| 不在 Android 10 以下重開 TCP adb | 做不到，那種機器重開機後還是要人插 USB |
| 不自己決定偵錯開或關 | 狀態由電腦端指派，agent 只執行與回報 |

### 這份協定會改到現有的什麼

| 元件 | 要動的地方 |
|---|---|
| `hangar` | `setup --enroll`；profile 多 `AGENT_TOKEN` / `AGENT_PORT`；`scan` 多探 5599 與 mDNS；`list --probe` 在 adb 不通時改問 agent 拿電量 |
| hub | 只是多讀幾個欄位（`agent`、`adb.wifi_port`），M2b 的「hub 不自己碰手機」維持不變 |
| README | 「profile 沒有任何祕密，直接抄過去也行」**不再成立** —— 有 token 之後那句要改掉 |

### 待實測（寫程式前先確認，猜錯要重來）

| | |
|---|---|
| `WRITE_SECURE_SETTINGS` 能不能寫 `Settings.Global.adb_wifi_enabled` | 這是 M3c 的全部基礎 |
| 打開無線偵錯之後，**之前配對過的電腦**能不能免配對重連 | 不能的話「重開機自動恢復」就破功，要人讀配對碼 |
| 把 `adb_enabled` 關掉時，無線偵錯會不會一起死 | 幾乎一定會，但要確認 M4 關掉之後 agent 端點還活著 |
| `NsdManager` 在你手上那幾支機器 + AP 上的實際表現 | 決定 mDNS 是主要路徑還是純加速器 |
| 前景服務在各家 ROM 的省電策略下活多久 | agent 被殺掉 = 那支手機失聯，這是整套的單點故障 |

## 待實測：讓 hub 當唯一被授權的那台電腦

上面那條限制的實際痛點是**加人**：每多一個 RD，就要有人拿著手機按一次「一律允許」，
而且那台電腦從此握有一把等同完整裝置控制權的金鑰。

繞開的方式是不要讓 RD 的電腦直連手機，改成連 hub 的 adb server —— adb 的 client
與 server 本來就可以分在兩台機器上：

```bash
# hub 上（綁在 tailnet 位址，不要開在所有介面）
adb -L tcp:100.x.y.z:5037 nodaemon server
```
```bash
# RD 的電腦上
export ADB_SERVER_SOCKET=tcp:100.x.y.z:5037
adb devices            # 看到的是 hub 上那幾支手機
./gradlew installDebug # APK 傳到 hub，再由 hub 裝進手機
```

這樣手機從頭到尾只看過 hub 那一把金鑰：新人加入不用碰手機，離職也不必擔心他的
筆電上還留著一把。agent app 在這條路上的角色也更清楚了 —— 它要保住的是
**hub 這唯一一條已授權的連線**（重開機後把 5555 開回來）。

要先確認的事：

| | |
|---|---|
| `ADB_SERVER_SOCKET` 對 adb CLI 與 Gradle | 文件行為，但沒實測過 |
| Android Studio 認不認 | **不確定**。它管自己的 adb server，可能要另外設定，或乾脆讓開發者用 CLI build |
| 安全 | `adb server` 的 5037 **沒有任何認證**，連得到就等於掌握所有手機。一定要綁 tailnet 位址 + ACL，絕不能開在辦公室區網上 |
| 多人同時操作 | 全部擠在 hub 的同一個 adb server 上，負載與互相干擾都還沒試過 |

實測結果出來之前，README 寫的仍然是「各台電腦直連手機」那條路。

### 最小驗證步驟

要三樣東西：hub（已經被這支手機授權過）、一支手機、**一台從來沒被這支手機授權過的
電腦**（以下叫 RD 機）。手邊只有已授權過的電腦的話，把金鑰換掉就等於一台新的：

```bash
# RD 機上：把現有金鑰移開，adb 下次啟動會自己產生一把新的（測完記得換回來）
mv ~/.android/adbkey     ~/.android/adbkey.bak
mv ~/.android/adbkey.pub ~/.android/adbkey.pub.bak
adb kill-server
```

**1. hub：確認基準狀態**

```bash
hangar status -p <手機>          # adb 要是 device，不是 unauthorized
adb kill-server
adb -L tcp:<hub 的 tailnet IP>:5037 nodaemon server &
```

**2. hub：確認真的只綁在 tailnet 位址上**

```bash
lsof -nP -iTCP:5037 -sTCP:LISTEN      # Linux 用 ss -ltn | grep 5037
```

> 期望：只看到 `100.x.y.z:5037`。出現 `*:5037` 或 `0.0.0.0:5037` 就是開在所有
> 介面上 —— 那等於把所有手機的完整控制權放到區網上，必須先修掉再繼續。

**3. RD 機：連過去，手機不該有任何反應**

```bash
export ADB_SERVER_SOCKET=tcp:<hub 的 tailnet IP>:5037
adb devices
```

> 期望：列出手機而且狀態是 `device`。**同時盯著手機螢幕：不可以跳出「允許 USB
> 偵錯」**。有跳出來就表示這條路沒有繞開授權，後面不用測了。

**4. RD 機：真的裝一個 APK 上去**

```bash
export ANDROID_SERIAL=<手機 IP>:5555
./gradlew installDebug        # 或 adb install app-debug.apk
```

> 期望：裝得進去。APK 是先傳到 hub、再由 hub 送進手機的，所以 RD 機跟手機之間
> 不需要任何直接連線。

**5. 反證：確認手機「仍然不信任」RD 機的金鑰**

這步是整件事的重點——要證明第 3 步的成功不是因為 RD 機被偷偷授權了。

```bash
unset ADB_SERVER_SOCKET
adb kill-server
adb connect <手機 IP>:5555
adb devices
```

> 期望：`unauthorized`（或連不上）。**手機這時候會跳出「允許 USB 偵錯」，不要按
> 允許**，按取消。然後 `adb disconnect <手機 IP>:5555 && adb kill-server` 收拾掉。
>
> 拿得到 `adb shell` 的話可以再對一次帳：`adb shell cat /data/misc/adb/adb_keys | wc -l`
> 在第 1 步與這一步的數字要一樣。讀不到（permission denied）是正常的，那就以上面
> 的行為判斷為準。

**6. Android Studio 認不認**（目前最不確定的一項）

macOS 從終端機啟動才吃得到環境變數，用 Finder 點開的不算：

```bash
export ADB_SERVER_SOCKET=tcp:<hub 的 tailnet IP>:5037
/Applications/Android\ Studio.app/Contents/MacOS/studio
```

> 期望：裝置選單裡看得到那支手機。看不到的話記下 Studio 版本 —— 結論可能是
> 「Studio 不支援，開發者用 CLI build」，那也是個可以接受的結論，只是要寫下來。

**7. 真正想買的東西：手機重開機之後**

```bash
# 手機重開機後，RD 機上：
adb devices                      # 期望：手機不見了（5555 沒了，所有人一起斷）

# hub 上：接 USB（或用 Android 11+ 的無線偵錯配對）重跑
hangar setup <手機>

# RD 機上：
adb devices                      # 期望：手機回來了，而且 RD 機什麼都沒做
```

> 這一步證明的是「加人與修復都只發生在 hub 這一台」。注意修復本身仍然要有人
> 碰手機（USB，或在手機上開無線偵錯讀配對碼）—— 那正是 agent app 要消掉的部分，
> 不是這條路線能解決的。

測完把每一步的實際結果補回這一節，然後才決定要不要把它寫進 README。

5. **hub 已經站起來了，而且只站在 `--json` 上面。** `hub/hangar_hub.py` 對手機
   的所有知識都來自 `hangar list --json` 與 `hangar scan --json`，沒有自己去碰
   adb 或網路。要多顯示一個欄位是去改 hangar，不是在 hub 裡另外接一條路 ——
   這樣 CLI 與網頁永遠不會各說各話。

## 還沒決定

web 版出來之後 CLI 是保留還是收掉、要不要支援多使用者與權限、
RD 的電腦要直連手機還是走上面那條「hub 當 adb server」——這些都還開放。

hub 目前是唯讀的。要從網頁動手機（M4 的切偵錯、M5 的投影）就會有寫入端點，
那時要決定的是認證怎麼做 —— 現在連「誰在看這頁」都不知道。

agent 的端點目前定為明文 HTTP + token。要不要上 TLS、還是乾脆只在 tailnet 上
開放，等 M3a 跑起來、知道實際的延遲與麻煩程度再決定。

多人同時裝 APK 進同一支手機會互相蓋掉，目前沒有任何佔用／排隊機制。hub 要不要
管「誰在用哪一支」也還沒決定。

---

## 專案結構

```
hangar/
├── hangar                # 主 script（bash，無外部相依）
├── README.md             # 安裝與使用
├── ROADMAP.md            # 這份：方向、里程碑、程式分層、測試
├── hangar_install.sh     # symlink 到 /usr/local/bin
├── hub/
│   ├── hangar_hub.py     # 常駐服務：輪詢 hangar --json、合併、開 HTTP
│   └── static/
│       └── index.html    # 唯讀裝置牆（純 HTML/CSS/JS，沒有 build 步驟）
└── tests/
    ├── run.sh            # 跑全部測試
    ├── test_core.sh      # 核心流程與錯誤分支
    ├── test_multi.sh     # 多台手機
    ├── test_adb_race.sh  # adb server 競態、欄位對齊
    ├── test_multihost.sh # 第二台電腦（--existing）
    ├── test_json.sh      # --json 輸出、錯誤 code、transport 抽象層、電量
    ├── test_scan.sh      # 區網掃描：網段、MAC、廠商、5555 探測、識別合併、--fix-ip
    ├── test_hub.sh       # hub：合併邏輯、HTTP 端點、唯讀保證
    ├── mockbin/          # 假的 adb / tailscale / scrcpy / nc / arp / ip / ping / route
    └── hubbin/           # 假的 hangar（吐固定的 JSON 給 hub 吃）
```

`hangar` 這支 script 內部分層（由下往上）：

| 層 | 內容 |
|---|---|
| 輸出 | `info` / `ok` / `warn` / `err` / `kv` / 中文欄寬對齊 |
| scan | `scan_*` —— ARP 層級的「這個網段上有哪些裝置」，不分已設定與否；`cmd_scan` 和 lan backend 的候選清單共用它 |
| transport | `transport_*` —— 「怎麼連到這支手機」全部收在這後面，底下有 `ts_*` 和 `lan_*` 兩個 backend |
| profile | `.conf` 的讀寫、預設值、舊格式遷移 |
| adb | 連線重試、狀態判讀、裝置資訊、電量 |
| probe | `probe_transport` / `probe_adb` —— 人類輸出與 `--json` 共用同一份取得邏輯 |
| 指令 | `cmd_setup` / `cmd_mirror` / `cmd_status` / `cmd_list` / `cmd_scan` / … |

`cmd_*` 層不直接呼叫 `ts_*`，一律走 `transport_*`。所有跟連線方式有關的**措辭**
也集中在 `transport_msg` 這一個查表函式裡，加 backend 時不用去各處翻字串。

設定檔在 `~/.config/hangar/`（`XDG_CONFIG_HOME` 有設就跟著走）。

`hub/hangar_hub.py` 的分層很薄，刻意如此 —— 它不該知道任何「怎麼問手機」的事：

| 層 | 內容 |
|---|---|
| 取資料 | `run_hangar()` —— 跑 `hangar <cmd> --json`，只認 stdout 的 JSON |
| 合併 | `merge()` —— 兩份資料合成裝置牆，主鍵 `DEVICE_SERIAL` > MAC > IP |
| 狀態 | `State` —— 兩個輪詢執行緒寫、HTTP 執行緒讀的共用快照 |
| HTTP | `Handler` —— `/`、`/api/devices`、`/healthz`，全部是 GET |

`merge()` 是純函式（輸入兩份 dict，輸出一個 list），所以裝置牆的邏輯不用開
伺服器也測得動。hub 對手機的所有知識都來自 `--json`，要多支援什麼欄位是改
hangar 那邊，不是在 hub 裡另外接一條路。

## 測試

```bash
./tests/run.sh
```

用 mock 的 `adb` / `tailscale` / `scrcpy` / `arp` / `ping` 跑，**不會碰到真的手機，
也不會真的對區網送封包**，設定檔也是寫在 `$TMPDIR/hangar-test` 底下，
不會動到 `~/.config/hangar`。

`test_hub.sh` 會在 `127.0.0.1` 上開幾個隨機埠（`--port 0`）把 hub 真的跑起來，
所以整份測試比以前久一點。它的最後一節刻意接**真正的** `hangar`（配 mockbin）
而不是假的 —— 手寫的 JSON 擋得住 hub 自己的迴歸，擋不住「hangar 改了欄位、hub
沒跟上」。

涵蓋範圍：

| Suite | 內容 |
|---|---|
| `test_core.sh` | direct/relay 參數、`--hq`/`--lq` 覆寫、手機重開機提示、`unauthorized`、`offline` 自動重試、Tailscale 未連線、手機不在 tailnet、`status` 區分 direct/relay、`reset`、重複執行不殘留 scrcpy |
| `test_multi.sh` | `list` / `use` / `forget`、`-p` 指定與前綴比對、名稱打錯、多台沒設預設、一台離線不影響另一台、`reset` 只作用在指定那台、`all` 同時開多台與部分失敗、視窗標題、setup 覆蓋提醒、重跑 setup 不洗掉掃描記住的 MAC |
| `test_adb_race.sh` | adb server 重啟競態的自動重試、本機 adb 問題與手機重開機的區分、setup 的 `start-server`、中文欄位對齊 |
| `test_multihost.sh` | `setup --existing`（第二台電腦）、unauthorized 的說明、連不上時的提示方向、`--name` 別名 |
| `test_json.sh` | `--json` 是合法 JSON 且 stdout 不被污染、schema 欄位、舊 profile 沒有 `TRANSPORT` 時的回退、慢欄位要 `--probe` 才取、電量數值與低電量標記、各種錯誤 code、傳輸層掛掉時不誤報成手機重開機、`lan` backend 可抽換、壞掉的 profile 不影響其他支、setup 記下裝置序號 |
| `test_scan.sh` | `scan --json` 的形狀、排除自己與別的網段、`incomplete` 不算裝置、macOS 省略 0 的 MAC 正規化、隨機 MAC 的判定、5555 探測與 `--no-probe`、已設定的 profile 標記、ping sweep 與 `--no-ping`、缺工具不可誤報成「區網上沒東西」、`/16` 與 `/28` 的網段判斷、`--subnet` 的三種寫法、OUI 兩種格式與沒有資料庫時不亂猜、廠商含中文時的欄位對齊、`lan` backend 的候選清單、識別合併（記住 MAC、換 IP 仍認得出、舊 IP 被別台拿走不誤認、一個 profile 只認領一台、隨機 MAC 換過會重學、序號附在輸出裡）、`--fix-ip` 只改認得出來的那幾支且不碰 tailscale profile |
| `test_hub.sh` | hub 起得來並印出網址、`/` 與 `/healthz` 與 `/api/devices`、兩份資料合成同一張卡（序號當主鍵）、沒設定過的手機也上牆、`no_adb` 與 `offline` 要分開、低電量標記、要注意的排前面、單支手機的錯誤留在卡片上、**輪詢絕不帶 `--fix-ip` 也不跑任何會寫入的指令**、hangar 壞掉時 hub 不跟著死、靜態檔不准往上跳 |

測試裡所有的 `pgrep` / `pkill` 都限定在 mock 使用的 `100.101.102.x`，
不會誤傷你真正在跑的 scrcpy。

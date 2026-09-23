# Hangar 專案方向

> 這份是給改程式的人看的：專案要往哪走、程式怎麼分層、測試涵蓋什麼。
> 安裝與使用看 [README](README.md)。

專案原本叫 `pmirror`（phone mirror），名字把自己限縮成「投影工具」了。改名為
**Hangar**（機庫＝一整隊裝置停放、維護、調度的地方）就是因為要往下面這個方向走。

## 目標的樣子

- **以區網為主。** 電腦與測試機在同一個網段是預設情境；Tailscale 是「要跨網路
  時建議加上」的選項，不是前提。這不只是措辭：掃描走 ARP、agent 靠 mDNS 報名，
  這兩件事本來就只在區網成立，整個裝置牆的前提就是同一個網段
- 管理**所有**測試手機，不管它有沒有開啟偵錯模式
- 只要在同一個區網底下，就要在網頁上看得到
- 網頁上可以**切換偵錯功能**：RD 需要開著才能 build app 進去，
  QA 需要關著才能測加固／混淆過的正式版
- 顯示電量，低電量時提醒充電
- 在一排長得一樣的機器裡，認得出牆上這張卡是**哪一支**（見「[響鈴](#響鈴在一排手機裡認出是哪一支)」）
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

每支測試機「入伍」時透過一次已授權的 ADB（USB 或網路）裝上 agent，之後它就能常駐回報電量、
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
| 連線方式的定位 | **區網是主場**（`TRANSPORT` 預設 `lan`，`hangar setup` 預設建區網 profile），Tailscale 是跨網路時的選項（`setup --transport tailscale`） |
| 手機端 agent | 要裝（一次性 adb 授權，不走 Device Owner） |
| hub 後端 | Python 3 標準函式庫，零外部相依（跟 hangar 是無相依 bash script 同一個理由） |
| hub 部署形態 | 一台常駐機器，接在測試機的同一個區網；兩者在同一台時用 `hangar wall` 一次起完 |
| 加固 app 實際擋什麼 | 還不知道，要先實測（實測 protocol 另存於專案外部） |
| 網頁投影 | **遠期目標**，不排進 M1–M5。投影目前維持走 CLI 的 scrcpy，網頁只負責切偵錯（見里程碑下面那段） |
| 牆上的投影按鈕 | 已經做了，但它**不是**上面那條：按鈕叫的是按按鈕那台電腦上的 `helper/`，helper 跑的就是 CLI 的 `hangar -p`。畫面仍然開在本機的 scrcpy 視窗裡，不是在瀏覽器裡 |
| 牆上的響鈴按鈕 | 已完成，跟投影同一條路：走 helper，不走 hub。**hub 維持唯讀**；M4 也沿用這個動作邊界 |
| hub 內嵌 helper（`hangar wall`） | 整合的是 **process，不是 listener**：helper 照樣自己綁 127.0.0.1、照樣走 Origin ＋ token 那三道鎖，hub 這一邊仍然一個會動到手機的端點都沒有。多出來的只有 `GET /api/helper`，而它**只回答 loopback** —— 同事從區網開同一頁拿不到鑰匙，他那台還是得自己跑一支 helper |

## 里程碑

| | 內容 | 狀態 |
|---|---|---|
| M1 | CLI 結構化：`--json`、transport 抽象層、裝置序號、電量 | **已完成** |
| M2a | 區網掃描：`hangar scan`、`scan_*` 層、lan backend 的候選清單、MAC／序號識別合併、`--fix-ip` | **已完成** |
| M2b | hub 骨架：常駐服務 + 唯讀裝置牆網頁 | **已完成**（Python 3 標準函式庫） |
| M2c | 裝置牆的第三個資料來源：`hangar usb --json`，讓插在 hub 那台上的手機（含 `unauthorized`）看得見 | **已完成**（見「[USB 也是一個來源](#usb-也是一個來源m2c插著的手機在牆上是隱形的)」）|
| M3a | agent 骨架：enroll、`/hello` 與 `/status`、`hangar` 這側接上、hub 顯示 | **已完成，而且在 Pixel 4 / Android 13 上實機驗過** |
| M3b | mDNS 廣播 + `hangar scan` 找得到 agent（找不到就退回探 5599） | **已完成**（電腦端兩條路都有測試；手機端的 `NsdManager` 廣播還沒在實機上看過 —— 見待確認清單 B3）|
| M3c | 重開機後自己打開無線偵錯（**不是** 5555，Android 11+ 才有） | 待實測那幾條先確認 |
| M3d | 響鈴：牆上按一下，那支手機響給你聽 —— 用來**識別**，不是用來找失聯的機器。只依賴 M3a，不卡 M3b／M3c | **已完成**（fake agent、CLI、helper、裝置牆與協定測試已接上；實機音量／震動仍待實測） |
| M3e | 反向識別：入伍時把 profile 名字也寫進手機，agent 那頁大字顯示。**協定不動**，最小的一條 | **已完成**（見「[反向識別](#反向識別m3e入伍時多寫一個名字)」） |
| M4 | 網頁切換偵錯（RD 開 / QA 關） | **已完成**（agent、CLI、helper 與裝置牆已接上；**全手動，沒有自動復原**，見下面那節；實機 ROM 行為仍待實測） |
| M5 | iOS 唯讀 | |

### 遠期：網頁投影串流

排在 M5 之後，**不在目前的路線上**。現在的分工是：投影走 CLI 的 `hangar`
（scrcpy），網頁只負責看狀態與切偵錯 —— 偵錯開著就用 CLI 投影，要關就從網頁關。
近期要做的網頁功能到 **M4 的切偵錯**為止。

牆上那顆投影按鈕不算破例：它按下去之後跑的還是 CLI 的 `hangar -p`，只是由
`helper/hangar_helper.py` 在**按按鈕那台電腦**上代跑（網頁啟動不了本機程式，
而 hub 跑起來的視窗開在沒有人看的那台機器上）。真正還沒做的是「畫面出現在
瀏覽器裡」，那才是下面這兩條要先有答案的東西。

會排到遠期不是因為沒價值，是因為它得由 agent 自己走 MediaProjection（不經過
adb），而那條路上有兩個還沒有解的地方。真的要動它之前，這兩條要先有答案：

| # | 要確認什麼 | 沒解的話 |
|---|---|---|
| D1 | MediaProjection 能不能不要每次都要人在手機上按同意（Android 14 起每個 session 都要）；常駐 app 有沒有豁免路徑 | 沒消掉「要人碰手機」，跟現在插 USB 的差別只剩少走幾步 |
| D2 | FLAG_SECURE 的頁面照樣全黑（見 [docs/flag-secure.md](docs/flag-secure.md)），這是系統層排除所有擷取管道，換掉 scrcpy 不會變好 | 加固／金流／密碼頁一樣投不出來，而那常常正是 QA 要看的畫面 |

D1 若是「每次都要人按」，這件事就不是「遠端管得動」，只是「不用開偵錯的投影」
—— 那時要重新判斷值不值得做。

## 現況速查（改東西之前先看這張）

號碼與端點只在這裡列一次。底下各節講的是「當時為什麼這樣決定」，不是現況 ——
對不起來的話以這張表和程式碼為準。

| | 現在是 | 在哪裡 |
|---|---|---|
| `hangar` 版本 | `1.5.0` | `hangar:20` |
| `list` / `status --json` | schema **4** | `JSON_SCHEMA`，`hangar:2586` |
| `scan --json` | schema **7** | `SCAN_SCHEMA`，`hangar:180` |
| `usb --json` | schema **1** | `USB_SCHEMA`，`hangar:181` |
| hub `/api/devices` | schema **8** | `API_SCHEMA`，`hub/hangar_hub.py:63` |
| agent 協定 | schema **3**，版本 `0.1.2` | `agent/app/build.gradle.kts` |
| hub 端點 | `GET /`、`GET /api/devices`、`GET /healthz`、`GET /static/…`、**`GET /api/helper`**（只回答 loopback）、**`POST /api/refresh`** | `Handler` |
| agent 端點 | `GET /hangar/v1/hello`、`GET /hangar/v1/status`、`POST /hangar/v1/ring`、`POST /hangar/v1/adb` | 5599/tcp |
| helper 端點 | `POST /mirror`、`POST /enroll`（可帶 `reinstall`）、`POST /ring`、`POST /adb`（只綁 127.0.0.1） | `API_SCHEMA` **5**，`helper/hangar_helper.py:73` |

`POST /api/refresh` 是 hub 目前唯一的非 GET 端點。它**不會動手機**，只是把輪詢
提早叫醒，跑的還是同樣那兩個唯讀的 `hangar` 指令 —— 「唯讀」在這份文件裡一律
指這個意思，不是指「只有 GET」。

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
  這件事 agent app 幫不上忙 —— 下面兩條「待實測」才是繞開它的方式：讓 RD 的電腦
  不要直連手機（待實測 1），或讓已經被授權的 hub 代按那個對話框（待實測 2）。
- **Android 12+ 不准 app 從背景啟動前景服務**：實機實測踩到的。入伍廣播裡呼叫
  `startForegroundService()` 會丟 `ForegroundServiceStartNotAllowedException`，
  沒接住的話整支 app 當場崩潰（入伍資料已經寫好了，但服務起不來）。被允許的路徑
  是「有人打開這個 app」與 `BOOT_COMPLETED`。所以 `hangar enroll` 在發完廣播之後
  多一步 `am start`：那個流程手上本來就有 adb，不需要任何人碰手機。
- **iOS 做不到對等**：Developer Mode（iOS 16+）必須人在裝置上開啟並重開機，
  無法遠端切換；電量與裝置資訊要靠 `libimobiledevice`，而且得先在 hub 上 USB 配對過。
  iOS 這條線現實的目標是「看得到、知道電量」，不是「管得動」。

## 這對現在的程式碼意味著什麼

在 web 版出現以前，`hangar` 這支 script 還是主要的東西。M1 與 M2a 已經把地基打好：

1. **Tailscale 的假設收在一層後面了。** 所有「怎麼連到這支手機」的知識都在
   `transport_*` 介面後面，`cmd_*` 層不直接呼叫 `ts_*`。多一種連線方式是加一個
   backend（目前除了 `tailscale` 還有一個很薄的 `lan`），不是整份 script 重寫。

   **預設值也已經翻到區網那一邊了**（v1.3.0）：`transport_name`（`hangar:888`）
   沒設就是 `lan`，`cmd_setup` 預設 `TRANSPORT="lan"`，只有 `--transport
   tailscale` 才會去要求 tailscale CLI —— 在那之前，沒裝 tailscale 的人連區網
   的手機都設定不了。

   翻預設值真正的風險不在 `transport_name`，在**舊 profile**：它們沒有
   `TRANSPORT` 那一行，跟著新預設走就等於被靜默改判成區網直連，而它們的
   `PHONE_IP` 是 Tailscale IP，連線診斷會整片指錯方向。所以沒有讓它們吃預設值
   —— `migrate_transport_field`（`hangar:1363`）在每次執行時就地把
   `TRANSPORT="tailscale"` 補進那些檔案，讓檔案自己講清楚；檔案唯讀寫不進去時，
   `load_profile_soft` 還留著一道同樣結論的保險絲。**「沒寫就是 lan」只適用於
   完全沒有 profile 的情境，不適用於沒寫那一行的舊檔。**

   **同一個道理的第二種錯標籤**：有那一行、寫的是 `lan`，但 `PHONE_IP`
   落在 `100.64.0.0/10`。`setup` 只看 `--transport` 旗標、不看位址，所以
   `hangar setup 100.77.7.104`（直接把 Tailscale IP 貼進去）就會生出這種檔案 ——
   adb 連得上（位址是對的），因此沒人發現，但 `status` / 裝置牆顯示的是「區網
   直連」，連不上時每一句提示都在叫人「確認手機連著同一個 Wi-Fi」，而手機其實
   在別的城市。位址是這裡最硬的證據（RFC 6598 明講那一段不該出現在使用者自己
   的區網），所以兩頭都堵：`cmd_setup` 在決定位址之後就地改判（明確給了
   `--lan` 就照做，只警告），`migrate_transport_mislabel`（`hangar:1389`）則把
   已經寫壞的檔案更正過來。後者只在這台電腦找得到 tailscale CLI 時才動手 ——
   真有人的區網開在那一段的話，改成 tailscale 只會讓他原本好好的指令全部死在
   「找不到 tailscale CLI」。

   `setup` 第 3 步（決定要寫哪個位址）是兩種連線方式唯一分岔的地方：tailscale
   去 tailnet 挑節點，lan 則問手機自己 —— `device_lan_ip`（`hangar:1928`）把手機
   所有 IPv4 拿回來，挑落在這台電腦同一個 /24 的那一個。**刻意不用
   `adb shell ip route get`**：手機開著行動網路時那條路回答的是 4G 位址，寫進
   profile 之後每次投影都失敗，而錯誤會指向手機。`--existing` 沒有 adb 可問，
   退回 `transport_list_candidates`（也就是 `hangar scan` 的結果）讓人挑 ——
   「從掃描結果直接建 profile」那條路因此順帶有了，但只在 setup 裡面，
   還沒有獨立的指令。
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

5. **agent 的協定被兩份實作夾住了。** `agent/` 是 Kotlin，`tests/agentbin/fake_agent.py`
   是同一份協定的 Python 參考實作，`tests/test_agent_protocol.sh` 兩邊都打得過去
   （帶 `HANGAR_AGENT_URL` 就打真的手機）。這是刻意的：同一份協定被寫兩次，
   對不起來的地方就是協定沒講清楚的地方。參考實作同時也讓 `hangar` 那一側不用
   有手機就能開發。
6. **helper 也只站在 `--json` 上面。** `helper/hangar_helper.py` 要知道「這台
   電腦上有哪些手機」，走的是 `hangar list --json`，不是自己去讀
   `~/.config/hangar/`。設定檔長什麼樣子是 `hangar` 的事 —— 多一個地方認得那個
   格式，就多一個地方會跟它走岔。它做的事也只有一件：在本機跑 `hangar -p`。

7. **hub 已經站起來了，而且只站在 `--json` 上面。** `hub/hangar_hub.py` 對手機
   的所有知識都來自 `hangar list --json` 與 `hangar scan --json`，沒有自己去碰
   adb 或網路。要多顯示一個欄位是去改 hangar，不是在 hub 裡另外接一條路 ——
   這樣 CLI 與網頁永遠不會各說各話。

## USB 也是一個來源（M2c）：插著的手機在牆上是隱形的

> **已完成**（`hangar` v1.4.0 / `USB_SCHEMA` 1 / hub `API_SCHEMA` 8）。
> 症狀是「新手機掃不到」，但掃描沒有壞 —— 是裝置牆的資料來源少了一個，
> 而少掉的那個正好就是「新手機剛到」的那個。下面留著當時的分析，因為那個
> 認知落差（「開了偵錯」≠「牆上看得見」）本身不會因為多一個來源就消失。

一支剛到的 Samsung A34：USB 插著、偵錯開了、`adb devices` 是 `device`（授權過了），
在裝置牆上找不到。實際查下來，它其實**掃到了**，是那一列匿名的
`192.168.0.155`、`mac 3e:19:e2:35:b1:6b`、`vendor: null`、`adb_port: closed` ——
跟隔壁的智慧插座長得一模一樣。三件事疊起來讓它認不出來：

1. **MAC 隨機化**：`3e:` 是 locally-administered 位，`scan_mac_is_random`
   （`hangar:414`）判定是隨機 MAC 就不查 OUI，所以沒有「Samsung」這個提示。
   這是「現實限制」那節第一條的直接後果，不是 bug。
2. **沒有 profile，所以沒有名字**：`cmd_list` 只走 `list_profiles`。
3. **5555 是關的**：`service.adb.tcp.port` 空的，所以 `adb_port: closed`。

第三條是這一條的重點，也是使用者一定會踩的認知落差：**「開了偵錯而且授權了」
跟「牆上看得見」是兩件不相干的事**。授權的是 USB 那把金鑰，掃描探的是 TCP 5555，
而 5555 要 `adb tcpip 5555` 才會開 —— 那正是 `hangar setup` 做的事。
所以在牆的視角，一支還沒 setup 的手機**無論偵錯開得多正確都是匿名的**，
而使用者手上握著「我明明都開好了」這個強烈的反證，會往錯的方向查很久。

真正的缺口是：裝置牆的資料來源只有兩個 —— `hangar list --json`（已設定的
profile）與 `hangar scan --json`（區網 ARP）。**`adb devices` 不在裡面。**
一支插著 USB、adb 狀態是 `device` 的手機，兩邊都不算，於是完全隱形。

### 要做的：第三個來源

| 元件 | 動到的地方 |
|---|---|
| `hangar` | 新增 `hangar usb --json`：列出**這台電腦上 USB 接著**的裝置，含 `device_serial`、`adb_state`（`device` / `unauthorized` / `offline`）、機型。序號與機型沿用 `usb_serials` 那一組既有函式，不要另外寫一套解析 |
| hub | 第三個 poller（`poller` 與 `REFRESH_MIN` 已經是照 kind 查表的，`hub/hangar_hub.py:382`），`merge()` 多吃一份；`/api/devices` 的 `sources` 多一個 `"usb"`，`API_SCHEMA` → **8** |
| 裝置牆 | 沒有 IP 的卡片要顯示得了（現在每張卡都預設有 IP）；`unmanaged` + USB 的卡片給一個「入伍」動作 |
| 測試 | `test_hub.sh` 的 merge 案例補「只有 USB 這一份」與「USB ＋ scan 同一支」；`tests/mockbin` 那支假 `adb` 要餵得出 `unauthorized` |

合併鍵不用另外想：USB 這一份給得出 `DEVICE_SERIAL`，那本來就是
`merge()`（`hub/hangar_hub.py:131`）優先序最高的識別碼，所以已經是 profile 的
手機會直接併回它原本那張卡（順帶多一個「USB 也接著」的事實），
沒設定過的才會長出新的一張。`scan_match_profiles`（`hangar:650`）那條路完全不動。

**`unauthorized` 是這裡最值錢的一格。** 「有人插了一支手機但沒人去按那個允許」
現在是查不出來的 —— 而 `merge()` 的排序表裡 `unauthorized` 本來就排第一位，
位置早就留好了。這一格也正好是「待實測 2」（hub 代按那個對話框）要盯的狀態，
兩條線看的是同一個東西。

### 做出來之後長這樣

`hangar usb --json` 吐 `{schema, devices[], errors[]}`，每一筆有 `adb_serial`、
`adb_state`、`device_serial`、`model`、`profile`。`unauthorized` 的手機問不到
`ro.serialno`，但 adb 的 USB serial 本來就是硬體序號，拿它當 `device_serial`
仍然對得起 merge —— **而「問不到」正是那一格最該被看見的時候，不能因此讓它
從牆上消失**。

一個併不起來的情況，已知並且刻意留著：一支還沒 setup 的手機**同時**會在掃描
那份裡出現一列匿名的 ARP 紀錄（隨機 MAC、沒有廠商、5555 關著）。那一列沒有
序號也沒有任何跟 USB 這份共通的鍵，所以牆上會同時有兩張卡。硬猜「同一個網段
上唯一一台匿名的就是它」會在有兩支的時候配錯人，寧可多一張卡。

牆上那張 USB 卡給的動作是**複製 `hangar setup` 指令**，不是「註冊 agent」——
helper 的 `/enroll` 吃的是 profile 名稱，而這支手機還沒有 profile；它缺的第一步
是 `setup`，而 `setup` 是互動的（要選裝置、可能要輸入配對碼），不是 helper 代跑
得了的。不假裝有一顆按得完的按鈕。

### 三個刻意不做的決定

**不塞進 `scan --json` 的 `hosts[]`。** `scan_*` 那一層的語意是「這個區網上有
什麼」，每一筆都有 IP 跟 MAC。USB 裝置兩個都沒有，混進去會讓 `hosts[]` 裡出現
一種要特別處理的東西，而 `SCAN_SCHEMA` 的消費者不只 hub。獨立的指令 ＋ 獨立的
schema 比較誠實，`--json` 這層的加法本來就便宜。

**hub 還是不碰 adb。** 「這對現在的程式碼意味著什麼」第 7 條的規矩不破例：
hub 對手機的所有知識都來自 `hangar` 的 `--json`。要多一個來源就多一個唯讀指令，
不是在 hub 裡開一條自己跑 adb 的路 —— 否則 CLI 跟網頁就開始各說各話了。

**牆上看得到的是「插在 hub 那台上的 USB」，不是「插在任何人電腦上的」。**
這跟掃描是同一個視角問題（掃的也一直是 hub 那台所在的網段），不是新的限制，
但 UI 上要講清楚，否則 RD 插在自己筆電上的手機沒出現又會變成一次誤判。
要做到「每台電腦都回報自己插了什麼」是 helper 那一側的事，那是另一條線，
現在不開。

### 順帶要修的文案

就算第三個來源做出來了，「掃不到」這個提問還是會再出現 —— 因為手機不在同一個
Wi-Fi、或 USB 插在別人電腦上的時候，它本來就該是匿名的。`hangar scan` 跟裝置牆
在「掃到了一台沒有廠商、5555 關著的機器」時，應該直接把話講完：
**這可能是一支還沒 `setup` 的 Android，開了偵錯也一樣看不出來。**
這比多一個欄位有用。

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
| `POST /hangar/v1/adb` | 要 token | 切偵錯；全手動，沒有任何自動復原（M4 已實作） |
| `POST /hangar/v1/ring` | 要 token | 響給人聽；最長 120 秒且可由通知停止（M3d 已實作） |

`status` 的形狀刻意跟 `hangar --json` 對齊，hub 合併時才不用翻譯：

```json
{
  "schema": 1,
  "agent":  { "version": "0.1.2", "uptime_s": 86400 },
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

### 入伍（enroll）：一次性 ADB（USB 或網路）

```bash
hangar enroll [-p 手機] [--apk agent.apk]
```

> 這份協定原本寫的是 `hangar setup --enroll`，實作時改成獨立指令：已經設定好的
> 手機也要能補裝 agent，而 `setup` 是「從零建立一支 profile」的流程，兩件事的
> 前提不一樣。

1. `adb install -r <APK>`
2. `adb shell pm grant com.hangar.agent android.permission.WRITE_SECURE_SETTINGS`
3. `DEVICE_SERIAL=$(adb shell getprop ro.serialno)` —— 這一步 `hangar setup` 現在就在做
4. 電腦端產生一組隨機 token（32 bytes hex）
5. 把 profile 名字、序號與 token 交給 agent：
   ```bash
   adb shell am broadcast -n com.hangar.agent/.EnrollReceiver \
     -a com.hangar.agent.ENROLL --es serial "$DEVICE_SERIAL" \
     --es token "$TOKEN" --es name "$PROFILE"
   ```
   指定 component（`-n`）是因為 Android 8+ 擋隱式廣播。
6. 把 `AGENT_TOKEN` / `AGENT_PORT` 寫進 profile
7. 驗證：打一次 `GET /hangar/v1/status`，拿得到東西才算成功

**agent 自己不產生 token。** 產生的一方是電腦端，因為那時候 adb 通道已經是信任的；
讓 agent 產生再由電腦來讀，多一個「誰先信任誰」的問題。

### 升級（`--reinstall`）：換 APK，不換 token

> **已實作。** `hangar enroll -p <手機> --reinstall`，裝置牆上是「更新agent」。

「一台手機只入伍一次」這條規矩擋的是**重新入伍**，不是**換版本**。但兩件事在
使用者眼前長得很像：裝置牆把低於目前標準的 agent 標成舊版，
說完了問題，卻沒有下一步 —— 而正規入伍那條路會撞上 `already_enrolled`，看起來
像是「被系統擋住了」。所以升級要有自己的一條路。

只做三件事，中間**不發入伍廣播**：

1. `adb install -r <APK>` —— 就地升級，app 的資料不動
2. `adb shell pm grant … WRITE_SECURE_SETTINGS` —— 再授一次
3. `am start` 把 app 叫到前景，再用**原本那組 token** 打一次 `GET /status`

| 決定 | 為什麼 |
|---|---|
| **不 `pm clear` 再重新入伍** | token 是每台電腦各自保管的。清一次就等於把所有入伍過這支手機的電腦一起鎖在門外 —— 升級不該有這種代價 |
| 第二步「再授一次權限」是刻意的 | 就地升級後權限本來就還在。這一步救的是另一種人：上次入伍時這一步失敗（手機沒解鎖、OEM 擋掉），那支 agent 從此切不了偵錯 |
| 新裝上去的 agent 說自己沒入伍 → 直接補完整入伍 | 有人 `pm clear` 過，或 app 曾被解除安裝。那一刻 adb 就在手上，不要丟一個錯誤叫人再跑一個指令 |
| 裝得上去、但新版不認這台電腦的 token → 停下來講清楚 | 手機上那支是別台電腦入伍的。解法有代價（見下一節的 `--takeover`），那個代價要由人決定，不是由指令順手做掉 |
| 沒有 token 的 profile 不給用這條 | 「只換 APK」對還沒入伍過的手機沒有意義：裝上去也問不到話。那條路本來就叫 `enroll` |
| 判斷「是不是舊版」看 agent 版號，不用能力欄位推測 | 裝置牆以 `0.1.2` 為目前標準，數字比較後只標出低於標準的版本；`can.ring` 只代表響鈴能力，`can.toggle_adb` 也不能拿來判斷版本 |
| helper 沿用 `POST /enroll`，只多一個 `reinstall` 布林 | 同一條 adb、同一套三道鎖、同一支 CLI。為了一個旗標開第二個端點只會多一份要一起維護的東西 |
| hub 一行都不用改 | 「hub 維持唯讀」那條規矩不因為多一顆按鈕就破例 |

### 接手（`--takeover`）：token 遺失、但 adb 還通

> **已實作。** `hangar enroll -p <手機> --takeover [--yes]`。裝置牆上**刻意沒有**
> 對應的按鈕。

上面兩條路中間有一個洞：手機上那支 agent 還入伍著，但**這台電腦手上沒有它的
token** —— 這裡的 profile 重建過，或它本來就是別台電腦入伍的。正規入伍撞
`already_enrolled`，`--reinstall` 說「沒有 token，沒辦法只換 APK」。兩個訊息都對，
人卻沒有下一步可走。

六個步驟，比正規入伍多的就是中間那一步：

1. `adb install -r <APK>`
2. `adb shell pm clear com.hangar.agent` —— 清掉手機上的入伍狀態
3. `adb shell pm grant … WRITE_SECURE_SETTINGS`
4. 入伍廣播：profile 名字、序號、一組新 token
5. `am start` 把 app 叫到前景
6. 用剛寫下的 token 打一次 `GET /status`

| 決定 | 為什麼 |
|---|---|
| **token 不從手機讀回來** | 它在 app 的私有資料裡，adb 這一側讀不出來（release 版連 `run-as` 都沒有）。「清掉重來」不是偷懶，是唯一成立的做法 |
| **不在 agent 那側加「重新入伍」廣播** | `EnrollReceiver` 必須 exported（發廣播的是 shell uid），同機任何 app 都發得出。真有那條路，誰都能把別人的手機搶走。`pm clear` 需要 adb，那道門檻本身就是保護 |
| 要當面點頭（輸入 `yes`），沒終端機就要 `--yes` | 代價落在**別台電腦**上，而這台電腦看不出來還有誰入伍過。看不見的代價只能用問的 |
| 先裝 APK、再清資料 | 簽章對不上這種失敗，要發生在還沒破壞任何東西之前 |
| 清完才授權 | `pm clear` 會把 `pm grant` 給過的權限一起收回去，先授等於白做 |
| 與 `--reinstall` 互斥 | 一個刻意不動 token，一個把它整組換掉。同時出現一定有一邊是誤會 |
| **裝置牆不給按鈕** | helper 的 `/enroll` 只走不會踢掉別人的兩條路。要接手就複製卡片上那行指令，回終端機點頭 —— 這條規矩跟「hub 維持唯讀」是同一個理由 |

### 找得到 agent：mDNS 是加速器，不是必要條件

> **已實作（M3b）**：手機端在 `agent/…/MdnsBroadcast.kt`，電腦端在 `hangar` 的
> `scan_mdns_*`。下面這份規格就是兩邊實際照著做的東西。

廣播 `_hangar-agent._tcp`，instance 名稱 `hangar-<序號後六碼>`，TXT：

```
v=1  serial=R58M12345AB  model=Pixel+7+Pro
```

**TXT 裡不放 token** —— mDNS 是整個區網都聽得到的明文廣播。序號放得進去，是因為
電腦端本來就要靠它認人，而且光知道序號並不能拿來存取那支 agent。

機型裡的空白編成 `+`（`Pixel 7 Pro` → `Pixel+7+Pro`）。TXT 在 `avahi-browse` 與
`dns-sd` 的輸出裡是用空白分隔的一串 `鍵=值`，值裡直接放空白會把電腦端的解析拆壞。
兩邊的實作要一起看：手機端 `Build.MODEL.replace(' ', '+')`，電腦端 `scan_mdns_txt_get`。

還沒入伍的 agent 沒有序號可放 —— 那時仍然廣播（「這裡有一支還沒入伍的 agent」本身
就是有用的資訊），instance 名稱退回 `hangar-agent`，TXT 裡就沒有 `serial` 那一項。

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
回得去的路**。agent 掛了就要人拿著手機處理。

第一版用「關閉後 `revert_after_s` 秒自動開回」去擋這件事，前提是「QA 測加固版
是有限時間的事」。**那個前提是錯的**，所以那套機制已經整個拿掉了 —— 為什麼錯、
換成什麼，見下一節。

### M4 實作邊界：helper 寫入，hub 仍唯讀

M4 已按原本的安全邊界落地：`hub` 只輪詢與呈現資料，瀏覽器上的偵錯按鈕透過
本機 `helper` 的三道鎖呼叫 `hangar adb`，再由 agent 執行真正的設定變更。這樣
不需要在 hub 增加一個新的遠端寫入認證面，也不會讓固定輪詢程序意外改手機。

```json
POST /hangar/v1/adb
{ "enabled": false }
→ { "schema": 3, "enabled": false, "adb": { ... } }
```

CLI 與 helper 都會先驗證輸入，並把 agent 回傳的能力不足（403）、未入伍（409）
或 token 錯誤（401）保留給使用者看。

### 為什麼沒有自動復原（schema 2 → 3 拿掉了 `revert_after_s`）

原本的設計把「關偵錯」當成一件有時限的事，關掉後排一個鬧鐘自己開回來。**機房
的實際用法剛好相反**：QA 長期關著偵錯測加固版，那才是常態；RD 偶爾開偵錯進去
協助，那才是例外。在這個前提下，那顆鬧鐘做的事是：

- **在一段長測的中途把條件改掉，而且不通知任何人。** 加固版會偵測
  `adb_enabled`，前半段跟後半段的行為可能不一樣，log 上卻看不出分界。這比測失敗
  更糟：拿到一個不知道在測什麼的結果。
- **把常態變成勞務。** 每 30 分鐘回來按一次，或設成 86400 秒每天按一次 —— 而那個
  24 小時上限的存在理由，正是不准有人把它設成實質永久。上限在對抗需求。
- **沒有真的救到什麼。** 「關掉偵錯後 agent 是唯一回得去的路」在這種用法下是**常態**，
  不是按鈕造成的臨時暴露。每隔一段時間把偵錯翻回開，只是開一扇隨機的窗，並沒有
  讓那條路變可靠。

所以 schema **2 → 3**：`revert_after_s` 不再是可選欄位，而是**會被拒絕的欄位**
（400）。刻意不做「靜默忽略」—— 一個被默默吃掉的欄位會讓人以為鬧鐘還武裝著，
而這次改動的重點正是狀態不能有歧義。同理，CLI 的 `--revert-after-s` 直接報錯。

失敗方向也因此變好了：舊設計裡復原失敗＝偵錯永遠關著、遠端救不回來；現在沒有
復原這回事，任何一次切換失敗都還留在「可以再按一次」的狀態。

真正該接手那個風險的是**看得見**，不是自動化：牆上要讓「agent 沒回話 ＋ 偵錯
關著」這個組合明顯到不用盯，因為那正是需要有人走過去的狀態。那是顯示層的事，
不會產生任何自動狀態變更。**還沒做。**

換版時注意：只更新電腦端拿不掉舊 APK 上的鬧鐘，每支手機都要換 APK。順序上沒有
死結 —— 用舊 agent 開偵錯（舊碼在 `enabled: true` 時會清掉期限）→ adb 推新
APK → 用新 agent 關回去。

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

### 這份協定已經改了現有的什麼（M3a／M3d／M4）

| 元件 | 動到的地方 | schema |
|---|---|---|
| `hangar` | `hangar enroll`（含 `--reinstall`）；`agent_*` 這一層；profile 多 `AGENT_TOKEN` / `AGENT_PORT`；`scan` 多探 5599；`list --probe` 在 adb 不通時改問 agent；新增 `ring` / `adb` CLI | `list` 現為 4、hub 現為 7 |
| hub | 多讀 `agent`、`agent.can`、`agent.adb` 與 `battery.source`；卡片按鈕仍經 helper，**沒有**直接跟 agent 講話 | `/api/devices` 現為 7 |
| helper | 新增 `/ring`、`/adb`，沿用 localhost、Origin、token 三道鎖；`/enroll` 多收一個 `reinstall` 布林 | API schema 2 → 5 |
| README | 「profile 沒有任何祕密」那句已經改掉 —— 入伍過的 profile 有 token |  |

還沒做的：`adb.wifi_port`（M3c，agent 目前一律回 `null`）。M3b 的 agent mDNS
廣播與電腦端 fallback 已完成；手機端廣播仍列在待實測清單 B3。

> 這張表把功能邊界與目前實作一起記下來；歷史上的 schema 變更仍以各元件的宣告
> 與上面的「現況速查」為準。

## 響鈴：在一排手機裡認出是哪一支

> **M3d 已完成。** 只依賴 M3a（已完成、實機驗過），不依賴 M3b／M3c／M4；
> agent、CLI、helper、裝置牆與 fake agent 協定測試都已接上。真機音量、震動與
> 各家 ROM 的通知顯示仍列在待實測清單。

### 先把「找不到手機」拆開

「找不到手機」至少是三件事，而響鈴只解其中兩件：

| 情境 | 響鈴 |
|---|---|
| 一整排長得一樣的機器，不知道牆上這張卡是哪一支 | **解得掉，而且是最好的解** —— 按下去，響的那支就是 |
| 手機在線上，但不知道它實體在哪（在誰桌上、在哪個抽屜） | 解得掉 |
| 手機失聯了（牆上是 `offline` / `no_adb`，agent 也叫不動） | **解不掉** —— 叫不動的東西響不了 |

第三種偏偏是最讓人抓狂的那一種。所以這個功能的定位是**識別**，不是**尋找**；
里程碑名稱、按鈕文案、README 都要照這個講，不然做完會發現沒解到某些人以為的
痛點。第三種要靠下面「互補的兩條便宜路」。

### 只有 agent 這條路是乾淨的

`adb` 那條不當主線。要讓手機真的發出聲音，得 `adb push` 一個音檔再
`am start -a android.intent.action.VIEW`，會跳出「用哪個 app 開啟」的選單 ——
髒，而且各家 ROM 不一樣。`input keyevent 224`（亮螢幕）與 `cmd vibrator` 倒是
乾淨，但那不是響鈴。

agent 反過來很簡單：它是一支 app，要的東西框架都給了 ——
`RingtoneManager.TYPE_ALARM` + `AudioManager` 的 `STREAM_ALARM` + `Vibrator`。
而且 agent 已經有前景服務撐著（`AgentService`），播聲音不需要任何新的豁免。

這裡有兩個已經知道的坑，都進了待確認清單：

**螢幕不要指望用 Activity 點亮。** Android 10+ 擋背景啟動 Activity —— 跟上面
「Android 12+ 不准 app 從背景啟動前景服務」是同一家族的限制，而且繞法
（`SYSTEM_ALERT_WINDOW`、full-screen intent）在 Android 14 又收緊了一次。改發
一則**高優先度 notification**：它會跳 heads-up、會點亮螢幕，而
`POST_NOTIFICATIONS` 在 manifest 裡已經有了，不必多要權限（B7）。順帶一提，
在架上一排手機裡，亮起來的那支其實比響的那支更好認 —— 聲音在櫃子裡很難定位。

**音量是個會回不去的狀態。** 手機被調成靜音的話，鈴響了也聽不到；但 agent 要是
去改系統 alarm 音量，就得負責改回來，而 app 被 ROM 殺掉的時候它改不回來。這跟
這跟偵錯開關不一樣，差別值得寫下來：**響鈴是一個動作，偵錯是一個狀態**。動作
一定要自己結束，狀態只能由人改。（M4 原本也給偵錯排了自動復原，後來拿掉了 ——
見「[為什麼沒有自動復原](#為什麼沒有自動復原schema-2--3-拿掉了-revert_after_s)」。）
第一版**不碰系統音量**，只用 alarm stream（它本來就不受靜音影響，DND 的
多數設定也放行）；要不要動音量等 B6／C8 實測完再說。

### 協定：`POST /hangar/v1/ring`

```json
POST /hangar/v1/ring   要 token   { "seconds": 30 }
     → 200             { "schema": 2, "ringing": true, "seconds": 30 }
```

| 規矩 | 為什麼 |
|---|---|
| **一定要自己停**，agent 端夾一個上限（暫定 120 秒） | 一支在抽屜裡響一整天的手機是災難。響鈴是動作，所以要自己結束；偵錯是狀態，所以不准自己變 |
| 回應回的是**實際會響幾秒**，不是你要的幾秒 | 被上限夾過的話呼叫端要知道。呼叫端不准假設它拿到的就是它送出的 |
| `{"seconds": 0}` 就是停 | 找到之後要能立刻關掉 |
| 手機上那則通知要有一顆「找到了」 | 手機已經在你手上的時候，那是最快的路，比跑回電腦按快 |
| 重複呼叫 = 重新計時，不疊加 | 按兩下不該變成響兩倍久 |
| `can.ring` 是能力宣告，跟 `can.toggle_adb` 同一套 | 舊版 agent 根本沒有這個欄位。兩邊都必須忽略不認得的欄位 —— 所以牆上要把「沒有這個欄位」當成 `false`，不是當成壞掉。它只負責表示響鈴能力；牆上的版本判斷改看 `agent.version`，見「[升級（`--reinstall`）](#升級--reinstall換-apk不換-token)」 |
| 錯誤碼沿用現在那套 | 沒入伍 409、token 不對 401、body 不是 JSON 400。不要為了一個新端點發明第二套 |
| **不做「全部響」** | 20 支一起響沒有任何識別價值，只有噪音 |

協定 schema **1 → 2**。`can` 多一個欄位，並加入響鈴與偵錯寫入端點；都是往上加而不是改意思。
（後來的 **2 → 3** 才是減法：拿掉 `revert_after_s`，見 M4 那節。）

### 誰按得動：走 helper，hub 維持唯讀（A 案）

牆上的鈴鐺跟投影按鈕走同一條路：打 `127.0.0.1` 上的 helper，helper 在**按按鈕
那台電腦**上跑 `hangar ring -p <名稱>`，由 `hangar` 去打手機裡的 agent。
**hub 一行都不用改**，「唯讀」那條規矩維持。

不讓 hub 自己打（B 案）的理由不只是省事。hub 的寫入端點要配一套認證，而
「誰在看這一頁」這題現在還沒有答案（見「[還沒決定](#還沒決定)」）。
**不要讓一顆鈴鐺順便把那個決定做掉** —— 那是 M4 該正面處理的事。走 helper 則是
直接借到它已經有的三道鎖：只綁 `127.0.0.1`、Origin 白名單、token；而且「你人在
這台跑著 helper 的電腦前面」本身就是一層授權。

要老實承認的不對稱：投影**必須**在本機（視窗要開在你面前），響鈴不必 ——
聲音出在手機上，跟你坐在哪台電腦前無關。走 helper 是為了借授權模型，不是物理上
非如此不可。代價是「沒跑 helper 就按不動」，這件事在響鈴上比在投影上難解釋。
接受這個代價，換的是牆上兩顆按鈕行為一致（都要 helper、說明都在同一個地方），
使用者不用學兩套。

反面論點留在這裡，因為它之後可能會翻案：響鈴是**風險最低的寫入動作** ——
不改任何持久狀態、會自己停、按錯了最糟就是某支手機響 30 秒。哪天真的要試
「hub 的寫入端點與認證長什麼樣」，它是比 M4 的切偵錯好得多的白老鼠。那時候把它
從 helper 搬到 hub 是個小改動：`hangar ring` 那一層不用動，換的只是誰去呼叫它。

### 牆上長什麼樣

- 每張卡一顆鈴鐺，只在 agent 叫得動**而且** `can.ring` 是 `true` 的時候是活的
- 按不動的時候不要只給一顆死按鈕，要說明為什麼（沒入伍／agent 叫不動／這台電腦
  沒跑 helper）—— 跟現在 helper 沒跑時那顆投影按鈕的處理一致，`hub/static/index.html`
  裡那段註解講的就是這件事
- 響鈴中的卡片要看得出來：倒數 + 一顆「停」
- iOS 沒有這條（M5 是唯讀）

### 互補的兩條便宜路

響鈴是「從牆上找到手機」。這兩條是「從手機找到牆上」跟「根本不用找」，解的正是
響鈴解不掉的第三種情境，而且都不需要新端點、不用碰認證那題：

| | 內容 | 狀態 |
|---|---|---|
| 反向識別 | agent 那頁狀態畫面把 profile 名字大字顯示出來，序號放在下方 | **M3e**，已完成，見「[反向識別](#反向識別m3e入伍時多寫一個名字)」 |
| 位置標籤 | profile 多一個 `LOCATION`（「三樓 A 櫃 第二層」），牆上顯示 | 還沒排。**對失聯的手機一樣有效** —— 「找不到手機」的情境裡，這條的涵蓋率恐怕比響鈴還高 |

三個一起才算把「找不到手機」解完。

### 會動到什麼（做的時候照這張改）

| 元件 | 動到的地方 | schema |
|---|---|---|
| agent | `POST /hangar/v1/ring`；一個 `Ringer`（alarm stream + 震動 + 高優先度通知 + 會自己到點停的計時器）；`Status` 的 `can` 多 `ring` | 協定 1 → 2 |
| `hangar` | `agent_ring`（agent 層）、`cmd_ring`（指令層）。transport 那一層不用動；`list --json` 的 `agent` 物件多帶 `can` | `list` 3 → 4 |
| helper | `POST /ring` 與 `POST /adb`，跟 `/mirror` 同一套三道鎖與同一套「別丟出去就回報成功」 | helper 2 → 4 |
| hub | **不用增加寫入端點** —— `agent` 物件是整包從 `hangar --json` 帶上來的；卡片動作仍走 helper | API schema 6 → 7 |
| 牆 | 每張卡一顆鈴鐺 + 倒數 + 停；讀 `agent.can.ring` | |
| 測試 | `tests/agentbin/fake_agent.py` 要同步實作 `/ring`（協定被兩份實作夾住的規矩）；`test_agent_protocol.sh`（上限夾得住、停得掉、沒入伍 409、舊版沒有 `can.ring` 不算壞）、`test_helper.sh`（`/ring` 的三道鎖）、`test_agent_client.sh`（`hangar ring`）、`test_hub.sh`（**hub 仍然沒有任何會動手機的端點**） | |

最後那一項不是順手加的：A 案的整個價值就在「hub 維持唯讀」，那句保證要有測試
夾著，不然它會在某一次「順手」裡消失。

## 反向識別（M3e）：入伍時多寫一個名字

> **已完成。** 整個 M3 裡最小的一條 —— 沒有新端點、協定號碼不用動、
> 手機端多一個字串欄位而已。

手上拿著一支手機，想知道「這是牆上哪一張卡」，入伍前只能看 `MainActivity` 上的
序號再回電腦比對。入伍那一刻電腦端本來就知道 profile 叫什麼，順手寫進去就好。

| 元件 | 動到的地方 |
|---|---|
| `hangar` | `cmd_enroll` 的那道廣播多一個 `--es name "$PROFILE"` |
| agent | `Enrollment` 多存一個 `name`（`enroll()` 的「第一次入伍者得之」規矩不變）；`EnrollReceiver` 多讀一個 extra；`MainActivity` 把它大字放在最上面，序號降一級 |
| 測試 | `test_agent_client.sh`：廣播帶的名字要跟 profile 一致。`test_agent_protocol.sh` **不用動** |

三個刻意不做的決定：

**協定 schema 不用動。** 這個名字是走 enroll 廣播進去的，不是 HTTP 協定的一部分。
`/hangar/v1/*` 的既有端點語意沒有被改寫；M3d/M4 新增的欄位與寫入端點已讓 agent
協定升到 schema 2，後來拿掉 `revert_after_s` 又升到 3，
`tests/agentbin/fake_agent.py` 都同步實作。

**名字不進 `/status`，也不做比對。** 同一支手機在不同電腦上**本來就會叫不同的
名字** —— `helper` 的 `resolve()` 就是為這件事寫的（牆上的名字是 hub 那台機器
取的，序號才是跨電腦不變的那個）。所以「手機裡記的名字」跟「你這台電腦上的
profile 名字」對不起來是**正常狀態，不是錯誤**。回報它只會誘使某一層去比對，
然後產生一整牆的假警報。它的用途就只有一個：給實際拿著手機的那個人看。

**改名不會同步過去，先接受。** 入伍是「第一次入伍者得之」，所以之後 profile
改了名字（現在沒有 rename 指令，實際上是去動 `~/.config/hangar/` 底下那個檔名，
或乾脆重跑 `setup`），手機裡記的還是舊的那個。這是外觀問題，不值得為它開第二條寫入路。
真的痛起來再加一個 token 認證的 `POST /hangar/v1/label` —— **不要**再開一個
exported 廣播，那是同一支手機上任何 app 都發得出來的攻擊面（`EnrollReceiver`
非 exported 不可是因為發的人是 shell uid，那是沒得選；這裡有得選）。

## 待確認清單

這份是「還沒有人在真實世界裡看過」的東西的總表。有實機之後照著跑，把結果補回來。
分成三級：**擋路**的做不出來就要改設計，**會痛**的是體驗差但繞得過，**想知道**的
只是還沒量過。

### A. 擋路的（猜錯要改設計）

| # | 要確認什麼 | 怎麼確認 | 猜錯的話 |
|---|---|---|---|
| A1 | `WRITE_SECURE_SETTINGS` 能不能**寫** `Settings.Global.adb_wifi_enabled` | `adb shell settings put global adb_wifi_enabled 1`，看無線偵錯有沒有真的開；再用 agent（已授權）寫一次 | M3c 整個做不成，重開機後還是要人插 USB |
| A2 | 打開無線偵錯後，**之前配對過的電腦**能不能免配對重連 | 配對一次 → 重開機 → agent 開無線偵錯 → 電腦端不做任何事，看 `adb devices` | 「重開機自動恢復」破功，要人讀配對碼 → M3c 價值大減 |
| A3 | 無線偵錯的埠怎麼找 | `dns-sd -B _adb-tls-connect._tcp`（macOS）／`avahi-browse` | 找不到就等於連不上，A1 A2 都白做 |

> A1 的**前提**已經確認了：實機上 `pm grant` 之後 `WRITE_SECURE_SETTINGS: granted=true`，
> 而且 agent 自己回報 `can.toggle_wifi_adb: true`（Android 13）。還沒確認的是「真的去寫
> 那個值會發生什麼事」—— 那一步會動到裝置的安全設定，要有意識地做。
>
> A4（Gradle 建得出 APK 嗎）已經有答案了，移到下面「已經確認過的」。

### B. 會痛的（繞得過，但要知道）

| # | 要確認什麼 | 怎麼確認 | 影響 |
|---|---|---|---|
| B1 | 前景服務在各家 ROM 的省電策略下活多久；以及手機重開機後它自己回不回得來 | 裝上去放 24／72 小時，中間不碰手機，看 `/hello` 還答不答得出來；然後重開機再看一次 | **整套的單點故障**：agent 被殺 = 那支手機失聯 |
| B2 | 關掉 `adb_enabled` 時無線偵錯會不會一起死 | 手動關掉 → 看 `adb devices` 與 agent 端點 | 偵錯現在會長期關著，這條決定了那段期間還剩哪些路回得去 |
| B3 | `NsdManager` 在你的機器 + AP 上的表現 | M3b 做完了，現在測得動：手機裝上新版 agent 後，在同區網的電腦跑 `dns-sd -B _hangar-agent._tcp`（macOS）或 `avahi-browse -rt _hangar-agent._tcp`（Linux）看得到嗎；再用 `hangar scan --json` 確認那台的 `agent.discovered_by` 是 `mdns` | 看不到就退回「探 5599」，只是慢。**電腦端已經自動處理這個退路**，不用改設定 |
| B4 | AP 有沒有開 client isolation | 兩支手機互 ping；或電腦 ping 手機 | 有的話整個區網掃描與 agent 都不通，得改走 Tailscale |
| B5 | 一個 /24 掃完要多久（真實網路，不是 mock） | `time hangar scan` | 太久的話 hub 的 `--scan-interval` 要往上調 |
| B6 | 手機被調成靜音／開著勿擾時，alarm stream 還響不響（各家 ROM 不一） | 手動設成靜音與各級 DND，各按一次響鈴 | 不響的話響鈴要去動系統音量，那就多一個「會回不去的狀態」（見 C8） |
| B7 | 高優先度 notification 會不會真的點亮螢幕、跳 heads-up | 螢幕關著時按響鈴，看它亮不亮 | 不亮的話只剩聲音；在櫃子裡聲音比亮光難定位，識別會慢很多 |

### C. 想知道的（還沒量過）

> C2 / C3 已經驗過，搬到下面「已經確認過的」了 —— 編號留著不重排，這樣舊 commit 訊息與筆記裡提到的「C 幾」還找得到人。

| # | 要確認什麼 | 怎麼確認 |
|---|---|---|
| C1 | agent 對電池的影響 | 裝了 agent 的手機放一天，比較耗電曲線 |
| C4 | 加固 app 實際擋什麼 | 實測 protocol 另存於專案外部 |
| C5 | hub 當 adb server 那條路可不可行 | 見「待實測 1」的最小驗證步驟 |
| C7 | 已授權的 hub 能不能代按授權對話框 | 見「待實測 2」的最小驗證步驟 |
| C6 | iOS 那條線（`libimobiledevice`）拿得到什麼 | 還沒開始 |
| C8 | 響鈴要不要動系統 alarm 音量；動了之後 app 被 ROM 殺掉時還還得回來嗎 | 改音量 → 播 → `am force-stop com.hangar.agent` → 看音量回去了沒 |

### 已經確認過的（不用再問）

| | 結論 |
|---|---|
| Kotlin 編譯得過嗎 | 過（`kotlinc` 對著 `android.jar`，7 個檔） |
| manifest 合法嗎 | 過（`aapt2 link`） |
| 手機能不能自己按掉授權對話框 | **不能**。見上面「幾個要記住的現實限制」。注意這句話管的是「手機自己點自己」—— 由**已授權的電腦**代點是另一回事，還沒測，見待實測 2 |
| **agent 在實機上跑得起來嗎** | **會**。Pixel 4 / Android 13：裝得上、服務起得來、5599 答得出話 |
| **`hangar enroll` 走得完嗎**（C2） | **走得完**，五步都 ok。但過程中發現 Android 12+ 的前景服務限制，多了 `am start` 那一步才行 |
| **`WRITE_SECURE_SETTINGS` 拿得到嗎** | **拿得到**。`pm grant` 之後 `granted=true`，agent 自報 `can.toggle_adb: true` |
| **兩份實作對得起來嗎**（C3） | **對得起來**。同一份協定測試打真的 Kotlin agent，25/25 全過 |
| **adb 不通時還看得到電量嗎** | **看得到**。adb `disconnected` 而機型與電量照樣回得來，`battery.source` 標 `agent` —— 這是整支 agent 存在的理由，它成立了 |
| **Gradle 建得出 APK 嗎**（A4） | **建得出來**。`./gradlew assembleDebug` 在 CI 上一次就過（AGP 8.2.2 / Gradle 8.5 / JDK 17），產出 `app-debug.apk` 812,398 bytes，`aapt2` 認得 `com.hangar.agent` v0.1.0 / compileSdk 34。現在每個 PR 都會建一次並留成可下載的 artifact，見 `.github/workflows/agent.yml` |

實機那一輪還**沒**驗到的：手機真的重開機之後 agent 會不會自己回來（B1 那條的
前半段）。測試時是用 `adb disconnect` 模擬「adb 不通」，那不等於重開機 ——
而真的重開機要由手邊有那支手機的人做。

## 待實測 1：讓 hub 當唯一被授權的那台電腦

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

## 待實測 2：讓 hub 代按那個「允許 USB 偵錯」

上一條是把 RD 的電腦擋在手機外面（改連 hub 的 adb server）。這一條反過來：RD 的
電腦照樣直連手機，但**按允許的那隻手改由 hub 出**，人不用走到手機架前面。

### 為什麼這條跟 agent 那條不一樣

「現實限制」那節寫的是對話框防疊加／防自動點擊。要講精確一點：那個防護擋的是
**覆蓋窗** —— `filterTouchesWhenObscured` 會讓對話框拒收「上面壓著別人視窗」的
觸控，所以裝在手機裡的 app 點不到它。

但 `adb shell input tap`（以及 scrcpy 的控制通道）不是覆蓋窗。它以 **shell uid**
走 `InputManager.injectInputEvent` 注入，這條路沒有「被遮蔽」這回事。而 hub 是
已經被授權的那台，它天生就有這條注入權限。

所以「adb 授權不能自動化」準確的說法是：**手機不能自己點自己**。已授權的電腦
代點是另一件事 —— 沒被證明不行，也還沒被證明行，所以放在這一節。

### 不需要投影

投影只是為了讓人看到對話框再用滑鼠點。既然 hub 已授權，它可以直接偵測與點掉：

```bash
adb shell dumpsys window | grep -i UsbDebugging     # 對話框在不在
adb shell uiautomator dump /sdcard/w.xml            # 撈「一律允許」與「允許」的 bounds
adb shell input tap <x> <y>
```

全程不需要螢幕、不需要 scrcpy、不需要有人在 hub 旁邊。hub 要是放在角落沒接螢幕，
投影那條反而卡住（scrcpy 要有桌面才開得出視窗），`input tap` 沒這問題。

要人眼確認的話，在 hub 上跑 `hangar -p` 投影出來用滑鼠點，是同一條路的手動版 ——
差別只在 hub 得有螢幕，以及得有人在旁邊。

### 要先確認的事

| | |
|---|---|
| 對話框是不是 `FLAG_SECURE` | 是的話投影全黑（見 [docs/flag-secure.md](docs/flag-secure.md)）。**但 tap 不看畫面** —— 只要 `uiautomator dump` 撈得到座標就還點得到。兩個都撈不到才是死路 |
| OEM ROM 擋不擋注入 | MIUI／HyperOS 要另外開「USB 偵錯（安全設定）」才准注入，Samsung 也有自己一套。AOSP 系的應該沒事 |
| 新連線會不會踢掉 hub 自己 | 另一把金鑰連上 5555 的時候，hub 那條已授權連線要撐得住 —— 不然要按的那隻手先斷了 |
| 對話框跨版本穩不穩 | 文字與元件 id 各版本不一定一樣。要靠 resource-id 去找，不要把座標寫死 |

### 這條解的是什麼、不解什麼

原本的痛點有兩半：**加人要有人碰手機**、**那台電腦從此握有一把等同完整裝置控制權
的金鑰**。兩條路解的不是同一半：

| | 待實測 1（走 hub 的 adb server） | 待實測 2（hub 代按） |
|---|---|---|
| 加人不用碰手機 | ✅ | ✅ |
| 收得回來 | ✅ 手機只認得 hub 那一把 | ❌ 每人一把永久金鑰，要撤只能在手機上全撤，所有人一起重來 |
| Android Studio | ❓ 最不確定的一項 | ✅ 完全不用改，RD 那邊照舊 |
| RD 跟手機的連線 | 不直連，全部擠在 hub | 直連 |

所以這兩條是**互補**的：1 的安全性明顯好，2 的相容性好。如果 1 的第 6 步
（Android Studio）過不了，2 就是退路。

### 絕對不能無條件自動按

5555 開著的時候，任何連得到的人都能觸發那個對話框。無條件幫他按「一律允許」
等於把整支手機送出去，而且不留任何痕跡。對話框上顯示的是 RSA 指紋，不是人名，
hub 自己分不出誰是誰。

要做就得是：hub 偵測到請求 → 把指紋丟到網頁上 → **有人在 UI 上按准** → hub 才 tap。
這樣「有人按一次」還在，但按的人是在自己座位上看網頁，不是走到手機架前面 ——
那才是真正省掉的東西。RD 那邊可以先自己算指紋來對：

```bash
awk '{print $1}' ~/.android/adbkey.pub | base64 -d | openssl dgst -md5 -c
```

> 指紋格式對不對得上手機顯示的那一串，也還沒實測過。

### 最小驗證步驟

要三樣東西：hub（已經被這支手機授權過）、一支手機、**一台從來沒被這支手機授權過的
電腦**（RD 機）。換金鑰的方法同上一條。

**1. hub：確認基準狀態**

```bash
hangar status -p <手機>          # adb 要是 device
adb shell echo ok                # 確認 shell 打得進去
```

**2. RD 機：觸發對話框**

```bash
adb connect <手機 IP>:5555
adb devices                      # 期望：unauthorized
```

> 手機上應該跳出「允許 USB 偵錯」。**從這裡開始不要碰手機** —— 整條路要證明的
> 就是不用碰。

**3. hub：看不看得見那個對話框**

```bash
adb shell dumpsys window | grep -i usbdebug
adb shell uiautomator dump /sdcard/w.xml
adb shell cat /sdcard/w.xml | tr '>' '\n' | grep -i "allow\|允許"
```

> 期望：抓得到 `UsbDebuggingActivity`，而且 dump 裡有「一律允許」checkbox 跟允許鈕
> 的 `bounds`。dump 失敗（secure window／拿不到 idle state）就記下來，這條大概到此為止。

**4. hub：先勾「一律允許」，再按允許**

```bash
adb shell input tap <checkbox 的 x y>
adb shell input tap <允許鈕的 x y>
```

> 期望：對話框消失。點不動（畫面沒反應、對話框還在）就是注入被擋了 —— 記下手機的
> 廠商與 Android 版本，那決定這條路能涵蓋哪些機型。

**5. RD 機：驗證真的授權了**

```bash
adb devices                      # 期望：device，不再是 unauthorized
adb shell getprop ro.product.model
```

**6. hub：確認自己沒被踢掉**

```bash
hangar status -p <手機>          # 期望：還是 device
```

**7. 收拾**

> 注意：手機上的「撤銷 USB 偵錯授權」是**一次全撤**，連 hub 那一把也會被撤掉 ——
> 撤完要有人拿著手機重新授權 hub 一次。排測試時間的時候要把這一步算進去。

測完把每一步的實際結果補回這一節。這條跟上一條不衝突，兩條都測完才比得出來要走哪邊。

## 還沒決定

web 版出來之後 CLI 是保留還是收掉、要不要支援多使用者與權限、
RD 的電腦要直連手機還是走上面那條「hub 當 adb server」——這些都還開放。

hub 目前沒有任何會動手機的端點（`POST /api/refresh` 只叫醒自己的輪詢）。M3d
與 M4 的網頁動作都走 helper，因此不需要替 hub 增加寫入端點；helper 已沿用
localhost、Origin、token 三道鎖。未來若要支援多使用者或把寫入權限移進 hub，仍要
另行設計認證與授權，不把這次實作當成多使用者方案。

agent 的端點目前定為明文 HTTP + token。要不要上 TLS、還是乾脆只在 tailnet 上
開放，等 M3a 跑起來、知道實際的延遲與麻煩程度再決定。

多人同時裝 APK 進同一支手機會互相蓋掉，目前沒有任何佔用／排隊機制。hub 要不要
管「誰在用哪一支」也還沒決定。

---

## 專案結構

```
hangar/
├── hangar                # 主 script（bash，無外部相依）
├── README.md             # 入口：安裝、設定一支手機、每天投影
├── ROADMAP.md            # 這份：方向、里程碑、程式分層、測試
├── hangar_install.sh     # symlink 到 /usr/local/bin
├── LICENSE
├── docs/                 # 一個題目一份，由 README 連過去
│   ├── scan.md           # 區網掃描
│   ├── json.md           # --json 的 schema 與 error code
│   ├── multi-host.md     # 多台電腦共用同一支手機
│   ├── agent.md          # 手機端 agent：入伍、升級、限制
│   ├── hub.md            # 裝置牆網頁
│   ├── wall-actions.md   # 牆上那幾顆按鈕與 helper 的三道鎖
│   ├── tailscale.md      # Tailscale ACL
│   ├── flag-secure.md    # 投影全黑（FLAG_SECURE）
│   ├── manual.html       # 上面那些接成一頁的使用手冊（給不看 GitHub 的人）
│   └── logo-agent*.svg   # agent 的圖示來源
├── tools/
│   └── make_manual.py    # README + docs/*.md → docs/manual.html
├── agent/                # 手機端 app（Kotlin，零外部相依，連 AndroidX 都沒有）
│   ├── README.md         # 怎麼蓋、怎麼手動入伍、驗證到什麼程度
│   └── app/src/main/     # HttpServer / Status / Enrollment / AgentService / MdnsBroadcast …
├── hub/
│   ├── hangar_hub.py     # 常駐服務：輪詢 hangar --json、合併、開 HTTP
│   └── static/
│       └── index.html    # 裝置牆（純 HTML/CSS/JS，沒有 build 步驟）
├── helper/
│   └── hangar_helper.py  # 每個人自己電腦上的那一支：牆上的投影按鈕代跑 hangar -p
└── tests/
    ├── run.sh            # 跑全部測試
    ├── test_core.sh      # 核心流程與錯誤分支
    ├── test_multi.sh     # 多台手機
    ├── test_adb_race.sh  # adb server 競態、欄位對齊
    ├── test_multihost.sh # 第二台電腦（--existing）
    ├── test_json.sh      # --json 輸出、錯誤 code、transport 抽象層、電量
    ├── test_scan.sh      # 區網掃描：網段、MAC、廠商、5555 探測、識別合併、--fix-ip
    ├── test_hub.sh       # hub：合併邏輯、HTTP 端點、唯讀保證
    ├── test_helper.sh    # helper：三道鎖、投影起得來／起不來的回報、序號對名字
    ├── test_agent_protocol.sh  # M3 協定的一致性測試（也打得到真的手機）
    ├── test_agent_client.sh     # 電腦這一側：enroll、改問 agent、掃描探 5599
    ├── test_versions.sh         # ROADMAP 現況速查與程式宣告的版本／schema 一致性
    ├── test_manual.sh    # 手冊：轉得乾不乾淨、多份來源接得對不對、錨點死了沒
    ├── mockbin/          # 假的 adb / tailscale / scrcpy / nc / curl / arp / ip / ping
    │                     #   / route / avahi-browse / dns-sd
    ├── hubbin/           # 假的 hangar（吐固定的 JSON 給 hub 吃）
    ├── helperbin/        # 假的 hangar + scrcpy（會真的 exec，helper 靠那個判斷起來了）
    └── agentbin/         # 假的 agent（M3 協定的 Python 參考實作）
```

`hangar` 這支 script 內部分層（由下往上）：

| 層 | 內容 |
|---|---|
| 輸出 | `info` / `ok` / `warn` / `err` / `kv` / 中文欄寬對齊 |
| agent | `agent_*` —— 怎麼跟手機裡的 agent 講話（HTTP + token），`curl` 不在就安靜降級 |
| scan | `scan_*` —— ARP 層級的「這個網段上有哪些裝置」，不分已設定與否；`cmd_scan` 和 lan backend 的候選清單共用它。`scan_mdns_*` 是它底下的一小層：先問 mDNS，問不到就退回逐台探埠 |
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
| HTTP | `Handler` —— `/`、`/api/devices`、`/healthz`、`/static/…` 都是 GET；另有 `POST /api/refresh`（把輪詢提早叫醒，帶最小間隔節流，不碰手機） |

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

有幾項的情境綁在機器本身，重現不了就印 `SKIP` 而不是假裝通過：

| SKIP 的東西 | 什麼時候 | 為什麼不能硬跑 |
|---|---|---|
| hub 綁 1024 以下埠的權限錯誤 | 以 root 執行時（CI 的容器常是 root） | root 綁得上 80 埠，hub 會正常起來然後一直跑，那個 `$(...)` 永遠等不到它結束 —— 結果是整套測試卡死到逾時，連後面的 suite 都跑不到 |
| 中文訊息在 `zh_TW.UTF-8` 底下不炸 | 機器上沒裝那個 locale（多數 Linux 只有 `C.utf8`） | bash 只會印一行 setlocale 警告然後退回 C；那行警告還會混進 `2>&1` 的輸出把 JSON 弄壞，看起來像產品壞了 |
| 裝置牆版號比較的實際行為 | 機器上沒有 `node` | 同一節剩下的檢查是對著網頁原始碼 grep，那只證明得了「`agentNeedsUpdate` 這個函式在」，證明不了它算得對（`0.1.10` 比 `0.1.2` 大就是字串比較會錯的那種）。拿 bash 再實作一次版號比較是在測第二份實作，不是測那一頁 |
| helper 只綁 `127.0.0.1` | 這台機器找不到自己的區網位址（容器裡常常只有 loopback） | 這一項要證明的是「**換一個位址**就連不進來」。沒有第二個位址可以撥，就只剩對 `127.0.0.1` 連一次 —— 而那正是它有在聽的位址，連得上是預期的，通過了什麼也沒證明 |

CI（`.github/workflows/tests.yml`）跑三條腿，因為上面那張表就是這樣被發現的：

| 腿 | 跑什麼 | 抓得到什麼 |
|---|---|---|
| `linux` | `ubuntu-latest`，非 root，額外裝 `zh_TW.UTF-8` | 平常在 macOS 開發時沒人看的那一邊；裝了 locale 之後中文那一節是真的在驗（825 項），不是 SKIP |
| `linux-root` | 同一個 OS 但跑在 `container: ubuntu:24.04` 裡，所以是 root，且**故意不裝** `zh_TW.UTF-8` | root 底下不會卡死、locale 不存在時會好好跳過（817 項）|
| `macos` | `macos-latest` | 修 Linux 的時候不要把開發機那邊弄壞 |

三條腿都設 `timeout-minutes`。預設是 6 小時，而這個專案已經有過「卡住而不是失敗」
的測試 —— 逾時要短到一看就知道是壞了。

平台差異已經咬過四次了：`wc -m` 要的 locale 不一定存在、`stat -f` 在 GNU 上是
`--file-system`（拿格式字串當檔名，會半成功）、1024 以下的埠在 root 底下綁得上、
`HTTPServer.server_bind()` 會做一次反向 DNS（`socket.getfqdn()`），在反向解析不通
的機器上卡到逾時 —— 啟動訊息是在它之後才印，所以看起來像服務起不來。前三個在測試
裡，第四個在 hub 與 helper 自己身上，是 macOS 那條 CI 腿上線第一天抓到的。

兩個從這裡學到的習慣：判斷平台的探測要讓失敗的那條乾淨地失敗，
`A 2>/dev/null || B` 的順序才靠得住；開伺服器的東西不要相信 stdlib 的預設行為會
只做你以為的那件事。

涵蓋範圍：

| Suite | 內容 |
|---|---|
| `test_core.sh` | direct/relay 參數、`--hq`/`--lq` 覆寫、手機重開機提示、`unauthorized`、`offline` 自動重試、Tailscale 未連線、手機不在 tailnet、`status` 區分 direct/relay、`reset`、重複執行不殘留 scrcpy |
| `test_multi.sh` | `list` / `use` / `forget`、`-p` 指定與前綴比對、名稱打錯、多台沒設預設、一台離線不影響另一台、`reset` 只作用在指定那台、`all` 同時開多台與部分失敗、視窗標題、setup 覆蓋提醒、重跑 setup 不洗掉掃描記住的 MAC |
| `test_adb_race.sh` | adb server 重啟競態的自動重試、本機 adb 問題與手機重開機的區分、setup 的 `start-server`、中文欄位對齊 |
| `test_multihost.sh` | `setup --existing`（第二台電腦）、unauthorized 的說明、連不上時的提示方向、`--name` 別名 |
| `test_json.sh` | `--json` 是合法 JSON 且 stdout 不被污染、schema 欄位、舊 profile 沒有 `TRANSPORT` 時的回退、慢欄位要 `--probe` 才取、電量數值與低電量標記、各種錯誤 code、傳輸層掛掉時不誤報成手機重開機、`lan` backend 可抽換、壞掉的 profile 不影響其他支、setup 記下裝置序號 |
| `test_scan.sh` | `scan --json` 的形狀、排除自己與別的網段、`incomplete` 不算裝置、macOS 省略 0 的 MAC 正規化、隨機 MAC 的判定、5555 探測與 `--no-probe`、已設定的 profile 標記、ping sweep 與 `--no-ping`、缺工具不可誤報成「區網上沒東西」、`/16` 與 `/28` 的網段判斷、`--subnet` 的三種寫法、OUI 兩種格式與沒有資料庫時不亂猜、廠商含中文時的欄位對齊、`lan` backend 的候選清單、識別合併（記住 MAC、換 IP 仍認得出、舊 IP 被別台拿走不誤認、一個 profile 只認領一台、隨機 MAC 換過會重學、序號附在輸出裡）、`--fix-ip` 只改認得出來的那幾支且不碰 tailscale profile、mDNS 兩條路（`avahi-browse` 與 `dns-sd`）都找得到 agent 且拿得到序號與機型、沒有 mDNS 工具時退回探 5599 仍然找得到、未解析的 `+` 紀錄不算數、profile 的序號優先於 mDNS 的、`--no-probe` 連 mDNS 都不問 |
| `test_hub.sh` | hub 起得來並印出網址、`/` 與 `/healthz` 與 `/api/devices`、兩份資料合成同一張卡（序號當主鍵）、沒設定過的手機也上牆、`no_adb` 與 `offline` 要分開、低電量標記、要注意的排前面、單支手機的錯誤留在卡片上、**輪詢絕不帶 `--fix-ip` 也不跑任何會寫入的指令**、hangar 壞掉時 hub 不跟著死、靜態檔不准往上跳、`POST /api/refresh` 的節流（剛問過回 429 並說還要等幾秒）、`GET /api/refresh` 是 404、不認得的 `what` 回 400 |
| `test_agent_protocol.sh` | `/hello` 不需要 token 也不吐序號、`/status` 要 token、status 的每個欄位型別（電量是 0-100 整數、充電狀態用小寫那一套、`wifi_enabled` 可以是 null 但不能用 false 混充、拿不到的東西回 null 不塞假值、協定裡根本沒有 MAC 這一欄）、501 與 404 要分得出來、沒入伍是 409 不是 401。**帶 `HANGAR_AGENT_URL` 就直接打真的手機** |
| `test_manual.sh` | `tools/make_manual.py`：Markdown 轉乾淨了沒（讀者不該看到 `**這樣**` 或一整列 `| --- |`）、區段與表格有沒有整段掉、`docs/` 每一份都接進手冊了沒（標題降級、跨檔連結變頁內錨點、沒被 README 連到的就是孤兒）、README 與 `docs/` 之間有沒有死錨點、同一份來源跑兩次印記要一模一樣（`--check` 才有意義） |
| `test_agent_client.sh` | `hangar enroll` 的四個步驟與三種失敗（沒 APK、已入伍過、安裝失敗）、`--takeover`（清了才重新入伍、順序是裝→清→授權、沒點頭不動手機、清不掉就停下來、與 `--reinstall` 互斥）、每次入伍都是新 token、廣播帶的序號與 profile 名字都一致、adb 通時用 adb 的資料、**adb 不通時改問 agent 拿電量與機型**、入伍過但 agent 死掉看得出來、掃描只對探得到 5599 的發 HTTP、缺 `curl` 時安靜降級但入伍要明講 |
| `test_versions.sh` | ROADMAP「現況速查」裡的 hangar／hub／helper／agent 版本與 schema 對上程式宣告、行號參照沒有漂移、Android 與 fake agent 的協定 schema 一致 |

測試裡所有的 `pgrep` / `pkill` 都限定在 mock 使用的 `100.101.102.x`，
不會誤傷你真正在跑的 scrcpy。

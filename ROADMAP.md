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
| 重開機後 5555 消失 | 要人去插 USB | agent 自己重開 |

## 已經確定的事

| 項目 | 決定 |
|---|---|
| 手機端 agent | 要裝（一次性 adb 授權，不走 Device Owner） |
| hub 部署形態 | 一台常駐機器，接在測試機的同一個區網 |
| 加固 app 實際擋什麼 | 還不知道，要先實測（實測 protocol 另存於專案外部） |

## 里程碑

| | 內容 | 狀態 |
|---|---|---|
| M1 | CLI 結構化：`--json`、transport 抽象層、裝置序號、電量 | **已完成** |
| M2a | 區網掃描：`hangar scan`、`scan_*` 層、lan backend 的候選清單、MAC／序號識別合併、`--fix-ip` | **已完成** |
| M2b | hub 骨架：常駐服務 + 唯讀裝置牆網頁 | 卡在「後端用什麼寫」還沒決定 |
| M3 | agent app：授權、電量回報、mDNS 廣播、重開機後自動重開 5555 | |
| M4 | 網頁切換偵錯（RD 開 / QA 關） | 需要 M3 + 加固實測結果 |
| M5 | 網頁投影串流；iOS 唯讀 | |

## 兩個要記住的現實限制

- **MAC randomization**：Android 10+ / iOS 14+ 對每個 SSID 使用隨機但穩定的 MAC。
  同一個 SSID 下可以拿它當識別碼，但使用者「忘記網路再重連」就會換一個。
  所以裝置識別不能只靠 MAC，要能跟 `DEVICE_SERIAL` 合併。
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

## 還沒決定

後端用什麼寫、web 版出來之後 CLI 是保留還是收掉、要不要支援多使用者與權限——
這些都還開放。

---

## 專案結構

```
hangar/
├── hangar                # 主 script（bash，無外部相依）
├── README.md             # 安裝與使用
├── ROADMAP.md            # 這份：方向、里程碑、程式分層、測試
├── hangar_install.sh     # symlink 到 /usr/local/bin
└── tests/
    ├── run.sh            # 跑全部測試
    ├── test_core.sh      # 核心流程與錯誤分支
    ├── test_multi.sh     # 多台手機
    ├── test_adb_race.sh  # adb server 競態、欄位對齊
    ├── test_multihost.sh # 第二台電腦（--existing）
    ├── test_json.sh      # --json 輸出、錯誤 code、transport 抽象層、電量
    ├── test_scan.sh      # 區網掃描：網段、MAC、廠商、5555 探測、識別合併、--fix-ip
    └── mockbin/          # 假的 adb / tailscale / scrcpy / nc / arp / ip / ping / route
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

## 測試

```bash
./tests/run.sh
```

用 mock 的 `adb` / `tailscale` / `scrcpy` / `arp` / `ping` 跑，**不會碰到真的手機，
也不會真的對區網送封包**，設定檔也是寫在 `$TMPDIR/hangar-test` 底下，
不會動到 `~/.config/hangar`。

涵蓋範圍：

| Suite | 內容 |
|---|---|
| `test_core.sh` | direct/relay 參數、`--hq`/`--lq` 覆寫、手機重開機提示、`unauthorized`、`offline` 自動重試、Tailscale 未連線、手機不在 tailnet、`status` 區分 direct/relay、`reset`、重複執行不殘留 scrcpy |
| `test_multi.sh` | `list` / `use` / `forget`、`-p` 指定與前綴比對、名稱打錯、多台沒設預設、一台離線不影響另一台、`reset` 只作用在指定那台、`all` 同時開多台與部分失敗、視窗標題、setup 覆蓋提醒、重跑 setup 不洗掉掃描記住的 MAC |
| `test_adb_race.sh` | adb server 重啟競態的自動重試、本機 adb 問題與手機重開機的區分、setup 的 `start-server`、中文欄位對齊 |
| `test_multihost.sh` | `setup --existing`（第二台電腦）、unauthorized 的說明、連不上時的提示方向、`--name` 別名 |
| `test_json.sh` | `--json` 是合法 JSON 且 stdout 不被污染、schema 欄位、舊 profile 沒有 `TRANSPORT` 時的回退、慢欄位要 `--probe` 才取、電量數值與低電量標記、各種錯誤 code、傳輸層掛掉時不誤報成手機重開機、`lan` backend 可抽換、壞掉的 profile 不影響其他支、setup 記下裝置序號 |
| `test_scan.sh` | `scan --json` 的形狀、排除自己與別的網段、`incomplete` 不算裝置、macOS 省略 0 的 MAC 正規化、隨機 MAC 的判定、5555 探測與 `--no-probe`、已設定的 profile 標記、ping sweep 與 `--no-ping`、缺工具不可誤報成「區網上沒東西」、`/16` 與 `/28` 的網段判斷、`--subnet` 的三種寫法、OUI 兩種格式與沒有資料庫時不亂猜、廠商含中文時的欄位對齊、`lan` backend 的候選清單、識別合併（記住 MAC、換 IP 仍認得出、舊 IP 被別台拿走不誤認、一個 profile 只認領一台、隨機 MAC 換過會重學、序號附在輸出裡）、`--fix-ip` 只改認得出來的那幾支且不碰 tailscale profile |

測試裡所有的 `pgrep` / `pkill` 都限定在 mock 使用的 `100.101.102.x`，
不會誤傷你真正在跑的 scrcpy。

# 機器可讀的輸出（--json）

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
  [手機端 agent](agent.md)。

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

# 從裝置牆上按投影

裝置牆上每張已設定的手機卡片都有一顆投影按鈕。按下去，scrcpy 開在**按按鈕的
那台電腦**上。

要理解它為什麼長這樣，先看一個限制：**網頁啟動不了本機程式**。所以按鈕不能
直接叫 hub —— hub 可能在角落那台常駐機器上，它跑起來的視窗開在那台機器的螢幕
上，沒有人看得到。要按的那台電腦得自己跑一支小服務，網頁再去叫它。

## hub 跟你在同一台

這是最常見的情形，也不用配對：

```bash
hangar wall
```

hub 跟 helper 會在同一個 process 裡一起起來（但仍是兩個 listener，helper 照樣
只綁 `127.0.0.1`）。在這台電腦的瀏覽器打開它印出來的網址，按鈕就是活的 ——
鑰匙由 hub 的 `GET /api/helper` 直接交給那一頁，而那個端點**只回答本機**。
細節見 [hub 那一份](hub.md#helper-跟著一起起來)。

## hub 在別台機器上

這時候按按鈕的那台電腦要自己跑一支：

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

兩條路走的是同一支 helper、同一套三道鎖 —— 差別只有鑰匙怎麼到那一頁手上。

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

## 從裝置牆自動入伍

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
profile。若 agent 其實還在手機上、只是暫時沒有回應，Android 端會拒絕重複入伍，
不會默默覆蓋原本的 token；這時候卡片上會帶回 CLI 的提示 —— 手上有 token 就用
`--reinstall`，沒有 token 就是
[`--takeover`](agent.md#接手一支已入伍的手機--takeover)。

**接手沒有做成按鈕，是刻意的。** `--takeover` 會讓其他電腦手上的 token 一起失效，
而那件事在裝置牆上完全看不出來（沒有任何一份資料知道還有誰入伍過這支手機）。
helper 的 `/enroll` 只走正規入伍與 `--reinstall` 這兩條不會踢掉別人的路；要接手，
就把卡片上那行指令複製到終端機，當面點一次頭。

如果 helper 沒有啟動，按鈕會改成「複製註冊指令」，讓你貼到終端機執行。入伍需要
安裝好的 agent APK；找不到 APK 時，helper 會把 CLI 的 build 提示帶回裝置牆。

## 從裝置牆升級舊版 agent

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
因此被鎖在門外；理由見 [`--reinstall`](agent.md#升級舊版-agent--reinstall)。
hub 這一側沒有新增任何會動手機的端點 —— 按鈕走的仍然是 helper 的 `/enroll`，
只是 body 多一個 `reinstall`。

## 每台電腦要先做的事

| | 為什麼 |
|---|---|
| 裝好 `hangar` + `adb` + `scrcpy`（README 的[安裝](../README.md#安裝)那一節） | 按鈕跑的就是 `hangar -p <名稱>`，它省的是打字，不是省掉這些 |
| 跑過一次 `hangar setup` | **這一步躲不掉**：adb 授權綁的是每台電腦自己的金鑰，要有人在手機上按「一律允許」。任何按鈕都繞不過它 |
| 跑著 `hangar_helper.py` | 網頁啟動不了本機程式 |

沒 setup 過的手機按下去，按鈕會照實說：

```
這台電腦上沒有這支手機（work）—— 先在這台電腦跑一次 hangar setup
```

牆上的名字是 **hub 那台機器**取的，同一支手機在你的電腦上可以叫別的名字：
按鈕會連**序號**一起送，helper 優先用序號去對，對到了會告訴你它在這台電腦上
叫什麼。這跟 `hangar scan` 認人用的是同一套順序。

## 它會回答你，不是丟出去就算

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

## 三道鎖

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

## 按不動的時候

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

## 讓 helper 開機就自己跑

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

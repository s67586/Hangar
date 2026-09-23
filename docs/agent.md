# 手機端 agent

`hangar scan` 看得到區網上有哪些裝置，但**沒開偵錯的手機 adb 完全碰不到** ——
拿得到 IP、MAC、廠商，拿不到機型，更拿不到電量。唯一的破口是在手機裡放一支
常駐的 app：它自己回報，不需要 adb。

程式在 [`agent/`](../agent/)，協定寫在 [ROADMAP](../ROADMAP.md) 的「M3 協定」。

## 入伍：一次性 ADB（USB 或網路）

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

**一台手機只入伍一次。** 已經入伍過的會直接拒絕；要重來得先清掉手機上的入伍
狀態，而那需要 adb。理由見 [agent/README.md](../agent/README.md)，這台電腦手上
沒有 token 時怎麼辦見 [`--takeover`](#接手一支已入伍的手機--takeover)。

## 升級舊版 agent：`--reinstall`

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
講清楚，不會假裝成功。那種情況要的是下一節的 `--takeover`。

## 接手一支已入伍的手機：`--takeover`

手機上那支 agent 還在、也還入伍著，但**這台電腦手上沒有它的 token**：

- 這裡的 profile 重建過（`AGENT_TOKEN` 是空的），或
- 這支手機本來就是別台電腦入伍的。

這種狀態以前是條死路：正規入伍會被手機端的 `already_enrolled` 擋下來，
`--reinstall` 又會說「沒有 token，沒辦法只換 APK」——兩邊都對，人卡在中間。
`hangar enroll --takeover` 就是那條出路：

```bash
hangar enroll -p work --takeover
```

```
 !! 接手會清掉手機上那支 agent 的入伍狀態
    其他也入伍過這支手機的電腦，手上的 token 會一起失效，要重新入伍才問得到它
    只是想換新版 APK 的話，要的是 --reinstall，不是這個
  確定要讓這台電腦接手「work」？輸入 yes ＞ yes

==> 1/6 安裝 agent
 ok  安裝完成
==> 2/6 清掉手機上的入伍狀態
 ok  手機上的入伍狀態已清掉
==> 3/6 授予 WRITE_SECURE_SETTINGS
 ok  已授予
==> 4/6 交出 profile 名字、裝置序號與 token
 ok  序號 R58M12345AB，token 已寫進 ~/.config/hangar/profiles/work.conf
==> 5/6 把 agent 叫起來
==> 6/6 驗證：直接問 agent
 ok  agent 0.1.2 回應正常
     機型  Pixel 7 Pro
     電量  78%  放電中  27.5°C

 ok  接手完成。這台電腦有自己的 token 了 —— 其他電腦要重新入伍才問得到這支手機。
```

幾件事值得先知道：

- **token 要不回來。** 它存在 app 的私有資料裡，adb 這一側讀不出來，所以沒有
  「把原本那組拿回來」這種選項，只有清掉重來。
- **代價是別台電腦。** `pm clear` 之後，其他也入伍過這支手機的電腦手上那組
  token 全部失效，而**這台電腦看不出來還有誰入伍過** —— 看不見的代價只能用問的，
  所以它會停下來要你打一次 `yes`。沒有終端機的時候（例如從 helper 執行）它不會
  自己點頭，而是要求把 `--yes` 明確打出來。
- **步驟順序是有理由的。** 先裝 APK 再清資料：簽章對不上這種失敗要發生在還沒
  破壞任何東西之前。清完才授權：`pm clear` 會把 `pm grant` 給過的權限一起收回去。
- **不要拿它當升級用。** 只是版本太舊的話，`--reinstall` 不會動 token，也就不會
  把別台電腦踢掉。

為什麼不在 agent 那一側做一個「重新入伍」廣播：`EnrollReceiver` 必須是 exported 的
（發廣播的是 shell uid），同一支手機上的任何 app 都發得出那個廣播。真有那條路，
等於誰都能把別人的手機搶走。門檻就是 `pm clear` 需要 adb —— 這條指令是走進那道門，
不是繞過它。

## 入伍之後有什麼不一樣

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

## 主動回報給 hub（跨網段）

平常是電腦端來問 agent。手機在另一個網段、hub 連不進去的時候，可以讓 agent 反過來
定期往 hub 送：

```bash
hangar enroll -p work --hub http://10.0.1.5:8789   # 新入伍或已入伍都可以
hangar enroll -p work --no-hub
```

- hub 那邊要帶 `--checkin`（見 [hub](hub.md#跨網段主動回報check-in)）。
- 已入伍的手機只發一個 `com.hangar.agent.SET_HUB` 廣播，不重裝、不換 token；
  廣播要帶 token，手機上其他 app 改不動它。舊版 agent 不認得這個廣播，先
  `--reinstall`（`--reinstall --hub …` 會一起做）。
- 回報是明文 HTTP，跟電腦端問 5599 一樣靠 token；所以 app 開了
  `usesCleartextTraffic`。
- 手機上打開 Hangar Agent 看得到回報對象、上次成功的時間與最近的錯誤。

## 限制

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

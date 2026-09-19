# Hangar Agent

手機端的常駐 app。它存在的理由跟整份 [ROADMAP](../ROADMAP.md) 的「關鍵結論」一樣：
**沒開偵錯模式的手機，adb 完全碰不到**，只有一支住在手機裡的 app 才回報得了
電量與裝置資訊，也才有機會把偵錯開關切回來。

協定寫在 [ROADMAP 的「M3 協定」](../ROADMAP.md)，那份是準的；這裡只講怎麼蓋、
怎麼裝。

## 現在做到哪

| | |
|---|---|
| `GET /hangar/v1/hello` | 好了（不需要 token，掃描靠它認人） |
| `GET /hangar/v1/status` | 好了（電量、機型、Android 版本、偵錯開關現況、能力宣告） |
| 入伍（收序號與 token） | 好了 |
| 重開機後自己起來 | 程式寫好了，**但還沒在實機上驗過重開機那一段**（把無線偵錯打開是 M3c，還沒做） |
| `POST /hangar/v1/adb` 切偵錯 | 還沒（M4），現在回 501 |
| mDNS 廣播 | 還沒（M3b） |
| `hangar enroll` | 好了 —— 電腦那一側接上了（實機跑過），下面那段手動流程留著當參考 |

## 蓋起來

```bash
cd agent
./gradlew assembleDebug      # 產物在 app/build/outputs/apk/debug/
```

**wrapper 進版控了**（`gradlew`、`gradlew.bat`、`gradle/wrapper/`）。這推翻了這份
文件原本寫的「wrapper 不進版控，因為 `gradle-wrapper.jar` 是二進位檔」—— 換成
現在這樣的理由：

- **CI 需要它。** 不進版控的話，CI 得先自己裝一套 gradle 再 `gradle wrapper`，
  於是「用哪個 Gradle 版本蓋的」由 runner 映像當下裝了什麼決定，跟本機不一樣。
  wrapper 的存在意義就是消掉這個差異，不進版控等於白放。
- **代價很小。** 那個 jar 是 43 KB，而且只有換 Gradle 版本時才會動。
- Gradle 官方本來也是建議整份 wrapper 一起進版控的。

所以現在 clone 下來就能直接 `./gradlew`，不需要先裝 gradle。指定的版本寫在
`gradle/wrapper/gradle-wrapper.properties`（目前 8.5，搭 AGP 8.2.2）。

> 還沒做：`distributionSha256Sum`。有它才擋得住「下載回來的發佈檔被換掉」。
> 要補的話在有網路的機器上跑
> `curl -sSL https://services.gradle.org/distributions/gradle-8.5-bin.zip.sha256`
> 再把值填進 `gradle-wrapper.properties`。

**`./gradlew assembleDebug` 通不通由 CI 回答** —— 見 `.github/workflows/agent.yml`，
每個 PR 與每次進 `main` 都會建一次，並把 APK 留成可下載的 artifact。要讓一支新
手機入伍時，可以直接去那裡抓，不必先在自己機器上裝好整套 Android 工具鏈。

需要 JDK 17 與 Android SDK（compileSdk 34）。`local.properties` 也不進版控，
Android Studio 會自己寫；用指令列的話：

```bash
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
```

## 裝到手機上（`hangar enroll` 幫你做完的那幾步）

平常用 `hangar enroll -p <手機>` 就好。下面是它實際做的事，出問題時用得上：

```bash
# 1. 裝
adb install -r app/build/outputs/apk/debug/app-debug.apk

# 2. 授權。這一步就是整套的破口：一次性授予，重開機後仍然有效
adb shell pm grant com.hangar.agent android.permission.WRITE_SECURE_SETTINGS

# 3. 入伍：把裝置序號與一組 token 交給它
SERIAL="$(adb shell getprop ro.serialno | tr -d '\r\n')"
TOKEN="$(openssl rand -hex 32)"
adb shell am broadcast -n com.hangar.agent/.EnrollReceiver \
  -a com.hangar.agent.ENROLL --es serial "$SERIAL" --es token "$TOKEN"
#    → 印出 result=0, data="enrolled" 才算成功

# 4. 驗證（手機要跟電腦在同一個區網）
IP=<手機的區網 IP>
curl -s "http://$IP:5599/hangar/v1/hello"
curl -s -H "Authorization: Bearer $TOKEN" "http://$IP:5599/hangar/v1/status"
```

把那組 `TOKEN` 記下來 —— `hangar` 之後會把它存在 profile 裡。

**一台手機只入伍一次。** `EnrollReceiver` 必須是 exported 的（發廣播的是 shell
uid，不是這支 app 自己），所以同一支手機上的其他 app 也發得出那個廣播。擋法是
「第一次入伍者得之」：已經有 token 之後一律拒收，要重來得先

```bash
adb shell pm clear com.hangar.agent
```

而那本來就需要 adb，也就是需要已經有人實體碰過這支手機。

## 設計上的幾個決定

- **零外部相依，連 AndroidX 都沒有。** 三個端點、全部回 JSON，用得到的東西
  framework 都有（`java.net.ServerSocket`、`org.json`）。跟 `hangar` 是一支無相依
  bash script、hub 只用 Python 標準函式庫是同一個理由。
- **序號與 token 都是電腦端給的**，不是 app 自己去問系統的。Android 10 以上一般
  app 拿不到 `ro.serialno`；而入伍那一刻 adb 就在旁邊，那邊拿得到。兩邊用同一個
  字串，hub 才能把三份資料合成同一張卡。
- **前景服務**，因為 M4 把偵錯關掉之後，這個 HTTP 端點是唯一回得去的路。被系統
  回收 = 那支手機失聯。各家 ROM 的省電策略能不能扛住是 ROADMAP 裡的待實測項目。
- **比對 token 時逐字元比完才回傳**，不在第一個不同的字元就 return —— 那會把
  答案洩漏在回應時間裡。

## 測試

協定的一致性測試在 repo 根目錄：

```bash
tests/test_agent_protocol.sh
```

預設跑的是 `tests/agentbin/fake_agent.py`（同一份協定的 Python 參考實作）。
裝到真的手機之後，同一份測試可以直接打過去：

```bash
HANGAR_AGENT_URL=http://192.168.1.77:5599 HANGAR_AGENT_TOKEN=<token> \
  tests/test_agent_protocol.sh
```

**兩份實作對不起來的地方，就是協定沒講清楚的地方。**

## 這份程式碼被驗證到什麼程度

誠實講：

| | |
|---|---|
| Kotlin 編譯 | **過了**（`kotlinc` 對著 `android.jar` 編，7 個檔） |
| AndroidManifest | **過了**（`aapt2 link` 通過，權限與元件都在） |
| 協定 | **過了** —— 同一份測試打真的 agent，25/25 |
| 裝到手機上跑起來 | **過了** —— Pixel 4 / Android 13 |
| `WRITE_SECURE_SETTINGS` | **拿得到** —— `pm grant` 之後 `granted=true` |
| Gradle 真的產出 APK | **過了** —— CI 上 `./gradlew assembleDebug` 一次就成功，812 KB 的 `app-debug.apk`，`aapt2` 認得 `com.hangar.agent` v0.1.0 |

實機那一輪的 APK 是用 SDK 內建工具手動組的（`kotlinc` → `d8` → `aapt2 link`
→ `apksigner`），因為那台機器上沒有完整的 gradle distribution。那條路證明的是
「程式本身跑得起來」。

`./gradlew assembleDebug` 現在也確認過了（CI 上一次就成功）。這兩條路不是同一件事
重複驗兩次 —— **Gradle 會多跑一個 manifest merger，手動那條的 `aapt2 link` 根本
不經過它**。所以真正新拿到的資訊是：`foregroundServiceType="specialUse"` 跟它底下
那個 `<property>` 標籤（`PROPERTY_SPECIAL_USE_FGS_SUBTYPE`）過得了 merger。那是兩條
路最可能分岔的地方，現在不用擔心了。

實機上踩到的一件事已經修進程式裡了：**Android 12+ 不准 app 從背景啟動前景
服務**。入伍廣播裡呼叫 `startForegroundService()` 會丟
`ForegroundServiceStartNotAllowedException`，而且沒接住的話整支 app 當場崩潰。
現在 `AgentService.start()` 會回傳成功與否而不是拋例外，`hangar enroll` 則在
發完廣播之後多一步 `am start` 把 app 叫到前景 —— 那條路徑是被允許的，而且入伍
流程手上本來就有 adb，不需要任何人碰手機。

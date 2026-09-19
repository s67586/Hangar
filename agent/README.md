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
| 重開機後自己起來 | 好了（服務會回來；**把無線偵錯打開是 M3c，還沒做**） |
| `POST /hangar/v1/adb` 切偵錯 | 還沒（M4），現在回 501 |
| mDNS 廣播 | 還沒（M3b） |
| `hangar setup --enroll` | 還沒 —— 電腦那一側還沒接，現在要手動下指令（見下面） |

## 蓋起來

```bash
cd agent
./gradlew assembleDebug      # 產物在 app/build/outputs/apk/debug/
```

**wrapper 沒有進版控**（`gradle-wrapper.jar` 是二進位檔）。第一次要自己生一份：

```bash
gradle wrapper --gradle-version 8.5 --distribution-type bin
```

沒有 `gradle` 指令的話，用 Android Studio 開 `agent/` 這個資料夾，它會自己補上。

需要 JDK 17 與 Android SDK（compileSdk 34）。`local.properties` 也不進版控，
Android Studio 會自己寫；用指令列的話：

```bash
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
```

## 裝到手機上（在 `hangar setup --enroll` 做好之前的手動流程）

手機插 USB、開著 USB 偵錯，然後：

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
| 協定 | **過了**，但驗的是 Python 參考實作，不是這支 app |
| Gradle 真的產出 APK | **沒驗過** —— 這台機器上沒有完整的 gradle distribution |
| 裝到手機上跑起來 | **沒驗過** —— 沒有實機 |

所以第一次 `./gradlew assembleDebug` 有可能還要修一兩個 Gradle 層面的東西。
程式邏輯本身是編譯過的。

# 機房放公司 APK 的注意事項

**Hangar 本身不會把公司 APK 帶出去** —— agent 不碰別的 app，hub 與裝置牆也不經手
APK。真正的暴露面是：**沒加固的 APK，放在一群人都有 adb 權限的共用手機上**。
這份整理的是那個情境下要守的事。

一句話版本：**測試版裡只放測試環境的金鑰，並且假設它會被看光。**

## adb 能拿走什麼

手機對每一台授權過的電腦（各自的 `~/.android/adbkey`）是完全敞開的。
以下都**不需要 root**，也跟 agent 無關，是 adb 本來的能力：

```bash
# 把任何一支已安裝的 app 拉回來
adb shell pm path com.example.app          # → package:/data/app/.../base.apk
adb pull /data/app/.../base.apk

# debuggable 的 build：直接讀它的私有資料
adb shell run-as com.example.app ls shared_prefs databases
adb shell run-as com.example.app cat shared_prefs/<檔名>.xml

# log：debug 版常把 API 回應、token 印出來
adb logcat
```

沒加固的 APK 拉回去之後，用 jadx 之類的工具打開就接近原始碼 —— 寫死的金鑰、
API 端點、測試後門都看得到。

Hangar 放大的是**人數**：[多台電腦共用同一支手機](multi-host.md)會讓授權過的電腦
越來越多，常開偵錯也讓這些能力隨時可用。

## 5555 開著時

`adb tcpip 5555` 讓 adbd 在所有介面上聽（見 [Tailscale ACL](tailscale.md)）。
沒授權過的電腦連進來，手機會跳授權框，所以光靠這個 port 還進不來。要注意的是：

- **授權框被人順手按了「允許」**，那台電腦就永久取得授權。機房裡沒人在看的手機
  跳出授權框，不要隨手按
- 走 Tailscale 時一定要設 ACL，否則整個 tailnet 都連得到

確認測試機不是「連線免授權」的系統版本：

```bash
adb shell getprop ro.adb.secure      # 要是 1
```

eng／userdebug 版的系統常是 `0`：任何連得到 5555 的人都不需要授權。這種機器只能
放在隔離的網段，並且要把「agent 的 token 被偷聽到」當成等同 adb 被拿走 ——
agent 的 5599 是明文 HTTP，token 在區網上看得到，而那組 token 可以
[切偵錯](agent.md)。

## 測試版與加固版分開對待

| | 沒加固的測試版 | 加固版／正式候選版 |
|---|---|---|
| 內含的金鑰、憑證、端點 | **只放測試環境的** | 正式環境的 |
| 偵錯 | 開著沒關係 | `hangar adb -p <手機> --off` 關掉再測 |
| `FLAG_SECURE` | 可以關（見[密碼頁面投影全黑](flag-secure.md)） | 必須開 |
| `android:debuggable` | 可以開 | 必須關 |
| log | 不印 token、個資 | 不印 token、個資 |

關於 `FLAG_SECURE`：debug build 關掉它是為了能投影，但那也表示那幾頁可以被
`scrcpy --record` 錄下來。確認判斷條件真的綁在 `BuildConfig.DEBUG`（或同等的
build type 判斷）上，不會漏進 release。

## 日常要做的事

- **正式環境的帳號不要登入測試機。** 機房的每支手機都當成共用的
- **定期清授權。** 有人離職、換電腦時，在手機「開發人員選項 → 撤銷 USB 偵錯授權」，
  需要的人再各自重新授權一次
- **不要複製 `adbkey`**，也不要把入伍過的 profile 隨手 `scp` 給別人 ——
  前者是整支手機的控制權，後者帶著 agent 的 token（見[多台電腦共用同一支手機](multi-host.md)）
- **手機離開機房前**（借出、送修、報廢）解除安裝公司 app，能重置就整支重置

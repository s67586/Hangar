# 密碼頁面投影全黑（FLAG_SECURE）

**這不是 Hangar 或 scrcpy 的問題，是 Android 系統層的設計。**

App 可以在視窗上加 `WindowManager.LayoutParams.FLAG_SECURE`，被標記的視窗會從
**所有**螢幕擷取管道中排除 —— 截圖、螢幕錄影、投影一律變黑。
鎖定畫面（keyguard）、銀行 / 支付 App、密碼管理器、Netflix 之類的 DRM 內容，
還有很多 App 的密碼輸入頁，都會加這個旗標。

## 先確認是不是這個原因

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

## 可行的做法

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

## 不會有用的做法

| 試過的做法 | 為什麼沒用 |
|---|---|
| 升級 scrcpy / 換版本 | 擷取是系統擋的，跟 scrcpy 無關 |
| `--video-codec` / 調 bitrate / 調解析度 | 送過來的畫面本來就是黑的 |
| scrcpy 3.x 的 `--new-display` 虛擬顯示器 | shell 權限開不出「secure display」，FLAG_SECURE 視窗一樣會被塗黑 |
| 改 Tailscale / adb 設定 | 跟傳輸層完全無關 |

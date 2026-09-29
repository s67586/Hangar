package com.hangar.agent

import android.content.Context
import android.os.Build
import android.provider.Settings

/**
 * 切換 Android 的偵錯：adb_enabled，關的時候連 adb_wifi_enabled 一起關。
 *
 * 這裡刻意沒有任何自動復原。偵錯是開是關由人決定，agent 只負責寫進去並回報。
 * 早期版本會在關閉後排一個鬧鐘把它開回來，但機房的常態就是「關著測加固版」——
 * 那個鬧鐘等於在一段長測的中途偷改條件，而且不會通知任何人。見 ROADMAP 的 M4。
 */
object AdbController {
    /** 寫不進去時丟 SecurityException，由 HTTP 層轉成明確的 403，而不是假裝成功。 */
    fun set(ctx: Context, enabled: Boolean) {
        val cr = ctx.applicationContext.contentResolver
        if (!enabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // 「關閉偵錯」要兩個一起關。USB 偵錯與無線偵錯是兩個開關，但共用同一個
            // adbd：無線偵錯開著，只關 USB 偵錯的話 adbd 照樣在跑，`adb tcpip` 開的
            // 5555 也還在 —— 按了「關閉」，網路上卻還連得進來（Pixel 8a 實測）。
            // 先關無線、再關 USB，adbd 才會真的停。
            // 開的時候只開 USB：adbd 會照著 service.adb.tcp.port 把 5555 開回來，
            // 無線偵錯（隨機埠、要配對）不是回得去的必要條件。
            if (!Settings.Global.putInt(cr, "adb_wifi_enabled", 0)) {
                throw SecurityException("Android 拒絕寫入 adb_wifi_enabled")
            }
        }
        AdbState.beforeWrite(ctx)
        val wrote = Settings.Global.putInt(cr, Settings.Global.ADB_ENABLED, if (enabled) 1 else 0)
        if (!wrote) throw SecurityException("Android 拒絕寫入 adb_enabled")
        AdbState.noteWrite(ctx, enabled)
    }
}

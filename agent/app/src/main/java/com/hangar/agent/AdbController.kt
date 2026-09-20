package com.hangar.agent

import android.content.Context
import android.provider.Settings

/**
 * 切換 Android 的 adb_enabled。
 *
 * 這裡刻意沒有任何自動復原。偵錯是開是關由人決定，agent 只負責寫進去並回報。
 * 早期版本會在關閉後排一個鬧鐘把它開回來，但機房的常態就是「關著測加固版」——
 * 那個鬧鐘等於在一段長測的中途偷改條件，而且不會通知任何人。見 ROADMAP 的 M4。
 */
object AdbController {
    /** 寫不進去時丟 SecurityException，由 HTTP 層轉成明確的 403，而不是假裝成功。 */
    fun set(ctx: Context, enabled: Boolean) {
        val wrote = Settings.Global.putInt(
            ctx.applicationContext.contentResolver,
            Settings.Global.ADB_ENABLED,
            if (enabled) 1 else 0,
        )
        if (!wrote) throw SecurityException("Android 拒絕寫入 adb_enabled")
    }
}

package com.hangar.agent

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.provider.Settings

/**
 * 切換 Android 的 adb_enabled，並保存「關掉後要自己開回來」的期限。
 *
 * 期限存的是 wall-clock 時間而不是 elapsed time：手機重開機後 elapsed clock 會歸零，
 * wall-clock 才能讓 BootReceiver 知道這個復原期限是否已經到了。AlarmManager 用的
 * 是同一個 wall-clock，因此 app 被暫停或服務被重建也不會遺失這個承諾。
 */
object AdbController {
    const val DEFAULT_REVERT_SECONDS = 30 * 60
    const val MAX_REVERT_SECONDS = 24 * 60 * 60
    const val ACTION_REVERT = "com.hangar.agent.REVERT_ADB"

    private const val PREFS = "hangar-agent-adb"
    private const val KEY_REVERT_AT = "revert_at_ms"
    private const val REQUEST_CODE = 3

    /** 切換後回傳實際採用的復原秒數；開啟偵錯時為 0。 */
    @Synchronized
    fun set(ctx: Context, enabled: Boolean, requestedRevertSeconds: Int?): Int {
        val app = ctx.applicationContext

        // WRITE_SECURE_SETTINGS 沒拿到時會丟 SecurityException，由 HTTP 層轉成
        // 明確的 403，而不是假裝切換成功。
        val wrote = Settings.Global.putInt(
            app.contentResolver,
            Settings.Global.ADB_ENABLED,
            if (enabled) 1 else 0,
        )
        if (!wrote) throw SecurityException("Android 拒絕寫入 adb_enabled")
        // 寫入成功後才取消舊鬧鐘；若 ROM 拒絕這次寫入，原本的自動復原承諾不能被
        // 一個失敗的切換請求順手弄丟。
        cancelAlarm(app)

        if (enabled) {
            prefs(app).edit().remove(KEY_REVERT_AT).apply()
            return 0
        }

        val seconds = (requestedRevertSeconds ?: DEFAULT_REVERT_SECONDS)
            .let { if (it <= 0) DEFAULT_REVERT_SECONDS else it }
            .coerceAtMost(MAX_REVERT_SECONDS)
        val at = System.currentTimeMillis() + seconds * 1000L
        prefs(app).edit().putLong(KEY_REVERT_AT, at).apply()
        schedule(app, at)
        return seconds
    }

    /** 服務／開機重建時補回 AlarmManager，期限已到就立刻開回。 */
    @Synchronized
    fun restore(ctx: Context) {
        val app = ctx.applicationContext
        val at = prefs(app).getLong(KEY_REVERT_AT, 0L)
        if (at <= 0L) return
        if (at <= System.currentTimeMillis()) {
            revert(app)
        } else {
            schedule(app, at)
        }
    }

    /** AlarmManager 到點後呼叫；尚未到點時重新排一次，避免提早觸發造成誤開。 */
    @Synchronized
    fun onAlarm(ctx: Context) {
        val app = ctx.applicationContext
        val at = prefs(app).getLong(KEY_REVERT_AT, 0L)
        if (at <= 0L) return
        if (at <= System.currentTimeMillis()) revert(app) else schedule(app, at)
    }

    private fun revert(ctx: Context) {
        try {
            if (!Settings.Global.putInt(ctx.contentResolver, Settings.Global.ADB_ENABLED, 1)) return
            prefs(ctx).edit().remove(KEY_REVERT_AT).apply()
            cancelAlarm(ctx)
        } catch (_: SecurityException) {
            // 權限若被 ROM 撤掉，不清期限；服務下次回來仍會再嘗試。
        }
    }

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun alarmIntent(ctx: Context): PendingIntent = PendingIntent.getBroadcast(
        ctx,
        REQUEST_CODE,
        Intent(ctx, AdbRevertReceiver::class.java).setAction(ACTION_REVERT),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun schedule(ctx: Context, at: Long) {
        val alarms = ctx.getSystemService(AlarmManager::class.java)
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, alarmIntent(ctx))
    }

    private fun cancelAlarm(ctx: Context) {
        val alarms = ctx.getSystemService(AlarmManager::class.java)
        alarms.cancel(alarmIntent(ctx))
    }
}

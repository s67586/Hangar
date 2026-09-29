package com.hangar.agent

import android.content.Context
import android.provider.Settings
import org.json.JSONObject

/**
 * 偵錯開關現在是開是關 —— 在讀不到真實值的機器上也要誠實地回答。
 *
 * Pixel 8a / Android 17 實測：一般 app 讀 adb_enabled 永遠是 0（getInt、getString、
 * 直接查 provider 都一樣），寫入卻有效。那種機器上 agent 能知道的只有「自己最後
 * 寫進去的是什麼」，以及「之後有沒有別人動過」（系統的設定變更通知）。
 *
 * 所以回報分三種來源：
 *
 *   settings     讀得準的機器：照讀
 *   agent_write  讀不準的機器：自己最後寫的，而且之後沒有別人動過
 *   unknown      讀不準，而且不知道（沒寫過，或寫完之後有人在手機上切過）
 *
 * 「讀不準」只靠證據判斷，不看 Android 版本號猜：寫了「開」、讀回來卻不是 1，
 * 就是讀不準。那一筆記下來，之後都算數。
 */
object AdbState {
    private const val PREFS = "hangar_adb_state"
    // 自己的寫入「在路上」最多算多久。不能用「寫完幾秒內的通知算自己的」：
    // Pixel 8a 實測通知晚了 3 秒多才到，會被誤判成有人在手機上切過。這一筆
    // 要有期限，因為寫入同一個值時系統不會送通知，它就永遠不會被銷掉
    private const val PENDING_MS = 15_000L

    /**
     * AdbController **寫入之前**叫：記一筆「接下來那個通知是我自己造成的」。
     * 一定要在寫之前 —— 通知走主執行緒，可能比寫完之後的記錄還早到。
     * commit 而不是 apply：主執行緒那邊要馬上讀得到。
     */
    fun beforeWrite(ctx: Context) {
        prefs(ctx).edit().putLong("self_pending_at", System.currentTimeMillis()).commit()
    }

    /** AdbController 寫完之後叫：記下寫了什麼，順便看讀不讀得準。 */
    fun noteWrite(ctx: Context, enabled: Boolean) {
        val e = prefs(ctx).edit()
            .putBoolean("last_written", enabled)
            .putLong("last_written_at", System.currentTimeMillis())
        if (enabled) {
            // 剛寫了 1：讀回來是 1 就是讀得準；不是 1 就是被遮住了
            e.putBoolean("masked", settingsValue(ctx) != 1)
        }
        e.apply()
    }

    /** 設定變更通知（AgentService 的 ContentObserver）進來時叫。 */
    fun noteChange(ctx: Context) {
        val p = prefs(ctx)
        val now = System.currentTimeMillis()
        val e = p.edit().putInt("changes_seen", p.getInt("changes_seen", 0) + 1)
        val pendingAt = p.getLong("self_pending_at", 0)
        if (pendingAt > 0 && now - pendingAt < PENDING_MS) {
            // 自己寫的那一筆到了：銷掉，下一個通知就不算自己的
            e.remove("self_pending_at")
        } else {
            // 不是自己寫的：有人在手機上（或用 adb）切過。自己記的那份就不能再信
            e.putLong("external_change_at", now)
        }
        e.commit()
    }

    /** /status 的 adb.enabled / adb.source / adb.readable。 */
    fun report(ctx: Context, into: JSONObject) {
        val p = prefs(ctx)
        val masked: Boolean? = if (p.contains("masked")) p.getBoolean("masked", false) else null
        into.put("readable", if (masked == null) JSONObject.NULL else !masked)
        if (masked != true) {
            val v = settingsValue(ctx)
            into.put("enabled", if (v == null) JSONObject.NULL else v == 1)
            into.put("source", "settings")
            return
        }
        val wroteAt = p.getLong("last_written_at", 0)
        val changedAt = p.getLong("external_change_at", 0)
        if (p.contains("last_written") && changedAt < wroteAt) {
            into.put("enabled", p.getBoolean("last_written", false))
            into.put("source", "agent_write")
        } else {
            into.put("enabled", JSONObject.NULL)
            into.put("source", "unknown")
        }
        into.put("changed_outside_at", if (changedAt > 0) changedAt / 1000 else JSONObject.NULL)
    }

    /** 觀察用：收到過幾次變更通知（驗證「遮蔽時通知還會不會來」）。 */
    fun changesSeen(ctx: Context): Int = prefs(ctx).getInt("changes_seen", 0)

    private fun settingsValue(ctx: Context): Int? = try {
        Settings.Global.getInt(ctx.contentResolver, Settings.Global.ADB_ENABLED)
    } catch (_: Settings.SettingNotFoundException) {
        null
    }

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

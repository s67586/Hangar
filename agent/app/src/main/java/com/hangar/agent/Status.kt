package com.hangar.agent

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import org.json.JSONObject

/**
 * `/hangar/v1/status` 的內容。
 *
 * 欄位名稱刻意跟 `hangar --json` 對齊（`device_serial`、`battery.level`、
 * `battery.status`…），hub 合併三份資料時才不用翻譯層。改這裡要同時改
 * ROADMAP 的「M3 協定」與 tests/test_agent_protocol.sh。
 */
object Status {

    fun canToggleAdb(ctx: Context): Boolean = hasSecureSettings(ctx)

    fun hello(ctx: Context): JSONObject = JSONObject().apply {
        put("schema", BuildConfig.PROTOCOL_SCHEMA)
        put("agent", "hangar-agent")
        put("version", BuildConfig.VERSION_NAME)
        // 沒入伍的手機也要答得出這一題：掃描要靠它認出「這是一支 agent」。
        // 但在入伍前不吐序號 —— 那是還沒建立信任時不必要的資訊。
        put("enrolled", Enrollment.isEnrolled(ctx))
    }

    fun status(ctx: Context): JSONObject {
        val o = JSONObject()
        o.put("schema", BuildConfig.PROTOCOL_SCHEMA)
        o.put("agent", JSONObject().apply {
            put("version", BuildConfig.VERSION_NAME)
            put("uptime_s", (System.currentTimeMillis() - AgentService.startedAt) / 1000)
        })
        o.put("device_serial", Enrollment.serial(ctx) ?: JSONObject.NULL)
        o.put("model", Build.MODEL)
        o.put("android", JSONObject().apply {
            put("release", Build.VERSION.RELEASE)
            put("sdk", Build.VERSION.SDK_INT)
        })
        o.put("battery", battery(ctx))
        o.put("adb", adb(ctx))
        o.put("can", JSONObject().apply {
            val granted = hasSecureSettings(ctx)
            put("toggle_adb", granted)
            // 無線偵錯是 Android 11（API 30）才有的東西。介面一致、能力不一致，
            // 比同一個端點在不同機器上行為不同好除錯。
            put("toggle_wifi_adb", granted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
            // 響鈴使用 framework 的 alarm stream / vibrator，不依賴 Android 版本上的
            // 特權設定；通知權限被使用者拒絕時仍有聲音與震動，所以能力仍宣告為 true。
            put("ring", true)
        })
        return o
    }

    private fun battery(ctx: Context): JSONObject {
        val i: Intent = ctx.applicationContext
            .registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return JSONObject()

        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val pct = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val temp = i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)

        return JSONObject().apply {
            put("level", if (pct >= 0) pct else JSONObject.NULL)
            // 字串用小寫，跟 hangar 從 dumpsys 取到的那一套一致
            put("status", when (i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
                BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
                BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
                BatteryManager.BATTERY_STATUS_FULL -> "full"
                BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not_charging"
                else -> JSONObject.NULL
            })
            put("temperature_c",
                if (temp != Int.MIN_VALUE) temp / 10.0 else JSONObject.NULL)
        }
    }

    private fun adb(ctx: Context): JSONObject = JSONObject().apply {
        put("enabled", globalInt(ctx, Settings.Global.ADB_ENABLED) == 1)
        // adb_wifi_enabled 在 Android 10 以下根本不存在，讀不到就回 null
        // —— 「關著」跟「這台機器沒有這個東西」是兩件事。
        val wifi = globalInt(ctx, "adb_wifi_enabled")
        put("wifi_enabled", if (wifi == null) JSONObject.NULL else wifi == 1)
        // 無線偵錯的埠是隨機的，而且一般 app 讀不到。M3c 要解的就是這個，
        // 在那之前誠實地回 null，讓電腦端退回用 mDNS 找。
        put("wifi_port", JSONObject.NULL)
    }

    private fun globalInt(ctx: Context, key: String): Int? = try {
        Settings.Global.getInt(ctx.contentResolver, key)
    } catch (e: Settings.SettingNotFoundException) {
        null
    }

    private fun hasSecureSettings(ctx: Context): Boolean =
        ctx.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED
}

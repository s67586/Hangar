package com.hangar.agent

import android.content.Context
import android.content.SharedPreferences

/**
 * 入伍狀態：序號與 token。
 *
 * 兩個都是**電腦端在入伍時給的**，不是這支 app 自己去問系統的：
 *
 *  - 序號：Android 10 以上一般 app 拿不到 `ro.serialno`（要 READ_PRIVILEGED_PHONE_STATE），
 *    但入伍那一刻 adb 就在旁邊，那邊拿得到。兩邊用同一個字串，hub 才能把
 *    agent、`hangar list`、`hangar scan` 三份資料合成同一張卡。
 *  - token：由電腦端產生。那時候 adb 通道已經是信任的；反過來讓 app 產生再由
 *    電腦去讀，會多出一個「誰先信任誰」的問題。
 */
object Enrollment {
    private const val PREFS = "hangar-agent"
    private const val KEY_SERIAL = "device_serial"
    private const val KEY_TOKEN = "token"
    private const val KEY_AT = "enrolled_at"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isEnrolled(ctx: Context): Boolean = !token(ctx).isNullOrEmpty()

    fun serial(ctx: Context): String? = prefs(ctx).getString(KEY_SERIAL, null)

    fun token(ctx: Context): String? = prefs(ctx).getString(KEY_TOKEN, null)

    fun enrolledAt(ctx: Context): Long = prefs(ctx).getLong(KEY_AT, 0L)

    /**
     * 寫入入伍資料。**第一次入伍者得之**：已經有 token 之後一律拒收。
     *
     * EnrollReceiver 必須是 exported 的（發廣播的是 adb shell，不是這支 app），
     * 也就是同一支手機上的其他 app 也發得出那個廣播。擋法就是這個：一台手機只
     * 入伍一次，要重來得先 `adb shell pm clear com.hangar.agent` —— 而那本來
     * 就需要 adb，也就是需要已經有人實體碰過這支手機。
     */
    fun enroll(ctx: Context, serial: String, token: String): Boolean {
        if (isEnrolled(ctx)) return false
        if (serial.isBlank() || token.isBlank()) return false
        prefs(ctx).edit()
            .putString(KEY_SERIAL, serial)
            .putString(KEY_TOKEN, token)
            .putLong(KEY_AT, System.currentTimeMillis())
            .apply()
        return true
    }

    /**
     * 比對 token。長度先對、再逐字元全部比完才回傳 —— 不要在第一個不同的字元
     * 就 return，那會把答案洩漏在回應時間裡。
     */
    fun tokenMatches(ctx: Context, given: String?): Boolean {
        val real = token(ctx) ?: return false
        if (given == null || given.length != real.length) return false
        var diff = 0
        for (i in real.indices) diff = diff or (real[i].code xor given[i].code)
        return diff == 0
    }
}

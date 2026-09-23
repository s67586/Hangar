package com.hangar.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 入伍，以及入伍後換回報對象。
 *
 * 入伍：電腦端在已授權的 ADB（USB 或網路）上發這個廣播：
 *
 *     adb shell am broadcast -n com.hangar.agent/.EnrollReceiver \
 *       -a com.hangar.agent.ENROLL --es serial "<ro.serialno>" \
 *       --es token "<隨機 token>" --es name "<profile>"
 *
 * 指定 component（-n）是因為 Android 8+ 擋隱式廣播。
 *
 * exported 是必要的（發的人是 shell uid，不是這支 app），所以同一支手機上的
 * 其他 app 也發得出來。擋法在 Enrollment.enroll()：第一次入伍者得之。
 *
 * 入伍時可以多帶 `--es hub "http://主機:埠"`：agent 會定期往那裡回報（跨網段、
 * 電腦端連不進手機時用）。已入伍的手機改回報對象用另一個 action，要帶 token：
 *
 *     adb shell am broadcast -n com.hangar.agent/.EnrollReceiver \
 *       -a com.hangar.agent.SET_HUB --es token "<token>" --es hub "<網址或空字串>"
 */
class EnrollReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            "com.hangar.agent.ENROLL" -> enroll(ctx, intent)
            "com.hangar.agent.SET_HUB" -> setHub(ctx, intent)
        }
    }

    private fun setHub(ctx: Context, intent: Intent) {
        val ok = Enrollment.setHub(
            ctx, intent.getStringExtra("token"), intent.getStringExtra("hub").orEmpty())
        resultCode = if (ok) 0 else 1
        resultData = when {
            ok -> "hub_set"
            !Enrollment.isEnrolled(ctx) -> "not_enrolled"
            !Enrollment.tokenMatches(ctx, intent.getStringExtra("token")) -> "unauthorized"
            else -> "bad_request"
        }
        Log.i("hangar-agent", "set hub: $resultData")
        // 服務在跑的話馬上用新的對象回報一次，不必等下一輪
        if (ok) CheckinReporter.kick()
    }

    private fun enroll(ctx: Context, intent: Intent) {
        val serial = intent.getStringExtra("serial").orEmpty()
        val token = intent.getStringExtra("token").orEmpty()
        val name = intent.getStringExtra("name").orEmpty()
        val hub = intent.getStringExtra("hub").orEmpty()

        val ok = Enrollment.enroll(ctx, serial, token, name, hub)
        // 用 setResultCode 回報結果：adb shell am broadcast 會把它印出來，
        // 電腦端那一側就看得到「到底有沒有成功」，不用靠猜。
        resultCode = if (ok) 0 else 1
        resultData = if (ok) "enrolled" else
            if (Enrollment.isEnrolled(ctx)) "already_enrolled" else "bad_request"
        Log.i("hangar-agent", "enroll: $resultData")

        // 服務這時候多半叫不起來（Android 12+ 擋背景啟動前景服務），那不是錯誤：
        // 入伍資料已經寫好了，電腦端接著會用 am start 把 app 叫到前景，
        // 那條路徑才是被允許的。
        if (ok && !AgentService.start(ctx)) {
            Log.i("hangar-agent", "入伍完成，但服務要等 app 被打開才起得來")
        }
        if (ok) CheckinReporter.kick()
    }
}

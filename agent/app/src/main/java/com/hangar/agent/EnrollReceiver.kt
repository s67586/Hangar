package com.hangar.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 入伍。電腦端在那唯一一次 USB 上發這個廣播：
 *
 *     adb shell am broadcast -n com.hangar.agent/.EnrollReceiver \
 *       -a com.hangar.agent.ENROLL --es serial "<ro.serialno>" --es token "<隨機 token>"
 *
 * 指定 component（-n）是因為 Android 8+ 擋隱式廣播。
 *
 * exported 是必要的（發的人是 shell uid，不是這支 app），所以同一支手機上的
 * 其他 app 也發得出來。擋法在 Enrollment.enroll()：第一次入伍者得之。
 */
class EnrollReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != "com.hangar.agent.ENROLL") return
        val serial = intent.getStringExtra("serial").orEmpty()
        val token = intent.getStringExtra("token").orEmpty()

        val ok = Enrollment.enroll(ctx, serial, token)
        // 用 setResultCode 回報結果：adb shell am broadcast 會把它印出來，
        // 電腦端那一側就看得到「到底有沒有成功」，不用靠猜。
        resultCode = if (ok) 0 else 1
        resultData = if (ok) "enrolled" else
            if (Enrollment.isEnrolled(ctx)) "already_enrolled" else "bad_request"
        Log.i("hangar-agent", "enroll: $resultData")

        if (ok) AgentService.start(ctx)
    }
}

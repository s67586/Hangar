package com.hangar.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 重開機後把服務叫回來。
 *
 * 這是整支 agent 存在的理由之一：手機重開機後 5555 會消失，以前只能等人去插
 * USB。agent 自己回來之後，至少「看得到、知道電量」不會斷；把偵錯也開回來是
 * M3c 的事（而且只有 Android 11+ 做得到，見 ROADMAP 的 M3 協定）。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        // M4 若在關閉偵錯的倒數期間重開機，先把復原鬧鐘接回來；若期限已到，
        // restore() 會直接把偵錯開回來。
        AdbController.restore(ctx)
        // 沒入伍的手機也把服務起起來：/hello 要答得出來，掃描才看得到它在那裡。
        // BOOT_COMPLETED 是 Android 12+ 允許啟動前景服務的例外之一，但還是接住
        // 回傳值 —— 各家 ROM 的省電策略不保證照規格走。
        if (!AgentService.start(ctx)) {
            Log.w("hangar-agent", "開機後服務起不來，要等有人打開 app")
        }
    }
}

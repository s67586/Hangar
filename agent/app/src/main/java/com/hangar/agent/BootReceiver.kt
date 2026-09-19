package com.hangar.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

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
        // 沒入伍的手機也把服務起起來：/hello 要答得出來，掃描才看得到它在那裡
        AgentService.start(ctx)
    }
}

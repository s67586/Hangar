package com.hangar.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** notification 上「找到了」按鈕的明確停止動作。 */
class RingerActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Ringer.ACTION_STOP) Ringer.stop(ctx)
    }
}

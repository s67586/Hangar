package com.hangar.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** M4 關閉偵錯後的自動復原鬧鐘。 */
class AdbRevertReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == AdbController.ACTION_REVERT) AdbController.onAlarm(ctx)
    }
}

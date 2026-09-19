package com.hangar.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * 常駐的前景服務：把 HTTP server 撐著。
 *
 * 為什麼一定要前景服務：M4 把偵錯關掉之後，這個 HTTP 端點是唯一回得去的路。
 * 背景服務被系統回收 = 那支手機失聯，要人拿著它處理。前景服務不保證萬無一失
 * （各家 ROM 的省電策略還是可能殺掉它，那是 ROADMAP 裡列的待實測項目），
 * 但那是框架給的最強保證。
 */
class AgentService : Service() {

    companion object {
        const val CHANNEL = "hangar-agent"
        const val NOTIFICATION_ID = 1
        /** 給 /status 的 uptime 用。服務重啟就重新算，那正是想知道的事。 */
        @Volatile var startedAt: Long = System.currentTimeMillis()

        fun start(ctx: Context) {
            val i = Intent(ctx, AgentService::class.java)
            ctx.startForegroundService(i)
        }
    }

    private var server: HttpServer? = null

    override fun onCreate() {
        super.onCreate()
        startedAt = System.currentTimeMillis()
        startForeground(NOTIFICATION_ID, notification())
        server = HttpServer(this).also { it.start() }
    }

    // 被系統殺掉之後要自己回來
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        server?.stop()
        server = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Hangar Agent", NotificationManager.IMPORTANCE_MIN)
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val state = if (Enrollment.isEnrolled(this)) "已入伍" else "尚未入伍"
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("Hangar Agent")
            .setContentText("$state ・ 連接埠 ${HttpServer.PORT}")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}

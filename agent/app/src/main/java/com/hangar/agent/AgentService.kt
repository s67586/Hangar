package com.hangar.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log

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

        /**
         * 把服務叫起來。回傳有沒有成功。
         *
         * Android 12+ 不准 app 從背景啟動前景服務（實機實測：從入伍廣播裡呼叫會丟
         * ForegroundServiceStartNotAllowedException，而且沒接住的話整支 app 當場
         * 崩潰）。這裡接住它 —— 叫不起來是一種要處理的狀況，不是當機的理由。
         * 真正把它叫起來的路徑是「有人打開這個 app」或「開機廣播」，那兩個才被允許。
         */
        fun start(ctx: Context): Boolean = try {
            ctx.startForegroundService(Intent(ctx, AgentService::class.java))
            true
        } catch (e: Exception) {
            Log.w("hangar-agent", "startForegroundService 被擋下來了", e)
            false
        }
    }

    private var server: HttpServer? = null
    private var mdns: MdnsBroadcast? = null

    override fun onCreate() {
        super.onCreate()
        startedAt = System.currentTimeMillis()
        startForeground(NOTIFICATION_ID, notification())
        server = HttpServer(this).also { it.start() }
        mdns = MdnsBroadcast(this).also { it.start() }
    }

    // 被系統殺掉之後要自己回來
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 入伍是在服務已經在跑的時候發生的（EnrollReceiver 寫完資料才把服務叫起來，
        // 而這時 onCreate 不會再跑一次）。廣播的內容跟著入伍狀態變 —— 未入伍時沒有
        // 序號可以放 —— 所以這裡重登記一次，讓 mDNS 上的資料跟實際狀態一致。
        mdns?.refresh()
        return START_STICKY
    }

    override fun onDestroy() {
        mdns?.stop()
        mdns = null
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
            .setSmallIcon(R.drawable.ic_stat_hangar)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}

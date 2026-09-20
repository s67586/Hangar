package com.hangar.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * 找手機用的短暫提示。
 *
 * 這裡刻意不改系統音量：音量是會留在手機上的持久狀態，app 若被 ROM 殺掉就
 * 沒有可靠的機會改回來。第一版只要求 alarm stream、震動，以及一則高優先度
 * notification；三者都在這支 app 自己的生命週期裡收得乾淨。
 */
object Ringer {
    const val MAX_SECONDS = 120
    const val CHANNEL = "hangar-ring"
    const val NOTIFICATION_ID = 2
    const val ACTION_STOP = "com.hangar.agent.STOP_RING"

    private val lock = Any()
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var timer: ScheduledFuture<*>? = null
    private var generation = 0L

    /** 開始或重新計時；回傳實際會響的秒數。0 代表停止。 */
    fun ring(ctx: Context, requestedSeconds: Int): Int {
        val seconds = requestedSeconds.coerceIn(0, MAX_SECONDS)
        val app = ctx.applicationContext
        synchronized(lock) {
            generation += 1
            val thisGeneration = generation
            stopLocked(app)
            if (seconds == 0) return 0

            playAlarm(app)
            vibrate(app)
            showNotification(app)
            timer = executor.schedule({
                synchronized(lock) {
                    if (generation == thisGeneration) {
                        stopLocked(app)
                    }
                }
            }, seconds.toLong(), TimeUnit.SECONDS)
        }
        return seconds
    }

    fun stop(ctx: Context) {
        synchronized(lock) {
            generation += 1
            stopLocked(ctx.applicationContext)
        }
    }

    private fun playAlarm(ctx: Context) {
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            val r = uri?.let { RingtoneManager.getRingtone(ctx, it) } ?: return
            // setStreamType 是這個功能的設計重點：不要跟著媒體音量走。
            @Suppress("DEPRECATION")
            r.setStreamType(AudioManager.STREAM_ALARM)
            r.isLooping = true
            r.play()
            ringtone = r
        } catch (_: Exception) {
            // 某些 ROM 沒有設定 alarm ringtone。通知與震動仍然提供識別訊號，
            // 不要因為音源拿不到就讓 HTTP 請求失敗或殺掉 agent。
            ringtone = null
        }
    }

    private fun vibrate(ctx: Context) {
        val v = ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        vibrator = v
        if (!v.hasVibrator()) return
        try {
            // 500ms 動、500ms 停，直到響鈴計時器收掉它。
            v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 500, 500), 0))
        } catch (_: SecurityException) {
            vibrator = null
        }
    }

    private fun showNotification(ctx: Context) {
        val manager = ctx.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL,
            "Hangar 找手機",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Hangar 響鈴時點亮螢幕並顯示停止按鈕"
            // 聲音由 alarm stream 控制；notification 只負責 heads-up 與點亮螢幕。
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)

        val stop = PendingIntent.getBroadcast(
            ctx,
            NOTIFICATION_ID,
            Intent(ctx, RingerActionReceiver::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_hangar)
            .setContentTitle("Hangar 找到了")
            .setContentText("這支手機正在響鈴，找到後可以按下面停止")
            .setCategory(Notification.CATEGORY_ALARM)
            .setPriority(Notification.PRIORITY_HIGH)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(ctx, R.drawable.ic_stat_hangar),
                    "找到了",
                    stop,
                ).build(),
            )
            .build()
        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // Android 13 未授予通知權限時，alarm stream 與震動仍可工作。
        }
    }

    private fun stopLocked(ctx: Context) {
        timer?.cancel(false)
        timer = null
        try { ringtone?.stop() } catch (_: Exception) { /* 已經停止，忽略 */ }
        ringtone = null
        try { vibrator?.cancel() } catch (_: Exception) { /* 已經停止，忽略 */ }
        vibrator = null
        ctx.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }
}

package com.hangar.agent

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URL
import java.nio.charset.StandardCharsets
import org.json.JSONObject

/**
 * 主動回報：定期把 /status 那一份 POST 到 `<hub>/api/checkin`。
 *
 * 平常是電腦端來問（hub → hangar → 5599），agent 不需要知道 hub 在哪。但跨網段
 * 時那條路常常不通：路由器後面的手機掃不到，防火牆也可能只放「手機 → 伺服器」
 * 那一個方向。反方向通的時候，靠這個讓 hub 知道「它還活著、現在在哪個位址」。
 *
 * 沒入伍或沒設 hub 就什麼都不做 —— 這是入伍時選擇打開的功能，不是預設行為。
 *
 * 節奏：hub 回的 next_s（預設 60 秒）；失敗就指數退避到 5 分鐘；網路一換
 * （換 Wi-Fi、換 IP）馬上送一次，那正是 hub 最需要知道的時候。
 */
class CheckinReporter(private val ctx: Context) {
    companion object {
        private const val TAG = "hangar-agent"
        private const val DEFAULT_NEXT_S = 60L
        private const val MAX_BACKOFF_S = 300L
        private const val TIMEOUT_MS = 5_000

        @Volatile private var current: CheckinReporter? = null

        /** 入伍或換 hub 之後叫一聲：不必等到下一輪。服務沒在跑就算了。 */
        fun kick() {
            current?.wake()
        }
    }

    private val lock = Object()
    @Volatile private var running = false
    @Volatile private var woken = false
    private var thread: Thread? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun start() {
        if (running) return
        running = true
        current = this
        thread = Thread({ loop() }, "hangar-checkin").also { it.start() }
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = wake()
            override fun onLinkPropertiesChanged(
                network: Network, lp: android.net.LinkProperties,
            ) = wake()
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            callback = cb
        } catch (e: RuntimeException) {
            // 註冊不到就只剩定時回報，不是致命的
            Log.w(TAG, "registerDefaultNetworkCallback failed", e)
        }
    }

    fun stop() {
        running = false
        if (current === this) current = null
        callback?.let {
            try {
                ctx.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (_: RuntimeException) { /* 收工，忽略 */ }
        }
        callback = null
        wake()
    }

    fun wake() {
        synchronized(lock) {
            woken = true
            lock.notifyAll()
        }
    }

    private fun loop() {
        var backoff = 0L
        while (running) {
            val next = try {
                val r = once()
                backoff = 0
                r
            } catch (e: Exception) {
                // 一次失敗不准讓這條執行緒死掉：它一死，hub 那邊的卡片會安靜地
                // 變舊，而手機這邊什麼跡象都沒有
                Log.w(TAG, "check-in failed: ${e.message}")
                Enrollment.recordCheckin(ctx, e.message ?: e.javaClass.simpleName)
                backoff = if (backoff == 0L) 15 else (backoff * 2).coerceAtMost(MAX_BACKOFF_S)
                backoff
            }
            synchronized(lock) {
                if (!woken && running) lock.wait(next * 1000)
                woken = false
            }
        }
    }

    /** 送一次 → 下次幾秒後再送。沒設定就回預設值（等著被 kick 叫醒）。 */
    private fun once(): Long {
        val hub = Enrollment.hub(ctx)
        val token = Enrollment.token(ctx)
        if (hub == null || token.isNullOrEmpty()) return DEFAULT_NEXT_S

        val body = Status.checkin(ctx, ipv4s()).toString().toByteArray(StandardCharsets.UTF_8)
        val conn = URL("$hub/api/checkin").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = TIMEOUT_MS
            conn.readTimeout = TIMEOUT_MS
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.setFixedLengthStreamingMode(body.size)
            conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            val text = try {
                (if (code < 400) conn.inputStream else conn.errorStream)
                    ?.use { String(it.readBytes(), StandardCharsets.UTF_8) }.orEmpty()
            } catch (_: IOException) {
                ""
            }
            val json = try { JSONObject(text) } catch (_: Exception) { JSONObject() }
            val next = json.optLong("next_s", DEFAULT_NEXT_S).coerceIn(10, MAX_BACKOFF_S)
            when (code) {
                200 -> Enrollment.recordCheckin(ctx, null)
                // 太快了：照 hub 說的等，不算錯
                429 -> {}
                else -> throw IOException(
                    "HTTP $code ${json.optString("error").ifEmpty { "" }}".trim())
            }
            return next
        } finally {
            conn.disconnect()
        }
    }

    /** 這支手機現在所有的 IPv4（不含 loopback）。hub 拿它來對 profile 的 IP。 */
    private fun ipv4s(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .mapNotNull { it.hostAddress }
            .distinct()
    } catch (_: Exception) {
        emptyList()
    }
}

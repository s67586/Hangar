package com.hangar.agent

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log

/**
 * 用 mDNS 把自己廣播出去。
 *
 * 為什麼要有這個：沒有它的話，`hangar scan` 要對整個 /24 每一台各探一次 5599 才
 * 知道哪幾台有 agent。有了它，電腦端一次多播就問得到，而且 TXT 裡直接帶著序號
 * —— 那是 hub 把 scan、list、agent 三份資料合成同一張卡的主鍵。
 *
 * **但它只是加速器，不是必要條件。** AP 開了 client isolation 會擋掉多播，各家
 * ROM 的 NsdManager 穩定度也不一。所以電腦端的規矩是「問不到就退回逐台探 5599」
 * ——這支廣播失敗時，整套功能只是變慢，不會不見。也因此這裡所有的錯誤都只記
 * log，不影響服務本身。
 *
 * TXT 裡**沒有也不可以有 token**：mDNS 是整個區網都聽得到的明文廣播。序號放得
 * 進去是因為電腦端本來就要靠它認人，而且知道序號並不能拿來存取這支 agent。
 *
 * 機型裡的空白編成 `+`（`Pixel 7 Pro` → `Pixel+7+Pro`）。TXT 在 avahi-browse 與
 * dns-sd 的輸出裡是用空白分隔的一串 `鍵=值`，值裡直接放空白會把電腦端的解析拆壞。
 * 對應的解碼在 `hangar` 的 `scan_mdns_txt_get`。
 */
class MdnsBroadcast(private val ctx: Context) {

    companion object {
        /** 跟 ROADMAP「M3 協定」與 hangar 的 MDNS_SERVICE 必須一致 */
        const val SERVICE_TYPE = "_hangar-agent._tcp"
        private const val TAG = "hangar-agent"
    }

    private var nsd: NsdManager? = null
    private var listener: NsdManager.RegistrationListener? = null

    fun start() {
        if (listener != null) return
        val serial = Enrollment.serial(ctx)
        val info = NsdServiceInfo().apply {
            // 實例名：hangar-<序號後六碼>。還沒入伍就沒有序號可用 —— 那時仍然要
            // 廣播（「這裡有一支還沒入伍的 agent」本身就是有用的資訊），名字退回
            // 通用的那個，同名衝突由 NsdManager 自己加後綴處理。
            serviceName =
                if (serial.isNullOrBlank()) "hangar-agent"
                else "hangar-" + serial.takeLast(6)
            serviceType = SERVICE_TYPE
            port = HttpServer.PORT
            setAttribute("v", "1")
            if (!serial.isNullOrBlank()) setAttribute("serial", serial)
            setAttribute("model", Build.MODEL.replace(' ', '+'))
        }

        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "mDNS 登記成功：${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "mDNS 登記失敗（errorCode=$errorCode）—— 電腦端會退回探 $SERVICE_TYPE 的埠")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "mDNS 已撤銷登記")
            }
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "mDNS 撤銷登記失敗（errorCode=$errorCode）")
            }
        }

        try {
            nsd = ctx.getSystemService(NsdManager::class.java)
            nsd?.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
            listener = l
        } catch (e: Exception) {
            // 拿不到 NsdManager、或這台機器的實作直接丟例外 —— 都不該讓服務起不來
            Log.w(TAG, "mDNS 起不來，改由電腦端逐台探埠", e)
            nsd = null
            listener = null
        }
    }

    /**
     * 重新登記一次。入伍會改變要廣播的內容（未入伍時沒有序號，入伍後才有），
     * 而那時服務通常已經在跑了 —— onCreate 不會再跑一次，所以要有這條路。
     */
    fun refresh() {
        stop()
        start()
    }

    fun stop() {
        val l = listener ?: return
        listener = null
        try {
            nsd?.unregisterService(l)
        } catch (e: Exception) {
            Log.w(TAG, "mDNS 撤銷登記時出錯", e)
        }
        nsd = null
    }
}

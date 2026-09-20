package com.hangar.agent

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 一頁純文字的狀態畫面。
 *
 * 這支 app 平常沒有人會開 —— 它存在的意義是讓實際拿著手機的人看得出「這台在
 * Hangar 的管理下、入伍了沒、埠是幾號」，以及在出事時有個地方可以看。
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Android 13+ 要使用者同意才顯示得出前景服務的通知。沒有通知不影響
        // 服務本身，但那條通知是現場的人唯一看得到的線索，值得要一次。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }

        AgentService.start(this)

        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad)
            gravity = Gravity.START
        }
        val profileName = Enrollment.name(this)
        if (Enrollment.isEnrolled(this) && !profileName.isNullOrBlank()) {
            root.addView(TextView(this).apply {
                textSize = 30f
                text = profileName
                setPadding(0, 0, 0, pad / 2)
            })
        }
        root.addView(TextView(this).apply {
            textSize = 22f
            text = "Hangar Agent ${BuildConfig.VERSION_NAME}"
        })
        root.addView(TextView(this).apply {
            textSize = 15f
            setPadding(0, pad, 0, 0)
            text = body()
        })
        setContentView(root)
    }

    private fun body(): String {
        val enrolled = Enrollment.isEnrolled(this)
        val granted = checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED
        return buildString {
            append("狀態：").append(if (enrolled) "已入伍" else "尚未入伍").append('\n')
            append("序號：").append(Enrollment.serial(this@MainActivity) ?: "（入伍時由電腦寫入）").append('\n')
            append("連接埠：").append(HttpServer.PORT).append('\n')
            append("切偵錯的權限：").append(if (granted) "已授予" else "沒有").append("\n\n")
            if (!enrolled || !granted) {
                append("在已設定這支手機的電腦上執行（USB 或網路 ADB）：\n\n")
                append("  hangar enroll -p <profile>\n\n")
                append("它會裝好這支 app、授予 WRITE_SECURE_SETTINGS，\n")
                append("並把 profile 名字、裝置序號與 token 寫進來。\n")
            } else {
                append("這支手機已經在 Hangar 的管理下。\n")
                append("電腦端看得到它的電量與裝置資訊，\n")
                append("不需要開著 USB 偵錯也看得到。\n")
            }
        }
    }
}

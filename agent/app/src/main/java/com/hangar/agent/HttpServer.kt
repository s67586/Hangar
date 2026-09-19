package com.hangar.agent

import android.content.Context
import android.util.Log
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import org.json.JSONObject

/**
 * 一個只夠用的 HTTP server。
 *
 * 為什麼不拉一個 HTTP 函式庫進來：這支 app 總共三個端點、全部回 JSON，
 * 用得到的東西 `java.net` 都有。整個專案（hangar / hub / agent）維持零外部
 * 相依是刻意的 —— 一台測試機的常駐 app 不該為了三個端點背一套框架。
 *
 * 只聽 5599，一個連線一個執行緒（同時來的請求不會超過個位數，不需要更花俏的東西）。
 */
class HttpServer(
    private val ctx: Context,
    private val port: Int = PORT,
) {
    companion object {
        const val PORT = 5599
        private const val TAG = "hangar-agent"
        private const val MAX_HEADERS = 50
    }

    private var socket: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()
    @Volatile private var running = false

    fun start() {
        if (running) return
        running = true
        Thread({ accept() }, "hangar-http").start()
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (e: IOException) { /* 收工，忽略 */ }
        pool.shutdownNow()
    }

    private fun accept() {
        try {
            ServerSocket(port).use { server ->
                socket = server
                Log.i(TAG, "listening on :$port")
                while (running) {
                    val s = try {
                        server.accept()
                    } catch (e: SocketException) {
                        break            // stop() 關掉的
                    }
                    pool.execute { handleSafely(s) }
                }
            }
        } catch (e: IOException) {
            Log.e(TAG, "listen :$port failed", e)
        }
    }

    private fun handleSafely(s: Socket) {
        try {
            s.use { handle(it) }
        } catch (e: Exception) {
            // 一個壞掉的請求不該讓整支 agent 消失 —— 偵錯關掉之後，這個端點是
            // 唯一回得去的路。
            Log.w(TAG, "request failed", e)
        }
    }

    private fun handle(s: Socket) {
        s.soTimeout = 10_000
        val reader = BufferedReader(InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))

        val requestLine = reader.readLine() ?: return
        val parts = requestLine.split(" ")
        if (parts.size < 3) return respond(s, 400, err("bad_request", "看不懂的請求行"))
        val method = parts[0]
        val path = parts[1].substringBefore('?')

        var auth: String? = null
        var n = 0
        while (n++ < MAX_HEADERS) {
            val line = reader.readLine() ?: break
            if (line.isEmpty()) break
            val i = line.indexOf(':')
            if (i > 0 && line.substring(0, i).equals("Authorization", ignoreCase = true)) {
                auth = line.substring(i + 1).trim()
            }
        }
        val token = auth?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }?.substring(7)

        when {
            // 不需要 token：掃描要靠它認出「這是一支 agent」。回的東西也僅止於此。
            method == "GET" && path == "/hangar/v1/hello" ->
                respond(s, 200, Status.hello(ctx))

            method == "GET" && path == "/hangar/v1/status" -> {
                if (!Enrollment.isEnrolled(ctx))
                    respond(s, 409, err("not_enrolled", "這支手機還沒入伍"))
                else if (!Enrollment.tokenMatches(ctx, token))
                    respond(s, 401, err("unauthorized", "token 不對"))
                else
                    respond(s, 200, Status.status(ctx))
            }

            // M4 才實作。先把路徑佔住並明確說「還沒有」，比回 404 讓對方以為
            // 打錯網址好 —— 那會害人去查一個不存在的問題。
            path == "/hangar/v1/adb" ->
                respond(s, 501, err("not_implemented", "切偵錯是 M4 的事，還沒實作"))

            else -> respond(s, 404, err("not_found", "沒有這個端點：$path"))
        }
    }

    private fun err(code: String, message: String) = JSONObject().apply {
        put("schema", BuildConfig.PROTOCOL_SCHEMA)
        put("error", JSONObject().apply {
            put("code", code)
            put("message", message)
        })
    }

    private fun respond(s: Socket, status: Int, body: JSONObject) {
        val text = when (status) {
            200 -> "OK"; 400 -> "Bad Request"; 401 -> "Unauthorized"
            404 -> "Not Found"; 409 -> "Conflict"; 501 -> "Not Implemented"
            else -> "Error"
        }
        val bytes = body.toString().toByteArray(StandardCharsets.UTF_8)
        val head = buildString {
            append("HTTP/1.1 $status $text\r\n")
            append("Content-Type: application/json; charset=utf-8\r\n")
            append("Content-Length: ${bytes.size}\r\n")
            append("Cache-Control: no-store\r\n")
            append("Connection: close\r\n\r\n")
        }
        s.getOutputStream().apply {
            write(head.toByteArray(StandardCharsets.US_ASCII))
            write(bytes)
            flush()
        }
    }
}

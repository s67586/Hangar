#!/usr/bin/env python3
"""假的 hangar agent —— M3 協定的參考實作。

兩個用途：

  1. tests/test_agent_protocol.sh 拿它當對照組，把協定鎖住
  2. `hangar` 那一側要接 agent 時，沒有手機也能開發

它跟 agent/ 那支 Kotlin 是**兩份獨立的實作**，故意的：同一份協定被寫兩次，
對不起來的地方就是協定沒講清楚的地方。

    ./fake_agent.py --port 0 [--token abc] [--serial R58M...] [--not-enrolled]
"""

import argparse
import json
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    """跳過 server_bind 裡的反向 DNS。

    HTTPServer.server_bind() 會呼叫 socket.getfqdn()，那是一次反向 DNS 查詢。
    在反向解析不通或很慢的機器上（GitHub 的 macOS runner 就是這樣）它會一路卡到
    DNS 逾時，而啟動訊息是在它之後才印 —— 看起來就像服務起不來。server_name
    這個欄位我們從來沒用過，所以直接跳過它。
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


SCHEMA = 4
VERSION = "0.1.0-fake"
STARTED = time.time()


class Handler(BaseHTTPRequestHandler):
    cfg = None

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/hangar/v1/hello":
            # 不需要 token：掃描要靠它認出「這是一支 agent」。入伍前也答得出來。
            return self._json(200, {
                "schema": SCHEMA, "agent": "hangar-agent", "version": VERSION,
                "enrolled": self.cfg.enrolled,
            })
        if path == "/hangar/v1/status":
            if not self.cfg.enrolled:
                return self._json(409, self._err("not_enrolled", "這支手機還沒入伍"))
            if not self._token_ok():
                return self._json(401, self._err("unauthorized", "token 不對"))
            return self._json(200, self._status())
        return self._json(404, self._err("not_found", "沒有這個端點：%s" % path))

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/hangar/v1/ring", "/hangar/v1/adb"):
            return self._json(404, self._err("not_found", "沒有這個端點"))
        if not self.cfg.enrolled:
            return self._json(409, self._err("not_enrolled", "這支手機還沒入伍"))
        if not self._token_ok():
            return self._json(401, self._err("unauthorized", "token 不對"))
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n > 4096:
            return self._json(400, self._err("bad_request", "body 太大"))
        try:
            body = json.loads(self.rfile.read(max(n, 0)).decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return self._json(400, self._err("bad_request", "body 不是 JSON"))
        if not isinstance(body, dict):
            return self._json(400, self._err("bad_request", "body 必須是 JSON 物件"))
        if path.endswith("/ring"):
            seconds = body.get("seconds")
            if isinstance(seconds, bool) or not isinstance(seconds, int) or seconds < 0:
                return self._json(400, self._err("bad_request", "seconds 必須是非負整數"))
            actual = min(seconds, 120)
            self.cfg.ring_until = time.time() + actual if actual else 0
            return self._json(200, {"schema": SCHEMA, "ringing": actual > 0,
                                    "seconds": actual})
        enabled = body.get("enabled")
        if not isinstance(enabled, bool):
            return self._json(400, self._err("bad_request", "enabled 必須是布林值"))
        if body.get("revert_after_s") is not None:
            return self._json(400, self._err(
                "bad_request", "revert_after_s 已移除：偵錯狀態全手動"))
        self.cfg.adb_enabled = enabled
        return self._json(200, {"schema": SCHEMA, "enabled": enabled,
                                "adb": {"enabled": enabled, "wifi_enabled": False,
                                        "wifi_port": None}})

    def _token_ok(self):
        auth = self.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            return False
        return auth[7:] == self.cfg.token

    def _status(self):
        if getattr(self.cfg, "ring_until", 0) and time.time() >= self.cfg.ring_until:
            self.cfg.ring_until = 0
        return {
            "schema": SCHEMA,
            "agent": {"version": VERSION, "uptime_s": int(time.time() - STARTED)},
            "device_serial": self.cfg.serial,
            "model": "Fake Phone",
            "android": {"release": "14", "sdk": 34},
            "battery": {"level": 78, "status": "discharging", "temperature_c": 27.5},
            # wifi_port 是隨機的而且一般 app 讀不到 —— M3c 之前誠實回 null
            "adb": {"enabled": getattr(self.cfg, "adb_enabled", True),
                    "wifi_enabled": False, "wifi_port": None},
            "can": {"toggle_adb": True, "toggle_wifi_adb": True, "ring": True},
        }

    def _err(self, code, message):
        return {"schema": SCHEMA, "error": {"code": code, "message": message}}

    def _json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5599)
    ap.add_argument("--token", default="testtoken")
    ap.add_argument("--serial", default="R58M12345AB")
    ap.add_argument("--not-enrolled", dest="enrolled", action="store_false")
    cfg = ap.parse_args()
    cfg.adb_enabled = True
    cfg.ring_until = 0

    Handler.cfg = cfg
    httpd = Server(("127.0.0.1", cfg.port), Handler)
    print("fake agent: http://127.0.0.1:%d/" % httpd.socket.getsockname()[1], flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

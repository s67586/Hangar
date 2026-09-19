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
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCHEMA = 1
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
        if path == "/hangar/v1/adb":
            return self._json(501, self._err("not_implemented", "切偵錯是 M4 的事"))
        return self._json(404, self._err("not_found", "沒有這個端點：%s" % path))

    def do_POST(self):
        if self.path.split("?", 1)[0] == "/hangar/v1/adb":
            return self._json(501, self._err("not_implemented", "切偵錯是 M4 的事"))
        return self._json(404, self._err("not_found", "沒有這個端點"))

    def _token_ok(self):
        auth = self.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            return False
        return auth[7:] == self.cfg.token

    def _status(self):
        return {
            "schema": SCHEMA,
            "agent": {"version": VERSION, "uptime_s": int(time.time() - STARTED)},
            "device_serial": self.cfg.serial,
            "model": "Fake Phone",
            "android": {"release": "14", "sdk": 34},
            "battery": {"level": 78, "status": "discharging", "temperature_c": 27.5},
            # wifi_port 是隨機的而且一般 app 讀不到 —— M3c 之前誠實回 null
            "adb": {"enabled": True, "wifi_enabled": False, "wifi_port": None},
            "can": {"toggle_adb": True, "toggle_wifi_adb": True},
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

    Handler.cfg = cfg
    httpd = ThreadingHTTPServer(("127.0.0.1", cfg.port), Handler)
    print("fake agent: http://127.0.0.1:%d/" % httpd.socket.getsockname()[1], flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

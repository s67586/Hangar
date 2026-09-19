#!/usr/bin/env python3
"""Hangar helper —— 跑在「你自己這台電腦」上的那一支。

裝置牆是一頁網頁，而網頁啟動不了本機程式。所以牆上的「投影」按鈕不能叫 hub：
hub 在角落那台常駐機器上，它跑起來的 scrcpy 視窗開在那台機器的螢幕上，沒有人
看得到。按鈕要叫的是**按按鈕的那台電腦**，也就是這一支。

它只聽 127.0.0.1，收到請求之後在這台電腦上跑 `hangar -p <名稱>`——跟你自己在
終端機打的是同一行指令，沒有另外一條通往手機的路。

    ./helper/hangar_helper.py --hub http://192.168.1.5:8787

起來之後會印一個帶鑰匙的連結，在這台電腦的瀏覽器上開一次，裝置牆就記得住了。

端點：

    GET  /healthz     還活著嗎、這台電腦叫什麼、它看得到幾支手機
    POST /mirror      投影一支手機（body：{"profile": "...", "serial": "..."}）

「網頁叫得動本機程式」本來就是一件要小心的事，所以有三道鎖：

    只綁 127.0.0.1    別台電腦連不到。這裡刻意沒有 --bind 可以改
    Origin 白名單     只有 --hub 給的那些網址上的頁面叫得動；Origin 是瀏覽器
                      自己填的，頁面上的 JS 偽造不了
    token             擋掉這台電腦上其他不是從那頁來的呼叫。它放在網址的 #
                      後面，所以永遠不會送到 hub 那邊去

跟 hub 一樣只用 Python 3 標準函式庫，理由也一樣：不該為了一顆按鈕在每個人的
電腦上裝一套生態系。
"""

import argparse
import errno
import json
import os
import re
import secrets
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

# 這一版的回應形狀。跟 hangar --json 與 hub 同一個規矩：欄位有變動就往上加。
API_SCHEMA = 1

CONFIG_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "hangar")
TOKEN_FILE = os.path.join(CONFIG_DIR, "helper.token")

# 這台電腦上有哪些 profile。問一次 hangar 要一點時間，但也不能永遠不問——
# 中間有人跑了 hangar setup，按鈕不該還在說「這台電腦上沒有這支手機」。
PROFILES_TTL = 20.0

ANSI = re.compile(r"\x1b\[[0-9;]*m")
# hangar 印給人看的行首記號（err / warn / info / ok）。留著只會讓網頁上的訊息
# 多兩個看不懂的字元
MARKER = re.compile(r"^\s*(?:xx|!!|==>|ok)\s+")


# ------------------------------------------------------------------ 鑰匙 ----

def load_token(path, regenerate=False):
    """讀出這台電腦的 token，沒有就生一把。

    權限鎖 0600：這把鑰匙的意思是「可以在這台電腦上開投影視窗」，同一台機器上
    的其他使用者不該讀得到。
    """
    if not regenerate and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            tok = f.read().strip()
        if tok:
            return tok
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tok = secrets.token_hex(16)
    # 先開成 0600 再寫，不要先寫完再 chmod——中間那一瞬間是讀得到的
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(tok + "\n")
    return tok


# --------------------------------------------------------------- hangar ----

def hangar_profiles(hangar, timeout):
    """這台電腦上設定過哪些手機 → ([{name, serial, ip}], 錯誤字串)。

    刻意用 `hangar list --json`（不帶 --probe）而不是自己去讀 ~/.config/hangar：
    設定檔長什麼樣子是 hangar 的事。hub 當初也是這樣決定的——多一個地方認得
    設定檔的格式，就多一個地方會跟它走岔。
    """
    try:
        p = subprocess.run([hangar, "list", "--json"], capture_output=True,
                           text=True, errors="replace", timeout=timeout)
    except FileNotFoundError:
        return None, "找不到 hangar：%s" % hangar
    except subprocess.TimeoutExpired:
        return None, "hangar list 超過 %s 秒沒回應" % timeout
    except OSError as e:
        return None, "跑不起來 hangar：%s" % e
    if not p.stdout.strip():
        why = p.stderr.strip().splitlines()
        return None, (why[-1] if why else "hangar list 沒有輸出（離開碼 %d）" % p.returncode)
    try:
        data = json.loads(p.stdout)
    except json.JSONDecodeError as e:
        return None, "hangar list 的輸出不是 JSON：%s" % e
    out = []
    for d in data.get("devices", []):
        out.append({"name": d.get("profile"),
                    "serial": d.get("device_serial"),
                    "ip": d.get("ip")})
    return out, None


def tidy(text, keep=4):
    """把 hangar 的 stderr 整理成能放上網頁的幾行。"""
    lines = []
    for raw in (text or "").splitlines():
        line = MARKER.sub("", ANSI.sub("", raw)).strip()
        if line:
            lines.append(line)
    return lines[-keep:]


def _cmdline(pid):
    try:
        p = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                           capture_output=True, text=True, errors="replace", timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.strip() or None


def _is_scrcpy(cmdline):
    """這個 pid 現在是不是 scrcpy 了。

    `hangar` 投影的最後一步是 `exec scrcpy`——process 換了身體但 pid 不變，所以
    ps 看到的指令列從 `…/hangar -p work` 變成 `scrcpy …`。這是個不用去解析任何
    中文訊息就能拿到的「真的起來了」訊號。

    （mock 的 scrcpy 是 shell script，exec 之後指令列長成 `bash …/mockbin/scrcpy`，
    所以這裡比對的是每一段的 basename，而不是第一段而已。）
    """
    return any(os.path.basename(tok) == "scrcpy" for tok in (cmdline or "").split())


def launch_mirror(hangar, profile, grace):
    """在這台電腦上開一個投影視窗 → (成功嗎, 訊息, 細節幾行)。

    這裡不是「丟出去就回報成功」：那樣的話手機沒開機、5555 掉了、adb 沒授權，
    網頁上一律顯示成功，而那正是這一版要避免的東西（URL scheme 那條路就是敗在
    這裡）。所以會等到其中一件事發生：

        process 死了            → 用它的離開碼與 stderr 講發生什麼事
        process 變成 scrcpy 了  → 視窗真的開了，馬上回報
        等超過 grace 秒         → 老實說「還在跑，但沒看到 scrcpy 換上來」

    start_new_session=True：投影視窗不該因為 helper 被關掉就跟著死。
    """
    err_file = tempfile.TemporaryFile()
    try:
        p = subprocess.Popen([hangar, "-p", profile],
                             stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=err_file,
                             start_new_session=True)
    except OSError as e:
        err_file.close()
        return False, "跑不起來 hangar：%s" % e, []

    def stderr_lines():
        try:
            err_file.seek(0)
            return tidy(err_file.read().decode("utf-8", "replace"))
        except OSError:
            return []

    deadline = time.time() + grace
    while time.time() < deadline:
        rc = p.poll()
        if rc is not None:
            lines = stderr_lines()
            err_file.close()
            if rc == 0:
                # exec 之後的 scrcpy 正常結束了——多半是有人把視窗關掉
                return True, "投影視窗已經關掉了", lines
            return False, "投影沒起來（hangar 離開碼 %d）" % rc, lines
        if _is_scrcpy(_cmdline(p.pid)):
            # 我們這邊的 fd 放掉，剩下的輸出讓它寫進那個已經 unlink 的暫存檔，
            # process 結束時自然收回去
            err_file.close()
            return True, "投影視窗開了", []
        time.sleep(0.4)

    err_file.close()
    return True, "還在跑，但等了 %g 秒沒看到 scrcpy 接手" % grace, []


# ------------------------------------------------------------------ 狀態 ----

class State:
    def __init__(self, hangar, timeout):
        self.hangar = hangar
        self.timeout = timeout
        self._lock = threading.Lock()
        self._profiles = None
        self._profiles_at = 0.0
        self._profiles_err = None
        self._busy = set()          # 正在啟動中的 profile

    def profiles(self, fresh=False):
        with self._lock:
            fresh_enough = (self._profiles is not None
                            and time.time() - self._profiles_at < PROFILES_TTL)
            if fresh_enough and not fresh:
                return self._profiles, self._profiles_err
        data, err = hangar_profiles(self.hangar, self.timeout)
        with self._lock:
            if err is None:
                self._profiles, self._profiles_at, self._profiles_err = data, time.time(), None
            else:
                self._profiles_err = err
            return self._profiles, self._profiles_err

    def resolve(self, profile, serial):
        """牆上那張卡 → 這台電腦上的 profile 名稱。

        序號優先，名字是備胎。牆上的名字是 **hub 那台機器**取的，同一支手機在
        你的電腦上很可能叫別的名字；序號則是跨電腦、跨 IP 都不變的——這跟
        hangar scan 認人用的是同一套順序。
        """
        err = None
        # 第二圈是重問一次再說「沒有」：中間可能剛好有人跑完 hangar setup，
        # 而「這台電腦上沒有這支手機」是個會讓人去做事的答案，不該猜錯
        for fresh in (False, True):
            devices, err = self.profiles(fresh=fresh)
            if not devices:
                continue
            if serial:
                for d in devices:
                    if d.get("serial") and d["serial"] == serial:
                        return d["name"], "serial", None
            if profile:
                for d in devices:
                    if d.get("name") == profile:
                        return d["name"], "name", None
        return None, None, err

    def claim(self, profile):
        with self._lock:
            if profile in self._busy:
                return False
            self._busy.add(profile)
            return True

    def release(self, profile):
        with self._lock:
            self._busy.discard(profile)


# ------------------------------------------------------------------ HTTP ----

class Handler(BaseHTTPRequestHandler):
    server_version = "hangar-helper"
    state = None          # main() 會塞進來
    token = None
    origins = ()
    grace = 30.0

    # ---- CORS ----
    def _origin_ok(self):
        """這個 Origin 准不准。

        沒有 Origin 的請求（curl、腳本）不在瀏覽器的規則底下，Origin 擋不到它們
        ——那種呼叫靠 token 擋。這裡只負責「哪一頁的 JS 叫得動我」。
        """
        origin = self.headers.get("Origin")
        if origin is None:
            return True, None
        return (origin in self.origins), origin

    def _cors(self, origin):
        if not origin:
            return
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Vary", "Origin")

    def do_OPTIONS(self):
        allowed, origin = self._origin_ok()
        if not allowed:
            return self._deny(origin)
        self.send_response(204)
        self._cors(origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "authorization, content-type")
        self.send_header("Access-Control-Max-Age", "600")
        # Chrome 對「公開／私有網段的頁面連本機」有額外的一關（Private Network
        # Access / Local Network Access）。這個標頭是舊版要的；新版改成問使用者
        # 一次權限，那一關是瀏覽器自己的 UI，這邊給不了也擋不掉。
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _deny(self, origin):
        # 這裡刻意把兩個網址都講出來。這個錯誤幾乎都是同一個原因：hub 開在
        # http://192.168.x.x:8787，但 helper 啟動時給的 --hub 寫成 localhost
        # ——兩邊只要差一個字，瀏覽器就當成不同來源。
        body = {"ok": False, "reason": "這頁不在白名單上：%s" % (origin or "?"),
                "allowed": list(self.origins),
                "hint": "helper 起來時的 --hub 要跟你瀏覽器網址列上的那個字一模一樣"}
        self._json(403, body, origin=None)

    # ---- 端點 ----
    def do_GET(self):
        allowed, origin = self._origin_ok()
        if not allowed:
            return self._deny(origin)
        path = self.path.split("?", 1)[0]
        if path != "/healthz":
            return self._json(404, {"ok": False, "reason": "沒有這個端點"}, origin)
        if not self._authed():
            return self._unauth(origin)
        devices, err = self.state.profiles()
        return self._json(200, {"ok": True, "schema": API_SCHEMA,
                                "host": hostname(),
                                "profiles": [d["name"] for d in (devices or [])],
                                "error": err}, origin)

    def do_POST(self):
        allowed, origin = self._origin_ok()
        if not allowed:
            return self._deny(origin)
        path = self.path.split("?", 1)[0]
        if path != "/mirror":
            return self._json(404, {"ok": False, "reason": "沒有這個端點"}, origin)
        if not self._authed():
            return self._unauth(origin)

        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        # 上限擋著：這個端點只收得下一個名字跟一個序號
        raw = self.rfile.read(min(n, 4096)) if n > 0 else b"{}"
        try:
            body = json.loads(raw.decode("utf-8", "replace")) or {}
        except json.JSONDecodeError:
            return self._json(400, {"ok": False, "reason": "body 不是 JSON"}, origin)
        profile = (body.get("profile") or "").strip()
        serial = (body.get("serial") or "").strip()
        if not profile and not serial:
            return self._json(400, {"ok": False,
                                    "reason": "要給 profile 或 serial"}, origin)

        name, matched_by, err = self.state.resolve(profile, serial)
        if name is None:
            if err:
                return self._json(502, {"ok": False, "reason": err}, origin)
            # 這就是那個躲不掉的前置動作，在它真正發生的地方講出來
            who = profile or serial
            return self._json(404, {
                "ok": False,
                "reason": "這台電腦上沒有這支手機（%s）" % who,
                "hint": "先在這台電腦跑一次 hangar setup —— adb 授權是綁每台電腦的"},
                origin)

        if not self.state.claim(name):
            return self._json(409, {"ok": False, "profile": name,
                                    "reason": "這支正在啟動中，等一下"}, origin)
        try:
            ok, message, detail = launch_mirror(self.state.hangar, name, self.grace)
        finally:
            self.state.release(name)
        return self._json(200 if ok else 502,
                          {"ok": ok, "profile": name, "matched_by": matched_by,
                           "host": hostname(),
                           "message": message, "detail": detail}, origin)

    # ---- 雜事 ----
    def _authed(self):
        got = self.headers.get("Authorization") or ""
        if got.lower().startswith("bearer "):
            got = got[7:]
        return secrets.compare_digest(got.strip(), self.token)

    def _unauth(self, origin):
        self._json(401, {"ok": False, "reason": "這頁沒有這台電腦的鑰匙",
                         "hint": "重開 helper，用它印出來的那個連結進裝置牆一次"},
                   origin)

    def _json(self, status, obj, origin):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._cors(origin)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


# ------------------------------------------------------------------ main ----

def hostname():
    """這台電腦叫什麼。

    只取第一段：在 tailnet 上 gethostname() 常常是一整串 FQDN，而這個字串是要
    印在裝置牆上給人認「是我這台」用的。
    """
    return socket.gethostname().split(".")[0] or "?"


def normalize_origin(url):
    """把 --hub 給的網址收斂成瀏覽器會送出的那個 Origin。

    瀏覽器送的 Origin 只有 scheme://host:port，沒有路徑也沒有結尾的斜線，而且
    大小寫是正規化過的。使用者貼進來的往往是整個網址列的內容。
    """
    u = url.strip()
    if "://" not in u:
        u = "http://" + u
    scheme, _, rest = u.partition("://")
    authority = rest.split("/", 1)[0]
    return scheme.lower() + "://" + authority.lower()


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Hangar helper：讓裝置牆上的投影按鈕在這台電腦上開視窗")
    ap.add_argument("--hub", action="append", default=[], metavar="網址",
                    help="裝置牆的網址（可以給多次）。只有這些頁面叫得動 helper")
    ap.add_argument("--hangar", default=os.path.join(HERE, "..", "hangar"),
                    help="hangar 執行檔的路徑（預設：這個 repo 裡的那支）")
    ap.add_argument("--port", type=int, default=8788,
                    help="埠（預設 8788，0 = 隨便挑）")
    ap.add_argument("--grace", type=float, default=30.0,
                    help="等投影起來的上限（秒，預設 30）")
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="單次 hangar list 的逾時（秒）")
    ap.add_argument("--token-file", default=TOKEN_FILE, help="鑰匙放哪（預設 %s）" % TOKEN_FILE)
    ap.add_argument("--new-token", action="store_true",
                    help="換一把新的鑰匙（舊的連結就失效了）")
    args = ap.parse_args(argv)

    hangar = os.path.abspath(args.hangar)
    if not os.access(hangar, os.X_OK):
        print("找不到可執行的 hangar：%s" % hangar, file=sys.stderr)
        return 1
    if not args.hub:
        print("要給 --hub：裝置牆開在哪個網址", file=sys.stderr)
        print("  ./helper/hangar_helper.py --hub http://192.168.1.5:8787", file=sys.stderr)
        print("  （只有那一頁叫得動這支 helper，所以它一定要講出來）", file=sys.stderr)
        return 1

    origins = tuple(dict.fromkeys(normalize_origin(h) for h in args.hub))
    try:
        token = load_token(args.token_file, args.new_token)
    except OSError as e:
        print("寫不了鑰匙檔 %s：%s" % (args.token_file, e), file=sys.stderr)
        return 1

    Handler.state = State(hangar, args.timeout)
    Handler.token = token
    Handler.origins = origins
    Handler.grace = args.grace

    try:
        # 只綁 127.0.0.1，而且沒有參數可以改。這一支會在這台電腦上開程式，
        # 沒有任何理由讓別台機器連得到它。
        httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as e:
        if e.errno == errno.EADDRINUSE:
            print("127.0.0.1:%d 已經有人在用了" % args.port, file=sys.stderr)
            print("  多半是另一個 helper 還在跑：", file=sys.stderr)
            print("    pgrep -fl hangar_helper.py     # 看是不是它", file=sys.stderr)
            print("    pkill -f hangar_helper.py      # 收掉", file=sys.stderr)
            print("  或者換一個埠：--port 8789", file=sys.stderr)
        elif e.errno == errno.EACCES:
            print("沒有權限綁 127.0.0.1:%d（1024 以下的埠要 root）" % args.port,
                  file=sys.stderr)
            print("  換一個大一點的：--port 8788", file=sys.stderr)
        else:
            print("開不了 127.0.0.1:%d：%s" % (args.port, e), file=sys.stderr)
        return 1

    port = httpd.socket.getsockname()[1]
    print("hangar helper: http://127.0.0.1:%d/（只有這台電腦連得到）" % port, flush=True)
    print("在這台電腦的瀏覽器開這個連結一次，裝置牆就記得住這台電腦了：", flush=True)
    for o in origins:
        print("  %s/#helper=%s&port=%d" % (o, token, port), flush=True)
    print("（鑰匙在 # 後面，不會送到 hub 那邊去）", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

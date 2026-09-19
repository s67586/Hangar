#!/usr/bin/env python3
"""Hangar hub —— 常駐服務 + 唯讀裝置牆。

跑在一台跟測試機同一個區網的常駐機器上，定期問 hangar 兩件事：

    hangar list --json --probe   已經設定過的手機：adb 狀態、機型、電量
    hangar scan --json           區網上看得到的所有東西：IP、MAC、廠商、5555

然後把兩份資料合成一張裝置牆。**這一版是唯讀的**：沒有任何會改到手機或設定檔
的端點，輪詢也不會帶 --fix-ip（那會寫 profile，固定輪詢的程式不該無條件做）。

只用標準函式庫，理由跟 hangar 自己是一支無相依 bash script 一樣：常駐機器上
不該為了看一頁網頁而先裝一套生態系。

    ./hub/hangar_hub.py --hangar ./hangar
    ./hub/hangar_hub.py --bind 0.0.0.0 --port 8787     # 給同事看要明講

端點：

    GET  /                裝置牆（HTML）
    GET  /api/devices     合併後的裝置清單（JSON）
    POST /api/refresh     現在就去問一次（?what=list|scan|all）
    GET  /healthz         還活著嗎
"""

import argparse
import errno
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
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


HERE = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(HERE, "static")

# 這一版 /api/devices 的形狀。跟 hangar 的 --json 一樣的規矩：欄位有變動就往上加。
API_SCHEMA = 6

# 跟 hangar 的 BATTERY_LOW 對齊。兩邊要是各有一套，同一支手機在 CLI 跟網頁上
# 會給出不同的答案。
BATTERY_LOW = 20


# --------------------------------------------------------------- 叫 hangar --

def run_hangar(hangar, args, timeout):
    """跑一次 hangar，把 stdout 的 JSON 解出來 → (資料, 錯誤字串)。

    --json 模式下 hangar 的 stdout 只有 JSON，給人看的訊息都在 stderr，所以
    stderr 只在真的失敗時拿來當錯誤訊息用。手機離線之類的狀況 hangar 是回 0
    並把原因放在 errors 裡的，那不算這裡的錯誤。
    """
    cmd = [hangar] + args
    try:
        # errors="replace"：輸出不是乾淨的 UTF-8 時換成替代字元，不要拋例外。
        # 這裡收到的是外部程式的輸出，壞掉的位元組是「有可能發生」而不是「不該發生」——
        # 為了一個字元讓整個輪詢停擺，代價完全不成比例。
        p = subprocess.run(cmd, capture_output=True, text=True,
                           errors="replace", timeout=timeout)
    except FileNotFoundError:
        return None, "找不到 hangar：%s" % hangar
    except subprocess.TimeoutExpired:
        return None, "hangar %s 超過 %s 秒沒回應" % (" ".join(args), timeout)
    except OSError as e:
        return None, "跑不起來 hangar：%s" % e
    if not p.stdout.strip():
        why = p.stderr.strip().splitlines()
        return None, (why[-1] if why else "hangar %s 沒有輸出（離開碼 %d）"
                      % (" ".join(args), p.returncode))
    try:
        return json.loads(p.stdout), None
    except json.JSONDecodeError as e:
        return None, "hangar %s 的輸出不是 JSON：%s" % (" ".join(args), e)


# ------------------------------------------------------------------ 合併 ----

def _battery(b):
    if not b:
        return None
    level = b.get("level")
    status = (b.get("status") or "").lower()
    low = (isinstance(level, int) and level < BATTERY_LOW
           and status not in ("charging", "full"))
    out = dict(b)
    out["low"] = low
    return out


def _state_of(dev):
    """一支已設定的手機現在是什麼狀態。

    刻意分開「連不到」與「連得到但 adb 不是 device」：前者要去看手機在不在線上，
    後者幾乎都是手機重開機把 5555 弄丟了 —— 這兩件事的下一步動作完全不同。
    """
    adb = dev.get("adb_state")
    if adb == "device":
        return "ready"
    if adb == "unauthorized":
        return "unauthorized"
    agent = dev.get("agent") or {}
    if agent.get("reachable"):
        # adb 進不去，但手機裡的 agent 答得出話 —— 看得到、管不動。
        # 這正是 agent 存在的理由，值得跟「整台失聯」分開顯示。
        return "agent_only"
    if dev.get("reachability") in ("offline", "notfound"):
        return "offline"
    return "no_adb"


def merge(list_data, scan_data):
    """把 list 與 scan 兩份資料合成一張裝置牆。

    識別碼的優先順序跟 hangar scan 那一層同一套：DEVICE_SERIAL > MAC > IP。
    序號是跨 IP、跨連線方式都不變的，所以只要 profile 記過序號，同一支手機在
    兩份資料裡就一定會合成同一張卡。
    """
    devices = []
    by_profile = {}

    for d in (list_data or {}).get("devices", []):
        entry = {
            "key": ("serial:" + d["device_serial"]) if d.get("device_serial")
                   else "profile:" + d.get("profile", ""),
            "name": d.get("profile"),
            "default": bool(d.get("default")),
            "state": _state_of(d),
            "transport": d.get("transport"),
            "ip": d.get("ip"),
            "adb_serial": d.get("adb_serial"),
            "device_serial": d.get("device_serial"),
            "adb_state": d.get("adb_state"),
            "reachability": d.get("reachability"),
            "model": d.get("model"),
            "android": d.get("android"),
            "battery": _battery(d.get("battery")),
            "mirroring": bool(d.get("scrcpy_pids")),
            # agent：null = 沒入伍過；reachable=false = 入伍過但現在叫不動
            "agent": d.get("agent"),
            # MAC 有兩個來源。這裡拿的是 adb 問手機自己要來的（list 那半邊），
            # 走 tailscale 或不同 Wi-Fi 的手機也有 —— 掃描永遠對不上那些。
            # 掃到的話下面會用區網那一份覆蓋：同一段區網上 ARP 換來的才是
            # 「hub 實際看到的那張網卡」。
            "mac": (d.get("mac") or {}).get("address"),
            "vendor": (d.get("mac") or {}).get("vendor"),
            "mac_randomized": (d.get("mac") or {}).get("randomized"),
            "mac_ssid": (d.get("mac") or {}).get("ssid"),
            # 區網那半邊的欄位，等下面掃描結果對上了再補
            "adb_port": None, "lan_ip": None, "profile_ip_stale": False,
            "is_gateway": False,
            "sources": ["list"],
            "errors": list(d.get("errors") or []),
        }
        devices.append(entry)
        if entry["name"]:
            by_profile[entry["name"]] = entry

    for h in (scan_data or {}).get("hosts", []):
        prof = h.get("profile")
        entry = by_profile.get(prof) if prof else None
        if entry is None and prof:
            # 掃描說它是某支已設定的手機，但 list 那邊沒有這一筆 —— 多半是那次
            # list 剛好失敗或逾時。這時候仍然要叫得出名字：把它顯示成一台陌生
            # 機器比什麼都不顯示更糟。
            entry = {
                "key": ("serial:" + h["device_serial"]) if h.get("device_serial")
                       else "profile:" + prof,
                "name": prof, "default": False, "state": "unknown",
                "transport": None, "ip": h.get("ip"), "adb_serial": None,
                "device_serial": h.get("device_serial"),
                "adb_state": None, "reachability": None,
                "model": None, "android": None, "battery": None,
                "mirroring": False,
                "mac": None, "vendor": None, "mac_randomized": None,
                "mac_ssid": None,
                "adb_port": None, "lan_ip": None, "profile_ip_stale": False,
                "agent": None, "is_gateway": False, "sources": [], "errors": [],
            }
            devices.append(entry)
            by_profile[prof] = entry
        if entry is None:
            # 掃到但沒設定過 —— 這正是裝置牆存在的理由：沒開偵錯的手機 adb 完全
            # 碰不到，網路層只給得出 IP 與 MAC，但它確實在那裡。
            devices.append({
                "key": ("mac:" + h["mac"]) if h.get("mac") else "ip:" + h["ip"],
                "name": None, "default": False, "state": "unmanaged",
                "transport": None, "ip": h.get("ip"), "adb_serial": None,
                "device_serial": h.get("device_serial"),
                "adb_state": None, "reachability": None,
                "model": None, "android": None, "battery": None,
                "mirroring": False,
                "mac": h.get("mac"), "vendor": h.get("vendor"),
                "mac_randomized": h.get("mac_randomized"), "mac_ssid": None,
                "adb_port": h.get("adb_port"), "lan_ip": h.get("ip"),
                "profile_ip_stale": False,
                # 掃到一支 agent 卻沒有對應的 profile：那台裝過 agent 但這台
                # hub 沒有它的 token。看得到、問不出細節。
                "agent": ({"reachable": True, "version": (h.get("agent") or {}).get("version"),
                           "enrolled": None} if h.get("agent") else None),
                # 這個網段的閘道器。每次掃描都會出現，標出來才不用每次重新猜
                "is_gateway": bool(h.get("is_gateway")),
                "sources": ["scan"], "errors": [],
            })
            continue
        # 掃到 MAC 才覆蓋。掃描配對是靠 profile 名字，配得上卻沒 MAC 是有的
        # （例如那一輪 ARP 沒回）—— 這時候不能把 adb 問到的那份洗掉。
        if h.get("mac"):
            entry["mac"] = h.get("mac")
            entry["vendor"] = h.get("vendor")
            entry["mac_randomized"] = h.get("mac_randomized")
        entry["adb_port"] = h.get("adb_port")
        entry["lan_ip"] = h.get("ip")
        entry["profile_ip_stale"] = bool(h.get("profile_ip_stale"))
        entry["is_gateway"] = bool(h.get("is_gateway"))
        if h.get("agent") and not (entry.get("agent") or {}).get("reachable"):
            # list 那邊沒問到（沒 token 或沒帶 --probe），但掃描看到它在聽
            entry["agent"] = {"reachable": True,
                              "version": (h.get("agent") or {}).get("version"),
                              "enrolled": (entry.get("agent") or {}).get("enrolled")}
            if entry["state"] in ("no_adb", "offline"):
                entry["state"] = "agent_only"
        if "scan" not in entry["sources"]:
            entry["sources"].append("scan")

    # 排序：要注意的排前面（電量低 > 設定過的 > 掃到的），同類再按名稱／IP
    order = {"unauthorized": 0, "no_adb": 1, "offline": 2, "unknown": 3,
             "agent_only": 4, "ready": 5, "unmanaged": 6}

    def sort_key(d):
        low = 0 if (d.get("battery") or {}).get("low") else 1
        # 閘道器排在同類的最後面：它每次都在，而且永遠不是要找的那台
        return (low, order.get(d["state"], 9), 1 if d.get("is_gateway") else 0,
                d.get("name") or "", _ip_key(d.get("ip") or ""))

    devices.sort(key=sort_key)
    return devices


def _ip_key(ip):
    try:
        return tuple(int(x) for x in ip.split("."))
    except (ValueError, AttributeError):
        return (999, 999, 999, 999)


# ------------------------------------------------------------------ 狀態 ----

class State:
    """兩個輪詢執行緒寫、HTTP 執行緒讀的那份共用狀態。

    掃描比 list 慢很多（ping 整個 /24），所以兩邊各自照自己的節奏跑，誰先回來
    就先更新誰 —— 網頁要的是「最新知道的樣子」，不是「兩邊同時量到的樣子」。
    """

    def __init__(self):
        self._lock = threading.Lock()
        self.list_data = None
        self.scan_data = None
        self.list_at = None
        self.scan_at = None
        self.errors = {}          # 來源 → 錯誤字串（連不到 hangar 這種）
        # 主動輪詢用：每個來源一個「醒來」旗標，POST /api/refresh 就是把它立起來
        self.wake = {}            # 來源 → threading.Event
        self.started_at = {}      # 來源 → 這一輪是什麼時候開始的
        self.busy = {}            # 來源 → 現在正在跑嗎

    def begin(self, kind):
        with self._lock:
            self.started_at[kind] = time.time()
            self.busy[kind] = True

    def done(self, kind):
        with self._lock:
            self.busy[kind] = False

    def since_start(self, kind):
        """距離這個來源上一輪開始過了多久。沒跑過就是很久很久。"""
        with self._lock:
            t = self.started_at.get(kind)
        return float("inf") if t is None else time.time() - t

    def update(self, kind, data, err):
        with self._lock:
            if err:
                self.errors[kind] = err
                return
            self.errors.pop(kind, None)
            if kind == "list":
                self.list_data, self.list_at = data, time.time()
            else:
                self.scan_data, self.scan_at = data, time.time()

    def snapshot(self):
        with self._lock:
            devices = merge(self.list_data, self.scan_data)
            errors = [{"source": k, "message": v} for k, v in self.errors.items()]
            # hangar 自己回報的錯誤（掃不動、缺工具…）也一起端上去
            for src, data in (("list", self.list_data), ("scan", self.scan_data)):
                for e in (data or {}).get("errors", []) or []:
                    errors.append({"source": src, "code": e.get("code"),
                                   "message": e.get("message")})
            return {
                "schema": API_SCHEMA,
                # hub 自己跑在哪一台。scrcpy_pids 是 hangar 在**這台機器上**
                # pgrep 出來的，所以牆上要講「哪台電腦開著視窗」時，答案永遠
                # 是這個名字 —— 端出來才不用叫人自己去猜 hub 在哪。
                "host": hostname(),
                "devices": devices,
                "subnet": (self.scan_data or {}).get("subnet"),
                "polled_at": {"list": self.list_at, "scan": self.scan_at},
                # 現在有沒有哪一邊正在問。網頁靠這個把「更新中」顯示出來 ——
                # 按了按鈕之後畫面要有反應，不然使用者會再按一次。
                "polling": {k: bool(v) for k, v in self.busy.items()},
                "errors": errors,
            }


def hostname():
    """這台機器叫什麼。只取第一段：在 tailnet 上 gethostname() 常常是一整串 FQDN，
    而這個字串是要印在牆上給人認「是哪一台」用的。"""
    return socket.gethostname().split(".")[0] or "?"


def poller(state, kind, hangar, args, interval, timeout, stop):
    """一個來源一個執行緒。第一輪馬上跑，之後照 interval。

    整圈包在 try 裡面是刻意的：**這個執行緒不准死**。它一死，網頁就停在舊資料上
    而且沒有任何跡象 —— 「沒有更新」跟「沒有變化」在畫面上長得一模一樣，那是最
    糟的失敗方式。任何沒預期到的例外都變成一則錯誤顯示在牆上，然後繼續跑。
    """
    wake = state.wake[kind]
    while not stop.is_set():
        state.begin(kind)
        try:
            data, err = run_hangar(hangar, args, timeout)
            state.update(kind, data, err)
            if err:
                print("[%s] %s" % (kind, err), file=sys.stderr, flush=True)
        except Exception as e:      # noqa: BLE001 —— 這裡就是要攔住全部
            msg = "%s 這一輪炸了：%s: %s" % (kind, type(e).__name__, e)
            state.update(kind, None, msg)
            print("[%s] %s" % (kind, msg), file=sys.stderr, flush=True)
        finally:
            state.done(kind)
        # 等下一輪，但 /api/refresh 可以把它提早叫醒
        wake.wait(interval)
        wake.clear()


# ------------------------------------------------------------------ HTTP ----

# 主動輪詢的最小間隔。按鈕按住不放不該變成對整個區網洗 ping ——
# 掃描那一邊尤其：它會對 254 個位址各送一個封包。
REFRESH_MIN = {"list": 5.0, "scan": 30.0}


class Handler(BaseHTTPRequestHandler):
    server_version = "hangar-hub"
    state = None          # main() 會塞進來

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            return self._file(os.path.join(STATIC_DIR, "index.html"), "text/html")
        if path == "/api/devices":
            return self._json(self.state.snapshot())
        if path == "/healthz":
            return self._json({"ok": True})
        # 靜態檔只開 static/ 底下的，而且不准往上跳
        if path.startswith("/static/"):
            name = os.path.normpath(path[len("/static/"):]).lstrip("./")
            full = os.path.join(STATIC_DIR, name)
            if os.path.commonpath([os.path.abspath(full), STATIC_DIR]) == STATIC_DIR:
                kind = "text/css" if name.endswith(".css") else "text/javascript"
                return self._file(full, kind)
        self.send_error(404)

    def do_POST(self):
        path, _, query = self.path.partition("?")
        if path != "/api/refresh":
            return self.send_error(404)
        want = "all"
        for part in query.split("&"):
            if part.startswith("what="):
                want = part[5:]
        kinds = [k for k in self.state.wake if want in ("all", k)]
        if not kinds:
            return self._json(400, {"ok": False,
                                    "reason": "不認得的 what：%s" % want})
        woke, waited = [], []
        for k in kinds:
            ago = self.state.since_start(k)
            need = REFRESH_MIN.get(k, 5.0)
            if ago < need:
                waited.append({"source": k, "retry_after_s": round(need - ago, 1)})
                continue
            self.state.wake[k].set()
            woke.append(k)
        if not woke:
            # 全部都被節流擋下來 —— 429 而不是 200，呼叫端才知道沒有真的去問
            return self._json(429, {"ok": False, "refreshed": [],
                                    "throttled": waited,
                                    "reason": "剛問過了，等一下再來"})
        return self._json(200, {"ok": True, "refreshed": woke, "throttled": waited})

    def _json(self, *args):
        """_json(obj) 或 _json(status, obj)。"""
        status, obj = (200, args[0]) if len(args) == 1 else args
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _file(self, full, kind):
        try:
            with open(full, "rb") as f:
                body = f.read()
        except OSError:
            return self.send_error(404)
        self.send_response(200)
        self.send_header("Content-Type", "%s; charset=utf-8" % kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):      # 預設會把每個請求印到 stderr，太吵
        pass


# ------------------------------------------------------------------ main ----

def main(argv=None):
    ap = argparse.ArgumentParser(description="Hangar hub：常駐服務 + 唯讀裝置牆")
    ap.add_argument("--hangar", default=os.path.join(HERE, "..", "hangar"),
                    help="hangar 執行檔的路徑（預設：這個 repo 裡的那支）")
    ap.add_argument("--bind", default="127.0.0.1",
                    help="綁哪個位址（預設只綁 127.0.0.1）")
    ap.add_argument("--port", type=int, default=8787, help="埠（預設 8787，0 = 隨便挑）")
    ap.add_argument("--list-interval", type=float, default=30.0,
                    help="多久問一次 hangar list（秒，預設 30）")
    ap.add_argument("--scan-interval", type=float, default=300.0,
                    help="多久掃一次區網（秒，預設 300 —— ping 整個 /24 不便宜）")
    ap.add_argument("--subnet", default=None, help="掃描網段，同 hangar scan --subnet")
    ap.add_argument("--no-scan", action="store_true", help="完全不掃區網")
    ap.add_argument("--timeout", type=float, default=120.0, help="單次 hangar 的逾時（秒）")
    args = ap.parse_args(argv)

    hangar = os.path.abspath(args.hangar)
    if not os.access(hangar, os.X_OK):
        print("找不到可執行的 hangar：%s" % hangar, file=sys.stderr)
        return 1

    state = State()
    stop = threading.Event()
    threads = []

    # 每個來源一個喚醒旗標。poller 等在它上面，/api/refresh 把它立起來。
    for kind in ("list", "scan"):
        state.wake[kind] = threading.Event()

    list_args = ["list", "--json", "--probe"]
    threads.append(threading.Thread(
        target=poller, args=(state, "list", hangar, list_args,
                             args.list_interval, args.timeout, stop), daemon=True))
    if args.no_scan:
        state.wake.pop("scan", None)      # 沒人服務的旗標不要留著騙人
    else:
        # 這裡刻意不帶 --fix-ip：那會改 profile，固定輪詢的程式不該無條件做。
        scan_args = ["scan", "--json"]
        if args.subnet:
            scan_args += ["--subnet", args.subnet]
        threads.append(threading.Thread(
            target=poller, args=(state, "scan", hangar, scan_args,
                                 args.scan_interval, args.timeout, stop), daemon=True))
    for t in threads:
        t.start()

    Handler.state = state
    try:
        httpd = Server((args.bind, args.port), Handler)
    except OSError as e:
        # 「埠被佔住」是最常發生的一種：多半是自己上一個 hub 還活著。
        # 這種事丟一整串 traceback 出來沒有幫到任何人 —— 它看起來像程式壞了，
        # 但實際上要做的事很明確。
        if e.errno == errno.EADDRINUSE:
            print("%s:%d 已經有人在用了" % (args.bind, args.port), file=sys.stderr)
            print("  多半是另一個 hangar hub 還在跑：", file=sys.stderr)
            print("    pgrep -fl hangar_hub.py       # 看是不是它", file=sys.stderr)
            print("    pkill -f hangar_hub.py        # 收掉", file=sys.stderr)
            print("  或者換一個埠：--port 8788", file=sys.stderr)
        elif e.errno == errno.EACCES:
            print("沒有權限綁 %s:%d（1024 以下的埠要 root）" % (args.bind, args.port),
                  file=sys.stderr)
            print("  換一個大一點的：--port 8787", file=sys.stderr)
        elif e.errno in (errno.EADDRNOTAVAIL, errno.ENOENT):
            print("綁不上 %s —— 這台機器上沒有這個位址" % args.bind, file=sys.stderr)
            print("  只給自己看用 --bind 127.0.0.1，要給同事看用 --bind 0.0.0.0",
                  file=sys.stderr)
        else:
            print("開不了 %s:%d：%s" % (args.bind, args.port, e), file=sys.stderr)
        stop.set()
        for ev in state.wake.values():
            ev.set()
        return 1
    host, port = httpd.socket.getsockname()[:2]
    print("hangar hub: http://%s:%d/" % (host, port), flush=True)
    if args.bind not in ("127.0.0.1", "localhost", "::1"):
        print("注意：綁在 %s，同網段的人都看得到這頁裝置牆" % args.bind,
              file=sys.stderr, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        # 叫醒還在等下一輪的 poller，不然要等滿一個 interval 才收得掉
        for ev in state.wake.values():
            ev.set()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

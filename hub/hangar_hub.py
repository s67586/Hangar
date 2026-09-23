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
    GET  /api/helper      內嵌的 helper 在哪、鑰匙是什麼（**只回答 loopback**）
    POST /api/refresh     現在就去問一次（?what=list|scan|all）
    GET  /healthz         還活著嗎

預設會把 helper 一起帶起來（`--no-helper` 關掉），但那是**另一個 listener**，
而且照樣只綁 127.0.0.1：hub 這一邊仍然一個會動到手機的端點都沒有。
"""

import argparse
import errno
import importlib.util
import ipaddress
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
API_SCHEMA = 8

# 跟 hangar 的 BATTERY_LOW 對齊。兩邊要是各有一套，同一支手機在 CLI 跟網頁上
# 會給出不同的答案。
BATTERY_LOW = 20


# ----------------------------------------------------------- 內嵌 helper ----
#
# 裝置牆上的動作按鈕（投影、響鈴、切偵錯、入伍）從來不是 hub 在做 —— 那些事得
# 發生在**按按鈕的那台電腦**上，所以做事的一直是 helper。但最常見的情形是 hub
# 跟 helper 在同一台（自己的筆電），那時候「兩個 process」只剩成本：兩個終端機、
# --hub 要跟網址列一字不差、還要去開那個帶 token 的連結。
#
# 所以這裡把 helper 帶進同一個 process —— 但**只是同一個 process，不是同一個
# listener**。helper 照樣自己綁 127.0.0.1，照樣走它那三道鎖，hub 這一邊還是一個
# 會動到手機的端點都沒有。要拆開跑（hub 在角落常駐機、每人一支 helper）也完全
# 沒變：helper/hangar_helper.py 一行都沒動。

HELPER_PATH = os.path.join(HERE, "..", "helper", "hangar_helper.py")

# helper 那邊的 `hangar list` 要多久算逾時。刻意不沿用 hub 的 --timeout：那個
# 是給掃整個 /24 用的（預設 120 秒），而這裡是有人按了按鈕在等，瀏覽器那端掛
# 兩分鐘等於沒有回應。用 helper 自己的預設值。
HELPER_LIST_TIMEOUT = 30.0


def load_helper(path=HELPER_PATH):
    """把 helper 那支腳本當成模組載進來 → (模組, 錯誤字串)。

    hub/ 與 helper/ 是兩個平行的目錄，不是 package。為了共用一支模組把整個 repo
    改成 package，代價遠大於這裡的收穫，所以照路徑載。

    載不起來不是致命的：hub 照樣是一頁看得到的裝置牆，只是動作按鈕要那台電腦
    自己跑一支 helper。**hub 絕不能因為 helper 不在就起不來** —— 只複製 hub/
    出去的部署本來就該活得下去。
    """
    full = os.path.abspath(path)
    if not os.path.exists(full):
        return None, "找不到 %s" % full
    try:
        spec = importlib.util.spec_from_file_location("hangar_helper", full)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:      # noqa: BLE001 —— 載不起來的理由很多種，都一樣不致命
        return None, "載不進 %s：%s: %s" % (full, type(e).__name__, e)
    return mod, None


def local_ips():
    """這台機器對外會用哪個位址。拿不到就算了 —— 少一個名字只代表從那個網址開
    的頁面叫不動 helper，不是 hub 起不來。

    **這條路上一個名字解析都不准有。** 它跑在「hub 已經綁好、但還沒進
    serve_forever」的那一小段裡，任何會卡住的呼叫都會讓 hub 看起來像死了：
    socket 綁著、連線排在 backlog 裡、沒有人 accept，而啟動訊息早就印出去了。
    上面那個 Server 跳過 server_bind 裡的 getfqdn() 是完全同一個理由 —— 在反向
    解析不通或很慢的機器上（GitHub 的 macOS runner 就是這樣）那會一路卡到 DNS
    逾時。getaddrinfo(gethostname()) 是同一個陷阱的另一個入口。

    所以這裡問的是核心的路由表：UDP socket 的 connect 不送出任何封包、也不做
    名字解析，但 getsockname() 會說「真要出去的話會用哪張網卡」。代價是多網卡
    的機器只拿得到主要那一張 —— 另外那些要自己用 --hub 補。
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 53))
        return [s.getsockname()[0]]
    except OSError:
        return []
    finally:
        s.close()


def local_origins(port):
    """這台機器上，裝置牆可能被開成哪些 Origin。

    Origin 是瀏覽器自己填的 scheme://host:port，而同一頁在同一台機器上可以從
    好幾個名字開：localhost、127.0.0.1、主機名、區網 IP —— 對瀏覽器來說每一個
    都是不同的來源。獨立跑 helper 時這件事是人用 --hub 講的，也正是最常打錯的
    地方（差一個字就是 403，而且錯誤發生在瀏覽器裡）。嵌在 hub 裡就不必問了：
    hub 知道自己聽哪個埠。

    把區網 IP 放進白名單並沒有放寬任何權限。白名單管的是「哪一頁的 JS 叫得動
    **這台**的 helper」；同事在他自己的電腦上開 http://192.168.1.5:8787，他的
    瀏覽器打的是他自己的 127.0.0.1，從頭到尾碰不到這台。

    gethostname() 只是讀核心裡的那個字串，不做解析 —— 這條路不碰 DNS，理由見
    local_ips()。
    """
    names = ["127.0.0.1", "localhost", "[::1]", socket.gethostname(), hostname()]
    names += local_ips()
    out = []
    for n in names:
        if not n:
            continue
        host = "[%s]" % n if ":" in n and not n.startswith("[") else n
        o = "http://%s:%d" % (host.lower(), port)
        if o not in out:
            out.append(o)
    return out


class EmbeddedHelper:
    """起來了的內嵌 helper：要收掉它、要印連結、要回答 /api/helper 都靠這個。"""

    def __init__(self, httpd, port, token, origins):
        self.httpd = httpd
        self.port = port
        self.token = token
        self.origins = origins

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def printable_origins(origins):
    """白名單裡值得印給人看的那幾個。

    白名單要寬（多一個名字只是多一頁叫得動這台的 helper，而它本來就只服務這
    台），但印出來的連結要窄 —— 沒有人會手動去開一個 link-local 的 IPv6 網址，
    而九行連結會讓真正該點的那一行淹掉。
    """
    return [o for o in origins if "[" not in o]


def start_helper(hangar, args, hub_port):
    """在同一個 process 裡把 helper 也開起來 → (EmbeddedHelper, 起不來的原因)。

    起不來一律回一句人看得懂的原因，然後 hub 照常跑。最常見的是埠被佔住 ——
    多半是那台電腦上還有一支獨立的 helper 活著，而那種情況下按鈕其實是好的，
    根本不該把 hub 一起拖下水。
    """
    mod, err = load_helper()
    if mod is None:
        return None, err
    origins = local_origins(hub_port)
    for h in args.hub:
        o = mod.normalize_origin(h)
        if o not in origins:
            origins.append(o)
    token_file = args.helper_token_file or mod.TOKEN_FILE
    try:
        token = mod.load_token(token_file, args.new_helper_token)
    except OSError as e:
        return None, "寫不了 helper 的鑰匙檔 %s：%s" % (token_file, e)
    mod.Handler.state = mod.State(hangar, HELPER_LIST_TIMEOUT)
    mod.Handler.token = token
    mod.Handler.origins = tuple(origins)
    try:
        # 只綁 127.0.0.1，跟獨立跑的時候一模一樣。hub 的 --bind 不會傳到這裡：
        # 這一支會在這台電腦上開程式，沒有任何理由讓別台機器連得到它。
        httpd = mod.Server(("127.0.0.1", args.helper_port), mod.Handler)
    except OSError as e:
        if e.errno == errno.EADDRINUSE:
            why = ("127.0.0.1:%d 已經有人在用了（多半是另一支 helper 還在跑）"
                   % args.helper_port)
        else:
            why = "開不了 127.0.0.1:%d：%s" % (args.helper_port, e)
        return None, why
    port = httpd.socket.getsockname()[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return EmbeddedHelper(httpd, port, token, origins), None


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


def _mac_key(mac):
    """MAC 當索引鍵用的樣子。兩邊來源的大小寫不見得一樣（adb 給小寫、ARP 表
    在某些系統上給大寫），不正規化就會白白配不上。"""
    return mac.lower() if isinstance(mac, str) and mac else None


def _index(entry, by_profile, by_serial, by_mac):
    """把一張卡登記進三張索引，之後掃描結果才認得出它已經在牆上了。"""
    if entry.get("name"):
        by_profile[entry["name"]] = entry
    if entry.get("device_serial"):
        by_serial.setdefault(entry["device_serial"], entry)
    key = _mac_key(entry.get("mac"))
    if key:
        by_mac.setdefault(key, entry)


def merge(list_data, scan_data, usb_data=None):
    """把 list、scan、usb 三份資料合成一張裝置牆。

    識別碼的優先順序跟 hangar scan 那一層同一套：DEVICE_SERIAL > MAC > IP。
    序號是跨 IP、跨連線方式都不變的，所以只要 profile 記過序號，同一支手機在
    兩份資料裡就一定會合成同一張卡。

    掃描那邊是靠 profile 名字回報配對的，而它自己只認得 MAC 與 IP —— 走
    tailscale 的手機 profile 記的是 100.x，區網上掃到的是 192.168.x，兩邊對不
    上。所以這裡不只看 h["profile"]：序號（mDNS TXT 給得出來）與 MAC 對得上
    就是同一支手機，不能讓它在牆上多長出一張 unmanaged 的卡。

    第三份（usb）給得出 DEVICE_SERIAL，那本來就是這裡優先序最高的識別碼，
    所以已經設定過的手機會直接併回原本那張卡，只是多一個「USB 也接著」的事實。
    usb_data 可以是 None：--no-usb 或舊的呼叫端都還走得通。
    """
    devices = []
    by_profile = {}
    by_serial = {}
    by_mac = {}

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
            # USB 那一份對上了才有：{adb_serial, adb_state}
            "usb": None,
            "sources": ["list"],
            "errors": list(d.get("errors") or []),
        }
        devices.append(entry)
        _index(entry, by_profile, by_serial, by_mac)

    for h in (scan_data or {}).get("hosts", []):
        prof = h.get("profile")
        entry = by_profile.get(prof) if prof else None
        if entry is None:
            entry = (by_serial.get(h.get("device_serial"))
                     or by_mac.get(_mac_key(h.get("mac"))))
            if entry is not None:
                prof = entry["name"]
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
                "agent": None, "is_gateway": False, "usb": None,
                "sources": [], "errors": [],
            }
            devices.append(entry)
            _index(entry, by_profile, by_serial, by_mac)
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
                           "enrolled": (h.get("agent") or {}).get("enrolled")} if h.get("agent") else None),
                # 這個網段的閘道器。每次掃描都會出現，標出來才不用每次重新猜
                "is_gateway": bool(h.get("is_gateway")),
                "usb": None,
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
        scan_agent = h.get("agent") or {}
        current_agent = entry.get("agent") or {}
        if h.get("agent") and not current_agent.get("reachable"):
            # list 那邊沒問到（沒 token 或沒帶 --probe），但掃描看到它在聽
            entry["agent"] = {"reachable": True,
                              "version": scan_agent.get("version"),
                              "enrolled": scan_agent.get("enrolled")}
            if entry["state"] in ("no_adb", "offline"):
                entry["state"] = "agent_only"
        elif (h.get("agent") and current_agent.get("reachable")
              and current_agent.get("enrolled") is None
              and "enrolled" in scan_agent):
            # 舊版 list/probe 可能只知道 agent 可達，掃描的 hello 若帶出 enrolled，
            # 用它補齊狀態；已有明確值時仍以 profile token 的 probe 為準。
            current_agent["enrolled"] = scan_agent.get("enrolled")
        if "scan" not in entry["sources"]:
            entry["sources"].append("scan")

    # 第三份：這台機器上 USB 接著的。
    #
    # 這一份存在的理由是「插著 USB、偵錯開了、但還沒 setup」的手機在另外兩份
    # 裡都不算：list 只看 profile，scan 探的是 5555，而 5555 要 adb tcpip 才會
    # 開。使用者手上握著「我明明都開好了」這個強烈的反證，會往錯的方向查很久。
    #
    # 對不上 scan 那一列是已知的：那種手機的 MAC 通常是隨機的，scan 也拿不到
    # 序號，沒有任何共同的鍵。牆上會同時有一張匿名的掃描卡與一張 USB 卡 ——
    # 併不起來，但至少 USB 這張講得出它是誰。
    for u in (usb_data or {}).get("devices", []):
        serial = u.get("device_serial")
        entry = by_serial.get(serial) if serial else None
        if entry is None and u.get("profile"):
            entry = by_profile.get(u["profile"])
        usb_info = {"adb_serial": u.get("adb_serial"),
                    "adb_state": u.get("adb_state")}
        if entry is not None:
            entry["usb"] = usb_info
            # 機型：USB 問得到而另外兩邊問不到，是常有的（手機沒開 5555）
            if not entry.get("model") and u.get("model"):
                entry["model"] = u.get("model")
            if "usb" not in entry["sources"]:
                entry["sources"].append("usb")
            continue
        devices.append({
            "key": "serial:" + (serial or u.get("adb_serial") or ""),
            "name": u.get("profile"), "default": False,
            # unauthorized 是這一份最值錢的一格：「有人插了手機，但沒人去按
            # 那個允許」在這之前查不出來。排序表裡它本來就排第一位。
            "state": ("unauthorized" if u.get("adb_state") == "unauthorized"
                      else "unmanaged"),
            "transport": None,
            # 沒有 IP —— 這一份是牆上第一種沒有位址的卡
            "ip": None, "adb_serial": None,
            "device_serial": serial,
            "adb_state": u.get("adb_state"), "reachability": None,
            "model": u.get("model"), "android": None, "battery": None,
            "mirroring": False,
            "mac": None, "vendor": None, "mac_randomized": None, "mac_ssid": None,
            "adb_port": None, "lan_ip": None, "profile_ip_stale": False,
            "agent": None, "is_gateway": False,
            "usb": usb_info,
            "sources": ["usb"], "errors": [],
        })

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
    """三個輪詢執行緒寫、HTTP 執行緒讀的那份共用狀態。

    掃描比 list 慢很多（ping 整個 /24），USB 又比 list 更快，所以每一邊各自照
    自己的節奏跑，誰先回來就先更新誰 —— 網頁要的是「最新知道的樣子」，不是
    「三邊同時量到的樣子」。
    """

    def __init__(self):
        self._lock = threading.Lock()
        self.list_data = None
        self.scan_data = None
        self.usb_data = None
        self.list_at = None
        self.scan_at = None
        self.usb_at = None
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
            elif kind == "usb":
                self.usb_data, self.usb_at = data, time.time()
            else:
                self.scan_data, self.scan_at = data, time.time()

    def snapshot(self):
        with self._lock:
            devices = merge(self.list_data, self.scan_data, self.usb_data)
            errors = [{"source": k, "message": v} for k, v in self.errors.items()]
            # hangar 自己回報的錯誤（掃不動、缺工具…）也一起端上去
            for src, data in (("list", self.list_data), ("scan", self.scan_data),
                              ("usb", self.usb_data)):
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
                "polled_at": {"list": self.list_at, "scan": self.scan_at,
                              "usb": self.usb_at},
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
REFRESH_MIN = {"list": 5.0, "scan": 30.0, "usb": 5.0}


class Handler(BaseHTTPRequestHandler):
    server_version = "hangar-hub"
    state = None          # main() 會塞進來
    # 內嵌的 helper：埠、鑰匙，以及沒有的話是為什麼、下一步是什麼。
    # 下一步由這裡講而不是讓網頁去猜：--no-helper 要的是「跑一支 helper」，
    # --no-auto-pair 要的是「用印出來的連結」，兩件事完全不一樣，而網頁手上
    # 只有一句原因字串，去比對它的內容是遲早會走岔的做法。
    helper_port = None
    helper_token = None
    helper_note = "這個 hub 沒有內嵌 helper"
    helper_hint = ""

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            return self._file(os.path.join(STATIC_DIR, "index.html"), "text/html")
        if path == "/api/devices":
            return self._json(self.state.snapshot())
        if path == "/api/helper":
            return self._helper_info()
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

    def _is_loopback(self):
        """這個請求是不是從這台機器自己來的。

        來源位址偽造不了完整的 TCP handshake，所以這個判斷是真的擋得住的 ——
        跟「Origin 是瀏覽器填的所以偽造不了」同一個性質的保證。
        """
        try:
            addr = ipaddress.ip_address(self.client_address[0])
        except (ValueError, IndexError):
            return False
        # ::ffff:127.0.0.1 這種 IPv4-mapped 位址的 is_loopback 是 False，
        # 但它就是本機。雙堆疊的機器上很常見，要先攤回 IPv4 再問。
        addr = getattr(addr, "ipv4_mapped", None) or addr
        return addr.is_loopback

    def _helper_info(self):
        """這一頁要用的 helper 在哪、鑰匙是什麼。**只回答 loopback。**

        這是整個整合唯一多出來的端點，也是把「去 helper 的終端機複製那個
        #helper=… 連結」那一步拿掉的地方。

        代價要講清楚：它等於把 helper 的鑰匙交給「任何能從 loopback 打到 hub
        的東西」，繞過了鑰匙檔那個 0600。在自己的筆電上這不是新風險（本來就
        是同一個人），但在多人共用帳號的機器上是 —— 那種機器要帶
        --no-auto-pair（鑰匙只走啟動時印的那個連結）或乾脆 --no-helper。
        這個取捨是選的，不是忘的。
        """
        if not self._is_loopback():
            return self._json(403, {
                "ok": False,
                "reason": "動作按鈕只在跑 hub 的那台機器上按得動",
                "hint": "你這台要自己跑一支："
                        "./helper/hangar_helper.py --hub <這一頁的網址>"})
        if not self.helper_token:
            return self._json(404, {"ok": False, "reason": self.helper_note,
                                    "hint": self.helper_hint})
        return self._json({"ok": True, "port": self.helper_port,
                           "token": self.helper_token})

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
        # 裝置牆的 HTML 內含 inline JavaScript；若瀏覽器沿用舊頁面，新增的
        # 註冊按鈕可能看得到但事件處理器仍是舊版，表面上就像按了沒反應。
        self.send_header("Cache-Control", "no-store")
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
    ap.add_argument("--usb-interval", type=float, default=15.0,
                    help="多久問一次本機 USB（秒，預設 15 —— 只問本機 adb，很便宜）")
    ap.add_argument("--no-scan", action="store_true", help="完全不掃區網")
    ap.add_argument("--no-usb", action="store_true",
                    help="不回報這台機器上 USB 接著的裝置")
    ap.add_argument("--timeout", type=float, default=120.0, help="單次 hangar 的逾時（秒）")
    # ---- 內嵌的 helper ----
    # 只開這幾個旋鈕。--grace / --enroll-timeout 那些沿用 helper 自己的預設值：
    # 要細調就跑獨立的 helper，不要把同一張參數表維護兩份。
    ap.add_argument("--no-helper", action="store_true",
                    help="不要把 helper 一起帶起來（牆上的動作按鈕就得靠獨立的 helper）")
    ap.add_argument("--helper-port", type=int, default=8788,
                    help="內嵌 helper 的埠（預設 8788，0 = 隨便挑）")
    ap.add_argument("--no-auto-pair", action="store_true",
                    help="不要讓這一頁自動拿到鑰匙；改用啟動時印出的那個連結")
    ap.add_argument("--helper-token-file", default=None,
                    help="helper 的鑰匙放哪（預設跟獨立跑的時候同一個檔）")
    ap.add_argument("--new-helper-token", action="store_true",
                    help="換一把新的 helper 鑰匙（舊的連結就失效了）")
    ap.add_argument("--hub", action="append", default=[], metavar="網址",
                    help="額外的 Origin（走反向代理之類的情況才需要）。"
                         "這台機器自己的那些名字是自動認得的")
    args = ap.parse_args(argv)

    hangar = os.path.abspath(args.hangar)
    if not os.access(hangar, os.X_OK):
        print("找不到可執行的 hangar：%s" % hangar, file=sys.stderr)
        return 1

    state = State()
    stop = threading.Event()
    threads = []

    # 每個來源一個喚醒旗標。poller 等在它上面，/api/refresh 把它立起來。
    for kind in ("list", "scan", "usb"):
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
    if args.no_usb:
        state.wake.pop("usb", None)       # 沒人服務的旗標不要留著騙人
    else:
        # 牆上看得到的是「插在 hub 這台機器上的 USB」，不是「插在任何人電腦上
        # 的」—— 跟掃描是同一個視角問題（掃的也一直是 hub 所在的網段）。
        threads.append(threading.Thread(
            target=poller, args=(state, "usb", hangar, ["usb", "--json"],
                                 args.usb_interval, args.timeout, stop), daemon=True))
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

    # helper 要等 hub 綁好才起得來：Origin 白名單要知道實際的埠（--port 0 的
    # 時候那是核心挑的）。hub 綁不上就整個收掉了，也不會走到這裡。
    helper = None
    if args.no_helper:
        Handler.helper_note = "這個 hub 是帶著 --no-helper 跑的"
        Handler.helper_hint = ("拿掉那個旗標，或在要按按鈕的那台電腦上跑一支 "
                               "helper/hangar_helper.py")
    else:
        helper, why = start_helper(hangar, args, port)
        if helper is None:
            Handler.helper_note = why
            Handler.helper_hint = "看 hub 那個視窗印出來的訊息"
            print("沒有把 helper 一起帶起來：%s" % why, file=sys.stderr, flush=True)
            print("  牆上的動作按鈕要那台電腦自己跑一支："
                  "./helper/hangar_helper.py --hub http://%s:%d" % (host, port),
                  file=sys.stderr, flush=True)
        elif args.no_auto_pair:
            Handler.helper_note = "這個 hub 是帶著 --no-auto-pair 跑的"
            Handler.helper_hint = "用它印出來的那個 #helper=… 連結進來一次"
            print("helper 也起來了：127.0.0.1:%d（只有這台電腦連得到）"
                  % helper.port, flush=True)
            print("自動配對關著，在這台電腦的瀏覽器開這個連結一次：", flush=True)
            for o in printable_origins(helper.origins):
                print("  %s/#helper=%s&port=%d" % (o, helper.token, helper.port),
                      flush=True)
        else:
            Handler.helper_port = helper.port
            Handler.helper_token = helper.token
            print("helper 也起來了：127.0.0.1:%d —— 這台電腦上的投影、響鈴與"
                  "偵錯按鈕直接可用（不必再開帶鑰匙的連結）" % helper.port,
                  flush=True)

    if args.bind not in ("127.0.0.1", "localhost", "::1"):
        print("注意：綁在 %s，同網段的人都看得到這頁裝置牆" % args.bind,
              file=sys.stderr, flush=True)
        print("　　　動作按鈕沒有跟著開放：helper 只綁 127.0.0.1，別台電腦要"
              "自己跑一支", file=sys.stderr, flush=True)
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
        if helper is not None:
            helper.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

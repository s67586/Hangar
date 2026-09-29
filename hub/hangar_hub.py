#!/usr/bin/env python3
"""Hangar hub —— 常駐服務 + 裝置牆。

跑在一台跟測試機同一個區網的常駐機器上，定期問 hangar 兩件事：

    hangar list --json --probe   已經設定過的手機：adb 狀態、機型、電量
    hangar scan --json           區網上看得到的所有東西：IP、MAC、廠商、5555

然後把兩份資料合成一張裝置牆。**輪詢是唯讀的**：不帶 --fix-ip（那會寫 profile，
固定輪詢的程式不該無條件做），也不會自己去動手機。

會動手機的只有兩個**有人按了才跑**的動作：響鈴與切偵錯（`POST /api/ring`、
`POST /api/adb`）。它們要一把**每人一把**的鑰匙（`--grant <名字>` 發），每一次
都記進操作紀錄 —— 這樣裝置牆只開在 hub 這一台，別台電腦、手機、平板開瀏覽器
就按得動，不必各自跑 helper、各自 setup。投影不在這裡：視窗得開在看的人面前，
那仍然是 helper 的事。

只用標準函式庫，理由跟 hangar 自己是一支無相依 bash script 一樣：常駐機器上
不該為了看一頁網頁而先裝一套生態系。

    ./hub/hangar_hub.py --hangar ./hangar
    ./hub/hangar_hub.py --bind 0.0.0.0 --port 8787     # 給同事看要明講

端點：

    GET  /                裝置牆（HTML）
    GET  /api/devices     合併後的裝置清單（JSON）
    GET  /api/helper      內嵌的 helper 在哪、鑰匙是什麼（**只回答 loopback**）
    GET  /api/whoami      這把鑰匙是誰、能按哪些動作
    POST /api/refresh     現在就去問一次（?what=list|scan|all）
    POST /api/ring        讓一支手機響鈴（要鑰匙）
    POST /api/adb         開／關偵錯（要鑰匙；全手動，不會自己改回去）
    GET  /healthz         還活著嗎

另外一個**選擇性**的 listener（`--checkin HOST:PORT`，預設不開）：

    POST /api/checkin     手機上的 agent 主動回報（Bearer = 入伍時的 token）

它存在是為了跨網段：hub 連不到手機的時候（路由、VLAN、防火牆只放單向），
手機往 hub 那一邊常常是通的。回報的東西只放在記憶體、不寫任何設定檔，
而且是另一個埠 —— 讓手機回報不等於把整面牆開給同網段的人看。

預設會把 helper 一起帶起來（`--no-helper` 關掉），但那是**另一個 listener**，
而且照樣只綁 127.0.0.1：投影與入伍仍然走它。

    ./hub/hangar_hub.py --grant alice               # 發一把鑰匙，印出帶鑰匙的連結
    ./hub/hangar_hub.py --grant qa --can ring,adb_off
    ./hub/hangar_hub.py --keys                      # 誰有鑰匙
    ./hub/hangar_hub.py --revoke alice              # 收回（不用重開 hub）
"""

import argparse
import errno
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import os
import re
import secrets
import socket
import socketserver
import stat
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
# 10：每張卡多一個 last_action（從牆上按的動作，每種留最後一次：
#     {"adb": {at, who, ok, message, enabled}, "ring": {…, seconds}}，沒按過是 null）。
# 11：same_device（同一個序號的其他 profile 名字）與 adb_conflict。
# 12：debug_enabled（adb 直接讀的偵錯開關，問不到是 null）；adb_conflict 改成
#     「agent 讀到的跟 adb 讀到的不一樣」，不再從「adb 連得上」推論。
# 13：agent.adb.source（settings / agent_write / unknown），牆上用來講「這是 agent
#     最後寫的值」或「有人在手機上切過，不知道」。
API_SCHEMA = 13

# agent 主動回報（check-in）。
#
# CHECKIN_NEXT_S 是 hub 回給手機的「下次什麼時候再來」；過了三倍還沒來就不算
# 新鮮 —— 一次沒送到（Wi-Fi 換手、手機睡著）不該讓卡片馬上變紅。
CHECKIN_NEXT_S = 60
CHECKIN_FRESH_S = 3 * CHECKIN_NEXT_S
CHECKIN_MIN_INTERVAL = 10.0     # 同一支手機最快多久收一次
CHECKIN_MAX_BODY = 4096
# token 表多久重讀一次：剛入伍的手機第一次來回報時，表裡還沒有它
TOKENS_REFRESH_S = 10.0

# 跟 hangar 的 BATTERY_LOW 對齊。兩邊要是各有一套，同一支手機在 CLI 跟網頁上
# 會給出不同的答案。
BATTERY_LOW = 20

# 牆上的動作（響鈴、切偵錯）。
#
# 鑰匙檔跟 profile 放在同一個設定目錄：它跟 profile 一樣是「這台 hub 的東西」。
# 檔案裡只存 sha256，不存鑰匙本身 —— 鑰匙只在 --grant 的那一刻印一次。
CONFIG_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "hangar")
KEYS_FILE = os.path.join(CONFIG_DIR, "hub-keys.json")
ACTION_LOG = os.path.join(CONFIG_DIR, "hub-actions.log")
# 能力分三格，因為三個動作的風險不一樣：響鈴會自己停；關偵錯之後 agent 是唯一
# 回得去的路；開偵錯等於遠端把 adb 打開。預設三格都給，要收窄用 --can。
CAPS = ("ring", "adb_off", "adb_on")
# 名字會印在牆上、寫進紀錄，也會出現在 --revoke 的指令列上
KEY_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
# 按鈕是有人在等的：一次響鈴／切偵錯跑超過這麼久就當失敗。60 秒是給「開啟偵錯」
# 的：開回來之後 hangar adb 會等 adbd 重啟、重連 5555，那一段要重試好幾次
ACTION_TIMEOUT = 60.0
ACTION_MAX_BODY = 4096


# ----------------------------------------------------------- 內嵌 helper ----
#
# 裝置牆上的投影與入伍按鈕不是 hub 在做 —— 那些事得發生在**按按鈕的那台電腦**
# 上，所以做事的是 helper（響鈴與切偵錯後來搬到 hub 了，見「動作」那一段）。
# 但最常見的情形是 hub 跟 helper 在同一台（自己的筆電），那時候「兩個 process」只剩成本：兩個終端機、
# --hub 要跟網址列一字不差、還要去開那個帶 token 的連結。
#
# 所以這裡把 helper 帶進同一個 process —— 但**只是同一個 process，不是同一個
# listener**。helper 照樣自己綁 127.0.0.1，照樣走它那三道鎖；helper 的端點不會
# 出現在 hub 上（hub 自己的響鈴／切偵錯走鑰匙，見 Handler._action）。要拆開跑
# （hub 在角落常駐機、每人一支 helper）也完全沒變：helper/hangar_helper.py 一行都沒動。

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


# ------------------------------------------------------------------ 鑰匙 ----
#
# 裝置牆開給同事之後，「誰在按」這題就躲不掉了。答案刻意做得很小：
#
#   每人一把    共用一把密碼的話，紀錄上只會寫「有人」，人走了也收不回來
#   只存雜湊    鑰匙檔被讀走不等於鑰匙被拿走
#   每次都重讀  --revoke 之後不用重開 hub 就生效
#
# 鑰匙走 Authorization 標頭，瀏覽器那邊存在 localStorage。區網上是明文 HTTP，
# 同網段聽得到 —— 這是選的代價，文件裡要講。

def _key_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def load_keys(path):
    """讀鑰匙檔 → [{name, sha256, can, created}]。沒有檔案就是沒有人。

    讀壞了（半寫的檔、手改壞）回空的：寧可所有人都按不動，也不要猜。
    """
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    out = []
    for k in (data or {}).get("keys", []) if isinstance(data, dict) else []:
        if (isinstance(k, dict) and isinstance(k.get("name"), str)
                and isinstance(k.get("sha256"), str)):
            can = [c for c in (k.get("can") or []) if c in CAPS]
            out.append({"name": k["name"], "sha256": k["sha256"], "can": can,
                        "created": k.get("created")})
    return out


def save_keys(path, keys):
    """整份寫回去：先寫暫存檔（0600）再換名字，不會留下寫到一半的檔。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"schema": 1, "keys": keys}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def grant_key(path, name, can):
    """發一把新鑰匙 → 鑰匙本身。同名的舊鑰匙會被換掉（等於重發）。"""
    token = secrets.token_hex(16)
    keys = [k for k in load_keys(path) if k["name"] != name]
    keys.append({"name": name, "sha256": _key_hash(token), "can": list(can),
                 "created": int(time.time())})
    save_keys(path, keys)
    return token


def revoke_key(path, name):
    keys = load_keys(path)
    left = [k for k in keys if k["name"] != name]
    if len(left) == len(keys):
        return False
    save_keys(path, left)
    return True


def find_key(path, token):
    """這把鑰匙是誰的 → 那一筆，或 None。"""
    if not token:
        return None
    want = _key_hash(token)
    for k in load_keys(path):
        if hmac.compare_digest(k["sha256"], want):
            return k
    return None


def parse_caps(v):
    """--can ring,adb_off → ("ring", "adb_off")。all 是三格全給。"""
    if v.strip() == "all":
        return CAPS
    out = []
    for c in v.replace("-", "_").split(","):
        c = c.strip()
        if not c:
            continue
        if c not in CAPS:
            raise ValueError(c)
        if c not in out:
            out.append(c)
    if not out:
        raise ValueError(v)
    return tuple(out)


# ------------------------------------------------------------------ 動作 ----
#
# 做事的仍然是 CLI：`hangar ring` / `hangar adb`，跟 helper 代跑的是同一行。
# hub 這裡只多了三件事：誰按的（鑰匙）、記下來（紀錄）、同一支不要同時被按兩次。
#
# 用的是 **hub 自己**的 profile 與 agent token。這正是把動作搬到 hub 的理由：
# 按的人那台電腦上什麼都不用有 —— 不用 setup、不用 helper、甚至不用是電腦。

TIDY_ANSI = re.compile(r"\x1b\[[0-9;]*m")
# hangar 印給人看的行首記號（err / warn / info / ok）
TIDY_MARKER = re.compile(r"^\s*(?:xx|!!|==>|ok)\s+")


def tidy(text, keep=4):
    """把 hangar 的輸出整理成能放上網頁的幾行（跟 helper 那一份同一個規矩）。"""
    lines = []
    for raw in (text or "").splitlines():
        line = TIDY_MARKER.sub("", TIDY_ANSI.sub("", raw)).strip()
        if line:
            lines.append(line)
    return lines[-keep:]


def run_action(hangar, args, profile, timeout):
    """跑一次 `hangar <args> -p <profile>` → (成功嗎, 訊息, 細節幾行)。"""
    try:
        p = subprocess.run([hangar] + args + ["-p", profile],
                           stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, errors="replace", timeout=timeout)
    except FileNotFoundError:
        return False, "找不到 hangar：%s" % hangar, []
    except subprocess.TimeoutExpired:
        return False, "動作逾時（超過 %g 秒）" % timeout, []
    except OSError as e:
        return False, "跑不起來 hangar：%s" % e, []
    detail = tidy((p.stdout or "") + "\n" + (p.stderr or ""), keep=8)
    if p.returncode == 0:
        return True, detail[-1] if detail else "完成", detail
    return False, (detail[-1] if detail
                   else "失敗（hangar 離開碼 %d）" % p.returncode), detail


class Actions:
    """牆上按下去的那些動作：同一支手機一次一個、每次都記下來。"""

    def __init__(self, hangar, log_path, timeout=ACTION_TIMEOUT):
        self.hangar = hangar
        self.log_path = log_path
        self.timeout = timeout
        self._lock = threading.Lock()
        self._busy = set()
        # profile → {動作 → 最後一次的 {at, who, ok, message, …}}。按動作分開
        # 記：後來按的一次響鈴不該把「偵錯是誰關的」蓋掉。只放記憶體；完整的
        # 歷史在紀錄檔裡
        self.last = {}

    def claim(self, profile):
        with self._lock:
            if profile in self._busy:
                return False
            self._busy.add(profile)
            return True

    def release(self, profile):
        with self._lock:
            self._busy.discard(profile)

    def record(self, entry):
        """記一筆。寫不進紀錄檔不擋動作 —— 但要在 hub 的視窗裡講。"""
        with self._lock:
            self.last.setdefault(entry["profile"], {})[entry["action"]] = {
                k: entry[k] for k in ("at", "who", "ok", "message", "seconds", "enabled")
                if k in entry}
        if not self.log_path:
            return
        try:
            os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except OSError as e:
            print("寫不進操作紀錄 %s：%s" % (self.log_path, e),
                  file=sys.stderr, flush=True)

    def snapshot(self):
        with self._lock:
            return {p: {a: dict(e) for a, e in v.items()} for p, v in self.last.items()}


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


def merge(list_data, scan_data, usb_data=None, checkins=None, now=None,
          adb_seen=None, actions=None):
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

    第四份（checkins）是 agent 主動回報的：序號 → State.checkin() 存下的那一筆。
    token 驗過才會存，所以它的序號可以直接拿來對卡片。

    adb_seen 是 State 記下的「每支手機最後一次看到的偵錯開關」（序號 →
    {enabled, at}）。agent 叫不動的那一輪，list 就不會帶 agent.adb，只有靠它
    才知道這支是不是「偵錯關著又沒人叫得動」—— 見 _stranded()。

    actions 是 Actions.snapshot()（profile → 每種動作最後一次）。偵錯是
    長期狀態、不會自己改回去，所以「是誰、什麼時候關的」要跟著卡片走。
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
            # 偵錯開關的硬證據：adb 直接讀的（hangar list 的 debug_enabled）
            "debug_enabled": d.get("debug_enabled"),
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
                # 跨網段逐台探埠找到的（hangar scan 的 routed）：沒有 MAC
                "routed": bool(h.get("routed")),
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
        entry["routed"] = bool(h.get("routed"))
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
    # 對 scan 那一列靠的是 Wi-Fi IP：那種手機的 MAC 通常是隨機的，scan 也拿不到
    # 序號，唯一的共同點是 USB 問手機自己要來的 IP 等於掃描看到的那個位址。
    # 問不到 IP（未授權、沒連 Wi-Fi、連的是別的網段）就併不起來 —— 牆上會同時
    # 有一張匿名的掃描卡與一張 USB 卡，但至少 USB 這張講得出它是誰。
    scan_by_ip = {d["lan_ip"]: d for d in devices
                  if not d["name"] and d.get("lan_ip") and d["sources"] == ["scan"]}
    for u in (usb_data or {}).get("devices", []):
        serial = u.get("device_serial")
        entry = by_serial.get(serial) if serial else None
        if entry is None and u.get("profile"):
            entry = by_profile.get(u["profile"])
        usb_info = {"adb_serial": u.get("adb_serial"),
                    "adb_state": u.get("adb_state"),
                    # 手機自己說的：連著哪個 Wi-Fi、在上面是哪個位址
                    "wifi_ssid": u.get("wifi_ssid"),
                    "wifi_ip": u.get("wifi_ip")}
        if entry is None and u.get("wifi_ip") in scan_by_ip:
            # 匿名的掃描卡原來就是這支：認領它，換上序號當主鍵 —— 掃描那一輪
            # 沒回應時卡片才不會換一把鑰匙、把按到一半的狀態弄丟
            entry = scan_by_ip.pop(u["wifi_ip"])
            if serial:
                entry["key"] = "serial:" + serial
                entry["device_serial"] = serial
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
            # 問得到 Wi-Fi 位址就用它；未授權或沒連 Wi-Fi 的就沒有位址
            "ip": u.get("wifi_ip"), "adb_serial": None,
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

    # 第四份：agent 主動回報的。
    #
    # 這一份的意義是「hub 連不到手機，但手機連得到 hub」：list 那邊問不到、
    # 掃描也掃不到，只有這裡知道它還活著、現在在哪個位址。
    #
    # agent.reachable **不**因為回報而變成 true —— reachable 的意思是「這台電腦
    # 問得到它」，響鈴、切偵錯都靠那條路。收得到回報只代表反方向是通的。
    now = time.time() if now is None else now
    for serial, c in (checkins or {}).items():
        entry = by_serial.get(serial) or by_profile.get(c.get("profile"))
        age = now - c["at"]
        fresh = age < CHECKIN_FRESH_S
        p = c.get("payload") or {}
        if entry is None:
            # list 那一輪剛好失敗：跟掃描那邊同一個道理，叫得出名字比較好
            entry = _blank_entry(serial, c.get("profile"))
            devices.append(entry)
            _index(entry, by_profile, by_serial, by_mac)
        entry["checkin"] = {"at": c["at"], "age_s": int(age), "fresh": fresh,
                            "peer_ip": c.get("peer_ip"), "ips": c.get("ips") or []}
        if "checkin" not in entry["sources"]:
            entry["sources"].append("checkin")
        if not fresh:
            continue
        if entry["state"] in ("no_adb", "offline", "unknown"):
            entry["state"] = "agent_only"
        if not entry.get("battery") and p.get("battery"):
            b = dict(p["battery"])
            b["source"] = "checkin"
            entry["battery"] = _battery(b)
        for k in ("model", "android"):
            if not entry.get(k) and p.get(k):
                entry[k] = p[k]
        if not entry.get("agent"):
            entry["agent"] = {"reachable": False, "version": p.get("version"),
                              "enrolled": True}
        # 手機自己說它現在在哪些位址。profile 指著的那個不在裡面 = profile 舊了
        # （只標，不修：hub 不寫設定檔）
        ips = c.get("ips") or []
        if (ips and entry.get("transport") == "lan" and entry.get("ip")
                and entry["ip"] not in ips):
            entry["profile_ip_stale"] = True
        if not entry.get("ip") and ips:
            entry["ip"] = ips[0]

    # 同一支手機有好幾份 profile：每份各自是一張卡（各自的連線方式、token），
    # 刻意不合成一張 —— 合了之後按下去不知道該走哪一份。但要讓人看得見
    names_by_serial = {}
    for d in devices:
        if d.get("name") and d.get("device_serial"):
            names_by_serial.setdefault(d["device_serial"], []).append(d["name"])

    for d in devices:
        d.setdefault("routed", False)
        d.setdefault("checkin", None)
        d.setdefault("debug_enabled", None)
        d["same_device"] = [n for n in names_by_serial.get(d.get("device_serial"), [])
                            if n != d.get("name")]
        d["adb_conflict"] = _adb_conflict(d)
        d["stranded"] = _stranded(d, adb_seen or {})
        d["last_action"] = (actions or {}).get(d["name"]) if d.get("name") else None

    # 排序：要注意的排前面（偵錯關著又叫不動 > 電量低 > 設定過的 > 掃到的），
    # 同類再按名稱／IP
    order = {"unauthorized": 0, "no_adb": 1, "offline": 2, "unknown": 3,
             "agent_only": 4, "ready": 5, "unmanaged": 6}

    def sort_key(d):
        # 偵錯關著又叫不動的排最前面，比電量低還前面：電量低等得起，這支不去
        # 碰它就永遠回不來
        if d.get("stranded"):
            return (0, 0, 0, d.get("name") or "", _ip_key(d.get("ip") or ""))
        low = 1 if (d.get("battery") or {}).get("low") else 2
        # 閘道器排在同類的最後面：它每次都在，而且永遠不是要找的那台
        return (low, order.get(d["state"], 9), 1 if d.get("is_gateway") else 0,
                d.get("name") or "", _ip_key(d.get("ip") or ""))

    devices.sort(key=sort_key)
    return devices


def _adb_conflict(d):
    """agent 讀到的偵錯開關，跟 adb 直接讀的不一樣。

    adb 讀的那份（debug_enabled）才是硬證據。Pixel 8a / Android 17 實測：app
    讀 adb_enabled 永遠不是 1，所以 agent 在那台上一律說「關閉」。反過來，
    「adb 連得上」**不是**證據 —— 關掉 adb_enabled 只停 USB 那一頭，5555 照樣
    連得上。所以這裡只比兩份讀值，不從連線狀態推論。
    """
    agent_says = ((d.get("agent") or {}).get("adb") or {}).get("enabled")
    real = d.get("debug_enabled")
    return isinstance(agent_says, bool) and isinstance(real, bool) and agent_says != real


def _stranded(d, adb_seen):
    """「agent 沒回話 ＋ 偵錯關著」：要有人走過去的那一種。

    M4 沒有自動復原（見 ROADMAP「為什麼沒有自動復原」），所以偵錯被關掉之後，
    唯一開得回來的路就是 agent。agent 也叫不動 = 遠端沒有任何一條路回得去。
    這裡只負責讓它**看得見**，不做任何狀態變更。

    偵錯開關用的是 hub 最後一次看到的值：agent 叫不動的那一輪本來就問不到。
    adb 此刻是通的（網路或 USB）就不算：偵錯就算關著，也還有 adb 這條路開得回來。
    """
    agent = d.get("agent")
    if not agent or agent.get("reachable") is True:
        return None
    if d.get("adb_state") == "device" or (d.get("usb") or {}).get("adb_state") == "device":
        return None
    seen = adb_seen.get(d.get("device_serial"))
    if not seen or seen.get("enabled") is not False:
        return None
    return {"adb_seen_off_at": seen["at"]}


def record_adb_seen(adb_seen, list_data, now):
    """從一輪 list --json 更新 adb_seen（就地改）。

    只在「真的知道」的時候寫：adb 直接讀得到（debug_enabled），或 agent 答得出
    adb.enabled。叫不動的那一輪什麼都不寫 —— 最後一次知道的值要留著。
    """
    for d in (list_data or {}).get("devices", []):
        serial = d.get("device_serial")
        if not serial:
            continue
        agent = d.get("agent") or {}
        enabled = (agent.get("adb") or {}).get("enabled") if agent.get("reachable") else None
        # adb 直接讀的那份優先（見 _adb_conflict）。「adb 連得上」不算：偵錯關了
        # 5555 也可能還連著
        if isinstance(d.get("debug_enabled"), bool):
            adb_seen[serial] = {"enabled": d["debug_enabled"], "at": now}
        elif isinstance(enabled, bool):
            adb_seen[serial] = {"enabled": enabled, "at": now}


def _blank_entry(serial, profile):
    """只有序號與名字的一張卡：其他來源都還沒給資料時用。"""
    return {
        "key": "serial:" + serial, "name": profile, "default": False,
        "state": "unknown", "transport": None, "ip": None, "adb_serial": None,
        "device_serial": serial, "adb_state": None, "reachability": None,
        "model": None, "android": None, "battery": None, "mirroring": False,
        "mac": None, "vendor": None, "mac_randomized": None, "mac_ssid": None,
        "adb_port": None, "lan_ip": None, "profile_ip_stale": False,
        "agent": None, "is_gateway": False, "usb": None,
        "sources": [], "errors": [],
    }


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
        # agent 主動回報：序號 → {at, profile, peer_ip, ips, payload}
        self.checkins = {}
        self.checkin_at = None
        # 每支手機最後一次看到的偵錯開關：序號 → {enabled, at}。只放記憶體 ——
        # hub 重開之後，要等 agent 再答一次話才知道
        self.adb_seen = {}
        # 牆上的動作（main() 會塞進來）。只拿來把「最後一次按了什麼」端上牆
        self.actions = None
        # 驗 check-in 用的 token 表：序號 → (profile, token)。由 hangar agent-tokens 來
        self.hangar = None
        self.tokens = {}
        self.tokens_at = 0.0
        self.tokens_err = None
        self._tokens_lock = threading.Lock()

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
                record_adb_seen(self.adb_seen, data, self.list_at)
            elif kind == "usb":
                self.usb_data, self.usb_at = data, time.time()
            else:
                self.scan_data, self.scan_at = data, time.time()

    # ---- check-in ----

    def load_tokens(self, force=False):
        """重讀 token 表。太常叫就跳過（除非 force）；讀不到就沿用舊的。

        token 不經過 list --json：那一份會整包端到網頁上。這裡是 hub 自己要用
        的，跟 profile 在同一台、同一個使用者，讀它沒有擴大任何人看得到的東西。
        """
        with self._tokens_lock:
            if not force and time.time() - self.tokens_at < TOKENS_REFRESH_S:
                return
            self.tokens_at = time.time()
            data, err = run_hangar(self.hangar, ["agent-tokens", "--json"], 30)
            if err:
                self.tokens_err = err
                return
            tokens = {}
            for t in (data or {}).get("tokens", []):
                if t.get("device_serial") and t.get("token"):
                    tokens[t["device_serial"]] = (t.get("profile"), t["token"])
            self.tokens, self.tokens_err = tokens, None

    def checkin(self, payload, token, peer, now=None):
        """收一筆回報 → (HTTP 狀態, 回應)。

        序號不認得與 token 不對回的是同一個 401：分開回的話，任何人都能拿這個
        端點去試「這台 hub 認得哪些序號」。
        """
        now = time.time() if now is None else now
        serial = payload.get("device_serial")
        if not isinstance(serial, str) or not serial:
            return 400, {"ok": False, "error": "bad_request",
                         "reason": "少了 device_serial"}
        known = self.tokens.get(serial)
        if known is None:
            # 剛入伍的手機：表是入伍之前讀的。重讀一次（有節流）再看
            self.load_tokens()
            known = self.tokens.get(serial)
        if (known is None or not token
                or not hmac.compare_digest(known[1].encode(), token.encode())):
            return 401, {"ok": False, "error": "unauthorized",
                         "reason": "序號或 token 對不上這台 hub 的 profile"}
        with self._lock:
            last = self.checkins.get(serial)
            if last and now - last["at"] < CHECKIN_MIN_INTERVAL:
                return 429, {"ok": False, "error": "too_many_requests",
                             "retry_after_s": round(CHECKIN_MIN_INTERVAL - (now - last["at"]), 1),
                             "next_s": CHECKIN_NEXT_S}
            self.checkins[serial] = {
                "at": now, "profile": known[0], "peer_ip": peer,
                "ips": _clean_ips(payload.get("ips")),
                "payload": {k: payload.get(k) for k in
                            ("version", "model", "android", "battery", "adb")
                            if isinstance(payload.get(k), (str, dict))},
            }
            self.checkin_at = now
            # 回報裡的偵錯開關一樣是手機自己說的，當成「看到過」
            enabled = (payload.get("adb") or {}).get("enabled") \
                if isinstance(payload.get("adb"), dict) else None
            if isinstance(enabled, bool):
                self.adb_seen[serial] = {"enabled": enabled, "at": now}
        return 200, {"ok": True, "next_s": CHECKIN_NEXT_S}

    def profile(self, name):
        """hub 這台上叫這個名字的 profile（上一輪 list 的那一筆），沒有就 None。

        動作只准打在這一份清單裡的名字上：它是要被接到 hangar 指令列上的字串，
        不能讓瀏覽器送什麼就跑什麼。
        """
        with self._lock:
            for d in (self.list_data or {}).get("devices", []):
                if d.get("profile") == name:
                    return dict(d)
        return None

    def saw_adb(self, serial, enabled):
        """剛從牆上切完偵錯：不用等下一輪 list，牆上馬上就該是新的樣子。"""
        if not serial:
            return
        with self._lock:
            self.adb_seen[serial] = {"enabled": enabled, "at": time.time()}

    def snapshot(self):
        with self._lock:
            devices = merge(self.list_data, self.scan_data, self.usb_data,
                            self.checkins, adb_seen=self.adb_seen,
                            actions=self.actions.snapshot() if self.actions else None)
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
                # 掃了哪幾個 /24、哪幾個是跨網段逐台探的（舊版 hangar 沒有這欄）
                "subnets": (self.scan_data or {}).get("subnets"),
                "polled_at": {"list": self.list_at, "scan": self.scan_at,
                              "usb": self.usb_at, "checkin": self.checkin_at},
                # 現在有沒有哪一邊正在問。網頁靠這個把「更新中」顯示出來 ——
                # 按了按鈕之後畫面要有反應，不然使用者會再按一次。
                "polling": {k: bool(v) for k, v in self.busy.items()},
                "errors": errors,
            }


def _clean_ips(v):
    """手機報上來的位址：只收 IPv4、最多 8 個。這是別人送來的資料。"""
    out = []
    for x in v if isinstance(v, list) else []:
        try:
            ip = ipaddress.ip_address(x)
        except (ValueError, TypeError):
            continue
        if ip.version == 4 and not ip.is_loopback and str(ip) not in out:
            out.append(str(ip))
    return out[:8]


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
    # 牆上的動作。keys_file 每次都重讀（--revoke 馬上生效）；trust_loopback 是
    # 「在 hub 這台自己開的那一頁不用鑰匙」—— 跟 /api/helper 同一個信任、同一個
    # 開關（--no-auto-pair 一起關掉）
    actions = None
    keys_file = KEYS_FILE
    trust_loopback = True
    extra_origins = ()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            return self._file(os.path.join(STATIC_DIR, "index.html"), "text/html")
        if path == "/api/devices":
            return self._json(self.state.snapshot())
        if path == "/api/helper":
            return self._helper_info()
        if path == "/api/whoami":
            return self._whoami()
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
        if path in ("/api/ring", "/api/adb"):
            return self._action(path[len("/api/"):])
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

    # ---- 牆上的動作 ----

    def _actor(self):
        """按按鈕的是誰 → {name, can, via}，認不出來就 None。

        Bearer 鑰匙優先：就算在 hub 這台上，帶了鑰匙就記那把鑰匙的名字。
        """
        auth = self.headers.get("Authorization") or ""
        token = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
        if token:
            k = find_key(self.keys_file, token)
            if k is None:
                return None
            return {"name": k["name"], "can": list(k["can"]), "via": "key"}
        if self.trust_loopback and self._is_loopback():
            return {"name": "%s（本機）" % hostname(), "can": list(CAPS),
                    "via": "loopback"}
        return None

    def _origin_ok(self):
        """從瀏覽器來的寫入，只接受這面牆自己那一頁。

        Origin 是瀏覽器填的，別的網站上的 JS 偽造不了；它要等於這個請求自己打
        的那個位址（Host），或是 --hub 明講過的（反向代理）。沒帶 Origin 的是
        curl 之類，不歸瀏覽器的規則管 —— 那種靠鑰匙擋。
        """
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        host = self.headers.get("Host") or ""
        return origin.lower() in (("http://" + host).lower(),) + tuple(self.extra_origins)

    def _whoami(self):
        who = self._actor()
        if who is None:
            has_key = bool(self.headers.get("Authorization"))
            return self._json(401, {
                "ok": False,
                "reason": "這把鑰匙不認得（可能被收回了）" if has_key
                          else "這一頁沒有鑰匙，響鈴與切偵錯按不動",
                "hint": "請管 hub 的人跑 hangar wall --grant <你的名字>，"
                        "用它印出來的連結進來一次"})
        return self._json({"ok": True, "name": who["name"], "can": who["can"],
                           "via": who["via"]})

    def _action(self, what):
        """POST /api/ring 或 /api/adb。"""
        if not self._origin_ok():
            return self._json(403, {"ok": False,
                                    "reason": "這個請求不是從這面牆送出來的"})
        who = self._actor()
        if who is None:
            return self._json(401, {
                "ok": False, "reason": "沒有鑰匙，或鑰匙已經被收回",
                "hint": "請管 hub 的人跑 hangar wall --grant <你的名字>"})
        # 只收 JSON：跨來源的 JSON POST 一定會先被瀏覽器 preflight，而這裡不回
        # OPTIONS —— 別的網站就算拿得到鑰匙也送不進來
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            return self._json(415, {"ok": False, "reason": "body 要是 application/json"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > ACTION_MAX_BODY:
            return self._json(400, {"ok": False, "reason": "body 太大或 Content-Length 不合法"})
        try:
            body = json.loads(self.rfile.read(n).decode("utf-8") or "{}") if n else {}
        except (ValueError, UnicodeDecodeError):
            return self._json(400, {"ok": False, "reason": "body 不是 JSON"})
        if not isinstance(body, dict):
            return self._json(400, {"ok": False, "reason": "body 必須是 JSON 物件"})

        name = body.get("profile")
        if not isinstance(name, str) or not name.strip():
            return self._json(400, {"ok": False, "reason": "要給 profile"})
        name = name.strip()

        if what == "ring":
            seconds = body.get("seconds", 30)
            if isinstance(seconds, bool) or not isinstance(seconds, int) or seconds < 0:
                return self._json(400, {"ok": False, "reason": "seconds 必須是非負整數"})
            seconds = min(seconds, 120)
            need = "ring"
            args = ["ring", "--seconds", str(seconds)]
            label = "響鈴 %d 秒" % seconds if seconds else "停止響鈴"
        else:
            enabled = body.get("enabled")
            if not isinstance(enabled, bool):
                return self._json(400, {"ok": False, "reason": "enabled 必須是布林值"})
            if body.get("revert_after_s") is not None:
                return self._json(400, {"ok": False,
                                        "reason": "revert_after_s 已移除：偵錯狀態全手動",
                                        "hint": "瀏覽器可能是舊頁面，重新整理一次"})
            need = "adb_on" if enabled else "adb_off"
            args = ["adb", "--on" if enabled else "--off"]
            label = "開啟偵錯" if enabled else "關閉偵錯"

        if need not in who["can"]:
            return self._json(403, {"ok": False,
                                    "reason": "%s 的鑰匙沒有「%s」的權限" % (who["name"], label),
                                    "hint": "要的話請管 hub 的人重發：hangar wall --grant %s --can …"
                                            % who["name"]})

        dev = self.state.profile(name)
        if dev is None:
            return self._json(404, {"ok": False,
                                    "reason": "hub 上沒有叫 %s 的手機" % name,
                                    "hint": "牆上那張卡可能是舊的，重新整理一次"})
        # 牆上那張卡可能是另一支手機換上同一個名字之前的樣子。序號對不上就不做
        serial = body.get("serial")
        if (isinstance(serial, str) and serial and dev.get("device_serial")
                and serial != dev["device_serial"]):
            return self._json(409, {"ok": False,
                                    "reason": "%s 現在不是牆上那支手機了" % name,
                                    "hint": "重新整理一次再按"})

        if not self.actions.claim(name):
            return self._json(409, {"ok": False, "profile": name,
                                    "reason": "這支正在處理另一個動作，等一下"})
        try:
            ok, message, detail = run_action(self.actions.hangar, args, name,
                                             self.actions.timeout)
        finally:
            self.actions.release(name)

        entry = {"at": time.time(), "who": who["name"], "via": who["via"],
                 "ip": self.client_address[0], "action": what, "profile": name,
                 "serial": dev.get("device_serial"), "ok": ok, "message": message}
        if what == "ring":
            entry["seconds"] = seconds
        else:
            entry["enabled"] = enabled
            if ok:
                self.state.saw_adb(dev.get("device_serial"), enabled)
                # 牆上的 agent.adb 是 list 那一輪問來的：叫它現在就重問
                wake = self.state.wake.get("list")
                if wake is not None:
                    wake.set()
        self.actions.record(entry)

        result = {"ok": ok, "profile": name, "by": who["name"],
                  "message": message, "detail": detail}
        if what == "ring":
            result.update({"ringing": ok and seconds > 0, "seconds": seconds})
        else:
            result["enabled"] = enabled
        return self._json(200 if ok else 502, result)

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


class CheckinHandler(BaseHTTPRequestHandler):
    """--checkin 那個 listener。只有一個端點，其他一律 404。

    跟 Handler 分開是刻意的：這一個要綁在手機連得到的位址上，而裝置牆
    （Handler）預設只綁 127.0.0.1。共用一個 listener 的話，開放回報就等於
    把牆一起開出去。
    """
    server_version = "hangar-hub-checkin"
    state = None

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api/checkin":
            return self._json(404, {"ok": False, "error": "not_found"})
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if length < 0:
            return self._json(400, {"ok": False, "error": "bad_request",
                                    "reason": "要有 Content-Length"})
        if length > CHECKIN_MAX_BODY:
            return self._json(413, {"ok": False, "error": "too_large"})
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            payload = None
        if not isinstance(payload, dict):
            return self._json(400, {"ok": False, "error": "bad_request",
                                    "reason": "body 不是 JSON 物件"})
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
        status, body = self.state.checkin(payload, token, self.client_address[0])
        return self._json(status, body)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/healthz":
            return self._json({"ok": True})
        return self._json(404, {"ok": False, "error": "not_found"})

    _json = Handler._json

    def log_message(self, fmt, *args):
        pass


def parse_checkin(v):
    """--checkin 的值 → (host, port)。只給埠就綁全部介面：這個 listener 本來就
    是要給別台（手機）連的，綁 127.0.0.1 沒有意義。"""
    host, sep, port = v.rpartition(":")
    if not sep:
        host, port = "0.0.0.0", v
    host = host.strip("[]") or "0.0.0.0"
    return host, int(port)


# ------------------------------------------------------------------ main ----

def _origin_of(url):
    """網址 → 瀏覽器會送的 Origin（scheme://host:port，小寫、沒有路徑）。"""
    u = url.strip()
    if "://" not in u:
        u = "http://" + u
    scheme, _, rest = u.partition("://")
    return scheme.lower() + "://" + rest.split("/", 1)[0].lower()


def manage_keys(args):
    """--grant / --revoke / --keys。做完就離開。"""
    path = args.keys_file
    if args.keys:
        keys = load_keys(path)
        if not keys:
            print("還沒有人有鑰匙（%s）" % path)
            print("  發一把：hangar wall --grant <名字>")
            return 0
        for k in keys:
            when = time.strftime("%Y-%m-%d", time.localtime(k["created"])) \
                if isinstance(k.get("created"), int) else "?"
            print("%-16s %-24s %s" % (k["name"], ",".join(k["can"]) or "（沒有）", when))
        return 0
    if args.revoke:
        try:
            gone = revoke_key(path, args.revoke)
        except OSError as e:
            print("寫不了鑰匙檔 %s：%s" % (path, e), file=sys.stderr)
            return 1
        if not gone:
            print("沒有叫 %s 的鑰匙（hangar wall --keys 看有誰）" % args.revoke,
                  file=sys.stderr)
            return 1
        print("收回了 %s 的鑰匙。正在跑的 hub 下一次請求就不認它了" % args.revoke)
        return 0

    name = args.grant.strip()
    if not KEY_NAME.match(name):
        print("名字只能用英數字與 . _ -（最長 32 個字）：%s" % args.grant, file=sys.stderr)
        return 1
    try:
        can = parse_caps(args.can)
    except ValueError as e:
        print("看不懂的 --can：%s（要是 %s 的組合，或 all）" % (e, "、".join(CAPS)),
              file=sys.stderr)
        return 1
    try:
        token = grant_key(path, name, can)
    except OSError as e:
        print("寫不了鑰匙檔 %s：%s" % (path, e), file=sys.stderr)
        return 1
    print("發給 %s 的鑰匙（能按：%s）。" % (name, "、".join(can)))
    print("把下面的連結交給對方，在要用的那個瀏覽器開一次就記住了：")
    hosts = [h for h in args.hub] or ["http://%s:%d" % (ip, args.port) for ip in local_ips()]
    if not hosts:
        hosts = ["http://<這台 hub 的位址>:%d" % args.port]
    for h in hosts:
        print("  %s/#key=%s" % (_origin_of(h), token))
    print("（鑰匙只印這一次，檔案裡存的是雜湊。弄丟就重跑一次 --grant %s）" % name)
    print("hub 要綁在別人連得到的位址上：hangar wall --bind 0.0.0.0")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Hangar hub：常駐服務 + 裝置牆")
    ap.add_argument("--hangar", default=os.path.join(HERE, "..", "hangar"),
                    help="hangar 執行檔的路徑（預設：這個 repo 裡的那支）")
    ap.add_argument("--bind", default="127.0.0.1",
                    help="綁哪個位址（預設只綁 127.0.0.1）")
    ap.add_argument("--port", type=int, default=8787, help="埠（預設 8787，0 = 隨便挑）")
    ap.add_argument("--list-interval", type=float, default=30.0,
                    help="多久問一次 hangar list（秒，預設 30）")
    ap.add_argument("--scan-interval", type=float, default=300.0,
                    help="多久掃一次區網（秒，預設 300 —— ping 整個 /24 不便宜）")
    ap.add_argument("--subnet", action="append", default=[],
                    help="掃描網段，同 hangar scan --subnet；可以給好幾次，"
                         "不在這台網段上的會逐台探埠")
    ap.add_argument("--checkin", default=None, metavar="HOST:PORT",
                    help="開一個讓手機上的 agent 主動回報的埠（例如 0.0.0.0:8789）。"
                         "跨網段、hub 連不到手機時用")
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
    # ---- 牆上的動作：鑰匙 ----
    # --grant / --revoke / --keys 做完就離開，不會把 hub 起起來
    ap.add_argument("--grant", metavar="名字",
                    help="發一把鑰匙給這個人（同名就是重發），印出帶鑰匙的連結後離開")
    ap.add_argument("--can", default="all", metavar="能力",
                    help="搭配 --grant：ring、adb_off、adb_on 用逗號串起來"
                         "（預設 all = 三個都給）")
    ap.add_argument("--revoke", metavar="名字", help="收回這個人的鑰匙後離開（不用重開 hub）")
    ap.add_argument("--keys", action="store_true", help="列出誰有鑰匙後離開")
    ap.add_argument("--keys-file", default=KEYS_FILE,
                    help="鑰匙檔（預設 %s）" % KEYS_FILE)
    ap.add_argument("--action-log", default=ACTION_LOG,
                    help="操作紀錄（預設 %s，一行一筆 JSON）" % ACTION_LOG)
    args = ap.parse_args(argv)

    if args.grant or args.revoke or args.keys:
        return manage_keys(args)

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
        for sub in args.subnet:
            scan_args += ["--subnet", sub]
        # 每多一個網段就多一輪逐台探埠，逾時跟著放大，不然永遠等不到結果
        scan_timeout = args.timeout * max(1, len(args.subnet))
        threads.append(threading.Thread(
            target=poller, args=(state, "scan", hangar, scan_args,
                                 args.scan_interval, scan_timeout, stop), daemon=True))
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
    CheckinHandler.state = state
    state.hangar = hangar
    Handler.actions = Actions(hangar, args.action_log)
    state.actions = Handler.actions
    Handler.keys_file = args.keys_file
    # --no-auto-pair 的意思是「這台機器上不是只有我」（多人共用帳號、反向代理）：
    # 那時候 loopback 也不該免鑰匙
    Handler.trust_loopback = not args.no_auto_pair
    Handler.extra_origins = tuple(_origin_of(h) for h in args.hub)
    checkin_addr = None
    if args.checkin:
        try:
            checkin_addr = parse_checkin(args.checkin)
        except ValueError:
            print("看不懂的 --checkin：%s（要像 0.0.0.0:8789 或 8789）" % args.checkin,
                  file=sys.stderr)
            return 1
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

    checkin_httpd = None
    if checkin_addr:
        try:
            checkin_httpd = Server(checkin_addr, CheckinHandler)
        except OSError as e:
            # 明講要開卻開不起來：不要默默少一個功能 —— 手機那邊會一直打不進來，
            # 而這邊看起來一切正常
            print("開不了 check-in 的 %s:%d：%s" % (checkin_addr[0], checkin_addr[1], e),
                  file=sys.stderr, flush=True)
            httpd.server_close()
            stop.set()
            for ev in state.wake.values():
                ev.set()
            return 1
        threading.Thread(target=state.load_tokens, kwargs={"force": True},
                         daemon=True).start()
        threading.Thread(target=checkin_httpd.serve_forever, daemon=True).start()
        cport = checkin_httpd.socket.getsockname()[1]
        print("check-in 也開了：%s:%d（手機上的 agent 往這裡回報）"
              % (checkin_addr[0], cport), flush=True)
        for ip in local_ips():
            print("  入伍時告訴手機：hangar enroll -p <名稱> --hub http://%s:%d"
                  % (ip, cport), flush=True)

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
        n = len(load_keys(args.keys_file))
        if n:
            print("　　　響鈴與切偵錯：%d 把鑰匙按得動（hangar wall --keys 看是誰）" % n,
                  file=sys.stderr, flush=True)
        else:
            print("　　　響鈴與切偵錯還沒有人按得動 —— 發鑰匙："
                  "hangar wall --grant <名字>", file=sys.stderr, flush=True)
        print("　　　投影不在這裡：視窗要開在看的人面前，那台要自己跑 helper",
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
        if checkin_httpd is not None:
            checkin_httpd.shutdown()
            checkin_httpd.server_close()
        if helper is not None:
            helper.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

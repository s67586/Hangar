#!/usr/bin/env bash
#
# M3 協定的一致性測試（ROADMAP 的「M3 協定」那一節）。
#
# 預設跑 tests/agentbin/fake_agent.py —— 那是協定的參考實作。
# 手上有真的手機時，同一份測試可以直接打過去：
#
#   HANGAR_AGENT_URL=http://192.168.1.77:5599 HANGAR_AGENT_TOKEN=<token> \
#     tests/test_agent_protocol.sh
#
# 這是這份測試存在的主要理由：Kotlin 那支跟 Python 這支是兩份獨立實作，
# 對不起來的地方就是協定沒講清楚的地方。
#
SP="$(cd "$(dirname "$0")" && pwd)"
FAKE="$SP/agentbin/fake_agent.py"
STATE="${TMPDIR:-/tmp}/hangar-test/agent"
PASS=0; FAIL=0

check()  { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
assert() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

command -v python3 >/dev/null 2>&1 || { echo "  SKIP  這台機器沒有 python3"; exit 0; }

# req <路徑> [token] → "<狀態碼>|<body>"
req() { python3 -c '
import sys, json, urllib.request, urllib.error
url, token = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
r = urllib.request.Request(url)
if token: r.add_header("Authorization", "Bearer " + token)
try:
    resp = urllib.request.urlopen(r, timeout=5)
    print("%d|%s" % (resp.status, resp.read().decode()))
except urllib.error.HTTPError as e:
    print("%d|%s" % (e.code, e.read().decode()))
except Exception as e:
    print("0|%s" % e)' "$1" "${2:-}"; }

code() { printf '%s' "$1" | cut -d'|' -f1; }
body() { printf '%s' "$1" | cut -d'|' -f2-; }
q()    { printf '%s' "$2" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1],{},{"d":d}))' "$1" 2>/dev/null; }

# 打真的手機還是打參考實作
if [ -n "${HANGAR_AGENT_URL:-}" ]; then
  URL="${HANGAR_AGENT_URL%/}"
  TOKEN="${HANGAR_AGENT_TOKEN:-}"
  echo "=== 對象：真的 agent（$URL）==="
  REAL=1
else
  rm -rf "$STATE"; mkdir -p "$STATE"
  TOKEN="testtoken"
  python3 "$FAKE" --port 0 --token "$TOKEN" > "$STATE/out" 2>&1 &
  AGENT_PID=$!
  trap 'kill "$AGENT_PID" 2>/dev/null' EXIT
  for i in $(seq 1 50); do
    URL="$(sed -nE 's|^fake agent: (http://[^ ]+)/$|\1|p' "$STATE/out" | head -1)"
    [ -n "$URL" ] && break
    sleep 0.1
  done
  [ -n "$URL" ] || { echo "  FAIL  參考實作起不來"; exit 1; }
  echo "=== 對象：參考實作（$URL）==="
  REAL=0
fi

echo "=== A1. /hello：不需要 token，掃描靠它認人 ==="
r="$(req "$URL/hangar/v1/hello")"
assert "沒帶 token 也要回 200" "200" "$(code "$r")"
assert "說得出自己是誰"        "hangar-agent" "$(q 'd["agent"]' "$(body "$r")")"
assert "有協定版本"            "1"            "$(q 'd["schema"]' "$(body "$r")")"
assert "說得出入伍了沒"        "True"         "$(q 'str(d["enrolled"])' "$(body "$r")")"
# /hello 是給還沒建立信任的對象看的，不該吐序號
assert "不吐序號"              "False"        "$(q 'str("device_serial" in d)' "$(body "$r")")"

echo "=== A2. /status：要 token ==="
r="$(req "$URL/hangar/v1/status")"
assert "沒帶 token 要 401"     "401" "$(code "$r")"
assert "而且說得出原因"        "unauthorized" "$(q 'd["error"]["code"]' "$(body "$r")")"
r="$(req "$URL/hangar/v1/status" "wrong-token")"
assert "token 錯了也要 401"    "401" "$(code "$r")"

echo "=== A3. /status 的形狀（hub 就是照這個合併的）==="
r="$(req "$URL/hangar/v1/status" "$TOKEN")"
assert "帶對 token 回 200"     "200" "$(code "$r")"
b="$(body "$r")"
assert "有協定版本"            "1"    "$(q 'd["schema"]' "$b")"
# 這一欄是 hub 把 agent / list / scan 三份資料合成同一張卡的主鍵
assert "序號不可以是空的"      "True" "$(q 'str(bool(d["device_serial"]))' "$b")"
assert "有機型"                "True" "$(q 'str(bool(d["model"]))' "$b")"
assert "Android 版本是數字"    "True" "$(q 'str(isinstance(d["android"]["sdk"], int))' "$b")"
# 欄位名稱刻意跟 hangar --json 對齊，hub 才不用翻譯層
assert "電量是 0-100 的整數"   "True" \
  "$(q 'str(isinstance(d["battery"]["level"], int) and 0 <= d["battery"]["level"] <= 100)' "$b")"
assert "充電狀態用小寫那一套"  "True" \
  "$(q 'str(d["battery"]["status"] in ("charging","discharging","full","not_charging",None))' "$b")"
assert "adb.enabled 是布林"    "True" "$(q 'str(isinstance(d["adb"]["enabled"], bool))' "$b")"
# 「關著」跟「這台機器沒有無線偵錯」是兩件事：後者是 null，不是 false
assert "wifi_enabled 是布林或 null" "True" \
  "$(q 'str(d["adb"]["wifi_enabled"] is None or isinstance(d["adb"]["wifi_enabled"], bool))' "$b")"
assert "能力宣告在"            "True" \
  "$(q 'str(isinstance(d["can"]["toggle_adb"], bool) and isinstance(d["can"]["toggle_wifi_adb"], bool))' "$b")"
assert "agent 自己的版本在"    "True" "$(q 'str(bool(d["agent"]["version"]))' "$b")"
# 拿不到的東西要誠實回 null，不要塞 0 或空字串假裝有值
assert "wifi_port 拿不到就 null" "True" \
  "$(q 'str(d["adb"]["wifi_port"] is None or isinstance(d["adb"]["wifi_port"], int))' "$b")"
# MAC 一般 app 拿不到（Android 6+ 回 02:00:00:00:00:00），所以協定裡根本沒有這一欄
assert "不回報 MAC"            "False" "$(q 'str("mac" in d)' "$b")"

echo "=== A4. 還沒實作與不存在要分得出來 ==="
r="$(req "$URL/hangar/v1/adb" "$TOKEN")"
assert "切偵錯回 501 而不是 404" "501" "$(code "$r")"
assert "而且說得出是還沒做"      "not_implemented" "$(q 'd["error"]["code"]' "$(body "$r")")"
r="$(req "$URL/hangar/v1/nonesuch" "$TOKEN")"
assert "不存在的端點才是 404"    "404" "$(code "$r")"
assert "錯誤也有 schema"         "1"   "$(q 'd["schema"]' "$(body "$r")")"

echo "=== A5. 沒入伍的手機 ==="
if [ "$REAL" -eq 1 ]; then
  echo "  SKIP  打真的手機時不測這段（要 pm clear 才能回到沒入伍）"
else
  kill "$AGENT_PID" 2>/dev/null; wait "$AGENT_PID" 2>/dev/null
  python3 "$FAKE" --port 0 --not-enrolled > "$STATE/out2" 2>&1 &
  AGENT_PID=$!
  for i in $(seq 1 50); do
    U2="$(sed -nE 's|^fake agent: (http://[^ ]+)/$|\1|p' "$STATE/out2" | head -1)"
    [ -n "$U2" ] && break
    sleep 0.1
  done
  r="$(req "$U2/hangar/v1/hello")"
  assert "沒入伍也要答 /hello"   "200"   "$(code "$r")"
  assert "而且老實說沒入伍"      "False" "$(q 'str(d["enrolled"])' "$(body "$r")")"
  r="$(req "$U2/hangar/v1/status" "testtoken")"
  # 沒入伍跟 token 不對是兩件事：前者要去插 USB，後者是電腦端的設定壞了
  assert "/status 要回 409 不是 401" "409" "$(code "$r")"
  assert "說得出是還沒入伍"          "not_enrolled" "$(q 'd["error"]["code"]' "$(body "$r")")"
fi

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

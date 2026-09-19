#!/usr/bin/env bash
#
# helper（helper/hangar_helper.py）：裝置牆上的投影按鈕真正動手的那一端。
#
# 這一支會在使用者自己的電腦上開程式，所以測試的重點有兩半：
#   1. 三道鎖都要真的鎖著 —— 只綁 127.0.0.1、Origin 白名單、token
#   2. 按下去之後講的話要是真的 —— 起來了就說起來了，沒起來要說出 hangar 的原因
#
# 用假的 hangar / scrcpy（tests/helperbin/），不會碰到真的手機。
#
SP="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SP/.." && pwd)"
HELPER="$ROOT/helper/hangar_helper.py"
FAKE="$SP/helperbin/hangar"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/helper"
export MOCK_SCRCPY_SLEEP=30
PASS=0; FAIL=0

check()  { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
nocheck(){ if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該出現 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }
assert() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
q()      { printf '%s' "$2" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1],{},{"d":d}))' "$1" 2>/dev/null; }

command -v python3 >/dev/null 2>&1 || { echo "  SKIP  這台機器沒有 python3"; exit 0; }

ORIGIN="http://192.168.1.5:8787"

helper_env() {
  rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE"
  # work 有序號、spare 沒有 —— 序號優先那條路兩種都要走得過
  cat > "$MOCK_STATE/list_json" <<'JSON'
{ "schema": 2, "devices": [
  { "profile": "work",  "default": true,  "device_serial": "R58M12345AB", "ip": "192.168.1.77" },
  { "profile": "spare", "default": false, "device_serial": null,          "ip": "192.168.1.78" }
] }
JSON
}

# helper_start [額外參數…]；--port 0 讓核心挑一個沒人用的
helper_start() {
  OUT="$MOCK_STATE/helper_out"; : > "$OUT"
  python3 "$HELPER" --hangar "$FAKE" --port 0 --token-file "$MOCK_STATE/token" \
    --hub "$ORIGIN" "$@" > "$OUT" 2>&1 &
  HPID=$!
  local i
  for i in $(seq 1 50); do
    PORT="$(sed -nE 's|^hangar helper: http://127\.0\.0\.1:([0-9]+)/.*|\1|p' "$OUT" | head -1)"
    [ -n "$PORT" ] && break
    sleep 0.1
  done
  URL="http://127.0.0.1:${PORT:-0}"
  TOKEN="$(cat "$MOCK_STATE/token" 2>/dev/null | tr -d '\n')"
  [ -n "$PORT" ]
}

helper_stop() {
  [ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null
  wait "$HPID" 2>/dev/null
  HPID=""
  pkill -f 'helperbin/scrcpy' 2>/dev/null
  return 0
}

# req <方法> <網址> [Origin] [token] [body] → "<碼>|<標頭 JSON>|<內文>"
req() {
  python3 - "$@" <<'PY'
import sys, json, urllib.request, urllib.error
method, url = sys.argv[1], sys.argv[2]
origin = sys.argv[3] if len(sys.argv) > 3 else ""
token  = sys.argv[4] if len(sys.argv) > 4 else ""
body   = sys.argv[5].encode() if len(sys.argv) > 5 and sys.argv[5] else None
r = urllib.request.Request(url, data=body, method=method)
if origin: r.add_header("Origin", origin)
if token:  r.add_header("Authorization", "Bearer " + token)
if body:   r.add_header("Content-Type", "application/json")
try:
    resp = urllib.request.urlopen(r, timeout=60)
    print("%d|%s|%s" % (resp.status, json.dumps(dict(resp.headers)), resp.read().decode()))
except urllib.error.HTTPError as e:
    print("%d|%s|%s" % (e.code, json.dumps(dict(e.headers)), e.read().decode()))
except Exception as e:
    print("0||%s" % e)
PY
}
code() { printf '%s' "$1" | cut -d'|' -f1; }
head_() { printf '%s' "$1" | cut -d'|' -f2; }
body() { printf '%s' "$1" | cut -d'|' -f3-; }

trap 'helper_stop' EXIT

echo "=== L1. 起不來的時候要講人話 ==="
helper_env
out="$(python3 "$HELPER" --hangar "$FAKE" --port 0 --token-file "$MOCK_STATE/token" 2>&1)"
assert   "沒有 --hub 就不啟動"   "1" "$?"
check    "而且說得出要給什麼"     "要給 --hub" "$out"
nocheck  "不丟 traceback"        "Traceback" "$out"

out="$(python3 "$HELPER" --hangar "$MOCK_STATE/nothere" --hub "$ORIGIN" 2>&1)"
check    "找不到 hangar 也講得出來" "找不到可執行的 hangar" "$out"

helper_start || { echo "  FAIL  helper 起不來"; FAIL=$((FAIL+1)); }
out="$(python3 "$HELPER" --hangar "$FAKE" --port "$PORT" --token-file "$MOCK_STATE/token" \
        --hub "$ORIGIN" 2>&1)"
check    "埠被佔住說得出是哪一種問題" "已經有人在用了" "$out"
check    "而且說得出怎麼確認"         "pgrep -fl hangar_helper.py" "$out"
nocheck  "埠被佔住不丟 traceback"     "Traceback" "$out"

echo "=== L2. 鑰匙 ==="
r="$(req GET "$URL/healthz" "$ORIGIN" "")"
assert "沒帶 token 是 401" "401" "$(code "$r")"
check  "而且說得出去哪裡拿" "用它印出來的那個連結" "$(body "$r")"
r="$(req GET "$URL/healthz" "$ORIGIN" "not-the-right-key")"
assert "token 不對也是 401" "401" "$(code "$r")"
r="$(req GET "$URL/healthz" "$ORIGIN" "$TOKEN")"
assert "對的 token 進得去" "200" "$(code "$r")"
assert "說得出這台電腦看得到幾支" "2" "$(q 'len(d["profiles"])' "$(body "$r")")"
# 這把鑰匙等於「可以在這台電腦上開視窗」，同機的其他使用者不該讀得到
assert "鑰匙檔是 0600" "600" "$(stat -f '%OLp' "$MOCK_STATE/token" 2>/dev/null || stat -c '%a' "$MOCK_STATE/token")"

echo "=== L3. Origin 白名單 ==="
r="$(req GET "$URL/healthz" "http://evil.example" "$TOKEN")"
assert "別的頁面叫不動" "403" "$(code "$r")"
# 被擋掉的回應不給 CORS 標頭 —— 那頁連內容都不該讀得到
nocheck "被擋的回應沒有 CORS 標頭" "Access-Control-Allow-Origin" "$(head_ "$r")"
r="$(req POST "$URL/mirror" "http://evil.example" "$TOKEN" '{"profile":"work"}')"
assert "POST 也擋" "403" "$(code "$r")"
assert "擋掉的沒有真的去投影" "0" "$(grep -c . "$MOCK_STATE/scrcpy_argv" 2>/dev/null || echo 0)"

r="$(req OPTIONS "$URL/mirror" "$ORIGIN" "")"
assert "preflight 過得了" "204" "$(code "$r")"
check  "回得了來源"         "$ORIGIN" "$(head_ "$r")"
# Chrome 對「區網上的頁面連本機」有額外一關，舊版靠這個標頭
check  "帶了 private-network 標頭" "Access-Control-Allow-Private-Network" "$(head_ "$r")"
r="$(req OPTIONS "$URL/mirror" "http://evil.example" "")"
assert "別的來源連 preflight 都過不了" "403" "$(code "$r")"

echo "=== L4. 只有這台電腦連得到 ==="
lan="$(ipconfig getifaddr en0 2>/dev/null || ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)"
if [ -n "$lan" ]; then
  r="$(req GET "http://$lan:$PORT/healthz" "$ORIGIN" "$TOKEN")"
  assert "從區網位址連不進來" "0" "$(code "$r")"
else
  echo "  SKIP  這台機器找不到區網位址"
fi

echo "=== L5. 投影：起來了就說起來了 ==="
r="$(req POST "$URL/mirror" "$ORIGIN" "$TOKEN" '{"profile":"work"}')"
assert "成功回 200"      "200" "$(code "$r")"
assert "ok 是 true"      "True" "$(q 'd["ok"]' "$(body "$r")")"
check  "說得出視窗開了"   "投影視窗開了" "$(body "$r")"
check  "真的跑了 scrcpy"  "work" "$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
# 這是這條路跟 URL scheme 的差別：那邊丟出去就沒消息，這邊等得到答案，
# 而且答案來自 process 真的變成 scrcpy，不是「叫過了」而已
check  "叫的是本機的 hangar -p" "^-p work$" "$(cat "$MOCK_STATE/argv_log")"

echo "=== L6. 沒起來要說出 hangar 的原因 ==="
touch "$MOCK_STATE/fail_spare"
r="$(req POST "$URL/mirror" "$ORIGIN" "$TOKEN" '{"profile":"spare"}')"
assert "失敗不是 200"        "502" "$(code "$r")"
assert "ok 是 false"         "False" "$(q 'd["ok"]' "$(body "$r")")"
check  "把 hangar 的話帶上來" "手機不在線上" "$(body "$r")"
check  "hint 也帶上來"        "去看看它有沒有開機" "$(body "$r")"
# 顏色碼與行首記號是給終端機看的，放到網頁上只會變成看不懂的字元
nocheck "沒有 ANSI 顏色碼"    "\[31m" "$(body "$r")"
nocheck "沒有行首的 xx 記號"  '"xx ' "$(body "$r")"

echo "=== L7. 牆上的名字跟這台電腦的名字可以不一樣 ==="
# 牆上的名字是 hub 那台機器取的。序號才是跨電腦不變的那個識別碼。
r="$(req POST "$URL/mirror" "$ORIGIN" "$TOKEN" \
     '{"profile":"hub那邊叫別的名字","serial":"R58M12345AB"}')"
assert "序號對得到"        "200" "$(code "$r")"
assert "投的是本機的 work" "work" "$(q 'd["profile"]' "$(body "$r")")"
assert "而且說得出是靠序號" "serial" "$(q 'd["matched_by"]' "$(body "$r")")"

echo "=== L8. 這台電腦沒有這支手機 ==="
r="$(req POST "$URL/mirror" "$ORIGIN" "$TOKEN" '{"profile":"ghost","serial":"ZZZZ"}')"
assert "回 404"            "404" "$(code "$r")"
check  "講得出是這台電腦沒有" "這台電腦上沒有這支手機" "$(body "$r")"
# 這就是那個躲不掉的前置動作：adb 授權綁每台電腦的金鑰，按鈕省不掉它
check  "而且講得出下一步"   "hangar setup" "$(body "$r")"

echo "=== L9. 同一支同時按兩次 ==="
helper_stop
helper_env
touch "$MOCK_STATE/slow_work"     # 讓第一個請求慢到擋得住第二個
MOCK_SCRCPY_SLEEP=30 helper_start --grace 10 || { echo "  FAIL  helper 起不來"; FAIL=$((FAIL+1)); }
# 第一個請求會等到 scrcpy 接手才回，趁它還在等的時候再按一次
( req POST "$URL/mirror" "$ORIGIN" "$TOKEN" '{"profile":"work"}' > "$MOCK_STATE/first" ) &
FIRST=$!
sleep 0.5
r="$(req POST "$URL/mirror" "$ORIGIN" "$TOKEN" '{"profile":"work"}')"
# 只等那一個請求。helper 自己也是背景子行程，不帶參數的 wait 會等到天荒地老
wait "$FIRST" 2>/dev/null
c="$(code "$r")"
if [ "$c" = "409" ]; then
  echo "  PASS  第二次按被擋下來（409）"; PASS=$((PASS+1))
  check "而且說得出在忙" "正在啟動中" "$(body "$r")"
else
  # 第一個請求太快回來的話就沒得擋，那不算錯 —— 但兩個都成功才算對
  assert "第一次成功" "200" "$(code "$(cat "$MOCK_STATE/first")")"
  assert "沒擋到的話第二次也要是好的" "200" "$c"
fi

echo "=== L10. normalize_origin：使用者貼進來的網址要收斂得起來 ==="
out="$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/helper")
import hangar_helper as h
for raw in ["http://192.168.1.5:8787/", "HTTP://192.168.1.5:8787",
            "192.168.1.5:8787", "http://192.168.1.5:8787/#helper=abc"]:
    print(h.normalize_origin(raw))
PY
)"
assert "四種寫法都收斂成同一個" "1" "$(printf '%s\n' "$out" | sort -u | grep -c .)"
check  "收斂的結果就是瀏覽器會送的那個" "http://192.168.1.5:8787" "$out"

helper_stop
echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

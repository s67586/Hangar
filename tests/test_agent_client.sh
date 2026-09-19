#!/usr/bin/env bash
#
# 電腦這一側怎麼跟 agent 講話：hangar enroll、list --probe 改問 agent、
# scan 探 5599。用 mock 的 adb / nc / curl，不會碰到真的手機也不會碰網路。
#
# 協定本身的一致性測試在 test_agent_protocol.sh，那份打得到真的手機。
#
SP="$(cd "$(dirname "$0")" && pwd)"
PM="$1"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/state" PATH="$SP/mockbin:$PATH" \
       XDG_CONFIG_HOME="${TMPDIR:-/tmp}/hangar-test/cfg" NO_COLOR=1 \
       HANGAR_SCAN_PARALLEL=254
PASS=0; FAIL=0

check()  { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
nocheck(){ if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該出現 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }
assert() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
q()      { printf '%s' "$2" | jq -r "$1" 2>/dev/null; }
pfield() { grep -E "^$2=" "$XDG_CONFIG_HOME/hangar/profiles/$1.conf" 2>/dev/null | head -1 | cut -d'"' -f2; }
# grep -c 在「數到 0」時離開碼是 1，直接接 `|| echo 0` 會印出兩個 0
nlines() { local n; n="$(grep -c "${2:-.}" "$1" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# 一支 lan profile，手機在 192.168.1.77，5555 開著、5599 也開著
env_one() {
  rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"
  mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
  printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.77"\nTRANSPORT="lan"\n' \
    > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
  printf '192.168.1.77\n192.168.1.77:5599\n' > "$MOCK_STATE/nc_open_ips"
  cat > "$MOCK_STATE/arp_table" <<'ARP'
? (192.168.1.1) at 3c:37:86:aa:bb:cc on en0 ifscope [ethernet]
? (192.168.1.77) at a4:3:e7:1:2:3 on en0 ifscope [ethernet]
ARP
  export HANGAR_OUI_FILE="$MOCK_STATE/no-such-oui-db"
  printf '192.168.1.77:5555\tdevice\n' > "$MOCK_STATE/adb_devices"
  cat > "$MOCK_STATE/agent_192.168.1.77_5599.json" <<'JSON'
{ "schema": 1,
  "agent": { "version": "0.1.0-mock", "uptime_s": 3600 },
  "device_serial": "PIX0000001",
  "model": "Pixel 7 Pro",
  "android": { "release": "14", "sdk": 34 },
  "battery": { "level": 42, "status": "discharging", "temperature_c": 29.0 },
  "adb": { "enabled": true, "wifi_enabled": false, "wifi_port": null },
  "can": { "toggle_adb": true, "toggle_wifi_adb": true } }
JSON
}

echo "=== C1. hangar enroll：那唯一一次 USB ==="
env_one
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "沒有 APK 要講清楚" "找不到 agent 的 APK" "$out"
check "並且教人怎麼 build" "gradlew assembleDebug" "$out"

env_one
: > "$MOCK_STATE/fake.apk"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "裝了 APK"            "install .*fake.apk" "$(cat "$MOCK_STATE/adb_log")"
check "授予了 WRITE_SECURE_SETTINGS" "WRITE_SECURE_SETTINGS" "$(cat "$MOCK_STATE/adb_log")"
check "發了入伍廣播"        "com.hangar.agent/.EnrollReceiver" "$(cat "$MOCK_STATE/adb_log")"
check "說入伍完成"          "入伍完成" "$out"
# token 要寫進 profile，而且不能是空的
assert "profile 記下 token" "64" "$(printf '%s' "$(pfield work AGENT_TOKEN)" | wc -c | tr -d ' ')"
assert "profile 記下埠"     "5599" "$(pfield work AGENT_PORT)"
assert "序號也記下來了"     "PIX0000001" "$(pfield work DEVICE_SERIAL)"
# 廣播帶出去的序號要跟 profile 一致 —— 那是 hub 合併三份資料的主鍵
assert "廣播帶的序號跟 profile 同一個" "PIX0000001" "$(cat "$MOCK_STATE/agent_serial")"
# 每次入伍都要是新的一組，不能寫死
t1="$(pfield work AGENT_TOKEN)"
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
t2="$(pfield work AGENT_TOKEN)"
if [ -n "$t1" ] && [ "$t1" != "$t2" ]; then echo "  PASS  每次入伍都是新 token"; PASS=$((PASS+1));
else echo "  FAIL  token 沒有變（$t1 / ${t2}）"; FAIL=$((FAIL+1)); fi

echo "=== C2. 入伍失敗的幾種樣子 ==="
env_one; : > "$MOCK_STATE/fake.apk"; touch "$MOCK_STATE/enroll_already"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "已經入伍過要說清楚"  "已經入伍過" "$out"
check "並且教人怎麼重來"    "pm clear" "$out"
assert "而且不可以寫壞 profile" "" "$(pfield work AGENT_TOKEN)"

# 權限拿不到不是致命傷：agent 照樣回報電量，只是切不了偵錯
env_one; : > "$MOCK_STATE/fake.apk"; touch "$MOCK_STATE/grant_fail"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "授權失敗要警告"      "授權沒成功" "$out"
check "但要說仍然可以回報"  "仍然可以回報電量" "$out"
assert "還是有入伍"         "5599" "$(pfield work AGENT_PORT)"

env_one; : > "$MOCK_STATE/fake.apk"; touch "$MOCK_STATE/install_fail"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "安裝失敗就停下來"    "安裝失敗" "$out"
assert "不會留下半套設定"   "" "$(pfield work AGENT_TOKEN)"

echo "=== C3. list --json：adb 通的時候，agent 只是附帶資訊 ==="
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
out="$("$PM" list --json --probe 2>/dev/null)"
assert "schema 往上加了"     "2" "$(q '.schema' "$out")"
assert "adb 通就用 adb 的資料" "adb" "$(q '.devices[0].battery.source' "$out")"
assert "電量是 adb 那份"      "78" "$(q '.devices[0].battery.level' "$out")"
assert "agent 也看得到"       "true" "$(q '.devices[0].agent.reachable' "$out")"
assert "說得出 agent 版本"    "0.1.0-mock" "$(q '.devices[0].agent.version' "$out")"

echo "=== C4. adb 碰不到時，改問 agent —— 這就是 agent 存在的理由 ==="
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
# 手機重開機：5555 沒了，但 agent 還在
: > "$MOCK_STATE/adb_devices"
printf '192.168.1.77:5599\n' > "$MOCK_STATE/nc_open_ips"
printf 'fail\n' > "$MOCK_STATE/adb_connect_result"
out="$("$PM" list --json --probe 2>/dev/null)"
assert "adb 是斷的"          "disconnected" "$(q '.devices[0].adb_state' "$out")"
assert "但電量拿得到"        "42" "$(q '.devices[0].battery.level' "$out")"
assert "而且說得出是誰給的"  "agent" "$(q '.devices[0].battery.source' "$out")"
assert "機型也拿得到"        "Pixel 7 Pro" "$(q '.devices[0].model' "$out")"
# agent 回報的序號跟入伍時寫進 profile 的是同一個字串 —— 那正是 hub 合併
# agent / list / scan 三份資料的主鍵，對不起來的話整張裝置牆就會分裂
assert "序號兩邊一致"        "PIX0000001" "$(q '.devices[0].device_serial' "$out")"

echo "=== C5. 入伍過但 agent 死掉：要看得出來 ==="
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
rm -f "$MOCK_STATE/agent_192.168.1.77_5599.json"    # agent 不回應了
out="$("$PM" list --json --probe 2>/dev/null)"
assert "agent 物件還在"      "false" "$(q '.devices[0].agent.reachable' "$out")"
# 沒入伍過的手機不該憑空多出一個 agent 物件
env_one
out="$("$PM" list --json --probe 2>/dev/null)"
assert "沒入伍的是 null"     "null" "$(q '.devices[0].agent' "$out")"

echo "=== C6. scan 探得到 agent ==="
env_one
out="$("$PM" scan --json 2>/dev/null)"
assert "schema 往上加了"     "6" "$(q '.schema' "$out")"
assert "有 agent 的標出版本" "0.1.0-mock" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.version' "$out")"
: > "$MOCK_STATE/curl_log"        # 上一次掃描寫過了，要先清掉才問得出這一題
out="$("$PM" scan --json --no-probe 2>/dev/null)"
assert "--no-probe 就不去問" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent' "$out")"
assert "--no-probe 也不戳 curl" "0" \
  "$(nlines "$MOCK_STATE/curl_log")"

# 沒有 agent 的機器不該被問 —— 一個 /24 上大多數東西沒有 agent，
# 每台都等 curl 逾時的話掃描會從幾秒變成幾分鐘
env_one
"$PM" scan --json >/dev/null 2>&1
assert "只對開著 5599 的發 curl" "1" \
  "$(nlines "$MOCK_STATE/curl_log" 5599)"
nocheck "沒探到的不會被問" "192.168.1.1:5599" "$(cat "$MOCK_STATE/curl_log" 2>/dev/null)"

echo "=== C7. 缺工具要說缺工具 ==="
# curl 不是硬相依：沒有它只是問不到 agent，掃描其他部分照常
env_one
NOCURL="$MOCK_STATE/nocurl"; rm -rf "$NOCURL"; mkdir -p "$NOCURL"
for d in "$SP/mockbin" /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "curl" ] && continue
    [ -e "$NOCURL/$b" ] || ln -s "$f" "$NOCURL/$b" 2>/dev/null
  done
done
out="$(PATH="$NOCURL" "$PM" scan --json 2>/dev/null)"
assert "沒有 curl 也掃得動" "2" "$(q '.hosts | length' "$out")"
assert "只是問不到 agent"   "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent' "$out")"
out="$(PATH="$NOCURL" "$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "但入伍要明講缺 curl" "找不到 curl" "$out"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

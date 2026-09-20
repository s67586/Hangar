#!/usr/bin/env bash
#
# hub（hub/hangar_hub.py）：合併邏輯與 HTTP 端點。
# 用假的 hangar（tests/hubbin/hangar）餵固定的 JSON，不會碰到真的手機或網路。
#
SP="$(cd "$(dirname "$0")" && pwd)"
HUB="$SP/../hub/hangar_hub.py"
FAKE="$SP/hubbin/hangar"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/hub"
PASS=0; FAIL=0

check()  { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
nocheck(){ if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該出現 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }
assert() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
q()      { printf '%s' "$2" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1],{},{"d":d}))' "$1" 2>/dev/null; }

command -v python3 >/dev/null 2>&1 || { echo "  SKIP  這台機器沒有 python3"; exit 0; }

# work 這支兩份資料都看得到（序號一樣，要合成同一張卡）；
# spare 只在 list 裡（電量低）；192.168.1.90 只在 scan 裡（沒設定過的手機）。
hub_env() {
  rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE"
  cat > "$MOCK_STATE/list_json" <<'JSON'
{ "schema": 1, "devices": [
  { "profile": "work", "default": true, "transport": "lan",
    "host": "", "ip": "192.168.1.77", "adb_serial": "192.168.1.77:5555",
    "device_serial": "R58M12345AB", "reachability": "online", "adb_state": "device",
    "path": { "kind": "direct", "latency_ms": 3 }, "model": "Pixel 7 Pro",
    "android": { "release": "14", "sdk": 34 },
    "battery": { "level": 78, "status": "discharging", "temperature_c": 27.5 },
    "scrcpy_pids": [], "errors": [] },
  { "profile": "spare", "default": false, "transport": "tailscale",
    "host": "zenfone", "ip": "100.101.102.110", "adb_serial": "100.101.102.110:5555",
    "device_serial": "", "reachability": "online", "adb_state": "offline",
    "path": null, "model": null, "android": null,
    "battery": { "level": 9, "status": "discharging", "temperature_c": 31.0 },
    "scrcpy_pids": [], "errors": [
      { "code": "adb_disconnected", "message": "手機重開機後 5555 會消失" } ] }
] }
JSON
  cat > "$MOCK_STATE/scan_json" <<'JSON'
{ "schema": 7, "subnet": "192.168.1.0/24", "hosts": [
  { "ip": "192.168.1.1", "mac": "3c:37:86:aa:bb:cc", "vendor": "Netgear",
    "mac_randomized": false, "adb_port": "closed", "profile": null,
    "matched_by": null, "device_serial": null,
    "profile_ip_stale": false, "profile_ip_fixed": false,
    "agent": null, "is_gateway": true },
  { "ip": "192.168.1.77", "mac": "a4:03:e7:01:02:03", "vendor": "宏達電子",
    "mac_randomized": false, "adb_port": "open", "profile": "work",
    "matched_by": "mac", "device_serial": "R58M12345AB",
    "profile_ip_stale": false, "profile_ip_fixed": false,
    "agent": { "version": "0.1.0", "enrolled": false } },
  { "ip": "192.168.1.90", "mac": "de:ad:be:ef:00:01", "vendor": null,
    "mac_randomized": true, "adb_port": "closed", "profile": null,
    "matched_by": null, "device_serial": null,
    "profile_ip_stale": false, "profile_ip_fixed": false,
    "agent": { "version": "0.1.0" }, "is_gateway": false }
], "errors": [] }
JSON
}

# 把 hub 跑起來，回傳它的網址（--port 0 讓核心挑一個沒人用的）
hub_start() {
  HUB_OUT="$MOCK_STATE/hub_out"; : > "$HUB_OUT"
  python3 "$HUB" --hangar "$FAKE" --bind 127.0.0.1 --port 0 \
    --list-interval 0.3 --scan-interval 0.3 "$@" > "$HUB_OUT" 2>"$MOCK_STATE/hub_err" &
  HUB_PID=$!
  local i url=""
  for i in $(seq 1 50); do
    url="$(sed -nE 's|^hangar hub: (http://[^ ]+)/$|\1|p' "$HUB_OUT" | head -1)"
    [ -n "$url" ] && break
    sleep 0.1
  done
  HUB_URL="$url"
  [ -n "$HUB_URL" ]
}

hub_stop() { [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; HUB_PID=""; }

# 抓一個端點；devices 要等第一輪輪詢回來，所以可以等到有東西為止
get() { python3 -c '
import sys, urllib.request
sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$1" 2>/dev/null; }
get_headers() { python3 -c '
import sys, urllib.request
r = urllib.request.urlopen(sys.argv[1], timeout=5)
sys.stdout.write("\\n".join("%s: %s" % x for x in r.headers.items()))' "$1" 2>/dev/null; }

get_devices() {
  local i out=""
  for i in $(seq 1 50); do
    out="$(get "$HUB_URL/api/devices")"
    printf '%s' "$out" | grep -q '"devices": \[{' && break
    printf '%s' "$out" | grep -q '"devices": \[\]' || break
    sleep 0.1
  done
  printf '%s' "$out"
}

# post <url> → "<狀態碼>|<body>"；get_code 同理但用 GET
post() { python3 -c '
import sys, urllib.request, urllib.error
r = urllib.request.Request(sys.argv[1], data=b"", method=sys.argv[2])
try:
    resp = urllib.request.urlopen(r, timeout=5)
    print("%d|%s" % (resp.status, resp.read().decode()))
except urllib.error.HTTPError as e:
    print("%d|%s" % (e.code, e.read().decode()))
except Exception as e:
    print("0|%s" % e)' "$1" POST; }
get_code() { python3 -c '
import sys, urllib.request, urllib.error
try:
    resp = urllib.request.urlopen(sys.argv[1], timeout=5)
    print("%d|%s" % (resp.status, resp.read().decode()))
except urllib.error.HTTPError as e:
    print("%d|%s" % (e.code, e.read().decode()))
except Exception as e:
    print("0|%s" % e)' "$1"; }
# grep -c 數到 0 時離開碼是 1，直接接 || echo 0 會印出兩個 0
nlines() { local n; n="$(grep -c "${2:-.}" "$1" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

trap 'hub_stop' EXIT

echo "=== H1. 端點活著 ==="
hub_env
if ! hub_start; then
  echo "  FAIL  hub 起不來：$(cat "$MOCK_STATE/hub_err")"; FAIL=$((FAIL+1))
  echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"; exit 1
fi
echo "  PASS  起得來並印出網址"; PASS=$((PASS+1))
assert "healthz 回 ok" "True" "$(q 'd["ok"]' "$(get "$HUB_URL/healthz")")"
check  "首頁是那張裝置牆" "Hangar 裝置牆" "$(get "$HUB_URL/")"
check  "首頁不快取舊版按鈕事件" "Cache-Control: no-store" "$(get_headers "$HUB_URL/")"
check  "首頁含註冊 handler" "async function enroll" "$(get "$HUB_URL/")"
check  "首頁含響鈴 handler" "async function ring" "$(get "$HUB_URL/")"
check  "首頁含切偵錯 handler" "async function toggleAdb" "$(get "$HUB_URL/")"
check  "註冊中只保留一顆按鈕" 'st.action === "enroll" && st.busy' "$(get "$HUB_URL/")"
check  "agent 無回應且 adb ready 可補裝" \
  'd.agent.reachable === false && d.agent.enrolled === null' "$(get "$HUB_URL/")"
page="$(get "$HUB_URL/")"
check  "首頁含更新 agent handler" "async function updateAgent" "$page"
check  "看板目標 agent 版號"       'const CURRENT_AGENT_VERSION = "0.1.2";' "$page"
check  "舊版改用版號比較"          'compareAgentVersions(d.agent.version, CURRENT_AGENT_VERSION) === -1' "$page"
version_logic="$(printf '%s' "$page" | sed -n '/function agentNeedsUpdate/,/^}/p')"
nocheck "舊版判斷不再看 can.ring"  "can.ring" "$version_logic"
if command -v node >/dev/null 2>&1; then
  version_source="$(printf '%s' "$page" | awk '/const CURRENT_AGENT_VERSION/{print; exit}')"
  version_source="$version_source
$(printf '%s' "$page" | awk '/function agentVersionParts/{keep=1} /function ringCommand/{exit} keep')"
  if VERSION_SOURCE="$version_source" node - <<'NODE'
const source = process.env.VERSION_SOURCE || "";
eval(source);
const old = { agent: { reachable: true, enrolled: true, version: "0.1.1" } };
const current = { agent: { reachable: true, enrolled: true, version: "0.1.2" } };
const newer = { agent: { reachable: true, enrolled: true, version: "0.1.3" } };
if (!agentNeedsUpdate(old) || agentNeedsUpdate(current) || agentNeedsUpdate(newer)) process.exit(1);
if (compareAgentVersions("0.1.10", "0.1.2") !== 1) process.exit(1);
NODE
  then
    echo "  PASS  0.1.1 會更新、0.1.2 不更新、更高版不降版"; PASS=$((PASS+1))
  else
    echo "  FAIL  版號比較實際執行結果不對"; FAIL=$((FAIL+1))
  fi
else
  echo "  SKIP  沒有 node，略過版號比較的 JavaScript 執行測試"
fi
check  "更新按鈕要 adb 通得到"    'd.adb_state !== "device"' "$page"
check  "更新走的是 helper 的 enroll" "reinstall: true" "$page"
check  "更新按鈕文字"            "更新agent" "$page"
# 這一條是整條路的重點：hub 自己永遠不會動手機
nocheck "hub 沒有新的動手機端點" "/api/reinstall" "$(get "$HUB_URL/")"
out="$(get_devices)"
assert "api 有 schema"    "7" "$(q 'd["schema"]' "$out")"
assert "掃到的網段帶出來" "192.168.1.0/24" "$(q 'd["subnet"]' "$out")"

# scrcpy_pids 是 hangar 在 hub 這台機器上 pgrep 出來的，牆上要講「哪一台開著
# 視窗」時答案永遠是 hub 自己 —— 所以它得講得出自己叫什麼
assert "端得出 hub 自己的名字" "True" \
  "$(q 'str(bool(d.get("host")))' "$(get "$HUB_URL/api/devices")")"
assert "而且不是一整串 FQDN" "True" \
  "$(q 'str("." not in d["host"])' "$(get "$HUB_URL/api/devices")")"

echo "=== H2. 兩份資料合成一張裝置牆 ==="
# work 在 list 與 scan 裡各出現一次，序號一樣 → 只能是一台。
# 四台 = work（兩份資料合起來）+ spare（只在 list）+ .90 與閘道器（只在 scan）
assert "總共四台"        "4" "$(q 'len(d["devices"])' "$out")"
assert "work 只有一張卡" "1" "$(q 'len([x for x in d["devices"] if x["name"]=="work"])' "$out")"
assert "而且兩個來源都算到" "list,scan" \
  "$(q '",".join([x for y in d["devices"] if y["name"]=="work" for x in y["sources"]])' "$out")"
assert "list 那邊的機型在"  "Pixel 7 Pro" \
  "$(q '[y["model"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "scan 那邊的 MAC 也在" "a4:03:e7:01:02:03" \
  "$(q '[y["mac"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "5555 的狀態併進來了" "open" \
  "$(q '[y["adb_port"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "scan 的未入伍狀態併進來了" "False" \
  "$(q '[y["agent"]["enrolled"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"

echo "=== H3. 沒設定過的手機也要上牆 ==="
# 裝置牆存在的理由就是這個：沒開偵錯的手機 adb 碰不到，但它確實在區網上
assert "掃到的那台在"      "unmanaged" \
  "$(q '[y["state"] for y in d["devices"] if y["ip"]=="192.168.1.90"][0]' "$out")"
assert "它沒有 profile 名稱" "None" \
  "$(q '[y["name"] for y in d["devices"] if y["ip"]=="192.168.1.90"][0]' "$out")"
assert "key 退回用 MAC"     "mac:de:ad:be:ef:00:01" \
  "$(q '[y["key"] for y in d["devices"] if y["ip"]=="192.168.1.90"][0]' "$out")"

echo "=== H4. 狀態判讀與電量 ==="
assert "adb device → ready" "ready" \
  "$(q '[y["state"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
# 連得到但 adb 不是 device：幾乎都是手機重開機把 5555 弄丟了，跟「手機離線」要分開
assert "連得到但 adb 不行 → no_adb" "no_adb" \
  "$(q '[y["state"] for y in d["devices"] if y["name"]=="spare"][0]' "$out")"
assert "低電量要標出來" "True" \
  "$(q '[y["battery"]["low"] for y in d["devices"] if y["name"]=="spare"][0]' "$out")"
assert "正常電量不要亂標" "False" \
  "$(q '[y["battery"]["low"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "要注意的排前面" "spare" "$(q 'd["devices"][0]["name"]' "$out")"
# 單支手機自己的錯誤留在那張卡上，不要混進整頁的錯誤列（那是給 hub 級的問題用的）
assert "手機自己的錯誤留在卡片上" "手機重開機後 5555 會消失" \
  "$(q '[y["errors"][0]["message"] for y in d["devices"] if y["name"]=="spare"][0]' "$out")"
assert "不會被塞進整頁的錯誤列" "0" "$(q 'len(d["errors"])' "$out")"

echo "=== H5. 唯讀：不可以偷偷去改設定檔 ==="
# --fix-ip 會寫 profile。固定輪詢的程式無條件帶著它跑遲早出事，所以鎖住。
argv="$(cat "$MOCK_STATE/argv_log")"
nocheck "輪詢不帶 --fix-ip"          "fix-ip" "$argv"
nocheck "也不會去跑 setup"            "setup"  "$argv"
nocheck "更不會去 reset 或 forget"    "reset\|forget" "$argv"
check   "list 有帶 --probe（要電量）" "probe"  "$argv"
check   "scan 有真的跑"               "scan"   "$argv"
hub_stop

echo "=== H6. hangar 壞掉時 hub 不能跟著死 ==="
hub_env
touch "$MOCK_STATE/scan_fail"
hub_start || { echo "  FAIL  hub 起不來"; FAIL=$((FAIL+1)); }
out="$(get_devices)"
assert "list 那邊照樣看得到" "2" "$(q 'len(d["devices"])' "$out")"
assert "掃描的錯誤要說出來" "1" \
  "$(q 'len([e for e in d["errors"] if e["source"]=="scan"])' "$out")"
assert "首頁還在"            "200" \
  "$(python3 -c 'import sys,urllib.request;print(urllib.request.urlopen(sys.argv[1],timeout=5).status)' "$HUB_URL/" 2>/dev/null)"
hub_stop

echo "=== H7. 靜態檔不准往上跳 ==="
hub_env
hub_start || true
code="$(python3 -c '
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(sys.argv[1], timeout=5); print("200")
except urllib.error.HTTPError as e: print(e.code)
except Exception: print("err")' "$HUB_URL/static/../../hangar")"
nocheck "讀不到 repo 裡的 hangar" "200" "$code"
hub_stop

echo "=== H8. merge() 是純函式，不用開伺服器也測得動 ==="
# 裝置牆的邏輯全在 merge() 裡（兩份 dict 進，一個 list 出）。這一節直接叫它，
# 不經過 HTTP —— 邊界情況用這種方式列，比一個個開伺服器便宜太多。
m() { python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hub", sys.argv[1])
hub = importlib.util.module_from_spec(spec); spec.loader.exec_module(hub)
print(eval(sys.argv[2], {}, {"merge": hub.merge}))
' "$HUB" "$1" 2>/dev/null; }

assert "兩邊都沒資料也不會爆" "0" "$(m 'len(merge(None, None))')"
assert "只有 scan 也列得出來" "1" \
  "$(m 'len(merge(None, {"hosts":[{"ip":"192.168.1.5","mac":"aa:bb:cc:dd:ee:ff"}]}))')"

# 序號是主鍵：list 說它在 tailscale 的 100.x、scan 在區網看到它，仍然是同一台
same='merge(
  {"devices":[{"profile":"work","ip":"100.1.1.1","device_serial":"S1","adb_state":"device","transport":"tailscale"}]},
  {"hosts":[{"ip":"192.168.1.77","mac":"a4:03:e7:01:02:03","profile":"work","device_serial":"S1","adb_port":"open"}]})'
assert "跨連線方式仍是一台"  "1"            "$(m "len(${same})")"
assert "IP 用 list 那邊的"    "100.1.1.1"    "$(m "${same}[0]['ip']")"
assert "區網位址另外放一欄"   "192.168.1.77" "$(m "${same}[0]['lan_ip']")"
assert "主鍵是序號"           "serial:S1"    "$(m "${same}[0]['key']")"

# MAC 兩個來源：adb 問到的（list.mac）在掃不到的時候要留著，掃得到的時候
# 讓區網那一份覆蓋 —— ARP 換來的才是「hub 實際看到的那張網卡」
adb_only='merge(
  {"devices":[{"profile":"work","device_serial":"S1","adb_state":"device",
               "mac":{"address":"f0:5c:77:aa:bb:01","randomized":False,
                      "vendor":None,"ssid":"TestNet"}}]}, None)'
assert "掃不到時用 adb 問到的 MAC" "f0:5c:77:aa:bb:01" "$(m "${adb_only}[0]['mac']")"
assert "SSID 也帶過來"             "TestNet"           "$(m "${adb_only}[0]['mac_ssid']")"

both='merge(
  {"devices":[{"profile":"work","device_serial":"S1","adb_state":"device",
               "mac":{"address":"f0:5c:77:aa:bb:01","randomized":False,
                      "vendor":None,"ssid":"TestNet"}}]},
  {"hosts":[{"ip":"192.168.1.77","mac":"a4:03:e7:01:02:03","vendor":"宏達電子",
             "profile":"work","device_serial":"S1"}]})'
assert "掃得到就用區網那一份" "a4:03:e7:01:02:03" "$(m "${both}[0]['mac']")"
assert "廠商也跟著換"         "宏達電子"          "$(m "${both}[0]['vendor']")"

# 掃描配得上（靠 profile 名字）卻沒 MAC —— 例如那一輪 ARP 沒回。
# 這時候不能把 adb 問到的那份洗成 None
no_arp='merge(
  {"devices":[{"profile":"work","device_serial":"S1","adb_state":"device",
               "mac":{"address":"f0:5c:77:aa:bb:01","randomized":False,
                      "vendor":None,"ssid":"TestNet"}}]},
  {"hosts":[{"ip":"192.168.1.77","mac":None,"profile":"work","device_serial":"S1"}]})'
assert "掃到但沒 MAC 時不清空" "f0:5c:77:aa:bb:01" "$(m "${no_arp}[0]['mac']")"

# list 那次剛好掛掉，但掃描認得出這是 work —— 要叫得出名字，不能顯示成陌生機器
only_scan='merge(None, {"hosts":[{"ip":"192.168.1.77","mac":"a4:03:e7:01:02:03","profile":"work","device_serial":"S1","adb_port":"open"}]})'
assert "名字還在"     "work"    "$(m "${only_scan}[0]['name']")"
assert "狀態說不知道" "unknown" "$(m "${only_scan}[0]['state']")"

# --- 掃描那側對不上 profile 名字時的兩條退路 -------------------------------
# scan_match_profiles 只認得「profile 的 PHONE_IP／PHONE_MAC 對得上」的手機。
# 走 tailscale 的手機 PHONE_IP 是 100.x，PHONE_MAC 又還沒學到，所以掃描回來的
# 那一筆 profile 是 null —— 但 list 那側用 adb 問得到同一張網卡的 MAC。
# 不接這條退路的話，同一支手機會在牆上出現兩次（實際踩過：A34 一張走 tailscale
# 的卡，加一張匿名的區網卡）。

# (1) 序號對得上就是同一台，即使掃描沒認出 profile
by_ser='merge(
  {"devices":[{"profile":"work","ip":"100.1.1.1","device_serial":"S1","adb_state":"device"}]},
  {"hosts":[{"ip":"192.168.1.77","mac":"a4:03:e7:01:02:03","profile":None,"device_serial":"S1"}]})'
assert "序號對得上就不另開一張" "1"            "$(m "len(${by_ser})")"
assert "併進原本那張卡"         "work"         "$(m "${by_ser}[0]['name']")"
assert "區網位址補上去"         "192.168.1.77" "$(m "${by_ser}[0]['lan_ip']")"

# (2) 連序號都沒有時，用 adb 問到的 MAC 對 —— 這就是 A34 那個情境
by_mac='merge(
  {"devices":[{"profile":"work","ip":"100.1.1.1","device_serial":"S1","adb_state":"device",
               "mac":{"address":"3e:19:e2:35:b1:6b","randomized":True,
                      "vendor":None,"ssid":"TestNet"}}]},
  {"hosts":[{"ip":"192.168.0.155","mac":"3e:19:e2:35:b1:6b","profile":None,
             "device_serial":None,"adb_port":"closed"}]})'
assert "MAC 對得上就不另開一張" "1"             "$(m "len(${by_mac})")"
assert "併進原本那張卡"         "work"          "$(m "${by_mac}[0]['name']")"
assert "區網位址補上去"         "192.168.0.155" "$(m "${by_mac}[0]['lan_ip']")"
assert "兩個來源都記著"         "['list', 'scan']" "$(m "${by_mac}[0]['sources']")"

# (3) 大小寫不一樣也要對得上：adb 給小寫，某些系統的 ARP 表給大寫
mixed='merge(
  {"devices":[{"profile":"work","device_serial":"S1","adb_state":"device",
               "mac":{"address":"3e:19:e2:35:b1:6b","randomized":True,
                      "vendor":None,"ssid":None}}]},
  {"hosts":[{"ip":"192.168.0.155","mac":"3E:19:E2:35:B1:6B","profile":None}]})'
assert "大小寫不同仍是同一台" "1" "$(m "len(${mixed})")"

# (4) 反過來：MAC 不一樣就是不同的兩台，不可以亂併
diff_mac='merge(
  {"devices":[{"profile":"work","device_serial":"S1","adb_state":"device",
               "mac":{"address":"3e:19:e2:35:b1:6b","randomized":True,
                      "vendor":None,"ssid":None}}]},
  {"hosts":[{"ip":"192.168.0.155","mac":"aa:bb:cc:dd:ee:ff","profile":None}]})'
assert "MAC 不同就分開兩張" "2" "$(m "len(${diff_mac})")"

echo "=== H9. 接真的 hangar（不是假的）—— 兩邊的 JSON 不可以各走各的 ==="
# 前面幾節餵的是手寫的 JSON，擋得住 hub 自己的迴歸，擋不住「hangar 改了欄位、
# hub 沒跟上」。這一節用 mockbin 的假 adb／arp 跑真正的 hangar，把兩邊接起來。
REAL_STATE="${TMPDIR:-/tmp}/hangar-test/hub-real"
rm -rf "$REAL_STATE"; mkdir -p "$REAL_STATE/cfg/hangar/profiles"
cat > "$REAL_STATE/arp_table" <<'ARP'
? (192.168.1.1) at 3c:37:86:aa:bb:cc on en0 ifscope [ethernet]
? (192.168.1.42) at 11:22:33:44:55:66 on en0 ifscope [ethernet]
? (192.168.1.77) at a4:3:e7:1:2:3 on en0 ifscope [ethernet]
ARP
printf '192.168.1.77\n' > "$REAL_STATE/nc_open_ips"
printf '192.168.1.77:5555\tdevice\n' > "$REAL_STATE/adb_devices"
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.77"\nTRANSPORT="lan"\nDEVICE_SERIAL="R58M12345AB"\n' \
  > "$REAL_STATE/cfg/hangar/profiles/work.conf"

HUB_OUT="$REAL_STATE/out"; : > "$HUB_OUT"
( MOCK_STATE="$REAL_STATE" XDG_CONFIG_HOME="$REAL_STATE/cfg" NO_COLOR=1 \
  HANGAR_SCAN_PARALLEL=254 HANGAR_OUI_FILE="$REAL_STATE/no-such-db" \
  PATH="$SP/mockbin:$PATH" \
  python3 "$HUB" --hangar "$SP/../hangar" --bind 127.0.0.1 --port 0 \
    --list-interval 30 --scan-interval 30 > "$HUB_OUT" 2>"$REAL_STATE/err" & echo $! > "$REAL_STATE/pid" )
for i in $(seq 1 100); do
  HUB_URL="$(sed -nE 's|^hangar hub: (http://[^ ]+)/$|\1|p' "$HUB_OUT" | head -1)"
  [ -n "$HUB_URL" ] && break
  sleep 0.1
done
# 兩邊都要等到：list 很快，掃描要 ping 完整個 /24 才會回來
out=""
for i in $(seq 1 150); do
  out="$(get "$HUB_URL/api/devices")"
  printf '%s' "$out" | grep -q '"ready"' \
    && printf '%s' "$out" | grep -q '"unmanaged"' && break
  sleep 0.2
done
assert "真的 hangar 也接得起來"   "ready" \
  "$(q '[y["state"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "機型是從 list 來的"        "Pixel 7 Pro" \
  "$(q '[y["model"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "MAC 是從 scan 來的"        "a4:03:e7:01:02:03" \
  "$(q '[y["mac"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "序號兩邊對得起來"          "R58M12345AB" \
  "$(q '[y["device_serial"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "閘道器是沒設定過的那種"    "unmanaged" \
  "$(q '[y["state"] for y in d["devices"] if y["ip"]=="192.168.1.1"][0]' "$out")"
assert "沒有整頁級的錯誤"          "0" "$(q 'len(d["errors"])' "$out")"
kill "$(cat "$REAL_STATE/pid")" 2>/dev/null

echo "=== H10. agent 的資料要上牆 ==="
# adb 進不去但 agent 還在，是 agent 存在的全部理由 —— 那要跟「整台失聯」分開顯示
hub_env
cat > "$MOCK_STATE/list_json" <<'JSON'
{ "schema": 2, "devices": [
  { "profile": "work", "default": true, "transport": "lan", "host": "",
    "ip": "192.168.1.77", "adb_serial": "192.168.1.77:5555",
    "device_serial": "R58M12345AB", "reachability": "offline",
    "adb_state": "disconnected", "path": null, "model": "Pixel 7 Pro",
    "android": { "release": "14", "sdk": 34 },
    "battery": { "level": 42, "status": "discharging", "temperature_c": 29.0,
                 "source": "agent" },
    "agent": { "reachable": true, "version": "0.1.1", "enrolled": true },
    "scrcpy_pids": [], "errors": [] },
  { "profile": "dead", "default": false, "transport": "lan", "host": "",
    "ip": "192.168.1.88", "adb_serial": "192.168.1.88:5555",
    "device_serial": "", "reachability": "offline", "adb_state": "disconnected",
    "path": null, "model": null, "android": null, "battery": null,
    "agent": { "reachable": false, "version": null, "enrolled": null },
    "scrcpy_pids": [], "errors": [] }
] }
JSON
hub_start || { echo "  FAIL  hub 起不來"; FAIL=$((FAIL+1)); }
out="$(get_devices)"
assert "adb 不通但 agent 在 → agent_only" "agent_only" \
  "$(q '[y["state"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "電量是 agent 給的"      "42" \
  "$(q '[y["battery"]["level"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
assert "而且說得出來源"         "agent" \
  "$(q '[y["battery"]["source"] for y in d["devices"] if y["name"]=="work"][0]' "$out")"
# 入伍過但 agent 叫不動：現在看不出事，但下次重開機就失聯，要標得出來
assert "agent 死掉看得出來"     "False" \
  "$(q '[y["agent"]["reachable"] for y in d["devices"] if y["name"]=="dead"][0]' "$out")"
assert "那台不算 agent_only"    "offline" \
  "$(q '[y["state"] for y in d["devices"] if y["name"]=="dead"][0]' "$out")"
# 掃描看到一支 agent，但這台 hub 沒有它的 profile
assert "陌生的 agent 也標得出來" "True" \
  "$(q 'str(any((y.get("agent") or {}).get("reachable") for y in d["devices"] if y["name"] is None))' "$out")"
hub_stop

echo "=== H11. 輪詢執行緒不准死 ==="
# 真的拿這台當 hub 的時候踩到的：hangar 的 stderr 有一個不是合法 UTF-8 的位元組，
# 解碼例外直接把輪詢執行緒殺掉 —— 網頁從此停在舊資料上，而且畫面看不出來。
# 「沒有更新」跟「沒有變化」長得一模一樣，那是最糟的失敗方式。
hub_env
cat > "$MOCK_STATE/list_json" <<'JSON'
{ "schema": 2, "devices": [
  { "profile": "work", "default": true, "transport": "lan", "host": "",
    "ip": "192.168.1.77", "adb_serial": "192.168.1.77:5555",
    "device_serial": "R58M12345AB", "reachability": "online", "adb_state": "device",
    "path": null, "model": "Pixel 7 Pro", "android": { "release": "14", "sdk": 34 },
    "battery": { "level": 78, "status": "discharging", "temperature_c": 27.5 },
    "scrcpy_pids": [], "errors": [] } ] }
JSON
# 讓假 hangar 在 stderr 吐一段壞掉的 UTF-8（0xef 開頭但沒有接續位元組）
printf '\xef\xbc 壞掉的位元組\n' > "$MOCK_STATE/list_stderr"
hub_start || { echo "  FAIL  hub 起不來"; FAIL=$((FAIL+1)); }
out="$(get_devices)"
# 重點不是總共幾台（掃描那半邊也會貢獻），而是 list 這一輪有沒有真的回來
assert "壞位元組不會讓輪詢停擺" "True" "$(q 'str(d["polled_at"]["list"] is not None)' "$out")"
assert "而且資料是對的"         "1" \
  "$(q 'len([y for y in d["devices"] if y["name"]=="work"])' "$out")"
# 再等一輪，確認執行緒還活著（死掉的話 polled_at 不會再前進）
t1="$(q 'd["polled_at"]["list"]' "$out")"
sleep 1
out2="$(get_devices)"
t2="$(q 'd["polled_at"]["list"]' "$out2")"
if [ "$t1" != "$t2" ]; then echo "  PASS  下一輪照樣跑"; PASS=$((PASS+1));
else echo "  FAIL  輪詢停住了（$t1 = ${t2}）"; FAIL=$((FAIL+1)); fi
hub_stop

echo "=== H12. 主動輪詢：不想等下一輪的時候 ==="
# 預設 list 30 秒、scan 300 秒。剛插上一支手機還要等半分鐘才看得到，很難用。
# 這一節把間隔設成 600 秒：沒有主動輪詢的話，測試期間絕不會有第二次。
code1() { printf '%s' "$1" | head -1 | cut -d'|' -f1; }
body1() { printf '%s' "$1" | cut -d'|' -f2-; }

hub_env
hub_start --list-interval 600 --scan-interval 600 \
  || { echo "  FAIL  hub 起不來"; FAIL=$((FAIL+1)); }
out="$(get_devices)"

# 節流是照「上一輪開始到現在」算的，剛啟動時那一輪才剛開始 —— 這時候該被擋
r="$(post "$HUB_URL/api/refresh?what=list")"
assert "剛問過就按要被擋" "429" "$(code1 "$r")"
check  "而且說得出要等多久" "retry_after_s" "$(body1 "$r")"

# 等過最小間隔（list 是 5 秒）再按
n1="$(nlines "$MOCK_STATE/argv_log" list)"
sleep 6
r="$(post "$HUB_URL/api/refresh?what=list")"
assert "過了間隔就叫得動"  "200"  "$(code1 "$r")"
assert "說得出叫醒了誰"    "list" "$(q 'd["refreshed"][0]' "$(body1 "$r")")"
n2="$n1"
for i in $(seq 1 50); do
  n2="$(nlines "$MOCK_STATE/argv_log" list)"
  [ "$n2" -gt "$n1" ] && break
  sleep 0.2
done
if [ "$n2" -gt "$n1" ]; then echo "  PASS  真的又問了一次（間隔還有 600 秒）"; PASS=$((PASS+1));
else echo "  FAIL  沒有提早問（$n1 → ${n2}）"; FAIL=$((FAIL+1)); fi

# 掃描那一邊的門檻高很多：它會對 254 個位址各送一個封包，按住不放不該變成洗 ping
r="$(post "$HUB_URL/api/refresh?what=scan")"
assert "掃描的節流更嚴"    "429" "$(code1 "$r")"
check  "回報是哪個來源被擋" "scan" "$(body1 "$r")"

# 唯讀的承諾不變：主動輪詢也不准帶 --fix-ip
nocheck "主動輪詢也不帶 --fix-ip" "fix-ip" "$(cat "$MOCK_STATE/argv_log")"
# GET 不該是觸發器 —— 那會讓任何預抓網址的東西都去戳一次手機
assert "GET 不觸發輪詢"    "404" "$(code1 "$(get_code "$HUB_URL/api/refresh")")"
assert "不認得的 what 回 400" "400" "$(code1 "$(post "$HUB_URL/api/refresh?what=nonesuch")")"
# M3d/M4 的寫入仍然走本機 helper；hub 不可以悄悄長出直連手機的端點。
assert "hub 沒有響鈴寫入端點" "404" "$(code1 "$(post "$HUB_URL/api/ring")")"
assert "hub 沒有偵錯寫入端點" "404" "$(code1 "$(post "$HUB_URL/api/adb")")"
hub_stop

echo "=== H13. 起不來的時候要講人話，不要丟 traceback ==="
# 實際踩到的：埠被自己上一個 hub 佔著，Python 吐一整串 traceback。
# 那看起來像程式壞了，但要做的事其實很明確。
hub_env
hub_start || { echo "  FAIL  第一個 hub 起不來"; FAIL=$((FAIL+1)); }
port="$(printf '%s' "$HUB_URL" | sed -E 's|.*:([0-9]+)$|\1|')"
out="$(python3 "$HUB" --hangar "$FAKE" --bind 127.0.0.1 --port "$port" 2>&1)"
rc=$?
assert "離開碼非 0"        "1" "$rc"
nocheck "不可以有 traceback" "Traceback" "$out"
check  "要說埠被佔住了"     "已經有人在用" "$out"
check  "並且教人怎麼查"     "pgrep" "$out"
check  "也給另一條路"       "--port" "$out"
hub_stop

# 1024 以下的埠不是「被佔住」，是權限 —— 兩件事要分得出來。
#
# 但 root 沒有這個限制：它綁得上 80 埠，hub 會正常起來然後一直跑，下面這個
# $(...) 就永遠等不到它結束。那不是一個 FAIL，是整套測試卡死到被 CI 的逾時砍掉
# ——而 test_hub.sh 後面還有四個 suite，會一起變成「沒跑到」。root 容器是很常見
# 的 CI 環境，所以這裡要主動跳過，不能賭沒人用 root 跑。
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP  權限那三項（root 綁得上 80 埠，這個情境在 root 底下重現不了）"
else
  out="$(python3 "$HUB" --hangar "$FAKE" --bind 127.0.0.1 --port 80 2>&1)"
  nocheck "權限問題也不丟 traceback" "Traceback" "$out"
  check   "說得出是權限"             "權限" "$out"
  nocheck "不可以誤報成被佔住"       "已經有人在用" "$out"
fi

# 綁一個這台機器上沒有的位址，又是第三種事
out="$(python3 "$HUB" --hangar "$FAKE" --bind 10.99.99.99 2>&1)"
nocheck "位址問題也不丟 traceback" "Traceback" "$out"
check   "說得出是位址的問題"       "沒有這個位址" "$out"

echo "=== H14. 閘道器要傳得到牆上 ==="
hub_env
hub_start || { echo "  FAIL  hub 起不來"; FAIL=$((FAIL+1)); }
out="$(get_devices)"
assert "閘道器標記傳過來了" "True" \
  "$(q 'str([y["is_gateway"] for y in d["devices"] if y["ip"]=="192.168.1.1"][0])' "$out")"
assert "別台不是閘道器"     "False" \
  "$(q 'str([y["is_gateway"] for y in d["devices"] if y["ip"]=="192.168.1.90"][0])' "$out")"
assert "已設定的手機也有這個欄位" "False" \
  "$(q 'str([y["is_gateway"] for y in d["devices"] if y["name"]=="work"][0])' "$out")"
# 閘道器排在同類的最後面：它每次都在，而且永遠不是要找的那台
assert "閘道器排在陌生裝置後面" "True" \
  "$(q 'str([y["ip"] for y in d["devices"] if y["state"]=="unmanaged"][-1] == "192.168.1.1")' "$out")"
hub_stop

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

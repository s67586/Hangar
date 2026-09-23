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
{ "schema": 3,
  "agent": { "version": "0.1.0-mock", "uptime_s": 3600 },
  "device_serial": "PIX0000001",
  "model": "Pixel 7 Pro",
  "android": { "release": "14", "sdk": 34 },
  "battery": { "level": 42, "status": "discharging", "temperature_c": 29.0 },
  "adb": { "enabled": true, "wifi_enabled": false, "wifi_port": null },
  "can": { "toggle_adb": true, "toggle_wifi_adb": true, "ring": true } }
JSON
}

echo "=== C1. hangar enroll：透過 USB 或網路 ADB 安裝 ==="
env_one
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "沒有 APK 要講清楚" "找不到 agent 的 APK" "$out"
check "並且教人怎麼 build" "gradlew assembleDebug" "$out"

env_one
: > "$MOCK_STATE/fake.apk"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "裝了 APK"            "install .*fake.apk" "$(cat "$MOCK_STATE/adb_log")"
check "用 profile 的網路 ADB serial 遠端安裝" "192.168.1.77:5555 install" "$(cat "$MOCK_STATE/adb_log")"
check "授予了 WRITE_SECURE_SETTINGS" "WRITE_SECURE_SETTINGS" "$(cat "$MOCK_STATE/adb_log")"
check "發了入伍廣播"        "com.hangar.agent/.EnrollReceiver" "$(cat "$MOCK_STATE/adb_log")"
check "說入伍完成"          "入伍完成" "$out"
# token 要寫進 profile，而且不能是空的
assert "profile 記下 token" "64" "$(printf '%s' "$(pfield work AGENT_TOKEN)" | wc -c | tr -d ' ')"
assert "profile 記下埠"     "5599" "$(pfield work AGENT_PORT)"
assert "序號也記下來了"     "PIX0000001" "$(pfield work DEVICE_SERIAL)"
# 廣播帶出去的序號要跟 profile 一致 —— 那是 hub 合併三份資料的主鍵
assert "廣播帶的序號跟 profile 同一個" "PIX0000001" "$(cat "$MOCK_STATE/agent_serial")"
assert "廣播帶的名字跟 profile 同一個" "work" "$(cat "$MOCK_STATE/agent_name")"
# 每次入伍都要是新的一組，不能寫死
t1="$(pfield work AGENT_TOKEN)"
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
t2="$(pfield work AGENT_TOKEN)"
if [ -n "$t1" ] && [ "$t1" != "$t2" ]; then echo "  PASS  每次入伍都是新 token"; PASS=$((PASS+1));
else echo "  FAIL  token 沒有變（$t1 / ${t2}）"; FAIL=$((FAIL+1)); fi

echo "=== C1b. 從 PATH 上的 symlink 執行也要找得到 APK ==="
# hangar_install.sh 裝的是 symlink（/usr/local/bin/hangar → repo/hangar）。找
# APK 要相對於「腳本真正在哪」，不是相對於那個 symlink —— 不解開的話，照著
# README 裝的人跑 enroll 一律會被告知「找不到 APK」，而 APK 明明就在 repo 裡。
env_one
mkdir -p "$MOCK_STATE/repo/agent/app/build/outputs/apk/debug" "$MOCK_STATE/bin/deep"
cp "$PM" "$MOCK_STATE/repo/hangar"
: > "$MOCK_STATE/repo/agent/app/build/outputs/apk/debug/app-debug.apk"
ln -sf "$MOCK_STATE/repo/hangar" "$MOCK_STATE/bin/deep/hangar"
# 再套一層，而且是相對路徑的 symlink：Homebrew 那種 bin/hangar → ../deep/hangar
ln -sf "deep/hangar" "$MOCK_STATE/bin/hangar"
out="$("$MOCK_STATE/bin/hangar" enroll -p work 2>&1)"
check "symlink 也找得到 APK" "repo/agent/app/build/outputs/apk/debug/app-debug.apk" "$out"
nocheck "不會說找不到"       "找不到 agent 的 APK" "$out"
check "而且真的裝下去了"     "install .*app-debug.apk" "$(cat "$MOCK_STATE/adb_log")"

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

echo "=== C2b. hangar enroll --reinstall：只換 APK，不動 token ==="
env_one; : > "$MOCK_STATE/fake.apk"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --reinstall 2>&1)"
check "還沒入伍過就不給只換 APK" "沒辦法只換 APK" "$out"
check "並且指回正規入伍"          "hangar enroll -p work" "$out"
assert "沒有裝任何東西"           "0" "$(nlines "$MOCK_STATE/adb_log" "install")"

env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
t1="$(pfield work AGENT_TOKEN)"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --reinstall 2>&1)"
check "說得出是更新 agent"     "agent 更新完成" "$out"
check "有再裝一次 APK"        "install .*fake.apk" "$(cat "$MOCK_STATE/adb_log")"
assert "而且真的裝了兩次"     "2" "$(nlines "$MOCK_STATE/adb_log" "install")"
check "順手補了一次授權"      "WRITE_SECURE_SETTINGS" "$(cat "$MOCK_STATE/adb_log")"
check "把新版的能力印出來"    "能力" "$out"
assert "token 沒有變"         "$t1" "$(pfield work AGENT_TOKEN)"
# 這是整條路的重點：沒有重新入伍，所以其他也入伍過這支手機的電腦不會被踢掉
assert "沒有再發一次入伍廣播" "1" "$(nlines "$MOCK_STATE/adb_log" "EnrollReceiver")"

# 手機上的資料被清掉（pm clear）或 app 被解除安裝過：新裝上去的是一支空的
# agent，這時候手上還有 adb，要順手補完入伍，不是丟一個錯誤給人
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
t1="$(pfield work AGENT_TOKEN)"
touch "$MOCK_STATE/agent_not_enrolled"; rm -f "$MOCK_STATE/agent_token"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --reinstall 2>&1)"
check "空的 agent 要講出來"   "入伍資料不見了" "$out"
check "並且自己補完"          "agent 更新完成" "$out"
# 這一次 token 真的換了，收尾那句話不可以照抄「token 沒有變」
check "換了 token 要講實話"   "token 是新的" "$out"
nocheck "不可以說 token 沒變" "token 沒有變" "$out"
assert "這次才會換 token"     "2" "$(nlines "$MOCK_STATE/adb_log" "EnrollReceiver")"
if [ -n "$t1" ] && [ "$t1" != "$(pfield work AGENT_TOKEN)" ]; then
  echo "  PASS  補入伍會寫一組新 token"; PASS=$((PASS+1));
else echo "  FAIL  補入伍之後 token 沒換"; FAIL=$((FAIL+1)); fi

# 手機上那支是別台電腦入伍的：裝得上去，但問不出 status。這不能假裝成功
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
printf 'someone-elses-token' > "$MOCK_STATE/agent_token"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --reinstall 2>&1)"; rc=$?
check "token 不對要說清楚"    "不接受這台電腦的 token" "$out"
check "並且說清楚代價"        "其他電腦手上的 token 也會一起失效" "$out"
assert "離開碼不是 0"         "1" "$rc"

echo "=== C2c. hangar enroll --takeover：token 遺失但 adb 還通 ==="
# 這支手機已經入伍過（別台電腦裝的，或這裡的 profile 重建過），所以正規入伍會
# 被 already_enrolled 擋下來，而 --reinstall 沒有 token 可用。以前這是死路。
env_one; : > "$MOCK_STATE/fake.apk"
touch "$MOCK_STATE/enroll_already"; printf 'someone-elses-token' > "$MOCK_STATE/agent_token"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "沒有 token 時要指向接手"   "\-\-takeover" "$out"
check "並且講清楚代價"           "其他電腦手上的 token 一起失效" "$out"
nocheck "不要叫人去 --reinstall"  "hangar enroll -p work --reinstall" "$out"

# 反過來：手上有 token 的那台電腦看到 already_enrolled，要的是 --reinstall，
# 不是接手 —— 接手會把自己的 token 也換掉，代價完全沒有必要。
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
touch "$MOCK_STATE/enroll_already"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" 2>&1)"
check "有 token 時指向就地升級" "hangar enroll -p work --reinstall" "$out"
nocheck "不要叫人去接手"        "\-\-takeover" "$out"

env_one; : > "$MOCK_STATE/fake.apk"
touch "$MOCK_STATE/enroll_already"; printf 'someone-elses-token' > "$MOCK_STATE/agent_token"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --takeover --yes 2>&1)"
check "接手會清掉入伍狀態"   "pm clear com.hangar.agent" "$(cat "$MOCK_STATE/adb_log")"
check "然後重新入伍一次"     "com.hangar.agent/.EnrollReceiver" "$(cat "$MOCK_STATE/adb_log")"
check "說得出這是接手"       "接手完成" "$out"
assert "profile 記下新 token" "64" "$(printf '%s' "$(pfield work AGENT_TOKEN)" | wc -c | tr -d ' ')"
assert "手機上換成同一組"     "$(pfield work AGENT_TOKEN)" "$(cat "$MOCK_STATE/agent_token")"
assert "埠也記下來了"         "5599" "$(pfield work AGENT_PORT)"
# 順序不是隨便排的：簽章對不上這種失敗要發生在「還沒清掉任何東西」之前，
# 而 pm clear 會把 pm grant 給過的權限收回去，所以授權一定在清除之後。
i_install="$(grep -n "install" "$MOCK_STATE/adb_log" | head -1 | cut -d: -f1)"
i_clear="$(grep -n "pm clear" "$MOCK_STATE/adb_log" | head -1 | cut -d: -f1)"
i_grant="$(grep -n "WRITE_SECURE_SETTINGS" "$MOCK_STATE/adb_log" | head -1 | cut -d: -f1)"
if [ "$i_install" -lt "$i_clear" ] && [ "$i_clear" -lt "$i_grant" ]; then
  echo "  PASS  先裝、再清、最後授權"; PASS=$((PASS+1))
else
  echo "  FAIL  步驟順序不對（install=${i_install} clear=${i_clear} grant=${i_grant}）"; FAIL=$((FAIL+1))
fi

# 沒有終端機又沒帶 --yes：不准自己點頭。helper 那條路（網頁按鈕）就是這種。
env_one; : > "$MOCK_STATE/fake.apk"
touch "$MOCK_STATE/enroll_already"; printf 'someone-elses-token' > "$MOCK_STATE/agent_token"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --takeover < /dev/null 2>&1)"; rc=$?
check "沒人點頭就不動手機" "沒有終端機可以確認" "$out"
assert "離開碼不是 0"      "1" "$rc"
assert "真的沒有清掉"      "0" "$(nlines "$MOCK_STATE/adb_log" "pm clear")"
assert "也沒有重新入伍"    "0" "$(nlines "$MOCK_STATE/adb_log" "EnrollReceiver")"

# 清不掉就停下來。半路失敗要停在「手機還是原來那樣」，不能接著寫一組
# 這支手機根本不認的 token 進 profile。
env_one; : > "$MOCK_STATE/fake.apk"
touch "$MOCK_STATE/enroll_already"; printf 'someone-elses-token' > "$MOCK_STATE/agent_token"
touch "$MOCK_STATE/pm_clear_fail"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --takeover --yes 2>&1)"; rc=$?
check "清不掉要講出來"  "清不掉手機上的入伍狀態" "$out"
assert "離開碼不是 0"   "1" "$rc"
assert "沒有發入伍廣播" "0" "$(nlines "$MOCK_STATE/adb_log" "EnrollReceiver")"
assert "profile 沒被寫壞" "" "$(pfield work AGENT_TOKEN)"

# 兩個旗標講的是相反的事，一起用一定有一邊是誤會
env_one; : > "$MOCK_STATE/fake.apk"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --reinstall --takeover 2>&1)"; rc=$?
check "互斥要擋下來" "不能一起用" "$out"
assert "離開碼不是 0" "1" "$rc"
assert "什麼都沒做"   "0" "$(nlines "$MOCK_STATE/adb_log" ".")"

echo "=== C3. list --json：adb 通的時候，agent 只是附帶資訊 ==="
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
out="$("$PM" list --json --probe 2>/dev/null)"
assert "schema 往上加了"     "4" "$(q '.schema' "$out")"
assert "adb 通就用 adb 的資料" "adb" "$(q '.devices[0].battery.source' "$out")"
assert "電量是 adb 那份"      "78" "$(q '.devices[0].battery.level' "$out")"
assert "agent 也看得到"       "true" "$(q '.devices[0].agent.reachable' "$out")"
assert "說得出 agent 版本"    "0.1.0-mock" "$(q '.devices[0].agent.version' "$out")"
assert "能力宣告帶上牆"        "true" "$(q '.devices[0].agent.can.ring' "$out")"

echo "=== C3b. hangar ring / adb：不需要 adb 通也能走 agent ==="
env_one; : > "$MOCK_STATE/fake.apk"
"$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" >/dev/null 2>&1
out="$("$PM" ring -p work --seconds 999 2>&1)"
check "ring 送到 agent"         "已響鈴 120 秒" "$out"
check "ring 真的打到端點"       "/hangar/v1/ring" "$(cat "$MOCK_STATE/curl_log")"
out="$("$PM" ring -p work --stop 2>&1)"
check "ring --stop 可以停"       "已停止響鈴" "$out"
out="$("$PM" adb -p work --off 2>&1)"
check "adb 關閉說清楚不會自己開回" "不會自己開回來" "$out"
check "adb 真的打到端點"        "/hangar/v1/adb" "$(cat "$MOCK_STATE/curl_log")"
out="$("$PM" adb -p work --off --revert-after-s 1800 2>&1 || true)"
check "舊的 --revert-after-s 直接擋下" "已移除" "$out"
out="$("$PM" adb -p work --on 2>&1)"
check "adb 可以再開"             "偵錯已開啟" "$out"

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
assert "schema 往上加了"     "8" "$(q '.schema' "$out")"
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

echo "=== C9. enroll --hub：讓 agent 主動回報 ==="
env_one; : > "$MOCK_STATE/fake.apk"
out="$("$PM" enroll -p work --apk "$MOCK_STATE/fake.apk" --hub http://10.0.0.5:8789/ 2>&1)"
check  "入伍廣播帶著 hub"         "--es hub http://10.0.0.5:8789$" "$(cat "$MOCK_STATE/adb_log")"
assert "手機收到的是去掉尾巴斜線的" "http://10.0.0.5:8789" "$(cat "$MOCK_STATE/agent_hub" 2>/dev/null)"
check  "profile 也記下來"         'AGENT_HUB="http://10.0.0.5:8789"' "$(cat "$XDG_CONFIG_HOME/hangar/profiles/work.conf")"

# 已入伍：只改回報對象，不裝 APK、不換 token
tok_before="$(cat "$MOCK_STATE/agent_token")"
: > "$MOCK_STATE/adb_log"
out="$("$PM" enroll -p work --hub http://10.0.0.6:8789/api/checkin 2>&1)"
check   "說改好了"                "會往 http://10.0.0.6:8789 回報" "$out"
nocheck "不重裝 APK"              "install" "$(cat "$MOCK_STATE/adb_log")"
check   "走 SET_HUB"              "com.hangar.agent.SET_HUB" "$(cat "$MOCK_STATE/adb_log")"
assert  "token 沒換"              "$tok_before" "$(cat "$MOCK_STATE/agent_token")"
assert  "網址尾巴的 /api/checkin 去掉" "http://10.0.0.6:8789" "$(cat "$MOCK_STATE/agent_hub")"
out="$("$PM" enroll -p work --no-hub 2>&1)"
check   "--no-hub 關掉回報"       "不再主動回報" "$out"
assert  "手機那邊清空"            "" "$(cat "$MOCK_STATE/agent_hub")"

# 手機那組 token 不是這台的：SET_HUB 會被拒
printf 'someone-else' > "$MOCK_STATE/agent_token"
out="$("$PM" enroll -p work --hub http://10.0.0.7:8789 2>&1)"; rc=$?
assert "被拒要失敗"               "1" "$rc"
check  "並且指向 --takeover"      "--takeover" "$out"

out="$("$PM" enroll -p work --hub 10.0.0.5:8789 2>&1)"
check  "不是網址要擋下來"         "--hub 要像 http://" "$out"

echo "=== C10. agent-tokens：只給 hub 讀的 token 表 ==="
env_one
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.77"\nTRANSPORT="lan"\nDEVICE_SERIAL="S1"\nAGENT_TOKEN="t1"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.78"\nTRANSPORT="lan"\nDEVICE_SERIAL="S2"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/spare.conf"
out="$("$PM" agent-tokens --json 2>/dev/null)"
assert "只列有 token 的"          "work|S1|t1" "$(q '.tokens[] | "\(.profile)|\(.device_serial)|\(.token)"' "$out")"
out="$("$PM" agent-tokens 2>&1)"
check  "沒帶 --json 不印 token"   "只給程式讀" "$out"
nocheck "真的沒印"                "t1" "$out"
out="$("$PM" list --json 2>/dev/null)"
nocheck "list --json 裡沒有 token" '"t1"' "$out"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

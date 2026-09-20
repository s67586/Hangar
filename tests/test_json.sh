#!/usr/bin/env bash
#
# --json 輸出與 transport 抽象層。用 mock 的 adb / tailscale，不碰真的手機。
#
SP="$(cd "$(dirname "$0")" && pwd)"
PM="$1"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/state" PATH="$SP/mockbin:$PATH" XDG_CONFIG_HOME="${TMPDIR:-/tmp}/hangar-test/cfg" NO_COLOR=1
P1=100.101.102.103; P2=100.101.102.110
PASS=0; FAIL=0

two_phones() {
  rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"; mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
  echo Running>"$MOCK_STATE/ts_backend"; echo true>"$MOCK_STATE/ts_online"; echo true>"$MOCK_STATE/ts_online2"
  echo direct>"$MOCK_STATE/ts_ping_mode"; echo ok>"$MOCK_STATE/adb_connect_result"
  # 刻意寫成「舊格式」的兩行 profile：沒有 TRANSPORT / DEVICE_SERIAL
  printf 'PHONE_HOST="pixel"\nPHONE_IP="%s"\n'   "$P1" > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
  printf 'PHONE_HOST="zenfone"\nPHONE_IP="%s"\n' "$P2" > "$XDG_CONFIG_HOME/hangar/profiles/test.conf"
  printf '%s\tdevice\n%s\tdevice\n' "$P1:5555" "$P2:5555" > "$MOCK_STATE/adb_devices"
  echo work > "$XDG_CONFIG_HOME/hangar/default"
}

check()   { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
assert()  { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

# q <jq-filter> <json> — 取值方便一點
q() { printf '%s' "$2" | jq -r "$1" 2>/dev/null; }
nocheck() { if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該出現 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }

echo "=== J1. stdout 只有 JSON，人類訊息不能污染 ==="
two_phones
out="$("$PM" list --json 2>/dev/null)"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && { echo "  PASS  list --json 是合法 JSON"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  list --json 不是合法 JSON：$out"; FAIL=$((FAIL+1)); }
out="$("$PM" status --json 2>/dev/null)"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && { echo "  PASS  status --json 是合法 JSON"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  status --json 不是合法 JSON：$out"; FAIL=$((FAIL+1)); }

# 沒有任何 profile 時也要吐出合法的空結果，不是警告文字
rm -rf "$XDG_CONFIG_HOME/hangar"; mkdir -p "$XDG_CONFIG_HOME/hangar/profiles"
out="$("$PM" list --json 2>/dev/null)"
assert "沒有手機時 devices 是空陣列" "0" "$(q '.devices | length' "$out")"

echo "=== J2. schema 與必要欄位 ==="
two_phones
out="$("$PM" list --json 2>/dev/null)"
assert "有 schema 版本"      "4"      "$(q '.schema' "$out")"
assert "列出兩支"            "2"      "$(q '.devices | length' "$out")"
assert "profile 名稱"        "work"   "$(q '.devices[] | select(.profile=="work") | .profile' "$out")"
assert "adb serial"          "$P1:5555" "$(q '.devices[] | select(.profile=="work") | .adb_serial' "$out")"
assert "host"                "pixel"  "$(q '.devices[] | select(.profile=="work") | .host' "$out")"
assert "ip"                  "$P1"    "$(q '.devices[] | select(.profile=="work") | .ip' "$out")"
assert "預設那支標記 default" "true"  "$(q '.devices[] | select(.profile=="work") | .default' "$out")"
assert "非預設那支是 false"   "false" "$(q '.devices[] | select(.profile=="test") | .default' "$out")"
assert "errors 是陣列"       "array"  "$(q '.devices[0].errors | type' "$out")"
assert "scrcpy_pids 是陣列"  "array"  "$(q '.devices[0].scrcpy_pids | type' "$out")"

echo "=== J3. 舊 profile 沒有 TRANSPORT → 回退成 tailscale ==="
assert "transport 預設值" "tailscale" "$(q '.devices[0].transport' "$out")"

echo "=== J4. 慢欄位要 --probe 才取，否則 list 會慢到不能用 ==="
two_phones
rm -f "$MOCK_STATE/ts_log"
out="$("$PM" list --json 2>/dev/null)"
assert "沒 --probe 時 path 是 null"    "null" "$(q '.devices[0].path' "$out")"
assert "沒 --probe 時 model 是 null"   "null" "$(q '.devices[0].model' "$out")"
assert "沒 --probe 時 battery 是 null" "null" "$(q '.devices[0].battery' "$out")"
assert "沒 --probe 時不去 ping"        "0"    "$(grep -c . "$MOCK_STATE/ts_log" 2>/dev/null || echo 0)"
# adb 狀態是便宜的（一次 adb devices），所以就算沒 --probe 也要有
assert "沒 --probe 仍有 adb_state"     "device" "$(q '.devices[0].adb_state' "$out")"

rm -f "$MOCK_STATE/ts_log"
out="$("$PM" list --json --probe 2>/dev/null)"
assert "--probe 取得 path"      "direct" "$(q '.devices[0].path.kind' "$out")"
assert "--probe 取得 latency"   "12"     "$(q '.devices[0].path.latency_ms' "$out")"
assert "--probe 取得機型"       "Pixel 7 Pro" "$(q '.devices[] | select(.profile=="work") | .model' "$out")"
assert "--probe 取得 Android"   "14"     "$(q '.devices[0].android.release' "$out")"
assert "--probe 的 sdk 是數字"  "number" "$(q '.devices[0].android.sdk | type' "$out")"
[ "$(grep -c . "$MOCK_STATE/ts_log" 2>/dev/null || echo 0)" -gt 0 ] \
  && { echo "  PASS  --probe 時才去 ping"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  --probe 沒有觸發 ping"; FAIL=$((FAIL+1)); }

echo "=== J4b. MAC：adb 問手機自己要（scan 只認得出同一段區網的） ==="
two_phones
out="$("$PM" list --json 2>/dev/null)"
assert "沒 --probe 時 mac 是 null" "null" "$(q '.devices[0].mac' "$out")"

out="$("$PM" list --json --probe 2>/dev/null)"
assert "--probe 取得 MAC"     "f0:5c:77:aa:bb:01" \
  "$(q '.devices[] | select(.profile=="work") | .mac.address' "$out")"
assert "兩支的 MAC 不一樣"    "f0:5c:77:aa:bb:02" \
  "$(q '.devices[] | select(.profile=="test") | .mac.address' "$out")"
assert "帶著 SSID"            "TestNet" "$(q '.devices[0].mac.ssid' "$out")"
# f0 的 locally-administered 位元是 0 → 這是出廠的硬體位址
assert "認得出不是隨機的"      "false"  "$(q '.devices[0].mac.randomized' "$out")"

# Android 10+ 的隨機 MAC：第一個 byte 帶 locally-administered 位元
echo "f2:5c:77:aa:bb:01" > "$MOCK_STATE/wifi_mac"
out="$("$PM" list --json --probe 2>/dev/null)"
assert "認得出隨機 MAC"        "true"   "$(q '.devices[0].mac.randomized' "$out")"
rm -f "$MOCK_STATE/wifi_mac"

# 應用程式拿不到 MAC 時 Android 回這一組假的，不能當成真的位址端出去
echo "02:00:00:00:00:00" > "$MOCK_STATE/wifi_mac"
out="$("$PM" list --json --probe 2>/dev/null)"
assert "擋掉 02:00:… 那組假的" "null" "$(q '.devices[0].mac' "$out")"
rm -f "$MOCK_STATE/wifi_mac"

# 沒連 Wi-Fi 就沒有 MAC，但其他欄位照樣要出得來
touch "$MOCK_STATE/wifi_off"
out="$("$PM" list --json --probe 2>/dev/null)"
assert "沒連 Wi-Fi 時 mac 是 null" "null" "$(q '.devices[0].mac' "$out")"
assert "沒連 Wi-Fi 也還有機型" "Pixel 7 Pro" \
  "$(q '.devices[] | select(.profile=="work") | .model' "$out")"
rm -f "$MOCK_STATE/wifi_off"

echo "=== J5. 電量 ==="
two_phones
out="$("$PM" status --json 2>/dev/null)"
assert "level 是數字"      "number" "$(q '.devices[0].battery.level | type' "$out")"
assert "level 值"          "78"     "$(q '.devices[0].battery.level' "$out")"
assert "status 轉成字串"   "discharging" "$(q '.devices[0].battery.status' "$out")"
assert "溫度有除以 10"     "27.5"   "$(q '.devices[0].battery.temperature_c' "$out")"

echo 5 > "$MOCK_STATE/battery_level"
out="$("$PM" status --json 2>/dev/null)"
assert "低電量讀得到"      "5"      "$(q '.devices[0].battery.level' "$out")"
out="$("$PM" list 2>&1)"
check "人類版 list 標出低電量" "5% !" "$out"

echo 2 > "$MOCK_STATE/battery_status"   # 2 = charging
out="$("$PM" status --json 2>/dev/null)"
assert "充電中狀態"        "charging" "$(q '.devices[0].battery.status' "$out")"
# 已經在充電了就沒必要再叫人去充電
out="$("$PM" list 2>&1)"
if printf '%s' "$out" | grep -q '5% !'; then
  printf '  FAIL  充電中不該再標「!」\n'; FAIL=$((FAIL+1))
else
  printf '  PASS  充電中不再催充電\n'; PASS=$((PASS+1))
fi
check "但電量本身還是顯示" "5%" "$out"

echo "=== J6. 錯誤要有 code，不只有中文訊息 ==="
two_phones
: > "$MOCK_STATE/adb_devices"; echo fail > "$MOCK_STATE/adb_connect_result"
out="$("$PM" status --json 2>/dev/null)"
assert "手機重開機 → adb_port_closed" "adb_port_closed" "$(q '.devices[0].errors[0].code' "$out")"
assert "連不上時 adb_state"           "disconnected"    "$(q '.devices[0].adb_state' "$out")"
check  "code 旁邊仍附人類訊息"        "重開"            "$(q '.devices[0].errors[0].message' "$out")"

two_phones
printf '%s\tunauthorized\n' "$P1:5555" > "$MOCK_STATE/adb_devices"
out="$("$PM" status --json 2>/dev/null)"
assert "unauthorized code" "unauthorized" "$(q '.devices[0].errors[] | select(.code=="unauthorized") | .code' "$out")"

two_phones
printf '%s\toffline\n' "$P1:5555" > "$MOCK_STATE/adb_devices"
out="$("$PM" status --json 2>/dev/null)"
assert "offline code" "adb_offline" "$(q '.devices[0].errors[] | select(.code=="adb_offline") | .code' "$out")"

echo "=== J7. 傳輸層掛掉時不可誤報成「手機重開機」 ==="
two_phones
echo Stopped > "$MOCK_STATE/ts_backend"
: > "$MOCK_STATE/adb_devices"; echo fail > "$MOCK_STATE/adb_connect_result"
out="$("$PM" list --json 2>/dev/null)"
assert "先報 transport_down" "transport_down" "$(q '.devices[0].errors[0].code' "$out")"
assert "reachability unknown" "unknown" "$(q '.devices[0].reachability' "$out")"
# 這是重點：Tailscale 沒開的時候如果還報 adb_port_closed，
# 讀 code 的人就會去叫使用者插 USB —— 方向完全錯了
assert "不該誤報 adb_port_closed" "" \
  "$(q '.devices[0].errors[] | select(.code=="adb_port_closed") | .code' "$out")"

echo "=== J8. 手機不在 tailnet / 離線 ==="
two_phones
echo false > "$MOCK_STATE/ts_online"
out="$("$PM" status --json 2>/dev/null)"
assert "reachability offline" "offline"      "$(q '.devices[0].reachability' "$out")"
assert "peer_offline code"    "peer_offline" "$(q '.devices[0].errors[] | select(.code=="peer_offline") | .code' "$out")"

echo "=== J9. transport 可抽換：profile 指定 lan 就走 lan backend ==="
two_phones
# lan backend 不碰 tailscale，靠 nc 測 5555 通不通
printf 'PHONE_HOST="pixel"\nPHONE_IP="%s"\nTRANSPORT="lan"\n' "$P1" \
  > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
rm -f "$MOCK_STATE/ts_log" "$MOCK_STATE/nc_log"
out="$("$PM" status --json -p work 2>/dev/null)"
assert "transport 讀到 lan" "lan" "$(q '.devices[0].transport' "$out")"
assert "lan 判定連得到"     "online" "$(q '.devices[0].reachability' "$out")"
assert "lan 不去 tailscale ping" "0" "$(grep -c . "$MOCK_STATE/ts_log" 2>/dev/null || echo 0)"
[ "$(grep -c . "$MOCK_STATE/nc_log" 2>/dev/null || echo 0)" -gt 0 ] \
  && { echo "  PASS  lan 改用 5555 連通性測試"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  lan backend 沒被呼叫到"; FAIL=$((FAIL+1)); }
# lan 連不通時要說「找不到 / 離線」，不能借用 tailnet 的措辭
echo down > "$MOCK_STATE/nc_result"
out="$("$PM" status --json -p work 2>/dev/null)"
assert "lan 連不通 → offline" "offline" "$(q '.devices[0].reachability' "$out")"
out="$("$PM" status -p work 2>&1)"
check "lan 的人類訊息不提 tailnet 以外沒意義的字" "區網" "$out"
rm -f "$MOCK_STATE/nc_result"
# 表頭在混用 transport 時必須是中性的，不能寫死 Tailscale
out="$("$PM" list 2>&1)"
check "表頭用中性欄位名" "IP" "$out"
if printf '%s' "$out" | grep -q 'Tailscale IP'; then
  printf '  FAIL  混用 transport 時表頭還寫 Tailscale IP\n'; FAIL=$((FAIL+1))
else
  printf '  PASS  表頭沒寫死 Tailscale\n'; PASS=$((PASS+1))
fi

echo "=== J10. 壞掉的 profile 不該讓整張表消失 ==="
two_phones
printf 'PHONE_HOST="broken"\n' > "$XDG_CONFIG_HOME/hangar/profiles/broken.conf"
out="$("$PM" list --json 2>/dev/null)"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && { echo "  PASS  仍輸出合法 JSON"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  一支壞掉就整個爛掉"; FAIL=$((FAIL+1)); }
assert "好的那兩支還在" "2" "$(q '.devices | length' "$out")"
out="$("$PM" list 2>&1)"
check "人類版也還列得出來" "work" "$out"

echo "=== J11. setup 會記下硬體序號與 transport ==="
rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"; mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
echo Running>"$MOCK_STATE/ts_backend"; echo true>"$MOCK_STATE/ts_online"
echo direct>"$MOCK_STATE/ts_ping_mode"; echo ok>"$MOCK_STATE/adb_connect_result"
printf 'ABC123\tdevice\n' > "$MOCK_STATE/adb_devices"
out="$("$PM" setup --transport tailscale pixel 2>&1)"
conf="$(cat "$XDG_CONFIG_HOME/hangar/profiles/pixel.conf" 2>/dev/null)"
check "profile 寫了 TRANSPORT"     'TRANSPORT="tailscale"'      "$conf"
check "profile 寫了 DEVICE_SERIAL" 'DEVICE_SERIAL="PIX0000001"' "$conf"
out="$("$PM" status --json -p pixel 2>/dev/null)"
assert "JSON 帶出 device_serial" "PIX0000001" "$(q '.devices[0].device_serial' "$out")"

echo "=== J11b. setup 預設走區網：位址問手機自己，不碰 tailscale ==="
# 這個專案以區網為主場，所以不加 --transport 時走的是 lan。
# 用 HANGAR_TAILSCALE 指到不存在的路徑，確認這條路真的沒碰 tailscale CLI。
rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"; mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
echo ok > "$MOCK_STATE/adb_connect_result"
echo ok > "$MOCK_STATE/nc_result"
printf 'ABC123\tdevice\n' > "$MOCK_STATE/adb_devices"
saved_ts="${HANGAR_TAILSCALE:-}"
export HANGAR_TAILSCALE=/nonexistent/tailscale
out="$("$PM" setup --name deskphone < /dev/null 2>&1)"; rc=$?
conf="$(cat "$XDG_CONFIG_HOME/hangar/profiles/deskphone.conf" 2>/dev/null)"
assert "離開碼 0"                  "0" "$rc"
check  "profile 是 lan"            'TRANSPORT="lan"'          "$conf"
# mock 的 en0 是 192.168.1.42/24，手機同時有 rmnet（10.244.13.7）與 wlan0
# （192.168.1.5）—— 挑到 4G 那個的話這台電腦連不到，所以這條是重點。
check  "挑到同網段的 wlan0 位址"   'PHONE_IP="192.168.1.5"'   "$conf"
nocheck "沒有挑到行動網路的位址"   '10.244.13.7'              "$conf"
check  "PHONE_HOST 是空的"         'PHONE_HOST=""'            "$conf"
nocheck "訊息裡不提 tailnet"       'tailnet'                  "$out"

# 直接給 IP 就不用問手機（--existing 之外的第二條路）
out="$("$PM" setup 192.168.1.77 --name given < /dev/null 2>&1)"
conf="$(cat "$XDG_CONFIG_HOME/hangar/profiles/given.conf" 2>/dev/null)"
check "指定的 IP 直接寫進去" 'PHONE_IP="192.168.1.77"' "$conf"

# 區網的 setup 收的是 IP，不是節點名 —— 拿節點名進來要講清楚，不要默默去掃描
out="$("$PM" setup zenfone --name bad < /dev/null 2>&1)"; rc=$?
assert "節點名進區網 setup 會擋下來" "1" "$rc"
check  "而且說得出要的是什麼"        "要的是手機的 IP"  "$out"

# 不加 --name 時用位址最後一段當名字（區網沒有節點名可以借）
"$PM" setup 192.168.1.88 < /dev/null >/dev/null 2>&1
[ -f "$XDG_CONFIG_HOME/hangar/profiles/phone-88.conf" ] \
  && { echo "  PASS  預設名稱取自位址最後一段"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  預設名稱取自位址最後一段（找不到 phone-88.conf）"; FAIL=$((FAIL+1)); }
if [ -n "$saved_ts" ]; then export HANGAR_TAILSCALE="$saved_ts"; else unset HANGAR_TAILSCALE; fi

echo "=== J11c. 舊 profile 沒有 TRANSPORT → 就地補成 tailscale，不吃新預設值 ==="
# 預設值翻成 lan 之後，舊檔跟著預設值走就等於被靜默改判成區網直連，
# 而它們的 PHONE_IP 是 Tailscale IP。所以要就地補行，不是靠預設值。
rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"; mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
echo Running>"$MOCK_STATE/ts_backend"; echo true>"$MOCK_STATE/ts_online"
printf 'PHONE_HOST="pixel"\nPHONE_IP="100.101.102.103"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/oldone.conf"
out="$("$PM" list --json 2>/dev/null)"
assert "讀進來當 tailscale" "tailscale" "$(q '.devices[0].transport' "$out")"
check  "那一行被補進檔案了"  'TRANSPORT="tailscale"' \
       "$(cat "$XDG_CONFIG_HOME/hangar/profiles/oldone.conf")"
# 補過之後再跑一次不可以重複追加
"$PM" list --json >/dev/null 2>&1
assert "不會重複補" "1" \
  "$(grep -c '^TRANSPORT=' "$XDG_CONFIG_HOME/hangar/profiles/oldone.conf")"

echo "=== J11d. hangar usb：裝置牆的第三個來源（M2c）==="
# 前兩份都看不到「插著 USB、偵錯開了、但還沒 setup」的手機：list 只走 profile，
# scan 探的是 5555，而 5555 要 adb tcpip 才會開。
rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"; mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
printf 'ABC123\tdevice\nBROKEN9\tunauthorized\n100.1.2.3:5555\tdevice\n' \
  > "$MOCK_STATE/adb_devices"
out="$("$PM" usb --json 2>/dev/null)"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && { echo "  PASS  是合法 JSON"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  usb --json 不是合法 JSON：$out"; FAIL=$((FAIL+1)); }
assert "有自己的 schema"   "1"      "$(q '.schema' "$out")"
# 網路 adb（host:port）不是 USB —— 混進來的話牆上會多一張假的卡
assert "只算 USB 那兩支"   "2"      "$(q '.devices | length' "$out")"
assert "序號問手機拿"      "PIX0000001" "$(q '.devices[0].device_serial' "$out")"
assert "機型也拿得到"      "Pixel 7 Pro" "$(q '.devices[0].model' "$out")"
assert "adb_state"         "device" "$(q '.devices[0].adb_state' "$out")"

# unauthorized 是這一份最值錢的一格。問不到 ro.serialno，但 adb 的 USB serial
# 本來就是硬體序號 —— 不能因為問不到就讓這一列消失。
assert "未授權那支也在"    "unauthorized" "$(q '.devices[1].adb_state' "$out")"
assert "退回用 adb serial" "BROKEN9"      "$(q '.devices[1].device_serial' "$out")"
assert "問不到機型就是 null" "null"       "$(q '.devices[1].model' "$out")"

# 已經設定過的手機要講得出 profile 名字（給人看的；merge 靠的是序號本身）
printf 'PHONE_IP="192.168.1.5"\nTRANSPORT="lan"\nDEVICE_SERIAL="PIX0000001"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
out="$("$PM" usb --json 2>/dev/null)"
assert "序號對得上就標出 profile" "work" "$(q '.devices[0].profile' "$out")"
assert "對不上的仍是 null"        "null" "$(q '.devices[1].profile' "$out")"

# 人類版：那句認知落差的提醒一定要在
out="$("$PM" usb 2>&1)"
check "列得出未授權" "未授權" "$out"
check "講出插著不等於看得見" "插著 USB 不等於牆上看得見" "$out"

printf '' > "$MOCK_STATE/adb_devices"
out="$("$PM" usb --json 2>/dev/null)"
assert "沒插東西是空陣列" "0" "$(q '.devices | length' "$out")"

echo "=== J12. 沒裝 tailscale 時，lan profile 仍然要能用 ==="
# 這一段用 HANGAR_TAILSCALE 指到不存在的路徑來模擬「這台機器沒裝 tailscale」。
# 不能只靠把 mockbin 從 PATH 拿掉——find_tailscale 有 /Applications 等絕對路徑 fallback。
two_phones
echo ok > "$MOCK_STATE/nc_result"
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.50"\nTRANSPORT="lan"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/lanphone.conf"
printf '%s\tdevice\n%s\tdevice\n%s\tdevice\n' \
  "$P1:5555" "$P2:5555" "192.168.1.50:5555" > "$MOCK_STATE/adb_devices"
export HANGAR_TAILSCALE=/nonexistent/tailscale

out="$("$PM" status --json -p lanphone 2>/dev/null)"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && { echo "  PASS  lan profile 仍吐得出合法 JSON"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  lan profile 沒有 tailscale 就掛了：$out"; FAIL=$((FAIL+1)); }
assert "lan profile 連得到"       "online" "$(q '.devices[0].reachability' "$out")"
assert "lan profile 沒有錯誤"     "0"      "$(q '.devices[0].errors | length' "$out")"

# tailscale profile 要說「工具沒裝」，不能說「沒連線」——後者會叫人去跑 tailscale up
out="$("$PM" status --json -p work 2>/dev/null)"
assert "tailscale profile 報 transport_unavailable" \
  "transport_unavailable" "$(q '.devices[0].errors[0].code' "$out")"
assert "不可誤報成 transport_down" "" \
  "$(q '.devices[0].errors[] | select(.code == "transport_down") | .code' "$out")"

# 一支缺工具不該讓整張表消失
out="$("$PM" list --json 2>/dev/null)"
assert "list 仍列出全部三支" "3" "$(q '.devices | length' "$out")"
assert "其中 lan 那支照常可用" "online" \
  "$(q '.devices[] | select(.profile == "lanphone") | .reachability' "$out")"

# 真的要操作 tailscale 裝置時才擋，而且要講到 tailscale
out="$("$PM" -p work 2>&1)"; rc=$?
assert "mirror tailscale profile 會失敗" "1" "$rc"
check "而且訊息要指向 tailscale" "tailscale" "$out"

unset HANGAR_TAILSCALE

echo "=== J13. 缺 nc 要說缺 nc，不能說成「手機沒連上區網」 ==="
# nc 沒裝跟手機真的不在線是兩回事：前者要修的是這台電腦，後者要去看手機。
# 用一個只有非執行權限的假 nc 讓 command -v 找不到它。
two_phones
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.50"\nTRANSPORT="lan"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/lanphone.conf"
printf '%s\tdevice\n' "192.168.1.50:5555" > "$MOCK_STATE/adb_devices"
# 只把 mockbin 的 nc 拿掉不夠——系統的 /usr/bin/nc 還在 PATH 上。所以另外組一份
# 「除了 nc 以外什麼都有」的 PATH，且只用這一份。
NONC="$MOCK_STATE/nonc"; rm -rf "$NONC"; mkdir -p "$NONC"
for d in "$SP/mockbin" /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "nc" ] && continue
    [ -e "$NONC/$b" ] || ln -s "$f" "$NONC/$b" 2>/dev/null
  done
done
command -v nc >/dev/null 2>&1 && [ ! -e "$NONC/nc" ] \
  && { echo "  PASS  測試前提：這份 PATH 裡確實沒有 nc"; PASS=$((PASS+1)); }
out="$(PATH="$NONC" "$PM" status --json -p lanphone 2>/dev/null)"
assert "缺 nc 報 transport_unavailable" \
  "transport_unavailable" "$(q '.devices[0].errors[0].code' "$out")"
check "訊息要點名 nc" "nc" "$(q '.devices[0].errors[0].message' "$out")"
assert "不可誤報成 peer_offline" "" \
  "$(q '.devices[0].errors[] | select(.code == "peer_offline") | .code' "$out")"


echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

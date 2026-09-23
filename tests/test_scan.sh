#!/usr/bin/env bash
#
# 區網掃描（hangar scan）與 lan backend 的候選清單。
# 用 mock 的 arp / ping / ip / ifconfig / route / nc，不會真的碰到網路。
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
lines()  { grep -c . "$1" 2>/dev/null || echo 0; }

# 這個網段上有：閘道器、這台電腦自己、一支開著 5555 的手機、一支用隨機 MAC 的
# 手機，另外還有一筆 incomplete 和一筆別的網段 —— 後面這三者都不該出現在結果裡。
lan_env() {
  rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"
  mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
  cat > "$MOCK_STATE/arp_table" <<'ARP'
? (192.168.1.1) at 3c:37:86:aa:bb:cc on en0 ifscope [ethernet]
? (192.168.1.42) at 11:22:33:44:55:66 on en0 ifscope [ethernet]
? (192.168.1.77) at a4:3:e7:1:2:3 on en0 ifscope [ethernet]
? (192.168.1.90) at de:ad:be:ef:00:01 on en0 ifscope [ethernet]
? (192.168.1.91) at (incomplete) on en0 ifscope [ethernet]
? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope [ethernet]
? (192.168.1.200) at 1:0:5e:7f:ff:fa on en0 ifscope [ethernet]
? (10.0.0.5) at 0:11:22:33:44:99 on en1 ifscope [ethernet]
ARP
  printf '192.168.1.77\n' > "$MOCK_STATE/nc_open_ips"
  # 預設當成「這台機器上沒有 OUI 資料庫」，廠商那欄才有確定的期望值
  export HANGAR_OUI_FILE="$MOCK_STATE/no-such-oui-db"
}

echo "=== S1. scan --json 的基本形狀 ==="
lan_env
out="$("$PM" scan --json 2>/dev/null)"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && { echo "  PASS  是合法 JSON"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  不是合法 JSON：$out"; FAIL=$((FAIL+1)); }
assert "有 schema 版本"      "8"                "$(q '.schema' "$out")"
assert "掃的網段寫在結果裡"  "192.168.1.0/24"   "$(q '.subnet' "$out")"
assert "hosts 是陣列"        "array"            "$(q '.hosts | type' "$out")"
assert "errors 是空陣列"     "0"                "$(q '.errors | length' "$out")"
assert "找到三台"            "3"                "$(q '.hosts | length' "$out")"
assert "排除這台電腦自己"    ""    "$(q '.hosts[] | select(.ip=="192.168.1.42") | .ip' "$out")"
assert "排除別的網段"        ""    "$(q '.hosts[] | select(.ip=="10.0.0.5") | .ip' "$out")"
assert "incomplete 不算裝置" ""    "$(q '.hosts[] | select(.ip=="192.168.1.91") | .ip' "$out")"
# ARP 表裡不只有裝置：廣播、mDNS 的多播位址都在裡面，那些背後沒有機器
assert "排除廣播位址"       ""    "$(q '.hosts[] | select(.ip=="192.168.1.255") | .ip' "$out")"
assert "排除多播 MAC 的項目" ""   "$(q '.hosts[] | select(.ip=="192.168.1.200") | .ip' "$out")"
assert "依 IP 排序"          "192.168.1.1 192.168.1.77 192.168.1.90" \
                             "$(q '[.hosts[].ip] | join(" ")' "$out")"

echo "=== S2. MAC：macOS 省略的 0 要補回來，隨機 MAC 要標出來 ==="
assert "a4:3:e7:1:2:3 正規化"  "a4:03:e7:01:02:03" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .mac' "$out")"
assert "隨機 MAC 要標記"        "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.90") | .mac_randomized' "$out")"
assert "一般 MAC 不標記"        "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.1") | .mac_randomized' "$out")"

echo "=== S3. 5555 開著的要看得出來 ==="
assert "有開的是 open"     "open"   "$(q '.hosts[] | select(.ip=="192.168.1.77") | .adb_port' "$out")"
assert "沒開的是 closed"   "closed" "$(q '.hosts[] | select(.ip=="192.168.1.1")  | .adb_port' "$out")"
lan_env
out="$("$PM" scan --json --no-probe 2>/dev/null)"
assert "--no-probe 一律 unknown" "unknown" \
  "$(q '[.hosts[].adb_port] | unique | .[0]' "$out")"
assert "--no-probe 不去戳 nc"    "0" "$(lines "$MOCK_STATE/nc_log")"

echo "=== S4. 已經設定過的裝置要標出 profile 名稱 ==="
lan_env
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.77"\nTRANSPORT="lan"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
out="$("$PM" scan --json 2>/dev/null)"
assert "設定過的認得出來"   "work" "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile' "$out")"
assert "沒設定過的是 null"  "null" "$(q '.hosts[] | select(.ip=="192.168.1.90") | .profile' "$out")"

echo "=== S5. ping sweep：預設掃整個 /24，--no-ping 只讀 ARP 表 ==="
lan_env
"$PM" scan --json >/dev/null 2>&1
assert "掃了 254 個位址" "254" "$(lines "$MOCK_STATE/ping_log")"
lan_env
out="$("$PM" scan --json --no-ping 2>/dev/null)"
assert "--no-ping 完全不 ping" "0" "$(lines "$MOCK_STATE/ping_log")"
assert "--no-ping 仍然讀得到 ARP 表" "3" "$(q '.hosts | length' "$out")"

echo "=== S6. 缺工具要說缺工具，不能說成「區網上沒東西」 ==="
# 讀不到 ARP 表跟區網上真的沒有裝置是兩回事：前者要修的是這台電腦。
# 做一份「除了 arp 與 ip 以外什麼都有」的 PATH——系統路徑上也可能有這兩個。
lan_env
NOARP="$MOCK_STATE/noarp"; rm -rf "$NOARP"; mkdir -p "$NOARP"
for d in "$SP/mockbin" /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    { [ "$b" = "arp" ] || [ "$b" = "ip" ]; } && continue
    [ -e "$NOARP/$b" ] || ln -s "$f" "$NOARP/$b" 2>/dev/null
  done
done
[ ! -e "$NOARP/arp" ] && [ ! -e "$NOARP/ip" ] \
  && { echo "  PASS  測試前提：這份 PATH 裡沒有 arp 也沒有 ip"; PASS=$((PASS+1)); }
out="$(PATH="$NOARP" "$PM" scan --json 2>/dev/null)"
assert "報 scan_unavailable" "scan_unavailable" "$(q '.errors[0].code' "$out")"
check "訊息要點名 ARP 表"    "ARP"              "$(q '.errors[0].message' "$out")"
assert "不可誤報成 subnet_unknown" "" \
  "$(q '.errors[] | select(.code=="subnet_unknown") | .code' "$out")"
assert "hosts 是空的"        "0"                "$(q '.hosts | length' "$out")"
PATH="$NOARP" "$PM" scan >/dev/null 2>&1
assert "人類模式離開碼 1"    "1"                "$?"

# ping 只有 sweep 才要用：--no-ping 是純讀 ARP 表，不該因為缺 ping 就整個擋掉
lan_env
NOPING="$MOCK_STATE/noping"; rm -rf "$NOPING"; mkdir -p "$NOPING"
for d in "$SP/mockbin" /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "ping" ] && continue
    [ -e "$NOPING/$b" ] || ln -s "$f" "$NOPING/$b" 2>/dev/null
  done
done
[ ! -e "$NOPING/ping" ] \
  && { echo "  PASS  測試前提：這份 PATH 裡沒有 ping"; PASS=$((PASS+1)); }
out="$(PATH="$NOPING" "$PM" scan --json --no-ping 2>/dev/null)"
assert "--no-ping 不需要 ping"     "3" "$(q '.hosts | length' "$out")"
out="$(PATH="$NOPING" "$PM" scan --json 2>/dev/null)"
assert "要 sweep 卻沒有 ping 才報錯" "scan_unavailable" "$(q '.errors[0].code' "$out")"
check "並且要提到 --no-ping"         "--no-ping"        "$(q '.errors[0].message' "$out")"

echo "=== S7. 網段偵測 ==="
lan_env
echo 1 > "$MOCK_STATE/ip_no_route"     # 沒有預設路由 → 改走 macOS 的 route+ifconfig
out="$("$PM" scan --json 2>/dev/null)"
assert "macOS 那條路也測得出網段" "192.168.1.0/24" "$(q '.subnet' "$out")"
assert "真的有去問 ifconfig"      "1" \
  "$( [ -f "$MOCK_STATE/ifconfig_log" ] && echo 1 || echo 0 )"

lan_env
echo "2: en0    inet 172.16.3.9/16 brd 172.16.255.255 scope global en0" > "$MOCK_STATE/ip_addr"
out="$("$PM" scan --json 2>/dev/null)"
assert "/16 掃不動要說清楚"  "subnet_too_big" "$(q '.errors[0].code' "$out")"
check "並且要教人怎麼指定"   "--subnet"       "$(q '.errors[0].message' "$out")"

lan_env
echo "2: en0    inet 192.168.1.42/28 brd 192.168.1.47 scope global en0" > "$MOCK_STATE/ip_addr"
out="$("$PM" scan --json 2>/dev/null)"
assert "比 /24 小的網段照掃"  "192.168.1.0/24" "$(q '.subnet' "$out")"

lan_env
echo 1 > "$MOCK_STATE/ip_no_route"; : > "$MOCK_STATE/ifconfig_out"
out="$("$PM" scan --json 2>/dev/null)"
assert "兩邊都測不出來 → subnet_unknown" "subnet_unknown" "$(q '.errors[0].code' "$out")"
check "要教人用 --subnet"                "--subnet"       "$(q '.errors[0].message' "$out")"

echo "=== S8. --subnet 指定 ==="
lan_env
out="$("$PM" scan --json --subnet 192.168.1.0/24 2>/dev/null)"
assert "吃得下 a.b.c.0/24 寫法" "192.168.1.0/24" "$(q '.subnet' "$out")"
assert "結果一樣是三台"         "3"              "$(q '.hosts | length' "$out")"
lan_env
out="$("$PM" scan --json --subnet 192.168.1.250 2>/dev/null)"
assert "給完整 IP 就取它的 /24" "192.168.1.0/24" "$(q '.subnet' "$out")"
lan_env
out="$("$PM" scan --json --subnet=10.9.8 2>/dev/null)"
assert "--subnet= 寫法也收"     "10.9.8.0/24"    "$(q '.subnet' "$out")"
assert "那個網段上沒有東西"     "0"              "$(q '.hosts | length' "$out")"
lan_env
out="$("$PM" scan --json --subnet 不是網段 2>/dev/null)"
assert "亂打要報 subnet_invalid" "subnet_invalid" "$(q '.errors[0].code' "$out")"

echo "=== S9. 廠商：有資料庫才查，沒有就老實說不知道 ==="
lan_env
out="$("$PM" scan --json 2>/dev/null)"
assert "沒有資料庫時 vendor 是 null" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .vendor' "$out")"
lan_env
printf 'A403E7 Pixel Widgets Inc\n' > "$MOCK_STATE/oui_nmap"
export HANGAR_OUI_FILE="$MOCK_STATE/oui_nmap"
out="$("$PM" scan --json 2>/dev/null)"
assert "nmap 格式查得到"  "Pixel Widgets Inc" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .vendor' "$out")"
lan_env
printf 'A4:03:E7\tPixelW\tPixel Widgets Inc\n' > "$MOCK_STATE/oui_manuf"
printf 'DE:AD:BE\tNope\tNope Inc\n' >> "$MOCK_STATE/oui_manuf"
export HANGAR_OUI_FILE="$MOCK_STATE/oui_manuf"
out="$("$PM" scan --json 2>/dev/null)"
assert "wireshark manuf 格式查得到" "PixelW" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .vendor' "$out")"
# 隨機 MAC 查 OUI 沒有意義（那一段是裝置自己隨機生的，不是廠商代碼）
assert "隨機 MAC 不查廠商" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.90") | .vendor' "$out")"

echo "=== S10. 人類輸出 ==="
lan_env
out="$("$PM" scan 2>/dev/null)"
check "列出 IP"            "192.168.1.77" "$out"
check "5555 開著的標 open" "open"         "$out"
lan_env
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.77"\nTRANSPORT="lan"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
out="$("$PM" scan 2>/dev/null)"
check "標出已設定的 profile" "work" "$out"
# 每一欄都要從同一個顯示欄位開始（跟 list / status 一樣的要求）。廠商是最後一欄，
# 量它的起點等於量前面每一欄的寬度都算對了 —— 這也是把長度不定的廠商名擺最後、
# 不讓它推歪別人的那個決定的回歸測試。
lan_env
printf 'A4:03:E7\t宏達電子\t宏達電子股份有限公司\n' > "$MOCK_STATE/oui_manuf"
printf '3C:3786\tHon Hai Precision Ind. Co., Ltd.\tx\n' >> "$MOCK_STATE/oui_manuf"
export HANGAR_OUI_FILE="$MOCK_STATE/oui_manuf"
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.77"\nTRANSPORT="lan"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
out="$("$PM" scan 2>&1)"
cols="$(printf '%s\n' "$out" | python3 -c '
import sys, unicodedata, re
w = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
starts = []
for line in sys.stdin:
    raw = re.sub(r"\x1b\[[0-9;]*m", "", line.rstrip("\n"))
    if not re.match(r"^\s+192\.168\.1\.", raw): continue
    m = re.match(r"^\s+\S+\s+\S+\s+(open|closed|\?)\s+\S+\s+", raw)
    if m: starts.append(w(m.group(0)))
print("same" if len(starts) > 1 and len(set(starts)) == 1 else f"differ:{starts}")')"
assert "廠商欄都從同一欄開始" "same" "$cols"

echo "=== S11. lan backend 的候選清單走的是同一份掃描結果 ==="
# transport_list_candidates 是 setup 選單的介面，沒有對應的子指令可以打；
# 把 script 最後那行 main 去掉之後 source 進來，直接叫那個函式。
lan_env
rows="$(bash -c '
  eval "$(sed "\$d" "'"$PM"'")"
  TRANSPORT=lan transport_list_candidates
' 2>/dev/null)"
assert "三台都列出來"       "3" "$(printf '%s\n' "$rows" | grep -c .)"
assert "欄位是 n|名稱|IP|OS|狀態" "5" \
  "$(printf '%s\n' "$rows" | head -1 | awk -F'|' '{print NF}')"
assert "編號從 1 開始連號"  "1 2 3" \
  "$(printf '%s\n' "$rows" | awk -F'|' '{printf "%s ", $1}' | sed 's/ $//')"
check  "5555 開著的標成 android" "|192.168.1.77|android|online" "$rows"
check  "隨機 MAC 的名稱說得出來" "隨機 MAC"                      "$rows"
assert "沒開 5555 的 OS 欄不亂猜" "?" \
  "$(printf '%s\n' "$rows" | awk -F'|' '$3=="192.168.1.1" {print $4}')"

echo "=== S12. 識別合併：認人靠 MAC 與序號，不是靠 IP ==="
# 只比 IP 的話，DHCP 一換位址同一支手機就變成「另一台」，而舊 IP 被分給別的
# 機器時還會把那台誤認成這支手機。以下四件事是這一層的全部重點。
mkprofile() { # <名稱> <IP> [MAC] [序號]
  { printf 'PHONE_HOST=""\nPHONE_IP="%s"\nTRANSPORT="lan"\n' "$2"
    [ -n "${3:-}" ] && printf 'PHONE_MAC="%s"\n' "$3"
    [ -n "${4:-}" ] && printf 'DEVICE_SERIAL="%s"\n' "$4"
  } > "$XDG_CONFIG_HOME/hangar/profiles/$1.conf"
}
pfield() { grep -E "^$2=" "$XDG_CONFIG_HOME/hangar/profiles/$1.conf" 2>/dev/null | head -1 | cut -d'"' -f2; }

# (1) 第一次只能靠 IP 對上，對上就把 MAC 記進 profile
lan_env
mkprofile work 192.168.1.77
out="$("$PM" scan --json 2>/dev/null)"
assert "第一次是靠 IP 對上的"   "ip"   "$(q '.hosts[] | select(.ip=="192.168.1.77") | .matched_by' "$out")"
assert "MAC 記進 profile 了"    "a4:03:e7:01:02:03" "$(pfield work PHONE_MAC)"
assert "沒對上的 matched_by 是 null" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.90") | .matched_by' "$out")"
# 記 MAC 是寫檔，不是輸出；--json 的 stdout 仍然只能有 JSON
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && { echo "  PASS  學到 MAC 時 stdout 仍是純 JSON"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  stdout 被污染：$out"; FAIL=$((FAIL+1)); }

# (2) 記過 MAC 之後，手機換了 IP 還是同一支
lan_env
mkprofile work 192.168.1.250 a4:03:e7:01:02:03
out="$("$PM" scan --json 2>/dev/null)"
assert "換了 IP 仍認得出來"     "work" "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile' "$out")"
assert "而且說得出是靠 MAC"     "mac"  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .matched_by' "$out")"
assert "profile 指著舊 IP 要標出來" "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile_ip_stale' "$out")"
assert "沒換 IP 的不該被標成 stale" "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.1") | .profile_ip_stale' "$out")"
out="$("$PM" scan 2>&1)"
check "人類模式要講舊 IP 已經不對" "192.168.1.250" "$out"
check "也要講手機現在在哪"         "就是 192.168.1.77 這台" "$out"
check "並且講得出怎麼修"          "scan --fix-ip" "$out"

# (3) 舊 IP 被別台機器拿走時，不可以把那台誤認成這支手機
lan_env
mkprofile work 192.168.1.1 a4:03:e7:01:02:03
out="$("$PM" scan --json 2>/dev/null)"
assert "IP 相同但 MAC 不同 → 不是它" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.1") | .profile' "$out")"
assert "真正的那支才是 work"          "work" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile' "$out")"
assert "而且 MAC 沒有被改掉"          "a4:03:e7:01:02:03" "$(pfield work PHONE_MAC)"

# (4) 一個 profile 只能認領一台機器
lan_env
mkprofile work 192.168.1.90 a4:03:e7:01:02:03
out="$("$PM" scan --json 2>/dev/null)"
assert "MAC 對上的那台算它"       "work" "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile' "$out")"
assert "IP 對上的那台不能也算它" "null" "$(q '.hosts[] | select(.ip=="192.168.1.90") | .profile' "$out")"

# (5) 隨機 MAC 會換一組，不能因為記過就把這支手機永遠鎖死在對不上
lan_env
mkprofile phone 192.168.1.90 de:ad:be:ef:00:99
out="$("$PM" scan --json 2>/dev/null)"
assert "隨機 MAC 換過 → 退回用 IP 對" "ip" \
  "$(q '.hosts[] | select(.ip=="192.168.1.90") | .matched_by' "$out")"
assert "並且把新的那組記起來"         "de:ad:be:ef:00:01" "$(pfield phone PHONE_MAC)"

# (6) 序號是 hub 合併資料時的主鍵，對上 profile 就要附出去
lan_env
mkprofile work 192.168.1.77 "" R58M12345AB
out="$("$PM" scan --json 2>/dev/null)"
assert "對上的附上裝置序號" "R58M12345AB" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .device_serial' "$out")"
assert "沒對上的是 null"    "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.90") | .device_serial' "$out")"

# (7) tailscale profile 存的是 100.x，拿區網 IP 去比沒有意義，不可以亂報 stale
lan_env
printf 'PHONE_HOST="pixel"\nPHONE_IP="100.101.102.77"\nTRANSPORT="tailscale"\nPHONE_MAC="a4:03:e7:01:02:03"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/pixel.conf"
out="$("$PM" scan --json 2>/dev/null)"
assert "tailscale profile 也認得出手機" "pixel" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile' "$out")"
assert "但不可以說它的 IP 過期了" "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile_ip_stale' "$out")"

# (8) 讀不懂的 profile 不可以讓整個比對停擺
lan_env
mkprofile work 192.168.1.77
printf 'garbage without any fields\n' > "$XDG_CONFIG_HOME/hangar/profiles/broken.conf"
out="$("$PM" scan --json 2>/dev/null)"
assert "壞掉的 profile 不影響別支" "work" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile' "$out")"
assert "而且它自己不會亂認一台" "0" \
  "$(q '[.hosts[] | select(.profile=="broken")] | length' "$out")"

# (9) 設定過的手機在 setup 的候選清單裡要直接顯示名稱，不是廠商
lan_env
mkprofile work 192.168.1.77
rows="$(bash -c '
  eval "$(sed "\$d" "'"$PM"'")"
  TRANSPORT=lan transport_list_candidates
' 2>/dev/null)"
check "候選清單標出 profile 名稱" "|work|192.168.1.77|android|online" "$rows"

echo "=== S13. --fix-ip：認得出是同一支手機，就把 profile 的 IP 修對 ==="
# 掃描平常是唯讀的，改設定檔要 --fix-ip 明講才做。
lan_env
mkprofile work 192.168.1.250 a4:03:e7:01:02:03
out="$("$PM" scan --json 2>/dev/null)"
assert "沒給旗標就不動 profile" "192.168.1.250" "$(pfield work PHONE_IP)"
assert "而且照樣標成 stale"     "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile_ip_stale' "$out")"
assert "沒給旗標 fixed 是 false" "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile_ip_fixed' "$out")"

lan_env
mkprofile work 192.168.1.250 a4:03:e7:01:02:03
out="$("$PM" scan --json --fix-ip 2>/dev/null)"
assert "--fix-ip 把 IP 改成現在的"  "192.168.1.77" "$(pfield work PHONE_IP)"
assert "修好了就不再是 stale"       "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile_ip_stale' "$out")"
assert "而且說得出這支被修過"       "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .profile_ip_fixed' "$out")"
assert "MAC 沒被動到"               "a4:03:e7:01:02:03" "$(pfield work PHONE_MAC)"
assert "改檔案不影響 JSON 純淨度"   "8" "$(q '.schema' "$out")"
# 只改該改的那一行，其他欄位不能被洗掉
assert "TRANSPORT 還在"             "lan"  "$(pfield work TRANSPORT)"

# 沒有 MAC 只靠 IP 對上的，本來就沒有 IP 可修，不該亂動別人
lan_env
mkprofile work 192.168.1.77
mkprofile other 192.168.1.1
"$PM" scan --json --fix-ip >/dev/null 2>&1
assert "IP 本來就對的不會被改" "192.168.1.77" "$(pfield work PHONE_IP)"
assert "別支也不會被波及"      "192.168.1.1"  "$(pfield other PHONE_IP)"

# tailscale profile 的 100.x 不是「舊 IP」，不可以被 --fix-ip 改成區網 IP
lan_env
printf 'PHONE_HOST="pixel"\nPHONE_IP="100.101.102.77"\nTRANSPORT="tailscale"\nPHONE_MAC="a4:03:e7:01:02:03"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/pixel.conf"
"$PM" scan --json --fix-ip >/dev/null 2>&1
assert "tailscale profile 的 IP 不准動" "100.101.102.77" "$(pfield pixel PHONE_IP)"

# 人類模式要講改了什麼；修過一次之後再掃就沒有東西可報了
lan_env
mkprofile work 192.168.1.250 a4:03:e7:01:02:03
out="$("$PM" scan --fix-ip 2>&1)"
check "說出改了哪一支"   "「work」的 PHONE_IP 已更新" "$out"
check "說出新舊位址"     "192.168.1.250 → 192.168.1.77" "$out"
out="$("$PM" scan --fix-ip 2>&1)"
nocheck "已經修好就不再重複報" "PHONE_IP 已更新" "$out"

echo "=== S14. 預設路由走 VPN 通道時，不可以拿通道當區網 ==="
# 真的拿一台 Mac 當 hub 的時候踩到的：預設路由走 utun4（Tailscale），而它的
# inet 行是點對點格式 `inet A --> B netmask 0x…`。照欄位位置抓 netmask 會抓到
# **對端位址**，算出來是 /0，掃描就報 subnet_too_big 整個停擺。
# 跑 Tailscale 的機器正是這個專案的目標機器，這不是邊緣案例。
lan_env
echo 1 > "$MOCK_STATE/ip_no_route"          # 走 macOS 那條路
export MOCK_ROUTE_IF=utun4
printf 'lo0 en0 utun4\n' > "$MOCK_STATE/ifconfig_list"
out="$("$PM" scan --json 2>/dev/null)"
assert "改去問實體介面"     "192.168.1.0/24" "$(q '.subnet' "$out")"
assert "不可以報 too_big"   "" "$(q '.errors[] | select(.code=="subnet_too_big") | .code' "$out")"
assert "而且掃得到東西"     "3" "$(q '.hosts | length' "$out")"
unset MOCK_ROUTE_IF

# 只有通道、沒有實體介面時，要老實說測不出來，不要硬掰一個 /0 出來
lan_env
echo 1 > "$MOCK_STATE/ip_no_route"
export MOCK_ROUTE_IF=utun4
printf 'lo0 utun4\n' > "$MOCK_STATE/ifconfig_list"
out="$("$PM" scan --json 2>/dev/null)"
assert "沒有實體介面就說不知道" "subnet_unknown" "$(q '.errors[0].code' "$out")"
check  "並且教人用 --subnet"    "--subnet" "$(q '.errors[0].message' "$out")"
unset MOCK_ROUTE_IF

echo "=== S15. 中文訊息在 zh_TW.UTF-8 底下不可以炸 ==="
# bash 在那個 locale 會把 "$pfx，" 的中文位元組算進變數名字裡，配上 set -u
# 就是 unbound variable —— 整個指令死掉，而且錯誤訊息本身是亂碼。
#
# 這一節要那個 locale 真的裝在這台機器上。沒有的話 bash 只印一行 setlocale 警告
# 然後退回 C，情境根本重現不了；更糟的是那行警告會混進下面 2>&1 抓的輸出裡，把
# JSON 弄壞 —— 看起來像產品吐不出 JSON，其實是 locale 不存在。多數 Linux 只有
# C.utf8，所以這裡先找，找不到就跳過。
ZHTW="$(locale -a 2>/dev/null | grep -im1 -E '^zh_TW\.(UTF-8|utf8)$')"
if [ -z "$ZHTW" ]; then
  echo "  SKIP  這台機器沒有 zh_TW.UTF-8，中文 locale 那一節重現不了"
else
  lan_env
  echo "2: en0    inet 172.16.3.9/16 brd 172.16.255.255 scope global en0" > "$MOCK_STATE/ip_addr"
  out="$(LC_ALL="$ZHTW" "$PM" scan --json 2>&1)"
  assert "該報的錯照樣報"   "subnet_too_big" "$(q '.errors[0].code' "$out")"
  nocheck "不可以 unbound"  "unbound variable" "$out"
  out="$(LC_ALL="$ZHTW" "$PM" scan 2>&1)"
  nocheck "人類模式也一樣"  "unbound variable" "$out"
fi

echo "=== S16. 閘道器要標出來（它每次都會出現，而且絕對不是測試機）==="
lan_env
printf '192.168.1.1\n' > "$MOCK_STATE/gateway_ip"
out="$("$PM" scan --json 2>/dev/null)"
assert "schema 往上加了"   "8" "$(q '.schema' "$out")"
assert "閘道器標出來了"     "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.1") | .is_gateway' "$out")"
assert "別台不可以被標成閘道器" "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .is_gateway' "$out")"
out="$("$PM" scan 2>/dev/null)"
check "人類表格的身分欄寫閘道器" "閘道器" "$out"

# 問不到閘道位址時不可以亂標一台
lan_env
touch "$MOCK_STATE/gateway_none"
echo 1 > "$MOCK_STATE/ip_no_route"      # Linux 那條路也問不到
out="$("$PM" scan --json 2>/dev/null)"
assert "問不到就一台都不標" "0" \
  "$(q '[.hosts[] | select(.is_gateway)] | length' "$out")"
assert "但其他東西照常"     "3" "$(q '.hosts | length' "$out")"

# 閘道位址不在正在掃的網段裡（換過網路、或指定了別的網段）也不該標
lan_env
printf '10.0.0.1\n' > "$MOCK_STATE/gateway_ip"
out="$("$PM" scan --json 2>/dev/null)"
assert "別的網段的閘道不算" "0" \
  "$(q '[.hosts[] | select(.is_gateway)] | length' "$out")"

echo "=== S18. 認不出的那幾台要把話講完（M2c 的文案）==="
# 「掃不到我的手機」這個提問就算多了 USB 來源也還是會出現：手機不在同一個
# Wi-Fi、或 USB 插在別人電腦上時，它本來就該是匿名的。使用者手上握著
# 「我明明都開好了」這個反證，不把話講完他會往錯的方向查很久。
lan_env
out="$("$PM" scan 2>/dev/null)"
check "說得出有幾台認不出"     "認不出是什麼" "$out"
check "點名可能是還沒 setup 的 Android" "還沒 hangar setup 的 Android" "$out"
check "講明偵錯開了也一樣"     "偵錯開得再正確" "$out"

# 5555 開著的不算匿名 —— 那台認得出是 Android，而且進得去
lan_env
printf '192.168.1.5\n192.168.1.77\n192.168.1.90\n' > "$MOCK_STATE/nc_open_ips"
out="$("$PM" scan 2>/dev/null)"
nocheck "全都進得去時不要亂提醒" "認不出是什麼" "$out"

echo "=== S17. mDNS：agent 自己報名，找不到就退回逐台探 5599 ==="
# mDNS 是加速器不是必要條件。這一節要鎖住兩件事：報得到名時省下探埠而且直接拿到
# 序號；完全沒有 mDNS 時行為跟以前一模一樣（只是慢）。
mdns_env() {
  lan_env
  # 192.168.1.77 上有一支 agent。nc 的 mock 是分埠的（只寫 IP 只代表 5555 通），
  # 所以 agent 的 5599 要另外標一筆，不然退回探埠那條路會探不到。
  printf '192.168.1.77\n192.168.1.77:5599\n' > "$MOCK_STATE/nc_open_ips"
  echo '{"schema":1}' > "$MOCK_STATE/agent_192.168.1.77_5599.json"
}

# --- avahi-browse 那條路（Linux）---
mdns_env
cat > "$MOCK_STATE/mdns_avahi" <<'AV'
+;en0;IPv4;hangar-2345AB;_hangar-agent._tcp;local
=;en0;IPv4;hangar-2345AB;_hangar-agent._tcp;local;phone.local;192.168.1.77;5599;"v=1" "serial=R58M12345AB" "model=Pixel+7+Pro"
AV
out="$("$PM" scan --json --no-ping 2>/dev/null)"
assert "schema 往上加了"        "8" "$(q '.schema' "$out")"
assert "mDNS 那台認得出有 agent" "0.1.0-mock" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.version' "$out")"
assert "mDNS 回報已入伍"       "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.enrolled' "$out")"
assert "說得出是怎麼發現的"      "mdns" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.discovered_by' "$out")"
# TXT 直接給序號 —— 這台電腦上沒有這支手機的 profile，照樣拿得到主鍵
assert "沒有 profile 也拿得到序號" "R58M12345AB" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .device_serial' "$out")"
assert "機型的 + 要還原成空白"   "Pixel 7 Pro" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.model' "$out")"
# mDNS 已經說它有 agent 了，就不該再對它探一次埠（省下來的正是這個）
nocheck "不再對它白探 5599" "192.168.1.77 5599" "$(cat "$MOCK_STATE/nc_log" 2>/dev/null)"
check   "別台還是照探"       "192.168.1.90 5599" "$(cat "$MOCK_STATE/nc_log" 2>/dev/null)"

# --- dns-sd 那條路（macOS）---
# 做一份沒有 avahi-browse 的 PATH，逼它走另一條
mdns_env
NOAV="$MOCK_STATE/noavahi"; rm -rf "$NOAV"; mkdir -p "$NOAV"
for d in "$SP/mockbin" /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "avahi-browse" ] && continue
    [ -e "$NOAV/$b" ] || ln -s "$f" "$NOAV/$b" 2>/dev/null
  done
done
[ ! -e "$NOAV/avahi-browse" ] && [ -e "$NOAV/dns-sd" ] \
  && { echo "  PASS  測試前提：這份 PATH 只有 dns-sd"; PASS=$((PASS+1)); }
cat > "$MOCK_STATE/mdns_dnssd_z" <<'DZ'
_hangar-agent._tcp                              PTR     hangar-2345AB._hangar-agent._tcp
hangar-2345AB._hangar-agent._tcp                SRV     0 0 5599 phone.local. ; Replace with unicast FQDN
hangar-2345AB._hangar-agent._tcp                TXT     "v=1" "serial=R58M12345AB" "model=Pixel+7+Pro"
DZ
printf 'phone.local 192.168.1.77\n' > "$MOCK_STATE/mdns_hosts"
out="$(PATH="$NOAV" "$PM" scan --json --no-ping 2>/dev/null)"
assert "dns-sd 也找得到"     "mdns" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.discovered_by' "$out")"
assert "序號一樣拿得到"      "R58M12345AB" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .device_serial' "$out")"
assert "機型一樣拿得到"      "Pixel 7 Pro" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.model' "$out")"
# 真的 dns-sd 不會自己結束，是被 run_timeout 砍掉的 —— 離開碼一定非 0。
# 拿它當「失敗」的話這條路永遠無效，所以這裡要確認它真的被呼叫且結果有用上。
check "真的有去問 dns-sd" "_hangar-agent._tcp" "$(cat "$MOCK_STATE/dnssd_log" 2>/dev/null)"

# --- 完全沒有 mDNS 工具：退回逐台探，功能還在只是慢 ---
mdns_env
NOMD="$MOCK_STATE/nomdns"; rm -rf "$NOMD"; mkdir -p "$NOMD"
for d in "$SP/mockbin" /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    { [ "$b" = "avahi-browse" ] || [ "$b" = "dns-sd" ]; } && continue
    [ -e "$NOMD/$b" ] || ln -s "$f" "$NOMD/$b" 2>/dev/null
  done
done
[ ! -e "$NOMD/avahi-browse" ] && [ ! -e "$NOMD/dns-sd" ] \
  && { echo "  PASS  測試前提：這份 PATH 兩個 mDNS 工具都沒有"; PASS=$((PASS+1)); }
out="$(PATH="$NOMD" "$PM" scan --json --no-ping 2>/dev/null)"
assert "沒有 mDNS 也找得到 agent" "0.1.0-mock" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.version' "$out")"
assert "逐台探測也帶入伍狀態" "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.enrolled' "$out")"
assert "這時說得出是探出來的"     "probe" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.discovered_by' "$out")"
assert "探出來的沒有機型"         "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.model' "$out")"
assert "也沒有序號（探埠問不到）" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .device_serial' "$out")"

# --- agent 有回應但尚未入伍：掃描要明確帶出 false，裝置牆才能顯示註冊按鈕 ---
mdns_env
touch "$MOCK_STATE/agent_not_enrolled"
cat > "$MOCK_STATE/mdns_avahi" <<'AV'
=;en0;IPv4;hangar-agent;_hangar-agent._tcp;local;phone.local;192.168.1.77;5599;"v=1" "model=Pixel+7+Pro"
AV
out="$("$PM" scan --json --no-ping 2>/dev/null)"
assert "未入伍狀態明確是 false" "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.enrolled' "$out")"

# 舊版 agent 沒有 enrolled 欄位時要保留 unknown，不要誤當成 false。
mdns_env
touch "$MOCK_STATE/agent_omit_enrolled"
cat > "$MOCK_STATE/mdns_avahi" <<'AV'
=;en0;IPv4;hangar-agent;_hangar-agent._tcp;local;phone.local;192.168.1.77;5599;"v=1"
AV
out="$("$PM" scan --json --no-ping 2>/dev/null)"
assert "舊版 agent 的入伍狀態是 null" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.enrolled' "$out")"

# --- 還沒入伍的 agent：TXT 裡沒有序號，但仍然要看得到它 ---
mdns_env
cat > "$MOCK_STATE/mdns_avahi" <<'AV'
=;en0;IPv4;hangar-agent;_hangar-agent._tcp;local;phone.local;192.168.1.77;5599;"v=1" "model=Pixel+7+Pro"
AV
out="$("$PM" scan --json --no-ping 2>/dev/null)"
assert "沒序號也還是看得到 agent" "mdns" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.discovered_by' "$out")"
assert "序號是 null 不是空字串"   "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .device_serial' "$out")"
assert "機型照樣拿得到"           "Pixel 7 Pro" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.model' "$out")"

# --- 沒解析完成的紀錄（+ 開頭）沒有位址，不可以當成 mDNS 找到了 ---
# avahi-browse 的 + 行只代表「看到有這個服務」，還沒解析出 IP。把它當成找到的話
# 會拿不到位址卻以為拿到了。正確的行為是退回探埠 —— 功能還在，只是慢。
mdns_env
cat > "$MOCK_STATE/mdns_avahi" <<'AV'
+;en0;IPv4;hangar-2345AB;_hangar-agent._tcp;local
AV
out="$("$PM" scan --json --no-ping 2>/dev/null)"
assert "+ 那行不算 mDNS 找到" "probe" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.discovered_by' "$out")"
assert "所以也沒有 mDNS 才有的機型" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent.model' "$out")"

# --- profile 有序號時以 profile 為準（那是 adb 拿到的，最可信）---
mdns_env
printf 'PHONE_HOST=""\nPHONE_IP="192.168.1.77"\nTRANSPORT="lan"\nDEVICE_SERIAL="FROMADB123"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
cat > "$MOCK_STATE/mdns_avahi" <<'AV'
=;en0;IPv4;hangar-2345AB;_hangar-agent._tcp;local;phone.local;192.168.1.77;5599;"v=1" "serial=R58M12345AB" "model=Pixel+7+Pro"
AV
out="$("$PM" scan --json --no-ping 2>/dev/null)"
assert "profile 的序號優先" "FROMADB123" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .device_serial' "$out")"

# --- --no-probe 時完全不碰 mDNS（那個旗標的意思就是「不要去問任何東西」）---
mdns_env
cat > "$MOCK_STATE/mdns_avahi" <<'AV'
=;en0;IPv4;hangar-2345AB;_hangar-agent._tcp;local;phone.local;192.168.1.77;5599;"v=1" "serial=R58M12345AB"
AV
out="$("$PM" scan --json --no-ping --no-probe 2>/dev/null)"
assert "--no-probe 不問 mDNS" "0" "$(lines "$MOCK_STATE/avahi_log")"
assert "--no-probe 的 agent 是 null" "null" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .agent' "$out")"

echo "=== S20. 跨網段：不在這台電腦網段上的 /24 改成逐台探埠 ==="
# 這台電腦在 192.168.1.x（mock 的 ifconfig）；10.20.30.x 在路由器後面。
# ARP 表裡**故意**放一筆 10.20.30.5：那種網段在真實世界不會出現在 ARP 表，
# 就算出現了也不該拿來用 —— 跨網段只信探埠的結果。
lan_env
printf '? (10.20.30.5) at 0:11:22:33:44:55 on en0 ifscope [ethernet]\n' >> "$MOCK_STATE/arp_table"
printf '10.20.30.7\n10.20.30.9:5599\n192.168.1.77\n' > "$MOCK_STATE/nc_open_ips"
printf '{}' > "$MOCK_STATE/agent_10.20.30.9_5599.json"
rm -f "$MOCK_STATE/ping_log"
out="$("$PM" scan --json --subnet 10.20.30 2>/dev/null)"
assert "只列得出有回應的兩台" "10.20.30.7 10.20.30.9" "$(q '[.hosts[].ip] | join(" ")' "$out")"
assert "ARP 表裡那筆不算"    "" "$(q '.hosts[] | select(.ip=="10.20.30.5") | .ip' "$out")"
assert "標成 routed"         "true" "$(q '[.hosts[].routed] | unique | .[0]' "$out")"
assert "沒有 MAC"            "null" "$(q '.hosts[] | select(.ip=="10.20.30.7") | .mac' "$out")"
assert "5555 開的看得出來"   "open" "$(q '.hosts[] | select(.ip=="10.20.30.7") | .adb_port' "$out")"
assert "只開 5599 的是 agent" "0.1.0-mock" "$(q '.hosts[] | select(.ip=="10.20.30.9") | .agent.version' "$out")"
assert "不做 ping sweep"     "0" "$(lines "$MOCK_STATE/ping_log")"
assert "subnets 標出 routed" "10.20.30.0/24 true" \
  "$(q '.subnets[] | "\(.cidr) \(.routed)"' "$out")"
assert "errors 是空的"       "0" "$(q '.errors | length' "$out")"

echo "=== S21. 本機網段與跨網段一起掃 ==="
lan_env
printf '10.20.30.7\n192.168.1.77\n' > "$MOCK_STATE/nc_open_ips"
out="$("$PM" scan --json --subnet 192.168.1 --subnet 10.20.30 2>/dev/null)"
assert "subnet 還是第一個"   "192.168.1.0/24" "$(q '.subnet' "$out")"
assert "兩個網段都列出來"    "192.168.1.0/24:false 10.20.30.0/24:true" \
  "$(q '[.subnets[] | "\(.cidr):\(.routed)"] | join(" ")' "$out")"
assert "本機網段照舊靠 ARP（三台）加跨網段一台" "4" "$(q '.hosts | length' "$out")"
assert "本機網段的不標 routed" "false" \
  "$(q '.hosts[] | select(.ip=="192.168.1.77") | .routed' "$out")"
assert "本機網段的閘道器照樣標" "true" \
  "$(q '.hosts[] | select(.ip=="192.168.1.1") | .is_gateway' "$out")"
out="$("$PM" scan --json --subnet 10.20.30,10.20.30.0/24 2>/dev/null)"
assert "重複的網段只掃一次"  "1" "$(q '.subnets | length' "$out")"

echo "=== S22. 跨網段靠 IP 對 profile，但不修 IP、也不學 MAC ==="
lan_env
printf '10.20.30.7\n' > "$MOCK_STATE/nc_open_ips"
# profile 記過一組燒死的 MAC：本機網段上那會擋掉 IP 比對（IP 換人了），
# 跨網段沒有 MAC 可比，只能信 IP
printf 'PHONE_HOST=""\nPHONE_IP="10.20.30.7"\nTRANSPORT="lan"\nPHONE_MAC="00:11:22:33:44:77"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/far.conf"
out="$("$PM" scan --json --subnet 10.20.30 --fix-ip 2>/dev/null)"
assert "靠 IP 對上"   "far|ip" "$(q '.hosts[] | select(.ip=="10.20.30.7") | "\(.profile)|\(.matched_by)"' "$out")"
check  "MAC 沒被洗掉" '00:11:22:33:44:77' "$(cat "$XDG_CONFIG_HOME/hangar/profiles/far.conf")"

echo "=== S23. 跨網段的限制要講出來 ==="
lan_env
out="$("$PM" scan --json --subnet 10.20.30 --no-probe 2>/dev/null)"
assert "--no-probe 時跨網段不掃" "routed_needs_probe" "$(q '.errors[0].code' "$out")"
assert "所以一台都沒有"          "0" "$(q '.hosts | length' "$out")"
lan_env
: > "$MOCK_STATE/nc_open_ips"
out="$("$PM" scan --subnet 10.20.30 2>&1)"
check "人看的輸出講得出為什麼看不到" "5555 或 5599 有回應" "$out"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

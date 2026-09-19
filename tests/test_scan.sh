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
assert "有 schema 版本"      "4"                "$(q '.schema' "$out")"
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
assert "改檔案不影響 JSON 純淨度"   "4" "$(q '.schema' "$out")"
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

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

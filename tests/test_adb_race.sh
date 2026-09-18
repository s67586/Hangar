#!/usr/bin/env bash
# adb server 重啟競態 + 中文欄位對齊
SP="$(cd "$(dirname "$0")" && pwd)"
PM="$1"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/state"
export PATH="$SP/mockbin:$PATH"
export XDG_CONFIG_HOME="${TMPDIR:-/tmp}/hangar-test/cfg"
export NO_COLOR=1
IP=100.101.102.103
PASS=0; FAIL=0

prep() {
  rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"
  mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
  echo Running>"$MOCK_STATE/ts_backend"; echo true>"$MOCK_STATE/ts_online"; echo true>"$MOCK_STATE/ts_online2"
  echo direct>"$MOCK_STATE/ts_ping_mode"; echo ok>"$MOCK_STATE/adb_connect_result"
  printf 'PHONE_HOST="pixel"\nPHONE_IP="%s"\n' "$IP" > "$XDG_CONFIG_HOME/hangar/profiles/pixel.conf"
  : > "$MOCK_STATE/adb_devices"
}
check()   { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
nocheck() { if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該包含 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }
assert()  { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

echo "=== R1. connect 撞到 adb server 空窗 → 自動 start-server 後重試成功 ==="
prep; echo 1 > "$MOCK_STATE/daemon_down"      # 第一次 connect 會噴 daemon 錯
out="$("$PM" 2>&1)"
check "最後有成功啟動 scrcpy" "max-size" "$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
log="$(cat "$MOCK_STATE/connect_log")"
check "有呼叫 start-server"   "start-server" "$log"
assert "connect 重試了一次"   "2" "$(grep -c '^connect ' <<<"$log")"
nocheck "沒有誤報成手機重開機" "重開機" "$out"

echo "=== R2. adb server 一直起不來 → 說是本機問題，不要怪手機/Tailscale ==="
prep; echo 99 > "$MOCK_STATE/daemon_down"; touch "$MOCK_STATE/daemon_permanent"
out="$("$PM" 2>&1)"; rc=$?
check "指出是本機 adb server"  "本機 adb server" "$out"
check "給出 kill-server 解法"  "adb kill-server" "$out"
nocheck "不要說手機重開機"     "重開機" "$out"
nocheck "不要說 Tailscale ACL" "ACL"    "$out"
[ "$rc" -ne 0 ] && { echo "  PASS  離開碼非 0"; PASS=$((PASS+1)); } || { echo "  FAIL  離開碼應非 0"; FAIL=$((FAIL+1)); }

echo "=== R3. 真的 connection refused → 仍然正確判定為手機重開機 ==="
prep; echo fail > "$MOCK_STATE/adb_connect_result"
out="$("$PM" 2>&1)"
check "說手機重開機"          "重開機" "$out"
check "叫你重跑 setup"        "hangar setup" "$out"
nocheck "不要誤判成本機問題"  "本機 adb server" "$out"

echo "=== R3b. connect 完全無回應（逾時，無輸出）→ 仍然判定為重開機並說明逾時 ==="
prep; echo silent > "$MOCK_STATE/adb_connect_result"
out="$("$PM" 2>&1)"
check "說明是逾時沒回應"      "逾時" "$out"
check "仍然判定為重開機"      "重開機" "$out"
check "給出 setup 指令"       "hangar setup" "$out"

echo "=== R4. setup 在 tcpip 之後會先確保 adb server 活著 ==="
prep; printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"
"$PM" setup pixel >/dev/null 2>&1
log="$(cat "$MOCK_STATE/connect_log")"
check "tcpip 有跑"                "tcpip 5555" "$log"
check "tcpip 之後有 start-server" "$(printf 'tcpip 5555\nstart-server')" "$log"

echo "=== R5. setup 期間 server 掛掉也能自己救回來 ==="
prep; printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"; echo 1 > "$MOCK_STATE/daemon_down"
out="$("$PM" setup pixel 2>&1)"; rc=$?
check "setup 仍然完成"        "setup 完成" "$out"
assert "離開碼 0"             "0" "$rc"

echo "=== R5b. 重開機復原：setup --name <既有 profile> 不該再問一次節點 ==="
prep; printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"
# profile 已存在（HostName=pixel），非互動執行：會問就會卡住/取消
out="$("$PM" setup --name pixel < /dev/null 2>&1)"; rc=$?
check "沿用既有節點"        "沿用 profile" "$out"
check "setup 完成"          "setup 完成"   "$out"
nocheck "沒有跳出節點選單"   "選擇這支手機" "$out"
nocheck "沒有被取消"         "已取消"       "$out"
assert "離開碼 0"           "0" "$rc"

echo "=== R5c. profile 不存在時仍然要列出節點讓人選 ==="
prep; rm -f "$XDG_CONFIG_HOME/hangar/profiles/pixel.conf"
printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"
out="$(printf '1\n' | "$PM" setup --name brandnew 2>&1)"
check "有列出節點清單"      "tailnet 內的節點" "$out"
check "setup 完成"          "setup 完成" "$out"

echo "=== R5d. 節點清單含中文名稱時欄位對齊 ==="
prep; rm -f "$XDG_CONFIG_HOME/hangar/profiles/pixel.conf"
printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"
echo 1 > "$MOCK_STATE/cjk_peer"
out="$(printf '1\n' | "$PM" setup --name cjktest 2>&1)"
cols="$(printf '%s\n' "$out" | python3 -c '
import sys, unicodedata, re
w = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
starts = []
for line in sys.stdin:
    raw = re.sub(r"\x1b\[[0-9;]*m", "", line.rstrip("\n"))
    m = re.match(r"^\s*\d+\) ", raw)
    if not m: continue
    ip = re.search(r"\b100\.[0-9.]+", raw)
    if ip: starts.append(w(raw[:ip.start()]))
print("same" if starts and len(set(starts)) == 1 else f"differ:{starts}")')"
assert "IP 欄都從同一欄開始" "same" "$cols"

echo "=== R6. status 的中文標籤欄位有對齊 ==="
prep; printf '%s\tdevice\n' "$IP:5555" > "$MOCK_STATE/adb_devices"
out="$("$PM" status 2>&1)"
cols="$(printf '%s\n' "$out" | python3 -c '
import sys, unicodedata, re
w = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
seen = set()
for line in sys.stdin:
    line = re.sub(r"\x1b\[[0-9;]*m", "", line.rstrip("\n"))
    m = re.match(r"^  (\S.*?)  +(\S.*)$", line)
    if m and m.group(1) not in ("hangar",):
        seen.add(w(line[:m.start(2)]))
print(",".join(str(x) for x in sorted(seen)))')"
assert "所有欄位值都從同一欄開始" "18" "$cols"

echo "=== R7. list 表格在有顏色時仍然對齊 ==="
prep; printf '%s\tdevice\n' "$IP:5555" > "$MOCK_STATE/adb_devices"
printf 'PHONE_HOST="zenfone"\nPHONE_IP="100.101.102.110"\n' > "$XDG_CONFIG_HOME/hangar/profiles/zen.conf"
out="$(NO_COLOR= "$PM" list 2>&1)"
cols="$(printf '%s\n' "$out" | python3 -c '
import sys, unicodedata, re
w = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
starts = []
for line in sys.stdin:
    raw = re.sub(r"\x1b\[[0-9;]*m", "", line.rstrip("\n"))
    if not re.match(r"^  [ *]  ?\S", raw) or "─" in raw:
        continue
    # 每一列的第 3 欄（tailnet）起始位置
    m = re.search(r"(online|offline|不在 tailnet)", raw)
    if m:
        starts.append(w(raw[:m.start()]))
print("same" if len(set(starts)) == 1 and starts else f"differ:{starts}")')"
assert "資料列欄位對齊" "same" "$cols"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

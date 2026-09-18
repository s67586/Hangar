#!/usr/bin/env bash
# 第二台電腦：hangar setup --existing
SP="$(cd "$(dirname "$0")" && pwd)"
PM="$1"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/state"
export PATH="$SP/mockbin:$PATH"
export XDG_CONFIG_HOME="${TMPDIR:-/tmp}/hangar-test/cfg"
export NO_COLOR=1
IP=100.101.102.103
PASS=0; FAIL=0

prep() { # 模擬全新的電腦：沒有任何 profile、沒有 USB 裝置
  rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"
  mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
  echo Running>"$MOCK_STATE/ts_backend"; echo true>"$MOCK_STATE/ts_online"; echo true>"$MOCK_STATE/ts_online2"
  echo direct>"$MOCK_STATE/ts_ping_mode"; echo ok>"$MOCK_STATE/adb_connect_result"
  : > "$MOCK_STATE/adb_devices"
}
check()   { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
nocheck() { if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該包含 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }
assert()  { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

echo "=== H1. 全新電腦、沒插 USB：--existing 直接建立設定 ==="
prep
out="$("$PM" setup --existing pixel < /dev/null 2>&1)"; rc=$?
assert "離開碼 0"              "0" "$rc"
check "說明有略過 tcpip"       "略過 USB" "$out"
check "setup 完成"             "setup 完成" "$out"
check "profile 寫出來了"       "$IP" "$(cat "$XDG_CONFIG_HOME/hangar/profiles/pixel.conf" 2>/dev/null)"
log="$(cat "$MOCK_STATE/connect_log")"
nocheck "完全沒跑 adb tcpip"   "tcpip" "$log"
nocheck "沒有要求無線配對"     "配對碼" "$out"
check "有實際驗證連線"         "connect $IP:5555" "$log"

echo "=== H2. 設定好之後就能直接投影 ==="
"$PM" >/dev/null 2>&1
check "投影用對的 serial"      "$IP:5555" "$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"

echo "=== H3. 對照組：沒有 --existing 又沒 USB → 走無線配對流程 ==="
prep
out="$("$PM" setup pixel < /dev/null 2>&1)"
check "要求無線偵錯配對"       "無線偵錯" "$out"
nocheck "不該直接完成"         "setup 完成" "$out"

echo "=== H4. 新電腦第一次連一定是 unauthorized → 要講清楚是正常的 ==="
prep; echo unauthorized > "$MOCK_STATE/adb_connect_result"
out="$("$PM" setup --existing pixel < /dev/null 2>&1)"; rc=$?
check "指出是 unauthorized"    "unauthorized" "$out"
check "說明換電腦都會這樣"     "換電腦第一次連" "$out"
check "告訴你按一律允許"       "一律允許" "$out"
[ "$rc" -ne 0 ] && { echo "  PASS  離開碼非 0"; PASS=$((PASS+1)); } || { echo "  FAIL  離開碼應非 0"; FAIL=$((FAIL+1)); }

echo "=== H5. --existing 連不上 → 提示要查 ACL／別台是否設定過，不是叫你配對 ==="
prep; echo fail > "$MOCK_STATE/adb_connect_result"
out="$("$PM" setup --existing pixel < /dev/null 2>&1)"
check "提到 ACL 要加新電腦"    "ACL" "$out"
check "提到別台電腦要先 setup" "另一台電腦" "$out"
check "提到手機重開過的情況"   "重開" "$out"
nocheck "不要叫人去無線配對"   "配對碼" "$out"

echo "=== H6. --existing 也吃 --name 別名 ==="
prep
"$PM" setup --existing pixel --name mac2 < /dev/null >/dev/null 2>&1
[ -f "$XDG_CONFIG_HOME/hangar/profiles/mac2.conf" ] && { echo "  PASS  profile 用別名存檔"; PASS=$((PASS+1)); } || { echo "  FAIL  別名沒生效"; FAIL=$((FAIL+1)); }
check "別名 profile 指到對的 IP" "$IP" "$(cat "$XDG_CONFIG_HOME/hangar/profiles/mac2.conf" 2>/dev/null)"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

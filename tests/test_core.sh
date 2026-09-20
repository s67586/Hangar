#!/usr/bin/env bash
SP="$(cd "$(dirname "$0")" && pwd)"
PM="$1"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/state"
export PATH="$SP/mockbin:$PATH"
export XDG_CONFIG_HOME="${TMPDIR:-/tmp}/hangar-test/cfg"
export NO_COLOR=1

PASS=0; FAIL=0
reset_state() {
  rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE"
  echo Running > "$MOCK_STATE/ts_backend"
  echo true    > "$MOCK_STATE/ts_online"
  echo direct  > "$MOCK_STATE/ts_ping_mode"
  echo ok      > "$MOCK_STATE/adb_connect_result"
  printf '100.101.102.103:5555\tdevice\n' > "$MOCK_STATE/adb_devices"
  rm -rf "$XDG_CONFIG_HOME/hangar"
  mkdir -p "$XDG_CONFIG_HOME/hangar"
  cat > "$XDG_CONFIG_HOME/hangar/config" <<CFG
PHONE_HOST="pixel"
PHONE_IP="100.101.102.103"
CFG
}
check() { # <name> <expect-substr> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then
    printf '  PASS  %s\n' "$1"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s\n        期望包含: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' '|')"; FAIL=$((FAIL+1))
  fi
}
nocheck() { # <name> <must-NOT-contain> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then
    printf '  FAIL  %s\n        不應包含: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else
    printf '  PASS  %s\n' "$1"; PASS=$((PASS+1))
  fi
}

# 等到 pgrep 數到的行程數符合預期為止，最多等 <secs> 秒（預設 15），回傳最後數到的值。
#
# 這裡不可以用固定 sleep：背景那支 mock scrcpy 多久才會出現在行程表上，看的是
# 當下機器多忙 —— 開發機上 3 秒綽綽有餘，CI runner 上就不一定，這正是這幾項在
# CI 偶爾紅、在本機重跑又綠的原因。固定 sleep 只能二選一：短了偶爾誤報，長了
# 每一輪都在空等。輪詢兩邊都不必挑。
wait_count() { # <pgrep-pattern> <test-op> <want> [secs]
  local i=0 n
  while :; do
    n="$(pgrep -f "$1" | grep -c .)"
    [ "$n" "$2" "$3" ] && break
    [ "$i" -ge "$(( ${4:-15} * 5 ))" ] && break
    i=$((i+1)); sleep 0.2
  done
  printf '%s' "$n"
}

echo "=== 1. direct → 高畫質參數 ==="
reset_state; echo direct > "$MOCK_STATE/ts_ping_mode"
out="$("$PM" 2>&1)"
check "偵測到 direct"        "direct（12ms）" "$out"
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
check "max-size=1280"        "max-size=1280"  "$argv"
check "video-bit-rate=8M"    "video-bit-rate=8M" "$argv"
check "max-fps=60"           "max-fps=60"     "$argv"
check "stay-awake"           "stay-awake"     "$argv"
check "no-audio"             "no-audio"       "$argv"
nocheck "direct 不用 h265"   "h265"           "$argv"

echo "=== 2. DERP relay → 警告 + 降參數 ==="
reset_state; echo derp > "$MOCK_STATE/ts_ping_mode"
out="$("$PM" 2>&1)"
check "警告 DERP relay"      "DERP relay"     "$out"
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
check "max-size=1024"        "max-size=1024"  "$argv"
check "video-bit-rate=3M"    "video-bit-rate=3M" "$argv"
check "max-fps=30"           "max-fps=30"     "$argv"
check "relay 用 h265"        "video-codec=h265" "$argv"

echo "=== 3. --hq / --lq 手動覆寫 ==="
reset_state; echo derp > "$MOCK_STATE/ts_ping_mode"
out="$("$PM" --hq 2>&1)"
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
check "--hq 覆寫 relay 判斷"  "max-size=1280" "$argv"
check "有印出覆寫訊息"        "手動覆寫畫質"   "$out"
reset_state; echo direct > "$MOCK_STATE/ts_ping_mode"
"$PM" --lq >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
check "--lq 覆寫 direct 判斷" "max-size=1024" "$argv"

echo "=== 4. 手機重開機（5555 不通）→ 明確提示 setup ==="
reset_state; echo fail > "$MOCK_STATE/adb_connect_result"; : > "$MOCK_STATE/adb_devices"
out="$("$PM" 2>&1)"; rc=$?
check "提示重跑 setup"        "hangar setup"  "$out"
check "說明是重開機"          "重開機"          "$out"
[ "$rc" -ne 0 ] && { echo "  PASS  離開碼非 0 ($rc)"; PASS=$((PASS+1)); } || { echo "  FAIL  離開碼應非 0"; FAIL=$((FAIL+1)); }
nocheck "沒有啟動 scrcpy"     "max-size"       "$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"

echo "=== 5. unauthorized → 提示一律允許 ==="
reset_state; printf '100.101.102.103:5555\tunauthorized\n' > "$MOCK_STATE/adb_devices"
out="$("$PM" 2>&1)"
check "提示一律允許"          "一律允許"        "$out"

echo "=== 6. offline → 自動 disconnect + connect 重試 ==="
reset_state; printf '100.101.102.103:5555\toffline\n' > "$MOCK_STATE/adb_devices"
out="$("$PM" 2>&1)"
check "有提到自動重連"        "自動重連"        "$out"
log="$(cat "$MOCK_STATE/connect_log" 2>/dev/null)"
check "確實呼叫 disconnect"   "disconnect 100.101.102.103:5555" "$log"
check "確實重新 connect"      "connect 100.101.102.103:5555"    "$log"
check "重試後成功啟動 scrcpy" "max-size" "$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"

echo "=== 7. Tailscale 未連線 ==="
reset_state; echo Stopped > "$MOCK_STATE/ts_backend"
out="$("$PM" 2>&1)"
check "提示 tailscale up"     "tailscale up"   "$out"

echo "=== 8. 手機不在 tailnet ==="
reset_state; echo false > "$MOCK_STATE/ts_online"
out="$("$PM" 2>&1)"
check "提示手機端 Tailscale"  "手機上打開 Tailscale" "$out"

echo "=== 9. status 區分 direct / relay ==="
reset_state; echo direct > "$MOCK_STATE/ts_ping_mode"
out="$("$PM" status 2>&1)"
check "status: direct"        "direct"         "$out"
check "status: 機型"          "Pixel 7 Pro"    "$out"
check "status: Android 版本"  "14"             "$out"
reset_state; echo derp > "$MOCK_STATE/ts_ping_mode"
out="$("$PM" status 2>&1)"
check "status: DERP relay"    "DERP relay"     "$out"
nocheck "relay 時不說 direct" "direct"         "$out"

echo "=== 10. reset ==="
reset_state
out="$("$PM" reset 2>&1)"
check "reset 成功訊息"        "連線已重建"      "$out"
log="$(cat "$MOCK_STATE/connect_log" 2>/dev/null)"
check "reset 先 disconnect"   "disconnect"     "$log"

echo "=== 11. 沒有設定檔 → 提示 setup ==="
reset_state; rm -rf "$XDG_CONFIG_HOME/hangar"
out="$("$PM" 2>&1)"
check "提示先跑 setup"        "hangar setup"  "$out"

echo "=== 12. 重複執行：不殘留 scrcpy、不重複 adb 連線 ==="
reset_state
MOCK_SCRCPY_SLEEP=30 "$PM" >/dev/null 2>&1 &
first=$!
running="$(wait_count 'scrcpy .*100.101.102.103:5555' -ge 1)"
[ "$running" -ge 1 ] && { echo "  PASS  第一個 scrcpy 已在執行 ($running)"; PASS=$((PASS+1)); } || { echo "  FAIL  第一個 scrcpy 沒起來"; FAIL=$((FAIL+1)); }
out="$(MOCK_SCRCPY_SLEEP=2 "$PM" 2>&1)"
check "偵測並清掉殘留 scrcpy" "殘留的 scrcpy"  "$out"
sleep 1
running="$(pgrep -f 'scrcpy .*100.101.102.103:5555' | wc -l | tr -d ' ')"
[ "$running" -le 1 ] && { echo "  PASS  沒有累積多個 scrcpy (現在 $running)"; PASS=$((PASS+1)); } || { echo "  FAIL  累積了 $running 個 scrcpy"; FAIL=$((FAIL+1)); }
wait $first 2>/dev/null
pkill -f 'scrcpy .*100.101.102.103:5555' 2>/dev/null
n_connect="$(grep -c '^connect ' "$MOCK_STATE/connect_log" 2>/dev/null || echo 0)"
[ "$n_connect" -eq 0 ] && { echo "  PASS  裝置已連線時不重複 adb connect"; PASS=$((PASS+1)); } || { echo "  FAIL  多餘的 adb connect 次數: $n_connect"; FAIL=$((FAIL+1)); }

echo "=== S. 預設關掉手機螢幕（--turn-screen-off） ==="
reset_state
"$PM" >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
check "預設帶 --turn-screen-off"  "turn-screen-off" "$argv"
check "同時仍有 --stay-awake"     "stay-awake"      "$argv"

reset_state
"$PM" --screen-on >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
nocheck "--screen-on 不關螢幕"    "turn-screen-off" "$argv"
check "--screen-on 仍然有投影"    "\\-s 100.101.102.103:5555" "$argv"

reset_state
"$PM" --lq >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
check "低頻寬模式也會關螢幕"      "turn-screen-off" "$argv"

reset_state
"$PM" -- --turn-screen-off >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
n="$(printf '%s' "$argv" | grep -o 'turn-screen-off' | wc -l | tr -d ' ')"
[ "$n" -eq 1 ] && { echo "  PASS  使用者自己傳時不重複（出現 $n 次）"; PASS=$((PASS+1)); } || { echo "  FAIL  --turn-screen-off 重複了 $n 次"; FAIL=$((FAIL+1)); }

reset_state
"$PM" -- -S >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"
n="$(printf '%s' "$argv" | grep -o 'turn-screen-off' | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && { echo "  PASS  使用者用 -S 短旗標時不另外加長旗標"; PASS=$((PASS+1)); } || { echo "  FAIL  -S 之外又加了 $n 個 --turn-screen-off"; FAIL=$((FAIL+1)); }

echo "=== M. 專案改名：舊的 ~/.config/pmirror 自動搬到 ~/.config/hangar ==="
reset_state
rm -rf "$XDG_CONFIG_HOME/hangar" "$XDG_CONFIG_HOME/pmirror"
mkdir -p "$XDG_CONFIG_HOME/pmirror/profiles"
cat > "$XDG_CONFIG_HOME/pmirror/profiles/oldphone.conf" <<CFG
PHONE_HOST="pixel"
PHONE_IP="100.101.102.103"
CFG
echo oldphone > "$XDG_CONFIG_HOME/pmirror/default"
out="$("$PM" list 2>&1)"
check "有告知設定搬遷"        "搬到"       "$out"
check "舊 profile 還在"       "oldphone"   "$out"
[ ! -d "$XDG_CONFIG_HOME/pmirror" ] && { echo "  PASS  舊目錄已移除"; PASS=$((PASS+1)); } || { echo "  FAIL  舊目錄還在"; FAIL=$((FAIL+1)); }
[ -f "$XDG_CONFIG_HOME/hangar/profiles/oldphone.conf" ] && { echo "  PASS  profile 落在新目錄"; PASS=$((PASS+1)); } || { echo "  FAIL  新目錄沒有 profile"; FAIL=$((FAIL+1)); }

echo "=== M2. 新舊目錄都存在 → 不覆蓋新設定 ==="
reset_state
rm -rf "$XDG_CONFIG_HOME/pmirror"
mkdir -p "$XDG_CONFIG_HOME/pmirror/profiles"
cat > "$XDG_CONFIG_HOME/pmirror/profiles/oldphone.conf" <<CFG
PHONE_HOST="pixel"
PHONE_IP="100.101.102.103"
CFG
out="$("$PM" list 2>&1)"
nocheck "沒有搬遷訊息"        "搬到"       "$out"
nocheck "沒把舊 profile 帶進來" "oldphone" "$out"
[ -d "$XDG_CONFIG_HOME/pmirror" ] && { echo "  PASS  舊目錄原封不動"; PASS=$((PASS+1)); } || { echo "  FAIL  舊目錄被動到了"; FAIL=$((FAIL+1)); }
rm -rf "$XDG_CONFIG_HOME/pmirror"

echo
echo "================================"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

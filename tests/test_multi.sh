#!/usr/bin/env bash
SP="$(cd "$(dirname "$0")" && pwd)"
PM="$1"
export MOCK_STATE="${TMPDIR:-/tmp}/hangar-test/state" PATH="$SP/mockbin:$PATH" XDG_CONFIG_HOME="${TMPDIR:-/tmp}/hangar-test/cfg" NO_COLOR=1
P1=100.101.102.103; P2=100.101.102.110
PASS=0; FAIL=0

two_phones() {
  rm -rf "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar"; mkdir -p "$MOCK_STATE" "$XDG_CONFIG_HOME/hangar/profiles"
  echo Running>"$MOCK_STATE/ts_backend"; echo true>"$MOCK_STATE/ts_online"; echo true>"$MOCK_STATE/ts_online2"
  echo direct>"$MOCK_STATE/ts_ping_mode"; echo ok>"$MOCK_STATE/adb_connect_result"
  printf 'PHONE_HOST="pixel"\nPHONE_IP="%s"\n'   "$P1" > "$XDG_CONFIG_HOME/hangar/profiles/work.conf"
  printf 'PHONE_HOST="zenfone"\nPHONE_IP="%s"\n' "$P2" > "$XDG_CONFIG_HOME/hangar/profiles/test.conf"
  printf '%s\tdevice\n%s\tdevice\n' "$P1:5555" "$P2:5555" > "$MOCK_STATE/adb_devices"
}
check()   { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
nocheck() { if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該包含 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }
assert()  { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望 %s，實際 %s）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

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

echo "=== M1. list 列出兩支 + 標記預設 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
out="$("$PM" list 2>&1)"
check "列出 work"          "work"   "$out"
check "列出 test"          "test"   "$out"
check "顯示 work 的 IP"    "$P1"    "$out"
check "顯示 test 的 IP"    "$P2"    "$out"
check "顯示 tailnet online" "online" "$out"
check "顯示 adb device"    "device" "$out"
check "預設標記 *"         "\* *work" "$out"

echo "=== M2. -p 指定手機 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
"$PM" -p test >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv")"
check "用 test 的 serial"  "$P2:5555" "$argv"
nocheck "沒用到 work"      "$P1:5555" "$argv"
check "視窗標題=profile 名" "window-title=test" "$argv"

echo "=== M3. 前綴唯一比對 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
"$PM" -p te >/dev/null 2>&1
check "-p te → test"       "$P2:5555" "$(cat "$MOCK_STATE/scrcpy_argv")"

echo "=== M4. 打錯名字 → 列出可用的 ==="
two_phones
out="$("$PM" -p nosuch 2>&1)"
check "說找不到"           "找不到手機" "$out"
check "列出 work"          "work" "$out"
check "列出 test"          "test" "$out"
nocheck "沒有啟動 scrcpy"  "max-size" "$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"

echo "=== M5. 多支但沒設預設、又非互動 → 明確報錯不亂猜 ==="
two_phones
out="$("$PM" < /dev/null 2>&1)"
check "提示要指定"         "沒有設定預設值" "$out"
check "給出 use 的用法"    "hangar use"    "$out"
nocheck "沒有亂投一支"     "max-size"       "$(cat "$MOCK_STATE/scrcpy_argv" 2>/dev/null)"

echo "=== M6. use 切換預設 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
out="$("$PM" use test 2>&1)"
check "回報已切換"         "test" "$out"
assert "default 檔已更新"  "test" "$(cat "$XDG_CONFIG_HOME/hangar/default")"
"$PM" >/dev/null 2>&1
check "不加 -p 走新預設"   "$P2:5555" "$(cat "$MOCK_STATE/scrcpy_argv")"

echo "=== M7. 只有一支時不需要 -p ==="
two_phones; rm -f "$XDG_CONFIG_HOME/hangar/profiles/test.conf" "$XDG_CONFIG_HOME/hangar/default"
"$PM" >/dev/null 2>&1
check "自動用唯一那支"     "$P1:5555" "$(cat "$MOCK_STATE/scrcpy_argv")"

echo "=== M8. 一支離線不影響另一支 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
echo false > "$MOCK_STATE/ts_online"          # work 離線
out="$("$PM" -p test 2>&1)"
check "test 仍然投得出來"  "$P2:5555" "$(cat "$MOCK_STATE/scrcpy_argv")"
out="$("$PM" -p work 2>&1)"
check "work 明確報離線"    "不在 tailnet 上" "$out"

echo "=== M9. reset / 清殘留只作用在指定那支 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
MOCK_SCRCPY_SLEEP=25 "$PM" -p work >/dev/null 2>&1 &
MOCK_SCRCPY_SLEEP=25 "$PM" -p test >/dev/null 2>&1 &
assert "work 視窗數" "1" "$(wait_count "scrcpy .*$P1:5555" -eq 1)"
assert "test 視窗數" "1" "$(wait_count "scrcpy .*$P2:5555" -eq 1)"
"$PM" reset -p work >/dev/null 2>&1
assert "reset work 後 work 視窗被關" "0" "$(wait_count "scrcpy .*$P1:5555" -eq 0)"
assert "test 視窗不受影響"           "1" "$(pgrep -f "scrcpy .*$P2:5555" | grep -c .)"
log="$(cat "$MOCK_STATE/connect_log")"
nocheck "reset 沒有碰到 test"        "disconnect $P2:5555" "$log"
pkill -f 'scrcpy .*100.101.102.1' 2>/dev/null; sleep 1

echo "=== M10. all 同時開兩支 ==="
two_phones; : > "$MOCK_STATE/scrcpy_argv"
out="$(MOCK_SCRCPY_SLEEP=15 "$PM" all 2>&1)"
# 兩支都進到行程表之後，argv 一定也寫好了（mock scrcpy 是先寫 argv 才 sleep）。
n_scrcpy="$(wait_count 'scrcpy .*100.101.102.1' -eq 2)"
check "訊息含 work"        "work" "$out"
check "訊息含 test"        "test" "$out"
check "回報啟動 2 個"      "已啟動 2 個視窗" "$out"
argv="$(cat "$MOCK_STATE/scrcpy_argv")"
check "work 有起來"        "$P1:5555" "$argv"
check "test 有起來"        "$P2:5555" "$argv"
check "work 視窗標題"      "window-title=work" "$argv"
check "test 視窗標題"      "window-title=test" "$argv"
assert "兩支都關掉手機螢幕" "2" "$(printf '%s' "$argv" | grep -o 'turn-screen-off' | grep -c .)"
assert "實際跑著兩個 scrcpy" "2" "$n_scrcpy"
pkill -f 'scrcpy .*100.101.102.1' 2>/dev/null; sleep 1

echo "=== M10b. all --screen-on 兩支都不關螢幕 ==="
two_phones; : > "$MOCK_STATE/scrcpy_argv"
out="$(MOCK_SCRCPY_SLEEP=5 "$PM" all --screen-on 2>&1)"
sleep 2
argv="$(cat "$MOCK_STATE/scrcpy_argv")"
nocheck "沒有 turn-screen-off"  "turn-screen-off" "$argv"
check "兩支還是有起來"          "$P2:5555" "$argv"
pkill -f 'scrcpy .*100.101.102.1' 2>/dev/null
sleep 1

echo "=== M11. all 遇到壞掉的那支不會中斷其他支 ==="
two_phones; : > "$MOCK_STATE/scrcpy_argv"; echo false > "$MOCK_STATE/ts_online"
out="$(MOCK_SCRCPY_SLEEP=8 "$PM" all 2>&1)"; rc=$?
sleep 1
check "test 仍然起來"      "$P2:5555" "$(cat "$MOCK_STATE/scrcpy_argv")"
check "回報 1 成功"        "已啟動 1 個視窗" "$out"
check "有標示失敗"         "失敗 1 支" "$out"
[ "$rc" -ne 0 ] && { echo "  PASS  離開碼非 0"; PASS=$((PASS+1)); } || { echo "  FAIL  離開碼應非 0"; FAIL=$((FAIL+1)); }
pkill -f 'scrcpy .*100.101.102.1' 2>/dev/null; sleep 1

echo "=== M12. 使用者自帶 --window-title 時不覆蓋 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"; : > "$MOCK_STATE/scrcpy_argv"
"$PM" -p work -- --window-title=MyOwn >/dev/null 2>&1
argv="$(cat "$MOCK_STATE/scrcpy_argv")"
check "用使用者的標題"     "window-title=MyOwn" "$argv"
nocheck "沒有塞 profile 名" "window-title=work" "$argv"

echo "=== M13. forget ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
out="$(printf 'n\n' | "$PM" forget test 2>&1)"
check "回答 n 會取消"      "取消" "$out"
[ -f "$XDG_CONFIG_HOME/hangar/profiles/test.conf" ] && { echo "  PASS  取消後檔案還在"; PASS=$((PASS+1)); } || { echo "  FAIL  取消後檔案不見了"; FAIL=$((FAIL+1)); }
out="$(printf 'y\n' | "$PM" forget test 2>&1)"
check "回答 y 會刪除"      "已刪除" "$out"
[ -f "$XDG_CONFIG_HOME/hangar/profiles/test.conf" ] || { echo "  PASS  檔案已刪除"; PASS=$((PASS+1)); }
"$PM" >/dev/null 2>&1
check "剩下的那支變成唯一" "$P1:5555" "$(cat "$MOCK_STATE/scrcpy_argv")"

echo "=== M14. status -p 分別回報 ==="
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
out="$("$PM" status -p test 2>&1)"
check "status 指到 test"   "test" "$out"
check "test 的 IP"         "$P2"  "$out"
check "test 的機型"        "Zenfone 10" "$out"
out="$("$PM" status -p work 2>&1)"
check "work 的機型"        "Pixel 7 Pro" "$out"

echo "=== M15. setup 同一名稱重設會提醒覆蓋 ==="
two_phones; : > "$MOCK_STATE/adb_devices"
printf 'PHONE_HOST="zenfone"\nPHONE_IP="100.99.99.99"\n' > "$XDG_CONFIG_HOME/hangar/profiles/zenfone.conf"
printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"
out="$("$PM" setup zenfone 2>&1)"
check "提醒 IP 會被更新"   "原本指向 100.99.99.99" "$out"
check "提醒與現有 profile 重複" "也指向 $P2" "$out"

echo "=== M16. 重跑 setup 不可以把 scan 記住的 MAC 洗掉 ==="
# save_profile 是整份重寫，不先讀回來就會把 PHONE_MAC 清成空的 ——
# 那等於每次 setup 都要重新學一次，換 IP 就又認不得了。
two_phones; : > "$MOCK_STATE/adb_devices"
printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"
printf 'PHONE_HOST="zenfone"\nPHONE_IP="%s"\nTRANSPORT="tailscale"\nPHONE_MAC="a4:03:e7:01:02:03"\n' \
  "$P2" > "$XDG_CONFIG_HOME/hangar/profiles/zenfone.conf"
"$PM" setup zenfone >/dev/null 2>&1
assert "IP 沒變就留著 MAC" "a4:03:e7:01:02:03" \
  "$(grep -E '^PHONE_MAC=' "$XDG_CONFIG_HOME/hangar/profiles/zenfone.conf" | cut -d'"' -f2)"
# 反過來：同一個名字改指到另一支手機時，舊的 MAC 是錯的，不能留
two_phones; : > "$MOCK_STATE/adb_devices"
printf 'USBSERIAL1\tdevice\n' > "$MOCK_STATE/adb_devices"
printf 'PHONE_HOST="zenfone"\nPHONE_IP="100.99.99.99"\nTRANSPORT="tailscale"\nPHONE_MAC="a4:03:e7:01:02:03"\n' \
  > "$XDG_CONFIG_HOME/hangar/profiles/zenfone.conf"
"$PM" setup zenfone >/dev/null 2>&1
assert "IP 換了就不留舊 MAC" "" \
  "$(grep -E '^PHONE_MAC=' "$XDG_CONFIG_HOME/hangar/profiles/zenfone.conf" | cut -d'"' -f2)"

echo "=== M17. 迴圈體把 stdin 吸乾，也不可以少掉手機 ==="
# 真的 `adb … shell …` 會把 stdin 轉發給手機、一路讀到 EOF——也就是把呼叫端的
# stdin 整個吸乾。profile 迴圈若用預設的 stdin，第一支手機處理完，process
# substitution 剩下的行就沒了，迴圈**安靜地**結束：exit 0、沒有錯誤訊息，就是
# 少了幾支手機，`hangar list` 與裝置牆上一起消失。只有一個 profile 時完全看不
# 出來，所以這條測試一定要有兩支。修法是讓迴圈改讀 fd 3（見 list_profiles 上面
# 那段註解）。mockbin 的假 adb 不模擬這個行為，這裡用一個只在本節生效的 shim。
two_phones; echo work > "$XDG_CONFIG_HOME/hangar/default"
GREEDY="$MOCK_STATE/greedybin"; mkdir -p "$GREEDY"
cat > "$GREEDY/adb" <<SHIM
#!/usr/bin/env bash
# 跟真的 adb 一樣：shell 子指令會把 stdin 讀到 EOF 為止
sub="\$1"; [ "\$1" = "-s" ] && sub="\$3"
[ "\$sub" = "shell" ] && cat >/dev/null 2>&1
exec "$SP/mockbin/adb" "\$@"
SHIM
chmod +x "$GREEDY/adb"
# stdin 給 /dev/null：迴圈外的 adb 呼叫才不會卡在一個沒人關的管線上等 EOF。
# 迴圈內的那些讀到的是 process substitution，本來就會自己 EOF。
out="$(PATH="$GREEDY:$PATH" "$PM" list </dev/null 2>&1)"
check "第一支還在"        "work"     "$out"
check "第二支沒有被吃掉"  "test"     "$out"
check "預設標記還在"      "\* *work" "$out"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

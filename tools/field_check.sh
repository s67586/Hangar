#!/usr/bin/env bash
#
# 待確認清單（ROADMAP「待確認清單」）裡要實機才答得出來的那幾條，照表跑。
# 每一項都把看到的東西印出來、也寫進 log，結果再手動補回 ROADMAP。
#
#   tools/field_check.sh watch    -p 手機 [--every 秒]   B1 前半：放著不碰，agent 活多久
#   tools/field_check.sh reboot   -p 手機 [--timeout 秒] B1 後半：重開機後 agent 自己回不回得來
#   tools/field_check.sh adb-off  -p 手機                B2：關掉 adb_enabled，無線偵錯與 agent 還在嗎
#   tools/field_check.sh wifi-adb -p 手機                A1 + A3：寫 adb_wifi_enabled 有沒有效、埠找不找得到
#   tools/field_check.sh repair   -p 手機                A2：配對過的電腦重開機後能不能免配對重連
#
# 會動到手機狀態的（reboot、adb-off、wifi-adb）執行前都會問一次，--yes 跳過；
# 跑完會把動過的東西改回原本的樣子。log 預設寫到 ./field_check-<手機>.log。
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HANGAR="${HANGAR:-$HERE/../hangar}"

die() { echo "錯誤：$*" >&2; exit 1; }
now() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s  %s\n' "$(now)" "$*" | tee -a "$LOG"; }

confirm() {
  [ "$YES" = 1 ] && return 0
  printf '%s\n要繼續嗎？[y/N] ' "$1"
  read -r ans; [ "$ans" = y ] || [ "$ans" = Y ] || die "取消"
}

# 從 hangar list --json --probe 取這支手機的一個欄位（python 表達式，d 是那一筆）
field() {
  "$HANGAR" list --json --probe 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin).get("devices", []):
    if d.get("profile") == sys.argv[1]:
        try: v = eval(sys.argv[2], {}, {"d": d})
        except Exception: v = None
        print("" if v is None else v)
        break' "$PROFILE" "$1"
}

# 一次拿齊：adb 狀態、agent 答不答得出話、偵錯、無線偵錯、電量
snapshot() {
  "$HANGAR" list --json --probe 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin).get("devices", []):
    if d.get("profile") != sys.argv[1]: continue
    a = d.get("agent") or {}; adb = a.get("adb") or {}; b = d.get("battery") or {}
    print("adb=%s agent=%s debug=%s wifi_adb=%s battery=%s" % (
        d.get("adb_state"), "up" if a.get("reachable") else "DOWN",
        adb.get("enabled"), adb.get("wifi_enabled"), b.get("level")))
    break
else:
    print("找不到這個 profile")' "$PROFILE"
}

agent_up() { [ "$(field 'd["agent"]["reachable"]')" = True ]; }
adb_up()   { [ "$(field 'd["adb_state"]')" = device ]; }

CMD="${1:-}"; shift || true
PROFILE=""; EVERY=300; TIMEOUT=600; YES=0; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PROFILE="$2"; shift 2 ;;
    --every) EVERY="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    --log) LOG="$2"; shift 2 ;;
    *) die "看不懂的參數：$1" ;;
  esac
done
[ -n "$CMD" ] || { sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -n "$PROFILE" ] || die "要給 -p 手機"
[ -n "$LOG" ] || LOG="./field_check-${PROFILE}.log"
[ -n "$(field 'd["profile"]')" ] || die "hangar list 裡沒有「${PROFILE}」這個 profile"
SERIAL="$(field 'd["adb_serial"]')"

case "$CMD" in
watch)
  # B1 前半。中間不要碰手機；Ctrl-C 結束，log 就是存活曲線
  log "[B1 watch] 開始，每 ${EVERY} 秒看一次（Ctrl-C 結束）"
  while :; do log "$(snapshot)"; sleep "$EVERY"; done
  ;;

reboot)
  # B1 後半。重開機之後 5555 會消失，所以 agent 回不回得來要從 agent 那條路看
  adb_up || die "adb 現在不通，沒辦法下 reboot（${SERIAL}）"
  confirm "會重開 ${PROFILE}（${SERIAL}）。"
  log "[B1 reboot] 重開前：$(snapshot)"
  adb -s "$SERIAL" reboot
  t0=$(date +%s); agent_at=""; adb_at=""
  while [ $(( $(date +%s) - t0 )) -lt "$TIMEOUT" ]; do
    sleep 10
    s="$(snapshot)"; el=$(( $(date +%s) - t0 ))
    log "+${el}s  $s"
    [ -z "$agent_at" ] && case "$s" in *agent=up*) agent_at=$el ;; esac
    [ -z "$adb_at" ] && case "$s" in *adb=device*) adb_at=$el ;; esac
    [ -n "$agent_at" ] && [ -n "$adb_at" ] && break
  done
  log "[B1 reboot] 結果：agent ${agent_at:+${agent_at}s 後回來}${agent_at:-${TIMEOUT}s 內沒回來}；adb ${adb_at:+${adb_at}s 後回來}${adb_at:-${TIMEOUT}s 內沒回來（Android 11 以下是預期的）}"
  [ -z "$agent_at" ] && log "  → agent 沒自己回來：先解鎖一次手機再看，分清楚是「開機沒起」還是「要解鎖才起」"
  ;;

adb-off)
  # B2。偵錯由 agent 關、再由 agent 開回來，所以 agent 必須先答得出話
  agent_up || die "agent 現在叫不動；這項要靠 agent 把偵錯開回來，先別跑"
  confirm "會用 agent 關掉 $PROFILE 的偵錯（adb_enabled=0），觀察 30 秒後再開回來。"
  log "[B2] 關之前：$(snapshot)"
  "$HANGAR" adb -p "$PROFILE" --off | tee -a "$LOG"
  for i in 1 2 3; do
    sleep 10
    log "+$((i*10))s  $(snapshot)"
    log "       adb devices：$(adb devices | grep -F "${SERIAL%%:*}" | tr '\n' ' ')"
    log "       adb mdns：$(adb mdns services 2>/dev/null | grep -c _adb-tls-connect) 筆 _adb-tls-connect"
  done
  "$HANGAR" adb -p "$PROFILE" --on | tee -a "$LOG" \
    || log "!!! 開不回來 —— 這支現在偵錯關著，要有人到手機旁邊處理"
  sleep 5; log "[B2] 開回來之後：$(snapshot)"
  ;;

wifi-adb)
  # A1 + A3。這一步會動到手機的安全設定（ROADMAP：要有意識地做）
  adb_up || die "adb 現在不通（${SERIAL}）"
  before="$(adb -s "$SERIAL" shell settings get global adb_wifi_enabled 2>/dev/null | tr -d '\r')"
  confirm "會把 $PROFILE 的 adb_wifi_enabled 從「${before}」寫成 1（打開無線偵錯），看完再改回去。"
  log "[A1] 寫之前：adb_wifi_enabled=$before  $(snapshot)"
  adb -s "$SERIAL" shell settings put global adb_wifi_enabled 1
  sleep 5
  after="$(adb -s "$SERIAL" shell settings get global adb_wifi_enabled 2>/dev/null | tr -d '\r')"
  log "[A1] 寫之後：adb_wifi_enabled=$after  $(snapshot)"
  log "     → 再去手機「開發人員選項 → 無線偵錯」看開關是不是真的亮了（值被寫進去 ≠ 服務真的起來）"
  log "[A3] adb mdns services："
  adb mdns services 2>&1 | tee -a "$LOG"
  if command -v dns-sd >/dev/null 2>&1; then
    log "[A3] dns-sd -B _adb-tls-connect._tcp（5 秒）："
    ( dns-sd -B _adb-tls-connect._tcp & p=$!; sleep 5; kill $p ) 2>&1 | tee -a "$LOG"
  fi
  if [ "$before" != 1 ]; then
    adb -s "$SERIAL" shell settings put global adb_wifi_enabled "${before:-0}"
    log "[A1] 已改回 adb_wifi_enabled=${before:-0}"
  fi
  ;;

repair)
  # A2。無線偵錯的埠每次開都會變，配對記錄在不在是這一項要看的
  echo "步驟："
  echo "  1. 手機「無線偵錯 → 使用配對碼配對裝置」，在這台電腦跑 adb pair <ip:port> <碼>（已配對過就跳過）"
  echo "  2. 重開手機，解鎖，手動打開「無線偵錯」—— 不要再配對"
  echo "  3. 按 Enter，這裡接著看 60 秒內 adb 會不會自己連上"
  read -r _
  log "[A2] 開始看 adb devices 與 mdns"
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 60 ]; do
    hit="$(adb devices | grep _adb-tls-connect)"
    if [ -n "$hit" ]; then log "[A2] 自己連上了：$hit"; exit 0; fi
    sleep 5
  done
  log "[A2] 60 秒內沒有自己連上。mdns 看得到的："
  adb mdns services 2>&1 | tee -a "$LOG"
  log "     → 試一次 adb connect <上面那個 ip:port>：連得上 = 配對還在、只是不會自動連；要求配對 = 配對沒留下來"
  ;;

*) die "不認得的項目：$CMD" ;;
esac

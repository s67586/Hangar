#!/usr/bin/env bash
#
# 跑全部測試。用 mock 的 adb / tailscale / scrcpy / arp，不會碰到真的手機，
# 也不會真的對區網送封包。hub 的測試會在 127.0.0.1 上開一個隨機埠。
#
#   tests/run.sh
#
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PM="${1:-$DIR/../hangar}"
[ -x "$PM" ] || { echo "找不到可執行的 hangar：$PM" >&2; exit 1; }
PM="$(cd "$(dirname "$PM")" && pwd)/$(basename "$PM")"

total_pass=0; total_fail=0; failed_suites=""
for suite in test_core.sh test_multi.sh test_adb_race.sh test_multihost.sh test_json.sh test_scan.sh test_hub.sh test_agent_protocol.sh test_agent_client.sh test_manual.sh; do
  echo
  echo "############ $suite ############"
  out="$(bash "$DIR/$suite" "$PM" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | grep -vE '^\s*$'
  p="$(printf '%s' "$out" | sed -nE 's/^PASS: ([0-9]+).*/\1/p' | tail -1)"
  f="$(printf '%s' "$out" | sed -nE 's/.*FAIL: ([0-9]+)/\1/p' | tail -1)"
  total_pass=$(( total_pass + ${p:-0} ))
  total_fail=$(( total_fail + ${f:-0} ))
  [ "$rc" -eq 0 ] || failed_suites="$failed_suites $suite"
done

# 收尾：測試會留下 mock 的 scrcpy process
pkill -f 'scrcpy .*100.101.102.1' 2>/dev/null
rm -rf "${TMPDIR:-/tmp}/hangar-test"

echo
echo "================================================"
printf '總計  PASS: %d   FAIL: %d\n' "$total_pass" "$total_fail"
[ -z "$failed_suites" ] || { echo "失敗的 suite:$failed_suites"; exit 1; }
echo "全部通過"

#!/usr/bin/env bash
#
# ROADMAP 的「現況速查」是給人看的單一入口；這份測試把它跟程式裡真正
# 會送出去的 schema/version 宣告對起來，避免只改了一邊又留下漂移。
#
SP="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SP/.." && pwd)"
PASS=0; FAIL=0

assert() {
  if [ "$2" = "$3" ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

value() { sed -nE "$1" "$2" | head -1; }
line_of() { grep -n -m1 -E "$2" "$1" 2>/dev/null | cut -d: -f1; }

HANGAR="$ROOT/hangar"
ROADMAP="$ROOT/ROADMAP.md"
HUB="$ROOT/hub/hangar_hub.py"
HELPER="$ROOT/helper/hangar_helper.py"
BUILD="$ROOT/agent/app/build.gradle.kts"
FAKE="$ROOT/tests/agentbin/fake_agent.py"

echo "=== V1. source declarations are present exactly once ==="
assert "hangar VERSION 唯一" "1" "$(grep -c '^VERSION=' "$HANGAR")"
assert "hangar JSON_SCHEMA 唯一" "1" "$(grep -c '^JSON_SCHEMA=' "$HANGAR")"
assert "hangar SCAN_SCHEMA 唯一" "1" "$(grep -c '^SCAN_SCHEMA=' "$HANGAR")"
assert "hub API_SCHEMA 唯一" "1" "$(grep -c '^API_SCHEMA' "$HUB")"
assert "helper API_SCHEMA 唯一" "1" "$(grep -c '^API_SCHEMA' "$HELPER")"
assert "agent versionName 唯一" "1" "$(grep -c 'versionName = ' "$BUILD")"
assert "agent PROTOCOL_SCHEMA 唯一" "1" "$(grep -c 'PROTOCOL_SCHEMA' "$BUILD")"

hangar_version="$(value 's/^VERSION="([^"]+)".*/\1/p' "$HANGAR")"
json_schema="$(value 's/^JSON_SCHEMA=([0-9]+)$/\1/p' "$HANGAR")"
scan_schema="$(value 's/^SCAN_SCHEMA=([0-9]+)$/\1/p' "$HANGAR")"
hub_schema="$(value 's/^API_SCHEMA = ([0-9]+)$/\1/p' "$HUB")"
helper_schema="$(value 's/^API_SCHEMA = ([0-9]+)$/\1/p' "$HELPER")"
agent_version="$(value 's/.*versionName = "([^"]+)".*/\1/p' "$BUILD")"
agent_schema="$(value 's/.*PROTOCOL_SCHEMA", "([0-9]+)".*/\1/p' "$BUILD")"
fake_schema="$(value 's/^SCHEMA = ([0-9]+)$/\1/p' "$FAKE")"

echo "=== V2. ROADMAP values match source declarations ==="
hangar_row="$(value 's/^\| `hangar` 版本 \| `([^`]+)` \| `hangar:([0-9]+)` \|$/\1 \2/p' "$ROADMAP")"
json_row="$(value 's/^\| `list` \/ `status --json` \| schema \*\*([0-9]+)\*\* \| `JSON_SCHEMA`，`hangar:([0-9]+)` \|$/\1 \2/p' "$ROADMAP")"
scan_row="$(value 's/^\| `scan --json` \| schema \*\*([0-9]+)\*\* \| `SCAN_SCHEMA`，`hangar:([0-9]+)` \|$/\1 \2/p' "$ROADMAP")"
hub_row="$(value 's/^\| hub `\/api\/devices` \| schema \*\*([0-9]+)\*\* \| `API_SCHEMA`，`hub\/hangar_hub.py:([0-9]+)` \|$/\1 \2/p' "$ROADMAP")"
agent_row="$(value 's/^\| agent 協定 \| schema \*\*([0-9]+)\*\*，版本 `([^`]+)` \| `agent\/app\/build.gradle.kts` \|$/\1 \2/p' "$ROADMAP")"
helper_row="$(value 's/^\| helper 端點 .* \| `API_SCHEMA` \*\*([0-9]+)\*\*，`helper\/hangar_helper.py:([0-9]+)` \|$/\1 \2/p' "$ROADMAP")"

read -r roadmap_hangar roadmap_hangar_line <<< "$hangar_row"
read -r roadmap_json roadmap_json_line <<< "$json_row"
read -r roadmap_scan roadmap_scan_line <<< "$scan_row"
read -r roadmap_hub roadmap_hub_line <<< "$hub_row"
read -r roadmap_agent roadmap_agent_version <<< "$agent_row"
read -r roadmap_helper roadmap_helper_line <<< "$helper_row"

assert "ROADMAP hangar 版本" "$hangar_version" "$roadmap_hangar"
assert "ROADMAP list schema" "$json_schema" "$roadmap_json"
assert "ROADMAP scan schema" "$scan_schema" "$roadmap_scan"
assert "ROADMAP hub schema" "$hub_schema" "$roadmap_hub"
assert "ROADMAP agent schema" "$agent_schema" "$roadmap_agent"
assert "ROADMAP agent 版本" "$agent_version" "$roadmap_agent_version"
assert "ROADMAP helper schema" "$helper_schema" "$roadmap_helper"

echo "=== V3. ROADMAP line references still point at declarations ==="
assert "hangar VERSION 行號" "$(line_of "$HANGAR" '^VERSION=')" "$roadmap_hangar_line"
assert "hangar JSON_SCHEMA 行號" "$(line_of "$HANGAR" '^JSON_SCHEMA=')" "$roadmap_json_line"
assert "hangar SCAN_SCHEMA 行號" "$(line_of "$HANGAR" '^SCAN_SCHEMA=')" "$roadmap_scan_line"
assert "hub API_SCHEMA 行號" "$(line_of "$HUB" '^API_SCHEMA')" "$roadmap_hub_line"
assert "helper API_SCHEMA 行號" "$(line_of "$HELPER" '^API_SCHEMA')" "$roadmap_helper_line"

echo "=== V4. agent reference implementation uses the same protocol schema ==="
assert "fake agent schema 跟 Android 一致" "$agent_schema" "$fake_schema"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

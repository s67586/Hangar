#!/usr/bin/env bash
#
# 從 README 產生手冊的那支腳本（tools/make_manual.py）。
#
# 這裡要擋的是兩種壞法：
#   1. Markdown 沒轉乾淨 —— 讀者會看到 `**這樣**` 或一整列 `| --- |`
#   2. 內容掉了 —— 少一個區段、少一張表格，而且沒有人會發現
#
SP="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SP/.." && pwd)"
GEN="$ROOT/tools/make_manual.py"
STATE="${TMPDIR:-/tmp}/hangar-test/manual"
PASS=0; FAIL=0

check()  { if printf '%s' "$3" | grep -q -- "$2"; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n        期望: %s\n        實際: %s\n' "$1" "$2" "$(printf '%s' "$3"|head -c 300|tr '\n' '|')"; FAIL=$((FAIL+1)); fi; }
nocheck(){ if printf '%s' "$3" | grep -q -- "$2"; then printf '  FAIL  %s（不該出現 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); fi; }
assert() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s（期望「%s」實際「%s」）\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

command -v python3 >/dev/null 2>&1 || { echo "  SKIP  這台機器沒有 python3"; exit 0; }
rm -rf "$STATE"; mkdir -p "$STATE"

echo "=== N1. 每一種構造都要轉得出來 ==="
cat > "$STATE/in.md" <<'MD'
# 測試文件

開頭這段在任何區段外面。

## 第一節

一段**粗體**與 `行內程式` 與 [連結](https://example.com/x)。

```bash
hangar list        # 這是註解
```

| 欄一 | 欄二 |
|---|---|
| `a` | **b** |

- 項目一
- 項目二

1. 第一步
2. 第二步

> 普通的引言

> [!WARNING]
> 這件事要小心

> [!CAUTION]
> 這件事會弄壞東西

### 小節

內容。
MD
out="$(python3 "$GEN" --readme "$STATE/in.md" --out "$STATE/out.html" 2>&1)"
body="$(cat "$STATE/out.html")"

check "標題來自 # 那一行"    "<title>測試文件 使用手冊</title>" "$body"
check "## 變成區段"          '<section id="第一節">' "$body"
check "## 也進目錄"          '<li><a href="#第一節">第一節</a></li>' "$body"
check "### 變成 h3"          '<h3 id="小節">小節</h3>' "$body"
check "粗體"                 '<strong>粗體</strong>' "$body"
check "行內程式"             '<code>行內程式</code>' "$body"
check "連結"                 '<a href="https://example.com/x">連結</a>' "$body"
check "程式區塊"             '<div class="term">' "$body"
check "區塊 bar 顯示語言"    '<div class="bar">bash</div>' "$body"
check "shell 註解調暗"       '<span class="c"># 這是註解</span>' "$body"
check "表格表頭"             '<th>欄一</th>' "$body"
check "表格內容也吃行內語法" '<td class="wrap"><code>a</code></td>' "$body"
check "無序清單"             '<li>項目一</li>' "$body"
check "有序清單"             '<ol class="list">' "$body"
check "普通引言"             '<div class="note">' "$body"
check "WARNING 轉成 warn"    '<div class="note warn">' "$body"
check "CAUTION 轉成 stop"    '<div class="note stop">' "$body"
check "區段外的開頭也留著"   "開頭這段在任何區段外面" "$body"

echo "=== N2. 不可以有沒轉乾淨的 Markdown 漏出去 ==="
# 讀者看到 `**這樣**` 或 `| --- |` 就代表轉換器有洞
nocheck "沒有裸的粗體記號"   '\*\*' "$body"
nocheck "沒有表格分隔列"     '^| ---' "$body"
nocheck "沒有裸的圍籬"       '^```' "$body"
nocheck "沒有裸的標題記號"   '^## ' "$body"

echo "=== N3. 危險的東西要轉義，不能變成 HTML ==="
cat > "$STATE/x.md" <<'MD'
# X

## 注入

`<script>alert(1)</script>` 與 <b>裸標籤</b> 與 `a && b` 與 "引號"。

行內程式裡的 `**星號**` 不該變成粗體。
MD
python3 "$GEN" --readme "$STATE/x.md" --out "$STATE/x.html" >/dev/null 2>&1
xb="$(cat "$STATE/x.html")"
nocheck "script 標籤被轉義"   '<script>alert' "$xb"
check   "轉義後的樣子還在"    '&lt;script&gt;' "$xb"
nocheck "裸的 b 標籤也轉義"   '<b>裸標籤</b>' "$xb"
check   "程式裡的星號不變粗體" '<code>\*\*星號\*\*</code>' "$xb"

echo "=== N4. 錨點要跟 GitHub 同一套規則 ==="
# README 裡有 [看這裡](#某某小節) 這種連結，錨點對不上的話手冊裡全是死連結
anchors="$(python3 - "$GEN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
for t in ["同區網直連（不經 Tailscale）", "Tailscale ACL（強烈建議）",
          "密碼頁面投影全黑（FLAG_SECURE）", "hub（裝置牆網頁）"]:
    print(g.slug(t))
PY
)"
check "括號被去掉"   "同區網直連不經-tailscale"   "$anchors"
check "大寫轉小寫"   "tailscale-acl強烈建議"      "$anchors"
check "底線留著"     "密碼頁面投影全黑flag_secure" "$anchors"

echo "=== N5. 真的拿 README 跑一次，內容不可以掉 ==="
# 統計腳本寫成檔案再跑：bash 解析 $( ) 裡的內嵌 heredoc 時會被裡面的 | 與反引號
# 絆倒，而那兩個字元在數 Markdown 表格與圍籬時躲不掉。
cat > "$STATE/count.py" <<'PY'
import re, sys
lines = open(sys.argv[2], encoding="utf-8").read().split("\n")
fence = False
n = 0
for i, l in enumerate(lines):
    if l.startswith("```"):
        fence = not fence
        continue
    if fence:
        continue
    if sys.argv[1] == "h2" and re.match(r"^## ", l):
        n += 1
    if sys.argv[1] == "table" and l.startswith("|") and i + 1 < len(lines) \
       and re.match(r"^\|[\s:|-]+\|\s*\Z", lines[i + 1]):
        n += 1
print(n)
PY

python3 "$GEN" --out "$STATE/real.html" >/dev/null 2>&1
real="$(cat "$STATE/real.html")"

md_h2="$(python3 "$STATE/count.py" h2 "$ROOT/README.md")"
html_h2="$(printf '%s' "$real" | grep -c '<section id=')"
assert "每個 ## 都變成區段" "$md_h2" "$html_h2"
toc_n="$(printf '%s' "$real" | grep -o '<li><a href="#' | grep -c .)"
assert "目錄項目數也一樣"   "$md_h2" "$toc_n"

md_tbl="$(python3 "$STATE/count.py" table "$ROOT/README.md")"
html_tbl="$(printf '%s' "$real" | grep -o '<table>' | grep -c .)"
assert "每張表格都在"       "$md_tbl" "$html_tbl"
nocheck "手冊裡不要有自己的連結" "claude.ai/artifact" "$real"

echo "=== N6. --check：落後了要講 ==="
python3 "$GEN" --readme "$STATE/in.md" --out "$STATE/chk.html" >/dev/null 2>&1
python3 "$GEN" --readme "$STATE/in.md" --out "$STATE/chk.html" --check >/dev/null 2>&1
assert "同步時回 0"     "0" "$?"
printf '\n改了一行\n' >> "$STATE/in.md"
python3 "$GEN" --readme "$STATE/in.md" --out "$STATE/chk.html" --check >/dev/null 2>&1
assert "來源變了回非 0" "1" "$?"
python3 "$GEN" --readme "$STATE/in.md" --out "$STATE/nothere.html" --check >/dev/null 2>&1
assert "檔案不存在回非 0" "1" "$?"

# 印記要是可決定的：同一份 README 跑兩次必須一模一樣，--check 才有意義
python3 "$GEN" --readme "$STATE/in.md" --out "$STATE/a.html" >/dev/null 2>&1
python3 "$GEN" --readme "$STATE/in.md" --out "$STATE/b.html" >/dev/null 2>&1
if cmp -s "$STATE/a.html" "$STATE/b.html"; then
  echo "  PASS  跑兩次的產出完全一樣"; PASS=$((PASS+1))
else
  echo "  FAIL  兩次產出不同（印記不可決定的話 --check 永遠會失敗）"; FAIL=$((FAIL+1))
fi
check "印記蓋的是 README 的指紋" "README sha256" "$(cat "$STATE/a.html")"

echo; echo "================================"; printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

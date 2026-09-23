#!/usr/bin/env python3
"""從 README.md 與 docs/*.md 產生一頁可讀的使用手冊（HTML）。

為什麼要有這支：手冊如果是手寫的第二份文件，它跟 README 一定會走岔，而讀的人
分不出哪份是對的。**每段內容只有一個來源檔**才是唯一不會過期的做法。

README 只留「裝起來、設定一支手機、每天投影」那條路，各個題目的完整說明分在
`docs/` 底下。手冊要的則是全部 —— 所以這支把它們接成一份再轉：

    README 的 <!-- manual:docs --> 那一行 → 換成 docs/ 那幾份的內容
    接哪幾份、什麼順序                    → 看 README 連到誰、先連到誰
    docs/x.md 的標題 `#`                  → 手冊裡降成章節 `##`
    跨檔連結 docs/x.md#y                  → 頁內錨點 #y

「README 連到誰誰就進手冊」是刻意的：不要有第二份需要同步維護的清單，而沒有
被 README 連到的 docs/ 檔案本來就是孤兒，不該出現在手冊裡。

    tools/make_manual.py                  # → docs/manual.html
    tools/make_manual.py --out /tmp/a.html
    tools/make_manual.py --check          # 產出跟現有檔案不一樣就回非 0

只用 Python 3 標準函式庫（跟 hub 一樣的理由：不為了一頁 HTML 裝一套生態系），
所以這裡有一份很小的 Markdown 轉換器 —— 它只認這些文件真的用到的那些構造：

    標題 # ## ### ####      → 區段（## 會進目錄）
    圍籬程式區塊 ```lang    → 終端機樣式的區塊，bar 顯示語言
    GFM 表格 | --- |        → 表格（窄螢幕自己橫向捲）
    清單 - / 1.             → ul / ol
    引言 >                  → 提示塊；支援 GitHub 的 [!WARNING] / [!CAUTION]
    行內 **粗體** `程式` [連結](網址)

刻意不支援的：巢狀清單、圖片、行內 HTML、刪除線 —— README 沒用到。真的要用的
時候這支會直接把它當普通文字放過去，不會假裝看得懂。
"""

import argparse
import hashlib
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# GitHub 的 alert 語法 → 提示塊的樣式。用這一套而不是自己發明標記，是因為它在
# GitHub 上也顯示得出來 —— README 仍然是給人直接讀的。
ALERTS = {
    "NOTE": ("note", ""),
    "TIP": ("note", ""),
    "IMPORTANT": ("note warn", ""),
    "WARNING": ("note warn", ""),
    "CAUTION": ("note stop", ""),
}


# ------------------------------------------------------------------ 行內 ----

def slug(text):
    """GitHub 風格的錨點。

    要跟 GitHub 一致，README 裡那些 `[看這裡](#某某小節)` 的連結在這一頁才會通。
    規則：轉小寫 → 去掉標點（CJK 與英數留著）→ 空白換成 -。
    """
    t = re.sub(r"`([^`]*)`", r"\1", text)
    t = re.sub(r"\*\*([^*]*)\*\*", r"\1", t)
    t = t.strip().lower()
    t = re.sub(r"[^\w\s-]", "", t, flags=re.UNICODE)
    return re.sub(r"\s+", "-", t)


def inline(text):
    """行內語法。先轉義 HTML，再把 `程式` 抽出來保護起來，才不會被粗體吃掉。"""
    spans = []

    def stash(m):
        spans.append(html.escape(m.group(1)))
        return "\x00%d\x00" % (len(spans) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
                  lambda m: '<a href="%s">%s</a>' % (html.escape(m.group(2), quote=True),
                                                     m.group(1)), text)
    return re.sub(r"\x00(\d+)\x00", lambda m: "<code>%s</code>" % spans[int(m.group(1))], text)


def shell_code(text, lang):
    """程式區塊的內容。bash/sh 的行尾註解調暗 —— 那是這份文件裡最常見的說明方式。

    只在 # 前面是行首或空白時才算註解。字串裡的 # 這樣就不會被誤判，而 README
    裡也沒有「註解符號出現在字串中間又要保持原色」的情況。
    """
    out = html.escape(text)
    if lang in ("bash", "sh", "ini"):
        out = re.sub(r"(^|\s)(#[^\n]*)", r'\1<span class="c">\2</span>', out, flags=re.M)
    return out


# ------------------------------------------------------------------ 區塊 ----

class Doc:
    def __init__(self):
        self.parts = []      # 主要內容（HTML 片段）
        self.toc = []        # (層級, 標題, 錨點)
        self.title = "使用手冊"
        self._open_section = False

    def close_section(self):
        if self._open_section:
            self.parts.append("</section>")
            self._open_section = False

    def open_section(self, anchor):
        self.close_section()
        self.parts.append('<section id="%s">' % anchor)
        self._open_section = True

    def html(self):
        self.close_section()
        return "\n".join(self.parts)


def convert(md):
    doc = Doc()
    lines = md.split("\n")
    i = 0
    para = []

    def flush_para():
        if para:
            doc.parts.append("<p>%s</p>" % inline(" ".join(para).strip()))
            para.clear()

    while i < len(lines):
        line = lines[i]

        # --- 程式區塊 ---
        if line.startswith("```"):
            lang = line[3:].strip()
            body = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            flush_para()
            bar = '<div class="bar">%s</div>' % html.escape(lang or "shell")
            doc.parts.append('<div class="term">%s<pre>%s</pre></div>'
                             % (bar, shell_code("\n".join(body), lang)))
            continue

        # --- 標題 ---
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            flush_para()
            level, text = len(m.group(1)), m.group(2).strip()
            if level == 1:
                doc.title = re.sub(r"`|\*\*", "", text)
            elif level == 2:
                a = slug(text)
                doc.toc.append((2, text, a))
                doc.open_section(a)
                doc.parts.append('<h2 id="%s">%s</h2>' % (a, inline(text)))
            else:
                a = slug(text)
                tag = "h3" if level == 3 else "h4"
                doc.parts.append('<%s id="%s">%s</%s>' % (tag, a, inline(text), tag))
            i += 1
            continue

        # --- 表格（GFM）---
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|\s*$", lines[i + 1]):
            flush_para()
            def cells(row):
                return [c.strip() for c in row.strip().strip("|").split("|")]
            head = cells(line)
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(cells(lines[i]))
                i += 1
            # 整列都空的表頭在 README 裡很常見（純對照表），那就不要印出空的一列
            has_head = any(c for c in head)
            out = ['<div class="tw"><table>']
            if has_head:
                out.append("<tr>%s</tr>" % "".join("<th>%s</th>" % inline(c) for c in head))
            for r in rows:
                out.append("<tr>%s</tr>" % "".join('<td class="wrap">%s</td>' % inline(c) for c in r))
            out.append("</table></div>")
            doc.parts.append("".join(out))
            continue

        # --- 引言／提示塊 ---
        if line.startswith(">"):
            flush_para()
            body = []
            while i < len(lines) and lines[i].startswith(">"):
                body.append(lines[i].lstrip(">").strip())
                i += 1
            text = "\n".join(body).strip()
            cls = "note"
            m2 = re.match(r"^\[!([A-Z]+)\]\s*", text)
            if m2:
                cls = ALERTS.get(m2.group(1), ("note", ""))[0]
                text = text[m2.end():]
            # 手冊自己的連結不要出現在手冊裡 —— 那一段是給 README 的讀者看的
            if "claude.ai/artifact" in text:
                continue
            paras = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
            doc.parts.append('<div class="%s">%s</div>'
                             % (cls, "".join("<p>%s</p>" % inline(p.replace("\n", " "))
                                             for p in paras)))
            continue

        # --- 清單 ---
        m = re.match(r"^(\d+)\.\s+(.*)$", line)
        if m or line.startswith("- "):
            flush_para()
            ordered = bool(m)
            items = []
            while i < len(lines):
                mm = re.match(r"^(\d+)\.\s+(.*)$", lines[i]) if ordered else None
                if ordered and mm:
                    items.append(mm.group(2))
                elif not ordered and lines[i].startswith("- "):
                    items.append(lines[i][2:])
                elif lines[i].startswith("  ") and items:
                    items[-1] += " " + lines[i].strip()      # 續行
                else:
                    break
                i += 1
            tag = "ol" if ordered else "ul"
            doc.parts.append("<%s%s>%s</%s>" % (
                tag, ' class="list"' if ordered else "",
                "".join("<li>%s</li>" % inline(x) for x in items), tag))
            continue

        # --- 分隔線：## 已經負責分段了，這裡不需要再畫一條 ---
        if line.strip() in ("---", "***", "___"):
            flush_para()
            i += 1
            continue

        # --- 空行／段落 ---
        if not line.strip():
            flush_para()
        else:
            para.append(line.strip())
        i += 1

    flush_para()
    return doc


# ------------------------------------------------------------------ 來源 ----

MARKER = re.compile(r"^<!-- manual:docs[^\n]*-->[ \t]*$", re.M)
DOC_LINK = re.compile(r"\]\((?:\.\./|docs/)?([\w.-]+\.md)(#[^)\s]*)?\)")


def demote(md):
    """把一份 docs/*.md 的標題整體降一級。

    那些檔案自己是一份文件（`#` 是它的標題），接進手冊時則是一個章節（`##`）。
    整份降一級之後，接起來的結構跟這些內容還在 README 裡時一模一樣 —— 章節照樣
    進目錄，小節照樣是 h3。圍籬裡的 `#` 是 shell 註解，不能動。
    """
    out, fence = [], False
    for line in md.split("\n"):
        if line.startswith("```"):
            fence = not fence
        elif not fence and re.match(r"^#{1,5} ", line):
            line = "#" + line
        out.append(line)
    return "\n".join(out)


def doc_title(md):
    """一份 docs/*.md 的標題（第一個 `#`）—— 也就是它在手冊裡的章節名。"""
    for line in md.split("\n"):
        m = re.match(r"^#\s+(.*)$", line)
        if m:
            return m.group(1).strip()
    return ""


def doc_order(readme_md):
    """要接哪幾份、照什麼順序：README 連到誰，誰就進來，先連到的先接。"""
    names = []
    for m in re.finditer(r"\]\(docs/([\w.-]+)\.md[^)]*\)", readme_md):
        if m.group(1) not in names:
            names.append(m.group(1))
    return names


def rewrite_links(md, anchors):
    """跨檔連結在一頁式手冊裡要變成頁內錨點，否則全是死連結。

        docs/hub.md#多久更新一次 → #多久更新一次   （那個小節就在這一頁上）
        docs/hub.md              → #hub裝置牆網頁  （那一份的標題）
        ../README.md#安裝        → #安裝

    不認得的檔案維持原樣 —— ROADMAP.md 與 agent/README.md 在 repo 裡，手冊
    這一頁沒有它們，指回檔案才是對的。
    """
    def repl(m):
        base, frag = m.group(1), m.group(2)
        if base not in anchors:
            return m.group(0)
        if frag:
            return "](%s)" % frag
        if not anchors[base]:
            return "](#)"                      # README 自己 → 回到這一頁最上面
        return "](#%s)" % anchors[base]
    return DOC_LINK.sub(repl, md)


def relativize(md):
    """README 的相對連結指的是 repo 根目錄，但手冊產在 docs/ 底下 —— 差一層。

    `[hangar](hangar)` 在 GitHub 上是對的，在 docs/manual.html 裡卻會指到
    docs/hangar。docs/ 那幾份本來就寫成 `../ROADMAP.md`，所以只有 README 這一份
    要補。網址、頁內錨點與已經是 `../` 的不動。
    """
    def repl(m):
        target = m.group(1)
        if re.match(r"^(?:[A-Za-z][\w+.-]*:|//|#|\.\./)", target):
            return m.group(0)
        return "](../%s)" % target
    return re.sub(r"\]\(([^)\s]+)\)", repl, md)


def load(readme_path):
    """README ＋ 它連到的那幾份 docs/*.md，接成手冊要轉的那一份 Markdown。"""
    root = os.path.dirname(os.path.abspath(readme_path))
    with open(readme_path, encoding="utf-8") as f:
        readme = f.read()

    anchors = {os.path.basename(readme_path): ""}
    bodies = []
    for name in doc_order(readme):
        path = os.path.join(root, "docs", name + ".md")
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as f:
            body = f.read()
        anchors[name + ".md"] = slug(doc_title(body))
        bodies.append(body)

    # 先把跨檔連結換成頁內錨點，再補 README 少的那一層 —— 順序反過來的話，
    # `docs/hub.md` 會先變成 `../docs/hub.md` 而對不上任何一份。
    readme = relativize(rewrite_links(readme, anchors))
    chunks = [rewrite_links(demote(b).strip(), anchors) for b in bodies]

    docs_md = "\n\n".join(chunks)
    if MARKER.search(readme):
        # 標記那一行換成接起來的內容 —— 用 lambda 是因為內容裡的反斜線不該被
        # 當成替換語法。
        readme = MARKER.sub(lambda _: docs_md, readme, count=1)
    elif chunks:
        readme = readme.rstrip() + "\n\n" + docs_md + "\n"
    return readme


# ------------------------------------------------------------------ 版型 ----

CSS = """
  :root {
    --paper:#f6f8f9; --surface:#ffffff; --surface-2:#eef2f4;
    --ink:#16202b; --ink-2:#52626f; --ink-3:#78868f;
    --line:#dce3e8; --line-2:#c3ced6;
    --accent:#0d6f79; --accent-2:#0a555d;
    --ok:#1c7a4d; --warn:#8f6300; --bad:#ad2b20;
    --term-bg:#14202a; --term-ink:#d6e2ea; --term-dim:#7b8e9c; --term-line:#233240;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --paper:#0f151b; --surface:#161e26; --surface-2:#1c262f;
      --ink:#e4ebf1; --ink-2:#a0aeba; --ink-3:#7c8a95;
      --line:#26313b; --line-2:#35434f;
      --accent:#4bb3bd; --accent-2:#7fcfd6;
      --ok:#4cc38a; --warn:#d5a340; --bad:#ef7f76;
      --term-bg:#0b1219; --term-ink:#ccdae6; --term-dim:#6b7d8b; --term-line:#1e2a35;
    }
  }
  :root[data-theme="dark"] {
    --paper:#0f151b; --surface:#161e26; --surface-2:#1c262f;
    --ink:#e4ebf1; --ink-2:#a0aeba; --ink-3:#7c8a95;
    --line:#26313b; --line-2:#35434f;
    --accent:#4bb3bd; --accent-2:#7fcfd6;
    --ok:#4cc38a; --warn:#d5a340; --bad:#ef7f76;
    --term-bg:#0b1219; --term-ink:#ccdae6; --term-dim:#6b7d8b; --term-line:#1e2a35;
  }

  * { box-sizing: border-box; }
  body {
    margin:0; background:var(--paper); color:var(--ink);
    font-family:"Noto Sans TC", system-ui, -apple-system, sans-serif;
    font-size:15px; line-height:1.75; -webkit-font-smoothing:antialiased;
  }
  .shell { max-width:1160px; margin:0 auto; padding-block:0 72px; padding-left:20px; padding-right:20px; }

  header.top { border-bottom:1px solid var(--line); padding-block:40px 28px; display:grid; gap:14px; }
  .wordmark {
    font-family:Archivo, system-ui, sans-serif; font-weight:700;
    font-size:clamp(30px,5vw,42px); letter-spacing:-.02em; line-height:1.1; margin:0;
  }
  .wordmark span { color:var(--accent); }
  .facts { display:flex; flex-wrap:wrap; gap:8px 10px; }
  .fact {
    font-family:"IBM Plex Mono", ui-monospace, monospace; font-size:12px;
    border:1px solid var(--line-2); border-radius:3px; padding:2px 8px;
    color:var(--ink-2); background:var(--surface);
  }

  .cols { display:grid; grid-template-columns:1fr; gap:40px; padding-top:36px; }
  @media (min-width:940px) {
    .cols { grid-template-columns:216px minmax(0,1fr); gap:56px; }
    nav.toc { position:sticky; top:24px; align-self:start; max-height:calc(100vh - 48px); overflow-y:auto; }
  }
  nav.toc ol { list-style:none; margin:0; padding:0; display:grid; gap:2px; }
  nav.toc a {
    display:block; color:var(--ink-2); text-decoration:none; font-size:13.5px;
    padding:3px 0 3px 10px; border-left:2px solid var(--line);
  }
  nav.toc a:hover { color:var(--accent); border-left-color:var(--accent); }

  section { padding-block:8px 44px; scroll-margin-top:20px; }
  h2 {
    font-family:Archivo,"Noto Sans TC",sans-serif; font-size:23px; font-weight:600;
    letter-spacing:-.01em; margin:0 0 14px; text-wrap:balance; scroll-margin-top:20px;
  }
  h3 { font-size:16px; font-weight:700; margin:30px 0 10px; text-wrap:balance; scroll-margin-top:20px; }
  h4 { font-size:14.5px; font-weight:700; margin:22px 0 8px; color:var(--ink-2); scroll-margin-top:20px; }
  p { margin:0 0 14px; max-width:68ch; }
  ul, ol.list { margin:0 0 16px; padding-left:20px; max-width:68ch; }
  li { margin-bottom:5px; }
  a { color:var(--accent); }
  code {
    font-family:"IBM Plex Mono", ui-monospace, monospace; font-size:.88em;
    background:var(--surface-2); border-radius:3px; padding:1px 5px;
  }

  .term {
    background:var(--term-bg); border:1px solid var(--term-line);
    border-radius:6px; margin:0 0 18px; overflow:hidden;
  }
  .term .bar {
    font-family:"IBM Plex Mono", monospace; font-size:11px; letter-spacing:.08em;
    text-transform:uppercase; color:var(--term-dim); padding:7px 14px;
    border-bottom:1px solid var(--term-line);
  }
  .term pre {
    margin:0; padding:14px; overflow-x:auto;
    font-family:"IBM Plex Mono", ui-monospace, monospace;
    font-size:12.8px; line-height:1.65; color:var(--term-ink);
  }
  .term .c { color:var(--term-dim); }

  .tw { overflow-x:auto; margin:0 0 20px; border:1px solid var(--line); border-radius:6px; background:var(--surface); }
  table { border-collapse:collapse; width:100%; font-size:14px; }
  th {
    font-family:Archivo,"Noto Sans TC",sans-serif; font-size:11.5px; letter-spacing:.08em;
    text-transform:uppercase; color:var(--ink-3); text-align:left; font-weight:600;
    padding:10px 14px; border-bottom:1px solid var(--line); white-space:nowrap;
  }
  td { padding:10px 14px; border-bottom:1px solid var(--line); vertical-align:top; }
  tr:last-child td { border-bottom:none; }
  td code { background:none; padding:0; color:var(--accent-2); }
  .num { font-variant-numeric:tabular-nums; }

  .note {
    border-left:3px solid var(--line-2); padding:2px 0 2px 16px; margin:0 0 18px;
    color:var(--ink-2); max-width:66ch;
  }
  .note.warn { border-left-color:var(--warn); }
  .note.warn strong { color:var(--warn); }
  .note.stop { border-left-color:var(--bad); }
  .note.stop strong { color:var(--bad); }
  .note p:last-child { margin-bottom:0; }

  footer.end { border-top:1px solid var(--line); margin-top:20px; padding-top:22px; color:var(--ink-3); font-size:13px; }
  footer.end p { max-width:70ch; }
  :focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
  @media (prefers-reduced-motion: reduce) { * { animation:none !important; transition:none !important; } }
"""

PAGE = """<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700&family=IBM+Plex+Mono:wght@400;500&family=Noto+Sans+TC:wght@400;500;700&display=swap">
<style>{css}</style>
</head>
<body>
<div class="shell">
<header class="top">
  <h1 class="wordmark">{name} <span>使用手冊</span></h1>
  <div class="facts">{facts}</div>
</header>

<div class="cols">
<nav class="toc" aria-label="目錄"><ol>{toc}</ol></nav>
<main>
{body}
<footer class="end">
  <p>這一頁是 <strong>README.md</strong> 與 <strong>docs/</strong> 底下那幾份自動產生的
     （<code>tools/make_manual.py</code>）。內容要改請改那些 Markdown；專案方向與待確認清單
     在 <strong>ROADMAP.md</strong>。</p>
  <p style="margin-top:12px">{stamp}
     —— 這是產生它的那幾份來源的指紋。跟 repo 裡的內容對不上，就是這一頁落後了。</p>
</footer>
</main>
</div>
</div>
</body>
</html>
"""


def stamp_facts(md):
    """蓋上來源的指紋 —— 落後了要看得出來，而不是安靜地過期。

    這裡蓋的是 **接起來那份內容的 sha256**（README 加上 docs/ 那幾份），不是日期
    也不是 git commit。理由很實際：產出必須是可決定的，`--check` 才有意義。蓋日期
    的話這一頁每天都「不一樣」，蓋 commit 的話每次提交都不一樣 —— 那種檢查每次
    都失敗，等於沒有檢查。

    任何一份來源改了指紋就會變，所以「改了 docs/hub.md 但忘了重跑」一樣抓得到。
    """
    digest = hashlib.sha256(md.encode("utf-8")).hexdigest()[:12]
    version = "?"
    try:
        with open(os.path.join(ROOT, "hangar"), encoding="utf-8") as f:
            for line in f:
                m = re.match(r'^VERSION="([^"]+)"', line)
                if m:
                    version = m.group(1)
                    break
    except OSError:
        pass
    return ["來源 sha256 %s" % digest, "hangar v%s" % version]


def build(md):
    doc = convert(md)
    toc = "".join('<li><a href="#%s">%s</a></li>' % (a, html.escape(re.sub(r"`|\*\*", "", t)))
                  for _, t, a in doc.toc)
    facts = stamp_facts(md)
    return PAGE.format(
        title="%s 使用手冊" % doc.title,
        name=html.escape(doc.title),
        css=CSS,
        toc=toc,
        body=doc.html(),
        facts="".join('<span class="fact">%s</span>' % html.escape(f) for f in facts),
        stamp='<span class="fact">%s</span>' % html.escape(facts[0]),
    )


def main(argv=None):
    ap = argparse.ArgumentParser(description="從 README.md 與 docs/*.md 產生一頁使用手冊")
    ap.add_argument("--readme", default=os.path.join(ROOT, "README.md"),
                    help="入口那一份；docs/ 是相對它的位置找的")
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "manual.html"))
    ap.add_argument("--check", action="store_true",
                    help="只比對，產出跟現有檔案不一樣就回非 0（不寫檔）")
    args = ap.parse_args(argv)

    page = build(load(args.readme))

    if args.check:
        try:
            with open(args.out, encoding="utf-8") as f:
                same = f.read() == page
        except OSError:
            same = False
        if same:
            print("手冊是最新的：%s" % args.out)
            return 0
        print("手冊落後了，重跑 tools/make_manual.py", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(page)
    print("寫出 %s（%d KB）" % (args.out, len(page.encode()) // 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())

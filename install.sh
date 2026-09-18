#!/usr/bin/env bash
#
# install.sh — 把 hangar symlink 到 PATH 上
#
#   ./install.sh                 # 裝到 /usr/local/bin（需要時會用 sudo）
#   PREFIX=~/.local ./install.sh # 裝到 ~/.local/bin
#   ./install.sh --uninstall
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/hangar"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
DEST="$BIN_DIR/hangar"

if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=""; Y=""; R=""; D=""; N=""
fi
ok()   { printf '%s ok %s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s !! %s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s xx %s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# 需要 sudo 才能寫入目標目錄時，自動加上
run_priv() {
  if [ -w "$BIN_DIR" ] || { [ ! -d "$BIN_DIR" ] && [ -w "$(dirname "$BIN_DIR")" ]; }; then
    "$@"
  else
    warn "$BIN_DIR 需要管理者權限，使用 sudo"
    sudo "$@"
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ -L "$DEST" ] || [ -e "$DEST" ]; then
    run_priv rm -f "$DEST"
    ok "已移除 $DEST"
  else
    warn "$DEST 不存在，沒事可做"
  fi
  printf '%s設定檔仍保留在 %s，要一併刪除請自行執行：%s\n' "$D" "${XDG_CONFIG_HOME:-$HOME/.config}/hangar" "$N"
  printf '%s  rm -rf %s%s\n' "$D" "${XDG_CONFIG_HOME:-$HOME/.config}/hangar" "$N"
  exit 0
fi

[ -f "$SRC" ] || die "找不到 $SRC"
chmod +x "$SRC"

run_priv mkdir -p "$BIN_DIR"

if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  if [ -L "$DEST" ] && [ "$(readlink "$DEST")" = "$SRC" ]; then
    ok "已經連結到同一份檔案，略過"
  else
    warn "$DEST 已存在，覆蓋"
    run_priv ln -sfn "$SRC" "$DEST"
    ok "已更新 $DEST -> $SRC"
  fi
else
  run_priv ln -s "$SRC" "$DEST"
  ok "已建立 $DEST -> $SRC"
fi

# 舊名 pmirror 的 symlink：只有在它指向本專案時才清掉，避免誤刪別人的東西
LEGACY_DEST="$BIN_DIR/pmirror"
if [ -L "$LEGACY_DEST" ]; then
  case "$(readlink "$LEGACY_DEST")" in
    "$SRC_DIR"/*|*/pmirror)
      run_priv rm -f "$LEGACY_DEST"
      ok "已移除舊名 symlink $LEGACY_DEST" ;;
  esac
fi

# PATH 檢查
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR 不在 PATH 裡，請加到 shell 設定："
     printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" >&2 ;;
esac

# 依賴檢查（只提示，不強制）
echo
missing=""
command -v adb    >/dev/null 2>&1 || missing="$missing android-platform-tools"
command -v scrcpy >/dev/null 2>&1 || missing="$missing scrcpy"
command -v jq     >/dev/null 2>&1 || missing="$missing jq"
if [ -n "$missing" ]; then
  warn "還缺少相依套件："
  case "$missing" in
    *android-platform-tools*) printf '    brew install --cask android-platform-tools\n' >&2 ;;
  esac
  for p in scrcpy jq; do
    case "$missing" in *" $p"*) printf '    brew install %s\n' "$p" >&2 ;; esac
  done
else
  ok "adb / scrcpy / jq 都在"
fi
if ! command -v tailscale >/dev/null 2>&1 \
   && [ ! -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  warn "找不到 tailscale CLI：brew install tailscale（或安裝 Tailscale.app）"
fi

echo
ok "安裝完成。下一步（手機請先插 USB 或連到同一個 Wi-Fi）："
printf '    hangar setup\n'

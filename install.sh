#!/usr/bin/env bash
#===============================================================================
#  usb-bench 安装引导
#  用法: curl -fsSL <url>/install.sh | sudo bash
#        bash install.sh --sysinfo
#
#  作用: 依次尝试多个下载源, 校验内容确实是脚本后再安装执行。
#        防止网络劫持返回 HTML 页面时被当成脚本执行。
#===============================================================================
set -uo pipefail

MARK="USB 外置存储"
TARGET="/usr/local/bin/usb-bench"
TMP=""

say()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 60 "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=60 "$1" 2>/dev/null
  else
    return 127
  fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "缺少 curl 或 wget。请先安装： sudo apt update && sudo apt install -y curl"
fi

SOURCES=()
[[ -n "${USB_BENCH_URL:-}" ]] && SOURCES+=("$USB_BENCH_URL")
SOURCES+=(
  "https://cdn.jsdelivr.net/gh/SupportSpark/usb-bench@main/usb-bench.sh"
  "https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh"
  "https://ghproxy.net/https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh"
  "https://raw.gitmirror.com/SupportSpark/usb-bench/main/usb-bench.sh"
)

TMP=$(mktemp /tmp/usb-bench.XXXXXX) || die "无法创建临时文件"
GOT=""

for u in "${SOURCES[@]}"; do
  [[ -z "$u" ]] && continue
  printf '[ .. ] 尝试 %s\n' "$u"
  if fetch "$u" > "$TMP" 2>/dev/null; then
    if head -1 "$TMP" 2>/dev/null | grep -q 'bash' && grep -q "$MARK" "$TMP" 2>/dev/null; then
      GOT="$u"
      break
    else
      printf '       内容不是脚本（可能被网络劫持），跳过\n'
    fi
  else
    printf '       下载失败，跳过\n'
  fi
done

if [[ -z "$GOT" ]]; then
  rm -f "$TMP"
  printf '\n'
  die "所有下载源均不可用。

请检查网络后重试，或手动下载：
  https://github.com/SupportSpark/usb-bench

若本机可访问 GitHub，可指定源：
  export USB_BENCH_URL=<可用的脚本地址>
  再重新运行本命令"
fi

printf '[ OK ] 下载成功：%s\n' "$GOT"

if install -m 755 "$TMP" "$TARGET" 2>/dev/null \
   || { command -v sudo >/dev/null 2>&1 && sudo install -m 755 "$TMP" "$TARGET" 2>/dev/null; }; then
  printf '[ OK ] 已安装到 %s\n\n' "$TARGET"
else
  warn "无法写入 $TARGET，改为直接运行临时文件"
  TARGET="$TMP"
  chmod 755 "$TARGET" 2>/dev/null
fi

if [[ "$TARGET" != "$TMP" ]]; then rm -f "$TMP" 2>/dev/null || true; fi

if [[ "$(id -u)" -eq 0 ]]; then
  exec "$TARGET" "$@"
elif command -v sudo >/dev/null 2>&1; then
  exec sudo "$TARGET" "$@"
else
  die "需要 root 权限运行，请用 sudo"
fi

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
    curl -fsSL --connect-timeout 5 --max-time 15 "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=15 --tries=1 "$1" 2>/dev/null
  else
    return 127
  fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "缺少 curl 或 wget。请先安装： sudo apt update && sudo apt install -y curl"
fi

SOURCES=()
[[ -n "${USB_BENCH_URL:-}" ]] && SOURCES+=("$USB_BENCH_URL")
# raw 优先；jsDelivr 放在后面，因为它对 @main 的缓存会滞后数小时
SOURCES+=(
  "https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh"
  "https://ghproxy.net/https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh"
  "https://cdn.jsdelivr.net/gh/SupportSpark/usb-bench@main/usb-bench.sh"
  "https://raw.gitmirror.com/SupportSpark/usb-bench/main/usb-bench.sh"
)

TMP=$(mktemp /tmp/usb-bench.XXXXXX) || die "无法创建临时文件"
BEST=$(mktemp /tmp/usb-bench.best.XXXXXX) || die "无法创建临时文件"
GOT=""
BEST_VER=""

# 不取第一个成功的源: jsDelivr 对 @main 有缓存, 可能落后于 GitHub。
# 遍历所有源, 装版本号最高的那个。
for u in "${SOURCES[@]}"; do
  [[ -z "$u" ]] && continue
  printf '[ .. ] 尝试 %s\n' "$u"
  if fetch "$u" > "$TMP" 2>/dev/null; then
    if head -1 "$TMP" 2>/dev/null | grep -q 'bash' && grep -q "$MARK" "$TMP" 2>/dev/null; then
      v=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$TMP" 2>/dev/null | head -1)
      printf '       版本 %s\n' "${v:-未知}"
      if [[ -z "$BEST_VER" ]] || [[ "$(printf '%s\n%s\n' "$BEST_VER" "${v:-0}" | sort -V | tail -1)" == "${v:-0}" && "${v:-0}" != "$BEST_VER" ]]; then
        cp -f "$TMP" "$BEST" && BEST_VER="${v:-0}" && GOT="$u"
      fi
    else
      printf '       内容不是脚本（可能被网络劫持），跳过\n'
    fi
  else
    printf '       下载失败或超时，跳过\n'
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

printf '[ OK ] 选用 %s（v%s）\n' "$GOT" "$BEST_VER"

if install -m 755 "$BEST" "$TARGET" 2>/dev/null \
   || { command -v sudo >/dev/null 2>&1 && sudo install -m 755 "$BEST" "$TARGET" 2>/dev/null; }; then
  # 校验真正落盘的版本，避免"装了个旧的"
  INSTALLED=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$TARGET" 2>/dev/null | head -1)
  if [[ "$INSTALLED" != "$BEST_VER" ]]; then
    warn "安装后版本校验不符（期望 $BEST_VER，实际 ${INSTALLED:-未知}），改为直接运行下载的文件"
    TARGET="$BEST"
    chmod 755 "$TARGET" 2>/dev/null
  else
    printf '[ OK ] 已安装到 %s（v%s）\n\n' "$TARGET" "$INSTALLED"
  fi
else
  warn "无法写入 $TARGET，改为直接运行下载的文件"
  TARGET="$BEST"
  chmod 755 "$TARGET" 2>/dev/null
fi

if [[ "$TARGET" != "$TMP" ]]; then rm -f "$TMP" 2>/dev/null || true; fi
if [[ "$TARGET" != "$BEST" ]]; then rm -f "$BEST" 2>/dev/null || true; fi

if [[ "$(id -u)" -eq 0 ]]; then
  exec "$TARGET" "$@"
elif command -v sudo >/dev/null 2>&1; then
  exec sudo "$TARGET" "$@"
else
  die "需要 root 权限运行，请用 sudo"
fi

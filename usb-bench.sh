#!/usr/bin/env bash
#===============================================================================
#  usb-bench.sh  ·  v1.0
#  USB / UASP 外置存储 —— 链路极限速率一键测试 + 中文报告
#
#  适用: Ubuntu 26.04 Desktop / Debian 12+ / 主流 Linux 内核 5.15+
#  用法: sudo ./usb-bench.sh            交互菜单
#        sudo ./usb-bench.sh --auto     全自动跑完并生成报告
#        sudo ./usb-bench.sh -h         帮助
#===============================================================================
set -uo pipefail
LC_ALL=C

VERSION="1.5.0"
SELF=$(readlink -f "$0")

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'
  M=$'\033[35m'; C=$'\033[36m'; W=$'\033[97m'; DK=$'\033[2m'
  BD=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; M=""; C=""; W=""; DK=""; BD=""; N=""
fi

hr()   { printf '%s\n' "${DK}----------------------------------------------------------------------------${N}"; }
hr2()  { printf '%s\n' "${B}============================================================================${N}"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
inf()  { printf '  [ .. ] %s\n' "$*"; }
wrn()  { printf '  [WARN] %s\n' "$*"; }
err()  { printf '  [FAIL] %s\n' "$*"; }
die()  { err "$*"; exit 1; }
tit()  { printf '\n%s\n' "$*"; dash; }

# 交互读取：优先 /dev/tty，保证 curl | sudo bash 管道方式下菜单仍可用
ask() {
  local __a=""
  # 有控制终端就用 /dev/tty（管道执行时菜单仍可交互）；
  # 无控制终端（CI/无 tty 的 ssh）自动回退到 stdin，避免阻塞。
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    IFS= read -r __a <&3 || __a=""
    exec 3<&- 2>/dev/null
  else
    IFS= read -r __a || __a=""
  fi
  printf '%s' "$__a"
}

sata_ver_of() {
  local dev=$1 out
  out=$(smartctl -i "/dev/$dev" 2>/dev/null | grep -m1 -i 'SATA Version is' || true)
  [[ -z "$out" ]] && return 1
  printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+ Gb/s' | head -1 | awk '{print $1}'
}

media_type_of() {  # SSD | HDD（USB 桥常把 SSD 报成 rotational）
  local dev=$1 rota out
  rota=${D_ROTA[$dev]:-1}
  out=$(smartctl -i "/dev/$dev" 2>/dev/null | grep -i 'Rotation Rate' || true)
  if [[ "$out" == *"Solid State"* ]]; then printf 'SSD'; return 0; fi
  if [[ -n "$out" ]]; then printf 'HDD'; return 0; fi
  if [[ "$rota" == "0" ]]; then printf 'SSD'; else printf 'HDD'; fi
}


BASE_DIR="${USB_BENCH_HOME:-$HOME/.usb-bench}"
OUT_ROOT="${USB_BENCH_REPORTS:-$HOME/usb-bench-reports}"
MOUNT_ROOT="$BASE_DIR/mnt"
RUN_ID=""
OUT_DIR=""
LOG_FILE=""

DEV_LIST=()
declare -A D_SIZE D_MODEL D_SER D_SPEED D_DRIVER D_USBPATH D_ROTA D_SATA D_FS D_MP D_VIDPID D_USBVER D_TYPE
SEL=()

declare -A R_BW R_IOPS R_LAT
RESULT_KEYS=()

AUTO_MOUNT=1
MOUNTED_BY_US=()
FILE_GB=16
RUNTIME=30
IOENGINE="libaio"
DO_WRITE=1
QUICK=0
FULL=0
AUTO=0
DEVICE_FILTER=""
TEST_DIR_OVERRIDE=""
INCLUDE_NONUSB=0
SYSINFO_ONLY=0
UPDATE_ONLY=0
NO_SYSINFO=0
NO_INSTALL=0

#------------------------------ 依赖与环境 ------------------------------------
cmds_missing() {
  local c m=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || m+=("$c"); done
  printf '%s' "${m[*]:-}"
}

detect_pkg_mgr() {
  local m
  for m in apt-get dnf yum pacman zypper apk; do
    if command -v "$m" >/dev/null 2>&1; then
      case "$m" in
        apt-get) echo apt ;;
        yum)     echo dnf ;;
        *)       echo "$m" ;;
      esac
      return 0
    fi
  done
  echo none
}

pkg_for() {
  local cmd=$1 mgr=$2
  case "$mgr:$cmd" in
    apt:smartctl|dnf:smartctl|pacman:smartctl|zypper:smartctl|apk:smartctl) echo smartmontools ;;
    apt:lsusb|dnf:lsusb|pacman:lsusb|zypper:lsusb|apk:lsusb)                echo usbutils ;;
    apt:lspci|dnf:lspci|pacman:lspci|zypper:lspci|apk:lspci)                echo pciutils ;;
    apt:dmidecode|dnf:dmidecode|pacman:dmidecode|zypper:dmidecode|apk:dmidecode) echo dmidecode ;;
    apt:nvme|dnf:nvme|pacman:nvme|zypper:nvme|apk:nvme)                     echo nvme-cli ;;
    apt:iostat|dnf:iostat|pacman:iostat|zypper:iostat|apk:iostat)           echo sysstat ;;
    apt:bc|dnf:bc|pacman:bc|zypper:bc|apk:bc)                              echo bc ;;
    apt:curl|dnf:curl|pacman:curl|zypper:curl|apk:curl)                     echo curl ;;
    *)                                                                      echo "$cmd" ;;
  esac
}

pkg_install() {
  local mgr=$1; shift
  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq "$@" >/dev/null 2>&1
      ;;
    dnf)    dnf install -y -q "$@" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper) zypper -n install -y "$@" >/dev/null 2>&1 ;;
    apk)    apk add --no-cache "$@" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

DEP_REQUIRED="fio jq awk sed grep lsblk"
DEP_OPTIONAL="smartctl lsusb lspci dmidecode hdparm nvme"

ensure_deps() {
  local mgr miss_req miss_opt pkgs=() c seen=" " p rc=0
  mgr=$(detect_pkg_mgr)
  miss_req=$(cmds_missing $DEP_REQUIRED)
  miss_opt=$(cmds_missing $DEP_OPTIONAL)

  if [[ -z "$miss_req" && -z "$miss_opt" ]]; then
    ok "依赖齐全，无需安装"
    return 0
  fi

  if [[ -n "$miss_req" ]]; then wrn "缺少必需组件: $miss_req"; fi
  if [[ -n "$miss_opt" ]]; then inf "缺少可选组件: $miss_opt（将尝试补装，失败则降级运行）"; fi

  if [[ "$mgr" == "none" ]]; then
    if [[ -n "$miss_req" ]]; then
      err "未识别包管理器，且缺少必需组件: $miss_req"
      err "请手动安装 fio 与 jq 后重试"
      return 1
    fi
    wrn "未识别包管理器，跳过可选组件安装，继续运行"
    return 0
  fi

  inf "自动安装依赖中（包管理器: $mgr），首次可能需要 1-2 分钟…"
  for c in $miss_req $miss_opt; do
    p=$(pkg_for "$c" "$mgr")
    if [[ "$seen" != *" $p "* ]]; then seen="$seen$p "; pkgs+=("$p"); fi
  done

  if (( ${#pkgs[@]} > 0 )); then
    pkg_install "$mgr" "${pkgs[@]}" || wrn "安装命令返回非零（部分包可能已失败）"
  fi

  miss_req=$(cmds_missing $DEP_REQUIRED)
  if [[ -n "$miss_req" ]]; then
    err "必需组件仍未就绪: $miss_req"
    err "请手动安装后重试："
    case "$mgr" in
      apt)    err "  sudo apt update && sudo apt install -y fio jq" ;;
      dnf)    err "  sudo dnf install -y fio jq" ;;
      pacman) err "  sudo pacman -S fio jq" ;;
      zypper) err "  sudo zypper install -y fio jq" ;;
      apk)    err "  sudo apk add fio jq" ;;
    esac
    rc=1
  else
    ok "必需组件就绪"
  fi

  miss_opt=$(cmds_missing $DEP_OPTIONAL)
  if [[ -n "$miss_opt" ]]; then
    wrn "以下可选组件缺失，相关功能将降级: $miss_opt"
  else
    ok "可选组件就绪"
  fi
  return $rc
}

#------------------------------ 链路理论值 ------------------------------------
link_theory() {
  case "$1" in
    1.5)   echo "USB 1.1 LS|0.0015|0.19|0.15"   ;;
    12)    echo "USB 1.1 FS|0.012|1.5|1.1"      ;;
    480)   echo "USB 2.0 HS|0.48|60|43"         ;;
    5000)  echo "USB 3.2 Gen1|5|625|450"        ;;
    10000) echo "USB 3.2 Gen2|10|1250|1050"     ;;
    20000) echo "USB 3.2 Gen2x2|20|2500|2000"   ;;
    *)     echo "未知|0|0|0"                    ;;
  esac
}
lt() { link_theory "$1" | cut -d'|' -f"$2"; }

sata_ref() {
  case "$1" in
    6.0) echo 550 ;; 3.0) echo 270 ;; 1.5) echo 130 ;; *) echo 550 ;;
  esac
}

#------------------------------ 系统与硬件信息 --------------------------------
pcie_lane_mbps() {
  case "$1" in
    2.5GT/s) echo 250 ;; 5GT/s) echo 500 ;; 8GT/s) echo 985 ;;
    16GT/s)  echo 1969 ;; 32GT/s) echo 3938 ;; 64GT/s) echo 7877 ;;
    *)       echo 0 ;;
  esac
}

gpu_summary() {
  local out=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    out=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -4 | paste -sd '; ' -)
  fi
  if [[ -z "$out" ]] && command -v lspci >/dev/null 2>&1; then
    out=$(lspci 2>/dev/null | grep -E 'VGA compatible|3D controller|Display controller' | sed 's/^[0-9a-fA-F:.]* //' | paste -sd '; ' -)
  fi
  printf '%s' "$out"
}

mem_summary() {
  local total used avail swap cnt speed
  total=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
  used=$(free -m | awk '/^Mem:/{printf "%.1f", $3/1024}')
  avail=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
  swap=$(awk '/SwapTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
  printf '共 %s GB · 已用 %s GB · 可用 %s GB · Swap %s GB' "$total" "$used" "$avail" "$swap"

  if command -v dmidecode >/dev/null 2>&1; then
    cnt=$(dmidecode -t 17 2>/dev/null | grep -c '^[[:space:]]*Size:.*[0-9]')
    speed=$(dmidecode -t 17 2>/dev/null | grep -m1 '^[[:space:]]*Speed:' | sed 's/.*: *//')
    if [[ "$cnt" -gt 0 ]]; then
      printf ' · %s 条内存' "$cnt"
      if [[ -n "$speed" && "$speed" != "Unknown" ]]; then printf ' @ %s' "$speed"; fi
    fi
  fi
}

cpu_summary() {
  local model threads cores maxmhz
  model=$(awk -F: '/model name/{gsub(/^ +/,"",$2);print $2;exit}' /proc/cpuinfo)
  threads=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  cores=$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2);print $2}' | head -1)
  maxmhz=$(lscpu 2>/dev/null | awk -F: '/CPU max MHz/{gsub(/ /,"",$2);print $2}' | head -1)
  local sock
  sock=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}' | head -1)
  printf '%s' "$model"
  printf ' · %s 线程' "$threads"
  if [[ -n "$sock" && "$sock" != "1" ]]; then printf ' · %s 路 × %s 核' "$sock" "${cores:-?}"; fi
  if [[ -n "$maxmhz" ]]; then printf ' · 最高 %s MHz' "$(printf '%.0f' "$maxmhz")"; fi
}

pcie_rows() {  # 输出 slot|desc|speed|width|totalMBs
  command -v lspci >/dev/null 2>&1 || return 1
  local line slot desc info sp wd lane tot
  while IFS= read -r line; do
    slot=${line%% *}
    desc=${line#* }
    info=$(lspci -vv -s "$slot" 2>/dev/null)
    sp=$(grep -m1 'LnkSta:' <<<"$info" | grep -oE '[0-9.]+GT/s' | head -1)
    wd=$(grep -m1 'LnkSta:' <<<"$info" | grep -oE 'Width x[0-9]+' | head -1 | grep -oE '[0-9]+$')
    [[ -z "$sp" ]] && continue
    lane=$(pcie_lane_mbps "$sp")
    tot=$(( lane * ${wd:-1} ))
    printf '%s|%s|%s|x%s|%s\n' "$slot" "${desc:0:46}" "$sp" "${wd:-?}" "$tot"
  done < <(lspci 2>/dev/null | grep -iE 'usb controller|non-volatile memory')
}

system_info_scan() {
  SYS_OS=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo Linux )
  SYS_KERNEL=$(uname -r)
  SYS_ARCH=$(uname -m)
  SYS_HOST=$(hostname)
  SYS_UPTIME=$(awk '{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
      if(d>0) printf "%d 天 %d 小时", d, h; else if(h>0) printf "%d 小时 %d 分", h, m; else printf "%d 分", m}' /proc/uptime 2>/dev/null || echo "?")
  SYS_LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
  SYS_CPU=$(cpu_summary)
  SYS_MEM=$(mem_summary)
  SYS_GPU=$(gpu_summary)
  SYS_MB_VENDOR=""; SYS_MB_MODEL=""; SYS_BIOS=""
  if command -v dmidecode >/dev/null 2>&1; then
    SYS_MB_VENDOR=$(dmidecode -s baseboard-manufacturer 2>/dev/null || true)
    SYS_MB_MODEL=$(dmidecode -s baseboard-product-name 2>/dev/null || true)
    SYS_BIOS=$(dmidecode -s bios-version 2>/dev/null || true)
    local bd
    bd=$(dmidecode -s bios-release-date 2>/dev/null || true)
    [[ -n "$bd" ]] && SYS_BIOS="$SYS_BIOS ($bd)"
  fi
  SYS_PCIE=$(pcie_rows)
  SYS_NVME_CTRL=""
  if command -v nvme >/dev/null 2>&1; then
    SYS_NVME_CTRL=$(nvme list 2>/dev/null | tail -n +3 | awk '{printf "%s %s %s; ", $1, $2, $3}' || true)
  fi
}

#------------------------------ 文本排版辅助 ----------------------------------
str_width() {  # 计算字符串显示宽度（ASCII=1，中文/emoji=2）
  local s=$1 b c
  b=${#s}
  c=$(printf '%s' "$s" | LC_ALL=C.utf8 wc -m 2>/dev/null)
  [[ -z "$c" ]] && c=$b
  printf '%d' $(( (b + c) / 2 ))
}

pad_to() {  # 内容 目标显示宽度
  local s=$1 target=$2 w pad
  w=$(str_width "$s")
  pad=$(( target - w ))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ""
}

dash() { printf '%s\n' "--------------------------------"; }

kv_line() {  # 标签 值 [目标宽度]
  local k=$1 v=$2 t=${3:-20} pad
  pad=$(( t - $(str_width "$k:") ))
  (( pad < 1 )) && pad=1
  printf '%s%*s%s\n' "$k:" "$pad" "" "$v"
}

#------------------------------ 指标采集 --------------------------------------
cpu_usage_pct() {
  local t1 i1 t2 i2 dt di
  read -r t1 i1 < <(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
  sleep 0.3
  read -r t2 i2 < <(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
  dt=$(( t2 - t1 )); di=$(( i2 - i1 ))
  if (( dt > 0 )); then printf '%d' $(( (dt - di) * 100 / dt )); else printf '0'; fi
}

fmt_bytes() {
  awk -v b="$1" 'BEGIN{
    if (b >= 1073741824) printf "%.2fG", b/1073741824;
    else if (b >= 1048576) printf "%.2fM", b/1048576;
    else printf "%.0fK", b/1024 }'
}

mem_stats() {  # 已用M 总量M 百分比
  awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{
    if (t>0) printf "%.0f %.0f %.0f", (t-a)/1024, t/1024, (t-a)*100/t;
    else printf "0 0 0" }' /proc/meminfo
}

swap_stats() {
  awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{
    if (t>0) printf "%.0f %.0f %.0f", (t-f)/1024, t/1024, (t-f)*100/t;
    else printf "0 0 0" }' /proc/meminfo
}

disk_stats() {  # 已用G 总量G 百分比
  df -B1 --output=used,size / 2>/dev/null | tail -1 | awk '{
    if ($2>0) printf "%.1f %.1f %.0f", $1/1073741824, $2/1073741824, $1*100/$2;
    else printf "0 0 0" }'
}

conn_stats() {  # TCP UDP
  local t u
  t=$(( $(wc -l < /proc/net/tcp) - 1 ))
  u=$(( $(wc -l < /proc/net/udp) - 1 ))
  (( t < 0 )) && t=0
  (( u < 0 )) && u=0
  printf '%d|%d' "$t" "$u"
}

net_totals() {  # 接收字节 发送字节
  awk 'NR>2 { rx += $2; tx += $10 } END { printf "%d %d", rx, tx }' /proc/net/dev
}

net_algo() {
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "-")
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "-")
  printf '%s %s' "$cc" "$qd"
}

ipv4_addr() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ -z "$ip" ]]; then ip=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
  printf '%s' "${ip:-未知}"
}

dns_list() {
  local d
  d=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
  d=${d% }
  printf '%s' "${d:-无}"
}

uptime_cn() {
  awk '{ s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
    if (d>0) printf "%d天 %d时 %d分", d, h, m;
    else if (h>0) printf "%d时 %d分", h, m;
    else printf "%d分", m }' /proc/uptime
}

cpu_freq_ghz() {
  local a b m
  a=$(lscpu 2>/dev/null | awk -F: '/CPU max MHz/{gsub(/ /,"",$2); print $2}' | head -1)
  b=$(awk -F':' '/cpu MHz/{gsub(/ /,"",$2); if ($2+0 > mx) mx=$2+0} END{if (mx>0) printf "%.0f", mx}' /proc/cpuinfo 2>/dev/null)
  m=$(awk -v a="${a:-0}" -v b="${b:-0}" 'BEGIN{x = (a+0 > b+0) ? a+0 : b+0; printf "%.0f", x}')
  if [[ -z "$m" || "$m" == "0" ]]; then printf '未知'; return; fi
  awk -v m="$m" 'BEGIN{printf "%.2f GHz", m/1000}'
}

show_system_info() {
  local fmt=${1:-text}
  system_info_scan

  if [[ "$fmt" == "md" ]]; then
    echo "| 项目 | 内容 |"
    echo "|---|---|"
    echo "| 主机名 | $(md_escape "$SYS_HOST") |"
    echo "| 操作系统 | $(md_escape "$SYS_OS") |"
    echo "| 内核 | $SYS_KERNEL ($SYS_ARCH) |"
    echo "| 运行时长 | $SYS_UPTIME · 负载 $SYS_LOAD |"
    echo "| CPU | $(md_escape "$SYS_CPU") |"
    echo "| 内存 | $(md_escape "$SYS_MEM") |"
    echo "| 显卡 | $(md_escape "${SYS_GPU:-未检测到独立/集成显卡}") |"
    if [[ -n "$SYS_MB_MODEL" ]]; then
      echo "| 主板 | $(md_escape "$SYS_MB_VENDOR $SYS_MB_MODEL") |"
    fi
    if [[ -n "$SYS_BIOS" ]]; then
      echo "| BIOS | $(md_escape "$SYS_BIOS") |"
    fi
    return 0
  fi

  local cpu_model cpu_cores cpu_freq cpu_use
  local mem_u mem_t mem_p sw_u sw_t sw_p dk_u dk_t dk_p
  local rx tx conn
  cpu_model=$(awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
  cpu_cores=$(nproc 2>/dev/null || echo 1)
  cpu_freq=$(cpu_freq_ghz)
  cpu_use=$(cpu_usage_pct)
  read -r mem_u mem_t mem_p <<<"$(mem_stats)"
  read -r sw_u sw_t sw_p <<<"$(swap_stats)"
  read -r dk_u dk_t dk_p <<<"$(disk_stats)"
  read -r rx tx <<<"$(net_totals)"
  conn=$(conn_stats)

  printf '\n系统信息查询\n'
  dash
  kv_line "主机名" "$SYS_HOST"
  kv_line "系统版本" "$SYS_OS"
  kv_line "Linux版本" "$SYS_KERNEL"
  kv_line "系统架构" "$SYS_ARCH"
  dash
  kv_line "CPU型号" "${cpu_model:-未知}"
  kv_line "CPU核心数" "$cpu_cores"
  kv_line "CPU频率" "$cpu_freq"
  kv_line "CPU占用" "${cpu_use}%"
  kv_line "系统负载" "$SYS_LOAD"
  dash
  kv_line "TCP|UDP连接数" "$conn"
  kv_line "物理内存" "${mem_u}M/${mem_t}M (${mem_p}%)"
  kv_line "虚拟内存" "${sw_u}M/${sw_t}M (${sw_p}%)"
  kv_line "硬盘占用" "${dk_u}G/${dk_t}G (${dk_p}%)"
  dash
  kv_line "总接收" "$(fmt_bytes "$rx")"
  kv_line "总发送" "$(fmt_bytes "$tx")"
  dash
  kv_line "网络算法" "$(net_algo)"
  dash
  kv_line "IPv4地址" "$(ipv4_addr)"
  kv_line "DNS地址" "$(dns_list)"
  kv_line "系统时间" "$(date +'%Z %Y-%m-%d %H:%M')"
  dash
  kv_line "运行时长" "$(uptime_cn)"
  dash
  printf '\n'

  printf '硬件信息\n'
  dash
  kv_line "显卡" "${SYS_GPU:-未检测到}"
  if [[ -n "$SYS_MB_MODEL" ]]; then
    kv_line "主板" "$SYS_MB_VENDOR $SYS_MB_MODEL"
  else
    kv_line "主板" "未知"
  fi
  kv_line "BIOS" "${SYS_BIOS:-未知}"
  dash
  printf '\n'

  printf '存储设备\n'
  dash
  printf '%s%s%s%s%s%s\n' \
    "$(pad_to "设备" 8)" "$(pad_to "型号" 30)" "$(pad_to "容量" 10)" \
    "$(pad_to "类型" 6)" "$(pad_to "总线" 7)" "挂载点"
  local d nm sz md rota tran mnt typ
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    nm=$(kv NAME "$d"); sz=$(kv SIZE "$d"); md=$(kv MODEL "$d")
    rota=$(kv ROTA "$d"); tran=$(kv TRAN "$d"); mnt=$(kv MOUNTPOINTS "$d")
    case "$nm" in loop*|sr*) continue ;; esac
    typ=${D_TYPE[$nm]:-HDD}
    [[ -z "$mnt" ]] && mnt="-"
    printf '%s%s%s%s%s%s\n' \
      "$(pad_to "$nm" 8)" "$(pad_to "${md:0:30}" 30)" "$(pad_to "$sz" 10)" \
      "$(pad_to "$typ" 6)" "$(pad_to "${tran:-?}" 7)" "$mnt"
  done < <(lsblk -d -P -n -o NAME,SIZE,MODEL,ROTA,TRAN,MOUNTPOINTS 2>/dev/null)
  dash
  printf '\n'

  printf 'PCIe 链路\n'
  dash
  local rows
  rows=$(pcie_rows)
  if [[ -z "$rows" ]]; then
    printf '未发现 USB 控制器或 NVMe 桥（lspci 不可用）\n'
  else
    local slot desc sp wd tot
    while IFS='|' read -r slot desc sp wd tot; do
      [[ -z "$slot" ]] && continue
      printf '%s  %s\n' "$slot" "$desc"
      printf '           协商 %s x%s，可用带宽 %s MB/s\n' "$sp" "$wd" "$tot"
      if (( tot > 0 && tot < 1050 )); then
        printf '           注意: 该控制器 PCIe 上行低于单口 10Gbps(1050 MB/s)，插 10Gbps 设备也跑不满\n'
      elif (( tot >= 1050 && tot < 2000 )); then
        printf '           注意: 上行约 %s MB/s，双口 10Gbps 同时满载(约2100 MB/s)会受限\n' "$tot"
      fi
    done <<<"$rows"
  fi
  dash
  printf '\n'
}


#------------------------------ sysfs 探测 ------------------------------------
kv() {
  local k=$1 s=$2 re
  re="(^| )${k}=\"([^\"]*)\""
  if [[ $s =~ $re ]]; then printf '%s' "${BASH_REMATCH[2]}"; fi
}

usb_dev_dir() {
  local dev=$1 p
  p=$(readlink -f "/sys/block/$dev" 2>/dev/null) || return 1
  while [[ -n "$p" && "$p" != "/" ]]; do
    if [[ -f "$p/speed" && -f "$p/idVendor" ]]; then printf '%s' "$p"; return 0; fi
    p=$(dirname "$p")
  done
  return 1
}

first_mount_of() {
  local dev=$1 m
  while IFS= read -r m; do
    if [[ -n "$m" ]]; then printf '%s' "$m"; return 0; fi
  done < <(lsblk -n -o MOUNTPOINTS "/dev/$dev" 2>/dev/null)
  return 1
}

first_partition() {
  local dev=$1 p
  p=$(lsblk -P -n -o NAME,TYPE "/dev/$dev" 2>/dev/null | awk '/TYPE="part"/{print $1; exit}')
  p=${p#NAME=\"}; p=${p%\"}
  if [[ -n "$p" ]]; then printf '%s' "$p"; fi
  return 0
}

fs_of() {  # 文件系统类型，blkid 失败时回退 lsblk
  local t
  t=$(blkid -o value -s TYPE "/dev/$1" 2>/dev/null | head -1)
  if [[ -z "$t" ]]; then
    t=$(lsblk -P -n -o FSTYPE "/dev/$1" 2>/dev/null | sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p' | head -1)
  fi
  printf '%s' "$t"
}

enumerate_devices() {
  DEV_LIST=(); SEL=()
  local line name tran type usbdir drv part mp
  while IFS= read -r line; do
    name=$(kv NAME "$line"); type=$(kv TYPE "$line"); tran=$(kv TRAN "$line")
    [[ "$type" == "disk" ]] || continue
    if [[ "$tran" != "usb" && "$INCLUDE_NONUSB" -ne 1 ]]; then continue; fi
    if [[ -n "$DEVICE_FILTER" ]] && [[ " $DEVICE_FILTER " != *" ${name} "* ]]; then continue; fi

    DEV_LIST+=("$name")
    D_SIZE[$name]=$(kv SIZE "$line")
    D_MODEL[$name]=$(kv MODEL "$line")
    D_SER[$name]=$(kv SERIAL "$line")
    D_ROTA[$name]=$(kv ROTA "$line")

    usbdir=$(usb_dev_dir "$name") || usbdir=""
    if [[ -n "$usbdir" ]]; then
      D_SPEED[$name]=$(cat "$usbdir/speed" 2>/dev/null || echo 0)
      D_USBPATH[$name]=$(basename "$usbdir")
      D_VIDPID[$name]="0x$(cat "$usbdir/idVendor" 2>/dev/null):0x$(cat "$usbdir/idProduct" 2>/dev/null)"
      D_USBVER[$name]=$(cat "$usbdir/version" 2>/dev/null || echo "?")
    else
      D_SPEED[$name]=0; D_USBPATH[$name]="?"; D_VIDPID[$name]="?"; D_USBVER[$name]="?"
    fi

    drv=$(udevadm info -q property -n "/dev/$name" 2>/dev/null | sed -n 's/^ID_USB_DRIVER=//p')
    if [[ -n "$drv" ]]; then D_DRIVER[$name]=$drv; else D_DRIVER[$name]="unknown"; fi

    part=$(first_partition "$name" || true)
    if [[ -z "$part" ]]; then part=$name; fi
    D_FS[$name]=$(fs_of "$part")
    mp=$(first_mount_of "$name" || true)
    D_MP[$name]="$mp"
    D_SATA[$name]=$(sata_ver_of "$name" || true)
    D_TYPE[$name]=$(media_type_of "$name")
  done < <(lsblk -P -d -b -o NAME,TYPE,SIZE,TRAN,ROTA,MODEL,SERIAL 2>/dev/null)

  local d
  for d in "${DEV_LIST[@]:-}"; do [[ -n "$d" ]] && SEL+=("$d"); done
  return 0
}

human_size() {
  local b=${1:-0}
  if   (( b >= 1000000000000 )); then awk -v b="$b" 'BEGIN{printf "%.2f TB", b/1e12}'
  elif (( b >= 1000000000 ))   ; then awk -v b="$b" 'BEGIN{printf "%.0f GB", b/1e9}'
  else                                awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1e6}'
  fi
}

speed_label() {
  case "${1:-0}" in
    5000)  printf '5Gbps' ;;
    10000) printf '10Gbps' ;;
    20000) printf '20Gbps' ;;
    480)   printf '480Mbps' ;;
    *)     printf '%s' "${1:-?}" ;;
  esac
}

drv_label() {
  if [[ "$1" == "uas" ]]; then printf 'UASP'; else printf '%s' "$1"; fi
}

list_devices() {
  printf '\n'
  printf '%s%s%s%s%s%s%s%s\n' \
    "$(pad_to "序号" 6)" "$(pad_to "设备" 8)" "$(pad_to "型号" 30)" \
    "$(pad_to "容量" 10)" "$(pad_to "USB链路" 9)" "$(pad_to "驱动" 6)" \
    "$(pad_to "SATA" 8)" "$(pad_to "选中" 6)"
  dash
  local i=1 d mark
  for d in "${DEV_LIST[@]:-}"; do
    [[ -z "$d" ]] && continue
    mark="-"
    if [[ " ${SEL[*]:-} " == *" $d "* ]]; then mark="*"; fi
    printf '%s%s%s%s%s%s%s%s\n' \
      "$(pad_to "[$i]" 6)" "$(pad_to "$d" 8)" "$(pad_to "${D_MODEL[$d]:0:30}" 30)" \
      "$(pad_to "$(human_size "${D_SIZE[$d]:-0}")" 10)" \
      "$(pad_to "$(speed_label "${D_SPEED[$d]:-0}")" 9)" \
      "$(pad_to "$(drv_label "${D_DRIVER[$d]:-?}")" 6)" \
      "$(pad_to "${D_SATA[$d]:-未知}" 8)" \
      "$(pad_to "$mark" 6)"
    i=$((i+1))
  done
  if [[ ${#DEV_LIST[@]} -eq 0 ]]; then wrn "未发现任何 USB 存储设备"; fi
  dash
  printf '共 %d 块设备，已选 %d 块\n' "${#DEV_LIST[@]}" "${#SEL[@]}"
}

#------------------------------ 拓扑审计 --------------------------------------
audit_topology() {
  printf 'USB 拓扑审计\n'
  dash
  if [[ ${#DEV_LIST[@]} -eq 0 ]]; then wrn "无 USB 存储设备"; return; fi

  printf '%s%s%s%s%s%s%s%s%s\n' \
    "$(pad_to "设备" 7)" "$(pad_to "型号" 30)" "$(pad_to "容量" 10)" \
    "$(pad_to "USB" 7)" "$(pad_to "链路世代" 15)" "$(pad_to "SATA" 9)" \
    "$(pad_to "驱动" 9)" "$(pad_to "端口" 8)" "UASP"
  dash
  local d uasp
  for d in "${DEV_LIST[@]}"; do
    uasp="否"
    [[ "${D_DRIVER[$d]:-}" == "uas" ]] && uasp="是"
    printf '%s%s%s%s%s%s%s%s%s\n' \
      "$(pad_to "$d" 7)" "$(pad_to "${D_MODEL[$d]:0:30}" 30)" \
      "$(pad_to "$(human_size "${D_SIZE[$d]:-0}")" 10)" \
      "$(pad_to "${D_USBVER[$d]:-?}" 7)" "$(pad_to "$(lt "${D_SPEED[$d]:-0}" 1)" 15)" \
      "$(pad_to "${D_SATA[$d]:-未知}" 9)" "$(pad_to "${D_DRIVER[$d]:-?}" 9)" \
      "$(pad_to "${D_USBPATH[$d]:-?}" 8)" "$uasp"
  done
  dash
  printf '\n'

  printf 'USB 控制器与端口树 (lsusb -t)\n'
  dash
  local lsub=""
  if command -v lsusb >/dev/null 2>&1; then
    lsub=$(lsusb -t 2>/dev/null)
  fi
  if [[ -n "$lsub" ]]; then
    printf '%s\n' "$lsub" | sed 's/^/   /'
  else
    printf '   无 USB 总线信息（虚拟机或未启用 USB 控制器）\n'
  fi
  printf '\n'

  printf 'USB 控制器 PCI 设备\n'
  dash
  local lpc=""
  if command -v lspci >/dev/null 2>&1; then
    lpc=$(lspci -nn 2>/dev/null | grep -iE 'usb|xhci')
  fi
  if [[ -n "$lpc" ]]; then
    printf '%s\n' "$lpc" | sed 's/^/   /'
  else
    printf '   无 USB 控制器\n'
  fi
  printf '\n'

  printf '诊断结论\n'
  dash
  local sp any=0
  for d in "${DEV_LIST[@]}"; do
    sp=${D_SPEED[$d]:-0}
    if [[ "$sp" -gt 0 && "${D_DRIVER[$d]:-}" != "uas" ]]; then
      printf '   %s: 走 BOT 协议（非 UASP），通常损失 15~30%% 带宽\n' "$d"; any=1
    fi
    if [[ "$sp" == "480" ]]; then
      printf '   %s: 插在 USB 2.0 端口，上限仅 43 MB/s，请换 USB3 口或换线\n' "$d"; any=1
    fi
    if [[ "${D_SATA[$d]:-6.0}" == "6.0" && "$sp" == "10000" ]]; then
      printf '   %s: SATA 6Gbps(约550MB/s) 低于 USB 10Gbps(约1050MB/s)，单盘跑不满链路属正常\n' "$d"; any=1
    fi
  done
  # 控制器/集线器有 10Gbps 能力，但设备只协商到 5Gbps
  local l10=0 n5=0
  if command -v lsusb >/dev/null 2>&1 && lsusb -t 2>/dev/null | grep -q '10000M'; then l10=1; fi
  for d in "${DEV_LIST[@]}"; do
    [[ "${D_SPEED[$d]:-0}" == "5000" ]] && n5=$((n5+1))
  done
  if (( l10 == 1 && n5 > 0 )); then
    printf '   有 %d 块设备协商在 5Gbps，而系统存在 10Gbps 端口/集线器\n' "$n5"
    printf '   若硬盘盒标称 10Gbps，检查：线材是否 USB3.2 Gen2、是否插在 10Gbps 口、桥接芯片型号\n'
    any=1
  fi
  (( any == 0 )) && printf '   未发现明显配置问题\n'
  dash
  printf '\n'
}

#------------------------------ 挂载 / 测试目录 --------------------------------
cleanup_mounts() {
  local m
  for m in "${MOUNTED_BY_US[@]:-}"; do
    if [[ -n "$m" ]]; then umount "$m" 2>/dev/null && rmdir "$m" 2>/dev/null; fi
  done
  MOUNTED_BY_US=()
}

# 解析可测试目标
#   rc=0 输出目录路径（文件级测试）
#   rc=2 无文件系统（应改用裸设备只读测试）
#   rc=1 不可测试
# 所有诊断走 stderr，避免被 $( ) 吞掉
test_dir_for() {
  local d=$1 mnt part fst err
  if [[ -n "$TEST_DIR_OVERRIDE" ]]; then printf '%s' "$TEST_DIR_OVERRIDE"; return 0; fi

  mnt=$(first_mount_of "$d" || true)
  if [[ -n "$mnt" ]]; then
    if [[ -w "$mnt" ]]; then printf '%s' "$mnt"; return 0; fi
    printf '  [WARN] /dev/%s 挂载点 %s 不可写\n' "$d" "$mnt" >&2
    return 1
  fi

  if [[ "$AUTO_MOUNT" -ne 1 ]]; then
    printf '  [WARN] /dev/%s 未挂载，且已禁用自动挂载（--no-mount）\n' "$d" >&2
    return 1
  fi

  part=$(first_partition "$d" || true)
  [[ -z "$part" ]] && part="$d"
  fst=$(fs_of "$part" || true)

  mnt="$MOUNT_ROOT/$d"
  mkdir -p "$mnt"

  # 先按已知类型挂载，未知类型交给内核自动探测
  if [[ -n "$fst" ]]; then
    if mount -t "$fst" -o noatime "/dev/$part" "$mnt" 2>/tmp/.ub_mnt_err; then
      MOUNTED_BY_US+=("$mnt"); printf '%s' "$mnt"; return 0
    fi
  else
    if mount -o noatime "/dev/$part" "$mnt" 2>/tmp/.ub_mnt_err; then
      MOUNTED_BY_US+=("$mnt"); printf '%s' "$mnt"; return 0
    fi
  fi

  err=$(head -2 /tmp/.ub_mnt_err 2>/dev/null | tr '\n' ' ')
  rm -f /tmp/.ub_mnt_err 2>/dev/null

  if [[ -z "$fst" ]]; then
    printf '  [WARN] /dev/%s 没有可识别的文件系统（未格式化或裸盘）\n' "$d" >&2
    printf '         将改为裸设备只读测试（不写入，不破坏数据）\n' >&2
    return 2
  fi

  printf '  [WARN] /dev/%s 挂载失败: %s\n' "$d" "${err:-未知原因}" >&2
  if [[ "$fst" == "ntfs" ]] && ! command -v ntfs-3g >/dev/null 2>&1; then
    printf '         请先安装 ntfs-3g: sudo apt install -y ntfs-3g\n' >&2
  fi
  return 1
}

avail_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

plan_file_size() {
  local dir=$1 avail cap
  avail=$(avail_gb "$dir"); avail=${avail:-0}
  if (( avail < 2 )); then echo 0; return; fi
  cap=$(( avail * 80 / 100 ))
  if (( cap > FILE_GB )); then cap=$FILE_GB; fi
  if (( cap < 2 )); then cap=2; fi
  echo "$cap"
}

#------------------------------ fio 执行 --------------------------------------
pick_engine() {
  if fio --enghelp 2>/dev/null | grep -qw io_uring; then IOENGINE="io_uring"; else IOENGINE="libaio"; fi
}

fio_bw()   { jq -r --arg k "$2" '[.jobs[]|.[$k].bw_bytes]|add//0|./1048576' <<<"$1" 2>/dev/null | head -1; }
fio_iops() { jq -r --arg k "$2" '[.jobs[]|.[$k].iops]|add//0' <<<"$1" 2>/dev/null | head -1; }
fio_lat()  { jq -r --arg k "$2" '[.jobs[]|.[$k].lat_ns.mean//0]|if length>0 then (add/length/1000) else 0 end' <<<"$1" 2>/dev/null | head -1; }

record() {
  local k="$1|$2"
  R_BW[$k]=$3; R_IOPS[$k]=$4; R_LAT[$k]=$5
  RESULT_KEYS+=("$k")
  printf '%s\n' "$1|$2|$3|$4|$5" >> "$OUT_DIR/results.txt"
}

show_result() {
  local bw=${2:-0} extra=""
  printf '   %s%10.1f MB/s %8s IOPS %8s us' "$(pad_to "$1" 22)" "$bw" "${3%.*}" "${4%.*}"
  if [[ -n "${5:-}" ]] && (( ${5%.*} > 0 )); then
    local pct
    pct=$(awk -v a="$bw" -v b="$5" 'BEGIN{p=a*100/b; if(p>100)p=100; printf "%.0f", p}')
    printf '   达成 %3s%%' "$pct"
  fi
  printf '\n'
}

set_fio_tgt() {  # dev path kind size -> 全局 FIO_TGT
  FIO_TGT=()
  if [[ "$3" == "raw" ]]; then
    FIO_TGT=("--filename=/dev/$1" "--time_based=1" "--runtime=$RUNTIME")
  else
    FIO_TGT=("--filename=$2/.usb_bench_$1.dat" "--size=${4}G")
  fi
}

bench_sequential() {  # dev path size kind
  local d=$1 dir=$2 size=$3 kind=$4 f j bw io lat cur=0
  f="$dir/.usb_bench_$d.dat"

  if [[ "$kind" == "file" ]]; then
    inf "[$d] 准备测试文件 ${size}GB @ $dir"
    [[ -f "$f" ]] && cur=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if (( cur < size*1024*1024*1024 )); then
      fio --name=prefill --filename="$f" --size="${size}G" --rw=write --bs=8M \
          --ioengine="$IOENGINE" --direct=1 --iodepth=4 --numjobs=1 --end_fsync=1 \
          --output-format=json >/dev/null 2>>"$LOG_FILE"
      if [[ $? -ne 0 ]]; then wrn "[$d] 预填失败（空间不足或只读）"; return 1; fi
    fi
  else
    inf "[$d] 裸设备只读测试（不写入，不破坏数据）"
  fi

  set_fio_tgt "$d" "$dir" "$kind" "$size"

  inf "[$d] 顺序读 1M QD8 ..."
  j=$(fio --name=sread "${FIO_TGT[@]}" --rw=read --bs=1M \
        --ioengine="$IOENGINE" --direct=1 --iodepth=8 --numjobs=1 \
        --group_reporting --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read); lat=$(fio_lat "$j" read)
  show_result "顺序读 1M QD8" "$bw" "$io" "$lat" "$(lt "${D_SPEED[$d]}" 4)"
  record "$d" "SEQ1M_QD8_READ" "$bw" "$io" "$lat"
  printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_seq_read.json"

  if [[ "$kind" == "raw" ]]; then
    inf "[$d] 裸设备跳过顺序写（避免破坏数据）"
    return 0
  fi
  if [[ "$DO_WRITE" -ne 1 ]]; then return 0; fi

  inf "[$d] 顺序写 1M QD8 ..."
  j=$(fio --name=swrite "${FIO_TGT[@]}" --rw=write --bs=1M \
        --ioengine="$IOENGINE" --direct=1 --iodepth=8 --numjobs=1 \
        --group_reporting --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write); lat=$(fio_lat "$j" write)
  show_result "顺序写 1M QD8" "$bw" "$io" "$lat" "$(lt "${D_SPEED[$d]}" 4)"
  record "$d" "SEQ1M_QD8_WRITE" "$bw" "$io" "$lat"
  printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_seq_write.json"
}

bench_random() {  # dev path size kind
  local d=$1 dir=$2 size=$3 kind=$4 j bw io lat
  set_fio_tgt "$d" "$dir" "$kind" "$size"

  inf "[$d] 4K 随机读 QD1 ..."
  j=$(fio --name=r4k1 "${FIO_TGT[@]}" --rw=randread --bs=4k \
        --ioengine="$IOENGINE" --direct=1 --iodepth=1 --numjobs=1 --time_based=1 \
        --runtime="$RUNTIME" --group_reporting --norandommap=1 --randrepeat=0 \
        --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read); lat=$(fio_lat "$j" read)
  show_result "4K 随机读 QD1" "$bw" "$io" "$lat" ""
  record "$d" "RND4K_QD1_READ" "$bw" "$io" "$lat"

  inf "[$d] 4K 随机读 QD32 ..."
  j=$(fio --name=r4k32 "${FIO_TGT[@]}" --rw=randread --bs=4k \
        --ioengine="$IOENGINE" --direct=1 --iodepth=32 --numjobs=1 --time_based=1 \
        --runtime="$RUNTIME" --group_reporting --norandommap=1 --randrepeat=0 \
        --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read); lat=$(fio_lat "$j" read)
  show_result "4K 随机读 QD32" "$bw" "$io" "$lat" ""
  record "$d" "RND4K_QD32_READ" "$bw" "$io" "$lat"

  if [[ "$kind" == "raw" ]]; then
    inf "[$d] 裸设备跳过随机写（避免破坏数据）"
    return 0
  fi
  if [[ "$DO_WRITE" -ne 1 ]]; then return 0; fi

  inf "[$d] 4K 随机写 QD1 ..."
  j=$(fio --name=w4k1 "${FIO_TGT[@]}" --rw=randwrite --bs=4k \
        --ioengine="$IOENGINE" --direct=1 --iodepth=1 --numjobs=1 --time_based=1 \
        --runtime="$RUNTIME" --group_reporting --norandommap=1 --randrepeat=0 \
        --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write); lat=$(fio_lat "$j" write)
  show_result "4K 随机写 QD1" "$bw" "$io" "$lat" ""
  record "$d" "RND4K_QD1_WRITE" "$bw" "$io" "$lat"

  inf "[$d] 4K 随机写 QD32 ..."
  j=$(fio --name=w4k32 "${FIO_TGT[@]}" --rw=randwrite --bs=4k \
        --ioengine="$IOENGINE" --direct=1 --iodepth=32 --numjobs=1 --time_based=1 \
        --runtime="$RUNTIME" --group_reporting --norandommap=1 --randrepeat=0 \
        --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write); lat=$(fio_lat "$j" write)
  show_result "4K 随机写 QD32" "$bw" "$io" "$lat" ""
  record "$d" "RND4K_QD32_WRITE" "$bw" "$io" "$lat"
}

bench_mixed() {  # dev path size kind
  local d=$1 dir=$2 size=$3 kind=$4 j bw io lat
  if [[ "$kind" == "raw" && "$DO_WRITE" -eq 1 ]]; then
    inf "[$d] 裸设备跳过写/混合测试（避免破坏数据）"
    return 0
  fi
  set_fio_tgt "$d" "$dir" "$kind" "$size"
  inf "[$d] 混合读写 70/30 4K QD16 ..."
  j=$(fio --name=mix "${FIO_TGT[@]}" --rw=randrw --rwmixread=70 --bs=4k \
        --ioengine="$IOENGINE" --direct=1 --iodepth=16 --numjobs=1 --time_based=1 \
        --runtime="$RUNTIME" --group_reporting --norandommap=1 --randrepeat=0 \
        --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(jq -r '[(.jobs[].read.bw_bytes//0)+(.jobs[].write.bw_bytes//0)]|add//0|./1048576' <<<"$j" 2>/dev/null | head -1)
  io=$(jq -r '[(.jobs[].read.iops//0)+(.jobs[].write.iops//0)]|add//0' <<<"$j" 2>/dev/null | head -1)
  lat=$(fio_lat "$j" read)
  show_result "混合读写 70/30 4K QD16" "$bw" "$io" "$lat" ""
  record "$d" "MIXED_70R30W_QD16" "$bw" "$io" "$lat"
  printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_mixed.json"
}

#------------------------------ 多盘并发 --------------------------------------
bench_multi() {
  local mode=$1
  printf '\n多盘并发 %s 测试 —— 链路共享上限\n' "$mode"
  dash
  local args=() d dir rc kind size f anyraw=0 n=0
  for d in "${SEL[@]:-}"; do
    [[ -z "$d" ]] && continue
    dir=$(test_dir_for "$d"); rc=$?
    if (( rc == 0 )); then
      kind=file
    elif (( rc == 2 )); then
      kind=raw; dir=""
    else
      continue
    fi

    if [[ "$kind" == "raw" ]]; then
      anyraw=1
      args+=(--name="job_$d" --filename="/dev/$d")
      printf '   %s 参与并发（裸设备只读）\n' "$d"
    else
      size=$(plan_file_size "$dir")
      (( size < 2 )) && continue
      f="$dir/.usb_bench_$d.dat"
      if [[ ! -f "$f" ]]; then
        fio --name=prefill --filename="$f" --size=1G --rw=write --bs=8M --ioengine="$IOENGINE" \
            --direct=1 --iodepth=4 --numjobs=1 --end_fsync=1 --output-format=json >/dev/null 2>&1 || continue
      fi
      args+=(--name="job_$d" --filename="$f" --size="${size}G")
      printf '   %s 参与并发（%sGB 文件）\n' "$d" "$size"
    fi
    n=$((n+1))
  done

  if (( ${#args[@]} == 0 )); then wrn "没有可用设备"; return; fi
  if [[ "$mode" == "write" && $anyraw -eq 1 ]]; then
    wrn "含裸设备，写入测试不安全，改为只读"; mode=read
  fi

  local j bw io
  # 注意: 不能用 --group_reporting, 该模式下 fio 会把多 job 合并成单条 JSON,
  # 导致分盘明细丢失。总带宽由 fio_bw 对 .jobs[] 求和得到。
  j=$(fio --name=global --rw="$mode" --bs=1M --ioengine="$IOENGINE" --direct=1 --iodepth=8 \
        --numjobs=1 --time_based=1 --runtime="$RUNTIME" \
        --output-format=json --eta=never "${args[@]}" 2>>"$LOG_FILE")

  if [[ "$mode" == "write" ]]; then
    bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write)
  else
    bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read)
  fi
  printf '\n'
  show_result "并发总带宽($mode)" "$bw" "$io" 0 ""
  record "ALL" "MULTI_$(echo $mode | tr a-z A-Z)" "$bw" "$io" 0
  printf '%s\n' "$j" > "$OUT_DIR/raw/all_multi_${mode}.json"

  printf '\n   分盘明细\n'
  local i nm val
  for i in $(seq 0 $((n-1))); do
    nm=$(jq -r ".jobs[$i].jobname" <<<"$j" 2>/dev/null)
    val=$(jq -r ".jobs[$i].$mode.bw_bytes//0|./1048576" <<<"$j" 2>/dev/null)
    printf '      %s %8.1f MB/s\n' "$(pad_to "${nm:-?}" 22)" "${val:-0}"
  done
}

#------------------------------ 报告 ------------------------------------------
csv_escape() {
  local v="${1:-}"
  v="${v//\"/\"\"}"
  printf '"%s"' "$v"
}

md_escape() {
  local v="${1:-}"
  v="${v//|/\\|}"
  v="${v//$'\n'/ }"
  v="${v//$'\r'/}"
  printf '%s' "$v"
}

analyze_bottleneck() {
  local d bw_read ref4 sata_r lim pct verdict
  for d in "${SEL[@]:-}"; do
    [[ -z "$d" ]] && continue
    if [[ -z "${R_BW[$d|SEQ1M_QD8_READ]:-}" ]]; then continue; fi
    bw_read=${R_BW[$d|SEQ1M_QD8_READ]:-0}
    ref4=$(lt "${D_SPEED[$d]:-0}" 4)
    sata_r=$(sata_ref "${D_SATA[$d]:-6.0}")
    lim=$ref4
    if (( lim == 0 )); then lim=$sata_r; fi
    if (( lim == 0 )); then continue; fi
    if (( sata_r > 0 && sata_r < lim )); then lim=$sata_r; fi
    pct=$(awk -v a="$bw_read" -v b="$lim" 'BEGIN{if(b>0)printf "%.0f", a*100/b; else print 0}')
    if (( pct > 110 )); then pct=110; fi

    if   (( pct > 100 )); then verdict="实测超过理论线速，判定为虚拟盘/页缓存/内存缓存影响，请以物理机数据为准"
    elif (( pct >= 85 )); then verdict="已跑满该盘理论上限（${pct}%）—— 当前配置即该组合极限"
    elif (( pct >= 65 )); then verdict="接近上限（${pct}%），差距来自 UASP 协议开销 / 线材 / 桥接芯片"
    else                       verdict="明显低于上限（仅 ${pct}%）—— 排查：链路降速 / BOT 协议 / 线材 / 供电 / SLC 缓存耗尽"
    fi
    printf -- '- **/dev/%s** 顺读 %.0f MB/s，理论上限 %s MB/s：%s\n' "$d" "$bw_read" "$lim" "$verdict"

    if [[ "${D_SATA[$d]:-6.0}" == "6.0" ]] && (( ref4 > 600 )); then
      printf '  - 该盘为 SATA 6Gbps，天花板约 550 MB/s，换线材也突破不了；想跑满 10Gbps 必须上 NVMe 盘\n'
    fi
    if [[ "${D_SPEED[$d]:-0}" -gt 0 && "${D_DRIVER[$d]:-}" != "uas" ]]; then
      printf '  - 当前走 usb-storage(BOT)，启用 UASP 通常可再提升 15~30%%\n'
    fi
  done
}

gen_report() {
  if [[ -z "$OUT_DIR" ]]; then die "尚未运行测试"; fi
  local md="$OUT_DIR/报告.md"
  local ts kern fiover d k dv t ref4 sata_r pct first sp drv sata
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  kern=$(uname -r)
  fiover=$(fio --version 2>/dev/null | sed 's/^fio-//')

  {
    echo "# USB 外置存储 · 链路极限速率测试报告"
    echo
    echo "| 项目 | 内容 |"
    echo "|---|---|"
    echo "| 生成时间 | $ts |"
    echo "| 主机 | $(hostname) |"
    echo "| 系统 | $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo Linux ) |"
    echo "| 内核 | $kern |"
    echo "| CPU | $(awk -F: '/model name/{gsub(/^ +/,"",$2);print $2;exit}' /proc/cpuinfo) |"
    echo "| fio 版本 | $fiover |"
    echo "| I/O 引擎 | $IOENGINE (direct=1) |"
    echo "| 测试文件 | ${FILE_GB} GB / 盘 |"
    echo "| 随机测试时长 | ${RUNTIME} s |"
    echo "| 写入测试 | $([[ $DO_WRITE -eq 1 ]] && echo 启用 || echo 仅读) |"
    echo
    echo "## 一、系统与硬件信息"
    echo
    show_system_info md
    echo
    echo "## 二、设备与链路拓扑"
    echo
    echo "| 设备 | 型号 | 容量 | USB 版本 | 链路世代 | SATA 协商 | 驱动 | 端口路径 |"
    echo "|---|---|---|---|---|---|---|---|"
    for d in "${DEV_LIST[@]:-}"; do
      [[ -z "$d" ]] && continue
      echo "| /dev/$d | $(md_escape "${D_MODEL[$d]:-?}") | $(human_size "${D_SIZE[$d]:-0}") | ${D_USBVER[$d]:-?} | $(lt "${D_SPEED[$d]:-0}" 1) | ${D_SATA[$d]:-未知} | ${D_DRIVER[$d]:-?} | ${D_USBPATH[$d]:-?} |"
    done
    echo
    echo "### 链路理论值参照"
    echo
    echo "| 链路 | 线速 | 理论带宽 | 实测可达上限 |"
    echo "|---|---|---|---|"
    echo "| USB 2.0 HighSpeed | 480 Mbps | 60 MB/s | 43 MB/s |"
    echo "| USB 3.2 Gen1 | 5 Gbps | 625 MB/s | 450 MB/s |"
    echo "| USB 3.2 Gen2 | 10 Gbps | 1250 MB/s | 1050 MB/s |"
    echo "| USB 3.2 Gen2x2 | 20 Gbps | 2500 MB/s | 2000 MB/s |"
    echo "| SATA III | 6 Gbps | 750 MB/s | 550 MB/s |"
    echo
    echo "## 三、单盘性能"
    for d in "${SEL[@]:-}"; do
      [[ -z "$d" ]] && continue
      [[ -f "$OUT_DIR/raw/${d}_seq_read.json" ]] || continue
      echo
      echo "### /dev/$d — $(md_escape "${D_MODEL[$d]:-?}")（$(human_size "${D_SIZE[$d]:-0}")，$(lt "${D_SPEED[$d]:-0}" 1)）"
      echo
      echo "| 测试项目 | 带宽 (MB/s) | IOPS | 平均延迟 (us) | 链路达成率 |"
      echo "|---|---:|---:|---:|---:|"
      ref4=$(lt "${D_SPEED[$d]:-0}" 4)
      sata_r=$(sata_ref "${D_SATA[$d]:-6.0}")
      for k in "${RESULT_KEYS[@]:-}"; do
        [[ -z "$k" ]] && continue
        [[ "${k%%|*}" == "$d" ]] || continue
        t="${k#*|}"
        pct="—"
        if [[ "$t" == *READ* && "$t" == SEQ* ]]; then
          pct=$(awk -v a="${R_BW[$k]:-0}" -v b="$ref4" 'BEGIN{if(b>0){p=a*100/b; if(p>100)p=100; printf "%.0f%%", p} else printf "—"}')
        fi
        echo "| $t | $(awk -v v="${R_BW[$k]:-0}" 'BEGIN{printf "%.1f", v}') | $(awk -v v="${R_IOPS[$k]:-0}" 'BEGIN{printf "%.0f", v}') | $(awk -v v="${R_LAT[$k]:-0}" 'BEGIN{printf "%.0f", v}') | $pct |"
      done
      echo
      if (( ref4 > 0 )); then
        echo "> 参照：USB 链路上限 $ref4 MB/s，SATA 上限 $sata_r MB/s，两者较小值即该盘理论上限。"
      else
        echo "> 参照：该盘未识别到 USB 链路（内置盘），按 SATA 上限 $sata_r MB/s 判定。"
      fi
    done
    echo
    echo "## 四、多盘并发总带宽"
    echo
    echo "| 场景 | 总带宽 (MB/s) | 总 IOPS |"
    echo "|---|---:|---:|"
    for k in "${RESULT_KEYS[@]:-}"; do
      [[ -z "$k" ]] && continue
      [[ "${k%%|*}" == "ALL" ]] || continue
      echo "| ${k#*|} | $(awk -v v="${R_BW[$k]:-0}" 'BEGIN{printf "%.1f", v}') | $(awk -v v="${R_IOPS[$k]:-0}" 'BEGIN{printf "%.0f", v}') |"
    done
    if [[ " ${RESULT_KEYS[*]:-} " != *"ALL|"* ]]; then
      echo "| （未执行多盘并发测试） | — | — |"
    fi
    echo
    echo "## 五、瓶颈分析"
    echo
    analyze_bottleneck
    echo
    echo "## 六、原始数据"
    echo
    printf '\140\140\140\n'
    echo "结果目录: $OUT_DIR"
    ls -1 "$OUT_DIR" 2>/dev/null | sed 's/^/  /'
    printf '\140\140\140\n'
  } > "$md"

  {
    echo "device,model,usb_link_mbps,driver,sata_gbps,test,bw_mb_s,iops,lat_us"
    for k in "${RESULT_KEYS[@]:-}"; do
      [[ -z "$k" ]] && continue
      dv="${k%%|*}"; t="${k#*|}"
      sp=0; drv="-"; sata="-"
      if [[ "$dv" != "ALL" ]]; then
        sp=${D_SPEED[$dv]:-0}; drv=${D_DRIVER[$dv]:-?}; sata=${D_SATA[$dv]:-?}
      fi
      echo "$dv,$(csv_escape "${D_MODEL[$dv]:-ALL}"),$sp,$drv,$sata,$t,${R_BW[$k]:-0},${R_IOPS[$k]:-0},${R_LAT[$k]:-0}"
    done
  } > "$OUT_DIR/结果.csv"

  {
    echo "{"
    echo "  \"run_id\": \"$RUN_ID\","
    echo "  \"timestamp\": \"$ts\","
    echo "  \"host\": \"$(hostname)\","
    echo "  \"kernel\": \"$kern\","
    echo "  \"ioengine\": \"$IOENGINE\","
    echo "  \"devices\": ["
    first=1
    for d in "${DEV_LIST[@]:-}"; do
      [[ -z "$d" ]] && continue
      if (( first )); then first=0; else printf ',\n'; fi
      printf '    {"name":"%s","model":"%s","size_bytes":%s,"usb_version":"%s","usb_speed_mbps":%s,"usb_port":"%s","driver":"%s","sata_gbps":"%s"}' \
        "$d" "${D_MODEL[$d]:-}" "${D_SIZE[$d]:-0}" "${D_USBVER[$d]:-}" "${D_SPEED[$d]:-0}" \
        "${D_USBPATH[$d]:-}" "${D_DRIVER[$d]:-}" "${D_SATA[$d]:-}"
    done
    echo
    echo "  ],"
    echo "  \"results\": ["
    first=1
    for k in "${RESULT_KEYS[@]:-}"; do
      [[ -z "$k" ]] && continue
      if (( first )); then first=0; else printf ',\n'; fi
      printf '    {"device":"%s","test":"%s","bw_mb_s":%s,"iops":%s,"lat_us":%s}' \
        "${k%%|*}" "${k#*|}" "${R_BW[$k]:-0}" "${R_IOPS[$k]:-0}" "${R_LAT[$k]:-0}"
    done
    echo
    echo "  ]"
    echo "}"
  } > "$OUT_DIR/结果.json"

  ok "报告已生成: $md"
  printf '       %s\n' "$OUT_DIR/结果.csv"
  printf '       %s\n' "$OUT_DIR/结果.json"
  printf '       %s\n' "$OUT_DIR/raw/"
}

#------------------------------ 测试主流程 ------------------------------------
start_run() {
  RUN_ID=$(date '+%Y%m%d-%H%M%S')
  OUT_DIR="$OUT_ROOT/$RUN_ID"
  mkdir -p "$OUT_DIR/raw" "$MOUNT_ROOT"
  LOG_FILE="$OUT_DIR/fio.log"
  : > "$OUT_DIR/results.txt"
  R_BW=(); R_IOPS=(); R_LAT=(); RESULT_KEYS=()

  {
    echo "=== lsblk ==="; lsblk -o NAME,TYPE,SIZE,TRAN,ROTA,MODEL,SERIAL,MOUNTPOINTS
    echo; echo "=== lsusb -t ==="; lsusb -t 2>/dev/null
    echo; echo "=== lspci usb ==="; lspci -nn 2>/dev/null | grep -iE 'usb|xhci'
    echo; echo "=== uname ==="; uname -a
    echo; echo "=== 系统信息 ==="
    show_system_info text
  } > "$OUT_DIR/topology.txt" 2>&1

  local d
  for d in "${DEV_LIST[@]:-}"; do
    [[ -z "$d" ]] && continue
    smartctl -a "/dev/$d" > "$OUT_DIR/smart_$d.txt" 2>&1 || true
  done
}

run_suite() {
  if [[ ${#SEL[@]} -eq 0 ]]; then wrn "未选择任何设备"; return 1; fi
  hr2
  local mode=标准
  if [[ "$QUICK" -eq 1 ]]; then mode=快速; fi
  if [[ "$FULL" -eq 1 ]]; then mode=极限; fi
  printf ' 测试开始 · 模式: %s · 设备: %d 块\n' "$mode" "${#SEL[@]}"
  hr2
  start_run

  local d dir rc size kind okcnt=0 skipcnt=0
  for d in "${SEL[@]}"; do
    tit "测试 /dev/$d — ${D_MODEL[$d]}"
    dir=$(test_dir_for "$d"); rc=$?
    if (( rc == 0 )); then
      kind=file
    elif (( rc == 2 )); then
      kind=raw; dir=""
    else
      wrn "[$d] 跳过"; skipcnt=$((skipcnt+1)); continue
    fi

    size=0
    if [[ "$kind" == "file" ]]; then
      size=$(plan_file_size "$dir")
      if (( size < 2 )); then wrn "[$d] 可用空间不足 2GB，跳过"; skipcnt=$((skipcnt+1)); continue; fi
      inf "[$d] 测试目录 $dir · 文件 ${size}GB"
    fi

    bench_sequential "$d" "$dir" "$size" "$kind"
    bench_random "$d" "$dir" "$size" "$kind"
    bench_mixed "$d" "$dir" "$size" "$kind"
    [[ "$kind" == "file" ]] && rm -f "$dir/.usb_bench_$d.dat" 2>/dev/null
    okcnt=$((okcnt+1))
    printf '\n'
  done

  if (( okcnt == 0 )); then
    printf '\n'
    wrn "没有任何设备可测试。请检查："
    printf '   - 磁盘是否需要先格式化（sudo mkfs.ext4 /dev/sdX1）\n'
    printf '   - 是否已挂载但不可写（挂载点权限）\n'
    printf '   - NTFS 盘需安装 ntfs-3g\n'
    printf '   裸盘会自动走只读测试，无需格式化即可测速\n\n'
  fi

  if (( okcnt >= 2 )); then
    bench_multi read
  elif (( okcnt == 1 )); then
    inf "仅 1 块盘可测，跳过多盘并发"
  fi

  printf '\n'
  printf '生成报告\n'
  dash
  gen_report
  cleanup_mounts
  printf '\n  报告目录: %s\n\n' "$OUT_DIR"
}

#------------------------------ 菜单 ------------------------------------------
choose_devices() {
  while true; do
    clear 2>/dev/null || true
    hr2; printf '              选择测试目标设备\n'; hr2
    list_devices
    printf '\n  输入编号(空格分隔，如 1 3)、a=全选、n=全不选、回车返回: '
    local in; in=$(ask)
    [[ -z "$in" ]] && return
    case "$in" in
      a|A|all) SEL=("${DEV_LIST[@]}"); continue ;;
      n|N|none) SEL=(); continue ;;
    esac
    local new=() x d
    for x in $in; do
      if [[ "$x" =~ ^[0-9]+$ ]]; then
        if (( x >= 1 && x <= ${#DEV_LIST[@]} )); then
          d="${DEV_LIST[$((x-1))]}"
          if [[ " ${new[*]:-} " != *" $d "* ]]; then new+=("$d"); fi
        fi
      fi
    done
    if (( ${#new[@]} > 0 )); then SEL=("${new[@]}"); fi
  done
}

set_params() {
  while true; do
    clear 2>/dev/null || true
    hr2; printf '              自定义测试参数\n'; hr2
    printf '\n  1) 测试文件大小     当前: %s GB\n' "$FILE_GB"
    printf '  2) 随机测试时长     当前: %s 秒\n' "$RUNTIME"
    printf '  3) 写入测试         当前: %s\n' "$([[ $DO_WRITE -eq 1 ]] && echo 启用 || echo 仅读)"
    printf '  4) 自动挂载未挂载盘 当前: %s\n' "$([[ $AUTO_MOUNT -eq 1 ]] && echo 是 || echo 否)"
    printf '  5) I/O 引擎         当前: %s\n' "$IOENGINE"
    printf '  6) 统一测试目录     当前: %s\n' "${TEST_DIR_OVERRIDE:-<自动>}"
    printf '  7) 包含内置盘       当前: %s\n' "$([[ $INCLUDE_NONUSB -eq 1 ]] && echo 是 || echo 否)"
    printf '\n  0) 返回\n'
    printf '\n  选择: '; local c v; c=$(ask)
    case "$c" in
      1) printf '  输入 GB (2-64): '; v=$(ask); if [[ "$v" =~ ^[0-9]+$ ]] && ((v>=2&&v<=64)); then FILE_GB=$v; fi ;;
      2) printf '  输入秒 (5-300): '; v=$(ask); if [[ "$v" =~ ^[0-9]+$ ]] && ((v>=5&&v<=300)); then RUNTIME=$v; fi ;;
      3) DO_WRITE=$(( 1 - DO_WRITE )) ;;
      4) AUTO_MOUNT=$(( 1 - AUTO_MOUNT )) ;;
      5) printf '  引擎 (libaio/io_uring/psync): '; v=$(ask); if [[ -n "$v" ]]; then IOENGINE=$v; fi ;;
      6) printf '  绝对路径（留空取消）: '; v=$(ask); if [[ -d "$v" ]]; then TEST_DIR_OVERRIDE=$v; else TEST_DIR_OVERRIDE=""; fi ;;
      7) INCLUDE_NONUSB=$(( 1 - INCLUDE_NONUSB )); enumerate_devices ;;
      0) return ;;
    esac
  done
}

show_results_dir() {
  clear 2>/dev/null || true
  hr2; printf '              历史测试记录\n'; hr2
  if [[ ! -d "$OUT_ROOT" ]]; then wrn "尚无记录"; printf '\n'; return; fi
  local i=1 d
  for d in $(ls -1d "$OUT_ROOT"/*/ 2>/dev/null | sort -r); do
    printf '  [%d] %s\n      %s\n' "$i" "$(basename "$d")" "$(ls "$d" 2>/dev/null | tr '\n' ' ')"
    i=$((i+1))
  done
  printf '\n  输入编号查看报告（回车返回）: '; local c; c=$(ask)
  if [[ "$c" =~ ^[0-9]+$ ]]; then
    local p; p=$(ls -1d "$OUT_ROOT"/*/ 2>/dev/null | sort -r | sed -n "${c}p")
    if [[ -n "$p" && -f "$p/报告.md" ]]; then
      head -160 "$p/报告.md"
    fi
  fi
}


#------------------------------ 菜单 ------------------------------------------
pick_preset() {
  hr2
  printf '   选择测试档位\n'
  hr2
  echo "     1) 快速   8GB  / 10s   约 1 分钟/盘"
  echo "     2) 标准   16GB / 30s   约 4 分钟/盘   ★推荐"
  echo "     3) 极限   32GB / 60s   约 10 分钟/盘"
  echo "     0) 返回"
  echo
  printf '   请选择: '
  local c; c=$(ask)
  case "$c" in
    1) QUICK=1; FULL=0; FILE_GB=8;  RUNTIME=10; return 0 ;;
    2) QUICK=0; FULL=0; FILE_GB=16; RUNTIME=30; return 0 ;;
    3) QUICK=0; FULL=1; FILE_GB=32; RUNTIME=60; return 0 ;;
    *) return 1 ;;
  esac
}

run_everything() {
  show_system_info text
  enumerate_devices
  audit_topology
  run_suite
}


#------------------------------ 自更新 ----------------------------------------
INSTALL_PATH="/usr/local/bin/usb-bench"
UPD_URL="${USB_BENCH_URL:-https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh}"
UPD_MARK="USB 外置存储"

http_get() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 8 --max-time 30 "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=30 "$1" 2>/dev/null
  else
    return 127
  fi
}

self_path() {
  local s="$SELF"
  if [[ -f "$s" && ! -L "$s" && "$s" != /dev/fd/* && "$s" != /proc/* ]] \
     && grep -q "usb-bench.sh" "$s" 2>/dev/null; then
    printf '%s' "$s"
  else
    printf '%s' "$INSTALL_PATH"
  fi
}

ver_newer() {
  [[ "$1" == "$2" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | tail -1)" == "$1" ]]
}

do_update() {
  local target tmp rver lver
  tit "检查更新"
  target=$(self_path)
  inf "将依次尝试多个镜像源"
  inf "安装位置: $target"

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    err "缺少 curl 或 wget，无法检查更新"
    err "请先安装：sudo apt install -y curl   （或 dnf/pacman 对应命令）"
    return 1
  fi

  local urls=() u got=""
  if [[ -n "${USB_BENCH_URL:-}" ]]; then urls+=("$USB_BENCH_URL"); fi
  urls+=(
    "https://cdn.jsdelivr.net/gh/SupportSpark/usb-bench@main/usb-bench.sh"
    "https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh"
    "https://ghproxy.net/https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh"
  )

  local best bestver=""
  tmp=$(mktemp /tmp/usb-bench.XXXXXX) || { err "无法创建临时文件"; return 1; }
  best=$(mktemp /tmp/usb-bench.best.XXXXXX) || { err "无法创建临时文件"; rm -f "$tmp"; return 1; }

  # 取所有可用源里版本号最高的: jsDelivr 对 @main 有缓存, 可能落后于 GitHub
  for u in "${urls[@]}"; do
    inf "尝试: $u"
    if http_get "$u" > "$tmp" 2>/dev/null && grep -q "$UPD_MARK" "$tmp" 2>/dev/null; then
      local v
      v=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$tmp" 2>/dev/null | head -1)
      inf "  版本 ${v:-未知}"
      if [[ -z "$bestver" ]] || [[ "$(printf '%s\n%s\n' "$bestver" "${v:-0}" | sort -V | tail -1)" == "${v:-0}" && "${v:-0}" != "$bestver" ]]; then
        cp -f "$tmp" "$best" && bestver="${v:-0}" && got="$u"
      fi
    fi
  done

  if [[ -z "$got" ]]; then
    rm -f "$tmp" "$best"
    err "所有更新源均失败（可能被网络拦截）"
    err "可设置 USB_BENCH_URL 指定可用地址后重试"
    return 1
  fi
  ok "来源: $got"

  rver=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$best" | head -1)
  lver="$VERSION"
  if [[ -z "$rver" ]]; then
    rm -f "$tmp" "$best"; err "无法解析上游版本号"; return 1
  fi

  if [[ "$rver" == "$lver" ]]; then
    rm -f "$tmp" "$best"
    ok "当前 v$lver 已是最新版本"
    return 0
  fi
  if ! ver_newer "$rver" "$lver"; then
    rm -f "$tmp" "$best"
    wrn "上游 v$rver 不高于当前 v$lver，保持现状"
    return 0
  fi

  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  if [[ -f "$target" ]]; then
    cp -f "$target" "$target.bak" 2>/dev/null && inf "已备份旧版本: $target.bak"
  fi

  if install -m 755 "$best" "$target" 2>/dev/null \
     || { cp -f "$best" "$target" && chmod 755 "$target"; }; then
    rm -f "$tmp" "$best"
    ok "更新完成: v$lver → v$rver"
    if [[ "$target" != "$SELF" ]]; then
      inf "下次可直接运行: sudo $target"
    else
      inf "重新运行脚本即生效"
    fi
    return 0
  fi

  rm -f "$tmp" "$best"
  err "写入失败: $target（权限不足？）"
  return 1
}


menu_item() {  # 编号 名称 [颜色]
  local n=$1 name=$2 col=${3:-$W}
  printf '   %s%2s.%s %s%s%s\n' "$Y" "$n" "$N" "$col" "$name" "$N"
}


main_menu() {
  while true; do
    clear 2>/dev/null || true
    hr2
    printf '   USB 外置存储 · 链路极限速率测试   v%s\n' "$VERSION"
    hr2
    printf "   ${DK}主机${N} %-20s ${DK}内核${N} %s\n" "$(hostname)" "$(uname -r)"
    printf "   ${DK}设备${N} 已识别 %d 块 · 已选择 %d 块\n" "${#DEV_LIST[@]}" "${#SEL[@]}"
    printf "   ${DK}参数${N} %sGB · %ss · 写入%s · %s\n" \
      "$FILE_GB" "$RUNTIME" "$([[ $DO_WRITE -eq 1 ]] && echo 开 || echo 关)" "$IOENGINE"
    hr
    echo
    menu_item 1 "一键全流程测试" "$C"
    menu_item 2 "快速体检"
    menu_item 3 "系统信息查询"
    menu_item 4 "USB 拓扑审计"
    menu_item 5 "性能测试"
    menu_item 6 "多盘并发测试"
    menu_item 7 "选择测试设备"
    menu_item 8 "参数设置"
    menu_item 9 "历史报告"
    menu_item 10 "一键更新脚本"
    menu_item 0 "退出"
    echo
    printf "   ${DK}提示 1=全流程 · 3=看硬件 · 4=查链路 · 6=测并发${N}\n"
    echo
    printf '   请选择: '
    local c; c=$(ask)
    case "$c" in
      1) pick_preset || continue; pick_engine; run_everything
         printf '\n   回车继续...'; ask >/dev/null ;;
      2) QUICK=1; FULL=0; FILE_GB=8; RUNTIME=10; pick_engine; run_everything
         printf '\n   回车继续...'; ask >/dev/null ;;
      3) enumerate_devices; show_system_info text
         printf '   回车继续...'; ask >/dev/null ;;
      4) enumerate_devices; audit_topology
         printf '   回车继续...'; ask >/dev/null ;;
      5) pick_preset || continue; pick_engine; enumerate_devices; run_suite
         printf '\n   回车继续...'; ask >/dev/null ;;
      6) pick_engine; enumerate_devices; start_run; bench_multi read; gen_report; cleanup_mounts
         printf '\n   回车继续...'; ask >/dev/null ;;
      7) choose_devices ;;
      8) set_params ;;
      9) show_results_dir ;;
      10) do_update
          printf '\n   回车继续...'; ask >/dev/null ;;
      0) printf '\n   再见。\n\n'; exit 0 ;;
      *) ;;
    esac
  done
}


#------------------------------ 入口 ------------------------------------------
usage() {
  cat <<EOF
usb-bench.sh v$VERSION — USB 外置存储链路极限速率一键测试

用法:
  sudo $0                 交互菜单
  sudo $0 --auto [选项]   全自动（系统信息 + 拓扑 + 测试 + 报告）
  sudo $0 --sysinfo       只看系统与硬件信息
  sudo $0 --update        检查并更新到最新版
  sudo $0 -h              本帮助

选项:
  --auto              无需交互直接跑完全流程
  --sysinfo           打印系统与硬件信息后退出
  --update, -u        检查并更新到最新版
  --quick             快速: 8GB 文件 / 10s 随机
  --full              极限: 32GB 文件 / 60s 随机
  --size N            自定义测试文件 GB (2-64)
  --runtime N         随机测试秒数 (5-300)
  --read-only         只做读测试（不写盘）
  --devices "sdb,sdc" 仅测指定设备
  --dir PATH          统一在该目录建测试文件（需可写）
  --engine NAME       libaio / io_uring / psync
  --no-mount          不自动挂载未挂载的盘
  --include-nonusb    同时列出内置 SATA/NVMe 盘（做基线对比用）
  --no-sysinfo        自动模式跳过系统信息打印
  --no-install        缺少依赖时不自动安装，直接退出

示例:
  sudo $0 --auto --devices sdb,sdc --read-only
  sudo $0 --auto --full --size 32 --runtime 60
  sudo $0 --sysinfo
EOF
}

main() {
  if [[ "$EUID" -ne 0 ]]; then
    # 只有当前脚本确实是本文件时才用 $SELF 提权；管道执行时 $0 是 bash，绝不能 exec 它
    local real=""
    if [[ -f "$SELF" ]] && grep -q "usb-bench.sh" "$SELF" 2>/dev/null; then
      real="$SELF"
    fi
    if [[ -n "$real" ]] && command -v sudo >/dev/null 2>&1; then
      printf '需要 root 权限（smartctl / 挂载 / 直连块设备），正在提权...\n'
      exec sudo -E bash "$real" "$@"
    else
      err "需要 root 权限，请以 sudo 运行"
      printf '  例如: sudo bash %s\n' "$0"
      exit 1
    fi
  fi
  mkdir -p "$BASE_DIR" "$MOUNT_ROOT" "$OUT_ROOT"

  if [[ "$AUTO" -eq 1 || "$SYSINFO_ONLY" -eq 1 || "$UPDATE_ONLY" -eq 1 ]]; then
    clear 2>/dev/null || true
    hr2
    printf '   USB 外置存储 · 链路极限速率测试   v%s\n' "$VERSION"
    hr2
  fi

  if [[ "$UPDATE_ONLY" -eq 1 ]]; then
    do_update
    exit 0
  fi

  if [[ "$NO_INSTALL" -eq 1 && -n "$(cmds_missing $DEP_REQUIRED)" ]]; then
    err "缺少必需组件且已指定 --no-install: $(cmds_missing $DEP_REQUIRED)"
    exit 1
  fi
  if ! ensure_deps; then
    printf '\n  依赖不满足，无法继续。按回车退出...'
    ask >/dev/null || true
    exit 1
  fi

  pick_engine
  enumerate_devices

  if [[ "$SYSINFO_ONLY" -eq 1 ]]; then
    show_system_info text
    exit 0
  fi

  if [[ "$AUTO" -eq 1 ]]; then
    if [[ "$NO_SYSINFO" -ne 1 ]]; then show_system_info text; fi
    audit_topology
    run_suite
    exit 0
  fi
  main_menu
}

trap 'cleanup_mounts' EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --auto)        AUTO=1 ;;
    --sysinfo)     SYSINFO_ONLY=1 ;;
    -u|--update)   UPDATE_ONLY=1 ;;
    --no-sysinfo)  NO_SYSINFO=1 ;;
    --no-install)  NO_INSTALL=1 ;;
    --quick)       QUICK=1; FILE_GB=8; RUNTIME=10 ;;
    --full)        FULL=1; FILE_GB=32; RUNTIME=60 ;;
    --size)        shift; FILE_GB=${1:-16} ;;
    --runtime)     shift; RUNTIME=${1:-30} ;;
    --read-only)   DO_WRITE=0 ;;
    --devices)     shift; DEVICE_FILTER=$(tr ',' ' ' <<<"${1:-}") ;;
    --dir)         shift; TEST_DIR_OVERRIDE=${1:-} ;;
    --engine)      shift; IOENGINE=${1:-libaio} ;;
    --no-mount)    AUTO_MOUNT=0 ;;
    --include-nonusb) INCLUDE_NONUSB=1 ;;
    *) ;;
  esac
  shift
done

main "$@"

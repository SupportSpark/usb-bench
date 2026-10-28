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

VERSION="1.0.0"
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
ok()   { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$*"; }
inf()  { printf '  %s[ .. ]%s %s\n' "$C" "$N" "$*"; }
wrn()  { printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '  %s[FAIL]%s %s\n' "$R" "$N" "$*"; }
die()  { err "$*"; exit 1; }
tit()  { printf '\n%s%s%s\n' "$BD$M" "$*" "$N"; hr; }

BASE_DIR="${USB_BENCH_HOME:-$HOME/.usb-bench}"
OUT_ROOT="${USB_BENCH_REPORTS:-$HOME/usb-bench-reports}"
MOUNT_ROOT="$BASE_DIR/mnt"
RUN_ID=""
OUT_DIR=""
LOG_FILE=""

DEV_LIST=()
declare -A D_SIZE D_MODEL D_SER D_SPEED D_DRIVER D_USBPATH D_ROTA D_SATA D_FS D_MP D_VIDPID D_USBVER
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

#------------------------------ 依赖 ------------------------------------------
cmds_missing() {
  local c m=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || m+=("$c"); done
  printf '%s' "${m[*]:-}"
}

pkg_for() {
  case "$1" in
    smartctl) echo "smartmontools" ;;
    lsusb)    echo "usbutils" ;;
    iostat)   echo "sysstat" ;;
    *)        echo "$1" ;;
  esac
}

ensure_deps() {
  local need req=() p
  need=$(cmds_missing fio jq lsblk lsusb smartctl awk sed)
  if [[ -z "$need" ]]; then ok "依赖齐全 (fio / jq / smartctl / lsusb)"; return 0; fi
  for p in $need; do req+=("$(pkg_for "$p")"); done
  wrn "缺少: $need   ->   apt 安装: ${req[*]}"
  if ! command -v apt-get >/dev/null 2>&1; then
    err "非 apt 系统，请手动安装 fio / jq / smartmontools 后重试"; return 1
  fi
  inf "正在安装（首次可能耗时 1-2 分钟）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  if apt-get install -y -qq "${req[@]}" >/dev/null 2>&1; then
    ok "依赖安装完成"
  else
    err "安装失败，请检查网络/软件源（可先执行 apt-get update）"
    return 1
  fi
  need=$(cmds_missing fio jq)
  if [[ -n "$need" ]]; then err "仍缺少关键命令: $need"; return 1; fi
  return 0
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

fs_of() { blkid -o value -s TYPE "/dev/$1" 2>/dev/null | head -1; }

sata_ver_of() {
  local dev=$1 out
  out=$(smartctl -i "/dev/$dev" 2>/dev/null | grep -m1 -i 'SATA Version is' || true)
  [[ -z "$out" ]] && return 1
  printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+ Gb/s' | head -1 | awk '{print $1}'
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
  printf '\n  %-4s %-7s %-10s %-9s %-7s %-9s %s\n' "#" "设备" "容量" "USB链路" "驱动" "SATA" "型号"
  hr
  local i=1 d mark
  for d in "${DEV_LIST[@]:-}"; do
    [[ -z "$d" ]] && continue
    mark=" "
    if [[ " ${SEL[*]:-} " == *" $d "* ]]; then mark="*"; fi
    printf '  [%d] %s %-7s %-10s %-9s %-7s %-9s %s\n' \
      "$i" "$mark" "$d" "$(human_size "${D_SIZE[$d]:-0}")" "$(speed_label "${D_SPEED[$d]:-0}")" \
      "$(drv_label "${D_DRIVER[$d]:-?}")" "${D_SATA[$d]:-未知}" "${D_MODEL[$d]:0:36}"
    i=$((i+1))
  done
  if [[ ${#DEV_LIST[@]} -eq 0 ]]; then wrn "未发现任何 USB 存储设备"; fi
  hr
  printf '  %d 块设备，已选 %d 块\n' "${#DEV_LIST[@]}" "${#SEL[@]}"
}

#------------------------------ 拓扑审计 --------------------------------------
audit_topology() {
  tit "一、设备与链路拓扑审计"
  if [[ ${#DEV_LIST[@]} -eq 0 ]]; then wrn "无设备"; return; fi
  printf '\n  %-6s %-34s %-10s %-6s %-14s %-8s %-6s %-10s\n' \
    "设备" "型号" "容量" "USB" "链路世代" "SATA" "驱动" "端口路径"
  hr
  local d
  for d in "${DEV_LIST[@]}"; do
    printf '  %-6s %-34s %-10s %-6s %-14s %-8s %-6s %-10s\n' \
      "$d" "${D_MODEL[$d]:0:34}" "$(human_size "${D_SIZE[$d]:-0}")" \
      "${D_USBVER[$d]:-?}" "$(lt "${D_SPEED[$d]:-0}" 1)" \
      "${D_SATA[$d]:-未知}" "${D_DRIVER[$d]:-?}" "${D_USBPATH[$d]:-?}"
  done
  hr

  printf '\n  USB 控制器与端口树 (lsusb -t)\n'
  lsusb -t 2>/dev/null | sed 's/^/    /' || wrn "lsusb 不可用"
  printf '\n  USB 控制器 PCI 设备\n'
  lspci -nn 2>/dev/null | grep -iE 'usb|xhci' | sed 's/^/    /' || true

  printf '\n  诊断结论\n'
  for d in "${DEV_LIST[@]}"; do
    local sp=${D_SPEED[$d]:-0}
    if [[ "${D_SPEED[$d]:-0}" -gt 0 && "${D_DRIVER[$d]:-}" != "uas" ]]; then
      printf '    %-6s [警告] 走 BOT 协议（非 UASP），通常损失 15~30%% 带宽\n' "$d"
    fi
    if [[ "$sp" == "480" ]]; then
      printf '    %-6s [严重] 插在 USB 2.0 端口！上限仅 43 MB/s —— 换 USB3 口或换线\n' "$d"
    fi
    if [[ "${D_SATA[$d]:-6.0}" == "6.0" && "$sp" == "10000" ]]; then
      printf '    %-6s [提示] SATA 6Gbps(约550MB/s) 小于 USB 10Gbps(约1050MB/s)，单盘跑不满链路属正常\n' "$d"
    fi
  done
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

test_dir_for() {
  local d=$1 mnt part fst
  if [[ -n "$TEST_DIR_OVERRIDE" ]]; then printf '%s' "$TEST_DIR_OVERRIDE"; return 0; fi
  mnt=$(first_mount_of "$d" || true)
  if [[ -n "$mnt" ]]; then
    if [[ -w "$mnt" ]]; then printf '%s' "$mnt"; return 0; fi
    wrn "$d 挂载点 $mnt 不可写"; return 1
  fi
  if [[ "$AUTO_MOUNT" -eq 1 ]]; then
    part=$(first_partition "$d" || true)
    if [[ -z "$part" ]]; then part="$d"; fi
    fst=$(fs_of "$part" || true)
    if [[ -z "$fst" ]]; then wrn "$d 无文件系统（未分区或裸盘），跳过文件级测试"; return 1; fi
    if [[ "$fst" == "ntfs" ]] && ! command -v ntfs-3g >/dev/null 2>&1; then
      wrn "$d 为 NTFS，请先 apt install ntfs-3g"; return 1
    fi
    mnt="$MOUNT_ROOT/$d"
    mkdir -p "$mnt"
    if mount -t "$fst" -o noatime "/dev/$part" "$mnt" 2>/dev/null; then
      MOUNTED_BY_US+=("$mnt"); printf '%s' "$mnt"; return 0
    fi
    wrn "$d 自动挂载失败（可能已被占用）"; return 1
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
  local bw=${2:-0}
  printf '    %-24s %10.1f MB/s %8s IOPS %8s us' "$1" "$bw" "${3%.*}" "${4%.*}"
  if [[ -n "${5:-}" ]] && (( ${5%.*} > 0 )); then
    local pct col
    pct=$(awk -v a="$bw" -v b="$5" 'BEGIN{p=a*100/b; if(p>100)p=100; printf "%.0f", p}')
    col=$R
    if (( pct >= 85 )); then col=$G; fi
    if (( pct >= 60 && pct < 85 )); then col=$Y; fi
    printf '   达成 %s%3s%%%s' "$col" "$pct" "$N"
  fi
  printf '\n'
}

bench_sequential() {
  local d=$1 dir=$2 size=$3 f=$2/.usb_bench_$1.dat j bw io lat cur=0
  inf "[$d] 准备测试文件 ${size}GB @ $dir"

  if [[ -f "$f" ]]; then cur=$(stat -c%s "$f" 2>/dev/null || echo 0); fi
  if (( cur < size*1024*1024*1024 )); then
    fio --name=prefill --filename="$f" --size="${size}G" --rw=write --bs=8M \
        --ioengine="$IOENGINE" --direct=1 --iodepth=4 --numjobs=1 --end_fsync=1 \
        --output-format=json >/dev/null 2>>"$LOG_FILE"
    if [[ $? -ne 0 ]]; then wrn "[$d] 预填失败（空间不足或只读）"; return 1; fi
  fi

  inf "[$d] 顺序读 1M QD8 ..."
  j=$(fio --name=sread --filename="$f" --size="${size}G" --rw=read --bs=1M \
        --ioengine="$IOENGINE" --direct=1 --iodepth=8 --numjobs=1 \
        --group_reporting --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read); lat=$(fio_lat "$j" read)
  show_result "顺序读 1M QD8" "$bw" "$io" "$lat" "$(lt "${D_SPEED[$d]}" 4)"
  record "$d" "SEQ1M_QD8_READ" "$bw" "$io" "$lat"
  printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_seq_read.json"

  if [[ "$DO_WRITE" -eq 1 ]]; then
    inf "[$d] 顺序写 1M QD8 ..."
    j=$(fio --name=swrite --filename="$f" --size="${size}G" --rw=write --bs=1M \
          --ioengine="$IOENGINE" --direct=1 --iodepth=8 --numjobs=1 \
          --group_reporting --output-format=json --eta=never 2>>"$LOG_FILE")
    bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write); lat=$(fio_lat "$j" write)
    show_result "顺序写 1M QD8" "$bw" "$io" "$lat" "$(lt "${D_SPEED[$d]}" 4)"
    record "$d" "SEQ1M_QD8_WRITE" "$bw" "$io" "$lat"
    printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_seq_write.json"
  fi
  return 0
}

bench_random() {
  local d=$1 dir=$2 size=$3 f=$2/.usb_bench_$1.dat j bw io lat rt=$RUNTIME
  inf "[$d] 4K 随机读 QD1 ..."
  j=$(fio --name=r4k1 --filename="$f" --size="${size}G" --rw=randread --bs=4k \
        --ioengine="$IOENGINE" --direct=1 --iodepth=1 --numjobs=1 --time_based=1 \
        --runtime=$rt --group_reporting --norandommap=1 --randrepeat=0 \
        --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read); lat=$(fio_lat "$j" read)
  show_result "4K 随机读 QD1" "$bw" "$io" "$lat" ""
  record "$d" "RND4K_QD1_READ" "$bw" "$io" "$lat"
  printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_rnd4k_qd1_read.json"

  inf "[$d] 4K 随机读 QD32 ..."
  j=$(fio --name=r4k32 --filename="$f" --size="${size}G" --rw=randread --bs=4k \
        --ioengine="$IOENGINE" --direct=1 --iodepth=32 --numjobs=1 --time_based=1 \
        --runtime=$rt --group_reporting --norandommap=1 --randrepeat=0 \
        --output-format=json --eta=never 2>>"$LOG_FILE")
  bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read); lat=$(fio_lat "$j" read)
  show_result "4K 随机读 QD32" "$bw" "$io" "$lat" ""
  record "$d" "RND4K_QD32_READ" "$bw" "$io" "$lat"
  printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_rnd4k_qd32_read.json"

  if [[ "$DO_WRITE" -eq 1 ]]; then
    inf "[$d] 4K 随机写 QD1 ..."
    j=$(fio --name=w4k1 --filename="$f" --size="${size}G" --rw=randwrite --bs=4k \
          --ioengine="$IOENGINE" --direct=1 --iodepth=1 --numjobs=1 --time_based=1 \
          --runtime=$rt --group_reporting --norandommap=1 --randrepeat=0 \
          --output-format=json --eta=never 2>>"$LOG_FILE")
    bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write); lat=$(fio_lat "$j" write)
    show_result "4K 随机写 QD1" "$bw" "$io" "$lat" ""
    record "$d" "RND4K_QD1_WRITE" "$bw" "$io" "$lat"

    inf "[$d] 4K 随机写 QD32 ..."
    j=$(fio --name=w4k32 --filename="$f" --size="${size}G" --rw=randwrite --bs=4k \
          --ioengine="$IOENGINE" --direct=1 --iodepth=32 --numjobs=1 --time_based=1 \
          --runtime=$rt --group_reporting --norandommap=1 --randrepeat=0 \
          --output-format=json --eta=never 2>>"$LOG_FILE")
    bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write); lat=$(fio_lat "$j" write)
    show_result "4K 随机写 QD32" "$bw" "$io" "$lat" ""
    record "$d" "RND4K_QD32_WRITE" "$bw" "$io" "$lat"
    printf '%s\n' "$j" > "$OUT_DIR/raw/${d}_rnd4k_qd32_write.json"
  fi
  return 0
}

bench_mixed() {
  local d=$1 dir=$2 size=$3 f=$2/.usb_bench_$1.dat j bw io lat
  inf "[$d] 混合读写 70/30 4K QD16 ..."
  j=$(fio --name=mix --filename="$f" --size="${size}G" --rw=randrw --rwmixread=70 \
        --bs=4k --ioengine="$IOENGINE" --direct=1 --iodepth=16 --numjobs=1 \
        --time_based=1 --runtime=$RUNTIME --group_reporting --norandommap=1 --randrepeat=0 \
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
  tit "多盘并发 $mode 测试 —— 链路共享上限"
  local args=() d dir size f cur
  for d in "${SEL[@]:-}"; do
    [[ -z "$d" ]] && continue
    dir=$(test_dir_for "$d") || continue
    size=$(plan_file_size "$dir")
    if (( size < 2 )); then continue; fi
    f="$dir/.usb_bench_$d.dat"
    if [[ "$mode" == "read" ]]; then
      cur=0
      if [[ -f "$f" ]]; then cur=$(stat -c%s "$f" 2>/dev/null || echo 0); fi
      if (( cur < 1000000000 )); then
        wrn "[$d] 先做 1GB 预填"
        fio --name=prefill --filename="$f" --size=1G --rw=write --bs=8M --ioengine="$IOENGINE" \
            --direct=1 --iodepth=4 --numjobs=1 --end_fsync=1 --output-format=json >/dev/null 2>&1 || continue
      fi
    fi
    args+=(--name="job_$d" --filename="$f" --size="${size}G")
    inf "[$d] 参与并发: ${size}GB"
  done
  if (( ${#args[@]} == 0 )); then wrn "没有可用设备"; return; fi

  local n=$(( ${#args[@]} / 3 ))
  printf '\n    参与设备数: %d\n' "$n"
  local j bw io
  j=$(fio --rw="$mode" --bs=1M --ioengine="$IOENGINE" --direct=1 \
        --iodepth=8 --numjobs=1 --group_reporting --output-format=json --eta=never \
        "${args[@]}" 2>>"$LOG_FILE")
  if [[ "$mode" == "write" ]]; then
    bw=$(fio_bw "$j" write); io=$(fio_iops "$j" write)
  else
    bw=$(fio_bw "$j" read); io=$(fio_iops "$j" read)
  fi
  printf '\n'
  show_result "并发总带宽($mode)" "$bw" "$io" 0 ""
  record "ALL" "MULTI_$(echo $mode | tr a-z A-Z)" "$bw" "$io" 0
  printf '%s\n' "$j" > "$OUT_DIR/raw/all_multi_${mode}.json"

  printf '\n    分盘明细\n'
  local i nm val
  for i in $(seq 0 $((n-1))); do
    nm=$(jq -r ".jobs[$i].jobname" <<<"$j" 2>/dev/null)
    val=$(jq -r ".jobs[$i].$mode.bw_bytes//0|./1048576" <<<"$j" 2>/dev/null)
    printf '      %-24s %8.1f MB/s\n' "$nm" "${val:-0}"
  done
}

#------------------------------ 报告 ------------------------------------------
md_escape() { printf '%s' "${1//|/|}"; }

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
    echo "## 一、设备与链路拓扑"
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
    echo "## 二、单盘性能"
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
    echo "## 三、多盘并发总带宽"
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
    echo "## 四、瓶颈分析"
    echo
    analyze_bottleneck
    echo
    echo "## 五、原始数据"
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
      echo "$dv,$(md_escape "${D_MODEL[$dv]:-ALL}"),$sp,$drv,$sata,$t,${R_BW[$k]:-0},${R_IOPS[$k]:-0},${R_LAT[$k]:-0}"
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

  local d dir size
  for d in "${SEL[@]}"; do
    tit "测试 /dev/$d — ${D_MODEL[$d]}"
    dir=$(test_dir_for "$d") || { wrn "[$d] 跳过（无可写挂载点）"; continue; }
    size=$(plan_file_size "$dir")
    if (( size < 2 )); then wrn "[$d] 可用空间不足 2GB，跳过"; continue; fi
    inf "[$d] 测试目录 $dir · 文件 ${size}GB"
    bench_sequential "$d" "$dir" "$size"
    bench_random "$d" "$dir" "$size"
    bench_mixed "$d" "$dir" "$size"
    rm -f "$dir/.usb_bench_$d.dat" 2>/dev/null
    printf '\n'
  done

  if (( ${#SEL[@]} >= 2 )); then
    bench_multi read
  else
    inf "仅 1 块盘，跳过多盘并发"
  fi

  tit "生成报告"
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
    local in; read -r in
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
    printf '\n  选择: '; local c v; read -r c
    case "$c" in
      1) printf '  输入 GB (2-64): '; read -r v; if [[ "$v" =~ ^[0-9]+$ ]] && ((v>=2&&v<=64)); then FILE_GB=$v; fi ;;
      2) printf '  输入秒 (5-300): '; read -r v; if [[ "$v" =~ ^[0-9]+$ ]] && ((v>=5&&v<=300)); then RUNTIME=$v; fi ;;
      3) DO_WRITE=$(( 1 - DO_WRITE )) ;;
      4) AUTO_MOUNT=$(( 1 - AUTO_MOUNT )) ;;
      5) printf '  引擎 (libaio/io_uring/psync): '; read -r v; if [[ -n "$v" ]]; then IOENGINE=$v; fi ;;
      6) printf '  绝对路径（留空取消）: '; read -r v; if [[ -d "$v" ]]; then TEST_DIR_OVERRIDE=$v; else TEST_DIR_OVERRIDE=""; fi ;;
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
  printf '\n  输入编号查看报告（回车返回）: '; local c; read -r c
  if [[ "$c" =~ ^[0-9]+$ ]]; then
    local p; p=$(ls -1d "$OUT_ROOT"/*/ 2>/dev/null | sort -r | sed -n "${c}p")
    if [[ -n "$p" && -f "$p/报告.md" ]]; then
      head -160 "$p/报告.md"
    fi
  fi
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    hr2
    printf '   USB / UASP 外置存储 · 链路极限速率一键测试   v%s\n' "$VERSION"
    hr2
    printf '   主机: %-22s 内核: %s\n' "$(hostname)" "$(uname -r)"
    printf '   已识别 USB 存储: %d 块    已选择: %d 块\n' "${#DEV_LIST[@]}" "${#SEL[@]}"
    printf '   参数: 文件 %sGB · 随机 %ss · 写入 %s · 引擎 %s\n' \
      "$FILE_GB" "$RUNTIME" "$([[ $DO_WRITE -eq 1 ]] && echo 开 || echo 关)" "$IOENGINE"
    hr2
    echo
    echo "     1) 拓扑审计   —— 链路 / 驱动 / 端口 / 是否降速"
    echo "     2) 快速测试   —— 每盘约 1 分钟（8GB  / 10s）"
    echo "     3) 标准测试   —— 每盘约 4 分钟（16GB / 30s）  推荐"
    echo "     4) 极限测试   —— 每盘约 10 分钟（32GB / 60s）"
    echo "     5) 多盘并发   —— 只测链路共享总带宽"
    echo "     6) 选择测试设备"
    echo "     7) 自定义参数"
    echo "     8) 查看历史报告"
    echo "     9) 检查/安装依赖"
    echo "     0) 退出"
    echo
    printf '   请选择: '; local c; read -r c
    case "$c" in
      1) enumerate_devices; audit_topology; printf '   回车继续...'; read -r _ ;;
      2) QUICK=1; FULL=0; FILE_GB=8;  RUNTIME=10; pick_engine; run_suite; printf '   回车继续...'; read -r _ ;;
      3) QUICK=0; FULL=0; FILE_GB=16; RUNTIME=30; pick_engine; run_suite; printf '   回车继续...'; read -r _ ;;
      4) QUICK=0; FULL=1; FILE_GB=32; RUNTIME=60; pick_engine; run_suite; printf '   回车继续...'; read -r _ ;;
      5) pick_engine; start_run; bench_multi read; gen_report; cleanup_mounts; printf '   回车继续...'; read -r _ ;;
      6) choose_devices ;;
      7) set_params ;;
      8) show_results_dir ;;
      9) ensure_deps; printf '   回车继续...'; read -r _ ;;
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
  sudo $0                交互菜单
  sudo $0 --auto [选项]  全自动（拓扑审计 + 标准测试 + 报告）
  sudo $0 -h             本帮助

选项:
  --auto              无需交互直接跑完全流程
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

示例:
  sudo $0 --auto --devices sdb,sdc --read-only
  sudo $0 --auto --full --size 32 --runtime 60
EOF
}

main() {
  if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      printf '需要 root 权限（smartctl / mount / 块设备），正在提权...\n'
      exec sudo -E bash "$SELF" "$@"
    else
      printf '警告: 非 root 运行，smartctl 与自动挂载不可用\n'
    fi
  fi
  mkdir -p "$BASE_DIR" "$MOUNT_ROOT" "$OUT_ROOT"

  clear 2>/dev/null || true
  hr2
  printf '   USB / UASP 外置存储 · 链路极限速率一键测试   v%s\n' "$VERSION"
  hr2
  if ! ensure_deps; then printf '\n  依赖不满足，回车退出...'; read -r _; exit 1; fi
  pick_engine
  enumerate_devices

  if [[ "$AUTO" -eq 1 ]]; then
    audit_topology
    run_suite
    exit 0
  fi
  main_menu
}

trap 'cleanup_mounts' EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --auto) AUTO=1 ;;
    --quick) QUICK=1; FILE_GB=8; RUNTIME=10 ;;
    --full) FULL=1; FILE_GB=32; RUNTIME=60 ;;
    --size) shift; FILE_GB=${1:-16} ;;
    --runtime) shift; RUNTIME=${1:-30} ;;
    --read-only) DO_WRITE=0 ;;
    --devices) shift; DEVICE_FILTER=$(tr ',' ' ' <<<"${1:-}") ;;
    --dir) shift; TEST_DIR_OVERRIDE=${1:-} ;;
    --engine) shift; IOENGINE=${1:-libaio} ;;
    --no-mount) AUTO_MOUNT=0 ;;
    --include-nonusb) INCLUDE_NONUSB=1 ;;
    *) ;;
  esac
  shift
done

main "$@"

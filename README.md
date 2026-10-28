# usb-bench

USB / UASP 外置存储 —— 链路极限速率一键测试。

在 Linux 上把外置硬盘盒/扩展坞的真实带宽压出来，并生成中文测试报告。
专为 SATA SSD 挂在 USB 3.x 桥接芯片后的场景设计，能正确区分「链路瓶颈」和「盘体瓶颈」，
不会给你一个误导性的"没跑满"结论。

```
 前置检查  系统信息(CPU/内存/显卡/磁盘/PCIe) + 依赖自动安装 + 环境探测
 自更新    --update 一键拉取新版, 自动备份旧版
 单盘 6 项 顺序读写 1M QD8 / 4K 随机读 QD1·QD32 / 4K 随机写 QD1·QD32 / 混合 70:30
 多盘 1 项 全部选中盘并发顺序读 —— 暴露扩展坞共享上行
 全程 --direct=1，绕页缓存，测的是真链路
```

## 一键运行

一条命令，下载即运行：

```bash
curl -fsSL https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh | sudo bash
```

脚本的交互输入走 `/dev/tty`，所以管道方式下菜单照样能操作，不用担心读不到键盘。

带参数（全自动 / 只看硬件信息）：

```bash
curl -fsSL https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh | sudo bash -s -- --auto
curl -fsSL https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh | sudo bash -s -- --sysinfo
```

想装到本地反复用（推荐，之后可以直接 `sudo usb-bench`）：

```bash
sudo curl -fsSL -o /usr/local/bin/usb-bench https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh
sudo chmod +x /usr/local/bin/usb-bench
sudo usb-bench
```

## 更新

```bash
sudo usb-bench.sh --update
```

或菜单里选 **10. 一键更新脚本**。逻辑：

| 情况 | 行为 |
|---|---|
| 上游版本更高 | 备份当前为 `<路径>.bak`，替换并保持 755 权限，提示新旧版本号 |
| 已在最新 | 直接提示，不动文件 |
| 当前是管道运行的（没有本地文件） | 自动安装到 `/usr/local/bin/usb-bench`，之后 `sudo usb-bench` 即可 |
| 下载内容校验不通过 | 放弃覆盖，避免把半截文件写成脚本 |

## 零配置：依赖自动装

脚本启动时先自检，缺什么装什么，装完直接继续跑，不需要你手动 `apt install`。

- **必需**：`fio` `jq` `awk` `sed` `grep` `lsblk` —— 缺了装不上才报错退出
- **可选**：`smartmontools` `usbutils` `pciutils` `dmidecode` `hdparm` `nvme-cli` —— 装不上就降级运行，不影响主流程

自动识别包管理器：`apt` / `dnf` / `pacman` / `zypper` / `apk`。
想关掉自动安装用 `--no-install`。

## 系统信息

菜单 3 或 `--sysinfo`，输出：

| 项目 | 内容 |
|---|---|
| 主机 / OS / 内核 / 运行时长 / 负载 | 基础环境 |
| CPU | 型号 · 线程数 · 路数×核心 · 最高频率 |
| 内存 | 总容量 · 已用 · 可用 · Swap · 内存条数量与频率 |
| 显卡 | nvidia-smi 优先，回退 lspci |
| 主板 / BIOS | dmidecode 读取厂商、型号、版本、日期 |
| 存储设备 | 每块盘的型号、容量、SSD/HDD、总线、挂载点 |
| **PCIe 链路** | USB 控制器 / NVMe 桥的协商速率与宽度，算出实际可用带宽 |

最后一项是这套工具的重点之一。**如果你把 M.2 转双 Type-C 卡插在 x1 的槽上，
PCIe 上行只有约 985 MB/s，两个 10Gbps 口加起来也突破不了这个数** —— 脚本会直接
把这一行标黄并给出警告，省得你怀疑盘或线。

## 菜单

```
   1. 一键全流程测试      系统信息 + 拓扑 + 全部测试 + 报告
   2. 快速体检            约 1 分钟/盘
   3. 系统信息查询        CPU / 内存 / 显卡 / 磁盘 / PCIe
   4. USB 拓扑审计        链路速率 / UASP / SATA 协商 / 端口
   5. 性能测试            选择档位后跑全项目
   6. 多盘并发测试        链路共享总带宽
   7. 选择测试设备
   8. 参数设置
   9. 历史报告
  10. 一键更新脚本
   0. 退出
```

## 输出

报告写到 `~/usb-bench-reports/<时间戳>/`：

| 文件 | 内容 |
|---|---|
| `报告.md` | 中文报告：系统信息、拓扑表、每盘性能表、并发总带宽、瓶颈分析 |
| `结果.csv` | 可直接导入 Excel |
| `结果.json` | 程序化处理用 |
| `raw/` | 每次 fio 的原始 JSON |
| `topology.txt` | 系统信息 + lsblk + lsusb -t + lspci + uname 快照 |
| `smart_<dev>.txt` | 每盘 SMART 全量输出 |

## 参数

```
--auto              无交互跑完全流程
--sysinfo           打印系统与硬件信息后退出
--update, -u        检查并更新到最新版
--quick / --full    快速 / 极限预设
--size N            测试文件 GB (2-64)
--runtime N         随机测试秒数 (5-300)
--read-only         只读测试，完全不写盘
--devices "sdb,sdc" 只测指定盘
--dir PATH          统一测试目录（多盘共用一个挂载点时用）
--engine NAME       libaio / io_uring / psync
--no-mount          不自动挂载未挂载的盘
--include-nonusb    把内置 SATA/NVMe 也列出来做基线对比
--no-sysinfo        自动模式跳过系统信息打印
--no-install        缺少依赖时不自动安装，直接退出
-h, --help          帮助
```

## 安全

- **不会裸写块设备**。所有写入都落在已挂载文件系统的 `/.usb_bench_<dev>.dat` 里。
- 未挂载的盘自动挂到 `~/.usb-bench/mnt/<dev>`，测完自动卸载。
- 测试文件默认 16GB，按可用空间 80% 自动收敛，每轮结束即删。
- 不想写盘：`--read-only`，或菜单 8 里关掉「写入测试」。

## 怎么读报告

脚本按 `min(USB 链路上限, SATA 协商上限)` 算达成率，而不是拿标称值硬比。

链路实测可达上限参照：

| 链路 | 线速 | 理论带宽 | 实测可达上限 |
|---|---|---|---|
| USB 2.0 HighSpeed | 480 Mbps | 60 MB/s | 43 MB/s |
| USB 3.2 Gen1 | 5 Gbps | 625 MB/s | 450 MB/s |
| USB 3.2 Gen2 | 10 Gbps | 1250 MB/s | 1050 MB/s |
| USB 3.2 Gen2x2 | 20 Gbps | 2500 MB/s | 2000 MB/s |
| SATA III | 6 Gbps | 750 MB/s | 550 MB/s |

所以一条 SATA SSD 接在 10Gbps 口上，达成率永远到不了 100%——
因为 SATA 6Gbps 的 550 MB/s 才是它真正的天花板，不是 USB 的问题。
要压满 10Gbps 链路，必须用 NVMe 硬盘盒 + NVMe 盘，或者多盘并发。

## 排查「怎么这么慢」

按顺序查，能解决九成问题：

1. `lsusb -t` 里该盘挂在 `5000M` 还是 `10000M` 分支下 —— 线材/口插错最常见
2. `ID_USB_DRIVER` 是 `uas` 还是 `usb-storage` —— BOT 协议白丢 15~30%
3. 转接卡的 **PCIe 上行**够不够 —— 菜单 3 的 PCIe 表直接给出可用带宽
4. 扩展坞/底座是否多口共享一条上行 —— 用菜单 6 的并发测试验证
5. QLC 盘的 SLC 缓存是否耗尽 —— 连续写超过缓存后掉速属正常
6. 供电不足 —— 双盘位底座同时跑，换带独立电源的 HUB

## 兼容性

在 Debian 12 / 内核 6.1 / fio 3.33 上完整验证：依赖自动安装、系统信息采集、
拓扑审计、7 项性能测试、报告生成、交互菜单、参数切换、JSON/CSV 导出均通过。

需要 bash 4+、fio 3.x、jq、util-linux 2.33+。
Ubuntu 22.04+、Debian 12+、Fedora、Arch 应当直接可用。

## License

MIT

# usb-bench

USB / UASP 外置存储 —— 链路极限速率一键测试。

在 Linux 上把外置硬盘盒/扩展坞的真实带宽压出来，并生成中文测试报告。
专为 SATA SSD 挂在 USB 3.x 桥接芯片后的场景设计，能正确区分「链路瓶颈」和「盘体瓶颈」，
不会给你一个误导性的"没跑满"结论。

```
 单盘 6 项: 顺序读写 1M QD8 / 4K 随机读 QD1·QD32 / 4K 随机写 QD1·QD32 / 混合 70:30
 多盘 1 项: 全部选中盘并发顺序读 —— 暴露扩展坞共享上行
 全程 --direct=1，绕页缓存，测的是真链路
```

## 一键运行

```bash
git clone https://github.com/SupportSpark/usb-bench.git
cd usb-bench
sudo ./usb-bench.sh
```

不想 clone，直接抓单个脚本：

```bash
curl -fsSL -o usb-bench.sh https://raw.githubusercontent.com/SupportSpark/usb-bench/main/usb-bench.sh
chmod +x usb-bench.sh
sudo ./usb-bench.sh
```

全自动无交互（跑完直接出报告）：

```bash
sudo ./usb-bench.sh --auto
```

首次运行自动 `apt install fio jq smartmontools usbutils`。支持 Debian/Ubuntu 系；
其他发行版需自行装齐依赖。

## 适用场景

- 拿到新硬盘盒/扩展坞，想知道它到底跑不跑得满标称速率
- 怀疑 USB 口降速（插成 USB 2.0、线材不对、走了 BOT 而非 UASP）
- 多盘位底座/一拖四扩展坞，想验证是否共享一条上行带宽
- 想给一块盘或一个组合留下可对比的性能基线

## 菜单

```
1) 拓扑审计   —— 链路 / 驱动 / 端口 / 是否降速
2) 快速测试   —— 每盘约 1 分钟（8GB  / 10s）
3) 标准测试   —— 每盘约 4 分钟（16GB / 30s）  推荐
4) 极限测试   —— 每盘约 10 分钟（32GB / 60s）
5) 多盘并发   —— 只测链路共享总带宽
6) 选择测试设备
7) 自定义参数
8) 查看历史报告
9) 检查/安装依赖
0) 退出
```

## 输出

报告写到 `~/usb-bench-reports/<时间戳>/`：

| 文件 | 内容 |
|---|---|
| `报告.md` | 中文报告：拓扑表、每盘性能表、并发总带宽、瓶颈分析 |
| `结果.csv` | 可直接导入 Excel |
| `结果.json` | 程序化处理用 |
| `raw/` | 每次 fio 的原始 JSON |
| `topology.txt` | lsblk / lsusb -t / lspci / uname 快照 |
| `smart_<dev>.txt` | 每盘 SMART 全量输出 |

## 参数

```
--auto              无交互跑完全流程
--quick / --full    快速 / 极限预设
--size N            测试文件 GB (2-64)
--runtime N         随机测试秒数 (5-300)
--read-only         只读测试，完全不写盘
--devices "sdb,sdc" 只测指定盘
--dir PATH          统一测试目录（多盘共用一个挂载点时用）
--engine NAME       libaio / io_uring / psync
--no-mount          不自动挂载未挂载的盘
--include-nonusb    把内置 SATA/NVMe 也列出来做基线对比
-h, --help          帮助
```

## 安全

- **不会裸写块设备**。所有写入都落在已挂载文件系统的 `/.usb_bench_<dev>.dat` 里。
- 未挂载的盘自动挂到 `~/.usb-bench/mnt/<dev>`，测完自动卸载。
- 测试文件默认 16GB，按可用空间 80% 自动收敛，每轮结束即删。
- 不想写盘：`--read-only`，或菜单 7 里关掉「写入测试」。

## 怎么读报告

脚本按 `min(USB 链路上限, SATA 协商上限)` 算达成率，而不是拿标称值硬比。

链路实测下限参照：

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
3. 扩展坞/底座是否多口共享一条上行 —— 用菜单 5 的并发测试验证
4. QLC 盘的 SLC 缓存是否耗尽 —— 连续写超过缓存后掉速属正常
5. 供电不足 —— 双盘位底座同时跑，换带独立电源的 HUB

## 兼容性

在 Debian 12 / 内核 6.1 / fio 3.33 上完整验证：依赖自检、拓扑审计、6 项性能测试、
报告生成、交互菜单、参数切换、JSON/CSV 导出均通过。

Ubuntu 22.04 及以上、Debian 12 及以上应当直接可用；需要 bash 4+、fio 3.x、jq、util-linux 2.33+。

## License

MIT

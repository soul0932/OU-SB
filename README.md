<p align="center"><img src="assets/logos/logo_ou-sb-v2.0.0.png" width="240" alt="OU-SB Logo"></p>
<h1 align="center">OU-SB · V2.0.1</h1>
<p align="center"><strong>SSH 中的一键 sing-box 安装与多协议管理工具</strong></p>
<p align="center">🚀 快速安装　🛡️ NAT小鸡保活　🌈 国旗节点名　🧰 自动备份　📶 BBR + FQ 调优</p>

## 📌 这是什么

OU-SB 面向需要在 SSH 中快速部署 sing-box 的用户。脚本会检测系统、安装 sing-box、创建服务、生成协议入站、输出客户端链接，并保留非 OU-SB 管理的配置。针对 NAT 小鸡与极低内存 VPS 深度强化了崩溃自动拉起、防 OOM 强杀与看门狗自愈机制。

V2.0.0 的交互重点是：首次运行按推荐值一路回车即可完成部署；协议名称默认使用“国旗 + 空格 + 协议名”，也可以在添加时自定义。

## ⚡ 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soul0932/OU-SB/main/OU-SB.sh)
```

首次运行流程：

1. 输入大写 `YES` 确认脚本将管理 sing-box、服务和防火墙；
2. 自动检测公网 IP，也可以输入自己的 IP 或 DDNS；
3. 检测 BBR + FQ，回车进入 TCP 调优；
4. TCP 缓冲区选择推荐值、预设 MB 或自定义 MB；
5. 添加协议，直接回车默认选择 VLESS TCP + Vision + Reality；
6. 设置协议名称并启动服务。

> 支持 Debian、Ubuntu、Rocky Linux、AlmaLinux、CentOS Stream 和 Alpine。建议使用 root 在全新服务器上运行，并提前放行安全组端口。

## 🔌 支持协议

- VLESS TCP + XTLS Vision + Reality
- Shadowsocks 2022
- Hysteria2（UDP 端口跳跃）
- TUIC
- AnyTLS Reality
- Trojan TLS
- Snell v4/v5/v6（实验）

所有 OU-SB 入站使用 `ou-sb-*` tag。删除 OU-SB 协议时，其他入站会被保留。

## 🧭 使用方式

安装完成后直接输入：

```bash
sb
```

主菜单提供节点配置、协议添加/删除、端口修改、HY2 端口跳跃、服务启停、BBR + FQ 与 TCP 调优、更新和卸载。



## 🌈 节点名称

脚本会尝试通过多个公网 IP 服务检测服务器地址，再根据国家代码生成国旗。默认名称示例：

```text
🇺🇸 VLESS
🇸🇬 SS2022
🇯🇵 Trojan
🌐 TUIC
```

如果公网 IP 服务不可用，会回退到本机地址或 `🌐`；也可以在“节点信息”中手动填写 IP、DDNS 或自定义名称。

## 📶 BBR + FQ 与 TCP 调优

首次安装会自动检测当前拥塞控制和队列调度。网络优化菜单支持：

- 开启 BBR + FQ；
- 切换回 cubic；
- 根据内存使用推荐 MB；
- 选择 4/8/16/32 MB 预设；
- 手动输入 1-1024 MB。

配置保存到 `/etc/sysctl.d/99-ou-sb-network.conf`。

## 🛡️ NAT 小鸡高可用加固与自动拉起

针对 64M / 128M / 256M / 512M 等超低内存 NAT 小鸡及 Alpine 容器环境，提供多层高可用保活加固：

1. **Systemd 自动重启 + 防重启风暴**：`Restart=always` 配合 `StartLimitIntervalSec=60` / `StartLimitBurst=5`，正常闪退秒级拉起；若配置错误导致连续失败，则先停下避免每 3 秒一次的 `fork/exec` 重启风暴打满 CPU，再由看门狗每分钟 `reset-failed` 继续尝试。
2. **OpenRC (Alpine) 监督守护**：采用 `supervise-daemon` 原生监督，毫秒级捕获退出并自动拉起，彻底告别 Alpine 上服务意外退出后无人看管的问题。
3. **低内存防暴毙策略 (Go Runtime 优化)**：根据物理内存（<=1GB）阶梯化自动注入 `GOMEMLIMIT` 软上限，配合 `OOMScoreAdjust=-500`，让 sing-box 在内存逼近红线时主动加密 GC，防止被系统 OOM Killer 强杀；同时**不下调 `GOGC`**，避免 GC 频繁触发带来的常驻 CPU 开销（Go 1.19+ 推荐做法）。
4. **单一来源看门狗巡检 (Keepalive Watchdog)**：Systemd 环境使用 Timer、OpenRC/无 systemd 时回退 Cron，每分钟巡检一次且不会重复唤醒；若发现进程退出、僵死卡住、端口残留或因断电导致配置文件损坏，看门狗自动清理冲突、回滚最新可用备份并重启服务加载恢复后的配置。
5. **管理命令与自愈日志**：
   - `sb --watchdog`：手动触发一次健康检测与自愈；
   - `sb --watchdog-log`：查看最近自愈拉起历史日志；
   - `sb --setup-services`：重新生成服务加固配置与看门狗（升级后推荐执行一次）；
   - 管理面板首页直观显示当前服务状态与看门狗状态。

### ⚠️ 128M 超低内存小鸡（LXC/NAT）注意事项

这类小鸡常见配置是 **1 vCPU + 128MB cgroup 内存上限且没有 swap**（例如 Alpine LXC）。跑 IP 质量体检、测速、`nexttrace` 这类脚本时，内存和 CPU 会被脚本自身瞬间打满 —— 这是脚本开销，不是 sing-box 的问题：

- sing-box 受 `GOMEMLIMIT` 与 `oom-score-adj` 保护，不会被优先 OOM 强杀；万一被杀，`supervise-daemon` / systemd / 看门狗会在秒级到 1 分钟内拉起；
- 看门狗在服务健康时只做一次 `jq` 结构检查，**不会每分钟再拉起一个 Go 进程**，避免在最紧张的时候抢内存；
- 服务正在启动/停止、或已被 `supervise-daemon` 接管重启时，看门狗不会插手，避免和 1 核小机上的慢启动互相叠加；
- 建议跑这类重负载脚本前先 `sb` → `8) 停止服务`，跑完再 `7) 启动服务`；
- 容器内的 OOM 记录要在**宿主机**上看：`dmesg -T | grep -i oom`（容器内 `dmesg` 通常不可用）；
- Alpine 的 `pgrep` 是 busybox 符号链接，`pgrep -x` 匹配不到运行中的进程，因此脚本一律用 `pidof` 判定进程存活（早期版本曾因此每分钟重启一次服务）；
- Alpine 的 busybox crond 只在 `/etc/crontabs` **目录 mtime** 变化时重新扫描 crontab，脚本在写入/删除条目后会 `touch` 该目录，否则新任务不会生效（早期版本看门狗因此从未被执行）；
- 非特权 LXC 容器通常**不允许写负的 `oom_score_adj`**（需要宿主命名空间的 `CAP_SYS_RESOURCE`），
  `--oom-score-adj -500` 会静默失效。`sb --doctor` 会读取真实值并提示「负值保护未生效」，
  此时请依赖 `GOMEMLIMIT`，并尽量避免在 128M 小鸡上跑重负载脚本。

#### 🔁 被 OOM 杀掉后会自动拉活吗？—— 会，且不会放弃

以下为 Alpine 3.23 / OpenRC 0.63 / 122MB 容器上的**实机验证结果**：

| 场景 | 实测行为 |
|---|---|
| sing-box 被 OOM killer 杀（`kill -9` 等价） | **约 5 秒**由 `supervise-daemon` 自动拉起（`rc-status` 重生计数 +1） |
| 连续多次被杀（模拟持续内存压力） | 连杀 3 次每次都恢复（重生计数累加到 3），不需要人工介入 |
| 启动一直失败（模拟内存未释放时反复重启） | 探针服务 80 秒内被重启 **18 次**仍在继续 → `respawn_max=0` 为**不限次数**，间隔 3 秒起步、最长 30 秒；资源恢复后一定能起来 |
| `supervise-daemon` 自己也被杀 | 服务短暂变为 `unsupervised`，**1 分钟内**由 cron 看门狗清理残留进程并重建监督 |
| 配置被断电/写坏 | cron 看门狗 1 分钟内从最近有效备份回滚并重启服务 |

- 用 `rc-status | grep sing-box` 看 `started 00:00:52 (3)`，括号里的数字就是被拉起的次数；
- systemd 侧对应机制：`Restart=always` + `StartLimitBurst=5`/60 秒限流，触发限流后单元进入 failed，
  由看门狗每分钟 `reset-failed` 再拉起 —— 同样永不放弃，但不会形成每 3 秒一次的重启风暴。

## 🔐 安全和恢复

- 配置变更前自动备份配置和状态；
- 失败校验不会覆盖旧配置；
- 私钥、配置和状态文件使用受限权限；
- Alpine 下载 sing-box 时校验 SHA-256；
- 卸载时可选择是否删除 sing-box 程序和残留。

## 🧪 开发测试

```bash
bash -n OU-SB.sh tests/test.sh
bash tests/test.sh
```

## 📄 License

[MIT](LICENSE)

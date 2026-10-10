<p align="center"><img src="assets/logos/logo_ou-sb-v2.0.0.png" width="240" alt="OU-SB Logo"></p>
<h1 align="center">OU-SB · V2.0.0</h1>
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

1. **Systemd 永久自愈**：启用 `Restart=always` 与 `StartLimitIntervalSec=0`，彻底关闭崩溃重试频率限制，即使遭遇突发网络波动或闪退也永不放弃拉起。
2. **OpenRC (Alpine) 监督守护**：采用 `supervise-daemon` 原生监督，毫秒级捕获退出并自动拉起，彻底告别 Alpine 上服务意外退出后无人看管的问题。
3. **低内存防暴毙策略 (Go Runtime 优化)**：根据物理内存（<=512MB）阶梯化自动计算并注入 `GOMEMLIMIT` 与 `GOGC`，配合 `OOMScoreAdjust=-500`，使 sing-box 进程在内存逼近红线时主动触发 GC，防止被系统 OOM Killer 强杀。
4. **双重看门狗巡检 (Keepalive Watchdog)**：Systemd Timer 与原生 Cron 每分钟联动巡检；若发现进程退出、僵死卡住、端口残留或因断电导致配置文件损坏，看门狗自动清理冲突、回滚最新可用备份并拉起服务。
5. **管理命令与自愈日志**：
   - `sb --watchdog`：手动触发一次健康检测与自愈；
   - `sb --watchdog-log`：查看最近自愈拉起历史日志；
   - 管理面板首页直观显示当前服务状态与看门狗状态。

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

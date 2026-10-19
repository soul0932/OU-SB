# Changelog

## Unreleased

### Fixed
- 修复修改端口 / 启停服务后 `sb` 持续报「另一个 OU-SB 操作正在运行」的问题。根因是锁 fd 泄漏：
  `acquire_lock` 用 `exec 9>` 打开 `ou-sb.lock`，而 OpenRC 的 `rc-service` 默认把非 CLOEXEC 的 fd 继承给它拉起的进程，
  `supervise-daemon` 因此长期持有这把锁；面板退出后锁不会释放，之后所有 `sb` 调用都失败，直到 sing-box 被重启。
  - `rc-service` 的 restart / start 改为经 `run_without_extra_fds` 调用：在子 shell 里关闭所有非标准 fd 后
    再 exec，锁 fd 不会再被继承给 `supervise-daemon`。（`rc-service` 本身**没有** `--close-fds` 选项，
    那是 `start-stop-daemon` 的参数，上一版误加会导致 OpenRC 上所有重启失败。）
  - `acquire_lock` 改为带重试的 `obtain_lock_fd`；失败时通过 `/proc` 扫描定位真正持有锁的进程：
    占锁进程已退出（如 SSH 断开后被挂住的面板）则自动清理并重试，仍存活则拒绝运行并提示占用者 PID，
    避免「有残留锁却无法操作」和「为了解锁误杀正常服务进程」两种问题。
- 新增回归测试：锁冲突（死进程自动清理 / 活进程拒绝并带 PID / 不误杀）、不再出现无效的 `--close-fds`、
  启动服务时锁 fd 不会被继承。

## V2.0.1 - 2026-10-10

### Added
- **NAT 小鸡高可用加固**：
  - Systemd 服务配置 `Restart=always`、有限重启限流（`StartLimitIntervalSec=60` + `StartLimitBurst=5`）与 `OOMScoreAdjust=-500`；触发限流后单元进入 failed，由看门狗每分钟 `reset-failed` 再拉起，兼顾"永不放弃"与"不烧 CPU"。
  - OpenRC 服务配置 `supervisor="supervise-daemon"` 与 `respawn_delay=3`，解决 Alpine Linux 下服务挂掉无法自愈的缺陷。
  - 针对 NAT 超低内存小鸡（<=1GB）阶梯化动态注入 `GOMEMLIMIT` 软内存上限，防止内存膨胀触发 OOM Killer 强杀；不再下调 `GOGC`，避免 GC 频繁触发推高常驻 CPU。
  - 增加看门狗每分钟健康巡检（Systemd Timer 优先，OpenRC/无 systemd 时回退 Cron，单一调度源不重复唤醒）；支持进程崩溃自愈、孤立僵死进程清理、损坏配置从备份自动回滚（回滚后自动重启以加载恢复的配置）与自愈日志记录。
- **CLI 与管理面板**：
  - 管理面板顶部实时展示服务运行状态与保活看门狗激活状态。
  - 新增管理菜单选项 `11) 保活看门狗管理（自动拉起/自愈日志）`。
  - 新增命令行选项 `sb --watchdog`、`sb --watchdog-log`、`sb --install-watchdog`、`sb --remove-watchdog` 与 `sb --setup-services`（别名 `--harden`）。
  - `sb --doctor` 新增内存阶梯检测与看门狗健康诊断。
- **测试套件扩展**：
  - 单元测试覆盖低内存分级限额、Systemd/OpenRC 模板生成、看门狗损坏配置自愈回滚与任务卸载。
  - 新增 `main()` 入口回归测试：非法 JSON / 被截断的配置下 `sb --watchdog` 仍能完成回滚与重启（此前会被预检 `ensure_base_config` 提前 `die`）。
  - 新增重启限流、GOGC 不再被覆盖、Timer 模式下 cron 去重的断言。

### Changed
- 看门狗健康巡检改为廉价路径：服务正常时只用 `jq` 做配置结构检查，仅在结构异常、或需要重启/回滚时才执行完整的 `sing-box check`，避免在 128M 小鸡上每分钟多拉起一个 Go 进程抢内存。
- 服务处于 `starting` / `stopping` / `crashed`（OpenRC supervise-daemon）或 `activating` / `reloading`（systemd）时，看门狗主动让路，不再与 1 核小机上的慢启动互相叠加。
- OpenRC 的 `--oom-score-adj` 由 `-900` 调整为 `-500`，与 systemd 对齐，避免宿主机 OOM killer 转而去杀其它进程。
- 看门狗状态显示要求 cron 守护进程确实在运行，避免 cron 未启动时面板误报「已激活」。
- 已在 Alpine 3.23 / OpenRC 0.63 实机核对 `supervise-daemon` 参数：`--respawn-delay-step`、`--respawn-delay-cap`、`--oom-score-adj` 均受支持，且 `output_log` / `error_log` 会被 OpenRC 自动映射为 `--stdout` / `--stderr`，切到 supervise-daemon 后日志不会丢。
- README 新增「128M 超低内存小鸡注意事项」，说明跑 IP 质量体检/测速脚本时的资源占用与排查方式。

### Verified
- 在 Alpine 3.23 / OpenRC 0.63 / 122MB 无 swap 容器上实机验证「被 OOM 杀掉后自动拉活」：
  - `kill -9`（等价 OOM killer）sing-box 后约 **5 秒**由 `supervise-daemon` 拉起；连续 3 次击杀每次都恢复（`rc-status` 重生计数累加到 3）。
  - `respawn_max=0` 确认为**不限次数**：探针服务（永远启动失败）在 80 秒内被重启 18 次仍在继续，因此内存压力缓解后必然自动恢复。
  - 连 `supervise-daemon` 一起击杀时，服务变为 `unsupervised`，cron 看门狗在 1 分钟内清理残留进程并重建监督（日志含 WARN/INFO/OK 三行）。
  - 故意写坏配置文件后，cron 看门狗在下一个整分钟从备份回滚并重启服务，无需人工介入。

### Fixed
- 修复 Alpine/busybox 下**看门狗从未被执行**的问题：busybox crond 只在 `/etc/crontabs` **目录 mtime** 变化时才重新扫描 crontab，就地追加/删除条目不会生效（实测追加后等 95 秒任务仍未运行，`touch` 目录后立刻生效）。现在写入或删除 cron 条目后都会 touch 目录，并确保 crond 已启用运行。
- 修复 busybox 环境（Alpine）下 `pgrep -x` 匹配不到运行中的进程：看门狗会把正常的 sing-box 误判为「进程已死」并**每分钟重启一次服务**。进程存活判定改为 pidof 优先，清理残留进程改用 killall / `pkill -f`（busybox 的 `pkill -x` 同样不可靠）。
- `sb --doctor` 现在读取运行中进程真实的 `oom_score_adj`：非特权 LXC 容器没有宿主命名空间的 `CAP_SYS_RESOURCE`，写负值会 EPERM，配置里的 `--oom-score-adj` / `OOMScoreAdjust` 会静默失效；doctor 会如实提示，而不是假报「已保护」。
- 修复配置损坏时自愈完全失效：`--watchdog` 等保活/加固类子命令改为在 `ensure_base_config` 与 `acquire_lock` 之前分发，非法 JSON 配置不再导致看门狗 `die`，被截断的配置也不再被静默覆盖成空配置。
- 修复看门狗回滚备份后不重启服务、恢复的配置不生效的问题。
- 移除看门狗绕过服务管理器的 `nohup` 应急兜底：该兜底会与 `Restart=always` 的单元抢端口，形成永久重启循环，并让 `systemctl` 无法管理该进程。
- 修复管理面板持有 `ou-sb.lock` 期间看门狗每分钟被拒绝、保活静默失效的问题。
- 修复 Systemd Timer 与 Cron 双重调度导致的每分钟重复巡检。
- 移除 `[Service]` 段中无效的 `StartLimitIntervalSec` 重复项（该指令属于 `[Unit]`）。
- 版本号与 CHANGELOG 对齐为 `2.0.1`。

## V2.0.0 - 2026-10-08

- 重新定位为 SSH 一键安装和运维版本。
- 增强公网 IP 多服务检测和国旗回退。
- 协议菜单回车默认选择 VLESS。
- 优化推荐提示、颜色和主菜单快捷键说明。
- README 按当前功能全面重写。


## V2.2.4 - 2026-10-08

### Improved

- 首次网络优化检测后，回车直接进入 TCP 调优，不再重复进入选择菜单。
- BBR 和 FQ 当前值使用绿色强调显示。
- TCP 调优提供推荐值、4/8/16/32 MB 预设和自定义 MB，回车默认使用推荐值。
- 添加协议菜单将 VLESS TCP + Vision + Reality 调整为第一项。
- 主菜单数字使用绿色显示，标题和退出项增加颜色层次。


## V2.2.3 - 2026-10-08

### Improved

- 首次添加协议前自动询问 BBR + FQ 与 TCP 调优。
- TCP 缓冲区交互改用 MB 选项，提供推荐值、小内存模式和自定义模式。
- 修复网络调优菜单中换行显示为字面量的问题。
- 优化网络调优状态、标题和成功提示的颜色与 Emoji。


## V2.2.2 - 2026-10-08

### Added

- 添加协议时支持按协议保存自定义节点名称。
- 默认名称提示为“国旗 + 空格 + 协议名称”，例如 `🇺🇸 VLESS`。
- 新增 BBR+FQ 状态检测、开启/关闭和基于内存的 TCP 缓冲区调优菜单。
- 卸载时可选择是否同时删除 sing-box、服务和残留配置。

### Improved

- 精简主菜单，移除服务状态、日志、校验、手动备份和恢复入口。
- 修复国家代码读取失败时国旗始终无法识别的问题，并提供 `🌐` 回退。


## V2.2.1 - 2026-10-08

### Improved

- 首次安装只询问连接 IP 或 DDNS，不再强制询问节点名称。
- 根据公网 IP 国家代码生成国旗前缀，链接名称支持 `🇺🇸 VLESS`、`🇸🇬 SS2022` 格式。
- 添加协议前增加确认步骤，输入 `n` 或 `0` 可返回上一级。
- 首次进入安装流程需要输入大写 `YES` 确认协议。
- 增加菜单提示颜色和 Emoji。


## V2.2.0 - 2026-10-08

### Added

- 新增 Trojan TLS 入站，支持添加、删除、改端口、状态显示和客户端链接导出。
- 新增 Trojan 配置测试，验证协议管理和链接生成。
- README 更新协议列表和 V2.2.0 使用说明。


## V2.1.0 - 2026-10-08

### Improved

- 配置备份同时保存 `state.json`，并默认轮换保留最近 20 组备份。
- sing-box 官方安装脚本先下载到临时文件并执行语法校验，避免直接管道执行。
- 增强下载失败和安装脚本异常时的清理逻辑。
- README 更新至 V2.1.0。


## V2.0.0 - 2026-10-08

### Added

- 增加 `--status`、`--validate`、`--backup`、`--export`、`--doctor` 非交互命令。
- 增加基础依赖诊断和配置/状态快速校验。
- 更新 V2.0.0 品牌 Logo 和 README 安装说明。

### Improved

- 更新版本号至 V2.0.0。
- 修复 HY2 密码重复生成的问题。
- 修复主菜单重复显示服务状态的问题。
- 强化 SSH 一键安装、日常维护和故障诊断入口。

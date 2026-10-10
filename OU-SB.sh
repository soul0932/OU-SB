#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="OU-SB"
APP_VERSION="2.0.1"
AUTHOR="nodeseek @cshaizhihao"
RAW_SCRIPT_URL="${OU_SB_RAW_URL:-https://raw.githubusercontent.com/soul0932/OU-SB/main/OU-SB.sh}"

OU_SB_ROOT="${OU_SB_ROOT:-}"
APP_DIR="${OU_SB_APP_DIR:-${OU_SB_ROOT}/etc/ou-sb}"
SB_DIR="${OU_SB_SB_DIR:-${OU_SB_ROOT}/etc/sing-box}"
CONFIG_PATH="${OU_SB_CONFIG_PATH:-$SB_DIR/config.json}"
STATE_PATH="${OU_SB_STATE_PATH:-$APP_DIR/state.json}"
BACKUP_DIR="${OU_SB_BACKUP_DIR:-$APP_DIR/backups}"
LOCK_PATH="${OU_SB_LOCK_PATH:-$APP_DIR/ou-sb.lock}"
CERT_DIR="${OU_SB_CERT_DIR:-$APP_DIR/certs}"
INSTALL_DIR="${OU_SB_INSTALL_DIR:-${OU_SB_ROOT}/usr/local/lib/ou-sb}"
INSTALL_PATH="$INSTALL_DIR/OU-SB.sh"
COMMAND_PATH="${OU_SB_COMMAND_PATH:-${OU_SB_ROOT}/usr/local/bin/sb}"
SYSTEMD_DIR="${OU_SB_SYSTEMD_DIR:-${OU_SB_ROOT}/etc/systemd/system}"
OPENRC_DIR="${OU_SB_OPENRC_DIR:-${OU_SB_ROOT}/etc/init.d}"
SERVICE_NAME="sing-box"
WATCHDOG_LOG="${OU_SB_WATCHDOG_LOG:-$APP_DIR/watchdog.log}"
WATCHDOG_LOCK="${OU_SB_WATCHDOG_LOCK:-$APP_DIR/watchdog.lock}"
CRON_FILE="${OU_SB_CRON_FILE:-${OU_SB_ROOT}/etc/cron.d/ou-sb-watchdog}"

TAG_SS="ou-sb-ss"
TAG_HY2="ou-sb-hy2"
TAG_TUIC="ou-sb-tuic"
TAG_VLESS="ou-sb-vless-reality"
TAG_ANYTLS="ou-sb-anytls-reality"
TAG_SNELL="ou-sb-snell"
TAG_TROJAN="ou-sb-trojan"

OS_FAMILY="unknown"
INIT_SYSTEM="unknown"
init_colors() {
    C_RESET="" C_BOLD="" C_CYAN="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_MUTED="" C_MAGENTA=""
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_CYAN=$'\033[38;5;44m'
        C_BLUE=$'\033[38;5;39m'
        C_GREEN=$'\033[38;5;42m'
        C_YELLOW=$'\033[38;5;214m'
        C_RED=$'\033[38;5;196m'
        C_MUTED=$'\033[38;5;245m'
        C_MAGENTA=$'\033[38;5;213m'
    else
        C_RESET="" C_BOLD="" C_CYAN="" C_BLUE="" C_GREEN=""
        C_YELLOW="" C_RED="" C_MUTED="" C_MAGENTA=""
    fi
}

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

banner() {
    if [[ -t 1 ]]; then
        clear || true
    fi
    printf '%s%s' "$C_CYAN" "$C_BOLD"
    cat <<'EOF'
   ____  __  __      _____ ____
  / __ \/ / / /     / ___// __ )
 / / / / / / /______\__ \/ __  |
/ /_/ / /_/ /_____/___/ / /_/ /
\____/\____/     /_____/_____/
EOF
    printf '%s' "$C_RESET"
    printf '  %sSing-box 多协议管理工具%s  v%s\n' "$C_BOLD" "$C_RESET" "$APP_VERSION"
    printf '  作者：%s\n\n' "$AUTHOR"
}

detect_platform() {
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"
        like="${ID_LIKE:-}"
    fi
    case " $id $like " in
        *alpine*) OS_FAMILY="alpine" ;;
        *debian*|*ubuntu*) OS_FAMILY="debian" ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) OS_FAMILY="redhat" ;;
        *) OS_FAMILY="unknown" ;;
    esac
    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    fi
}

require_root() {
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return 0
    [[ $(id -u) -eq 0 ]] || die "请使用 root 用户运行"
}

install_dependencies() {
    local missing=0 command
    for command in curl jq openssl flock ss; do
        command -v "$command" >/dev/null 2>&1 || missing=1
    done
    [[ $missing -eq 0 ]] && return 0
    info "安装基础依赖"
    case "$OS_FAMILY" in
        alpine) apk add --no-cache bash curl jq openssl ca-certificates util-linux iproute2 ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y bash curl jq openssl ca-certificates util-linux iproute2
            ;;
        redhat) dnf install -y bash curl jq openssl ca-certificates util-linux iproute || yum install -y bash curl jq openssl ca-certificates util-linux iproute ;;
        *) die "无法自动安装依赖，请先安装 bash、curl、jq、openssl、flock、ss" ;;
    esac
}

prepare_directories() {
    mkdir -p "$APP_DIR" "$SB_DIR" "$BACKUP_DIR" "$CERT_DIR" "$INSTALL_DIR"
    chmod 700 "$APP_DIR" "$BACKUP_DIR" "$CERT_DIR"
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || die "未找到 flock"
    exec 9>"$LOCK_PATH"
    flock -n 9 || die "另一个 OU-SB 操作正在运行"
}

init_state() {
    [[ -s "$STATE_PATH" ]] && jq -e . "$STATE_PATH" >/dev/null 2>&1 && return 0
    jq -n --arg author "$AUTHOR" '{
        schema: 1,
        owner: "OU-SB",
        author: $author,
        public_host: "",
        node_name: "",
        protocol_names: {},
        config_adopted: false,
        hy2: {hop_ports: "", listen_port: 0, firewall_backend: ""},
        reality: {vless: {}, anytls: {}},
        snell: {client_version: 0, obfs: "none"}
    }' > "$STATE_PATH"
    chmod 600 "$STATE_PATH"
}

state_get() {
    jq -r "$1 // empty" "$STATE_PATH"
}

state_set_string() {
    local path=$1 value=$2 tmp
    tmp=$(mktemp "$APP_DIR/.state.XXXXXX")
    jq --arg path "$path" --arg value "$value" 'setpath($path | split("."); $value)' "$STATE_PATH" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_PATH"
}

state_set_number() {
    local path=$1 value=$2 tmp
    tmp=$(mktemp "$APP_DIR/.state.XXXXXX")
    jq --arg path "$path" --argjson value "$value" 'setpath($path | split("."); $value)' "$STATE_PATH" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_PATH"
}

state_set_boolean() {
    local path=$1 value=$2 tmp
    tmp=$(mktemp "$APP_DIR/.state.XXXXXX")
    jq --arg path "$path" --argjson value "$value" 'setpath($path | split("."); $value)' "$STATE_PATH" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_PATH"
}

ensure_base_config() {
    if [[ -s "$CONFIG_PATH" ]]; then
        jq -e '.inbounds and .outbounds' "$CONFIG_PATH" >/dev/null 2>&1 || die "现有 sing-box 配置不是有效的 OU-SB 可管理结构"
        if [[ $(state_get '.config_adopted') != true ]]; then
            local answer foreign_count backup
            foreign_count=$(jq '[.inbounds[]? | select(((.tag // "") | startswith("ou-sb-")) | not)] | length' "$CONFIG_PATH")
            if ((foreign_count > 0)); then
                [[ -t 0 ]] || die "检测到非 OU-SB 配置，需要交互确认后才能管理"
                warn "检测到 $foreign_count 个非 OU-SB 入站；OU-SB 只会增删 ou-sb-* 标签"
                read -r -p "备份并保留现有配置，继续？[y/N]: " answer
                [[ $answer =~ ^[Yy]$ ]] || die "已取消"
                backup=$(backup_config)
                ok "现有配置已备份：$backup"
            fi
            state_set_boolean 'config_adopted' true
        fi
        return 0
    fi
    jq -n '{
        log: {level: "info", timestamp: true},
        inbounds: [],
        outbounds: [{type: "direct", tag: "direct-out"}]
    }' > "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
    state_set_boolean 'config_adopted' true
}

config_has_tag() {
    jq -e --arg tag "$1" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_PATH" >/dev/null 2>&1
}

protocol_exists() {
    config_has_tag "$1"
}

backup_config() {
    local stamp target state_target
    stamp="$(date '+%Y%m%d-%H%M%S')-$(rand_hex 3)"
    target="$BACKUP_DIR/config-$stamp.json"
    cp -p "$CONFIG_PATH" "$target"
    if [[ -s "$STATE_PATH" ]]; then
        state_target="$BACKUP_DIR/state-$stamp.json"
        cp -p "$STATE_PATH" "$state_target"
    fi
    rotate_backups
    printf '%s\n' "$target"
}

rotate_backups() {
    local keep=${OU_SB_BACKUP_KEEP:-20} file count=0
    [[ $keep =~ ^[0-9]+$ ]] || keep=20
    while IFS= read -r file; do
        count=$((count + 1))
        ((count > keep)) && rm -f -- "$file" "${file/config-/state-}"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
}

validate_candidate() {
    local candidate=$1
    [[ "${OU_SB_FORCE_CHECK_FAIL:-0}" == "1" ]] && return 1
    jq -e . "$candidate" >/dev/null 2>&1 || return 1
    if [[ "${OU_SB_TESTING:-0}" == "1" ]]; then
        return 0
    fi
    command -v sing-box >/dev/null 2>&1 || return 1
    sing-box check -c "$candidate" >/dev/null 2>&1
}

# 廉价结构校验：只起一个 jq 进程，用于每分钟的看门狗健康巡检。
# 完整的 sing-box check 会拉起一个 Go 进程（128M 小鸡上十几 MB 的瞬时内存），
# 所以只在配置结构异常、或服务需要重启/回滚时才执行。
config_structurally_valid() {
    local candidate=$1
    [[ -s $candidate ]] || return 1
    jq -e '.inbounds and .outbounds' "$candidate" >/dev/null 2>&1
}

detect_memory_mb() {
    local mb=""
    if [[ -r /proc/meminfo ]]; then
        mb=$(awk '/MemTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || true)
    fi
    if [[ -z $mb || $mb -le 0 ]]; then
        mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}' || true)
    fi
    echo "${mb:-1024}"
}

# 返回 "<GOMEMLIMIT> <GOGC>"。
# 注意：这里刻意不再下调 GOGC。GOGC 越低 GC 触发越频繁，是用 CPU 换内存，
# 在 NAT 小鸡上表现为 sing-box 常驻 CPU 明显升高。Go 1.19+ 的正确做法是保留
# GOGC 默认值（100），只设置 GOMEMLIMIT 作为软上限：堆接近上限时运行时才会
# 主动加密 GC，既防 OOM 又不牺牲平时的 CPU。
get_sing_box_mem_limits() {
    local mem_total
    mem_total=$(detect_memory_mb)
    local gomemlimit="" gogc=""
    if ((mem_total <= 128)); then
        gomemlimit="70MiB"
    elif ((mem_total <= 256)); then
        gomemlimit="150MiB"
    elif ((mem_total <= 512)); then
        gomemlimit="320MiB"
    elif ((mem_total <= 1024)); then
        gomemlimit="700MiB"
    fi
    printf '%s %s' "$gomemlimit" "$gogc"
}

sing_box_pid() {
    local pid=""
    if command -v pidof >/dev/null 2>&1; then
        pid=$(pidof sing-box 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z $pid ]] && command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -f "sing-box run" 2>/dev/null | head -n1)
    fi
    echo "$pid"
}

is_sing_box_process_running() {
    local pid
    pid=$(sing_box_pid)
    [[ -n $pid ]]
}

# 读取运行中进程真实的 oom_score_adj。
# 非特权容器（LXC + user namespace）没有宿主命名空间的 CAP_SYS_RESOURCE，
# 写负值会 EPERM，服务配置里的 --oom-score-adj / OOMScoreAdjust 会静默失效，
# 所以这里必须读实际值，而不是只相信配置。
live_oom_score_adj() {
    local pid adj=""
    pid=$(sing_box_pid)
    [[ -n $pid && -r /proc/$pid/oom_score_adj ]] || return 1
    adj=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || true)
    [[ -n $adj ]] || return 1
    printf '%s' "$adj"
}

kill_sing_box_process() {
    if command -v killall >/dev/null 2>&1; then
        killall -9 sing-box 2>/dev/null || true
    fi
    if command -v pkill >/dev/null 2>&1; then
        pkill -9 -f "sing-box run" 2>/dev/null || true
    fi
}

service_is_active() {
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return "${OU_SB_TEST_SERVICE_ACTIVE:-0}"
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null ;;
        openrc) rc-service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
        *) is_sing_box_process_running ;;
    esac
}

get_service_status_text() {
    local pid=""
    pid=$(sing_box_pid)
    if service_is_active || [[ -n $pid ]]; then
        printf '%s● 运行中%s%s' "$C_GREEN" "$C_RESET" "${pid:+ (PID: $pid)}"
    else
        printf '%s● 未运行 / 已停止%s' "$C_RED" "$C_RESET"
    fi
}

service_in_transition() {
    # 服务正在启动/停止，或已被监督进程（supervise-daemon）接管重启时不要插手：
    # 1 核小机上慢启动很常见，插手会与负载叠加，还会把正常的慢启动误判成故障反复重启。
    if [[ "${OU_SB_TESTING:-0}" == "1" && "${OU_SB_TEST_SERVICE_TRANSITION:-0}" == "1" ]]; then
        return 0
    fi
    local out=""
    case "$INIT_SYSTEM" in
        systemd)
            out=$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>/dev/null || true)
            [[ $out == activating || $out == reloading || $out == deactivating ]]
            ;;
        openrc)
            # OpenRC 状态：starting / stopping / inactive / started / crashed / unsupervised
            out=$(rc-service "$SERVICE_NAME" status 2>&1 || true)
            [[ $out == *starting* || $out == *stopping* || $out == *crashed* ]]
            ;;
        *) return 1 ;;
    esac
}

cron_daemon_running() {
    # 只有 cron 守护进程真的在跑，cron 兜底才算是"已激活"，否则面板会误报绿灯
    if [[ "${OU_SB_TESTING:-0}" == "1" && -n "${OU_SB_TEST_CRON_RUNNING:-}" ]]; then
        [[ $OU_SB_TEST_CRON_RUNNING == 1 ]]
        return
    fi
    if [[ $INIT_SYSTEM == systemd ]]; then
        systemctl is-active --quiet cron 2>/dev/null && return 0
        systemctl is-active --quiet crond 2>/dev/null && return 0
    fi
    if command -v pidof >/dev/null 2>&1; then
        pidof crond >/dev/null 2>&1 && return 0
        pidof cron >/dev/null 2>&1 && return 0
    fi
    # 注意：不能用 pgrep -x —— Alpine 的 pgrep 是 busybox 符号链接，-x 匹配不到运行中的进程
    if command -v pgrep >/dev/null 2>&1; then
        pgrep crond >/dev/null 2>&1 && return 0
        pgrep cron >/dev/null 2>&1 && return 0
    fi
    return 1
}

get_watchdog_status_text() {
    local active=0
    if [[ $INIT_SYSTEM == systemd ]]; then
        systemctl is-active --quiet ou-sb-watchdog.timer 2>/dev/null && active=1
    fi
    if ((active == 0)) && cron_daemon_running; then
        if [[ -f "$CRON_FILE" ]] && grep -q -- "--watchdog" "$CRON_FILE" 2>/dev/null; then
            active=1
        elif [[ -f /etc/crontabs/root ]] && grep -q -- "--watchdog" /etc/crontabs/root 2>/dev/null; then
            active=1
        elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q -- "--watchdog"; then
            active=1
        fi
    fi
    if ((active == 1)); then
        printf '%s● 已激活 (1分钟自愈巡检)%s' "$C_GREEN" "$C_RESET"
    else
        printf '%s○ 未激活%s' "$C_YELLOW" "$C_RESET"
    fi
}

service_restart() {
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return 0
    case "$INIT_SYSTEM" in
        systemd)
            systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
            systemctl restart "$SERVICE_NAME"
            ;;
        openrc) rc-service "$SERVICE_NAME" restart ;;
        *) return 1 ;;
    esac
}

service_start() {
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return 0
    case "$INIT_SYSTEM" in
        systemd)
            systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
            systemctl start "$SERVICE_NAME"
            ;;
        openrc) rc-service "$SERVICE_NAME" start ;;
        *) return 1 ;;
    esac
}

service_stop() {
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return 0
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "$SERVICE_NAME" ;;
        openrc) rc-service "$SERVICE_NAME" stop ;;
        *) return 1 ;;
    esac
}

service_status() {
    case "$INIT_SYSTEM" in
        systemd) systemctl status "$SERVICE_NAME" --no-pager ;;
        openrc) rc-service "$SERVICE_NAME" status ;;
        *) warn "未知的服务管理器" ;;
    esac
}

service_ready() {
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return 1
    case "$INIT_SYSTEM" in
        systemd) [[ -f "$SYSTEMD_DIR/sing-box.service" ]] ;;
        openrc) [[ -f "$OPENRC_DIR/sing-box" ]] ;;
        *) return 1 ;;
    esac
}

commit_candidate() {
    local candidate=$1 description=$2 backup
    validate_candidate "$candidate" || { rm -f "$candidate"; warn "配置校验失败，未应用：$description"; return 1; }
    backup=$(backup_config)
    chmod 600 "$candidate"
    mv -f "$candidate" "$CONFIG_PATH"
    if service_ready && ! service_restart; then
        warn "服务重启失败，正在恢复配置"
        cp -p "$backup" "$CONFIG_PATH"
        service_restart || true
        return 1
    fi
    ok "$description"
}

apply_inbound_json() {
    local tag=$1 inbound_json=$2 candidate
    if config_has_tag "$tag"; then
        warn "协议已存在：$tag"
        return 2
    fi
    candidate=$(mktemp "$SB_DIR/.config.XXXXXX")
    jq --argjson inbound "$inbound_json" '.inbounds += [$inbound]' "$CONFIG_PATH" > "$candidate"
    commit_candidate "$candidate" "协议配置已添加"
}

replace_inbound_json() {
    local tag=$1 inbound_json=$2 candidate
    candidate=$(mktemp "$SB_DIR/.config.XXXXXX")
    jq --arg tag "$tag" --argjson inbound "$inbound_json" '
        .inbounds = ([.inbounds[] | select(.tag != $tag)] + [$inbound])
    ' "$CONFIG_PATH" > "$candidate"
    commit_candidate "$candidate" "协议配置已更新"
}

remove_inbound_tags() {
    local description=$1
    shift
    local candidate tags_json
    tags_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    candidate=$(mktemp "$SB_DIR/.config.XXXXXX")
    jq --argjson tags "$tags_json" '.inbounds = [.inbounds[] | select(.tag as $tag | $tags | index($tag) | not)]' "$CONFIG_PATH" > "$candidate"
    commit_candidate "$candidate" "$description"
}

random_port() {
    local port attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        port=$((RANDOM % 50001 + 10000))
        if ! port_in_use "$port" && ! port_in_config "$port" && ! port_in_hy2_hop_spec "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

port_in_use() {
    local port=$1
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$port$"
}

port_in_config() {
    local port=$1
    [[ -s $CONFIG_PATH ]] || return 1
    jq -e --argjson port "$port" '.inbounds[]? | select(.listen_port == $port)' "$CONFIG_PATH" >/dev/null 2>&1
}

hop_spec_contains_port() {
    local spec=$1 port=$2 item start end
    local -a items
    [[ -n $spec ]] || return 1
    IFS=',' read -r -a items <<< "$spec"
    for item in "${items[@]}"; do
        if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            ((10#$port >= 10#$start && 10#$port <= 10#$end)) && return 0
        elif ((10#$port == 10#$item)); then
            return 0
        fi
    done
    return 1
}

port_in_hy2_hop_spec() {
    local spec
    [[ -s $STATE_PATH ]] || return 1
    spec=$(state_get '.hy2.hop_ports')
    hop_spec_contains_port "$spec" "$1"
}

valid_port() {
    [[ $1 =~ ^[0-9]+$ && ${#1} -le 5 ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

prompt_port() {
    local label=$1 input default_port
    default_port=$(random_port) || die "无法找到可用端口"
    while true; do
        read -r -p "$label [默认 $default_port]: " input
        input=${input:-$default_port}
        if ! valid_port "$input"; then
            warn "端口必须在 1-65535 之间"
        elif port_in_config "$input"; then
            warn "端口 $input 已被其他协议配置使用"
        elif port_in_hy2_hop_spec "$input"; then
            warn "端口 $input 位于 HY2 跳跃范围内"
        elif port_in_use "$input"; then
            warn "端口 $input 已被占用"
        else
            printf '%s\n' "$input"
            return 0
        fi
    done
}

valid_hop_spec() {
    local spec=$1 item start end
    local -a items
    [[ -n $spec && $spec != *[[:space:]]* ]] || return 1
    IFS=',' read -r -a items <<< "$spec"
    ((${#items[@]} > 0 && ${#items[@]} <= 32)) || return 1
    for item in "${items[@]}"; do
        if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            valid_port "$start" && valid_port "$end" && ((10#$start <= 10#$end)) || return 1
        elif ! valid_port "$item"; then
            return 1
        fi
    done
}

prompt_hop_spec() {
    local input
    while true; do
        read -r -p "跳跃端口（如 20000-30000 或 20000,21000-22000，留空关闭）: " input
        [[ -z $input ]] && { printf '\n'; return 0; }
        if ! valid_hop_spec "$input"; then
            warn "端口范围格式无效"
        elif hop_spec_conflicts_with_config "$input"; then
            warn "跳跃范围与其他协议端口冲突"
        else
            printf '%s\n' "$input"
            return 0
        fi
    done
}

hop_spec_conflicts_with_config() {
    local spec=$1 port
    while IFS= read -r port; do
        [[ -n $port ]] || continue
        hop_spec_contains_port "$spec" "$port" && return 0
    done < <(jq -r --arg hy2 "$TAG_HY2" '.inbounds[]? | select(.tag != $hy2) | .listen_port // empty' "$CONFIG_PATH")
    return 1
}

valid_endpoint_host() {
    [[ -n $1 && ${#1} -le 253 && $1 != *[[:space:],/?#]* ]]
}

valid_sni() {
    [[ -n $1 && ${#1} -le 253 && $1 =~ ^[A-Za-z0-9.-]+$ ]]
}

prompt_sni() {
    local input
    while true; do
        read -r -p "Reality SNI [addons.mozilla.org]: " input
        input=${input:-addons.mozilla.org}
        if valid_sni "$input"; then
            printf '%s\n' "$input"
            return 0
        fi
        warn "SNI 必须是有效域名"
    done
}

rand_base64() { openssl rand -base64 "$1" | tr -d '\n\r'; }
rand_hex() { openssl rand -hex "$1"; }
rand_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr -d '\n\r' < /proc/sys/kernel/random/uuid
    else
        local hex
        hex=$(openssl rand -hex 16)
        printf '%s-%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
    fi
}

ensure_certificates() {
    [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] && return 0
    info "生成 HY2/TUIC 自签证书"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=www.bing.com" >/dev/null 2>&1
    chmod 600 "$CERT_DIR/privkey.pem"
}

get_public_host() {
    local host
    host=$(state_get '.public_host')
    if [[ -n $host ]]; then
        printf '%s\n' "$host"
        return 0
    fi
    for endpoint in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://icanhazip.com" \
        "https://checkip.amazonaws.com"; do
        host=$(curl -4 -fsSL --max-time 4 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        [[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        host=""
    done
    if [[ -z $host ]]; then
        host=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [[ -n $host ]] || host="YOUR_SERVER_IP"
    printf '%s\n' "$host"
}

country_flag() {
    case "${1^^}" in
        US) printf '🇺🇸' ;; SG) printf '🇸🇬' ;; JP) printf '🇯🇵' ;; HK) printf '🇭🇰' ;;
        TW) printf '🇹🇼' ;; KR) printf '🇰🇷' ;; CN) printf '🇨🇳' ;; GB) printf '🇬🇧' ;;
        DE) printf '🇩🇪' ;; FR) printf '🇫🇷' ;; NL) printf '🇳🇱' ;; RU) printf '🇷🇺' ;;
        CA) printf '🇨🇦' ;; AU) printf '🇦🇺' ;; IN) printf '🇮🇳' ;; *) printf '🌐' ;;
    esac
}

get_public_flag() {
    local host code
    host=$(get_public_host)
    [[ $host != YOUR_SERVER_IP ]] || { printf '🌐'; return 0; }
    code=$(curl -4 -fsSL --max-time 4 "https://ipapi.co/$host/country_code/" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -n $code ]] || code=$(curl -4 -fsSL --max-time 4 "https://ipinfo.io/$host/country" 2>/dev/null | tr -d '[:space:]' || true)
    country_flag "$code"
}

link_prefix() {
    local custom flag
    custom=$(state_get '.node_name')
    if [[ -n $custom && $custom != OU-SB ]]; then
        printf '%s' "$custom"
    else
        flag=$(get_public_flag)
        printf '%s' "$flag"
    fi
}

host_for_uri() {
    local host=$1
    if [[ $host == *:* && $host != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

url_encode() { jq -rn --arg value "$1" '$value | @uri'; }
base64_nowrap() { base64 | tr -d '\n\r'; }

generate_reality_material() {
    local output private public sid
    output=$(sing-box generate reality-keypair 2>/dev/null) || return 1
    private=$(awk -F': *' '/PrivateKey|Private key/ {print $2; exit}' <<< "$output")
    public=$(awk -F': *' '/PublicKey|Public key/ {print $2; exit}' <<< "$output")
    [[ -n $private && -n $public ]] || return 1
    sid=$(rand_hex 8)
    printf '%s\t%s\t%s\n' "$private" "$public" "$sid"
}

prompt_protocol_name() {
    local tag=$1 protocol=$2 current name flag
    flag=$(get_public_flag)
    current="$flag $protocol"
    read -r -p "请输入节点自定义名称（默认前缀：国旗 + 空格 + 协议名称）[$current]: " name
    name=${name:-$current}
    state_set_string "protocol_names.$tag" "$name"
}

protocol_label() {
    local tag=$1 fallback=$2 name
    name=$(jq -r --arg tag "$tag" '.protocol_names[$tag] // empty' "$STATE_PATH" 2>/dev/null || true)
    [[ -n $name ]] && printf '%s' "$name" || printf '%s' "$(link_prefix) $fallback"
}

add_ss() {
    protocol_exists "$TAG_SS" && { warn "SS2022 已安装"; return 0; }
    local port password inbound
    port=$(prompt_port "SS2022 端口")
    password=$(rand_base64 16)
    inbound=$(jq -nc --arg tag "$TAG_SS" --argjson port "$port" --arg password "$password" '{
        type:"shadowsocks", tag:$tag, listen:"::", listen_port:$port,
        method:"2022-blake3-aes-128-gcm", password:$password
    }')
    apply_inbound_json "$TAG_SS" "$inbound" || return
    prompt_protocol_name "$TAG_SS" "SS2022"
}

add_hy2() {
    protocol_exists "$TAG_HY2" && { warn "Hysteria2 已安装"; return 0; }
    local port password hop inbound
    port=$(prompt_port "HY2 实际监听端口")
    hop=$(prompt_hop_spec)
    password=$(rand_base64 18)
    ensure_certificates
    inbound=$(jq -nc --arg tag "$TAG_HY2" --argjson port "$port" --arg password "$password" \
        --arg cert "$CERT_DIR/fullchain.pem" --arg key "$CERT_DIR/privkey.pem" '{
        type:"hysteria2", tag:$tag, listen:"::", listen_port:$port,
        users:[{name:"ou-sb", password:$password}],
        tls:{enabled:true, alpn:["h3"], certificate_path:$cert, key_path:$key}
    }')
    apply_inbound_json "$TAG_HY2" "$inbound" || return
    prompt_protocol_name "$TAG_HY2" "Hysteria2"
    state_set_number 'hy2.listen_port' "$port"
    state_set_string 'hy2.hop_ports' "$hop"
    if [[ -n $hop ]]; then
        apply_hy2_firewall || warn "HY2 已添加，但端口跳跃防火墙规则未能应用"
    fi
}

add_tuic() {
    protocol_exists "$TAG_TUIC" && { warn "TUIC 已安装"; return 0; }
    local port uuid password inbound
    port=$(prompt_port "TUIC 端口")
    uuid=$(rand_uuid)
    password=$(rand_base64 18)
    ensure_certificates
    inbound=$(jq -nc --arg tag "$TAG_TUIC" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" \
        --arg cert "$CERT_DIR/fullchain.pem" --arg key "$CERT_DIR/privkey.pem" '{
        type:"tuic", tag:$tag, listen:"::", listen_port:$port,
        users:[{name:"ou-sb", uuid:$uuid, password:$password}], congestion_control:"bbr",
        tls:{enabled:true, alpn:["h3"], certificate_path:$cert, key_path:$key}
    }')
    apply_inbound_json "$TAG_TUIC" "$inbound" || return
    prompt_protocol_name "$TAG_TUIC" "TUIC"
}

add_trojan() {
    protocol_exists "$TAG_TROJAN" && { warn "Trojan 已安装"; return 0; }
    local port password inbound
    port=$(prompt_port "Trojan 端口")
    password=$(rand_base64 24)
    ensure_certificates
    inbound=$(jq -nc --arg tag "$TAG_TROJAN" --argjson port "$port" --arg password "$password" \
        --arg cert "$CERT_DIR/fullchain.pem" --arg key "$CERT_DIR/privkey.pem" '{
        type:"trojan", tag:$tag, listen:"::", listen_port:$port,
        users:[{name:"ou-sb", password:$password}],
        tls:{enabled:true, certificate_path:$cert, key_path:$key}
    }')
    apply_inbound_json "$TAG_TROJAN" "$inbound" || return
    prompt_protocol_name "$TAG_TROJAN" "Trojan"
}

add_vless() {
    protocol_exists "$TAG_VLESS" && { warn "VLESS Reality 已安装"; return 0; }
    local port uuid sni material private public sid inbound
    port=$(prompt_port "VLESS Reality 端口")
    sni=$(prompt_sni)
    uuid=$(rand_uuid)
    material=$(generate_reality_material) || { warn "Reality 密钥生成失败"; return 1; }
    IFS=$'\t' read -r private public sid <<< "$material"
    inbound=$(jq -nc --arg tag "$TAG_VLESS" --argjson port "$port" --arg uuid "$uuid" \
        --arg sni "$sni" --arg private "$private" --arg sid "$sid" '{
        type:"vless", tag:$tag, listen:"::", listen_port:$port,
        users:[{name:"ou-sb", uuid:$uuid, flow:"xtls-rprx-vision"}],
        tls:{enabled:true, server_name:$sni, reality:{enabled:true,
            handshake:{server:$sni, server_port:443}, private_key:$private, short_id:[$sid]}}
    }')
    apply_inbound_json "$TAG_VLESS" "$inbound" || return
    prompt_protocol_name "$TAG_VLESS" "VLESS"
    state_set_string 'reality.vless.public_key' "$public"
    state_set_string 'reality.vless.short_id' "$sid"
    state_set_string 'reality.vless.sni' "$sni"
}

add_anytls() {
    protocol_exists "$TAG_ANYTLS" && { warn "AnyTLS Reality 已安装"; return 0; }
    local port password sni material private public sid inbound
    port=$(prompt_port "AnyTLS Reality 端口")
    sni=$(prompt_sni)
    password=$(rand_base64 18)
    material=$(generate_reality_material) || { warn "Reality 密钥生成失败"; return 1; }
    IFS=$'\t' read -r private public sid <<< "$material"
    inbound=$(jq -nc --arg tag "$TAG_ANYTLS" --argjson port "$port" --arg password "$password" \
        --arg sni "$sni" --arg private "$private" --arg sid "$sid" '{
        type:"anytls", tag:$tag, listen:"::", listen_port:$port,
        users:[{name:"ou-sb", password:$password}],
        tls:{enabled:true, server_name:$sni, reality:{enabled:true,
            handshake:{server:$sni, server_port:443}, private_key:$private, short_id:[$sid]}}
    }')
    apply_inbound_json "$TAG_ANYTLS" "$inbound" || return
    prompt_protocol_name "$TAG_ANYTLS" "AnyTLS"
    state_set_string 'reality.anytls.public_key' "$public"
    state_set_string 'reality.anytls.short_id' "$sid"
    state_set_string 'reality.anytls.sni' "$sni"
}

sing_box_version() {
    sing-box version 2>/dev/null | awk 'NR==1 {print $3}'
}

snell_supported() {
    local candidate
    command -v sing-box >/dev/null 2>&1 || return 1
    candidate=$(mktemp)
    jq -n '{
        inbounds: [{type:"snell", tag:"probe", listen:"127.0.0.1", listen_port:61601,
            version:5, psk:"123456789012", obfs_mode:"none"}],
        outbounds: [{type:"direct", tag:"direct"}]
    }' > "$candidate"
    if sing-box check -c "$candidate" >/dev/null 2>&1; then
        rm -f "$candidate"
        return 0
    fi
    rm -f "$candidate"
    return 1
}

ensure_snell_capable() {
    local version answer
    version=$(sing_box_version || true)
    if snell_supported; then
        return 0
    fi
    warn "Snell 需要 sing-box 1.14.0-alpha.38 或更高版本，当前版本：${version:-未安装}"
    read -r -p "是否安装官方 beta/testing 版本？[y/N]: " answer
    [[ $answer =~ ^[Yy]$ ]] || return 1
    install_sing_box beta
    version=$(sing_box_version || true)
    snell_supported
}

add_snell() {
    protocol_exists "$TAG_SNELL" && { warn "Snell 已安装"; return 0; }
    ensure_snell_capable || { warn "已取消 Snell 安装"; return 0; }
    local port choice client_version server_version password obfs mode inbound
    port=$(prompt_port "Snell 端口")
    cat <<'EOF'
1) Snell v4 客户端（v5 兼容服务端）
2) Snell v5 客户端（不含 QUIC Proxy）
3) Snell v6
EOF
    read -r -p "版本 [1]: " choice
    case "${choice:-1}" in
        1) client_version=4; server_version=5 ;;
        2) client_version=5; server_version=5 ;;
        3) client_version=6; server_version=6 ;;
        *) warn "无效版本"; return 1 ;;
    esac
    password=$(rand_base64 24)
    if [[ $server_version -eq 5 ]]; then
        read -r -p "HTTP 混淆？[y/N]: " choice
        [[ $choice =~ ^[Yy]$ ]] && obfs="http" || obfs="none"
        inbound=$(jq -nc --arg tag "$TAG_SNELL" --argjson port "$port" --arg password "$password" --arg obfs "$obfs" '{
            type:"snell", tag:$tag, listen:"::", listen_port:$port,
            version:5, psk:$password, obfs_mode:$obfs
        }')
    else
        mode="default"
        inbound=$(jq -nc --arg tag "$TAG_SNELL" --argjson port "$port" --arg password "$password" --arg mode "$mode" '{
            type:"snell", tag:$tag, listen:"::", listen_port:$port,
            version:6, psk:$password, mode:$mode
        }')
        obfs="none"
    fi
    apply_inbound_json "$TAG_SNELL" "$inbound" || return
    state_set_number 'snell.client_version' "$client_version"
    state_set_string 'snell.obfs' "$obfs"
}

add_protocol_menu() {
    while true; do
        banner
        printf '%s%s添加协议%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET"
        printf '%s─────────────────────────%s\n' "$C_MUTED" "$C_RESET"
        printf '  %s1)%s VLESS TCP + XTLS Vision + Reality %s（推荐）%s\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"
        printf '  %s2)%s Shadowsocks 2022\n' "$C_GREEN" "$C_RESET"
        printf '  %s3)%s Hysteria2\n' "$C_GREEN" "$C_RESET"
        printf '  %s4)%s TUIC\n' "$C_GREEN" "$C_RESET"
        printf '  %s5)%s AnyTLS Reality\n' "$C_GREEN" "$C_RESET"
        printf '  %s6)%s Trojan TLS\n' "$C_GREEN" "$C_RESET"
        printf '  %s7)%s Snell v4/v5/v6 %s（实验）%s\n' "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET"
        printf '  %s0)%s 返回\n' "$C_RED" "$C_RESET"
        read -r -p "选择 [默认 1]: " choice
        choice=${choice:-1}
        case "$choice" in
            0) return 0 ;;
            1|2|3|4|5|6|7)
                read -r -p "确认添加该协议？（直接回车确认，输入 n 返回）: " confirm
                [[ $confirm =~ ^[Nn]$ ]] && continue
                case "$choice" in
                    1) add_vless ;; 2) add_ss ;; 3) add_hy2 ;; 4) add_tuic ;;
                    5) add_anytls ;; 6) add_trojan ;; 7) add_snell ;;
                esac
                break ;;
            *) warn "⚠️ 无效选项"; sleep 1 ;;
        esac
    done
}

remove_protocol_menu() {
    cat <<'EOF'
1) Shadowsocks 2022
2) Hysteria2
3) TUIC
4) VLESS Reality
5) AnyTLS Reality
6) Trojan TLS
7) Snell
0) 返回
EOF
    local choice tag name
    read -r -p "删除协议: " choice
    case "$choice" in
        1) tag=$TAG_SS; name=SS2022 ;;
        2) tag=$TAG_HY2; name=HY2 ;;
        3) tag=$TAG_TUIC; name=TUIC ;;
        4) tag=$TAG_VLESS; name=VLESS ;;
        5) tag=$TAG_ANYTLS; name=AnyTLS ;;
        6) tag=$TAG_TROJAN; name=Trojan ;;
        7) tag=$TAG_SNELL; name=Snell ;;
        0) return 0 ;;
        *) warn "无效选项"; return 1 ;;
    esac
    protocol_exists "$tag" || { warn "$name 未安装"; return 0; }
    read -r -p "确认删除 $name？[y/N]: " choice
    [[ $choice =~ ^[Yy]$ ]] || return 0
    [[ $tag == "$TAG_HY2" ]] && { clear_hy2_firewall || true; state_set_string 'hy2.hop_ports' ''; }
    remove_inbound_tags "$name 已删除" "$tag"
}

change_protocol_port() {
    local tag name choice new_port candidate current
    cat <<'EOF'
1) Shadowsocks 2022
2) Hysteria2
3) TUIC
4) VLESS Reality
5) AnyTLS Reality
6) Trojan TLS
7) Snell
0) 返回
EOF
    read -r -p "选择协议: " choice
    case "$choice" in
        1) tag=$TAG_SS; name=SS2022 ;;
        2) tag=$TAG_HY2; name=HY2 ;;
        3) tag=$TAG_TUIC; name=TUIC ;;
        4) tag=$TAG_VLESS; name=VLESS ;;
        5) tag=$TAG_ANYTLS; name=AnyTLS ;;
        6) tag=$TAG_TROJAN; name=Trojan ;;
        7) tag=$TAG_SNELL; name=Snell ;;
        0) return 0 ;;
        *) warn "无效选项"; return 1 ;;
    esac
    protocol_exists "$tag" || { warn "协议不存在"; return 1; }
    current=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' "$CONFIG_PATH")
    new_port=$(prompt_port "$name 新端口（当前 $current）")
    candidate=$(mktemp "$SB_DIR/.config.XXXXXX")
    jq --arg tag "$tag" --argjson port "$new_port" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $port' "$CONFIG_PATH" > "$candidate"
    commit_candidate "$candidate" "端口已修改为 $new_port" || return
    if [[ $tag == "$TAG_HY2" ]]; then
        state_set_number 'hy2.listen_port' "$new_port"
        [[ -n $(state_get '.hy2.hop_ports') ]] && apply_hy2_firewall
    fi
}

configure_hy2_hopping() {
    protocol_exists "$TAG_HY2" || { warn "请先安装 Hysteria2"; return 0; }
    local spec port
    spec=$(prompt_hop_spec)
    port=$(jq -r --arg tag "$TAG_HY2" '.inbounds[] | select(.tag==$tag) | .listen_port' "$CONFIG_PATH")
    state_set_string 'hy2.hop_ports' "$spec"
    state_set_number 'hy2.listen_port' "$port"
    if [[ -n $spec ]]; then
        apply_hy2_firewall
    else
        clear_hy2_firewall
        ok "HY2 端口跳跃已关闭"
    fi
}

detect_firewall_backend() {
    if command -v nft >/dev/null 2>&1; then
        printf 'nftables\n'
    elif command -v iptables >/dev/null 2>&1; then
        printf 'iptables\n'
    else
        return 1
    fi
}

ensure_firewall_tool() {
    detect_firewall_backend >/dev/null 2>&1 && return 0
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return 1
    info "安装 nftables"
    case "$OS_FAMILY" in
        alpine) apk add --no-cache nftables ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y nftables
            ;;
        redhat) dnf install -y nftables || yum install -y nftables ;;
        *) return 1 ;;
    esac
}

clear_hy2_firewall() {
    [[ "${OU_SB_TESTING:-0}" == "1" ]] && return 0
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet ou_sb_hy2 >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        while iptables -t nat -C PREROUTING -p udp -j OU_SB_HY2 >/dev/null 2>&1; do
            iptables -t nat -D PREROUTING -p udp -j OU_SB_HY2
        done
        iptables -t nat -F OU_SB_HY2 >/dev/null 2>&1 || true
        iptables -t nat -X OU_SB_HY2 >/dev/null 2>&1 || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -t nat -C PREROUTING -p udp -j OU_SB_HY2 >/dev/null 2>&1; do
            ip6tables -t nat -D PREROUTING -p udp -j OU_SB_HY2
        done
        ip6tables -t nat -F OU_SB_HY2 >/dev/null 2>&1 || true
        ip6tables -t nat -X OU_SB_HY2 >/dev/null 2>&1 || true
    fi
}

apply_hy2_firewall() {
    local spec port backend item rule_port
    local -a items
    spec=$(state_get '.hy2.hop_ports')
    port=$(state_get '.hy2.listen_port')
    [[ -n $spec ]] || return 0
    valid_hop_spec "$spec" || { warn "保存的 HY2 跳跃范围无效"; return 1; }
    valid_port "$port" || { warn "保存的 HY2 监听端口无效"; return 1; }
    ensure_firewall_tool || { warn "无法安装 nftables，端口跳跃不可用"; return 1; }
    backend=$(detect_firewall_backend) || { warn "未找到 nftables 或 iptables"; return 1; }
    clear_hy2_firewall
    if [[ $backend == nftables ]]; then
        nft add table inet ou_sb_hy2
        nft 'add chain inet ou_sb_hy2 prerouting { type nat hook prerouting priority dstnat; policy accept; }'
        IFS=',' read -r -a items <<< "$spec"
        for item in "${items[@]}"; do
            nft add rule inet ou_sb_hy2 prerouting udp dport "$item" redirect to ":$port"
        done
    else
        iptables -t nat -N OU_SB_HY2
        iptables -t nat -A PREROUTING -p udp -j OU_SB_HY2
        command -v ip6tables >/dev/null 2>&1 && { ip6tables -t nat -N OU_SB_HY2; ip6tables -t nat -A PREROUTING -p udp -j OU_SB_HY2; }
        IFS=',' read -r -a items <<< "$spec"
        for item in "${items[@]}"; do
            rule_port=${item/-/:}
            iptables -t nat -A OU_SB_HY2 -p udp --dport "$rule_port" -j REDIRECT --to-ports "$port"
            command -v ip6tables >/dev/null 2>&1 && ip6tables -t nat -A OU_SB_HY2 -p udp --dport "$rule_port" -j REDIRECT --to-ports "$port"
        done
    fi
    state_set_string 'hy2.firewall_backend' "$backend"
    ok "HY2 UDP 跳跃规则已应用：$spec -> $port ($backend)"
}

hop_spec_to_server_ports() {
    local spec=$1 item
    IFS=',' read -r -a items <<< "$spec"
    for item in "${items[@]}"; do
        printf '%s\n' "${item/-/:}"
    done | jq -R . | jq -s .
}

show_links() {
    local host uri_host label tag port password method uuid sni public sid encoded hop version obfs
    host=$(get_public_host)
    uri_host=$(host_for_uri "$host")
    label=$(url_encode "$(link_prefix)")
    printf '\n%s节点配置%s\n' "$C_BOLD" "$C_RESET"
    printf '%s\n' '────────────────────────────────────────'
    if protocol_exists "$TAG_SS"; then
        label=$(url_encode "$(protocol_label "$TAG_SS" "SS2022")")
        method=$(jq -r --arg tag "$TAG_SS" '.inbounds[]|select(.tag==$tag)|.method' "$CONFIG_PATH")
        password=$(jq -r --arg tag "$TAG_SS" '.inbounds[]|select(.tag==$tag)|.password' "$CONFIG_PATH")
        port=$(jq -r --arg tag "$TAG_SS" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_PATH")
        encoded=$(printf '%s:%s' "$method" "$password" | base64_nowrap)
        printf 'SS2022\nss://%s@%s:%s#%s-SS2022\n\n' "$encoded" "$uri_host" "$port" "$label"
    fi
    if protocol_exists "$TAG_HY2"; then
        label=$(url_encode "$(protocol_label "$TAG_HY2" "Hysteria2")")
        password=$(jq -r --arg tag "$TAG_HY2" '.inbounds[]|select(.tag==$tag)|.users[0].password' "$CONFIG_PATH")
        port=$(jq -r --arg tag "$TAG_HY2" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_PATH")
        hop=$(state_get '.hy2.hop_ports')
        [[ -n $hop ]] && port=$hop
        printf 'Hysteria2\nhy2://%s@%s:%s/?sni=www.bing.com&alpn=h3&insecure=1#%s-HY2\n' "$(url_encode "$password")" "$uri_host" "$port" "$label"
        if [[ -n $hop ]]; then
            printf 'sing-box server_ports: '
            hop_spec_to_server_ports "$hop" | jq -c .
            printf 'sing-box hop_interval: 30s\n'
        fi
        printf '\n'
    fi
    if protocol_exists "$TAG_TUIC"; then
        label=$(url_encode "$(protocol_label "$TAG_TUIC" "TUIC")")
        uuid=$(jq -r --arg tag "$TAG_TUIC" '.inbounds[]|select(.tag==$tag)|.users[0].uuid' "$CONFIG_PATH")
        password=$(jq -r --arg tag "$TAG_TUIC" '.inbounds[]|select(.tag==$tag)|.users[0].password' "$CONFIG_PATH")
        port=$(jq -r --arg tag "$TAG_TUIC" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_PATH")
        printf 'TUIC\ntuic://%s:%s@%s:%s/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#%s-TUIC\n\n' "$uuid" "$(url_encode "$password")" "$uri_host" "$port" "$label"
    fi
    for tag in "$TAG_VLESS" "$TAG_ANYTLS"; do
        protocol_exists "$tag" || continue
        if [[ $tag == "$TAG_VLESS" ]]; then label=$(url_encode "$(protocol_label "$TAG_VLESS" "VLESS")"); else label=$(url_encode "$(protocol_label "$TAG_ANYTLS" "AnyTLS")"); fi
        port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_PATH")
        sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name' "$CONFIG_PATH")
        sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_PATH")
        if [[ $tag == "$TAG_VLESS" ]]; then
            public=$(state_get '.reality.vless.public_key')
            uuid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[0].uuid' "$CONFIG_PATH")
            printf 'VLESS TCP + XTLS Vision + Reality\nvless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s#%s-VLESS\n\n' "$uuid" "$uri_host" "$port" "$sni" "$public" "$sid" "$label"
        else
            public=$(state_get '.reality.anytls.public_key')
            password=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[0].password' "$CONFIG_PATH")
            printf 'AnyTLS Reality\nanytls://%s@%s:%s/?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s-AnyTLS\n\n' "$(url_encode "$password")" "$uri_host" "$port" "$sni" "$public" "$sid" "$label"
        fi
    done
    if protocol_exists "$TAG_TROJAN"; then
        label=$(url_encode "$(protocol_label "$TAG_TROJAN" "Trojan")")
        port=$(jq -r --arg tag "$TAG_TROJAN" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_PATH")
        password=$(jq -r --arg tag "$TAG_TROJAN" '.inbounds[]|select(.tag==$tag)|.users[0].password' "$CONFIG_PATH")
        printf 'Trojan TLS\ntrojan://%s@%s:%s?security=tls&sni=%s#%s-Trojan\n\n' "$(url_encode "$password")" "$uri_host" "$port" "$host" "$label"
    fi
    if protocol_exists "$TAG_SNELL"; then
        label=$(url_encode "$(protocol_label "$TAG_SNELL" "Snell")")
        port=$(jq -r --arg tag "$TAG_SNELL" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_PATH")
        password=$(jq -r --arg tag "$TAG_SNELL" '.inbounds[]|select(.tag==$tag)|.psk' "$CONFIG_PATH")
        version=$(state_get '.snell.client_version')
        obfs=$(state_get '.snell.obfs')
        printf 'Snell v%s (Surge)\nOU-SB-Snell = snell, %s, %s, psk=%s, version=%s' "$version" "$host" "$port" "$password" "$version"
        [[ $obfs == http ]] && printf ', obfs=http'
        printf '\n\n'
    fi
}

show_protocol_status() {
    local tag name status
    printf '  %-34s %s\n' "协议" "状态"
    printf '  %-34s %s\n' "────────────────────────────────" "────"
    while IFS='|' read -r tag name; do
        if protocol_exists "$tag"; then status="${C_GREEN}已安装${C_RESET}"; else status="${C_MUTED}未安装${C_RESET}"; fi
        printf '  %-34s %b\n' "$name" "$status"
    done <<EOF
$TAG_SS|Shadowsocks 2022
$TAG_HY2|Hysteria2
$TAG_TUIC|TUIC
$TAG_VLESS|VLESS TCP+Vision+Reality
$TAG_ANYTLS|AnyTLS Reality
$TAG_TROJAN|Trojan TLS
$TAG_SNELL|Snell v4/v5/v6
EOF
}

configure_identity_ip() {
    local host current
    current=$(state_get '.public_host')
    read -r -p "连接 IP 或 DDNS [自动检测]: " host
    host=${host#[}; host=${host%]}
    if [[ -n $host ]]; then
        valid_endpoint_host "$host" || { warn "连接地址格式无效"; return 1; }
        state_set_string 'public_host' "$host"
    fi
    info "已检测连接地址：$(get_public_host) $(get_public_flag)"
}

configure_identity() {
    local host name current
    current=$(state_get '.public_host')
    read -r -p "连接 IP 或 DDNS [${current:-自动检测}]: " host
    host=${host#[}
    host=${host%]}
    if [[ -n $host ]]; then
        valid_endpoint_host "$host" || { warn "连接地址格式无效"; return 1; }
        state_set_string 'public_host' "$host"
    fi
    current=$(state_get '.node_name')
    read -r -p "节点名称 [$current]: " name
    [[ -n $name ]] && state_set_string 'node_name' "$name"
    ok "节点信息已更新"
}

show_logs() {
    case "$INIT_SYSTEM" in
        systemd) journalctl -u "$SERVICE_NAME" -n 100 --no-pager ;;
        openrc) tail -n 100 /var/log/sing-box.log 2>/dev/null || warn "暂无日志" ;;
    esac
}

restore_backup() {
    local latest candidate
    latest=$(for file in "$BACKUP_DIR"/config-*.json; do
        [[ -e $file ]] && printf '%s\n' "$file"
    done | sort -r | head -n1)
    [[ -n $latest ]] || { warn "没有可恢复的备份"; return 0; }
    candidate=$(mktemp "$SB_DIR/.config.XXXXXX")
    cp -p "$latest" "$candidate"
    commit_candidate "$candidate" "已恢复 $(basename "$latest")"
}

create_manual_backup() {
    local backup
    backup=$(backup_config)
    ok "配置已备份：$backup"
}

normalize_sing_box_arch() {
    local machine=$1
    case "$machine" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l|armv7) printf 'armv7\n' ;;
        armv6l|armv6) printf 'armv6\n' ;;
        armv5l|armv5) printf 'armv5\n' ;;
        i386|i486|i586|i686|386) printf '386\n' ;;
        loongarch64|loong64) printf 'loong64\n' ;;
        mips64el|mips64le) printf 'mips64le\n' ;;
        mipsel|mipsle) printf 'mipsle\n' ;;
        ppc64le|riscv64|s390x) printf '%s\n' "$machine" ;;
        *) return 1 ;;
    esac
}

github_api_get() {
    local url=$1
    if [[ -n ${GITHUB_TOKEN:-} ]]; then
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' "$url"
    else
        curl -fsSL -H 'Accept: application/vnd.github+json' "$url"
    fi
}

check_free_space_kb() {
    local path=$1 required_kb=$2 available_kb
    available_kb=$(df -Pk "$path" | awk 'NR == 2 {print $4}')
    [[ $available_kb =~ ^[0-9]+$ ]] || return 1
    ((available_kb >= required_kb))
}

install_sing_box_alpine() {
    local channel=$1 release_json tag version arch asset_name asset_json
    local asset_url asset_digest asset_size digest actual required_kb
    local temp_dir archive binary target

    if [[ $channel == beta ]]; then
        release_json=$(github_api_get 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30' \
            | jq -c '[.[] | select(.prerelease == true and .draft == false)] | first')
    else
        release_json=$(github_api_get 'https://api.github.com/repos/SagerNet/sing-box/releases/latest')
    fi
    [[ -n $release_json && $release_json != null ]] || die "无法获取 sing-box $channel 版本信息"

    tag=$(jq -r '.tag_name // empty' <<< "$release_json")
    version=${tag#v}
    [[ -n $version ]] || die "sing-box 版本信息无效"
    arch=$(normalize_sing_box_arch "$(uname -m)") || die "不支持的 CPU 架构：$(uname -m)"
    asset_name="sing-box-${version}-linux-${arch}-musl.tar.gz"
    asset_json=$(jq -c --arg name "$asset_name" '.assets[] | select(.name == $name)' <<< "$release_json")
    [[ -n $asset_json ]] || die "未找到适用于 $arch 的官方 sing-box 压缩包"

    asset_url=$(jq -r '.browser_download_url // empty' <<< "$asset_json")
    asset_digest=$(jq -r '.digest // empty' <<< "$asset_json")
    asset_size=$(jq -r '.size // 0' <<< "$asset_json")
    [[ -n $asset_url && $asset_digest == sha256:* && $asset_size =~ ^[0-9]+$ ]] \
        || die "sing-box 下载信息缺少 URL 或 SHA-256"

    required_kb=$((asset_size * 4 / 1024 + 32768))
    check_free_space_kb "$APP_DIR" "$required_kb" \
        || die "磁盘空间不足，安装至少需要约 $((required_kb / 1024)) MiB 可用空间"

    temp_dir=$(mktemp -d "$APP_DIR/install.XXXXXX")
    archive="$temp_dir/$asset_name"
    info "下载 sing-box $version ($arch)"
    if ! curl -fL --retry 3 --connect-timeout 10 "$asset_url" -o "$archive"; then
        rm -rf -- "$temp_dir"
        die "sing-box 下载失败"
    fi

    digest=${asset_digest#sha256:}
    actual=$(sha256sum "$archive" | awk '{print $1}')
    if [[ $actual != "$digest" ]]; then
        rm -rf -- "$temp_dir"
        die "sing-box SHA-256 校验失败"
    fi

    if ! tar -xzf "$archive" -C "$temp_dir"; then
        rm -rf -- "$temp_dir"
        die "sing-box 压缩包解压失败"
    fi
    binary=$(find "$temp_dir" -type f -name sing-box | head -n1)
    [[ -n $binary && -x $binary ]] || { rm -rf -- "$temp_dir"; die "压缩包中未找到 sing-box 可执行文件"; }

    target="${OU_SB_SING_BOX_BIN:-/usr/local/bin/sing-box}"
    mkdir -p "$(dirname "$target")"
    install -m 755 "$binary" "$target"
    rm -rf -- "$temp_dir"
    hash -r
}

install_sing_box() {
    local channel=${1:-stable}
    info "安装 sing-box ($channel)"
    if [[ $OS_FAMILY == alpine ]]; then
        install_sing_box_alpine "$channel"
    else
        local installer
        installer=$(mktemp "$APP_DIR/sing-box-installer.XXXXXX")
        if ! curl -fL --retry 3 --connect-timeout 10 https://sing-box.app/install.sh -o "$installer"; then
            rm -f -- "$installer"
            die "sing-box 安装脚本下载失败"
        fi
        bash -n "$installer" || { rm -f -- "$installer"; die "sing-box 安装脚本语法校验失败"; }
        if [[ $channel == beta ]]; then bash "$installer" --beta; else bash "$installer"; fi
        rm -f -- "$installer"
    fi
    command -v sing-box >/dev/null 2>&1 || die "sing-box 安装失败"
    ok "$(sing-box version 2>/dev/null | head -n1)"
}

setup_services() {
    local sb_bin gomemlimit gogc env_lines=""
    sb_bin=$(command -v sing-box 2>/dev/null || echo "${OU_SB_SING_BOX_BIN:-/usr/local/bin/sing-box}")
    read -r gomemlimit gogc <<< "$(get_sing_box_mem_limits)"
    if [[ -n $gomemlimit ]]; then
        env_lines="Environment=\"GOMEMLIMIT=$gomemlimit\""$'\n'
    fi
    if [[ -n $gogc ]]; then
        env_lines="${env_lines}Environment=\"GOGC=$gogc\""$'\n'
    fi

    if [[ $INIT_SYSTEM == systemd ]]; then
        mkdir -p "$SYSTEMD_DIR"
        cat > "$SYSTEMD_DIR/sing-box.service" <<EOF
[Unit]
Description=sing-box service managed by OU-SB
After=network-online.target ou-sb-firewall.service
Wants=network-online.target
# 保留有限重试（60 秒内 5 次）。彻底关闭限流会在配置错误/端口冲突时形成
# 每 3 秒一次的 fork/exec 重启风暴，在 NAT 小鸡上直接表现为 CPU 打满。
# 超过限制后单元进入 failed，由 ou-sb-watchdog 每分钟 reset-failed 后再拉起。
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$sb_bin run -c $CONFIG_PATH
Restart=always
RestartSec=3s
LimitNOFILE=1048576
LimitNPROC=512
OOMScoreAdjust=-500
TimeoutStopSec=10s
${env_lines}[Install]
WantedBy=multi-user.target
EOF
        cat > "$SYSTEMD_DIR/ou-sb-firewall.service" <<EOF
[Unit]
Description=OU-SB Hysteria2 port hopping
Before=sing-box.service

[Service]
Type=oneshot
ExecStart=$COMMAND_PATH --apply-firewall
ExecStop=$COMMAND_PATH --clear-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        if [[ "${OU_SB_TESTING:-0}" != "1" ]]; then
            systemctl daemon-reload
            systemctl enable sing-box ou-sb-firewall >/dev/null 2>&1 || true
        fi
    elif [[ $INIT_SYSTEM == openrc ]]; then
        mkdir -p "$OPENRC_DIR"
        local openrc_env=""
        [[ -n $gomemlimit ]] && openrc_env="export GOMEMLIMIT=\"$gomemlimit\""$'\n'
        [[ -n $gogc ]] && openrc_env="${openrc_env}export GOGC=\"$gogc\""$'\n'

        cat > "$OPENRC_DIR/sing-box" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service managed by OU-SB"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay-step 2 --respawn-delay-cap 30 --oom-score-adj -500"
respawn_delay=3
respawn_max=0
respawn_period=1800
command="$sb_bin"
command_args="run -c $CONFIG_PATH"
command_user="root"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; after ou-sb-firewall; }
start_pre() {
${openrc_env}    mkdir -p /run /var/log
    [ -f "/var/log/sing-box.log" ] || : > "/var/log/sing-box.log"
    if [ ! -s "$CONFIG_PATH" ]; then
        eerror "sing-box: config not found or empty: $CONFIG_PATH"
        return 1
    fi
    if ! "\$command" check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        eerror "sing-box: config is invalid, refusing to start: $CONFIG_PATH"
        "\$command" check -c "$CONFIG_PATH" 2>&1 | while read -r line; do
            eerror "sing-box:   \$line"
        done
        return 1
    fi
    if [ -f "/var/log/sing-box.log" ]; then
        _size=\$(wc -c < "/var/log/sing-box.log" 2>/dev/null || echo 0)
        if [ "\$_size" -gt 20971520 ]; then
            mv -f "/var/log/sing-box.log" "/var/log/sing-box.log.1"
            : > "/var/log/sing-box.log"
            ewarn "sing-box: log exceeded 20 MiB, rotated to /var/log/sing-box.log.1"
        fi
    fi
    return 0
}
EOF
        cat > "$OPENRC_DIR/ou-sb-firewall" <<EOF
#!/sbin/openrc-run
description="OU-SB Hysteria2 port hopping"
start() { $COMMAND_PATH --apply-firewall; }
stop() { $COMMAND_PATH --clear-firewall; }
EOF
        chmod +x "$OPENRC_DIR/sing-box" "$OPENRC_DIR/ou-sb-firewall"
        if [[ "${OU_SB_TESTING:-0}" != "1" ]]; then
            rc-update add ou-sb-firewall default >/dev/null 2>&1 || true
            rc-update add sing-box default >/dev/null 2>&1 || true
        fi
    else
        die "仅支持 systemd 或 OpenRC"
    fi
    install_watchdog
}

install_watchdog() {
    mkdir -p "$(dirname "$WATCHDOG_LOG")" 2>/dev/null || true

    # 1. 优先使用 systemd 原生定时器（每分钟巡检）
    if [[ $INIT_SYSTEM == systemd ]]; then
        mkdir -p "$SYSTEMD_DIR"
        cat > "$SYSTEMD_DIR/ou-sb-watchdog.service" <<EOF
[Unit]
Description=OU-SB Keepalive Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=$COMMAND_PATH --watchdog
EOF
        cat > "$SYSTEMD_DIR/ou-sb-watchdog.timer" <<EOF
[Unit]
Description=Run OU-SB Keepalive Watchdog every minute

[Timer]
OnBootSec=1m
OnUnitActiveSec=1m
Unit=ou-sb-watchdog.service

[Install]
WantedBy=timers.target
EOF
        local timer_ready=0
        if [[ "${OU_SB_TESTING:-0}" != "1" ]]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable --now ou-sb-watchdog.timer >/dev/null 2>&1 || true
            if systemctl is-active --quiet ou-sb-watchdog.timer 2>/dev/null; then
                timer_ready=1
            fi
        else
            timer_ready=1
        fi
        if ((timer_ready == 1)); then
            # 单一调度源：清掉历史版本叠加的 cron 任务，避免每分钟被唤醒两次
            remove_watchdog_cron_entries
            return 0
        fi
    fi

    # 2. cron 兜底（OpenRC、无 systemd，或定时器启用失败时）
    local cron_dir
    cron_dir="$(dirname "$CRON_FILE")"
    if [[ -d "$cron_dir" ]]; then
        cat > "$CRON_FILE" <<EOF
# OU-SB Keepalive Watchdog: every minute health-check and auto-recover sing-box
* * * * * root $COMMAND_PATH --watchdog >/dev/null 2>&1
EOF
        chmod 644 "$CRON_FILE" 2>/dev/null || true
        notify_cron_change
    elif [[ -f /etc/crontabs/root ]] || command -v crontab >/dev/null 2>&1; then
        if [[ -d /etc/crontabs ]]; then
            touch /etc/crontabs/root
            if ! grep -q -- "$COMMAND_PATH --watchdog" /etc/crontabs/root 2>/dev/null; then
                printf '* * * * * %s --watchdog >/dev/null 2>&1\n' "$COMMAND_PATH" >> /etc/crontabs/root
            fi
            notify_cron_change
        elif [[ "${OU_SB_TESTING:-0}" != "1" ]]; then
            (crontab -l 2>/dev/null | grep -v -- "$COMMAND_PATH --watchdog" || true; echo "* * * * * $COMMAND_PATH --watchdog >/dev/null 2>&1") | crontab - 2>/dev/null || true
        fi
    fi
}

# busybox crond（Alpine）只在 /etc/crontabs 目录 mtime 变化时才重新扫描 crontab，
# 就地追加/删除条目不会生效 —— 实测追加后等 95 秒任务仍未运行，touch 目录后立刻生效。
# 所以每次改动 cron 条目后都必须 touch 目录，否则看门狗永远不会被调度。
notify_cron_change() {
    if [[ -d /etc/crontabs ]]; then
        touch /etc/crontabs 2>/dev/null || true
    fi
    if [[ -d "$(dirname "$CRON_FILE")" ]]; then
        touch "$(dirname "$CRON_FILE")" 2>/dev/null || true
    fi
    if [[ "${OU_SB_TESTING:-0}" != "1" ]] && command -v rc-service >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    fi
}

remove_watchdog_cron_entries() {
    rm -f "$CRON_FILE" 2>/dev/null || true
    if [[ -f /etc/crontabs/root ]]; then
        sed -i "\|$COMMAND_PATH --watchdog|d" /etc/crontabs/root 2>/dev/null || true
    fi
    if [[ "${OU_SB_TESTING:-0}" != "1" ]] && command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v -- "$COMMAND_PATH --watchdog" || true) | crontab - 2>/dev/null || true
    fi
    notify_cron_change
}

uninstall_watchdog() {
    if [[ $INIT_SYSTEM == systemd ]]; then
        if [[ "${OU_SB_TESTING:-0}" != "1" ]]; then
            systemctl disable --now ou-sb-watchdog.timer >/dev/null 2>&1 || true
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        rm -f "$SYSTEMD_DIR/ou-sb-watchdog.service" "$SYSTEMD_DIR/ou-sb-watchdog.timer"
    fi
    remove_watchdog_cron_entries
}

log_watchdog() {
    local msg=$1
    mkdir -p "$(dirname "$WATCHDOG_LOG")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$WATCHDOG_LOG" 2>/dev/null || true
    if [[ -f "$WATCHDOG_LOG" ]]; then
        local line_count
        line_count=$(wc -l < "$WATCHDOG_LOG" 2>/dev/null || echo 0)
        if ((line_count > 500)); then
            local tmp_log
            tmp_log=$(mktemp "$APP_DIR/watchdog.XXXXXX" 2>/dev/null || mktemp /tmp/watchdog.XXXXXX)
            tail -n 200 "$WATCHDOG_LOG" > "$tmp_log" 2>/dev/null && mv -f "$tmp_log" "$WATCHDOG_LOG"
        fi
    fi
}

recover_config_from_backup() {
    log_watchdog "[ALERT] 当前配置文件校验失败，尝试从最近备份中寻找有效配置恢复..."
    local b
    for b in $(ls -t "$BACKUP_DIR"/config[-.]*.json 2>/dev/null || true); do
        if validate_candidate "$b"; then
            cp -f "$b" "$CONFIG_PATH"
            chmod 600 "$CONFIG_PATH"
            log_watchdog "[OK] 已成功从有效备份 $(basename "$b") 恢复配置"
            return 0
        fi
    done
    log_watchdog "[ERR] 未找到任何有效配置备份，自愈终止"
    return 1
}

run_watchdog() {
    mkdir -p "$(dirname "$WATCHDOG_LOCK")" 2>/dev/null || true
    exec 8>"$WATCHDOG_LOCK" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        flock -n 8 2>/dev/null || return 0
    fi

    # 未安装则不处理
    if [[ "${OU_SB_TESTING:-0}" != "1" ]]; then
        command -v sing-box >/dev/null 2>&1 || return 0
    fi

    # 1. 廉价结构校验（只起 jq）：捕获配置被截断/非法 JSON 等断电损坏
    local need_restart=0
    if ! config_structurally_valid "$CONFIG_PATH"; then
        recover_config_from_backup || return 1
        need_restart=1
    fi

    # 2. 如果配置正常但没有任何入站协议，则不需要运行服务
    local inbound_count
    inbound_count=$(jq '.inbounds | length' "$CONFIG_PATH" 2>/dev/null || echo 0)
    ((inbound_count > 0)) || return 0

    # 3. 服务正在启动/停止/被监督进程重启中，本次不插手
    if service_in_transition; then
        return 0
    fi

    local is_active=1 has_process=1
    if service_is_active; then is_active=0; fi
    # 用 pidof 优先的探测：Alpine 的 pgrep 是 busybox 符号链接，pgrep -x 匹配不到运行中的 sing-box，
    # 会造成"进程不存在"的误判并每分钟重启一次服务。
    if is_sing_box_process_running; then has_process=0; fi
    if [[ "${OU_SB_TESTING:-0}" == "1" && "${OU_SB_TEST_WATCHDOG_DEAD:-0}" != "1" ]]; then
        is_active=0; has_process=0
    fi

    # 健康且正常运行：不做完整 sing-box check，直接返回（每分钟省下一个 Go 进程）
    if ((is_active == 0 && has_process == 0 && need_restart == 0)); then
        return 0
    fi

    # 4. 需要重启/回滚前才做完整校验，避免带着 schema 错误的配置去反复重启
    if ((need_restart == 0)) && ! validate_candidate "$CONFIG_PATH"; then
        recover_config_from_backup || return 1
        need_restart=1
    fi

    log_watchdog "[WARN] 检测到 sing-box 异常 (active=$is_active, process=$has_process)，启动自愈恢复..."
    if ((need_restart == 1)); then
        log_watchdog "[INFO] 配置已从备份回滚，重启服务以加载恢复后的配置"
    fi

    # 5. 清理可能卡死端口的僵尸孤立进程
    if [[ "${OU_SB_TESTING:-0}" != "1" ]]; then
        if ((is_active != 0 && has_process == 0)); then
            log_watchdog "[INFO] 检测到服务停止但进程仍在，清理残留进程以释放端口..."
            # killall/pkill -f 在 busybox 上可用；pkill -x 在 busybox 上匹配不到进程
            kill_sing_box_process
            sleep 1
        fi
        apply_hy2_firewall >/dev/null 2>&1 || true
    fi

    # 6. 通过服务管理器拉起
    if [[ "$INIT_SYSTEM" == "systemd" && "${OU_SB_TESTING:-0}" != "1" ]]; then
        systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    if service_restart >/dev/null 2>&1 || service_start >/dev/null 2>&1; then
        [[ "${OU_SB_TESTING:-0}" != "1" ]] && sleep 1
        if service_is_active || is_sing_box_process_running || [[ "${OU_SB_TESTING:-0}" == "1" ]]; then
            log_watchdog "[OK] 自愈成功：sing-box 服务已成功拉起并恢复运行"
            return 0
        fi
    fi

    # 7. 不再绕过服务管理器用 nohup 手动拉起：那样会与 Restart=always 的单元抢端口，
    #    形成「systemd 每 3 秒重试 + 野进程占住端口」的永久循环，既烧 CPU 又让 systemctl 管不住，
    #    而且单元里的 GOMEMLIMIT / OOMScoreAdjust 对该进程全部失效。
    #    这里只记录明确错误，交由服务管理器与下一次巡检继续处理。
    log_watchdog "[ERR] 服务管理器未能拉起 sing-box，请用 sb --doctor 与 journalctl -u $SERVICE_NAME 排查"
    return 1
}

show_watchdog_log() {
    printf '%s=== 保活看门狗自愈日志（最近 50 条）===%s\n' "$C_CYAN" "$C_RESET"
    if [[ -s "$WATCHDOG_LOG" ]]; then
        tail -n 50 "$WATCHDOG_LOG"
    else
        printf '暂无自愈日志（未发生异常拉起事件）\n'
    fi
}

watchdog_menu() {
    local choice
    while true; do
        banner
        printf '%s保活看门狗与自愈管理%s\n\n' "$C_CYAN" "$C_RESET"
        printf '  当前服务状态：%s\n' "$(get_service_status_text)"
        printf '  看门狗巡检  ：%s\n' "$(get_watchdog_status_text)"
        printf '  自愈日志文件：%s\n\n' "$WATCHDOG_LOG"
        cat <<'EOF'
1) 立即执行健康巡检与自愈测试
2) 查看最近自愈巡检日志
3) 重新安装并启用保活看门狗
4) 停止并卸载保活看门狗
0) 返回主菜单
EOF
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                info "正在执行健康巡检..."
                if run_watchdog; then
                    ok "巡检完成，服务状态良好"
                else
                    warn "巡检执行完毕，请检查日志"
                fi
                pause_screen
                ;;
            2)
                show_watchdog_log
                pause_screen
                ;;
            3)
                setup_services
                ok "服务加固配置与看门狗已重新应用并启用"
                service_restart >/dev/null 2>&1 || true
                pause_screen
                ;;
            4)
                uninstall_watchdog
                ok "保活看门狗已停止并移除"
                pause_screen
                ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

install_self() {
    local source_path=${BASH_SOURCE[0]}
    mkdir -p "$INSTALL_DIR" "$(dirname "$COMMAND_PATH")"
    if [[ -f $source_path && $source_path != /dev/fd/* && $source_path != /proc/self/fd/* ]]; then
        install -m 755 "$source_path" "$INSTALL_PATH"
    else
        curl -fsSL "$RAW_SCRIPT_URL" -o "$INSTALL_PATH"
        chmod 755 "$INSTALL_PATH"
    fi
    ln -sfn "$INSTALL_PATH" "$COMMAND_PATH"
}

update_ou_sb() {
    local tmp
    tmp=$(mktemp)
    curl -fsSL "$RAW_SCRIPT_URL" -o "$tmp"
    bash -n "$tmp" || { rm -f "$tmp"; warn "下载的新脚本语法校验失败"; return 1; }
    install -m 755 "$tmp" "$INSTALL_PATH"
    rm -f "$tmp"
    ok "OU-SB 已更新"
}

update_sing_box() {
    local channel=stable
    protocol_exists "$TAG_SNELL" && channel=beta
    install_sing_box "$channel"
    if validate_candidate "$CONFIG_PATH"; then
        if service_restart; then
            ok "sing-box 已更新并重启"
        else
            warn "sing-box 更新成功，但服务重启失败"
        fi
    else
        warn "更新后的 sing-box 无法通过当前配置校验"
        return 1
    fi
}

uninstall_ou_sb() {
    local answer candidate count remove_sb sb_binary
    read -r -p "确认卸载 OU-SB 并删除其协议？[y/N]: " answer
    [[ $answer =~ ^[Yy]$ ]] || return 0
    read -r -p "是否同时删除 sing-box 程序、服务和配置残留？[y/N]: " remove_sb
    clear_hy2_firewall || true
    candidate=$(mktemp "$SB_DIR/.config.XXXXXX")
    jq '.inbounds = [.inbounds[] | select((.tag // "") | startswith("ou-sb-") | not)]' "$CONFIG_PATH" > "$candidate"
    commit_candidate "$candidate" "OU-SB 协议已移除" || return
    count=$(jq '.inbounds | length' "$CONFIG_PATH")
    if ((count == 0)); then
        service_stop || true
        uninstall_watchdog || true
        if [[ $INIT_SYSTEM == systemd ]]; then
            systemctl disable sing-box ou-sb-firewall >/dev/null 2>&1 || true
            rm -f "$SYSTEMD_DIR/sing-box.service" "$SYSTEMD_DIR/ou-sb-firewall.service"
            systemctl daemon-reload
        else
            rc-update del sing-box default >/dev/null 2>&1 || true
            rc-update del ou-sb-firewall default >/dev/null 2>&1 || true
            rm -f "$OPENRC_DIR/sing-box" "$OPENRC_DIR/ou-sb-firewall"
        fi
    fi
    rm -f "$COMMAND_PATH" "$WATCHDOG_LOG" "$WATCHDOG_LOCK" "$CRON_FILE"
    rm -rf "$APP_DIR" "$INSTALL_DIR"
    if [[ $remove_sb =~ ^[Yy]$ ]]; then
        sb_binary=$(command -v sing-box 2>/dev/null || true)
        [[ -n $sb_binary && $sb_binary == /usr/local/bin/sing-box ]] && rm -f -- "$sb_binary"
        rm -f -- /usr/local/bin/sing-box
        rm -rf -- "$SB_DIR"
        ok "OU-SB 与 sing-box 程序、服务和残留已删除"
    else
        ok "OU-SB 已卸载；sing-box 程序本体已保留"
    fi
    exit 0
}

pause_screen() {
    if [[ -t 0 ]]; then
        read -r -p "按 Enter 返回..." _ || true
    fi
}

memory_recommendation() {
    local mb
    mb=$(awk '/MemTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 1024)
    if ((mb < 512)); then printf '4'; elif ((mb < 1024)); then printf '8'; elif ((mb < 2048)); then printf '16'; else printf '32'; fi
}

bbr_status() {
    printf '%s当前网络状态%s\n' "$C_CYAN" "$C_RESET"
    printf '  拥塞控制：%s%s%s\n' "$C_GREEN" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)" "$C_RESET"
    printf '  队列调度：%s%s%s\n' "$C_GREEN" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)" "$C_RESET"
}

enable_bbr_fq() {
    command -v sysctl >/dev/null 2>&1 || { warn "未找到 sysctl"; return 1; }
    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr >/dev/null || { warn "BBR 开启失败"; return 1; }
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-ou-sb-network.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    ok "✅ BBR + FQ 已开启"
}

tcp_tuning() {
    local rec_mb choice mb max
    rec_mb=$(memory_recommendation)
    printf '%s推荐值%s：根据检测到的物理内存自动选择 %s MB\n' "$C_CYAN" "$C_RESET" "$rec_mb"
    cat <<EOF
1) 推荐值（${rec_mb} MB）
2) 4 MB（低内存）
3) 8 MB（均衡）
4) 16 MB（高吞吐）
5) 32 MB（大内存）
6) 自定义 MB
0) 返回
EOF
    read -r -p "选择 [默认 1]: " choice
    choice=${choice:-1}
    case "$choice" in
        1) mb=$rec_mb ;; 2) mb=4 ;; 3) mb=8 ;; 4) mb=16 ;; 5) mb=32 ;;
        6) read -r -p "请输入缓冲区大小（MB）: " mb ;;
        0) return 0 ;; *) warn "无效选项"; return 1 ;;
    esac
    [[ $mb =~ ^[0-9]+$ && $mb -ge 1 && $mb -le 1024 ]] || { warn "请输入 1-1024 之间的 MB 数值"; return 1; }
    max=$((mb * 1024 * 1024))
    sysctl -w net.core.rmem_max="$max" net.core.wmem_max="$max" \
        net.ipv4.tcp_rmem="4096 87380 $max" net.ipv4.tcp_wmem="4096 65536 $max" >/dev/null
    mkdir -p /etc/sysctl.d
    cat >> /etc/sysctl.d/99-ou-sb-network.conf <<EOF
net.core.rmem_max=$max
net.core.wmem_max=$max
net.ipv4.tcp_rmem=4096 87380 $max
net.ipv4.tcp_wmem=4096 65536 $max
EOF
    ok "✅ TCP 缓冲区已设置为 ${mb} MB"
}

network_tuning_menu() {
    local choice
    bbr_status
    cat <<'EOF'
1) 开启 BBR + FQ
2) 关闭 BBR（恢复 cubic）
3) TCP 缓冲区调优
0) 返回
EOF
    read -r -p "选择: " choice
    case "$choice" in
        1) enable_bbr_fq ;; 2) sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null && ok "已切换为 cubic" ;;
        3) tcp_tuning ;; 0) return 0 ;; *) warn "无效选项" ;;
    esac
}

main_menu() {
    local choice
    while true; do
        banner
        printf '  %s服务状态%s：%s  |  %s保活看门狗%s：%s\n\n' \
            "$C_BOLD" "$C_RESET" "$(get_service_status_text)" \
            "$C_BOLD" "$C_RESET" "$(get_watchdog_status_text)"
        show_protocol_status
        printf '%s快捷按键：sb%s（随时输入 sb 可重新打开管理面板）\n' "$C_CYAN" "$C_RESET"
        printf '\n%s%s操作菜单%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET"
        printf '  %s1)%s 查看节点配置\n' "$C_GREEN" "$C_RESET"
        printf '  %s2)%s 添加协议\n' "$C_GREEN" "$C_RESET"
        printf '  %s3)%s 删除协议\n' "$C_GREEN" "$C_RESET"
        printf '  %s4)%s 修改协议端口\n' "$C_GREEN" "$C_RESET"
        printf '  %s5)%s HY2 端口跳跃\n' "$C_GREEN" "$C_RESET"
        printf '  %s6)%s 节点信息\n' "$C_GREEN" "$C_RESET"
        printf '  %s7)%s 启动服务\n' "$C_GREEN" "$C_RESET"
        printf '  %s8)%s 停止服务\n' "$C_GREEN" "$C_RESET"
        printf '  %s9)%s 重启服务\n' "$C_GREEN" "$C_RESET"
        printf '  %s10)%s BBR+FQ 与 TCP 调优\n' "$C_GREEN" "$C_RESET"
        printf '  %s11)%s 保活看门狗管理（自动拉起/自愈日志）\n' "$C_GREEN" "$C_RESET"
        printf '  %s12)%s 更新 sing-box\n' "$C_GREEN" "$C_RESET"
        printf '  %s13)%s 更新 OU-SB\n' "$C_GREEN" "$C_RESET"
        printf '  %s14)%s 卸载 OU-SB\n' "$C_GREEN" "$C_RESET"
        printf '  %s0)%s 退出\n' "$C_RED" "$C_RESET"
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) show_links; pause_screen ;; 2) add_protocol_menu; pause_screen ;;
            3) remove_protocol_menu; pause_screen ;; 4) change_protocol_port; pause_screen ;;
            5) configure_hy2_hopping; pause_screen ;; 6) configure_identity; pause_screen ;;
            7) if service_start; then ok "服务已启动"; else warn "服务启动失败"; fi; pause_screen ;;
            8) if service_stop; then ok "服务已停止"; else warn "服务停止失败"; fi; pause_screen ;;
            9) if service_restart; then ok "服务已重启"; else warn "服务重启失败"; fi; pause_screen ;;
            10) network_tuning_menu; pause_screen ;; 11) watchdog_menu ;;
            12) update_sing_box; pause_screen ;; 13) update_ou_sb; pause_screen ;;
            14) uninstall_ou_sb ;; 0) exit 0 ;;
            *) warn "⚠️ 无效选项"; sleep 1 ;;
        esac
    done
}

first_run() {
    local answer current_cc current_qdisc
    if command -v sing-box >/dev/null 2>&1; then
        info "检测到 $(sing-box version 2>/dev/null | head -n1)"
    else
        install_sing_box stable
    fi
    install_self
    setup_services
    printf '%s%s首次运行协议%s
' "$C_MAGENTA" "$C_BOLD" "$C_RESET"
    printf '该脚本会修改 sing-box 配置、服务和防火墙规则。继续请准确输入大写 YES：'
    read -r answer
    [[ $answer == YES ]] || die "未确认协议，已退出"
    configure_identity_ip
    printf '%s网络优化%s\n' "$C_MAGENTA" "$C_RESET"
    read -r -p "首次安装现在检测并配置 BBR + FQ / TCP 调优？[Y/n]: " answer
    if [[ ! $answer =~ ^[Nn]$ ]]; then
        bbr_status
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
        if [[ $current_cc != bbr || $current_qdisc != fq ]]; then
            read -r -p "回车开启 BBR + FQ，输入 n 跳过: " answer
            [[ ! $answer =~ ^[Nn]$ ]] && enable_bbr_fq
        fi
        printf '%s按 Enter 进入 TCP 调优%s\n' "$C_CYAN" "$C_RESET"
        read -r -p "继续: " _
        tcp_tuning
    fi
    read -r -p "现在添加第一个协议？（直接回车添加，输入 n 跳过）: " answer
    [[ ! $answer =~ ^[Nn]$ ]] && add_protocol_menu
    apply_hy2_firewall || true
    service_restart || service_start || warn "服务启动失败，请使用 sb 查看状态"
}

cli_status() {
    printf '%s %s\n' "$APP_NAME" "$APP_VERSION"
    printf 'OS: %s | init: %s\n' "$OS_FAMILY" "$INIT_SYSTEM"
    printf '服务状态: %s\n' "$(get_service_status_text)"
    printf '保活看门狗: %s\n' "$(get_watchdog_status_text)"
    if command -v sing-box >/dev/null 2>&1; then
        printf 'sing-box: %s\n' "$(sing-box version 2>/dev/null | head -n1)"
    else
        printf 'sing-box: 未安装\n'
    fi
    printf '配置: %s\n' "$CONFIG_PATH"
    if [[ -s "$CONFIG_PATH" ]]; then
        jq -r '.inbounds[]?.tag // empty' "$CONFIG_PATH" | sed 's/^/协议: /'
    fi
}

cli_validate() {
    validate_candidate "$CONFIG_PATH" || die "配置校验失败"
    jq -e . "$STATE_PATH" >/dev/null || die "状态文件校验失败"
    ok "配置和状态校验通过"
}

cli_backup() {
    [[ -s "$CONFIG_PATH" ]] || die "配置文件不存在"
    backup_config
}

cli_export() {
    show_links
}

doctor() {
    local missing=() command
    for command in bash curl jq openssl flock ss awk grep sed base64 tar sha256sum install find; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    if ((${#missing[@]})); then
        warn "缺少依赖：${missing[*]}"
        return 1
    fi
    ok "基础依赖完整"
    cli_validate
    info "检测系统内存与小鸡保护机制..."
    local mem_total
    mem_total=$(detect_memory_mb)
    info "检测到系统物理内存: ${mem_total} MB"
    local gomemlimit gogc
    read -r gomemlimit gogc <<< "$(get_sing_box_mem_limits)"
    if [[ -n $gomemlimit ]]; then
        ok "NAT 低内存保护已生效: GOMEMLIMIT=${gomemlimit}（GOGC 保持 Go 默认值，避免 GC 频繁触发推高 CPU）"
    else
        info "内存较充裕 (>1024MB)，使用标准垃圾回收"
    fi
    if service_is_active; then
        ok "sing-box 服务正在运行"
    else
        warn "sing-box 服务未处于运行状态"
    fi
    local live_adj
    if live_adj=$(live_oom_score_adj); then
        if ((live_adj < 0)); then
            ok "OOM 优先级保护已生效: oom_score_adj=${live_adj}"
        else
            warn "oom_score_adj=${live_adj}，负值保护未生效：本容器不允许写负 oom_score_adj（需要宿主命名空间的 CAP_SYS_RESOURCE）"
            info "  → sing-box 不会获得 OOM 优先级保护，请依赖 GOMEMLIMIT，并避免在低内存小鸡上跑 IP 体检/测速类重负载脚本"
        fi
    fi
    ok "保活看门狗配置状态: $(get_watchdog_status_text)"
}

usage() {
    cat <<EOF
$APP_NAME $APP_VERSION
用法：
  sb                     打开管理面板
  sb --apply-firewall    恢复 OU-SB 的 HY2 跳跃规则
  sb --clear-firewall    清理 OU-SB 的 HY2 跳跃规则
  sb --watchdog          执行保活看门狗健康巡检与自愈
  sb --watchdog-log      查看保活看门狗自愈日志
  sb --setup-services    重新应用服务加固配置与看门狗（升级后推荐）
  sb --remove-watchdog   停止并卸载保活看门狗
  sb --status            查看系统、服务和协议状态
  sb --validate          校验配置和状态文件
  sb --backup            创建配置备份
  sb --export            输出客户端连接信息
  sb --doctor            检查依赖、服务保活和配置
  sb --version           显示版本
EOF
}

main() {
    init_colors
    detect_platform
    require_root

    # 关键：保活类子命令必须在 ensure_base_config 与 acquire_lock 之前分发，而且不能触发依赖安装。
    # 否则会出现三个问题：
    #   1) 配置损坏时 ensure_base_config 会先 die，--watchdog 永远走不到回滚自愈逻辑；
    #   2) 管理面板一直持有 ou-sb.lock，看门狗每分钟都会被 flock 拒绝而静默失效；
    #   3) 每分钟一次的巡检若因缺依赖去跑 apt/apk，会把小鸡 CPU 直接打满。
    case "${1:-}" in
        --watchdog)
            prepare_directories
            init_state
            run_watchdog
            exit $?
            ;;
        --watchdog-log) show_watchdog_log; exit $? ;;
        --remove-watchdog) uninstall_watchdog; exit $? ;;
    esac

    install_dependencies
    prepare_directories
    init_state

    # 保活/加固类命令在配置损坏时也必须可用，因此同样放在 ensure_base_config 与 acquire_lock 之前
    case "${1:-}" in
        --install-watchdog) install_watchdog; exit $? ;;
        --setup-services|--harden)
            setup_services
            ok "服务配置与看门狗已全部加固更新"
            service_restart >/dev/null 2>&1 || true
            exit 0
            ;;
        --apply-firewall) apply_hy2_firewall; exit $? ;;
        --clear-firewall) clear_hy2_firewall; exit $? ;;
    esac

    acquire_lock
    ensure_base_config
    case "${1:-}" in
        --status) cli_status; exit $? ;;
        --validate) cli_validate; exit $? ;;
        --backup) cli_backup; exit $? ;;
        --export) cli_export; exit $? ;;
        --doctor) doctor; exit $? ;;
        --version) printf '%s %s\n' "$APP_NAME" "$APP_VERSION"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        "") ;;
        *) usage; exit 1 ;;
    esac
    if [[ ! -x $COMMAND_PATH || ! -x $INSTALL_PATH ]] || ! command -v sing-box >/dev/null 2>&1; then
        banner
        first_run
    fi
    main_menu
}

init_colors
if [[ "${OU_SB_LIB_ONLY:-0}" != "1" ]]; then
    main "$@"
fi

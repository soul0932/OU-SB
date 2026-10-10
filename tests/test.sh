#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/ou-sb-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

export OU_SB_LIB_ONLY=1
export OU_SB_TESTING=1
export OU_SB_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$PROJECT_DIR/OU-SB.sh"

passes=0
failures=0

pass() {
    printf 'ok - %s\n' "$1"
    passes=$((passes + 1))
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

assert_true() {
    local name=$1
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

assert_false() {
    local name=$1
    shift
    if "$@"; then fail "$name"; else pass "$name"; fi
}

assert_eq() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then
        pass "$name"
    else
        fail "$name (expected=$expected actual=$actual)"
    fi
}

prepare_directories
init_state
ensure_base_config

assert_true "base config is valid JSON" jq -e '.inbounds == [] and .outbounds[0].tag == "direct-out"' "$CONFIG_PATH"

vless_uuid="11111111-2222-3333-4444-555555555555"
vless=$(jq -nc --arg tag "$TAG_VLESS" --arg uuid "$vless_uuid" '{
    type:"vless", tag:$tag, listen:"::", listen_port:443,
    users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
    tls:{enabled:true, reality:{enabled:true, private_key:"private", short_id:["aabbccdd"]}}
}')
assert_true "add VLESS" apply_inbound_json "$TAG_VLESS" "$vless"

ss=$(jq -nc --arg tag "$TAG_SS" '{
    type:"shadowsocks", tag:$tag, listen:"::", listen_port:1443,
    method:"2022-blake3-aes-128-gcm", password:"cGFzc3dvcmQxMjM0NTY="
}')
assert_true "add SS after VLESS" apply_inbound_json "$TAG_SS" "$ss"
assert_eq "VLESS credentials survive SS addition" "$vless_uuid" "$(jq -r --arg tag "$TAG_VLESS" '.inbounds[]|select(.tag==$tag)|.users[0].uuid' "$CONFIG_PATH")"
assert_eq "two protocols coexist" "2" "$(jq '.inbounds|length' "$CONFIG_PATH")"

if apply_inbound_json "$TAG_SS" "$ss" >/dev/null 2>&1; then
    fail "duplicate tag is rejected"
else
    pass "duplicate tag is rejected"
fi
assert_eq "duplicate attempt keeps inbound count" "2" "$(jq '.inbounds|length' "$CONFIG_PATH")"

assert_true "remove SS only" remove_inbound_tags "test remove" "$TAG_SS"
assert_true "VLESS remains after SS removal" protocol_exists "$TAG_VLESS"
assert_false "SS is gone" protocol_exists "$TAG_SS"

assert_true "valid continuous hop range" valid_hop_spec "20000-30000"
assert_true "valid mixed hop range" valid_hop_spec "20000,21000-22000,23000"
assert_false "reject descending range" valid_hop_spec "30000-20000"
assert_false "reject out-of-range port" valid_hop_spec "0,65536"
assert_false "reject whitespace" valid_hop_spec "20000, 21000"
assert_eq "convert hop range for sing-box" '["20000","21000:22000"]' "$(hop_spec_to_server_ports '20000,21000-22000' | jq -c .)"
assert_true "detect port inside hop range" hop_spec_contains_port "20000,21000-22000" "21500"
assert_false "detect port outside hop range" hop_spec_contains_port "20000,21000-22000" "23000"
assert_true "valid DDNS endpoint" valid_endpoint_host "node.example.com"
assert_true "valid IPv6 endpoint" valid_endpoint_host "2001:db8::1"
assert_false "reject endpoint injection characters" valid_endpoint_host "host,evil"
assert_eq "map x86_64 release architecture" "amd64" "$(normalize_sing_box_arch x86_64)"
assert_eq "map Alpine aarch64 release architecture" "arm64" "$(normalize_sing_box_arch aarch64)"
assert_eq "map 32-bit ARM release architecture" "armv7" "$(normalize_sing_box_arch armv7l)"
assert_false "reject unsupported release architecture" normalize_sing_box_arch "sparc64"

before=$(sha256sum "$CONFIG_PATH" | awk '{print $1}')
bad_candidate=$(mktemp "$SB_DIR/.config.XXXXXX")
jq '.log.level="debug"' "$CONFIG_PATH" > "$bad_candidate"
export OU_SB_FORCE_CHECK_FAIL=1
if commit_candidate "$bad_candidate" "forced failure" >/dev/null 2>&1; then
    fail "failed validation is rejected"
else
    pass "failed validation is rejected"
fi
unset OU_SB_FORCE_CHECK_FAIL
after=$(sha256sum "$CONFIG_PATH" | awk '{print $1}')
assert_eq "failed validation leaves config untouched" "$before" "$after"

snell=$(jq -nc --arg tag "$TAG_SNELL" '{
    type:"snell", tag:$tag, listen:"::", listen_port:6160,
    version:5, psk:"123456789012", obfs_mode:"http"
}')
assert_true "add Snell v5-compatible inbound" apply_inbound_json "$TAG_SNELL" "$snell"
# shellcheck disable=SC2016
assert_true "Snell uses supported HTTP obfs" jq -e --arg tag "$TAG_SNELL" '.inbounds[]|select(.tag==$tag)|.version==5 and .obfs_mode=="http"' "$CONFIG_PATH"

anytls=$(jq -nc --arg tag "$TAG_ANYTLS" '{
    type:"anytls", tag:$tag, listen:"::", listen_port:2443,
    users:[{name:"ou-sb", password:"anytls-password"}],
    tls:{enabled:true, server_name:"example.com", reality:{enabled:true,
        private_key:"private", short_id:["1122334455667788"]}}
}')
assert_true "add AnyTLS alongside VLESS" apply_inbound_json "$TAG_ANYTLS" "$anytls"
state_set_string 'public_host' 'node.example.com'
state_set_string 'reality.vless.public_key' 'vless-public-key'
state_set_string 'reality.anytls.public_key' 'anytls-public-key'
links=$(show_links)
assert_true "VLESS link is explicitly TCP Vision Reality" grep -q 'flow=xtls-rprx-vision&security=reality&type=tcp' <<< "$links"
assert_true "VLESS keeps its own Reality public key" grep -q 'pbk=vless-public-key' <<< "$links"
assert_true "AnyTLS keeps a separate Reality public key" grep -q 'pbk=anytls-public-key' <<< "$links"

trojan=$(jq -nc --arg tag "$TAG_TROJAN" '{type:"trojan", tag:$tag, listen:"::", listen_port:3443, users:[{name:"ou-sb", password:"trojan-password"}], tls:{enabled:true, certificate_path:"/tmp/fullchain.pem", key_path:"/tmp/privkey.pem"}}')
assert_true "add Trojan TLS inbound" apply_inbound_json "$TAG_TROJAN" "$trojan"
trojan_links=$(show_links)
assert_true "Trojan link is exported" grep -q '^trojan://' <<< "$trojan_links"
assert_true "Trojan tag is managed" protocol_exists "$TAG_TROJAN"

assert_true "remove menu contains Trojan and Snell" grep -q '6) Trojan TLS' "$PROJECT_DIR/OU-SB.sh"
assert_true "remove menu keeps Snell at option 7" grep -q '7) Snell' "$PROJECT_DIR/OU-SB.sh"

# 1. 内存检测与 Go runtime 内存限额测试
mem_detected=$(detect_memory_mb)
assert_true "detect_memory_mb returns positive integer" test "$mem_detected" -gt 0

# Mock memory function to test tiered limits
detect_memory_mb() { echo 128; }
assert_eq "tier 128M limit" "70MiB " "$(get_sing_box_mem_limits)"
detect_memory_mb() { echo 256; }
assert_eq "tier 256M limit" "150MiB " "$(get_sing_box_mem_limits)"
detect_memory_mb() { echo 512; }
assert_eq "tier 512M limit" "320MiB " "$(get_sing_box_mem_limits)"
detect_memory_mb() { echo 1024; }
assert_eq "tier 1024M limit" "700MiB " "$(get_sing_box_mem_limits)"
detect_memory_mb() { echo 2048; }
assert_eq "tier >1024M has no hard limits" " " "$(get_sing_box_mem_limits)"
detect_memory_mb() { echo 128; }
assert_false "no GOGC override (GC frequency would raise CPU)" grep -q 'GOGC' <(get_sing_box_mem_limits)
unset -f detect_memory_mb

# 2. setup_services (systemd) 加固测试
INIT_SYSTEM="systemd"
detect_memory_mb() { echo 256; }
# 预置一个历史版本叠加的 cron 任务，验证安装 systemd timer 时会被清理（避免每分钟双重唤醒）
mkdir -p "$(dirname "$CRON_FILE")"
printf '* * * * * root %s --watchdog >/dev/null 2>&1\n' "$COMMAND_PATH" > "$CRON_FILE"
setup_services
assert_true "systemd service has Restart=always" grep -q "Restart=always" "$SYSTEMD_DIR/sing-box.service"
assert_true "systemd service keeps restart rate limit" grep -q "^StartLimitIntervalSec=60" "$SYSTEMD_DIR/sing-box.service"
assert_true "systemd service limits restart burst" grep -q "^StartLimitBurst=5" "$SYSTEMD_DIR/sing-box.service"
assert_eq "restart limit declared once ([Unit] only)" "1" "$(grep -c 'StartLimitIntervalSec=' "$SYSTEMD_DIR/sing-box.service")"
assert_true "systemd service has RestartSec=3s" grep -q "RestartSec=3s" "$SYSTEMD_DIR/sing-box.service"
assert_true "systemd service has OOMScoreAdjust=-500" grep -q "OOMScoreAdjust=-500" "$SYSTEMD_DIR/sing-box.service"
assert_true "systemd service sets GOMEMLIMIT on low ram" grep -q "Environment=\"GOMEMLIMIT=150MiB\"" "$SYSTEMD_DIR/sing-box.service"
assert_false "systemd service does not force GOGC" grep -q "GOGC" "$SYSTEMD_DIR/sing-box.service"
assert_true "systemd watchdog timer created" grep -q "OnUnitActiveSec=1m" "$SYSTEMD_DIR/ou-sb-watchdog.timer"
assert_false "timer mode drops duplicated cron watchdog" test -f "$CRON_FILE"
unset -f detect_memory_mb

# 3. setup_services (openrc) 加固测试
INIT_SYSTEM="openrc"
detect_memory_mb() { echo 128; }
setup_services
assert_true "openrc service uses supervise-daemon" grep -q 'supervisor="supervise-daemon"' "$OPENRC_DIR/sing-box"
assert_true "openrc service sets respawn delay" grep -q 'respawn_delay=3' "$OPENRC_DIR/sing-box"
assert_true "openrc service exports GOMEMLIMIT" grep -q 'export GOMEMLIMIT="70MiB"' "$OPENRC_DIR/sing-box"
assert_true "openrc service adjusts oom score" grep -q -- '--oom-score-adj -500' "$OPENRC_DIR/sing-box"
assert_true "openrc service keeps log redirection (supervise-daemon maps output_log)" grep -q 'output_log="/var/log/sing-box.log"' "$OPENRC_DIR/sing-box"
assert_true "openrc falls back to cron watchdog" test -f "$CRON_FILE"
unset -f detect_memory_mb

# 4. run_watchdog 自动回滚与自愈测试
# 先创建一个有效备份
valid_backup=$(backup_config)
assert_true "backup file is created before corruption" test -s "$valid_backup"
# 故意破坏当前配置文件
echo '{ invalid json syntax' > "$CONFIG_PATH"
assert_false "config is broken" validate_candidate "$CONFIG_PATH"
# 触发 watchdog 自愈
export OU_SB_TEST_WATCHDOG_DEAD=1
assert_true "run_watchdog recovers from backup" run_watchdog
assert_true "config is restored and valid" validate_candidate "$CONFIG_PATH"
assert_true "watchdog log records recovery" grep -q "已成功从有效备份" "$WATCHDOG_LOG"
unset OU_SB_TEST_WATCHDOG_DEAD
# 释放第 4 节在进程内持有的看门狗锁，否则子进程巡检会被 flock 拒绝
exec 8>&- 2>/dev/null || true

# 5. main() 入口回归测试：配置损坏时 --watchdog 必须仍能自愈（不能被预检 ensure_base_config 拦住）
run_watchdog_cli() {
    OU_SB_LIB_ONLY=0 OU_SB_ROOT="$TEST_ROOT" OU_SB_TESTING=1 \
        OU_SB_WATCHDOG_LOCK="$TEST_ROOT/watchdog-cli.lock" \
        bash "$PROJECT_DIR/OU-SB.sh" --watchdog
}

backup_config >/dev/null
rm -f "$WATCHDOG_LOG"
printf '{ "inbounds": [ THIS IS NOT JSON\n' > "$CONFIG_PATH"
if run_watchdog_cli >/dev/null 2>&1; then
    pass "main --watchdog survives invalid JSON config"
else
    fail "main --watchdog survives invalid JSON config"
fi
assert_true "main --watchdog restores valid config" validate_candidate "$CONFIG_PATH"
assert_true "main --watchdog logs rollback from backup" grep -q "已成功从有效备份" "$WATCHDOG_LOG"
assert_true "main --watchdog restarts service after rollback" grep -q "配置已从备份回滚" "$WATCHDOG_LOG"

: > "$CONFIG_PATH"
if run_watchdog_cli >/dev/null 2>&1; then
    pass "main --watchdog survives truncated config"
else
    fail "main --watchdog survives truncated config"
fi
assert_true "truncated config restored instead of emptied" jq -e '.inbounds | length > 0' "$CONFIG_PATH"

assert_false "watchdog no longer uses emergency nohup fallback" grep -q '应急后台直接拉起' "$PROJECT_DIR/OU-SB.sh"

# 6. 健康路径必须廉价：结构正常 + 服务健康时不启动 sing-box check（128M 小鸡每分钟一个 Go 进程）
rm -f "$WATCHDOG_LOG"
run_watchdog >/dev/null 2>&1 || true
export OU_SB_FORCE_CHECK_FAIL=1
if run_watchdog; then
    pass "healthy watchdog skips expensive sing-box check"
else
    fail "healthy watchdog skips expensive sing-box check"
fi
assert_false "healthy watchdog does not fall into rollback" test -s "$WATCHDOG_LOG"
unset OU_SB_FORCE_CHECK_FAIL

# 7. 服务正在启动/停止/被监督进程重启时看门狗必须让路（1 核小机慢启动很常见）
export OU_SB_TEST_WATCHDOG_DEAD=1 OU_SB_TEST_SERVICE_TRANSITION=1
rm -f "$WATCHDOG_LOG"
if run_watchdog; then
    pass "watchdog stands down while service is in transition"
else
    fail "watchdog stands down while service is in transition"
fi
assert_false "no self-heal logged while service is in transition" test -s "$WATCHDOG_LOG"
unset OU_SB_TEST_WATCHDOG_DEAD OU_SB_TEST_SERVICE_TRANSITION

# 8. busybox 环境下（pgrep 是 busybox 符号链接，pgrep -x 匹配不到运行中的进程）必须靠 pidof 判定
saved_path=$PATH
mkdir -p "$TEST_ROOT/bin"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = sing-box ] && { echo 4242; exit 0; }\nexit 1\n' > "$TEST_ROOT/bin/pidof"
printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/bin/pgrep"
chmod +x "$TEST_ROOT/bin/pidof" "$TEST_ROOT/bin/pgrep"
PATH="$TEST_ROOT/bin:$PATH"
assert_true "process detection survives busybox-style pgrep" is_sing_box_process_running
PATH=$saved_path
assert_false "no pgrep -x usage (busybox pgrep -x matches nothing)" grep -q 'pgrep -x' <(grep -v '^[[:space:]]*#' "$PROJECT_DIR/OU-SB.sh")
assert_true "cron changes touch the crontabs dir (busybox crond reloads on dir mtime)" grep -q 'touch /etc/crontabs' "$PROJECT_DIR/OU-SB.sh"
assert_true "cron watchdog install notifies crond" grep -q 'notify_cron_change' "$PROJECT_DIR/OU-SB.sh"

# 9. 配置结构校验（看门狗每分钟使用的廉价路径）
printf '{"inbounds":[],"outbounds":[]}\n' > "$CONFIG_PATH"
assert_true "structural check accepts minimal config" config_structurally_valid "$CONFIG_PATH"
printf '{ broken\n' > "$CONFIG_PATH"
assert_false "structural check rejects invalid JSON" config_structurally_valid "$CONFIG_PATH"
: > "$CONFIG_PATH"
assert_false "structural check rejects empty file" config_structurally_valid "$CONFIG_PATH"
printf '{"log":{}}\n' > "$CONFIG_PATH"
assert_false "structural check rejects config without inbounds/outbounds" config_structurally_valid "$CONFIG_PATH"

# 10. 看门狗状态显示：cron 文件存在但 cron 守护进程没跑时不能误报绿灯
INIT_SYSTEM="openrc"
mkdir -p "$(dirname "$CRON_FILE")"
printf '* * * * * %s --watchdog >/dev/null 2>&1\n' "$COMMAND_PATH" > "$CRON_FILE"
export OU_SB_TEST_CRON_RUNNING=0
assert_true "cron watchdog reported inactive when cron daemon is down" grep -q "未激活" <(get_watchdog_status_text)
export OU_SB_TEST_CRON_RUNNING=1
assert_true "cron watchdog reported active when cron daemon runs" grep -q "已激活" <(get_watchdog_status_text)
unset OU_SB_TEST_CRON_RUNNING

# 10. uninstall_watchdog 清理测试
INIT_SYSTEM="systemd"
uninstall_watchdog
assert_false "watchdog service removed" test -f "$SYSTEMD_DIR/ou-sb-watchdog.service"
assert_false "watchdog timer removed" test -f "$SYSTEMD_DIR/ou-sb-watchdog.timer"
assert_false "watchdog cron entry removed" test -f "$CRON_FILE"

printf '\n%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))

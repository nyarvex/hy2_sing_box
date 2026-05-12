#!/usr/bin/env bash
# ============================================================================
# anti_probe_wizard_pro.sh
# 生产级 VPS 入站防护墙 - 修复版
#
# 修复内容：
#   1. 空回滚文件现在写入 "flush ruleset"，确保回滚绝对生效
#   2. 增加应急逃生端口 65522（无条件放行，防永久锁死）
#   3. 修复日志变量空格缺失导致的语法错误（ENABLE_LOGGING=no 时）
#   4. 改进 SSH_CONNECTION 解析（read 替代 set，避免 IPv6 错位）
#   5. 增加内核硬化（syncookies、conntrack、keepalive、ARP）
#   6. 增加 Fail2Ban 联动与 IP 格式验证
#   7. 清理旧回滚守护进程，支持 at 命令提高可靠性
# ============================================================================

set -Eeuo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
BASE_DIR="/root/anti-probe-firewall"
BACKUP_DIR="$BASE_DIR/backups"
NFT_CONF="/etc/nftables.conf"
NFT_CONF_NEW="$BASE_DIR/nftables.conf.new"
NFT_CONF_BACKUP="$BACKUP_DIR/nftables.conf.rollback.bak"
NFT_CONF_ABSENT_MARK="$BACKUP_DIR/nftables.conf.was-absent"
SYSCTL_CONF="/etc/sysctl.d/99-anti-probe.conf"
RUNTIME_CONF="$BASE_DIR/last-run.conf"
ROLLBACK_FILE="$BACKUP_DIR/rollback-ruleset.nft"
INSTALL_LOG="$BACKUP_DIR/install.log"
NFTABLES_STATE_FILE="$BACKUP_DIR/nftables.service.state"
F2B_JAIL_CONF="/etc/fail2ban/jail.d/anti-probe.conf"
F2B_JAIL_BACKUP="$BACKUP_DIR/fail2ban-anti-probe.conf.rollback.bak"
F2B_JAIL_ABSENT_MARK="$BACKUP_DIR/fail2ban-anti-probe.conf.was-absent"
GUARD_SCRIPT="$BASE_DIR/rollback-guard.sh"
GUARD_PID_FILE="$BASE_DIR/rollback-guard.pid"
GUARD_AT_JOB_FILE="$BASE_DIR/rollback-guard.atjob"
CONFIRM_FILE="/run/anti-probe-firewall-confirmed"
RESCUE_PORT=65522

SSH_PORT="22"
TCP_PORTS="443"
UDP_PORTS=""
MGMT_WHITELIST=""
PING_MODE="limited"
PROTECTION_MODE="safe"
ROLLBACK_MINUTES="3"
ENABLE_LOGGING="yes"
ENABLE_IPV6="yes"
AUTO_INSTALL_NFT="yes"
SKIP_SERVICE_STOP="no"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[34m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    red "[错误] 请使用 root 运行：sudo bash $SCRIPT_NAME"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

pause() {
  echo
  read -r -p "按 Enter 继续... " _
}

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME               # 引导式部署
  sudo bash $SCRIPT_NAME --status      # 查看状态
  sudo bash $SCRIPT_NAME --rollback-now # 立刻回滚
  sudo bash $SCRIPT_NAME --ban IP [DURATION] # 黑名单封禁，默认 1h
  sudo bash $SCRIPT_NAME --unban IP     # 解封黑名单
  sudo bash $SCRIPT_NAME --whitelist-add IP # 加入白名单
  sudo bash $SCRIPT_NAME --whitelist-del IP # 移出白名单
  sudo bash $SCRIPT_NAME --uninstall    # 卸载本脚本规则/辅助文件
  bash $SCRIPT_NAME --help
EOF
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

validate_duration() {
  local d="$1"
  [[ "$d" =~ ^[0-9]+(s|m|h|d)?$ ]] || return 1
  [ "${d//[!0-9]/}" -gt 0 ]
}

validate_port_list() {
  local list="$1" item start end
  list="${list//[[:space:]]/}"
  [ -z "$list" ] && return 0
  IFS=',' read -r -a arr <<< "$list"
  for item in "${arr[@]}"; do
    [ -z "$item" ] && return 1
    if [[ "$item" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${item%-*}"
      end="${item#*-}"
      validate_port "$start" || return 1
      validate_port "$end" || return 1
      [ "$start" -le "$end" ] || return 1
    else
      validate_port "$item" || return 1
    fi
  done
}

validate_cidr_prefix() {
  local prefix="$1" max="$2"
  [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le "$max" ]
}

validate_ipv4_addr() {
  local addr="$1" a b c d extra octet
  IFS='.' read -r a b c d extra <<< "$addr"
  [ -z "${extra:-}" ] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

validate_ip() {
  local ip="$1"
  local addr="${ip%/*}" prefix=""
  if [[ "$ip" == */* ]]; then
    prefix="${ip#*/}"
  fi
  if [[ "$addr" == *":"* ]]; then
    [[ "$addr" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    [ -z "$prefix" ] || validate_cidr_prefix "$prefix" 128
  else
    validate_ipv4_addr "$addr" || return 1
    [ -z "$prefix" ] || validate_cidr_prefix "$prefix" 32
  fi
}

split_csv() {
  local list="$1"
  __csv_arr=()
  list="${list//[[:space:]]/}"
  [ -z "$list" ] && return 0
  IFS=',' read -r -a __csv_arr <<< "$list"
}

join_csv() {
  local out="" x
  for x in "$@"; do
    [ -z "$x" ] && continue
    if [ -z "$out" ]; then out="$x"; else out="$out,$x"; fi
  done
  printf '%s' "$out"
}

csv_to_nft_elements() {
  local list="$1"
  list="${list//[[:space:]]/}"
  [ -z "$list" ] && { printf ''; return; }
  printf '%s' "${list//,/ , }"
}

ip_family() {
  case "$1" in
    *:*) echo v6 ;;
    *.*) echo v4 ;;
    *) echo unknown ;;
  esac
}

install_nftables() {
  if cmd_exists nft; then
    return 0
  fi
  if [ "$AUTO_INSTALL_NFT" != "yes" ]; then
    red "[错误] nft 不存在，请先安装 nftables。"
    exit 1
  fi
  blue "[信息] 正在尝试安装 nftables..."
  if cmd_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nftables
  elif cmd_exists dnf; then
    dnf install -y nftables
  elif cmd_exists yum; then
    yum install -y nftables
  elif cmd_exists zypper; then
    zypper --non-interactive install nftables
  elif cmd_exists pacman; then
    pacman -Sy --noconfirm nftables
  else
    red "[错误] 未识别包管理器，请手动安装 nftables。"
    exit 1
  fi
  cmd_exists nft || { red "[错误] nftables 安装失败。"; exit 1; }
}

detect_ssh_port() {
  if [ -n "${SSH_CONNECTION:-}" ]; then
    read -r _ _ _ SSH_PORT <<< "$SSH_CONNECTION"
  elif cmd_exists sshd; then
    local p
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    [ -n "$p" ] && SSH_PORT="$p"
  fi
  SSH_PORT="${SSH_PORT:-22}"
}

show_listeners() {
  echo
  blue "当前监听端口（仅供参考）："
  if cmd_exists ss; then
    ss -lntup 2>/dev/null || ss -lntu 2>/dev/null || true
  elif cmd_exists netstat; then
    netstat -lntup 2>/dev/null || netstat -lntu 2>/dev/null || true
  else
    yellow "未找到 ss/netstat，跳过。"
  fi
}

conflict_check() {
  local active=()
  if cmd_exists systemctl; then
    systemctl is-active --quiet ufw 2>/dev/null && active+=("ufw")
    systemctl is-active --quiet firewalld 2>/dev/null && active+=("firewalld")
    systemctl is-active --quiet docker 2>/dev/null && active+=("docker")
  fi

  if [ "${#active[@]}" -gt 0 ]; then
    echo
    yellow "检测到可能冲突的服务：${active[*]}"
    echo "nftables 和这些服务同时运行时，可能造成规则冲突。"
    yellow "脚本不会自动停止这些服务；但后续 apply 会写入 /etc/nftables.conf 并 flush ruleset，现有规则可能被替换。"
    read -r -p "确认继续？输入 YES 继续：" keep_ans
    [ "$keep_ans" = "YES" ] || { yellow "已取消。"; exit 0; }
  fi
}

warn_existing_ruleset() {
  local current_ruleset tables
  current_ruleset="$(nft list ruleset 2>/dev/null || true)"
  [ -n "$current_ruleset" ] || return 0

  echo
  yellow "检测到当前系统已经存在 nftables 规则。"
  tables="$(printf '%s\n' "$current_ruleset" | awk '/^table /{print "  - " $0}')"
  [ -n "$tables" ] && printf '%s\n' "$tables"
  if printf '%s\n' "$current_ruleset" | grep -Eiq 'f2b|fail2ban|addr-set-sshd'; then
    yellow "其中看起来包含 Fail2Ban 规则；部署时会先备份，但 apply 阶段仍会 flush 当前 runtime ruleset。"
  fi
  yellow "继续部署会保存快照并替换当前 ruleset；失败或未确认时会自动回滚。"
  read -r -p "确认接受这个影响面？输入 YES 继续：" ans
  [ "$ans" = "YES" ] || { yellow "已取消。"; exit 0; }
}

save_nftables_service_state() {
  if ! cmd_exists systemctl; then
    printf 'ENABLED=unknown\nACTIVE=unknown\n' > "$NFTABLES_STATE_FILE"
    return
  fi
  {
    printf 'ENABLED=%s\n' "$(systemctl is-enabled nftables 2>/dev/null || true)"
    printf 'ACTIVE=%s\n' "$(systemctl is-active nftables 2>/dev/null || true)"
  } > "$NFTABLES_STATE_FILE"
}

restore_nftables_service_state() {
  [ -f "$NFTABLES_STATE_FILE" ] || return 0
  cmd_exists systemctl || return 0
  local enabled
  enabled="$(awk -F= '/^ENABLED=/{print $2; exit}' "$NFTABLES_STATE_FILE")"
  case "$enabled" in
    enabled|enabled-runtime) systemctl enable nftables >/dev/null 2>&1 || true ;;
    disabled) systemctl disable nftables >/dev/null 2>&1 || true ;;
    masked) systemctl mask nftables >/dev/null 2>&1 || true ;;
  esac
}

show_banner() {
  clear || true
  bold "============================================================"
  bold "        Anti-Probe Firewall 生产级修复版"
  bold "============================================================"
  echo
  echo "核心改进："
  echo "  - 防火墙放行应急端口 $RESCUE_PORT（需 sshd 实际监听才可登录）"
  echo "  - 空回滚文件自动写入 flush ruleset（回滚绝对生效）"
  echo "  - 修复无日志模式下的语法错误"
  echo "  - 内核硬化（syncookies / conntrack / keepalive）"
  echo "  - Fail2Ban 联动"
  echo "  - 白名单 IP 格式校验"
  echo
  yellow "重要：部署后不要关闭当前 SSH 窗口。"
  yellow "请在新窗口测试 SSH 和代理端口，确认后再手动保留规则。"
}

choose_profile() {
  echo
  bold "选择端口配置方案"
  echo "  1) web     : 80,443"
  echo "  2) proxy   : 443"
  echo "  3) mixed   : 80,443,8443"
  echo "  4) custom  : 手动输入"
  read -r -p "请选择 [2]：" ans
  case "${ans:-2}" in
    1) TCP_PORTS="80,443" ;;
    2) TCP_PORTS="443" ;;
    3) TCP_PORTS="80,443,8443" ;;
    4)
      read -r -p "请输入 TCP 端口（逗号分隔，例如 443,8443,20000-20100）：" TCP_PORTS
      ;;
    *) TCP_PORTS="443" ;;
  esac
  validate_port_list "$TCP_PORTS" || { red "TCP 端口格式不合法。"; exit 1; }

  echo
  read -r -p "是否额外开放 UDP 端口？留空跳过：" UDP_PORTS || true
  if [ -n "$UDP_PORTS" ]; then
    validate_port_list "$UDP_PORTS" || { red "UDP 端口格式不合法。"; exit 1; }
  fi
}

choose_ping_mode() {
  echo
  bold "Ping/ICMP 策略"
  echo "  1) limited : 允许低频 ping，便于排障（推荐）"
  echo "  2) off     : 禁止普通 ping，但保留必要 ICMP/ICMPv6"
  read -r -p "请选择 [1]：" ans
  case "${ans:-1}" in
    1) PING_MODE="limited" ;;
    2) PING_MODE="off" ;;
    *) red "选择无效。"; exit 1 ;;
  esac
}

choose_protection_mode() {
  echo
  bold "防护强度"
  echo "  1) safe    : 最稳，适合生产"
  echo "  2) strict  : 丢弃所有入站 RST，可能影响正常连接重置"
  echo "  3) paranoid: 更低限速 + 丢弃入站 RST，误伤概率最高"
  read -r -p "请选择 [1]：" ans
  case "${ans:-1}" in
    1) PROTECTION_MODE="safe" ;;
    2) PROTECTION_MODE="strict" ;;
    3) PROTECTION_MODE="paranoid" ;;
    *) red "选择无效。"; exit 1 ;;
  esac
}

choose_whitelist() {
  echo
  bold "白名单管理"
  echo "你可以填写多个管理 IP，用英文逗号分隔（支持 CIDR，如 1.2.3.4/24）。"
  echo "这些 IP 访问本机时会优先放行，适合固定家宽/办公网/跳板机。"
  if [ -n "${SSH_CONNECTION:-}" ]; then
    read -r current_ip _ _ _ <<< "$SSH_CONNECTION"
    echo "检测到当前 SSH 来源 IP：$current_ip"
    read -r -p "是否把当前 IP 加入白名单？yes/no [no]：" ans
    if [ "${ans:-no}" = "yes" ] && [ -n "$current_ip" ]; then
      MGMT_WHITELIST="$current_ip"
    fi
  fi
  read -r -p "额外白名单 IP（可留空）：" extra
  if [ -n "$extra" ]; then
    if [ -z "$MGMT_WHITELIST" ]; then
      MGMT_WHITELIST="$extra"
    else
      MGMT_WHITELIST="$(join_csv "$MGMT_WHITELIST" "$extra")"
    fi
  fi
}

choose_rollback() {
  echo
  bold "自动回滚保护"
  echo "如果你不确认部署成功，规则会在指定分钟后自动回滚。"
  read -r -p "回滚等待分钟数 [3]：" ans
  [ -n "$ans" ] && ROLLBACK_MINUTES="$ans"
  [[ "$ROLLBACK_MINUTES" =~ ^[0-9]+$ ]] && [ "$ROLLBACK_MINUTES" -ge 1 ] && [ "$ROLLBACK_MINUTES" -le 30 ] || {
    red "回滚分钟数必须是 1-30。"
    exit 1
  }
}

choose_logging() {
  echo
  bold "日志策略"
  echo "建议保留低频日志，便于排障。"
  read -r -p "是否记录少量异常包日志？yes/no [yes]：" ans
  case "${ans:-yes}" in
    yes) ENABLE_LOGGING="yes" ;;
    no) ENABLE_LOGGING="no" ;;
    *) red "选择无效。"; exit 1 ;;
  esac
}

choose_ipv6() {
  echo
  read -r -p "是否启用 IPv6 规则？yes/no [yes]：" ans
  case "${ans:-yes}" in
    yes) ENABLE_IPV6="yes" ;;
    no)
      if cmd_exists ip && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; then
        yellow "检测到本机有公网/全局 IPv6。关闭 IPv6 规则会导致 IPv6 入站 ICMPv6 基础报文被默认丢弃，可能影响 IPv6 可达性。"
        read -r -p "仍然关闭 IPv6 规则？输入 YES 确认：" confirm_v6
        [ "$confirm_v6" = "YES" ] || { ENABLE_IPV6="yes"; return; }
      fi
      ENABLE_IPV6="no"
      ;;
    *) red "选择无效。"; exit 1 ;;
  esac
}

rate_values() {
  case "$PROTECTION_MODE" in
    safe)
      TCP_RATE="50/second"; TCP_BURST="100"
      UDP_RATE="80/second"; UDP_BURST="160"
      SSH_RATE="20/minute"; SSH_BURST="20"
      ;;
    strict)
      TCP_RATE="25/second"; TCP_BURST="50"
      UDP_RATE="40/second"; UDP_BURST="80"
      SSH_RATE="10/minute"; SSH_BURST="10"
      ;;
    paranoid)
      TCP_RATE="10/second"; TCP_BURST="20"
      UDP_RATE="20/second"; UDP_BURST="40"
      SSH_RATE="6/minute"; SSH_BURST="6"
      ;;
  esac
}

write_runtime_conf() {
  mkdir -p "$BASE_DIR" "$BACKUP_DIR"
  cat > "$RUNTIME_CONF" <<EOF
SSH_PORT="$SSH_PORT"
TCP_PORTS="$TCP_PORTS"
UDP_PORTS="$UDP_PORTS"
MGMT_WHITELIST="$MGMT_WHITELIST"
PING_MODE="$PING_MODE"
PROTECTION_MODE="$PROTECTION_MODE"
ROLLBACK_MINUTES="$ROLLBACK_MINUTES"
ENABLE_LOGGING="$ENABLE_LOGGING"
ENABLE_IPV6="$ENABLE_IPV6"
EOF
}

save_rollback_snapshot() {
  mkdir -p "$BACKUP_DIR"
  : > "$INSTALL_LOG"
  rm -f "$NFT_CONF_BACKUP" "$NFT_CONF_ABSENT_MARK" "$F2B_JAIL_BACKUP" "$F2B_JAIL_ABSENT_MARK"
  save_nftables_service_state
  local current_ruleset
  current_ruleset="$(nft list ruleset 2>/dev/null || true)"
  if [ -n "$current_ruleset" ]; then
    printf '%s\n' "$current_ruleset" > "$ROLLBACK_FILE"
    cp "$ROLLBACK_FILE" "$BACKUP_DIR/rollback-ruleset-$(date +%Y%m%d-%H%M%S).nft"
  else
    echo "flush ruleset" > "$ROLLBACK_FILE"
    yellow "[提醒] 当前无 nftables 规则，回滚时将清空规则集。"
  fi
  if [ -f "$NFT_CONF" ]; then
    cp "$NFT_CONF" "$NFT_CONF_BACKUP"
    cp "$NFT_CONF" "$BACKUP_DIR/nftables.conf-$(date +%Y%m%d-%H%M%S).bak"
  else
    : > "$NFT_CONF_ABSENT_MARK"
  fi

  if [ -f "$F2B_JAIL_CONF" ]; then
    cp "$F2B_JAIL_CONF" "$F2B_JAIL_BACKUP"
  else
    : > "$F2B_JAIL_ABSENT_MARK"
  fi
}

restore_nft_conf_snapshot() {
  if [ -f "$NFT_CONF_BACKUP" ]; then
    cp "$NFT_CONF_BACKUP" "$NFT_CONF"
  elif [ -f "$NFT_CONF_ABSENT_MARK" ]; then
    rm -f "$NFT_CONF"
  elif [ -f "$NFT_CONF" ] && grep -q 'Generated by anti_probe_wizard_pro.sh' "$NFT_CONF"; then
    cat > "$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
# anti-probe-firewall removed; intentionally empty.
EOF
  fi
}

restore_fail2ban_conf_snapshot() {
  if [ -f "$F2B_JAIL_BACKUP" ]; then
    mkdir -p "$(dirname "$F2B_JAIL_CONF")"
    cp "$F2B_JAIL_BACKUP" "$F2B_JAIL_CONF"
  elif [ -f "$F2B_JAIL_ABSENT_MARK" ]; then
    rm -f "$F2B_JAIL_CONF"
  else
    return 0
  fi

  if cmd_exists fail2ban-client && fail2ban-client -t >/dev/null 2>&1; then
    systemctl restart fail2ban 2>/dev/null || true
  fi
}

render_whitelist_sets() {
  local v4="" v6="" ip family
  split_csv "$MGMT_WHITELIST"
  for ip in "${__csv_arr[@]:-}"; do
    [ -z "$ip" ] && continue
    if ! validate_ip "$ip"; then
      yellow "[警告] 白名单地址格式不合法，已跳过：$ip"
      continue
    fi
    family="$(ip_family "$ip")"
    case "$family" in
      v4)
        if [ -z "$v4" ]; then v4="$ip"; else v4="$v4, $ip"; fi
        ;;
      v6)
        if [ -z "$v6" ]; then v6="$ip"; else v6="$v6, $ip"; fi
        ;;
    esac
  done
  if [ -n "$v4" ]; then
    WHITELIST_V4_DEF="elements = { $v4 }"
  else
    WHITELIST_V4_DEF="# no v4 whitelist"
  fi
  if [ -n "$v6" ]; then
    WHITELIST_V6_DEF="elements = { $v6 }"
  else
    WHITELIST_V6_DEF="# no v6 whitelist"
  fi
}

check_payload_support() {
    if nft -c -f - <<'TEST' 2>/dev/null; then
table inet test_payload_compat {
    chain test {
        type filter hook input priority 0;
        tcp flags & (syn|ack) == syn|ack tcp sequence 0 drop
    }
}
TEST
        echo "yes"
    else
        echo "no"
    fi
}

build_nft_config() {
  rate_values
  render_whitelist_sets
  local tcp_set udp_set log_rule
  tcp_set="$(csv_to_nft_elements "$TCP_PORTS")"
  udp_set="$(csv_to_nft_elements "$UDP_PORTS")"

  local log_prefix=""
  if [ "$ENABLE_LOGGING" = "yes" ]; then
    log_prefix="log prefix \"anti-probe: \" flags all counter"
  fi

  local early_rst_rule="" late_rst_rule=""
  case "$PROTECTION_MODE" in
    safe)
      late_rst_rule="tcp flags & rst == rst ct state new drop comment \"drop unsolicited new rst\""
      ;;
    strict|paranoid)
      early_rst_rule="tcp flags & rst == rst drop comment \"drop all inbound rst - strict mode\""
      ;;
  esac

  local seq0_rule=""
  if [ "${PAYLOAD_SUPPORT:-no}" = "yes" ]; then
    seq0_rule="tcp flags & (syn|ack) == syn|ack tcp sequence 0 ${log_prefix} drop comment \"drop seq0 syn-ack anomaly\""
  else
    seq0_rule="# seq=0 detection skipped (nftables does not support tcp sequence matching)"
  fi

  cat > "$NFT_CONF_NEW" <<EOF
#!/usr/sbin/nft -f
# Generated by anti_probe_wizard_pro.sh on $(date -Is)
# Protection mode: $PROTECTION_MODE

flush ruleset

table inet anti_probe {
    set mgmt_v4 {
        type ipv4_addr
        flags interval
        ${WHITELIST_V4_DEF}
    }

    set mgmt_v6 {
        type ipv6_addr
        flags interval
        ${WHITELIST_V6_DEF}
    }

    set temp_block_v4 {
        type ipv4_addr
        flags interval,timeout
        timeout 1h
    }

    set temp_block_v6 {
        type ipv6_addr
        flags interval,timeout
        timeout 1h
    }
EOF

  if [ -n "$tcp_set" ]; then
    cat >> "$NFT_CONF_NEW" <<EOF

    set tcp_service_ports {
        type inet_service
        flags interval
        elements = { $tcp_set }
    }
EOF
  fi

  if [ -n "$udp_set" ]; then
    cat >> "$NFT_CONF_NEW" <<EOF

    set udp_service_ports {
        type inet_service
        flags interval
        elements = { $udp_set }
    }
EOF
  fi

  cat >> "$NFT_CONF_NEW" <<EOF

    chain input {
        type filter hook input priority filter; policy drop;

        # 应急逃生端口（绝对优先，永不拦截）
        tcp dport $RESCUE_PORT accept comment "emergency rescue port"

        # 基础放行
        iifname "lo" accept comment "allow loopback"
        ct state invalid drop comment "drop invalid conntrack packets"
        $early_rst_rule

        # 白名单优先
        ip saddr @mgmt_v4 accept comment "allow management whitelist v4"
        ip6 saddr @mgmt_v6 accept comment "allow management whitelist v6"

        # 临时黑名单
        ip saddr @temp_block_v4 drop comment "drop temp blocked v4"
        ip6 saddr @temp_block_v6 drop comment "drop temp blocked v6"

        ct state established,related accept comment "allow established/related"

        # 畸形 TCP 标志与异常握手
        tcp flags & (fin|syn) == fin|syn ${log_prefix} drop comment "drop syn-fin"
        tcp flags & (syn|rst) == syn|rst ${log_prefix} drop comment "drop syn-rst"
        tcp flags & (fin|rst) == fin|rst ${log_prefix} drop comment "drop fin-rst"
        tcp flags & (fin|psh|urg) == fin|psh|urg ${log_prefix} drop comment "drop xmas"
        tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 ${log_prefix} drop comment "drop null tcp flags"
        $late_rst_rule
        $seq0_rule

        # 必要 ICMP
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept comment "allow essential ipv4 icmp"
EOF

  if [ "$PING_MODE" = "limited" ]; then
    cat >> "$NFT_CONF_NEW" <<'EOF'
        ip protocol icmp icmp type echo-request limit rate 3/second burst 5 packets accept comment "rate-limit ipv4 ping"
        ip protocol icmp icmp type echo-request drop comment "drop excessive ipv4 ping"
EOF
  else
    cat >> "$NFT_CONF_NEW" <<'EOF'
        ip protocol icmp icmp type echo-request drop comment "drop ipv4 ping"
EOF
  fi

  if [ "$ENABLE_IPV6" = "yes" ]; then
    cat >> "$NFT_CONF_NEW" <<'EOF'
        meta nfproto ipv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept comment "allow essential ipv6 icmp"
EOF
    if [ "$PING_MODE" = "limited" ]; then
      cat >> "$NFT_CONF_NEW" <<'EOF'
        meta nfproto ipv6 icmpv6 type echo-request limit rate 3/second burst 5 packets accept comment "rate-limit ipv6 ping"
        meta nfproto ipv6 icmpv6 type echo-request drop comment "drop excessive ipv6 ping"
EOF
    else
      cat >> "$NFT_CONF_NEW" <<'EOF'
        meta nfproto ipv6 icmpv6 type echo-request drop comment "drop ipv6 ping"
EOF
    fi
  fi

  if [ "$PROTECTION_MODE" = "safe" ]; then
    cat >> "$NFT_CONF_NEW" <<EOF

        # SSH：safe 模式不做全局限速，避免公网扫描挤掉正常管理连接
        tcp dport $SSH_PORT ct state new accept comment "allow ssh"
EOF
  else
    cat >> "$NFT_CONF_NEW" <<EOF

        # SSH：严格模式限速新连接
        tcp dport $SSH_PORT ct state new limit rate $SSH_RATE burst $SSH_BURST packets accept comment "allow rate-limited ssh"
        tcp dport $SSH_PORT ct state new drop comment "drop excessive ssh attempts"
EOF
  fi

  if [ -n "$tcp_set" ]; then
    if [ "$PROTECTION_MODE" = "safe" ]; then
      cat >> "$NFT_CONF_NEW" <<EOF

        # 业务 / 代理 TCP 端口
        tcp dport @tcp_service_ports ct state new accept comment "allow tcp services"
EOF
    else
      cat >> "$NFT_CONF_NEW" <<EOF

        # 业务 / 代理 TCP 端口
        tcp dport @tcp_service_ports ct state new limit rate $TCP_RATE burst $TCP_BURST packets accept comment "allow rate-limited tcp services"
        tcp dport @tcp_service_ports ct state new drop comment "drop excessive tcp service attempts"
EOF
    fi
  fi

  if [ -n "$udp_set" ]; then
    if [ "$PROTECTION_MODE" = "safe" ]; then
      cat >> "$NFT_CONF_NEW" <<EOF

        # UDP 业务 / 代理端口
        udp dport @udp_service_ports ct state new accept comment "allow udp services"
EOF
    else
      cat >> "$NFT_CONF_NEW" <<EOF

        # UDP 业务 / 代理端口
        udp dport @udp_service_ports ct state new limit rate $UDP_RATE burst $UDP_BURST packets accept comment "allow rate-limited udp services"
        udp dport @udp_service_ports ct state new drop comment "drop excessive udp service attempts"
EOF
    fi
  fi

  cat >> "$NFT_CONF_NEW" <<EOF

        # 其余新建连接静默丢弃
        tcp flags & syn == syn drop comment "silently drop non-whitelisted tcp syn"
        udp drop comment "silently drop non-whitelisted udp"
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
}

test_nft_config() {
  blue "[信息] 正在检查 nftables 语法..."
  if nft -c -f "$NFT_CONF_NEW" >>"$INSTALL_LOG" 2>&1; then
    green "[完成] nftables 语法检查通过。"
    return 0
  fi

  yellow "[提示] 你的 nft 版本可能不支持 sequence 匹配，正在自动降级..."
  sed -i '/tcp flags & (syn|ack) == syn|ack tcp sequence 0/d' "$NFT_CONF_NEW"

  if nft -c -f "$NFT_CONF_NEW" >>"$INSTALL_LOG" 2>&1; then
    green "[完成] 降级后的语法检查通过。"
    return 0
  fi

  red "[错误] nftables 语法检查失败，日志：$INSTALL_LOG"
  tail -n 60 "$INSTALL_LOG" || true
  exit 1
}

apply_nft_config() {
  blue "[信息] 正在应用 nftables 规则..."
  cp "$NFT_CONF_NEW" "$NFT_CONF"
  if ! nft -f "$NFT_CONF"; then
    red "[错误] 应用 nftables 规则失败，正在恢复持久化配置。"
    restore_nft_conf_snapshot
    restore_nftables_service_state
    return 1
  fi
  if cmd_exists systemctl; then
    systemctl enable nftables >/dev/null 2>&1 || true
  fi
}

harden_sysctl() {
  blue "[信息] 正在配置内核抗探测参数..."
  cat > "$SYSCTL_CONF" <<'EOF'
# Anti-Probe Firewall Kernel Hardening

# SYN Cookies: 防止 SYN Flood 耗尽连接表
net.ipv4.tcp_syncookies=1

# 禁用所有 ICMP 重定向（防止被用于流量劫持探测）
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# 禁用源路由
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0

# TIME-WAIT assassination protection（防止连接被伪造 RST 重置）
net.ipv4.tcp_rfc1337=1

# SYN 队列（保持合理大小，兼顾代理性能）
net.ipv4.tcp_max_syn_backlog=4096

# 快速丢弃入站半开连接；不缩短出站 SYN 重试，避免影响 apt/curl/API 等外连
net.ipv4.tcp_synack_retries=3

# 连接追踪超时（保守清理探测留下的垃圾状态，不压短正常长连接）
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=10
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=10
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=10
net.netfilter.nf_conntrack_tcp_timeout_time_wait=10

# 连接追踪表上限
net.netfilter.nf_conntrack_max=524288

# Keepalive 清理僵尸连接（配合 RST 丢弃策略）
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=3

# ARP 硬化
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2

# 保留 IPv6 Router Solicitation；很多 VPS 的 IPv6 默认路由依赖 RA/SLAAC。
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
  green "[完成] 内核参数已应用。"
}

setup_fail2ban() {
  if ! cmd_exists fail2ban-server; then
    yellow "[提醒] fail2ban 未安装，跳过动态黑名单联动。"
    return
  fi
  local recidive_log=""
  local candidate
  local jail_conf="$F2B_JAIL_CONF"
  local jail_backup=""
  for candidate in /var/log/fail2ban.log /var/log/fail2ban/fail2ban.log; do
    if [ -e "$candidate" ]; then
      recidive_log="$candidate"
      break
    fi
  done

  mkdir -p /etc/fail2ban/jail.d
  if [ -f "$jail_conf" ]; then
    jail_backup="$jail_conf.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$jail_conf" "$jail_backup"
  fi

  cat > "$jail_conf" <<EOF
[sshd]
enabled = true
port = $SSH_PORT,$RESCUE_PORT
filter = sshd
backend = systemd
findtime = 300
maxretry = 3
bantime = 7200
banaction = nftables-multiport
EOF

  if [ -n "$recidive_log" ]; then
    cat >> "$jail_conf" <<EOF
[recidive]
enabled = true
filter = recidive
logpath = $recidive_log
action = nftables-allports[name=recidive, protocol=all]
bantime = 604800
findtime = 86400
maxretry = 3
EOF
  else
    yellow "[提醒] 未找到 fail2ban 日志文件，已跳过 recidive jail。"
  fi

  if cmd_exists fail2ban-client && ! fail2ban-client -t >/dev/null 2>&1; then
    red "[错误] Fail2Ban 配置测试失败，已跳过重启 fail2ban。"
    fail2ban-client -t || true
    if [ -n "$jail_backup" ] && [ -f "$jail_backup" ]; then
      cp "$jail_backup" "$jail_conf"
    else
      rm -f "$jail_conf"
    fi
    return
  fi

  if cmd_exists systemctl; then
    if systemctl restart fail2ban 2>/dev/null; then
      green "[完成] Fail2Ban 已配置并重启。"
    else
      yellow "[提醒] Fail2Ban 配置已写入，但重启 fail2ban 失败，请手动检查 systemctl status fail2ban。"
    fi
  else
    green "[完成] Fail2Ban 配置已写入。"
  fi
}

cancel_rollback_guard() {
  if [ -s "$GUARD_AT_JOB_FILE" ] && cmd_exists atrm; then
    while read -r job; do
      [ -n "$job" ] && atrm "$job" 2>/dev/null || true
    done < "$GUARD_AT_JOB_FILE"
  fi
  pkill -f "$GUARD_SCRIPT" 2>/dev/null || true
  rm -f "$GUARD_PID_FILE" "$GUARD_AT_JOB_FILE" 2>/dev/null || true
}

start_rollback_guard() {
  # 清理旧的守护进程，并清掉上次运行残留的确认标记
  cancel_rollback_guard
  rm -f "$CONFIRM_FILE" 2>/dev/null || true

  cat > "$GUARD_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" != "--run-now" ]; then
  sleep $((ROLLBACK_MINUTES * 60))
fi
if [ ! -f "$CONFIRM_FILE" ]; then
  if [ -s "$ROLLBACK_FILE" ]; then
    nft -f "$ROLLBACK_FILE" >/dev/null 2>&1 || true
  else
    nft flush ruleset >/dev/null 2>&1 || true
  fi
  if [ -f "$NFT_CONF_BACKUP" ]; then
    cp "$NFT_CONF_BACKUP" "$NFT_CONF" >/dev/null 2>&1 || true
  elif [ -f "$NFT_CONF_ABSENT_MARK" ]; then
    rm -f "$NFT_CONF" >/dev/null 2>&1 || true
  fi
  if [ -f "$NFTABLES_STATE_FILE" ] && command -v systemctl >/dev/null 2>&1; then
    enabled="\$(awk -F= '/^ENABLED=/{print \$2; exit}' "$NFTABLES_STATE_FILE" 2>/dev/null || true)"
    case "\$enabled" in
      enabled|enabled-runtime) systemctl enable nftables >/dev/null 2>&1 || true ;;
      disabled) systemctl disable nftables >/dev/null 2>&1 || true ;;
      masked) systemctl mask nftables >/dev/null 2>&1 || true ;;
    esac
  fi
  if [ -f "$F2B_JAIL_BACKUP" ]; then
    mkdir -p /etc/fail2ban/jail.d >/dev/null 2>&1 || true
    cp "$F2B_JAIL_BACKUP" "$F2B_JAIL_CONF" >/dev/null 2>&1 || true
  elif [ -f "$F2B_JAIL_ABSENT_MARK" ]; then
    rm -f "$F2B_JAIL_CONF" >/dev/null 2>&1 || true
  fi
  if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client -t >/dev/null 2>&1; then
    systemctl restart fail2ban >/dev/null 2>&1 || true
  fi
  rm -f "$SYSCTL_CONF"
  sysctl --system >/dev/null 2>&1 || true
fi
EOF
  chmod +x "$GUARD_SCRIPT"

  # 首选 at 命令（系统级，最可靠）
  if cmd_exists at; then
    local at_output at_job
    if at_output="$(printf '%s\n' "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; bash $GUARD_SCRIPT --run-now" | at "now + $ROLLBACK_MINUTES minutes" 2>&1)"; then
      at_job="$(printf '%s\n' "$at_output" | awk '/^job[[:space:]]+[0-9]+/{print $2; exit}')"
      [ -n "$at_job" ] && printf '%s\n' "$at_job" > "$GUARD_AT_JOB_FILE"
      green "[完成] 已使用 at 命令设置 $ROLLBACK_MINUTES 分钟后自动回滚。"
      return 0
    fi
  fi

  # 回退到 nohup
  nohup "$GUARD_SCRIPT" >/dev/null 2>&1 &
  echo $! > "$GUARD_PID_FILE"
  yellow "[提醒] 已使用 nohup 设置回滚守护（建议安装 at 命令以提高可靠性）。"
}

confirm_success() {
  echo
  bold "============================================================"
  bold "规则已经应用"
  bold "============================================================"
  echo "应急逃生端口：$RESCUE_PORT（如主 SSH 被锁，用 ssh -p $RESCUE_PORT 连接）"
  echo "请你现在做三件事："
  echo "  1. 新开一个 SSH 窗口，确认还能登录（端口 $SSH_PORT）。"
  echo "  2. 测试你的代理/网站端口是否可用。"
  echo "  3. 尝试从另一台机器 ping 本机，确认 ICMP 策略符合预期。"
  echo
  echo "如果一切正常，请回到这个窗口输入 YES。"
  echo "如果你什么都不做，规则会在 ${ROLLBACK_MINUTES} 分钟后自动回滚。"
  echo
  read -r -p "确认保留规则？输入 YES：" ans
  if [ "$ans" = "YES" ]; then
    touch "$CONFIRM_FILE" 2>/dev/null || true
    cancel_rollback_guard
    green "[完成] 已确认成功，自动回滚已取消。"
  else
    yellow "未确认。请等待自动回滚，或立即执行：sudo bash $SCRIPT_NAME --rollback-now"
  fi
}

listener_check() {
  echo
  blue "部署后自检（本机监听情况）"
  if cmd_exists ss; then
    local ports p
    ports="$TCP_PORTS"
    if [ -n "$UDP_PORTS" ]; then
      ports="$(join_csv "$ports" "$UDP_PORTS")"
    fi
    for p in ${ports//,/ }; do
      p="${p%%-*}"
      if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p$"; then
        green "[检测] TCP 端口 $p 看起来在监听。"
      else
        yellow "[提醒] TCP 端口 $p 未检测到监听（如果服务还没启动，这是正常的）。"
      fi
      if ss -lnu 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p$"; then
        green "[检测] UDP 端口 $p 看起来在监听。"
      fi
    done
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$SSH_PORT$"; then
      green "[检测] SSH 端口 $SSH_PORT 在监听。"
    else
      red "[警告] SSH 端口 $SSH_PORT 未检测到监听！"
    fi
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$RESCUE_PORT$"; then
      green "[检测] 应急逃生端口 $RESCUE_PORT 在监听。"
    else
      yellow "[提醒] 应急逃生端口 $RESCUE_PORT 未监听（如需使用，请在 sshd_config 中添加 Port $RESCUE_PORT）。"
    fi
  else
    yellow "未找到 ss，跳过监听检查。"
  fi
}

print_summary() {
  echo
  bold "============================================================"
  bold "准备应用的配置"
  bold "============================================================"
  echo "SSH 端口：        $SSH_PORT"
  echo "TCP 开放端口：    ${TCP_PORTS:-无}"
  echo "UDP 开放端口：    ${UDP_PORTS:-无}"
  echo "白名单：          ${MGMT_WHITELIST:-无}"
  echo "Ping 模式：       $PING_MODE"
  echo "防护强度：        $PROTECTION_MODE"
  echo "日志：            $ENABLE_LOGGING"
  echo "IPv6：            $ENABLE_IPV6"
  echo "应急逃生端口：    $RESCUE_PORT"
  echo "自动回滚：        $ROLLBACK_MINUTES 分钟"
  echo
  yellow "如果 SSH 端口填错，自动回滚通常能救你。"
  yellow "应急逃生端口 $RESCUE_PORT 已启用，建议同时在 sshd_config 中监听此端口。"
  read -r -p "确认应用？输入 YES 继续：" ans
  [ "$ans" = "YES" ] || { yellow "已取消。"; exit 0; }
}

status() {
  need_root
  echo "=== 配置文件 ==="
  [ -f "$RUNTIME_CONF" ] && cat "$RUNTIME_CONF" || echo "未找到运行配置：$RUNTIME_CONF"
  echo
  echo "=== nftables 规则 ==="
  if cmd_exists nft; then
    nft list ruleset || true
  else
    echo "nft 不存在。"
  fi
  echo
  echo "=== 白名单集合 ==="
  nft list set inet anti_probe mgmt_v4 2>/dev/null || true
  nft list set inet anti_probe mgmt_v6 2>/dev/null || true
  echo
  echo "=== 黑名单集合 ==="
  nft list set inet anti_probe temp_block_v4 2>/dev/null || true
  nft list set inet anti_probe temp_block_v6 2>/dev/null || true
  echo
  echo "=== 内核参数 ==="
  sysctl net.ipv4.tcp_syncookies net.netfilter.nf_conntrack_max 2>/dev/null || true
  echo
  echo "=== 回滚文件 ==="
  ls -l "$ROLLBACK_FILE" 2>/dev/null || echo "未找到。"
  echo
  echo "=== 回滚守护 ==="
  if [ -s "$GUARD_AT_JOB_FILE" ]; then
    echo "at job: $(tr '\n' ' ' < "$GUARD_AT_JOB_FILE")"
    cmd_exists atq && atq 2>/dev/null || true
  else
    pgrep -af "$GUARD_SCRIPT" || echo "未发现回滚守护进程。"
  fi
}

rollback_now() {
  need_root
  if [ -f "$ROLLBACK_FILE" ] && [ -s "$ROLLBACK_FILE" ]; then
    blue "[信息] 正在回滚到部署前规则..."
    nft -f "$ROLLBACK_FILE" || red "[警告] runtime ruleset 回滚失败，请手动检查 $ROLLBACK_FILE"
  else
    blue "[信息] 回滚文件为空，执行清空规则..."
    nft flush ruleset || true
  fi
  restore_nft_conf_snapshot
  restore_nftables_service_state
  restore_fail2ban_conf_snapshot
  touch "$CONFIRM_FILE" 2>/dev/null || true
  cancel_rollback_guard
  rm -f "$SYSCTL_CONF"
  sysctl --system >/dev/null 2>&1 || true
  green "[完成] 已回滚。"
}

ban_ip() {
  need_root
  local ip="${1:-}" duration="${2:-1h}" fam
  [ -n "$ip" ] || { red "[错误] 请提供 IP。"; exit 1; }
  validate_ip "$ip" || { red "[错误] IP 格式不合法。"; exit 1; }
  validate_duration "$duration" || { red "[错误] 封禁时长格式不合法，例如 30m、1h、1d。"; exit 1; }
  fam="$(ip_family "$ip")"
  case "$fam" in
    v4) nft add element inet anti_probe temp_block_v4 "{ $ip timeout $duration }" ;;
    v6) nft add element inet anti_probe temp_block_v6 "{ $ip timeout $duration }" ;;
    *) red "[错误] 只能处理 IPv4/IPv6 地址。"; exit 1 ;;
  esac
  green "[完成] 已封禁 $ip，时长 $duration。"
}

unban_ip() {
  need_root
  local ip="${1:-}" fam
  [ -n "$ip" ] || { red "[错误] 请提供 IP。"; exit 1; }
  validate_ip "$ip" || { red "[错误] IP 格式不合法。"; exit 1; }
  fam="$(ip_family "$ip")"
  case "$fam" in
    v4) nft delete element inet anti_probe temp_block_v4 "{ $ip }" ;;
    v6) nft delete element inet anti_probe temp_block_v6 "{ $ip }" ;;
    *) red "[错误] 只能处理 IPv4/IPv6 地址。"; exit 1 ;;
  esac
  green "[完成] 已解封 $ip。"
}

whitelist_add() {
  need_root
  local ip="${1:-}" fam
  [ -n "$ip" ] || { red "[错误] 请提供 IP。"; exit 1; }
  validate_ip "$ip" || { red "[错误] IP 格式不合法。"; exit 1; }
  fam="$(ip_family "$ip")"
  case "$fam" in
    v4) nft add element inet anti_probe mgmt_v4 "{ $ip }" ;;
    v6) nft add element inet anti_probe mgmt_v6 "{ $ip }" ;;
    *) red "[错误] 只能处理 IPv4/IPv6 地址。"; exit 1 ;;
  esac
  green "[完成] 已加入白名单 $ip。"
}

whitelist_del() {
  need_root
  local ip="${1:-}" fam
  [ -n "$ip" ] || { red "[错误] 请提供 IP。"; exit 1; }
  validate_ip "$ip" || { red "[错误] IP 格式不合法。"; exit 1; }
  fam="$(ip_family "$ip")"
  case "$fam" in
    v4) nft delete element inet anti_probe mgmt_v4 "{ $ip }" ;;
    v6) nft delete element inet anti_probe mgmt_v6 "{ $ip }" ;;
    *) red "[错误] 只能处理 IPv4/IPv6 地址。"; exit 1 ;;
  esac
  green "[完成] 已从白名单移除 $ip。"
}

uninstall() {
  need_root
  echo
  red "这会移除本脚本的 anti_probe 表、辅助文件和持久化配置。"
  yellow "不会清空其他 nftables 表；如需恢复部署前 runtime ruleset，请先执行 --rollback-now。"
  read -r -p "确认卸载？输入 YES 继续：" ans
  [ "$ans" = "YES" ] || { yellow "已取消。"; exit 0; }
  nft delete table inet anti_probe >/dev/null 2>&1 || true
  restore_nft_conf_snapshot
  restore_nftables_service_state
  restore_fail2ban_conf_snapshot
  cancel_rollback_guard
  rm -f "$SYSCTL_CONF"
  sysctl --system >/dev/null 2>&1 || true
  rm -rf "$BASE_DIR" 2>/dev/null || true
  rm -f "$CONFIRM_FILE" 2>/dev/null || true
  green "[完成] 已清空并移除本脚本生成的辅助文件。"
}

main_interactive() {
  need_root
  show_banner
  pause
  install_nftables
  detect_ssh_port
  show_listeners
  conflict_check
  warn_existing_ruleset
  echo
  bold "第一步：SSH 端口确认"
  echo "检测到的 SSH 端口：$SSH_PORT"
  read -r -p "请确认 SSH 端口 [$SSH_PORT]：" ans
  [ -n "$ans" ] && SSH_PORT="$ans"
  validate_port "$SSH_PORT" || { red "SSH 端口不合法。"; exit 1; }
  choose_profile
  choose_whitelist
  choose_ping_mode
  choose_protection_mode
  choose_logging
  choose_ipv6
  choose_rollback
  print_summary
  write_runtime_conf
  save_rollback_snapshot
  PAYLOAD_SUPPORT=$(check_payload_support)
  build_nft_config
  test_nft_config
  start_rollback_guard
  harden_sysctl
  apply_nft_config
  setup_fail2ban
  listener_check
  confirm_success
  echo
  green "[完成] 配置已写入：$NFT_CONF"
  green "[完成] 运行配置：$RUNTIME_CONF"
  green "[完成] 回滚快照：$ROLLBACK_FILE"
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    --status)
      status
      exit 0
      ;;
    --rollback-now)
      rollback_now
      exit 0
      ;;
    --ban)
      shift
      ban_ip "${1:-}" "${2:-1h}"
      exit 0
      ;;
    --unban)
      shift
      unban_ip "${1:-}"
      exit 0
      ;;
    --whitelist-add)
      shift
      whitelist_add "${1:-}"
      exit 0
      ;;
    --whitelist-del)
      shift
      whitelist_del "${1:-}"
      exit 0
      ;;
    --uninstall)
      uninstall
      exit 0
      ;;
    "")
      main_interactive
      ;;
    *)
      red "未知参数：$1"
      usage
      exit 1
      ;;
  esac
}

main "$@"

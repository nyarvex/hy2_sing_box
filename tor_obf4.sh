#!/usr/bin/env bash
#
# ==============================================================================
# PRIVATE TOR BRIDGE INSTALLER (Ubuntu / Debian)
#
# Features:
# - Official Tor Project repo with GPG fingerprint validation
# - Interactive port selection (or env vars) + port conflict detection
# - Safe UFW handling (only if active; preserves SSH by detecting sshd listeners)
# - Hardened Tor bridge config (private, SOCKS disabled, ControlPort localhost)
# - Prints complete obfs4 bridge line with PUBLIC IP + fingerprint
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- Defaults (override via env) ---
DEFAULT_OR_PORT="${DEFAULT_OR_PORT:-9001}"
DEFAULT_PT_PORT="${DEFAULT_PT_PORT:-54321}"
DEFAULT_EMAIL="${DEFAULT_EMAIL:-change_me@example.com}"

# --- Tor Project constants ---
TOR_KEY_FPR_EXPECTED="A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89"
TOR_KEY_URL="https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc"
TOR_KEYRING="/usr/share/keyrings/tor-archive-keyring.gpg"
TOR_LIST="/etc/apt/sources.list.d/tor.list"
TORRC="/etc/tor/torrc"

# --- File paths ---
BRIDGE_FILE="/var/lib/tor/pt_state/obfs4_bridgeline.txt"
TOR_FINGERPRINT_FILE="/var/lib/tor/fingerprint"

# --- Options ---
ENABLE_UFW=0

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# IMPORTANT: log/warn -> STDERR (prevents contaminating captured stdout)
log()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }
is_tty() { [[ -t 0 && -t 1 ]]; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

usage() {
  cat >&2 <<'EOF'
Usage:
  setup-bridge.sh [--enable-ufw]

Examples:
  curl -sL https://.../setup-bridge.sh | sudo bash
  curl -sL https://.../setup-bridge.sh | sudo bash -s -- --enable-ufw
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --enable-ufw) ENABLE_UFW=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1 (use --help)" ;;
    esac
  done
}

trim_all_ws_and_crlf() {
  local v="$1"
  v="${v//$'\r'/}"
  v="${v//$'\n'/}"
  v="$(printf '%s' "$v" | tr -d '[:space:]')"
  printf '%s' "$v"
}

validate_numeric_port() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} must be numeric."
  (( value >= 1025 && value <= 65535 )) || die "${name} must be between 1025-65535."
}

prompt_value() {
  local label="$1" def="$2" val=""
  if ! is_tty; then
    printf '%s' "$def"
    return 0
  fi
  read -r -p "$(echo -e "${BLUE}${label} [${def}]:${NC} ")" val
  printf '%s' "${val:-$def}"
}

# --- Port utilities ---

is_port_free() {
  local port="$1"
  if ss -Hltpn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${port}$"; then
    return 1
  fi
  return 0
}

next_free_port() {
  local start="$1"
  local p=$((start + 1))
  while (( p <= 65535 )); do
    if is_port_free "$p"; then
      printf '%s' "$p"
      return 0
    fi
    ((p++))
  done
  die "No free TCP port found in range ${start}-65535."
}

resolve_port() {
  # Prints ONLY digits on STDOUT
  local name="$1"
  local desired="$2"

  desired="$(trim_all_ws_and_crlf "$desired")"
  [[ -n "$desired" ]] || die "${name} is empty."
  validate_numeric_port "$name" "$desired"

  if is_port_free "$desired"; then
    printf '%s' "$desired"
    return 0
  fi

  if is_tty; then
    warn "Port ${desired} (${name}) is already in use."
    while true; do
      desired="$(prompt_value "Choose a different ${name}" "$desired")"
      desired="$(trim_all_ws_and_crlf "$desired")"
      validate_numeric_port "$name" "$desired"
      if is_port_free "$desired"; then
        printf '%s' "$desired"
        return 0
      fi
      warn "Port ${desired} is still in use."
    done
  else
    local picked
    picked="$(next_free_port "$desired")"
    warn "Port ${desired} (${name}) is in use. Auto-selected ${picked}."
    printf '%s' "$picked"
  fi
}

# --- Main steps ---

install_prereqs() {
  log "Installing prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gpg lsb-release apt-transport-https iproute2 >/dev/null
}

collect_config() {
  echo -e "${GREEN}=== Configuration ===${NC}"

  local or_raw pt_raw em_raw
  or_raw="${OR_PORT:-}"
  pt_raw="${PT_PORT:-}"
  em_raw="${EMAIL:-}"

  [[ -n "$or_raw" ]] || or_raw="$DEFAULT_OR_PORT"
  [[ -n "$pt_raw" ]] || pt_raw="$DEFAULT_PT_PORT"
  [[ -n "$em_raw" ]] || em_raw="$DEFAULT_EMAIL"

  if is_tty; then
    or_raw="$(prompt_value "Tor OR_PORT (ORPort traffic)" "$or_raw")"
    pt_raw="$(prompt_value "Tor PT_PORT (obfs4 transport port for Tor Browser)" "$pt_raw")"
    em_raw="$(prompt_value "Contact email (optional)" "$em_raw")"
  else
    log "Non-interactive mode detected. Using defaults/env vars."
  fi

  OR_PORT="$(resolve_port "OR_PORT" "$or_raw")"
  PT_PORT="$(resolve_port "PT_PORT" "$pt_raw")"
  EMAIL="$em_raw"

  if [[ "$OR_PORT" == "$PT_PORT" ]]; then
    warn "OR_PORT and PT_PORT are identical (${OR_PORT}). Picking a new PT_PORT..."
    PT_PORT="$(resolve_port "PT_PORT" "$(next_free_port "$PT_PORT")")"
  fi

  log "Final ports: OR_PORT=${OR_PORT}, PT_PORT=${PT_PORT}"
}

add_tor_repo() {
  log "Setting up Tor Project APT repository..."
  require_cmd curl
  require_cmd gpg
  require_cmd lsb_release

  log "Downloading Tor Project signing key..."
  local tmpkey
  tmpkey="$(mktemp)"
  curl -fsSL "$TOR_KEY_URL" -o "$tmpkey"

  log "Verifying signing key fingerprint..."
  local fpr
  fpr="$(gpg --with-colons --show-keys "$tmpkey" | awk -F: '/^fpr:/ {print $10; exit}')"
  rm -f -- "$tmpkey"

  [[ "$fpr" == "$TOR_KEY_FPR_EXPECTED" ]] || die "Key fingerprint mismatch. Expected $TOR_KEY_FPR_EXPECTED, got $fpr"

  rm -f "$TOR_KEYRING"
  curl -fsSL "$TOR_KEY_URL" | gpg --dearmor > "$TOR_KEYRING"
  chmod 0644 "$TOR_KEYRING"

  local codename
  codename="$(lsb_release -cs)"
  printf 'deb [signed-by=%s] https://deb.torproject.org/torproject.org %s main\n' \
    "$TOR_KEYRING" "$codename" > "$TOR_LIST"

  log "Repo added for distro codename: ${codename}"
}

install_packages() {
  log "Installing Tor, obfs4proxy and nyx..."
  apt-get update -qq
  apt-get install -y -qq tor obfs4proxy nyx >/dev/null
  require_cmd tor
  require_cmd obfs4proxy
  require_cmd ss
}

backup_torrc() {
  if [[ -f "$TORRC" ]]; then
    local ts
    ts="$(date +%F_%H%M%S)"
    cp -a "$TORRC" "${TORRC}.backup.${ts}"
    log "Backed up existing torrc to ${TORRC}.backup.${ts}"
  fi
}

write_torrc() {
  log "Writing Tor bridge configuration to ${TORRC}..."

  cat > "$TORRC" <<EOF
# --- Private Tor Bridge Configuration ---
# Generated by setup-bridge.sh

BridgeRelay 1
PublishServerDescriptor 0

ServerTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ServerTransportListenAddr obfs4 0.0.0.0:${PT_PORT}

ORPort ${OR_PORT}

SocksPort 0
ExitPolicy reject *:*

ControlPort 127.0.0.1:9051
CookieAuthentication 1

ContactInfo ${EMAIL}

DataDirectory /var/lib/tor
User debian-tor
EOF

  log "Verifying Tor configuration..."
  local verify_out=""
  if ! verify_out="$(tor --verify-config -f "$TORRC" 2>&1)"; then
    echo "$verify_out" >&2
    echo -e "\n---- /etc/tor/torrc (debug) ----" >&2
    nl -ba "$TORRC" >&2
    die "Tor config verification failed."
  fi

  log "Tor configuration verified OK."
}

get_sshd_listening_ports() {
  # Detect sshd ports via ss (covers non-standard ports)
  ss -Hltpn 2>/dev/null \
    | awk '/users:\(\("sshd"/ {print $4}' \
    | sed -E 's/.*:([0-9]+)$/\1/' \
    | grep -E '^[0-9]+$' \
    | sort -u || true
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW not installed. Ensure provider firewall allows TCP ${OR_PORT} and ${PT_PORT}."
    return 0
  fi

  # You can add rules even when ufw is inactive.
  log "Configuring UFW rules..."
  ufw allow 22/tcp >/dev/null || true

  local ssh_ports
  ssh_ports="$(get_sshd_listening_ports || true)"
  if [[ -n "$ssh_ports" ]]; then
    while read -r p; do
      [[ -n "$p" ]] || continue
      ufw allow "${p}/tcp" >/dev/null || true
    done <<< "$ssh_ports"
    log "Allowed detected sshd ports: $(echo "$ssh_ports" | tr '\n' ' ')"
  else
    warn "Could not detect sshd listening port(s). At minimum, 22/tcp was allowed."
  fi

  ufw allow "${OR_PORT}/tcp" >/dev/null || true
  ufw allow "${PT_PORT}/tcp" >/dev/null || true

  # Enable only if requested
  if [[ "$ENABLE_UFW" -eq 1 ]]; then
    log "Enabling UFW (requested via --enable-ufw)..."
    ufw --force enable >/dev/null
    log "UFW enabled."
  else
    # Keep prior behavior: do not enable automatically
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      log "UFW is active. Rules updated."
    else
      warn "UFW installed but inactive. Run: sudo ufw enable (or re-run with --enable-ufw)."
    fi
  fi
}

restart_tor() {
  log "Enabling and restarting Tor service..."
  systemctl daemon-reload || true
  systemctl stop tor >/dev/null 2>&1 || true
  systemctl enable --now tor >/dev/null
  systemctl restart tor

  sleep 2
  systemctl is-active --quiet tor || die "Tor failed to start. Check: journalctl -u tor -e"
  log "Tor service is active."
}

get_public_ip() {
  local ip=""
  ip="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsSL https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="<YOUR_SERVER_PUBLIC_IP>"
  printf '%s' "$ip"
}

wait_for_bridge_line() {
  log "Waiting for obfs4 bridge line to appear..."
  local retries=120 i=0
  while [[ $i -lt $retries ]]; do
    if [[ -f "$BRIDGE_FILE" ]] && grep -qE '^[[:space:]]*Bridge[[:space:]]+obfs4[[:space:]]+' "$BRIDGE_FILE" 2>/dev/null; then
      return 0
    fi
    sleep 1
    ((i++))
  done
  return 1
}

get_tor_fingerprint() {
  if [[ -f "$TOR_FINGERPRINT_FILE" ]]; then
    awk '{print $2}' "$TOR_FINGERPRINT_FILE" | tr -d '\r' | tr '[:lower:]' '[:upper:]'
  else
    echo ""
  fi
}

get_bridge_line_raw() {
  grep -m1 -E '^[[:space:]]*Bridge[[:space:]]+obfs4[[:space:]]+' "$BRIDGE_FILE" 2>/dev/null || true
}

extract_cert() { echo "$1" | grep -oE 'cert=[^ ]+' | head -n1 || true; }
extract_iat()  { echo "$1" | grep -oE 'iat-mode=[^ ]+' | head -n1 || true; }
extract_hex40_fingerprint() { echo "$1" | grep -oE '[A-Fa-f0-9]{40}' | head -n1 | tr '[:lower:]' '[:upper:]' || true; }

print_result() {
  echo -e "\n${GREEN}======================================================${NC}"
  echo -e "${GREEN}              INSTALLATION COMPLETE                   ${NC}"
  echo -e "${GREEN}======================================================${NC}\n"

  local public_ip tor_fp raw stripped cert iat obfs_fp
  public_ip="$(get_public_ip)"
  tor_fp="$(get_tor_fingerprint)"

  if ! wait_for_bridge_line; then
    warn "Bridge line not generated yet: ${BRIDGE_FILE}"
    warn "Tor may still be bootstrapping. Check: sudo journalctl -u tor -e"
    warn "Try later: sudo cat ${BRIDGE_FILE}"
    return 0
  fi

  raw="$(get_bridge_line_raw)"
  [[ -n "$raw" ]] || die "Could not find 'Bridge obfs4 ...' line in ${BRIDGE_FILE}"

  stripped="$(echo "$raw" | sed -E 's/^[[:space:]]*Bridge[[:space:]]+//')"

  cert="$(extract_cert "$stripped")"
  iat="$(extract_iat "$stripped")"
  obfs_fp="$(extract_hex40_fingerprint "$stripped")"

  [[ -n "$iat" ]] || iat="iat-mode=0"
  [[ -n "$obfs_fp" ]] || obfs_fp="$tor_fp"

  [[ -n "$cert" ]] || die "Bridge line is incomplete (missing cert=...)."

  local bridge_line="obfs4 ${public_ip}:${PT_PORT} ${obfs_fp} ${cert} ${iat}"

  echo -e "${YELLOW}Detected parameters:${NC}"
  echo "  Public IP:         ${public_ip}"
  echo "  OR_PORT (ORPort):  ${OR_PORT}"
  echo "  PT_PORT (obfs4):   ${PT_PORT}"
  [[ -n "$tor_fp"  ]] && echo "  Tor Fingerprint:   ${tor_fp}"
  [[ -n "$obfs_fp" ]] && echo "  obfs4 Fingerprint: ${obfs_fp}"

  echo -e "\n${YELLOW}Bridge Line (paste into Tor Browser):${NC}"
  echo "----------------------------------------------------------------"
  echo "${bridge_line}"
  echo "----------------------------------------------------------------"

  echo -e "\n${BLUE}Management:${NC}"
  echo "  • Monitor:     sudo nyx"
  echo "  • Logs:        sudo journalctl -u tor -e"
  echo "  • Restart:     sudo systemctl restart tor"
  echo "  • Bridge file: sudo cat ${BRIDGE_FILE}"
  echo "  • Ports:       sudo ss -tulpn | egrep '(:${OR_PORT}|:${PT_PORT})'"
}

main() {
  require_root
  parse_args "$@"
  install_prereqs
  collect_config
  add_tor_repo
  install_packages
  backup_torrc
  write_torrc
  configure_firewall
  restart_tor
  print_result
}

main "$@"

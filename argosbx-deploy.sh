#!/usr/bin/env bash
# Reproducible Argosbx deployment wrapper. See README.md.
set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="0.2.0"
readonly UPSTREAM_REPO="https://github.com/yonggekkk/argosbx"
readonly UPSTREAM_COMMIT="59e5d34519253fe2f17f4789dba22e2ad09e9b57"
readonly UPSTREAM_SHA256="95ec2799ba39a2eab15be3effaf5cfa5b2fdda64bf6a086e2aecf30369e483d7"
readonly PATCHED_SHA256="b4e211e22df646523b9b4ecc18fa96e23a496462f6caf3e85b41817420d8d19d"
readonly XRAY_AMD64_SHA256="8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed"
readonly CLOUDFLARED_VERSION="2026.7.3"
readonly CLOUDFLARED_AMD64_SHA256="9d71c677db00134c1bd4144b7783486b654ad281b1ea62b4972098d19f770f17"
readonly CLOUDFLARED_ARM64_SHA256="65259e652a7bea08bf5df603233ab22b8bf3116af8df9f9206209af6a1b955c0"
readonly STATE_DIR="/root/agsbx"
readonly BIN_DIR="/root/bin"
readonly WEB_ROOT="/root/websbx"
readonly DEPLOY_SELF="/root/bin/argosbx-deploy"
readonly XCONF="/root/agsbx/xr.json"
readonly XRAY_BIN="/root/agsbx/xray"
readonly CLOUDFLARED_BIN="/root/agsbx/cloudflared"
readonly -a SUBSCRIPTION_FILES=(clmi.yaml sbox.json sbox-1.14.json sbox-legacy.json jhsub.txt)
readonly -a STRUCTURED_SUBSCRIPTION_FILES=(clmi.yaml sbox.json sbox-1.14.json sbox-legacy.json)

NODE_NAME=${NODE_NAME:-argosbx}
REALITY_SNI=${REALITY_SNI:-www.bing.com}
VLESS_PORT=${VLESS_PORT:-443}
HY2_PORT=${HY2_PORT:-443}
VMESS_ORIGIN_PORT=${VMESS_ORIGIN_PORT:-44020}
UUID=${UUID:-}
SUB_TOKEN=${SUB_TOKEN:-}
CF_PRIMARY_IP=${CF_PRIMARY_IP:-}
CF_BACKUP_IP=${CF_BACKUP_IP:-}
CF_CANDIDATES=${CF_CANDIDATES:-"172.64.145.93 108.162.192.5 104.16.0.1 104.17.0.1 104.18.0.1 104.19.0.1 104.20.0.1 104.21.0.1 104.22.0.1 104.23.0.1"}
SKIP_CDN_PROBE=${SKIP_CDN_PROBE:-0}
SKIP_BBR=${SKIP_BBR:-0}
FORCE=${FORCE:-0}
DRY_RUN=${DRY_RUN:-0}
EDGE_IP_VERSION=${EDGE_IP_VERSION:-4}
ARGO_MODE=${ARGO_MODE:-quick}
ARGO_DOMAIN=${ARGO_DOMAIN:-}
ARGO_TOKEN=${ARGO_TOKEN:-}

BACKUP_DIR=
PUBLIC_IPV4=
SUB_BASE=

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }
on_error() {
  local line=$1 status=$2
  printf '[%s] ERROR: command failed at line %s (status %s)\n' "$(date -u +%H:%M:%S)" "$line" "$status" >&2
}
trap 'on_error "${LINENO}" "$?"' ERR

usage() {
  cat <<'USAGE'
argosbx-deploy.sh — reproducible Argosbx node deployment

Usage: bash argosbx-deploy.sh [options]

Options:
  --node-name NAME          Node-name prefix (default: argosbx)
  --reality-sni HOST        Reality SNI/destination (default: www.bing.com)
  --uuid UUID               Reuse UUID; otherwise generate one
  --subscription-token T    Reuse URL-safe token; otherwise generate one
  --cf-primary-ip IP        Explicit Cloudflare IPv4 for Argo TLS/443
  --cf-backup-ip IP         Explicit Cloudflare IPv4 for Argo plain/80
  --cf-candidates "IP ..."  Candidate IPv4 list for TCP probing
  --skip-cdn-probe          Use explicit/default CDN IPs without probing
  --no-bbr                  Do not change BBR/fq sysctl/qdisc
  --origin-port PORT        Loopback VMess-WS origin port (default: 44020)
  --quick-tunnel             Use an accountless Quick Tunnel (default)
  --argo-domain HOST         Named Tunnel hostname
  --argo-token TOKEN          Named Tunnel token (implies named mode)
  --force                    Move existing files/services to a backup first
  --dry-run                  Validate and print the resolved plan only
  -h, --help                Show this help

For a named Cloudflare Tunnel, set both ARGO_DOMAIN and ARGO_TOKEN and make
sure the Tunnel ingress already points to http://127.0.0.1:44020.
USAGE
}

require_value() {
  [[ $# -ge 2 && -n ${2:-} ]] || die "$1 requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --node-name) require_value "$@"; NODE_NAME=$2; shift ;;
      --reality-sni) require_value "$@"; REALITY_SNI=$2; shift ;;
      --uuid) require_value "$@"; UUID=$2; shift ;;
      --subscription-token) require_value "$@"; SUB_TOKEN=$2; shift ;;
      --cf-primary-ip) require_value "$@"; CF_PRIMARY_IP=$2; shift ;;
      --cf-backup-ip) require_value "$@"; CF_BACKUP_IP=$2; shift ;;
      --cf-candidates) require_value "$@"; CF_CANDIDATES=$2; shift ;;
      --skip-cdn-probe) SKIP_CDN_PROBE=1 ;;
      --no-bbr) SKIP_BBR=1 ;;
      --origin-port) require_value "$@"; VMESS_ORIGIN_PORT=$2; shift ;;
      --quick-tunnel) ARGO_MODE=quick; ARGO_DOMAIN=; ARGO_TOKEN= ;;
      --argo-domain) require_value "$@"; ARGO_DOMAIN=$2; ARGO_MODE=named; shift ;;
      --argo-token) require_value "$@"; ARGO_TOKEN=$2; ARGO_MODE=named; shift ;;
      --force) FORCE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --) shift; [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"; break ;;
      *) die "unknown option: $1 (use --help)" ;;
    esac
    shift
  done
}

valid_port() {
  local value=$1 number
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  number=$((10#$value))
  (( number >= 1 && number <= 65535 ))
}

valid_ipv4() {
  local value=$1 octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}

valid_host() {
  local value=$1
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$value" != *..* && ${#value} -le 253 ]]
}

validate_config() {
  [[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "NODE_NAME contains unsafe characters"
  valid_host "$REALITY_SNI" || die "invalid REALITY_SNI: $REALITY_SNI"
  valid_port "$VLESS_PORT" || die "invalid VLESS_PORT: $VLESS_PORT"
  valid_port "$HY2_PORT" || die "invalid HY2_PORT: $HY2_PORT"
  valid_port "$VMESS_ORIGIN_PORT" || die "invalid VMESS_ORIGIN_PORT: $VMESS_ORIGIN_PORT"
  (( VMESS_ORIGIN_PORT != 80 && VMESS_ORIGIN_PORT != 443 )) || die "VMESS_ORIGIN_PORT must not be 80 or 443"
  if [[ -n "$UUID" ]]; then
    [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || die "UUID is not RFC 4122 format"
  fi
  if [[ -n "$SUB_TOKEN" ]]; then
    [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || die "SUB_TOKEN must be URL-safe and 16-128 characters"
  fi
  case "$EDGE_IP_VERSION" in 4|6|auto) ;; *) die "EDGE_IP_VERSION must be 4, 6, or auto" ;; esac
  case "$ARGO_MODE" in
    quick) [[ -z "$ARGO_DOMAIN" && -z "$ARGO_TOKEN" ]] || die "quick mode cannot include named tunnel values" ;;
    named)
      [[ -n "$ARGO_DOMAIN" && -n "$ARGO_TOKEN" ]] || die "named mode requires ARGO_DOMAIN and ARGO_TOKEN"
      valid_host "$ARGO_DOMAIN" || die "invalid ARGO_DOMAIN: $ARGO_DOMAIN"
      [[ "$ARGO_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die "ARGO_TOKEN contains unsupported characters"
      ;;
    *) die "ARGO_MODE must be quick or named" ;;
  esac
  [[ -z "$CF_PRIMARY_IP" ]] || valid_ipv4 "$CF_PRIMARY_IP" || die "invalid CF_PRIMARY_IP"
  [[ -z "$CF_BACKUP_IP" ]] || valid_ipv4 "$CF_BACKUP_IP" || die "invalid CF_BACKUP_IP"
  [[ "$CF_PRIMARY_IP" != "$CF_BACKUP_IP" ]] || [[ -z "$CF_PRIMARY_IP" ]] || die "CDN IPs must differ"
}

print_plan() {
  cat <<PLAN
Argosbx installer $INSTALLER_VERSION (dry-run)
  upstream commit : $UPSTREAM_COMMIT
  Reality SNI     : $REALITY_SNI
  VLESS TCP port  : $VLESS_PORT
  Hysteria2 port  : $HY2_PORT/udp
  VMess origin    : 127.0.0.1:$VMESS_ORIGIN_PORT (never public)
  Argo mode       : $ARGO_MODE
  Sing-box configs: 1.11, 1.12-1.13, 1.14+
  CDN probe       : $([[ "$SKIP_CDN_PROBE" == 1 ]] && printf disabled || printf enabled)
  BBR/fq          : $([[ "$SKIP_BBR" == 1 ]] && printf disabled || printf enabled)
  force           : $FORCE
  UUID            : $([[ -n "$UUID" ]] && printf provided || printf generated)
  subscription    : $([[ -n "$SUB_TOKEN" ]] && printf provided || printf generated)
PLAN
}

ensure_root_and_systemd() {
  [[ "$(uname -s)" == Linux ]] || die "this installer targets Linux"
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  [[ -d /run/systemd/system ]] || die "systemd is not PID 1"
  command -v apt-get >/dev/null 2>&1 || die "Debian/Ubuntu apt-get is required"
}

ensure_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    ca-certificates curl openssl python3 busybox coreutils iproute2 procps \
    util-linux kmod tar >/dev/null
  local command_name
  for command_name in curl sha256sum python3 busybox systemctl ss sysctl tc modprobe flock; do
    command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
  done
}

acquire_lock() {
  exec 9>/run/lock/argosbx-deploy.lock
  flock -n 9 || die "another argosbx deployment is running"
}

backup_existing() {
  BACKUP_DIR="/root/argosbx-backups/preinstall-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p -m 700 "$BACKUP_DIR"
  printf 'installer_version=%s\nupstream_commit=%s\n' "$INSTALLER_VERSION" "$UPSTREAM_COMMIT" > "$BACKUP_DIR/metadata"
  chmod 600 "$BACKUP_DIR/metadata"
  local path
  for path in "$STATE_DIR" "$WEB_ROOT" "$BIN_DIR/agsbx" "$DEPLOY_SELF" \
    /etc/systemd/system/xr.service /etc/systemd/system/sb.service \
    /etc/systemd/system/argo.service /etc/systemd/system/argosbx-argo.service \
    /etc/systemd/system/argosbx-sub.service /etc/sysctl.d/99-argosbx-bbr.conf; do
    if [[ -e "$path" || -L "$path" ]]; then cp -a -- "$path" "$BACKUP_DIR/$(basename "$path")"; fi
  done
  if crontab -l >/dev/null 2>&1; then
    crontab -l > "$BACKUP_DIR/root.crontab"
    chmod 600 "$BACKUP_DIR/root.crontab"
  fi
  log "backup saved at $BACKUP_DIR"
}

move_existing_targets() {
  [[ "$FORCE" == 1 ]] || {
    local path
    for path in "$STATE_DIR" "$WEB_ROOT" "$BIN_DIR/agsbx" \
      /etc/systemd/system/xr.service /etc/systemd/system/argosbx-argo.service \
      /etc/systemd/system/argosbx-sub.service; do
      [[ -e "$path" || -L "$path" ]] && die "$path already exists; use --force"
    done
    return 0
  }
  local service path
  for service in xr.service sb.service sing-box.service argo.service argosbx-argo.service argosbx-sub.service; do
    systemctl disable --now "$service" >/dev/null 2>&1 || true
  done
  for path in "$STATE_DIR" "$WEB_ROOT" "$BIN_DIR/agsbx" "$DEPLOY_SELF" \
    /etc/systemd/system/xr.service /etc/systemd/system/sb.service \
    /etc/systemd/system/argo.service /etc/systemd/system/argosbx-argo.service \
    /etc/systemd/system/argosbx-sub.service; do
    if [[ -e "$path" || -L "$path" ]]; then mv -- "$path" "$BACKUP_DIR/$(basename "$path").replaced"; fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
}

write_atomic() {
  local destination=$1 mode=$2 directory temporary
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.argosbx-write.XXXXXX")
  cat > "$temporary"
  chmod "$mode" "$temporary"
  chown root:root "$temporary"
  mv -f -- "$temporary" "$destination"
}

configure_bbr() {
  if [[ "$SKIP_BBR" == 1 ]]; then warn "BBR/fq skipped by request"; return; fi
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe sch_fq >/dev/null 2>&1 || true
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || die "kernel does not expose BBR"
  write_atomic /etc/sysctl.d/99-argosbx-bbr.conf 644 <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
  sysctl --system >/dev/null
  local interface
  interface=$(ip -4 route show default | awk 'NR==1 {print $5}')
  [[ -z "$interface" ]] || tc qdisc replace dev "$interface" root fq
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || die "BBR runtime setting failed"
  [[ "$(sysctl -n net.core.default_qdisc)" == fq ]] || die "fq runtime setting failed"
  log "BBR + fq enabled"
}

probe_tcp_ms() {
  python3 -c 'import socket,sys,time; h,p=sys.argv[1],int(sys.argv[2]); s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.settimeout(1.2); t=time.monotonic(); s.connect((h,p)); s.close(); print((time.monotonic()-t)*1000)' "$1" "$2"
}

choose_cdn_ips() {
  local -a candidates=() tls_results=() plain_results=()
  read -r -a candidates <<< "$CF_CANDIDATES"
  if [[ "$SKIP_CDN_PROBE" == 1 ]]; then
    CF_PRIMARY_IP=${CF_PRIMARY_IP:-172.64.145.93}
    CF_BACKUP_IP=${CF_BACKUP_IP:-108.162.192.5}
    [[ "$CF_BACKUP_IP" != "$CF_PRIMARY_IP" ]] || CF_BACKUP_IP=172.64.145.93
    [[ "$CF_BACKUP_IP" != "$CF_PRIMARY_IP" ]] || die "CDN IPs must differ"
    log "CDN probe skipped; using $CF_PRIMARY_IP (443) and $CF_BACKUP_IP (80)"
    return
  fi
  local candidate latency
  for candidate in "${candidates[@]}"; do
    valid_ipv4 "$candidate" || { warn "ignoring invalid CDN candidate $candidate"; continue; }
    if [[ -z "$CF_PRIMARY_IP" ]]; then
      latency=$(probe_tcp_ms "$candidate" 443 2>/dev/null || true)
      [[ -n "$latency" ]] && tls_results+=("$latency $candidate")
    fi
    if [[ -z "$CF_BACKUP_IP" ]]; then
      latency=$(probe_tcp_ms "$candidate" 80 2>/dev/null || true)
      [[ -n "$latency" ]] && plain_results+=("$latency $candidate")
    fi
  done
  if [[ -z "$CF_PRIMARY_IP" && ${#tls_results[@]} -gt 0 ]]; then
    CF_PRIMARY_IP=$(printf '%s\n' "${tls_results[@]}" | sort -n | awk 'NR==1 {print $2}')
  fi
  if [[ -z "$CF_BACKUP_IP" && ${#plain_results[@]} -gt 0 ]]; then
    CF_BACKUP_IP=$(printf '%s\n' "${plain_results[@]}" | sort -n | awk -v primary="$CF_PRIMARY_IP" '$2 != primary {print; exit}' | awk '{print $2}')
  fi
  CF_PRIMARY_IP=${CF_PRIMARY_IP:-172.64.145.93}
  CF_BACKUP_IP=${CF_BACKUP_IP:-108.162.192.5}
  [[ "$CF_BACKUP_IP" != "$CF_PRIMARY_IP" ]] || CF_BACKUP_IP=108.162.192.5
  valid_ipv4 "$CF_PRIMARY_IP" || die "invalid selected primary CDN IP"
  valid_ipv4 "$CF_BACKUP_IP" || die "invalid selected backup CDN IP"
  log "CDN probe selected $CF_PRIMARY_IP (443) and $CF_BACKUP_IP (80)"
}

download_verified() {
  local destination=$1 url=$2 expected=$3 temporary
  temporary=$(mktemp "$(dirname "$destination")/.argosbx-download.XXXXXX")
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 10 --max-time 300 -o "$temporary" "$url"
  printf '%s  %s\n' "$expected" "$temporary" | sha256sum -c - >/dev/null || die "SHA256 mismatch for $url"
  chmod 600 "$temporary"
  chown root:root "$temporary"
  mv -f -- "$temporary" "$destination"
}

download_upstream() {
  mkdir -p -m 700 "$BIN_DIR"
  local upstream_file="$BIN_DIR/agsbx.upstream-$UPSTREAM_COMMIT"
  local raw_url="$UPSTREAM_REPO/raw/$UPSTREAM_COMMIT/argosbx.sh"
  if [[ ! -f "$upstream_file" ]] || [[ "$(sha256sum "$upstream_file" | awk '{print $1}')" != "$UPSTREAM_SHA256" ]]; then
    log "downloading pinned Argosbx source"
    download_verified "$upstream_file" "$raw_url" "$UPSTREAM_SHA256"
  fi
  install -m 700 -o root -g root "$upstream_file" "$BIN_DIR/agsbx"
  python3 - "$BIN_DIR/agsbx" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
block = '''\t  "http_clients": [
    {
      "tag": "http-client-direct"
    }
    ],
'''
line = '        "default_http_client": "http-client-direct",\n'
if source.count(block) != 1 or source.count(line) != 1:
    raise SystemExit("unexpected upstream generator layout; refusing to patch")
path.write_text(source.replace(block, '', 1).replace(line, '', 1))
PY
  [[ "$(sha256sum "$BIN_DIR/agsbx" | awk '{print $1}')" == "$PATCHED_SHA256" ]] || die "patched Argosbx hash mismatch"
  log "pinned Argosbx source verified"
}

run_upstream() {
  local upstream_log="$BACKUP_DIR/upstream-install.log"
  local status runner
  local -a environment=(
    HOME=/root
    LANG=C.UTF-8
    vlpt="$VLESS_PORT"
    hypt="$HY2_PORT"
    vmpt="$VMESS_ORIGIN_PORT"
    reym="$REALITY_SNI"
    name="$NODE_NAME"
    cfip="$CF_PRIMARY_IP $CF_BACKUP_IP"
    argo=
  )
  [[ -n "$UUID" ]] && environment+=(uuid="$UUID")
  runner=$(mktemp "$BACKUP_DIR/upstream-run.XXXXXX")
  install -m 700 -o root -g root "$BIN_DIR/agsbx" "$runner"
  log "running pinned upstream generator (log: $upstream_log)"
  set +e
  timeout 900s env -i PATH="$PATH" "${environment[@]}" bash "$runner" 2>&1 | tee "$upstream_log"
  status=${PIPESTATUS[0]}
  set -e
  rm -f -- "$runner"
  # Upstream refreshes /root/bin/agsbx while installing. Restore the pinned,
  # compatibility-patched copy used by later subscription refreshes.
  download_upstream
  (( status == 0 )) || die "upstream generator failed; see $upstream_log"
  [[ -x "$XRAY_BIN" && -f "$XCONF" && -f "$STATE_DIR/uuid" ]] || die "upstream did not create Xray state"
  if [[ "$(uname -m)" == x86_64 ]]; then
    [[ "$(sha256sum "$XRAY_BIN" | awk '{print $1}')" == "$XRAY_AMD64_SHA256" ]] || die "Xray amd64 SHA256 mismatch"
  else
    warn "Xray arm64 binary version is checked by the upstream script; no local arm64 digest is pinned"
  fi
}

patch_xray_config() {
  systemctl stop xr.service >/dev/null 2>&1 || true
  local uuid
  uuid=$(tr -d '[:space:]' < "$STATE_DIR/uuid")
  python3 - "$XCONF" "$uuid" "$VMESS_ORIGIN_PORT" <<'PY'
import json
import os
import sys
from pathlib import Path
path = Path(sys.argv[1])
uuid = sys.argv[2]
origin_port = int(sys.argv[3])
config = json.loads(path.read_text())
inbounds = config.setdefault("inbounds", [])
vmess = next((item for item in inbounds if item.get("protocol") == "vmess"), None)
if vmess is None:
    vmess = {
        "tag": "vmess-argo-origin",
        "listen": "127.0.0.1",
        "port": origin_port,
        "protocol": "vmess",
        "settings": {"clients": [{"id": uuid}]},
        "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": f"{uuid}-vm"}},
    }
    inbounds.append(vmess)
vmess["listen"] = "127.0.0.1"
vmess["port"] = origin_port
vmess.setdefault("settings", {}).setdefault("clients", [{}])
vmess["settings"]["clients"][0]["id"] = uuid
stream = vmess.setdefault("streamSettings", {})
stream["network"] = "ws"
stream["security"] = "none"
stream.setdefault("wsSettings", {})["path"] = f"{uuid}-vm"
config.setdefault("log", {})["loglevel"] = "warning"
temporary = path.with_name(path.name + ".tmp")
temporary.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
  chmod 600 "$XCONF"
  chown root:root "$XCONF"
  "$XRAY_BIN" run -test -config "$XCONF" >/dev/null || die "Xray configuration validation failed"
  log "VMess origin restricted to 127.0.0.1:$VMESS_ORIGIN_PORT"
}

install_self() {
  [[ -f "$BASH_SOURCE" ]] || die "save this installer to a file before running it"
  install -m 700 -o root -g root "$BASH_SOURCE" "$DEPLOY_SELF"
}

install_cloudflared() {
  local asset expected url temporary
  case "$(uname -m)" in
    x86_64|amd64) asset=amd64; expected=$CLOUDFLARED_AMD64_SHA256 ;;
    aarch64|arm64) asset=arm64; expected=$CLOUDFLARED_ARM64_SHA256 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  url="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$asset"
  temporary=$(mktemp "$STATE_DIR/.cloudflared.XXXXXX")
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 10 --max-time 300 -o "$temporary" "$url"
  printf '%s  %s\n' "$expected" "$temporary" | sha256sum -c - >/dev/null || die "cloudflared SHA256 mismatch"
  chmod 700 "$temporary"; chown root:root "$temporary"; mv -f -- "$temporary" "$CLOUDFLARED_BIN"
  "$CLOUDFLARED_BIN" version | grep -Fq "$CLOUDFLARED_VERSION" || die "unexpected cloudflared version"
  log "cloudflared $CLOUDFLARED_VERSION verified"
}

install_subscription_layout() {
  [[ -n "$SUB_TOKEN" ]] || SUB_TOKEN=$(openssl rand -hex 24)
  [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || die "subscription token is invalid"
  mkdir -p -m 700 "$WEB_ROOT/$SUB_TOKEN"
  local file
  for file in "${SUBSCRIPTION_FILES[@]}"; do
    [[ -e "$STATE_DIR/$file" ]] || : > "$STATE_DIR/$file"
    if [[ -e "$WEB_ROOT/$SUB_TOKEN/$file" || -L "$WEB_ROOT/$SUB_TOKEN/$file" ]]; then rm -f -- "$WEB_ROOT/$SUB_TOKEN/$file"; fi
    ln -s "$STATE_DIR/$file" "$WEB_ROOT/$SUB_TOKEN/$file"
  done
  chmod 700 "$STATE_DIR" "$WEB_ROOT" "$WEB_ROOT/$SUB_TOKEN"
  write_atomic "$STATE_DIR/sub-token" 600 <<TOKEN
$SUB_TOKEN
TOKEN
}

generate_sing_box_variants() {
  local source=$1 modern_destination=$2 legacy_destination=$3
  python3 - "$source" "$modern_destination" "$legacy_destination" <<'PY'
import copy
import json
import os
import sys
from pathlib import Path

source = Path(sys.argv[1])
modern_destination = Path(sys.argv[2])
legacy_destination = Path(sys.argv[3])
base = json.loads(source.read_text())

modern = copy.deepcopy(base)
modern["http_clients"] = [{"tag": "http-client-direct"}]
modern["route"]["default_http_client"] = "http-client-direct"

legacy = copy.deepcopy(base)
legacy["dns"]["servers"] = [
    {
        "tag": "aliDns",
        "address": "https://dns.alidns.com/dns-query",
        "address_resolver": "local",
    },
    {"tag": "local", "address": "223.5.5.5"},
    {
        "tag": "proxyDns",
        "address": "https://dns.google/dns-query",
        "address_resolver": "aliDns",
        "detour": "proxy",
    },
    {"tag": "fakeip", "address": "fakeip"},
]
legacy["dns"]["fakeip"] = {
    "enabled": True,
    "inet4_range": "198.18.0.0/15",
    "inet6_range": "fc00::/18",
}
legacy["route"].pop("default_domain_resolver", None)

for destination, config in (
    (modern_destination, modern),
    (legacy_destination, legacy),
):
    destination.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    os.chmod(destination, 0o600)
PY
}

wait_for_quick_tunnel_domain() {
  local log_file=$1 max_attempts=${2:-60} attempt domain
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -n1 | sed 's#^https://##' || true)
    if valid_host "$domain" && [[ "$domain" == *.trycloudflare.com ]]; then
      printf '%s\n' "$domain"
      return 0
    fi
    (( attempt == max_attempts )) || sleep 1
  done
  return 1
}

refresh_subscriptions() {
  local mode domain stage list_status=0 token file vless_count hy2_count vmess_count domain_in_raw=false
  mode=$(cat "$STATE_DIR/argo-mode" 2>/dev/null || printf quick)
  if [[ "$mode" == named ]]; then
    domain=$(tr -d '[:space:]' < "$STATE_DIR/sbargoym.log" 2>/dev/null || true)
  else
    domain=$(wait_for_quick_tunnel_domain "$STATE_DIR/argo.log" 60 || true)
  fi
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.([A-Za-z]{2,})$ ]] || die "Argo hostname unavailable"
  [[ -f "$BIN_DIR/agsbx" ]] || die "patched generator missing"
  [[ "$(sha256sum "$BIN_DIR/agsbx" | awk '{print $1}')" == "$PATCHED_SHA256" ]] || die "unexpected generator hash"
  stage=$(mktemp -d /root/.argosbx-cdn-sub.XXXXXX)
  trap '[[ -z ${stage:-} ]] || rm -rf -- "$stage"' EXIT
  mkdir -m 700 "$stage/agsbx" "$stage/bin"
  cp -a "$STATE_DIR/." "$stage/agsbx/"
  cp -a "$BIN_DIR/agsbx" "$stage/bin/agsbx"
  printf '%s\n' "$domain" > "$stage/agsbx/sbargoym.log"
  printf 'Vmess\n' > "$stage/agsbx/vlvm"
  HOME="$stage" vmpt="$(cat "$stage/agsbx/port_vm_ws")" bash "$stage/bin/agsbx" list > "$stage/list.log" 2>&1 || list_status=$?
  python3 - "$stage/agsbx/jhsub.txt" "$(cat "$stage/agsbx/port_vm_ws")" <<'PY'
import base64
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
origin_port = str(sys.argv[2])
kept = []
for line in path.read_text().splitlines():
    if line.startswith("vmess://"):
        try:
            payload = line[len("vmess://"):]
            payload += "=" * (-len(payload) % 4)
            item = json.loads(base64.b64decode(payload).decode())
            if str(item.get("port")) == origin_port:
                continue
        except Exception:
            pass
    kept.append(line)
path.write_text("\n".join(kept) + "\n")
PY
  python3 -m json.tool "$stage/agsbx/sbox.json" >/dev/null || die "generated sbox.json is invalid"
  grep -Eq '"(http_clients|default_http_client)"' "$stage/agsbx/sbox.json" && die "unsupported sing-box fields generated"
  generate_sing_box_variants \
    "$stage/agsbx/sbox.json" \
    "$stage/agsbx/sbox-1.14.json" \
    "$stage/agsbx/sbox-legacy.json"
  python3 -m json.tool "$stage/agsbx/sbox-1.14.json" >/dev/null || die "generated sbox-1.14.json is invalid"
  python3 -m json.tool "$stage/agsbx/sbox-legacy.json" >/dev/null || die "generated sbox-legacy.json is invalid"
  vless_count=$(grep -c '^vless://' "$stage/agsbx/jhsub.txt" || true)
  hy2_count=$(grep -c '^hysteria2://' "$stage/agsbx/jhsub.txt" || true)
  vmess_count=$(grep -c '^vmess://' "$stage/agsbx/jhsub.txt" || true)
  (( vless_count >= 1 && hy2_count >= 1 && vmess_count >= 1 )) || die "subscription misses a required protocol"
  for file in "${STRUCTURED_SUBSCRIPTION_FILES[@]}"; do
    [[ -s "$stage/agsbx/$file" ]] || die "generated $file is empty"
    grep -Fq "$domain" "$stage/agsbx/$file" || die "generated $file lacks active Argo hostname"
  done
  while IFS= read -r file; do
    [[ "$file" == vmess://* ]] || continue
    if printf '%s' "${file#vmess://}" | base64 -d 2>/dev/null | grep -Fq "$domain"; then domain_in_raw=true; break; fi
  done < "$stage/agsbx/jhsub.txt"
  [[ "$domain_in_raw" == true ]] || die "raw subscription lacks active Argo hostname"
  token=$(tr -d '[:space:]' < "$STATE_DIR/sub-token" 2>/dev/null || true)
  [[ "$token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || die "subscription token missing"
  for file in "${SUBSCRIPTION_FILES[@]}"; do
    chmod 600 "$stage/agsbx/$file"; chown root:root "$stage/agsbx/$file"
    mv -f -- "$stage/agsbx/$file" "$STATE_DIR/$file"
  done
  printf '%s\n' "$domain" > "$STATE_DIR/sbargoym.log"
  chmod 600 "$STATE_DIR/sbargoym.log"; chown root:root "$STATE_DIR/sbargoym.log"
  printf 'refresh ok: domain=%s vless=%s hy2=%s vmess=%s' "$domain" "$vless_count" "$hy2_count" "$vmess_count"
  (( list_status == 0 )) || printf ' (list exited %s after validated output)' "$list_status"
  printf '\n'
}

install_units() {
  write_atomic /etc/systemd/system/argosbx-sub.service 644 <<'UNIT'
[Unit]
Description=Argosbx subscription HTTP service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/busybox httpd -f -p 80 -h /root/websbx
Restart=always
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

  local argo_exec unit_mode=644
  if [[ "$ARGO_MODE" == named ]]; then
    printf '%s\n' "$ARGO_DOMAIN" > "$STATE_DIR/sbargoym.log"
    write_atomic "$STATE_DIR/argo-mode" 600 <<'MODE'
named
MODE
    write_atomic "$STATE_DIR/sbargotoken.log" 600 <<TOKEN
$ARGO_TOKEN
TOKEN
    unit_mode=600
    argo_exec="/root/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version $EDGE_IP_VERSION --protocol http2 run --token=$ARGO_TOKEN"
  else
    : > "$STATE_DIR/argo.log"
    write_atomic "$STATE_DIR/argo-mode" 600 <<'MODE'
quick
MODE
    argo_exec="/root/agsbx/cloudflared tunnel --url http://127.0.0.1:$VMESS_ORIGIN_PORT --edge-ip-version $EDGE_IP_VERSION --no-autoupdate --protocol http2 --metrics 127.0.0.1:49312"
  fi
  write_atomic /etc/systemd/system/argosbx-argo.service "$unit_mode" <<UNIT
[Unit]
Description=Argosbx Cloudflare Argo tunnel
Wants=network-online.target
After=network-online.target xr.service
Requires=xr.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
UMask=0077
ExecStartPre=/usr/bin/truncate -s 0 /root/agsbx/argo.log
ExecStart=$argo_exec
ExecStartPost=/root/bin/argosbx-deploy --refresh
ExecReload=/root/bin/argosbx-deploy --refresh
Restart=always
RestartSec=5s
TimeoutStartSec=90s
TimeoutStopSec=20s
KillSignal=SIGTERM
StandardOutput=append:/root/agsbx/argo.log
StandardError=append:/root/agsbx/argo.log
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=65536
TasksMax=128
MemoryMax=200M

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

clean_upstream_cron() {
  local current filtered
  current=$(mktemp); filtered=$(mktemp)
  if crontab -l >/dev/null 2>&1; then
    crontab -l > "$current"
    grep -Ev '/root/agsbx/(xray|sing-box|cloudflared)' "$current" > "$filtered" || true
    crontab "$filtered"
  fi
  rm -f -- "$current" "$filtered"
}

start_services() {
  clean_upstream_cron
  systemctl enable --now xr.service
  systemctl enable --now argosbx-sub.service
  systemctl enable --now argosbx-argo.service
  systemctl is-active --quiet xr.service || die "xr.service did not become active"
  systemctl is-active --quiet argosbx-sub.service || die "argosbx-sub.service did not become active"
  systemctl is-active --quiet argosbx-argo.service || die "argosbx-argo.service did not become active"
}

discover_public_ipv4() {
  PUBLIC_IPV4=$(curl -4 --fail --silent --show-error --max-time 8 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)
  valid_ipv4 "$PUBLIC_IPV4" || PUBLIC_IPV4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  valid_ipv4 "$PUBLIC_IPV4" || PUBLIC_IPV4=
}

wait_for_subscriptions() {
  local url="http://127.0.0.1/$SUB_TOKEN/clmi.yaml"
  for _ in $(seq 1 90); do
    if [[ -s "$STATE_DIR/clmi.yaml" && -s "$STATE_DIR/sbox.json" && \
          -s "$STATE_DIR/sbox-1.14.json" && -s "$STATE_DIR/sbox-legacy.json" && \
          -s "$STATE_DIR/jhsub.txt" ]] && \
       curl --fail --silent --max-time 5 "$url" | grep -q '^proxies:'; then
      return
    fi
    sleep 1
  done
  systemctl status argosbx-argo.service --no-pager >&2 || true
  die "subscription artifacts were not served successfully"
}

verify_installation() {
  "$XRAY_BIN" run -test -config "$XCONF" >/dev/null || die "Xray verification failed"
  python3 -m json.tool "$STATE_DIR/sbox.json" >/dev/null || die "sbox.json verification failed"
  python3 -m json.tool "$STATE_DIR/sbox-1.14.json" >/dev/null || die "sbox-1.14.json verification failed"
  python3 -m json.tool "$STATE_DIR/sbox-legacy.json" >/dev/null || die "sbox-legacy.json verification failed"
  grep -q '^proxies:' "$STATE_DIR/clmi.yaml" || die "Clash YAML lacks proxies"
  (( $(grep -c '^vmess://' "$STATE_DIR/jhsub.txt" || true) >= 1 )) || die "raw subscription lacks VMess"
  ss -lnt | awk '$4 ~ /127\.0\.0\.1:'"$VMESS_ORIGIN_PORT"'$/ {found=1} END {exit(found ? 0 : 1)}' || die "VMess origin is not loopback-only"
  if [[ "$SKIP_BBR" != 1 ]]; then
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || die "BBR verification failed"
    [[ "$(sysctl -n net.core.default_qdisc)" == fq ]] || die "fq verification failed"
  fi
  log "local service and subscription checks passed"
}

write_delivery_info() {
  discover_public_ipv4
  if [[ -n "$PUBLIC_IPV4" ]]; then SUB_BASE="http://$PUBLIC_IPV4/$SUB_TOKEN"; else SUB_BASE="http://<VPS_IPV4>/$SUB_TOKEN"; warn "public IPv4 discovery failed"; fi
  write_atomic "$STATE_DIR/subscription.txt" 600 <<INFO
Clash/Mihomo/Shadowrocket (Subscribe): $SUB_BASE/clmi.yaml
Sing-box 1.12-1.13: $SUB_BASE/sbox.json
Sing-box 1.14+: $SUB_BASE/sbox-1.14.json
Sing-box 1.11: $SUB_BASE/sbox-legacy.json
Raw URI list: $SUB_BASE/jhsub.txt
CDN primary IPv4: $CF_PRIMARY_IP:443
CDN backup IPv4: $CF_BACKUP_IP:80
Argo mode: $ARGO_MODE
INFO
  log "deployment complete; subscription URLs:"
  printf '  Clash/Shadowrocket: %s/clmi.yaml\n' "$SUB_BASE"
  printf '  Sing-box 1.12-1.13: %s/sbox.json\n' "$SUB_BASE"
  printf '  Sing-box 1.14+:     %s/sbox-1.14.json\n' "$SUB_BASE"
  printf '  Sing-box 1.11:      %s/sbox-legacy.json\n' "$SUB_BASE"
  printf '  Raw URI list:       %s/jhsub.txt\n' "$SUB_BASE"
  printf '  local record:       %s/subscription.txt\n' "$STATE_DIR"
}

main() {
  parse_args "$@"
  validate_config
  if [[ "$DRY_RUN" == 1 ]]; then print_plan; return 0; fi
  ensure_root_and_systemd
  acquire_lock
  ensure_dependencies
  backup_existing
  move_existing_targets
  configure_bbr
  choose_cdn_ips
  download_upstream
  run_upstream
  patch_xray_config
  install_self
  install_cloudflared
  install_subscription_layout
  install_units
  start_services
  wait_for_subscriptions
  verify_installation
  write_delivery_info
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ ${1:-} == --refresh ]]; then
    refresh_subscriptions
  else
    main "$@"
  fi
fi

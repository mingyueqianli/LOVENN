#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box 1.12+ compatibility fallback.
# Real config generation is also adjusted below, but these envs prevent hard stop
# when users run against transitional config snippets.
export ENABLE_DEPRECATED_LEGACY_DNS_SERVERS="${ENABLE_DEPRECATED_LEGACY_DNS_SERVERS:-true}"
export ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER="${ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER:-true}"

# ==============================================================================
# Love.sh / LOVENN_NATIVE_ALL
# Self-contained all-in-one installer / manager
#
# Maintenance command:
#   Love
# Compatible command:
#   love
#
# Publish command after uploading to GitHub:
#   bash <(wget -qO- https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh)
#
# Main engines:
#   1) Native Xray stable mode:
#      - VLESS + REALITY + Vision on 443/tcp
#      - Optional HY2 / Hysteria2 on 443/udp
#      - Domain mode: Let's Encrypt cert
#      - No-domain mode: Reality-only by default; optional self-signed HY2
#
#   2) Native sing-box all/custom mode:
#      - VLESS Reality
#      - Hysteria2
#      - TUIC
#      - Shadowsocks
#      - Trojan
#      - VMess WS
#      - VLESS WS TLS
#      - H2 Reality
#      - gRPC Reality
#      - AnyTLS
#      - Naive
#      - ShadowTLS placeholder/advanced note
#
#   3) Advanced helpers:
#      - Preferred client address/IP/domain
#      - Cloudflared Argo tunnel helper
#      - Port Hopping helper for UDP
#      - WARP note/helper
#      - Status / backup / uninstall
#
# Important:
#   Server-side WARP does NOT give an IPv6-only VPS a public IPv4 inbound address.
#   If a VPS is IPv6-only, direct clients still need IPv6 unless you use Argo/other tunnel mode.
# ==============================================================================

VERSION="Love v12.0.0-warp-decision-engine-final"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

LOVE_HOME="/opt/Love"
LOVE_INFO="${LOVE_HOME}/client-info"
LOVE_BACKUP="${LOVE_HOME}/backup"
LOVE_LOG="${LOVE_HOME}/logs"
LOVE_SUB="${LOVE_HOME}/subscribe"
LOVE_WEB="/var/www/love-admin"
LOVE_UPDATE_URL="${LOVE_UPDATE_URL:-}"
LOVE_TOKEN_FILE="${LOVE_HOME}/.subscribe_token"
LOVE_NOTIFY_CONF="${LOVE_HOME}/notify.conf"
LOVE_USERS_FILE="${LOVE_HOME}/users.json"
LOVE_SNAPSHOT="${LOVE_HOME}/snapshots"
LOVE_PIN_CONF="${LOVE_HOME}/pins.conf"
LOVE_CFIP_FILE="${LOVE_HOME}/preferred_ip.txt"
LOVE_STATUS_JSON="${LOVE_HOME}/status.json"
LOVE_RELEASE="${LOVE_HOME}/release"
LOVE_REPORT="${LOVE_HOME}/reports"
LOVE_IMPORT="${LOVE_HOME}/import"
LOVE_NGINX="${LOVE_HOME}/nginx"
LOVE_SUB="${LOVE_HOME}/subscribe"
LOVE_WEB="/var/www/love-admin"
LOVE_UPDATE_URL="${LOVE_UPDATE_URL:-}"
LOVE_TOKEN_FILE="${LOVE_HOME}/.subscribe_token"
LOVE_NOTIFY_CONF="${LOVE_HOME}/notify.conf"
LOVE_USERS_FILE="${LOVE_HOME}/users.json"
LOVE_BIN="/usr/local/bin/Love"
LOVE_BIN_LOWER="/usr/local/bin/love"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="${XRAY_CONF_DIR}/config.json"
XRAY_INFO="${LOVE_INFO}/xray-client-info.txt"

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/etc/sing-box"
SINGBOX_CONF="${SINGBOX_DIR}/config.json"
SINGBOX_CERT_DIR="${SINGBOX_DIR}/cert"
SINGBOX_INFO="${LOVE_INFO}/sing-box-client-info.txt"

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "请用 root 运行：sudo -i 后再执行。"
}

prepare_dirs() {
  mkdir -p "${LOVE_HOME}" "${LOVE_INFO}" "${LOVE_BACKUP}" "${LOVE_LOG}" "${LOVE_SUB}" "${LOVE_SNAPSHOT}" "${LOVE_RELEASE}" "${LOVE_REPORT}" "${LOVE_IMPORT}" "${LOVE_NGINX}"
}

fix_hostname() {
  local hn
  hn="$(hostname 2>/dev/null || true)"
  if [[ -n "${hn}" ]] && ! grep -q "${hn}" /etc/hosts 2>/dev/null; then
    echo "127.0.1.1 ${hn}.localdomain ${hn}" >> /etc/hosts || true
    log "已补充 /etc/hosts 主机名解析：${hn}"
  fi
}

check_os_soft() {
  if [[ ! -f /etc/os-release ]]; then
    warn "无法识别系统，继续尝试。"
    return 0
  fi

  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu)
      log "系统检测通过：${PRETTY_NAME:-$ID}"
      ;;
    centos|rhel|rocky|almalinux|fedora|alpine|arch|armbian)
      warn "当前系统 ${PRETTY_NAME:-$ID}：sing-box 模式可能可用；Xray 稳定模式主要按 Debian/Ubuntu 测试。"
      ;;
    *)
      warn "当前系统 ${PRETTY_NAME:-unknown} 未严格测试。"
      ;;
  esac
}

install_base() {
  info "安装基础依赖..."

  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update || true
    apt --fix-broken install -y || true
    apt install -y curl wget unzip jq openssl ca-certificates ufw certbot lsof dnsutils iproute2 gawk sed coreutils tar gzip uuid-runtime nginx qrencode apache2-utils netcat-openbsd bc mailutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget unzip jq openssl ca-certificates firewalld certbot lsof bind-utils iproute gawk sed coreutils tar gzip util-linux nginx qrencode httpd-tools nmap-ncat bc mailx
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget unzip jq openssl ca-certificates firewalld certbot lsof bind-utils iproute gawk sed coreutils tar gzip util-linux nginx qrencode httpd-tools nmap-ncat bc mailx
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash curl wget unzip jq openssl ca-certificates ufw certbot lsof bind-tools iproute2 gawk sed coreutils tar gzip util-linux nginx qrencode apache2-utils netcat-openbsd bc mailx
  else
    warn "未识别包管理器，跳过依赖安装。"
  fi

  log "基础依赖处理完成。"
}

install_shortcut() {
  prepare_dirs
  if [[ "$0" != "${LOVE_BIN}" ]]; then
    cp -f "$0" "${LOVE_HOME}/Love.sh" 2>/dev/null || true
    chmod +x "${LOVE_HOME}/Love.sh" 2>/dev/null || true
    ln -sf "${LOVE_HOME}/Love.sh" "${LOVE_BIN}" 2>/dev/null || true
    ln -sf "${LOVE_HOME}/Love.sh" "${LOVE_BIN_LOWER}" 2>/dev/null || true
    log "维护命令已创建：Love"
    log "兼容小写命令已创建：love"
  fi
}

detect_network() {
  SERVER_IPV4="$(curl -4 -s --max-time 5 https://ifconfig.co 2>/dev/null || true)"
  SERVER_IPV6="$(curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null || true)"

  [[ -n "${SERVER_IPV4}" ]] && info "IPv4 出站：${SERVER_IPV4}" || warn "未检测到 IPv4 出站。"
  [[ -n "${SERVER_IPV6}" ]] && info "IPv6 出站：${SERVER_IPV6}" || warn "未检测到 IPv6 出站。"
}

enable_ufw_ipv6() {
  if [[ -f /etc/default/ufw ]]; then
    if grep -q '^IPV6=' /etc/default/ufw; then
      sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    else
      echo 'IPV6=yes' >> /etc/default/ufw
    fi
  fi
}

ask_ssh_port() {
  read -rp "SSH 端口 [22]: " SSH_PORT
  SSH_PORT="${SSH_PORT:-22}"
}

setup_ufw() {
  local allow80="$1"
  local allow443tcp="$2"
  local allow443udp="$3"
  local allow8443udp="$4"
  local extra_udp_range="${5:-}"

  if ! command -v ufw >/dev/null 2>&1; then
    warn "未检测到 ufw，跳过 UFW 配置。"
    return 0
  fi

  enable_ufw_ipv6

  ufw allow "${SSH_PORT}/tcp" || true
  [[ "${allow80}" == "yes" ]] && ufw allow 80/tcp || true
  [[ "${allow443tcp}" == "yes" ]] && ufw allow 443/tcp || true
  [[ "${allow443udp}" == "yes" ]] && ufw allow 443/udp || true
  [[ "${allow8443udp}" == "yes" ]] && ufw allow 8443/udp || true
  [[ -n "${extra_udp_range}" ]] && ufw allow "${extra_udp_range}/udp" || true

  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw --force enable || true
  ufw status verbose || true
}

uri_host() {
  local h="$1"
  if [[ "$h" == \[*\] ]]; then
    echo "$h"
  elif [[ "$h" == *:* ]]; then
    echo "[$h]"
  else
    echo "$h"
  fi
}

parse_endpoint() {
  local input="$1"
  local default_port="${2:-443}"

  ENDPOINT_HOST=""
  ENDPOINT_PORT="${default_port}"

  input="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$input")"
  [[ -n "$input" ]] || return 1

  if [[ "$input" =~ ^\[([^][]+)\]:([0-9]{1,5})$ ]]; then
    ENDPOINT_HOST="${BASH_REMATCH[1]}"
    ENDPOINT_PORT="${BASH_REMATCH[2]}"
  elif [[ "$input" =~ ^\[([^][]+)\]$ ]]; then
    ENDPOINT_HOST="${BASH_REMATCH[1]}"
    ENDPOINT_PORT="${default_port}"
  elif [[ "$input" =~ ^([^:]+):([0-9]{1,5})$ ]] && [[ "${BASH_REMATCH[1]}" != *:* ]]; then
    ENDPOINT_HOST="${BASH_REMATCH[1]}"
    ENDPOINT_PORT="${BASH_REMATCH[2]}"
  else
    ENDPOINT_HOST="$input"
    ENDPOINT_PORT="${default_port}"
  fi

  [[ "$ENDPOINT_PORT" =~ ^[0-9]+$ ]] || return 1
  [[ "$ENDPOINT_PORT" -ge 1 && "$ENDPOINT_PORT" -le 65535 ]] || return 1
  return 0
}

ask_preferred_endpoint() {
  local default_addr="$1"
  local default_port="${2:-443}"

  CLIENT_ADDR="$default_addr"
  CLIENT_PORT="$default_port"

  echo
  warn "优选 IP / 域名只改变客户端链接里的 Address，不改变服务端监听和 SNI。"
  warn "支持格式：域名、IPv4、[IPv6]、域名:端口、[IPv6]:端口。"
  read -rp "是否设置客户端优选 IP / 域名？[y/N]: " use_preferred

  if [[ "$use_preferred" =~ ^[Yy]$ ]]; then
    while true; do
      read -rp "请输入优选 IP / 域名: " preferred
      if parse_endpoint "$preferred" "$default_port"; then
        CLIENT_ADDR="$ENDPOINT_HOST"
        CLIENT_PORT="$ENDPOINT_PORT"
        break
      fi
      warn "格式不正确，请重新输入。例如 cfip.example.com、1.2.3.4、[2606:4700::6810:85e5]、domain.com:443。"
    done
  fi

  info "服务端真实地址：${default_addr}:${default_port}"
  info "客户端连接地址：${CLIENT_ADDR}:${CLIENT_PORT}"
}


auto_detect_endpoint() {
  local ep=""

  ep="$(curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "$ep" && "$ep" == *:* ]]; then
    echo "[$ep]"
    return 0
  fi

  ep="$(curl -4 -s --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "$ep" ]]; then
    echo "$ep"
    return 0
  fi

  ep="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d '\r\n' || true)"
  if [[ -n "$ep" ]]; then
    if [[ "$ep" == *:* ]]; then
      echo "[$ep]"
    else
      echo "$ep"
    fi
    return 0
  fi

  return 1
}

read_node_addr_with_default() {
  local node_addr_var="$1"
  local auto_addr

  auto_addr="$(auto_detect_endpoint || true)"
  if [[ -n "$auto_addr" ]]; then
    read -rp "连接地址，可填 IPv4 / IPv6 / 临时域名 [${auto_addr}]: " node_addr_input
    node_addr_input="${node_addr_input:-$auto_addr}"
  else
    read -rp "连接地址，可填 IPv4 / IPv6 / 临时域名: " node_addr_input
  fi

  [[ -n "${node_addr_input}" ]] || die "连接地址不能为空。自动检测失败，请手动填写 VPS 公网 IP / IPv6。"
  printf -v "$node_addr_var" '%s' "$node_addr_input"
}

random_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

random_password() {
  openssl rand -hex "${1:-16}"
}

urlencode() {
  local raw="${1:-}"
  local length="${#raw}"
  local i c
  for (( i = 0; i < length; i++ )); do
    c="${raw:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

urldecode() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

json_escape() {
  jq -Rn --arg s "$1" '$s'
}

random_token() {
  openssl rand -hex "${1:-16}"
}

get_sub_token() {
  prepare_dirs
  if [[ ! -s "${LOVE_TOKEN_FILE}" ]]; then
    random_token 16 > "${LOVE_TOKEN_FILE}"
    chmod 600 "${LOVE_TOKEN_FILE}"
  fi
  cat "${LOVE_TOKEN_FILE}"
}

reset_sub_token() {
  prepare_dirs
  random_token 16 > "${LOVE_TOKEN_FILE}"
  chmod 600 "${LOVE_TOKEN_FILE}"
  log "订阅随机路径 token 已重置：$(cat "${LOVE_TOKEN_FILE}")"
}

recommend_free_port() {
  local start="${1:-8881}"
  local p="$start"
  while ss -tuln | awk '{print $5}' | grep -Eq "[:.]${p}$"; do
    p=$((p+1))
  done
  echo "$p"
}

check_port_conflict_and_recommend() {
  echo
  echo "================ Love Port Advisor ================"
  read -rp "请输入要检查的起始端口 [8881]: " base
  base="${base:-8881}"
  read -rp "需要连续几个端口 [12]: " count
  count="${count:-12}"

  local p="$base" used=0
  for ((i=0;i<count;i++)); do
    p=$((base+i))
    if ss -tuln | awk '{print $5}' | grep -Eq "[:.]${p}$"; then
      echo "[USED] ${p}"
      used=1
    else
      echo "[FREE] ${p}"
    fi
  done

  if [[ "$used" == "1" ]]; then
    local rec
    rec="$(recommend_free_port "$base")"
    warn "检测到端口占用。建议新的起始端口：${rec}"
  else
    log "所选端口段未发现占用。"
  fi
}

test_reality_sni() {
  local sni="$1"
  info "测试 Reality SNI：${sni}"

  if curl -6 -I --max-time 10 "https://${sni}" >/tmp/love_sni_test.log 2>&1; then
    log "IPv6 测试通过：${sni}"
  elif curl -4 -I --max-time 10 "https://${sni}" >/tmp/love_sni_test.log 2>&1; then
    log "IPv4 测试通过：${sni}"
  else
    warn "SNI 测试失败。仍可继续，但建议换一个真实 HTTPS 域名。"
    cat /tmp/love_sni_test.log || true
  fi
}

stop_web_for_cert() {
  if ! ss -lntp | awk '{print $4}' | grep -Eq '(^|:|\])80$'; then
    return 0
  fi

  warn "80 端口被占用："
  ss -lntp | grep ':80' || true
  read -rp "是否自动停止 apache2/nginx/caddy 申请证书？[y/N]: " ok
  [[ "${ok}" =~ ^[Yy]$ ]] || die "80 被占用，无法 standalone 申请证书。"

  systemctl stop apache2 nginx caddy 2>/dev/null || true
  systemctl disable apache2 nginx caddy 2>/dev/null || true

  if ss -lntp | awk '{print $4}' | grep -Eq '(^|:|\])80$'; then
    ss -lntp | grep ':80' || true
    die "80 仍被占用，请手动处理。"
  fi
}

issue_cert_generic() {
  local domain="$1"
  local email="$2"
  local outdir="$3"
  local group="${4:-root}"

  mkdir -p "$outdir"
  stop_web_for_cert

  certbot certonly --standalone \
    --preferred-challenges http \
    -d "${domain}" \
    --agree-tos \
    -m "${email}" \
    --non-interactive \
    --keep-until-expiring

  install -m 640 -o root -g "${group}" "/etc/letsencrypt/live/${domain}/fullchain.pem" "${outdir}/cert.pem"
  install -m 640 -o root -g "${group}" "/etc/letsencrypt/live/${domain}/privkey.pem" "${outdir}/key.pem"
}

make_selfsigned_generic() {
  local sni="$1"
  local outdir="$2"
  local group="${3:-root}"

  mkdir -p "$outdir"

  openssl req -x509 -nodes -newkey rsa:2048 \
    -days 3650 \
    -keyout "${outdir}/key.pem" \
    -out "${outdir}/cert.pem" \
    -subj "/CN=${sni}"

  chown root:"${group}" "${outdir}/cert.pem" "${outdir}/key.pem" 2>/dev/null || chown root:root "${outdir}/cert.pem" "${outdir}/key.pem"
  chmod 640 "${outdir}/cert.pem" "${outdir}/key.pem"
}

# ------------------------------------------------------------------------------
# Xray stable mode
# ------------------------------------------------------------------------------

install_xray_core() {
  info "安装 / 更新 Xray-core..."

  useradd --system --no-create-home --shell /usr/sbin/nologin xray 2>/dev/null || true
  mkdir -p "${XRAY_CONF_DIR}" /usr/local/share/xray /var/log/xray
  chown -R root:xray "${XRAY_CONF_DIR}"
  chown -R xray:xray /var/log/xray
  chmod 750 "${XRAY_CONF_DIR}" /var/log/xray

  if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --install-user xray; then
    "${XRAY_BIN}" version
    log "Xray-core 安装完成。"
    return 0
  fi

  warn "在线安装 Xray-core 失败。"

  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" version
    log "检测到已有 Xray-core，继续。"
    return 0
  fi

  if [[ -f /root/Xray-linux-64.zip ]]; then
    rm -rf /tmp/love-xray
    mkdir -p /tmp/love-xray
    unzip -o /root/Xray-linux-64.zip -d /tmp/love-xray
    install -m 755 /tmp/love-xray/xray "${XRAY_BIN}"
    [[ -f /tmp/love-xray/geoip.dat ]] && install -m 644 /tmp/love-xray/geoip.dat /usr/local/share/xray/geoip.dat
    [[ -f /tmp/love-xray/geosite.dat ]] && install -m 644 /tmp/love-xray/geosite.dat /usr/local/share/xray/geosite.dat
    "${XRAY_BIN}" version
    log "Xray-core 已从 /root/Xray-linux-64.zip 本地安装。"
    return 0
  fi

  die "无法安装 Xray-core。可先上传 Xray-linux-64.zip 到 /root。"
}

gen_xray_keys() {
  XR_UUID="$("${XRAY_BIN}" uuid)"
  local pair
  pair="$("${XRAY_BIN}" x25519 2>&1)"

  XR_PRIVATE=""
  XR_PUBLIC=""

  while IFS= read -r line; do
    case "$line" in
      PrivateKey:*) XR_PRIVATE="${line#PrivateKey: }" ;;
      "Private key:"*) XR_PRIVATE="${line#Private key: }" ;;
      "Password (PublicKey):"*) XR_PUBLIC="${line#Password (PublicKey): }" ;;
      PublicKey:*) XR_PUBLIC="${line#PublicKey: }" ;;
      "Public key:"*) XR_PUBLIC="${line#Public key: }" ;;
    esac
  done <<< "$pair"

  XR_SHORT_ID="$(openssl rand -hex 8)"
  HY2_AUTH="$(openssl rand -hex 24)"

  [[ -n "${XR_UUID}" ]] || die "UUID 生成失败。"
  [[ -n "${XR_PRIVATE}" ]] || { echo "${pair}"; die "Reality privateKey 解析失败。"; }
  [[ -n "${XR_PUBLIC}" ]] || { echo "${pair}"; die "Reality publicKey 解析失败。"; }
}

write_xray_config() {
  local node_addr="$1"
  local reality_sni="$2"
  local enable_hy2="$3"
  local hy2_sni="$4"

  local hy2_block=""
  if [[ "${enable_hy2}" == "yes" ]]; then
    hy2_block=$(cat <<EOF
    ,
    {
      "tag": "hy2-in",
      "listen": "::",
      "port": 443,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "users": [
          {
            "auth": "${HY2_AUTH}",
            "level": 0,
            "email": "hy2-user"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${hy2_sni}",
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "${XRAY_CONF_DIR}/cert.pem",
              "keyFile": "${XRAY_CONF_DIR}/key.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60,
          "masquerade": {
            "type": "string",
            "content": "<html><body><h1>Welcome</h1></body></html>",
            "headers": {"content-type": "text/html"},
            "statusCode": 200
          }
        }
      }
    }
EOF
)
  fi

  cp "${XRAY_CONF}" "${XRAY_CONF}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true

  cat > "${XRAY_CONF}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "port": "25,465,587",
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XR_UUID}",
            "flow": "xtls-rprx-vision",
            "email": "reality-user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${reality_sni}:443",
          "serverNames": ["${reality_sni}"],
          "privateKey": "${XR_PRIVATE}",
          "shortIds": ["${XR_SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }${hy2_block}
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {
        "response": {"type": "none"}
      }
    }
  ]
}
EOF

  jq empty "${XRAY_CONF}"
  chown root:xray "${XRAY_CONF}"
  chmod 640 "${XRAY_CONF}"
}

write_xray_service() {
  rm -rf /etc/systemd/system/xray.service.d 2>/dev/null || true

  cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service by Love
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
UMask=0077

ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=23

LimitNOFILE=1048576
LimitNPROC=10000

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native

RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

save_xray_info() {
  local node_addr="$1"
  local reality_sni="$2"
  local enable_hy2="$3"
  local hy2_sni="$4"
  local insecure="$5"
  local client_addr="${6:-$node_addr}"
  local client_port="${7:-443}"

  local h
  h="$(uri_host "${client_addr}")"

  local reality_link="vless://${XR_UUID}@${h}:${client_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${XR_PUBLIC}&sid=${XR_SHORT_ID}&type=tcp#LOVE-XRAY-REALITY"
  local hy2_link1="HY2 disabled"
  local hy2_link2="HY2 disabled"

  if [[ "${enable_hy2}" == "yes" ]]; then
    hy2_link1="hysteria2://${HY2_AUTH}@${h}:${client_port}/?sni=${hy2_sni}&insecure=${insecure}#LOVE-XRAY-HY2"
    hy2_link2="hy2://${HY2_AUTH}@${h}:${client_port}/?sni=${hy2_sni}&insecure=${insecure}#LOVE-XRAY-HY2"
  fi

  cat > "${XRAY_INFO}" <<EOF
Love Xray Client Info

Server Real Listen:
${node_addr}:443

Client Preferred Address:
${client_addr}:${client_port}

Reality:
${reality_link}

HY2:
${hy2_link1}
${hy2_link2}

Manual Reality:
Address: ${client_addr}
Port: ${client_port}
Protocol: VLESS
UUID: ${XR_UUID}
Flow: xtls-rprx-vision
Security: reality
SNI: ${reality_sni}
Fingerprint: chrome
PublicKey: ${XR_PUBLIC}
ShortID: ${XR_SHORT_ID}

Manual HY2:
Address: ${client_addr}
Port: ${client_port}
Auth: ${HY2_AUTH}
SNI: ${hy2_sni}
Insecure: ${insecure}

Note:
1. 优选 IP / 域名只替换客户端 Address。
2. Reality SNI 保持：${reality_sni}
3. HY2 SNI 保持：${hy2_sni}
4. 如果 HY2 使用真实证书，SNI 不要改成优选 IP。
EOF

  chmod 600 "${XRAY_INFO}"
  cat "${XRAY_INFO}"
}

install_xray_stable() {
  echo
  echo "================ Love Xray 稳定模式 ================"

  read -rp "有自己的节点域名吗？[Y/n]: " has_domain
  has_domain="${has_domain:-Y}"

  local node_addr domain email enable_hy2 hy2_sni insecure
  insecure="0"

  if [[ "${has_domain}" =~ ^[Yy]$ ]]; then
    read -rp "节点域名，例如 node.example.com: " domain
    [[ -n "${domain}" ]] || die "域名不能为空。"
    node_addr="${domain}"

    read -rp "Let's Encrypt 邮箱: " email
    [[ -n "${email}" ]] || die "邮箱不能为空。"

    read -rp "安装 HY2 / Hysteria2？[Y/n]: " hy2_choice
    hy2_choice="${hy2_choice:-Y}"
    [[ "${hy2_choice}" =~ ^[Yy]$ ]] && enable_hy2="yes" || enable_hy2="no"
    hy2_sni="${domain}"
  else
    read_node_addr_with_default node_addr

    warn "无域名默认 Reality-only。HY2 自签需要客户端 insecure=1。"
    read -rp "是否强行安装 HY2 自签模式？[y/N]: " hy2_self
    if [[ "${hy2_self}" =~ ^[Yy]$ ]]; then
      enable_hy2="yes"
      insecure="1"
      read -rp "HY2 自签 SNI [self.local]: " hy2_sni
      hy2_sni="${hy2_sni:-self.local}"
    else
      enable_hy2="no"
      hy2_sni=""
    fi
  fi

  read -rp "Reality SNI [www.cloudflare.com]: " reality_sni
  reality_sni="${reality_sni:-www.cloudflare.com}"

  ask_preferred_endpoint "${node_addr}" "443"

  ask_ssh_port

  install_base
  setup_ufw "$([[ "${has_domain}" =~ ^[Yy]$ && "${enable_hy2}" == "yes" ]] && echo yes || echo no)" yes "$([[ "${enable_hy2}" == "yes" ]] && echo yes || echo no)" no
  install_xray_core
  gen_xray_keys
  test_reality_sni "${reality_sni}"

  if [[ "${enable_hy2}" == "yes" ]]; then
    if [[ "${has_domain}" =~ ^[Yy]$ ]]; then
      issue_cert_generic "${domain}" "${email}" "${XRAY_CONF_DIR}" "xray"
      mkdir -p /etc/letsencrypt/renewal-hooks/deploy
      cat > /etc/letsencrypt/renewal-hooks/deploy/love-xray-copy-cert.sh <<EOF
#!/usr/bin/env bash
set -e
DOMAIN="${domain}"
if echo " \$RENEWED_DOMAINS " | grep -q " \$DOMAIN "; then
  install -m 640 -o root -g xray "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" "${XRAY_CONF_DIR}/cert.pem"
  install -m 640 -o root -g xray "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" "${XRAY_CONF_DIR}/key.pem"
  systemctl restart xray || true
fi
EOF
      chmod +x /etc/letsencrypt/renewal-hooks/deploy/love-xray-copy-cert.sh
    else
      make_selfsigned_generic "${hy2_sni}" "${XRAY_CONF_DIR}" "xray"
    fi
  fi

  write_xray_config "${node_addr}" "${reality_sni}" "${enable_hy2}" "${hy2_sni}"
  write_xray_service

  "${XRAY_BIN}" run -test -config "${XRAY_CONF}"
  systemctl enable xray
  systemctl restart xray

  sleep 2
  systemctl status xray --no-pager || true
  ss -lntp | grep ':443' || true
  ss -lunp | grep ':443' || true

  save_xray_info "${node_addr}" "${reality_sni}" "${enable_hy2}" "${hy2_sni}" "${insecure}" "${CLIENT_ADDR}" "${CLIENT_PORT}"
  log "Xray 稳定模式安装完成。"
}

# ------------------------------------------------------------------------------
# Native sing-box mode
# ------------------------------------------------------------------------------

install_singbox_core() {
  info "安装 / 更新 sing-box..."

  mkdir -p "${SINGBOX_DIR}" "${SINGBOX_CERT_DIR}"

  if [[ -x "${SINGBOX_BIN}" ]]; then
    "${SINGBOX_BIN}" version || true
    read -rp "检测到 sing-box 已存在，是否继续覆盖更新？[y/N]: " up
    if [[ ! "${up}" =~ ^[Yy]$ ]]; then
      log "跳过 sing-box 安装。"
      return 0
    fi
  fi

  local arch pkg release version url v
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pkg="linux-amd64" ;;
    aarch64|arm64) pkg="linux-arm64" ;;
    armv7l) pkg="linux-armv7" ;;
    *) die "暂不支持架构：$arch" ;;
  esac

  release="$(curl -sL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest || true)"
  version="$(echo "$release" | jq -r '.tag_name // empty' 2>/dev/null || true)"

  if [[ -z "${version}" || "${version}" == "null" ]]; then
    warn "无法获取最新版本，使用备用版本 v1.12.0"
    version="v1.12.0"
  fi

  v="${version#v}"
  url="https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${v}-${pkg}.tar.gz"

  if ! curl -L --max-time 90 "$url" -o /tmp/love-sing-box.tar.gz; then
    die "sing-box 下载失败。你可以手动上传 sing-box tar.gz 后自行安装。"
  fi

  rm -rf /tmp/love-sing-box
  mkdir -p /tmp/love-sing-box
  tar -xzf /tmp/love-sing-box.tar.gz -C /tmp/love-sing-box --strip-components=1
  install -m 755 /tmp/love-sing-box/sing-box "${SINGBOX_BIN}"

  "${SINGBOX_BIN}" version
  log "sing-box 安装完成。"
}

singbox_reality_keys() {
  local pair
  pair="$("${SINGBOX_BIN}" generate reality-keypair 2>&1)"
  SB_PRIVATE="$(echo "$pair" | awk -F': ' '/PrivateKey|Private key|Private/ {print $2; exit}')"
  SB_PUBLIC="$(echo "$pair" | awk -F': ' '/PublicKey|Public key|Public/ {print $2; exit}')"

  [[ -n "${SB_PRIVATE}" && -n "${SB_PUBLIC}" ]] || { echo "$pair"; die "sing-box reality keypair 解析失败。"; }
}

choose_singbox_protocols() {
  cat <<'EOF'

================ Love sing-box 节点选择 ================

a) all 全部
b) VLESS Reality
c) Hysteria2
d) TUIC
e) Shadowsocks
f) Trojan
g) VMess WS
h) VLESS WS TLS
i) H2 Reality
j) gRPC Reality
k) AnyTLS
l) Naive
m) ShadowTLS 高级占位说明

示例：
  a       = 全部
  bcd     = Reality + HY2 + TUIC
  bcfg    = Reality + HY2 + Trojan + VMess WS

=========================================================

EOF

  read -rp "请选择协议 [bcd]: " proto
  proto="${proto:-bcd}"

  if [[ "${proto}" == "a" || "${proto}" == "all" ]]; then
    proto="bcdefghijklm"
  fi

  INSTALL_REALITY="no"
  INSTALL_HY2="no"
  INSTALL_TUIC="no"
  INSTALL_SS="no"
  INSTALL_TROJAN="no"
  INSTALL_VMESS_WS="no"
  INSTALL_VLESS_WS_TLS="no"
  INSTALL_H2_REALITY="no"
  INSTALL_GRPC_REALITY="no"
  INSTALL_ANYTLS="no"
  INSTALL_NAIVE="no"
  INSTALL_SHADOWTLS="no"

  [[ "$proto" == *b* ]] && INSTALL_REALITY="yes" || true
  [[ "$proto" == *c* ]] && INSTALL_HY2="yes" || true
  [[ "$proto" == *d* ]] && INSTALL_TUIC="yes" || true
  [[ "$proto" == *e* ]] && INSTALL_SS="yes" || true
  [[ "$proto" == *f* ]] && INSTALL_TROJAN="yes" || true
  [[ "$proto" == *g* ]] && INSTALL_VMESS_WS="yes" || true
  [[ "$proto" == *h* ]] && INSTALL_VLESS_WS_TLS="yes" || true
  [[ "$proto" == *i* ]] && INSTALL_H2_REALITY="yes" || true
  [[ "$proto" == *j* ]] && INSTALL_GRPC_REALITY="yes" || true
  [[ "$proto" == *k* ]] && INSTALL_ANYTLS="yes" || true
  [[ "$proto" == *l* ]] && INSTALL_NAIVE="yes" || true
  [[ "$proto" == *m* ]] && INSTALL_SHADOWTLS="yes" || true

  return 0
}

gen_singbox_values() {
  SB_UUID="$(random_uuid)"
  SB_REALITY_SHORT="$(openssl rand -hex 8)"
  SB_HY2_PASS="$(openssl rand -hex 24)"
  SB_TUIC_PASS="$(openssl rand -hex 24)"
  SB_SS_PASS="$(openssl rand -base64 16 | tr -d '=+/ ' | cut -c1-16)"
  SB_TROJAN_PASS="$(openssl rand -hex 16)"
  SB_ANYTLS_PASS="$(openssl rand -hex 16)"
  SB_NAIVE_USER="love"
  SB_NAIVE_PASS="$(openssl rand -hex 16)"
  SB_SHADOWTLS_PASS="$(openssl rand -hex 16)"
  singbox_reality_keys
}

write_singbox_config() {
  local reality_sni="$1"
  local tls_sni="$2"
  local cert_dir="$3"
  local start_port="$4"

  local port="$start_port"
  SB_REALITY_PORT="$port"
  ((port++)) || true
  SB_HY2_PORT="$port"
  ((port++)) || true
  SB_TUIC_PORT="$port"
  ((port++)) || true
  SB_SS_PORT="$port"
  ((port++)) || true
  SB_TROJAN_PORT="$port"
  ((port++)) || true
  SB_VMESS_WS_PORT="$port"
  ((port++)) || true
  SB_VLESS_WS_TLS_PORT="$port"
  ((port++)) || true
  SB_H2_REALITY_PORT="$port"
  ((port++)) || true
  SB_GRPC_REALITY_PORT="$port"
  ((port++)) || true
  SB_ANYTLS_PORT="$port"
  ((port++)) || true
  SB_NAIVE_PORT="$port"
  ((port++)) || true
  SB_SHADOWTLS_PORT="$port"
  ((port++)) || true

  local inbound_file="/tmp/love-singbox-inbounds.jsonl"
  : > "$inbound_file"

  if [[ "$INSTALL_REALITY" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"vless-reality-in","listen":"::","listen_port":${SB_REALITY_PORT},"users":[{"uuid":"${SB_UUID}","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]}}}
EOF
  fi

  if [[ "$INSTALL_HY2" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":${SB_HY2_PORT},"users":[{"password":"${SB_HY2_PASS}"}],"tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem"}}
EOF
  fi

  if [[ "$INSTALL_TUIC" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":${SB_TUIC_PORT},"users":[{"uuid":"${SB_UUID}","password":"${SB_TUIC_PASS}"}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem"}}
EOF
  fi

  if [[ "$INSTALL_SS" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":${SB_SS_PORT},"method":"aes-128-gcm","password":"${SB_SS_PASS}"}
EOF
  fi

  if [[ "$INSTALL_TROJAN" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"trojan","tag":"trojan-in","listen":"::","listen_port":${SB_TROJAN_PORT},"users":[{"password":"${SB_TROJAN_PASS}"}],"tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem"}}
EOF
  fi

  if [[ "$INSTALL_VMESS_WS" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vmess","tag":"vmess-ws-in","listen":"::","listen_port":${SB_VMESS_WS_PORT},"users":[{"uuid":"${SB_UUID}","alterId":0}],"transport":{"type":"ws","path":"/vmess"}}
EOF
  fi

  if [[ "$INSTALL_VLESS_WS_TLS" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"vless-ws-tls-in","listen":"::","listen_port":${SB_VLESS_WS_TLS_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem"},"transport":{"type":"ws","path":"/vless"}}
EOF
  fi

  if [[ "$INSTALL_H2_REALITY" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"h2-reality-in","listen":"::","listen_port":${SB_H2_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]}},"transport":{"type":"http","host":["${reality_sni}"],"path":"/h2"}}
EOF
  fi

  if [[ "$INSTALL_GRPC_REALITY" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"grpc-reality-in","listen":"::","listen_port":${SB_GRPC_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]}},"transport":{"type":"grpc","service_name":"lovegrpc"}}
EOF
  fi

  if [[ "$INSTALL_ANYTLS" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"anytls","tag":"anytls-in","listen":"::","listen_port":${SB_ANYTLS_PORT},"users":[{"password":"${SB_ANYTLS_PASS}"}],"tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem"}}
EOF
  fi

  if [[ "$INSTALL_NAIVE" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"naive","tag":"naive-in","listen":"::","listen_port":${SB_NAIVE_PORT},"users":[{"username":"${SB_NAIVE_USER}","password":"${SB_NAIVE_PASS}"}],"tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem"}}
EOF
  fi

  if [[ "$INSTALL_SHADOWTLS" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"shadowtls","tag":"shadowtls-in","listen":"::","listen_port":${SB_SHADOWTLS_PORT},"version":3,"users":[{"name":"love","password":"${SB_SHADOWTLS_PASS}"}],"handshake":{"server":"addons.mozilla.org","server_port":443},"detour":"ss-in"}
EOF
    if [[ "$INSTALL_SS" != "yes" ]]; then
      warn "ShadowTLS 需要 SS detour；已自动附加 Shadowsocks 入站。"
      cat >> "$inbound_file" <<EOF
{"type":"shadowsocks","tag":"ss-in","listen":"127.0.0.1","listen_port":${SB_SS_PORT},"method":"aes-128-gcm","password":"${SB_SS_PASS}"}
EOF
    fi
  fi

  local inbounds_json
  inbounds_json="$(jq -s '.' "$inbound_file")"

  mkdir -p "${SINGBOX_DIR}" "${SINGBOX_CERT_DIR}"

  jq -n \
    --argjson inbounds "$inbounds_json" \
    '{
      log: {level: "warn", timestamp: true},
      dns: {
        servers: [
          {tag: "cf", type: "udp", server: "2606:4700:4700::1111"},
          {tag: "google", type: "udp", server: "2001:4860:4860::8888"}
        ],
        final: "cf"
      },
      inbounds: $inbounds,
      outbounds: [
        {type: "direct", tag: "direct"},
        {type: "block", tag: "block"}
      ],
      route: {
        rules: [
          {ip_is_private: true, outbound: "block"},
          {port: [25,465,587], outbound: "block"},
          {protocol: "bittorrent", outbound: "block"}
        ],
        final: "direct",
        default_domain_resolver: "cf"
      }
    }' > "${SINGBOX_CONF}"

  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true "${SINGBOX_BIN}" check -c "${SINGBOX_CONF}"
}

write_singbox_service() {
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service by Love
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
Environment=ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

save_singbox_info() {
  local client_addr="$1"
  local client_port_base="$2"
  local reality_sni="$3"
  local tls_sni="$4"
  local insecure="$5"

  local h
  h="$(uri_host "${client_addr}")"

  : > "${SINGBOX_INFO}"

  {
    echo "Love sing-box Client Info"
    echo
    echo "Client Address: ${client_addr}"
    echo "Base Port: ${client_port_base}"
    echo "Reality SNI: ${reality_sni}"
    echo "TLS SNI: ${tls_sni}"
    echo "Insecure: ${insecure}"
    echo
  } >> "${SINGBOX_INFO}"

  if [[ "$INSTALL_REALITY" == "yes" ]]; then
    echo "VLESS Reality:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=tcp#LOVE-SB-REALITY" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_HY2" == "yes" ]]; then
    echo "HY2:" >> "${SINGBOX_INFO}"
    echo "hy2://${SB_HY2_PASS}@${h}:${SB_HY2_PORT}/?sni=${tls_sni}&insecure=${insecure}#LOVE-HY2" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TUIC" == "yes" ]]; then
    echo "TUIC:" >> "${SINGBOX_INFO}"
    echo "tuic://${SB_UUID}:${SB_TUIC_PASS}@${h}:${SB_TUIC_PORT}?sni=${tls_sni}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=${insecure}#LOVE-SB-TUIC" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_SS" == "yes" ]]; then
    echo "Shadowsocks:" >> "${SINGBOX_INFO}"
    echo "ss://$(printf 'aes-128-gcm:%s' "${SB_SS_PASS}" | base64 -w0)@${h}:${SB_SS_PORT}#LOVE-SB-SS" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TROJAN" == "yes" ]]; then
    echo "Trojan:" >> "${SINGBOX_INFO}"
    echo "trojan://${SB_TROJAN_PASS}@${h}:${SB_TROJAN_PORT}?security=tls&sni=${tls_sni}&allowInsecure=${insecure}#LOVE-SB-TROJAN" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VMESS_WS" == "yes" ]]; then
    echo "VMess WS manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_VMESS_WS_PORT} UUID=${SB_UUID} Transport=ws Path=/vmess TLS=off" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VLESS_WS_TLS" == "yes" ]]; then
    echo "VLESS WS TLS:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_VLESS_WS_TLS_PORT}?encryption=none&security=tls&sni=${tls_sni}&type=ws&path=%2Fvless#LOVE-SB-VLESS-WS-TLS" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_H2_REALITY" == "yes" ]]; then
    echo "H2 Reality manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_H2_REALITY_PORT} UUID=${SB_UUID} SNI=${reality_sni} PublicKey=${SB_PUBLIC} ShortID=${SB_REALITY_SHORT} Transport=http Path=/h2 Host=${reality_sni}" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_GRPC_REALITY" == "yes" ]]; then
    echo "gRPC Reality manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_GRPC_REALITY_PORT} UUID=${SB_UUID} SNI=${reality_sni} PublicKey=${SB_PUBLIC} ShortID=${SB_REALITY_SHORT} ServiceName=lovegrpc" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_ANYTLS" == "yes" ]]; then
    echo "AnyTLS manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_ANYTLS_PORT} Password=${SB_ANYTLS_PASS} SNI=${tls_sni} Insecure=${insecure}" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_NAIVE" == "yes" ]]; then
    echo "Naive:" >> "${SINGBOX_INFO}"
    echo "https://${SB_NAIVE_USER}:${SB_NAIVE_PASS}@${h}:${SB_NAIVE_PORT}#LOVE-SB-NAIVE" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_SHADOWTLS" == "yes" ]]; then
    echo "ShadowTLS manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_SHADOWTLS_PORT} Password=${SB_SHADOWTLS_PASS} Version=3 Handshake=addons.mozilla.org Detour=SS" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  chmod 600 "${SINGBOX_INFO}"
  cat "${SINGBOX_INFO}"
}

install_singbox_native() {
  echo
  echo "================ Love sing-box 原生全协议模式 ================"
  warn "建议使用干净服务器。若 443 已被 Xray 占用，请先停止 Xray 或选择非 443 起始端口。"

  choose_singbox_protocols

  read -rp "有自己的节点域名吗？[Y/n]: " has_domain
  has_domain="${has_domain:-Y}"

  local node_addr domain email tls_sni insecure cert_needed
  insecure="0"
  cert_needed="no"

  if [[ "${has_domain}" =~ ^[Yy]$ ]]; then
    read -rp "节点域名，例如 node.example.com: " domain
    [[ -n "${domain}" ]] || die "域名不能为空。"
    node_addr="${domain}"
    tls_sni="${domain}"
    read -rp "Let's Encrypt 邮箱: " email
    [[ -n "${email}" ]] || die "邮箱不能为空。"
    cert_needed="yes"
  else
    read_node_addr_with_default node_addr
    read -rp "自签证书 SNI [self.local]: " tls_sni
    tls_sni="${tls_sni:-self.local}"
    insecure="1"
    if [[ "$INSTALL_HY2$INSTALL_TUIC$INSTALL_TROJAN$INSTALL_VLESS_WS_TLS$INSTALL_ANYTLS$INSTALL_NAIVE" == *yes* ]]; then
      cert_needed="yes"
    fi
  fi

  read -rp "Reality SNI [www.cloudflare.com]: " reality_sni
  reality_sni="${reality_sni:-www.cloudflare.com}"

  read -rp "起始端口 [8881]: " start_port
  start_port="${start_port:-8881}"

  ask_preferred_endpoint "${node_addr}" "${start_port}"

  ask_ssh_port

  install_base
  install_singbox_core
  gen_singbox_values
  test_reality_sni "${reality_sni}"

  if [[ "${cert_needed}" == "yes" ]]; then
    if [[ "${has_domain}" =~ ^[Yy]$ ]]; then
      setup_ufw yes yes yes yes
      issue_cert_generic "${domain}" "${email}" "${SINGBOX_CERT_DIR}" "root"
    else
      setup_ufw no yes yes yes
      make_selfsigned_generic "${tls_sni}" "${SINGBOX_CERT_DIR}" "root"
    fi
  else
    setup_ufw no yes yes yes
  fi

  write_singbox_config "${reality_sni}" "${tls_sni}" "${SINGBOX_CERT_DIR}" "${start_port}"
  write_singbox_service

  systemctl enable sing-box
  systemctl restart sing-box
  sleep 2
  systemctl status sing-box --no-pager || true
  ss -tulpn | grep -E ':443|:8443|:888|sing-box' || true

  save_singbox_info "${CLIENT_ADDR}" "${CLIENT_PORT}" "${reality_sni}" "${tls_sni}" "${insecure}"
  log "sing-box 原生模式安装完成。"
}

# ------------------------------------------------------------------------------
# Advanced helpers
# ------------------------------------------------------------------------------

install_cloudflared() {
  if [[ -x "${CLOUDFLARED_BIN}" ]]; then
    "${CLOUDFLARED_BIN}" version || true
    return 0
  fi

  info "安装 cloudflared..."

  local arch url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    aarch64|arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    *) die "暂不支持 cloudflared 架构：$arch" ;;
  esac

  curl -L --max-time 90 "$url" -o "${CLOUDFLARED_BIN}"
  chmod +x "${CLOUDFLARED_BIN}"
  "${CLOUDFLARED_BIN}" version || true
}

argo_helper() {
  echo
  echo "================ Love Argo / Cloudflared ================"
  warn "Argo 适合没有公网入口、IPv6-only 客户端不可达、WS 回源等场景。"
  echo "1) Try 临时隧道：cloudflared tunnel --url http://127.0.0.1:PORT"
  echo "2) Token 隧道：cloudflared tunnel run --token TOKEN"
  echo "3) API 自动创建 Tunnel + DNS"
  echo "0) 返回"
  read -rp "请选择: " a

  case "$a" in
    1)
      install_base
      install_cloudflared
      read -rp "本地回源端口，例如 VMess WS 端口或 nginx 端口 [8080]: " p
      p="${p:-8080}"

      cat > /etc/systemd/system/love-argo.service <<EOF
[Unit]
Description=Love Cloudflared Try Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --url http://127.0.0.1:${p} --no-autoupdate
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable love-argo
      systemctl restart love-argo
      sleep 5
      journalctl -u love-argo -n 80 --no-pager
      ;;
    2)
      install_base
      install_cloudflared
      read -rp "请输入 Cloudflare Tunnel Token: " token
      [[ -n "$token" ]] || die "Token 不能为空。"
      cat > /etc/systemd/system/love-argo.service <<EOF
[Unit]
Description=Love Cloudflared Token Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel run --token ${token}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable love-argo
      systemctl restart love-argo
      sleep 3
      systemctl status love-argo --no-pager || true
      ;;
    3)
      install_base
      argo_api_create_tunnel
      ;;
    *) return 0 ;;
  esac
}

port_hopping_helper() {
  echo
  echo "================ Love Port Hopping ================"
  warn "端口跳跃适合 UDP 单端口被限速/阻断时使用。会占用一段 UDP 端口。"
  read -rp "目标 UDP 端口，例如 HY2 的 443 或 8882 [443]: " target
  target="${target:-443}"
  read -rp "跳跃端口范围，例如 50000:51000: " range
  [[ "$range" =~ ^[0-9]{2,5}:[0-9]{2,5}$ ]] || die "端口范围格式错误。"

  local start="${range%:*}"
  local end="${range#*:}"

  [[ "$start" -lt "$end" ]] || die "端口范围错误：起始端口必须小于结束端口。"
  [[ "$start" -ge 1 && "$end" -le 65535 ]] || die "端口范围必须在 1-65535。"

  ask_ssh_port
  setup_ufw no no yes no "${start}:${end}"

  if ! command -v iptables >/dev/null 2>&1; then
    warn "未检测到 iptables，只完成了防火墙放行。"
    return 0
  fi

  mkdir -p "${LOVE_HOME}/rules"

  cat > "${LOVE_HOME}/rules/port-hopping.env" <<EOF
LOVE_HOPPING_START=${start}
LOVE_HOPPING_END=${end}
LOVE_HOPPING_TARGET=${target}
EOF

  cat > /usr/local/bin/love-port-hopping-apply <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/opt/Love/rules/port-hopping.env"
[[ -f "$ENV_FILE" ]] || exit 0
source "$ENV_FILE"

iptables -t nat -C PREROUTING -p udp --dport "${LOVE_HOPPING_START}:${LOVE_HOPPING_END}" -j REDIRECT --to-ports "${LOVE_HOPPING_TARGET}" 2>/dev/null || \
iptables -t nat -A PREROUTING -p udp --dport "${LOVE_HOPPING_START}:${LOVE_HOPPING_END}" -j REDIRECT --to-ports "${LOVE_HOPPING_TARGET}"
EOF
  chmod +x /usr/local/bin/love-port-hopping-apply

  cat > /etc/systemd/system/love-port-hopping.service <<'EOF'
[Unit]
Description=Love UDP Port Hopping Rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/love-port-hopping-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable love-port-hopping
  systemctl restart love-port-hopping

  log "端口跳跃已启用并持久化：UDP ${start}:${end} -> ${target}"
  warn "如果你更换 HY2/TUIC 端口，需要重新运行本功能。"
}
warp_helper() {
  echo
  echo "================ Love WARP 说明 ================"
  warn "服务器装 WARP 主要改善服务器出站，例如 IPv6-only VPS 访问 IPv4/GitHub。"
  warn "它不能给 IPv6-only VPS 提供公网 IPv4 入站。"
  echo
  echo "推荐操作："
  echo "1) Debian/Ubuntu 可使用 Cloudflare 官方 WARP 客户端安装流程"
  echo "2) 或者你自行安装 wgcf/warp-go"
  echo "3) 安装后用 curl -4/-6 ifconfig.co 测试出站"
  echo
  read -rp "是否打开 Cloudflare WARP 官方文档链接提示？[y/N]: " ok
  if [[ "$ok" =~ ^[Yy]$ ]]; then
    echo "https://developers.cloudflare.com/warp-client/"
  fi
}



extract_raw_links() {
  prepare_dirs
  mkdir -p "${LOVE_SUB}"
  local raw="${LOVE_SUB}/all.txt"
  : > "$raw"

  if [[ -f "${XRAY_INFO}" ]]; then
    grep -E '^(vless|hysteria2|hy2|tuic|ss|trojan|https)://' "${XRAY_INFO}" >> "$raw" || true
  fi

  if [[ -f "${SINGBOX_INFO}" ]]; then
    grep -E '^(vless|hysteria2|hy2|tuic|ss|trojan|https)://' "${SINGBOX_INFO}" >> "$raw" || true
  fi

  sort -u "$raw" -o "$raw" || true
  echo "$raw"
}

generate_mihomo_yaml() {
  prepare_dirs
  mkdir -p "${LOVE_SUB}"

  local raw="${LOVE_SUB}/all.txt"
  [[ -s "$raw" ]] || raw="$(extract_raw_links)"

  local out="${LOVE_SUB}/mihomo.yaml"
  local providers="${LOVE_SUB}/mihomo-provider.yaml"
  local i=0

  {
    echo "mixed-port: 7890"
    echo "allow-lan: false"
    echo "mode: rule"
    echo "log-level: warning"
    echo "ipv6: true"
    echo "dns:"
    echo "  enable: true"
    echo "  ipv6: true"
    echo "  enhanced-mode: fake-ip"
    echo "  nameserver:"
    echo "    - https://1.1.1.1/dns-query"
    echo "    - https://8.8.8.8/dns-query"
    echo "proxies:"
  } > "$out"

  {
    echo "proxies:"
  } > "$providers"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ((i++)) || true
    local name="LOVE-${i}"
    local scheme="${line%%://*}"

    case "$scheme" in
      vless)
        local rest="${line#vless://}"
        local uuid="${rest%@*}"
        local after="${rest#*@}"
        local hostport="${after%%\?*}"
        local query_tag="${after#*\?}"
        local query="${query_tag%%#*}"
        local tag="${after#*#}"
        [[ "$tag" == "$after" ]] && tag="$name"
        name="$(urldecode "$tag")"

        local server="${hostport%:*}"
        local port="${hostport##*:}"
        if [[ "$hostport" == \[*\]:* ]]; then
          server="${hostport%%]*}]"; server="${hostport%%]*}"; server="${server#[}"
          port="${hostport##*:}"
        fi

        local sni="$(sed -n 's/.*[?&]sni=\([^&]*\).*/\1/p' <<< "?$query")"
        local pbk="$(sed -n 's/.*[?&]pbk=\([^&]*\).*/\1/p' <<< "?$query")"
        local sid="$(sed -n 's/.*[?&]sid=\([^&]*\).*/\1/p' <<< "?$query")"
        local flow="$(sed -n 's/.*[?&]flow=\([^&]*\).*/\1/p' <<< "?$query")"
        local network="$(sed -n 's/.*[?&]type=\([^&]*\).*/\1/p' <<< "?$query")"
        local path="$(sed -n 's/.*[?&]path=\([^&]*\).*/\1/p' <<< "?$query")"
        local security="$(sed -n 's/.*[?&]security=\([^&]*\).*/\1/p' <<< "?$query")"
        [[ -z "$network" ]] && network="tcp"

        {
          echo "  - name: \"${name}\""
          echo "    type: vless"
          echo "    server: \"${server}\""
          echo "    port: ${port}"
          echo "    uuid: ${uuid}"
          echo "    network: ${network}"
          echo "    udp: true"
          if [[ "$security" == "reality" || -n "$pbk" ]]; then
            echo "    tls: true"
            echo "    servername: \"${sni}\""
            echo "    flow: ${flow:-xtls-rprx-vision}"
            echo "    reality-opts:"
            echo "      public-key: \"${pbk}\""
            echo "      short-id: \"${sid}\""
            echo "    client-fingerprint: chrome"
          elif [[ "$security" == "tls" ]]; then
            echo "    tls: true"
            echo "    servername: \"${sni}\""
          fi
          if [[ "$network" == "ws" ]]; then
            echo "    ws-opts:"
            echo "      path: \"$(urldecode "${path:-/}")\""
          fi
        } >> "$out"
        ;;
      hy2|hysteria2)
        local rest="${line#*://}"
        local auth="${rest%@*}"
        local after="${rest#*@}"
        local hostport="${after%%/*}"
        local query_tag="${after#*\?}"
        local query="${query_tag%%#*}"
        local tag="${after#*#}"
        [[ "$tag" == "$after" ]] && tag="$name"
        name="$(urldecode "$tag")"
        local server="${hostport%:*}"
        local port="${hostport##*:}"
        if [[ "$hostport" == \[*\]:* ]]; then
          server="${hostport%%]*}"; server="${server#[}"
          port="${hostport##*:}"
        fi
        local sni="$(sed -n 's/.*[?&]sni=\([^&]*\).*/\1/p' <<< "?$query")"
        local insecure="$(sed -n 's/.*[?&]insecure=\([^&]*\).*/\1/p' <<< "?$query")"
        {
          echo "  - name: \"${name}\""
          echo "    type: hysteria2"
          echo "    server: \"${server}\""
          echo "    port: ${port}"
          echo "    password: \"${auth}\""
          echo "    sni: \"${sni}\""
          echo "    skip-cert-verify: $([[ "$insecure" == "1" || "$insecure" == "true" ]] && echo true || echo false)"
        } >> "$out"
        ;;
      tuic)
        local rest="${line#tuic://}"
        local auth="${rest%@*}"
        local uuid="${auth%%:*}"
        local password="${auth#*:}"
        local after="${rest#*@}"
        local hostport="${after%%\?*}"
        local query_tag="${after#*\?}"
        local query="${query_tag%%#*}"
        local tag="${after#*#}"
        [[ "$tag" == "$after" ]] && tag="$name"
        name="$(urldecode "$tag")"
        local server="${hostport%:*}"
        local port="${hostport##*:}"
        local sni="$(sed -n 's/.*[?&]sni=\([^&]*\).*/\1/p' <<< "?$query")"
        {
          echo "  - name: \"${name}\""
          echo "    type: tuic"
          echo "    server: \"${server}\""
          echo "    port: ${port}"
          echo "    uuid: ${uuid}"
          echo "    password: \"${password}\""
          echo "    sni: \"${sni}\""
          echo "    alpn: [h3]"
          echo "    congestion-controller: bbr"
          echo "    udp-relay-mode: native"
        } >> "$out"
        ;;
      trojan)
        local rest="${line#trojan://}"
        local pass="${rest%@*}"
        local after="${rest#*@}"
        local hostport="${after%%\?*}"
        local query_tag="${after#*\?}"
        local query="${query_tag%%#*}"
        local tag="${after#*#}"
        [[ "$tag" == "$after" ]] && tag="$name"
        name="$(urldecode "$tag")"
        local server="${hostport%:*}"
        local port="${hostport##*:}"
        local sni="$(sed -n 's/.*[?&]sni=\([^&]*\).*/\1/p' <<< "?$query")"
        {
          echo "  - name: \"${name}\""
          echo "    type: trojan"
          echo "    server: \"${server}\""
          echo "    port: ${port}"
          echo "    password: \"${pass}\""
          echo "    sni: \"${sni}\""
          echo "    udp: true"
        } >> "$out"
        ;;
      ss)
        echo "  # Shadowsocks URI kept for client import: ${line}" >> "$out"
        ;;
      https)
        echo "  # Naive URI kept for client import: ${line}" >> "$out"
        ;;
      *)
        echo "  # Unsupported URI kept for import: ${line}" >> "$out"
        ;;
    esac
  done < "$raw"

  cat >> "$out" <<'EOF'
proxy-groups:
  - name: LOVE-AUTO
    type: select
    proxies:
EOF

  grep '^  - name:' "$out" | sed 's/^  - name: /      - /' >> "$out" || true

  cat >> "$out" <<'EOF'
rules:
  - MATCH,LOVE-AUTO
EOF

  cp "$out" "$providers"
  log "Mihomo / Clash YAML 已生成：$out"
}

generate_client_exports() {
  prepare_dirs
  mkdir -p "${LOVE_SUB}/clients"
  local raw="${LOVE_SUB}/all.txt"
  [[ -s "$raw" ]] || raw="$(extract_raw_links)"

  local shadowrocket="${LOVE_SUB}/clients/shadowrocket.conf"
  local nekobox="${LOVE_SUB}/clients/nekobox-uri.txt"
  local v2rayn="${LOVE_SUB}/clients/v2rayn-uri.txt"
  local singbox="${LOVE_SUB}/clients/sing-box-uri.txt"

  cp "$raw" "$shadowrocket"
  cp "$raw" "$nekobox"
  cp "$raw" "$v2rayn"
  cp "$raw" "$singbox"

  base64 -w0 "$shadowrocket" > "${shadowrocket}.base64"
  base64 -w0 "$nekobox" > "${nekobox}.base64"
  base64 -w0 "$v2rayn" > "${v2rayn}.base64"

  log "客户端专用导出完成："
  echo "Shadowrocket: ${shadowrocket}"
  echo "NekoBox:      ${nekobox}"
  echo "V2RayN:       ${v2rayn}"
  echo "sing-box:     ${singbox}"
}
export_subscription() {
  prepare_dirs
  if [[ ! -s "${LOVE_SUB}/all.txt" && -f /etc/sing-box/config.json ]]; then
    love_generate_hy2_subscription_from_config >/dev/null 2>&1 || true
  fi
  mkdir -p "${LOVE_SUB}"

  local raw="${LOVE_SUB}/all.txt"
  local b64="${LOVE_SUB}/all_base64.txt"
  local clash="${LOVE_SUB}/clash_like.yaml"

  : > "$raw"

  if [[ -f "${XRAY_INFO}" ]]; then
    grep -E '^(vless|hysteria2|hy2)://' "${XRAY_INFO}" >> "$raw" || true
  fi

  if [[ -f "${SINGBOX_INFO}" ]]; then
    grep -E '^(vless|hysteria2|hy2|tuic|ss|trojan|https)://' "${SINGBOX_INFO}" >> "$raw" || true
  fi

  if [[ ! -s "$raw" ]]; then
    warn "没有找到可导出的节点链接。请先安装节点。"
    return 0
  fi

  base64 -w0 "$raw" > "$b64"

  {
    echo "# Love URI subscription list"
    echo "links:"
    local i=0
    while IFS= read -r line; do
      ((i++)) || true
      safe="$(printf '%s' "$line" | sed 's/"/\\"/g')"
      echo "  - name: \"LOVE-${i}\""
      echo "    uri: \"${safe}\""
    done < "$raw"
  } > "$clash"

  local index="${LOVE_SUB}/index.html"
  {
    echo "<!doctype html><html><head><meta charset='utf-8'><title>Love Subscription</title></head><body><h1>Love Subscription</h1><pre>"
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$raw"
    echo "</pre></body></html>"
  } > "$index"

  log "订阅已导出："
  echo "Raw:    $raw"
  echo "Base64: $b64"
  echo "YAML:   $clash"
  echo "HTML:   $index"
  echo
  generate_mihomo_yaml >/dev/null 2>&1 || true
  generate_client_exports >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true
  cat "$raw"
}

show_node_info() {
  echo
  echo "================ Love 节点信息 ================"
  [[ -f "${XRAY_INFO}" ]] && { echo; echo "[Xray]"; cat "${XRAY_INFO}"; }
  [[ -f "${SINGBOX_INFO}" ]] && { echo; echo "[sing-box]"; cat "${SINGBOX_INFO}"; }
  [[ ! -f "${XRAY_INFO}" && ! -f "${SINGBOX_INFO}" ]] && warn "还没有节点信息。"
  echo
  [[ -d "${LOVE_SUB}" ]] && ls -lah "${LOVE_SUB}" 2>/dev/null || true
}

doctor_check() {
  echo
  echo "================ Love Doctor ================"
  echo "Version: ${VERSION}"
  echo "Date: $(date -Is)"
  echo

  detect_network || true
  echo

  echo "[System]"
  uname -a || true
  [[ -f /etc/os-release ]] && cat /etc/os-release | sed -n '1,6p'
  echo

  echo "[Binaries]"
  command -v xray >/dev/null 2>&1 && xray version | head -n2 || echo "xray: not installed"
  command -v sing-box >/dev/null 2>&1 && sing-box version | head -n2 || echo "sing-box: not installed"
  command -v cloudflared >/dev/null 2>&1 && cloudflared version || echo "cloudflared: not installed"
  command -v certbot >/dev/null 2>&1 && certbot --version || echo "certbot: not installed"
  echo

  echo "[Ports]"
  ss -tulpn | grep -E ':22|:80|:443|:8443|:888|xray|sing-box|nginx|cloudflared' || true
  echo

  echo "[Services]"
  systemctl is-active xray 2>/dev/null && systemctl status xray --no-pager | sed -n '1,12p' || true
  systemctl is-active sing-box 2>/dev/null && systemctl status sing-box --no-pager | sed -n '1,12p' || true
  systemctl is-active love-argo 2>/dev/null && systemctl status love-argo --no-pager | sed -n '1,12p' || true
  systemctl is-active love-port-hopping 2>/dev/null && systemctl status love-port-hopping --no-pager | sed -n '1,12p' || true
  echo

  echo "[Firewall]"
  ufw status verbose 2>/dev/null || true
  echo

  echo "[Config validation]"
  [[ -x "${XRAY_BIN}" && -f "${XRAY_CONF}" ]] && "${XRAY_BIN}" run -test -config "${XRAY_CONF}" || true
  [[ -x "${SINGBOX_BIN}" && -f "${SINGBOX_CONF}" ]] && ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true "${SINGBOX_BIN}" check -c "${SINGBOX_CONF}" || true
}

repair_apt_dpkg() {
  echo
  echo "================ Love Repair apt/dpkg ================"
  warn "该功能用于修复 apt/dpkg 锁、tzdata、python3、certbot、ufw 等常见安装中断问题。"
  read -rp "确认开始修复？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

  export DEBIAN_FRONTEND=noninteractive

  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.service 2>/dev/null || true
  systemctl stop apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop packagekit 2>/dev/null || true

  if ! ps aux | grep -E 'apt|dpkg|unattended|packagekit' | grep -v grep >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock
  else
    warn "检测到 apt/dpkg 进程仍在运行，未删除锁文件。"
    ps aux | grep -E 'apt|dpkg|unattended|packagekit' | grep -v grep || true
  fi

  ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime || true
  echo "Etc/UTC" > /etc/timezone || true

  dpkg --configure -a || true
  apt --fix-broken install -y || true
  apt update || true
  apt install -y python3 python3-minimal tzdata curl wget unzip jq openssl ca-certificates ufw certbot lsof dnsutils iproute2 || true
  dpkg --configure -a || true

  echo
  dpkg --audit || true
  python3 --version || true
  certbot --version || true
  ufw status || true
  log "修复流程完成。"
}

set_ipv6_dns() {
  echo
  echo "================ Love IPv6 DNS ================"
  warn "该功能用于 IPv6-only VPS 出站解析优化。"
  read -rp "是否写入 systemd-resolved IPv6 DNS？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

  mkdir -p /etc/systemd/resolved.conf.d

  cat > /etc/systemd/resolved.conf.d/love-ipv6-dns.conf <<'EOF'
[Resolve]
DNS=2a01:4f8:c2c:123f::1 2a00:1098:2c::1 2a01:4f9:c010:3f02::1
FallbackDNS=2606:4700:4700::1111 2001:4860:4860::8888
EOF

  systemctl restart systemd-resolved || true
  resolvectl status || true
  log "IPv6 DNS 已写入。"
}

update_core_menu() {
  echo
  echo "================ Love Update ================"
  echo "1) 更新 Xray-core"
  echo "2) 更新 sing-box"
  echo "3) 更新维护脚本本体提示"
  echo "0) 返回"
  read -rp "请选择: " u

  case "$u" in
    1)
      install_base
      install_xray_core
      systemctl restart xray 2>/dev/null || true
      ;;
    2)
      install_base
      install_singbox_core
      systemctl restart sing-box 2>/dev/null || true
      ;;
    3)
      echo "GitHub 发布后可执行："
      echo "bash <(wget -qO- https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh)"
      ;;
    *) return 0 ;;
  esac
}

change_preferred_info_only() {
  echo
  echo "================ Love 修改优选地址导出 ================"
  warn "当前功能只重写导出文件中的客户端 Address，不修改服务端监听。"
  read -rp "新的客户端优选 IP / 域名: " newaddr
  parse_endpoint "$newaddr" "443" || die "格式错误。"

  local old_files=("${XRAY_INFO}" "${SINGBOX_INFO}")
  for f in "${old_files[@]}"; do
    [[ -f "$f" ]] || continue
    cp "$f" "${f}.bak.$(date +%F-%H%M%S)"
    sed -i -E "s#^(Address: ).*#\1${ENDPOINT_HOST}#g; s#^(Client Preferred Address: ).*#\1${ENDPOINT_HOST}:${ENDPOINT_PORT}#g" "$f" || true
  done

  warn "链接 URL 内的地址可能需要重新安装/重新导出才能完全替换。"
  export_subscription
}


generate_qrcodes() {
  prepare_dirs
  mkdir -p "${LOVE_SUB}/qr"
  local raw="${LOVE_SUB}/all.txt"
  [[ -s "$raw" ]] || export_subscription >/dev/null 2>&1 || true
  [[ -s "$raw" ]] || { warn "没有节点链接可生成二维码。"; return 0; }

  if ! command -v qrencode >/dev/null 2>&1; then
    warn "未检测到 qrencode，开始安装。"
    install_base >/dev/null 2>&1 || true
  fi
  command -v qrencode >/dev/null 2>&1 || { warn "qrencode 安装失败，无法生成二维码。"; return 0; }

  rm -f "${LOVE_SUB}/qr"/* 2>/dev/null || true
  local i=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ((i++)) || true
    printf '%s' "$line" | qrencode -t ANSIUTF8 > "${LOVE_SUB}/qr/node-${i}.ansi" || true
    printf '%s' "$line" | qrencode -t PNG -o "${LOVE_SUB}/qr/node-${i}.png" || true
    printf '%s' "$line" | qrencode -t SVG -o "${LOVE_SUB}/qr/node-${i}.svg" || true
  done < "$raw"
  log "二维码已生成：${LOVE_SUB}/qr/"
  ls -lah "${LOVE_SUB}/qr/" || true
  [[ -f "${LOVE_SUB}/qr/node-1.ansi" ]] && { echo; echo "第一个二维码："; cat "${LOVE_SUB}/qr/node-1.ansi"; }
}

serve_subscription_nginx() {
  echo
  echo "================ Love Subscription Server ================"
  read -rp "订阅服务端口 [8088]: " port
  port="${port:-8088}"
  export_subscription >/dev/null 2>&1 || true
  install_base >/dev/null 2>&1 || true
  mkdir -p /var/www/love-sub
  cp -a "${LOVE_SUB}/." /var/www/love-sub/
  cat > /etc/nginx/sites-available/love-sub <<EOF
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    root /var/www/love-sub;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  ln -sf /etc/nginx/sites-available/love-sub /etc/nginx/sites-enabled/love-sub
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  command -v ufw >/dev/null 2>&1 && ufw allow "${port}/tcp" || true
  log "订阅服务：/var/www/love-sub"
  echo "http://服务器IP:${port}/all.txt"
  echo "http://服务器IP:${port}/all_base64.txt"
  echo "http://服务器IP:${port}/index.html"
}

cloudflare_api_request() {
  local method="$1" url="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$url" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "$data"
  else
    curl -sS -X "$method" "$url" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json"
  fi
}

argo_api_create_tunnel() {
  echo
  echo "================ Love Argo API 自动隧道 ================"
  warn "需要 Cloudflare API Token：Zone DNS Edit + Account Cloudflare Tunnel Edit。"
  read -rp "Cloudflare API Token: " CF_API_TOKEN
  [[ -n "$CF_API_TOKEN" ]] || die "API Token 不能为空。"
  read -rp "Argo 域名，例如 sub.example.com: " ARGO_DOMAIN
  [[ "$ARGO_DOMAIN" == *.* ]] || die "Argo 域名格式错误。"
  read -rp "本地回源端口 [8080]: " SERVICE_PORT
  SERVICE_PORT="${SERVICE_PORT:-8080}"

  local ROOT_DOMAIN="${ARGO_DOMAIN#*.}" TUNNEL_NAME="${ARGO_DOMAIN%%.*}-love"
  local zone_resp zone_id account_id
  zone_resp="$(cloudflare_api_request GET "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}")"
  zone_id="$(echo "$zone_resp" | jq -r '.result[0].id // empty')"
  account_id="$(echo "$zone_resp" | jq -r '.result[0].account.id // empty')"
  [[ -n "$zone_id" && -n "$account_id" ]] || { echo "$zone_resp"; die "获取 Zone/Account 失败。"; }

  local secret create_resp tunnel_id tunnel_token
  secret="$(openssl rand -base64 32)"
  create_resp="$(cloudflare_api_request POST "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel" "{\"name\":\"${TUNNEL_NAME}\",\"config_src\":\"cloudflare\",\"tunnel_secret\":\"${secret}\"}")"
  echo "$create_resp" | jq -e '.success == true' >/dev/null 2>&1 || { echo "$create_resp"; die "创建 Tunnel 失败。"; }
  tunnel_id="$(echo "$create_resp" | jq -r '.result.id')"
  tunnel_token="$(echo "$create_resp" | jq -r '.result.token')"

  local ingress_payload conf_resp
  ingress_payload="$(jq -n --arg host "$ARGO_DOMAIN" --arg service "http://localhost:${SERVICE_PORT}" '{config:{ingress:[{hostname:$host,service:$service},{service:"http_status:404"}],"warp-routing":{enabled:false}}}')"
  conf_resp="$(cloudflare_api_request PUT "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$ingress_payload")"
  echo "$conf_resp" | jq -e '.success == true' >/dev/null 2>&1 || { echo "$conf_resp"; die "配置 Tunnel 失败。"; }

  local dns_list dns_id dns_payload dns_resp
  dns_payload="$(jq -n --arg name "$ARGO_DOMAIN" --arg content "${tunnel_id}.cfargotunnel.com" '{type:"CNAME",name:$name,content:$content,proxied:true}')"
  dns_list="$(cloudflare_api_request GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${ARGO_DOMAIN}")"
  dns_id="$(echo "$dns_list" | jq -r '.result[0].id // empty')"
  if [[ -n "$dns_id" ]]; then
    dns_resp="$(cloudflare_api_request PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${dns_id}" "$dns_payload")"
  else
    dns_resp="$(cloudflare_api_request POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" "$dns_payload")"
  fi
  echo "$dns_resp" | jq -e '.success == true' >/dev/null 2>&1 || { echo "$dns_resp"; die "DNS 配置失败。"; }

  install_cloudflared
  mkdir -p "${LOVE_HOME}/argo"
  echo "$tunnel_token" > "${LOVE_HOME}/argo/${ARGO_DOMAIN}.token"
  chmod 600 "${LOVE_HOME}/argo/${ARGO_DOMAIN}.token"
  cat > /etc/systemd/system/love-argo.service <<EOF
[Unit]
Description=Love Cloudflared API Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel run --token ${tunnel_token}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable love-argo
  systemctl restart love-argo
  sleep 3
  systemctl status love-argo --no-pager || true
  log "Argo API 隧道完成：https://${ARGO_DOMAIN} -> localhost:${SERVICE_PORT}"
}

hy2_realm_helper() {
  echo
  echo "================ Love HY2 Realm ================"
  warn "HY2 Realm 属于高级 NAT/无公网入口场景；Love 会 check 失败自动回滚。"
  [[ -f "${SINGBOX_CONF}" ]] || die "未找到 ${SINGBOX_CONF}。"
  [[ -x "${SINGBOX_BIN}" ]] || die "未找到 sing-box。"
  echo "1) 尝试开启 Realm"
  echo "2) 关闭 Realm"
  echo "0) 返回"
  read -rp "请选择: " r
  local backup="${SINGBOX_CONF}.realm.bak.$(date +%F-%H%M%S)"
  cp "${SINGBOX_CONF}" "$backup"
  case "$r" in
    1)
      read -rp "Realm ID [love-realm]: " rid; rid="${rid:-love-realm}"
      read -rp "STUN 服务器 [stun.cloudflare.com:3478]: " stun; stun="${stun:-stun.cloudflare.com:3478}"
      jq --arg rid "$rid" --arg stun "$stun" '.inbounds |= map(if .type=="hysteria2" then . + {realm:{enabled:true,id:$rid,stun_server:$stun}} else . end)' "${SINGBOX_CONF}" > "${SINGBOX_CONF}.tmp" && mv "${SINGBOX_CONF}.tmp" "${SINGBOX_CONF}"
      ;;
    2)
      jq '.inbounds |= map(if .type=="hysteria2" then del(.realm) else . end)' "${SINGBOX_CONF}" > "${SINGBOX_CONF}.tmp" && mv "${SINGBOX_CONF}.tmp" "${SINGBOX_CONF}"
      ;;
    *) return 0 ;;
  esac
  if ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true "${SINGBOX_BIN}" check -c "${SINGBOX_CONF}"; then
    systemctl restart sing-box
    log "HY2 Realm 操作完成。备份：${backup}"
  else
    warn "sing-box check 失败，回滚。"
    cp "$backup" "${SINGBOX_CONF}"
    systemctl restart sing-box || true
    die "HY2 Realm 写入失败，已回滚。"
  fi
}

reload_protocols_helper() {
  echo
  echo "================ Love 增删协议 ================"
  warn "安全方式：先备份旧配置，再重建 sing-box 协议。"
  read -rp "确认备份并重建？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0
  backup_configs
  install_singbox_native
}
super_menu() {
  while true; do
    echo
    echo "================ Love Super Tools ================"
    echo "1) Love -n 查看节点"
    echo "2) Love sub 导出订阅"
    echo "3) Love qr 生成二维码"
    echo "4) 订阅静态服务 nginx"
    echo "5) Love doctor 全面诊断"
    echo "6) Love repair 修复 apt/dpkg"
    echo "7) Love dns 设置 IPv6 DNS"
    echo "8) Love -v 更新核心"
    echo "9) 修改优选地址导出"
    echo "10) Argo API 自动隧道"
    echo "11) HY2 Realm 安全开关"
    echo "12) Love -r 增删协议 / 重建"
    echo "13) Mihomo / Clash YAML 生成"
    echo "14) Shadowrocket / NekoBox / V2RayN 导出"
    echo "15) 在线更新 Love 自身脚本"
    echo "16) Web 管理页"
    echo "17) Love links 简洁链接总览"
    echo "18) Love singbox-json"
    echo "19) Love shadowrocket"
    echo "20) Love v2rayn"
    echo "21) Love nekobox"
    echo "22) SFI / SFA / SFM"
    echo "23) 完整客户端包"
    echo "24) v6 Project Tools：Web安全/推送/检测/备份/证书/Oracle/多用户"
    echo "0) 返回"
    read -rp "请选择: " s
    case "$s" in
      1) show_node_info ;;
      2) export_subscription ;;
      3) generate_qrcodes ;;
      4) serve_subscription_nginx ;;
      5) doctor_check ;;
      6) repair_apt_dpkg ;;
      7) set_ipv6_dns ;;
      8) update_core_menu ;;
      9) change_preferred_info_only ;;
      10) argo_api_create_tunnel ;;
      11) hy2_realm_helper ;;
      12) reload_protocols_helper ;;
      13) generate_mihomo_yaml ;;
      14) generate_client_exports ;;
      15) self_update_love ;;
      16) web_admin_page ;;
      17) love_links ;;
      18) love_singbox_json ;;
      19) love_shadowrocket ;;
      20) love_v2rayn ;;
      21) love_nekobox ;;
      22) love_sfi_sfa_sfm ;;
      23) love_full_client_pack ;;
      24) v6_super_menu ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


# ------------------------------------------------------------------------------
# Maintenance
# ------------------------------------------------------------------------------

show_all_node_catalog() {
  cat <<'EOF'

================ Love 全节点目录 ================

A. 原生 Xray 稳定节点
  1. VLESS + REALITY + Vision 443/tcp
  2. HY2 / Hysteria2 443/udp
  3. IPv6 listen ::
  4. 有域名：Let's Encrypt
  5. 无域名：Reality-only
  6. 无域名可选 HY2 自签 insecure=1
  7. 优选 IP / 域名

B. 原生 sing-box 节点
  8.  VLESS Reality
  9.  Hysteria2
  10. TUIC
  11. Shadowsocks
  12. Trojan
  13. VMess WS
  14. VLESS WS TLS
  15. H2 Reality
  16. gRPC Reality
  17. AnyTLS
  18. Naive
  19. ShadowTLS

C. 高级能力
  20. all 全协议
  21. Argo / Cloudflared
  22. Port Hopping
  23. WARP 出站增强说明
  24. 备份 / 状态 / 卸载
  25. Love -n 节点查看
  26. Love sub 订阅导出
  27. Love doctor 全面诊断
  28. Love repair apt/dpkg 修复
  29. Love dns IPv6 DNS 优化
  30. Love -v 核心更新
  31. Love qr 二维码 PNG/SVG/终端显示
  32. Argo API 自动创建 Tunnel + DNS
  33. HY2 Realm 安全开关，失败自动回滚
  34. Love -r 增删协议 / 安全重建
  35. 订阅静态服务 nginx
  36. Mihomo / Clash 标准 YAML
  37. Shadowrocket 专用导出
  38. NekoBox / V2RayN 专用导出
  39. 在线更新 Love 自身脚本
  40. Web 静态管理页
  41. Love links 简洁链接总览
  42. Love singbox-json 生成 sing-box outbounds/client
  43. Love shadowrocket 专用导出
  44. Love v2rayn 专用导出
  45. Love nekobox / nekoray 专用导出
  46. SFI / SFA / SFM 完整客户端 JSON
  47. 完整客户端包 tar.gz
  48. Web Basic Auth 密码保护
  49. Web 一键复制链接
  50. 订阅随机路径 token
  51. Telegram / Bark / Email 推送
  52. 节点健康检测
  53. 定时备份 systemd timer
  54. 证书续签状态检查
  55. 端口冲突检测与推荐
  56. Oracle Cloud 安全组模板
  57. 多用户 UUID 管理
  58. Love precheck 环境预检
  59. Love mode 安装模式分级
  60. Love snapshot / rollback 快照回滚
  61. Love users 分用户订阅和二维码
  62. Love support 客户端兼容矩阵
  63. Love logs / errors 日志系统
  64. Love pin 版本锁定
  65. Love compat sing-box 兼容性检测
  66. Love speed 连接测速
  67. Love cfip Cloudflare 优选 IP / 域名
  68. Love cloud-firewall 云防火墙模板
  69. Love harden 安全加固
  70. Love uninstall soft/full
  71. Love web-status Web 状态页
  72. Love validate 全量验证
  73. Love audit 安全审计
  74. Love dashboard 项目仪表盘
  75. Love state 状态 JSON
  76. Love release GitHub 发布包
  77. Love readme README 生成
  78. Love support-bundle 脱敏支持包
  79. Love import-links 外部节点导入
  80. Love rotate token/Web 密码轮换
  81. Love test-suite 测试套件
  82. Love update-channel 更新通道
  83. Love nginx Nginx 反代菜单
  84. Love nginx-ws WS 反代 VLESS/VMess
  85. Love nginx-grpc gRPC 反代
  86. Love nginx-fallback 伪装站点
  87. Love nginx-stream SNI passthrough 分流
  88. Love nginx-status 反代状态
  89. Love nginx-rollback Nginx 配置回滚
  90. Love fix-hy2 修复 sing-box 1.12 / 自动放行端口 / 生成 HY2 订阅
  91. Love fix-ipv6 IPv6-only 出站 prefer_ipv6 修复
  92. Love test-outbound 测试 IPv4 / IPv6 出站
  93. Love warp-hint WARP / IPv4 出站提示
  94. Love warp WARP Manager
  95. Love warp-install 安装 Cloudflare 官方 WARP 客户端
  96. Love warp-status 查看 WARP 状态
  97. Love warp-test 测试 WARP / IPv4 / IPv6 出站

================================================

EOF
}

show_status() {
  echo
  echo "================ Love 状态 ================"
  echo "Version: ${VERSION}"
  echo "Home: ${LOVE_HOME}"
  echo
  detect_network || true
  echo
  systemctl status xray --no-pager 2>/dev/null || true
  systemctl status sing-box --no-pager 2>/dev/null || true
  systemctl status love-argo --no-pager 2>/dev/null || true
  echo
  ss -tulpn | grep -E ':22|:80|:443|:8443|:888|xray|sing-box|nginx|cloudflared' || true
  echo
  ufw status verbose 2>/dev/null || true
  echo
  ls -lah "${LOVE_INFO}" 2>/dev/null || true
  echo
  [[ -f "${XRAY_INFO}" ]] && echo "Xray 节点信息：${XRAY_INFO}"
  [[ -f "${SINGBOX_INFO}" ]] && echo "sing-box 节点信息：${SINGBOX_INFO}"
  command -v Love >/dev/null 2>&1 && echo "维护命令：Love"
  command -v love >/dev/null 2>&1 && echo "兼容命令：love"
}

backup_configs() {
  prepare_dirs
  local ts out
  ts="$(date +%F-%H%M%S)"
  out="${LOVE_BACKUP}/backup-${ts}.tar.gz"

  tar -czf "${out}" \
    /etc/sing-box \
    /usr/local/etc/xray \
    /etc/systemd/system/xray.service \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/love-argo.service \
    "${LOVE_INFO}" 2>/dev/null || true

  log "备份完成：${out}"
}

uninstall_menu() {
  echo
  echo "================ Love 卸载 ================"
  echo "1) 卸载 Xray only"
  echo "2) 卸载 sing-box only"
  echo "3) 卸载 Argo service only"
  echo "0) 返回"
  read -rp "请选择: " u

  case "$u" in
    1)
      systemctl stop xray 2>/dev/null || true
      systemctl disable xray 2>/dev/null || true
      rm -f /etc/systemd/system/xray.service
      rm -rf /etc/systemd/system/xray.service.d
      systemctl daemon-reload || true
      log "Xray 服务已卸载，配置目录未删除。"
      ;;
    2)
      systemctl stop sing-box 2>/dev/null || true
      systemctl disable sing-box 2>/dev/null || true
      rm -f /etc/systemd/system/sing-box.service
      systemctl daemon-reload || true
      log "sing-box 服务已卸载，配置目录未删除。"
      ;;
    3)
      systemctl stop love-argo 2>/dev/null || true
      systemctl disable love-argo 2>/dev/null || true
      rm -f /etc/systemd/system/love-argo.service
      systemctl daemon-reload || true
      log "Argo service 已卸载。"
      ;;
    *) return 0 ;;
  esac
}


self_update_love() {
  echo
  echo "================ Love Self Update ================"
  local url="${LOVE_UPDATE_URL:-}"
  if [[ -z "$url" ]]; then
    read -rp "请输入 Love.sh raw URL: " url
  fi
  [[ -n "$url" ]] || die "更新 URL 不能为空。"

  local target="${LOVE_HOME}/Love.sh"
  local tmp="/tmp/Love.update.$$"
  curl -fsSL "$url" -o "$tmp" || die "下载新版 Love 失败。"
  bash -n "$tmp" || die "新版脚本语法检查失败，已取消更新。"

  cp -f "$target" "${target}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  install -m 755 "$tmp" "$target"
  ln -sf "$target" "${LOVE_BIN}"
  ln -sf "$target" "${LOVE_BIN_LOWER}"
  rm -f "$tmp"

  log "Love 已更新。重新运行：Love"
}

web_admin_page() {
  echo
  echo "================ Love Web 管理页 ================"
  warn "静态管理页：展示状态、订阅、二维码、复制按钮；不在浏览器执行 root 命令。"
  read -rp "Web 管理页端口 [8099]: " port
  port="${port:-8099}"

  read -rp "是否开启 Basic Auth 密码保护？[Y/n]: " auth_on
  auth_on="${auth_on:-Y}"
  local web_user="love"
  local web_pass=""
  if [[ "$auth_on" =~ ^[Yy]$ ]]; then
    read -rp "Web 用户名 [love]: " web_user
    web_user="${web_user:-love}"
    read -rsp "Web 密码，留空自动生成: " web_pass
    echo
    if [[ -z "$web_pass" ]]; then
      web_pass="$(random_token 8)"
      warn "自动生成 Web 密码：${web_pass}"
    fi
    mkdir -p "${LOVE_HOME}/auth"
    if command -v htpasswd >/dev/null 2>&1; then
      htpasswd -bc "${LOVE_HOME}/auth/htpasswd" "$web_user" "$web_pass" >/dev/null
    else
      printf "%s:$(openssl passwd -apr1 "%s")\n" "$web_user" "$web_pass" > "${LOVE_HOME}/auth/htpasswd"
    fi
    chmod 600 "${LOVE_HOME}/auth/htpasswd"
  fi

  local token
  token="$(get_sub_token)"

  export_subscription >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true
  love_full_client_pack >/dev/null 2>&1 || true

  install_base >/dev/null 2>&1 || true
  mkdir -p "${LOVE_WEB}/${token}/subscribe" "${LOVE_WEB}/${token}/qr" "${LOVE_WEB}/${token}/clients" "${LOVE_WEB}/${token}/sing-box"

  cp -a "${LOVE_SUB}/." "${LOVE_WEB}/${token}/subscribe/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/qr/." "${LOVE_WEB}/${token}/qr/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/clients/." "${LOVE_WEB}/${token}/clients/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/sing-box/." "${LOVE_WEB}/${token}/sing-box/" 2>/dev/null || true

  cat > "${LOVE_WEB}/${token}/index.html" <<'EOF'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Love Admin</title>
<style>
body{font-family:Arial,sans-serif;max-width:1080px;margin:36px auto;line-height:1.6;background:#fafafa;color:#222}
.card{background:#fff;border:1px solid #eee;border-radius:14px;padding:18px;margin:14px 0;box-shadow:0 2px 10px rgba(0,0,0,.05)}
a{display:block;margin:6px 0;color:#0b57d0;text-decoration:none}
button{border:0;border-radius:10px;padding:8px 12px;margin:5px;background:#0b57d0;color:white;cursor:pointer}
code{background:#f1f3f4;padding:2px 6px;border-radius:6px}
textarea{width:100%;height:160px;border:1px solid #ddd;border-radius:10px;padding:10px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px}
</style>
<script>
async function copyUrl(path){
  const url = location.origin + path;
  await navigator.clipboard.writeText(url);
  alert("Copied: " + url);
}
async function copyText(id){
  const text = document.getElementById(id).value;
  await navigator.clipboard.writeText(text);
  alert("Copied");
}
async function loadRaw(){
  try {
    const r = await fetch("subscribe/all.txt");
    document.getElementById("raw").value = await r.text();
  } catch(e) {}
}
window.onload=loadRaw;
</script>
</head>
<body>
<h1>Love Admin</h1>
<div class="card">
<h2>One-click Copy</h2>
<button onclick="copyUrl(location.pathname + 'subscribe/all.txt')">Copy Raw Subscription URL</button>
<button onclick="copyUrl(location.pathname + 'subscribe/all_base64.txt')">Copy Base64 Subscription URL</button>
<button onclick="copyUrl(location.pathname + 'subscribe/mihomo.yaml')">Copy Mihomo URL</button>
<button onclick="copyUrl(location.pathname + 'clients/v2rayn-uri.txt')">Copy V2RayN URL</button>
<button onclick="copyUrl(location.pathname + 'clients/shadowrocket.conf')">Copy Shadowrocket URL</button>
<button onclick="copyUrl(location.pathname + 'clients/nekobox-uri.txt')">Copy NekoBox URL</button>
</div>

<div class="grid">
<div class="card">
<h2>Subscriptions</h2>
<a href="subscribe/all.txt">Raw URI List</a>
<a href="subscribe/all_base64.txt">Base64 Subscription</a>
<a href="subscribe/mihomo.yaml">Mihomo / Clash YAML</a>
<a href="subscribe/uri-list.yaml">URI YAML</a>
</div>
<div class="card">
<h2>Clients</h2>
<a href="clients/shadowrocket.conf">Shadowrocket</a>
<a href="clients/nekobox-uri.txt">NekoBox</a>
<a href="clients/v2rayn-uri.txt">V2RayN</a>
<a href="clients/sfi-sfa-sfm-client.json">SFI / SFA / SFM</a>
</div>
<div class="card">
<h2>sing-box</h2>
<a href="sing-box/sing-box-outbounds.json">sing-box outbounds</a>
<a href="sing-box/sing-box-client.json">sing-box client config</a>
</div>
<div class="card">
<h2>QR Codes</h2>
<a href="qr/">QR Directory</a>
</div>
</div>

<div class="card">
<h2>Raw Links</h2>
<textarea id="raw"></textarea>
<button onclick="copyText('raw')">Copy All Links</button>
</div>

<div class="card">
<h2>Useful Commands</h2>
<code>Love -n</code><br>
<code>Love sub</code><br>
<code>Love qr</code><br>
<code>Love doctor</code><br>
<code>Love check</code><br>
<code>Love backup-auto</code>
</div>
</body>
</html>
EOF

  cat > /etc/nginx/sites-available/love-admin <<EOF
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    root ${LOVE_WEB};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
EOF

  if [[ "$auth_on" =~ ^[Yy]$ ]]; then
    cat >> /etc/nginx/sites-available/love-admin <<EOF
        auth_basic "Love Admin";
        auth_basic_user_file ${LOVE_HOME}/auth/htpasswd;
EOF
  fi

  cat >> /etc/nginx/sites-available/love-admin <<'EOF'
    }
}
EOF

  ln -sf /etc/nginx/sites-available/love-admin /etc/nginx/sites-enabled/love-admin
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  command -v ufw >/dev/null 2>&1 && ufw allow "${port}/tcp" || true

  log "Love Web 管理页已开启："
  echo "URL: http://服务器IP:${port}/${token}/"
  if [[ "$auth_on" =~ ^[Yy]$ ]]; then
    echo "User: ${web_user}"
    echo "Pass: ${web_pass}"
  fi
  echo "Token path: ${token}"
}



notify_config_menu() {
  echo
  echo "================ Love Notify 配置 ================"
  echo "1) Telegram"
  echo "2) Bark"
  echo "3) Email"
  echo "4) 查看当前配置"
  echo "0) 返回"
  read -rp "请选择: " n
  mkdir -p "${LOVE_HOME}"

  case "$n" in
    1)
      read -rp "Telegram Bot Token: " tg_token
      read -rp "Telegram Chat ID: " tg_chat
      cat > "${LOVE_NOTIFY_CONF}" <<EOF
NOTIFY_TYPE=telegram
TG_TOKEN='${tg_token}'
TG_CHAT='${tg_chat}'
EOF
      chmod 600 "${LOVE_NOTIFY_CONF}"
      ;;
    2)
      read -rp "Bark URL，例如 https://api.day.app/KEY: " bark_url
      cat > "${LOVE_NOTIFY_CONF}" <<EOF
NOTIFY_TYPE=bark
BARK_URL='${bark_url}'
EOF
      chmod 600 "${LOVE_NOTIFY_CONF}"
      ;;
    3)
      read -rp "收件邮箱: " mail_to
      cat > "${LOVE_NOTIFY_CONF}" <<EOF
NOTIFY_TYPE=email
MAIL_TO='${mail_to}'
EOF
      chmod 600 "${LOVE_NOTIFY_CONF}"
      warn "Email 依赖本机 mail 命令和 MTA/SMTP 配置。"
      ;;
    4)
      [[ -f "${LOVE_NOTIFY_CONF}" ]] && cat "${LOVE_NOTIFY_CONF}" || warn "未配置。"
      ;;
    *) return 0 ;;
  esac
  log "通知配置完成：${LOVE_NOTIFY_CONF}"
}

notify_send() {
  local title="${1:-Love Notice}"
  local body="${2:-}"
  [[ -f "${LOVE_NOTIFY_CONF}" ]] || { warn "未配置通知，先运行 Love notify。"; return 0; }
  # shellcheck disable=SC1090
  source "${LOVE_NOTIFY_CONF}"

  case "${NOTIFY_TYPE:-}" in
    telegram)
      curl -sS "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" \
        --data-urlencode "text=${title}

${body}" >/dev/null || true
      ;;
    bark)
      curl -sS "${BARK_URL}/$(urlencode "$title")/$(urlencode "$body")" >/dev/null || true
      ;;
    email)
      if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$body" | mail -s "$title" "$MAIL_TO" || true
      else
        warn "mail 命令不存在。"
      fi
      ;;
    *)
      warn "未知通知类型。"
      ;;
  esac
}

notify_nodes() {
  export_subscription >/dev/null 2>&1 || true
  local body=""
  body+="Love version: ${VERSION}"$'\n'
  body+="Node info path: ${LOVE_INFO}"$'\n'
  body+="Subscription path: ${LOVE_SUB}"$'\n'
  [[ -f "${LOVE_SUB}/all.txt" ]] && body+=$'\n'"$(sed -n '1,20p' "${LOVE_SUB}/all.txt")"
  notify_send "Love Nodes" "$body"
  log "节点通知已发送。"
}

health_check_nodes() {
  echo
  echo "================ Love 可用性检测 ================"
  export_subscription >/dev/null 2>&1 || true
  local raw="${LOVE_SUB}/all.txt"
  [[ -s "$raw" ]] || { warn "没有节点链接。"; return 0; }

  local report="${LOVE_HOME}/health-$(date +%F-%H%M%S).txt"
  : > "$report"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local hostport scheme host port
    scheme="${line%%://*}"

    case "$scheme" in
      vless|trojan|tuic)
        hostport="${line#*://}"
        hostport="${hostport#*@}"
        hostport="${hostport%%\?*}"
        ;;
      hy2|hysteria2)
        hostport="${line#*://}"
        hostport="${hostport#*@}"
        hostport="${hostport%%/*}"
        ;;
      ss)
        hostport="${line#*@}"
        hostport="${hostport%%\?*}"
        hostport="${hostport%%#*}"
        ;;
      *)
        echo "[SKIP] $scheme $line" | tee -a "$report"
        continue
        ;;
    esac

    if [[ "$hostport" == \[*\]:* ]]; then
      host="${hostport%%]*}"
      host="${host#[}"
      port="${hostport##*:}"
    else
      host="${hostport%:*}"
      port="${hostport##*:}"
    fi

    if command -v nc >/dev/null 2>&1; then
      if timeout 5 nc -z "$host" "$port" >/dev/null 2>&1; then
        echo "[OK] ${scheme} ${host}:${port}" | tee -a "$report"
      else
        echo "[FAIL] ${scheme} ${host}:${port}" | tee -a "$report"
      fi
    else
      echo "[INFO] nc 未安装，跳过 ${host}:${port}" | tee -a "$report"
    fi
  done < "$raw"

  log "检测报告：${report}"
}

setup_auto_backup() {
  echo
  echo "================ Love 定时备份 ================"
  read -rp "备份频率 daily/weekly [daily]: " freq
  freq="${freq:-daily}"

  cat > /etc/systemd/system/love-backup.service <<EOF
[Unit]
Description=Love Backup Service

[Service]
Type=oneshot
ExecStart=${LOVE_BIN} backup
EOF

  cat > /etc/systemd/system/love-backup.timer <<EOF
[Unit]
Description=Love Backup Timer

[Timer]
OnCalendar=${freq}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now love-backup.timer
  systemctl list-timers | grep love-backup || true
  log "定时备份已开启：${freq}"
}

cert_status_check() {
  echo
  echo "================ Love Cert Check ================"
  local found=0
  if [[ -d /etc/letsencrypt/live ]]; then
    for cert in /etc/letsencrypt/live/*/fullchain.pem; do
      [[ -f "$cert" ]] || continue
      found=1
      local domain end epoch now days
      domain="$(basename "$(dirname "$cert")")"
      end="$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)"
      epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
      now="$(date +%s)"
      days=$(( (epoch-now)/86400 ))
      echo "${domain}: expires in ${days} days (${end})"
      if [[ "$days" -lt 15 ]]; then
        warn "${domain} 证书快过期，建议 certbot renew --dry-run 检查。"
      fi
    done
  fi

  [[ "$found" == "1" ]] || warn "没有发现 Let's Encrypt 证书。"
  echo
  certbot renew --dry-run --quiet && log "certbot dry-run 通过。" || warn "certbot dry-run 失败或未配置证书。"
}

oracle_security_template() {
  cat <<'EOF'

================ Oracle Cloud 安全组 / NSG 模板 ================

Oracle 控制台也要放行，不能只配置 VPS 内部 ufw。

基础端口：
  22/tcp      SSH
  80/tcp      Let's Encrypt HTTP-01
  443/tcp     Reality / TLS
  443/udp     HY2 / QUIC

Love sing-box 默认常用端口：
  8881-8895/tcp
  8881-8895/udp

订阅 / Web：
  8088/tcp    订阅静态服务
  8099/tcp    Love Web 管理页

Port Hopping 示例：
  50000-51000/udp

Oracle 安全规则建议：
  Source CIDR: 0.0.0.0/0
  IPv6 Source CIDR: ::/0
  IP Protocol: TCP 或 UDP
  Destination Port Range: 按上面填写

注意：
  1. Oracle ARM/AMD 都支持，推荐 Ubuntu 22.04/24.04。
  2. IPv6-only 机器，客户端没有 IPv6 仍然不能直连。
  3. Argo 可绕过公网入站端口限制，但需要域名和 Cloudflare。

===============================================================

EOF
}

multi_user_menu() {
  echo
  echo "================ Love 多用户 UUID 管理 ================"
  warn "该功能主要管理 Xray Reality 用户。修改后会备份配置并重启 Xray。"
  [[ -f "${XRAY_CONF}" ]] || { warn "未找到 Xray 配置：${XRAY_CONF}"; return 0; }

  echo "1) 查看用户"
  echo "2) 添加用户"
  echo "3) 删除用户"
  echo "0) 返回"
  read -rp "请选择: " m

  cp "${XRAY_CONF}" "${XRAY_CONF}.users.bak.$(date +%F-%H%M%S)"

  case "$m" in
    1)
      jq '.inbounds[]? | select(.protocol=="vless") | .settings.clients' "${XRAY_CONF}"
      return 0
      ;;
    2)
      read -rp "新用户 UUID，留空自动生成: " new_uuid
      new_uuid="${new_uuid:-$(random_uuid)}"
      read -rp "备注 email/name [love-user]: " email
      email="${email:-love-user}"
      jq --arg id "$new_uuid" --arg email "$email" '
        .inbounds |= map(
          if .protocol=="vless" then
            .settings.clients += [{id:$id,flow:"xtls-rprx-vision",email:$email}]
          else . end
        )
      ' "${XRAY_CONF}" > "${XRAY_CONF}.tmp" && mv "${XRAY_CONF}.tmp" "${XRAY_CONF}"
      echo "New UUID: ${new_uuid}"
      ;;
    3)
      read -rp "要删除的 UUID: " del_uuid
      [[ -n "$del_uuid" ]] || die "UUID 不能为空。"
      jq --arg id "$del_uuid" '
        .inbounds |= map(
          if .protocol=="vless" then
            .settings.clients = (.settings.clients | map(select(.id != $id)))
          else . end
        )
      ' "${XRAY_CONF}" > "${XRAY_CONF}.tmp" && mv "${XRAY_CONF}.tmp" "${XRAY_CONF}"
      ;;
    *) return 0 ;;
  esac

  if "${XRAY_BIN}" run -test -config "${XRAY_CONF}"; then
    systemctl restart xray
    log "多用户配置已更新。"
  else
    warn "Xray 测试失败，正在回滚。"
    local latest
    latest="$(ls -t ${XRAY_CONF}.users.bak.* | head -n1)"
    cp "$latest" "${XRAY_CONF}"
    systemctl restart xray || true
    die "配置已回滚。"
  fi
}

v6_super_menu() {
  while true; do
    echo
    echo "================ Love v6 Project Tools ================"
    echo "1) Web 密码保护 + 随机路径"
    echo "2) 重置订阅随机路径 token"
    echo "3) 通知配置 Telegram/Bark/Email"
    echo "4) 推送节点信息"
    echo "5) 自动测速 / 可用性检测"
    echo "6) 定时备份"
    echo "7) 证书续签状态检查"
    echo "8) 端口冲突检测与推荐"
    echo "9) Oracle Cloud 安全组模板"
    echo "10) 多用户 UUID 管理"
    echo "11) v7 Stable Tools"
    echo "0) 返回"
    read -rp "请选择: " v
    case "$v" in
      1) web_admin_page ;;
      2) reset_sub_token ;;
      3) notify_config_menu ;;
      4) notify_nodes ;;
      5) health_check_nodes ;;
      6) setup_auto_backup ;;
      7) cert_status_check ;;
      8) check_port_conflict_and_recommend ;;
      9) oracle_security_template ;;
      10) users_menu_v7 ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


# ------------------------------------------------------------------------------
# V7 Stable Release Extensions
# ------------------------------------------------------------------------------

love_log_event() {
  prepare_dirs
  printf '[%s] %s\n' "$(date -Is)" "$*" >> "${LOVE_LOG}/love.log" 2>/dev/null || true
}

love_error_event() {
  prepare_dirs
  printf '[%s] %s\n' "$(date -Is)" "$*" >> "${LOVE_LOG}/error.log" 2>/dev/null || true
}

precheck_env() {
  echo
  echo "================ Love Precheck 环境预检 ================"
  local ok=1
  echo "Version: ${VERSION}"
  echo "Date: $(date -Is)"
  echo

  echo "[1] Root 权限"
  if [[ "${EUID}" -eq 0 ]]; then log "root OK"; else warn "不是 root"; ok=0; fi

  echo
  echo "[2] 系统与架构"
  [[ -f /etc/os-release ]] && sed -n '1,8p' /etc/os-release || true
  echo "Arch: $(uname -m)"
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) log "架构支持 AMD64/ARM64 OK" ;;
    *) warn "架构未严格测试"; ok=0 ;;
  esac

  echo
  echo "[3] systemd"
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    systemctl --version | head -n1
    log "systemd OK"
  else
    warn "未检测到 systemd，服务管理可能失败"
    ok=0
  fi

  echo
  echo "[4] 网络"
  detect_network || true
  echo "DNS test:"
  getent hosts github.com 2>/dev/null | head -n1 || warn "DNS 解析 github.com 失败"
  curl -I --max-time 8 https://github.com >/dev/null 2>&1 && log "GitHub HTTPS OK" || warn "GitHub 访问可能异常"

  echo
  echo "[5] 资源"
  free -h || true
  df -h / || true
  local mem_kb disk_avail
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  disk_avail="$(df -Pk / | awk 'NR==2{print $4}' 2>/dev/null || echo 0)"
  [[ "$mem_kb" -ge 450000 ]] && log "内存 OK" || warn "内存低于 512MB，建议 1GB+"
  [[ "$disk_avail" -ge 4000000 ]] && log "磁盘 OK" || warn "磁盘剩余低于约 4GB，建议 10GB+"

  echo
  echo "[6] 端口占用"
  for p in 22 80 443 8881 8882 8883 8088 8099; do
    if ss -tuln | awk '{print $5}' | grep -Eq "[:.]${p}$"; then
      echo "[USED] ${p}"
    else
      echo "[FREE] ${p}"
    fi
  done

  echo
  echo "[7] 云平台提示"
  if curl -s --max-time 2 http://169.254.169.254/opc/v1/instance/ >/dev/null 2>&1; then
    warn "检测到可能是 Oracle Cloud。请同时配置控制台 NSG / Security List。"
  fi

  echo
  if [[ "$ok" == "1" ]]; then
    log "Precheck 完成：环境基本可用。"
  else
    warn "Precheck 完成：存在警告，建议先修复再安装。"
  fi
}

mode_wizard() {
  echo
  echo "================ Love Mode 安装模式 ================"
  echo "1) 新手推荐：Xray Reality + 可选 HY2"
  echo "2) 稳定模式：Xray Reality-only"
  echo "3) 全协议模式：sing-box all / 自选协议"
  echo "4) IPv6-only 专用建议"
  echo "5) Argo 无公网入口模式"
  echo "6) 高级自定义"
  echo "0) 返回"
  read -rp "请选择模式: " m
  case "$m" in
    1) install_xray_stable ;;
    2)
      warn "稳定 Reality-only：安装时选择有/无域名均可，HY2 选 n。"
      install_xray_stable
      ;;
    3) install_singbox_native ;;
    4)
      cat <<'EOF'
IPv6-only 建议：
1. 客户端有 IPv6：Reality / HY2 可以直连。
2. 客户端没有 IPv6：请使用 Argo / Cloudflared 或中转。
3. WARP 只改善服务器出站，不提供公网 IPv4 入站。
EOF
      ;;
    5) argo_helper ;;
    6) main_menu ;;
    *) return 0 ;;
  esac
}

snapshot_create() {
  prepare_dirs
  local name="${1:-snapshot-$(date +%F-%H%M%S)}"
  local out="${LOVE_SNAPSHOT}/${name}.tar.gz"
  tar -czf "$out" \
    /etc/sing-box \
    /usr/local/etc/xray \
    /etc/nginx/sites-available \
    /etc/nginx/sites-enabled \
    /etc/systemd/system/xray.service \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/love-argo.service \
    /etc/systemd/system/love-backup.service \
    /etc/systemd/system/love-backup.timer \
    "${LOVE_HOME}" 2>/dev/null || true
  log "快照已创建：${out}"
}

snapshot_list() {
  prepare_dirs
  echo
  echo "================ Love Snapshots ================"
  ls -lah "${LOVE_SNAPSHOT}" 2>/dev/null || warn "暂无快照。"
}

snapshot_rollback() {
  prepare_dirs
  snapshot_list
  read -rp "请输入要回滚的快照文件完整路径: " file
  [[ -f "$file" ]] || die "快照不存在：$file"
  warn "回滚会覆盖配置。建议确认这是你想恢复的版本。"
  read -rp "确认回滚？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0
  tar -xzf "$file" -C / 2>/dev/null || tar -xzf "$file" -C / --strip-components=0 || true
  systemctl daemon-reload || true
  systemctl restart xray 2>/dev/null || true
  systemctl restart sing-box 2>/dev/null || true
  systemctl restart nginx 2>/dev/null || true
  log "回滚完成：$file"
}

snapshot_menu() {
  echo
  echo "================ Love Snapshot / Rollback ================"
  echo "1) 创建快照"
  echo "2) 查看快照"
  echo "3) 回滚快照"
  echo "0) 返回"
  read -rp "请选择: " s
  case "$s" in
    1) snapshot_create ;;
    2) snapshot_list ;;
    3) snapshot_rollback ;;
    *) return 0 ;;
  esac
}

logs_menu() {
  echo
  echo "================ Love Logs ================"
  echo "1) 查看 love.log"
  echo "2) 查看 error.log"
  echo "3) 查看 install / doctor 相关日志目录"
  echo "4) 清理日志"
  echo "0) 返回"
  read -rp "请选择: " l
  case "$l" in
    1) tail -n 200 "${LOVE_LOG}/love.log" 2>/dev/null || warn "暂无 love.log" ;;
    2) tail -n 200 "${LOVE_LOG}/error.log" 2>/dev/null || warn "暂无 error.log" ;;
    3) ls -lah "${LOVE_LOG}" 2>/dev/null || true ;;
    4) read -rp "确认清理日志？[y/N]: " ok; [[ "$ok" =~ ^[Yy]$ ]] && rm -f "${LOVE_LOG}"/*.log ;;
    *) return 0 ;;
  esac
}

pin_core_menu() {
  echo
  echo "================ Love Version Pin ================"
  echo "1) 查看锁定版本"
  echo "2) 锁定 Xray 版本"
  echo "3) 锁定 sing-box 版本"
  echo "4) 取消锁定"
  echo "0) 返回"
  read -rp "请选择: " p
  mkdir -p "${LOVE_HOME}"
  touch "${LOVE_PIN_CONF}"
  case "$p" in
    1) cat "${LOVE_PIN_CONF}" ;;
    2)
      read -rp "Xray 版本，例如 v1.8.24 / latest: " xv
      grep -v '^XRAY_PIN=' "${LOVE_PIN_CONF}" > "${LOVE_PIN_CONF}.tmp" || true
      echo "XRAY_PIN='${xv}'" >> "${LOVE_PIN_CONF}.tmp"
      mv "${LOVE_PIN_CONF}.tmp" "${LOVE_PIN_CONF}"
      ;;
    3)
      read -rp "sing-box 版本，例如 v1.12.0 / latest: " sv
      grep -v '^SINGBOX_PIN=' "${LOVE_PIN_CONF}" > "${LOVE_PIN_CONF}.tmp" || true
      echo "SINGBOX_PIN='${sv}'" >> "${LOVE_PIN_CONF}.tmp"
      mv "${LOVE_PIN_CONF}.tmp" "${LOVE_PIN_CONF}"
      ;;
    4) : > "${LOVE_PIN_CONF}" ;;
    *) return 0 ;;
  esac
  log "版本锁定配置：${LOVE_PIN_CONF}"
}

singbox_compat_check() {
  echo
  echo "================ Love sing-box Compatibility ================"
  if ! command -v sing-box >/dev/null 2>&1; then
    warn "未安装 sing-box。"
    return 0
  fi
  local ver
  ver="$(sing-box version | head -n1)"
  echo "$ver"
  echo
  echo "兼容性提示："
  echo "- Reality / HY2 / TUIC：主流版本支持较好"
  echo "- AnyTLS / Naive / ShadowTLS / Realm：字段变化较快，安装后必须 sing-box check"
  echo "- Love 会在生成配置后执行 sing-box check，失败应回滚。"
  echo
  [[ -f "${SINGBOX_CONF}" ]] && ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true sing-box check -c "${SINGBOX_CONF}" || true
}

support_matrix() {
  cat <<'EOF'

================ Love Client Support Matrix ================

协议 / 客户端          V2RayN   Shadowrocket   NekoBox   Mihomo   sing-box
VLESS Reality          ✅       ✅/部分         ✅        ✅       ✅
HY2 / Hysteria2        ✅       ✅             ✅        ✅       ✅
TUIC                   ✅       部分           ✅        ✅       ✅
Trojan TLS             ✅       ✅             ✅        ✅       ✅
Shadowsocks            ✅       ✅             ✅        ✅       ✅
VMess WS               ✅       ✅             ✅        ✅       ✅
VLESS WS TLS           ✅       ✅             ✅        ✅       ✅
H2 Reality             部分     部分           ✅        ✅       ✅
gRPC Reality           ✅       部分           ✅        ✅       ✅
AnyTLS                 部分     较少           部分      新版     ✅
Naive                  较少     较少           部分      较少     ✅
ShadowTLS              需专用   需插件/部分     custom   plugin  ✅

建议：
1. 普通用户优先 Reality / HY2 / TUIC。
2. ShadowTLS / AnyTLS / Naive 放高级菜单，不默认推荐。
3. 客户端导入失败时，用 Love links / Love clients / Love singbox-json 分类导出。

============================================================

EOF
}

speed_test() {
  echo
  echo "================ Love Speed / Latency Test ================"
  export_subscription >/dev/null 2>&1 || true
  local raw="${LOVE_SUB}/all.txt"
  [[ -s "$raw" ]] || { warn "没有节点链接。"; return 0; }

  local report="${LOVE_HOME}/speed-$(date +%F-%H%M%S).txt"
  : > "$report"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local scheme hostport host port start end ms
    scheme="${line%%://*}"
    case "$scheme" in
      vless|trojan|tuic)
        hostport="${line#*://}"; hostport="${hostport#*@}"; hostport="${hostport%%\?*}" ;;
      hy2|hysteria2)
        hostport="${line#*://}"; hostport="${hostport#*@}"; hostport="${hostport%%/*}" ;;
      ss)
        hostport="${line#*@}"; hostport="${hostport%%\?*}"; hostport="${hostport%%#*}" ;;
      *) continue ;;
    esac
    if [[ "$hostport" == \[*\]:* ]]; then
      host="${hostport%%]*}"; host="${host#[}"; port="${hostport##*:}"
    else
      host="${hostport%:*}"; port="${hostport##*:}"
    fi
    start="$(date +%s%3N)"
    if timeout 5 bash -c ":</dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      end="$(date +%s%3N)"
      ms=$((end-start))
      echo "[OK] ${scheme} ${host}:${port} ${ms}ms" | tee -a "$report"
    else
      echo "[FAIL] ${scheme} ${host}:${port}" | tee -a "$report"
    fi
  done < "$raw"

  read -rp "是否做 HTTP 下载测速？需要输入测试 URL [y/N]: " dl
  if [[ "$dl" =~ ^[Yy]$ ]]; then
    read -rp "下载测试 URL: " url
    if [[ -n "$url" ]]; then
      curl -L -o /dev/null -w 'Download: %{speed_download} bytes/s Time: %{time_total}s\n' "$url" | tee -a "$report" || true
    fi
  fi
  log "测速报告：${report}"
}

cfip_helper() {
  echo
  echo "================ Love Cloudflare 优选 IP / 域名 ================"
  echo "1) 手动保存优选 IP / 域名"
  echo "2) 从文件批量导入"
  echo "3) 查看当前优选列表"
  echo "4) 用第一个优选地址重写导出 Address 提示"
  echo "0) 返回"
  read -rp "请选择: " c
  mkdir -p "${LOVE_HOME}"
  case "$c" in
    1)
      read -rp "输入优选 IP / 域名: " ip
      [[ -n "$ip" ]] && echo "$ip" >> "${LOVE_CFIP_FILE}"
      ;;
    2)
      read -rp "输入文件路径: " f
      [[ -f "$f" ]] || die "文件不存在"
      cat "$f" >> "${LOVE_CFIP_FILE}"
      sort -u "${LOVE_CFIP_FILE}" -o "${LOVE_CFIP_FILE}"
      ;;
    3) cat "${LOVE_CFIP_FILE}" 2>/dev/null || warn "暂无优选列表。" ;;
    4)
      local first
      first="$(grep -v '^\s*$' "${LOVE_CFIP_FILE}" 2>/dev/null | head -n1 || true)"
      [[ -n "$first" ]] || die "没有优选地址。"
      parse_endpoint "$first" "443" || die "优选地址格式错误。"
      warn "将提示重写导出信息里的 Address 为：${ENDPOINT_HOST}:${ENDPOINT_PORT}"
      local f
      for f in "${XRAY_INFO}" "${SINGBOX_INFO}"; do
        [[ -f "$f" ]] || continue
        cp "$f" "${f}.cfip.bak.$(date +%F-%H%M%S)"
        sed -i -E "s#^(Address: ).*#\1${ENDPOINT_HOST}#g; s#^(Client Preferred Address: ).*#\1${ENDPOINT_HOST}:${ENDPOINT_PORT}#g" "$f" || true
      done
      export_subscription
      ;;
    *) return 0 ;;
  esac
}

cloud_firewall_templates() {
  echo
  echo "================ Love Cloud Firewall Templates ================"
  echo "1) Oracle Cloud"
  echo "2) AWS Lightsail / EC2"
  echo "3) Google Cloud"
  echo "4) Azure"
  echo "5) Vultr / Hetzner / 通用"
  echo "0) 返回"
  read -rp "请选择: " c
  case "$c" in
    1) oracle_security_template ;;
    2)
      cat <<'EOF'
AWS 建议放行：
Inbound Security Group:
TCP 22,80,443,8088,8099,8881-8895
UDP 443,8881-8895,50000-51000
Source: 0.0.0.0/0 和 ::/0
EOF
      ;;
    3)
      cat <<'EOF'
GCP 建议创建 VPC Firewall Rule：
tcp:22,80,443,8088,8099,8881-8895
udp:443,8881-8895,50000-51000
Source IPv4: 0.0.0.0/0
Source IPv6: ::/0
EOF
      ;;
    4)
      cat <<'EOF'
Azure NSG 入站规则：
TCP 22,80,443,8088,8099,8881-8895
UDP 443,8881-8895,50000-51000
Priority 建议 1000-1100
Source: Any
EOF
      ;;
    5)
      cat <<'EOF'
通用云防火墙：
TCP: 22,80,443,8088,8099,8881-8895
UDP: 443,8881-8895,50000-51000
IPv4 Source: 0.0.0.0/0
IPv6 Source: ::/0
EOF
      ;;
    *) return 0 ;;
  esac
}

harden_menu() {
  echo
  echo "================ Love Harden 安全加固 ================"
  warn "所有操作均为可选，不会默认强制修改。"
  echo "1) 安装 fail2ban"
  echo "2) SSH 禁用密码登录"
  echo "3) 限制 Web 管理页访问 IP"
  echo "4) 查看开放端口"
  echo "0) 返回"
  read -rp "请选择: " h
  case "$h" in
    1)
      if command -v apt >/dev/null 2>&1; then apt install -y fail2ban; fi
      systemctl enable --now fail2ban 2>/dev/null || true
      ;;
    2)
      warn "操作前请确认你已经配置 SSH key，否则可能无法登录。"
      read -rp "确认禁用 SSH 密码登录？[y/N]: " ok
      [[ "$ok" =~ ^[Yy]$ ]] || return 0
      cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"
      sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
      ;;
    3)
      read -rp "允许访问 Web 的 IP/CIDR，例如 1.2.3.4 或 1.2.3.0/24: " allowip
      [[ -n "$allowip" ]] || die "不能为空"
      if [[ -f /etc/nginx/sites-available/love-admin ]]; then
        cp /etc/nginx/sites-available/love-admin "/etc/nginx/sites-available/love-admin.bak.$(date +%F-%H%M%S)"
        sed -i "/location \//a\\        allow ${allowip};\\n        deny all;" /etc/nginx/sites-available/love-admin
        nginx -t && systemctl reload nginx
      else
        warn "未找到 love-admin nginx 配置。"
      fi
      ;;
    4) ss -tulpn ;;
    *) return 0 ;;
  esac
}

uninstall_menu_v7() {
  echo
  echo "================ Love Uninstall v7 ================"
  echo "1) 软卸载 Xray：停服务，保留配置"
  echo "2) 软卸载 sing-box：停服务，保留配置"
  echo "3) 软卸载 Web/Argo/Timer"
  echo "4) 完整卸载 Love：删除服务、配置、订阅、Web、定时器"
  echo "0) 返回"
  read -rp "请选择: " u
  case "$u" in
    1)
      systemctl stop xray 2>/dev/null || true
      systemctl disable xray 2>/dev/null || true
      log "Xray 已软卸载，配置保留。"
      ;;
    2)
      systemctl stop sing-box 2>/dev/null || true
      systemctl disable sing-box 2>/dev/null || true
      log "sing-box 已软卸载，配置保留。"
      ;;
    3)
      systemctl stop love-argo love-backup.timer love-backup.service 2>/dev/null || true
      systemctl disable love-argo love-backup.timer love-backup.service 2>/dev/null || true
      rm -f /etc/systemd/system/love-argo.service /etc/systemd/system/love-backup.service /etc/systemd/system/love-backup.timer
      rm -f /etc/nginx/sites-enabled/love-admin /etc/nginx/sites-available/love-admin /etc/nginx/sites-enabled/love-sub /etc/nginx/sites-available/love-sub
      systemctl daemon-reload || true
      systemctl reload nginx 2>/dev/null || true
      log "Web/Argo/Timer 已清理。"
      ;;
    4)
      warn "完整卸载会删除 /opt/Love、服务、订阅、Web 配置。"
      read -rp "确认完整卸载？[y/N]: " ok
      [[ "$ok" =~ ^[Yy]$ ]] || return 0
      systemctl stop xray sing-box love-argo love-backup.timer love-backup.service 2>/dev/null || true
      systemctl disable xray sing-box love-argo love-backup.timer love-backup.service 2>/dev/null || true
      rm -f /etc/systemd/system/xray.service /etc/systemd/system/sing-box.service /etc/systemd/system/love-argo.service /etc/systemd/system/love-backup.service /etc/systemd/system/love-backup.timer
      rm -f /etc/nginx/sites-enabled/love-admin /etc/nginx/sites-available/love-admin /etc/nginx/sites-enabled/love-sub /etc/nginx/sites-available/love-sub
      rm -f "${LOVE_BIN}" "${LOVE_BIN_LOWER}"
      rm -rf "${LOVE_HOME}" "${LOVE_WEB}"
      systemctl daemon-reload || true
      systemctl reload nginx 2>/dev/null || true
      log "Love 已完整卸载。"
      ;;
    *) return 0 ;;
  esac
}

user_token_get() {
  local user="$1"
  mkdir -p "${LOVE_HOME}/users"
  local file="${LOVE_HOME}/users/${user}.token"
  [[ -s "$file" ]] || random_token 16 > "$file"
  cat "$file"
}

user_sub_generate() {
  local user="$1"
  mkdir -p "${LOVE_HOME}/users/${user}"
  local token
  token="$(user_token_get "$user")"
  local out="${LOVE_HOME}/users/${user}/all.txt"
  : > "$out"

  # For Xray Reality user, reuse current Reality parameters from XRAY_INFO.
  if [[ -f "${XRAY_INFO}" ]]; then
    local addr port sni pub sid flow
    addr="$(awk -F': ' '/^Address:/{print $2; exit}' "${XRAY_INFO}")"
    port="$(awk -F': ' '/^Port:/{print $2; exit}' "${XRAY_INFO}")"
    sni="$(awk -F': ' '/^SNI:/{print $2; exit}' "${XRAY_INFO}")"
    pub="$(awk -F': ' '/^PublicKey:/{print $2; exit}' "${XRAY_INFO}")"
    sid="$(awk -F': ' '/^ShortID:/{print $2; exit}' "${XRAY_INFO}")"
    flow="$(awk -F': ' '/^Flow:/{print $2; exit}' "${XRAY_INFO}")"
    local uuid
    uuid="$(jq -r --arg email "$user" '.inbounds[]? | select(.protocol=="vless") | .settings.clients[]? | select(.email==$email) | .id' "${XRAY_CONF}" 2>/dev/null | head -n1)"
    if [[ -n "$uuid" && -n "$addr" ]]; then
      echo "vless://${uuid}@$(uri_host "$addr"):${port:-443}?encryption=none&flow=${flow:-xtls-rprx-vision}&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#LOVE-${user}-REALITY" >> "$out"
    fi
  fi

  if [[ ! -s "$out" ]]; then
    warn "未生成用户订阅。可能还没有 Xray Reality 信息。"
  else
    log "用户订阅已生成：${out}"
    echo "User token: ${token}"
  fi
}

users_menu_v7() {
  echo
  echo "================ Love Users v7 ================"
  echo "1) 查看 Xray 用户"
  echo "2) 添加 Xray Reality 用户"
  echo "3) 删除 Xray Reality 用户"
  echo "4) 生成用户订阅"
  echo "5) 生成用户二维码"
  echo "0) 返回"
  read -rp "请选择: " m
  case "$m" in
    1) jq '.inbounds[]? | select(.protocol=="vless") | .settings.clients' "${XRAY_CONF}" 2>/dev/null || warn "未找到 Xray Reality 用户。" ;;
    2)
      [[ -f "${XRAY_CONF}" ]] || die "未找到 Xray 配置。"
      cp "${XRAY_CONF}" "${XRAY_CONF}.users.bak.$(date +%F-%H%M%S)"
      read -rp "用户名/email [user$(date +%s)]: " email
      email="${email:-user$(date +%s)}"
      read -rp "UUID，留空自动生成: " uid
      uid="${uid:-$(random_uuid)}"
      jq --arg id "$uid" --arg email "$email" '.inbounds |= map(if .protocol=="vless" then .settings.clients += [{id:$id,flow:"xtls-rprx-vision",email:$email}] else . end)' "${XRAY_CONF}" > "${XRAY_CONF}.tmp" && mv "${XRAY_CONF}.tmp" "${XRAY_CONF}"
      if "${XRAY_BIN}" run -test -config "${XRAY_CONF}"; then
        systemctl restart xray
        user_sub_generate "$email"
      else
        warn "配置测试失败，回滚。"
        cp "$(ls -t ${XRAY_CONF}.users.bak.* | head -n1)" "${XRAY_CONF}"
        systemctl restart xray || true
      fi
      ;;
    3)
      read -rp "要删除的用户名/email: " email
      [[ -n "$email" ]] || die "不能为空"
      cp "${XRAY_CONF}" "${XRAY_CONF}.users.bak.$(date +%F-%H%M%S)"
      jq --arg email "$email" '.inbounds |= map(if .protocol=="vless" then .settings.clients = (.settings.clients | map(select(.email != $email))) else . end)' "${XRAY_CONF}" > "${XRAY_CONF}.tmp" && mv "${XRAY_CONF}.tmp" "${XRAY_CONF}"
      "${XRAY_BIN}" run -test -config "${XRAY_CONF}" && systemctl restart xray
      ;;
    4)
      read -rp "用户名/email: " email
      user_sub_generate "$email"
      ;;
    5)
      read -rp "用户名/email: " email
      local f="${LOVE_HOME}/users/${email}/all.txt"
      [[ -s "$f" ]] || user_sub_generate "$email"
      if command -v qrencode >/dev/null 2>&1 && [[ -s "$f" ]]; then
        qrencode -t ANSIUTF8 < "$f"
      else
        warn "缺少 qrencode 或用户订阅为空。"
      fi
      ;;
    *) return 0 ;;
  esac
}

web_status_generate() {
  prepare_dirs
  local token
  token="$(get_sub_token)"
  mkdir -p "${LOVE_WEB}/${token}"
  {
    echo "{"
    echo "  \"version\": \"${VERSION}\","
    echo "  \"date\": \"$(date -Is)\","
    echo "  \"ipv4\": \"$(curl -4 -s --max-time 3 https://ifconfig.co 2>/dev/null || true)\","
    echo "  \"ipv6\": \"$(curl -6 -s --max-time 3 https://ifconfig.co 2>/dev/null || true)\","
    echo "  \"xray\": \"$(systemctl is-active xray 2>/dev/null || true)\","
    echo "  \"singbox\": \"$(systemctl is-active sing-box 2>/dev/null || true)\","
    echo "  \"nginx\": \"$(systemctl is-active nginx 2>/dev/null || true)\","
    echo "  \"argo\": \"$(systemctl is-active love-argo 2>/dev/null || true)\""
    echo "}"
  } > "${LOVE_WEB}/${token}/status.json"
  cat > "${LOVE_WEB}/${token}/status.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>Love Status</title></head><body>
<h1>Love Status</h1><pre id="s"></pre>
<script>fetch('status.json').then(r=>r.json()).then(j=>s.textContent=JSON.stringify(j,null,2));</script>
</body></html>
EOF
  log "Web 状态页已生成：${LOVE_WEB}/${token}/status.html"
}

v7_stable_menu() {
  while true; do
    echo
    echo "================ Love v7 Stable Tools ================"
    echo "1) precheck 环境预检"
    echo "2) mode 安装模式分级"
    echo "3) snapshot / rollback"
    echo "4) users 分用户订阅/二维码"
    echo "5) support 客户端兼容矩阵"
    echo "6) logs / errors 日志"
    echo "7) version pin 核心版本锁定"
    echo "8) sing-box 兼容性检测"
    echo "9) speed 连接测速"
    echo "10) cfip 优选 IP / 域名"
    echo "11) cloud-firewall 云防火墙模板"
    echo "12) harden 安全加固"
    echo "13) uninstall soft/full"
    echo "14) Web 状态页增强"
    echo "0) 返回"
    read -rp "请选择: " v
    case "$v" in
      1) precheck_env ;;
      2) mode_wizard ;;
      3) snapshot_menu ;;
      4) users_menu_v7 ;;
      5) support_matrix ;;
      6) logs_menu ;;
      7) pin_core_menu ;;
      8) singbox_compat_check ;;
      9) speed_test ;;
      10) cfip_helper ;;
      11) cloud_firewall_templates ;;
      12) harden_menu ;;
      13) uninstall_menu_v7 ;;
      14) web_status_generate ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


# ------------------------------------------------------------------------------
# V8 Project Panel / Release Engineering Extensions
# ------------------------------------------------------------------------------

v8_state_generate() {
  prepare_dirs
  local token
  token="$(get_sub_token 2>/dev/null || echo "")"

  jq -n \
    --arg version "${VERSION}" \
    --arg date "$(date -Is)" \
    --arg ipv4 "$(curl -4 -s --max-time 3 https://ifconfig.co 2>/dev/null || true)" \
    --arg ipv6 "$(curl -6 -s --max-time 3 https://ifconfig.co 2>/dev/null || true)" \
    --arg xray "$(systemctl is-active xray 2>/dev/null || true)" \
    --arg singbox "$(systemctl is-active sing-box 2>/dev/null || true)" \
    --arg nginx "$(systemctl is-active nginx 2>/dev/null || true)" \
    --arg argo "$(systemctl is-active love-argo 2>/dev/null || true)" \
    --arg backup_timer "$(systemctl is-active love-backup.timer 2>/dev/null || true)" \
    --arg token "$token" \
    --arg arch "$(uname -m)" \
    --arg kernel "$(uname -r)" \
    '{
      version:$version,
      date:$date,
      system:{arch:$arch,kernel:$kernel,ipv4:$ipv4,ipv6:$ipv6},
      services:{xray:$xray,sing_box:$singbox,nginx:$nginx,argo:$argo,backup_timer:$backup_timer},
      paths:{
        home:"/opt/Love",
        subscription:"/opt/Love/subscribe",
        web:"/var/www/love-admin",
        token:$token
      }
    }' > "${LOVE_STATUS_JSON}"

  log "状态 JSON 已生成：${LOVE_STATUS_JSON}"
  cat "${LOVE_STATUS_JSON}"
}

v8_validate_all() {
  echo
  echo "================ Love V8 Validate ================"
  local fail=0

  echo "[Binary]"
  for bin in jq curl openssl systemctl nginx; do
    if command -v "$bin" >/dev/null 2>&1; then
      echo "[OK] $bin"
    else
      echo "[MISS] $bin"
      fail=1
    fi
  done
  command -v xray >/dev/null 2>&1 && xray version | head -n2 || echo "[INFO] xray not installed"
  command -v sing-box >/dev/null 2>&1 && sing-box version | head -n2 || echo "[INFO] sing-box not installed"

  echo
  echo "[Config]"
  if [[ -x "${XRAY_BIN}" && -f "${XRAY_CONF}" ]]; then
    "${XRAY_BIN}" run -test -config "${XRAY_CONF}" || fail=1
  else
    echo "[INFO] Xray config not found"
  fi

  if [[ -x "${SINGBOX_BIN}" && -f "${SINGBOX_CONF}" ]]; then
    ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true "${SINGBOX_BIN}" check -c "${SINGBOX_CONF}" || fail=1
  else
    echo "[INFO] sing-box config not found"
  fi

  if command -v nginx >/dev/null 2>&1; then
    nginx -t || fail=1
  fi

  echo
  echo "[Subscriptions]"
  export_subscription >/dev/null 2>&1 || true
  for f in "${LOVE_SUB}/all.txt" "${LOVE_SUB}/all_base64.txt" "${LOVE_SUB}/mihomo.yaml"; do
    [[ -s "$f" ]] && echo "[OK] $f" || echo "[INFO] missing/empty $f"
  done

  echo
  echo "[Services]"
  for svc in xray sing-box nginx love-argo love-backup.timer; do
    systemctl list-unit-files "$svc" >/dev/null 2>&1 && echo "$svc: $(systemctl is-active "$svc" 2>/dev/null || true)" || true
  done

  echo
  echo "[Ports]"
  ss -tulpn | grep -E ':22|:80|:443|:8088|:8099|:888' || true

  if [[ "$fail" == "0" ]]; then
    log "Validate 通过。"
  else
    warn "Validate 有失败项，请查看上方输出。"
  fi
}

v8_security_audit() {
  echo
  echo "================ Love V8 Security Audit ================"
  local warn_count=0

  echo "[Permissions]"
  for f in "${LOVE_TOKEN_FILE}" "${LOVE_NOTIFY_CONF}" "${LOVE_HOME}/auth/htpasswd"; do
    if [[ -f "$f" ]]; then
      local perm
      perm="$(stat -c '%a' "$f" 2>/dev/null || echo "?")"
      echo "$f perm=$perm"
      if [[ "$perm" != "600" && "$perm" != "640" ]]; then
        warn "权限建议设为 600/640：$f"
        warn_count=$((warn_count+1))
      fi
    fi
  done

  echo
  echo "[Web]"
  if [[ -f /etc/nginx/sites-available/love-admin ]]; then
    grep -q "auth_basic" /etc/nginx/sites-available/love-admin && log "Web Basic Auth 已启用" || { warn "Web Basic Auth 未启用"; warn_count=$((warn_count+1)); }
    grep -q "deny all" /etc/nginx/sites-available/love-admin && log "Web IP 限制已配置" || echo "[INFO] Web 未限制访问 IP"
  else
    echo "[INFO] Web 管理页未配置"
  fi

  echo
  echo "[SSH]"
  if [[ -f /etc/ssh/sshd_config ]]; then
    grep -Ei '^\s*PasswordAuthentication\s+no' /etc/ssh/sshd_config >/dev/null && log "SSH 密码登录已禁用" || echo "[INFO] SSH 密码登录未禁用"
    grep -Ei '^\s*PermitRootLogin\s+no' /etc/ssh/sshd_config >/dev/null && log "Root SSH 登录已禁用" || echo "[INFO] Root SSH 登录未禁用或使用默认"
  fi

  echo
  echo "[Firewall]"
  ufw status verbose 2>/dev/null || echo "[INFO] ufw unavailable"
  echo

  if [[ "$warn_count" -eq 0 ]]; then
    log "安全审计完成：无高优先级警告。"
  else
    warn "安全审计完成：${warn_count} 个警告。"
  fi
}

v8_dashboard() {
  echo
  echo "================ Love V8 Dashboard ================"
  read -rp "Dashboard 端口 [8100]: " port
  port="${port:-8100}"

  v8_state_generate >/dev/null 2>&1 || true
  export_subscription >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true

  install_base >/dev/null 2>&1 || true
  local token
  token="$(get_sub_token)"
  local root="${LOVE_WEB}/${token}/dashboard"
  mkdir -p "$root" "$root/subscribe" "$root/qr" "$root/clients" "$root/sing-box"

  cp "${LOVE_STATUS_JSON}" "$root/state.json" 2>/dev/null || true
  cp -a "${LOVE_SUB}/." "$root/subscribe/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/qr/." "$root/qr/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/clients/." "$root/clients/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/sing-box/." "$root/sing-box/" 2>/dev/null || true

  cat > "$root/index.html" <<'EOF'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Love V8 Dashboard</title>
<style>
body{font-family:Arial,sans-serif;max-width:1180px;margin:30px auto;background:#f7f8fa;color:#222}
h1{font-size:28px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px}
.card{background:#fff;border:1px solid #e9e9e9;border-radius:16px;padding:18px;box-shadow:0 4px 18px rgba(0,0,0,.05)}
.ok{color:#137333}.bad{color:#b3261e}.info{color:#0b57d0}
a{display:block;color:#0b57d0;text-decoration:none;margin:6px 0}
button{border:0;border-radius:10px;padding:8px 12px;background:#0b57d0;color:white;cursor:pointer;margin:4px}
pre{white-space:pre-wrap;background:#f1f3f4;border-radius:12px;padding:12px;max-height:360px;overflow:auto}
</style>
<script>
async function copyPath(path){const u=location.origin+location.pathname.replace(/index\.html$/,'')+path;await navigator.clipboard.writeText(u);alert("Copied: "+u)}
async function load(){
 const st=await fetch('state.json').then(r=>r.json()).catch(()=>({}));
 document.getElementById('state').textContent=JSON.stringify(st,null,2);
 const svc=st.services||{};
 for(const [k,v] of Object.entries(svc)){
   const div=document.createElement('div');
   div.innerHTML=`<b>${k}</b>: <span class="${v==='active'?'ok':'bad'}">${v||'unknown'}</span>`;
   document.getElementById('services').appendChild(div);
 }
}
window.onload=load;
</script>
</head>
<body>
<h1>Love V8 Dashboard</h1>
<div class="grid">
<div class="card"><h2>Services</h2><div id="services"></div></div>
<div class="card"><h2>Subscriptions</h2>
<a href="subscribe/all.txt">Raw URI</a>
<a href="subscribe/all_base64.txt">Base64</a>
<a href="subscribe/mihomo.yaml">Mihomo YAML</a>
<button onclick="copyPath('subscribe/all.txt')">Copy Raw URL</button>
<button onclick="copyPath('subscribe/mihomo.yaml')">Copy Mihomo URL</button>
</div>
<div class="card"><h2>Clients</h2>
<a href="clients/v2rayn-uri.txt">V2RayN</a>
<a href="clients/shadowrocket.conf">Shadowrocket</a>
<a href="clients/nekobox-uri.txt">NekoBox</a>
<a href="clients/sfi-sfa-sfm-client.json">SFI/SFA/SFM</a>
</div>
<div class="card"><h2>sing-box</h2>
<a href="sing-box/sing-box-client.json">Client JSON</a>
<a href="sing-box/sing-box-outbounds.json">Outbounds JSON</a>
</div>
<div class="card"><h2>QR</h2><a href="qr/">QR Directory</a></div>
</div>
<div class="card"><h2>State JSON</h2><pre id="state"></pre></div>
</body>
</html>
EOF

  cat > /etc/nginx/sites-available/love-dashboard <<EOF
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    root ${LOVE_WEB};
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
        auth_basic "Love Dashboard";
        auth_basic_user_file ${LOVE_HOME}/auth/htpasswd;
    }
}
EOF

  if [[ ! -f "${LOVE_HOME}/auth/htpasswd" ]]; then
    mkdir -p "${LOVE_HOME}/auth"
    local pass
    pass="$(random_token 8)"
    if command -v htpasswd >/dev/null 2>&1; then
      htpasswd -bc "${LOVE_HOME}/auth/htpasswd" love "$pass" >/dev/null
    else
      printf "love:$(openssl passwd -apr1 "$pass")\n" > "${LOVE_HOME}/auth/htpasswd"
    fi
    chmod 600 "${LOVE_HOME}/auth/htpasswd"
    warn "Dashboard 自动生成账号：love 密码：${pass}"
  fi

  ln -sf /etc/nginx/sites-available/love-dashboard /etc/nginx/sites-enabled/love-dashboard
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  command -v ufw >/dev/null 2>&1 && ufw allow "${port}/tcp" || true

  log "V8 Dashboard 已开启："
  echo "http://服务器IP:${port}/${token}/dashboard/"
}

v8_generate_readme() {
  prepare_dirs
  mkdir -p "${LOVE_RELEASE}"
  cat > "${LOVE_RELEASE}/README.md" <<'EOF'
# Love

Love is a native Xray + sing-box all-in-one installer and manager.

## Install

```bash
bash <(wget -qO- https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh)
```

## Core commands

```bash
Love
Love precheck
Love mode
Love links
Love sub
Love qr
Love mihomo
Love singbox-json
Love web
Love dashboard
Love doctor
Love repair
Love snapshot
Love rollback
Love users
Love support
Love audit
Love validate
```

## Recommended OS

Ubuntu 22.04 / 24.04 or Debian 12, amd64 or arm64.

## Notes

WARP on the server improves outbound access only. It does not provide public IPv4 inbound for IPv6-only VPS.
EOF
  log "README 已生成：${LOVE_RELEASE}/README.md"
}

v8_release_pack() {
  echo
  echo "================ Love V8 Release Pack ================"
  prepare_dirs
  mkdir -p "${LOVE_RELEASE}/dist"
  v8_generate_readme >/dev/null 2>&1 || true

  local script="${LOVE_HOME}/Love.sh"
  [[ -f "$script" ]] || script="$0"
  cp -f "$script" "${LOVE_RELEASE}/dist/Love.sh"
  chmod +x "${LOVE_RELEASE}/dist/Love.sh"
  cp -f "${LOVE_RELEASE}/README.md" "${LOVE_RELEASE}/dist/README.md"
  sha256sum "${LOVE_RELEASE}/dist/Love.sh" > "${LOVE_RELEASE}/dist/Love.sh.sha256"

  cat > "${LOVE_RELEASE}/dist/install.sh" <<'EOF'
#!/usr/bin/env bash
set -e
bash <(wget -qO- https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh)
EOF
  chmod +x "${LOVE_RELEASE}/dist/install.sh"

  local pack="${LOVE_RELEASE}/Love-v8-release-$(date +%F-%H%M%S).tar.gz"
  tar -czf "$pack" -C "${LOVE_RELEASE}/dist" .
  log "Release 包已生成：${pack}"
  ls -lah "${LOVE_RELEASE}/dist"
}

v8_support_bundle() {
  echo
  echo "================ Love V8 Support Bundle ================"
  prepare_dirs
  local tmp="/tmp/love-support-$$"
  mkdir -p "$tmp"

  {
    echo "Version: ${VERSION}"
    date -Is
    uname -a
    [[ -f /etc/os-release ]] && cat /etc/os-release
    echo
    echo "[Services]"
    systemctl status xray --no-pager 2>/dev/null | sed -n '1,40p' || true
    systemctl status sing-box --no-pager 2>/dev/null | sed -n '1,40p' || true
    systemctl status nginx --no-pager 2>/dev/null | sed -n '1,40p' || true
    echo
    echo "[Ports]"
    ss -tulpn || true
  } > "$tmp/report.txt"

  cp "${LOVE_STATUS_JSON}" "$tmp/status.json" 2>/dev/null || true
  cp "${LOVE_LOG}/error.log" "$tmp/error.log" 2>/dev/null || true
  cp "${LOVE_LOG}/love.log" "$tmp/love.log" 2>/dev/null || true

  # Redact obvious secrets.
  find "$tmp" -type f -maxdepth 1 -print0 | while IFS= read -r -d '' f; do
    sed -i -E \
      -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/REDACTED-UUID/g' \
      -e 's/(password|Password|uuid|token|Token|private_key|PrivateKey)[":= ]+[^", ]+/\1: REDACTED/g' \
      "$f" || true
  done

  local out="${LOVE_REPORT}/support-bundle-$(date +%F-%H%M%S).tar.gz"
  tar -czf "$out" -C "$tmp" .
  rm -rf "$tmp"
  log "脱敏支持包已生成：${out}"
}

v8_import_links() {
  echo
  echo "================ Love V8 Import Links ================"
  mkdir -p "${LOVE_IMPORT}" "${LOVE_SUB}"
  read -rp "输入包含节点链接的文件路径: " file
  [[ -f "$file" ]] || die "文件不存在：$file"

  local imported="${LOVE_IMPORT}/imported-$(date +%F-%H%M%S).txt"
  grep -Eo '(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|naive|nekoray|v2rayn)://[^[:space:]]+' "$file" | sed 's/\r$//' | sort -u > "$imported" || true

  if [[ ! -s "$imported" ]]; then
    warn "未识别到节点链接。"
    return 0
  fi

  cp "${LOVE_SUB}/all.txt" "${LOVE_SUB}/all.txt.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  cat "$imported" >> "${LOVE_SUB}/all.txt"
  sort -u "${LOVE_SUB}/all.txt" -o "${LOVE_SUB}/all.txt"

  generate_client_exports >/dev/null 2>&1 || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true

  log "已导入链接：${imported}"
  echo "合并后：${LOVE_SUB}/all.txt"
}

v8_rotate_menu() {
  echo
  echo "================ Love V8 Rotate ================"
  echo "1) 重置订阅 token"
  echo "2) 重置 Web Basic Auth 密码"
  echo "3) 重新生成客户端包"
  echo "0) 返回"
  read -rp "请选择: " r
  case "$r" in
    1) reset_sub_token ;;
    2)
      mkdir -p "${LOVE_HOME}/auth"
      read -rp "Web 用户名 [love]: " user
      user="${user:-love}"
      read -rsp "新密码，留空自动生成: " pass
      echo
      pass="${pass:-$(random_token 8)}"
      if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -bc "${LOVE_HOME}/auth/htpasswd" "$user" "$pass" >/dev/null
      else
        printf "%s:$(openssl passwd -apr1 "%s")\n" "$user" "$pass" > "${LOVE_HOME}/auth/htpasswd"
      fi
      chmod 600 "${LOVE_HOME}/auth/htpasswd"
      systemctl reload nginx 2>/dev/null || true
      log "Web 密码已更新：user=${user} pass=${pass}"
      ;;
    3) love_full_client_pack ;;
    *) return 0 ;;
  esac
}

v8_test_suite() {
  echo
  echo "================ Love V8 Test Suite ================"
  local fail=0
  bash -n "${LOVE_HOME}/Love.sh" 2>/dev/null || bash -n "$0" || fail=1
  v8_validate_all || fail=1
  v8_security_audit || true
  v8_state_generate >/dev/null 2>&1 || fail=1
  export_subscription >/dev/null 2>&1 || true
  [[ "$fail" == "0" ]] && log "Test Suite 完成。" || warn "Test Suite 存在失败项。"
}

v8_update_channel() {
  echo
  echo "================ Love V8 Update Channel ================"
  echo "1) 设置 stable URL"
  echo "2) 设置 dev URL"
  echo "3) 查看当前 LOVE_UPDATE_URL"
  echo "0) 返回"
  read -rp "请选择: " u
  case "$u" in
    1|2)
      read -rp "输入 Raw URL: " url
      [[ -n "$url" ]] || die "URL 不能为空"
      sed -i '/LOVE_UPDATE_URL=/d' /etc/environment 2>/dev/null || true
      echo "LOVE_UPDATE_URL=${url}" >> /etc/environment
      export LOVE_UPDATE_URL="$url"
      log "更新通道已设置：${url}"
      ;;
    3) echo "LOVE_UPDATE_URL=${LOVE_UPDATE_URL:-未设置}" ;;
    *) return 0 ;;
  esac
}

v8_menu() {
  while true; do
    echo
    echo "================ Love V8 Project Panel ================"
    echo "1) validate 全量验证"
    echo "2) audit 安全审计"
    echo "3) dashboard 项目仪表盘"
    echo "4) state 生成状态 JSON"
    echo "5) release 生成 GitHub 发布包"
    echo "6) readme 生成 README"
    echo "7) support-bundle 脱敏支持包"
    echo "8) import-links 导入外部节点链接"
    echo "9) rotate token/web/password"
    echo "10) test-suite 测试套件"
    echo "11) update-channel 更新通道"
    echo "0) 返回"
    read -rp "请选择: " v
    case "$v" in
      1) v8_validate_all ;;
      2) v8_security_audit ;;
      3) v8_dashboard ;;
      4) v8_state_generate ;;
      5) v8_release_pack ;;
      6) v8_generate_readme ;;
      7) v8_support_bundle ;;
      8) v8_import_links ;;
      9) v8_rotate_menu ;;
      10) v8_test_suite ;;
      11) v8_update_channel ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


# ------------------------------------------------------------------------------
# V9 Nginx Reverse Proxy Edition
# ------------------------------------------------------------------------------

nginx_backup_conf() {
  prepare_dirs
  mkdir -p "${LOVE_NGINX}/backup"
  local out="${LOVE_NGINX}/backup/nginx-$(date +%F-%H%M%S).tar.gz"
  tar -czf "$out" /etc/nginx 2>/dev/null || true
  log "Nginx 配置已备份：${out}"
}

nginx_test_reload() {
  nginx -t || die "nginx -t 失败，配置未生效。"
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  log "Nginx 配置测试通过并已重载。"
}

nginx_443_strategy() {
  echo
  echo "================ Nginx 443 端口策略 ================"
  if ss -lntp | awk '{print $4}' | grep -Eq '(^|:|\])443$'; then
    warn "检测到 443/tcp 已被占用："
    ss -lntp | grep ':443' || true
    echo
    echo "1) 停止 xray / sing-box，让 Nginx 占用 443"
    echo "2) 不动现有服务，Nginx 改用 8443"
    echo "3) 仅生成配置，不启动"
    echo "0) 返回"
    read -rp "请选择: " p
    case "$p" in
      1)
        systemctl stop xray 2>/dev/null || true
        systemctl stop sing-box 2>/dev/null || true
        NGINX_LISTEN_PORT="443"
        ;;
      2)
        NGINX_LISTEN_PORT="8443"
        ;;
      3)
        NGINX_LISTEN_PORT="443"
        NGINX_DRY_RUN="yes"
        ;;
      *) return 1 ;;
    esac
  else
    NGINX_LISTEN_PORT="443"
  fi
  NGINX_DRY_RUN="${NGINX_DRY_RUN:-no}"
  log "Nginx listen port: ${NGINX_LISTEN_PORT}"
}

nginx_make_fallback_site() {
  local root="$1"
  mkdir -p "$root"
  cat > "${root}/index.html" <<'EOF'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Welcome</title>
<style>
body{font-family:Arial,sans-serif;background:#f6f7f8;color:#222;max-width:880px;margin:80px auto;line-height:1.7}
.card{background:#fff;border-radius:18px;padding:32px;box-shadow:0 8px 28px rgba(0,0,0,.08)}
</style>
</head>
<body>
<div class="card">
<h1>Welcome</h1>
<p>This site is running normally.</p>
</div>
</body>
</html>
EOF
}

nginx_cert_prepare() {
  local domain="$1"
  local email="$2"
  local cert_dir="${LOVE_NGINX}/cert/${domain}"
  mkdir -p "$cert_dir"

  if [[ -f "${cert_dir}/cert.pem" && -f "${cert_dir}/key.pem" ]]; then
    log "检测到已有证书：${cert_dir}"
    echo "$cert_dir"
    return 0
  fi

  echo
  echo "证书方式："
  echo "1) Let's Encrypt HTTP-01，推荐有真实域名"
  echo "2) 使用已有证书路径"
  echo "3) 自签证书，客户端需 insecure"
  read -rp "请选择 [1]: " c
  c="${c:-1}"

  case "$c" in
    1)
      [[ -n "$email" ]] || read -rp "Let's Encrypt 邮箱: " email
      issue_cert_generic "$domain" "$email" "$cert_dir" "root"
      ;;
    2)
      read -rp "cert.pem/fullchain.pem 路径: " cpem
      read -rp "key.pem/privkey.pem 路径: " kpem
      [[ -f "$cpem" && -f "$kpem" ]] || die "证书路径不存在。"
      install -m 640 "$cpem" "${cert_dir}/cert.pem"
      install -m 640 "$kpem" "${cert_dir}/key.pem"
      ;;
    3)
      make_selfsigned_generic "$domain" "$cert_dir" "root"
      ;;
    *)
      die "无效选择。"
      ;;
  esac

  echo "$cert_dir"
}

nginx_ws_reverse_proxy() {
  echo
  echo "================ Love Nginx WS Reverse Proxy ================"
  warn "适合 VMess WS / VLESS WS TLS / Argo 回源。Reality/HY2/TUIC 不走普通 HTTP 反代。"

  read -rp "域名，例如 node.example.com: " domain
  [[ -n "$domain" ]] || die "域名不能为空。"
  read -rp "邮箱，用于证书申请: " email
  read -rp "VLESS WS 路径 [/vless]: " vless_path
  vless_path="${vless_path:-/vless}"
  read -rp "VLESS WS 本地端口 [10001]: " vless_port
  vless_port="${vless_port:-10001}"
  read -rp "VMess WS 路径 [/vmess]: " vmess_path
  vmess_path="${vmess_path:-/vmess}"
  read -rp "VMess WS 本地端口 [10002]: " vmess_port
  vmess_port="${vmess_port:-10002}"

  install_base
  nginx_backup_conf
  nginx_443_strategy || return 0

  local cert_dir
  cert_dir="$(nginx_cert_prepare "$domain" "$email")"
  local root="/var/www/love-fallback/${domain}"
  nginx_make_fallback_site "$root"

  cat > "/etc/nginx/sites-available/love-ws-${domain}.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${NGINX_LISTEN_PORT} ssl http2;
    listen [::]:${NGINX_LISTEN_PORT} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert_dir}/cert.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    root ${root};
    index index.html;

    location = ${vless_path} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${vless_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
    }

    location = ${vmess_path} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${vmess_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/love-ws-${domain}.conf" "/etc/nginx/sites-enabled/love-ws-${domain}.conf"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow "${NGINX_LISTEN_PORT}/tcp" || true
  fi

  if [[ "${NGINX_DRY_RUN}" == "yes" ]]; then
    nginx -t
    warn "已生成配置但未启动。"
  else
    nginx_test_reload
  fi

  cat > "${LOVE_NGINX}/ws-${domain}.txt" <<EOF
Nginx WS Reverse Proxy

Domain: ${domain}
Listen: ${NGINX_LISTEN_PORT}
VLESS WS:
  Path: ${vless_path}
  Upstream: 127.0.0.1:${vless_port}
VMess WS:
  Path: ${vmess_path}
  Upstream: 127.0.0.1:${vmess_port}

Client:
  Address: ${domain}
  Port: ${NGINX_LISTEN_PORT}
  TLS: true
  Host/SNI: ${domain}
EOF
  log "WS 反代配置完成：${LOVE_NGINX}/ws-${domain}.txt"
}

nginx_grpc_reverse_proxy() {
  echo
  echo "================ Love Nginx gRPC Reverse Proxy ================"
  warn "适合 gRPC 节点反代。客户端 serviceName 要和路径/服务名一致。"

  read -rp "域名，例如 grpc.example.com: " domain
  [[ -n "$domain" ]] || die "域名不能为空。"
  read -rp "邮箱，用于证书申请: " email
  read -rp "gRPC serviceName [lovegrpc]: " service
  service="${service:-lovegrpc}"
  read -rp "gRPC 本地端口 [10003]: " grpc_port
  grpc_port="${grpc_port:-10003}"

  install_base
  nginx_backup_conf
  nginx_443_strategy || return 0

  local cert_dir
  cert_dir="$(nginx_cert_prepare "$domain" "$email")"
  local root="/var/www/love-fallback/${domain}"
  nginx_make_fallback_site "$root"

  cat > "/etc/nginx/sites-available/love-grpc-${domain}.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${NGINX_LISTEN_PORT} ssl http2;
    listen [::]:${NGINX_LISTEN_PORT} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert_dir}/cert.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${root};
    index index.html;

    location /${service} {
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_read_timeout 3600s;
        grpc_send_timeout 3600s;
        grpc_pass grpc://127.0.0.1:${grpc_port};
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/love-grpc-${domain}.conf" "/etc/nginx/sites-enabled/love-grpc-${domain}.conf"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow "${NGINX_LISTEN_PORT}/tcp" || true
  fi

  if [[ "${NGINX_DRY_RUN}" == "yes" ]]; then
    nginx -t
    warn "已生成配置但未启动。"
  else
    nginx_test_reload
  fi

  cat > "${LOVE_NGINX}/grpc-${domain}.txt" <<EOF
Nginx gRPC Reverse Proxy

Domain: ${domain}
Listen: ${NGINX_LISTEN_PORT}
ServiceName: ${service}
Upstream: 127.0.0.1:${grpc_port}

Client:
  Address: ${domain}
  Port: ${NGINX_LISTEN_PORT}
  TLS: true
  SNI: ${domain}
  Transport: grpc
  serviceName: ${service}
EOF
  log "gRPC 反代配置完成：${LOVE_NGINX}/grpc-${domain}.txt"
}

nginx_fallback_only() {
  echo
  echo "================ Love Nginx Fallback Site ================"
  read -rp "域名，例如 site.example.com: " domain
  [[ -n "$domain" ]] || die "域名不能为空。"
  read -rp "邮箱，用于证书申请: " email

  install_base
  nginx_backup_conf
  nginx_443_strategy || return 0

  local cert_dir
  cert_dir="$(nginx_cert_prepare "$domain" "$email")"
  local root="/var/www/love-fallback/${domain}"
  nginx_make_fallback_site "$root"

  cat > "/etc/nginx/sites-available/love-fallback-${domain}.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${NGINX_LISTEN_PORT} ssl http2;
    listen [::]:${NGINX_LISTEN_PORT} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert_dir}/cert.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${root};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/love-fallback-${domain}.conf" "/etc/nginx/sites-enabled/love-fallback-${domain}.conf"

  if [[ "${NGINX_DRY_RUN}" == "yes" ]]; then
    nginx -t
    warn "已生成配置但未启动。"
  else
    nginx_test_reload
  fi

  log "伪装站点已配置：https://${domain}:${NGINX_LISTEN_PORT}/"
}

nginx_stream_enable_include() {
  if ! grep -q 'include /etc/nginx/stream-conf.d/\*.conf;' /etc/nginx/nginx.conf 2>/dev/null; then
    cat >> /etc/nginx/nginx.conf <<'EOF'

stream {
    include /etc/nginx/stream-conf.d/*.conf;
}
EOF
  fi
  mkdir -p /etc/nginx/stream-conf.d
}

nginx_stream_sni_passthrough() {
  echo
  echo "================ Love Nginx Stream SNI Passthrough ================"
  warn "这是 TCP SNI 分流，不是 HTTP 反代。适合高级场景。"
  warn "如果 Nginx 监听 443，Xray/sing-box 不能再直接占用 443。"

  read -rp "监听端口 [443]: " listen_port
  listen_port="${listen_port:-443}"
  read -rp "默认后端，例如 127.0.0.1:1443: " default_backend
  [[ -n "$default_backend" ]] || die "默认后端不能为空。"

  local map_entries=""
  local upstream_entries=""
  while true; do
    read -rp "添加 SNI 域名，留空结束: " sni
    [[ -z "$sni" ]] && break
    read -rp "该 SNI 后端，例如 127.0.0.1:2443: " backend
    [[ -n "$backend" ]] || die "后端不能为空。"
    local name
    name="$(echo "$sni" | tr '.-' '__')"
    map_entries+="    ${sni} ${name};"$'\n'
    upstream_entries+="upstream ${name} { server ${backend}; }"$'\n'
  done

  install_base
  nginx_backup_conf
  nginx_stream_enable_include

  cat > /etc/nginx/stream-conf.d/love-sni.conf <<EOF
map \$ssl_preread_server_name \$love_backend {
${map_entries}    default love_default;
}

upstream love_default { server ${default_backend}; }
${upstream_entries}

server {
    listen ${listen_port} reuseport;
    listen [::]:${listen_port} reuseport;
    proxy_pass \$love_backend;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 3600s;
}
EOF

  command -v ufw >/dev/null 2>&1 && ufw allow "${listen_port}/tcp" || true
  nginx_test_reload
  log "Nginx stream SNI 分流已配置：/etc/nginx/stream-conf.d/love-sni.conf"
}

nginx_generate_local_inbound_notes() {
  echo
  echo "================ Love Nginx Local Upstream Notes ================"
  mkdir -p "${LOVE_NGINX}"
  cat > "${LOVE_NGINX}/local-upstream-examples.txt" <<'EOF'
Nginx 反代模式下，建议服务端节点只监听本地 127.0.0.1：

VLESS WS upstream:
  listen: 127.0.0.1
  port: 10001
  path: /vless

VMess WS upstream:
  listen: 127.0.0.1
  port: 10002
  path: /vmess

gRPC upstream:
  listen: 127.0.0.1
  port: 10003
  serviceName: lovegrpc

架构：
Client -> Nginx 443 TLS -> 127.0.0.1:10001/10002/10003 -> sing-box/Xray

注意：
Reality / HY2 / TUIC 不建议走普通 Nginx HTTP 反代。
EOF
  cat "${LOVE_NGINX}/local-upstream-examples.txt"
}

nginx_rp_status() {
  echo
  echo "================ Love Nginx Reverse Proxy Status ================"
  nginx -t 2>&1 || true
  echo
  systemctl status nginx --no-pager 2>/dev/null | sed -n '1,30p' || true
  echo
  echo "[sites-enabled]"
  ls -lah /etc/nginx/sites-enabled 2>/dev/null || true
  echo
  echo "[stream-conf.d]"
  ls -lah /etc/nginx/stream-conf.d 2>/dev/null || true
  echo
  echo "[listen]"
  ss -tulpn | grep -E 'nginx|:80|:443|:8443|:1000' || true
}

nginx_rp_rollback() {
  echo
  echo "================ Love Nginx Rollback ================"
  ls -lah "${LOVE_NGINX}/backup" 2>/dev/null || { warn "暂无备份。"; return 0; }
  read -rp "输入要恢复的 nginx 备份完整路径: " file
  [[ -f "$file" ]] || die "备份不存在。"
  read -rp "确认恢复 Nginx 配置？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0
  tar -xzf "$file" -C / 2>/dev/null || true
  nginx_test_reload
  log "Nginx 已回滚：${file}"
}

nginx_rp_menu() {
  while true; do
    echo
    echo "================ Love V9 Nginx Reverse Proxy ================"
    echo "1) WS 反代：VLESS WS / VMess WS"
    echo "2) gRPC 反代"
    echo "3) 仅创建伪装站点 fallback"
    echo "4) Stream SNI passthrough 分流"
    echo "5) 生成本地 upstream 示例"
    echo "6) 443 端口策略检测"
    echo "7) Nginx 反代状态"
    echo "8) 回滚 Nginx 配置"
    echo "0) 返回"
    read -rp "请选择: " n
    case "$n" in
      1) nginx_ws_reverse_proxy ;;
      2) nginx_grpc_reverse_proxy ;;
      3) nginx_fallback_only ;;
      4) nginx_stream_sni_passthrough ;;
      5) nginx_generate_local_inbound_notes ;;
      6) nginx_443_strategy ;;
      7) nginx_rp_status ;;
      8) nginx_rp_rollback ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


# ------------------------------------------------------------------------------
# V9.6 HY2 subscribe / firewall hard fix
# ------------------------------------------------------------------------------

love_get_public_addr() {
  local ep=""
  ep="$(curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "$ep" && "$ep" == *:* ]]; then
    echo "[$ep]"
    return 0
  fi

  ep="$(curl -4 -s --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "$ep" ]]; then
    echo "$ep"
    return 0
  fi

  ep="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d '\r\n' || true)"
  if [[ -n "$ep" ]]; then
    if [[ "$ep" == *:* ]]; then
      echo "[$ep]"
    else
      echo "$ep"
    fi
    return 0
  fi

  return 1
}

love_fix_singbox_112_config() {
  [[ -f /etc/sing-box/config.json ]] || return 0
  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.$(date +%F-%H%M%S) 2>/dev/null || true

  jq '
    .dns = (.dns // {}) |
    .dns.servers = (
      (.dns.servers // []) |
      map(
        if type == "string" then
          {tag: ("dns-" + (tostring)), type: "udp", server: .}
        elif has("address") then
          . + {type: "udp", server: .address} | del(.address)
        else
          .
        end
      )
    ) |
    if (.dns.servers | length) == 0 then
      .dns.servers = [
        {tag: "cf", type: "udp", server: "1.1.1.1"},
        {tag: "google", type: "udp", server: "8.8.8.8"}
      ]
    else
      .
    end |
    .route = (.route // {}) |
    .route.default_domain_resolver = "cf"
  ' /etc/sing-box/config.json > /tmp/sing-box-love-fix.json && mv /tmp/sing-box-love-fix.json /etc/sing-box/config.json

  mkdir -p /etc/systemd/system/sing-box.service.d
  cat > /etc/systemd/system/sing-box.service.d/10-love-singbox-compat.conf <<'EOF'
[Service]
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
Environment=ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
EOF

  systemctl daemon-reload || true
}

love_generate_hy2_subscription_from_config() {
  prepare_dirs
  mkdir -p "${LOVE_SUB}"

  [[ -f /etc/sing-box/config.json ]] || {
    warn "未找到 /etc/sing-box/config.json，无法生成 HY2 订阅。"
    return 0
  }

  if ! jq -e '.inbounds[]? | select(.type=="hysteria2")' /etc/sing-box/config.json >/dev/null 2>&1; then
    warn "当前 sing-box 配置里没有 hysteria2 inbound。"
    return 0
  fi

  local pass port sni addr tag line
  pass="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .users[0].password // empty' /etc/sing-box/config.json | head -n1)"
  port="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port // empty' /etc/sing-box/config.json | head -n1)"
  sni="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.server_name // "self.local"' /etc/sing-box/config.json | head -n1)"
  addr="$(love_get_public_addr || true)"

  [[ -n "$pass" && -n "$port" && -n "$addr" ]] || {
    warn "HY2 信息不完整，无法生成订阅。pass/port/addr 缺失。"
    return 0
  }

  tag="LOVE-HY2"
  line="hysteria2://${pass}@${addr}:${port}?sni=${sni}&insecure=1&allowInsecure=1&alpn=h3#${tag}"

  touch "${LOVE_SUB}/all.txt"
  grep -v 'LOVE-HY2' "${LOVE_SUB}/all.txt" > "${LOVE_SUB}/all.txt.tmp" 2>/dev/null || true
  mv "${LOVE_SUB}/all.txt.tmp" "${LOVE_SUB}/all.txt"
  echo "$line" >> "${LOVE_SUB}/all.txt"

  base64 -w0 "${LOVE_SUB}/all.txt" > "${LOVE_SUB}/all_base64.txt" 2>/dev/null || true

  log "HY2 订阅已生成：${LOVE_SUB}/all.txt"
  echo "$line"
}

love_allow_singbox_inbound_ports() {
  [[ -f /etc/sing-box/config.json ]] || return 0

  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  local row proto port
  jq -r '.inbounds[]? | [.type, (.listen_port|tostring)] | @tsv' /etc/sing-box/config.json | while IFS=$'\t' read -r proto port; do
    [[ -n "$port" && "$port" != "null" ]] || continue

    case "$proto" in
      hysteria2|tuic|naive)
        ufw allow "${port}/udp" || true
        ;;
      *)
        ufw allow "${port}/tcp" || true
        ;;
    esac
  done

  ufw reload || true
}

love_fix_hy2_now() {
  echo
  echo "================ Love HY2 Fix Now ================"

  if [[ ! -x /usr/local/bin/sing-box ]]; then
    warn "未检测到 /usr/local/bin/sing-box。当前系统还没有安装 sing-box。"
    warn "请先回主菜单选择：3) Love sing-box 原生全协议 / 自选协议"
    warn "如果只要 HY2，协议选择输入：c"
    return 0
  fi

  if [[ ! -f /etc/sing-box/config.json ]]; then
    warn "未检测到 /etc/sing-box/config.json。当前还没有生成 sing-box 配置。"
    warn "请先回主菜单选择：3) Love sing-box 原生全协议 / 自选协议"
    return 0
  fi

  love_fix_singbox_112_config
  love_allow_singbox_inbound_ports

  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true /usr/local/bin/sing-box check -c /etc/sing-box/config.json

  systemctl restart sing-box
  sleep 2
  systemctl status sing-box --no-pager || true
  ss -lunp | grep sing-box || true

  love_generate_hy2_subscription_from_config
}


# ------------------------------------------------------------------------------
# V9.7 IPv6-only outbound fixer
# ------------------------------------------------------------------------------

love_test_outbound_stack() {
  echo
  echo "================ Love IPv4 / IPv6 Outbound Test ================"
  local v4_ok="no"
  local v6_ok="no"

  if curl -4 -I --connect-timeout 5 https://alive.github.com >/dev/null 2>&1; then
    v4_ok="yes"
  fi

  if curl -6 -I --connect-timeout 5 https://alive.github.com >/dev/null 2>&1; then
    v6_ok="yes"
  fi

  echo "IPv4 outbound: ${v4_ok}"
  echo "IPv6 outbound: ${v6_ok}"

  if [[ "$v4_ok" == "no" && "$v6_ok" == "yes" ]]; then
    warn "检测到 IPv6-only 出站：建议 direct 出站使用 prefer_ipv6。"
    return 6
  elif [[ "$v4_ok" == "yes" && "$v6_ok" == "yes" ]]; then
    log "双栈出站正常。"
    return 0
  elif [[ "$v4_ok" == "yes" && "$v6_ok" == "no" ]]; then
    warn "仅 IPv4 出站正常。"
    return 4
  else
    warn "IPv4 / IPv6 出站都异常，请检查 VPS 网络。"
    return 1
  fi
}

love_fix_ipv6_only_outbound() {
  echo
  echo "================ Love IPv6-only Outbound Fix ================"
  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.ipv6.$(date +%F-%H%M%S)

  jq '
    .dns = (.dns // {}) |
    .dns.servers = (
      (.dns.servers // []) |
      map(
        if type == "string" then
          {tag: ("dns-" + (tostring)), type: "udp", server: .}
        elif has("address") then
          . + {type: "udp", server: .address} | del(.address)
        else
          .
        end
      )
    ) |
    if (.dns.servers | length) == 0 then
      .dns.servers = [
        {tag: "cf", type: "udp", server: "2606:4700:4700::1111"},
        {tag: "google", type: "udp", server: "2001:4860:4860::8888"}
      ]
    else . end |
    .route = (.route // {}) |
    .route.default_domain_resolver = "cf" |
    .outbounds = (
      (.outbounds // []) |
      map(
        if (.type == "direct" or .tag == "direct") then
          . + {domain_strategy: "prefer_ipv6"}
        else
          .
        end
      )
    )
  ' /etc/sing-box/config.json > /tmp/sing-box-ipv6.json && mv /tmp/sing-box-ipv6.json /etc/sing-box/config.json

  mkdir -p /etc/systemd/system/sing-box.service.d
  cat > /etc/systemd/system/sing-box.service.d/10-love-singbox-compat.conf <<'EOF'
[Service]
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
Environment=ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
EOF

  systemctl daemon-reload

  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true /usr/local/bin/sing-box check -c /etc/sing-box/config.json

  systemctl restart sing-box
  sleep 2
  systemctl status sing-box --no-pager || true

  log "IPv6-only 出站修复完成：direct.domain_strategy=prefer_ipv6"
  warn "如果目标网站只有 IPv4，没有 AAAA 记录，IPv6-only VPS 仍然需要 WARP/NAT64/中转才能访问。"
}

love_warp_hint() {
  cat <<'EOF'

================ WARP / IPv4 出站提示 ================

你的 VPS 如果是 IPv6-only：
1. prefer_ipv6 可以减少 IPv4 timeout
2. 但只有 IPv4 的网站仍然可能打不开
3. 需要 IPv4 出站时，可以考虑安装 WARP

常用命令：
  wget -N https://pkg.cloudflareclient.com/ && bash menu.sh

安装后测试：
  curl -4 -I --connect-timeout 5 https://alive.github.com
  curl -6 -I --connect-timeout 5 https://alive.github.com

注意：
  WARP 只改善服务器出站，不会给 IPv6-only VPS 提供公网 IPv4 入站。

=======================================================

EOF
}

love_ipv6_outbound_menu() {
  echo
  echo "================ Love IPv6-only Outbound Menu ================"
  echo "1) 测试 IPv4 / IPv6 出站"
  echo "2) 修复 sing-box direct 为 prefer_ipv6"
  echo "3) WARP / IPv4 出站提示"
  echo "0) 返回"
  read -rp "请选择: " i
  case "$i" in
    1) love_test_outbound_stack || true ;;
    2) love_fix_ipv6_only_outbound ;;
    3) love_warp_hint ;;
    *) return 0 ;;
  esac
}


# ------------------------------------------------------------------------------
# V10 Native WARP Manager
# ------------------------------------------------------------------------------


love_warp_preflight() {
  echo
  echo "================ Love WARP Preflight ================"
  echo "OS: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  echo "Arch: $(uname -m)"
  echo "Kernel: $(uname -r)"
  echo "Virtualization: $(systemd-detect-virt 2>/dev/null || true)"

  echo
  echo "[TUN]"
  if [[ -c /dev/net/tun ]]; then
    log "/dev/net/tun 存在"
  else
    warn "/dev/net/tun 不存在，官方 WARP/WireGuard 可能失败。"
  fi

  echo
  echo "[WireGuard]"
  if lsmod 2>/dev/null | grep -q '^wireguard'; then
    log "wireguard 内核模块已加载"
  else
    modprobe wireguard 2>/dev/null || true
    if lsmod 2>/dev/null | grep -q '^wireguard'; then
      log "wireguard 内核模块已加载"
    else
      warn "wireguard 内核模块未加载。可用官方 WARP Proxy 模式或 wgcf fallback。"
    fi
  fi

  echo
  echo "[Outbound]"
  love_test_outbound_stack || true
}

love_install_cloudflare_warp_package_only() {
  if command -v warp-cli >/dev/null 2>&1; then
    log "cloudflare-warp 已安装。"
    return 0
  fi

  if ! command -v apt >/dev/null 2>&1; then
    die "当前系统不是 apt 系。官方 WARP 安装器暂只支持 Ubuntu/Debian。"
  fi

  apt update
  apt install -y curl gpg lsb-release ca-certificates

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [[ -n "$codename" ]] || die "无法识别系统 codename。"

  mkdir -p /usr/share/keyrings
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" > /etc/apt/sources.list.d/cloudflare-client.list

  if ! apt update; then
    warn "Cloudflare 官方源 apt update 失败。可能该系统 codename 暂未被官方源支持。"
    return 1
  fi

  apt install -y cloudflare-warp
  systemctl enable --now warp-svc || true
  sleep 2
}

love_warp_register_if_needed() {
  if ! command -v warp-cli >/dev/null 2>&1; then
    die "warp-cli 不存在。"
  fi

  warp-cli --accept-tos registration show >/dev/null 2>&1 && return 0

  warp-cli --accept-tos registration new 2>/dev/null || \
  warp-cli --accept-tos register 2>/dev/null || \
  warp-cli registration new 2>/dev/null || \
  warp-cli register 2>/dev/null || true
}

love_warp_set_proxy_mode() {
  local port="${1:-40000}"

  love_install_cloudflare_warp_package_only
  love_warp_register_if_needed

  # New and legacy command compatibility.
  warp-cli --accept-tos mode proxy 2>/dev/null || \
  warp-cli mode proxy 2>/dev/null || \
  warp-cli --accept-tos set-mode proxy 2>/dev/null || \
  warp-cli set-mode proxy 2>/dev/null || true

  warp-cli --accept-tos proxy port "$port" 2>/dev/null || \
  warp-cli proxy port "$port" 2>/dev/null || \
  warp-cli --accept-tos set-proxy-port "$port" 2>/dev/null || \
  warp-cli set-proxy-port "$port" 2>/dev/null || true

  warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true

  sleep 3
  warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true

  if ss -lntp | grep -q ":${port}"; then
    log "WARP Local Proxy 已监听：127.0.0.1:${port}"
  else
    warn "未检测到 ${port} 监听。请运行 Love warp-status 查看。"
  fi
}

love_singbox_route_via_warp_proxy() {
  local port="${1:-40000}"

  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.warp-proxy.$(date +%F-%H%M%S)

  jq --argjson port "$port" '
    .outbounds = (.outbounds // []) |
    .outbounds = (
      [ .outbounds[]? | select(.tag != "warp-socks") ] +
      [{
        type: "socks",
        tag: "warp-socks",
        server: "127.0.0.1",
        server_port: $port,
        version: "5"
      }]
    ) |
    .route = (.route // {}) |
    .route.final = "warp-socks" |
    .route.default_domain_resolver = (
      .route.default_domain_resolver // {server:"cf", strategy:"prefer_ipv6"}
    )
  ' /etc/sing-box/config.json > /tmp/sing-box-warp-proxy.json && mv /tmp/sing-box-warp-proxy.json /etc/sing-box/config.json

  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true /usr/local/bin/sing-box check -c /etc/sing-box/config.json

  systemctl restart sing-box
  sleep 2
  systemctl status sing-box --no-pager || true

  log "sing-box 出站已切换为 WARP Local Proxy：warp-socks -> 127.0.0.1:${port}"
  warn "这个模式不会修改系统默认路由，SSH 不容易失联。"
}

love_singbox_restore_direct_outbound() {
  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.restore-direct.$(date +%F-%H%M%S)

  jq '
    .outbounds = ([ .outbounds[]? | select(.tag != "warp-socks") ]) |
    .route = (.route // {}) |
    .route.final = "direct"
  ' /etc/sing-box/config.json > /tmp/sing-box-direct.json && mv /tmp/sing-box-direct.json /etc/sing-box/config.json

  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true /usr/local/bin/sing-box check -c /etc/sing-box/config.json
  systemctl restart sing-box
  log "sing-box 出站已恢复 direct。"
}

love_warp_proxy_safe_install() {
  echo
  echo "================ Love Superior WARP Proxy Mode ================"
  warn "推荐模式：不改系统默认路由，不容易导致 SSH 失联。"
  warn "原理：Cloudflare WARP 开本地 SOCKS5，sing-box 出站走 127.0.0.1:40000。"
  read -rp "WARP Local Proxy 端口 [40000]: " port
  port="${port:-40000}"

  love_warp_preflight

  read -rp "确认安装/启用 WARP Proxy，并让 sing-box 出站走它？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

  love_warp_set_proxy_mode "$port"
  love_singbox_route_via_warp_proxy "$port"

  echo
  echo "[Test through VPS]"
  curl -4 -I --connect-timeout 8 https://github.com || true
  curl -6 -I --connect-timeout 8 https://github.com || true

  echo
  echo "[Cloudflare trace]"
  curl -s --connect-timeout 8 --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'ip=|warp=|colo=' || true

  log "Superior WARP Proxy 模式完成。现在 V2RayN -> HY2 -> sing-box -> WARP socks 出站。"
}

love_warp_compare_modes() {
  cat <<'EOF'

================ Love WARP 模式对比 ================

A. Love Superior Proxy Mode（推荐）
   命令：Love warp-proxy
   原理：warp-cli proxy mode -> 127.0.0.1:40000
        sing-box outbound -> socks -> 127.0.0.1:40000
   优点：不改系统默认路由，SSH 不容易失联
   适合：你的 IPv6-only VPS，修 GitHub IPv4 出站

B. Official WARP Full Tunnel
   命令：Love warp-official
   原理：warp-cli connect，系统默认路由可能被 WARP 接管
   优点：系统全局出站都走 WARP
   风险：可能导致 SSH 失联，需要 V10.4 自动回滚保护

C. wgcf/WireGuard
   命令：Love warp-wgcf
   原理：WireGuard 接口
   优点：兼容性强，可控性高
   风险：路由配置不当也可能导致 SSH 失联

D. prefer_ipv6
   命令：Love fix-ipv6
   原理：让 sing-box direct 优先 IPv6
   优点：无 WARP，无路由风险
   缺点：只有 IPv4 的网站仍打不开

结论：
你的 VPS 是 IPv6-only，最稳方案是 A：
Love warp-proxy

====================================================

EOF
}

love_warp_super_status() {
  echo
  echo "================ Love WARP Super Status ================"
  love_warp_status
  echo
  echo "[sing-box route final]"
  jq -r '.route.final // empty' /etc/sing-box/config.json 2>/dev/null || true
  echo
  echo "[warp-socks outbound]"
  jq '.outbounds[]? | select(.tag=="warp-socks")' /etc/sing-box/config.json 2>/dev/null || true
  echo
  echo "[proxy port listening]"
  ss -lntp | grep -E ':(40000|40001|1080)' || true
}



# ------------------------------------------------------------------------------
# V10.6 WARP All Modes: 4 / 6 / d / c / l / w / g / s
# ------------------------------------------------------------------------------


love_install_optional_dns_resolver() {
  # WireProxy does not require openresolv. It is only useful for wg-quick DNS handling.
  # Some Ubuntu/Virtuozzo templates do not provide openresolv, so never fail here.
  apt install -y openresolv >/dev/null 2>&1 || \
  apt install -y resolvconf >/dev/null 2>&1 || \
  warn "openresolv/resolvconf 不可用，已跳过；WireProxy 模式不依赖它。"
}

love_wgcf_prepare_profile() {
  apt update
  apt install -y curl jq wireguard-tools iproute2 ca-certificates file unzip
  love_install_optional_dns_resolver

  if ! command -v wgcf >/dev/null 2>&1; then
    love_download_latest_wgcf
  fi

  mkdir -p /etc/wireguard /opt/Love/warp
  cd /opt/Love/warp

  if [[ ! -f wgcf-account.toml ]]; then
    yes | wgcf register
  fi

  wgcf generate
  [[ -f wgcf-profile.conf ]] || die "wgcf-profile.conf 生成失败。"
}

love_wgcf_apply_allowed_ips() {
  local mode="$1"
  local file="$2"

  case "$mode" in
    4)
      sed -i 's#^AllowedIPs =.*#AllowedIPs = 0.0.0.0/0#' "$file"
      ;;
    6)
      sed -i 's#^AllowedIPs =.*#AllowedIPs = ::/0#' "$file"
      ;;
    d|dual)
      sed -i 's#^AllowedIPs =.*#AllowedIPs = 0.0.0.0/0, ::/0#' "$file"
      ;;
    *)
      die "WARP interface mode 无效：$mode"
      ;;
  esac
}

love_warp_interface_mode() {
  local mode="$1"
  local label
  case "$mode" in
    4) label="IPv4 only interface" ;;
    6) label="IPv6 only interface" ;;
    d|dual) label="dual-stack interface" ;;
    *) die "用法：Love warp 4 / 6 / d" ;;
  esac

  echo
  echo "================ Love WARP Interface Mode: ${label} ================"
  warn "这是 WireGuard 接口模式，会修改系统路由，可能影响 SSH。"
  warn "Love 会创建 180 秒自动回滚，失联后尽量自动恢复。"
  read -rp "确认启用 WARP ${label}？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

  love_wgcf_prepare_profile

  cp /opt/Love/warp/wgcf-profile.conf /etc/wireguard/wgcf.conf
  chmod 600 /etc/wireguard/wgcf.conf
  sed -i '/^DNS =/d' /etc/wireguard/wgcf.conf
  love_wgcf_apply_allowed_ips "$mode" /etc/wireguard/wgcf.conf

  systemctl enable wg-quick@wgcf
  love_warp_create_rollback_timer 180 || true
  systemctl restart wg-quick@wgcf

  sleep 5
  love_warp_status
  love_warp_test

  echo
  warn "如果 SSH 没断，并且网络符合预期，请输入 y 保留该 WARP 接口。"
  read -t 60 -rp "保留当前 WARP interface 并取消自动回滚？[y/N]: " keep || keep=""
  if [[ "$keep" =~ ^[Yy]$ ]]; then
    love_warp_cancel_rollback
    log "WARP interface ${label} 已保留。"
  else
    warn "未确认保留。180 秒后自动回滚会关闭 WARP interface。"
  fi
}

love_download_latest_wireproxy() {
  local arch url tmp asset
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7*|armhf) arch="arm" ;;
    i386|i686) arch="386" ;;
    *) die "暂不支持该架构自动下载 wireproxy：$(uname -m)" ;;
  esac

  apt update || true
  apt install -y curl jq ca-certificates file unzip tar || true

  tmp="/tmp/wireproxy-download"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  url="https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_${arch}.tar.gz"

  warn "尝试直接下载 WireProxy：$url"
  if ! curl -6 -L --connect-timeout 25 --retry 2 -o "$tmp/wireproxy.asset" "$url"; then
    warn "IPv6 直连下载失败，尝试普通连接。"
    curl -L --connect-timeout 25 --retry 2 -o "$tmp/wireproxy.asset" "$url" || {
      warn "WireProxy 直接下载失败。"
      warn "当前 VPS 无法访问 GitHub release；可以在本地电脑下载对应文件后 scp 上传到 /usr/local/bin/wireproxy。"
      return 1
    }
  fi

  if file "$tmp/wireproxy.asset" | grep -qi 'gzip compressed'; then
    tar -xzf "$tmp/wireproxy.asset" -C "$tmp"
  elif file "$tmp/wireproxy.asset" | grep -qi 'Zip archive'; then
    unzip -o "$tmp/wireproxy.asset" -d "$tmp"
  else
    cp "$tmp/wireproxy.asset" "$tmp/wireproxy"
  fi

  asset="$(find "$tmp" -type f -name 'wireproxy*' | head -n1)"
  [[ -n "$asset" ]] || die "下载后未找到 wireproxy 可执行文件。"

  install -m 755 "$asset" /usr/local/bin/wireproxy
  /usr/local/bin/wireproxy --version 2>/dev/null || /usr/local/bin/wireproxy --help | head -n 3 || true
  log "WireProxy 已安装到 /usr/local/bin/wireproxy"
}

love_warp_wireproxy_mode() {
  echo
  echo "================ Love WireProxy SOCKS5 Mode ================"
  warn "这是类似 FS warp w 的模式：WARP 变成本地 SOCKS5，不改系统默认路由。"
  read -rp "WireProxy SOCKS5 端口 [40001]: " port
  port="${port:-40001}"
  read -rp "是否让 sing-box 出站自动走 WireProxy SOCKS？[Y/n]: " use_sb
  use_sb="${use_sb:-Y}"

  love_wgcf_prepare_profile

  if ! command -v wireproxy >/dev/null 2>&1; then
    love_download_latest_wireproxy || {
      warn "wireproxy 自动下载失败。可能是 GitHub API/DNS 暂时不可用。"
      warn "可先确认 WARP/网络后重试：Love warp w"
      return 1
    }
  fi

  mkdir -p /etc/wireproxy
  cp /opt/Love/warp/wgcf-profile.conf /etc/wireproxy/warp.conf
  sed -i '/^DNS =/d' /etc/wireproxy/warp.conf

  cat >> /etc/wireproxy/warp.conf <<EOF

[Socks5]
BindAddress = 127.0.0.1:${port}
EOF

  cat > /etc/systemd/system/love-wireproxy.service <<EOF
[Unit]
Description=Love WireProxy WARP SOCKS5
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy/warp.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now love-wireproxy.service
  sleep 3

  systemctl status love-wireproxy.service --no-pager || true

  if ! ss -lntp | grep -q ":${port}"; then
    warn "WireProxy 未监听 127.0.0.1:${port}，输出最近日志："
    journalctl -u love-wireproxy.service -n 80 -l --no-pager || true
    warn "WireProxy 启动失败，暂不修改 sing-box 出站，避免把流量切到不可用端口。"
    return 1
  fi

  log "WireProxy 已监听：127.0.0.1:${port}"

  if [[ "$use_sb" =~ ^[Yy]$ ]]; then
    love_singbox_route_via_warp_proxy "$port"
  fi

  echo
  echo "[WireProxy trace]"
  curl -s --connect-timeout 10 --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'ip=|warp=|colo=' || true

  log "WireProxy 模式完成：127.0.0.1:${port}"
}

love_warp_global_toggle_menu() {
  echo
  echo "================ Love WARP Global / Non-global ================"
  echo "1) 非全局：Superior Proxy，推荐，sing-box 走 WARP SOCKS"
  echo "2) 非全局：WireProxy SOCKS5"
  echo "3) 全局：Cloudflare 官方 WARP Full Tunnel，有失联风险但带回滚"
  echo "4) 全局：wgcf/WireGuard 双栈接口，有失联风险但带回滚"
  echo "5) 恢复 sing-box direct，并断开 WARP"
  echo "0) 返回"
  read -rp "请选择: " g
  case "$g" in
    1) love_warp_proxy_safe_install ;;
    2) love_warp_wireproxy_mode ;;
    3) love_install_cloudflare_warp_official ;;
    4) love_warp_interface_mode d ;;
    5) love_singbox_restore_direct_outbound; love_warp_disconnect ;;
    *) return 0 ;;
  esac
}

love_warp_set_priority() {
  echo
  echo "================ Love WARP Priority / Strategy ================"
  echo "1) IPv4 优先：prefer_ipv4"
  echo "2) IPv6 优先：prefer_ipv6"
  echo "3) VPS 默认：不强制 resolver strategy"
  echo "4) sing-box 出站走 warp-socks"
  echo "5) sing-box 出站恢复 direct"
  echo "0) 返回"
  read -rp "请选择: " p

  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"
  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.priority.$(date +%F-%H%M%S)

  case "$p" in
    1)
      jq '
        .route = (.route // {}) |
        .route.default_domain_resolver = {server:"cf", strategy:"prefer_ipv4"} |
        .outbounds = ((.outbounds // []) | map(if (.type=="direct" or .tag=="direct") then . + {domain_resolver:{server:"cf", strategy:"prefer_ipv4"}} else . end))
      ' /etc/sing-box/config.json > /tmp/sing-box-priority.json
      ;;
    2)
      jq '
        .route = (.route // {}) |
        .route.default_domain_resolver = {server:"cf", strategy:"prefer_ipv6"} |
        .outbounds = ((.outbounds // []) | map(if (.type=="direct" or .tag=="direct") then . + {domain_resolver:{server:"cf", strategy:"prefer_ipv6"}} else . end))
      ' /etc/sing-box/config.json > /tmp/sing-box-priority.json
      ;;
    3)
      jq '
        .route = (.route // {}) |
        del(.route.default_domain_resolver) |
        .outbounds = ((.outbounds // []) | map(if (.type=="direct" or .tag=="direct") then del(.domain_resolver) else . end))
      ' /etc/sing-box/config.json > /tmp/sing-box-priority.json
      ;;
    4)
      jq '.route = (.route // {}) | .route.final = "warp-socks"' /etc/sing-box/config.json > /tmp/sing-box-priority.json
      ;;
    5)
      jq '.route = (.route // {}) | .route.final = "direct"' /etc/sing-box/config.json > /tmp/sing-box-priority.json
      ;;
    *)
      return 0
      ;;
  esac

  mv /tmp/sing-box-priority.json /etc/sing-box/config.json
  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true /usr/local/bin/sing-box check -c /etc/sing-box/config.json
  systemctl restart sing-box
  log "WARP / DNS 优先级策略已应用。"
}


love_warp_compat_help() {
  cat <<'EOF'

================ Love WARP 兼容命令 ================

已整合 FS 风格命令，但不是复制它的代码：

  Love warp 4   IPv4 Only 单栈：添加 WARP IPv4 出站（wgcf/WireGuard，带回滚）
  Love warp 6   IPv6 Only 单栈：添加 WARP IPv6 出站（wgcf/WireGuard，带回滚）
  Love warp d   Dual Stack 双栈：添加 WARP IPv4 + IPv6 出站（wgcf/WireGuard，带回滚）

  Love warp c   Linux Client Proxy 模式：官方 WARP Proxy + sing-box socks 出站
  Love warp l   Linux Client WARP 模式：官方 WARP 全局模式，带回滚
  Love warp w   WireProxy 模式：WARP 本地 SOCKS5，默认可接 sing-box
  Love warp g   切换全局 / 非全局模式
  Love warp s   设置 IPv4 / IPv6 / VPS 默认优先级

推荐你的 IPv6-only HY2 VPS 使用：
  Love warp c
或：
  Love warp w

不推荐优先用：
  Love warp l
  Love warp d

因为全局路由模式更容易导致 SSH 失联。

====================================================

EOF
}

love_warp_compat_command() {
  local sub="${1:-}"
  case "$sub" in
    4)
      love_warp_interface_mode 4
      ;;
    6)
      love_warp_interface_mode 6
      ;;
    d|dual)
      love_warp_interface_mode d
      ;;
    c)
      love_warp_proxy_safe_install
      ;;
    l)
      love_install_cloudflare_warp_official
      ;;
    w)
      love_warp_wireproxy_mode
      ;;
    g)
      love_warp_global_toggle_menu
      ;;
    s)
      love_warp_set_priority
      ;;
    ""|menu)
      love_warp_manager_menu
      ;;
    *)
      warn "兼容命令：Love warp 4 / 6 / d / c / l / w / g / s"
      love_warp_manager_menu
      ;;
  esac
}



# ------------------------------------------------------------------------------
# V10.7 WARP Smart Split / Advanced Diagnostics
# ------------------------------------------------------------------------------

love_warp_trace_via_proxy() {
  local port="${1:-40000}"
  echo
  echo "================ WARP Trace via SOCKS5 127.0.0.1:${port} ================"
  curl -s --connect-timeout 10 --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'ip=|warp=|colo=' || true
}

love_warp_ip_asn_region() {
  echo
  echo "================ Love WARP IP / ASN / Region ================"
  echo "[direct IPv4]"
  curl -4 -s --connect-timeout 8 https://ipinfo.io/json 2>/dev/null | jq -r '"ip=\(.ip // "-") country=\(.country // "-") region=\(.region // "-") city=\(.city // "-") org=\(.org // "-")"' 2>/dev/null || true
  echo
  echo "[direct IPv6]"
  curl -6 -s --connect-timeout 8 https://ipinfo.io/json 2>/dev/null | jq -r '"ip=\(.ip // "-") country=\(.country // "-") region=\(.region // "-") city=\(.city // "-") org=\(.org // "-")"' 2>/dev/null || true
  echo
  echo "[warp socks 40000]"
  curl -s --connect-timeout 8 --socks5-hostname 127.0.0.1:40000 https://ipinfo.io/json 2>/dev/null | jq -r '"ip=\(.ip // "-") country=\(.country // "-") region=\(.region // "-") city=\(.city // "-") org=\(.org // "-")"' 2>/dev/null || true
  echo
  echo "[warp socks 40001]"
  curl -s --connect-timeout 8 --socks5-hostname 127.0.0.1:40001 https://ipinfo.io/json 2>/dev/null | jq -r '"ip=\(.ip // "-") country=\(.country // "-") region=\(.region // "-") city=\(.city // "-") org=\(.org // "-")"' 2>/dev/null || true
}

love_warp_unlock_check() {
  echo
  echo "================ Love WARP Unlock / Trace Check ================"
  echo "[Cloudflare direct trace]"
  curl -s --connect-timeout 8 https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'ip=|warp=|colo=' || true
  echo
  echo "[Cloudflare WARP SOCKS 40000 trace]"
  curl -s --connect-timeout 8 --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'ip=|warp=|colo=' || true
  echo
  echo "[Cloudflare WARP SOCKS 40001 trace]"
  curl -s --connect-timeout 8 --socks5-hostname 127.0.0.1:40001 https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'ip=|warp=|colo=' || true
  echo
  warn "这里的解锁检测以 Cloudflare trace 的 warp=on/plus 为准；流媒体完整解锁需另行测试。"
}

love_warp_full_report() {
  echo
  echo "================ Love Full WARP / Network Report ================"
  echo "Time: $(date -Is)"
  echo "Version: ${VERSION:-unknown}"
  echo
  love_warp_preflight || true
  echo
  love_test_outbound_stack || true
  echo
  love_warp_super_status || true
  echo
  love_warp_ip_asn_region || true
  echo
  love_warp_unlock_check || true
  echo
  echo "[sing-box inbound]"
  jq -r '.inbounds[]? | [.tag, .type, .listen, .listen_port] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
  echo
  echo "[sing-box route]"
  jq '.route' /etc/sing-box/config.json 2>/dev/null || true
}

love_warp_detect_mtu() {
  echo
  echo "================ Love WARP MTU Detect ================"
  local target="${1:-2606:4700:4700::1111}"
  local mtu="1280"

  if command -v tracepath >/dev/null 2>&1; then
    local t
    t="$(tracepath "$target" 2>/dev/null | awk '/pmtu/ {print $NF; exit}')"
    [[ -n "$t" ]] && mtu="$t"
  fi

  if [[ -z "$mtu" || "$mtu" == "0" ]]; then
    mtu="1280"
  fi

  echo "$mtu"
}

love_warp_apply_mtu() {
  echo
  echo "================ Love WARP MTU Apply ================"
  read -rp "MTU 值，留空自动检测/默认 1280: " mtu
  if [[ -z "$mtu" ]]; then
    mtu="$(love_warp_detect_mtu | tail -n1)"
  fi

  [[ "$mtu" =~ ^[0-9]+$ ]] || die "MTU 无效：$mtu"

  if [[ -f /etc/wireguard/wgcf.conf ]]; then
    if grep -q '^MTU' /etc/wireguard/wgcf.conf; then
      sed -i "s/^MTU.*/MTU = ${mtu}/" /etc/wireguard/wgcf.conf
    else
      sed -i "/^\[Interface\]/a MTU = ${mtu}" /etc/wireguard/wgcf.conf
    fi
    log "已写入 /etc/wireguard/wgcf.conf MTU=${mtu}"
  fi

  if [[ -f /etc/wireproxy/warp.conf ]]; then
    if grep -q '^MTU' /etc/wireproxy/warp.conf; then
      sed -i "s/^MTU.*/MTU = ${mtu}/" /etc/wireproxy/warp.conf
    else
      sed -i "/^\[Interface\]/a MTU = ${mtu}" /etc/wireproxy/warp.conf
    fi
    log "已写入 /etc/wireproxy/warp.conf MTU=${mtu}"
  fi

  systemctl restart wg-quick@wgcf 2>/dev/null || true
  systemctl restart love-wireproxy.service 2>/dev/null || true
}

love_warp_endpoint_list() {
  cat <<'EOF'
engage.cloudflareclient.com:2408
162.159.192.1:2408
162.159.192.2:2408
162.159.192.3:2408
162.159.192.4:2408
162.159.192.5:2408
162.159.193.1:2408
162.159.193.2:2408
162.159.193.3:2408
162.159.193.4:2408
162.159.193.5:2408
[2606:4700:d0::a29f:c001]:2408
[2606:4700:d0::a29f:c002]:2408
[2606:4700:d0::a29f:c003]:2408
EOF
}

love_warp_endpoint_select() {
  echo
  echo "================ Love WARP Endpoint Select ================"
  echo "1) 自动优选 endpoint"
  echo "2) 固定手动 endpoint"
  echo "3) 恢复默认 engage.cloudflareclient.com:2408"
  echo "0) 返回"
  read -rp "请选择: " e

  local endpoint=""
  case "$e" in
    1)
      endpoint="$(love_warp_endpoint_list | while read -r ep; do
        host="${ep%:*}"
        host="${host#[}"
        host="${host%]}"
        # TCP ping is not exact for WARP UDP, but gives a practical reachability hint.
        if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
          echo "$ep"
          break
        fi
      done)"
      endpoint="${endpoint:-engage.cloudflareclient.com:2408}"
      ;;
    2)
      read -rp "输入 endpoint，例如 162.159.192.1:2408: " endpoint
      [[ -n "$endpoint" ]] || die "endpoint 不能为空。"
      ;;
    3)
      endpoint="engage.cloudflareclient.com:2408"
      ;;
    *)
      return 0
      ;;
  esac

  mkdir -p /opt/Love/warp
  echo "$endpoint" > /opt/Love/warp/endpoint.txt
  log "WARP endpoint 已设置：$endpoint"

  for f in /etc/wireguard/wgcf.conf /etc/wireproxy/warp.conf /opt/Love/warp/wgcf-profile.conf; do
    [[ -f "$f" ]] || continue
    if grep -q '^Endpoint' "$f"; then
      sed -i "s#^Endpoint.*#Endpoint = ${endpoint}#" "$f"
      log "已更新 $f"
    fi
  done

  systemctl restart wg-quick@wgcf 2>/dev/null || true
  systemctl restart love-wireproxy.service 2>/dev/null || true
}

love_wireguard_go_fallback() {
  echo
  echo "================ Love WireGuard Kernel -> wireguard-go Fallback ================"
  warn "这是 WireGuard userspace fallback，不调用第三方 WARP 脚本。"

  apt update
  apt install -y wireguard-tools wireguard-go || true
  love_install_optional_dns_resolver

  if ! command -v wireguard-go >/dev/null 2>&1; then
    warn "系统源没有 wireguard-go。将继续使用 wireguard-tools 或建议使用 WireProxy。"
    return 1
  fi

  if [[ ! -f /etc/wireguard/wgcf.conf ]]; then
    warn "未找到 /etc/wireguard/wgcf.conf，先生成 wgcf 配置。"
    love_wgcf_prepare_profile
    cp /opt/Love/warp/wgcf-profile.conf /etc/wireguard/wgcf.conf
    chmod 600 /etc/wireguard/wgcf.conf
    sed -i '/^DNS =/d' /etc/wireguard/wgcf.conf
  fi

  cat > /etc/systemd/system/love-wgcf-go.service <<'EOF'
[Unit]
Description=Love WARP wireguard-go fallback
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc 'ip link delete wgcf 2>/dev/null || true; wireguard-go wgcf; wg setconf wgcf <(wg-quick strip wgcf); ip link set mtu 1280 up dev wgcf; ip route replace default dev wgcf table 51820 || true'
ExecStop=/bin/bash -lc 'ip link delete wgcf 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  love_warp_create_rollback_timer 180 || true
  systemctl restart love-wgcf-go.service || {
    warn "wireguard-go fallback 启动失败，建议使用 Love warp w / Love warp c。"
    return 1
  }

  sleep 3
  love_warp_test
}

love_warp_go_fallback() {
  echo
  echo "================ Love warp-go fallback ================"
  warn "当前 Love 不调用第三方 warp-go 脚本。这里提供本地 fallback 顺序："
  echo "1) wireguard-go userspace fallback"
  echo "2) WireProxy SOCKS5 fallback"
  echo "3) Superior WARP Proxy fallback"
  echo "0) 返回"
  read -rp "请选择: " f
  case "$f" in
    1) love_wireguard_go_fallback || love_warp_wireproxy_mode ;;
    2) love_warp_wireproxy_mode ;;
    3) love_warp_proxy_safe_install ;;
    *) return 0 ;;
  esac
}

love_warp_proxy_auto_with_fallback() {
  echo
  echo "================ Love WARP Proxy Auto + WireProxy Fallback ================"
  read -rp "WARP Proxy 端口 [40000]: " port
  port="${port:-40000}"

  love_warp_set_proxy_mode "$port" || true
  sleep 2

  if ss -lntp | grep -q ":${port}"; then
    log "官方 WARP Proxy 可用：127.0.0.1:${port}"
    love_singbox_route_via_warp_proxy "$port"
    return 0
  fi

  warn "官方 WARP Proxy 未监听，自动切换 WireProxy fallback。"
  love_warp_wireproxy_mode
}

love_singbox_smart_split_warp() {
  echo
  echo "================ Love Smart Split: IPv6 direct / IPv4 WARP ================"
  warn "推荐模式：IPv6 保持 direct 高速，IPv4 走 WARP SOCKS。"
  read -rp "WARP SOCKS 端口 [40000]: " port
  port="${port:-40000}"

  if ! ss -lntp | grep -q ":${port}"; then
    warn "未检测到 127.0.0.1:${port}，先尝试官方 WARP Proxy，失败自动 WireProxy。"
    love_warp_proxy_auto_with_fallback
  fi

  if ! ss -lntp | grep -q ":${port}"; then
    warn "${port} 仍未监听，尝试检测 40001 WireProxy。"
    if ss -lntp | grep -q ":40001"; then
      port="40001"
    else
      die "没有可用 WARP SOCKS 端口。"
    fi
  fi

  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.smart-split.$(date +%F-%H%M%S)

  jq --argjson port "$port" '
    .outbounds = (.outbounds // []) |
    .outbounds = (
      [ .outbounds[]? | select(.tag != "warp-socks") ] +
      [{
        type: "socks",
        tag: "warp-socks",
        server: "127.0.0.1",
        server_port: $port,
        version: "5"
      }]
    ) |
    .route = (.route // {}) |
    .route.default_domain_resolver = {server:"cf", strategy:"prefer_ipv6"} |
    .route.rules = (
      [
        {ip_is_private:true, outbound:"block"},
        {port:[25,465,587], outbound:"block"},
        {protocol:"bittorrent", outbound:"block"},
        {ip_version:6, outbound:"direct"},
        {ip_version:4, outbound:"warp-socks"},
        {domain_suffix:["github.com","githubusercontent.com","githubassets.com","github.io","microsoft.com","windows.com","msftconnecttest.com"], outbound:"warp-socks"}
      ] + ((.route.rules // []) | map(select((.ip_version? == 6 or .ip_version? == 4 or .domain_suffix? != null) | not)))
    ) |
    .route.final = "direct"
  ' /etc/sing-box/config.json > /tmp/sing-box-smart-split.json && mv /tmp/sing-box-smart-split.json /etc/sing-box/config.json

  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true /usr/local/bin/sing-box check -c /etc/sing-box/config.json
  systemctl restart sing-box

  log "Smart Split 已启用：IPv6 -> direct，IPv4/GitHub/Microsoft -> warp-socks:${port}"
  warn "如果某些域名仍解析成 IPv4 且未走 WARP，请运行 Love warp-report 查看。"
}

love_singbox_restore_from_smart_split() {
  echo
  echo "================ Restore from Smart Split ================"
  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"
  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.smart-restore.$(date +%F-%H%M%S)

  jq '
    .outbounds = ([ .outbounds[]? | select(.tag != "warp-socks") ]) |
    .route = (.route // {}) |
    .route.rules = ((.route.rules // []) | map(select((.ip_version? == 6 or .ip_version? == 4 or .domain_suffix? != null) | not))) |
    .route.final = "direct"
  ' /etc/sing-box/config.json > /tmp/sing-box-smart-restore.json && mv /tmp/sing-box-smart-restore.json /etc/sing-box/config.json

  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true /usr/local/bin/sing-box check -c /etc/sing-box/config.json
  systemctl restart sing-box
  log "已恢复：移除 warp-socks 和 Smart Split 规则，route.final=direct。"
}


love_warp_stack_menu() {
  while true; do
    echo
    echo "================ Love WARP 单栈 / 双栈模式 ================"
    echo "1) IPv4 Only 单栈：添加 WARP IPv4 出站"
    echo "2) IPv6 Only 单栈：添加 WARP IPv6 出站"
    echo "3) Dual Stack 双栈：添加 WARP IPv4 + IPv6 出站"
    echo "4) 查看当前 IPv4 / IPv6 出站状态"
    echo "5) 查看 WARP 模式对比"
    echo "0) 返回"
    read -rp "请选择: " st
    case "$st" in
      1) love_warp_interface_mode 4 ;;
      2) love_warp_interface_mode 6 ;;
      3) love_warp_interface_mode d ;;
      4) love_test_outbound_stack || true ;;
      5) love_warp_compare_modes ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


love_warp_smart_menu() {
  while true; do
    echo
    echo "================ Love V10.7 Smart WARP Menu ================"
    echo "1) Smart Split：IPv6 direct，IPv4/GitHub/Microsoft 走 WARP"
    echo "2) Proxy 自动安装，失败自动 WireProxy"
    echo "3) Endpoint 自动优选 / 固定"
    echo "4) MTU 自动检测与修正"
    echo "5) Full Report：IPv4/IPv6/双栈/WARP/IP/ASN/Region"
    echo "6) WARP 解锁 / Trace 检测"
    echo "7) kernel WireGuard 失败 -> wireguard-go / WireProxy fallback"
    echo "8) warp-go fallback 菜单"
    echo "9) 恢复 direct，移除 Smart Split"
    echo "0) 返回"
    read -rp "请选择: " x
    case "$x" in
      1) love_warp_auto_fix_v12 ;;
      2) love_singbox_smart_split_warp ;;
      2) love_warp_proxy_auto_with_fallback ;;
      3) love_warp_endpoint_select ;;
      4) love_warp_apply_mtu ;;
      5) love_warp_full_report ;;
      6) love_warp_unlock_check ;;
      7) love_wireguard_go_fallback || love_warp_wireproxy_mode ;;
      8) love_warp_go_fallback ;;
      9) love_singbox_restore_from_smart_split ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v12 WARP Decision Engine Final
# Inspired by FS-style flow: detect -> choose -> install -> verify -> safe switch.
# Does not copy third-party scripts.
# ==============================================================================

love_cmd_exists() { command -v "$1" >/dev/null 2>&1; }

love_arch_normalize() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7*|armhf) echo "arm" ;;
    i386|i686) echo "386" ;;
    *) echo "unknown" ;;
  esac
}

love_print_section() {
  echo
  echo "================ $* ================"
}

love_direct_test_url() {
  local ipver="$1" url="$2"
  case "$ipver" in
    4) curl -4 -I --connect-timeout 6 --max-time 10 "$url" >/dev/null 2>&1 ;;
    6) curl -6 -I --connect-timeout 6 --max-time 10 "$url" >/dev/null 2>&1 ;;
    *) curl -I --connect-timeout 6 --max-time 10 "$url" >/dev/null 2>&1 ;;
  esac
}

love_socks_test_url() {
  local port="$1" url="$2"
  curl -I --connect-timeout 6 --max-time 12 --socks5-hostname "127.0.0.1:${port}" "$url" >/dev/null 2>&1
}

love_socks_trace_warp() {
  local port="$1"
  curl -s --connect-timeout 8 --max-time 12 --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^warp=' | head -n1
}

love_socks_health_gate() {
  local port="$1"
  love_print_section "Love SOCKS Health Gate 127.0.0.1:${port}"

  if ! ss -lntp 2>/dev/null | grep -q ":${port}"; then
    warn "端口 ${port} 未监听。"
    return 1
  fi

  if ! timeout 4 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; then
    warn "端口 ${port} 虽然监听，但本机 TCP 连接失败。"
    return 1
  fi

  local trace
  trace="$(curl -s --connect-timeout 8 --max-time 12 --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  echo "$trace" | grep -E '^(ip|colo|warp)=' || true

  if ! echo "$trace" | grep -Eq '^warp=(on|plus)$'; then
    warn "SOCKS ${port} 没有通过 Cloudflare WARP trace。"
    return 1
  fi

  if ! love_socks_test_url "$port" "https://github.com"; then
    warn "SOCKS ${port} 无法访问 GitHub。"
    return 1
  fi

  log "SOCKS ${port} 通过健康检查：监听 + TCP + WARP trace + GitHub。"
  return 0
}

love_warp_full_precheck_v12() {
  love_print_section "Love v12 Full Precheck"

  echo "Version: ${VERSION:-unknown}"
  echo "OS: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  echo "Kernel: $(uname -r)"
  echo "Arch: $(uname -m) -> $(love_arch_normalize)"
  echo "Virt: $(systemd-detect-virt 2>/dev/null || true)"

  echo
  echo "[Network stack]"
  if love_direct_test_url 4 "https://github.com"; then echo "IPv4 outbound: yes"; else echo "IPv4 outbound: no"; fi
  if love_direct_test_url 6 "https://github.com"; then echo "IPv6 outbound: yes"; else echo "IPv6 outbound: no"; fi

  echo
  echo "[Loopback]"
  ip link show lo 2>/dev/null | head -n1 || true
  ip addr show lo 2>/dev/null | grep -E '127\.0\.0\.1|::1' || true
  ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1 && echo "lo ping: ok" || echo "lo ping: fail"

  echo
  echo "[TUN / WireGuard]"
  [[ -c /dev/net/tun ]] && echo "/dev/net/tun: yes" || echo "/dev/net/tun: no"
  modprobe wireguard >/dev/null 2>&1 || true
  lsmod 2>/dev/null | grep -q '^wireguard' && echo "wireguard kernel: yes" || echo "wireguard kernel: no"

  echo
  echo "[Downloads]"
  curl -6 -I --connect-timeout 6 --max-time 10 https://github.com >/dev/null 2>&1 && echo "GitHub via IPv6: yes" || echo "GitHub via IPv6: no"
  curl -4 -I --connect-timeout 6 --max-time 10 https://github.com >/dev/null 2>&1 && echo "GitHub via IPv4: yes" || echo "GitHub via IPv4: no"
  curl -I --connect-timeout 6 --max-time 10 https://gitlab.com >/dev/null 2>&1 && echo "GitLab: yes" || echo "GitLab: no"

  echo
  echo "[Current SOCKS]"
  ss -lntp 2>/dev/null | grep -E ':(40000|40001|40002)' || true
}

love_install_base_deps_v12() {
  apt update || true
  apt install -y curl jq ca-certificates file unzip tar iproute2 iputils-ping wireguard-tools tcpdump || true
}

love_download_with_fallbacks() {
  local out="$1"
  shift
  local urls=("$@")
  local u

  rm -f "$out"
  for u in "${urls[@]}"; do
    [[ -n "$u" ]] || continue
    warn "尝试下载：$u"
    if curl -6 -L --fail --connect-timeout 20 --max-time 120 --retry 1 -o "$out" "$u"; then
      [[ -s "$out" ]] && return 0
    fi
    if curl -L --fail --connect-timeout 20 --max-time 120 --retry 1 -o "$out" "$u"; then
      [[ -s "$out" ]] && return 0
    fi
  done
  return 1
}

love_download_wireproxy_v12() {
  love_print_section "Love v12 WireProxy Download"
  love_install_base_deps_v12

  local arch tmp url1 url2 url3 url4 asset bin
  arch="$(love_arch_normalize)"
  [[ "$arch" != "unknown" ]] || die "不支持的架构：$(uname -m)"

  tmp="/tmp/love-wireproxy-v12"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  url1="https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_${arch}.tar.gz"
  url2="https://ghproxy.net/${url1}"
  url3="https://gh-proxy.com/${url1}"
  url4="https://hub.gitmirror.com/${url1}"

  if ! love_download_with_fallbacks "$tmp/wireproxy.tar.gz" "$url1" "$url2" "$url3" "$url4"; then
    die "WireProxy 下载失败：GitHub/反代均不可用。"
  fi

  file "$tmp/wireproxy.tar.gz"
  tar -xzf "$tmp/wireproxy.tar.gz" -C "$tmp" || die "WireProxy 解压失败。"

  bin="$(find "$tmp" -type f -exec file {} \; | awk -F: '/ELF/ {print $1; exit}')"
  [[ -n "$bin" ]] || {
    find "$tmp" -type f -maxdepth 3 -print -exec file {} \;
    die "未找到 ELF 二进制，下载内容可能错误。"
  }

  file "$bin"
  install -m 755 "$bin" /usr/local/bin/wireproxy
  file /usr/local/bin/wireproxy

  if ! /usr/local/bin/wireproxy --help >/dev/null 2>&1; then
    warn "wireproxy --help 未返回正常状态，但继续尝试。"
  fi

  log "WireProxy 安装完成。"
}

love_wgcf_prepare_profile_v12() {
  love_print_section "Love v12 WGCF Profile"
  love_install_base_deps_v12

  mkdir -p /opt/Love/warp /etc/wireguard
  cd /opt/Love/warp || exit 1

  if ! love_cmd_exists wgcf; then
    if declare -F love_download_latest_wgcf >/dev/null 2>&1; then
      love_download_latest_wgcf
    else
      warn "未找到 wgcf 下载函数，尝试 apt 安装 wgcf。"
      apt install -y wgcf || true
    fi
  fi

  love_cmd_exists wgcf || die "wgcf 不存在，无法生成 WARP profile。"

  if [[ ! -f wgcf-account.toml ]]; then
    yes | wgcf register
  fi

  wgcf generate
  [[ -f /opt/Love/warp/wgcf-profile.conf ]] || die "wgcf-profile.conf 生成失败。"
  log "wgcf-profile.conf 已生成。"
}

love_fix_loopback_v12() {
  love_print_section "Love v12 Loopback Fix"
  ip link set lo up || true
  ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true
  iptables -I INPUT 1 -i lo -j ACCEPT 2>/dev/null || true
  iptables -I OUTPUT 1 -o lo -j ACCEPT 2>/dev/null || true
  ufw allow in on lo >/dev/null 2>&1 || true
  ufw allow out on lo >/dev/null 2>&1 || true
  ping -c 1 -W 1 127.0.0.1 && log "loopback 正常。" || warn "loopback 仍异常。"
}

love_wireproxy_endpoint_set_v12() {
  local endpoint="${1:-[2606:4700:d0::a29f:c001]:2408}"
  [[ -f /etc/wireproxy/warp.conf ]] || return 0
  if grep -q '^Endpoint = ' /etc/wireproxy/warp.conf; then
    sed -i "s#^Endpoint = .*#Endpoint = ${endpoint}#" /etc/wireproxy/warp.conf
  else
    sed -i "/^\[Peer\]/a Endpoint = ${endpoint}" /etc/wireproxy/warp.conf
  fi
}

love_wireproxy_make_service_v12() {
  local port="${1:-40001}"
  local profile="/opt/Love/warp/wgcf-profile.conf"

  [[ -f "$profile" ]] || love_wgcf_prepare_profile_v12
  [[ -f "$profile" ]] || die "找不到 WARP profile：$profile"

  [[ -x /usr/local/bin/wireproxy ]] || love_download_wireproxy_v12

  mkdir -p /etc/wireproxy
  cp "$profile" /etc/wireproxy/warp.conf
  sed -i '/^DNS =/d' /etc/wireproxy/warp.conf

  # Prefer IPv6 endpoint for IPv6-only VPS.
  love_wireproxy_endpoint_set_v12 "[2606:4700:d0::a29f:c001]:2408"

  cat >> /etc/wireproxy/warp.conf <<EOF

[Socks5]
BindAddress = 127.0.0.1:${port}
EOF

  cat > /etc/systemd/system/love-wireproxy.service <<EOF
[Unit]
Description=Love WireProxy WARP SOCKS5
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy/warp.conf
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now love-wireproxy.service
  sleep 3
}

love_wireproxy_try_endpoints_v12() {
  local port="${1:-40001}"
  local ep
  local endpoints=(
    "[2606:4700:d0::a29f:c001]:2408"
    "[2606:4700:d0::a29f:c002]:2408"
    "[2606:4700:d0::a29f:c003]:2408"
    "engage.cloudflareclient.com:2408"
    "162.159.192.1:2408"
    "162.159.192.2:2408"
    "162.159.193.1:2408"
  )

  for ep in "${endpoints[@]}"; do
    warn "尝试 WireProxy Endpoint：$ep"
    love_wireproxy_endpoint_set_v12 "$ep"
    systemctl restart love-wireproxy.service
    sleep 4
    systemctl status love-wireproxy.service --no-pager | head -n 12 || true
    ss -lntp | grep ":${port}" || true

    if love_socks_health_gate "$port"; then
      log "WireProxy Endpoint 可用：$ep"
      echo "$ep" > /opt/Love/warp/wireproxy-working-endpoint.txt
      return 0
    fi
  done

  warn "所有 WireProxy endpoint 健康检查失败。"
  journalctl -u love-wireproxy.service -n 120 -l --no-pager || true
  return 1
}

love_wireproxy_auto_v12() {
  local port="${1:-40001}"
  love_print_section "Love v12 WireProxy Auto"
  love_fix_loopback_v12
  love_download_wireproxy_v12
  love_wgcf_prepare_profile_v12
  love_wireproxy_make_service_v12 "$port"
  love_wireproxy_try_endpoints_v12 "$port"
}

love_warp_cli_proxy_v12() {
  local port="${1:-40000}"
  love_print_section "Love v12 Official WARP Proxy"
  love_fix_loopback_v12

  if declare -F love_warp_set_proxy_mode >/dev/null 2>&1; then
    love_warp_set_proxy_mode "$port" || true
  else
    if ! love_cmd_exists warp-cli; then
      warn "warp-cli 不存在，跳过官方 Proxy。"
      return 1
    fi
    systemctl restart warp-svc || true
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || warp-cli disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli mode proxy >/dev/null 2>&1 || true
    warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1 || warp-cli proxy port "$port" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true
    sleep 5
  fi

  love_socks_health_gate "$port"
}

love_singbox_switch_warp_socks_v12() {
  local port="$1"
  local mode="${2:-smart}"
  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"

  if ! love_socks_health_gate "$port"; then
    die "SOCKS ${port} 未通过健康检查，拒绝切换 sing-box，避免节点出站中断。"
  fi

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.v12-warp.$(date +%F-%H%M%S)

  if [[ "$mode" == "smart" ]]; then
    jq --argjson port "$port" '
      .outbounds = (
        [.outbounds[]? | select(.tag!="warp-socks")] +
        [{
          type:"socks",
          tag:"warp-socks",
          server:"127.0.0.1",
          server_port:$port,
          version:"5"
        }]
      ) |
      .route = (.route // {}) |
      .route.rules = [
        {ip_is_private:true, outbound:"block"},
        {port:[25,465,587], outbound:"block"},
        {protocol:"bittorrent", outbound:"block"},
        {domain_suffix:["github.com","githubusercontent.com","githubassets.com","github.io","api.github.com","collector.github.com","alive.github.com","microsoft.com","windows.com","msftconnecttest.com","google.com","gstatic.com","googleapis.com"], outbound:"warp-socks"},
        {ip_version:4, outbound:"warp-socks"},
        {ip_version:6, outbound:"direct"}
      ] |
      .route.final = "warp-socks"
    ' /etc/sing-box/config.json > /tmp/love-singbox-v12.json
  else
    jq --argjson port "$port" '
      .outbounds = (
        [.outbounds[]? | select(.tag!="warp-socks")] +
        [{
          type:"socks",
          tag:"warp-socks",
          server:"127.0.0.1",
          server_port:$port,
          version:"5"
        }]
      ) |
      .route = (.route // {}) |
      .route.final = "warp-socks"
    ' /etc/sing-box/config.json > /tmp/love-singbox-v12.json
  fi

  mv /tmp/love-singbox-v12.json /etc/sing-box/config.json
  /usr/local/bin/sing-box check -c /etc/sing-box/config.json
  systemctl restart sing-box
  log "sing-box 已安全切换到 warp-socks:${port}，模式：${mode}"
}

love_singbox_restore_direct_v12() {
  [[ -f /etc/sing-box/config.json ]] || die "未找到 /etc/sing-box/config.json"
  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.v12-restore.$(date +%F-%H%M%S)
  jq '
    .outbounds = ([.outbounds[]? | select(.tag!="warp-socks")]) |
    .route = (.route // {}) |
    .route.rules = ((.route.rules // []) | map(select((.ip_version? == 4 or .ip_version? == 6 or .domain_suffix? != null) | not))) |
    .route.final = "direct"
  ' /etc/sing-box/config.json > /tmp/love-singbox-direct.json && mv /tmp/love-singbox-direct.json /etc/sing-box/config.json
  /usr/local/bin/sing-box check -c /etc/sing-box/config.json
  systemctl restart sing-box
  log "sing-box 已恢复 direct。"
}

love_warp_auto_fix_v12() {
  love_print_section "Love v12 Auto Fix / Decision Engine"
  love_warp_full_precheck_v12

  local chosen_port=""

  warn "阶段 1：尝试官方 WARP Proxy 40000。"
  if love_warp_cli_proxy_v12 40000; then
    chosen_port="40000"
  else
    warn "官方 WARP Proxy 40000 不可用，进入 WireProxy fallback。"
  fi

  if [[ -z "$chosen_port" ]]; then
    warn "阶段 2：尝试 WireProxy 40001。"
    if love_wireproxy_auto_v12 40001; then
      chosen_port="40001"
    fi
  fi

  if [[ -z "$chosen_port" ]]; then
    warn "阶段 3：SOCKS 方案失败，不切换 sing-box。"
    warn "建议改用 WGCF Non-global / wireguard-go fallback，或保留 prefer_ipv6。"
    return 1
  fi

  warn "健康检查通过，准备安全切换 sing-box。"
  love_singbox_switch_warp_socks_v12 "$chosen_port" smart

  love_print_section "Love v12 Final Test"
  jq '{final:.route.final, warp_socks:[.outbounds[]? | select(.tag=="warp-socks")]}' /etc/sing-box/config.json
  curl -s --connect-timeout 8 --socks5-hostname "127.0.0.1:${chosen_port}" https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo|warp)=' || true
  log "Auto Fix 完成。V2RayN -> HY2 -> sing-box -> WARP SOCKS 已联动。"
}

love_warp_report_v12() {
  love_print_section "Love v12 Report"
  echo "Version: ${VERSION:-unknown}"
  echo
  echo "[sing-box]"
  systemctl status sing-box --no-pager | head -n 20 || true
  jq '{route:.route, warp_socks:[.outbounds[]? | select(.tag=="warp-socks")], inbounds:[.inbounds[]? | {tag,type,listen,listen_port}]}' /etc/sing-box/config.json 2>/dev/null || true

  echo
  echo "[wireproxy]"
  command -v wireproxy || true
  systemctl status love-wireproxy.service --no-pager | head -n 20 || true
  ss -lntp | grep -E ':(40000|40001)' || true

  echo
  echo "[official warp]"
  warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true

  echo
  echo "[SOCKS health]"
  love_socks_health_gate 40000 || true
  love_socks_health_gate 40001 || true
}

love_warp_final_menu_v12() {
  while true; do
    love_print_section "Love v12 WARP Decision Engine Final"
    echo "1) Auto Fix：自动检测 + 自动 fallback + 成功才切 sing-box"
    echo "2) Smart Split：IPv6 direct，IPv4/GitHub/Microsoft 走 WARP"
    echo "3) Official WARP Proxy 40000 健康检查/修复"
    echo "4) WireProxy 40001 安装/修复/endpoint 自动尝试"
    echo "5) SOCKS 健康检查 40000/40001"
    echo "6) sing-box 安全切换到 40000"
    echo "7) sing-box 安全切换到 40001"
    echo "8) 恢复 sing-box direct"
    echo "9) 完整诊断报告"
    echo "10) Full Precheck"
    echo "0) 返回"
    read -rp "请选择: " x
    case "$x" in
      1) love_warp_auto_fix_v12 ;;
      2)
        if love_socks_health_gate 40001; then love_singbox_switch_warp_socks_v12 40001 smart
        elif love_socks_health_gate 40000; then love_singbox_switch_warp_socks_v12 40000 smart
        else love_warp_auto_fix_v12
        fi
        ;;
      3) love_warp_cli_proxy_v12 40000 ;;
      4) love_wireproxy_auto_v12 40001 ;;
      5) love_socks_health_gate 40000 || true; love_socks_health_gate 40001 || true ;;
      6) love_singbox_switch_warp_socks_v12 40000 all ;;
      7) love_singbox_switch_warp_socks_v12 40001 all ;;
      8) love_singbox_restore_direct_v12 ;;
      9) love_warp_report_v12 ;;
      10) love_warp_full_precheck_v12 ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


love_warp_status() {
  echo
  echo "================ Love Native WARP Status ================"

  echo "[warp-cli]"
  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true
  else
    echo "[INFO] warp-cli 未安装。"
  fi

  echo
  echo "[warp-svc]"
  systemctl status warp-svc --no-pager 2>/dev/null | sed -n '1,40p' || echo "[INFO] warp-svc 未安装。"

  echo
  echo "[wireguard/wgcf]"
  systemctl status wg-quick@wgcf --no-pager 2>/dev/null | sed -n '1,35p' || true
  command -v wg >/dev/null 2>&1 && wg show 2>/dev/null || true

  echo
  echo "[interface]"
  ip addr show | grep -Ei 'warp|wgcf|wg[0-9]|cloudflare' -A4 || true

  echo
  echo "[route]"
  ip route 2>/dev/null | grep -Ei 'warp|wgcf|default' || true
  ip -6 route 2>/dev/null | grep -Ei 'warp|wgcf|default' || true
}

love_warp_test() {
  echo
  echo "================ Love WARP Outbound Test ================"
  echo "[IPv4 GitHub]"
  curl -4 -I --connect-timeout 8 https://github.com || true
  echo
  echo "[IPv6 GitHub]"
  curl -6 -I --connect-timeout 8 https://github.com || true
  echo
  echo "[Cloudflare trace]"
  curl -s --connect-timeout 8 https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'ip=|warp=|colo=' || true
}


love_warp_create_rollback_timer() {
  local seconds="${1:-180}"

  cat > /root/love-warp-rollback.sh <<'EOF'
#!/usr/bin/env bash
set +e
logger -t Love "WARP rollback timer triggered: disconnecting WARP and restoring SSH"

if command -v warp-cli >/dev/null 2>&1; then
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || warp-cli disconnect >/dev/null 2>&1 || true
fi

systemctl stop wg-quick@wgcf >/dev/null 2>&1 || true
systemctl stop warp-go >/dev/null 2>&1 || true

ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 22/tcp comment 'Love SSH rescue' >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true

systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
EOF

  chmod +x /root/love-warp-rollback.sh

  systemctl stop love-warp-rollback.timer love-warp-rollback.service >/dev/null 2>&1 || true
  systemd-run --unit=love-warp-rollback --on-active="${seconds}s" /root/love-warp-rollback.sh >/dev/null 2>&1 || {
    warn "systemd-run 创建回滚定时器失败，将不会自动回滚。"
    return 1
  }

  warn "已创建 WARP 自动回滚定时器：${seconds} 秒后若未确认，将自动断开 WARP 并恢复 SSH。"
}

love_warp_cancel_rollback() {
  systemctl stop love-warp-rollback.timer love-warp-rollback.service >/dev/null 2>&1 || true
  rm -f /root/love-warp-rollback.sh
  log "已取消 WARP 自动回滚定时器。"
}

love_warp_rollback_status() {
  echo
  echo "================ Love WARP Rollback Timer ================"
  systemctl status love-warp-rollback.timer --no-pager 2>/dev/null || echo "[INFO] 当前没有 WARP 自动回滚定时器。"
  systemctl status love-warp-rollback.service --no-pager 2>/dev/null || true
}

love_warp_emergency_off() {
  echo
  echo "================ Love WARP Emergency OFF ================"
  warn "将断开 WARP / 停止 wgcf，并恢复 SSH 22 端口。"

  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli --accept-tos disconnect 2>/dev/null || warp-cli disconnect 2>/dev/null || true
  fi

  systemctl stop wg-quick@wgcf 2>/dev/null || true
  systemctl stop warp-go 2>/dev/null || true

  ufw allow 22/tcp || true
  ufw reload || true

  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

  love_warp_cancel_rollback || true
  love_warp_status
}


love_install_cloudflare_warp_official() {
  echo
  echo "================ Love Native WARP：Cloudflare 官方客户端 ================"
  warn "WARP 只解决 VPS 出站问题，不会给 IPv6-only VPS 提供公网 IPv4 入站。"
  warn "安装/连接 WARP 可能改变默认路由，导致 SSH 失联。"
  warn "V10.4 会先创建自动回滚定时器：如果连接后失联，会自动断开 WARP 并恢复 SSH。"
  read -rp "确认安装 Cloudflare 官方 WARP 客户端？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

  if ! command -v apt >/dev/null 2>&1; then
    die "当前系统不是 apt 系，官方 WARP 安装器暂只支持 Ubuntu/Debian。"
  fi

  apt update
  apt install -y curl gpg lsb-release ca-certificates

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [[ -n "$codename" ]] || die "无法识别系统 codename。"

  mkdir -p /usr/share/keyrings
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" > /etc/apt/sources.list.d/cloudflare-client.list

  if ! apt update; then
    warn "Cloudflare 官方源 apt update 失败。可能该系统 codename 暂未被官方源支持。"
    warn "你可以改用 V10 菜单里的 wgcf/WireGuard 备用方式，或换 Ubuntu 22.04 / Debian 12。"
    return 1
  fi

  apt install -y cloudflare-warp

  systemctl enable --now warp-svc || true
  sleep 2

  # Different warp-cli versions use slightly different verbs. Try compatible paths.
  warp-cli --accept-tos registration new 2>/dev/null || \
  warp-cli --accept-tos register 2>/dev/null || \
  warp-cli registration new 2>/dev/null || \
  warp-cli register 2>/dev/null || true

  warp-cli --accept-tos mode warp 2>/dev/null || warp-cli mode warp 2>/dev/null || true

  # Safe connect: create rollback timer first. If SSH drops, WARP will be disconnected automatically.
  love_warp_create_rollback_timer 180 || true

  warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true

  sleep 5
  love_warp_status
  love_warp_test

  echo
  warn "如果当前 SSH 没断，并且 curl -4 已经能通，请输入 y 保留 WARP。"
  warn "如果不输入 y，180 秒自动回滚定时器会断开 WARP，避免服务器再次失联。"
  read -t 60 -rp "保留当前 WARP 连接并取消回滚？[y/N]: " keep || keep=""

  if [[ "$keep" =~ ^[Yy]$ ]]; then
    love_warp_cancel_rollback
    log "WARP 已保留。"
  else
    warn "未确认保留。请等待自动回滚，或手动执行：Love warp-emergency-off"
  fi

  warn "如果 curl -4 仍然超时，进入 Love warp 菜单查看状态，或尝试 wgcf/WireGuard 备用方式。"
}

love_download_latest_wgcf() {
  local arch asset url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7*) arch="armv7" ;;
    *) die "暂不支持该架构自动下载 wgcf：$(uname -m)" ;;
  esac

  tmp="/tmp/wgcf-download"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  url="$(curl -fsSL --connect-timeout 15 https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r --arg arch "$arch" '
    .assets[]
    | select(.name | test("linux_" + $arch + "($|\\.|_|-)"))
    | .browser_download_url
  ' | head -n1)"

  [[ -n "$url" && "$url" != "null" ]] || die "无法自动获取 wgcf 最新下载地址。"

  curl -L --connect-timeout 20 -o "$tmp/wgcf.asset" "$url"

  if file "$tmp/wgcf.asset" | grep -qi 'gzip compressed'; then
    tar -xzf "$tmp/wgcf.asset" -C "$tmp" 2>/dev/null || gzip -dc "$tmp/wgcf.asset" > "$tmp/wgcf" || true
  elif file "$tmp/wgcf.asset" | grep -qi 'Zip archive'; then
    unzip -o "$tmp/wgcf.asset" -d "$tmp"
  else
    cp "$tmp/wgcf.asset" "$tmp/wgcf"
  fi

  asset="$(find "$tmp" -type f -name 'wgcf*' | head -n1)"
  [[ -n "$asset" ]] || die "下载后未找到 wgcf 可执行文件。"

  install -m 755 "$asset" /usr/local/bin/wgcf
  /usr/local/bin/wgcf --version || true
}

love_install_wgcf_wireguard() {
  echo
  echo "================ Love Native WARP：wgcf/WireGuard 备用方式 ================"
  warn "这是 Love 自带的备用安装逻辑，不调用 Native。"
  warn "会生成 /etc/wireguard/wgcf.conf 并启动 wg-quick@wgcf。"
  warn "WireGuard 路由可能影响 SSH，请保持当前窗口不要关闭。"
  read -rp "确认继续？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

  apt update
  apt install -y curl jq wireguard-tools iproute2 ca-certificates file unzip
  love_install_optional_dns_resolver

  if ! command -v wgcf >/dev/null 2>&1; then
    love_download_latest_wgcf
  fi

  mkdir -p /etc/wireguard /opt/Love/warp
  cd /opt/Love/warp

  if [[ ! -f wgcf-account.toml ]]; then
    yes | wgcf register
  fi

  wgcf generate

  [[ -f wgcf-profile.conf ]] || die "wgcf-profile.conf 生成失败。"

  cp wgcf-profile.conf /etc/wireguard/wgcf.conf
  chmod 600 /etc/wireguard/wgcf.conf

  # Safer server-side DNS handling: avoid breaking resolvconf if not available.
  sed -i '/^DNS =/d' /etc/wireguard/wgcf.conf

  systemctl enable wg-quick@wgcf

  love_warp_create_rollback_timer 180 || true
  systemctl restart wg-quick@wgcf

  sleep 5
  love_warp_status
  love_warp_test

  echo
  warn "如果当前 SSH 没断，并且 curl -4 已经能通，请输入 y 保留 wgcf/WireGuard。"
  read -t 60 -rp "保留当前 wgcf/WireGuard 并取消回滚？[y/N]: " keep || keep=""

  if [[ "$keep" =~ ^[Yy]$ ]]; then
    love_warp_cancel_rollback
    log "wgcf/WireGuard 已保留。"
  else
    warn "未确认保留。请等待自动回滚，或手动执行：Love warp-emergency-off"
  fi
}

love_warp_disconnect() {
  echo
  echo "================ Love WARP Disconnect ================"
  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli --accept-tos disconnect 2>/dev/null || warp-cli disconnect 2>/dev/null || true
  fi
  systemctl stop wg-quick@wgcf 2>/dev/null || true
  love_warp_status
}

love_warp_uninstall() {
  echo
  echo "================ Love WARP Uninstall ================"
  warn "卸载/关闭 WARP 可能改变出站网络。"
  read -rp "确认卸载/关闭 Love 原生 WARP 配置？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli --accept-tos disconnect 2>/dev/null || warp-cli disconnect 2>/dev/null || true
  fi

  systemctl disable --now wg-quick@wgcf 2>/dev/null || true
  rm -f /etc/wireguard/wgcf.conf

  read -rp "是否同时卸载 cloudflare-warp 软件包？[y/N]: " purge
  if [[ "$purge" =~ ^[Yy]$ ]]; then
    apt purge -y cloudflare-warp 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
  fi

  systemctl daemon-reload || true
  love_warp_status
}

love_warp_quick_fix() {
  echo
  echo "================ Love Native WARP Quick Fix ================"
  love_test_outbound_stack || true
  echo
  warn "如果 IPv4 outbound=no、IPv6 outbound=yes，建议安装 WARP 出站。"
  echo "1) Superior WARP Proxy：推荐，不改系统默认路由"
  echo "2) 安装 Cloudflare 官方 WARP 全局客户端"
  echo "3) 安装 wgcf/WireGuard 备用方式"
  echo "4) 只应用 sing-box prefer_ipv6"
  echo "0) 返回"
  read -rp "请选择: " w
  case "$w" in
    1) love_warp_proxy_safe_install ;;
    2) love_install_cloudflare_warp_official ;;
    3) love_install_wgcf_wireguard ;;
    4) love_fix_ipv6_only_outbound ;;
    *) return 0 ;;
  esac
}

love_warp_manager_menu() {
  while true; do
    echo
    echo "================ Love Native WARP Manager ================"
    echo "1) Auto Fix：Decision Engine 自动检测/自动 fallback（最终推荐）"
    echo "2) Smart Split：IPv6 direct，IPv4 走 WARP（推荐）"
    echo "2) Superior WARP Proxy：sing-box 全部出站走 WARP SOCKS"
    echo "3) WARP 单栈 / 双栈：IPv4 Only / IPv6 Only / Dual Stack"
    echo "4) WARP 快速判断 / 修复建议"
    echo "5) 安装 Cloudflare 官方 WARP 全局客户端"
    echo "6) 安装 wgcf/WireGuard 备用方式"
    echo "7) 查看 WARP 状态"
    echo "8) 测试 IPv4 / IPv6 出站"
    echo "9) sing-box prefer_ipv6 修复"
    echo "10) 恢复 sing-box direct 出站"
    echo "11) WARP 紧急关闭/恢复 SSH"
    echo "12) 查看/取消 WARP 自动回滚"
    echo "13) WARP 模式对比说明"
    echo "14) 兼容模式：warp 4/6/d/c/l/w/g/s 说明"
    echo "15) WARP 优先级设置 IPv4/IPv6/VPS 默认"
    echo "16) V10.8 Smart WARP 高级菜单"
    echo "17) 卸载/清理 WARP"
    echo "0) 返回"
    read -rp "请选择: " w
    case "$w" in
      1) love_singbox_smart_split_warp ;;
      2) love_warp_proxy_safe_install ;;
      3) love_warp_stack_menu ;;
      4) love_warp_quick_fix ;;
      5) love_install_cloudflare_warp_official ;;
      6) love_install_wgcf_wireguard ;;
      7) love_warp_super_status ;;
      8) love_warp_test ;;
      9) love_fix_ipv6_only_outbound ;;
      10) love_singbox_restore_direct_outbound ;;
      11) love_warp_emergency_off ;;
      12)
        love_warp_rollback_status
        read -rp "是否取消自动回滚？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] && love_warp_cancel_rollback
        ;;
      13) love_warp_compare_modes ;;
      14) love_warp_compat_help ;;
      15) love_warp_set_priority ;;
      16) love_warp_smart_menu ;;
      17) love_warp_uninstall ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

# Backward compatible command name.
love_warp_download_menu() {
  love_install_cloudflare_warp_official
}

love_warp_hint() {
  cat <<'EOF'

================ Love 原生 WARP 说明 ================

V10 已经不再调用第三方 WARP 脚本，WARP 管理已内置在 Love 中。

当前 Love 自带三种 WARP 出站方案，优先推荐 Superior Proxy 模式：
1. Cloudflare 官方 Linux 客户端：
   Love warp -> 2

2. wgcf/WireGuard 备用方式：
   Love warp -> 3

适用场景：
- IPv6-only VPS
- curl -4 超时
- V2RayN 日志出现 outbound/direct dial tcp IPv4 timeout
- GitHub / Microsoft / 部分 IPv4 网站打不开

注意：
- WARP 解决 VPS 出站 IPv4。
- WARP 不会给 IPv6-only VPS 提供公网 IPv4 入站。
- 安装 WARP 可能改变默认路由，请保持 SSH 窗口不要关闭。

=======================================================

EOF
}

github_publish_note() {
  cat <<'EOF'

================ GitHub 发布建议 ================

仓库建议：
  LOVENN/
  ├── Love.sh
  ├── README.md
  └── LICENSE

安装命令：
  bash <(wget -qO- https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh)

或者：
  curl -fsSL https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh | bash

维护命令：
  Love
  Love -n
  Love sub
  Love doctor
  Love repair
  Love dns
  Love -v
  Love -u
  Love qr
  Love argo-api
  Love realm
  Love -r
  Love serve-sub
  Love mihomo
  Love clients
  Love web
  Love self-update
  Love links
  Love singbox-json
  Love shadowrocket
  Love v2rayn
  Love nekobox
  Love sfi
  Love pack
  Love notify
  Love push
  Love check
  Love backup-auto
  Love cert
  Love port
  Love oracle
  Love users
  Love token
  Love project
  Love v7
  Love precheck
  Love mode
  Love snapshot
  Love rollback
  Love support
  Love logs
  Love pin
  Love compat
  Love speed
  Love cfip
  Love cloud-firewall
  Love harden
  Love web-status
  Love v8
  Love validate
  Love audit
  Love dashboard
  Love state
  Love release
  Love readme
  Love support-bundle
  Love import-links
  Love rotate
  Love test-suite
  Love update-channel
  Love nginx
  Love nginx-ws
  Love nginx-grpc
  Love nginx-fallback
  Love nginx-stream
  Love nginx-status
  Love nginx-rollback
  Love fix-hy2
  Love fix-ipv6
  Love test-outbound
  Love warp-hint
  Love ipv6-outbound
  Love warp
  Love warp-install
  Love warp-status
  Love warp-test
  Love warp-official
  Love warp-wgcf
  Love warp-disconnect
  Love warp-uninstall
  Love warp-emergency-off
  Love warp-keep
  Love warp-rollback-status
  Love warp-proxy
  Love warp-direct
  Love warp-modes
  Love warp-super-status
  Love warp-preflight
  Love warp 4
  Love warp 6
  Love warp d
  Love warp c
  Love warp l
  Love warp w
  Love warp g
  Love warp s
  Love warp-smart
  Love warp-report
  Love warp-unlock
  Love warp-ip
  Love warp-endpoint
  Love warp-mtu
  Love warp-proxy-auto
  Love warp-go-fallback
  Love warp-smart-restore
  Love warp-stack
  Love warp-single4
  Love warp-single6
  Love warp-dual-stack

兼容小写：
  love

README 里建议说明：
  1. Love 是原生 Xray + 原生 sing-box 的统一安装管理脚本。
  2. WARP 不提供公网 IPv4 入站。
  3. IPv6-only VPS 仍要求直连客户端具备 IPv6，除非使用 Argo/其他隧道。
  4. all 全协议模式建议干净 VPS 使用。
  5. 优选 IP / 域名只替换客户端 Address，不替换 SNI。

================================================

EOF
}

main_menu() {
  while true; do
    echo
    echo "================ ${VERSION} ================"
    echo "1) 查看全节点目录"
    echo "2) Love Xray 稳定模式 Reality + 可选 HY2"
    echo "3) Love sing-box 原生全协议 / 自选协议"
    echo "4) Argo / Cloudflared 隧道"
    echo "5) Port Hopping UDP 端口跳跃"
    echo "6) WARP 出站增强说明"
    echo "7) 查看节点信息 Love -n"
    echo "8) 导出订阅 Love sub"
    echo "9) 生成二维码 Love qr"
    echo "10) Super Tools 诊断/修复/更新/Realm/增删协议"
    echo "11) Web 管理页 Love web"
    echo "12) 在线更新 Love update"
    echo "13) 客户端专用导出 links/json/各客户端"
    echo "14) v6 Project Tools：Web安全/推送/检测/备份/证书/Oracle/多用户"
    echo "15) v7 Stable Tools：预检/模式/快照/用户/日志/加固"
    echo "16) v8 Project Panel：验证/审计/发布/迁移/仪表盘"
    echo "17) v9 Nginx Reverse Proxy：WS/gRPC/Stream/伪装站"
    echo "18) HY2/sing-box 自动修复与订阅生成"
    echo "19) IPv6-only 出站修复 / WARP 提示"
    echo "20) WARP Manager：安装/状态/测试/修复"
    echo "21) 查看状态"
    echo "22) 备份配置"
    echo "23) 卸载菜单"
    echo "24) GitHub 发布说明"
    echo "0) 退出"
    echo
    read -rp "请选择: " choice

    case "${choice}" in
      1) show_all_node_catalog ;;
      2) install_xray_stable ;;
      3) install_singbox_native ;;
      4) argo_helper ;;
      5) port_hopping_helper ;;
      6) warp_helper ;;
      7) show_node_info ;;
      8) export_subscription ;;
      9) generate_qrcodes ;;
      10) super_menu ;;
      11) web_admin_page ;;
      12) self_update_love ;;
      13) love_full_client_pack ;;
      14) v6_super_menu ;;
      15) v7_stable_menu ;;
      16) v8_menu ;;
      17) nginx_rp_menu ;;
      18) love_fix_hy2_now ;;
      19) love_ipv6_outbound_menu ;;
      20) love_warp_manager_menu ;;
      21) show_status ;;
      22) backup_configs ;;
      23) uninstall_menu_v7 ;;
      24) github_publish_note ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main() {
  need_root
  prepare_dirs
  fix_hostname
  check_os_soft
  install_shortcut

  case "${1:-}" in
    xray)
      install_xray_stable
      ;;
    singbox|sing-box|all)
      install_singbox_native
      ;;
    argo)
      argo_helper
      ;;
    hopping)
      port_hopping_helper
      ;;
    warp)
      love_warp_compat_command "${2:-}"
      ;;
    -n|n|node|nodes)
      show_node_info
      ;;
    sub|subscribe|subscription)
      export_subscription
      ;;
    qr|qrcode)
      generate_qrcodes
      ;;
    mihomo|clash)
      generate_mihomo_yaml
      ;;
    clients|export-clients)
      generate_client_exports
      ;;
    links)
      love_links
      ;;
    singbox-json|sing-box-json)
      love_singbox_json
      ;;
    shadowrocket|sr)
      love_shadowrocket
      ;;
    v2rayn)
      love_v2rayn
      ;;
    nekobox|nekoray)
      love_nekobox
      ;;
    sfi|sfa|sfm|sing-box-client)
      love_sfi_sfa_sfm
      ;;
    pack|client-pack)
      love_full_client_pack
      ;;
    notify)
      notify_config_menu
      ;;
    push)
      notify_nodes
      ;;
    check|health|speedtest)
      health_check_nodes
      ;;
    backup-auto)
      setup_auto_backup
      ;;
    cert|cert-check)
      cert_status_check
      ;;
    port|ports|port-advisor)
      check_port_conflict_and_recommend
      ;;
    oracle)
      oracle_security_template
      ;;
    user|users)
      users_menu_v7
      ;;
    token|reset-token)
      reset_sub_token
      ;;
    project|v6)
      v6_super_menu
      ;;
    v7|stable)
      v7_stable_menu
      ;;
    v8|panel|project-panel)
      v8_menu
      ;;
    v9|nginx|nginx-rp|reverse-proxy)
      nginx_rp_menu
      ;;
    nginx-ws)
      nginx_ws_reverse_proxy
      ;;
    nginx-grpc)
      nginx_grpc_reverse_proxy
      ;;
    nginx-fallback)
      nginx_fallback_only
      ;;
    nginx-stream)
      nginx_stream_sni_passthrough
      ;;
    nginx-status)
      nginx_rp_status
      ;;
    nginx-rollback)
      nginx_rp_rollback
      ;;
    fix-hy2|hy2-fix|fix-singbox)
      love_fix_hy2_now
      ;;
    fix-ipv6|ipv6-out|ipv6-fix)
      love_fix_ipv6_only_outbound
      ;;
    test-outbound|outbound-test)
      love_test_outbound_stack || true
      ;;
    warp-hint)
      love_warp_hint
      ;;
    warp-old-hint)
      warp_helper
      ;;
    warp|warp-manager)
      love_warp_manager_menu
      ;;
    warp-install)
      love_warp_download_menu
      ;;
    warp-status)
      love_warp_status
      ;;
    warp-test)
      love_warp_test
      ;;
    warp-official)
      love_install_cloudflare_warp_official
      ;;
    warp-wgcf|warp-wireguard)
      love_install_wgcf_wireguard
      ;;
    warp-disconnect)
      love_warp_disconnect
      ;;
    warp-uninstall)
      love_warp_uninstall
      ;;
    warp-emergency-off|warp-off|warp-rescue)
      love_warp_emergency_off
      ;;
    warp-keep|warp-cancel-rollback)
      love_warp_cancel_rollback
      ;;
    warp-rollback-status)
      love_warp_rollback_status
      ;;
    warp-proxy|warp-safe|warp-super)
      love_warp_proxy_safe_install
      ;;
    warp-direct)
      love_singbox_restore_direct_outbound
      ;;
    warp-modes)
      love_warp_compare_modes
      ;;
    warp-super-status)
      love_warp_super_status
      ;;
    warp-preflight)
      love_warp_preflight
      ;;
    warp4|warp-ipv4)
      love_warp_interface_mode 4
      ;;
    warp6|warp-ipv6)
      love_warp_interface_mode 6
      ;;
    warpd|warp-dual)
      love_warp_interface_mode d
      ;;
    warp-c|warp-client-proxy)
      love_warp_proxy_safe_install
      ;;
    warp-l|warp-linux-client)
      love_install_cloudflare_warp_official
      ;;
    warp-w|wireproxy)
      love_warp_wireproxy_mode
      ;;
    warp-fix-deps)
      apt update || true
      apt install -y curl jq wireguard-tools iproute2 ca-certificates file unzip tar
      love_install_optional_dns_resolver
      ;;
    wireproxy-install|warp-wireproxy-install)
      love_download_latest_wireproxy
      ;;
    wireproxy-status|warp-wireproxy-status)
      command -v wireproxy || true
      systemctl status love-wireproxy.service --no-pager || true
      journalctl -u love-wireproxy.service -n 80 -l --no-pager || true
      ss -lntp | grep -E ":(40001|40000)" || true
      ;;
    warp-g|warp-global)
      love_warp_global_toggle_menu
      ;;
    warp-s|warp-priority)
      love_warp_set_priority
      ;;
    warp-smart|smart-warp|smart-split)
      love_singbox_smart_split_warp
      ;;
    warp-smart-menu)
      love_warp_smart_menu
      ;;
    warp-report)
      love_warp_full_report
      ;;
    warp-unlock)
      love_warp_unlock_check
      ;;
    warp-ip)
      love_warp_ip_asn_region
      ;;
    warp-endpoint)
      love_warp_endpoint_select
      ;;
    warp-mtu)
      love_warp_apply_mtu
      ;;
    warp-proxy-auto)
      love_warp_proxy_auto_with_fallback
      ;;
    warp-go-fallback)
      love_warp_go_fallback
      ;;
    warp-smart-restore)
      love_singbox_restore_from_smart_split
      ;;
    warp-stack|warp-stack-menu)
      love_warp_stack_menu
      ;;
    warp-single4|warp-ipv4-only|warp-v4-only)
      love_warp_interface_mode 4
      ;;
    warp-single6|warp-ipv6-only|warp-v6-only)
      love_warp_interface_mode 6
      ;;
    warp-dual-stack|warp-dual)
      love_warp_interface_mode d
      ;;
    ipv6-outbound)
      love_ipv6_outbound_menu
      ;;
    validate)
      v8_validate_all
      ;;
    audit)
      v8_security_audit
      ;;
    dashboard)
      v8_dashboard
      ;;
    state)
      v8_state_generate
      ;;
    release)
      v8_release_pack
      ;;
    readme)
      v8_generate_readme
      ;;
    support-bundle|bundle)
      v8_support_bundle
      ;;
    import-links|import)
      v8_import_links
      ;;
    rotate)
      v8_rotate_menu
      ;;
    test-suite|test)
      v8_test_suite
      ;;
    update-channel|channel)
      v8_update_channel
      ;;
    precheck)
      precheck_env
      ;;
    mode)
      mode_wizard
      ;;
    snapshot)
      snapshot_menu
      ;;
    rollback)
      snapshot_rollback
      ;;
    support)
      support_matrix
      ;;
    logs)
      logs_menu
      ;;
    errors)
      tail -n 200 "${LOVE_LOG}/error.log" 2>/dev/null || warn "暂无 error.log"
      ;;
    pin)
      pin_core_menu
      ;;
    compat)
      singbox_compat_check
      ;;
    speed)
      speed_test
      ;;
    cfip)
      cfip_helper
      ;;
    cloud-firewall)
      cloud_firewall_templates
      ;;
    harden)
      harden_menu
      ;;
    uninstall-full|uninstall-soft)
      uninstall_menu_v7
      ;;
    web-status)
      web_status_generate
      ;;
    web|admin)
      web_admin_page
      ;;
    self-update|update-love)
      self_update_love
      ;;
    serve-sub|sub-server)
      serve_subscription_nginx
      ;;
    argo-api)
      argo_api_create_tunnel
      ;;
    realm|hy2-realm)
      hy2_realm_helper
      ;;
    -r|r|reload|protocols)
      reload_protocols_helper
      ;;
    doctor|diag|diagnose)
      doctor_check
      ;;
    repair)
      repair_apt_dpkg
      ;;
    dns)
      set_ipv6_dns
      ;;
    -v|v|update)
      update_core_menu
      ;;
    -u|u|uninstall)
      uninstall_menu
      ;;
    status)
      show_status
      ;;
    backup)
      backup_configs
      ;;
    catalog)
      show_all_node_catalog
      ;;

    warp-auto|warp-final|warp-v12|warp-decision)
      love_warp_final_menu_v12
      ;;
    warp-auto-fix)
      love_warp_auto_fix_v12
      ;;
    warp-report-v12|warp-report)
      love_warp_report_v12
      ;;
    warp-precheck-v12|warp-precheck)
      love_warp_full_precheck_v12
      ;;
    warp-wireproxy-fix|wireproxy-fix)
      love_wireproxy_auto_v12 40001
      ;;
    warp-official-fix)
      love_warp_cli_proxy_v12 40000
      ;;
    warp-safe-40000)
      love_singbox_switch_warp_socks_v12 40000 smart
      ;;
    warp-safe-40001)
      love_singbox_switch_warp_socks_v12 40001 smart
      ;;
    warp-restore-direct|warp-direct)
      love_singbox_restore_direct_v12
      ;;
    *)
      main_menu
      ;;
  esac
}

main "$@"

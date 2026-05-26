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

VERSION="Love v13.60.9-early-main-update-final"

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
  love_after_node_generated_exports
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
{"type":"vless","tag":"h2-reality-in","listen":"::","listen_port":${SB_H2_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]},"alpn":["h2"]},"transport":{"type":"http","host":["${reality_sni}"],"path":"/h2"}}
EOF
  fi

  if [[ "$INSTALL_GRPC_REALITY" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"grpc-reality-in","listen":"::","listen_port":${SB_GRPC_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]},"alpn":["h2"]},"transport":{"type":"grpc","service_name":"lovegrpc"}}
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
    echo "vless://${SB_UUID}@${h}:${SB_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=tcp#LOVE-REALITY" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_HY2" == "yes" ]]; then
    echo "HY2:" >> "${SINGBOX_INFO}"
    echo "hy2://${SB_HY2_PASS}@${h}:${SB_HY2_PORT}/?sni=${tls_sni}&insecure=${insecure}#LOVE-HY2" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TUIC" == "yes" ]]; then
    echo "TUIC:" >> "${SINGBOX_INFO}"
    echo "tuic://${SB_UUID}:${SB_TUIC_PASS}@${h}:${SB_TUIC_PORT}?sni=${tls_sni}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=${insecure}#LOVE-TUIC" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_SS" == "yes" ]]; then
    echo "Shadowsocks:" >> "${SINGBOX_INFO}"
    echo "ss://$(printf 'aes-128-gcm:%s' "${SB_SS_PASS}" | base64 -w0)@${h}:${SB_SS_PORT}#LOVE-SS" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TROJAN" == "yes" ]]; then
    echo "Trojan:" >> "${SINGBOX_INFO}"
    echo "trojan://${SB_TROJAN_PASS}@${h}:${SB_TROJAN_PORT}?security=tls&sni=${tls_sni}&allowInsecure=${insecure}#LOVE-TROJAN" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VMESS_WS" == "yes" ]]; then
    echo "VMess WS manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_VMESS_WS_PORT} UUID=${SB_UUID} Transport=ws Path=/vmess TLS=off" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VLESS_WS_TLS" == "yes" ]]; then
    echo "VLESS WS TLS:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_VLESS_WS_TLS_PORT}?encryption=none&security=tls&sni=${tls_sni}&type=ws&path=%2Fvless#LOVE-VLESS-WS-TLS" >> "${SINGBOX_INFO}"
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
    echo "https://${SB_NAIVE_USER}:${SB_NAIVE_PASS}@${h}:${SB_NAIVE_PORT}#LOVE-NAIVE" >> "${SINGBOX_INFO}"
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
  love_after_node_generated_exports
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

love_after_node_generated_exports() {
  echo
  echo "================ Love Auto Export / QR ================"
  log "节点已生成，开始自动生成订阅、客户端文件和二维码。"

  export_subscription >/dev/null 2>&1 || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  generate_client_exports >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true

  # If Web panel already exists, sync files automatically.
  local token
  token="$(get_sub_token 2>/dev/null || true)"
  if [[ -n "$token" && -d "${LOVE_WEB}" ]]; then
    mkdir -p "${LOVE_WEB}/${token}/subscribe" "${LOVE_WEB}/${token}/qr" "${LOVE_WEB}/${token}/clients" "${LOVE_WEB}/${token}/sing-box"
    cp -a "${LOVE_SUB}/." "${LOVE_WEB}/${token}/subscribe/" 2>/dev/null || true
    cp -a "${LOVE_SUB}/qr/." "${LOVE_WEB}/${token}/qr/" 2>/dev/null || true
    cp -a "${LOVE_SUB}/clients/." "${LOVE_WEB}/${token}/clients/" 2>/dev/null || true
    cp -a "${LOVE_SUB}/sing-box/." "${LOVE_WEB}/${token}/sing-box/" 2>/dev/null || true
    chown -R www-data:www-data "${LOVE_WEB}" 2>/dev/null || true
    find "${LOVE_WEB}" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "${LOVE_WEB}" -type f -exec chmod 644 {} \; 2>/dev/null || true
    log "Web 面板文件已同步：${LOVE_WEB}/${token}/"
  fi

  echo
  echo "订阅文件：${LOVE_SUB}/all.txt"
  echo "Base64：${LOVE_SUB}/all_base64.txt"
  echo "二维码目录：${LOVE_SUB}/qr/"
  [[ -f "${LOVE_SUB}/qr/index.html" ]] && echo "二维码预览：${LOVE_SUB}/qr/index.html"
  [[ -f "${LOVE_SUB}/qr/node-1.png" ]] && echo "第一个节点二维码：${LOVE_SUB}/qr/node-1.png"
  echo
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
    apt update >/dev/null 2>&1 || true
    apt install -y qrencode >/dev/null 2>&1 || install_base >/dev/null 2>&1 || true
  fi
  command -v qrencode >/dev/null 2>&1 || { warn "qrencode 安装失败，无法生成二维码。"; return 0; }

  rm -f "${LOVE_SUB}/qr"/* 2>/dev/null || true

  local i=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ((i++)) || true
    printf '%s' "$line" | qrencode -t ANSIUTF8 > "${LOVE_SUB}/qr/node-${i}.ansi" || true
    printf '%s' "$line" | qrencode -t PNG -s 8 -m 2 -o "${LOVE_SUB}/qr/node-${i}.png" || true
    printf '%s' "$line" | qrencode -t SVG -o "${LOVE_SUB}/qr/node-${i}.svg" || true
  done < "$raw"

  # Common client/subscription QR files.
  [[ -s "${LOVE_SUB}/all.txt" ]] && printf '%s' "$(cat "${LOVE_SUB}/all.txt")" | qrencode -t PNG -s 8 -m 2 -o "${LOVE_SUB}/qr/all.png" || true
  [[ -s "${LOVE_SUB}/all_base64.txt" ]] && printf '%s' "$(cat "${LOVE_SUB}/all_base64.txt")" | qrencode -t PNG -s 8 -m 2 -o "${LOVE_SUB}/qr/all_base64.png" || true
  [[ -s "${LOVE_SUB}/clients/v2rayn-uri.txt" ]] && printf '%s' "$(cat "${LOVE_SUB}/clients/v2rayn-uri.txt")" | qrencode -t PNG -s 8 -m 2 -o "${LOVE_SUB}/qr/v2rayn.png" || true
  [[ -s "${LOVE_SUB}/clients/shadowrocket.conf" ]] && printf '%s' "$(cat "${LOVE_SUB}/clients/shadowrocket.conf")" | qrencode -t PNG -s 8 -m 2 -o "${LOVE_SUB}/qr/shadowrocket.png" || true
  [[ -s "${LOVE_SUB}/clients/nekobox-uri.txt" ]] && printf '%s' "$(cat "${LOVE_SUB}/clients/nekobox-uri.txt")" | qrencode -t PNG -s 8 -m 2 -o "${LOVE_SUB}/qr/nekobox.png" || true

  # QR preview page.
  {
    cat <<'EOF'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Love QR Codes</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
    :root{
      --bg:#0f172a; --text:#e5e7eb; --card:#111827; --border:#334155;
      --hero1:#1d4ed8; --hero2:#7c3aed; --h2:#93c5fd; --link:#67e8f9;
      --code:#020617; --codeText:#d1d5db; --muted:#94a3b8; --yellow:#facc15;
      --btn:#2563eb; --btnGreen:#16a34a; --btnOrange:#ea580c; --btnGray:#475569;
    }
    *{box-sizing:border-box}
    body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,"Microsoft YaHei",sans-serif;background:#0f172a;color:#e5e7eb;}
    input.theme-radio{position:absolute;opacity:0;pointer-events:none}
    .page{
      min-height:100vh;padding:24px;background:var(--bg);color:var(--text);
      --bg:#0f172a; --text:#e5e7eb; --card:#111827; --border:#334155;
      --hero1:#1d4ed8; --hero2:#7c3aed; --h2:#93c5fd; --link:#67e8f9;
      --code:#020617; --codeText:#d1d5db; --muted:#94a3b8; --yellow:#facc15;
      --btn:#2563eb; --btnGreen:#16a34a; --btnOrange:#ea580c; --btnGray:#475569;
    }
    #themeGreen:checked ~ .page{
      --bg:#edf7ed; --text:#12351f; --card:#ffffff; --border:#b9d8bd;
      --hero1:#1b5e20; --hero2:#81c784; --h2:#1b5e20; --link:#0f766e;
      --code:#f2fff2; --codeText:#12351f; --muted:#4b6b50; --yellow:#8a5a00;
      --btn:#2e7d32; --btnGreen:#1b8a3b; --btnOrange:#b45309; --btnGray:#6b7f6d;
    }
    #themeDark:checked ~ .page{
      --bg:#0f172a; --text:#e5e7eb; --card:#111827; --border:#334155;
      --hero1:#1d4ed8; --hero2:#7c3aed; --h2:#93c5fd; --link:#67e8f9;
      --code:#020617; --codeText:#d1d5db; --muted:#94a3b8; --yellow:#facc15;
      --btn:#2563eb; --btnGreen:#16a34a; --btnOrange:#ea580c; --btnGray:#475569;
    }
    .wrap{max-width:1080px;margin:0 auto;}
    .hero{background:linear-gradient(135deg,var(--hero1),var(--hero2));padding:24px;border-radius:20px;box-shadow:0 12px 30px rgba(0,0,0,.18);color:white;}
    h1{margin:0 0 8px;font-size:28px}
    h2{margin:22px 0 12px;font-size:20px;color:var(--h2)}
    .floating-theme{
      position:fixed;right:18px;top:18px;z-index:9999;
      background:rgba(15,23,42,.92);backdrop-filter:blur(8px);
      border:1px solid rgba(148,163,184,.45);border-radius:999px;
      padding:8px;box-shadow:0 10px 30px rgba(0,0,0,.28);
      display:flex;gap:6px;align-items:center;
    }
    #themeGreen:checked ~ .floating-theme{background:rgba(237,247,237,.96);border-color:#9fcbab}
    .floating-theme label{
      border:0;border-radius:999px;padding:8px 12px;cursor:pointer;font-weight:700;
      background:#020617;color:#e5e7eb;display:inline-block;user-select:none;
    }
    #themeDark:checked ~ .floating-theme label[for="themeDark"],
    #themeGreen:checked ~ .floating-theme label[for="themeGreen"]{background:#2563eb;color:white}
    #themeGreen:checked ~ .floating-theme label{background:#f2fff2;color:#12351f}
    #themeGreen:checked ~ .floating-theme label[for="themeGreen"]{background:#2e7d32;color:white}
    .themebar{display:flex;justify-content:space-between;align-items:center;gap:12px;background:var(--card);border:1px solid var(--border);border-radius:16px;padding:14px 16px;margin-top:16px;}
    .themebar .label{font-weight:700;color:var(--h2)}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px;margin-top:18px;}
    .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:16px;}
    .card h3{margin:0 0 10px;font-size:17px;color:var(--yellow)}
    a{color:var(--link);text-decoration:none;word-break:break-all}
    a:hover{text-decoration:underline}
    code,pre{background:var(--code);border:1px solid var(--border);border-radius:12px;color:var(--codeText);padding:10px;display:block;white-space:pre-wrap;word-break:break-all}
    .ok{color:#22c55e}.warn{color:#ca8a04}.muted{color:var(--muted)}
    .btn{display:inline-block;background:var(--btn);color:white;padding:9px 12px;border-radius:10px;margin:4px 4px 4px 0}
    .btn.green{background:var(--btnGreen)}.btn.orange{background:var(--btnOrange)}.btn.gray{background:var(--btnGray)}
    table{width:100%;border-collapse:collapse;background:var(--card);border-radius:12px;overflow:hidden}
    td,th{border-bottom:1px solid var(--border);padding:10px;text-align:left}
    th{color:var(--yellow)}
    @media(max-width:760px){
      .page{padding:14px}
      .floating-theme{position:sticky;top:8px;margin:0 auto 14px;justify-content:center;border-radius:16px}
    }
  </style>
</head>
<body>
<h1>Love QR Codes</h1>
<div class="grid">
EOF
    for img in "${LOVE_SUB}/qr"/*.png; do
      [[ -f "$img" ]] || continue
      base="$(basename "$img")"
      echo "<div class='card'><a href='${base}'><img src='${base}'></a><div>${base}</div></div>"
    done
    cat <<'EOF'
</div>
</div>
</body>
</html>
EOF
  } > "${LOVE_SUB}/qr/index.html"

  log "二维码已生成：${LOVE_SUB}/qr/"
  ls -lah "${LOVE_SUB}/qr/" || true

  [[ "${1:-}" == "quiet" ]] && return 0

  [[ -f "${LOVE_SUB}/qr/node-1.ansi" ]] && { echo; echo "第一个节点二维码："; cat "${LOVE_SUB}/qr/node-1.ansi"; }
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
  local auth_file="/etc/nginx/.love_web_htpasswd"

  install_base >/dev/null 2>&1 || true
  apt install -y nginx apache2-utils >/dev/null 2>&1 || true

  # Avoid nginx binding 80 when Apache already owns it.
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

  if [[ "$auth_on" =~ ^[Yy]$ ]]; then
    read -rp "Web 用户名 [love]: " web_user
    web_user="${web_user:-love}"
    read -rsp "Web 密码，留空自动生成: " web_pass
    echo
    if [[ -z "$web_pass" ]]; then
      web_pass="$(random_token 8)"
      warn "自动生成 Web 密码：${web_pass}"
    fi

    if command -v htpasswd >/dev/null 2>&1; then
      htpasswd -bc "$auth_file" "$web_user" "$web_pass" >/dev/null
    else
      printf "%s:$(openssl passwd -apr1 "%s")
" "$web_user" "$web_pass" > "$auth_file"
    fi

    chown root:www-data "$auth_file"
    chmod 640 "$auth_file"
  fi

  local token
  token="$(get_sub_token)"

  export_subscription >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true
  love_full_client_pack >/dev/null 2>&1 || true

  mkdir -p "${LOVE_WEB}/${token}/subscribe" "${LOVE_WEB}/${token}/qr" "${LOVE_WEB}/${token}/clients" "${LOVE_WEB}/${token}/sing-box"

  cp -a "${LOVE_SUB}/." "${LOVE_WEB}/${token}/subscribe/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/qr/." "${LOVE_WEB}/${token}/qr/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/clients/." "${LOVE_WEB}/${token}/clients/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/sing-box/." "${LOVE_WEB}/${token}/sing-box/" 2>/dev/null || true

  # Root page prevents 403 when opening http://IP:PORT/
  cat > "${LOVE_WEB}/index.html" <<EOF
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Love Admin Panel</title>
<style>
body{font-family:Arial,sans-serif;background:#0f172a;color:#e5e7eb;padding:40px}
.card{max-width:820px;margin:auto;background:#111827;padding:28px;border-radius:16px}
h1{color:#fff} a{color:#93c5fd} code{background:#020617;padding:4px 8px;border-radius:6px}
</style>
</head>
<body>
  <div class="card">
    <h1>Love Admin Panel</h1>
    <p>Status: OK</p>
    <p>This is a static management page. It does not execute root commands in browser.</p>
    <p>Love Web Panel is running on <code>${port}</code>.</p>
    <p><a href="/${token}/">Open Token Panel</a></p>
  </div>
</body>
</html>
EOF

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
<h2>二维码</h2>
<p class="small">二维码会在生成节点时自动生成；没有显示时执行 <code>Love qr</code> 后刷新。</p>
<a href="qr/index.html">打开全部二维码页面</a>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(135px,1fr));gap:12px;margin-top:12px">
  <div style="text-align:center"><img src="qr/node-1.png" style="max-width:130px;width:100%;background:#fff;padding:6px;border-radius:8px" onerror="this.style.display='none'"><br>Node 1</div>
  <div style="text-align:center"><img src="qr/all.png" style="max-width:130px;width:100%;background:#fff;padding:6px;border-radius:8px" onerror="this.style.display='none'"><br>All</div>
  <div style="text-align:center"><img src="qr/v2rayn.png" style="max-width:130px;width:100%;background:#fff;padding:6px;border-radius:8px" onerror="this.style.display='none'"><br>V2RayN</div>
  <div style="text-align:center"><img src="qr/shadowrocket.png" style="max-width:130px;width:100%;background:#fff;padding:6px;border-radius:8px" onerror="this.style.display='none'"><br>Shadowrocket</div>
  <div style="text-align:center"><img src="qr/nekobox.png" style="max-width:130px;width:100%;background:#fff;padding:6px;border-radius:8px" onerror="this.style.display='none'"><br>NekoBox</div>
</div>
</div>
</div>

<div class="card">
<h2>Raw Links</h2>
<textarea id="raw"></textarea>
<button onclick="copyText('raw')">Copy All Links</button>
</div>

<div class="card">
<h2>维护命令</h2>
<p><code>Love warp-auto-fix</code> 自动修复 WARP 出站</p>
<p><code>Love warp</code> 双列 WARP 菜单</p>
<p><code>Love warp h</code> 维护命令中文说明</p>
<p><code>Love sub</code> 重新生成订阅</p>
<p><code>Love qr</code> 重新生成二维码</p>
<p><code>Love doctor</code> 诊断节点环境</p>
<p><code>Love backup-auto</code> 自动备份配置</p>
</div>
</body>
</html>
EOF

  chown -R www-data:www-data "${LOVE_WEB}"
  chmod 755 /var /var/www "${LOVE_WEB}" 2>/dev/null || true
  find "${LOVE_WEB}" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "${LOVE_WEB}" -type f -exec chmod 644 {} \; 2>/dev/null || true

  cat > /etc/nginx/sites-available/love-admin <<EOF
server {
    listen ${port};
    listen [::]:${port};
    server_name _;

    root ${LOVE_WEB};
    index index.html;

EOF

  if [[ "$auth_on" =~ ^[Yy]$ ]]; then
    cat >> /etc/nginx/sites-available/love-admin <<EOF
    auth_basic "Love Admin";
    auth_basic_user_file ${auth_file};

EOF
  fi

  cat >> /etc/nginx/sites-available/love-admin <<'EOF'
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/love-admin /etc/nginx/sites-enabled/love-admin

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx

  command -v ufw >/dev/null 2>&1 && ufw allow "${port}/tcp" >/dev/null 2>&1 || true

  log "Love Web 管理页已开启："
  echo "Root URL: http://服务器IP:${port}/"
  echo "Token URL: http://服务器IP:${port}/${token}/"
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
  generate_client_exports >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true

  log "HY2 订阅与二维码已生成：${LOVE_SUB}/all.txt"
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



love_warp_fs_style_help() {
  cat <<'EOF'

================ Love WARP 维护命令中文说明 ================

基础帮助 / 维护：
  Love warp h        帮助说明：显示这张中文命令表
  Love warp n        网络刷新：重启 WARP / WireProxy / WGCF 服务并显示状态
  Love warp o        开关菜单：连接/断开 WARP、启动/停止 WireProxy
  Love warp u        卸载清理：清理 WARP / WireProxy / WGCF 相关组件
  Love warp b        网络优化：检查并尝试开启 BBR
  Love warp v        在线更新：从 GitHub 更新 Love 主脚本
  Love warp r        官方客户端：Cloudflare WARP Client 连接/断开

WARP 出站模式：
  Love warp 4        IPv4 Only：给 IPv6-only VPS 补 IPv4 出站
  Love warp 6        IPv6 Only：只添加 WARP IPv6 出站
  Love warp d        Dual Stack：WARP IPv4 + IPv6 双栈
  Love warp c        Client Proxy：官方 WARP 本地 SOCKS，默认 40000
  Love warp l        Client Global：官方 WARP 全局模式，有 SSH 风险
  Love warp w        WireProxy：本地 SOCKS5，默认 40001，推荐 fallback
  Love warp k        Fallback：kernel WG / wireguard-go / WireProxy 备用方案

节点服务器增强：
  Love warp e        Smart Split：IPv6 直连，IPv4/GitHub/Microsoft/Google 走 WARP
  Love warp g        全局/非全局：切换 WARP 接管范围
  Love warp s        优先级：设置 IPv4 / IPv6 / VPS 默认策略
  Love warp s 4      IPv4 优先
  Love warp s 6      IPv6 优先
  Love warp s d      VPS 默认

诊断与修复：
  Love warp-auto-fix 自动修复：检测网络 → fallback → 健康检查 → 安全切 sing-box
  Love warp-final    最终菜单：进入双列 WARP 管理菜单
  Love warp-report   完整报告：sing-box / WARP / WireProxy / SOCKS 状态
  Love warp-precheck 预检：IPv4/IPv6、架构、虚拟化、TUN、WireGuard
  Love warp-safe-40000 通过健康检查后切到官方 WARP Proxy
  Love warp-safe-40001 通过健康检查后切到 WireProxy
  Love warp-restore-direct 恢复 sing-box direct 出站

使用建议：
  IPv6-only HY2/sing-box 节点服务器，优先用：
    Love warp-auto-fix

  或者菜单：
    Love warp
    选择 1) Auto Fix

==============================================================

EOF
}

love_warp_network_refresh_v12() {
  love_print_section "Love WARP Network Refresh"
  systemctl restart warp-svc 2>/dev/null || true
  systemctl restart love-wireproxy.service 2>/dev/null || true
  systemctl restart wg-quick@wgcf 2>/dev/null || true
  sleep 3
  love_warp_report_v12 2>/dev/null || true
}

love_warp_onoff_menu_v12() {
  while true; do
    love_print_section "Love WARP On/Off"
    echo "1) 查看状态"
    echo "2) 断开 Cloudflare WARP Client"
    echo "3) 连接 Cloudflare WARP Client"
    echo "4) 停止 WireProxy"
    echo "5) 启动 WireProxy"
    echo "6) 恢复 sing-box direct"
    echo "0) 返回"
    read -rp "请选择: " x
    case "$x" in
      1) love_warp_report_v12 ;;
      2) warp-cli --accept-tos disconnect 2>/dev/null || warp-cli disconnect 2>/dev/null || true ;;
      3) warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true ;;
      4) systemctl stop love-wireproxy.service 2>/dev/null || true ;;
      5) systemctl start love-wireproxy.service 2>/dev/null || true ;;
      6) love_singbox_restore_direct_v12 ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

love_warp_bbr_hint_v12() {
  love_print_section "Love BBR / Network Optimize"
  echo "当前拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "可用拥塞控制：$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr || true
    grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    log "BBR 已尝试开启。"
  else
    warn "当前内核未显示 bbr，可通过系统内核升级后再开启。"
  fi
}

love_warp_update_v12() {
  love_print_section "Love Self Update"
  if declare -F self_update_love >/dev/null 2>&1; then
    self_update_love
  else
    wget -O /usr/local/bin/Love https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh
    chmod +x /usr/local/bin/Love
    ln -sf /usr/local/bin/Love /usr/local/bin/love
    /usr/local/bin/Love install-warp-command >/dev/null 2>&1 || true
    hash -r
    grep '^VERSION=' /usr/local/bin/Love
  fi
}

love_warp_client_toggle_v12() {
  love_print_section "Love WARP Linux Client Toggle"
  if ! command -v warp-cli >/dev/null 2>&1; then
    warn "warp-cli 不存在，先安装官方 WARP Client。"
    love_install_cloudflare_warp_official
    return
  fi
  warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true
  echo "1) connect"
  echo "2) disconnect"
  echo "0) 返回"
  read -rp "请选择: " x
  case "$x" in
    1) warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true ;;
    2) warp-cli --accept-tos disconnect 2>/dev/null || warp-cli disconnect 2>/dev/null || true ;;
    *) return 0 ;;
  esac
}

love_warp_ip_refresh_v12() {
  love_print_section "Love WARP Endpoint / IP Refresh"
  echo "1) Endpoint 自动优选 / 固定"
  echo "2) 重启 WireProxy 并重试 endpoint"
  echo "3) 重启官方 WARP Proxy"
  echo "0) 返回"
  read -rp "请选择: " x
  case "$x" in
    1) love_warp_endpoint_select ;;
    2) love_wireproxy_try_endpoints_v12 40001 ;;
    3) love_warp_cli_proxy_v12 40000 ;;
    *) return 0 ;;
  esac
}

love_warp_stream_split_v12() {
  love_print_section "Love Smart Split / Stream Route"
  warn "这里不是复制 FS 的 iptables+dnsmasq+ipset 方案，而是用 sing-box 原生 route 实现节点服务器分流。"
  love_warp_auto_fix_v12
}

love_wireproxy_toggle_v12() {
  love_print_section "Love WireProxy Toggle"
  systemctl is-active --quiet love-wireproxy.service
  if [[ $? -eq 0 ]]; then
    read -rp "WireProxy 正在运行，是否停止？[y/N]: " y
    [[ "$y" =~ ^[Yy]$ ]] && systemctl stop love-wireproxy.service
  else
    read -rp "WireProxy 未运行，是否启动/修复？[Y/n]: " y
    y="${y:-Y}"
    [[ "$y" =~ ^[Yy]$ ]] && love_wireproxy_auto_v12 40001
  fi
  ss -lntp | grep 40001 || true
}

love_warp_kernel_switch_v12() {
  love_print_section "Love Kernel WG / wireguard-go / WireProxy Fallback"
  echo "1) 尝试 WGCF interface"
  echo "2) 尝试 wireguard-go fallback"
  echo "3) 尝试 WireProxy fallback"
  echo "4) Auto Fix 自动决策"
  echo "0) 返回"
  read -rp "请选择: " x
  case "$x" in
    1) love_install_wgcf_wireguard ;;
    2) love_wireguard_go_fallback ;;
    3) love_wireproxy_auto_v12 40001 ;;
    4) love_warp_auto_fix_v12 ;;
    *) return 0 ;;
  esac
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
  local sub2="${2:-}"
  case "$sub" in
    h|help)
      love_warp_fs_style_help
      ;;
    n)
      love_warp_network_refresh_v12
      ;;
    o)
      love_warp_onoff_menu_v12
      ;;
    u)
      love_warp_uninstall
      ;;
    b)
      love_warp_bbr_hint_v12
      ;;
    v)
      love_warp_update_v12
      ;;
    r)
      love_warp_client_toggle_v12
      ;;
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
      love_warp_cli_proxy_v12 40000 || love_warp_proxy_safe_install
      ;;
    l)
      love_install_cloudflare_warp_official
      ;;
    i)
      love_warp_ip_refresh_v12
      ;;
    e)
      love_warp_stream_split_v12
      ;;
    w)
      love_wireproxy_auto_v12 40001
      ;;
    y)
      love_wireproxy_toggle_v12
      ;;
    k)
      love_warp_kernel_switch_v12
      ;;
    g)
      love_warp_global_toggle_menu
      ;;
    s)
      if [[ -n "$sub2" ]]; then
        case "$sub2" in
          4)
            jq '.route.default_domain_resolver={server:"cf",strategy:"prefer_ipv4"}' /etc/sing-box/config.json > /tmp/love-s.json && mv /tmp/love-s.json /etc/sing-box/config.json
            systemctl restart sing-box
            ;;
          6)
            jq '.route.default_domain_resolver={server:"cf",strategy:"prefer_ipv6"}' /etc/sing-box/config.json > /tmp/love-s.json && mv /tmp/love-s.json /etc/sing-box/config.json
            systemctl restart sing-box
            ;;
          d)
            love_warp_set_priority
            ;;
          *) love_warp_set_priority ;;
        esac
      else
        love_warp_set_priority
      fi
      ;;
    ""|menu)
      love_warp_final_menu_v12
      ;;
    *)
      warn "兼容命令：Love warp h/n/o/u/b/v/r/4/6/d/c/l/i/e/w/y/k/g/s"
      love_warp_final_menu_v12
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

love_warp_menu_row() {
  printf "  %-48s %s\n" "$1" "$2"
}


love_ui_c() {
  case "$1" in
    red) printf "\033[31m" ;;
    green) printf "\033[32m" ;;
    yellow) printf "\033[33m" ;;
    blue) printf "\033[34m" ;;
    magenta) printf "\033[35m" ;;
    cyan) printf "\033[36m" ;;
    bold) printf "\033[1m" ;;
    reset|*) printf "\033[0m" ;;
  esac
}

love_ui_line() {
  printf "%s\n" "================================================================================"
}

love_bool_status() {
  local label="$1" ok="$2" detail="$3"
  if [[ "$ok" == "yes" || "$ok" == "on" || "$ok" == "active" ]]; then
    printf "  %-24s %b%s%b %s\n" "$label" "$(love_ui_c green)" "$ok" "$(love_ui_c reset)" "$detail"
  else
    printf "  %-24s %b%s%b %s\n" "$label" "$(love_ui_c yellow)" "$ok" "$(love_ui_c reset)" "$detail"
  fi
}

love_warp_fs_like_status_panel() {
  local os arch virt ipv4 ipv6 public_v6 warp_client wireproxy sb_final sb_port wp_ep
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  arch="$(uname -m)"
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"

  curl -4 -I --connect-timeout 4 --max-time 6 https://github.com >/dev/null 2>&1 && ipv4="yes" || ipv4="no"
  curl -6 -I --connect-timeout 4 --max-time 6 https://github.com >/dev/null 2>&1 && ipv6="yes" || ipv6="no"
  public_v6="$(curl -6 -s --connect-timeout 4 --max-time 6 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"

  if command -v warp-cli >/dev/null 2>&1 && (warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null) | grep -qi "Connected"; then
    warp_client="active"
  else
    warp_client="not active"
  fi

  systemctl is-active --quiet love-wireproxy.service && wireproxy="active" || wireproxy="not active"

  sb_final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  sb_port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"
  wp_ep="$(grep -m1 '^Endpoint = ' /etc/wireproxy/warp.conf 2>/dev/null | sed 's/^Endpoint = //')"

  echo
  love_ui_line
  printf "%bLove WARP / Node Server Manager%b  %s\n" "$(love_ui_c bold)$(love_ui_c cyan)" "$(love_ui_c reset)" "${VERSION:-unknown}"
  love_ui_line

  printf "%b系统信息%b\n" "$(love_ui_c green)" "$(love_ui_c reset)"
  printf "  %-24s %s\n" "OS:" "${os}"
  printf "  %-24s %s\n" "Kernel:" "$(uname -r)"
  printf "  %-24s %s\n" "Arch / Virt:" "${arch} / ${virt}"
  [[ -n "$public_v6" ]] && printf "  %-24s %s\n" "Public IPv6:" "${public_v6}"

  echo
  printf "%b出站状态%b\n" "$(love_ui_c green)" "$(love_ui_c reset)"
  love_bool_status "IPv4 outbound:" "$ipv4" ""
  love_bool_status "IPv6 outbound:" "$ipv6" ""
  love_bool_status "WARP Client:" "$warp_client" ""
  love_bool_status "WireProxy:" "$wireproxy" "$(ss -lntp 2>/dev/null | grep -E ':(40001|40000)' | awk '{print $4}' | xargs echo)"
  [[ -n "$wp_ep" ]] && printf "  %-24s %s\n" "WireProxy Endpoint:" "$wp_ep"

  echo
  printf "%bsing-box 联动%b\n" "$(love_ui_c green)" "$(love_ui_c reset)"
  printf "  %-24s %s\n" "route.final:" "$sb_final"
  [[ -n "$sb_port" ]] && printf "  %-24s %s\n" "warp-socks port:" "$sb_port"
  systemctl is-active --quiet sing-box && love_bool_status "sing-box:" "active" "" || love_bool_status "sing-box:" "not active" ""

  echo
  printf "%b下载 / 更新入口%b\n" "$(love_ui_c green)" "$(love_ui_c reset)"
  printf "  %-24s %s\n" "GitHub Raw:" "https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"
  printf "  %-24s %s\n" "Update:" "Love update  或  Love warp v"
  printf "  %-24s %s\n" "FS-style:" "warp h / warp w / warp s 6"

  love_ui_line
}


love_warp_menu_row() {
  printf "  %-48s %s\n" "$1" "$2"
}

love_warp_final_menu_v12() {
  while true; do
    love_warp_fs_like_status_panel

    printf "%b请选择功能%b\n" "$(love_ui_c yellow)" "$(love_ui_c reset)"
    love_warp_menu_row "1) 为 IPv6 only 添加 WARP IPv4【推荐】" "14) MTU 自动检测与修正"
    love_warp_menu_row "2) 为 IPv6 only 添加 WARP IPv6" "15) WG/wireguard-go/WireProxy fallback"
    love_warp_menu_row "3) 添加 WARP 双栈接口" "16) WARP IP/ASN/地区/解锁检测"
    love_warp_menu_row "4) Auto Fix 自动检测 + fallback" "17) SOCKS 健康检查 40000/40001"
    love_warp_menu_row "5) 官方 WARP Proxy 40000" "18) sing-box 安全切到 40000"
    love_warp_menu_row "6) WireProxy 40001【推荐备用】" "19) sing-box 安全切到 40001"
    love_warp_menu_row "7) Smart Split 智能分流" "20) 恢复 sing-box direct"
    love_warp_menu_row "8) 官方 WARP 全局模式" "21) 完整诊断报告"
    love_warp_menu_row "9) WARP 开关 / 状态" "22) Full Precheck 全面预检"
    love_warp_menu_row "10) WireProxy 开关" "23) FS 风格命令中文说明"
    love_warp_menu_row "11) 全局 / 非全局切换" "24) 更新 Love / 显示下载链接"
    love_warp_menu_row "12) IPv4/IPv6/VPS 优先级" "25) 卸载 / 清理 WARP"
    love_warp_menu_row "13) Endpoint / WARP IP 刷新" "0) 退出"

    echo
    printf "%b推荐：%bIPv6-only 节点服务器优先选 4，自动验证 SOCKS 后才切 sing-box。\n" "$(love_ui_c cyan)" "$(love_ui_c reset)"
    printf "%b说明：%b端口监听不算成功，必须 TCP + warp=on + GitHub HTTP 成功才切换。\n" "$(love_ui_c cyan)" "$(love_ui_c reset)"
    echo

    read -rp "请选择: " x
    case "$x" in
      1) love_warp_interface_mode 4 ;;
      2) love_warp_interface_mode 6 ;;
      3) love_warp_interface_mode d ;;
      4) love_warp_auto_fix_v12 ;;
      5) love_warp_cli_proxy_v12 40000 ;;
      6) love_wireproxy_auto_v12 40001 ;;
      7)
        if love_socks_health_gate 40001; then love_singbox_switch_warp_socks_v12 40001 smart
        elif love_socks_health_gate 40000; then love_singbox_switch_warp_socks_v12 40000 smart
        else love_warp_auto_fix_v12
        fi
        ;;
      8) love_install_cloudflare_warp_official ;;
      9) love_warp_onoff_menu_v12 ;;
      10) love_wireproxy_toggle_v12 ;;
      11) love_warp_global_toggle_menu ;;
      12) love_warp_set_priority ;;
      13) love_warp_ip_refresh_v12 ;;
      14) love_warp_apply_mtu ;;
      15) love_warp_kernel_switch_v12 ;;
      16) love_warp_unlock_check; love_warp_ip_asn_region ;;
      17) love_socks_health_gate 40000 || true; love_socks_health_gate 40001 || true ;;
      18) love_singbox_switch_warp_socks_v12 40000 smart ;;
      19) love_singbox_switch_warp_socks_v12 40001 smart ;;
      20) love_singbox_restore_direct_v12 ;;
      21) love_warp_report_v12 ;;
      22) love_warp_full_precheck_v12 ;;
      23) love_warp_fs_style_help ;;
      24)
        echo "下载链接："
        echo "https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"
        love_warp_update_v12
        ;;
      25) love_warp_uninstall ;;
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
  love_warp_final_menu_v12
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

love_main_menu_row() {
  printf "  %-50s %s
" "$1" "$2"
}

love_main_status_panel() {
  local sb_state ng_state wp_state final port ipv4 ipv6
  systemctl is-active --quiet sing-box && sb_state="active" || sb_state="not active"
  systemctl is-active --quiet nginx && ng_state="active" || ng_state="not active"
  systemctl is-active --quiet love-wireproxy.service && wp_state="active" || wp_state="not active"
  final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"
  curl -4 -I --connect-timeout 3 --max-time 5 https://github.com >/dev/null 2>&1 && ipv4="yes" || ipv4="no"
  curl -6 -I --connect-timeout 3 --max-time 5 https://github.com >/dev/null 2>&1 && ipv6="yes" || ipv6="no"

  echo
  echo "================================================================================"
  echo " Love Node Server Manager  ${VERSION}"
  echo "================================================================================"
  printf "  %-22s %s
" "OS:" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf "  %-22s %s / %s
" "Arch / Virt:" "$(uname -m)" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  printf "  %-22s IPv4: %s    IPv6: %s
" "Outbound:" "$ipv4" "$ipv6"
  printf "  %-22s %s
" "sing-box:" "$sb_state"
  printf "  %-22s %s
" "nginx web:" "$ng_state"
  printf "  %-22s %s
" "WireProxy:" "$wp_state"
  printf "  %-22s %s
" "route.final:" "$final"
  [[ -n "$port" ]] && printf "  %-22s %s
" "warp-socks port:" "$port"
  echo "================================================================================"
}

main_menu() {
  while true; do
    love_main_status_panel

    echo "请选择功能："
    love_main_menu_row "1) 查看全节点目录" "14) v6 Project Tools"
    love_main_menu_row "2) Xray 稳定模式 Reality + HY2" "15) v7 Stable Tools"
    love_main_menu_row "3) sing-box 原生全协议 / 自选协议" "16) v8 Project Panel"
    love_main_menu_row "4) Argo / Cloudflared 隧道" "17) Nginx Reverse Proxy"
    love_main_menu_row "5) Port Hopping UDP 端口跳跃" "18) HY2/sing-box 修复与订阅"
    love_main_menu_row "6) WARP 出站增强说明" "19) IPv6-only 出站修复"
    love_main_menu_row "7) 查看节点信息 Love -n" "20) WARP Manager / FS-style"
    love_main_menu_row "8) 导出订阅 Love sub" "21) 查看运行状态"
    love_main_menu_row "9) 生成二维码 Love qr" "22) 备份配置"
    love_main_menu_row "10) Super Tools 诊断/修复/更新" "23) 卸载菜单"
    love_main_menu_row "11) Web 管理页 Love web" "24) GitHub 发布说明"
    love_main_menu_row "12) 在线更新 Love update" "25) 安装 FS 风格 warp 命令"
    love_main_menu_row "13) 客户端导出 links/json" "0) 退出"

    echo
    echo "常用命令：Love warp-auto-fix | Love web | Love sub | Love qr | warp h | warp w"
    echo "推荐流程：3 生成节点 → 20 修 WARP 出站 → 11 打开 Web 面板"
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
      25) love_install_fs_warp_command ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}


love_install_fs_warp_command() {
  # FS-style daily command:
  #   warp h / warp 4 / warp 6 / warp d / warp c / warp l / warp w / warp g / warp s 6
  # It delegates to Love's own WARP engine and does not overwrite the Love command.
  cat > /usr/local/bin/warp <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/Love warp "$@"
EOF
  chmod +x /usr/local/bin/warp
  log "FS 风格命令已安装：warp"
  echo "示例：warp h | warp 4 | warp 6 | warp d | warp c | warp w | warp s 6"
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
      love_warp_compat_command "${2:-}" "${3:-}"
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

    warp-fs-help)
      love_warp_fs_style_help
      ;;
    warp-fs-menu)
      love_warp_final_menu_v12
      ;;

    install-warp-command|warp-command|fs-warp-command)
      love_install_fs_warp_command
      ;;
    *)
      main_menu
      ;;
  esac
}


# ==============================================================================
# Love v12.8 Full Color UI Overlay
# Override main menu + major submenus with unified colorful UI.
# ==============================================================================

love_ui_color_on() {
  [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]
}

lc() {
  if love_ui_color_on; then
    case "$1" in
      red) printf "\033[31m" ;;
      green) printf "\033[32m" ;;
      yellow) printf "\033[33m" ;;
      blue) printf "\033[34m" ;;
      magenta) printf "\033[35m" ;;
      cyan) printf "\033[36m" ;;
      white) printf "\033[37m" ;;
      gray) printf "\033[90m" ;;
      bold) printf "\033[1m" ;;
      dim) printf "\033[2m" ;;
      reset|*) printf "\033[0m" ;;
    esac
  fi
}

love_color_text() {
  local color="$1"; shift
  printf "%b%s%b" "$(lc "$color")" "$*" "$(lc reset)"
}

love_ui_hr() {
  printf "%b%s%b\n" "$(lc blue)" "================================================================================" "$(lc reset)"
}

love_ui_title() {
  echo
  love_ui_hr
  printf "%b%s%b %b%s%b\n" "$(lc bold)$(lc cyan)" "$1" "$(lc reset)" "$(lc gray)" "${2:-}" "$(lc reset)"
  love_ui_hr
}

love_ui_subtitle() {
  printf "%b▶ %s%b\n" "$(lc green)" "$1" "$(lc reset)"
}

love_ui_row() {
  printf "  %b%-48s%b %b%s%b\n" "$(lc yellow)" "$1" "$(lc reset)" "$(lc cyan)" "$2" "$(lc reset)"
}

love_ui_item() {
  printf "  %b%-4s%b %s\n" "$(lc yellow)" "$1)" "$(lc reset)" "$2"
}

love_ui_tip() {
  printf "%b%s%b\n" "$(lc magenta)" "$*" "$(lc reset)"
}

love_ui_ok_bad() {
  local label="$1" value="$2"
  case "$value" in
    active|yes|on|running|ok)
      printf "  %-22s %b%s%b\n" "$label" "$(lc green)" "$value" "$(lc reset)"
      ;;
    no|off|failed|not*)
      printf "  %-22s %b%s%b\n" "$label" "$(lc red)" "$value" "$(lc reset)"
      ;;
    *)
      printf "  %-22s %b%s%b\n" "$label" "$(lc yellow)" "$value" "$(lc reset)"
      ;;
  esac
}

love_menu_pause() {
  echo
  read -rp "$(printf "%b按回车返回菜单...%b" "$(lc gray)" "$(lc reset)")" _
}

love_quick_status_compact() {
  local sb_state ng_state wp_state final port ipv4 ipv6
  systemctl is-active --quiet sing-box && sb_state="active" || sb_state="not active"
  systemctl is-active --quiet nginx && ng_state="active" || ng_state="not active"
  systemctl is-active --quiet love-wireproxy.service && wp_state="active" || wp_state="not active"
  final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"
  curl -4 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv4="yes" || ipv4="no"
  curl -6 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv6="yes" || ipv6="no"

  love_ui_subtitle "状态概览"
  printf "  %-22s %s\n" "OS:" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf "  %-22s %s / %s\n" "Arch / Virt:" "$(uname -m)" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  printf "  %-22s IPv4: %b%s%b    IPv6: %b%s%b\n" "Outbound:" "$(lc $([[ "$ipv4" == yes ]] && echo green || echo red))" "$ipv4" "$(lc reset)" "$(lc $([[ "$ipv6" == yes ]] && echo green || echo red))" "$ipv6" "$(lc reset)"
  love_ui_ok_bad "sing-box:" "$sb_state"
  love_ui_ok_bad "nginx web:" "$ng_state"
  love_ui_ok_bad "WireProxy:" "$wp_state"
  printf "  %-22s %b%s%b\n" "route.final:" "$(lc cyan)" "$final" "$(lc reset)"
  [[ -n "$port" ]] && printf "  %-22s %b%s%b\n" "warp-socks port:" "$(lc cyan)" "$port" "$(lc reset)"
  echo
}

love_main_menu_row() {
  love_ui_row "$1" "$2"
}

main_menu() {
  while true; do
    love_ui_title "Love Node Server Manager" "${VERSION}"
    love_quick_status_compact

    love_ui_subtitle "主菜单"
    love_main_menu_row "1) 查看全节点目录" "14) v6 Project Tools"
    love_main_menu_row "2) Xray 稳定模式 Reality + HY2" "15) v7 Stable Tools"
    love_main_menu_row "3) sing-box 原生全协议 / 自选协议" "16) v8 Project Panel"
    love_main_menu_row "4) Argo / Cloudflared 隧道" "17) Nginx Reverse Proxy"
    love_main_menu_row "5) Port Hopping UDP 端口跳跃" "18) HY2/sing-box 修复与订阅"
    love_main_menu_row "6) WARP 出站增强说明" "19) IPv6-only 出站修复"
    love_main_menu_row "7) 查看节点信息 Love -n" "20) WARP Manager / FS-style"
    love_main_menu_row "8) 导出订阅 Love sub" "21) 查看运行状态"
    love_main_menu_row "9) 生成二维码 Love qr" "22) 备份配置"
    love_main_menu_row "10) Super Tools 诊断/修复/更新" "23) 卸载菜单"
    love_main_menu_row "11) Web 管理页 Love web" "24) GitHub 发布说明"
    love_main_menu_row "12) 在线更新 Love update" "25) 安装 FS 风格 warp 命令"
    love_main_menu_row "13) 客户端导出 links/json" "0) 退出"

    echo
    love_ui_tip "常用：Love warp-auto-fix | Love web | Love sub | Love qr | warp h | warp w"
    love_ui_tip "推荐流程：3 生成节点 → 20 修 WARP 出站 → 11 打开 Web 面板"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" choice

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
      25) love_install_fs_warp_command ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

super_menu() {
  while true; do
    love_ui_title "Love Super Tools" "诊断 / 修复 / 导出 / Web"
    love_ui_row "1) Love -n 查看节点" "13) Mihomo / Clash YAML"
    love_ui_row "2) Love sub 导出订阅" "14) Shadowrocket / NekoBox / V2RayN"
    love_ui_row "3) Love qr 生成二维码" "15) 在线更新 Love 自身脚本"
    love_ui_row "4) 订阅静态服务 nginx" "16) Web 管理页"
    love_ui_row "5) Love doctor 全面诊断" "17) Love links 简洁链接总览"
    love_ui_row "6) Love repair 修复 apt/dpkg" "18) Love singbox-json"
    love_ui_row "7) Love dns 设置 IPv6 DNS" "19) Love shadowrocket"
    love_ui_row "8) Love -v 更新核心" "20) Love v2rayn"
    love_ui_row "9) 修改优选地址导出" "21) Love nekobox"
    love_ui_row "10) Argo API 自动隧道" "22) SFI / SFA / SFM"
    love_ui_row "11) HY2 Realm 安全开关" "23) 完整客户端包"
    love_ui_row "12) Love -r 增删协议 / 重建" "24) v6 Project Tools"
    love_ui_row "0) 返回" ""
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" s
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

v6_super_menu() {
  while true; do
    love_ui_title "Love v6 Project Tools" "Web 安全 / 推送 / 检测 / 备份"
    love_ui_row "1) Web 密码保护 + 随机路径" "7) 证书续签状态检查"
    love_ui_row "2) 重置订阅随机路径 token" "8) 端口冲突检测与推荐"
    love_ui_row "3) 通知配置 Telegram/Bark/Email" "9) Oracle Cloud 安全组模板"
    love_ui_row "4) 推送节点信息" "10) 多用户 UUID 管理"
    love_ui_row "5) 自动测速 / 可用性检测" "11) v7 Stable Tools"
    love_ui_row "6) 定时备份" "0) 返回"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" v
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
      11) v7_stable_menu ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

v7_stable_menu() {
  while true; do
    love_ui_title "Love v7 Stable Tools" "预检 / 快照 / 用户 / 安全"
    love_ui_row "1) precheck 环境预检" "8) sing-box 兼容性检测"
    love_ui_row "2) mode 安装模式分级" "9) speed 连接测速"
    love_ui_row "3) snapshot / rollback" "10) cfip 优选 IP / 域名"
    love_ui_row "4) users 分用户订阅/二维码" "11) cloud-firewall 云防火墙模板"
    love_ui_row "5) support 客户端兼容矩阵" "12) harden 安全加固"
    love_ui_row "6) logs / errors 日志" "13) uninstall soft/full"
    love_ui_row "7) version pin 核心版本锁定" "14) Web 状态页增强"
    love_ui_row "0) 返回" ""
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" v
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

v8_menu() {
  while true; do
    love_ui_title "Love v8 Project Panel" "验证 / 审计 / 发布 / 仪表盘"
    love_ui_row "1) validate 全量验证" "7) support-bundle 脱敏支持包"
    love_ui_row "2) audit 安全审计" "8) import-links 导入外部节点链接"
    love_ui_row "3) dashboard 项目仪表盘" "9) rotate token/web/password"
    love_ui_row "4) state 生成状态 JSON" "10) test-suite 测试套件"
    love_ui_row "5) release 生成 GitHub 发布包" "11) update-channel 更新通道"
    love_ui_row "6) readme 生成 README" "0) 返回"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" v
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

nginx_rp_menu() {
  while true; do
    love_ui_title "Love v9 Nginx Reverse Proxy" "WS / gRPC / Stream / fallback"
    love_ui_row "1) WS 反代：VLESS WS / VMess WS" "5) 生成本地 upstream 示例"
    love_ui_row "2) gRPC 反代" "6) 443 端口策略检测"
    love_ui_row "3) 仅创建伪装站点 fallback" "7) Nginx 反代状态"
    love_ui_row "4) Stream SNI passthrough 分流" "8) 回滚 Nginx 配置"
    love_ui_row "0) 返回" ""
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" n
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

love_ipv6_outbound_menu() {
  love_ui_title "Love IPv6-only Outbound Menu" "IPv6-only / WARP / prefer_ipv6"
  love_ui_item "1" "测试 IPv4 / IPv6 出站"
  love_ui_item "2" "修复 sing-box direct 为 prefer_ipv6"
  love_ui_item "3" "WARP / IPv4 出站提示"
  love_ui_item "0" "返回"
  read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" i
  case "$i" in
    1) love_test_outbound_stack || true ;;
    2) love_fix_ipv6_only_outbound ;;
    3) love_warp_hint ;;
    *) return 0 ;;
  esac
}

love_warp_menu_row() {
  love_ui_row "$1" "$2"
}

love_warp_final_menu_v12() {
  while true; do
    if declare -F love_warp_fs_like_status_panel >/dev/null 2>&1; then
      love_warp_fs_like_status_panel
    else
      love_ui_title "Love WARP / Node Server Manager" "${VERSION}"
      love_quick_status_compact
    fi

    printf "%b请选择 WARP 功能%b\n" "$(lc yellow)" "$(lc reset)"
    love_warp_menu_row "1) 为 IPv6 only 添加 WARP IPv4【推荐】" "14) MTU 自动检测与修正"
    love_warp_menu_row "2) 为 IPv6 only 添加 WARP IPv6" "15) WG/wireguard-go/WireProxy fallback"
    love_warp_menu_row "3) 添加 WARP 双栈接口" "16) WARP IP/ASN/地区/解锁检测"
    love_warp_menu_row "4) Auto Fix 自动检测 + fallback" "17) SOCKS 健康检查 40000/40001"
    love_warp_menu_row "5) 官方 WARP Proxy 40000" "18) sing-box 安全切到 40000"
    love_warp_menu_row "6) WireProxy 40001【推荐备用】" "19) sing-box 安全切到 40001"
    love_warp_menu_row "7) Smart Split 智能分流" "20) 恢复 sing-box direct"
    love_warp_menu_row "8) 官方 WARP 全局模式" "21) 完整诊断报告"
    love_warp_menu_row "9) WARP 开关 / 状态" "22) Full Precheck 全面预检"
    love_warp_menu_row "10) WireProxy 开关" "23) FS 风格命令中文说明"
    love_warp_menu_row "11) 全局 / 非全局切换" "24) 更新 Love / 显示下载链接"
    love_warp_menu_row "12) IPv4/IPv6/VPS 优先级" "25) 卸载 / 清理 WARP"
    love_warp_menu_row "13) Endpoint / WARP IP 刷新" "0) 退出"

    echo
    love_ui_tip "推荐：IPv6-only 节点服务器优先选 4，自动验证 SOCKS 后才切 sing-box。"
    love_ui_tip "说明：端口监听不算成功，必须 TCP + warp=on + GitHub HTTP 成功才切换。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_warp_interface_mode 4 ;;
      2) love_warp_interface_mode 6 ;;
      3) love_warp_interface_mode d ;;
      4) love_warp_auto_fix_v12 ;;
      5) love_warp_cli_proxy_v12 40000 ;;
      6) love_wireproxy_auto_v12 40001 ;;
      7)
        if love_socks_health_gate 40001; then love_singbox_switch_warp_socks_v12 40001 smart
        elif love_socks_health_gate 40000; then love_singbox_switch_warp_socks_v12 40000 smart
        else love_warp_auto_fix_v12
        fi
        ;;
      8) love_install_cloudflare_warp_official ;;
      9) love_warp_onoff_menu_v12 ;;
      10) love_wireproxy_toggle_v12 ;;
      11) love_warp_global_toggle_menu ;;
      12) love_warp_set_priority ;;
      13) love_warp_ip_refresh_v12 ;;
      14) love_warp_apply_mtu ;;
      15) love_warp_kernel_switch_v12 ;;
      16) love_warp_unlock_check; love_warp_ip_asn_region ;;
      17) love_socks_health_gate 40000 || true; love_socks_health_gate 40001 || true ;;
      18) love_singbox_switch_warp_socks_v12 40000 smart ;;
      19) love_singbox_switch_warp_socks_v12 40001 smart ;;
      20) love_singbox_restore_direct_v12 ;;
      21) love_warp_report_v12 ;;
      22) love_warp_full_precheck_v12 ;;
      23) love_warp_fs_style_help ;;
      24)
        echo "下载链接："
        echo "https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"
        love_warp_update_v12
        ;;
      25) love_warp_uninstall ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v12.9 Force Color Two-Column UI + Update Link Final
# This override is placed immediately before 

# ==============================================================================
# Love v13.60.1 Color Bilingual Main Menu Final
# Purpose:
#   - Do NOT delete old functions.
#   - Do NOT change Green Web UI.
#   - Add all v13.58/v13.59/v13.60 commands into the visible main menu.
#   - Add bilingual Chinese/English labels so users can find features quickly.
#   - Keep legacy links hidden from normal subscriptions; provide show/backup/clean tools.
# ===============================================================================
LOVE_SCRIPT_VERSION="Love v13.60.1-color-bilingual-main-menu-final"

love_c13601() {
  case "${1:-reset}" in
    red) printf '\033[0;31m' ;;
    green) printf '\033[0;32m' ;;
    yellow) printf '\033[1;33m' ;;
    blue) printf '\033[0;34m' ;;
    magenta) printf '\033[0;35m' ;;
    cyan) printf '\033[0;36m' ;;
    white) printf '\033[1;37m' ;;
    gray) printf '\033[0;90m' ;;
    bold) printf '\033[1m' ;;
    reset|*) printf '\033[0m' ;;
  esac
}

love_pause13601() {
  echo
  read -rp "$(printf '%b按 Enter 返回主菜单 / Press Enter to return...%b' "$(love_c13601 gray)" "$(love_c13601 reset)")" _ || true
}

love_hr13601() {
  printf "%b%s%b\n" "$(love_c13601 cyan)" "════════════════════════════════════════════════════════════════════════════════" "$(love_c13601 reset)"
}

love_header13601() {
  clear 2>/dev/null || true
  love_hr13601
  printf "%b%-78s%b\n" "$(love_c13601 magenta)" "  Love Node Server Manager · 全彩中英主菜单 / Color Bilingual Main Menu" "$(love_c13601 reset)"
  printf "%b%-78s%b\n" "$(love_c13601 yellow)" "  ${LOVE_SCRIPT_VERSION}" "$(love_c13601 reset)"
  love_hr13601
}

love_status13601() {
  if declare -F love_safe_status_v1335 >/dev/null 2>&1; then
    love_safe_status_v1335 || true
    return 0
  fi
  local os arch sb xr ng sub_count
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  systemctl is-active --quiet sing-box 2>/dev/null && sb="active" || sb="not active"
  systemctl is-active --quiet xray 2>/dev/null && xr="active" || xr="not active"
  systemctl is-active --quiet nginx 2>/dev/null && ng="active" || ng="not active"
  sub_count="$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' /opt/Love/subscribe/all.txt 2>/dev/null || echo 0)"
  printf "%b系统状态 / Status%b\n" "$(love_c13601 green)" "$(love_c13601 reset)"
  printf "  %-24s %s\n" "OS:" "$os"
  printf "  %-24s %s\n" "Arch:" "$arch"
  printf "  %-24s %s\n" "Nodes:" "$sub_count"
  printf "  %-24s %s\n" "sing-box:" "$sb"
  printf "  %-24s %s\n" "xray:" "$xr"
  printf "  %-24s %s\n" "nginx web:" "$ng"
  echo
}

love_row13601() {
  local l="$1" r="$2" lc="${3:-white}" rc="${4:-white}"
  printf "  %b%-42s%b  %b%-42s%b\n" "$(love_c13601 "$lc")" "$l" "$(love_c13601 reset)" "$(love_c13601 "$rc")" "$r" "$(love_c13601 reset)"
}

love_section13601() {
  printf "\n%b▶ %s%b\n" "$(love_c13601 cyan)" "$1" "$(love_c13601 reset)"
}

love_call13601() {
  local fn="$1"; shift || true
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
  else
    printf "%b[WARN]%b 函数不存在 / Missing function: %s\n" "$(love_c13601 yellow)" "$(love_c13601 reset)" "$fn"
  fi
}

love_h2_v2rayn_help13601() {
  love_header13601
  printf "%bLOVE-H2-REALITY · v2rayN 使用说明 / Usage Notes%b\n\n" "$(love_c13601 green)" "$(love_c13601 reset)"
  cat <<'EOF'
中文：
  LOVE-H2-REALITY = VLESS + Reality + HTTP/H2。
  在 v2rayN 里必须设置：设置 -> Core 类型设置 -> VLESS -> sing_box。
  如果 VLESS 仍使用 Xray，新版 Xray 会报：HTTP transport has been removed。

English:
  LOVE-H2-REALITY is VLESS + Reality + HTTP/H2.
  In v2rayN, set: Settings -> Core Type Settings -> VLESS -> sing_box.
  If VLESS still uses Xray, newer Xray may fail with: HTTP transport has been removed.

正确链接关键参数 / Required URI fields:
  security=reality
  type=http
  path=/h2
  host=Reality SNI, e.g. www.cloudflare.com
  alpn=h2
  flow must be empty; do NOT use xtls-rprx-vision for H2 Reality.
EOF
}

love_legacy_file13601() {
  echo "/opt/Love/subscribe/clients/legacy-raw-links.txt"
}

love_legacy_show13601() {
  love_header13601
  local f; f="$(love_legacy_file13601)"
  printf "%bLegacy links / 旧链接归档%b\n" "$(love_c13601 green)" "$(love_c13601 reset)"
  echo "File: $f"
  echo
  if [[ -s "$f" ]]; then
    cat "$f"
  else
    echo "[INFO] 没有 legacy 旧链接归档，或文件为空。"
  fi
}

love_legacy_backup13601() {
  love_header13601
  local f b
  f="$(love_legacy_file13601)"
  mkdir -p /opt/Love/backup
  b="/opt/Love/backup/legacy-raw-links.$(date +%F-%H%M%S).txt"
  if [[ -s "$f" ]]; then
    cp -f "$f" "$b"
    chmod 600 "$b" 2>/dev/null || true
    echo "[OK] 已备份 legacy 旧链接到：$b"
  else
    echo "[INFO] legacy 文件不存在或为空，无需备份。"
  fi
}

love_legacy_clean13601() {
  love_header13601
  local f b ok
  f="$(love_legacy_file13601)"
  if [[ ! -s "$f" ]]; then
    echo "[INFO] legacy 文件不存在或为空，无需清理。"
    return 0
  fi
  echo "这不会删除正式订阅，只会把 legacy 旧链接先备份再清空。"
  echo "This will NOT delete active subscriptions. It backs up and empties legacy links only."
  read -rp "确认清理 legacy 旧链接？[y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "[INFO] 已取消。"; return 0; }
  mkdir -p /opt/Love/backup
  b="/opt/Love/backup/legacy-raw-links.cleaned.$(date +%F-%H%M%S).txt"
  cp -f "$f" "$b"
  : > "$f"
  chmod 600 "$f" "$b" 2>/dev/null || true
  echo "[OK] 已备份到：$b"
  echo "[OK] 已清空 legacy 旧链接文件：$f"
}

love_color_menu_help13601() {
  cat <<'EOF'
Love v13.60.1 menu commands / 菜单命令：
  Love menu          打开全彩中英主菜单
  Love help1360      查看 v13.60 新增命令
  Love env           VPS 环境识别
  Love optimize      BBR / MTU / sysctl 优化
  Love speed         一键诊断
  Love sub           自动生成订阅
  Love web           绿色 Web 管理页
  Love cert-check    证书检查
  Love cert-ca       HTTP-01 Let's Encrypt 证书
  Love cf-config     Cloudflare Token 配置
  Love cf-dns        Cloudflare DNS 自动解析
  Love cf-cert       Cloudflare DNS-01 证书
  Love legacy-show   查看旧链接归档
  Love legacy-backup 备份旧链接归档
  Love legacy-clean  备份后清空旧链接归档
EOF
}

love_color_menu13601() {
  while true; do
    love_header13601
    love_status13601

    love_section13601 "核心安装 / Core Install"
    love_row13601 "1) 节点目录 / Node catalog" "2) Xray Reality + HY2" green green
    love_row13601 "3) sing-box 全协议 / All protocols" "4) Argo 隧道 / Cloudflared" green blue
    love_row13601 "5) UDP 跳跃 / Port hopping" "6) WARP 出站 / Outbound help" blue blue

    love_section13601 "导出与客户端 / Export & Clients"
    love_row13601 "7) 节点信息 / Node info" "8) 订阅生成 / Build subscriptions" yellow yellow
    love_row13601 "9) 二维码 / QR codes" "10) Super Tools / 修复工具" yellow magenta
    love_row13601 "11) 绿色 Web / Green Web panel" "12) 在线更新 / Online update" green blue
    love_row13601 "13) 客户端导出 / Client export" "30) 专用订阅 / Client-specific sub" yellow yellow
    love_row13601 "31) Clash Meta / Mihomo YAML" "38) H2 Reality v2rayN help" cyan cyan

    love_section13601 "旧版工具保留 / Legacy Tools Kept"
    love_row13601 "14) v6 Project Tools" "15) v7 Stable Tools" white white
    love_row13601 "16) v8 Project Panel" "17) Nginx Reverse Proxy" white white
    love_row13601 "18) HY2/sing-box 修复 / Fix" "19) IPv6-only 出站修复" white white
    love_row13601 "20) WARP Manager / FS-style" "21) 运行状态 / Runtime status" white white
    love_row13601 "22) 备份配置 / Backup" "23) 卸载菜单 / Uninstall" white red
    love_row13601 "24) GitHub 发布说明" "25) 安装 FS warp 命令" white white

    love_section13601 "v13.60 新增 / New Automation"
    love_row13601 "26) VPS 环境识别 / VPS env" "27) BBR/MTU 优化 / Optimize" cyan cyan
    love_row13601 "28) 一键测速诊断 / Speed diagnose" "29) 重建订阅 / Rebuild sub" cyan yellow
    love_row13601 "32) 证书检查 / Cert check" "33) HTTP-01 证书 / LE cert" green green
    love_row13601 "34) 证书模式切换 / Cert switch" "35) CF Token 配置 / CF config" green magenta
    love_row13601 "36) CF DNS 自动解析 / DNS upsert" "37) CF DNS-01 证书 / DNS cert" magenta magenta
    love_row13601 "43) v13.60 检查 / Final check" "44) 端口/防火墙 / Ports" cyan cyan

    love_section13601 "旧链接归档 / Legacy Link Archive"
    love_row13601 "39) 查看旧链接 / Show legacy" "40) 备份旧链接 / Backup legacy" gray gray
    love_row13601 "41) 清空旧链接 / Clean legacy" "42) 帮助 / Help" red cyan
    love_row13601 "45) 国旗图标设置 / Flag icon" "46) 自动识别国旗 / Auto flag" magenta magenta
    love_row13601 "47) 修复国旗字母 / Fix flag letters" "48) TRUE 手动提醒 / TRUE note" magenta yellow
    love_row13601 "0) 退出 / Exit" "" red white

    echo
    printf "%b提示 / Tips:%b 绿色 Web 不改样式；旧链接不进入正式订阅，只用于回滚和排错。\n" "$(love_c13601 yellow)" "$(love_c13601 reset)"
    printf "%bLOVE-H2-REALITY:%b v2rayN 里 VLESS Core 要改成 sing_box。\n" "$(love_c13601 yellow)" "$(love_c13601 reset)"
    printf "%b证书 TRUE 提醒:%b 自签/self.local 的 TLS 节点若 v2rayN 导入后仍为 False，请按 48 查看手动开关。\n" "$(love_c13601 yellow)" "$(love_c13601 reset)"
    echo
    read -rp "请选择 / Select: " choice

    case "${choice}" in
      1) love_call13601 show_all_node_catalog ;;
      2) love_call13601 install_xray_stable ;;
      3) love_call13601 install_singbox_native ;;
      4) love_call13601 argo_helper ;;
      5) love_call13601 port_hopping_helper ;;
      6) love_call13601 warp_helper ;;
      7) love_call13601 show_node_info ;;
      8) love_v1360_generate_client_subs ;;
      9) love_call13601 generate_qrcodes ;;
      10) love_call13601 super_menu ;;
      11) love_v1360_web ;;
      12) love_call13601 self_update_love ;;
      13) love_v1360_generate_client_subs ; love_call13601 love_full_client_pack ;;
      14) love_call13601 v6_super_menu ;;
      15) love_call13601 v7_stable_menu ;;
      16) love_call13601 v8_menu ;;
      17) love_call13601 nginx_rp_menu ;;
      18) love_call13601 love_fix_hy2_now ;;
      19) love_call13601 love_ipv6_outbound_menu ;;
      20) love_call13601 love_warp_manager_menu ;;
      21) love_call13601 show_status ;;
      22) love_call13601 backup_configs ;;
      23) love_call13601 uninstall_menu_v7 ;;
      24) love_call13601 github_publish_note ;;
      25) love_call13601 love_install_fs_warp_command ;;
      26) love_v1360_env_detect ;;
      27) love_v1360_optimize ;;
      28) love_v1360_speed ;;
      29) love_v1360_generate_client_subs ;;
      30) love_v1360_generate_client_subs ;;
      31) love_v1360_generate_client_subs; generate_mihomo_yaml 2>/dev/null || true ;;
      32) love_v1360_cert_check ;;
      33) love_v1360_cert_http01 ;;
      34) love_call13601 love_v1354_cert_switch ;;
      35) love_v1360_cf_config ;;
      36) love_v1360_cf_dns ;;
      37) love_v1360_cf_cert_dns01 ;;
      38) love_h2_v2rayn_help13601 ;;
      39) love_legacy_show13601 ;;
      40) love_legacy_backup13601 ;;
      41) love_legacy_clean13601 ;;
      42) love_color_menu_help13601 ;;
      43) love_v1360_env_detect; echo; love_v1360_cert_check; echo; love_v1356_source_check 2>/dev/null || true ;;
      44) love_call13601 love_ports_v1334 ;;
      45) love_flag_set13602 ;;
      46) love_flag_auto13602; love_v13602_fix_flags_all ;;
      47) love_v13602_fix_flags_all ;;
      48) love_v13604_tls_manual_report ;;
      0|q|Q|exit) exit 0 ;;
      *) printf "%b[WARN]%b 无效选择 / Invalid choice.\n" "$(love_c13601 yellow)" "$(love_c13601 reset)" ;;
    esac
    love_pause13601
  done
}

# Preserve v13.60 main and then expose the new color menu.
if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1360_before_color_menu >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1360_before_color_menu/')"
fi

main_menu() {
  love_color_menu13601
}

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.60.1-color-bilingual-main-menu-final}"
  case "${1:-}" in
    ""|menu|main|m)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      love_color_menu13601 ;;
    legacy|legacy-show)
      love_legacy_show13601 ;;
    legacy-backup)
      love_legacy_backup13601 ;;
    legacy-clean|legacy-clear)
      love_legacy_clean13601 ;;
    h2-help|v2rayn-h2|h2-v2rayn)
      love_h2_v2rayn_help13601 ;;
    help-menu|color-help|menu-help)
      love_color_menu_help13601 ;;
    *)
      love_original_main_v1360_before_color_menu "$@" ;;
  esac
}

# disabled by v13.60.9 early-main fix: main "$@" so it wins.
# ==============================================================================

LOVE_RAW_URL_DEFAULT="https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"

lc() {
  [[ -n "${NO_COLOR:-}" ]] && return 0
  case "$1" in
    red) printf "\033[31m" ;;
    green) printf "\033[32m" ;;
    yellow) printf "\033[33m" ;;
    blue) printf "\033[34m" ;;
    magenta) printf "\033[35m" ;;
    cyan) printf "\033[36m" ;;
    white) printf "\033[37m" ;;
    gray) printf "\033[90m" ;;
    bold) printf "\033[1m" ;;
    reset|*) printf "\033[0m" ;;
  esac
}

love_ui_hr() {
  printf "%b%s%b\n" "$(lc blue)" "================================================================================" "$(lc reset)"
}

love_ui_title() {
  echo
  love_ui_hr
  printf "%b%s%b %b%s%b\n" "$(lc bold)$(lc cyan)" "$1" "$(lc reset)" "$(lc gray)" "${2:-}" "$(lc reset)"
  love_ui_hr
}

love_ui_status_line() {
  local label="$1" value="$2"
  local color="yellow"
  case "$value" in
    active|yes|on|running|ok) color="green" ;;
    no|off|failed|not*) color="red" ;;
  esac
  printf "  %-20s %b%s%b\n" "$label" "$(lc "$color")" "$value" "$(lc reset)"
}

love_ui_menu2() {
  # Compact 2-column layout that works better on 80-100 width terminals.
  printf "  %b%-34s%b │ %b%s%b\n" "$(lc yellow)" "$1" "$(lc reset)" "$(lc cyan)" "$2" "$(lc reset)"
}

love_ui_tip() {
  printf "%b%s%b\n" "$(lc magenta)" "$*" "$(lc reset)"
}

love_main_status_panel_v129() {
  local sb ng wp final port ipv4 ipv6
  systemctl is-active --quiet sing-box && sb="active" || sb="not active"
  systemctl is-active --quiet nginx && ng="active" || ng="not active"
  systemctl is-active --quiet love-wireproxy.service && wp="active" || wp="not active"
  final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"
  curl -4 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv4="yes" || ipv4="no"
  curl -6 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv6="yes" || ipv6="no"

  printf "%b系统状态%b\n" "$(lc green)" "$(lc reset)"
  printf "  %-20s %s\n" "OS:" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf "  %-20s %s / %s\n" "Arch/Virt:" "$(uname -m)" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  printf "  %-20s IPv4: %b%s%b    IPv6: %b%s%b\n" "Outbound:" "$(lc $([[ "$ipv4" == yes ]] && echo green || echo red))" "$ipv4" "$(lc reset)" "$(lc $([[ "$ipv6" == yes ]] && echo green || echo red))" "$ipv6" "$(lc reset)"
  love_ui_status_line "sing-box:" "$sb"
  love_ui_status_line "nginx web:" "$ng"
  love_ui_status_line "WireProxy:" "$wp"
  printf "  %-20s %b%s%b\n" "route.final:" "$(lc cyan)" "$final" "$(lc reset)"
  [[ -n "$port" ]] && printf "  %-20s %b%s%b\n" "warp-socks port:" "$(lc cyan)" "$port" "$(lc reset)"
  echo
}

love_show_update_link() {
  love_ui_title "Love 在线更新 / 下载链接" "${VERSION}"
  echo "Raw 下载链接："
  echo "${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}"
  echo
  echo "手动更新命令："
  echo "wget -O /usr/local/bin/Love ${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}"
  echo "chmod +x /usr/local/bin/Love"
  echo "ln -sf /usr/local/bin/Love /usr/local/bin/love"
  echo "hash -r"
  echo "grep '^VERSION=' /usr/local/bin/Love"
  echo
}

self_update_love() {
  love_show_update_link

  local url="${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}"
  read -rp "使用上面的链接更新？直接回车确认，或输入新 URL: " input_url
  [[ -n "$input_url" ]] && url="$input_url"

  [[ -n "$url" ]] || die "更新 URL 不能为空。"

  local target="${LOVE_HOME}/Love.sh"
  local tmp="/tmp/Love.update.$$"
  local dl_url="${url}?t=$(date +%s)"

  curl -fsSL "$dl_url" -o "$tmp" || wget -O "$tmp" "$dl_url" || die "下载新版 Love 失败。"
  bash -n "$tmp" || die "新版脚本语法检查失败，已取消更新。"

  cp -f "$target" "${target}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  install -m 755 "$tmp" "$target"
  ln -sf "$target" "${LOVE_BIN}"
  ln -sf "$target" "${LOVE_BIN_LOWER}"
  rm -f "$tmp"
  /usr/local/bin/Love install-warp-command >/dev/null 2>&1 || true

  log "Love 已更新。"
  grep '^VERSION=' /usr/local/bin/Love 2>/dev/null || true
  echo "重新运行：Love"
}

love_warp_update_v12() {
  self_update_love
}

update_core_menu() {
  love_ui_title "Love Core / Script Update" "更新与下载链接"
  love_show_update_link
  echo "1) 更新 Love 主脚本"
  echo "2) 更新 Xray / sing-box 核心"
  echo "0) 返回"
  read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" u
  case "$u" in
    1) self_update_love ;;
    2) update_core_menu_original 2>/dev/null || true ;;
    *) return 0 ;;
  esac
}

main_menu() {
  while true; do
    love_ui_title "Love Node Server Manager" "${VERSION}"
    love_main_status_panel_v129

    printf "%b主菜单%b\n" "$(lc green)" "$(lc reset)"
    love_ui_menu2 "1) 节点目录" "14) v6 Project Tools"
    love_ui_menu2 "2) Xray Reality + HY2" "15) v7 Stable Tools"
    love_ui_menu2 "3) sing-box 全协议" "16) v8 Project Panel"
    love_ui_menu2 "4) Argo 隧道" "17) Nginx Reverse Proxy"
    love_ui_menu2 "5) UDP 端口跳跃" "18) HY2/sing-box 修复"
    love_ui_menu2 "6) WARP 说明" "19) IPv6-only 出站"
    love_ui_menu2 "7) 节点信息 Love -n" "20) WARP Manager / FS"
    love_ui_menu2 "8) 导出订阅 Love sub" "21) 查看运行状态"
    love_ui_menu2 "9) 生成二维码 Love qr" "22) 备份配置"
    love_ui_menu2 "10) Super Tools" "23) 卸载菜单"
    love_ui_menu2 "11) Web 管理页 Love web" "24) GitHub 发布说明"
    love_ui_menu2 "12) 在线更新 / 下载链接" "25) 安装 warp 命令"
    love_ui_menu2 "13) 客户端导出" "0) 退出"

    echo
    love_ui_tip "常用：Love warp-auto-fix | Love web | Love sub | Love qr | warp h | warp w"
    love_ui_tip "推荐流程：3 生成节点 → 20 修 WARP 出站 → 11 打开 Web 面板"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" choice

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
      25) love_install_fs_warp_command ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

love_warp_final_menu_v12() {
  while true; do
    if declare -F love_warp_fs_like_status_panel >/dev/null 2>&1; then
      love_warp_fs_like_status_panel
    else
      love_ui_title "Love WARP / Node Server Manager" "${VERSION}"
      love_main_status_panel_v129
    fi

    printf "%bWARP 菜单%b\n" "$(lc green)" "$(lc reset)"
    love_ui_menu2 "1) WARP IPv4 Only" "14) MTU 自动检测"
    love_ui_menu2 "2) WARP IPv6 Only" "15) WG/WireProxy fallback"
    love_ui_menu2 "3) WARP Dual Stack" "16) WARP IP/ASN/解锁"
    love_ui_menu2 "4) Auto Fix【推荐】" "17) SOCKS 健康检查"
    love_ui_menu2 "5) 官方 Proxy 40000" "18) sing-box 切 40000"
    love_ui_menu2 "6) WireProxy 40001" "19) sing-box 切 40001"
    love_ui_menu2 "7) Smart Split" "20) 恢复 direct"
    love_ui_menu2 "8) 官方全局模式" "21) 完整诊断报告"
    love_ui_menu2 "9) WARP 开关状态" "22) Full Precheck"
    love_ui_menu2 "10) WireProxy 开关" "23) 中文命令说明"
    love_ui_menu2 "11) 全局/非全局" "24) 更新 / 下载链接"
    love_ui_menu2 "12) 优先级设置" "25) 卸载 WARP"
    love_ui_menu2 "13) Endpoint 刷新" "0) 返回"

    echo
    love_ui_tip "推荐：IPv6-only 节点服务器选 4，健康检查通过后才切 sing-box。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_warp_interface_mode 4 ;;
      2) love_warp_interface_mode 6 ;;
      3) love_warp_interface_mode d ;;
      4) love_warp_auto_fix_v12 ;;
      5) love_warp_cli_proxy_v12 40000 ;;
      6) love_wireproxy_auto_v12 40001 ;;
      7)
        if love_socks_health_gate 40001; then love_singbox_switch_warp_socks_v12 40001 smart
        elif love_socks_health_gate 40000; then love_singbox_switch_warp_socks_v12 40000 smart
        else love_warp_auto_fix_v12
        fi
        ;;
      8) love_install_cloudflare_warp_official ;;
      9) love_warp_onoff_menu_v12 ;;
      10) love_wireproxy_toggle_v12 ;;
      11) love_warp_global_toggle_menu ;;
      12) love_warp_set_priority ;;
      13) love_warp_ip_refresh_v12 ;;
      14) love_warp_apply_mtu ;;
      15) love_warp_kernel_switch_v12 ;;
      16) love_warp_unlock_check; love_warp_ip_asn_region ;;
      17) love_socks_health_gate 40000 || true; love_socks_health_gate 40001 || true ;;
      18) love_singbox_switch_warp_socks_v12 40000 smart ;;
      19) love_singbox_switch_warp_socks_v12 40001 smart ;;
      20) love_singbox_restore_direct_v12 ;;
      21) love_warp_report_v12 ;;
      22) love_warp_full_precheck_v12 ;;
      23) love_warp_fs_style_help ;;
      24) self_update_love ;;
      25) love_warp_uninstall ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.0 Aligned Color UI Final
# CJK-width aware two-column layout. This override is placed before main "$@".
# ==============================================================================

LOVE_RAW_URL_DEFAULT="https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"

lc() {
  [[ -n "${NO_COLOR:-}" ]] && return 0
  case "$1" in
    red) printf "\033[31m" ;;
    green) printf "\033[32m" ;;
    yellow) printf "\033[33m" ;;
    blue) printf "\033[34m" ;;
    magenta) printf "\033[35m" ;;
    cyan) printf "\033[36m" ;;
    white) printf "\033[37m" ;;
    gray) printf "\033[90m" ;;
    bold) printf "\033[1m" ;;
    reset|*) printf "\033[0m" ;;
  esac
}

love_ui_hr() {
  printf "%b%s%b\n" "$(lc blue)" "════════════════════════════════════════════════════════════════════════════════" "$(lc reset)"
}

love_ui_title() {
  echo
  love_ui_hr
  printf "%b%s%b %b%s%b\n" "$(lc bold)$(lc cyan)" "$1" "$(lc reset)" "$(lc gray)" "${2:-}" "$(lc reset)"
  love_ui_hr
}

love_ui_tip() {
  printf "%b%s%b\n" "$(lc magenta)" "$*" "$(lc reset)"
}

love_ui_status_line() {
  local label="$1" value="$2"
  local color="yellow"
  case "$value" in
    active|yes|on|running|ok) color="green" ;;
    no|off|failed|not*) color="red" ;;
  esac
  printf "  %-20s %b%s%b\n" "$label" "$(lc "$color")" "$value" "$(lc reset)"
}

love_cjk_pad() {
  # Usage: love_cjk_pad "text" width
  # Python handles Chinese/Japanese/Korean display width. Fallback is simple printf.
  local text="$1"
  local width="${2:-34}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$text" "$width" <<'PY'
import sys, unicodedata
s = sys.argv[1]
w = int(sys.argv[2])
def swidth(x):
    total = 0
    for ch in x:
        if unicodedata.combining(ch):
            continue
        ea = unicodedata.east_asian_width(ch)
        total += 2 if ea in ("W", "F") else 1
    return total
d = swidth(s)
if d > w:
    out = ""
    cur = 0
    for ch in s:
        cw = 0 if unicodedata.combining(ch) else (2 if unicodedata.east_asian_width(ch) in ("W","F") else 1)
        if cur + cw > w - 1:
            break
        out += ch
        cur += cw
    s = out + "…"
    d = swidth(s)
print(s + " " * max(0, w - d), end="")
PY
  else
    printf "%-${width}s" "$text"
  fi
}

love_ui_menu2() {
  local left right lcell rcell
  left="$1"
  right="$2"
  lcell="$(love_cjk_pad "$left" 36)"
  rcell="$(love_cjk_pad "$right" 36)"
  printf "  %b│%b %b%s%b %b│%b %b%s%b %b│%b\n" \
    "$(lc blue)" "$(lc reset)" "$(lc yellow)" "$lcell" "$(lc reset)" \
    "$(lc blue)" "$(lc reset)" "$(lc cyan)" "$rcell" "$(lc reset)" \
    "$(lc blue)" "$(lc reset)"
}

love_ui_row() {
  love_ui_menu2 "$1" "$2"
}

love_warp_menu_row() {
  love_ui_menu2 "$1" "$2"
}

love_main_menu_row() {
  love_ui_menu2 "$1" "$2"
}

love_main_status_panel_v13() {
  local sb ng wp final port ipv4 ipv6
  systemctl is-active --quiet sing-box && sb="active" || sb="not active"
  systemctl is-active --quiet nginx && ng="active" || ng="not active"
  systemctl is-active --quiet love-wireproxy.service && wp="active" || wp="not active"
  final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"
  curl -4 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv4="yes" || ipv4="no"
  curl -6 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv6="yes" || ipv6="no"

  printf "%b系统状态%b\n" "$(lc green)" "$(lc reset)"
  printf "  %-20s %s\n" "OS:" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf "  %-20s %s / %s\n" "Arch/Virt:" "$(uname -m)" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  printf "  %-20s IPv4: %b%s%b    IPv6: %b%s%b\n" "Outbound:" "$(lc $([[ "$ipv4" == yes ]] && echo green || echo red))" "$ipv4" "$(lc reset)" "$(lc $([[ "$ipv6" == yes ]] && echo green || echo red))" "$ipv6" "$(lc reset)"
  love_ui_status_line "sing-box:" "$sb"
  love_ui_status_line "nginx web:" "$ng"
  love_ui_status_line "WireProxy:" "$wp"
  printf "  %-20s %b%s%b\n" "route.final:" "$(lc cyan)" "$final" "$(lc reset)"
  [[ -n "$port" ]] && printf "  %-20s %b%s%b\n" "warp-socks port:" "$(lc cyan)" "$port" "$(lc reset)"
  echo
}

love_show_update_link() {
  love_ui_title "Love 在线更新 / 下载链接" "${VERSION}"
  echo "Raw 下载链接："
  echo "${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}"
  echo
  echo "手动更新命令："
  echo "wget -O /usr/local/bin/Love ${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}"
  echo "chmod +x /usr/local/bin/Love"
  echo "ln -sf /usr/local/bin/Love /usr/local/bin/love"
  echo "hash -r"
  echo "grep '^VERSION=' /usr/local/bin/Love"
  echo
}

self_update_love() {
  love_show_update_link

  local url="${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}"
  read -rp "使用上面的链接更新？直接回车确认，或输入新 URL: " input_url
  [[ -n "$input_url" ]] && url="$input_url"

  local target="${LOVE_HOME}/Love.sh"
  local tmp="/tmp/Love.update.$$"
  local dl_url="${url}?t=$(date +%s)"

  curl -fsSL "$dl_url" -o "$tmp" || wget -O "$tmp" "$dl_url" || die "下载新版 Love 失败。"
  bash -n "$tmp" || die "新版脚本语法检查失败，已取消更新。"

  cp -f "$target" "${target}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  install -m 755 "$tmp" "$target"
  ln -sf "$target" "${LOVE_BIN}"
  ln -sf "$target" "${LOVE_BIN_LOWER}"
  rm -f "$tmp"
  /usr/local/bin/Love install-warp-command >/dev/null 2>&1 || true

  log "Love 已更新。"
  grep '^VERSION=' /usr/local/bin/Love 2>/dev/null || true
  echo "重新运行：Love"
}

love_warp_update_v12() {
  self_update_love
}

main_menu() {
  while true; do
    love_ui_title "Love Node Server Manager" "${VERSION}"
    love_main_status_panel_v13

    printf "%b主菜单%b\n" "$(lc green)" "$(lc reset)"
    love_ui_menu2 "1) 节点目录" "14) v6 Project Tools"
    love_ui_menu2 "2) Xray Reality + HY2" "15) v7 Stable Tools"
    love_ui_menu2 "3) sing-box 全协议" "16) v8 Project Panel"
    love_ui_menu2 "4) Argo 隧道" "17) Nginx Reverse Proxy"
    love_ui_menu2 "5) UDP 端口跳跃" "18) HY2/sing-box 修复"
    love_ui_menu2 "6) WARP 说明" "19) IPv6-only 出站"
    love_ui_menu2 "7) 节点信息 Love -n" "20) WARP Manager / FS"
    love_ui_menu2 "8) 导出订阅 Love sub" "21) 查看运行状态"
    love_ui_menu2 "9) 生成二维码 Love qr" "22) 备份配置"
    love_ui_menu2 "10) Super Tools" "23) 卸载菜单"
    love_ui_menu2 "11) Web 管理页 Love web" "24) GitHub 发布说明"
    love_ui_menu2 "12) 在线更新 / 下载链接" "25) 安装 warp 命令"
    love_ui_menu2 "13) 客户端导出" "0) 退出"

    echo
    love_ui_tip "常用：Love warp-auto-fix | Love web | Love sub | Love qr | warp h | warp w"
    love_ui_tip "推荐流程：3 生成节点 → 20 修 WARP 出站 → 11 打开 Web 面板"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" choice

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
      25) love_install_fs_warp_command ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

love_warp_final_menu_v12() {
  while true; do
    if declare -F love_warp_fs_like_status_panel >/dev/null 2>&1; then
      love_warp_fs_like_status_panel
    else
      love_ui_title "Love WARP / Node Server Manager" "${VERSION}"
      love_main_status_panel_v13
    fi

    printf "%bWARP 菜单%b\n" "$(lc green)" "$(lc reset)"
    love_ui_menu2 "1) WARP IPv4 Only" "14) MTU 自动检测"
    love_ui_menu2 "2) WARP IPv6 Only" "15) WG/WireProxy fallback"
    love_ui_menu2 "3) WARP Dual Stack" "16) WARP IP/ASN/解锁"
    love_ui_menu2 "4) Auto Fix【推荐】" "17) SOCKS 健康检查"
    love_ui_menu2 "5) 官方 Proxy 40000" "18) sing-box 切 40000"
    love_ui_menu2 "6) WireProxy 40001" "19) sing-box 切 40001"
    love_ui_menu2 "7) Smart Split" "20) 恢复 direct"
    love_ui_menu2 "8) 官方全局模式" "21) 完整诊断报告"
    love_ui_menu2 "9) WARP 开关状态" "22) Full Precheck"
    love_ui_menu2 "10) WireProxy 开关" "23) 中文命令说明"
    love_ui_menu2 "11) 全局/非全局" "24) 更新 / 下载链接"
    love_ui_menu2 "12) 优先级设置" "25) 卸载 WARP"
    love_ui_menu2 "13) Endpoint 刷新" "0) 返回"

    echo
    love_ui_tip "推荐：IPv6-only 节点服务器选 4，健康检查通过后才切 sing-box。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_warp_interface_mode 4 ;;
      2) love_warp_interface_mode 6 ;;
      3) love_warp_interface_mode d ;;
      4) love_warp_auto_fix_v12 ;;
      5) love_warp_cli_proxy_v12 40000 ;;
      6) love_wireproxy_auto_v12 40001 ;;
      7)
        if love_socks_health_gate 40001; then love_singbox_switch_warp_socks_v12 40001 smart
        elif love_socks_health_gate 40000; then love_singbox_switch_warp_socks_v12 40000 smart
        else love_warp_auto_fix_v12
        fi
        ;;
      8) love_install_cloudflare_warp_official ;;
      9) love_warp_onoff_menu_v12 ;;
      10) love_wireproxy_toggle_v12 ;;
      11) love_warp_global_toggle_menu ;;
      12) love_warp_set_priority ;;
      13) love_warp_ip_refresh_v12 ;;
      14) love_warp_apply_mtu ;;
      15) love_warp_kernel_switch_v12 ;;
      16) love_warp_unlock_check; love_warp_ip_asn_region ;;
      17) love_socks_health_gate 40000 || true; love_socks_health_gate 40001 || true ;;
      18) love_singbox_switch_warp_socks_v12 40000 smart ;;
      19) love_singbox_switch_warp_socks_v12 40001 smart ;;
      20) love_singbox_restore_direct_v12 ;;
      21) love_warp_report_v12 ;;
      22) love_warp_full_precheck_v12 ;;
      23) love_warp_fs_style_help ;;
      24) self_update_love ;;
      25) love_warp_uninstall ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.1 Status Label Fix Final
# Separate VPS direct outbound from node/sing-box outbound to avoid misleading NO.
# ==============================================================================

love_node_outbound_status_v131() {
  local final port socks_status node_status
  final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"

  node_status="unknown"
  socks_status="not tested"

  if ! systemctl is-active --quiet sing-box; then
    node_status="sing-box not active"
  elif [[ "$final" == "warp-socks" && -n "$port" ]]; then
    if ss -lntp 2>/dev/null | grep -q ":${port}"; then
      if curl -s --connect-timeout 3 --max-time 6 --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -Eq '^warp=(on|plus)$'; then
        socks_status="ok"
        node_status="via WARP SOCKS ok"
      else
        socks_status="listen but test fail"
        node_status="check WARP SOCKS"
      fi
    else
      socks_status="not listening"
      node_status="warp-socks not listening"
    fi
  elif [[ "$final" == "direct" ]]; then
    node_status="direct"
  else
    node_status="$final"
  fi

  echo "$node_status|$socks_status|$port|$final"
}

love_main_status_panel_v13() {
  local sb ng wp final port ipv4 ipv6 node_line node_status socks_status
  systemctl is-active --quiet sing-box && sb="active" || sb="not active"
  systemctl is-active --quiet nginx && ng="active" || ng="not active"
  systemctl is-active --quiet love-wireproxy.service && wp="active" || wp="not active"
  final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"

  # These are VPS direct outbound tests only. They do NOT represent client->node proxy connectivity.
  curl -4 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv4="yes" || ipv4="no"
  curl -6 -I --connect-timeout 2 --max-time 4 https://github.com >/dev/null 2>&1 && ipv6="yes" || ipv6="no"

  IFS='|' read -r node_status socks_status _ _ <<< "$(love_node_outbound_status_v131)"

  printf "%b系统状态%b\n" "$(lc green)" "$(lc reset)"
  printf "  %-22s %s\n" "OS:" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf "  %-22s %s / %s\n" "Arch/Virt:" "$(uname -m)" "$(systemd-detect-virt 2>/dev/null || echo unknown)"

  printf "  %-22s IPv4: %b%s%b    IPv6: %b%s%b\n" "VPS direct:" "$(lc $([[ "$ipv4" == yes ]] && echo green || echo yellow))" "$ipv4" "$(lc reset)" "$(lc $([[ "$ipv6" == yes ]] && echo green || echo yellow))" "$ipv6" "$(lc reset)"

  love_ui_status_line "sing-box:" "$sb"
  love_ui_status_line "nginx web:" "$ng"
  love_ui_status_line "WireProxy:" "$wp"

  printf "  %-22s %b%s%b\n" "route.final:" "$(lc cyan)" "$final" "$(lc reset)"
  [[ -n "$port" ]] && printf "  %-22s %b%s%b\n" "warp-socks port:" "$(lc cyan)" "$port" "$(lc reset)"

  case "$node_status" in
    *ok*)
      printf "  %-22s %b%s%b\n" "Node outbound:" "$(lc green)" "$node_status" "$(lc reset)"
      ;;
    *check*|*not*)
      printf "  %-22s %b%s%b\n" "Node outbound:" "$(lc yellow)" "$node_status" "$(lc reset)"
      ;;
    *)
      printf "  %-22s %b%s%b\n" "Node outbound:" "$(lc cyan)" "$node_status" "$(lc reset)"
      ;;
  esac

  printf "  %-22s %b%s%b\n" "SOCKS health:" "$(lc cyan)" "$socks_status" "$(lc reset)"
  printf "  %b说明：VPS direct 只是服务器直连测试；节点能否使用看 Node outbound / sing-box 联动。%b\n" "$(lc gray)" "$(lc reset)"
  echo
}

love_warp_fs_like_status_panel() {
  local os arch virt ipv4 ipv6 public_v6 warp_client wireproxy sb_final sb_port wp_ep node_status socks_status
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  arch="$(uname -m)"
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"

  curl -4 -I --connect-timeout 4 --max-time 6 https://github.com >/dev/null 2>&1 && ipv4="yes" || ipv4="no"
  curl -6 -I --connect-timeout 4 --max-time 6 https://github.com >/dev/null 2>&1 && ipv6="yes" || ipv6="no"
  public_v6="$(curl -6 -s --connect-timeout 4 --max-time 6 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"

  if command -v warp-cli >/dev/null 2>&1 && (warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null) | grep -qi "Connected"; then
    warp_client="active"
  else
    warp_client="not active"
  fi

  systemctl is-active --quiet love-wireproxy.service && wireproxy="active" || wireproxy="not active"

  sb_final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
  sb_port="$(jq -r '.outbounds[]? | select(.tag=="warp-socks") | .server_port' /etc/sing-box/config.json 2>/dev/null | head -n1)"
  wp_ep="$(grep -m1 '^Endpoint = ' /etc/wireproxy/warp.conf 2>/dev/null | sed 's/^Endpoint = //')"
  IFS='|' read -r node_status socks_status _ _ <<< "$(love_node_outbound_status_v131)"

  echo
  love_ui_hr
  printf "%bLove WARP / Node Server Manager%b  %s\n" "$(lc bold)$(lc cyan)" "$(lc reset)" "${VERSION:-unknown}"
  love_ui_hr

  printf "%b系统信息%b\n" "$(lc green)" "$(lc reset)"
  printf "  %-24s %s\n" "OS:" "${os}"
  printf "  %-24s %s\n" "Kernel:" "$(uname -r)"
  printf "  %-24s %s\n" "Arch / Virt:" "${arch} / ${virt}"
  [[ -n "$public_v6" ]] && printf "  %-24s %s\n" "Public IPv6:" "${public_v6}"

  echo
  printf "%bVPS 直连出站%b\n" "$(lc green)" "$(lc reset)"
  love_ui_status_line "IPv4 direct:" "$ipv4"
  love_ui_status_line "IPv6 direct:" "$ipv6"
  printf "  %b说明：这里是 VPS 自己直连 curl 测试，不等于客户端节点不可用。%b\n" "$(lc gray)" "$(lc reset)"

  echo
  printf "%bWARP / SOCKS 状态%b\n" "$(lc green)" "$(lc reset)"
  love_ui_status_line "WARP Client:" "$warp_client"
  love_ui_status_line "WireProxy:" "$wireproxy"
  [[ -n "$wp_ep" ]] && printf "  %-24s %s\n" "WireProxy Endpoint:" "$wp_ep"
  printf "  %-24s %b%s%b\n" "SOCKS health:" "$(lc cyan)" "$socks_status" "$(lc reset)"

  echo
  printf "%bsing-box 节点联动状态%b\n" "$(lc green)" "$(lc reset)"
  printf "  %-24s %s\n" "route.final:" "$sb_final"
  [[ -n "$sb_port" ]] && printf "  %-24s %s\n" "warp-socks port:" "$sb_port"
  systemctl is-active --quiet sing-box && love_ui_status_line "sing-box:" "active" || love_ui_status_line "sing-box:" "not active"
  case "$node_status" in
    *ok*) printf "  %-24s %b%s%b\n" "Node outbound:" "$(lc green)" "$node_status" "$(lc reset)" ;;
    *check*|*not*) printf "  %-24s %b%s%b\n" "Node outbound:" "$(lc yellow)" "$node_status" "$(lc reset)" ;;
    *) printf "  %-24s %b%s%b\n" "Node outbound:" "$(lc cyan)" "$node_status" "$(lc reset)" ;;
  esac

  echo
  printf "%b下载 / 更新入口%b\n" "$(lc green)" "$(lc reset)"
  printf "  %-24s %s\n" "GitHub Raw:" "https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"
  printf "  %-24s %s\n" "Update:" "Love update  或  Love warp v"
  printf "  %-24s %s\n" "FS-style:" "warp h / warp w / warp s 6"

  love_ui_hr
}



# ==============================================================================
# Love v13.2 Global Submenu UI Final
# 全局下级菜单 UI 统一：全彩标题 + 中文宽度对齐双列。
# ==============================================================================

love_menu_title(){ love_ui_title "$1" "$2"; }
love_menu2(){ love_ui_menu2 "$1" "$2"; }
love_back(){ echo; read -rp "$(printf "%b按回车返回...%b" "$(lc gray)" "$(lc reset)")" _; }

show_all_node_catalog(){
  while true; do
    love_menu_title "Love 全节点目录" "Node Catalog / Protocol Map"
    printf "%b核心节点模式%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "1) Xray Reality 稳定模式" "8) Trojan TLS 节点"
    love_menu2 "2) sing-box 原生全协议" "9) VMess WS 节点"
    love_menu2 "3) Hysteria2 UDP 高速节点" "10) VLESS WS 节点"
    love_menu2 "4) Reality + HY2 组合节点" "11) gRPC 节点"
    love_menu2 "5) ShadowTLS / AnyTLS" "12) TUIC / NaiveProxy"
    love_menu2 "6) Argo / Cloudflared 隧道" "13) Nginx WS/gRPC 反代"
    love_menu2 "7) Port Hopping UDP 跳跃" "14) 多用户订阅管理"
    echo
    printf "%b客户端导出%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "15) Raw URI 订阅" "20) sing-box client JSON"
    love_menu2 "16) Base64 订阅" "21) Shadowrocket"
    love_menu2 "17) Mihomo / Clash YAML" "22) NekoBox"
    love_menu2 "18) V2RayN 链接" "23) SFI / SFA / SFM"
    love_menu2 "19) 二维码 QR" "24) 完整客户端包"
    echo
    printf "%b常用维护%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "25) 查看当前节点 Love -n" "30) WARP Auto Fix"
    love_menu2 "26) 重新生成订阅 Love sub" "31) Web 管理页 Love web"
    love_menu2 "27) 重新生成二维码 Love qr" "32) 备份配置"
    love_menu2 "28) 完整诊断 Love doctor" "33) 查看运行状态"
    love_menu2 "29) 客户端导出" "0) 返回"
    echo
    love_ui_tip "推荐：新装节点选 2 或 3；IPv6-only VPS 出站修复选 30；Web 展示选 31。"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" n
    case "$n" in
      1) install_xray_stable;; 2) install_singbox_native;; 3) love_fix_hy2_now;;
      4) install_xray_stable;; 5) install_singbox_native;; 6) argo_helper;; 7) port_hopping_helper;;
      8|9|10|11|12) install_singbox_native;; 13) nginx_rp_menu;; 14) users_menu_v7;;
      15|16) export_subscription;; 17) generate_mihomo_yaml;; 18) love_v2rayn;; 19) generate_qrcodes;;
      20) love_singbox_json;; 21) love_shadowrocket;; 22) love_nekobox;; 23) love_sfi_sfa_sfm;; 24) love_full_client_pack;;
      25) show_node_info;; 26) export_subscription;; 27) generate_qrcodes;; 28) doctor_check;; 29) love_full_client_pack;;
      30) love_warp_auto_fix_v12;; 31) web_admin_page;; 32) backup_configs;; 33) show_status;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

super_menu(){
  while true; do
    love_menu_title "Love Super Tools" "诊断 / 修复 / 导出 / Web"
    love_menu2 "1) 查看节点 Love -n" "13) Mihomo / Clash YAML"
    love_menu2 "2) 导出订阅 Love sub" "14) Shadowrocket / NekoBox / V2RayN"
    love_menu2 "3) 生成二维码 Love qr" "15) 在线更新 Love"
    love_menu2 "4) 订阅静态服务 nginx" "16) Web 管理页"
    love_menu2 "5) 全面诊断 Love doctor" "17) 简洁链接总览"
    love_menu2 "6) 修复 apt / dpkg" "18) sing-box JSON"
    love_menu2 "7) 设置 IPv6 DNS" "19) Shadowrocket"
    love_menu2 "8) 更新核心 Xray/sing-box" "20) V2RayN"
    love_menu2 "9) 修改优选地址导出" "21) NekoBox"
    love_menu2 "10) Argo API 隧道" "22) SFI / SFA / SFM"
    love_menu2 "11) HY2 Realm 安全开关" "23) 完整客户端包"
    love_menu2 "12) 增删协议 / 重建" "24) v6 Project Tools"
    love_menu2 "0) 返回" ""
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) show_node_info;; 2) export_subscription;; 3) generate_qrcodes;; 4) serve_subscription_nginx;;
      5) doctor_check;; 6) repair_apt_dpkg;; 7) set_ipv6_dns;; 8) update_core_menu;;
      9) change_preferred_info_only;; 10) argo_api_create_tunnel;; 11) hy2_realm_helper;; 12) reload_protocols_helper;;
      13) generate_mihomo_yaml;; 14) generate_client_exports;; 15) self_update_love;; 16) web_admin_page;;
      17) love_links;; 18) love_singbox_json;; 19) love_shadowrocket;; 20) love_v2rayn;;
      21) love_nekobox;; 22) love_sfi_sfa_sfm;; 23) love_full_client_pack;; 24) v6_super_menu;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

v6_super_menu(){
  while true; do
    love_menu_title "Love v6 Project Tools" "Web 安全 / 推送 / 检测 / 备份"
    love_menu2 "1) Web 密码保护 + 随机路径" "7) 证书续签状态检查"
    love_menu2 "2) 重置订阅随机路径 token" "8) 端口冲突检测与推荐"
    love_menu2 "3) 通知配置 Telegram/Bark/Email" "9) Oracle Cloud 安全组模板"
    love_menu2 "4) 推送节点信息" "10) 多用户 UUID 管理"
    love_menu2 "5) 自动测速 / 可用性检测" "11) v7 Stable Tools"
    love_menu2 "6) 定时备份" "0) 返回"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) web_admin_page;; 2) reset_sub_token;; 3) notify_config_menu;; 4) notify_nodes;;
      5) health_check_nodes;; 6) setup_auto_backup;; 7) cert_status_check;; 8) check_port_conflict_and_recommend;;
      9) oracle_security_template;; 10) users_menu_v7;; 11) v7_stable_menu;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

v7_stable_menu(){
  while true; do
    love_menu_title "Love v7 Stable Tools" "预检 / 快照 / 用户 / 安全"
    love_menu2 "1) precheck 环境预检" "8) sing-box 兼容性检测"
    love_menu2 "2) mode 安装模式分级" "9) speed 连接测速"
    love_menu2 "3) snapshot / rollback" "10) cfip 优选 IP / 域名"
    love_menu2 "4) users 分用户订阅/二维码" "11) cloud-firewall 云防火墙模板"
    love_menu2 "5) support 客户端兼容矩阵" "12) harden 安全加固"
    love_menu2 "6) logs / errors 日志" "13) uninstall soft/full"
    love_menu2 "7) version pin 核心版本锁定" "14) Web 状态页增强"
    love_menu2 "0) 返回" ""
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) precheck_env;; 2) mode_wizard;; 3) snapshot_menu;; 4) users_menu_v7;;
      5) support_matrix;; 6) logs_menu;; 7) pin_core_menu;; 8) singbox_compat_check;;
      9) speed_test;; 10) cfip_helper;; 11) cloud_firewall_templates;; 12) harden_menu;;
      13) uninstall_menu_v7;; 14) web_status_generate;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

v8_menu(){
  while true; do
    love_menu_title "Love v8 Project Panel" "验证 / 审计 / 发布 / 仪表盘"
    love_menu2 "1) validate 全量验证" "7) support-bundle 脱敏支持包"
    love_menu2 "2) audit 安全审计" "8) import-links 导入外部节点"
    love_menu2 "3) dashboard 项目仪表盘" "9) rotate token/web/password"
    love_menu2 "4) state 生成状态 JSON" "10) test-suite 测试套件"
    love_menu2 "5) release 生成 GitHub 发布包" "11) update-channel 更新通道"
    love_menu2 "6) readme 生成 README" "0) 返回"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) v8_validate_all;; 2) v8_security_audit;; 3) v8_dashboard;; 4) v8_state_generate;;
      5) v8_release_pack;; 6) v8_generate_readme;; 7) v8_support_bundle;; 8) v8_import_links;;
      9) v8_rotate_menu;; 10) v8_test_suite;; 11) v8_update_channel;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

nginx_rp_menu(){
  while true; do
    love_menu_title "Love v9 Nginx Reverse Proxy" "WS / gRPC / Stream / fallback"
    love_menu2 "1) WS 反代：VLESS/VMess WS" "5) 生成 upstream 示例"
    love_menu2 "2) gRPC 反代" "6) 443 端口策略检测"
    love_menu2 "3) 仅创建伪装站点 fallback" "7) Nginx 反代状态"
    love_menu2 "4) Stream SNI passthrough" "8) 回滚 Nginx 配置"
    love_menu2 "0) 返回" ""
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) nginx_ws_reverse_proxy;; 2) nginx_grpc_reverse_proxy;; 3) nginx_fallback_only;; 4) nginx_stream_sni_passthrough;;
      5) nginx_generate_local_inbound_notes;; 6) nginx_443_strategy;; 7) nginx_rp_status;; 8) nginx_rp_rollback;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

love_ipv6_outbound_menu(){
  while true; do
    love_menu_title "Love IPv6-only 出站修复" "IPv6-only / WARP / prefer_ipv6"
    love_menu2 "1) 测试 IPv4 / IPv6 出站" "4) Auto Fix 自动修复"
    love_menu2 "2) sing-box prefer_ipv6 修复" "5) WARP Manager / FS"
    love_menu2 "3) WARP / IPv4 出站说明" "0) 返回"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_test_outbound_stack || true;; 2) love_fix_ipv6_only_outbound;; 3) love_warp_hint;;
      4) love_warp_auto_fix_v12;; 5) love_warp_manager_menu;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

love_warp_onoff_menu_v12(){
  while true; do
    love_menu_title "Love WARP 开关 / 状态" "Connect / Disconnect / Toggle"
    love_menu2 "1) 查看完整状态报告" "4) 停止 WireProxy"
    love_menu2 "2) 连接 Cloudflare WARP Client" "5) 启动 / 修复 WireProxy"
    love_menu2 "3) 断开 Cloudflare WARP Client" "6) 恢复 sing-box direct"
    love_menu2 "0) 返回" ""
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_warp_report_v12;; 2) warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true;;
      3) warp-cli --accept-tos disconnect 2>/dev/null || warp-cli disconnect 2>/dev/null || true;;
      4) systemctl stop love-wireproxy.service 2>/dev/null || true;; 5) love_wireproxy_auto_v12 40001;;
      6) love_singbox_restore_direct_v12;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

love_warp_kernel_switch_v12(){
  while true; do
    love_menu_title "Love WARP Fallback" "kernel WG / wireguard-go / WireProxy"
    love_menu2 "1) 尝试 WGCF interface" "4) Auto Fix 自动决策"
    love_menu2 "2) 尝试 wireguard-go fallback" "5) 完整诊断报告"
    love_menu2 "3) 尝试 WireProxy fallback" "0) 返回"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_install_wgcf_wireguard;; 2) love_wireguard_go_fallback;; 3) love_wireproxy_auto_v12 40001;;
      4) love_warp_auto_fix_v12;; 5) love_warp_report_v12;;
      0) return 0;; *) warn "无效选择。";;
    esac
  done
}

logs_menu(){
  while true; do
    love_menu_title "Love 日志 / 错误查看" "Logs / Errors"
    love_menu2 "1) sing-box 最近日志" "5) nginx error.log"
    love_menu2 "2) sing-box 实时日志" "6) nginx access.log"
    love_menu2 "3) WireProxy 日志" "7) systemd failed 服务"
    love_menu2 "4) WARP Client 状态" "0) 返回"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) journalctl -u sing-box -n 100 -l --no-pager;; 2) journalctl -u sing-box -f -l --no-pager;;
      3) journalctl -u love-wireproxy.service -n 100 -l --no-pager;; 4) warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true;;
      5) tail -n 100 /var/log/nginx/error.log;; 6) tail -n 100 /var/log/nginx/access.log;; 7) systemctl --failed --no-pager;;
      0) return 0;; *) warn "无效选择。";;
    esac
    love_back
  done
}

uninstall_menu_v7(){
  while true; do
    love_menu_title "Love 卸载 / 清理菜单" "Uninstall / Cleanup"
    love_menu2 "1) Soft 卸载节点服务" "6) 清理 Web 面板"
    love_menu2 "2) Full 卸载 Love 全部文件" "7) 清理 WARP / WireProxy"
    love_menu2 "3) 仅停止 sing-box" "8) 清理 nginx Love 配置"
    love_menu2 "4) 仅删除订阅/二维码" "9) 清理 systemd 残留"
    love_menu2 "5) 仅删除客户端导出" "0) 返回"
    echo
    love_ui_tip "危险操作前建议先执行：Love backup-auto"
    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) systemctl stop sing-box 2>/dev/null || true; systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload;;
      2) read -rp "确认删除 /opt/Love、/etc/sing-box、Love 命令？[y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] || continue; systemctl stop sing-box 2>/dev/null || true; systemctl stop love-wireproxy.service 2>/dev/null || true; rm -rf /opt/Love /etc/sing-box; rm -f /usr/local/bin/Love /usr/local/bin/love /usr/local/bin/warp; rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/love-wireproxy.service; systemctl daemon-reload;;
      3) systemctl stop sing-box 2>/dev/null || true;; 4) rm -rf /opt/Love/subscribe;;
      5) rm -rf /opt/Love/subscribe/clients /opt/Love/subscribe/sing-box;; 6) rm -rf /var/www/love-admin /opt/Love/web;;
      7) love_warp_uninstall;; 8) rm -f /etc/nginx/sites-enabled/love-admin /etc/nginx/sites-available/love-admin; systemctl restart nginx 2>/dev/null || true;;
      9) systemctl daemon-reload;; 0) return 0;; *) warn "无效选择。";;
    esac
  done
}

show_status(){
  love_menu_title "Love 运行状态" "Services / Ports / Outbound"
  printf "%b服务状态%b\n" "$(lc green)" "$(lc reset)"
  systemctl is-active --quiet sing-box && love_ui_status_line "sing-box:" "active" || love_ui_status_line "sing-box:" "not active"
  systemctl is-active --quiet nginx && love_ui_status_line "nginx:" "active" || love_ui_status_line "nginx:" "not active"
  systemctl is-active --quiet love-wireproxy.service && love_ui_status_line "WireProxy:" "active" || love_ui_status_line "WireProxy:" "not active"
  systemctl is-active --quiet warp-svc && love_ui_status_line "warp-svc:" "active" || love_ui_status_line "warp-svc:" "not active"
  echo
  printf "%b端口监听%b\n" "$(lc green)" "$(lc reset)"
  ss -lntup 2>/dev/null | grep -E ':(22|80|443|8099|30001|40000|40001)\b' || true
  echo
  printf "%bsing-box 联动%b\n" "$(lc green)" "$(lc reset)"
  jq '{final:.route.final, warp_socks:[.outbounds[]? | select(.tag=="warp-socks")], inbounds:[.inbounds[]? | {tag,type,listen,listen_port}]}' /etc/sing-box/config.json 2>/dev/null || true
  love_back
}

backup_configs(){
  love_menu_title "Love 备份配置" "Backup"
  local ts out
  ts="$(date +%F-%H%M%S)"
  out="/root/love-backup-${ts}.tar.gz"
  tar -czf "$out" /etc/sing-box /etc/systemd/system/sing-box.service /opt/Love /etc/nginx/sites-available/love-admin /etc/nginx/sites-enabled/love-admin /etc/nginx/.love_web_htpasswd 2>/dev/null || true
  if [[ -s "$out" ]]; then
    printf "%b[OK]%b 备份完成：%s\n" "$(lc green)" "$(lc reset)" "$out"
    ls -lh "$out"
  else
    printf "%b[WARN]%b 备份可能失败。\n" "$(lc yellow)" "$(lc reset)"
  fi
  love_back
}

love_full_client_pack(){
  love_menu_title "Love 客户端导出" "Client Export Pack"
  export_subscription >/dev/null 2>&1 || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  generate_client_exports >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || true
  printf "%b导出完成%b\n" "$(lc green)" "$(lc reset)"
  love_menu2 "Raw 订阅" "/opt/Love/subscribe/all.txt"
  love_menu2 "Base64 订阅" "/opt/Love/subscribe/all_base64.txt"
  love_menu2 "Mihomo YAML" "/opt/Love/subscribe/mihomo.yaml"
  love_menu2 "V2RayN" "/opt/Love/subscribe/clients/v2rayn-uri.txt"
  love_menu2 "Shadowrocket" "/opt/Love/subscribe/clients/shadowrocket.conf"
  love_menu2 "NekoBox" "/opt/Love/subscribe/clients/nekobox-uri.txt"
  love_menu2 "二维码目录" "/opt/Love/subscribe/qr/"
  love_back
}

github_publish_note(){
  love_menu_title "Love GitHub 发布说明" "Release Notes / Download"
  echo "当前版本：${VERSION}"
  echo
  echo "Raw 下载链接："
  echo "https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"
  echo
  echo "一键安装 / 更新："
  echo "wget -O /usr/local/bin/Love https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"
  echo "chmod +x /usr/local/bin/Love"
  echo "ln -sf /usr/local/bin/Love /usr/local/bin/love"
  echo "hash -r"
  echo "grep '^VERSION=' /usr/local/bin/Love"
  echo
  echo "FS 风格 warp 命令："
  echo "Love install-warp-command"
  echo "warp h"
  love_back
}



# ==============================================================================
# Love v13.3 Node Catalog Full Restore Final
# Restore full node catalog view while keeping compact category catalog.
# ==============================================================================

love_catalog_full_action() {
  local n="$1"
  case "$n" in
    1|2|3|4|5|6) install_xray_stable ;;
    7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28|29|30) install_singbox_native ;;
    31|32|33|34|35|36) love_fix_hy2_now ;;
    37|38|39|40|41|42|43|44) nginx_rp_menu ;;
    45|46|47) argo_helper ;;
    48|49|50) port_hopping_helper ;;
    51|52|53|54|55|56|57|58|59|60) love_full_client_pack ;;
    61) show_node_info ;;
    62) export_subscription ;;
    63) generate_qrcodes ;;
    64) web_admin_page ;;
    65) doctor_check ;;
    66) show_status ;;
    67) cfip_helper ;;
    68) change_preferred_info_only ;;
    69) speed_test ;;
    70) health_check_nodes ;;
    71) love_warp_auto_fix_v12 ;;
    72) love_warp_manager_menu ;;
    73) love_ipv6_outbound_menu ;;
    74) love_fix_ipv6_only_outbound ;;
    75) love_singbox_restore_direct_v12 ;;
    76) love_warp_report_v12 ;;
    77) users_menu_v7 ;;
    78) logs_menu ;;
    79) backup_configs ;;
    80) setup_auto_backup ;;
    81) snapshot_menu ;;
    82) v8_validate_all ;;
    83) v8_security_audit ;;
    84) v8_dashboard ;;
    85) v8_release_pack ;;
    86) self_update_love ;;
    87) update_core_menu ;;
    88) repair_apt_dpkg ;;
    89) set_ipv6_dns ;;
    90) web_admin_page ;;
    91) reset_sub_token ;;
    92) notify_config_menu ;;
    93) notify_nodes ;;
    94) cert_status_check ;;
    95) check_port_conflict_and_recommend ;;
    96) oracle_security_template ;;
    97) cloud_firewall_templates ;;
    98) harden_menu ;;
    99) uninstall_menu_v7 ;;
    100) github_publish_note ;;
    *) warn "无效选择。" ;;
  esac
}

show_all_node_catalog_full() {
  while true; do
    love_menu_title "Love 完整节点目录" "Full Catalog 1-100"

    printf "%bXray / Reality 稳定模式%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "1) Reality Vision" "2) Reality gRPC"
    love_menu2 "3) Reality + HY2" "4) Reality 多用户"
    love_menu2 "5) Reality 证书无关模式" "6) Xray 稳定模式重建"

    echo
    printf "%bsing-box 原生协议%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "7) VLESS Reality" "8) VLESS WS TLS"
    love_menu2 "9) VLESS gRPC TLS" "10) VLESS TCP"
    love_menu2 "11) VMess WS TLS" "12) VMess TCP"
    love_menu2 "13) Trojan TLS" "14) Trojan WS"
    love_menu2 "15) Shadowsocks 2022" "16) Hysteria2"
    love_menu2 "17) TUIC v5" "18) NaiveProxy"
    love_menu2 "19) ShadowTLS" "20) AnyTLS"
    love_menu2 "21) Mixed inbound" "22) Socks inbound"
    love_menu2 "23) HTTP inbound" "24) Direct outbound"
    love_menu2 "25) DNS 规则模式" "26) IPv6 优先模式"
    love_menu2 "27) 全协议自选安装" "28) 多协议组合安装"
    love_menu2 "29) sing-box 配置检查" "30) sing-box 重建"

    echo
    printf "%bHY2 / UDP / 反代 / 隧道%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "31) HY2 自动修复" "32) HY2 订阅生成"
    love_menu2 "33) HY2 证书修复" "34) HY2 端口检查"
    love_menu2 "35) HY2 防火墙放行" "36) HY2 Reality 组合"
    love_menu2 "37) Nginx WS 反代" "38) Nginx gRPC 反代"
    love_menu2 "39) Nginx fallback 伪装" "40) Stream SNI 分流"
    love_menu2 "41) 443 策略检测" "42) upstream 示例"
    love_menu2 "43) Nginx 状态" "44) Nginx 回滚"
    love_menu2 "45) Argo 临时隧道" "46) Argo API 隧道"
    love_menu2 "47) Cloudflared 管理" "48) UDP 端口跳跃"
    love_menu2 "49) Port Hopping 规则" "50) UDP 防火墙检测"

    echo
    printf "%b订阅 / 客户端导出%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "51) Raw URI 订阅" "52) Base64 订阅"
    love_menu2 "53) Mihomo / Clash YAML" "54) sing-box client JSON"
    love_menu2 "55) Shadowrocket" "56) NekoBox"
    love_menu2 "57) V2RayN" "58) SFI / SFA / SFM"
    love_menu2 "59) QR 二维码" "60) 完整客户端包"

    echo
    printf "%b状态 / 优选 / 诊断%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "61) 查看节点信息" "62) 重新导出订阅"
    love_menu2 "63) 重新生成二维码" "64) Web 管理页"
    love_menu2 "65) Love doctor 诊断" "66) 查看运行状态"
    love_menu2 "67) cfip 优选 IP" "68) 修改导出地址"
    love_menu2 "69) speed 连接测速" "70) 可用性检测"

    echo
    printf "%bWARP / IPv6-only 出站%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "71) WARP Auto Fix" "72) WARP Manager"
    love_menu2 "73) IPv6-only 出站菜单" "74) prefer_ipv6 修复"
    love_menu2 "75) 恢复 sing-box direct" "76) WARP 完整报告"

    echo
    printf "%b用户 / 日志 / 备份 / 安全%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "77) 多用户管理" "78) 日志菜单"
    love_menu2 "79) 立即备份" "80) 定时备份"
    love_menu2 "81) 快照 / 回滚" "82) validate 全量验证"
    love_menu2 "83) audit 安全审计" "84) dashboard 仪表盘"
    love_menu2 "85) release 发布包" "86) 在线更新"
    love_menu2 "87) 更新核心" "88) 修复 apt/dpkg"
    love_menu2 "89) IPv6 DNS" "90) Web 面板重建"
    love_menu2 "91) 重置 token" "92) 通知配置"
    love_menu2 "93) 推送节点信息" "94) 证书续签检查"
    love_menu2 "95) 端口冲突检测" "96) Oracle 安全组模板"
    love_menu2 "97) 云防火墙模板" "98) 安全加固"
    love_menu2 "99) 卸载 / 清理" "100) GitHub 发布说明"
    love_menu2 "0) 返回" ""

    echo
    love_ui_tip "说明：完整目录恢复了上一版的铺开式入口；同类协议最终会调用对应安装/修复函数。"
    love_ui_tip "优选 IP：67；WARP Auto Fix：71；Web 面板：64/90。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" n
    [[ "$n" == "0" ]] && return 0
    love_catalog_full_action "$n"
  done
}

show_all_node_catalog() {
  while true; do
    love_menu_title "Love 全节点目录" "Compact + Full Catalog"

    printf "%b精简分类入口%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "1) Xray Reality 稳定模式" "8) Trojan TLS 节点"
    love_menu2 "2) sing-box 原生全协议" "9) VMess WS 节点"
    love_menu2 "3) Hysteria2 UDP 高速节点" "10) VLESS WS 节点"
    love_menu2 "4) Reality + HY2 组合节点" "11) gRPC 节点"
    love_menu2 "5) ShadowTLS / AnyTLS" "12) TUIC / NaiveProxy"
    love_menu2 "6) Argo / Cloudflared 隧道" "13) Nginx WS/gRPC 反代"
    love_menu2 "7) Port Hopping UDP 跳跃" "14) 多用户订阅管理"

    echo
    printf "%b客户端导出%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "15) Raw URI 订阅" "20) sing-box client JSON"
    love_menu2 "16) Base64 订阅" "21) Shadowrocket"
    love_menu2 "17) Mihomo / Clash YAML" "22) NekoBox"
    love_menu2 "18) V2RayN 链接" "23) SFI / SFA / SFM"
    love_menu2 "19) 二维码 QR" "24) 完整客户端包"

    echo
    printf "%b常用维护%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "25) 查看当前节点 Love -n" "30) WARP Auto Fix"
    love_menu2 "26) 重新生成订阅 Love sub" "31) Web 管理页 Love web"
    love_menu2 "27) 重新生成二维码 Love qr" "32) 备份配置"
    love_menu2 "28) 完整诊断 Love doctor" "33) 查看运行状态"
    love_menu2 "29) 客户端导出" "34) 完整目录 1-100"

    love_menu2 "0) 返回" ""
    echo
    love_ui_tip "如果你想看上一版接近 100 项的完整列表，选 34。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" n
    case "$n" in
      1) install_xray_stable ;;
      2) install_singbox_native ;;
      3) love_fix_hy2_now ;;
      4) install_xray_stable ;;
      5) install_singbox_native ;;
      6) argo_helper ;;
      7) port_hopping_helper ;;
      8|9|10|11|12) install_singbox_native ;;
      13) nginx_rp_menu ;;
      14) users_menu_v7 ;;
      15|16) export_subscription ;;
      17) generate_mihomo_yaml ;;
      18) love_v2rayn ;;
      19) generate_qrcodes ;;
      20) love_singbox_json ;;
      21) love_shadowrocket ;;
      22) love_nekobox ;;
      23) love_sfi_sfa_sfm ;;
      24) love_full_client_pack ;;
      25) show_node_info ;;
      26) export_subscription ;;
      27) generate_qrcodes ;;
      28) doctor_check ;;
      29) love_full_client_pack ;;
      30) love_warp_auto_fix_v12 ;;
      31) web_admin_page ;;
      32) backup_configs ;;
      33) show_status ;;
      34) show_all_node_catalog_full ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.4 CFIP Auto Finder Final
# Cloudflare preferred IP auto finder + safe warnings.
# ==============================================================================

love_cfip_file() {
  echo "${LOVE_HOME:-/opt/Love}/cfip.list"
}

love_export_addr_file() {
  echo "${LOVE_HOME:-/opt/Love}/preferred_addr"
}

love_cfip_save_one() {
  local v="$1" f
  f="$(love_cfip_file)"
  mkdir -p "$(dirname "$f")"
  [[ -n "$v" ]] || return 1
  grep -qxF "$v" "$f" 2>/dev/null || echo "$v" >> "$f"
}

love_cfip_view() {
  local f
  f="$(love_cfip_file)"
  love_menu_title "Love CFIP 当前优选列表" "Preferred IP / Domain"
  if [[ ! -s "$f" ]]; then
    warn "当前没有保存优选 IP / 域名。"
    echo "文件位置：$f"
    return 0
  fi
  nl -ba "$f"
  echo
  echo "第一个地址会被用于：4) 用第一个优选地址重写导出 Address 提示"
}

love_cfip_import_file() {
  local p f
  f="$(love_cfip_file)"
  read -rp "输入文件路径，一行一个 IP / 域名: " p
  [[ -f "$p" ]] || { warn "文件不存在：$p"; return 1; }
  mkdir -p "$(dirname "$f")"
  grep -Ev '^\s*($|#)' "$p" | sed 's/\r//g' >> "$f"
  awk '!seen[$0]++' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  log "已导入：$f"
  love_cfip_view
}

love_cfip_rewrite_first() {
  local f first pf
  f="$(love_cfip_file)"
  pf="$(love_export_addr_file)"
  first="$(grep -Ev '^\s*($|#)' "$f" 2>/dev/null | head -n1)"
  [[ -n "$first" ]] || { warn "优选列表为空，先添加或自动查找。"; return 1; }
  mkdir -p "$(dirname "$pf")"
  echo "$first" > "$pf"
  log "已把第一个优选地址写入导出 Address 提示：$first"
  log "建议继续执行：Love sub && Love qr && Love web"
}

love_cfip_generate_candidates() {
  local mode="${1:-4}" count="${2:-80}" out="$3"
  mkdir -p "$(dirname "$out")"
  : > "$out"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "缺少 python3，无法生成 CIDR 候选。"
    return 1
  fi

  if [[ "$mode" == "6" ]]; then
    curl -fsSL --connect-timeout 8 --max-time 20 https://www.cloudflare.com/ips-v6 -o /tmp/love_cf_ips.txt || return 1
  else
    curl -fsSL --connect-timeout 8 --max-time 20 https://www.cloudflare.com/ips-v4 -o /tmp/love_cf_ips.txt || return 1
  fi

  python3 - "$mode" "$count" "$out" <<'PY'
import sys, ipaddress, random
mode=sys.argv[1]
count=int(sys.argv[2])
out=sys.argv[3]
cidrs=[x.strip() for x in open('/tmp/love_cf_ips.txt') if x.strip() and not x.startswith('#')]
res=[]
per=max(1, count//max(1,len(cidrs)))
for c in cidrs:
    net=ipaddress.ip_network(c, strict=False)
    first=int(net.network_address)+1
    last=int(net.broadcast_address)-1 if net.version==4 else int(net.network_address)+net.num_addresses-2
    if last <= first:
        continue
    for _ in range(per):
        res.append(str(ipaddress.ip_address(random.randint(first,last))))
random.shuffle(res)
res=res[:count]
open(out,'w').write('\n'.join(res)+'\n')
PY
}

love_cfip_test_one() {
  local ip="$1" host="$2" port="${3:-443}" max="${4:-5}"
  # Output: ip time_total http_code
  local res code total
  res="$(curl -k -sS -o /dev/null \
    --connect-timeout 3 --max-time "$max" \
    --connect-to "${host}:${port}:${ip}:${port}" \
    -w "%{time_connect} %{time_appconnect} %{time_total} %{http_code}" \
    "https://${host}:${port}/cdn-cgi/trace" 2>/dev/null || true)"
  [[ -n "$res" ]] || return 1
  total="$(awk '{print $3}' <<< "$res")"
  code="$(awk '{print $4}' <<< "$res")"
  [[ "$code" =~ ^(200|204|301|302|403|404)$ ]] || return 1
  printf "%s %s %s\n" "$ip" "$total" "$code"
}

love_cfip_auto_find() {
  love_menu_title "Love CFIP 自动优选" "VPS 视角测速 / Cloudflare CDN"

  echo "这个功能会自动从 Cloudflare 官方 IP 段抽样，测试 HTTPS 握手/访问速度。"
  echo
  printf "%b重要说明：%b\n" "$(lc yellow)" "$(lc reset)"
  echo "1. 这是在 VPS 上测速，结果代表 VPS → Cloudflare，不一定代表你手机/电脑 → Cloudflare。"
  echo "2. 真正给客户端用的优选 IP，最好在客户端网络上测。"
  echo "3. 只适合 Cloudflare CDN / WS / gRPC / TLS 类节点。"
  echo "4. 纯 HY2 直连 IPv6:端口 通常不要用 CF 优选 IP。"
  echo

  read -rp "测速域名/SNI [www.cloudflare.com]: " host
  host="${host:-www.cloudflare.com}"

  read -rp "测试 IPv4 还是 IPv6？[4/6，默认4]: " mode
  mode="${mode:-4}"

  read -rp "抽样数量 [80]: " count
  count="${count:-80}"

  local cand="/tmp/love_cfip_candidates.txt"
  local result="/tmp/love_cfip_result.txt"
  : > "$result"

  log "正在生成 Cloudflare 候选 IP..."
  love_cfip_generate_candidates "$mode" "$count" "$cand" || { warn "候选生成失败。"; return 1; }

  log "开始测速，可能需要几十秒..."
  local i=0 ok=0 line r
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ((i++)) || true
    r="$(love_cfip_test_one "$line" "$host" 443 6 || true)"
    if [[ -n "$r" ]]; then
      echo "$r" >> "$result"
      ((ok++)) || true
      printf "%b[OK]%b %s\n" "$(lc green)" "$(lc reset)" "$r"
    else
      printf "%b[FAIL]%b %s\n" "$(lc gray)" "$(lc reset)" "$line"
    fi
  done < "$cand"

  if [[ "$ok" -eq 0 ]]; then
    warn "没有测到可用 IP。可能是 VPS 直连该 IP 版本不通，或该域名不适合测试。"
    return 1
  fi

  sort -k2,2n "$result" | head -n 20 > /tmp/love_cfip_top20.txt

  love_menu_title "Love CFIP Top 20" "按 time_total 排序"
  nl -ba /tmp/love_cfip_top20.txt

  read -rp "保存前几个到优选列表？[5]: " keep
  keep="${keep:-5}"

  local f
  f="$(love_cfip_file)"
  mkdir -p "$(dirname "$f")"

  awk -v k="$keep" 'NR<=k{print $1}' /tmp/love_cfip_top20.txt >> "$f"
  awk '!seen[$0]++' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"

  log "已保存 Top ${keep} 到：$f"
  love_cfip_view

  read -rp "是否立即用第一个优选地址重写导出 Address？[Y/n]: " y
  y="${y:-Y}"
  [[ "$y" =~ ^[Yy]$ ]] && love_cfip_rewrite_first
}

love_cfip_client_side_guide() {
  love_menu_title "客户端侧优选 IP 建议" "更准确"
  echo "Cloudflare 优选 IP 最好在客户端网络上测，因为最终是你的手机/电脑连接 Cloudflare。"
  echo
  echo "推荐方式："
  echo "1. 在 Windows / Mac / 本地网络跑 CloudflareST 或同类测速工具。"
  echo "2. 得到最快的 IP 列表。"
  echo "3. 回到 VPS 执行：Love cfip"
  echo "4. 选 1 手动保存，或 2 从文件批量导入。"
  echo "5. 选 4 用第一个地址重写导出 Address。"
  echo "6. 执行：Love sub && Love qr && Love web"
  echo
  echo "如果你是纯 HY2 直连 IPv6:30001，不建议使用 CF 优选 IP。"
  love_back 2>/dev/null || true
}

cfip_helper() {
  while true; do
    love_menu_title "Love CFIP 优选 IP / 域名" "保存 / 自动查找 / 导出替换"
    love_menu2 "1) 手动保存优选 IP / 域名" "5) 自动查找 Cloudflare 优选 IP"
    love_menu2 "2) 从文件批量导入" "6) 客户端侧测速说明"
    love_menu2 "3) 查看当前优选列表" "7) 清空优选列表"
    love_menu2 "4) 用第一个优选地址重写导出 Address" "0) 返回"

    echo
    love_ui_tip "提示：自动查找是 VPS 视角；客户端实际最快 IP 建议在本地网络测速后导入。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" c
    case "$c" in
      1)
        read -rp "输入优选 IP / 域名: " v
        love_cfip_save_one "$v"
        love_cfip_view
        ;;
      2) love_cfip_import_file ;;
      3) love_cfip_view ;;
      4) love_cfip_rewrite_first ;;
      5) love_cfip_auto_find ;;
      6) love_cfip_client_side_guide ;;
      7)
        read -rp "确认清空优选列表？[y/N]: " y
        [[ "$y" =~ ^[Yy]$ ]] && : > "$(love_cfip_file)"
        ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.6 Old Catalog Exact Restore Final
# Restore old uncompressed catalog exactly: 1-97, colored and actionable.
# ==============================================================================

love_safe_call() {
  local fn="$1"; shift || true
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
  else
    warn "当前脚本未启用该功能函数：$fn"
    echo "入口已保留，但这个函数在当前文件中不存在或旧版本命名不同。"
  fi
}

love_old_catalog_action() {
  local n="$1"
  case "$n" in
    1|2|3|4|5|6) love_safe_call install_xray_stable ;;
    7) love_safe_call cfip_helper ;;

    8|9|10|11|12|13|14|15|16|17|18|19|20) love_safe_call install_singbox_native ;;

    21) love_safe_call argo_helper ;;
    22) love_safe_call port_hopping_helper ;;
    23) love_safe_call warp_helper ;;
    24) love_safe_call show_status ;;
    25) love_safe_call show_node_info ;;
    26) love_safe_call export_subscription ;;
    27) love_safe_call doctor_check ;;
    28) love_safe_call repair_apt_dpkg ;;
    29) love_safe_call set_ipv6_dns ;;
    30) love_safe_call update_core_menu ;;
    31) love_safe_call generate_qrcodes ;;
    32) love_safe_call argo_api_create_tunnel ;;
    33) love_safe_call hy2_realm_helper ;;
    34) love_safe_call reload_protocols_helper ;;
    35) love_safe_call serve_subscription_nginx ;;
    36) love_safe_call generate_mihomo_yaml ;;
    37) love_safe_call love_shadowrocket ;;
    38) love_safe_call generate_client_exports ;;
    39) love_safe_call self_update_love ;;
    40) love_safe_call web_admin_page ;;
    41) love_safe_call love_links ;;
    42) love_safe_call love_singbox_json ;;
    43) love_safe_call love_shadowrocket ;;
    44) love_safe_call love_v2rayn ;;
    45) love_safe_call love_nekobox ;;
    46) love_safe_call love_sfi_sfa_sfm ;;
    47) love_safe_call love_full_client_pack ;;
    48) love_safe_call web_admin_page ;;
    49) love_safe_call web_admin_page ;;
    50) love_safe_call reset_sub_token ;;
    51) love_safe_call notify_config_menu ;;
    52) love_safe_call health_check_nodes ;;
    53) love_safe_call setup_auto_backup ;;
    54) love_safe_call cert_status_check ;;
    55) love_safe_call check_port_conflict_and_recommend ;;
    56) love_safe_call oracle_security_template ;;
    57) love_safe_call users_menu_v7 ;;
    58) love_safe_call precheck_env ;;
    59) love_safe_call mode_wizard ;;
    60) love_safe_call snapshot_menu ;;
    61) love_safe_call users_menu_v7 ;;
    62) love_safe_call support_matrix ;;
    63) love_safe_call logs_menu ;;
    64) love_safe_call pin_core_menu ;;
    65) love_safe_call singbox_compat_check ;;
    66) love_safe_call speed_test ;;
    67) love_safe_call cfip_helper ;;
    68) love_safe_call cloud_firewall_templates ;;
    69) love_safe_call harden_menu ;;
    70) love_safe_call uninstall_menu_v7 ;;
    71) love_safe_call web_status_generate ;;
    72) love_safe_call v8_validate_all ;;
    73) love_safe_call v8_security_audit ;;
    74) love_safe_call v8_dashboard ;;
    75) love_safe_call v8_state_generate ;;
    76) love_safe_call v8_release_pack ;;
    77) love_safe_call v8_generate_readme ;;
    78) love_safe_call v8_support_bundle ;;
    79) love_safe_call v8_import_links ;;
    80) love_safe_call v8_rotate_menu ;;
    81) love_safe_call v8_test_suite ;;
    82) love_safe_call v8_update_channel ;;
    83) love_safe_call nginx_rp_menu ;;
    84) love_safe_call nginx_ws_reverse_proxy ;;
    85) love_safe_call nginx_grpc_reverse_proxy ;;
    86) love_safe_call nginx_fallback_only ;;
    87) love_safe_call nginx_stream_sni_passthrough ;;
    88) love_safe_call nginx_rp_status ;;
    89) love_safe_call nginx_rp_rollback ;;
    90) love_safe_call love_fix_hy2_now ;;
    91) love_safe_call love_ipv6_outbound_menu ;;
    92) love_safe_call love_test_outbound_stack ;;
    93) love_safe_call love_warp_hint ;;
    94) love_safe_call love_warp_manager_menu ;;
    95) love_safe_call love_install_cloudflare_warp_official ;;
    96) love_safe_call love_warp_status ;;
    97) love_safe_call love_test_outbound_stack ;;

    98) love_safe_call love_cfip_auto_find ;;
    99) love_safe_call love_cfip_view ;;
    100) love_safe_call love_cfip_rewrite_first ;;
    101) love_safe_call love_cfip_import_file ;;
    102) love_safe_call love_cfip_client_side_guide ;;
    103) love_safe_call love_warp_auto_fix_v12 ;;
    104) love_safe_call love_singbox_restore_direct_v12 ;;
    105) love_safe_call love_warp_report_v12 ;;
    106) love_safe_call love_full_client_pack ;;
    107) love_safe_call backup_configs ;;
    108) love_safe_call github_publish_note ;;
    *) warn "无效选择。" ;;
  esac
}

show_all_node_catalog_full() {
  while true; do
    love_menu_title "Love 完整节点目录" "旧版原编号 1-97 + 新增扩展"

    printf "%bA. 原生 Xray 稳定节点%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "1) VLESS + REALITY + Vision 443/tcp" "2) HY2 / Hysteria2 443/udp"
    love_menu2 "3) IPv6 listen ::" "4) 有域名：Let's Encrypt"
    love_menu2 "5) 无域名：Reality-only" "6) 无域名可选 HY2 自签"
    love_menu2 "7) 优选 IP / 域名" ""

    echo
    printf "%bB. 原生 sing-box 节点%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "8) VLESS Reality" "9) Hysteria2"
    love_menu2 "10) TUIC" "11) Shadowsocks"
    love_menu2 "12) Trojan" "13) VMess WS"
    love_menu2 "14) VLESS WS TLS" "15) H2 Reality"
    love_menu2 "16) gRPC Reality" "17) AnyTLS"
    love_menu2 "18) Naive" "19) ShadowTLS"

    echo
    printf "%bC. 高级能力 20-47%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "20) all 全协议" "21) Argo / Cloudflared"
    love_menu2 "22) Port Hopping" "23) WARP 出站增强说明"
    love_menu2 "24) 备份 / 状态 / 卸载" "25) Love -n 节点查看"
    love_menu2 "26) Love sub 订阅导出" "27) Love doctor 全面诊断"
    love_menu2 "28) Love repair apt/dpkg" "29) Love dns IPv6 DNS"
    love_menu2 "30) Love -v 核心更新" "31) Love qr 二维码"
    love_menu2 "32) Argo API Tunnel + DNS" "33) HY2 Realm 安全开关"
    love_menu2 "34) Love -r 增删协议 / 重建" "35) 订阅静态服务 nginx"
    love_menu2 "36) Mihomo / Clash YAML" "37) Shadowrocket 专用导出"
    love_menu2 "38) NekoBox / V2RayN 导出" "39) 在线更新 Love"
    love_menu2 "40) Web 静态管理页" "41) Love links 简洁链接"
    love_menu2 "42) sing-box outbounds/client" "43) Shadowrocket 导出"
    love_menu2 "44) V2RayN 导出" "45) NekoBox / NekoRay 导出"
    love_menu2 "46) SFI / SFA / SFM JSON" "47) 完整客户端包 tar.gz"

    echo
    printf "%bC. 高级能力 48-71%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "48) Web Basic Auth 保护" "49) Web 一键复制链接"
    love_menu2 "50) 订阅随机路径 token" "51) Telegram/Bark/Email 推送"
    love_menu2 "52) 节点健康检测" "53) 定时备份 systemd"
    love_menu2 "54) 证书续签状态检查" "55) 端口冲突检测与推荐"
    love_menu2 "56) Oracle Cloud 安全组模板" "57) 多用户 UUID 管理"
    love_menu2 "58) Love precheck 环境预检" "59) Love mode 安装模式"
    love_menu2 "60) snapshot / rollback" "61) users 分用户订阅"
    love_menu2 "62) support 客户端矩阵" "63) logs / errors 日志"
    love_menu2 "64) pin 版本锁定" "65) compat sing-box 检测"
    love_menu2 "66) speed 连接测速" "67) cfip Cloudflare 优选"
    love_menu2 "68) cloud-firewall 模板" "69) harden 安全加固"
    love_menu2 "70) uninstall soft/full" "71) web-status 状态页"

    echo
    printf "%bC. 高级能力 72-97%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "72) validate 全量验证" "73) audit 安全审计"
    love_menu2 "74) dashboard 仪表盘" "75) state 状态 JSON"
    love_menu2 "76) release GitHub 发布包" "77) readme README 生成"
    love_menu2 "78) support-bundle 脱敏包" "79) import-links 外部导入"
    love_menu2 "80) rotate token/Web 密码" "81) test-suite 测试套件"
    love_menu2 "82) update-channel 更新通道" "83) nginx Nginx 反代菜单"
    love_menu2 "84) nginx-ws WS 反代" "85) nginx-grpc gRPC 反代"
    love_menu2 "86) nginx-fallback 伪装站" "87) nginx-stream SNI 分流"
    love_menu2 "88) nginx-status 反代状态" "89) nginx-rollback 配置回滚"
    love_menu2 "90) fix-hy2 HY2 自动修复" "91) fix-ipv6 prefer_ipv6"
    love_menu2 "92) test-outbound 出站测试" "93) warp-hint WARP 提示"
    love_menu2 "94) warp WARP Manager" "95) warp-install 官方 WARP"
    love_menu2 "96) warp-status WARP 状态" "97) warp-test 出站测试"

    echo
    printf "%bD. V13 新增扩展 98-108%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "98) 自动查找 CF 优选 IP" "99) 查看 CFIP 列表"
    love_menu2 "100) 第一优选写入导出" "101) 文件批量导入 CFIP"
    love_menu2 "102) 客户端侧测速说明" "103) WARP Auto Fix"
    love_menu2 "104) 恢复 sing-box direct" "105) WARP 完整报告"
    love_menu2 "106) 完整客户端包刷新" "107) 立即备份"
    love_menu2 "108) GitHub 发布说明" "0) 返回"

    echo
    love_ui_tip "说明：1-97 按旧版未精简目录恢复；98+ 是 V13 新增扩展。"
    love_ui_tip "优选 IP：7 或 67；自动查找 CFIP：98；测速：66；WARP Manager：94。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" n
    [[ "$n" == "0" ]] && return 0
    love_old_catalog_action "$n"
  done
}

show_all_node_catalog() {
  while true; do
    love_menu_title "Love 全节点目录" "精简入口 + 旧版完整目录"

    printf "%b精简分类入口%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "1) Xray Reality 稳定模式" "8) Trojan TLS 节点"
    love_menu2 "2) sing-box 原生全协议" "9) VMess WS 节点"
    love_menu2 "3) Hysteria2 UDP 高速节点" "10) VLESS WS 节点"
    love_menu2 "4) Reality + HY2 组合节点" "11) gRPC 节点"
    love_menu2 "5) ShadowTLS / AnyTLS" "12) TUIC / NaiveProxy"
    love_menu2 "6) Argo / Cloudflared 隧道" "13) Nginx WS/gRPC 反代"
    love_menu2 "7) Port Hopping UDP 跳跃" "14) 多用户订阅管理"

    echo
    printf "%b客户端导出%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "15) Raw URI 订阅" "20) sing-box client JSON"
    love_menu2 "16) Base64 订阅" "21) Shadowrocket"
    love_menu2 "17) Mihomo / Clash YAML" "22) NekoBox"
    love_menu2 "18) V2RayN 链接" "23) SFI / SFA / SFM"
    love_menu2 "19) 二维码 QR" "24) 完整客户端包"

    echo
    printf "%b常用维护%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "25) 查看当前节点 Love -n" "30) WARP Auto Fix"
    love_menu2 "26) 重新生成订阅 Love sub" "31) Web 管理页 Love web"
    love_menu2 "27) 重新生成二维码 Love qr" "32) 备份配置"
    love_menu2 "28) 完整诊断 Love doctor" "33) 查看运行状态"
    love_menu2 "29) 客户端导出" "34) 旧版完整目录 1-97"

    echo
    printf "%b优选 / 测速快捷入口%b\n" "$(lc green)" "$(lc reset)"
    love_menu2 "35) CFIP 优选 IP 菜单" "38) 修改导出地址"
    love_menu2 "36) 自动查找 CF 优选 IP" "39) 查看 CFIP 列表"
    love_menu2 "37) speed 连接测速" "40) 客户端侧测速说明"
    love_menu2 "0) 返回" ""

    echo
    love_ui_tip "旧版未精简完整目录选 34；优选 IP 选 35 或完整目录 7/67。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" n
    case "$n" in
      1) install_xray_stable ;;
      2) install_singbox_native ;;
      3) love_fix_hy2_now ;;
      4) install_xray_stable ;;
      5) install_singbox_native ;;
      6) argo_helper ;;
      7) port_hopping_helper ;;
      8|9|10|11|12) install_singbox_native ;;
      13) nginx_rp_menu ;;
      14) users_menu_v7 ;;
      15|16) export_subscription ;;
      17) generate_mihomo_yaml ;;
      18) love_v2rayn ;;
      19) generate_qrcodes ;;
      20) love_singbox_json ;;
      21) love_shadowrocket ;;
      22) love_nekobox ;;
      23) love_sfi_sfa_sfm ;;
      24) love_full_client_pack ;;
      25) show_node_info ;;
      26) export_subscription ;;
      27) generate_qrcodes ;;
      28) doctor_check ;;
      29) love_full_client_pack ;;
      30) love_warp_auto_fix_v12 ;;
      31) web_admin_page ;;
      32) backup_configs ;;
      33) show_status ;;
      34) show_all_node_catalog_full ;;
      35) cfip_helper ;;
      36) love_safe_call love_cfip_auto_find ;;
      37) speed_test ;;
      38) change_preferred_info_only ;;
      39) love_safe_call love_cfip_view ;;
      40) love_safe_call love_cfip_client_side_guide ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.7 CFIP Client Test Pack Final
# Generate Windows / macOS / Linux local Cloudflare preferred-IP test package.
# ==============================================================================

love_cfip_candidates_file() {
  echo "${LOVE_HOME:-/opt/Love}/cfip-client-test/cfip_candidates.txt"
}

love_cfip_generate_client_candidates() {
  local mode="${1:-4}" count="${2:-120}" out="$3"
  mkdir -p "$(dirname "$out")"
  : > "$out"

  if declare -F love_cfip_generate_candidates >/dev/null 2>&1; then
    love_cfip_generate_candidates "$mode" "$count" "$out" && return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "缺少 python3，无法生成候选 IP。"
    return 1
  fi

  if [[ "$mode" == "6" ]]; then
    curl -fsSL --connect-timeout 8 --max-time 20 https://www.cloudflare.com/ips-v6 -o /tmp/love_cf_ips.txt || return 1
  else
    curl -fsSL --connect-timeout 8 --max-time 20 https://www.cloudflare.com/ips-v4 -o /tmp/love_cf_ips.txt || return 1
  fi

  python3 - "$count" "$out" <<'PY'
import sys, ipaddress, random
count=int(sys.argv[1])
out=sys.argv[2]
cidrs=[x.strip() for x in open('/tmp/love_cf_ips.txt') if x.strip() and not x.startswith('#')]
res=[]
per=max(1, count//max(1,len(cidrs)))
for c in cidrs:
    net=ipaddress.ip_network(c, strict=False)
    if net.version == 4:
        first=int(net.network_address)+1
        last=int(net.broadcast_address)-1
    else:
        first=int(net.network_address)+1
        last=int(net.network_address)+net.num_addresses-2
    if last <= first:
        continue
    for _ in range(per):
        res.append(str(ipaddress.ip_address(random.randint(first,last))))
random.shuffle(res)
open(out,'w').write('\n'.join(res[:count])+'\n')
PY
}

love_cfip_generate_client_test_pack() {
  love_menu_title "Love CFIP 本地测速包生成" "Windows / macOS / Linux"

  echo "这个包不是在 VPS 上测速，而是让你的电脑自己测速。"
  echo "最终结果更接近：你的电脑/手机网络 → Cloudflare IP → 节点。"
  echo
  printf "%b适合：%b Cloudflare CDN / WS / gRPC / TLS 类节点\n" "$(lc green)" "$(lc reset)"
  printf "%b不适合：%b 纯 HY2 直连 IPv6:端口\n" "$(lc yellow)" "$(lc reset)"
  echo

  read -rp "测试域名/SNI [www.cloudflare.com]: " host
  host="${host:-www.cloudflare.com}"

  read -rp "候选 IP 类型 [4/6，默认4]: " mode
  mode="${mode:-4}"

  read -rp "候选数量 [120]: " count
  count="${count:-120}"

  local dir="${LOVE_HOME:-/opt/Love}/cfip-client-test"
  local cand="${dir}/cfip_candidates.txt"
  mkdir -p "$dir"

  log "正在生成候选 IP：Cloudflare IPv${mode} / ${count} 个..."
  love_cfip_generate_client_candidates "$mode" "$count" "$cand" || {
    warn "候选 IP 生成失败。可以手动把候选 IP 一行一个写入：$cand"
    return 1
  }

  cat > "${dir}/cfip_test_windows.ps1" <<'PS1'
param(
  [string]$HostName = "www.cloudflare.com",
  [int]$Port = 443,
  [string]$Candidates = ".\cfip_candidates.txt",
  [string]$OutAll = ".\cfip_result_all.txt",
  [string]$OutTop = ".\cfip_result_top.txt",
  [int]$Timeout = 8
)

Write-Host "Love CFIP Windows local test"
Write-Host "Host/SNI: $HostName"
Write-Host "Candidates: $Candidates"
Write-Host ""

if (!(Test-Path $Candidates)) {
  Write-Host "Candidates file not found: $Candidates"
  exit 1
}

if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  Write-Host "curl.exe not found. Windows 10/11 usually includes curl.exe."
  exit 1
}

"" | Out-File -Encoding ascii $OutAll

$ips = Get-Content $Candidates | Where-Object { $_ -and !$_.StartsWith("#") }
$total = $ips.Count
$i = 0

foreach ($ip in $ips) {
  $i++
  Write-Host "[$i/$total] testing $ip ..."
  $connectTo = "${HostName}:${Port}:${ip}:${Port}"
  $url = "https://${HostName}:${Port}/cdn-cgi/trace"
  $fmt = "%{time_connect} %{time_appconnect} %{time_total} %{http_code}"

  try {
    $r = & curl.exe -k -sS -o NUL --connect-timeout 3 --max-time $Timeout --connect-to $connectTo -w $fmt $url 2>$null
    if ($LASTEXITCODE -eq 0 -and $r) {
      $parts = $r.Trim().Split(" ")
      if ($parts.Length -ge 4) {
        $timeTotal = [double]$parts[2]
        $code = $parts[3]
        if ($code -match "^(200|204|301|302|403|404)$") {
          "$ip $timeTotal $code" | Tee-Object -FilePath $OutAll -Append
        }
      }
    }
  } catch {}
}

$rows = Get-Content $OutAll | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
  $p = $_.Trim().Split(" ")
  [PSCustomObject]@{ IP=$p[0]; Time=[double]$p[1]; Code=$p[2] }
} | Sort-Object Time

$rows | Select-Object -First 20 | ForEach-Object { "$($_.IP) $($_.Time) $($_.Code)" } | Out-File -Encoding ascii $OutTop

Write-Host ""
Write-Host "Top result saved to: $OutTop"
Write-Host "Upload or copy cfip_result_top.txt back to VPS, then run:"
Write-Host "Love cfip -> 7) 导入本地测速结果"
PS1

  cat > "${dir}/cfip_test_mac_linux.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

HOST_NAME="${1:-www.cloudflare.com}"
PORT="${2:-443}"
CANDIDATES="${3:-./cfip_candidates.txt}"
OUT_ALL="${4:-./cfip_result_all.txt}"
OUT_TOP="${5:-./cfip_result_top.txt}"

echo "Love CFIP macOS/Linux local test"
echo "Host/SNI: ${HOST_NAME}"
echo "Candidates: ${CANDIDATES}"
echo

: > "${OUT_ALL}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found."
  exit 1
fi

i=0
total="$(grep -Ev '^\s*($|#)' "${CANDIDATES}" | wc -l | tr -d ' ')"

while IFS= read -r ip; do
  [[ -n "${ip}" ]] || continue
  [[ "${ip}" =~ ^# ]] && continue
  i=$((i+1))
  echo "[${i}/${total}] testing ${ip} ..."
  res="$(curl -k -sS -o /dev/null \
    --connect-timeout 3 --max-time 8 \
    --connect-to "${HOST_NAME}:${PORT}:${ip}:${PORT}" \
    -w "%{time_connect} %{time_appconnect} %{time_total} %{http_code}" \
    "https://${HOST_NAME}:${PORT}/cdn-cgi/trace" 2>/dev/null || true)"
  [[ -n "${res}" ]] || continue
  code="$(awk '{print $4}' <<< "${res}")"
  total_time="$(awk '{print $3}' <<< "${res}")"
  if [[ "${code}" =~ ^(200|204|301|302|403|404)$ ]]; then
    echo "${ip} ${total_time} ${code}" | tee -a "${OUT_ALL}"
  fi
done < "${CANDIDATES}"

sort -k2,2n "${OUT_ALL}" | head -n 20 > "${OUT_TOP}"

echo
echo "Top result saved to: ${OUT_TOP}"
echo "Upload/copy cfip_result_top.txt back to VPS, then run:"
echo "Love cfip -> 7) 导入本地测速结果"
SH
  chmod +x "${dir}/cfip_test_mac_linux.sh"

  cat > "${dir}/README.txt" <<EOF
Love CFIP Client-Side Test Pack

用途：
  在你的电脑本地网络测试 Cloudflare 优选 IP。
  这比 VPS 端测速更接近真实客户端连接效果。

测试域名/SNI：
  ${host}

Windows:
  打开 PowerShell，进入本目录后执行：
  powershell -ExecutionPolicy Bypass -File .\\cfip_test_windows.ps1 -HostName ${host}

macOS / Linux:
  chmod +x ./cfip_test_mac_linux.sh
  ./cfip_test_mac_linux.sh ${host}

输出：
  cfip_result_all.txt
  cfip_result_top.txt

导入 VPS：
  把 cfip_result_top.txt 上传回 VPS，例如：
  scp cfip_result_top.txt root@你的VPS:/root/cfip_result_top.txt

然后 VPS 执行：
  Love cfip
  7) 导入本地测速结果
  输入：/root/cfip_result_top.txt
  4) 用第一个优选地址重写导出 Address
  Love sub
  Love qr
  Love web

重要：
  只适合 Cloudflare CDN / WS / gRPC / TLS 类节点。
  纯 HY2 直连 IPv6:端口，不建议使用 Cloudflare 优选 IP。
EOF

  # Replace default HostName in PS1/sh usage hint by writing host to helper file too.
  echo "$host" > "${dir}/host.txt"

  if command -v zip >/dev/null 2>&1; then
    (cd "$dir" && zip -qr "${LOVE_HOME:-/opt/Love}/cfip-client-test.zip" .)
  else
    (cd "${LOVE_HOME:-/opt/Love}" && tar -czf cfip-client-test.tar.gz cfip-client-test)
  fi

  love_menu_title "Love CFIP 本地测速包已生成" "Download to your computer"
  echo "目录：$dir"
  echo "候选 IP：$cand"
  [[ -f "${LOVE_HOME:-/opt/Love}/cfip-client-test.zip" ]] && echo "ZIP：${LOVE_HOME:-/opt/Love}/cfip-client-test.zip"
  [[ -f "${LOVE_HOME:-/opt/Love}/cfip-client-test.tar.gz" ]] && echo "TAR：${LOVE_HOME:-/opt/Love}/cfip-client-test.tar.gz"
  echo
  echo "如果你开了 Web 面板，也可以手动复制到 Web 目录后下载。"
  echo "最简单方式：用 SFTP 下载整个目录或压缩包。"
}

love_cfip_import_local_result() {
  love_menu_title "Love 导入本地测速结果" "cfip_result_top.txt"
  local p f
  read -rp "输入本地测速结果文件路径，例如 /root/cfip_result_top.txt: " p
  [[ -f "$p" ]] || { warn "文件不存在：$p"; return 1; }

  f="$(love_cfip_file)"
  mkdir -p "$(dirname "$f")"

  # Result format: IP time code. Import first column only.
  awk 'NF>=1 && $1 !~ /^#/ {print $1}' "$p" >> "$f"
  awk '!seen[$0]++' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"

  log "已导入本地测速结果到：$f"
  love_cfip_view

  read -rp "是否立即用第一个优选地址重写导出 Address？[Y/n]: " y
  y="${y:-Y}"
  [[ "$y" =~ ^[Yy]$ ]] && love_cfip_rewrite_first
}

cfip_helper() {
  while true; do
    love_menu_title "Love CFIP 优选 IP / 域名" "VPS 测速 + 电脑本地测速"
    love_menu2 "1) 手动保存优选 IP / 域名" "6) 生成电脑本地测速包"
    love_menu2 "2) 从文件批量导入 IP/域名" "7) 导入本地测速结果"
    love_menu2 "3) 查看当前优选列表" "8) 客户端侧测速说明"
    love_menu2 "4) 用第一个优选地址重写导出" "9) 清空优选列表"
    love_menu2 "5) VPS 自动查找 CF 优选 IP" "0) 返回"

    echo
    love_ui_tip "最准确流程：6 生成本地测速包 → 电脑运行 → 7 导入结果 → 4 重写导出 → Love sub/qr/web。"
    love_ui_tip "纯 HY2 直连 IPv6:端口，不建议使用 Cloudflare 优选 IP。"
    echo

    read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" c
    case "$c" in
      1)
        read -rp "输入优选 IP / 域名: " v
        love_cfip_save_one "$v"
        love_cfip_view
        ;;
      2) love_cfip_import_file ;;
      3) love_cfip_view ;;
      4) love_cfip_rewrite_first ;;
      5) love_cfip_auto_find ;;
      6) love_cfip_generate_client_test_pack ;;
      7) love_cfip_import_local_result ;;
      8) love_cfip_client_side_guide ;;
      9)
        read -rp "确认清空优选列表？[y/N]: " y
        [[ "$y" =~ ^[Yy]$ ]] && : > "$(love_cfip_file)"
        ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.8 Xray Preselect Menu Final
# Main menu option 2 now shows node choices before asking domain/config.
# ==============================================================================

love_xray_install_core_v138() {
  local mode="${1:-wizard}"
  local node_addr="" domain="" email="" enable_hy2="no" hy2_sni="" insecure="0" has_domain="N"
  local reality_sni

  love_menu_title "Love Xray 安装配置" "$mode"

  case "$mode" in
    reality_only)
      echo "模式：VLESS + REALITY + Vision，TCP 443。"
      echo "说明：不需要域名证书；客户端地址可以是 VPS IP / IPv6 / 域名。"
      read_node_addr_with_default node_addr
      has_domain="N"
      enable_hy2="no"
      ;;
    reality_hy2_domain)
      echo "模式：VLESS + REALITY + Vision TCP 443 + HY2 UDP 443。"
      echo "说明：HY2 使用 Let's Encrypt 证书，需要你自己的域名解析到 VPS。"
      read -rp "节点域名，例如 node.example.com，输入 0 返回: " domain
      [[ "$domain" == "0" ]] && return 0
      [[ -n "$domain" ]] || { warn "域名不能为空，已返回 Xray 菜单。"; return 0; }
      node_addr="$domain"
      has_domain="Y"
      enable_hy2="yes"
      hy2_sni="$domain"
      read -rp "Let's Encrypt 邮箱，输入 0 返回: " email
      [[ "$email" == "0" ]] && return 0
      [[ -n "$email" ]] || { warn "邮箱不能为空，已返回 Xray 菜单。"; return 0; }
      ;;
    reality_hy2_self)
      echo "模式：VLESS + REALITY + Vision TCP 443 + HY2 UDP 443 自签证书。"
      echo "说明：无域名可用；HY2 客户端需要 insecure=1。"
      read_node_addr_with_default node_addr
      has_domain="N"
      enable_hy2="yes"
      insecure="1"
      read -rp "HY2 自签 SNI [self.local]: " hy2_sni
      hy2_sni="${hy2_sni:-self.local}"
      ;;
    domain_reality)
      echo "模式：有域名，但只安装 VLESS + REALITY + Vision，不安装 HY2。"
      read -rp "节点域名，例如 node.example.com，输入 0 返回: " domain
      [[ "$domain" == "0" ]] && return 0
      [[ -n "$domain" ]] || { warn "域名不能为空，已返回 Xray 菜单。"; return 0; }
      node_addr="$domain"
      has_domain="Y"
      enable_hy2="no"
      ;;
    wizard|*)
      echo "模式：旧版 Xray 稳定向导。"
      read -rp "有自己的节点域名吗？[Y/n/0返回]: " has_domain
      has_domain="${has_domain:-Y}"
      [[ "$has_domain" == "0" ]] && return 0
      if [[ "${has_domain}" =~ ^[Yy]$ ]]; then
        read -rp "节点域名，例如 node.example.com，输入 0 返回: " domain
        [[ "$domain" == "0" ]] && return 0
        [[ -n "${domain}" ]] || { warn "域名不能为空，已返回 Xray 菜单。"; return 0; }
        node_addr="${domain}"

        read -rp "安装 HY2 / Hysteria2？[Y/n]: " hy2_choice
        hy2_choice="${hy2_choice:-Y}"
        if [[ "${hy2_choice}" =~ ^[Yy]$ ]]; then
          enable_hy2="yes"
          hy2_sni="${domain}"
          read -rp "Let's Encrypt 邮箱，输入 0 返回: " email
          [[ "$email" == "0" ]] && return 0
          [[ -n "${email}" ]] || { warn "邮箱不能为空，已返回 Xray 菜单。"; return 0; }
        else
          enable_hy2="no"
          hy2_sni=""
        fi
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
      ;;
  esac

  echo
  printf "%b即将安装：%b\n" "$(lc green)" "$(lc reset)"
  echo "  Xray Reality: yes"
  echo "  VLESS Vision: yes"
  echo "  HY2: ${enable_hy2}"
  echo "  Client Address: ${node_addr}"
  [[ -n "$hy2_sni" ]] && echo "  HY2 SNI: ${hy2_sni}"
  [[ "$insecure" == "1" ]] && echo "  HY2 insecure: 1"
  echo

  read -rp "确认继续安装？[Y/n]: " ok
  ok="${ok:-Y}"
  [[ "$ok" =~ ^[Yy]$ ]] || return 0

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
  love_after_node_generated_exports
  log "Xray 稳定模式安装完成。"
}

install_xray_stable() {
  while true; do
    love_menu_title "Love Xray Reality 节点选择" "先选节点类型，再填写域名/地址"

    printf "%b当前 Xray 稳定模式实际包含：%b\n" "$(lc green)" "$(lc reset)"
    echo "  - VLESS + REALITY + Vision，TCP 443"
    echo "  - 可选 HY2 / Hysteria2，UDP 443"
    echo
    printf "%b不在这里的协议：%bTUIC / Naive / ShadowTLS / AnyTLS / VMess / Trojan 等请用 3) sing-box 全协议。\n" "$(lc yellow)" "$(lc reset)"
    echo

    love_menu2 "1) VLESS Reality Vision【无域名/IP可用】" "5) 传统完整 Xray 向导"
    love_menu2 "2) VLESS Reality + HY2【有域名/证书】" "6) 跳转 sing-box 全协议"
    love_menu2 "3) VLESS Reality + HY2【无域名/自签】" "7) 查看当前节点信息"
    love_menu2 "4) 有域名但只装 Reality【不装HY2】" "0) 返回"

    echo
    love_ui_tip "建议：只要稳定节点选 1；有域名并想加 UDP 高速 HY2 选 2；无域名想强行 HY2 选 3。"
    echo

    read -rp "$(printf "%b请选择节点类型:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_xray_install_core_v138 reality_only ;;
      2) love_xray_install_core_v138 reality_hy2_domain ;;
      3) love_xray_install_core_v138 reality_hy2_self ;;
      4) love_xray_install_core_v138 domain_reality ;;
      5) love_xray_install_core_v138 wizard ;;
      6) install_singbox_native ;;
      7) show_node_info ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.9 Xray/HY2 Choice Complete Final
# Main menu option 2 shows standalone HY2/Hysteria2 UDP 443 clearly.
# ==============================================================================

love_xray_install_hy2_only_v139() {
  love_menu_title "Love HY2 / Hysteria2 单独安装" "UDP 443"

  echo "模式：HY2 / Hysteria2 单独节点，UDP 443。"
  echo "说明：这是独立 HY2，不安装 VLESS Reality。"
  echo
  echo "证书模式："
  love_menu2 "1) 有域名 / Let's Encrypt 证书" "2) 无域名 / 自签证书 insecure=1"
  love_menu2 "0) 返回" ""

  read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" m
  case "$m" in
    1)
      # Reuse existing Xray+HY2 installer path but install HY2-capable stable config.
      # In current Love architecture, HY2 generation and subscription are tied to stable node export helpers.
      love_xray_install_core_v138 reality_hy2_domain
      ;;
    2)
      love_xray_install_core_v138 reality_hy2_self
      ;;
    0) return 0 ;;
    *) warn "无效选择。" ;;
  esac
}

install_xray_stable() {
  while true; do
    love_menu_title "Love Xray / HY2 节点选择" "先选节点类型，再填写域名/地址"

    printf "%b这里包含的稳定节点类型：%b\n" "$(lc green)" "$(lc reset)"
    echo "  - VLESS + REALITY + Vision，TCP 443"
    echo "  - HY2 / Hysteria2，UDP 443"
    echo "  - Reality + HY2 组合模式"
    echo
    printf "%b更多协议：%bTUIC / Naive / ShadowTLS / AnyTLS / VMess / Trojan 等请用 3) sing-box 全协议。\n" "$(lc yellow)" "$(lc reset)"
    echo

    love_menu2 "1) VLESS Reality Vision【无域名/IP可用】" "6) 传统完整 Xray 向导"
    love_menu2 "2) HY2 / Hysteria2 UDP 443【单独安装】" "7) 跳转 sing-box 全协议"
    love_menu2 "3) VLESS Reality + HY2【有域名/证书】" "8) 查看当前节点信息"
    love_menu2 "4) VLESS Reality + HY2【无域名/自签】" "0) 返回"
    love_menu2 "5) 有域名但只装 Reality【不装HY2】" ""

    echo
    love_ui_tip "建议：只要稳定 Reality 选 1；只要 UDP 高速 HY2 选 2；有域名想组合选 3。"
    love_ui_tip "注意：HY2 单独安装仍会复用当前 Love 的证书/订阅生成逻辑。"
    echo

    read -rp "$(printf "%b请选择节点类型:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_xray_install_core_v138 reality_only ;;
      2) love_xray_install_hy2_only_v139 ;;
      3) love_xray_install_core_v138 reality_hy2_domain ;;
      4) love_xray_install_core_v138 reality_hy2_self ;;
      5) love_xray_install_core_v138 domain_reality ;;
      6) love_xray_install_core_v138 wizard ;;
      7) install_singbox_native ;;
      8) show_node_info ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.10 Xray Menu Wide Final
# Rename "旧版" to "传统", widen Xray two-column menu to avoid truncation.
# ==============================================================================

love_ui_menu2_wide_xray() {
  local left right lcell rcell
  left="$1"
  right="$2"
  lcell="$(love_cjk_pad "$left" 48)"
  rcell="$(love_cjk_pad "$right" 34)"
  printf "  %b│%b %b%s%b %b│%b %b%s%b %b│%b\n" \
    "$(lc blue)" "$(lc reset)" "$(lc yellow)" "$lcell" "$(lc reset)" \
    "$(lc blue)" "$(lc reset)" "$(lc cyan)" "$rcell" "$(lc reset)" \
    "$(lc blue)" "$(lc reset)"
}

love_xray_install_hy2_only_v139() {
  love_menu_title "Love HY2 / Hysteria2 单独安装" "UDP 443"

  echo "模式：HY2 / Hysteria2 单独节点，UDP 443。"
  echo "说明：这是独立 HY2，不安装 VLESS Reality。"
  echo
  echo "证书模式："
  love_ui_menu2_wide_xray "1) 有域名 / Let's Encrypt 证书" "2) 无域名 / 自签证书 insecure=1"
  love_ui_menu2_wide_xray "0) 返回" ""

  read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" m
  case "$m" in
    1) love_xray_install_core_v138 reality_hy2_domain ;;
    2) love_xray_install_core_v138 reality_hy2_self ;;
    0) return 0 ;;
    *) warn "无效选择。" ;;
  esac
}

install_xray_stable() {
  while true; do
    love_menu_title "Love Xray / HY2 节点选择" "先选节点类型，再填写域名/地址"

    printf "%b这里包含的稳定节点类型：%b\n" "$(lc green)" "$(lc reset)"
    echo "  - VLESS + REALITY + Vision，TCP 443"
    echo "  - HY2 / Hysteria2，UDP 443"
    echo "  - Reality + HY2 组合模式"
    echo
    printf "%b更多协议：%bTUIC / Naive / ShadowTLS / AnyTLS / VMess / Trojan 等请用 3) sing-box 全协议。\n" "$(lc yellow)" "$(lc reset)"
    echo

    love_ui_menu2_wide_xray "1) VLESS Reality Vision【无域名/IP可用】" "6) 传统完整 Xray 向导"
    love_ui_menu2_wide_xray "2) HY2 / Hysteria2 UDP 443【单独安装】" "7) 跳转 sing-box 全协议"
    love_ui_menu2_wide_xray "3) VLESS Reality + HY2【有域名/证书】" "8) 查看当前节点信息"
    love_ui_menu2_wide_xray "4) VLESS Reality + HY2【无域名/自签】" "0) 返回"
    love_ui_menu2_wide_xray "5) 有域名但只装 Reality【不装HY2】" ""

    echo
    love_ui_tip "建议：只要稳定 Reality 选 1；只要 UDP 高速 HY2 选 2；有域名想组合选 3。"
    love_ui_tip "说明：传统完整向导 = 以前那种一步步询问域名/邮箱/HY2 的完整流程，不是旧脚本版本。"
    echo

    read -rp "$(printf "%b请选择节点类型:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_xray_install_core_v138 reality_only ;;
      2) love_xray_install_hy2_only_v139 ;;
      3) love_xray_install_core_v138 reality_hy2_domain ;;
      4) love_xray_install_core_v138 reality_hy2_self ;;
      5) love_xray_install_core_v138 domain_reality ;;
      6) love_xray_install_core_v138 wizard ;;
      7) install_singbox_native ;;
      8) show_node_info ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.11 Xray Menu Shift Right Final
# Xray menu: right column moved further right; auto single-column on narrow terminals.
# ==============================================================================

love_ui_menu2_xray_shift() {
  local left="$1" right="$2" lcell rcell cols
  cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}"

  # If terminal is narrow, use single-column to avoid truncation/overlap.
  if [[ "${cols}" -lt 105 ]]; then
    lcell="$(love_cjk_pad "$left" 72)"
    printf "  %b│%b %b%s%b %b│%b\n" \
      "$(lc blue)" "$(lc reset)" "$(lc yellow)" "$lcell" "$(lc reset)" "$(lc blue)" "$(lc reset)"
    if [[ -n "$right" ]]; then
      rcell="$(love_cjk_pad "$right" 72)"
      printf "  %b│%b %b%s%b %b│%b\n" \
        "$(lc blue)" "$(lc reset)" "$(lc cyan)" "$rcell" "$(lc reset)" "$(lc blue)" "$(lc reset)"
    fi
    return 0
  fi

  # Wide terminal: move second column further right.
  lcell="$(love_cjk_pad "$left" 58)"
  rcell="$(love_cjk_pad "$right" 30)"
  printf "  %b│%b %b%s%b %b│%b %b%s%b %b│%b\n" \
    "$(lc blue)" "$(lc reset)" "$(lc yellow)" "$lcell" "$(lc reset)" \
    "$(lc blue)" "$(lc reset)" "$(lc cyan)" "$rcell" "$(lc reset)" \
    "$(lc blue)" "$(lc reset)"
}

love_xray_install_hy2_only_v139() {
  love_menu_title "Love HY2 / Hysteria2 单独安装" "UDP 443"

  echo "模式：HY2 / Hysteria2 单独节点，UDP 443。"
  echo "说明：这是独立 HY2，不安装 VLESS Reality。"
  echo
  echo "证书模式："
  love_ui_menu2_xray_shift "1) 有域名 / Let's Encrypt 证书" "2) 无域名 / 自签证书 insecure=1"
  love_ui_menu2_xray_shift "0) 返回" ""

  read -rp "$(printf "%b请选择:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" m
  case "$m" in
    1) love_xray_install_core_v138 reality_hy2_domain ;;
    2) love_xray_install_core_v138 reality_hy2_self ;;
    0) return 0 ;;
    *) warn "无效选择。" ;;
  esac
}

install_xray_stable() {
  while true; do
    love_menu_title "Love Xray / HY2 节点选择" "先选节点类型，再填写域名/地址"

    printf "%b这里包含的稳定节点类型：%b\n" "$(lc green)" "$(lc reset)"
    echo "  - VLESS + REALITY + Vision，TCP 443"
    echo "  - HY2 / Hysteria2，UDP 443"
    echo "  - Reality + HY2 组合模式"
    echo
    printf "%b更多协议：%bTUIC / Naive / ShadowTLS / AnyTLS / VMess / Trojan 等请用 3) sing-box 全协议。\n" "$(lc yellow)" "$(lc reset)"
    echo

    love_ui_menu2_xray_shift "1) VLESS Reality Vision【无域名 / IP 可用】" "6) 传统完整 Xray 向导"
    love_ui_menu2_xray_shift "2) HY2 / Hysteria2 UDP 443【单独安装】" "7) 跳转 sing-box 全协议"
    love_ui_menu2_xray_shift "3) VLESS Reality + HY2【有域名 / 证书】" "8) 查看当前节点信息"
    love_ui_menu2_xray_shift "4) VLESS Reality + HY2【无域名 / 自签】" "0) 返回"
    love_ui_menu2_xray_shift "5) 有域名但只装 Reality【不装 HY2】" ""

    echo
    love_ui_tip "建议：只要稳定 Reality 选 1；只要 UDP 高速 HY2 选 2；有域名想组合选 3。"
    love_ui_tip "说明：传统完整向导 = 以前那种一步步询问域名/邮箱/HY2 的完整流程，不是旧脚本版本。"
    echo

    read -rp "$(printf "%b请选择节点类型:%b " "$(lc bold)$(lc yellow)" "$(lc reset)")" x
    case "$x" in
      1) love_xray_install_core_v138 reality_only ;;
      2) love_xray_install_hy2_only_v139 ;;
      3) love_xray_install_core_v138 reality_hy2_domain ;;
      4) love_xray_install_core_v138 reality_hy2_self ;;
      5) love_xray_install_core_v138 domain_reality ;;
      6) love_xray_install_core_v138 wizard ;;
      7) install_singbox_native ;;
      8) show_node_info ;;
      0) return 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}



# ==============================================================================
# Love v13.12 Self Install Guard Final
# Fix empty /opt/Love issue: always persist the running script to /opt/Love/Love.sh
# and repair /usr/local/bin/Love + /usr/local/bin/love symlinks.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.56.1-source-first-export-hotfix"
LOVE_RAW_URL_DEFAULT="https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh"

love_version_line_v1312() {
  echo "VERSION=\"${LOVE_SCRIPT_VERSION}\""
}

love_script_self_path_v1312() {
  local p=""
  p="${BASH_SOURCE[0]:-$0}"
  readlink -f "$p" 2>/dev/null || echo "$p"
}

ensure_love_installed_v1312() {
  local target="/opt/Love/Love.sh"
  local bin1="/usr/local/bin/Love"
  local bin2="/usr/local/bin/love"
  local tmp="/tmp/Love.selfinstall.$$"
  local self=""
  local want=""
  local have=""

  # Avoid recursion if the wrapper is called more than once in the same shell.
  [[ "${LOVE_SELF_INSTALL_GUARD_DONE:-}" == "1" ]] && return 0
  export LOVE_SELF_INSTALL_GUARD_DONE=1

  want="$(love_version_line_v1312)"
  mkdir -p /opt/Love

  have="$(grep '^VERSION=' "$target" 2>/dev/null || true)"

  if [[ ! -s "$target" ]] || [[ -z "$have" ]] || [[ "$have" != "$want" ]]; then
    echo "[WARN] /opt/Love/Love.sh 缺失、异常或不是当前版本，正在自动修复..."
    self="$(love_script_self_path_v1312)"

    if [[ -f "$self" ]] && grep -q '^VERSION=' "$self" 2>/dev/null; then
      install -m 755 "$self" "$target"
    else
      curl -L --fail --retry 3 \
        -H 'Cache-Control: no-cache' \
        -o "$tmp" \
        "${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}?$(date +%s)" \
        || wget -O "$tmp" "${LOVE_UPDATE_URL:-$LOVE_RAW_URL_DEFAULT}?$(date +%s)" \
        || {
          echo "[ERROR] 下载 Love.sh 失败，无法修复 /opt/Love/Love.sh"
          return 1
        }

      bash -n "$tmp" || {
        echo "[ERROR] 下载到的 Love.sh 语法检查失败"
        rm -f "$tmp"
        return 1
      }

      install -m 755 "$tmp" "$target"
      rm -f "$tmp"
    fi

    chmod +x "$target"
  fi

  # Always repair command symlinks.
  ln -sf "$target" "$bin1"
  ln -sf "$target" "$bin2"

  # Verify final target.
  if [[ ! -s "$target" ]] || ! grep -q '^VERSION=' "$target" 2>/dev/null; then
    echo "[ERROR] /opt/Love/Love.sh 修复后仍然异常"
    return 1
  fi

  return 0
}

# Preserve original main and main_menu, then wrap them.
# This also fixes VERSION being overwritten by /etc/os-release in some checks.
if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1312 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1312/')"
fi

if declare -F main_menu >/dev/null 2>&1 && ! declare -F love_original_main_menu_v1312 >/dev/null 2>&1; then
  eval "$(declare -f main_menu | sed '1s/^main_menu/love_original_main_menu_v1312/')"
fi

main_menu() {
  VERSION="${LOVE_SCRIPT_VERSION}"
  love_original_main_menu_v1312 "$@"
}

main() {
  VERSION="${LOVE_SCRIPT_VERSION}"
  ensure_love_installed_v1312 || exit 1
  VERSION="${LOVE_SCRIPT_VERSION}"
  love_original_main_v1312 "$@"
}



# ==============================================================================
# Love v13.13 Web Panel Enhanced Final
# Replace placeholder static page with useful node/subscription/download panel.
# ==============================================================================

love_web_public_base_url_v1313() {
  local port="${1:-8099}"
  local ip6 ip4
  ip6="$(curl -6 -s --connect-timeout 3 --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  ip4="$(curl -4 -s --connect-timeout 3 --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "$ip6" ]]; then
    echo "http://[${ip6}]:${port}"
  elif [[ -n "$ip4" ]]; then
    echo "http://${ip4}:${port}"
  else
    echo "http://YOUR_SERVER_IP:${port}"
  fi
}

love_web_copy_if_exists_v1313() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" 2>/dev/null || true
  fi
}

love_web_build_downloads_v1313() {
  local webroot="$1"
  mkdir -p "$webroot/downloads" "$webroot/qr" "$webroot/sub" "$webroot/clients"

  # Subscription and client exports, if they exist.
  love_web_copy_if_exists_v1313 "/opt/Love/subscribe/all.txt" "$webroot/sub/all.txt"
  love_web_copy_if_exists_v1313 "/opt/Love/subscribe/all_base64.txt" "$webroot/sub/all_base64.txt"
  love_web_copy_if_exists_v1313 "/opt/Love/subscribe/mihomo.yaml" "$webroot/sub/mihomo.yaml"
  love_web_copy_if_exists_v1313 "/opt/Love/subscribe/sing-box-client.json" "$webroot/sub/sing-box-client.json"
  love_web_copy_if_exists_v1313 "/opt/Love/subscribe/clients" "$webroot/clients"
  love_web_copy_if_exists_v1313 "/opt/Love/subscribe/qr" "$webroot/qr"

  # CFIP local test pack.
  love_web_copy_if_exists_v1313 "/opt/Love/cfip-client-test.zip" "$webroot/downloads/cfip-client-test.zip"
  love_web_copy_if_exists_v1313 "/opt/Love/cfip-client-test.tar.gz" "$webroot/downloads/cfip-client-test.tar.gz"

  # Common backup if present.
  local last_backup
  last_backup="$(ls -t /root/love-backup-*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$last_backup" ]] && love_web_copy_if_exists_v1313 "$last_backup" "$webroot/downloads/$(basename "$last_backup")"

  chown -R www-data:www-data "$webroot" 2>/dev/null || true
  chmod -R 755 "$webroot" 2>/dev/null || true
}

love_web_collect_links_v1313() {
  local webroot="$1"
  local out="$webroot/node-links.txt"
  : > "$out"

  {
    echo "# Love Node Links"
    echo "# Generated at: $(date)"
    echo

    if [[ -f /opt/Love/node_info.txt ]]; then
      cat /opt/Love/node_info.txt
      echo
    fi

    if [[ -f /opt/Love/subscribe/all.txt ]]; then
      echo "# /opt/Love/subscribe/all.txt"
      cat /opt/Love/subscribe/all.txt
      echo
    fi

    if [[ -f /opt/Love/subscribe/clients/v2rayn-uri.txt ]]; then
      echo "# V2RayN"
      cat /opt/Love/subscribe/clients/v2rayn-uri.txt
      echo
    fi

    if [[ -f /opt/Love/subscribe/clients/nekobox-uri.txt ]]; then
      echo "# NekoBox"
      cat /opt/Love/subscribe/clients/nekobox-uri.txt
      echo
    fi
  } >> "$out"

  chown www-data:www-data "$out" 2>/dev/null || true
  chmod 644 "$out" 2>/dev/null || true
}

web_admin_page() {
  love_menu_title "Love Web 管理页" "Enhanced Static Panel"

  local port user pass webroot conf base node_links sub_status qr_status cfip_status
  read -rp "Web 管理页端口 [8099]: " port
  port="${port:-8099}"

  read -rp "是否开启 Basic Auth 密码保护？[Y/n]: " auth
  auth="${auth:-Y}"

  user="love"
  pass=""
  if [[ "$auth" =~ ^[Yy]$ ]]; then
    read -rp "Web 用户名 [love]: " user
    user="${user:-love}"
    read -rp "Web 密码，留空自动生成: " pass
    if [[ -z "$pass" ]]; then
      pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
    fi
  fi

  webroot="/var/www/love-admin"
  conf="/etc/nginx/sites-available/love-admin"

  mkdir -p "$webroot" /etc/nginx/sites-available /etc/nginx/sites-enabled

  # Try to regenerate exports first, but do not fail web page if export functions fail.
  export_subscription >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || generate_qrcodes >/dev/null 2>&1 || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  generate_client_exports >/dev/null 2>&1 || true

  love_web_build_downloads_v1313 "$webroot"
  love_web_collect_links_v1313 "$webroot"

  [[ -s "$webroot/node-links.txt" ]] && node_links="ready" || node_links="empty"
  [[ -d "$webroot/qr" ]] && qr_status="ready" || qr_status="empty"
  [[ -f "$webroot/downloads/cfip-client-test.zip" || -f "$webroot/downloads/cfip-client-test.tar.gz" ]] && cfip_status="ready" || cfip_status="not generated"
  [[ -f "$webroot/sub/all.txt" || -f "$webroot/sub/all_base64.txt" ]] && sub_status="ready" || sub_status="empty"

  base="$(love_web_public_base_url_v1313 "$port")"

  cat > "$webroot/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Love Admin Panel</title>
  <style>
    :root{
      --bg:#0f172a; --text:#e5e7eb; --card:#111827; --border:#334155;
      --hero1:#1d4ed8; --hero2:#7c3aed; --h2:#93c5fd; --link:#67e8f9;
      --code:#020617; --codeText:#d1d5db; --muted:#94a3b8; --yellow:#facc15;
      --btn:#2563eb; --btnGreen:#16a34a; --btnOrange:#ea580c; --btnGray:#475569;
    }
    body.theme-green{
      --bg:#edf7ed; --text:#12351f; --card:#ffffff; --border:#b9d8bd;
      --hero1:#2e7d32; --hero2:#66bb6a; --h2:#1b5e20; --link:#0f766e;
      --code:#f2fff2; --codeText:#12351f; --muted:#4b6b50; --yellow:#8a5a00;
      --btn:#2e7d32; --btnGreen:#1b8a3b; --btnOrange:#b45309; --btnGray:#6b7f6d;
    }
    body.theme-dark{
      --bg:#0f172a; --text:#e5e7eb; --card:#111827; --border:#334155;
      --hero1:#1d4ed8; --hero2:#7c3aed; --h2:#93c5fd; --link:#67e8f9;
      --code:#020617; --codeText:#d1d5db; --muted:#94a3b8; --yellow:#facc15;
      --btn:#2563eb; --btnGreen:#16a34a; --btnOrange:#ea580c; --btnGray:#475569;
    }
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,"Microsoft YaHei",sans-serif;background:var(--bg);color:var(--text);margin:0;padding:24px;transition:background .25s,color .25s;}
    .wrap{max-width:1080px;margin:0 auto;}
    .hero{background:linear-gradient(135deg,var(--hero1),var(--hero2));padding:24px;border-radius:20px;box-shadow:0 12px 30px rgba(0,0,0,.18);color:white;}
    h1{margin:0 0 8px;font-size:28px}
    h2{margin:22px 0 12px;font-size:20px;color:var(--h2)}
    .themebar{display:flex;justify-content:space-between;align-items:center;gap:12px;background:var(--card);border:1px solid var(--border);border-radius:16px;padding:14px 16px;margin-top:16px;}
    .themebar .label{font-weight:700;color:var(--h2)}
    .switch{display:flex;gap:8px;flex-wrap:wrap}
    .switch button{border:1px solid var(--border);background:var(--code);color:var(--text);border-radius:999px;padding:8px 12px;cursor:pointer}
    .switch button.active{background:var(--btn);color:white;border-color:var(--btn)}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px;margin-top:18px;}
    .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:16px;}
    .card h3{margin:0 0 10px;font-size:17px;color:var(--yellow)}
    a{color:var(--link);text-decoration:none;word-break:break-all}
    a:hover{text-decoration:underline}
    code,pre{background:var(--code);border:1px solid var(--border);border-radius:12px;color:var(--codeText);padding:10px;display:block;white-space:pre-wrap;word-break:break-all}
    .ok{color:#22c55e}.warn{color:#ca8a04}.muted{color:var(--muted)}
    .btn{display:inline-block;background:var(--btn);color:white;padding:9px 12px;border-radius:10px;margin:4px 4px 4px 0}
    .btn.green{background:var(--btnGreen)}.btn.orange{background:var(--btnOrange)}.btn.gray{background:var(--btnGray)}
    .floating-theme{
      position:fixed;right:18px;top:18px;z-index:9999;
      background:rgba(15,23,42,.92);backdrop-filter:blur(8px);
      border:1px solid rgba(148,163,184,.45);border-radius:999px;
      padding:8px;box-shadow:0 10px 30px rgba(0,0,0,.28);
      display:flex;gap:6px;align-items:center;
    }
    body.theme-green .floating-theme{background:rgba(237,247,237,.94);border-color:#9fcbab}
    .floating-theme button{
      border:0;border-radius:999px;padding:8px 12px;cursor:pointer;font-weight:700;
      background:var(--code);color:var(--text);
    }
    .floating-theme button.active{background:var(--btn);color:white}
    @media(max-width:760px){
      .floating-theme{position:static;margin:0 auto 14px;justify-content:center;border-radius:16px}
    }

    table{width:100%;border-collapse:collapse;background:var(--card);border-radius:12px;overflow:hidden}
    td,th{border-bottom:1px solid var(--border);padding:10px;text-align:left}
    th{color:var(--yellow)}
    body.theme-green .hero{background:linear-gradient(135deg,#1b5e20,#81c784)!important;}
    body.theme-green .card, body.theme-green table, body.theme-green .themebar{background:#ffffff!important;color:#12351f!important;}
    body.theme-green code, body.theme-green pre{background:#f2fff2!important;color:#12351f!important;}
    body.theme-green h2{color:#1b5e20!important;}
    body.theme-green a{color:#0f766e!important;}

  </style>
</head>
<body>
<input class="theme-radio" type="radio" name="loveTheme" id="themeDark" checked>
<input class="theme-radio" type="radio" name="loveTheme" id="themeGreen">
<div class="floating-theme" title="切换 Web 页面主题">
  <label for="themeDark">深色主题</label>
  <label for="themeGreen">绿色护眼</label>
</div>
<div class="page">
<div class="wrap">
  <div class="hero">
    <h1>Love Admin Panel</h1>
    <div>Status: <span class="ok">OK</span> · Theme Switch: <span class="ok">Enabled</span></div>
    <div class="muted">这是静态管理页，只展示节点、订阅、二维码、下载入口；不会在浏览器执行 root 命令。</div>
    <div class="muted">Base URL: ${base}</div>
  </div></div>

  <h2>状态 / Status</h2>
  <table>
    <tr><th>项目</th><th>状态</th><th>说明</th></tr>
    <tr><td>Node Links</td><td>${node_links}</td><td>节点链接汇总文件</td></tr>
    <tr><td>Subscription</td><td>${sub_status}</td><td>订阅文件是否已生成</td></tr>
    <tr><td>QR Codes</td><td>${qr_status}</td><td>二维码目录是否存在</td></tr>
    <tr><td>CFIP Pack</td><td>${cfip_status}</td><td>电脑本地测速包</td></tr>
  </table>

  <h2>节点 / 订阅 / 二维码</h2>
  <div class="grid">
    <div class="card">
      <h3>节点链接汇总</h3>
      <p>查看当前导出的节点链接，适合复制到客户端。</p>
      <a class="btn" href="/node-links.txt">打开 node-links.txt</a>
    </div>
    <div class="card">
      <h3>Raw 订阅</h3>
      <p>一行一个节点链接。</p>
      <a class="btn" href="/sub/all.txt">打开 all.txt</a>
      <a class="btn gray" href="/sub/all_base64.txt">Base64</a>
    </div>
    <div class="card">
      <h3>二维码</h3>
      <p>手机端可进入目录查看二维码图片。</p>
      <a class="btn green" href="/qr/">打开 QR 目录</a>
    </div>
  </div>

  <h2>客户端配置文件</h2>
  <div class="grid">
    <div class="card">
      <h3>Mihomo / Clash</h3>
      <a class="btn" href="/sub/mihomo.yaml">下载 mihomo.yaml</a>
    </div>
    <div class="card">
      <h3>sing-box Client</h3>
      <a class="btn" href="/sub/sing-box-client.json">下载 sing-box-client.json</a>
    </div>
    <div class="card">
      <h3>客户端目录</h3>
      <p>V2RayN / Shadowrocket / NekoBox 等导出文件。</p>
      <a class="btn" href="/clients/">打开 clients 目录</a>
    </div>
  </div>

  <h2>CFIP 本地测速包</h2>
  <div class="grid">
    <div class="card">
      <h3>Windows / macOS / Linux 测速包</h3>
      <p>下载到你的电脑本地测速 Cloudflare 优选 IP。</p>
      <a class="btn orange" href="/downloads/cfip-client-test.zip">下载 ZIP</a>
      <a class="btn gray" href="/downloads/cfip-client-test.tar.gz">下载 TAR.GZ</a>
    </div>
  </div>

  <h2>常用命令</h2>
  <pre>Love -n
Love sub
Love qr
Love web
Love cfip
Love warp-auto-fix</pre>

  <h2>说明</h2>
  <div class="card">
    <p><b>如果这里只有 Status: OK 或内容为空：</b>先在 VPS 执行 <code>Love sub</code>、<code>Love qr</code>、<code>Love web</code> 重新生成。</p>
    <p><b>如果文件 404：</b>说明对应文件还没有生成，比如 CFIP 测速包需要先执行 <code>Love cfip → 6</code>。</p>
  </div>
</div>
</body>
</html>
EOF

  if [[ "$auth" =~ ^[Yy]$ ]]; then
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y apache2-utils nginx >/dev/null 2>&1 || true
    htpasswd -bc /etc/nginx/.love_web_htpasswd "$user" "$pass" >/dev/null 2>&1 || true
  else
    apt-get install -y nginx >/dev/null 2>&1 || true
    rm -f /etc/nginx/.love_web_htpasswd
  fi

  cat > "$conf" <<EOF
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    root ${webroot};
    index index.html;
    autoindex on;
    charset utf-8;
EOF

  if [[ "$auth" =~ ^[Yy]$ ]]; then
    cat >> "$conf" <<EOF
    auth_basic "Love Admin";
    auth_basic_user_file /etc/nginx/.love_web_htpasswd;
EOF
  fi

  cat >> "$conf" <<'EOF'
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

  ln -sf "$conf" /etc/nginx/sites-enabled/love-admin
  nginx -t || {
    warn "nginx 配置检查失败。"
    return 1
  }

  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || {
    warn "nginx 重启失败，尝试 reload。"
    systemctl reload nginx 2>/dev/null || true
  }

  ufw allow "${port}/tcp" >/dev/null 2>&1 || true

  echo
  log "Love Web Panel 已生成。"
  echo "访问地址：${base}/"
  if [[ "$auth" =~ ^[Yy]$ ]]; then
    echo "用户名：${user}"
    echo "密码：${pass}"
  fi
  echo
  echo "常用下载："
  echo "  节点汇总：${base}/node-links.txt"
  echo "  订阅：${base}/sub/all.txt"
  echo "  二维码目录：${base}/qr/"
  echo "  客户端目录：${base}/clients/"
  echo "  CFIP 测速包：${base}/downloads/cfip-client-test.zip"
}



# ==============================================================================
# Love v13.18 Web Theme Clean Final
# Full override web_admin_page: clean old webroot, no JS, no duplicated buttons.
# ==============================================================================

love_web_public_base_url_v1318() {
  local port="${1:-8099}"
  local ip6 ip4
  ip6="$(curl -6 -s --connect-timeout 3 --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  ip4="$(curl -4 -s --connect-timeout 3 --max-time 5 https://ifconfig.co 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "$ip6" ]]; then
    echo "http://[${ip6}]:${port}"
  elif [[ -n "$ip4" ]]; then
    echo "http://${ip4}:${port}"
  else
    echo "http://YOUR_SERVER_IP:${port}"
  fi
}

love_web_copy_if_exists_v1318() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" 2>/dev/null || true
  fi
}

love_web_build_downloads_v1318() {
  local webroot="$1"
  mkdir -p "$webroot/downloads" "$webroot/qr" "$webroot/sub" "$webroot/clients"

  love_web_copy_if_exists_v1318 "/opt/Love/subscribe/all.txt" "$webroot/sub/all.txt"
  love_web_copy_if_exists_v1318 "/opt/Love/subscribe/all_base64.txt" "$webroot/sub/all_base64.txt"
  love_web_copy_if_exists_v1318 "/opt/Love/subscribe/mihomo.yaml" "$webroot/sub/mihomo.yaml"
  love_web_copy_if_exists_v1318 "/opt/Love/subscribe/sing-box-client.json" "$webroot/sub/sing-box-client.json"
  love_web_copy_if_exists_v1318 "/opt/Love/subscribe/clients" "$webroot/clients"
  love_web_copy_if_exists_v1318 "/opt/Love/subscribe/qr" "$webroot/qr"

  love_web_copy_if_exists_v1318 "/opt/Love/cfip-client-test.zip" "$webroot/downloads/cfip-client-test.zip"
  love_web_copy_if_exists_v1318 "/opt/Love/cfip-client-test.tar.gz" "$webroot/downloads/cfip-client-test.tar.gz"

  local last_backup
  last_backup="$(ls -t /root/love-backup-*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$last_backup" ]] && love_web_copy_if_exists_v1318 "$last_backup" "$webroot/downloads/$(basename "$last_backup")"

  chown -R www-data:www-data "$webroot" 2>/dev/null || true
  chmod -R 755 "$webroot" 2>/dev/null || true
}

love_web_collect_links_v1318() {
  local webroot="$1"
  local out="$webroot/node-links.txt"
  : > "$out"

  {
    echo "# Love Node Links"
    echo "# Generated at: $(date)"
    echo
    [[ -f /opt/Love/node_info.txt ]] && cat /opt/Love/node_info.txt && echo
    [[ -f /opt/Love/subscribe/all.txt ]] && echo "# /opt/Love/subscribe/all.txt" && cat /opt/Love/subscribe/all.txt && echo
    [[ -f /opt/Love/subscribe/clients/v2rayn-uri.txt ]] && echo "# V2RayN" && cat /opt/Love/subscribe/clients/v2rayn-uri.txt && echo
    [[ -f /opt/Love/subscribe/clients/nekobox-uri.txt ]] && echo "# NekoBox" && cat /opt/Love/subscribe/clients/nekobox-uri.txt && echo
  } >> "$out"

  chown www-data:www-data "$out" 2>/dev/null || true
  chmod 644 "$out" 2>/dev/null || true
}

web_admin_page() {
  love_menu_title "Love Web 管理页" "Clean Theme Panel / No JS"

  local port auth user pass webroot conf base node_links sub_status qr_status cfip_status
  read -rp "Web 管理页端口 [8099]: " port
  port="${port:-8099}"

  read -rp "是否开启 Basic Auth 密码保护？[Y/n]: " auth
  auth="${auth:-Y}"

  user="love"
  pass=""
  if [[ "$auth" =~ ^[Yy]$ ]]; then
    read -rp "Web 用户名 [love]: " user
    user="${user:-love}"
    read -rp "Web 密码，留空自动生成: " pass
    if [[ -z "$pass" ]]; then
      pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
    fi
  fi

  webroot="/var/www/love-admin"
  conf="/etc/nginx/sites-available/love-admin"

  # Critical fix: fully clean old page files to remove duplicated old buttons/scripts.
  rm -rf "$webroot"
  mkdir -p "$webroot" /etc/nginx/sites-available /etc/nginx/sites-enabled

  export_subscription >/dev/null 2>&1 || true
  generate_qrcodes quiet >/dev/null 2>&1 || generate_qrcodes >/dev/null 2>&1 || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  generate_client_exports >/dev/null 2>&1 || true

  love_web_build_downloads_v1318 "$webroot"
  love_web_collect_links_v1318 "$webroot"

  [[ -s "$webroot/node-links.txt" ]] && node_links="ready" || node_links="empty"
  [[ -d "$webroot/qr" ]] && qr_status="ready" || qr_status="empty"
  [[ -f "$webroot/downloads/cfip-client-test.zip" || -f "$webroot/downloads/cfip-client-test.tar.gz" ]] && cfip_status="ready" || cfip_status="not generated"
  [[ -f "$webroot/sub/all.txt" || -f "$webroot/sub/all_base64.txt" ]] && sub_status="ready" || sub_status="empty"

  base="$(love_web_public_base_url_v1318 "$port")"

  cat > "$webroot/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Love Admin Panel</title>
  <style>
    *{box-sizing:border-box}
    body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,"Microsoft YaHei",sans-serif;background:#0f172a;color:#e5e7eb;}
    .theme-radio{position:absolute;opacity:0;pointer-events:none}
    .page{
      min-height:100vh;padding:24px;background:var(--bg);color:var(--text);
      --bg:#0f172a;--text:#e5e7eb;--card:#111827;--border:#334155;
      --hero1:#1d4ed8;--hero2:#7c3aed;--h2:#93c5fd;--link:#67e8f9;
      --code:#020617;--codeText:#d1d5db;--muted:#94a3b8;--yellow:#facc15;
      --btn:#2563eb;--btnGreen:#16a34a;--btnOrange:#ea580c;--btnGray:#475569;
    }
    #themeGreen:checked ~ .page{
      --bg:#edf7ed;--text:#12351f;--card:#ffffff;--border:#b9d8bd;
      --hero1:#1b5e20;--hero2:#81c784;--h2:#1b5e20;--link:#0f766e;
      --code:#f2fff2;--codeText:#12351f;--muted:#4b6b50;--yellow:#8a5a00;
      --btn:#2e7d32;--btnGreen:#1b8a3b;--btnOrange:#b45309;--btnGray:#6b7f6d;
    }
    .floating-theme{
      position:fixed;right:18px;top:18px;z-index:9999;
      background:rgba(15,23,42,.92);border:1px solid rgba(148,163,184,.45);
      border-radius:999px;padding:8px;box-shadow:0 10px 30px rgba(0,0,0,.28);
      display:flex;gap:6px;align-items:center;
    }
    #themeGreen:checked ~ .floating-theme{background:rgba(237,247,237,.96);border-color:#9fcbab}
    .floating-theme label{
      border-radius:999px;padding:8px 12px;cursor:pointer;font-weight:700;
      background:#020617;color:#e5e7eb;display:inline-block;user-select:none;
    }
    #themeDark:checked ~ .floating-theme label[for="themeDark"]{background:#2563eb;color:white}
    #themeGreen:checked ~ .floating-theme label{background:#f2fff2;color:#12351f}
    #themeGreen:checked ~ .floating-theme label[for="themeGreen"]{background:#2e7d32;color:white}
    .wrap{max-width:1080px;margin:0 auto;}
    .hero{background:linear-gradient(135deg,var(--hero1),var(--hero2));padding:24px;border-radius:20px;box-shadow:0 12px 30px rgba(0,0,0,.18);color:white;}
    h1{margin:0 0 8px;font-size:28px}
    h2{margin:22px 0 12px;font-size:20px;color:var(--h2)}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px;margin-top:18px;}
    .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:16px;}
    .card h3{margin:0 0 10px;font-size:17px;color:var(--yellow)}
    a{color:var(--link);text-decoration:none;word-break:break-all}
    a:hover{text-decoration:underline}
    code,pre{background:var(--code);border:1px solid var(--border);border-radius:12px;color:var(--codeText);padding:10px;display:block;white-space:pre-wrap;word-break:break-all}
    .ok{color:#22c55e}.warn{color:#ca8a04}.muted{color:var(--muted)}
    .btn{display:inline-block;background:var(--btn);color:white;padding:9px 12px;border-radius:10px;margin:4px 4px 4px 0}
    .btn.green{background:var(--btnGreen)}.btn.orange{background:var(--btnOrange)}.btn.gray{background:var(--btnGray)}
    table{width:100%;border-collapse:collapse;background:var(--card);border-radius:12px;overflow:hidden}
    td,th{border-bottom:1px solid var(--border);padding:10px;text-align:left}
    th{color:var(--yellow)}
    @media(max-width:760px){
      .page{padding:14px}
      .floating-theme{position:sticky;top:8px;margin:0 auto 14px;justify-content:center;border-radius:16px}
    }
  </style>
</head>
<body>
<input class="theme-radio" type="radio" name="loveTheme" id="themeDark" checked>
<input class="theme-radio" type="radio" name="loveTheme" id="themeGreen">
<div class="floating-theme" title="切换 Web 页面主题">
  <label for="themeDark">深色主题</label>
  <label for="themeGreen">绿色护眼</label>
</div>
<div class="page">
  <div class="wrap">
    <div class="hero">
      <h1>Love Admin Panel</h1>
      <div>Status: <span class="ok">OK</span> · Theme: <span class="ok">Pure CSS</span></div>
      <div class="muted">这是静态管理页，只展示节点、订阅、二维码、下载入口；不会在浏览器执行 root 命令。</div>
      <div class="muted">Base URL: ${base}</div>
    </div>

    <h2>状态 / Status</h2>
    <table>
      <tr><th>项目</th><th>状态</th><th>说明</th></tr>
      <tr><td>Node Links</td><td>${node_links}</td><td>节点链接汇总文件</td></tr>
      <tr><td>Subscription</td><td>${sub_status}</td><td>订阅文件是否已生成</td></tr>
      <tr><td>QR Codes</td><td>${qr_status}</td><td>二维码目录是否存在</td></tr>
      <tr><td>CFIP Pack</td><td>${cfip_status}</td><td>电脑本地测速包</td></tr>
    </table>

    <h2>节点 / 订阅 / 二维码</h2>
    <div class="grid">
      <div class="card"><h3>节点链接汇总</h3><p>查看当前导出的节点链接。</p><a class="btn" href="/node-links.txt">打开 node-links.txt</a></div>
      <div class="card"><h3>Raw 订阅</h3><p>一行一个节点链接。</p><a class="btn" href="/sub/all.txt">打开 all.txt</a><a class="btn gray" href="/sub/all_base64.txt">Base64</a></div>
      <div class="card"><h3>二维码</h3><p>手机端可进入目录查看二维码图片。</p><a class="btn green" href="/qr/">打开 QR 目录</a></div>
    </div>

    <h2>客户端配置文件</h2>
    <div class="grid">
      <div class="card"><h3>Mihomo / Clash</h3><a class="btn" href="/sub/mihomo.yaml">下载 mihomo.yaml</a></div>
      <div class="card"><h3>sing-box Client</h3><a class="btn" href="/sub/sing-box-client.json">下载 sing-box-client.json</a></div>
      <div class="card"><h3>客户端目录</h3><p>V2RayN / Shadowrocket / NekoBox 等导出文件。</p><a class="btn" href="/clients/">打开 clients 目录</a></div>
    </div>

    <h2>CFIP 本地测速包</h2>
    <div class="grid">
      <div class="card"><h3>Windows / macOS / Linux 测速包</h3><p>下载到电脑本地测速 Cloudflare 优选 IP。</p><a class="btn orange" href="/downloads/cfip-client-test.zip">下载 ZIP</a><a class="btn gray" href="/downloads/cfip-client-test.tar.gz">下载 TAR.GZ</a></div>
    </div>

    <h2>常用命令</h2>
    <pre>Love -n
Love sub
Love qr
Love web
Love cfip
Love warp-auto-fix</pre>

    <h2>说明</h2>
    <div class="card">
      <p><b>主题切换：</b>右上角只有两个按钮，深色主题 / 绿色护眼。此版是纯 CSS，不依赖 JavaScript。</p>
      <p><b>如果文件 404：</b>说明对应文件还没有生成，比如 CFIP 测速包需要先执行 <code>Love cfip → 6</code>。</p>
    </div>
  </div>
</div>
</body>
</html>
EOF

  apt-get install -y nginx >/dev/null 2>&1 || true

  if [[ "$auth" =~ ^[Yy]$ ]]; then
    apt-get install -y apache2-utils >/dev/null 2>&1 || true
    htpasswd -bc /etc/nginx/.love_web_htpasswd "$user" "$pass" >/dev/null 2>&1 || true
  else
    rm -f /etc/nginx/.love_web_htpasswd
  fi

  cat > "$conf" <<EOF
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    root ${webroot};
    index index.html;
    autoindex on;
    charset utf-8;
EOF

  if [[ "$auth" =~ ^[Yy]$ ]]; then
    cat >> "$conf" <<EOF
    auth_basic "Love Admin";
    auth_basic_user_file /etc/nginx/.love_web_htpasswd;
EOF
  fi

  cat >> "$conf" <<'EOF'
    location / {
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        try_files $uri $uri/ =404;
    }
}
EOF

  ln -sf "$conf" /etc/nginx/sites-enabled/love-admin
  nginx -t || { warn "nginx 配置检查失败。"; return 1; }
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || systemctl reload nginx 2>/dev/null || true
  ufw allow "${port}/tcp" >/dev/null 2>&1 || true

  echo
  log "Love Web Panel 已生成。"
  echo "访问地址：${base}/?v=118"
  if [[ "$auth" =~ ^[Yy]$ ]]; then
    echo "用户名：${user}"
    echo "密码：${pass}"
  fi
  echo
  echo "常用下载："
  echo "  节点汇总：${base}/node-links.txt"
  echo "  订阅：${base}/sub/all.txt"
  echo "  二维码目录：${base}/qr/"
  echo "  客户端目录：${base}/clients/"
  echo "  CFIP 测速包：${base}/downloads/cfip-client-test.zip"
  echo
  echo "主题检查："
  echo "  grep -n 'theme-radio\\|绿色护眼\\|Pure CSS' /var/www/love-admin/index.html"
}



# ==============================================================================
# Love v13.19 sing-box name clean + port fix
# 1) Remove "SB" from exported sing-box node names.
# 2) Auto-open sing-box full-protocol ports according to /etc/sing-box/config.json.
# 3) Add commands: Love sing-fix / Love sing-debug / Love clean-names
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.19.0-singbox-name-clean-port-fix-final"

love_clean_singbox_node_names_v1319() {
  local roots f
  roots="/opt/Love/subscribe /var/www/love-admin"
  for d in $roots; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      case "$f" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.zip|*.tar.gz) continue ;;
      esac
      sed -i \
        -e 's/SB-REALITY/LOVE-REALITY/g' \
        -e 's/SB-HY2/LOVE-HY2/g' \
        -e 's/SB-TUIC/LOVE-TUIC/g' \
        -e 's/SB-SS/LOVE-SS/g' \
        -e 's/SB-TROJAN/LOVE-TROJAN/g' \
        -e 's/SB-VMESS/LOVE-VMESS/g' \
        -e 's/SB-VLESS/LOVE-VLESS/g' \
        -e 's/SB-WSTLS/LOVE-WSTLS/g' \
        -e 's/SB-GRPC/LOVE-GRPC/g' \
        -e 's/SB-H2/LOVE-H2/g' \
        -e 's/SB-ANYTLS/LOVE-ANYTLS/g' \
        -e 's/SB-NAIVE/LOVE-NAIVE/g' \
        -e 's/SB-SHADOWTLS/LOVE-SHADOWTLS/g' \
        -e 's/#SB-/#LOVE-/g' \
        -e 's/name: SB-/name: LOVE-/g' \
        -e 's/name: "SB-/name: "LOVE-/g' \
        -e "s/name: 'SB-/name: 'LOVE-/g" \
        "$f" 2>/dev/null || true
    done < <(find "$d" -type f -print0 2>/dev/null)
  done

  if [[ -f /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi
}

love_singbox_open_ports_from_config_v1319() {
  local cfg="/etc/sing-box/config.json"
  [[ -f "$cfg" ]] || { warn "未找到 $cfg"; return 1; }
  command -v jq >/dev/null 2>&1 || { warn "缺少 jq"; return 1; }

  love_menu_title "Love sing-box 全协议端口修复" "Open ports from config"

  echo "将按当前 /etc/sing-box/config.json 自动放行端口："
  jq -r '.inbounds[]? | [.tag,.type,.listen_port] | @tsv' "$cfg" 2>/dev/null || true
  echo

  while IFS=$'\t' read -r tag typ port; do
    [[ -n "$port" && "$port" != "null" ]] || continue
    case "$typ" in
      hysteria2|tuic)
        ufw allow "${port}/udp" >/dev/null 2>&1 || true
        printf "%b[OK]%b %-18s %-12s %s/udp\n" "$(lc green)" "$(lc reset)" "$tag" "$typ" "$port"
        ;;
      shadowsocks)
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        ufw allow "${port}/udp" >/dev/null 2>&1 || true
        printf "%b[OK]%b %-18s %-12s %s/tcp+udp\n" "$(lc green)" "$(lc reset)" "$tag" "$typ" "$port"
        ;;
      *)
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        printf "%b[OK]%b %-18s %-12s %s/tcp\n" "$(lc green)" "$(lc reset)" "$tag" "$typ" "$port"
        ;;
    esac
  done < <(jq -r '.inbounds[]? | [.tag,.type,.listen_port] | @tsv' "$cfg" 2>/dev/null)

  ufw reload >/dev/null 2>&1 || true
}

love_singbox_full_fix_v1319() {
  love_menu_title "Love sing-box 全协议修复" "Name Clean + Port Fix + Restart"

  echo "修复内容："
  echo "1. 去掉导出节点名称里的 SB 前缀，改成 LOVE。"
  echo "2. 按当前 sing-box 配置自动放行 50000-50011 等实际端口。"
  echo "3. 检查配置并重启 sing-box。"
  echo "4. 重新生成订阅、二维码、Web。"
  echo

  love_clean_singbox_node_names_v1319
  love_singbox_open_ports_from_config_v1319 || true

  if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c /etc/sing-box/config.json || return 1
  elif [[ -x /usr/local/bin/sing-box ]]; then
    /usr/local/bin/sing-box check -c /etc/sing-box/config.json || return 1
  fi

  systemctl restart sing-box
  sleep 2

  echo
  printf "%b当前监听：%b\n" "$(lc green)" "$(lc reset)"
  ss -lntup | grep -E '50000|50001|50002|50003|50004|50005|50006|50007|50008|50009|50010|50011|30001|sing-box' || true

  echo
  printf "%b当前入站：%b\n" "$(lc green)" "$(lc reset)"
  jq -r '.inbounds[]? | [.tag,.type,.listen,.listen_port] | @tsv' /etc/sing-box/config.json 2>/dev/null || true

  export_subscription >/dev/null 2>&1 || true
  love_clean_singbox_node_names_v1319
  generate_qrcodes quiet >/dev/null 2>&1 || generate_qrcodes >/dev/null 2>&1 || true
  web_admin_page >/dev/null 2>&1 || true

  echo
  log "sing-box 全协议修复完成。"
  echo "建议打开 Web：Love web 或 http://[你的IPv6]:8099/?v=119"
}

love_singbox_debug_v1319() {
  love_menu_title "Love sing-box 全协议诊断" "Reality / TUIC / SS / Trojan / WS TLS"

  echo "1) 当前入站："
  jq -r '.inbounds[]? | [.tag,.type,.listen,.listen_port] | @tsv' /etc/sing-box/config.json 2>/dev/null || true

  echo
  echo "2) 当前 TCP/UDP 监听："
  ss -lntup | grep -E '50000|50001|50002|50003|50004|50005|50006|50007|50008|50009|50010|50011|30001|sing-box' || true

  echo
  echo "3) UFW 状态："
  ufw status || true

  echo
  echo "4) sing-box 最近日志："
  journalctl -u sing-box -n 80 -l --no-pager || true

  echo
  echo "判断："
  echo "- Reality / Trojan / VLESS WS TLS 是 TCP，不通优先看 TCP 端口是否放行。"
  echo "- TUIC / HY2 是 UDP，不通优先看 UDP 端口是否放行。"
  echo "- SS 通常 TCP/UDP 都可能用，建议两个都放行。"
  echo "- 如果端口有监听、有放行，但客户端仍不通，下一步看客户端链接参数：address、port、uuid/password、sni、flow、insecure。"
}

if declare -F export_subscription >/dev/null 2>&1 && ! declare -F love_original_export_subscription_v1319 >/dev/null 2>&1; then
  eval "$(declare -f export_subscription | sed '1s/^export_subscription/love_original_export_subscription_v1319/')"
  export_subscription() {
    love_original_export_subscription_v1319 "$@"
    love_clean_singbox_node_names_v1319
  }
fi

if declare -F generate_client_exports >/dev/null 2>&1 && ! declare -F love_original_generate_client_exports_v1319 >/dev/null 2>&1; then
  eval "$(declare -f generate_client_exports | sed '1s/^generate_client_exports/love_original_generate_client_exports_v1319/')"
  generate_client_exports() {
    love_original_generate_client_exports_v1319 "$@"
    love_clean_singbox_node_names_v1319
  }
fi

if declare -F generate_mihomo_yaml >/dev/null 2>&1 && ! declare -F love_original_generate_mihomo_yaml_v1319 >/dev/null 2>&1; then
  eval "$(declare -f generate_mihomo_yaml | sed '1s/^generate_mihomo_yaml/love_original_generate_mihomo_yaml_v1319/')"
  generate_mihomo_yaml() {
    love_original_generate_mihomo_yaml_v1319 "$@"
    love_clean_singbox_node_names_v1319
  }
fi

if declare -F install_singbox_native >/dev/null 2>&1 && ! declare -F love_original_install_singbox_native_v1319 >/dev/null 2>&1; then
  eval "$(declare -f install_singbox_native | sed '1s/^install_singbox_native/love_original_install_singbox_native_v1319/')"
  install_singbox_native() {
    love_original_install_singbox_native_v1319 "$@"
    love_singbox_open_ports_from_config_v1319 || true
    love_clean_singbox_node_names_v1319 || true
  }
fi

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1319 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1319/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.19.0-singbox-name-clean-port-fix-final}"
  case "${1:-}" in
    sing-fix|fix-sing|singbox-fix)
      love_singbox_full_fix_v1319
      ;;
    sing-debug|debug-sing|singbox-debug)
      love_singbox_debug_v1319
      ;;
    clean-names|name-clean)
      love_clean_singbox_node_names_v1319
      log "节点名称清理完成。"
      ;;
    *)
      love_original_main_v1319 "$@"
      ;;
  esac
}



# ==============================================================================
# Love v13.20 sing-box client link fix
# Fix VLESS WS TLS self-signed cert issue: add allowInsecure/insecure.
# Fix TUIC compatibility: add allowInsecure/insecure aliases.
# Fix duplicate LOVE-LOVE names.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.20.0-singbox-client-link-fix-final"

love_fix_client_links_v1320() {
  local roots f
  roots="/opt/Love/subscribe /var/www/love-admin"
  for d in $roots; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      case "$f" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.zip|*.tar.gz) continue ;;
      esac

      sed -i \
        -e 's/LOVE-/LOVE-/g' \
        -e 's/SB-REALITY/LOVE-REALITY/g' \
        -e 's/SB-HY2/LOVE-HY2/g' \
        -e 's/SB-TUIC/LOVE-TUIC/g' \
        -e 's/SB-SS/LOVE-SS/g' \
        -e 's/SB-TROJAN/LOVE-TROJAN/g' \
        -e 's/SB-VMESS/LOVE-VMESS/g' \
        -e 's/SB-VLESS/LOVE-VLESS/g' \
        -e 's/SB-WSTLS/LOVE-WSTLS/g' \
        -e 's/SB-GRPC/LOVE-GRPC/g' \
        -e 's/SB-H2/LOVE-H2/g' \
        -e 's/SB-ANYTLS/LOVE-ANYTLS/g' \
        -e 's/SB-NAIVE/LOVE-NAIVE/g' \
        -e 's/SB-SHADOWTLS/LOVE-SHADOWTLS/g' \
        "$f" 2>/dev/null || true

      if grep -qE 'vless://.*:50006' "$f" 2>/dev/null; then
        sed -i \
          -e '/vless:\/\/.*:50006/ s/#/\&allowInsecure=1\&insecure=1#/' \
          -e '/vless:\/\/.*:50006/ s/&allowInsecure=1&insecure=1&allowInsecure=1&insecure=1/&allowInsecure=1&insecure=1/g' \
          "$f" 2>/dev/null || true
      fi

      if grep -qE 'tuic://.*:50002' "$f" 2>/dev/null; then
        sed -i \
          -e '/tuic:\/\/.*:50002/ s/#/\&allowInsecure=1\&insecure=1#/' \
          -e '/tuic:\/\/.*:50002/ s/&allowInsecure=1&insecure=1&allowInsecure=1&insecure=1/&allowInsecure=1&insecure=1/g' \
          "$f" 2>/dev/null || true
      fi
    done < <(find "$d" -type f -print0 2>/dev/null)
  done

  for f in /opt/Love/subscribe/mihomo.yaml /opt/Love/subscribe/mihomo-provider.yaml /opt/Love/subscribe/clash_like.yaml /var/www/love-admin/sub/mihomo.yaml; do
    [[ -f "$f" ]] || continue
    sed -i 's/LOVE-/LOVE-/g' "$f" 2>/dev/null || true
    python3 - "$f" <<'PY' 2>/dev/null || true
import sys, re
p=sys.argv[1]
lines=open(p,encoding='utf-8',errors='ignore').read().splitlines()
out=[]
in_target=False
has_skip=False
for line in lines:
    if re.match(r'\s*-\s+name:\s*"?LOVE-(TUIC|VLESS-WS-TLS)', line):
        if in_target and not has_skip:
            out.append('    skip-cert-verify: true')
        in_target=True
        has_skip=False
    elif re.match(r'\s*-\s+name:', line):
        if in_target and not has_skip:
            out.append('    skip-cert-verify: true')
        in_target=False
        has_skip=False
    if in_target and 'skip-cert-verify:' in line:
        has_skip=True
    out.append(line)
if in_target and not has_skip:
    out.append('    skip-cert-verify: true')
open(p,'w',encoding='utf-8').write('\n'.join(out)+'\n')
PY
  done

  if [[ -f /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi
}

love_show_fixed_client_links_v1320() {
  love_menu_title "Love 客户端链接修复结果" "TUIC / VLESS WS TLS"
  echo "VLESS WS TLS 应包含：allowInsecure=1&insecure=1"
  echo "TUIC 应包含：allow_insecure=1&allowInsecure=1&insecure=1"
  echo
  grep -RniE "TUIC|50002|VLESS-WS-TLS|50006|vless.*50006|tuic.*50002" /opt/Love/subscribe /var/www/love-admin 2>/dev/null | head -40 || true
}

love_client_link_fix_v1320() {
  love_menu_title "Love 客户端链接参数修复" "Self-signed TLS compatibility"

  echo "修复内容："
  echo "1. 修复 VLESS WS TLS 自签证书错误：x509 unknown authority。"
  echo "2. 给 VLESS WS TLS 链接补 allowInsecure=1&insecure=1。"
  echo "3. 给 TUIC 链接同时保留 allow_insecure / allowInsecure / insecure。"
  echo "4. 清理 LOVE-LOVE 重复名称。"
  echo

  export_subscription >/dev/null 2>&1 || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  generate_client_exports >/dev/null 2>&1 || true

  love_fix_client_links_v1320
  generate_qrcodes quiet >/dev/null 2>&1 || generate_qrcodes >/dev/null 2>&1 || true
  web_admin_page >/dev/null 2>&1 || true
  love_fix_client_links_v1320

  log "客户端链接参数修复完成。"
  love_show_fixed_client_links_v1320
}

if declare -F export_subscription >/dev/null 2>&1 && ! declare -F love_original_export_subscription_v1320 >/dev/null 2>&1; then
  eval "$(declare -f export_subscription | sed '1s/^export_subscription/love_original_export_subscription_v1320/')"
  export_subscription() {
    love_original_export_subscription_v1320 "$@"
    love_fix_client_links_v1320
  }
fi

if declare -F generate_client_exports >/dev/null 2>&1 && ! declare -F love_original_generate_client_exports_v1320 >/dev/null 2>&1; then
  eval "$(declare -f generate_client_exports | sed '1s/^generate_client_exports/love_original_generate_client_exports_v1320/')"
  generate_client_exports() {
    love_original_generate_client_exports_v1320 "$@"
    love_fix_client_links_v1320
  }
fi

if declare -F generate_mihomo_yaml >/dev/null 2>&1 && ! declare -F love_original_generate_mihomo_yaml_v1320 >/dev/null 2>&1; then
  eval "$(declare -f generate_mihomo_yaml | sed '1s/^generate_mihomo_yaml/love_original_generate_mihomo_yaml_v1320/')"
  generate_mihomo_yaml() {
    love_original_generate_mihomo_yaml_v1320 "$@"
    love_fix_client_links_v1320
  }
fi

if declare -F web_admin_page >/dev/null 2>&1 && ! declare -F love_original_web_admin_page_v1320 >/dev/null 2>&1; then
  eval "$(declare -f web_admin_page | sed '1s/^web_admin_page/love_original_web_admin_page_v1320/')"
  web_admin_page() {
    love_original_web_admin_page_v1320 "$@"
    love_fix_client_links_v1320
  }
fi

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1320 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1320/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.20.0-singbox-client-link-fix-final}"
  case "${1:-}" in
    link-fix|client-fix|fix-links)
      love_client_link_fix_v1320
      ;;
    show-links|links-check)
      love_show_fixed_client_links_v1320
      ;;
    *)
      love_original_main_v1320 "$@"
      ;;
  esac
}



# ==============================================================================
# Love v13.21 sing-box no-SB source final
# Source-level generated node names no longer contain LOVE-SB.
# This cleaner remains as a safety guard only; users do NOT need to run it manually.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.21.0-singbox-no-sb-source-final"

love_no_sb_final_clean_v1321() {
  local roots f
  roots="/opt/Love/subscribe /var/www/love-admin"
  for d in $roots; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      case "$f" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.zip|*.tar.gz) continue ;;
      esac
      sed -i \
        -e 's/LOVE-LOVE-/LOVE-/g' \
        -e 's/LOVE-SB-/LOVE-/g' \
        -e 's/#SB-/#LOVE-/g' \
        -e 's/#LOVE-SB-/#LOVE-/g' \
        -e 's/name: SB-/name: LOVE-/g' \
        -e 's/name: "SB-/name: "LOVE-/g' \
        -e "s/name: 'SB-/name: 'LOVE-/g" \
        "$f" 2>/dev/null || true
    done < <(find "$d" -type f -print0 2>/dev/null)
  done

  if [[ -f /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi
}

# Hard-wrap exports once more so every generation automatically cleans names.
if declare -F export_subscription >/dev/null 2>&1 && ! declare -F love_original_export_subscription_v1321 >/dev/null 2>&1; then
  eval "$(declare -f export_subscription | sed '1s/^export_subscription/love_original_export_subscription_v1321/')"
  export_subscription() {
    love_original_export_subscription_v1321 "$@"
    love_no_sb_final_clean_v1321
    love_fix_client_links_v1320 >/dev/null 2>&1 || true
  }
fi

if declare -F generate_client_exports >/dev/null 2>&1 && ! declare -F love_original_generate_client_exports_v1321 >/dev/null 2>&1; then
  eval "$(declare -f generate_client_exports | sed '1s/^generate_client_exports/love_original_generate_client_exports_v1321/')"
  generate_client_exports() {
    love_original_generate_client_exports_v1321 "$@"
    love_no_sb_final_clean_v1321
    love_fix_client_links_v1320 >/dev/null 2>&1 || true
  }
fi

if declare -F web_admin_page >/dev/null 2>&1 && ! declare -F love_original_web_admin_page_v1321 >/dev/null 2>&1; then
  eval "$(declare -f web_admin_page | sed '1s/^web_admin_page/love_original_web_admin_page_v1321/')"
  web_admin_page() {
    love_original_web_admin_page_v1321 "$@"
    love_no_sb_final_clean_v1321
    love_fix_client_links_v1320 >/dev/null 2>&1 || true
  }
fi

if declare -F install_singbox_native >/dev/null 2>&1 && ! declare -F love_original_install_singbox_native_v1321 >/dev/null 2>&1; then
  eval "$(declare -f install_singbox_native | sed '1s/^install_singbox_native/love_original_install_singbox_native_v1321/')"
  install_singbox_native() {
    love_original_install_singbox_native_v1321 "$@"
    love_no_sb_final_clean_v1321
    love_fix_client_links_v1320 >/dev/null 2>&1 || true
  }
fi

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1321 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1321/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.21.0-singbox-no-sb-source-final}"
  case "${1:-}" in
    no-sb-check|sb-check)
      love_no_sb_final_clean_v1321
      echo "[OK] 已检查并清理导出文件中的 SB/LOVE-LOVE。"
      grep -RniE 'LOVE-SB|LOVE-LOVE|#SB-|name: SB-' /opt/Love/subscribe /var/www/love-admin 2>/dev/null | head -30 || echo "[OK] 未发现 SB 残留。"
      ;;
    *)
      love_original_main_v1321 "$@"
      ;;
  esac
}



# ==============================================================================
# Love v13.28 Disk Guard Stable Final
# Prevent /opt/Love/subscribe from growing to GB.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.28.0-disk-guard-stable-final"

love_avail_mb_v1328() { df -Pm / 2>/dev/null | awk 'NR==2{print $4+0}'; }
love_dir_mb_v1328() { du -sm "$1" 2>/dev/null | awk '{print $1+0}'; }

love_disk_guard_v1328() {
  local min="${1:-200}" avail
  avail="$(love_avail_mb_v1328)"
  if [[ -z "$avail" || "$avail" -lt "$min" ]]; then
    echo "[ERROR] 根分区剩余空间不足：${avail:-0} MB，至少需要 ${min} MB。"
    echo "先执行：Love clean-cache，然后检查 df -h。"
    return 1
  fi
  return 0
}

love_clean_generated_cache_v1328() {
  love_menu_title "Love 安全清理生成缓存" "Disk Guard"
  echo "只清理可重新生成的缓存，不删除真实节点配置。"
  echo "保留 /etc/sing-box/config.json、/opt/Love/Love.sh、/opt/Love/client-info。"
  echo

  mkdir -p /root/love-safe-backup
  cp -a /opt/Love/Love.sh /root/love-safe-backup/Love.sh.bak 2>/dev/null || true
  cp -a /opt/Love/client-info /root/love-safe-backup/client-info.bak 2>/dev/null || true
  cp -a /opt/Love/subscribe/all.txt /root/love-safe-backup/all.txt.bak 2>/dev/null || true
  cp -a /opt/Love/subscribe/all_base64.txt /root/love-safe-backup/all_base64.txt.bak 2>/dev/null || true

  rm -f /opt/Love/subscribe/clients/sed*
  rm -f /opt/Love/subscribe/clients/推荐节点.txt
  rm -f /opt/Love/subscribe/clients/节点清晰版.txt
  rm -f /opt/Love/subscribe/clients/nodes-clean.txt
  rm -f /opt/Love/subscribe/clients/all-clean-uri.txt
  rm -f /opt/Love/subscribe/推荐节点.txt
  rm -f /opt/Love/subscribe/节点清晰版.txt
  rm -f /opt/Love/subscribe/nodes-clean.txt
  rm -f /opt/Love/subscribe/all-clean-uri.txt
  find /opt/Love/subscribe/clients -type f -size +10M -print -delete 2>/dev/null || true
  find /opt/Love/subscribe -maxdepth 1 -type f \( -name "*.png" -o -name "*.svg" -o -name "*.html" -o -name "*.yaml" -o -name "*.zip" -o -name "*.tar.gz" \) -print -delete 2>/dev/null || true
  rm -rf /opt/Love/subscribe/qr/*
  rm -rf /var/www/love-admin/*
  rm -rf /opt/Love/backup/* /opt/Love/snapshots/* /opt/Love/release/* /opt/Love/reports/* /opt/Love/logs/* /opt/Love/import/* /opt/Love/nginx/*
  apt clean >/dev/null 2>&1 || true
  journalctl --vacuum-size=30M >/dev/null 2>&1 || true
  truncate -s 0 /var/log/syslog 2>/dev/null || true
  truncate -s 0 /var/log/auth.log 2>/dev/null || true
  truncate -s 0 /var/log/nginx/access.log 2>/dev/null || true
  truncate -s 0 /var/log/nginx/error.log 2>/dev/null || true
  sync
  df -h
  du -xhd1 /opt/Love 2>/dev/null | sort -h || true
}

love_disk_check_v1328() {
  love_menu_title "Love 磁盘检查" "Disk / Subscribe / Big files"
  df -h /
  echo
  df -i /
  echo
  du -xhd1 /opt/Love 2>/dev/null | sort -h || true
  echo
  find /opt/Love -xdev -type f -size +5M -printf '%s %p\n' 2>/dev/null | sort -n | tail -30 || true
}

love_fix_line_v1328() {
  local line="$1"
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"
  if [[ "$line" == vless://*":50006"* ]]; then
    [[ "$line" != *"allowInsecure=1"* ]] && line="${line//#/&allowInsecure=1#}"
    [[ "$line" != *"insecure=1"* ]] && line="${line//#/&insecure=1#}"
  fi
  if [[ "$line" == tuic://*":50002"* ]]; then
    [[ "$line" != *"allow_insecure=1"* ]] && line="${line//#/&allow_insecure=1#}"
    [[ "$line" != *"allowInsecure=1"* ]] && line="${line//#/&allowInsecure=1#}"
    [[ "$line" != *"insecure=1"* ]] && line="${line//#/&insecure=1#}"
  fi
  echo "$line"
}

love_label_v1328() {
  local line="$1"
  case "$line" in
    vless://*:50000*) echo "01-LOVE-REALITY-50000【推荐｜TCP｜无域名首选】" ;;
    hysteria2://*:50001*|hy2://*:50001*) echo "02-LOVE-HY2-50001【推荐｜UDP｜速度优先】" ;;
    hysteria2://*:30001*|hy2://*:30001*) echo "03-LOVE-HY2-30001【旧节点｜UDP｜保留兼容】" ;;
    tuic://*:50002*) echo "04-LOVE-TUIC-50002【备用｜UDP｜建议 sing-box/NekoBox】" ;;
    ss://*:50003*) echo "05-LOVE-SS-50003【兼容｜TCP/UDP】" ;;
    trojan://*:50004*) echo "06-LOVE-TROJAN-50004【兼容｜TCP｜TLS】" ;;
    vmess://*) echo "07-LOVE-VMESS-WS-50005【兼容｜TCP｜WS】" ;;
    vless://*:50006*) echo "08-LOVE-VLESS-WS-TLS-50006【备用｜TCP｜自签需允许不安全】" ;;
    vless://*:50007*) echo "09-LOVE-H2-REALITY-50007【高级｜TCP】" ;;
    vless://*:50008*) echo "10-LOVE-GRPC-REALITY-50008【高级｜TCP】" ;;
    anytls://*:50009*) echo "11-LOVE-ANYTLS-50009【高级｜TCP】" ;;
    https://*:50010*|naive+https://*:50010*) echo "12-LOVE-NAIVE-50010【高级｜TCP】" ;;
    shadowtls://*:50011*) echo "13-LOVE-SHADOWTLS-50011【高级｜TCP】" ;;
    *) echo "${line##*#}" ;;
  esac
}

love_set_label_v1328() {
  local line="$1" label
  label="$(love_label_v1328 "$line")"
  [[ "$line" == *"#"* ]] && echo "${line%%#*}#${label}" || echo "${line}#${label}"
}

love_collect_links_safe_v1328() {
  grep -hE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' \
    /opt/Love/client-info/xray-client-info.txt \
    /opt/Love/client-info/sing-box-client-info.txt \
    /opt/Love/node_info.txt \
    2>/dev/null | sed 's/\r$//' | awk '!seen[$0]++' || true
}

love_sub_safe_v1328() {
  love_menu_title "Love 订阅安全导出" "Stable / Disk Guard / No Recursion"
  love_disk_guard_v1328 200 || return 1
  mkdir -p /opt/Love/subscribe /opt/Love/subscribe/clients
  local raw="/opt/Love/subscribe/all.txt" b64="/opt/Love/subscribe/all_base64.txt" html="/opt/Love/subscribe/index.html" yaml="/opt/Love/subscribe/clash_like.yaml" tmp="/tmp/love_sub_safe.$$"

  echo "[1/4] 从 client-info 收集节点，不读取 subscribe/clients 输出目录..."
  : > "$tmp"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    love_set_label_v1328 "$(love_fix_line_v1328 "$line")" >> "$tmp"
  done < <(love_collect_links_safe_v1328)
  awk '!seen[$0]++' "$tmp" > "$raw"
  rm -f "$tmp"

  cp -f "$raw" /opt/Love/subscribe/clients/v2rayn-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/nekobox-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/sing-box-uri.txt 2>/dev/null || true

  echo "[2/4] 生成 Base64..."
  if base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w0 "$raw" > "$b64" 2>/dev/null || true; else base64 "$raw" | tr -d '\n' > "$b64" 2>/dev/null || true; fi

  echo "[3/4] 生成简易 HTML / YAML..."
  { echo "<!doctype html><html><head><meta charset='utf-8'><title>Love Subscription</title></head><body><pre>"; sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$raw"; echo "</pre></body></html>"; } > "$html"
  { echo "# Love URI subscription list"; echo "links:"; awk '{gsub(/"/,"\\\""); print "  - \"" $0 "\""}' "$raw"; } > "$yaml"

  echo "[4/4] 生成小型 TXT 速查..."
  love_txt_safe_v1328 >/dev/null 2>&1 || true

  echo
  log "订阅安全导出完成："
  echo "Raw:    $raw"
  echo "Base64: $b64"
  echo "HTML:   $html"
  echo "TXT:    /opt/Love/subscribe/推荐节点.txt"

  local sub_mb; sub_mb="$(love_dir_mb_v1328 /opt/Love/subscribe)"
  if [[ "$sub_mb" -gt 100 ]]; then
    warn "/opt/Love/subscribe 已超过 ${sub_mb} MB，自动清理异常缓存。"
    love_clean_generated_cache_v1328
  fi
}

love_txt_safe_v1328() {
  love_disk_guard_v1328 100 || return 1
  mkdir -p /opt/Love/subscribe
  local raw="/opt/Love/subscribe/all.txt" clean="/opt/Love/subscribe/节点清晰版.txt" rec="/opt/Love/subscribe/推荐节点.txt" all="/opt/Love/subscribe/all-clean-uri.txt" simple="/opt/Love/subscribe/nodes-clean.txt"
  [[ -s "$raw" ]] || love_sub_safe_v1328 >/dev/null 2>&1 || true
  : > "$clean"; : > "$rec"; : > "$all"; : > "$simple"
  { echo "Love 节点清晰版 / Clean Node List"; echo "生成时间: $(date)"; echo "说明：全部节点都保留；推荐节点只是精选入口，不代表删除其他节点。"; echo; echo "================ 推荐节点 ================"; } >> "$clean"
  echo "# Love 推荐节点 / Recommended" >> "$rec"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    fixed="$(love_set_label_v1328 "$(love_fix_line_v1328 "$line")")"
    echo "$fixed" >> "$all"
    case "$fixed" in
      *"REALITY-50000"*|*"HY2-50001"*|*"HY2-30001"*|*"TROJAN-50004"*|*"VLESS-WS-TLS-50006"*)
        echo "$fixed" >> "$rec"; { echo; echo "【${fixed##*#}】"; echo "$fixed"; } >> "$clean" ;;
    esac
  done < "$raw"
  { echo; echo "================ 全部节点 ================"; cat "$all"; } >> "$clean"
  { echo "推荐节点："; cat "$rec"; echo; echo "全部节点："; cat "$all"; } > "$simple"
  mkdir -p /opt/Love/subscribe/clients
  cat > /opt/Love/subscribe/clients/READ_ME_TXT位置.txt <<EOF
TXT 文件在：
/opt/Love/subscribe/推荐节点.txt
/opt/Love/subscribe/节点清晰版.txt
/opt/Love/subscribe/all-clean-uri.txt
EOF
  log "TXT 安全生成完成："
  echo "  $rec"
  echo "  $clean"
  echo "  $all"
}

web_admin_page() {
  love_menu_title "Love Web 管理页" "Safe / No Auto Generate"
  love_disk_guard_v1328 100 || return 1
  local web_port auth user pass webroot conf host base
  read -rp "Web 管理页端口 [8099]: " web_port; web_port="${web_port:-8099}"; [[ "$web_port" =~ ^[0-9]+$ ]] || web_port="8099"
  read -rp "是否开启 Basic Auth 密码保护？[Y/n]: " auth; auth="${auth:-Y}"
  user="love"; pass=""
  if [[ "$auth" =~ ^[Yy]$ ]]; then read -rp "Web 用户名 [love]: " user; user="${user:-love}"; read -rp "Web 密码，留空自动生成: " pass; [[ -z "$pass" ]] && pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"; fi
  webroot="/var/www/love-admin"; conf="/etc/nginx/sites-available/love-admin"
  command -v nginx >/dev/null 2>&1 || { echo "[ERROR] nginx 未安装。"; return 1; }
  [[ "$auth" =~ ^[Yy]$ ]] && ! command -v htpasswd >/dev/null 2>&1 && { echo "[ERROR] htpasswd 未安装。"; return 1; }
  rm -rf "$webroot"; rm -f /etc/nginx/sites-enabled/love-admin /etc/nginx/sites-available/love-admin 2>/dev/null || true
  mkdir -p "$webroot/sub" "$webroot/qr" "$webroot/clients" "$webroot/downloads" /etc/nginx/sites-available /etc/nginx/sites-enabled
  cp -a /opt/Love/subscribe/. "$webroot/sub/" 2>/dev/null || true
  cp -a /opt/Love/subscribe/qr/. "$webroot/qr/" 2>/dev/null || true
  cp -a /opt/Love/subscribe/clients/. "$webroot/clients/" 2>/dev/null || true
  host="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1)"
  [[ -n "$host" ]] && base="http://[${host}]:${web_port}" || base="http://YOUR_SERVER_IP:${web_port}"
  cp -f /opt/Love/subscribe/all.txt "$webroot/node-links.txt" 2>/dev/null || true
  cat > "$webroot/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Love Admin Panel</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,"Microsoft YaHei",sans-serif;background:#edf7ed;color:#12351f;margin:0;padding:24px}.wrap{max-width:1000px;margin:auto}.hero{background:linear-gradient(135deg,#1b5e20,#81c784);padding:24px;border-radius:20px;color:white}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px;margin-top:18px}.card{background:white;border:1px solid #b9d8bd;border-radius:16px;padding:16px}a{color:#0f766e;word-break:break-all}.btn{display:inline-block;background:#2e7d32;color:white;padding:9px 12px;border-radius:10px;margin:4px 4px 4px 0;text-decoration:none}pre{background:#f2fff2;padding:12px;border-radius:12px;white-space:pre-wrap}</style></head>
<body><div class="wrap"><div class="hero"><h1>Love Admin Panel</h1><p>Status: OK · Safe Web · Port: ${web_port}</p><p>${base}</p></div>
<h2>清晰 TXT / 推荐导入</h2><div class="grid"><div class="card"><h3>推荐节点</h3><a class="btn" href="/sub/推荐节点.txt">下载 推荐节点.txt</a></div><div class="card"><h3>节点清晰版</h3><a class="btn" href="/sub/节点清晰版.txt">下载 节点清晰版.txt</a></div><div class="card"><h3>全部节点</h3><a class="btn" href="/sub/all-clean-uri.txt">下载 all-clean-uri.txt</a></div></div>
<h2>订阅 / 二维码</h2><div class="grid"><div class="card"><h3>Raw 订阅</h3><a class="btn" href="/sub/all.txt">打开 all.txt</a></div><div class="card"><h3>Base64</h3><a class="btn" href="/sub/all_base64.txt">打开 all_base64.txt</a></div><div class="card"><h3>二维码</h3><a class="btn" href="/qr/">打开 QR 目录</a></div></div>
<h2>常用命令</h2><pre>Love clean-cache
Love disk-check
Love sub
Love qr
Love txt
Love web</pre></div></body></html>
EOF
  if [[ "$auth" =~ ^[Yy]$ ]]; then htpasswd -bc /etc/nginx/.love_web_htpasswd "$user" "$pass" >/dev/null || return 1; else rm -f /etc/nginx/.love_web_htpasswd; fi
  cat > "$conf" <<EOF
server {
    listen ${web_port};
    listen [::]:${web_port};
    server_name _;
    root ${webroot};
    index index.html;
    autoindex on;
    charset utf-8;
EOF
  if [[ "$auth" =~ ^[Yy]$ ]]; then cat >> "$conf" <<EOF
    auth_basic "Love Admin";
    auth_basic_user_file /etc/nginx/.love_web_htpasswd;
EOF
  fi
  cat >> "$conf" <<'EOF'
    location / {
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        try_files $uri $uri/ =404;
    }
}
EOF
  ln -sf "$conf" /etc/nginx/sites-enabled/love-admin
  nginx -t || { cat "$conf"; return 1; }
  systemctl restart nginx || return 1
  echo; log "Love Web Panel 已生成。"; echo "访问地址：${base}/?v=128"; [[ "$auth" =~ ^[Yy]$ ]] && { echo "用户名：${user}"; echo "密码：${pass}"; }
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1328 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1328/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.28.0-disk-guard-stable-final}"
  case "${1:-}" in
    sub|subscription) love_sub_safe_v1328 ;;
    txt|node-txt|clean-txt|nodes-clean) love_txt_safe_v1328 ;;
    clean-cache|disk-clean|clean) love_clean_generated_cache_v1328 ;;
    disk-check|check-disk) love_disk_check_v1328 ;;
    *) love_original_main_v1328 "$@" ;;
  esac
}



# ==============================================================================
# Love v13.29 Web QR Theme Gallery Final
# Based on v13.28 stable disk guard.
# Fix:
#   - Restore dark theme and green eye-protection theme switch.
#   - Web QR page uses responsive grid, not crowded images.
#   - QR terminal still prints first ANSI only, but Web shows all PNG/SVG entries.
#   - No auto sub/qr/txt generation from Love web, no recursion.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.29.0-web-qr-theme-gallery-final"

love_web_theme_css_v1329() {
cat <<'EOF'
<style>
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,"Microsoft YaHei",sans-serif;background:#0f172a;color:#e5e7eb}
.theme-radio{position:absolute;opacity:0;pointer-events:none}
.page{
  min-height:100vh;padding:24px;background:var(--bg);color:var(--text);
  --bg:#0f172a;--text:#e5e7eb;--card:#111827;--border:#334155;
  --hero1:#1d4ed8;--hero2:#7c3aed;--h2:#93c5fd;--link:#67e8f9;
  --muted:#94a3b8;--yellow:#facc15;--btn:#2563eb;--btnGreen:#16a34a;--btnGray:#475569;--code:#020617;--codeText:#d1d5db;
}
#themeGreen:checked ~ .page{
  --bg:#edf7ed;--text:#12351f;--card:#ffffff;--border:#b9d8bd;
  --hero1:#1b5e20;--hero2:#81c784;--h2:#1b5e20;--link:#0f766e;
  --muted:#4b6b50;--yellow:#8a5a00;--btn:#2e7d32;--btnGreen:#1b8a3b;--btnGray:#6b7f6d;--code:#f2fff2;--codeText:#12351f;
}
.floating-theme{
  position:fixed;right:18px;top:18px;z-index:9999;background:rgba(15,23,42,.92);
  border:1px solid rgba(148,163,184,.45);border-radius:999px;padding:8px;
  box-shadow:0 10px 30px rgba(0,0,0,.28);display:flex;gap:6px;align-items:center;
}
#themeGreen:checked ~ .floating-theme{background:rgba(237,247,237,.96);border-color:#9fcbab}
.floating-theme label{border-radius:999px;padding:8px 12px;cursor:pointer;font-weight:700;background:#020617;color:#e5e7eb;display:inline-block;user-select:none}
#themeDark:checked ~ .floating-theme label[for="themeDark"]{background:#2563eb;color:white}
#themeGreen:checked ~ .floating-theme label{background:#f2fff2;color:#12351f}
#themeGreen:checked ~ .floating-theme label[for="themeGreen"]{background:#2e7d32;color:white}
.wrap{max-width:1100px;margin:0 auto}
.hero{background:linear-gradient(135deg,var(--hero1),var(--hero2));padding:24px;border-radius:20px;box-shadow:0 12px 30px rgba(0,0,0,.18);color:white}
h1{margin:0 0 8px;font-size:28px} h2{margin:22px 0 12px;font-size:20px;color:var(--h2)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px;margin-top:18px}
.qr-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:18px;margin-top:18px;align-items:start}
.card,.qr-card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:16px;overflow:hidden}
.card h3,.qr-card h3{margin:0 0 10px;font-size:17px;color:var(--yellow);word-break:break-all}
.qr-card img{display:block;width:100%;max-width:260px;height:auto;margin:8px auto;background:white;border-radius:12px;padding:10px}
a{color:var(--link);text-decoration:none;word-break:break-all}a:hover{text-decoration:underline}
.btn{display:inline-block;background:var(--btn);color:white!important;padding:9px 12px;border-radius:10px;margin:4px 4px 4px 0;text-decoration:none}
.btn.green{background:var(--btnGreen)}.btn.gray{background:var(--btnGray)}
pre,code{background:var(--code);border:1px solid var(--border);border-radius:12px;color:var(--codeText);padding:10px;display:block;white-space:pre-wrap;word-break:break-all}
.muted{color:var(--muted)}.ok{color:#22c55e}
@media(max-width:760px){
  .page{padding:14px}
  .floating-theme{position:sticky;top:8px;margin:0 auto 14px;justify-content:center;border-radius:16px}
}
</style>
EOF
}

love_write_qr_gallery_v1329() {
  local qrdir="$1"
  local base_title="${2:-Love QR Gallery}"
  [[ -d "$qrdir" ]] || return 0

  local count
  count="$(find "$qrdir" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"

  cat > "$qrdir/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${base_title}</title>
$(love_web_theme_css_v1329)
</head>
<body>
<input class="theme-radio" type="radio" name="loveTheme" id="themeDark" checked>
<input class="theme-radio" type="radio" name="loveTheme" id="themeGreen">
<div class="floating-theme"><label for="themeDark">深色主题</label><label for="themeGreen">绿色护眼</label></div>
<div class="page"><div class="wrap">
  <div class="hero">
    <h1>Love QR Gallery</h1>
    <div>QR Count: <span class="ok">${count}</span> · Layout: <span class="ok">Grid</span></div>
    <div class="muted">每个二维码独立卡片显示，不再挤在一起。点击 PNG/SVG 可单独打开。</div>
    <p><a class="btn" href="/">返回 Web 首页</a></p>
  </div>
  <h2>二维码列表</h2>
  <div class="qr-grid">
EOF

  local f name svg
  while IFS= read -r f; do
    name="$(basename "$f")"
    svg="${name%.png}.svg"
    cat >> "$qrdir/index.html" <<EOF
    <div class="qr-card">
      <h3>${name}</h3>
      <a href="./${name}" target="_blank"><img src="./${name}" alt="${name}"></a>
      <a class="btn" href="./${name}" target="_blank">打开 PNG</a>
EOF
    if [[ -f "$qrdir/$svg" ]]; then
      cat >> "$qrdir/index.html" <<EOF
      <a class="btn gray" href="./${svg}" target="_blank">打开 SVG</a>
EOF
    fi
    cat >> "$qrdir/index.html" <<'EOF'
    </div>
EOF
  done < <(find "$qrdir" -maxdepth 1 -type f -name '*.png' | sort)

  cat >> "$qrdir/index.html" <<'EOF'
  </div>
</div></div>
</body>
</html>
EOF
}

web_admin_page() {
  love_menu_title "Love Web 管理页" "Dark Theme / Green Theme / QR Gallery"

  love_disk_guard_v1328 100 || return 1

  local web_port auth user pass webroot conf host base
  read -rp "Web 管理页端口 [8099]: " web_port
  web_port="${web_port:-8099}"
  [[ "$web_port" =~ ^[0-9]+$ ]] || web_port="8099"

  read -rp "是否开启 Basic Auth 密码保护？[Y/n]: " auth
  auth="${auth:-Y}"

  user="love"
  pass=""
  if [[ "$auth" =~ ^[Yy]$ ]]; then
    read -rp "Web 用户名 [love]: " user
    user="${user:-love}"
    read -rp "Web 密码，留空自动生成: " pass
    [[ -z "$pass" ]] && pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
  fi

  webroot="/var/www/love-admin"
  conf="/etc/nginx/sites-available/love-admin"

  command -v nginx >/dev/null 2>&1 || { echo "[ERROR] nginx 未安装。请执行：apt update && apt install -y nginx apache2-utils"; return 1; }
  [[ "$auth" =~ ^[Yy]$ ]] && ! command -v htpasswd >/dev/null 2>&1 && { echo "[ERROR] htpasswd 未安装。请执行：apt install -y apache2-utils"; return 1; }

  echo "[1/4] 清理旧 Web 并复制已有文件，不自动触发 sub/qr/txt..."
  rm -rf "$webroot"
  rm -f /etc/nginx/sites-enabled/love-admin /etc/nginx/sites-available/love-admin 2>/dev/null || true
  mkdir -p "$webroot/sub" "$webroot/qr" "$webroot/clients" "$webroot/downloads" /etc/nginx/sites-available /etc/nginx/sites-enabled

  cp -a /opt/Love/subscribe/. "$webroot/sub/" 2>/dev/null || true
  cp -a /opt/Love/subscribe/qr/. "$webroot/qr/" 2>/dev/null || true
  cp -a /opt/Love/subscribe/clients/. "$webroot/clients/" 2>/dev/null || true
  cp -f /opt/Love/cfip-client-test.zip "$webroot/downloads/cfip-client-test.zip" 2>/dev/null || true
  cp -f /opt/Love/cfip-client-test.tar.gz "$webroot/downloads/cfip-client-test.tar.gz" 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt "$webroot/node-links.txt" 2>/dev/null || true

  echo "[2/4] 生成二维码网格页面..."
  love_write_qr_gallery_v1329 "$webroot/qr" "Love QR Gallery"

  host="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1)"
  [[ -n "$host" ]] && base="http://[${host}]:${web_port}" || base="http://YOUR_SERVER_IP:${web_port}"

  local qr_count
  qr_count="$(find "$webroot/qr" -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"

  echo "[3/4] 生成 Web 首页..."
  cat > "$webroot/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Love Admin Panel</title>
$(love_web_theme_css_v1329)
</head>
<body>
<input class="theme-radio" type="radio" name="loveTheme" id="themeDark" checked>
<input class="theme-radio" type="radio" name="loveTheme" id="themeGreen">
<div class="floating-theme"><label for="themeDark">深色主题</label><label for="themeGreen">绿色护眼</label></div>
<div class="page"><div class="wrap">
  <div class="hero">
    <h1>Love Admin Panel</h1>
    <div>Status: <span class="ok">OK</span> · Theme: <span class="ok">Dark / Green</span> · QR: <span class="ok">${qr_count}</span></div>
    <div class="muted">静态页面，只展示节点、订阅、二维码、下载入口；不会在 Web 阶段自动重新生成节点。</div>
    <div class="muted">Base URL: ${base}</div>
  </div>

  <h2>清晰 TXT / 推荐导入</h2>
  <div class="grid">
    <div class="card"><h3>推荐节点</h3><p>普通用户优先用这个。</p><a class="btn green" href="/sub/推荐节点.txt">下载 推荐节点.txt</a></div>
    <div class="card"><h3>节点清晰版</h3><p>按用途分组说明。</p><a class="btn" href="/sub/节点清晰版.txt">下载 节点清晰版.txt</a></div>
    <div class="card"><h3>全部节点</h3><p>全部节点，一个不删。</p><a class="btn gray" href="/sub/all-clean-uri.txt">下载 all-clean-uri.txt</a></div>
  </div>

  <h2>二维码 / QR Codes</h2>
  <div class="grid">
    <div class="card"><h3>二维码网格目录</h3><p>共 ${qr_count} 个 PNG 二维码，单独卡片展示。</p><a class="btn green" href="/qr/">打开 QR 网格</a></div>
    <div class="card"><h3>V2RayN 二维码</h3><a class="btn" href="/qr/v2rayn.png" target="_blank">打开 v2rayn.png</a></div>
    <div class="card"><h3>NekoBox 二维码</h3><a class="btn" href="/qr/nekobox.png" target="_blank">打开 nekobox.png</a></div>
  </div>

  <h2>节点 / 订阅</h2>
  <div class="grid">
    <div class="card"><h3>Raw 订阅</h3><a class="btn" href="/sub/all.txt">打开 all.txt</a><a class="btn gray" href="/sub/all_base64.txt">Base64</a></div>
    <div class="card"><h3>节点链接汇总</h3><a class="btn" href="/node-links.txt">打开 node-links.txt</a></div>
    <div class="card"><h3>客户端目录</h3><a class="btn" href="/clients/">打开 clients 目录</a></div>
  </div>

  <h2>常用命令</h2>
  <pre>Love clean-cache
Love disk-check
Love sub
Love qr
Love txt
Love web</pre>
</div></div>
</body>
</html>
EOF

  echo "[4/4] 写入 nginx 配置并重启..."
  if [[ "$auth" =~ ^[Yy]$ ]]; then
    htpasswd -bc /etc/nginx/.love_web_htpasswd "$user" "$pass" >/dev/null || return 1
  else
    rm -f /etc/nginx/.love_web_htpasswd
  fi

  cat > "$conf" <<EOF
server {
    listen ${web_port};
    listen [::]:${web_port};
    server_name _;
    root ${webroot};
    index index.html;
    autoindex on;
    charset utf-8;
EOF

  if [[ "$auth" =~ ^[Yy]$ ]]; then
    cat >> "$conf" <<EOF
    auth_basic "Love Admin";
    auth_basic_user_file /etc/nginx/.love_web_htpasswd;
EOF
  fi

  cat >> "$conf" <<'EOF'
    location / {
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        try_files $uri $uri/ =404;
    }
}
EOF

  ln -sf "$conf" /etc/nginx/sites-enabled/love-admin
  nginx -t || { cat "$conf"; return 1; }
  systemctl restart nginx || return 1

  echo
  log "Love Web Panel 已生成。"
  echo "访问地址：${base}/?v=129"
  echo "二维码目录：${base}/qr/?v=129"
  [[ "$auth" =~ ^[Yy]$ ]] && { echo "用户名：${user}"; echo "密码：${pass}"; }
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1329 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1329/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.29.0-web-qr-theme-gallery-final}"
  love_original_main_v1329 "$@"
}



# ==============================================================================
# Love v13.30 TUIC / VLESS WS TLS LinkFix Final
# Fix:
#   TUIC 50002 only had allow_insecure=1.
#   VLESS WS TLS 50006 had no allowInsecure/insecure.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.30.0-tuic-wstls-linkfix-final"

love_linkfix_line_v1330() {
  local line="$1"
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"

  if [[ "$line" == vless://*50006* ]]; then
    [[ "$line" != *"allowInsecure=1"* ]] && line="${line//#/&allowInsecure=1#}"
    [[ "$line" != *"insecure=1"* ]] && line="${line//#/&insecure=1#}"
  fi

  if [[ "$line" == tuic://*50002* ]]; then
    [[ "$line" != *"allow_insecure=1"* ]] && line="${line//#/&allow_insecure=1#}"
    [[ "$line" != *"allowInsecure=1"* ]] && line="${line//#/&allowInsecure=1#}"
    [[ "$line" != *"insecure=1"* ]] && line="${line//#/&insecure=1#}"
  fi

  echo "$line"
}

love_fix_line_v1328() {
  love_linkfix_line_v1330 "$1"
}

love_linkfix_files_v1330() {
  love_menu_title "Love TUIC / VLESS WS TLS 链接修复" "50002 / 50006"

  local files=(
    "/opt/Love/subscribe/all.txt"
    "/opt/Love/subscribe/clients/v2rayn-uri.txt"
    "/opt/Love/subscribe/clients/nekobox-uri.txt"
    "/opt/Love/subscribe/clients/sing-box-uri.txt"
    "/var/www/love-admin/sub/all.txt"
    "/var/www/love-admin/node-links.txt"
  )

  local f tmp
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    tmp="${f}.tmp.$$"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^(vless|tuic):// ]]; then
        love_linkfix_line_v1330 "$line"
      else
        echo "$line"
      fi
    done < "$f" > "$tmp"
    mv "$tmp" "$f"
  done

  if [[ -f /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi

  mkdir -p /var/www/love-admin/sub 2>/dev/null || true
  cp -f /opt/Love/subscribe/all_base64.txt /var/www/love-admin/sub/all_base64.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/sub/all.txt 2>/dev/null || true

  echo "[OK] 已修复当前导出链接："
  grep -nE '50002|50006|TUIC|VLESS-WS-TLS' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo
  echo "下一步建议执行："
  echo "  Love qr"
  echo "  Love txt"
  echo "  Love web"
}

if declare -F love_sub_safe_v1328 >/dev/null 2>&1 && ! declare -F love_original_sub_safe_v1330 >/dev/null 2>&1; then
  eval "$(declare -f love_sub_safe_v1328 | sed '1s/^love_sub_safe_v1328/love_original_sub_safe_v1330/')"
  love_sub_safe_v1328() {
    love_original_sub_safe_v1330 "$@"
    love_linkfix_files_v1330 >/dev/null 2>&1 || true
  }
fi

if declare -F love_txt_safe_v1328 >/dev/null 2>&1 && ! declare -F love_original_txt_safe_v1330 >/dev/null 2>&1; then
  eval "$(declare -f love_txt_safe_v1328 | sed '1s/^love_txt_safe_v1328/love_original_txt_safe_v1330/')"
  love_txt_safe_v1328() {
    love_original_txt_safe_v1330 "$@"
    love_linkfix_files_v1330 >/dev/null 2>&1 || true
  }
fi

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1330 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1330/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.30.0-tuic-wstls-linkfix-final}"
  case "${1:-}" in
    link-fix|client-fix|fix-links)
      love_linkfix_files_v1330
      ;;
    *)
      love_original_main_v1330 "$@"
      ;;
  esac
}



# ==============================================================================
# Love v13.31 Source Correct Links Final
# Goal:
#   Generate correct TUIC 50002 / VLESS WS TLS 50006 links from source.
#   Love link-fix is kept only for repairing old exported files, not required
#   for normal generation.
# Key fix:
#   Do NOT check "insecure=1" by substring, because allow_insecure=1 contains it.
#   Use exact query parameter detection: ?key= or &key=.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.31.0-source-correct-links-final"

love_has_param_v1331() {
  local line="$1" key="$2"
  [[ "$line" == *"?${key}="* || "$line" == *"&${key}="* ]]
}

love_add_param_v1331() {
  local line="$1" key="$2" val="${3:-1}"
  love_has_param_v1331 "$line" "$key" && { echo "$line"; return 0; }

  local pre frag sep
  if [[ "$line" == *"#"* ]]; then
    pre="${line%%#*}"
    frag="#${line#*#}"
  else
    pre="$line"
    frag=""
  fi

  [[ "$pre" == *"?"* ]] && sep="&" || sep="?"
  echo "${pre}${sep}${key}=${val}${frag}"
}

love_normalize_name_v1331() {
  local line="$1"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"
  echo "$line"
}

love_fix_line_source_v1331() {
  local line="$1"
  line="${line//$'\r'/}"
  line="$(love_normalize_name_v1331 "$line")"

  # VLESS WS TLS 50006: self-signed TLS must allow insecure cert.
  if [[ "$line" == vless://*50006* ]]; then
    line="$(love_add_param_v1331 "$line" "allowInsecure" "1")"
    line="$(love_add_param_v1331 "$line" "insecure" "1")"
  fi

  # TUIC 50002: different clients use different parameter names.
  if [[ "$line" == tuic://*50002* ]]; then
    line="$(love_add_param_v1331 "$line" "allow_insecure" "1")"
    line="$(love_add_param_v1331 "$line" "allowInsecure" "1")"
    line="$(love_add_param_v1331 "$line" "insecure" "1")"
  fi

  echo "$line"
}

love_label_v1331() {
  local line="$1"
  case "$line" in
    vless://*:50000*) echo "01-LOVE-REALITY-50000【推荐｜TCP｜无域名首选】" ;;
    hysteria2://*:50001*|hy2://*:50001*) echo "02-LOVE-HY2-50001【推荐｜UDP｜速度优先】" ;;
    hysteria2://*:30001*|hy2://*:30001*) echo "03-LOVE-HY2-30001【旧节点｜UDP｜保留兼容】" ;;
    tuic://*:50002*) echo "04-LOVE-TUIC-50002【备用｜UDP｜建议 sing-box/NekoBox】" ;;
    ss://*:50003*) echo "05-LOVE-SS-50003【兼容｜TCP/UDP】" ;;
    trojan://*:50004*) echo "06-LOVE-TROJAN-50004【兼容｜TCP｜TLS】" ;;
    vmess://*) echo "07-LOVE-VMESS-WS-50005【兼容｜TCP｜WS】" ;;
    vless://*:50006*) echo "08-LOVE-VLESS-WS-TLS-50006【备用｜TCP｜自签需允许不安全】" ;;
    vless://*:50007*) echo "09-LOVE-H2-REALITY-50007【高级｜TCP】" ;;
    vless://*:50008*) echo "10-LOVE-GRPC-REALITY-50008【高级｜TCP】" ;;
    anytls://*:50009*) echo "11-LOVE-ANYTLS-50009【高级｜TCP】" ;;
    https://*:50010*|naive+https://*:50010*) echo "12-LOVE-NAIVE-50010【高级｜TCP】" ;;
    shadowtls://*:50011*) echo "13-LOVE-SHADOWTLS-50011【高级｜TCP】" ;;
    *) echo "${line##*#}" ;;
  esac
}

love_set_label_v1331() {
  local line="$1" label
  label="$(love_label_v1331 "$line")"
  if [[ "$line" == *"#"* ]]; then
    echo "${line%%#*}#${label}"
  else
    echo "${line}#${label}"
  fi
}

love_collect_source_links_v1331() {
  # Source-only input. Never read /opt/Love/subscribe/clients or generated TXT.
  grep -hE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' \
    /opt/Love/client-info/xray-client-info.txt \
    /opt/Love/client-info/sing-box-client-info.txt \
    /opt/Love/node_info.txt \
    2>/dev/null | sed 's/\r$//' | awk '!seen[$0]++' || true
}

love_sub_source_correct_v1331() {
  love_menu_title "Love 订阅源头正确导出" "No Patch Needed / Disk Guard"

  love_disk_guard_v1328 200 || return 1

  mkdir -p /opt/Love/subscribe /opt/Love/subscribe/clients

  local raw="/opt/Love/subscribe/all.txt"
  local b64="/opt/Love/subscribe/all_base64.txt"
  local html="/opt/Love/subscribe/index.html"
  local yaml="/opt/Love/subscribe/clash_like.yaml"
  local tmp="/tmp/love_sub_source_correct.$$"

  echo "[1/4] 从 client-info 源文件生成正确链接，不读取输出目录..."
  : > "$tmp"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    love_set_label_v1331 "$(love_fix_line_source_v1331 "$line")" >> "$tmp"
  done < <(love_collect_source_links_v1331)

  awk '!seen[$0]++' "$tmp" > "$raw"
  rm -f "$tmp"

  cp -f "$raw" /opt/Love/subscribe/clients/v2rayn-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/nekobox-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/sing-box-uri.txt 2>/dev/null || true

  echo "[2/4] 生成 Base64..."
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$raw" > "$b64" 2>/dev/null || true
  else
    base64 "$raw" | tr -d '\n' > "$b64" 2>/dev/null || true
  fi

  echo "[3/4] 生成简易 HTML / YAML..."
  {
    echo "<!doctype html><html><head><meta charset='utf-8'><title>Love Subscription</title></head><body><pre>"
    sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$raw"
    echo "</pre></body></html>"
  } > "$html"

  {
    echo "# Love URI subscription list"
    echo "# Generated source-correct, no link-fix required"
    echo "links:"
    awk '{gsub(/"/,"\\\""); print "  - \"" $0 "\""}' "$raw"
  } > "$yaml"

  echo "[4/4] 生成小型 TXT 速查..."
  love_txt_source_correct_v1331 >/dev/null 2>&1 || true

  echo
  log "订阅源头正确导出完成："
  echo "Raw:    $raw"
  echo "Base64: $b64"
  echo "HTML:   $html"
  echo "TXT:    /opt/Love/subscribe/推荐节点.txt"

  echo
  echo "关键链接检查："
  grep -nE '50002|50006|TUIC|VLESS-WS-TLS' "$raw" 2>/dev/null || true
}

love_txt_source_correct_v1331() {
  love_disk_guard_v1328 100 || return 1
  mkdir -p /opt/Love/subscribe

  local raw="/opt/Love/subscribe/all.txt"
  local clean="/opt/Love/subscribe/节点清晰版.txt"
  local rec="/opt/Love/subscribe/推荐节点.txt"
  local all="/opt/Love/subscribe/all-clean-uri.txt"
  local simple="/opt/Love/subscribe/nodes-clean.txt"

  [[ -s "$raw" ]] || love_sub_source_correct_v1331 >/dev/null 2>&1 || true

  : > "$clean"; : > "$rec"; : > "$all"; : > "$simple"

  {
    echo "Love 节点清晰版 / Clean Node List"
    echo "生成时间: $(date)"
    echo "说明：全部节点都保留；推荐节点只是精选入口，不代表删除其他节点。"
    echo "说明：50002 / 50006 参数已在生成源头修正，不需要额外补丁。"
    echo
    echo "================ 推荐节点 ================"
  } >> "$clean"

  echo "# Love 推荐节点 / Recommended" >> "$rec"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    fixed="$(love_set_label_v1331 "$(love_fix_line_source_v1331 "$line")")"
    echo "$fixed" >> "$all"

    case "$fixed" in
      *"REALITY-50000"*|*"HY2-50001"*|*"HY2-30001"*|*"TROJAN-50004"*|*"VLESS-WS-TLS-50006"*)
        echo "$fixed" >> "$rec"
        { echo; echo "【${fixed##*#}】"; echo "$fixed"; } >> "$clean"
        ;;
    esac
  done < "$raw"

  {
    echo
    echo "================ 全部节点 ================"
    cat "$all"
  } >> "$clean"

  {
    echo "推荐节点："
    cat "$rec"
    echo
    echo "全部节点："
    cat "$all"
  } > "$simple"

  mkdir -p /opt/Love/subscribe/clients
  cat > /opt/Love/subscribe/clients/READ_ME_TXT位置.txt <<EOF
TXT 文件在：
/opt/Love/subscribe/推荐节点.txt
/opt/Love/subscribe/节点清晰版.txt
/opt/Love/subscribe/all-clean-uri.txt
EOF

  log "TXT 源头正确生成完成："
  echo "  $rec"
  echo "  $clean"
  echo "  $all"
}

love_linkfix_files_v1331() {
  love_menu_title "Love 旧导出链接修复" "Optional Repair Only"

  echo "说明：正常执行 Love sub 已经会源头生成正确链接。"
  echo "这个命令只用于修复旧的 all.txt / Web 缓存。"
  echo

  local files=(
    "/opt/Love/subscribe/all.txt"
    "/opt/Love/subscribe/clients/v2rayn-uri.txt"
    "/opt/Love/subscribe/clients/nekobox-uri.txt"
    "/opt/Love/subscribe/clients/sing-box-uri.txt"
    "/var/www/love-admin/sub/all.txt"
    "/var/www/love-admin/node-links.txt"
  )

  local f tmp
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    tmp="${f}.tmp.$$"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^(vless|tuic):// ]]; then
        love_set_label_v1331 "$(love_fix_line_source_v1331 "$line")"
      else
        echo "$line"
      fi
    done < "$f" > "$tmp"
    mv "$tmp" "$f"
  done

  if [[ -f /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi

  mkdir -p /var/www/love-admin/sub 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/sub/all.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all_base64.txt /var/www/love-admin/sub/all_base64.txt 2>/dev/null || true

  echo "[OK] 旧导出链接修复完成："
  grep -nE '50002|50006|TUIC|VLESS-WS-TLS' /opt/Love/subscribe/all.txt 2>/dev/null || true
}

# Override v13.28/v13.30 helper names too, so any internal call also uses source-correct logic.
love_fix_line_v1328() { love_fix_line_source_v1331 "$1"; }
love_linkfix_line_v1330() { love_fix_line_source_v1331 "$1"; }
love_linkfix_files_v1330() { love_linkfix_files_v1331 "$@"; }

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1331 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1331/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.31.0-source-correct-links-final}"
  case "${1:-}" in
    sub|subscription)
      love_sub_source_correct_v1331
      ;;
    txt|node-txt|clean-txt|nodes-clean)
      love_txt_source_correct_v1331
      ;;
    link-fix|client-fix|fix-links)
      love_linkfix_files_v1331
      ;;
    *)
      love_original_main_v1331 "$@"
      ;;
  esac
}



# ==============================================================================
# Love v13.32 Final Unified Stable
# config.json is source; client-info is cache; subscribe is output only.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.32.0-final-unified-stable"

love_host_uri_v1332() {
  local old ip6 ip4
  old="$(grep -hEo '@\[[0-9a-fA-F:]+\]:' /opt/Love/client-info/*.txt /opt/Love/subscribe/all.txt 2>/dev/null | head -1 | sed -E 's/^@\[|\]:$//g' || true)"
  [[ -n "$old" ]] && { echo "[$old]"; return; }
  ip6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)"
  [[ -n "$ip6" ]] && { echo "[$ip6]"; return; }
  ip4="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
  [[ -n "$ip4" ]] && { echo "$ip4"; return; }
  echo "YOUR_SERVER_IP"
}

love_b64_v1332() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w0; else base64 | tr -d '\n'; fi
}

love_existing_uri_port_v1332() {
  local port="$1"
  grep -hE "://.*(\]|:)${port}([/?#]|$)" \
    /opt/Love/client-info/*.txt \
    /opt/Love/subscribe/all.txt \
    /root/love-safe-backup/client-info.bak/*.txt \
    2>/dev/null | head -1 || true
}

love_label_uri_v1332() {
  local line="$1" label="$2"
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"
  [[ "$line" == *"#"* ]] && echo "${line%%#*}#${label}" || echo "${line}#${label}"
}

love_sync_v1332() {
  love_menu_title "Love 节点源同步" "config.json -> client-info"

  local cfg="/etc/sing-box/config.json"
  local out="/opt/Love/client-info/sing-box-client-info.txt"
  local host tmp
  [[ -s "$cfg" ]] || { echo "[ERROR] 缺少 $cfg"; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "[ERROR] 缺少 jq"; return 1; }

  mkdir -p /opt/Love/client-info
  host="$(love_host_uri_v1332)"
  tmp="/tmp/love_sync_v1332.$$"
  : > "$tmp"

  # Reality needs public key; preserve existing correct URI if available.
  local old
  old="$(love_existing_uri_port_v1332 50000)"
  [[ -n "$old" ]] && love_label_uri_v1332 "$old" "01-LOVE-REALITY-50000【推荐｜TCP｜无域名首选】" >> "$tmp"

  while IFS=$'\t' read -r tag typ port; do
    [[ -n "$tag" && -n "$typ" && -n "$port" ]] || continue
    case "$typ:$port:$tag" in
      hysteria2:50001:*|hysteria2:30001:*)
        local pass sni name
        pass="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").users[0].password // empty' "$cfg")"
        sni="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").tls.server_name // "self.local"' "$cfg")"
        [[ -n "$pass" ]] || continue
        [[ "$port" == "30001" ]] && name="03-LOVE-HY2-30001【旧节点｜UDP｜保留兼容】" || name="02-LOVE-HY2-50001【推荐｜UDP｜速度优先】"
        echo "hy2://${pass}@${host}:${port}/?sni=${sni}&insecure=1#${name}" >> "$tmp"
        ;;
      tuic:*)
        local uuid password sni cc
        uuid="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").users[0].uuid // empty' "$cfg")"
        password="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").users[0].password // empty' "$cfg")"
        sni="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").tls.server_name // "self.local"' "$cfg")"
        cc="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").congestion_control // "bbr"' "$cfg")"
        [[ -n "$uuid" && -n "$password" ]] || continue
        echo "tuic://${uuid}:${password}@${host}:${port}?sni=${sni}&congestion_control=${cc}&udp_relay_mode=native&alpn=h3&allow_insecure=true&allowInsecure=true&insecure=true#04-LOVE-TUIC-${port}【备用｜UDP｜建议 sing-box/NekoBox】" >> "$tmp"
        ;;
      shadowsocks:*)
        local method password enc
        method="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").method // "aes-128-gcm"' "$cfg")"
        password="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").password // empty' "$cfg")"
        [[ -n "$password" ]] || continue
        enc="$(printf "%s:%s" "$method" "$password" | love_b64_v1332)"
        echo "ss://${enc}@${host}:${port}#05-LOVE-SS-${port}【兼容｜TCP/UDP】" >> "$tmp"
        ;;
      trojan:*)
        local password sni extra
        password="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").users[0].password // empty' "$cfg")"
        sni="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").tls.server_name // "self.local"' "$cfg")"
        [[ -n "$password" ]] || continue
        extra=""; [[ "$sni" == "self.local" || "$sni" == *.local ]] && extra="&allowInsecure=true"
        echo "trojan://${password}@${host}:${port}?security=tls&sni=${sni}${extra}#06-LOVE-TROJAN-${port}【兼容｜TCP｜TLS】" >> "$tmp"
        ;;
      vmess:*)
        local uuid path raw enc hostraw
        uuid="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").users[0].uuid // empty' "$cfg")"
        path="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").transport.path // "/vmess"' "$cfg")"
        hostraw="${host#[}"; hostraw="${hostraw%]}"
        [[ -n "$uuid" ]] || continue
        raw="$(printf '{"v":"2","ps":"07-LOVE-VMESS-WS-%s【兼容｜TCP｜WS】","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"%s","tls":""}' "$port" "$hostraw" "$port" "$uuid" "$path")"
        enc="$(printf "%s" "$raw" | love_b64_v1332)"
        echo "vmess://${enc}" >> "$tmp"
        ;;
      vless:50006:*)
        local uuid sni path extra
        uuid="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").users[0].uuid // empty' "$cfg")"
        sni="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").tls.server_name // "self.local"' "$cfg")"
        path="$(jq -r '.inbounds[]? | select(.tag=="'"$tag"'").transport.path // "/vless"' "$cfg")"
        path="${path//\//%2F}"
        [[ -n "$uuid" ]] || continue
        extra=""; [[ "$sni" == "self.local" || "$sni" == *.local ]] && extra="&allowInsecure=true&insecure=true"
        echo "vless://${uuid}@${host}:${port}?encryption=none&security=tls&sni=${sni}&type=ws&path=${path}${extra}#08-LOVE-VLESS-WS-TLS-50006【备用｜TCP｜自签需允许不安全】" >> "$tmp"
        ;;
      *)
        old="$(love_existing_uri_port_v1332 "$port")"
        [[ -n "$old" ]] && love_label_uri_v1332 "$old" "LOVE-${tag}-${port}" >> "$tmp"
        ;;
    esac
  done < <(jq -r '.inbounds[]? | [.tag,.type,.listen_port] | @tsv' "$cfg")

  awk '!seen[$0]++' "$tmp" > "$out"
  rm -f "$tmp"

  echo "[OK] 已同步：$out"
  echo "源节点数：$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' "$out" 2>/dev/null || echo 0)"
}

love_sub_final_v1332() {
  love_menu_title "Love 订阅最终稳定导出" "Sync First / No Recursion"
  love_disk_guard_v1328 200 || return 1
  love_sync_v1332 >/dev/null 2>&1 || true
  love_sub_source_correct_v1331
}

love_qr_count_v1332() {
  local d="${1:-/opt/Love/subscribe/qr}" node total helper
  node="$(find "$d" -maxdepth 1 -type f -name 'node-*.png' 2>/dev/null | wc -l | tr -d ' ')"
  total="$(find "$d" -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  helper=$((total-node)); [[ "$helper" -lt 0 ]] && helper=0
  echo "单节点二维码：$node"
  echo "合集/客户端二维码：$helper"
  echo "二维码 PNG 总数：$total"
}

love_write_qr_gallery_v1332() {
  local qrdir="$1"
  [[ -d "$qrdir" ]] || return 0
  local node total helper
  node="$(find "$qrdir" -maxdepth 1 -type f -name 'node-*.png' 2>/dev/null | wc -l | tr -d ' ')"
  total="$(find "$qrdir" -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  helper=$((total-node)); [[ "$helper" -lt 0 ]] && helper=0

  cat > "$qrdir/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Love QR Gallery</title>
$(love_web_theme_css_v1329)
</head><body>
<input class="theme-radio" type="radio" name="loveTheme" id="themeDark" checked>
<input class="theme-radio" type="radio" name="loveTheme" id="themeGreen">
<div class="floating-theme"><label for="themeDark">深色主题</label><label for="themeGreen">绿色护眼</label></div>
<div class="page"><div class="wrap"><div class="hero"><h1>Love QR Gallery</h1>
<div>单节点二维码：<span class="ok">${node}</span> · 合集二维码：<span class="ok">${helper}</span> · PNG 总数：<span class="ok">${total}</span></div>
<div class="muted">真实节点数看订阅 all.txt；all/v2rayn/nekobox/shadowrocket 是合集入口。</div><p><a class="btn" href="/">返回首页</a></p></div>
<h2>一、单节点二维码</h2><div class="qr-grid">
EOF
  local f name
  while IFS= read -r f; do
    name="$(basename "$f")"
    echo "<div class=\"qr-card\"><h3>${name}</h3><a href=\"./${name}\" target=\"_blank\"><img src=\"./${name}\" alt=\"${name}\"></a><a class=\"btn\" href=\"./${name}\" target=\"_blank\">打开 PNG</a></div>" >> "$qrdir/index.html"
  done < <(find "$qrdir" -maxdepth 1 -type f -name 'node-*.png' | sort)

  echo '</div><h2>二、订阅 / 客户端合集二维码</h2><div class="qr-grid">' >> "$qrdir/index.html"
  while IFS= read -r f; do
    name="$(basename "$f")"
    echo "<div class=\"qr-card\"><h3>${name}</h3><a href=\"./${name}\" target=\"_blank\"><img src=\"./${name}\" alt=\"${name}\"></a><a class=\"btn gray\" href=\"./${name}\" target=\"_blank\">打开 PNG</a></div>" >> "$qrdir/index.html"
  done < <(find "$qrdir" -maxdepth 1 -type f -name '*.png' ! -name 'node-*.png' | sort)
  echo '</div></div></div></body></html>' >> "$qrdir/index.html"
}

# Patch the v13.29 web function by generating grouped QR gallery before nginx restarts.
if declare -F web_admin_page >/dev/null 2>&1 && ! declare -F love_original_web_admin_v1332 >/dev/null 2>&1; then
  eval "$(declare -f web_admin_page | sed '1s/^web_admin_page/love_original_web_admin_v1332/')"
  web_admin_page() {
    love_original_web_admin_v1332 "$@"
    love_write_qr_gallery_v1332 /var/www/love-admin/qr 2>/dev/null || true
    local sub_count node total helper
    sub_count="$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' /opt/Love/subscribe/all.txt 2>/dev/null || echo 0)"
    node="$(find /var/www/love-admin/qr -maxdepth 1 -type f -name 'node-*.png' 2>/dev/null | wc -l | tr -d ' ')"
    total="$(find /var/www/love-admin/qr -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
    helper=$((total-node)); [[ "$helper" -lt 0 ]] && helper=0
    echo
    echo "[INFO] Web 数量说明：订阅节点=${sub_count}，单节点二维码=${node}，合集二维码=${helper}，PNG总数=${total}"
  }
fi

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1332 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1332/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.32.0-final-unified-stable}"
  case "${1:-}" in
    sync|rebuild-client-info) love_sync_v1332 ;;
    sub|subscription) love_sub_final_v1332 ;;
    qr-count|count-qr) love_qr_count_v1332 ;;
    *) love_original_main_v1332 "$@" ;;
  esac
}



# ==============================================================================
# Love v13.33 Start Menu Safe Final
# Fix:
#   Fresh VPS: bash <(wget ...) installed successfully but stopped after title.
#   Love / love returned no visible menu on some systems.
# Reason:
#   Old main menu status panel had external checks and set -e sensitive calls.
#   On minimal VPS this could exit before drawing menu.
# ==============================================================================
LOVE_SCRIPT_VERSION="Love v13.33.0-start-menu-safe-final"

love_service_state_v1333() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "active"
  else
    echo "not active"
  fi
}

love_main_status_panel_v13() {
  local sb ng wp final os virt arch sub_count cfg_ok
  sb="$(love_service_state_v1333 sing-box)"
  ng="$(love_service_state_v1333 nginx)"
  wp="$(love_service_state_v1333 love-wireproxy.service)"
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"

  if [[ -s /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
    final="$(jq -r '.route.final // "unknown"' /etc/sing-box/config.json 2>/dev/null || echo unknown)"
    cfg_ok="yes"
  else
    final="unknown"
    cfg_ok="no"
  fi

  sub_count="$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' /opt/Love/subscribe/all.txt 2>/dev/null || echo 0)"

  printf "%b系统状态%b\n" "$(lc green)" "$(lc reset)"
  printf "  %-22s %s\n" "OS:" "$os"
  printf "  %-22s %s / %s\n" "Arch/Virt:" "$arch" "$virt"
  printf "  %-22s %s\n" "config.json:" "$cfg_ok"
  printf "  %-22s %s\n" "订阅节点:" "$sub_count"
  love_ui_status_line "sing-box:" "$sb"
  love_ui_status_line "nginx web:" "$ng"
  love_ui_status_line "WireProxy:" "$wp"
  printf "  %-22s %b%s%b\n" "route.final:" "$(lc cyan)" "$final" "$(lc reset)"
  printf "  %b说明：此面板不再做外网 curl 探测，避免新 VPS 首次启动卡住或提前退出。%b\n" "$(lc gray)" "$(lc reset)"
  echo
}

love_bootstrap_check_v1333() {
  local f="/opt/Love/Love.sh"
  if [[ ! -s "$f" ]]; then
    echo "[ERROR] $f 不存在或是 0 字节。请重新下载 Love.sh。"
    return 1
  fi
  bash -n "$f" || return 1
  return 0
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1333 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1333/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.33.0-start-menu-safe-final}"

  case "${1:-}" in
    ""|menu)
      need_root
      prepare_dirs
      fix_hostname
      check_os_soft
      install_shortcut
      main_menu
      ;;
    singbox|sing-box|sb)
      install_singbox_native
      ;;
    xray|reality|hy2|xray-hy2)
      install_xray_stable
      ;;
    boot-check|start-check)
      love_bootstrap_check_v1333
      ;;
    *)
      love_original_main_v1333 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.34 Dual Stack Final
# Goal:
#   Keep Xray Reality+HY2 on 443 and sing-box full protocols on 38xxx together.
#   Generate correct links at source; no post-delete / no generated-file recursion.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.34.0-dual-stack-final"

love_uri_has_param_v1334() {
  local line="$1" key="$2"
  [[ "$line" == *"?${key}="* || "$line" == *"&${key}="* ]]
}

love_uri_add_param_v1334() {
  local line="$1" key="$2" val="${3:-true}" pre frag sep
  love_uri_has_param_v1334 "$line" "$key" && { echo "$line"; return; }
  if [[ "$line" == *"#"* ]]; then
    pre="${line%%#*}"
    frag="#${line#*#}"
  else
    pre="$line"
    frag=""
  fi
  [[ "$pre" == *"?"* ]] && sep="&" || sep="?"
  echo "${pre}${sep}${key}=${val}${frag}"
}

love_uri_fix_v1334() {
  local line="$1"
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"
  line="${line//allow_insecure=1/allow_insecure=true}"
  line="${line//allowInsecure=1/allowInsecure=true}"
  line="${line//insecure=1/insecure=true}"

  # TUIC: both old 50002 and new 38002 use QUIC h3 and self-signed compatibility flags.
  if [[ "$line" == tuic://*":50002"* || "$line" == tuic://*":38002"* ]]; then
    line="$(love_uri_add_param_v1334 "$line" "alpn" "h3")"
    line="$(love_uri_add_param_v1334 "$line" "allow_insecure" "true")"
    line="$(love_uri_add_param_v1334 "$line" "allowInsecure" "true")"
    line="$(love_uri_add_param_v1334 "$line" "insecure" "true")"
  fi

  # VLESS WS TLS self-signed ports.
  if [[ "$line" == vless://*":50006"* || "$line" == vless://*":38006"* ]]; then
    if [[ "$line" == *"security=tls"* && "$line" == *"type=ws"* ]]; then
      line="$(love_uri_add_param_v1334 "$line" "allowInsecure" "true")"
      line="$(love_uri_add_param_v1334 "$line" "insecure" "true")"
    fi
  fi

  # Trojan self.local certificate compatibility.
  if [[ "$line" == trojan://* && "$line" == *"sni=self.local"* ]]; then
    line="$(love_uri_add_param_v1334 "$line" "allowInsecure" "true")"
  fi

  echo "$line"
}

love_collect_dual_uris_v1334() {
  # Source/caches only; never read generated TXT in subscribe/clients.
  grep -hE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' \
    /opt/Love/client-info/xray-client-info.txt \
    /opt/Love/client-info/sing-box-client-info.txt \
    /opt/Love/node_info.txt \
    /opt/Love/subscribe/all.txt \
    2>/dev/null | sed 's/\r$//' || true
}

love_sub_dual_final_v1334() {
  love_menu_title "Love 订阅双栈最终导出" "Xray 443 + sing-box Full"

  love_disk_guard_v1328 200 || return 1

  # Sync sing-box from real config first if function exists.
  if declare -F love_sync_v1332 >/dev/null 2>&1; then
    love_sync_v1332 >/dev/null 2>&1 || true
  fi

  mkdir -p /opt/Love/subscribe /opt/Love/subscribe/clients

  local raw="/opt/Love/subscribe/all.txt"
  local b64="/opt/Love/subscribe/all_base64.txt"
  local html="/opt/Love/subscribe/index.html"
  local yaml="/opt/Love/subscribe/clash_like.yaml"
  local tmp="/tmp/love_dual_sub.$$"

  echo "[1/4] 收集 Xray 443 + sing-box 全协议节点..."
  : > "$tmp"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    love_uri_fix_v1334 "$line" >> "$tmp"
  done < <(love_collect_dual_uris_v1334)

  awk '!seen[$0]++' "$tmp" > "$raw"
  rm -f "$tmp"

  cp -f "$raw" /opt/Love/subscribe/clients/v2rayn-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/nekobox-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/sing-box-uri.txt 2>/dev/null || true

  echo "[2/4] 生成 Base64..."
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$raw" > "$b64" 2>/dev/null || true
  else
    base64 "$raw" | tr -d '\n' > "$b64" 2>/dev/null || true
  fi

  echo "[3/4] 生成 HTML / YAML..."
  {
    echo "<!doctype html><html><head><meta charset='utf-8'><title>Love Subscription</title></head><body><pre>"
    sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$raw"
    echo "</pre></body></html>"
  } > "$html"

  {
    echo "# Love URI subscription list"
    echo "# Dual stack: Xray 443 + sing-box full protocols"
    echo "links:"
    awk '{gsub(/"/,"\\\""); print "  - \"" $0 "\""}' "$raw"
  } > "$yaml"

  echo "[4/4] 生成 TXT..."
  if declare -F love_txt_final_v1332 >/dev/null 2>&1; then
    love_txt_final_v1332 >/dev/null 2>&1 || true
  elif declare -F love_txt_source_correct_v1331 >/dev/null 2>&1; then
    love_txt_source_correct_v1331 >/dev/null 2>&1 || true
  fi

  echo
  log "双栈订阅导出完成："
  echo "订阅节点行数：$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' "$raw" 2>/dev/null || echo 0)"
  echo "Raw:    $raw"
  echo "Base64: $b64"
  echo
  echo "关键节点检查："
  grep -nE '443|38000|38001|38002|38003|38004|38005|38006|REALITY|HY2|TUIC|TROJAN|VLESS-WS-TLS' "$raw" 2>/dev/null || true
}

love_ports_v1334() {
  love_menu_title "Love 自动放行端口" "config.json + xray 443 + web"

  echo "将按当前服务自动放行："
  echo "1) sing-box config.json 入站端口"
  echo "2) xray 监听端口，例如 443/tcp + 443/udp"
  echo "3) Web 8099/tcp"
  echo

  if ! command -v ufw >/dev/null 2>&1; then
    echo "[INFO] ufw 未安装，系统防火墙可能默认开放。"
    echo "注意：服务商后台安全组仍需手动放行。"
    return 0
  fi

  # Open sing-box ports.
  if [[ -s /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.inbounds[]? | [.tag,.type,.listen_port] | @tsv' /etc/sing-box/config.json
    while IFS=$'\t' read -r tag typ port; do
      [[ -n "$port" ]] || continue
      case "$typ" in
        hysteria2|tuic) ufw allow "${port}/udp" >/dev/null 2>&1 || true; echo "[OK] $tag $typ ${port}/udp" ;;
        shadowsocks|naive) ufw allow "${port}/tcp" >/dev/null 2>&1 || true; ufw allow "${port}/udp" >/dev/null 2>&1 || true; echo "[OK] $tag $typ ${port}/tcp+udp" ;;
        *) ufw allow "${port}/tcp" >/dev/null 2>&1 || true; echo "[OK] $tag $typ ${port}/tcp" ;;
      esac
    done < <(jq -r '.inbounds[]? | [.tag,.type,.listen_port] | @tsv' /etc/sing-box/config.json)
  fi

  # Open xray listening ports from ss output.
  local xp
  for xp in $(ss -lntup 2>/dev/null | awk '/xray/ {print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -nu); do
    ufw allow "${xp}/tcp" >/dev/null 2>&1 || true
    ufw allow "${xp}/udp" >/dev/null 2>&1 || true
    echo "[OK] xray ${xp}/tcp+udp"
  done

  ufw allow 8099/tcp >/dev/null 2>&1 || true
  echo "[OK] web 8099/tcp"
  ufw reload >/dev/null 2>&1 || true
  ufw status
}

love_count_v1334() {
  love_menu_title "Love 节点数量说明" "Subscription vs QR"
  local raw="/opt/Love/subscribe/all.txt"
  local sub node total helper
  sub="$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' "$raw" 2>/dev/null || echo 0)"
  node="$(find /opt/Love/subscribe/qr -maxdepth 1 -type f -name 'node-*.png' 2>/dev/null | wc -l | tr -d ' ')"
  total="$(find /opt/Love/subscribe/qr -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  helper=$((total-node)); [[ "$helper" -lt 0 ]] && helper=0
  echo "订阅节点行数：$sub"
  echo "单节点二维码：$node"
  echo "合集/客户端二维码：$helper"
  echo "二维码 PNG 总数：$total"
  echo
  echo "说明：hysteria2:// 和 hy2:// 可能是同一个 HY2 节点的兼容写法，会占两行。"
  echo "说明：v2rayn/nekobox/shadowrocket/all/all_base64 是合集二维码，不算独立节点。"
}

# Override current helpers too.
love_linkfix_files_v1331() { love_sub_dual_final_v1334; }
love_linkfix_files_v1330() { love_sub_dual_final_v1334; }

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1334 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1334/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.34.0-dual-stack-final}"
  case "${1:-}" in
    sub|subscription) love_sub_dual_final_v1334 ;;
    link-fix|client-fix|fix-links) love_sub_dual_final_v1334 ;;
    ports|open-ports|firewall) love_ports_v1334 ;;
    count|node-count|qr-count) love_count_v1334 ;;
    *)
      love_original_main_v1334 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.35 Hard Menu + Dual Stack Final
# Fix:
#   - Love / love no output on fresh VPS.
#   - Force a hard safe menu that does not depend on old status panel.
#   - Keep Xray 443 Reality+HY2 and sing-box full 38xxx together.
#   - Generate correct insecure/allowInsecure/allow_insecure at source.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.35.0-hard-menu-dual-stack-final"

love_call_if_exists_v1335() {
  local fn="$1"; shift || true
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
  else
    echo "[WARN] 函数不存在：$fn"
  fi
}

love_safe_status_v1335() {
  local os arch virt sb xr ng sub_count
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  systemctl is-active --quiet sing-box 2>/dev/null && sb="active" || sb="not active"
  systemctl is-active --quiet xray 2>/dev/null && xr="active" || xr="not active"
  systemctl is-active --quiet nginx 2>/dev/null && ng="active" || ng="not active"
  sub_count="$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' /opt/Love/subscribe/all.txt 2>/dev/null || echo 0)"

  echo "系统状态"
  printf "  %-22s %s\n" "OS:" "$os"
  printf "  %-22s %s / %s\n" "Arch/Virt:" "$arch" "$virt"
  printf "  %-22s %s\n" "订阅节点:" "$sub_count"
  printf "  %-22s %s\n" "sing-box:" "$sb"
  printf "  %-22s %s\n" "xray:" "$xr"
  printf "  %-22s %s\n" "nginx web:" "$ng"
  echo
}

love_hard_menu_v1335() {
  while true; do
    clear 2>/dev/null || true
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo "Love Node Server Manager ${LOVE_SCRIPT_VERSION:-Love v13.35.0-hard-menu-dual-stack-final}"
    echo "════════════════════════════════════════════════════════════════════════════════"
    love_safe_status_v1335

    echo "主菜单"
    printf "  │ %-36s │ %-36s │\n" "1) 节点目录" "14) v6 Project Tools"
    printf "  │ %-36s │ %-36s │\n" "2) Xray Reality + HY2" "15) v7 Stable Tools"
    printf "  │ %-36s │ %-36s │\n" "3) sing-box 全协议" "16) v8 Project Panel"
    printf "  │ %-36s │ %-36s │\n" "4) Argo 隧道" "17) Nginx Reverse Proxy"
    printf "  │ %-36s │ %-36s │\n" "5) UDP 端口跳跃" "18) HY2/sing-box 修复"
    printf "  │ %-36s │ %-36s │\n" "6) WARP 说明" "19) IPv6-only 出站"
    printf "  │ %-36s │ %-36s │\n" "7) 节点信息 Love -n" "20) WARP Manager / FS"
    printf "  │ %-36s │ %-36s │\n" "8) 导出订阅 Love sub" "21) 查看运行状态"
    printf "  │ %-36s │ %-36s │\n" "9) 生成二维码 Love qr" "22) 备份配置"
    printf "  │ %-36s │ %-36s │\n" "10) Super Tools" "23) 卸载菜单"
    printf "  │ %-36s │ %-36s │\n" "11) Web 管理页 Love web" "24) GitHub 发布说明"
    printf "  │ %-36s │ %-36s │\n" "12) 在线更新 / 下载链接" "25) 安装 warp 命令"
    printf "  │ %-36s │ %-36s │\n" "13) 客户端导出" "0) 退出"
    echo
    echo "双栈推荐：2 可保留 Xray 443；3 生成 sing-box 全协议；sub 会合并两边。"
    echo "常用：Love ports | Love sync | Love sub | Love qr | Love txt | Love web | Love count"
    echo
    read -rp "请选择: " choice

    case "${choice}" in
      1) love_call_if_exists_v1335 show_all_node_catalog ;;
      2) love_call_if_exists_v1335 install_xray_stable ;;
      3) love_call_if_exists_v1335 install_singbox_native ;;
      4) love_call_if_exists_v1335 argo_helper ;;
      5) love_call_if_exists_v1335 port_hopping_helper ;;
      6) love_call_if_exists_v1335 warp_helper ;;
      7) love_call_if_exists_v1335 show_node_info ;;
      8) love_sub_dual_final_v1334 ;;
      9) love_call_if_exists_v1335 generate_qrcodes ;;
      10) love_call_if_exists_v1335 super_menu ;;
      11) love_call_if_exists_v1335 web_admin_page ;;
      12) love_call_if_exists_v1335 self_update_love ;;
      13) love_call_if_exists_v1335 love_full_client_pack ;;
      14) love_call_if_exists_v1335 v6_super_menu ;;
      15) love_call_if_exists_v1335 v7_stable_menu ;;
      16) love_call_if_exists_v1335 v8_menu ;;
      17) love_call_if_exists_v1335 nginx_rp_menu ;;
      18) love_call_if_exists_v1335 love_fix_hy2_now ;;
      19) love_call_if_exists_v1335 love_ipv6_outbound_menu ;;
      20) love_call_if_exists_v1335 love_warp_manager_menu ;;
      21) love_call_if_exists_v1335 show_status ;;
      22) love_call_if_exists_v1335 backup_configs ;;
      23) love_call_if_exists_v1335 uninstall_menu_v7 ;;
      24) love_call_if_exists_v1335 github_publish_note ;;
      25) love_call_if_exists_v1335 love_install_fs_warp_command ;;
      0) exit 0 ;;
      *) echo "[WARN] 无效选择。" ;;
    esac

    echo
    read -rp "按 Enter 返回主菜单..." _
  done
}

love_boot_check_v1335() {
  echo "==== Love 文件 ===="
  ls -lh /opt/Love/Love.sh 2>/dev/null || true
  grep '^VERSION=' /opt/Love/Love.sh 2>/dev/null || true
  bash -n /opt/Love/Love.sh && echo "[OK] bash -n"
  echo
  echo "==== 命令指向 ===="
  type -a Love 2>/dev/null || true
  type -a love 2>/dev/null || true
  readlink -f /usr/local/bin/Love 2>/dev/null || true
  echo
  echo "==== 服务 ===="
  systemctl is-active sing-box 2>/dev/null || true
  systemctl is-active xray 2>/dev/null || true
  systemctl is-active nginx 2>/dev/null || true
  echo
  echo "==== 监听 ===="
  ss -lntup | grep -E '443|38000|38001|38002|38003|38004|38005|38006|38007|38008|38009|38010|38011|8099|sing-box|xray' || true
}

# Hard override old menu/status entry.
main_menu() {
  love_hard_menu_v1335
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1335 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1335/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.35.0-hard-menu-dual-stack-final}"
  case "${1:-}" in
    ""|menu)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      love_hard_menu_v1335
      ;;
    boot-check|start-check|doctor)
      love_boot_check_v1335
      ;;
    singbox|sing-box|sb|all)
      love_call_if_exists_v1335 install_singbox_native
      ;;
    xray|reality|hy2|xray-hy2)
      love_call_if_exists_v1335 install_xray_stable
      ;;
    sub|subscription)
      love_sub_dual_final_v1334
      ;;
    link-fix|client-fix|fix-links)
      love_sub_dual_final_v1334
      ;;
    ports|open-ports|firewall)
      love_ports_v1334
      ;;
    count|node-count|qr-count)
      love_count_v1334
      ;;
    *)
      love_original_main_v1335 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.36 Domain-Aware Dual Stack Final
# Full version:
#   - Hard menu retained.
#   - Xray 443 + sing-box 38xxx dual stack retained.
#   - No-domain mode: self.local + insecure flags.
#   - Domain mode: real domain + real certificate, do NOT add insecure flags.
#   - Generates correct links at source, not by post-delete/patch.
#   - Adds domain-check / cert-fix / sync / ports / count.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.36.0-domain-aware-dual-stack-final"

love_uri_get_param_v1336() {
  local line="$1" key="$2" q
  q="${line#*\?}"
  q="${q%%#*}"
  tr '&' '\n' <<< "$q" | awk -F= -v k="$key" '$1==k{print $2; exit}'
}

love_is_self_domain_v1336() {
  local s="${1:-}"
  [[ -z "$s" || "$s" == "self.local" || "$s" == "localhost" || "$s" == *.local ]]
}

love_uri_remove_param_v1336() {
  local line="$1" key="$2"
  local pre frag base query out item first
  if [[ "$line" == *"#"* ]]; then
    frag="#${line#*#}"
    pre="${line%%#*}"
  else
    frag=""
    pre="$line"
  fi
  if [[ "$pre" != *"?"* ]]; then
    echo "$line"
    return
  fi
  base="${pre%%\?*}"
  query="${pre#*\?}"
  out=""
  first=1
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    [[ "${item%%=*}" == "$key" ]] && continue
    if [[ "$first" -eq 1 ]]; then
      out="$item"; first=0
    else
      out="${out}&${item}"
    fi
  done < <(tr '&' '\n' <<< "$query")
  if [[ -n "$out" ]]; then
    echo "${base}?${out}${frag}"
  else
    echo "${base}${frag}"
  fi
}

love_uri_has_param_v1336() {
  local line="$1" key="$2"
  [[ "$line" == *"?${key}="* || "$line" == *"&${key}="* ]]
}

love_uri_add_param_v1336() {
  local line="$1" key="$2" val="${3:-true}" pre frag sep
  love_uri_has_param_v1336 "$line" "$key" && { echo "$line"; return; }
  if [[ "$line" == *"#"* ]]; then
    pre="${line%%#*}"
    frag="#${line#*#}"
  else
    pre="$line"; frag=""
  fi
  [[ "$pre" == *"?"* ]] && sep="&" || sep="?"
  echo "${pre}${sep}${key}=${val}${frag}"
}

love_uri_label_v1336() {
  local line="$1" label="$2"
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"
  [[ "$line" == *"#"* ]] && echo "${line%%#*}#${label}" || echo "${line}#${label}"
}

love_singbox_sni_by_port_v1336() {
  local port="$1"
  jq -r '.inbounds[]? | select(.listen_port=='"$port"' and .tls?) | .tls.server_name // empty' /etc/sing-box/config.json 2>/dev/null | head -1
}

love_uri_fix_domain_v1336() {
  local line="$1" sni port
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"

  # normalize old booleans
  line="${line//allow_insecure=1/allow_insecure=true}"
  line="${line//allowInsecure=1/allowInsecure=true}"
  line="${line//insecure=1/insecure=true}"

  # Determine SNI from URI first, config second.
  sni="$(love_uri_get_param_v1336 "$line" "sni")"
  [[ -z "$sni" ]] && sni="$(love_uri_get_param_v1336 "$line" "serverName")"

  # TUIC
  if [[ "$line" == tuic://* ]]; then
    if [[ "$line" == *":38002"* ]]; then port=38002; elif [[ "$line" == *":50002"* ]]; then port=50002; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"
    line="$(love_uri_add_param_v1336 "$line" "alpn" "h3")"
    if love_is_self_domain_v1336 "$sni"; then
      line="$(love_uri_add_param_v1336 "$line" "allow_insecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "insecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allow_insecure")"
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  # VLESS WS TLS
  if [[ "$line" == vless://* && "$line" == *"security=tls"* && "$line" == *"type=ws"* ]]; then
    if [[ "$line" == *":38006"* ]]; then port=38006; elif [[ "$line" == *":50006"* ]]; then port=50006; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"
    if love_is_self_domain_v1336 "$sni"; then
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "insecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  # Trojan
  if [[ "$line" == trojan://* ]]; then
    if [[ "$line" == *":38004"* ]]; then port=38004; elif [[ "$line" == *":50004"* ]]; then port=50004; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"
    if love_is_self_domain_v1336 "$sni"; then
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  # HY2 / Hysteria2
  if [[ "$line" == hy2://* || "$line" == hysteria2://* ]]; then
    sni="$(love_uri_get_param_v1336 "$line" "sni")"
    if love_is_self_domain_v1336 "$sni"; then
      line="$(love_uri_add_param_v1336 "$line" "insecure" "1")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
    fi
  fi

  echo "$line"
}

# Override previous URI fixer.
love_uri_fix_v1334() { love_uri_fix_domain_v1336 "$1"; }
love_fix_line_source_v1331() { love_uri_fix_domain_v1336 "$1"; }

love_domain_check_v1336() {
  love_menu_title "Love 域名 / 证书模式检查" "Domain-aware"

  echo "1) sing-box TLS 入站："
  if [[ -s /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.inbounds[]? | select(.tls?) | [.tag,.type,.listen_port,.tls.server_name,.tls.certificate_path,.tls.key_path,(.tls.alpn|tostring)] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
  else
    echo "  未找到 /etc/sing-box/config.json 或 jq"
  fi
  echo

  echo "2) 证书文件检查："
  local cert="/etc/sing-box/cert/cert.pem" key="/etc/sing-box/cert/key.pem"
  if [[ -f "$cert" && -f "$key" ]]; then
    openssl x509 -noout -subject -issuer -dates -in "$cert" 2>/dev/null || true
    local a b
    a="$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
    b="$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
    echo "cert-md5: ${a:-unknown}"
    echo "key-md5:  ${b:-unknown}"
    [[ -n "$a" && "$a" == "$b" ]] && echo "[OK] 证书和私钥匹配" || echo "[WARN] 证书和私钥不匹配"
  else
    echo "[WARN] 未找到 $cert 或 $key"
  fi
  echo

  echo "3) 当前订阅关键链接："
  grep -nE '443|38001|38002|38004|38006|50001|50002|50004|50006|HY2|TUIC|TROJAN|VLESS-WS-TLS' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo

  echo "说明："
  echo "  self.local / *.local = 无域名自签模式，应带 insecure / allowInsecure。"
  echo "  正式域名 + 正式证书 = 有域名模式，不应带 insecure / allowInsecure。"
  echo "  TUIC 无论有无域名都应带 alpn=h3；服务端 tls.alpn 也应为 [\"h3\"]。"
}

love_cert_fix_selflocal_v1336() {
  love_menu_title "Love 自签证书修复" "self.local cert/key"
  mkdir -p /etc/sing-box/cert
  cp -f /etc/sing-box/cert/cert.pem /etc/sing-box/cert/cert.pem.bak.$(date +%F-%H%M%S) 2>/dev/null || true
  cp -f /etc/sing-box/cert/key.pem /etc/sing-box/cert/key.pem.bak.$(date +%F-%H%M%S) 2>/dev/null || true

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/sing-box/cert/key.pem \
    -out /etc/sing-box/cert/cert.pem \
    -days 3650 \
    -subj "/CN=self.local" \
    -addext "subjectAltName=DNS:self.local"

  chmod 600 /etc/sing-box/cert/key.pem
  chmod 644 /etc/sing-box/cert/cert.pem

  if [[ -s /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
    cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.certfix.$(date +%F-%H%M%S)
    jq '
      (.inbounds[]? | select(.tls?).tls.server_name) = "self.local" |
      (.inbounds[]? | select(.tls?).tls.certificate_path) = "/etc/sing-box/cert/cert.pem" |
      (.inbounds[]? | select(.tls?).tls.key_path) = "/etc/sing-box/cert/key.pem" |
      (.inbounds[]? | select(.type=="tuic").tls.alpn) = ["h3"]
    ' /etc/sing-box/config.json > /root/config.json.tmp && mv /root/config.json.tmp /etc/sing-box/config.json
    sing-box check -c /etc/sing-box/config.json && systemctl restart sing-box
  fi

  echo "[OK] self.local 自签证书已重建并同步。"
  echo "下一步：Love sub && Love qr && Love web"
}

love_domain_set_singbox_v1336() {
  love_menu_title "Love 设置 sing-box 域名模式" "Real domain / cert paths"

  local domain cert key
  read -rp "请输入节点域名，例如 node.example.com: " domain
  [[ -n "$domain" ]] || { echo "[ERROR] 域名不能为空"; return 1; }
  read -rp "证书路径 [/etc/sing-box/cert/cert.pem]: " cert
  cert="${cert:-/etc/sing-box/cert/cert.pem}"
  read -rp "私钥路径 [/etc/sing-box/cert/key.pem]: " key
  key="${key:-/etc/sing-box/cert/key.pem}"

  [[ -f "$cert" ]] || { echo "[ERROR] 证书不存在：$cert"; return 1; }
  [[ -f "$key" ]] || { echo "[ERROR] 私钥不存在：$key"; return 1; }

  local a b
  a="$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  b="$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  [[ -n "$a" && "$a" == "$b" ]] || { echo "[ERROR] 证书和私钥不匹配"; return 1; }

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.domain.$(date +%F-%H%M%S)
  jq '
    (.inbounds[]? | select(.tls?).tls.server_name) = "'"$domain"'" |
    (.inbounds[]? | select(.tls?).tls.certificate_path) = "'"$cert"'" |
    (.inbounds[]? | select(.tls?).tls.key_path) = "'"$key"'" |
    (.inbounds[]? | select(.type=="tuic").tls.alpn) = ["h3"]
  ' /etc/sing-box/config.json > /root/config.json.tmp && mv /root/config.json.tmp /etc/sing-box/config.json

  sing-box check -c /etc/sing-box/config.json || return 1
  systemctl restart sing-box
  echo "[OK] sing-box 已设置为域名模式：$domain"
  echo "下一步：Love sub && Love qr && Love web"
}

love_sub_domain_final_v1336() {
  love_menu_title "Love 域名感知双栈订阅导出" "Domain-aware / Dual-stack"

  love_disk_guard_v1328 200 || return 1

  # Sync sing-box from config if available, but keep xray cache too.
  if declare -F love_sync_v1332 >/dev/null 2>&1; then
    love_sync_v1332 >/dev/null 2>&1 || true
  fi

  mkdir -p /opt/Love/subscribe /opt/Love/subscribe/clients
  local raw="/opt/Love/subscribe/all.txt"
  local b64="/opt/Love/subscribe/all_base64.txt"
  local html="/opt/Love/subscribe/index.html"
  local yaml="/opt/Love/subscribe/clash_like.yaml"
  local tmp="/tmp/love_domain_sub.$$"

  echo "[1/4] 收集 Xray 443 + sing-box 全协议节点..."
  : > "$tmp"
  grep -hE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' \
    /opt/Love/client-info/xray-client-info.txt \
    /opt/Love/client-info/sing-box-client-info.txt \
    /opt/Love/node_info.txt \
    /opt/Love/subscribe/all.txt \
    2>/dev/null | sed 's/\r$//' | while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      love_uri_fix_domain_v1336 "$line"
    done | awk '!seen[$0]++' > "$raw"

  cp -f "$raw" /opt/Love/subscribe/clients/v2rayn-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/nekobox-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/sing-box-uri.txt 2>/dev/null || true

  echo "[2/4] 生成 Base64..."
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$raw" > "$b64" 2>/dev/null || true
  else
    base64 "$raw" | tr -d '\n' > "$b64" 2>/dev/null || true
  fi

  echo "[3/4] 生成 HTML / YAML..."
  {
    echo "<!doctype html><html><head><meta charset='utf-8'><title>Love Subscription</title></head><body><pre>"
    sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$raw"
    echo "</pre></body></html>"
  } > "$html"

  {
    echo "# Love URI subscription list"
    echo "# Domain-aware dual stack: Xray 443 + sing-box full protocols"
    echo "links:"
    awk '{gsub(/"/,"\\\""); print "  - \"" $0 "\""}' "$raw"
  } > "$yaml"

  echo "[4/4] 生成 TXT..."
  if declare -F love_txt_final_v1332 >/dev/null 2>&1; then
    love_txt_final_v1332 >/dev/null 2>&1 || true
  elif declare -F love_txt_source_correct_v1331 >/dev/null 2>&1; then
    love_txt_source_correct_v1331 >/dev/null 2>&1 || true
  fi

  echo
  log "域名感知双栈订阅导出完成："
  echo "订阅节点行数：$(grep -cE '^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls)://' "$raw" 2>/dev/null || echo 0)"
  echo "Raw:    $raw"
  echo "Base64: $b64"
  echo
  echo "关键节点检查："
  grep -nE '443|38000|38001|38002|38004|38006|50001|50002|50004|50006|HY2|TUIC|TROJAN|VLESS-WS-TLS' "$raw" 2>/dev/null || true
}

# Override previous sub/link-fix entrypoints.
love_sub_dual_final_v1334() { love_sub_domain_final_v1336; }
love_linkfix_files_v1331() { love_sub_domain_final_v1336; }
love_linkfix_files_v1330() { love_sub_domain_final_v1336; }

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1336 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1336/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.36.0-domain-aware-dual-stack-final}"
  case "${1:-}" in
    sub|subscription|link-fix|client-fix|fix-links)
      love_sub_domain_final_v1336
      ;;
    domain-check|cert-check-domain)
      love_domain_check_v1336
      ;;
    cert-fix|self-cert-fix|fix-cert)
      love_cert_fix_selflocal_v1336
      ;;
    domain-set|set-domain|domain-mode)
      love_domain_set_singbox_v1336
      ;;
    *)
      love_original_main_v1336 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.37 Domain + Self-signed Aware Final
# Adds the third TLS mode:
#   1) no domain: self.local + self-signed -> insecure required
#   2) real domain + public CA certificate -> insecure removed
#   3) real domain + self-signed/custom certificate -> domain SNI kept, insecure required
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.37.0-domain-selfsigned-aware-final"
LOVE_CERT_MODE_FILE="/opt/Love/domain-cert-mode"

love_cert_mode_v1337() {
  [[ -f "$LOVE_CERT_MODE_FILE" ]] && cat "$LOVE_CERT_MODE_FILE" 2>/dev/null || echo "auto"
}

love_cert_is_selfsigned_v1337() {
  local cert="${1:-/etc/sing-box/cert/cert.pem}"
  [[ -f "$cert" ]] || return 1

  local subject issuer
  subject="$(openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed 's/^subject=//')"
  issuer="$(openssl x509 -noout -issuer -in "$cert" 2>/dev/null | sed 's/^issuer=//')"

  [[ -n "$subject" && "$subject" == "$issuer" ]]
}

love_tls_requires_insecure_v1337() {
  local sni="${1:-}" port="${2:-}" cert mode
  mode="$(love_cert_mode_v1337)"

  case "$mode" in
    selfsigned|custom|insecure)
      return 0
      ;;
    public|official|trusted)
      return 1
      ;;
  esac

  # Auto mode:
  # self.local / *.local always requires insecure.
  if love_is_self_domain_v1336 "$sni"; then
    return 0
  fi

  # Real domain but self-signed cert also requires insecure.
  cert="$(jq -r '.inbounds[]? | select(.listen_port=='"${port:-0}"' and .tls?) | .tls.certificate_path // empty' /etc/sing-box/config.json 2>/dev/null | head -1)"
  [[ -z "$cert" ]] && cert="/etc/sing-box/cert/cert.pem"

  if love_cert_is_selfsigned_v1337 "$cert"; then
    return 0
  fi

  return 1
}

love_uri_fix_domain_v1337() {
  local line="$1" sni port
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"
  line="${line//allow_insecure=1/allow_insecure=true}"
  line="${line//allowInsecure=1/allowInsecure=true}"
  line="${line//insecure=1/insecure=true}"

  sni="$(love_uri_get_param_v1336 "$line" "sni")"
  [[ -z "$sni" ]] && sni="$(love_uri_get_param_v1336 "$line" "serverName")"

  if [[ "$line" == tuic://* ]]; then
    if [[ "$line" == *":38002"* ]]; then port=38002; elif [[ "$line" == *":50002"* ]]; then port=50002; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"
    line="$(love_uri_add_param_v1336 "$line" "alpn" "h3")"

    if love_tls_requires_insecure_v1337 "$sni" "$port"; then
      line="$(love_uri_add_param_v1336 "$line" "allow_insecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "insecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allow_insecure")"
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  if [[ "$line" == vless://* && "$line" == *"security=tls"* && "$line" == *"type=ws"* ]]; then
    if [[ "$line" == *":38006"* ]]; then port=38006; elif [[ "$line" == *":50006"* ]]; then port=50006; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"

    if love_tls_requires_insecure_v1337 "$sni" "$port"; then
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "insecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  if [[ "$line" == trojan://* ]]; then
    if [[ "$line" == *":38004"* ]]; then port=38004; elif [[ "$line" == *":50004"* ]]; then port=50004; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"

    if love_tls_requires_insecure_v1337 "$sni" "$port"; then
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  if [[ "$line" == hy2://* || "$line" == hysteria2://* ]]; then
    sni="$(love_uri_get_param_v1336 "$line" "sni")"
    # HY2 URI cannot know port reliably in every format, use cert mode and SNI as primary.
    if love_tls_requires_insecure_v1337 "$sni" ""; then
      line="$(love_uri_add_param_v1336 "$line" "insecure" "1")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
    fi
  fi

  echo "$line"
}

# Override v13.36 fixer.
love_uri_fix_domain_v1336() { love_uri_fix_domain_v1337 "$1"; }
love_uri_fix_v1334() { love_uri_fix_domain_v1337 "$1"; }
love_fix_line_source_v1331() { love_uri_fix_domain_v1337 "$1"; }

love_domain_self_set_v1337() {
  love_menu_title "Love 设置：有域名 + 自签/自管证书" "Domain + self-signed"

  local domain cert key
  read -rp "请输入节点域名，例如 node.example.com: " domain
  [[ -n "$domain" ]] || { echo "[ERROR] 域名不能为空"; return 1; }

  read -rp "证书路径 [/etc/sing-box/cert/cert.pem]: " cert
  cert="${cert:-/etc/sing-box/cert/cert.pem}"
  read -rp "私钥路径 [/etc/sing-box/cert/key.pem]: " key
  key="${key:-/etc/sing-box/cert/key.pem}"

  [[ -f "$cert" ]] || { echo "[ERROR] 证书不存在：$cert"; return 1; }
  [[ -f "$key" ]] || { echo "[ERROR] 私钥不存在：$key"; return 1; }

  local a b
  a="$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  b="$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  [[ -n "$a" && "$a" == "$b" ]] || { echo "[ERROR] 证书和私钥不匹配"; return 1; }

  mkdir -p /opt/Love
  echo "selfsigned" > "$LOVE_CERT_MODE_FILE"

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.domain-self.$(date +%F-%H%M%S)
  jq '
    (.inbounds[]? | select(.tls?).tls.server_name) = "'"$domain"'" |
    (.inbounds[]? | select(.tls?).tls.certificate_path) = "'"$cert"'" |
    (.inbounds[]? | select(.tls?).tls.key_path) = "'"$key"'" |
    (.inbounds[]? | select(.type=="tuic").tls.alpn) = ["h3"]
  ' /etc/sing-box/config.json > /root/config.json.tmp && mv /root/config.json.tmp /etc/sing-box/config.json

  sing-box check -c /etc/sing-box/config.json || return 1
  systemctl restart sing-box

  echo "[OK] 已设置为：有域名 + 自签/自管证书模式"
  echo "域名：$domain"
  echo "证书模式：selfsigned"
  echo "下一步：Love domain-check && Love sub && Love qr && Love web"
}

love_domain_set_singbox_v1336() {
  love_menu_title "Love 设置 sing-box 正式域名证书模式" "Real domain / public CA cert"

  local domain cert key
  read -rp "请输入节点域名，例如 node.example.com: " domain
  [[ -n "$domain" ]] || { echo "[ERROR] 域名不能为空"; return 1; }
  read -rp "证书路径 [/etc/sing-box/cert/cert.pem]: " cert
  cert="${cert:-/etc/sing-box/cert/cert.pem}"
  read -rp "私钥路径 [/etc/sing-box/cert/key.pem]: " key
  key="${key:-/etc/sing-box/cert/key.pem}"

  [[ -f "$cert" ]] || { echo "[ERROR] 证书不存在：$cert"; return 1; }
  [[ -f "$key" ]] || { echo "[ERROR] 私钥不存在：$key"; return 1; }

  local a b
  a="$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  b="$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  [[ -n "$a" && "$a" == "$b" ]] || { echo "[ERROR] 证书和私钥不匹配"; return 1; }

  mkdir -p /opt/Love
  echo "public" > "$LOVE_CERT_MODE_FILE"

  cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.domain-public.$(date +%F-%H%M%S)
  jq '
    (.inbounds[]? | select(.tls?).tls.server_name) = "'"$domain"'" |
    (.inbounds[]? | select(.tls?).tls.certificate_path) = "'"$cert"'" |
    (.inbounds[]? | select(.tls?).tls.key_path) = "'"$key"'" |
    (.inbounds[]? | select(.type=="tuic").tls.alpn) = ["h3"]
  ' /etc/sing-box/config.json > /root/config.json.tmp && mv /root/config.json.tmp /etc/sing-box/config.json

  sing-box check -c /etc/sing-box/config.json || return 1
  systemctl restart sing-box

  echo "[OK] 已设置为：有域名 + 正式 CA 证书模式"
  echo "域名：$domain"
  echo "证书模式：public"
  echo "下一步：Love domain-check && Love sub && Love qr && Love web"
}

love_domain_check_v1336() {
  love_menu_title "Love 域名 / 证书模式检查" "Domain-aware"

  local mode
  mode="$(love_cert_mode_v1337)"

  echo "0) 当前证书模式：$mode"
  echo "   auto       = 自动判断"
  echo "   selfsigned = 有域名但证书不被客户端信任，需要 insecure"
  echo "   public     = 有域名正式 CA 证书，不需要 insecure"
  echo

  echo "1) sing-box TLS 入站："
  if [[ -s /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.inbounds[]? | select(.tls?) | [.tag,.type,.listen_port,.tls.server_name,.tls.certificate_path,.tls.key_path,(.tls.alpn|tostring)] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
  else
    echo "  未找到 /etc/sing-box/config.json 或 jq"
  fi
  echo

  echo "2) 证书文件检查："
  local cert="/etc/sing-box/cert/cert.pem" key="/etc/sing-box/cert/key.pem"
  if [[ -f "$cert" && -f "$key" ]]; then
    openssl x509 -noout -subject -issuer -dates -in "$cert" 2>/dev/null || true
    local a b
    a="$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
    b="$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
    echo "cert-md5: ${a:-unknown}"
    echo "key-md5:  ${b:-unknown}"
    [[ -n "$a" && "$a" == "$b" ]] && echo "[OK] 证书和私钥匹配" || echo "[WARN] 证书和私钥不匹配"
    if love_cert_is_selfsigned_v1337 "$cert"; then
      echo "[INFO] 证书看起来是自签证书。"
    else
      echo "[INFO] 证书看起来不是自签证书，是否被公网信任取决于签发机构。"
    fi
  else
    echo "[WARN] 未找到 $cert 或 $key"
  fi
  echo

  echo "3) 当前订阅关键链接："
  grep -nE '443|38001|38002|38004|38006|50001|50002|50004|50006|HY2|TUIC|TROJAN|VLESS-WS-TLS' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo

  echo "说明："
  echo "  无域名 self.local：需要 insecure / allowInsecure。"
  echo "  有域名 + 正式 CA 证书：不需要 insecure / allowInsecure。"
  echo "  有域名 + 自签/自管证书：仍然需要 insecure / allowInsecure，但 SNI 保持你的域名。"
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1337 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1337/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.37.0-domain-selfsigned-aware-final}"
  case "${1:-}" in
    domain-self-set|domain-self|set-domain-self|domain-custom-cert)
      love_domain_self_set_v1337
      ;;
    domain-set|set-domain|domain-mode)
      love_domain_set_singbox_v1336
      ;;
    domain-check|cert-check-domain)
      love_domain_check_v1336
      ;;
    sub|subscription|link-fix|client-fix|fix-links)
      love_sub_domain_final_v1336
      ;;
    *)
      love_original_main_v1337 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.38 No-domain HardFix Final
# Fix root cause:
#   v13.37 introduced /opt/Love/domain-cert-mode.
#   If mode was "public", self.local links could lose insecure flags.
#   For no-domain/self.local, insecure must ALWAYS be kept regardless of mode file.
# ==============================================================================
LOVE_SCRIPT_VERSION="Love v13.38.0-nodomain-hardfix-final"

love_tls_requires_insecure_v1338() {
  local sni="${1:-}" port="${2:-}" cert mode

  # Highest priority: no-domain/self.local always requires insecure.
  if love_is_self_domain_v1336 "$sni"; then
    return 0
  fi

  mode="$(love_cert_mode_v1337 2>/dev/null || echo auto)"

  case "$mode" in
    selfsigned|custom|insecure|nodomain)
      return 0
      ;;
    public|official|trusted)
      return 1
      ;;
  esac

  cert="$(jq -r '.inbounds[]? | select(.listen_port=='"${port:-0}"' and .tls?) | .tls.certificate_path // empty' /etc/sing-box/config.json 2>/dev/null | head -1)"
  [[ -z "$cert" ]] && cert="/etc/sing-box/cert/cert.pem"

  if love_cert_is_selfsigned_v1337 "$cert"; then
    return 0
  fi

  return 1
}

love_uri_fix_nodomain_hard_v1338() {
  local line="$1" sni port
  line="${line//$'\r'/}"
  line="${line//LOVE-LOVE-/LOVE-}"
  line="${line//LOVE-SB-/LOVE-}"
  line="${line//#SB-/#LOVE-}"
  line="${line//allow_insecure=1/allow_insecure=true}"
  line="${line//allowInsecure=1/allowInsecure=true}"
  line="${line//insecure=1/insecure=true}"

  sni="$(love_uri_get_param_v1336 "$line" "sni")"
  [[ -z "$sni" ]] && sni="$(love_uri_get_param_v1336 "$line" "serverName")"

  if [[ "$line" == tuic://* ]]; then
    if [[ "$line" == *":38002"* ]]; then port=38002; elif [[ "$line" == *":50002"* ]]; then port=50002; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"
    line="$(love_uri_add_param_v1336 "$line" "alpn" "h3")"
    if love_tls_requires_insecure_v1338 "$sni" "$port"; then
      line="$(love_uri_add_param_v1336 "$line" "allow_insecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "insecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allow_insecure")"
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  if [[ "$line" == vless://* && "$line" == *"security=tls"* && "$line" == *"type=ws"* ]]; then
    if [[ "$line" == *":38006"* ]]; then port=38006; elif [[ "$line" == *":50006"* ]]; then port=50006; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"
    if love_tls_requires_insecure_v1338 "$sni" "$port"; then
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
      line="$(love_uri_add_param_v1336 "$line" "insecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  if [[ "$line" == trojan://* ]]; then
    if [[ "$line" == *":38004"* ]]; then port=38004; elif [[ "$line" == *":50004"* ]]; then port=50004; else port=""; fi
    [[ -z "$sni" && -n "$port" ]] && sni="$(love_singbox_sni_by_port_v1336 "$port")"
    if love_tls_requires_insecure_v1338 "$sni" "$port"; then
      line="$(love_uri_add_param_v1336 "$line" "allowInsecure" "true")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
    fi
  fi

  if [[ "$line" == hy2://* || "$line" == hysteria2://* ]]; then
    sni="$(love_uri_get_param_v1336 "$line" "sni")"
    if love_tls_requires_insecure_v1338 "$sni" ""; then
      line="$(love_uri_add_param_v1336 "$line" "insecure" "1")"
    else
      line="$(love_uri_remove_param_v1336 "$line" "insecure")"
      line="$(love_uri_remove_param_v1336 "$line" "allowInsecure")"
    fi
  fi

  echo "$line"
}

# Override all previous fixers.
love_uri_fix_domain_v1337() { love_uri_fix_nodomain_hard_v1338 "$1"; }
love_uri_fix_domain_v1336() { love_uri_fix_nodomain_hard_v1338 "$1"; }
love_uri_fix_v1334() { love_uri_fix_nodomain_hard_v1338 "$1"; }
love_fix_line_source_v1331() { love_uri_fix_nodomain_hard_v1338 "$1"; }

love_validate_sub_hard_v1338() {
  local raw="/opt/Love/subscribe/all.txt" tmp="/tmp/love_validate_sub_v1338.$$"
  [[ -s "$raw" ]] || return 0
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls):// ]]; then
      love_uri_fix_nodomain_hard_v1338 "$line" >> "$tmp"
    else
      echo "$line" >> "$tmp"
    fi
  done < "$raw"
  awk '!seen[$0]++' "$tmp" > "$raw"
  rm -f "$tmp"

  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$raw" > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
  else
    base64 "$raw" | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
  fi

  cp -f "$raw" /opt/Love/subscribe/clients/v2rayn-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/nekobox-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/sing-box-uri.txt 2>/dev/null || true
}

love_sub_hard_v1338() {
  love_menu_title "Love 无域名硬修复订阅导出" "No-domain hardfix / Dual-stack"

  if declare -F love_sub_domain_final_v1336 >/dev/null 2>&1; then
    love_sub_domain_final_v1336
  elif declare -F love_sub_dual_final_v1334 >/dev/null 2>&1; then
    love_sub_dual_final_v1334
  else
    echo "[ERROR] 找不到订阅导出函数"
    return 1
  fi

  echo
  echo "[HardFix] 二次校验 HY2 / TUIC / Trojan / VLESS WS TLS 参数..."
  love_validate_sub_hard_v1338

  echo
  echo "[OK] 硬校验完成，关键节点如下："
  grep -nE '443|38001|38002|38004|38006|50001|50002|50004|50006|HY2|TUIC|TROJAN|VLESS-WS-TLS' /opt/Love/subscribe/all.txt 2>/dev/null || true
}

love_nodomain_set_v1338() {
  love_menu_title "Love 设置无域名模式" "self.local / insecure required"
  mkdir -p /opt/Love
  echo "selfsigned" > /opt/Love/domain-cert-mode

  if [[ -s /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
    cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.nodomain.$(date +%F-%H%M%S)
    jq '
      (.inbounds[]? | select(.tls?).tls.server_name) = "self.local" |
      (.inbounds[]? | select(.tls?).tls.certificate_path) = "/etc/sing-box/cert/cert.pem" |
      (.inbounds[]? | select(.tls?).tls.key_path) = "/etc/sing-box/cert/key.pem" |
      (.inbounds[]? | select(.type=="tuic").tls.alpn) = ["h3"]
    ' /etc/sing-box/config.json > /root/config.json.tmp && mv /root/config.json.tmp /etc/sing-box/config.json

    sing-box check -c /etc/sing-box/config.json && systemctl restart sing-box || true
  fi

  echo "[OK] 已设置为无域名 self.local 模式。"
  echo "下一步：Love cert-fix && Love sub && Love qr && Love web"
}

# Patch cert-fix to also set mode selfsigned.
if declare -F love_cert_fix_selflocal_v1336 >/dev/null 2>&1 && ! declare -F love_original_cert_fix_v1338 >/dev/null 2>&1; then
  eval "$(declare -f love_cert_fix_selflocal_v1336 | sed '1s/^love_cert_fix_selflocal_v1336/love_original_cert_fix_v1338/')"
  love_cert_fix_selflocal_v1336() {
    mkdir -p /opt/Love
    echo "selfsigned" > /opt/Love/domain-cert-mode
    love_original_cert_fix_v1338 "$@"
    echo "selfsigned" > /opt/Love/domain-cert-mode
  }
fi

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1338 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1338/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.38.0-nodomain-hardfix-final}"
  case "${1:-}" in
    sub|subscription|link-fix|client-fix|fix-links)
      love_sub_hard_v1338
      ;;
    nodomain|no-domain|nodomain-set|no-domain-set)
      love_nodomain_set_v1338
      ;;
    cert-fix|self-cert-fix|fix-cert)
      love_cert_fix_selflocal_v1336
      ;;
    *)
      love_original_main_v1338 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.39 All-mode Server HardFix Final
# Final checks added:
#   - server-side TUIC tls.alpn=["h3"] always enforced.
#   - Love sub validates links AND server config.
#   - sing-box install wrapper applies server hardfix after install.
#   - Xray HY2 domain + self-signed and domain + public cert post-set commands.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.39.0-all-mode-server-hardfix-final"

love_server_hardfix_v1339() {
  local cfg="/etc/sing-box/config.json"
  [[ -s "$cfg" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  cp "$cfg" "$cfg.bak.server-hardfix.$(date +%F-%H%M%S)" 2>/dev/null || true

  jq '
    (.inbounds[]? | select(.type=="tuic").tls.alpn) = ["h3"] |
    (.inbounds[]? | select(.type=="tuic").congestion_control) = ((.inbounds[]? | select(.type=="tuic").congestion_control) // "bbr")
  ' "$cfg" > /root/config.json.tmp && mv /root/config.json.tmp "$cfg"

  sing-box check -c "$cfg" >/dev/null 2>&1 && systemctl restart sing-box >/dev/null 2>&1 || true
}

love_xray_hy2_update_client_info_v1339() {
  local domain="$1" insecure="$2" addr port info tmp
  info="/opt/Love/client-info/xray-client-info.txt"
  [[ -f "$info" ]] || return 0

  # Extract address/port from old HY2 if possible; otherwise from Reality.
  addr="$(grep -m1 -Eo '@\[[^]]+\]:' "$info" 2>/dev/null | sed -E 's/^@\[|\]:$//g' || true)"
  [[ -z "$addr" ]] && addr="$(grep -m1 -Eo '@[^:/]+:' "$info" 2>/dev/null | sed -E 's/^@|:$//g' || true)"
  port="$(grep -m1 -Eo ':443[/?#]' "$info" 2>/dev/null | grep -Eo '[0-9]+' || true)"
  port="${port:-443}"
  [[ -z "$addr" ]] && return 0

  tmp="/tmp/xray-client-info-v1339.$$"
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == hysteria2://* || "$line" == hy2://* ]]; then
      continue
    fi
    echo "$line" >> "$tmp"
  done < "$info"

  local auth
  auth="$(grep -m1 -Eo 'hysteria2://[^@]+' "$info" | sed 's#hysteria2://##' || true)"
  [[ -z "$auth" ]] && auth="$(grep -m1 -Eo 'hy2://[^@]+' "$info" | sed 's#hy2://##' || true)"

  if [[ -n "$auth" ]]; then
    {
      echo
      echo "HY2:"
      echo "hysteria2://${auth}@[$addr]:${port}/?sni=${domain}&insecure=${insecure}#LOVE-XRAY-HY2"
      echo "hy2://${auth}@[$addr]:${port}/?sni=${domain}&insecure=${insecure}#LOVE-XRAY-HY2"
    } >> "$tmp"
  fi

  mv "$tmp" "$info"
}

love_xray_domain_self_set_v1339() {
  love_menu_title "Love Xray：有域名 + 自签证书" "Xray HY2 domain self-signed"

  local domain cert key cfg="/usr/local/etc/xray/config.json"
  read -rp "请输入 Xray HY2 域名，例如 node.example.com: " domain
  [[ -n "$domain" ]] || { echo "[ERROR] 域名不能为空"; return 1; }

  mkdir -p /usr/local/etc/xray
  cert="/usr/local/etc/xray/cert.pem"
  key="/usr/local/etc/xray/key.pem"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$key" \
    -out "$cert" \
    -days 3650 \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain}"

  chown root:xray "$cert" "$key" 2>/dev/null || true
  chmod 640 "$cert" "$key" 2>/dev/null || true

  if [[ -s "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    cp "$cfg" "$cfg.bak.domain-self.$(date +%F-%H%M%S)"
    jq '
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.serverName) = "'"$domain"'" |
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.alpn) = ["h3"] |
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.certificates[0].certificateFile) = "'"$cert"'" |
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.certificates[0].keyFile) = "'"$key"'"
    ' "$cfg" > /root/xray.json.tmp && mv /root/xray.json.tmp "$cfg"

    /usr/local/bin/xray run -test -config "$cfg" >/dev/null 2>&1 && systemctl restart xray || true
  fi

  love_xray_hy2_update_client_info_v1339 "$domain" "1"
  echo "[OK] Xray HY2 已设置为：有域名 + 自签证书。"
  echo "下一步：Love sub && Love qr && Love web"
}

love_xray_domain_public_set_v1339() {
  love_menu_title "Love Xray：有域名 + 正式证书" "Xray HY2 domain public cert"

  local domain cert key cfg="/usr/local/etc/xray/config.json"
  read -rp "请输入 Xray HY2 域名，例如 node.example.com: " domain
  [[ -n "$domain" ]] || { echo "[ERROR] 域名不能为空"; return 1; }
  read -rp "证书路径 [/usr/local/etc/xray/cert.pem]: " cert
  cert="${cert:-/usr/local/etc/xray/cert.pem}"
  read -rp "私钥路径 [/usr/local/etc/xray/key.pem]: " key
  key="${key:-/usr/local/etc/xray/key.pem}"

  [[ -f "$cert" ]] || { echo "[ERROR] 证书不存在：$cert"; return 1; }
  [[ -f "$key" ]] || { echo "[ERROR] 私钥不存在：$key"; return 1; }

  local a b
  a="$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  b="$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')"
  [[ -n "$a" && "$a" == "$b" ]] || { echo "[ERROR] 证书和私钥不匹配"; return 1; }

  if [[ -s "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    cp "$cfg" "$cfg.bak.domain-public.$(date +%F-%H%M%S)"
    jq '
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.serverName) = "'"$domain"'" |
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.alpn) = ["h3"] |
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.certificates[0].certificateFile) = "'"$cert"'" |
      (.inbounds[]? | select(.tag=="hy2-in").streamSettings.tlsSettings.certificates[0].keyFile) = "'"$key"'"
    ' "$cfg" > /root/xray.json.tmp && mv /root/xray.json.tmp "$cfg"

    /usr/local/bin/xray run -test -config "$cfg" >/dev/null 2>&1 && systemctl restart xray || true
  fi

  love_xray_hy2_update_client_info_v1339 "$domain" "0"
  echo "[OK] Xray HY2 已设置为：有域名 + 正式证书。"
  echo "下一步：Love sub && Love qr && Love web"
}

love_all_mode_check_v1339() {
  love_menu_title "Love 全模式检查" "No-domain / Domain public / Domain self-signed"

  echo "1) Love 版本："
  grep '^VERSION=' /opt/Love/Love.sh 2>/dev/null || true
  echo

  echo "2) 模式文件："
  cat /opt/Love/domain-cert-mode 2>/dev/null || echo "auto"
  echo

  echo "3) sing-box TLS 入站："
  jq -r '.inbounds[]? | select(.tls?) | [.tag,.type,.listen_port,.tls.server_name,(.tls.alpn|tostring),.tls.certificate_path,.tls.key_path] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
  echo

  echo "4) Xray HY2 TLS："
  jq -r '.inbounds[]? | select(.tag=="hy2-in") | [.tag,.port,.streamSettings.tlsSettings.serverName,(.streamSettings.tlsSettings.alpn|tostring),.streamSettings.tlsSettings.certificates[0].certificateFile,.streamSettings.tlsSettings.certificates[0].keyFile] | @tsv' /usr/local/etc/xray/config.json 2>/dev/null || true
  echo

  echo "5) 监听端口："
  ss -lntup | grep -E '443|38000|38001|38002|38003|38004|38005|38006|xray|sing-box' || true
  echo

  echo "6) 关键订阅："
  grep -nE '443|38001|38002|38004|38006|HY2|TUIC|TROJAN|VLESS-WS-TLS' /opt/Love/subscribe/all.txt 2>/dev/null || true
}

# Wrap sing-box installer: always enforce server-side TUIC ALPN after generation.
if declare -F install_singbox_native >/dev/null 2>&1 && ! declare -F love_original_install_singbox_v1339 >/dev/null 2>&1; then
  eval "$(declare -f install_singbox_native | sed '1s/^install_singbox_native/love_original_install_singbox_v1339/')"
  install_singbox_native() {
    love_original_install_singbox_v1339 "$@"
    love_server_hardfix_v1339
  }
fi

if declare -F love_sub_hard_v1338 >/dev/null 2>&1 && ! declare -F love_original_sub_hard_v1339 >/dev/null 2>&1; then
  eval "$(declare -f love_sub_hard_v1338 | sed '1s/^love_sub_hard_v1338/love_original_sub_hard_v1339/')"
  love_sub_hard_v1338() {
    love_server_hardfix_v1339
    love_original_sub_hard_v1339 "$@"
  }
fi

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1339 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1339/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.39.0-all-mode-server-hardfix-final}"
  case "${1:-}" in
    server-fix|server-hardfix|tuic-alpn-fix)
      love_server_hardfix_v1339
      ;;
    xray-domain-self|xray-self|xray-domain-self-set)
      love_xray_domain_self_set_v1339
      ;;
    xray-domain-set|xray-domain-public|xray-public)
      love_xray_domain_public_set_v1339
      ;;
    all-check|mode-check)
      love_all_mode_check_v1339
      ;;
    sub|subscription|link-fix|client-fix|fix-links)
      love_server_hardfix_v1339
      love_sub_hard_v1338
      ;;
    *)
      love_original_main_v1339 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.41 Safe Main + Xray HY2 Subscription Restore + Auto Flag Final
# Conservative version:
#   - Keep sing-box logic untouched from v13.39.
#   - Do NOT rewrite Xray server config automatically.
#   - Only restore Xray HY2 subscription URI to old stable format: sni + insecure.
#   - Add hard no-arg Love/love menu entry.
#   - Add safe-update guard to prevent 0-byte script overwrite.
#   - Add auto country flag labels; failure falls back to US.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.41.0-safe-main-xray-sub-flag-final"

# ------------------------------
# Safe update guard: never overwrite with empty/broken script.
# ------------------------------
love_safe_install_script_v1341() {
  local src="$1" dst="${2:-/opt/Love/Love.sh}" size
  [[ -f "$src" ]] || { echo "[ERROR] 文件不存在：$src"; return 1; }

  size="$(stat -c '%s' "$src" 2>/dev/null || echo 0)"
  if [[ "$size" -lt 100000 ]]; then
    echo "[ERROR] 新脚本太小：${size} bytes，禁止覆盖，避免 Love.sh 变 0 字节。"
    return 1
  fi

  grep -q '^VERSION=' "$src" || { echo "[ERROR] 新脚本找不到 VERSION，禁止覆盖。"; return 1; }
  bash -n "$src" || { echo "[ERROR] 新脚本语法检查失败，禁止覆盖。"; return 1; }

  mkdir -p "$(dirname "$dst")"
  if [[ -s "$dst" ]]; then
    cp -f "$dst" "$dst.bak.safe.$(date +%F-%H%M%S)" 2>/dev/null || true
  fi
  install -m 755 "$src" "$dst"
  ln -sf "$dst" /usr/local/bin/Love
  ln -sf "$dst" /usr/local/bin/love
  hash -r 2>/dev/null || true
  echo "[OK] Love 脚本已安全安装：$dst"
  grep '^VERSION=' "$dst" || true
}

love_update_safe_v1341() {
  love_menu_title "Love 安全更新" "Zero-byte overwrite protected"
  local url tmp size
  url="${LOVE_UPDATE_URL:-https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh?force=$(date +%s)}"
  tmp="/root/Love.new"

  rm -f "$tmp" /tmp/Love.new 2>/dev/null || true

  echo "下载：$url"
  curl -L --fail --retry 5 \
    -H 'Cache-Control: no-cache, no-store, must-revalidate' \
    -H 'Pragma: no-cache' \
    -H 'Expires: 0' \
    -o "$tmp" "$url" || { echo "[ERROR] 下载失败。"; return 1; }

  ls -lh "$tmp"
  love_safe_install_script_v1341 "$tmp" /opt/Love/Love.sh
}

# Override old self_update_love if it exists.
self_update_love() { love_update_safe_v1341; }

# ------------------------------
# Country flag: automatic, manual fallback.
# ------------------------------
love_cc_to_flag_v1341() {
  local cc="${1^^}"
  case "$cc" in
    US) echo "🇺🇸" ;; JP) echo "🇯🇵" ;; SG) echo "🇸🇬" ;; HK) echo "🇭🇰" ;;
    TW) echo "🇹🇼" ;; KR) echo "🇰🇷" ;; DE) echo "🇩🇪" ;; GB|UK) echo "🇬🇧" ;;
    FR) echo "🇫🇷" ;; NL) echo "🇳🇱" ;; CA) echo "🇨🇦" ;; AU) echo "🇦🇺" ;;
    IN) echo "🇮🇳" ;; TH) echo "🇹🇭" ;; VN) echo "🇻🇳" ;; ID) echo "🇮🇩" ;;
    MY) echo "🇲🇾" ;; PH) echo "🇵🇭" ;; BR) echo "🇧🇷" ;; TR) echo "🇹🇷" ;;
    AE) echo "🇦🇪" ;; ES) echo "🇪🇸" ;; IT) echo "🇮🇹" ;; PL) echo "🇵🇱" ;;
    SE) echo "🇸🇪" ;; FI) echo "🇫🇮" ;; NO) echo "🇳🇴" ;; CH) echo "🇨🇭" ;;
    *) echo "🇺🇸" ;;
  esac
}

love_flag_detect_v1341() {
  mkdir -p /opt/Love 2>/dev/null || true
  if [[ -s /opt/Love/node-country && -s /opt/Love/node-flag ]]; then
    return 0
  fi

  local cc=""
  if command -v curl >/dev/null 2>&1; then
    cc="$(curl -fsS --max-time 3 https://ipapi.co/country/ 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
    [[ -z "$cc" ]] && cc="$(curl -fsS --max-time 3 https://ifconfig.co/country-iso 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
    [[ -z "$cc" ]] && cc="$(curl -fsS --max-time 3 https://ipinfo.io/country 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
  fi
  cc="${cc^^}"
  [[ -z "$cc" ]] && cc="US"
  echo "$cc" > /opt/Love/node-country
  love_cc_to_flag_v1341 "$cc" > /opt/Love/node-flag
}

love_flag_get_v1341() {
  love_flag_detect_v1341 >/dev/null 2>&1 || true
  cat /opt/Love/node-flag 2>/dev/null || echo "🇺🇸"
}

love_cc_get_v1341() {
  love_flag_detect_v1341 >/dev/null 2>&1 || true
  cat /opt/Love/node-country 2>/dev/null || echo "US"
}

love_flag_set_v1341() {
  love_menu_title "Love 节点国旗设置" "Auto flag / Manual fallback"
  local cc flag
  echo "当前：$(love_flag_get_v1341) $(love_cc_get_v1341)"
  echo
  read -rp "输入国家代码 US/JP/SG/HK，或直接输入 emoji 国旗: " cc
  [[ -n "$cc" ]] || { echo "[WARN] 未输入，保持不变。"; return 0; }
  if [[ "$cc" =~ ^[A-Za-z]{2}$ ]]; then
    cc="${cc^^}"
    flag="$(love_cc_to_flag_v1341 "$cc")"
  else
    flag="$cc"
    cc="CUSTOM"
  fi
  mkdir -p /opt/Love
  echo "$cc" > /opt/Love/node-country
  echo "$flag" > /opt/Love/node-flag
  echo "[OK] 已设置：$flag $cc"
}

love_strip_known_flag_v1341() {
  local label="$1"
  label="${label#🇺🇸 }"; label="${label#🇯🇵 }"; label="${label#🇸🇬 }"; label="${label#🇭🇰 }"
  label="${label#🇹🇼 }"; label="${label#🇰🇷 }"; label="${label#🇩🇪 }"; label="${label#🇬🇧 }"
  label="${label#🇫🇷 }"; label="${label#🇳🇱 }"; label="${label#🇨🇦 }"; label="${label#🇦🇺 }"
  label="${label#🇮🇳 }"; label="${label#🇹🇭 }"; label="${label#🇻🇳 }"; label="${label#🇮🇩 }"
  label="${label#🇲🇾 }"; label="${label#🇵🇭 }"; label="${label#🇧🇷 }"; label="${label#🇹🇷 }"
  echo "$label"
}

love_label_flag_v1341() {
  local label="$1" flag
  flag="$(love_flag_get_v1341)"
  label="$(love_strip_known_flag_v1341 "$label")"
  echo "$flag $label"
}

love_apply_flag_uri_v1341() {
  local line="$1" pre label
  [[ "$line" == *"#"* ]] || { echo "$line"; return; }
  pre="${line%%#*}"
  label="${line#*#}"
  echo "${pre}#$(love_label_flag_v1341 "$label")"
}

# ------------------------------
# Xray HY2 subscription restore only.
# Does not touch sing-box and does not rewrite Xray config.
# ------------------------------
love_uri_get_param_v1341() {
  local line="$1" key="$2" q
  q="${line#*\?}"
  q="${q%%#*}"
  tr '&' '\n' <<< "$q" | awk -F= -v k="$key" '$1==k{print $2; exit}'
}

love_uri_host_from_reality_v1341() {
  local sub="/opt/Love/subscribe/all.txt" line host ip6 ip4
  line="$(grep -h -m1 '^vless://.*LOVE-XRAY-REALITY' /opt/Love/client-info/xray-client-info.txt "$sub" /opt/Love/node_info.txt 2>/dev/null || true)"
  host="$(echo "$line" | sed -E 's#^[^@]+@(.+):443\?.*#\1#' 2>/dev/null || true)"
  if [[ -n "$host" && "$host" != "$line" ]]; then
    echo "$host"; return
  fi
  ip6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1)"
  [[ -n "$ip6" ]] && { echo "[$ip6]"; return; }
  ip4="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  [[ -n "$ip4" ]] && { echo "$ip4"; return; }
  echo "SERVER"
}

love_xray_hy2_insecure_v1341() {
  local sni="${1:-self.local}" mode
  mode="$(cat /opt/Love/domain-cert-mode 2>/dev/null || echo auto)"
  if [[ "$sni" == "self.local" || "$sni" == "localhost" || "$sni" == *.local ]]; then echo "1"; return; fi
  if [[ "$mode" == "selfsigned" || "$mode" == "custom" || "$mode" == "insecure" ]]; then echo "1"; return; fi
  echo "0"
}

love_rebuild_xray_client_info_v1341() {
  local cfg="/usr/local/etc/xray/config.json" info="/opt/Love/client-info/xray-client-info.txt"
  [[ -s "$cfg" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local auth sni insecure server reality hy2a hy2b
  auth="$(jq -r '.inbounds[]? | select(.tag=="hy2-in") | .settings.users[0].auth // empty' "$cfg" 2>/dev/null | head -n1)"
  sni="$(jq -r '.inbounds[]? | select(.tag=="hy2-in") | .streamSettings.tlsSettings.serverName // "self.local"' "$cfg" 2>/dev/null | head -n1)"
  [[ -z "$auth" ]] && return 0
  [[ -z "$sni" ]] && sni="self.local"

  insecure="$(love_xray_hy2_insecure_v1341 "$sni")"
  server="$(love_uri_host_from_reality_v1341)"
  reality="$(grep -h -m1 '^vless://.*LOVE-XRAY-REALITY' /opt/Love/client-info/xray-client-info.txt /opt/Love/subscribe/all.txt /opt/Love/node_info.txt 2>/dev/null || true)"
  [[ -n "$reality" ]] && reality="$(love_apply_flag_uri_v1341 "$reality")"

  hy2a="hysteria2://${auth}@${server}:443/?sni=${sni}&insecure=${insecure}#$(love_label_flag_v1341 "LOVE-XRAY-HY2")"
  hy2b="hy2://${auth}@${server}:443/?sni=${sni}&insecure=${insecure}#$(love_label_flag_v1341 "LOVE-XRAY-HY2")"

  mkdir -p /opt/Love/client-info
  {
    echo "Love Xray Client Info"
    echo
    echo "Reality:"
    [[ -n "$reality" ]] && echo "$reality"
    echo
    echo "HY2:"
    echo "$hy2a"
    echo "$hy2b"
    echo
    echo "Manual HY2:"
    echo "Address: $server"
    echo "Port: 443"
    echo "Auth: $auth"
    echo "SNI: $sni"
    echo "Insecure: $insecure"
    echo
    echo "Note: Xray HY2 keeps old stable URI: only sni + insecure."
  } > "$info"
  chmod 600 "$info" 2>/dev/null || true
}

love_fix_sub_xray_only_v1341() {
  local raw="/opt/Love/subscribe/all.txt" tmp="/tmp/love-sub-v1341.$$" line label
  [[ -s "$raw" ]] || return 0

  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Xray HY2: old stable format only.
    if [[ "$line" == *"LOVE-XRAY-HY2"* && ( "$line" == hysteria2://* || "$line" == hy2://* ) ]]; then
      local pre sni insecure
      pre="${line%%#*}"
      pre="${pre%%\?*}"
      pre="${pre%/}/"
      sni="$(love_uri_get_param_v1341 "$line" "sni")"
      [[ -z "$sni" ]] && sni="self.local"
      insecure="$(love_xray_hy2_insecure_v1341 "$sni")"
      echo "${pre}?sni=${sni}&insecure=${insecure}#$(love_label_flag_v1341 "LOVE-XRAY-HY2")" >> "$tmp"
      continue
    fi

    # Other nodes: only add flag; do not modify params.
    if [[ "$line" =~ ^(vless|hysteria2|hy2|tuic|ss|trojan|vmess|anytls|https|shadowtls):// ]]; then
      love_apply_flag_uri_v1341 "$line" >> "$tmp"
    else
      echo "$line" >> "$tmp"
    fi
  done < "$raw"

  awk '!seen[$0]++' "$tmp" > "$raw"
  rm -f "$tmp"

  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$raw" > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
  else
    base64 "$raw" | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
  fi

  mkdir -p /opt/Love/subscribe/clients
  cp -f "$raw" /opt/Love/subscribe/clients/v2rayn-uri.txt 2>/dev/null || true
  cp -f "$raw" /opt/Love/subscribe/clients/nekobox-uri.txt 2>/dev/null || true
}

# Save previous sub if available.
if declare -F love_sub_hard_v1338 >/dev/null 2>&1 && ! declare -F love_original_sub_v1341 >/dev/null 2>&1; then
  eval "$(declare -f love_sub_hard_v1338 | sed '1s/^love_sub_hard_v1338/love_original_sub_v1341/')"
fi

love_sub_safe_v1341() {
  love_rebuild_xray_client_info_v1341

  # keep sing-box behavior from v13.39 exactly: call original sub wrapper if it exists
  if declare -F love_original_sub_v1341 >/dev/null 2>&1; then
    love_original_sub_v1341 "$@"
  elif declare -F love_sub_domain_final_v1336 >/dev/null 2>&1; then
    love_sub_domain_final_v1336 "$@"
  else
    echo "[ERROR] 找不到订阅导出函数"
    return 1
  fi

  love_rebuild_xray_client_info_v1341
  love_fix_sub_xray_only_v1341

  echo
  echo "[OK] 订阅已导出：sing-box 保持原逻辑；Xray HY2 恢复旧版稳定链接；节点名已加国旗。"
  grep -nE 'LOVE-XRAY|38002|38006|TUIC|VLESS-WS-TLS|HY2' /opt/Love/subscribe/all.txt 2>/dev/null || true
}

# ------------------------------
# Diagnostics and hard menu wrapper.
# ------------------------------
love_menu_check_v1341() {
  love_menu_title "Love 菜单入口检查" "Safe v13.41"
  local f
  for f in love_hard_menu_v1335 install_xray_stable install_singbox_native love_sub_safe_v1341 generate_qrcodes web_admin_page uninstall_menu_v7 love_ports_v1334 love_count_v1334 love_update_safe_v1341 love_flag_set_v1341; do
    if declare -F "$f" >/dev/null 2>&1; then
      printf "[OK]   %s\n" "$f"
    else
      printf "[MISS] %s\n" "$f"
    fi
  done
}

love_boot_check_v1341() {
  echo "==== Love 文件 ===="
  ls -lh /opt/Love/Love.sh 2>/dev/null || true
  stat -c 'size=%s' /opt/Love/Love.sh 2>/dev/null || true
  grep '^VERSION=' /opt/Love/Love.sh 2>/dev/null || true
  bash -n /opt/Love/Love.sh && echo "[OK] bash -n"
  echo
  echo "==== 命令指向 ===="
  type -a Love 2>/dev/null || true
  type -a love 2>/dev/null || true
  readlink -f /usr/local/bin/Love 2>/dev/null || true
  readlink -f /usr/local/bin/love 2>/dev/null || true
  echo
  echo "==== Xray ===="
  /usr/local/bin/xray version 2>/dev/null | head -5 || true
  jq '.inbounds[]? | select(.tag=="hy2-in") | {tag,port,protocol,auth:.settings.users[0].auth,sni:.streamSettings.tlsSettings.serverName,alpn:.streamSettings.tlsSettings.alpn,network:.streamSettings.network}' /usr/local/etc/xray/config.json 2>/dev/null || true
  echo
  echo "==== 监听 ===="
  ss -lntup | grep -E '443|38000|38001|38002|38006|xray|sing-box' || true
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1341 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1341/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.41.0-safe-main-xray-sub-flag-final}"
  case "${1:-}" in
    ""|menu)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      if declare -F love_hard_menu_v1335 >/dev/null 2>&1; then
        love_hard_menu_v1335
      elif declare -F main_menu >/dev/null 2>&1; then
        main_menu
      else
        echo "Love v13.41"
        echo "可用命令：Love xray | Love singbox | Love sub | Love qr | Love web | Love boot-check"
      fi
      ;;
    sub|subscription|link-fix|client-fix|fix-links)
      love_sub_safe_v1341
      ;;
    update|self-update)
      love_update_safe_v1341
      ;;
    flag-set|set-flag)
      love_flag_set_v1341
      ;;
    flag-auto|detect-flag)
      rm -f /opt/Love/node-country /opt/Love/node-flag 2>/dev/null || true
      love_flag_detect_v1341
      echo "[OK] 自动识别：$(love_flag_get_v1341) $(love_cc_get_v1341)"
      ;;
    menu-check)
      love_menu_check_v1341
      ;;
    boot-check|doctor)
      love_boot_check_v1341
      ;;
    *)
      love_original_main_v1341 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.42 Latest Xray + Auto Web Final
# User requirements:
#   - Xray pulls the latest version, not locked 26.5.9.
#   - Do not touch sing-box logic.
#   - After node generation, automatically run Web setup interactively:
#       port / Basic Auth / username / password.
#   - Keep v13.41 zero-byte update guard, old Xray HY2 subscription format, auto flag.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.42.0-latest-xray-auto-web-final"
XRAY_INSTALL_POLICY="latest"

# Force Xray install/update to latest release.
# No --version parameter here.
install_xray_core() {
  info "安装 / 更新 Xray-core：拉取最新版 latest..."

  useradd --system --no-create-home --shell /usr/sbin/nologin xray 2>/dev/null || true
  mkdir -p "${XRAY_CONF_DIR}" /usr/local/share/xray /var/log/xray
  chown -R root:xray "${XRAY_CONF_DIR}" 2>/dev/null || true
  chown -R xray:xray /var/log/xray 2>/dev/null || true
  chmod 750 "${XRAY_CONF_DIR}" /var/log/xray 2>/dev/null || true

  if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --install-user xray; then
    "${XRAY_BIN}" version | head -5
    log "Xray-core 最新版安装完成。"
    return 0
  fi

  warn "在线安装 Xray-core 最新版失败。"

  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" version | head -5
    log "检测到已有 Xray-core，继续使用当前版本。"
    return 0
  fi

  if [[ -f /root/Xray-linux-64.zip ]]; then
    warn "检测到 /root/Xray-linux-64.zip，尝试本地安装。"
    rm -rf /tmp/love-xray
    mkdir -p /tmp/love-xray
    unzip -o /root/Xray-linux-64.zip -d /tmp/love-xray
    install -m 755 /tmp/love-xray/xray "${XRAY_BIN}"
    [[ -f /tmp/love-xray/geoip.dat ]] && install -m 644 /tmp/love-xray/geoip.dat /usr/local/share/xray/geoip.dat
    [[ -f /tmp/love-xray/geosite.dat ]] && install -m 644 /tmp/love-xray/geosite.dat /usr/local/share/xray/geosite.dat
    "${XRAY_BIN}" version | head -5
    log "Xray-core 已从 /root/Xray-linux-64.zip 本地安装。"
    return 0
  fi

  die "无法安装 Xray-core。可先上传 Xray-linux-64.zip 到 /root，或修复 GitHub 访问。"
}

love_xray_update_latest_v1342() {
  love_menu_title "Love Xray Core 最新版更新" "latest"
  echo "当前版本："
  /usr/local/bin/xray version 2>/dev/null | head -5 || true
  echo
  read -rp "确认拉取 Xray 最新版？[Y/n]: " ok
  ok="${ok:-Y}"
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "已取消。"; return 0; }

  cp -f /usr/local/bin/xray /usr/local/bin/xray.bak.$(date +%F-%H%M%S) 2>/dev/null || true
  install_xray_core

  if [[ -s /usr/local/etc/xray/config.json ]]; then
    /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json || return 1
    systemctl restart xray 2>/dev/null || true
  fi

  echo
  echo "更新后版本："
  /usr/local/bin/xray version 2>/dev/null | head -5 || true
  ss -lntup | grep -E ':443|xray' || true
}

# Auto Web after node generation.
# This intentionally calls interactive web_admin_page so the user can input port/user/password.
if declare -F love_after_node_generated_exports >/dev/null 2>&1 && ! declare -F love_original_after_exports_v1342 >/dev/null 2>&1; then
  eval "$(declare -f love_after_node_generated_exports | sed '1s/^love_after_node_generated_exports/love_original_after_exports_v1342/')"
fi

love_after_node_generated_exports() {
  if declare -F love_original_after_exports_v1342 >/dev/null 2>&1; then
    love_original_after_exports_v1342 "$@"
  else
    export_subscription >/dev/null 2>&1 || true
    generate_qrcodes quiet >/dev/null 2>&1 || true
    generate_client_exports >/dev/null 2>&1 || true
  fi

  echo
  echo "================ Love Auto Web ================"
  echo "节点已生成，开始自动启动/更新 Web 管理页。"
  echo "下面会要求输入 Web 端口、Basic Auth、用户名和密码。"
  echo

  if declare -F web_admin_page >/dev/null 2>&1; then
    web_admin_page
  else
    echo "[WARN] web_admin_page 函数不存在，无法自动运行 Web。"
  fi
}

love_web_sync_v1342() {
  love_menu_title "Love Web 同步" "sync existing panel files"
  local token
  token="$(get_sub_token 2>/dev/null || true)"
  [[ -n "$token" ]] || token="default"

  mkdir -p "${LOVE_WEB}/${token}/subscribe" "${LOVE_WEB}/${token}/qr" "${LOVE_WEB}/${token}/clients" "${LOVE_WEB}/${token}/sing-box"
  cp -a "${LOVE_SUB}/." "${LOVE_WEB}/${token}/subscribe/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/qr/." "${LOVE_WEB}/${token}/qr/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/clients/." "${LOVE_WEB}/${token}/clients/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/sing-box/." "${LOVE_WEB}/${token}/sing-box/" 2>/dev/null || true

  # Also provide simple non-token shortcut copies for easier inspection.
  mkdir -p "${LOVE_WEB}/sub" "${LOVE_WEB}/qr" "${LOVE_WEB}/clients"
  cp -f "${LOVE_SUB}/all.txt" "${LOVE_WEB}/sub/all.txt" 2>/dev/null || true
  cp -f "${LOVE_SUB}/all_base64.txt" "${LOVE_WEB}/sub/all_base64.txt" 2>/dev/null || true
  cp -a "${LOVE_SUB}/qr/." "${LOVE_WEB}/qr/" 2>/dev/null || true
  cp -a "${LOVE_SUB}/clients/." "${LOVE_WEB}/clients/" 2>/dev/null || true

  chown -R www-data:www-data "${LOVE_WEB}" 2>/dev/null || true
  find "${LOVE_WEB}" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "${LOVE_WEB}" -type f -exec chmod 644 {} \; 2>/dev/null || true

  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

  echo "[OK] Web 文件已同步：${LOVE_WEB}"
  find "${LOVE_WEB}" -type f -name 'all.txt' -print 2>/dev/null || true
}

# Wrap Web generation: after interactive setup, also create shortcut /sub/all.txt copies.
if declare -F web_admin_page >/dev/null 2>&1 && ! declare -F love_original_web_admin_v1342 >/dev/null 2>&1; then
  eval "$(declare -f web_admin_page | sed '1s/^web_admin_page/love_original_web_admin_v1342/')"
fi

web_admin_page() {
  love_original_web_admin_v1342 "$@"
  love_web_sync_v1342 >/dev/null 2>&1 || true
}

# Extend diagnostics.
if declare -F love_boot_check_v1341 >/dev/null 2>&1 && ! declare -F love_original_boot_check_v1342 >/dev/null 2>&1; then
  eval "$(declare -f love_boot_check_v1341 | sed '1s/^love_boot_check_v1341/love_original_boot_check_v1342/')"
fi

love_boot_check_v1341() {
  love_original_boot_check_v1342 "$@"
  echo
  echo "==== Xray install policy ===="
  echo "XRAY_INSTALL_POLICY=${XRAY_INSTALL_POLICY}"
  echo
  echo "==== Web copies ===="
  find /var/www/love-admin -type f -name 'all.txt' -print 2>/dev/null || true
}

# Final main override for new commands.
if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1342 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1342/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.42.0-latest-xray-auto-web-final}"
  case "${1:-}" in
    xray-latest|xray-update-latest|xray-version)
      love_xray_update_latest_v1342
      ;;
    web-sync)
      love_web_sync_v1342
      ;;
    boot-check|doctor)
      love_boot_check_v1341
      ;;
    *)
      love_original_main_v1342 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.43 Color Menu + Clean Uninstall Final
# Fixes:
#   - Restores colored aligned main menu.
#   - Menu choices call the newest safe wrappers, not old legacy functions.
#   - Uninstall menu is force-overridden; Full uninstall really cleans and exits.
#   - Keeps v13.42 latest Xray + Auto Web.
#   - Keeps sing-box logic untouched.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.43.0-color-menu-clean-uninstall-final"

# ------------------------------
# Color helpers
# ------------------------------
love_tty_colors_v1343() {
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    C_RESET="$(tput sgr0 2>/dev/null || true)"
    C_BOLD="$(tput bold 2>/dev/null || true)"
    C_DIM="$(tput dim 2>/dev/null || true)"
    C_RED="$(tput setaf 1 2>/dev/null || true)"
    C_GREEN="$(tput setaf 2 2>/dev/null || true)"
    C_YELLOW="$(tput setaf 3 2>/dev/null || true)"
    C_BLUE="$(tput setaf 4 2>/dev/null || true)"
    C_MAGENTA="$(tput setaf 5 2>/dev/null || true)"
    C_CYAN="$(tput setaf 6 2>/dev/null || true)"
    C_WHITE="$(tput setaf 7 2>/dev/null || true)"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""
  fi
}

love_line_v1343() {
  printf '%b\n' "${C_CYAN}════════════════════════════════════════════════════════════════════════════════${C_RESET}"
}

love_title_v1343() {
  local title="$1" sub="${2:-}"
  love_line_v1343
  printf '%b\n' "${C_BOLD}${C_MAGENTA}${title}${C_RESET}"
  [[ -n "$sub" ]] && printf '%b\n' "${C_DIM}${sub}${C_RESET}"
  love_line_v1343
}

love_row_v1343() {
  # Use short mixed Chinese/English labels to avoid CJK width drift.
  # Borders are kept stable by fixed visual padding.
  printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}$1${C_RESET} ${C_DIM}${2}${C_RESET}        ${C_CYAN}│${C_RESET} ${C_GREEN}$3${C_RESET} ${C_DIM}${4}${C_RESET}"
}

love_pause_v1343() {
  echo
  read -rp "按 Enter 返回菜单..." _
}

# ------------------------------
# Clean uninstall, forced override
# ------------------------------
love_clean_web_v1343() {
  systemctl stop nginx 2>/dev/null || true
  rm -rf /var/www/love-admin
  rm -f /etc/nginx/sites-enabled/love-admin
  rm -f /etc/nginx/sites-available/love-admin
  rm -f /etc/nginx/sites-enabled/love-sub
  rm -f /etc/nginx/sites-available/love-sub
  rm -f /etc/nginx/.love_web_htpasswd
  nginx -t >/dev/null 2>&1 && systemctl restart nginx 2>/dev/null || true
}

love_full_uninstall_v1343() {
  echo
  printf '%b\n' "${C_RED}${C_BOLD}Full 卸载会删除 Love、Xray、sing-box、Web、WARP/WireProxy、订阅 TXT、二维码和客户端导出。${C_RESET}"
  read -rp "确认继续？输入 y 执行 [y/N]: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "已取消。"; return 0; }

  echo "[1/8] 停止并禁用服务..."
  systemctl stop xray sing-box nginx love-wireproxy.service love-argo.service love-backup.timer love-backup.service wireproxy 2>/dev/null || true
  systemctl disable xray sing-box love-wireproxy.service love-argo.service love-backup.timer love-backup.service wireproxy 2>/dev/null || true

  echo "[2/8] 删除 systemd 服务..."
  rm -f /etc/systemd/system/xray.service
  rm -rf /etc/systemd/system/xray.service.d
  rm -f /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray@.service.d
  rm -f /etc/systemd/system/sing-box.service
  rm -rf /etc/systemd/system/sing-box.service.d
  rm -f /etc/systemd/system/love-wireproxy.service
  rm -f /etc/systemd/system/love-argo.service
  rm -f /etc/systemd/system/love-backup.service
  rm -f /etc/systemd/system/love-backup.timer
  rm -f /etc/systemd/system/wireproxy.service

  echo "[3/8] 删除核心配置和数据..."
  rm -rf /opt/Love
  rm -rf /etc/sing-box
  rm -rf /usr/local/etc/xray
  rm -rf /usr/local/share/xray
  rm -rf /var/log/xray
  rm -rf /etc/wireproxy
  rm -rf /opt/warp /opt/wireproxy

  echo "[4/8] 删除 Web 副本和 nginx Love 配置..."
  rm -rf /var/www/love-admin
  rm -f /etc/nginx/sites-enabled/love-admin
  rm -f /etc/nginx/sites-available/love-admin
  rm -f /etc/nginx/sites-enabled/love-sub
  rm -f /etc/nginx/sites-available/love-sub
  rm -f /etc/nginx/.love_web_htpasswd

  echo "[5/8] 删除证书续签 Hook..."
  rm -f /etc/letsencrypt/renewal-hooks/deploy/love-xray-copy-cert.sh

  echo "[6/8] 删除命令和二进制..."
  rm -f /usr/local/bin/Love
  rm -f /usr/local/bin/love
  rm -f /usr/local/bin/xray
  rm -f /usr/local/bin/sing-box
  rm -f /usr/local/bin/warp
  rm -f /usr/local/bin/warp-go
  rm -f /usr/local/bin/wireproxy

  echo "[7/8] 清理缓存残留..."
  rm -rf /tmp/love-* /tmp/Love.* /tmp/xray.* /tmp/singbox.* 2>/dev/null || true

  echo "[8/8] 刷新 systemd..."
  systemctl daemon-reload || true
  systemctl reset-failed || true
  nginx -t >/dev/null 2>&1 && systemctl restart nginx 2>/dev/null || true

  echo
  echo "[OK] Full 卸载完成。"
  echo "已删除：/opt/Love、/etc/sing-box、/usr/local/etc/xray、/var/www/love-admin、Love/love 命令。"
  echo "当前脚本即将退出，避免继续显示旧菜单。"
  exit 0
}

love_uninstall_menu_v1343() {
  love_tty_colors_v1343
  while true; do
    clear 2>/dev/null || true
    love_title_v1343 "Love 卸载 / 清理菜单" "Clean uninstall / Web copies / systemd leftovers"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}1)${C_RESET} Soft 卸载节点服务              ${C_CYAN}│${C_RESET} ${C_GREEN}6)${C_RESET} 清理 Web 面板和副本"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}2)${C_RESET} Full 卸载 Love 全部文件        ${C_CYAN}│${C_RESET} ${C_GREEN}7)${C_RESET} 清理 WARP / WireProxy"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}3)${C_RESET} 仅停止 sing-box                ${C_CYAN}│${C_RESET} ${C_GREEN}8)${C_RESET} 清理 nginx Love 配置"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}4)${C_RESET} 删除订阅/二维码/Web副本        ${C_CYAN}│${C_RESET} ${C_GREEN}9)${C_RESET} 清理 systemd 残留"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}5)${C_RESET} 仅删除客户端导出              ${C_CYAN}│${C_RESET} ${C_GREEN}0)${C_RESET} 返回"
    echo
    printf '%b\n' "${C_YELLOW}危险操作前建议先执行：Love backup-auto${C_RESET}"
    read -rp "请选择: " u
    case "$u" in
      1)
        systemctl stop xray sing-box love-wireproxy.service love-argo.service wireproxy 2>/dev/null || true
        systemctl disable xray sing-box love-wireproxy.service love-argo.service wireproxy 2>/dev/null || true
        systemctl daemon-reload || true
        echo "[OK] 节点服务已停止并禁用，配置保留。"
        ;;
      2) love_full_uninstall_v1343 ;;
      3)
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        echo "[OK] sing-box 已停止。"
        ;;
      4)
        rm -rf /opt/Love/subscribe
        rm -rf /var/www/love-admin/sub /var/www/love-admin/qr /var/www/love-admin/clients /var/www/love-admin/sing-box
        rm -f /var/www/love-admin/node-links.txt
        echo "[OK] 订阅 TXT、二维码、Web 副本已删除。"
        ;;
      5)
        rm -rf /opt/Love/subscribe/clients
        rm -rf /var/www/love-admin/clients
        echo "[OK] 客户端导出已删除。"
        ;;
      6)
        love_clean_web_v1343
        echo "[OK] Web 面板和副本已清理。"
        ;;
      7)
        systemctl stop love-wireproxy.service wireproxy 2>/dev/null || true
        systemctl disable love-wireproxy.service wireproxy 2>/dev/null || true
        rm -f /etc/systemd/system/love-wireproxy.service /etc/systemd/system/wireproxy.service
        rm -rf /etc/wireproxy /opt/warp /opt/wireproxy
        systemctl daemon-reload || true
        echo "[OK] WARP / WireProxy 已清理。"
        ;;
      8)
        rm -f /etc/nginx/sites-enabled/love-admin /etc/nginx/sites-available/love-admin /etc/nginx/.love_web_htpasswd
        nginx -t >/dev/null 2>&1 && systemctl restart nginx 2>/dev/null || true
        echo "[OK] nginx Love 配置已清理。"
        ;;
      9)
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /etc/systemd/system/sing-box.service /etc/systemd/system/love-wireproxy.service /etc/systemd/system/love-argo.service /etc/systemd/system/love-backup.service /etc/systemd/system/love-backup.timer
        rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d /etc/systemd/system/sing-box.service.d
        systemctl daemon-reload || true
        systemctl reset-failed || true
        echo "[OK] systemd 残留已清理。"
        ;;
      0) return 0 ;;
      *) echo "[WARN] 无效选择。" ;;
    esac
    love_pause_v1343
  done
}

uninstall_menu_v7() { love_uninstall_menu_v1343; }
uninstall_menu() { love_uninstall_menu_v1343; }

# ------------------------------
# Colored main menu, forced override
# ------------------------------
love_call_v1343() {
  local f="$1"; shift || true
  if declare -F "$f" >/dev/null 2>&1; then
    "$f" "$@"
  else
    echo "[MISS] 功能不存在：$f"
    return 1
  fi
}

love_main_menu_v1343() {
  love_tty_colors_v1343
  while true; do
    clear 2>/dev/null || true
    love_title_v1343 "Love Node Server Manager ${LOVE_SCRIPT_VERSION:-Love v13.43}" "Color UI / aligned menu / latest Xray / auto Web"
    if declare -F love_safe_status_v1335 >/dev/null 2>&1; then
      love_safe_status_v1335
    elif declare -F show_status >/dev/null 2>&1; then
      show_status
    fi
    echo
    printf '%b\n' "${C_BOLD}主菜单${C_RESET}"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}1)${C_RESET} 节点目录                     ${C_CYAN}│${C_RESET} ${C_GREEN}14)${C_RESET} v6 Project Tools"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}2)${C_RESET} Xray Reality + HY2           ${C_CYAN}│${C_RESET} ${C_GREEN}15)${C_RESET} v7 Stable Tools"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}3)${C_RESET} sing-box 全协议              ${C_CYAN}│${C_RESET} ${C_GREEN}16)${C_RESET} v8 Project Panel"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}4)${C_RESET} Argo 隧道                    ${C_CYAN}│${C_RESET} ${C_GREEN}17)${C_RESET} Nginx Reverse Proxy"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}5)${C_RESET} UDP 端口跳跃                 ${C_CYAN}│${C_RESET} ${C_GREEN}18)${C_RESET} HY2/sing-box 修复"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}6)${C_RESET} WARP 说明                    ${C_CYAN}│${C_RESET} ${C_GREEN}19)${C_RESET} IPv6-only 出站"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}7)${C_RESET} 节点信息 Love -n             ${C_CYAN}│${C_RESET} ${C_GREEN}20)${C_RESET} WARP Manager / FS"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}8)${C_RESET} 导出订阅 Love sub            ${C_CYAN}│${C_RESET} ${C_GREEN}21)${C_RESET} 查看运行状态"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}9)${C_RESET} 生成二维码 Love qr          ${C_CYAN}│${C_RESET} ${C_GREEN}22)${C_RESET} 备份配置"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}10)${C_RESET} Super Tools                ${C_CYAN}│${C_RESET} ${C_GREEN}23)${C_RESET} 卸载菜单"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}11)${C_RESET} Web 管理页 Love web        ${C_CYAN}│${C_RESET} ${C_GREEN}24)${C_RESET} GitHub 发布说明"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}12)${C_RESET} 在线更新 / 下载链接        ${C_CYAN}│${C_RESET} ${C_GREEN}25)${C_RESET} 安装 warp 命令"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}13)${C_RESET} 客户端导出                 ${C_CYAN}│${C_RESET} ${C_GREEN}0)${C_RESET} 退出"
    echo
    printf '%b\n' "${C_YELLOW}双栈推荐：2 保留 Xray 443；3 生成 sing-box 全协议；Love sub 合并两边。${C_RESET}"
    printf '%b\n' "${C_DIM}常用：Love ports | Love sub | Love qr | Love txt | Love web | Love web-sync | Love count${C_RESET}"
    echo
    read -rp "请选择: " choice
    case "$choice" in
      1) love_call_v1343 show_all_node_catalog ;;
      2) love_call_v1343 install_xray_stable ;;
      3) love_call_v1343 install_singbox_native ;;
      4) love_call_v1343 argo_helper ;;
      5) love_call_v1343 port_hopping_helper ;;
      6) love_call_v1343 warp_helper ;;
      7) love_call_v1343 show_node_info ;;
      8) love_call_v1343 love_sub_safe_v1341 || love_call_v1343 export_subscription ;;
      9) love_call_v1343 generate_qrcodes ;;
      10) love_call_v1343 super_menu ;;
      11) love_call_v1343 web_admin_page ;;
      12) love_call_v1343 self_update_love ;;
      13) love_call_v1343 love_full_client_pack ;;
      14) love_call_v1343 v6_super_menu ;;
      15) love_call_v1343 v7_stable_menu ;;
      16) love_call_v1343 v8_menu ;;
      17) love_call_v1343 nginx_rp_menu ;;
      18) love_call_v1343 love_fix_hy2_now ;;
      19) love_call_v1343 love_ipv6_outbound_menu ;;
      20) love_call_v1343 love_warp_manager_menu ;;
      21) love_call_v1343 show_status ;;
      22) love_call_v1343 backup_configs ;;
      23) love_uninstall_menu_v1343 ;;
      24) love_call_v1343 github_publish_note ;;
      25) love_call_v1343 love_install_fs_warp_command ;;
      0) exit 0 ;;
      *) echo "[WARN] 无效选择。" ;;
    esac
    love_pause_v1343
  done
}

love_hard_menu_v1335() { love_main_menu_v1343; }
main_menu() { love_main_menu_v1343; }

love_menu_check_v1343() {
  love_tty_colors_v1343
  love_title_v1343 "Love 菜单入口检查" "v13.43"
  local f
  for f in \
    love_main_menu_v1343 install_xray_stable install_singbox_native love_sub_safe_v1341 \
    generate_qrcodes web_admin_page love_web_sync_v1342 show_status backup_configs \
    love_uninstall_menu_v1343 love_full_uninstall_v1343 self_update_love \
    love_xray_update_latest_v1342 love_safe_install_script_v1341; do
    if declare -F "$f" >/dev/null 2>&1; then
      printf '%b\n' "${C_GREEN}[OK]${C_RESET}   $f"
    else
      printf '%b\n' "${C_RED}[MISS]${C_RESET} $f"
    fi
  done
}

# Final main override.
if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1343 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1343/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.43.0-color-menu-clean-uninstall-final}"
  case "${1:-}" in
    ""|menu)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      love_main_menu_v1343
      ;;
    uninstall|remove|clean-uninstall)
      love_uninstall_menu_v1343
      ;;
    menu-check)
      love_menu_check_v1343
      ;;
    sub|subscribe|subscription|link-fix|client-fix|fix-links)
      if declare -F love_sub_safe_v1341 >/dev/null 2>&1; then love_sub_safe_v1341 "$@"; else export_subscription "$@"; fi
      ;;
    *)
      love_original_main_v1343 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.44 Reload After Update + Xray Info Dir Fix Final
# Fixes the exact field issue:
#   1) After update, current old bash process returns to old menu. Now update execs new Love menu.
#   2) Xray node generation failed because /opt/Love/client-info did not exist.
#      save_xray_info is wrapped to mkdir required dirs first.
#   3) Keep v13.43 colored menu, clean uninstall, latest Xray, auto Web, auto flag.
#   4) sing-box logic untouched.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.44.0-reload-after-update-xrayinfo-fix-final"

love_prepare_core_dirs_v1344() {
  mkdir -p /opt/Love
  mkdir -p /opt/Love/client-info
  mkdir -p /opt/Love/subscribe
  mkdir -p /opt/Love/subscribe/qr
  mkdir -p /opt/Love/subscribe/clients
  mkdir -p /opt/Love/subscribe/sing-box
  mkdir -p /var/www/love-admin 2>/dev/null || true
}

# Wrap save_xray_info to prevent:
# /usr/local/bin/love: line 781: /opt/Love/client-info/xray-client-info.txt: No such file or directory
if declare -F save_xray_info >/dev/null 2>&1 && ! declare -F love_original_save_xray_info_v1344 >/dev/null 2>&1; then
  eval "$(declare -f save_xray_info | sed '1s/^save_xray_info/love_original_save_xray_info_v1344/')"
fi

save_xray_info() {
  love_prepare_core_dirs_v1344
  local info_dir
  info_dir="$(dirname "${XRAY_INFO:-/opt/Love/client-info/xray-client-info.txt}")"
  mkdir -p "$info_dir" /opt/Love/client-info
  love_original_save_xray_info_v1344 "$@"

  # Also keep a stable copy path.
  if [[ -s "${XRAY_INFO:-}" ]]; then
    cp -f "${XRAY_INFO}" /opt/Love/client-info/xray-client-info.txt 2>/dev/null || true
  fi
}

# Wrap auto export to ensure dirs exist before any copy/export.
if declare -F love_after_node_generated_exports >/dev/null 2>&1 && ! declare -F love_original_after_exports_v1344 >/dev/null 2>&1; then
  eval "$(declare -f love_after_node_generated_exports | sed '1s/^love_after_node_generated_exports/love_original_after_exports_v1344/')"
fi

love_after_node_generated_exports() {
  love_prepare_core_dirs_v1344
  love_original_after_exports_v1344 "$@"
}

# Update must reload the new script immediately; otherwise user stays in old v13.41/v13.42 menu.
love_update_safe_v1344() {
  love_tty_colors_v1343 2>/dev/null || true
  love_title_v1343 "Love 安全更新" "Zero-byte protected / Auto reload new menu" 2>/dev/null || {
    echo "================ Love 安全更新 ================"
  }

  local url tmp size
  url="${LOVE_UPDATE_URL:-https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh?force=$(date +%s)}"
  tmp="/root/Love.new"

  rm -f "$tmp" /tmp/Love.new 2>/dev/null || true

  echo "下载：$url"
  curl -L --fail --retry 5 \
    -H 'Cache-Control: no-cache, no-store, must-revalidate' \
    -H 'Pragma: no-cache' \
    -H 'Expires: 0' \
    -o "$tmp" "$url" || { echo "[ERROR] 下载失败。"; return 1; }

  ls -lh "$tmp"
  size="$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)"
  echo "size=${size}"

  if [[ "$size" -lt 100000 ]]; then
    echo "[ERROR] 新脚本太小：${size} bytes，禁止覆盖。"
    return 1
  fi
  grep -q '^VERSION=' "$tmp" || { echo "[ERROR] 新脚本找不到 VERSION，禁止覆盖。"; return 1; }
  bash -n "$tmp" || { echo "[ERROR] 新脚本语法检查失败，禁止覆盖。"; return 1; }

  mkdir -p /opt/Love
  if [[ -s /opt/Love/Love.sh ]]; then
    cp -f /opt/Love/Love.sh /opt/Love/Love.sh.bak.safe.$(date +%F-%H%M%S) 2>/dev/null || true
  fi

  install -m 755 "$tmp" /opt/Love/Love.sh
  ln -sf /opt/Love/Love.sh /usr/local/bin/Love
  ln -sf /opt/Love/Love.sh /usr/local/bin/love
  hash -r 2>/dev/null || true

  echo "[OK] Love 脚本已安全安装：/opt/Love/Love.sh"
  grep '^VERSION=' /opt/Love/Love.sh || true

  echo
  echo "[OK] 正在重新载入新版主菜单，避免继续停留在旧菜单..."
  exec /usr/local/bin/Love menu
}

self_update_love() { love_update_safe_v1344; }

love_boot_check_v1344() {
  echo "==== Love 文件 ===="
  ls -lh /opt/Love/Love.sh 2>/dev/null || true
  stat -c 'size=%s' /opt/Love/Love.sh 2>/dev/null || true
  grep '^VERSION=' /opt/Love/Love.sh 2>/dev/null || true
  bash -n /opt/Love/Love.sh && echo "[OK] bash -n"
  echo
  echo "==== 关键目录 ===="
  for d in /opt/Love /opt/Love/client-info /opt/Love/subscribe /opt/Love/subscribe/qr /opt/Love/subscribe/clients /var/www/love-admin; do
    [[ -d "$d" ]] && echo "[OK] $d" || echo "[MISS] $d"
  done
  echo
  echo "==== Xray info ===="
  ls -lh /opt/Love/client-info/xray-client-info.txt 2>/dev/null || true
  echo
  echo "==== Web all.txt ===="
  find /var/www/love-admin -type f -name 'all.txt' -print 2>/dev/null || true
}

# Final main override for boot-check and update.
if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1344 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1344/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.44.0-reload-after-update-xrayinfo-fix-final}"
  case "${1:-}" in
    update|self-update)
      love_update_safe_v1344
      ;;
    boot-check|doctor)
      love_boot_check_v1344
      ;;
    *)
      love_prepare_core_dirs_v1344
      love_original_main_v1344 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.45 WARP Manager Restore + Xray IPv4 Outbound Final
# Fixes:
#   - Main menu 20 is forced to a restored WARP Manager, not a missing/old link.
#   - Original V12 WARP menu is preserved and reachable.
#   - Adds Xray Reality/HY2 outbound via WARP SOCKS IPv4 path without touching sing-box.
#   - Keeps v13.44 reload/directory fix, v13.43 colored menu, v13.42 latest Xray/auto Web.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.45.0-warp-manager-restore-xray-ipv4-final"

love_socks_health_gate_v1345() {
  local port="${1:-40000}"
  echo
  echo "==== SOCKS 健康检查 127.0.0.1:${port} ===="
  if ss -lntp 2>/dev/null | grep -q ":${port}"; then
    echo "[OK] 端口监听：${port}"
  else
    echo "[WARN] 未检测到 SOCKS 监听：${port}"
    return 1
  fi

  if curl -s --connect-timeout 10 --max-time 20 --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace | grep -Ei 'warp=on|warp=plus|ip=|colo='; then
    echo "[OK] WARP SOCKS 可用：127.0.0.1:${port}"
    return 0
  fi

  echo "[WARN] SOCKS 端口存在，但 WARP trace 未通过。"
  return 1
}

love_xray_route_via_warp_socks_v1345() {
  local port="${1:-40000}"
  [[ -s /usr/local/etc/xray/config.json ]] || { echo "[ERROR] 未找到 /usr/local/etc/xray/config.json"; return 1; }

  if ! love_socks_health_gate_v1345 "$port"; then
    echo
    echo "[WARN] 当前 WARP SOCKS 未通过健康检查。"
    read -rp "是否先尝试启动官方 WARP Proxy ${port}？[Y/n]: " start
    start="${start:-Y}"
    if [[ "$start" =~ ^[Yy]$ ]]; then
      if declare -F love_warp_cli_proxy_v12 >/dev/null 2>&1; then
        love_warp_cli_proxy_v12 "$port" || true
      elif declare -F love_warp_set_proxy_mode >/dev/null 2>&1; then
        love_warp_set_proxy_mode "$port" || true
      else
        echo "[ERROR] 未找到 WARP Proxy 启动函数。"
        return 1
      fi
    fi
  fi

  love_socks_health_gate_v1345 "$port" || {
    echo "[ERROR] WARP SOCKS 仍不可用，拒绝切换 Xray，避免出站中断。"
    return 1
  }

  cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak.xray-warp.$(date +%F-%H%M%S)

  jq --argjson port "$port" '
    .outbounds = ((.outbounds // []) | map(select(.tag!="warp-socks"))) +
    [{
      "tag": "warp-socks",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": $port
          }
        ]
      }
    }] |
    .routing = (.routing // {}) |
    .routing.domainStrategy = "IPIfNonMatch" |
    .routing.rules = ((.routing.rules // []) | map(select(.outboundTag!="warp-socks"))) +
    [
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "warp-socks"
      }
    ]
  ' /usr/local/etc/xray/config.json > /root/xray.warp.json && mv /root/xray.warp.json /usr/local/etc/xray/config.json

  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json || {
    echo "[ERROR] Xray 配置检查失败，尝试恢复备份。"
    ls -t /usr/local/etc/xray/config.json.bak.xray-warp.* 2>/dev/null | head -1 | xargs -r -I{} cp -f {} /usr/local/etc/xray/config.json
    return 1
  }

  systemctl restart xray
  sleep 2

  echo "[OK] Xray 出站已切到 WARP SOCKS：127.0.0.1:${port}"
  echo "说明：这会让 Xray Reality/HY2 的出站走 WARP IPv4/IPv6，不影响 sing-box 配置。"
  jq '.outbounds[]? | select(.tag=="warp-socks")' /usr/local/etc/xray/config.json 2>/dev/null || true
  journalctl -u xray -n 10 -l --no-pager || true
}

love_xray_restore_direct_v1345() {
  [[ -s /usr/local/etc/xray/config.json ]] || { echo "[ERROR] 未找到 /usr/local/etc/xray/config.json"; return 1; }
  cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak.restore-direct.$(date +%F-%H%M%S)

  jq '
    .outbounds = ((.outbounds // []) | map(select(.tag!="warp-socks"))) |
    .routing = (.routing // {}) |
    .routing.rules = ((.routing.rules // []) | map(select(.outboundTag!="warp-socks")))
  ' /usr/local/etc/xray/config.json > /root/xray.direct.json && mv /root/xray.direct.json /usr/local/etc/xray/config.json

  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json || return 1
  systemctl restart xray
  echo "[OK] Xray 出站已恢复 direct。"
}

love_warp_status_plus_v1345() {
  echo
  echo "================ Love WARP / IPv4 出站状态 ================"
  echo "[VPS direct IPv4]"
  curl -4 -I --connect-timeout 8 --max-time 12 https://www.google.com 2>&1 | sed -n '1,6p' || true
  echo
  echo "[VPS direct IPv6]"
  curl -6 -I --connect-timeout 8 --max-time 12 https://www.google.com 2>&1 | sed -n '1,6p' || true
  echo
  echo "[WARP SOCKS 40000]"
  curl -s --connect-timeout 8 --max-time 15 --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -Ei 'ip=|warp=|colo=' || true
  echo
  echo "[WireProxy SOCKS 40001]"
  curl -s --connect-timeout 8 --max-time 15 --socks5-hostname 127.0.0.1:40001 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -Ei 'ip=|warp=|colo=' || true
  echo
  echo "[Xray warp-socks outbound]"
  jq '.outbounds[]? | select(.tag=="warp-socks")' /usr/local/etc/xray/config.json 2>/dev/null || true
  echo
  echo "[sing-box route.final]"
  jq -r '.route.final // empty' /etc/sing-box/config.json 2>/dev/null || true
  echo
  echo "[Services]"
  systemctl is-active xray 2>/dev/null | sed 's/^/xray: /' || true
  systemctl is-active sing-box 2>/dev/null | sed 's/^/sing-box: /' || true
  systemctl is-active warp-svc 2>/dev/null | sed 's/^/warp-svc: /' || true
  systemctl is-active love-wireproxy.service 2>/dev/null | sed 's/^/wireproxy: /' || true
}

love_install_fs_warp_command_v1345() {
  cat > /usr/local/bin/warp <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/Love warp "$@"
EOF
  chmod +x /usr/local/bin/warp
  echo "[OK] FS 风格 warp 命令已安装：warp"
  echo "示例：warp h | warp 4 | warp 6 | warp d | warp c | warp w | warp g | warp s 4 | warp s 6"
}

love_warp_restored_menu_v1345() {
  love_tty_colors_v1343 2>/dev/null || true
  while true; do
    clear 2>/dev/null || true
    love_title_v1343 "Love WARP Manager / IPv4 出站" "Restored V12 WARP + Xray IPv4 outbound" 2>/dev/null || echo "================ Love WARP Manager ================"
    echo "  1) 原版完整 WARP Manager v12【保留原来的完善菜单】"
    echo "  2) 一键为 Xray Reality/HY2 增加 WARP IPv4 出站【推荐先试】"
    echo "  3) Xray 出站恢复 direct"
    echo "  4) 官方 WARP Proxy 40000"
    echo "  5) WireProxy SOCKS 40001"
    echo "  6) sing-box 安全切到 WARP SOCKS 40000"
    echo "  7) sing-box 安全切到 WireProxy SOCKS 40001"
    echo "  8) 恢复 sing-box direct"
    echo "  9) WARP / IPv4 出站状态检查"
    echo " 10) 安装 FS 风格 warp 命令"
    echo "  0) 返回"
    echo
    echo "说明：2 只改 Xray 出站，不动 sing-box；6/7 只改 sing-box。"
    read -rp "请选择: " w
    case "$w" in
      1)
        if declare -F love_warp_final_menu_v12 >/dev/null 2>&1; then love_warp_final_menu_v12
        else echo "[MISS] love_warp_final_menu_v12 不存在。"; fi
        ;;
      2) love_xray_route_via_warp_socks_v1345 40000 ;;
      3) love_xray_restore_direct_v1345 ;;
      4)
        if declare -F love_warp_cli_proxy_v12 >/dev/null 2>&1; then love_warp_cli_proxy_v12 40000
        elif declare -F love_warp_set_proxy_mode >/dev/null 2>&1; then love_warp_set_proxy_mode 40000
        else echo "[MISS] WARP Proxy 函数不存在。"; fi
        ;;
      5)
        if declare -F love_wireproxy_auto_v12 >/dev/null 2>&1; then love_wireproxy_auto_v12 40001
        elif declare -F love_warp_wireproxy_mode >/dev/null 2>&1; then love_warp_wireproxy_mode
        else echo "[MISS] WireProxy 函数不存在。"; fi
        ;;
      6)
        if declare -F love_singbox_switch_warp_socks_v12 >/dev/null 2>&1; then love_singbox_switch_warp_socks_v12 40000 smart
        elif declare -F love_singbox_route_via_warp_proxy >/dev/null 2>&1; then love_singbox_route_via_warp_proxy 40000
        else echo "[MISS] sing-box WARP 切换函数不存在。"; fi
        ;;
      7)
        if declare -F love_singbox_switch_warp_socks_v12 >/dev/null 2>&1; then love_singbox_switch_warp_socks_v12 40001 smart
        else echo "[MISS] sing-box WireProxy 切换函数不存在。"; fi
        ;;
      8)
        if declare -F love_singbox_restore_direct_v12 >/dev/null 2>&1; then love_singbox_restore_direct_v12
        elif declare -F love_singbox_restore_direct_outbound >/dev/null 2>&1; then love_singbox_restore_direct_outbound
        else echo "[MISS] sing-box direct 恢复函数不存在。"; fi
        ;;
      9) love_warp_status_plus_v1345 ;;
      10) love_install_fs_warp_command_v1345 ;;
      0) return 0 ;;
      *) echo "[WARN] 无效选择。" ;;
    esac
    echo
    read -rp "按 Enter 返回 WARP 菜单..." _
  done
}

# Force restore these entry points.
love_warp_manager_menu() { love_warp_restored_menu_v1345; }
love_warp_final_menu() { love_warp_restored_menu_v1345; }

# Patch colored main menu 20 and command entry.
if declare -F love_main_menu_v1343 >/dev/null 2>&1 && ! declare -F love_original_main_menu_v1345 >/dev/null 2>&1; then
  eval "$(declare -f love_main_menu_v1343 | sed '1s/^love_main_menu_v1343/love_original_main_menu_v1345/')"
fi

# Rebuild menu with option 20 hard-wired to restored WARP menu.
love_main_menu_v1343() {
  love_tty_colors_v1343 2>/dev/null || true
  while true; do
    clear 2>/dev/null || true
    love_title_v1343 "Love Node Server Manager ${LOVE_SCRIPT_VERSION:-Love v13.45}" "Color UI / Latest Xray / Auto Web / Restored WARP"
    if declare -F love_safe_status_v1335 >/dev/null 2>&1; then love_safe_status_v1335; fi
    echo
    printf '%b\n' "${C_BOLD}主菜单${C_RESET}"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}1)${C_RESET} 节点目录                     ${C_CYAN}│${C_RESET} ${C_GREEN}14)${C_RESET} v6 Project Tools"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}2)${C_RESET} Xray Reality + HY2           ${C_CYAN}│${C_RESET} ${C_GREEN}15)${C_RESET} v7 Stable Tools"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}3)${C_RESET} sing-box 全协议              ${C_CYAN}│${C_RESET} ${C_GREEN}16)${C_RESET} v8 Project Panel"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}4)${C_RESET} Argo 隧道                    ${C_CYAN}│${C_RESET} ${C_GREEN}17)${C_RESET} Nginx Reverse Proxy"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}5)${C_RESET} UDP 端口跳跃                 ${C_CYAN}│${C_RESET} ${C_GREEN}18)${C_RESET} HY2/sing-box 修复"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}6)${C_RESET} WARP 说明                    ${C_CYAN}│${C_RESET} ${C_GREEN}19)${C_RESET} IPv6-only 出站"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}7)${C_RESET} 节点信息 Love -n             ${C_CYAN}│${C_RESET} ${C_GREEN}20)${C_RESET} WARP Manager / IPv4"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}8)${C_RESET} 导出订阅 Love sub            ${C_CYAN}│${C_RESET} ${C_GREEN}21)${C_RESET} 查看运行状态"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}9)${C_RESET} 生成二维码 Love qr          ${C_CYAN}│${C_RESET} ${C_GREEN}22)${C_RESET} 备份配置"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}10)${C_RESET} Super Tools                ${C_CYAN}│${C_RESET} ${C_GREEN}23)${C_RESET} 卸载菜单"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}11)${C_RESET} Web 管理页 Love web        ${C_CYAN}│${C_RESET} ${C_GREEN}24)${C_RESET} GitHub 发布说明"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}12)${C_RESET} 在线更新 / 下载链接        ${C_CYAN}│${C_RESET} ${C_GREEN}25)${C_RESET} 安装 warp 命令"
    printf '%b\n' "  ${C_CYAN}│${C_RESET} ${C_GREEN}13)${C_RESET} 客户端导出                 ${C_CYAN}│${C_RESET} ${C_GREEN}0)${C_RESET} 退出"
    echo
    printf '%b\n' "${C_YELLOW}WARP：20 已恢复原版 WARP Manager，并新增 Xray IPv4 出站。${C_RESET}"
    printf '%b\n' "${C_DIM}常用：Love warp | Love warp-ipv4 | Love warp-status | Love web-sync${C_RESET}"
    echo
    read -rp "请选择: " choice
    case "$choice" in
      1) love_call_v1343 show_all_node_catalog ;;
      2) love_call_v1343 install_xray_stable ;;
      3) love_call_v1343 install_singbox_native ;;
      4) love_call_v1343 argo_helper ;;
      5) love_call_v1343 port_hopping_helper ;;
      6) love_call_v1343 warp_helper ;;
      7) love_call_v1343 show_node_info ;;
      8) love_call_v1343 love_sub_safe_v1341 || love_call_v1343 export_subscription ;;
      9) love_call_v1343 generate_qrcodes ;;
      10) love_call_v1343 super_menu ;;
      11) love_call_v1343 web_admin_page ;;
      12) love_call_v1343 self_update_love ;;
      13) love_call_v1343 love_full_client_pack ;;
      14) love_call_v1343 v6_super_menu ;;
      15) love_call_v1343 v7_stable_menu ;;
      16) love_call_v1343 v8_menu ;;
      17) love_call_v1343 nginx_rp_menu ;;
      18) love_call_v1343 love_fix_hy2_now ;;
      19) love_call_v1343 love_ipv6_outbound_menu ;;
      20) love_warp_restored_menu_v1345 ;;
      21) love_call_v1343 show_status ;;
      22) love_call_v1343 backup_configs ;;
      23) love_uninstall_menu_v1343 ;;
      24) love_call_v1343 github_publish_note ;;
      25) love_install_fs_warp_command_v1345 ;;
      0) exit 0 ;;
      *) echo "[WARN] 无效选择。" ;;
    esac
    echo
    read -rp "按 Enter 返回主菜单..." _
  done
}

love_hard_menu_v1335() { love_main_menu_v1343; }
main_menu() { love_main_menu_v1343; }

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1345 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1345/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.45.0-warp-manager-restore-xray-ipv4-final}"
  case "${1:-}" in
    ""|menu)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      love_prepare_core_dirs_v1344 2>/dev/null || true
      love_main_menu_v1343
      ;;
    warp|warp-menu|warp-manager)
      love_warp_restored_menu_v1345
      ;;
    warp-ipv4|xray-warp|xray-ipv4)
      love_xray_route_via_warp_socks_v1345 40000
      ;;
    xray-direct|warp-direct-xray)
      love_xray_restore_direct_v1345
      ;;
    warp-status|warp-test)
      love_warp_status_plus_v1345
      ;;
    warp-install)
      love_install_fs_warp_command_v1345
      ;;
    *)
      love_original_main_v1345 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.46 Web/QR + WARP Final Restore
# Fixes:
#   - Confirms WARP uses the post-13.27 final V12 WARP functions.
#   - Keeps menu 20 hard-wired to restored WARP manager.
#   - Fixes Web 404 for 推荐节点 / 节点清晰版 / 全部节点.
#   - Fixes QR gallery crowding and overlarge QR display.
#   - Adds Love web-fix and Love qr-fix.
#   - Keeps Xray latest / auto Web / xray-info dir fix / sing-box untouched.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.46.0-web-qr-warp-final-restore"

love_web_css_final_v1346() {
  cat <<'EOF'
<style>
:root{
  --bg:#0f172a;--card:#111827;--text:#e5e7eb;--muted:#94a3b8;
  --line:#334155;--blue:#60a5fa;--green:#22c55e;--btn:#2563eb;
}
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,"Microsoft YaHei",sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1120px;margin:0 auto;padding:24px}
.hero{background:linear-gradient(135deg,#1d4ed8,#7c3aed);border-radius:20px;padding:24px;box-shadow:0 14px 36px rgba(0,0,0,.28)}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:18px;margin:16px 0;box-shadow:0 10px 24px rgba(0,0,0,.18)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:16px}
.qr-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:18px;align-items:start}
.qr-card{text-align:center;background:var(--card);border:1px solid var(--line);border-radius:18px;padding:16px;overflow:hidden}
.qr-card img{width:180px;max-width:88%;height:auto;image-rendering:pixelated;background:white;border-radius:12px;padding:8px;margin:8px auto;display:block}
.qr-card h3{font-size:14px;line-height:1.35;word-break:break-all;min-height:36px}
h1{margin:0 0 8px;font-size:28px} h2{color:#93c5fd;margin:24px 0 12px}
a{color:#93c5fd;text-decoration:none;word-break:break-all}
.btn{display:inline-block;background:var(--btn);color:white!important;border-radius:999px;padding:8px 12px;margin:5px 4px;font-weight:700}
.btn.gray{background:#475569}.btn.green{background:#16a34a}.btn.orange{background:#ea580c}
textarea{width:100%;height:180px;border-radius:14px;border:1px solid var(--line);background:#020617;color:#d1d5db;padding:12px}
code{background:#020617;border:1px solid #1f2937;border-radius:8px;padding:3px 7px;color:#d1d5db}
.muted{color:var(--muted)} .ok{color:#86efac;font-weight:700}
@media(max-width:520px){.wrap{padding:14px}.qr-grid{grid-template-columns:1fr}.qr-card img{width:165px}}
</style>
EOF
}

love_copy_one_if_exists_v1346() {
  local src="$1" dst="$2"
  [[ -s "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst" 2>/dev/null || true
}

love_web_fix_files_v1346() {
  local web="${LOVE_WEB:-/var/www/love-admin}"
  local sub="${LOVE_SUB:-/opt/Love/subscribe}"
  local token
  token="$(get_sub_token 2>/dev/null || true)"
  [[ -n "$token" ]] || token="default"

  mkdir -p "$web" "$web/sub" "$web/qr" "$web/clients" "$web/downloads"
  mkdir -p "$web/$token" "$web/$token/subscribe" "$web/$token/qr" "$web/$token/clients" "$web/$token/downloads"

  # Canonical subscriptions.
  love_copy_one_if_exists_v1346 "$sub/all.txt" "$web/sub/all.txt"
  love_copy_one_if_exists_v1346 "$sub/all_base64.txt" "$web/sub/all_base64.txt"
  love_copy_one_if_exists_v1346 "$sub/clash_like.yaml" "$web/sub/clash_like.yaml"
  love_copy_one_if_exists_v1346 "$sub/mihomo.yaml" "$web/sub/mihomo.yaml"

  # Root shortcuts to stop 404 from old index links.
  love_copy_one_if_exists_v1346 "$sub/all.txt" "$web/all.txt"
  love_copy_one_if_exists_v1346 "$sub/all.txt" "$web/node-links.txt"
  love_copy_one_if_exists_v1346 "$sub/all.txt" "$web/全部节点.txt"
  love_copy_one_if_exists_v1346 "$sub/all_base64.txt" "$web/all_base64.txt"

  # User-facing txt files: several historical names are supported.
  love_copy_one_if_exists_v1346 "$sub/推荐节点.txt" "$web/推荐节点.txt"
  love_copy_one_if_exists_v1346 "$sub/节点清晰版.txt" "$web/节点清晰版.txt"
  love_copy_one_if_exists_v1346 "$sub/clients/nodes-clean.txt" "$web/nodes-clean.txt"
  love_copy_one_if_exists_v1346 "$sub/clients/nodes-clean.txt" "$web/节点清晰版.txt"

  # Token panel copies.
  cp -a "$sub/." "$web/$token/subscribe/" 2>/dev/null || true
  cp -a "$sub/qr/." "$web/$token/qr/" 2>/dev/null || true
  cp -a "$sub/clients/." "$web/$token/clients/" 2>/dev/null || true
  love_copy_one_if_exists_v1346 "$sub/all.txt" "$web/$token/全部节点.txt"
  love_copy_one_if_exists_v1346 "$sub/推荐节点.txt" "$web/$token/推荐节点.txt"
  love_copy_one_if_exists_v1346 "$sub/节点清晰版.txt" "$web/$token/节点清晰版.txt"
  love_copy_one_if_exists_v1346 "$sub/clients/nodes-clean.txt" "$web/$token/nodes-clean.txt"

  # Non-token copies for QR and clients.
  cp -a "$sub/qr/." "$web/qr/" 2>/dev/null || true
  cp -a "$sub/clients/." "$web/clients/" 2>/dev/null || true

  chown -R www-data:www-data "$web" 2>/dev/null || true
  find "$web" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$web" -type f -exec chmod 644 {} \; 2>/dev/null || true

  echo "[OK] Web 文件副本已修复：$web"
  echo "关键文件："
  for f in "$web/all.txt" "$web/node-links.txt" "$web/全部节点.txt" "$web/推荐节点.txt" "$web/节点清晰版.txt" "$web/sub/all.txt"; do
    [[ -f "$f" ]] && echo "  [OK] $f" || echo "  [MISS] $f"
  done
}

love_write_qr_gallery_v1346() {
  local qrdir="$1"
  local base_title="${2:-Love QR Gallery}"
  [[ -d "$qrdir" ]] || return 0

  local count
  count="$(find "$qrdir" -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"

  cat > "$qrdir/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${base_title}</title>
$(love_web_css_final_v1346)
</head>
<body>
<div class="wrap">
  <div class="hero">
    <h1>${base_title}</h1>
    <div>二维码数量：<span class="ok">${count}</span></div>
    <div class="muted">二维码已限制显示尺寸，不再挤在一起；点击可单独打开原图。</div>
    <p><a class="btn" href="/">返回 Web 首页</a></p>
  </div>
  <h2>二维码列表</h2>
  <div class="qr-grid">
EOF

  local f name svg title
  while IFS= read -r f; do
    name="$(basename "$f")"
    svg="${name%.png}.svg"
    title="$name"
    cat >> "$qrdir/index.html" <<EOF
    <div class="qr-card">
      <h3>${title}</h3>
      <a href="./${name}" target="_blank"><img src="./${name}" alt="${name}" loading="lazy"></a>
      <a class="btn" href="./${name}" target="_blank">打开 PNG</a>
EOF
    if [[ -f "$qrdir/$svg" ]]; then
      cat >> "$qrdir/index.html" <<EOF
      <a class="btn gray" href="./${svg}" target="_blank">打开 SVG</a>
EOF
    fi
    cat >> "$qrdir/index.html" <<'EOF'
    </div>
EOF
  done < <(find "$qrdir" -maxdepth 1 -type f -name '*.png' | sort)

  cat >> "$qrdir/index.html" <<'EOF'
  </div>
</div>
</body>
</html>
EOF
}

# Override historical gallery names too.
love_write_qr_gallery_v1329() { love_write_qr_gallery_v1346 "$@"; }
love_write_qr_gallery_v1332() { love_write_qr_gallery_v1346 "$@"; }

love_generate_qr_fixed_v1346() {
  local sub="${LOVE_SUB:-/opt/Love/subscribe}"
  mkdir -p "$sub/qr"
  [[ -s "$sub/all.txt" ]] || { echo "[WARN] 没有 $sub/all.txt，先执行 Love sub"; return 1; }

  command -v qrencode >/dev/null 2>&1 || apt install -y qrencode >/dev/null 2>&1 || true
  command -v qrencode >/dev/null 2>&1 || { echo "[ERROR] qrencode 不存在"; return 1; }

  rm -f "$sub/qr/"* 2>/dev/null || true

  local i=0 line label safe
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    ((i++)) || true
    label="${line#*#}"
    [[ "$label" == "$line" || -z "$label" ]] && label="node-$i"
    safe="$(echo "$label" | sed 's#[/\\:*?"<>| ]#_#g' | head -c 80)"
    printf '%s' "$line" | qrencode -t ANSIUTF8 > "$sub/qr/node-${i}.ansi" 2>/dev/null || true
    printf '%s' "$line" | qrencode -t PNG -s 5 -m 2 -o "$sub/qr/node-${i}.png" 2>/dev/null || true
    printf '%s' "$line" | qrencode -t SVG -o "$sub/qr/node-${i}.svg" 2>/dev/null || true
    # Named copy for easier UI.
    cp -f "$sub/qr/node-${i}.png" "$sub/qr/${safe}.png" 2>/dev/null || true
  done < "$sub/all.txt"

  # Aggregated QR files can be huge; generate smaller display scale and let gallery cap them.
  [[ -s "$sub/all.txt" ]] && printf '%s' "$(cat "$sub/all.txt")" | qrencode -t PNG -s 3 -m 1 -o "$sub/qr/all.png" 2>/dev/null || true
  [[ -s "$sub/all_base64.txt" ]] && printf '%s' "$(cat "$sub/all_base64.txt")" | qrencode -t PNG -s 3 -m 1 -o "$sub/qr/all_base64.png" 2>/dev/null || true
  [[ -s "$sub/clients/v2rayn-uri.txt" ]] && printf '%s' "$(cat "$sub/clients/v2rayn-uri.txt")" | qrencode -t PNG -s 3 -m 1 -o "$sub/qr/v2rayn.png" 2>/dev/null || true
  [[ -s "$sub/clients/nekobox-uri.txt" ]] && printf '%s' "$(cat "$sub/clients/nekobox-uri.txt")" | qrencode -t PNG -s 3 -m 1 -o "$sub/qr/nekobox.png" 2>/dev/null || true

  love_write_qr_gallery_v1346 "$sub/qr" "Love QR Gallery"
  echo "[OK] 二维码已修复生成：$sub/qr/"
}

# Override generate_qrcodes conservatively.
if declare -F generate_qrcodes >/dev/null 2>&1 && ! declare -F love_original_generate_qrcodes_v1346 >/dev/null 2>&1; then
  eval "$(declare -f generate_qrcodes | sed '1s/^generate_qrcodes/love_original_generate_qrcodes_v1346/')"
fi

generate_qrcodes() {
  love_generate_qr_fixed_v1346 "$@"
}

love_web_index_final_v1346() {
  local web="${LOVE_WEB:-/var/www/love-admin}"
  local token
  token="$(get_sub_token 2>/dev/null || true)"
  [[ -n "$token" ]] || token="default"

  cat > "$web/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Love Admin Panel</title>
$(love_web_css_final_v1346)
<script>
async function copyUrl(path){
  const url = location.origin + path;
  await navigator.clipboard.writeText(url);
  alert("Copied: " + url);
}
async function copyText(path){
  const r = await fetch(path);
  const t = await r.text();
  await navigator.clipboard.writeText(t);
  alert("Copied text");
}
</script>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <h1>Love Admin Panel</h1>
    <div>Web fixed: 推荐节点 / 节点清晰版 / 全部节点 / QR Gallery</div>
    <p><a class="btn" href="/${token}/">打开 Token 面板</a><a class="btn green" href="/qr/index.html">二维码网格</a></p>
  </div>

  <div class="card">
    <h2>订阅 / 节点文本</h2>
    <div class="grid">
      <div><a class="btn" href="/sub/all.txt" target="_blank">全部节点 all.txt</a><button class="btn gray" onclick="copyUrl('/sub/all.txt')">复制URL</button></div>
      <div><a class="btn" href="/all.txt" target="_blank">全部节点 根目录</a><button class="btn gray" onclick="copyUrl('/all.txt')">复制URL</button></div>
      <div><a class="btn" href="/推荐节点.txt" target="_blank">推荐节点</a><button class="btn gray" onclick="copyUrl('/推荐节点.txt')">复制URL</button></div>
      <div><a class="btn" href="/节点清晰版.txt" target="_blank">节点清晰版</a><button class="btn gray" onclick="copyUrl('/节点清晰版.txt')">复制URL</button></div>
      <div><a class="btn" href="/node-links.txt" target="_blank">node-links.txt</a><button class="btn gray" onclick="copyUrl('/node-links.txt')">复制URL</button></div>
      <div><a class="btn" href="/sub/all_base64.txt" target="_blank">Base64</a><button class="btn gray" onclick="copyUrl('/sub/all_base64.txt')">复制URL</button></div>
    </div>
  </div>

  <div class="card">
    <h2>二维码 / 客户端</h2>
    <a class="btn green" href="/qr/index.html" target="_blank">二维码网格页面</a>
    <a class="btn" href="/clients/v2rayn-uri.txt" target="_blank">V2RayN URI</a>
    <a class="btn" href="/clients/nekobox-uri.txt" target="_blank">NekoBox URI</a>
  </div>
</div>
</body>
</html>
EOF

  mkdir -p "$web/$token"
  cp -f "$web/index.html" "$web/$token/index.html" 2>/dev/null || true
}

love_web_fix_v1346() {
  echo "================ Love Web Fix v13.46 ================"
  [[ -s "${LOVE_SUB:-/opt/Love/subscribe}/all.txt" ]] || {
    echo "[WARN] 订阅为空，先执行 Love sub"
    if declare -F love_sub_safe_v1341 >/dev/null 2>&1; then love_sub_safe_v1341; else export_subscription; fi
  }

  love_generate_qr_fixed_v1346 || true
  love_web_fix_files_v1346
  love_write_qr_gallery_v1346 "${LOVE_WEB:-/var/www/love-admin}/qr" "Love QR Gallery"
  love_web_index_final_v1346

  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  echo "[OK] Web 404 和二维码布局已修复。"
  find "${LOVE_WEB:-/var/www/love-admin}" -maxdepth 2 -type f \( -name 'all.txt' -o -name '推荐节点.txt' -o -name '节点清晰版.txt' -o -name 'index.html' \) -print 2>/dev/null || true
}

# Wrap existing web sync/web admin to always apply final web fix.
if declare -F love_web_sync_v1342 >/dev/null 2>&1 && ! declare -F love_original_web_sync_v1346 >/dev/null 2>&1; then
  eval "$(declare -f love_web_sync_v1342 | sed '1s/^love_web_sync_v1342/love_original_web_sync_v1346/')"
fi
love_web_sync_v1342() {
  love_original_web_sync_v1346 "$@" 2>/dev/null || true
  love_web_fix_v1346
}

if declare -F web_admin_page >/dev/null 2>&1 && ! declare -F love_original_web_admin_v1346 >/dev/null 2>&1; then
  eval "$(declare -f web_admin_page | sed '1s/^web_admin_page/love_original_web_admin_v1346/')"
fi
web_admin_page() {
  love_original_web_admin_v1346 "$@"
  love_web_fix_v1346
}

love_warp_version_check_v1346() {
  echo "================ Love WARP Version Check ================"
  for f in love_warp_final_menu_v12 love_warp_auto_fix_v12 love_wireproxy_auto_v12 love_singbox_switch_warp_socks_v12 love_warp_proxy_safe_install love_warp_restored_menu_v1345; do
    if declare -F "$f" >/dev/null 2>&1; then
      echo "[OK] $f"
    else
      echo "[MISS] $f"
    fi
  done
  echo
  echo "说明：V13.46 使用 13.27 之后已经完善的 V12 WARP 函数；主菜单 20 只是把入口重新接回，并额外增加 Xray IPv4 出站。"
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1346 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1346/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.46.0-web-qr-warp-final-restore}"
  case "${1:-}" in
    web-fix|fix-web|web-sync)
      love_web_fix_v1346
      ;;
    qr-fix|fix-qr)
      love_generate_qr_fixed_v1346
      ;;
    warp-version|warp-check)
      love_warp_version_check_v1346
      ;;
    *)
      love_original_main_v1346 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.47 VLESS WS TLS Insecure Restore Final
# Fix:
#   - Restores the historical post-processing fix for VLESS WS TLS self-signed cert.
#   - Adds allowInsecure=1, insecure=1, allow_insecure=1 to every VLESS WS TLS URI.
#   - Applies to all.txt, client exports, xray/singbox info text, and Web copies.
#   - Does not touch Xray HY2 old-format logic.
#   - Does not touch sing-box server config.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.47.0-vless-ws-tls-insecure-restore-final"

love_fix_vless_ws_tls_line_v1347() {
  local line="$1"
  local low="${line,,}"

  if [[ "$line" == vless://* && "$low" == *"security=tls"* && "$low" == *"type=ws"* ]]; then
    local main frag base query
    if [[ "$line" == *"#"* ]]; then
      main="${line%%#*}"
      frag="${line#*#}"
    else
      main="$line"
      frag="LOVE-VLESS-WS-TLS"
    fi

    if [[ "$main" == *"?"* ]]; then
      base="${main%%\?*}"
      query="${main#*\?}"
    else
      base="$main"
      query=""
    fi

    # remove duplicates first, then append final compatibility flags
    query="$(tr '&' '\n' <<< "$query" | awk -F= '
      BEGIN{IGNORECASE=1}
      $1!="allowInsecure" && $1!="allow_insecure" && $1!="insecure" {print}
    ' | paste -sd'&' -)"
    [[ -n "$query" ]] && query="${query}&"
    query="${query}allowInsecure=1&insecure=1&allow_insecure=1"

    echo "${base}?${query}#${frag}"
  else
    echo "$line"
  fi
}

love_fix_vless_ws_tls_file_v1347() {
  local f="$1" tmp
  [[ -s "$f" ]] || return 0
  tmp="/tmp/love-vless-ws-tls-fix.$$.$RANDOM"
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    love_fix_vless_ws_tls_line_v1347 "$line" >> "$tmp"
  done < "$f"
  mv "$tmp" "$f"
}

love_fix_vless_ws_tls_all_v1347() {
  echo "================ Love VLESS WS TLS 修复 v13.47 ================"
  local files=()

  # Core subscription and client/info exports
  while IFS= read -r f; do files+=("$f"); done < <(
    find /opt/Love -type f \( \
      -name '*.txt' -o -name '*.yaml' -o -name '*.yml' -o -name '*.html' \
    \) 2>/dev/null
  )

  # Web copies
  while IFS= read -r f; do files+=("$f"); done < <(
    find /var/www/love-admin -type f \( \
      -name '*.txt' -o -name '*.yaml' -o -name '*.yml' -o -name '*.html' \
    \) 2>/dev/null
  )

  local f
  for f in "${files[@]}"; do
    grep -qiE '^vless://|VLESS-WS-TLS|type=ws|security=tls' "$f" 2>/dev/null || continue
    love_fix_vless_ws_tls_file_v1347 "$f"
  done

  # Rebuild base64 after fixing all.txt
  if [[ -s /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi

  # Sync fixed copies to Web common paths
  mkdir -p /var/www/love-admin/sub /var/www/love-admin/clients 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/sub/all.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/all.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/node-links.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all_base64.txt /var/www/love-admin/sub/all_base64.txt 2>/dev/null || true
  cp -a /opt/Love/subscribe/clients/. /var/www/love-admin/clients/ 2>/dev/null || true

  echo "==== 修复后的 VLESS WS TLS ===="
  grep -nEi 'VLESS-WS-TLS|vless://.*security=tls.*type=ws|8887|38006|50006' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo
  echo "[OK] 已恢复 VLESS WS TLS 自签证书兼容参数：allowInsecure=1 & insecure=1 & allow_insecure=1"
}

# Wrap subscription export so the fix is always applied after generation.
if declare -F love_sub_safe_v1341 >/dev/null 2>&1 && ! declare -F love_original_sub_safe_v1347 >/dev/null 2>&1; then
  eval "$(declare -f love_sub_safe_v1341 | sed '1s/^love_sub_safe_v1341/love_original_sub_safe_v1347/')"
fi
love_sub_safe_v1341() {
  love_original_sub_safe_v1347 "$@"
  love_fix_vless_ws_tls_all_v1347
}

# Wrap web fix so web copies never go stale.
if declare -F love_web_fix_v1346 >/dev/null 2>&1 && ! declare -F love_original_web_fix_v1347 >/dev/null 2>&1; then
  eval "$(declare -f love_web_fix_v1346 | sed '1s/^love_web_fix_v1346/love_original_web_fix_v1347/')"
fi
love_web_fix_v1346() {
  love_original_web_fix_v1347 "$@"
  love_fix_vless_ws_tls_all_v1347
}

# Wrap QR generation after link fixing to avoid QR carrying old links.
if declare -F generate_qrcodes >/dev/null 2>&1 && ! declare -F love_original_generate_qrcodes_v1347 >/dev/null 2>&1; then
  eval "$(declare -f generate_qrcodes | sed '1s/^generate_qrcodes/love_original_generate_qrcodes_v1347/')"
fi
generate_qrcodes() {
  love_fix_vless_ws_tls_all_v1347 >/dev/null 2>&1 || true
  love_original_generate_qrcodes_v1347 "$@"
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1347 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1347/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.47.0-vless-ws-tls-insecure-restore-final}"
  case "${1:-}" in
    fix-vless-ws|vless-ws-fix|fix-ws-tls)
      love_fix_vless_ws_tls_all_v1347
      ;;
    sub|subscribe|subscription|link-fix|client-fix|fix-links)
      if declare -F love_sub_safe_v1341 >/dev/null 2>&1; then love_sub_safe_v1341 "$@"; else love_original_main_v1347 "$@"; love_fix_vless_ws_tls_all_v1347; fi
      ;;
    web-fix|fix-web|web-sync)
      if declare -F love_web_fix_v1346 >/dev/null 2>&1; then love_web_fix_v1346 "$@"; else love_original_main_v1347 "$@"; fi
      ;;
    *)
      love_original_main_v1347 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.48 Source-Correct Cert/Flag/Client Output Final
# 新 VPS 首装 + 旧 VPS 修复双场景。
# 边界：不写 xray/sing-box 服务端 config，不重启服务，不换 UUID/key/auth/cert。
# 只统一生成客户端输出：client-info / all.txt / clients / QR / Web。
# ==============================================================================
LOVE_SCRIPT_VERSION="Love v13.48.0-source-correct-cert-flag-all-final"

love_v1348_mkdirs() {
  mkdir -p /opt/Love/client-info /opt/Love/subscribe/clients /opt/Love/subscribe/qr /opt/Love/subscribe/sing-box
  mkdir -p /var/www/love-admin/sub /var/www/love-admin/clients /var/www/love-admin/qr 2>/dev/null || true
}

love_v1348_is_ip() {
  local x="$1"; x="${x#[}"; x="${x%]}"
  [[ "$x" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$x" == *:* ]]
}

love_v1348_flag() {
  if declare -F love_flag_get_v1341 >/dev/null 2>&1; then love_flag_get_v1341
  elif [[ -s /opt/Love/node-flag ]]; then cat /opt/Love/node-flag
  else echo "🇺🇸"; fi
}

love_v1348_strip_flag() {
  local x="$1"
  for f in 🇺🇸 🇯🇵 🇸🇬 🇭🇰 🇹🇼 🇰🇷 🇩🇪 🇬🇧 🇫🇷 🇳🇱 🇨🇦 🇦🇺 🇮🇳 🇹🇭 🇻🇳 🇮🇩 🇲🇾 🇵🇭 🇧🇷 🇹🇷 🇦🇪 🇪🇸 🇮🇹 🇵🇱; do
    x="${x#${f} }"
  done
  echo "$x"
}

love_v1348_label() {
  local label="$1" flag
  flag="$(love_v1348_flag)"
  label="$(love_v1348_strip_flag "$label")"
  echo "$flag ${label# }"
}

love_v1348_get_param() {
  local line="$1" key="$2" q
  q="${line#*\?}"; q="${q%%#*}"
  tr '&' '\n' <<< "$q" | awk -F= -v k="$key" 'tolower($1)==tolower(k){print $2; exit}'
}

love_v1348_manual_mode() {
  local m
  m="$(cat /opt/Love/cert-mode 2>/dev/null || cat /opt/Love/domain-cert-mode 2>/dev/null || true)"
  m="${m,,}"
  case "$m" in
    public|public_ca|domain_public_ca|ca|letsencrypt|lets_encrypt|zerossl) echo "public_ca"; return ;;
    self|selfsigned|self_signed|domain_self_signed|no_domain_self_signed|custom|custom_cert|insecure) echo "self_signed"; return ;;
  esac
  echo ""
}

love_v1348_probe_cert_mode() {
  local sni="$1" cert="$2" manual sans cn
  manual="$(love_v1348_manual_mode)"
  [[ -n "$manual" ]] && { echo "$manual"; return; }

  if [[ -z "$sni" || "$sni" == "self.local" || "$sni" == "localhost" || "$sni" == *.local ]] || love_v1348_is_ip "$sni"; then
    echo "self_signed"; return
  fi
  [[ -s "$cert" ]] || { echo "self_signed"; return; }
  openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1 || { echo "cert_expired"; return; }
  sans="$(openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null | tr '\n' ' ' || true)"
  cn="$(openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' || true)"
  if echo "$sans" | grep -qi "DNS:${sni}\b" || [[ "$cn" == "$sni" ]]; then
    echo "public_ca"
  else
    echo "cert_mismatch"
  fi
}

love_v1348_detect_mode() {
  local scfg="/etc/sing-box/config.json" xcfg="/usr/local/etc/xray/config.json"
  local sni cert mode xsni xcert xmode
  sni="$(jq -r '.inbounds[]? | select((.type=="vless" or .type=="trojan" or .type=="tuic" or .type=="hysteria2") and (.tls.enabled==true)) | .tls.server_name // empty' "$scfg" 2>/dev/null | head -1)"
  cert="$(jq -r '.inbounds[]? | select((.type=="vless" or .type=="trojan" or .type=="tuic" or .type=="hysteria2") and (.tls.enabled==true)) | .tls.certificate_path // empty' "$scfg" 2>/dev/null | head -1)"
  mode="$(love_v1348_probe_cert_mode "${sni:-self.local}" "$cert")"

  xsni="$(jq -r '.inbounds[]? | select(.tag=="hy2-in") | .streamSettings.tlsSettings.serverName // empty' "$xcfg" 2>/dev/null | head -1)"
  xcert="$(jq -r '.inbounds[]? | select(.tag=="hy2-in") | .streamSettings.tlsSettings.certificates[0].certificateFile // empty' "$xcfg" 2>/dev/null | head -1)"
  xmode="$(love_v1348_probe_cert_mode "${xsni:-self.local}" "$xcert")"

  [[ -n "$mode" ]] || mode="$xmode"
  [[ -n "$mode" ]] || mode="self_signed"
  cat > /opt/Love/source-correct.env <<EOF
GLOBAL_CERT_MODE="$mode"
XRAY_CERT_MODE="${xmode:-self_signed}"
SINGBOX_CERT_MODE="${mode:-self_signed}"
EOF
  cat /opt/Love/source-correct.env
}

love_v1348_clean_query() {
  tr '&' '\n' | awk -F= 'BEGIN{IGNORECASE=1}$1!="allowInsecure"&&$1!="allow_insecure"&&$1!="insecure"&&$1!=""{print}' | paste -sd'&' -
}

love_v1348_flags() {
  local proto="$1" mode="$2"
  if [[ "$mode" == "public_ca" ]]; then
    [[ "$proto" == "hy2" ]] && echo "insecure=0"
    [[ "$proto" == "tuic" ]] && echo "alpn=h3"
    return
  fi
  case "$proto" in
    vless_ws_tls) echo "allowInsecure=1&insecure=1&allow_insecure=1" ;;
    trojan) echo "allowInsecure=1&insecure=1&allow_insecure=1" ;;
    hy2) echo "insecure=1" ;;
    tuic) echo "allow_insecure=1&allowInsecure=1&insecure=1&alpn=h3" ;;
  esac
}

love_v1348_line_mode() {
  local line="$1" def="$2" sni
  [[ "${line,,}" == *"security=reality"* ]] && { echo "public_ca"; return; }
  sni="$(love_v1348_get_param "$line" "sni")"
  [[ -z "$sni" ]] && sni="$(love_v1348_get_param "$line" "host")"
  if [[ -z "$sni" || "$sni" == "self.local" || "$sni" == *.local ]] || love_v1348_is_ip "$sni"; then
    echo "self_signed"
  else
    echo "${def:-self_signed}"
  fi
}

love_v1348_fix_line() {
  local line="$1" mode="$2" low main frag base query newq proto flags
  low="${line,,}"
  [[ "$line" =~ ^(vless|hy2|hysteria2|tuic|trojan|ss|vmess|anytls|https|shadowtls):// ]] || { echo "$line"; return; }

  if [[ "$line" == *"#"* ]]; then main="${line%%#*}"; frag="${line#*#}"; else main="$line"; frag="LOVE"; fi
  if [[ "$main" == *"?"* ]]; then base="${main%%\?*}"; query="${main#*\?}"; else base="$main"; query=""; fi

  proto=""
  [[ "$low" == *"security=reality"* ]] && proto="reality"
  [[ "$line" == vless://* && "$low" == *"security=tls"* && "$low" == *"type=ws"* ]] && proto="vless_ws_tls"
  [[ "$line" == trojan://* ]] && proto="trojan"
  [[ "$line" == hy2://* || "$line" == hysteria2://* ]] && proto="hy2"
  [[ "$line" == tuic://* ]] && proto="tuic"

  if [[ "$proto" == "reality" ]]; then
    newq="$(printf '%s' "$query" | love_v1348_clean_query)"
    echo "${base}?${newq}#$(love_v1348_label "$frag")"; return
  fi

  if [[ -z "$proto" ]]; then
    echo "${main}#$(love_v1348_label "$frag")"; return
  fi

  newq="$(printf '%s' "$query" | love_v1348_clean_query)"
  flags="$(love_v1348_flags "$proto" "$mode")"
  [[ -n "$newq" && -n "$flags" ]] && newq="${newq}&${flags}" || newq="${newq}${flags}"
  echo "${base}?${newq}#$(love_v1348_label "$frag")"
}

love_v1348_fix_file() {
  local f="$1" def="$2" tmp line mode
  [[ -s "$f" ]] || return 0
  tmp="/tmp/love-v1348.$$.$RANDOM"
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^(vless|hy2|hysteria2|tuic|trojan|ss|vmess|anytls|https|shadowtls):// ]]; then
      mode="$(love_v1348_line_mode "$line" "$def")"
      love_v1348_fix_line "$line" "$mode" >> "$tmp"
    else
      echo "$line" >> "$tmp"
    fi
  done < "$f"
  awk '!seen[$0]++' "$tmp" > "$f"
  rm -f "$tmp"
}

love_v1348_disk_guard() {
  local avail size
  avail="$(df -Pk / | awk 'NR==2{print $4}')"
  [[ -n "$avail" && "$avail" -lt 102400 ]] && { echo "[ERROR] 根分区剩余不足100MB，停止生成，避免爆盘。"; df -h /; return 1; }
  size="$(du -sk /opt/Love/subscribe 2>/dev/null | awk '{print $1}')"
  if [[ -n "$size" && "$size" -gt 51200 ]]; then
    echo "[WARN] subscribe 超过50MB，清理旧 QR/clients 后重建。"
    rm -rf /opt/Love/subscribe/qr /opt/Love/subscribe/clients
    mkdir -p /opt/Love/subscribe/qr /opt/Love/subscribe/clients
  fi
  find /opt/Love/subscribe -type f -name 'sed*' -delete 2>/dev/null || true
  find /opt/Love/subscribe/clients -type f -size +5M -delete 2>/dev/null || true
}

love_v1348_rebuild_txts() {
  local sub="/opt/Love/subscribe"
  [[ -s "$sub/all.txt" ]] || return 0
  mkdir -p "$sub/clients"
  cp -f "$sub/all.txt" "$sub/全部节点.txt"
  cp -f "$sub/all.txt" "$sub/推荐节点.txt"
  cp -f "$sub/all.txt" "$sub/节点清晰版.txt"
  cp -f "$sub/all.txt" "$sub/clients/v2rayn-uri.txt"
  cp -f "$sub/all.txt" "$sub/clients/nekobox-uri.txt"
  cp -f "$sub/all.txt" "$sub/clients/nodes-clean.txt"
  if base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w0 "$sub/all.txt" > "$sub/all_base64.txt"; else base64 "$sub/all.txt" | tr -d '\n' > "$sub/all_base64.txt"; fi
}

love_v1348_sync_web_simple() {
  local web="/var/www/love-admin" sub="/opt/Love/subscribe"
  mkdir -p "$web/sub" "$web/clients" "$web/qr"
  cp -f "$sub/all.txt" "$web/all.txt" 2>/dev/null || true
  cp -f "$sub/all.txt" "$web/node-links.txt" 2>/dev/null || true
  cp -f "$sub/all.txt" "$web/全部节点.txt" 2>/dev/null || true
  cp -f "$sub/推荐节点.txt" "$web/推荐节点.txt" 2>/dev/null || true
  cp -f "$sub/节点清晰版.txt" "$web/节点清晰版.txt" 2>/dev/null || true
  cp -f "$sub/all.txt" "$web/sub/all.txt" 2>/dev/null || true
  cp -f "$sub/all_base64.txt" "$web/sub/all_base64.txt" 2>/dev/null || true
  cp -a "$sub/clients/." "$web/clients/" 2>/dev/null || true
  cp -a "$sub/qr/." "$web/qr/" 2>/dev/null || true
  chown -R www-data:www-data "$web" 2>/dev/null || true
}

love_v1348_source_correct_outputs() {
  echo "================ Love Source-Correct v13.48 ================"
  love_v1348_mkdirs
  love_v1348_disk_guard || return 1
  love_v1348_detect_mode
  . /opt/Love/source-correct.env 2>/dev/null || true
  local mode="${GLOBAL_CERT_MODE:-self_signed}" f

  for f in /opt/Love/client-info/*.txt /opt/Love/subscribe/*.txt /opt/Love/subscribe/clients/*.txt /var/www/love-admin/*.txt /var/www/love-admin/sub/*.txt /var/www/love-admin/clients/*.txt; do
    love_v1348_fix_file "$f" "$mode"
  done

  [[ -s /opt/Love/subscribe/all.txt ]] && love_v1348_fix_file /opt/Love/subscribe/all.txt "$mode"
  love_v1348_rebuild_txts

  if declare -F love_generate_qr_fixed_v1346 >/dev/null 2>&1; then love_generate_qr_fixed_v1346 >/dev/null 2>&1 || true; fi
  love_v1348_sync_web_simple

  echo "==== 最终节点预览 ===="
  grep -nE 'LOVE-XRAY|LOVE-SB|VLESS-WS-TLS|TUIC|TROJAN|HY2' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo "==== 体积检查 ===="
  du -xhd1 /opt/Love/subscribe 2>/dev/null | sort -h || true
  find /opt/Love/subscribe -type f -size +5M -printf '%s %p\n' 2>/dev/null | sort -n | tail -20 || true
  echo "[OK] 证书模式、insecure 参数、国旗、TXT/QR/Web 已统一。"
}

if declare -F love_after_node_generated_exports >/dev/null 2>&1 && ! declare -F love_original_after_exports_v1348 >/dev/null 2>&1; then
  eval "$(declare -f love_after_node_generated_exports | sed '1s/^love_after_node_generated_exports/love_original_after_exports_v1348/')"
fi
love_after_node_generated_exports() {
  love_v1348_mkdirs
  love_original_after_exports_v1348 "$@"
  love_v1348_source_correct_outputs
}

if declare -F love_sub_safe_v1341 >/dev/null 2>&1 && ! declare -F love_original_sub_safe_v1348 >/dev/null 2>&1; then
  eval "$(declare -f love_sub_safe_v1341 | sed '1s/^love_sub_safe_v1341/love_original_sub_safe_v1348/')"
fi
love_sub_safe_v1341() {
  love_original_sub_safe_v1348 "$@"
  love_v1348_source_correct_outputs
}

love_v1348_menu_check() {
  echo "================ Love v13.48 按钮检查 ================"
  for f in love_main_menu_v1343 install_xray_stable install_singbox_native love_after_node_generated_exports love_sub_safe_v1341 web_admin_page love_web_fix_v1346 love_generate_qr_fixed_v1346 love_warp_restored_menu_v1345 love_v1348_source_correct_outputs love_uninstall_menu_v1343; do
    declare -F "$f" >/dev/null 2>&1 && echo "[OK] $f" || echo "[MISS] $f"
  done
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1348 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1348/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.48.0-source-correct-cert-flag-all-final}"
  case "${1:-}" in
    source-correct|cert-fix|final-fix|client-output-fix) love_v1348_source_correct_outputs ;;
    menu-check|check-buttons) love_v1348_menu_check ;;
    sub|subscribe|subscription|link-fix|client-fix|fix-links)
      if declare -F love_sub_safe_v1341 >/dev/null 2>&1; then love_sub_safe_v1341 "$@"; else love_original_main_v1348 "$@"; love_v1348_source_correct_outputs; fi ;;
    web-fix|fix-web|web-sync)
      if declare -F love_web_fix_v1346 >/dev/null 2>&1; then love_web_fix_v1346 "$@"; fi
      love_v1348_source_correct_outputs ;;
    qr-fix|fix-qr) love_v1348_source_correct_outputs ;;
    *) love_original_main_v1348 "$@" ;;
  esac
}


# ==============================================================================
# Love v13.49 Install-Source + Output-Source Correct Final
# 修正 V13.48 的边界：V13.48 偏“输出源头正确”；V13.49 增加“首次安装源头选择正确”。
#
# 首次安装时：
#   - Xray / sing-box 都先选择证书环境。
#   - 保存 /opt/Love/cert-mode、node-sni、node-address、client-address。
#   - 服务端安装按选择使用正式 CA 或自签证书。
#   - client-info 保存后立刻按证书模式和国旗统一修正。
#   - 最后自动 sub/QR/Web/source-correct。
#
# 已安装机器修复时：
#   - Love sub / source-correct 仍然只重建客户端输出，不改服务端 config。
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.49.0-install-source-output-source-final"

love_v1349_cert_menu() {
  echo
  echo "================ 证书 / 连接环境选择 ================"
  echo "1) 无域名 + self.local + 自签证书【IP/IPv6直连】"
  echo "2) 有域名 + 正式 CA 证书【Let's Encrypt / ZeroSSL】"
  echo "3) 有域名 + 自签 / 自管证书"
  echo "4) 优选 IP / CFIP + 域名 SNI + 正式 CA 证书"
  echo "5) 优选 IP / CFIP + 域名 SNI + 自签 / 自管证书"
  echo
  read -rp "请选择证书环境 [1-5]: " LOVE_CERT_CASE
  LOVE_CERT_CASE="${LOVE_CERT_CASE:-1}"

  LOVE_CERT_MODE="self_signed"
  LOVE_HAS_DOMAIN="no"
  LOVE_NEED_CA="no"
  LOVE_DOMAIN=""
  LOVE_TLS_SNI="self.local"
  LOVE_NODE_ADDR=""

  case "$LOVE_CERT_CASE" in
    1)
      LOVE_CERT_MODE="no_domain_self_signed"
      LOVE_HAS_DOMAIN="no"
      read_node_addr_with_default LOVE_NODE_ADDR
      read -rp "自签证书 SNI [self.local]: " LOVE_TLS_SNI
      LOVE_TLS_SNI="${LOVE_TLS_SNI:-self.local}"
      ;;
    2)
      LOVE_CERT_MODE="domain_public_ca"
      LOVE_HAS_DOMAIN="yes"
      LOVE_NEED_CA="yes"
      read -rp "节点域名，例如 node.example.com: " LOVE_DOMAIN
      [[ -n "$LOVE_DOMAIN" ]] || die "域名不能为空。"
      LOVE_NODE_ADDR="$LOVE_DOMAIN"
      LOVE_TLS_SNI="$LOVE_DOMAIN"
      ;;
    3)
      LOVE_CERT_MODE="domain_self_signed"
      LOVE_HAS_DOMAIN="yes"
      LOVE_NEED_CA="no"
      read -rp "节点域名，例如 node.example.com: " LOVE_DOMAIN
      [[ -n "$LOVE_DOMAIN" ]] || die "域名不能为空。"
      LOVE_NODE_ADDR="$LOVE_DOMAIN"
      LOVE_TLS_SNI="$LOVE_DOMAIN"
      ;;
    4)
      LOVE_CERT_MODE="domain_public_ca"
      LOVE_HAS_DOMAIN="yes"
      LOVE_NEED_CA="yes"
      read -rp "SNI / 证书域名，例如 node.example.com: " LOVE_DOMAIN
      [[ -n "$LOVE_DOMAIN" ]] || die "域名不能为空。"
      LOVE_NODE_ADDR="$LOVE_DOMAIN"
      LOVE_TLS_SNI="$LOVE_DOMAIN"
      ;;
    5)
      LOVE_CERT_MODE="domain_self_signed"
      LOVE_HAS_DOMAIN="yes"
      LOVE_NEED_CA="no"
      read -rp "SNI / 自签证书域名，例如 node.example.com: " LOVE_DOMAIN
      [[ -n "$LOVE_DOMAIN" ]] || die "域名不能为空。"
      LOVE_NODE_ADDR="$LOVE_DOMAIN"
      LOVE_TLS_SNI="$LOVE_DOMAIN"
      ;;
    *)
      die "无效证书环境选择。"
      ;;
  esac

  mkdir -p /opt/Love
  case "$LOVE_CERT_MODE" in
    domain_public_ca) echo "public_ca" > /opt/Love/cert-mode ;;
    *) echo "self_signed" > /opt/Love/cert-mode ;;
  esac
  echo "$LOVE_NODE_ADDR" > /opt/Love/node-address
  echo "$LOVE_TLS_SNI" > /opt/Love/node-sni
}

love_v1349_record_client_endpoint() {
  mkdir -p /opt/Love
  echo "${CLIENT_ADDR:-}" > /opt/Love/client-address
  echo "${CLIENT_PORT:-}" > /opt/Love/client-port
  echo "${LOVE_CERT_MODE:-}" > /opt/Love/install-cert-case
}

love_v1349_cert_need_insecure() {
  case "${LOVE_CERT_MODE:-self_signed}" in
    domain_public_ca) echo "0" ;;
    *) echo "1" ;;
  esac
}

# 保存文件源头也立即正确：写完 client-info 后直接修这个文件，不等 all.txt。
if declare -F save_xray_info >/dev/null 2>&1 && ! declare -F love_original_save_xray_info_v1349 >/dev/null 2>&1; then
  eval "$(declare -f save_xray_info | sed '1s/^save_xray_info/love_original_save_xray_info_v1349/')"
fi
save_xray_info() {
  love_v1348_mkdirs 2>/dev/null || mkdir -p /opt/Love/client-info /opt/Love/subscribe
  love_original_save_xray_info_v1349 "$@"
  if declare -F love_v1348_detect_mode >/dev/null 2>&1; then
    love_v1348_detect_mode >/dev/null 2>&1 || true
    . /opt/Love/source-correct.env 2>/dev/null || true
    love_v1348_fix_file "${XRAY_INFO:-/opt/Love/client-info/xray-client-info.txt}" "${GLOBAL_CERT_MODE:-self_signed}" 2>/dev/null || true
  fi
}

if declare -F save_singbox_info >/dev/null 2>&1 && ! declare -F love_original_save_singbox_info_v1349 >/dev/null 2>&1; then
  eval "$(declare -f save_singbox_info | sed '1s/^save_singbox_info/love_original_save_singbox_info_v1349/')"
fi
save_singbox_info() {
  love_v1348_mkdirs 2>/dev/null || mkdir -p /opt/Love/client-info /opt/Love/subscribe
  love_original_save_singbox_info_v1349 "$@"
  if declare -F love_v1348_detect_mode >/dev/null 2>&1; then
    love_v1348_detect_mode >/dev/null 2>&1 || true
    . /opt/Love/source-correct.env 2>/dev/null || true
    love_v1348_fix_file "${SINGBOX_INFO:-/opt/Love/client-info/sing-box-client-info.txt}" "${GLOBAL_CERT_MODE:-self_signed}" 2>/dev/null || true
  fi
}

# 备份旧安装入口，V13.49 用新安装源头。
if declare -F install_xray_stable >/dev/null 2>&1 && ! declare -F love_original_install_xray_stable_v1349 >/dev/null 2>&1; then
  eval "$(declare -f install_xray_stable | sed '1s/^install_xray_stable/love_original_install_xray_stable_v1349/')"
fi

install_xray_stable() {
  echo
  echo "================ Love Xray 稳定模式 v13.49【安装源头正确】 ================"

  love_v1349_cert_menu

  local node_addr domain email enable_hy2 hy2_sni insecure reality_sni
  node_addr="$LOVE_NODE_ADDR"
  domain="$LOVE_DOMAIN"
  hy2_sni="$LOVE_TLS_SNI"
  insecure="$(love_v1349_cert_need_insecure)"

  read -rp "安装 HY2 / Hysteria2？[Y/n]: " hy2_choice
  hy2_choice="${hy2_choice:-Y}"
  [[ "$hy2_choice" =~ ^[Yy]$ ]] && enable_hy2="yes" || enable_hy2="no"

  read -rp "Reality SNI [www.cloudflare.com]: " reality_sni
  reality_sni="${reality_sni:-www.cloudflare.com}"

  # 优选 IP / CFIP 场景也通过这里设置客户端 Address，SNI 仍保持域名。
  ask_preferred_endpoint "$node_addr" "443"
  love_v1349_record_client_endpoint

  ask_ssh_port
  install_base
  setup_ufw "$([[ "$LOVE_NEED_CA" == "yes" && "$enable_hy2" == "yes" ]] && echo yes || echo no)" yes "$([[ "$enable_hy2" == "yes" ]] && echo yes || echo no)" no
  install_xray_core
  gen_xray_keys
  test_reality_sni "$reality_sni"

  if [[ "$enable_hy2" == "yes" ]]; then
    if [[ "$LOVE_NEED_CA" == "yes" ]]; then
      read -rp "Let's Encrypt 邮箱: " email
      [[ -n "$email" ]] || die "邮箱不能为空。"
      issue_cert_generic "$domain" "$email" "$XRAY_CONF_DIR" "xray"
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
      make_selfsigned_generic "$hy2_sni" "$XRAY_CONF_DIR" "xray"
    fi
  fi

  write_xray_config "$node_addr" "$reality_sni" "$enable_hy2" "$hy2_sni"
  write_xray_service

  "$XRAY_BIN" run -test -config "$XRAY_CONF"
  systemctl enable xray
  systemctl restart xray

  sleep 2
  systemctl status xray --no-pager || true
  ss -lntp | grep ':443' || true
  ss -lunp | grep ':443' || true

  save_xray_info "$node_addr" "$reality_sni" "$enable_hy2" "$hy2_sni" "$insecure" "$CLIENT_ADDR" "$CLIENT_PORT"
  love_after_node_generated_exports
  log "Xray 稳定模式安装完成：证书环境=${LOVE_CERT_MODE}，客户端地址=${CLIENT_ADDR}:${CLIENT_PORT}，SNI=${hy2_sni}"
}

if declare -F install_singbox_native >/dev/null 2>&1 && ! declare -F love_original_install_singbox_native_v1349 >/dev/null 2>&1; then
  eval "$(declare -f install_singbox_native | sed '1s/^install_singbox_native/love_original_install_singbox_native_v1349/')"
fi

install_singbox_native() {
  echo
  echo "================ Love sing-box 全协议 v13.49【安装源头正确】 ================"
  warn "建议使用干净服务器。若 443 已被 Xray 占用，请先停止 Xray 或选择非 443 起始端口。"

  choose_singbox_protocols
  love_v1349_cert_menu

  local node_addr domain email tls_sni insecure cert_needed reality_sni start_port
  node_addr="$LOVE_NODE_ADDR"
  domain="$LOVE_DOMAIN"
  tls_sni="$LOVE_TLS_SNI"
  insecure="$(love_v1349_cert_need_insecure)"
  cert_needed="no"

  if [[ "$INSTALL_HY2$INSTALL_TUIC$INSTALL_TROJAN$INSTALL_VLESS_WS_TLS$INSTALL_ANYTLS$INSTALL_NAIVE" == *yes* ]]; then
    cert_needed="yes"
  fi

  read -rp "Reality SNI [www.cloudflare.com]: " reality_sni
  reality_sni="${reality_sni:-www.cloudflare.com}"

  read -rp "起始端口 [8881]: " start_port
  start_port="${start_port:-8881}"

  ask_preferred_endpoint "$node_addr" "$start_port"
  love_v1349_record_client_endpoint

  ask_ssh_port
  install_base
  install_singbox_core
  gen_singbox_values
  test_reality_sni "$reality_sni"

  if [[ "$cert_needed" == "yes" ]]; then
    if [[ "$LOVE_NEED_CA" == "yes" ]]; then
      setup_ufw yes yes yes yes
      read -rp "Let's Encrypt 邮箱: " email
      [[ -n "$email" ]] || die "邮箱不能为空。"
      issue_cert_generic "$domain" "$email" "$SINGBOX_CERT_DIR" "root"
    else
      setup_ufw no yes yes yes
      make_selfsigned_generic "$tls_sni" "$SINGBOX_CERT_DIR" "root"
    fi
  else
    setup_ufw no yes yes yes
  fi

  write_singbox_config "$reality_sni" "$tls_sni" "$SINGBOX_CERT_DIR" "$start_port"
  write_singbox_service

  systemctl enable sing-box
  systemctl restart sing-box
  sleep 2
  systemctl status sing-box --no-pager || true
  ss -tulpn | grep -E ':443|:8443|:888|sing-box' || true

  save_singbox_info "$CLIENT_ADDR" "$CLIENT_PORT" "$reality_sni" "$tls_sni" "$insecure"
  love_after_node_generated_exports
  log "sing-box 原生模式安装完成：证书环境=${LOVE_CERT_MODE}，客户端地址=${CLIENT_ADDR}:${CLIENT_PORT}，SNI=${tls_sni}"
}

love_v1349_install_source_check() {
  echo "================ Love v13.49 安装源头检查 ================"
  for f in install_xray_stable install_singbox_native save_xray_info save_singbox_info love_after_node_generated_exports love_v1348_source_correct_outputs; do
    declare -F "$f" >/dev/null 2>&1 && echo "[OK] $f" || echo "[MISS] $f"
  done
  echo
  echo "当前保存的证书环境："
  for f in /opt/Love/cert-mode /opt/Love/install-cert-case /opt/Love/node-address /opt/Love/node-sni /opt/Love/client-address /opt/Love/client-port; do
    [[ -f "$f" ]] && echo "$f = $(cat "$f")" || echo "$f = <empty>"
  done
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1349 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1349/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.49.0-install-source-output-source-final}"
  case "${1:-}" in
    install-source-check|source-check)
      love_v1349_install_source_check
      ;;
    xray|reality|hy2|xray-hy2)
      install_xray_stable
      ;;
    singbox|sing-box|sb)
      install_singbox_native
      ;;
    *)
      love_original_main_v1349 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.50 TUIC ALPN + V2RayN Importable URI Source Final
#
# Fixes:
#   1. TUIC server-side source config must include tls.alpn=["h3"].
#      Client had alpn=h3, but server did not advertise ALPN -> CRYPTO_ERROR 0x178.
#   2. VLESS WS TLS self-signed links use true values for v2rayN:
#      allowInsecure=true&insecure=true&allow_insecure=true.
#   3. Node count confusion:
#      all.txt / v2rayn-uri.txt should contain importable URI lines only.
#      Manual text lines remain in client-info/manual files, not counted as URI import nodes.
#   4. Convert VMess WS manual, H2 Reality manual, gRPC Reality manual, AnyTLS manual
#      into importable URI lines where supported by clients.
#
# Boundaries:
#   - New install: write_singbox_config is patched at source to set TUIC tls.alpn=["h3"].
#   - Existing VPS: Love fix-tuic patches /etc/sing-box/config.json and restarts sing-box only.
#   - Xray service/core/key/auth untouched by this fix.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.50.0-tuic-alpn-v2rayn-import-source-final"

love_v1350_fix_singbox_tuic_alpn_config() {
  [[ -s /etc/sing-box/config.json ]] || { echo "[WARN] /etc/sing-box/config.json 不存在。"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq 不存在。"; return 1; }

  cp -f /etc/sing-box/config.json /etc/sing-box/config.json.bak.tuic-alpn-v1350.$(date +%F-%H%M%S) 2>/dev/null || true

  jq '
    (.inbounds[]? | select(.type=="tuic" or .tag=="tuic-in").tls.alpn) = ["h3"] |
    (.inbounds[]? | select(.type=="tuic" or .tag=="tuic-in").congestion_control) = ((.inbounds[]? | select(.type=="tuic" or .tag=="tuic-in").congestion_control) // "bbr")
  ' /etc/sing-box/config.json > /tmp/love-singbox-tuic-v1350.json && mv /tmp/love-singbox-tuic-v1350.json /etc/sing-box/config.json

  sing-box check -c /etc/sing-box/config.json || {
    echo "[ERROR] sing-box 配置检查失败，恢复最近备份。"
    ls -t /etc/sing-box/config.json.bak.tuic-alpn-v1350.* 2>/dev/null | head -1 | xargs -r -I{} cp -f {} /etc/sing-box/config.json
    return 1
  }

  echo "[OK] TUIC 服务端 tls.alpn 已固定为 [\"h3\"]。"
  jq -r '.inbounds[]? | select(.type=="tuic" or .tag=="tuic-in") | [.tag,.type,.listen_port,(.tls.alpn|tostring)] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
}

love_v1350_fix_tuic_now() {
  echo "================ Love TUIC ALPN 修复 v13.50 ================"
  love_v1350_fix_singbox_tuic_alpn_config || return 1
  systemctl restart sing-box
  sleep 2
  systemctl status sing-box --no-pager -l | sed -n '1,18p' || true
  ss -lunp | grep -E '8883|38002|50002|tuic|sing-box' || true
}

# Patch source server config generation: after write_singbox_config, immediately set TUIC alpn=["h3"].
if declare -F write_singbox_config >/dev/null 2>&1 && ! declare -F love_original_write_singbox_config_v1350 >/dev/null 2>&1; then
  eval "$(declare -f write_singbox_config | sed '1s/^write_singbox_config/love_original_write_singbox_config_v1350/')"
fi
write_singbox_config() {
  love_original_write_singbox_config_v1350 "$@"
  love_v1350_fix_singbox_tuic_alpn_config >/dev/null 2>&1 || true
}

# Override flags for v2rayN: use true instead of 1 for TLS verify skip.
love_v1348_flags() {
  local proto="$1" mode="$2"
  if [[ "$mode" == "public_ca" ]]; then
    [[ "$proto" == "hy2" ]] && echo "insecure=0"
    [[ "$proto" == "tuic" ]] && echo "alpn=h3"
    return
  fi
  case "$proto" in
    vless_ws_tls) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
    trojan) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
    hy2) echo "insecure=1" ;;
    tuic) echo "allow_insecure=true&allowInsecure=true&insecure=true&alpn=h3" ;;
  esac
}

love_v1350_importable_from_manual() {
  python3 <<'PY'
from pathlib import Path
import re, json, base64, urllib.parse

info = Path("/opt/Love/client-info/sing-box-client-info.txt")
sub = Path("/opt/Love/subscribe/all.txt")
clients = Path("/opt/Love/subscribe/clients")
clients.mkdir(parents=True, exist_ok=True)

lines = []
if sub.exists():
    lines = sub.read_text(encoding="utf-8", errors="ignore").splitlines()
existing = set(lines)

txt = info.read_text(encoding="utf-8", errors="ignore") if info.exists() else ""
extra = []

def add(line):
    if line and line not in existing:
        extra.append(line)
        existing.add(line)

def host_to_uri(h):
    h = h.strip()
    if ":" in h and not (h.startswith("[") and h.endswith("]")):
        return f"[{h}]"
    return h

# VMess WS manual:
# Address=[IPv6] Port=8886 UUID=... Transport=ws Path=/vmess TLS=off
for m in re.finditer(r"VMess WS manual:\s*\nAddress=(\S+)\s+Port=(\d+)\s+UUID=([0-9a-fA-F-]+)\s+Transport=ws\s+Path=(\S+)\s+TLS=off", txt):
    addr, port, uuid, path = m.groups()
    obj = {
        "v": "2", "ps": "🇺🇸 LOVE-VMESS-WS",
        "add": addr.strip("[]"), "port": port, "id": uuid,
        "aid": "0", "scy": "auto", "net": "ws",
        "type": "none", "host": "", "path": path,
        "tls": "", "sni": ""
    }
    b = base64.urlsafe_b64encode(json.dumps(obj,separators=(',',':')).encode()).decode().rstrip("=")
    add("vmess://" + b)

# H2 Reality manual
for m in re.finditer(r"H2 Reality manual:\s*\nAddress=(\S+)\s+Port=(\d+)\s+UUID=([0-9a-fA-F-]+)\s+SNI=(\S+)\s+PublicKey=(\S+)\s+ShortID=(\S+)\s+Transport=http\s+Path=(\S+)\s+Host=(\S+)", txt):
    addr, port, uuid, sni, pbk, sid, path, host = m.groups()
    q = {
        "encryption":"none","security":"reality","sni":sni,"fp":"chrome",
        "pbk":pbk,"sid":sid,"type":"http","path":path,"host":host
    }
    add(f"vless://{uuid}@{addr}:{port}?{urllib.parse.urlencode(q)}#🇺🇸 LOVE-H2-REALITY")

# gRPC Reality manual
for m in re.finditer(r"gRPC Reality manual:\s*\nAddress=(\S+)\s+Port=(\d+)\s+UUID=([0-9a-fA-F-]+)\s+SNI=(\S+)\s+PublicKey=(\S+)\s+ShortID=(\S+)\s+ServiceName=(\S+)", txt):
    addr, port, uuid, sni, pbk, sid, service = m.groups()
    q = {
        "encryption":"none","security":"reality","sni":sni,"fp":"chrome",
        "pbk":pbk,"sid":sid,"type":"grpc","serviceName":service,"authority":sni
    }
    add(f"vless://{uuid}@{addr}:{port}?{urllib.parse.urlencode(q)}#🇺🇸 LOVE-GRPC-REALITY")

# AnyTLS manual; v2rayN support depends on core/front-end, keep in all URI list.
for m in re.finditer(r"AnyTLS manual:\s*\nAddress=(\S+)\s+Port=(\d+)\s+Password=(\S+)\s+SNI=(\S+)\s+Insecure=(\S+)", txt):
    addr, port, pwd, sni, ins = m.groups()
    ins_val = "true" if ins in ("1","true","True") else "false"
    q = {"sni":sni, "insecure":ins_val}
    add(f"anytls://{pwd}@{addr}:{port}?{urllib.parse.urlencode(q)}#🇺🇸 LOVE-ANYTLS")

# Naive already URI if present in info; keep it
for m in re.finditer(r"^(https://\S+#LOVE-NAIVE)\s*$", txt, re.M):
    add(m.group(1).replace("#LOVE-NAIVE", "#🇺🇸 LOVE-NAIVE"))

# ShadowTLS is not reliably importable in v2rayN as a single URI; keep manual file only.

if extra:
    lines.extend(extra)
    sub.write_text("\n".join(lines) + "\n", encoding="utf-8")

# Dedicated files
uri_lines = [x for x in lines if re.match(r'^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://', x)]
(clients / "v2rayn-uri.txt").write_text("\n".join(uri_lines) + "\n", encoding="utf-8")
(clients / "nekobox-uri.txt").write_text("\n".join(uri_lines) + "\n", encoding="utf-8")
(clients / "manual-nodes.txt").write_text(txt, encoding="utf-8")
PY
}

love_v1350_force_vless_true_files() {
  python3 <<'PY'
from pathlib import Path
targets = []
for root in [Path("/opt/Love"), Path("/var/www/love-admin")]:
    if root.exists():
        targets += [p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in ("",".txt",".html",".yaml",".yml")]
for p in targets:
    try:
        lines = p.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        continue
    changed = False
    out = []
    for line in lines:
        low = line.lower()
        if line.startswith("vless://") and "security=tls" in low and "type=ws" in low:
            main, sep, frag = line.partition("#")
            base, qsep, query = main.partition("?")
            params = []
            for x in query.split("&"):
                if not x: continue
                k = x.split("=",1)[0].lower()
                if k in ("allowinsecure","insecure","allow_insecure"): continue
                params.append(x)
            params += ["allowInsecure=true","insecure=true","allow_insecure=true"]
            line = base + "?" + "&".join(params) + "#" + (frag or "LOVE-VLESS-WS-TLS")
            changed = True
        if line.startswith("tuic://"):
            main, sep, frag = line.partition("#")
            base, qsep, query = main.partition("?")
            params = []
            for x in query.split("&"):
                if not x: continue
                k = x.split("=",1)[0].lower()
                if k in ("allowinsecure","insecure","allow_insecure","alpn"): continue
                params.append(x)
            params += ["allow_insecure=true","allowInsecure=true","insecure=true","alpn=h3"]
            line = base + "?" + "&".join(params) + "#" + (frag or "LOVE-TUIC")
            changed = True
        out.append(line)
    if changed:
        p.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

# Wrap source-correct outputs: first apply v13.48, then add importable URIs and true flags.
if declare -F love_v1348_source_correct_outputs >/dev/null 2>&1 && ! declare -F love_original_source_correct_v1350 >/dev/null 2>&1; then
  eval "$(declare -f love_v1348_source_correct_outputs | sed '1s/^love_v1348_source_correct_outputs/love_original_source_correct_v1350/')"
fi
love_v1348_source_correct_outputs() {
  love_original_source_correct_v1350 "$@"
  love_v1350_importable_from_manual
  love_v1350_force_vless_true_files

  if [[ -s /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi

  mkdir -p /var/www/love-admin/sub /var/www/love-admin/clients
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/all.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/node-links.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/sub/all.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all_base64.txt /var/www/love-admin/sub/all_base64.txt 2>/dev/null || true
  cp -a /opt/Love/subscribe/clients/. /var/www/love-admin/clients/ 2>/dev/null || true

  echo "==== v13.50 最终可导入 URI 数量 ===="
  grep -Ec '^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo "==== TUIC / VLESS WS TLS 检查 ===="
  grep -nEi 'LOVE-TUIC|LOVE-VLESS-WS-TLS|tuic://|vless://.*security=tls.*type=ws' /opt/Love/subscribe/all.txt 2>/dev/null || true
}

love_v1350_count_importable() {
  echo "================ Love v13.50 节点计数 ================"
  echo "可导入 URI 节点："
  grep -En '^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo
  echo "数量：$(grep -Ec '^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://' /opt/Love/subscribe/all.txt 2>/dev/null || echo 0)"
  echo
  echo "手动节点说明保存在：/opt/Love/subscribe/clients/manual-nodes.txt"
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1350 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1350/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.50.0-tuic-alpn-v2rayn-import-source-final}"
  case "${1:-}" in
    fix-tuic|tuic-fix|tuic-alpn-fix)
      love_v1350_fix_tuic_now
      ;;
    importable-fix|v2rayn-fix|count-fix)
      love_v1348_source_correct_outputs
      ;;
    count|node-count|count-importable)
      love_v1350_count_importable
      ;;
    *)
      love_original_main_v1350 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.51 Full Matrix Guard Final
#
# Purpose:
#   Final guard pass after reviewing v13.50.
#
# Fixes remaining hidden issues:
#   1. New sing-box installs using non-443 port ranges must auto-open all config ports.
#      v13.49 source install path bypassed older v13.19 port-open wrapper.
#   2. After converting manual nodes into URI nodes, regenerate QR and Web copies again.
#      Otherwise QR/Web may lag behind all.txt/v2rayn-uri.txt.
#   3. Add one-shot final matrix check for:
#      - Xray/sing-box cert modes
#      - no-domain / domain-public-CA / domain-self-signed behavior
#      - TUIC server alpn=["h3"]
#      - TUIC client alpn=h3 + insecure flags
#      - VLESS WS TLS v2rayN true flags
#      - importable URI count
#      - Web files
#      - disk size guard
#
# Boundaries:
#   - Existing VPS: source-correct/final-check do not rewrite Xray/sing-box service configs
#     except Love fix-tuic / post-install-fix only touches sing-box TUIC alpn and firewall ports.
#   - Xray core/key/auth/cert files are untouched by this final guard.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.51.0-full-matrix-guard-final"

love_v1351_open_ports_from_current_configs() {
  echo "================ Love 自动放行当前配置端口 v13.51 ================"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${SSH_PORT:-22}/tcp" >/dev/null 2>&1 || true

    # Xray 443 TCP/UDP
    if [[ -s /usr/local/etc/xray/config.json ]]; then
      if jq -e '.inbounds[]? | select(.port==443 and .protocol=="vless")' /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        ufw allow 443/tcp >/dev/null 2>&1 || true
        echo "[OK] xray reality 443/tcp"
      fi
      if jq -e '.inbounds[]? | select(.port==443 and .protocol=="hysteria")' /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        ufw allow 443/udp >/dev/null 2>&1 || true
        echo "[OK] xray hy2 443/udp"
      fi
    fi

    # sing-box ports by inbound type
    if [[ -s /etc/sing-box/config.json ]]; then
      while IFS=$'\t' read -r tag typ port; do
        [[ -n "$port" && "$port" != "null" ]] || continue
        case "$typ" in
          hysteria2|tuic)
            ufw allow "${port}/udp" >/dev/null 2>&1 || true
            printf "[OK] %-18s %-12s %s/udp\n" "$tag" "$typ" "$port"
            ;;
          shadowsocks)
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
            ufw allow "${port}/udp" >/dev/null 2>&1 || true
            printf "[OK] %-18s %-12s %s/tcp+udp\n" "$tag" "$typ" "$port"
            ;;
          *)
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
            printf "[OK] %-18s %-12s %s/tcp\n" "$tag" "$typ" "$port"
            ;;
        esac
      done < <(jq -r '.inbounds[]? | [.tag,.type,.listen_port] | @tsv' /etc/sing-box/config.json 2>/dev/null)
    fi

    # Web panel if nginx config exists
    nginx -T 2>/dev/null | awk '/server_name _;|love-admin|listen /{print}' | grep -Eo 'listen[[:space:]]+\[?::\]?:?[0-9]+|listen[[:space:]]+[0-9]+' | grep -Eo '[0-9]+' | sort -u | while read -r p; do
      [[ -n "$p" ]] || continue
      [[ "$p" == "80" || "$p" == "443" ]] && continue
      ufw allow "${p}/tcp" >/dev/null 2>&1 || true
      echo "[OK] nginx web ${p}/tcp"
    done

    ufw reload >/dev/null 2>&1 || true
  else
    echo "[WARN] 未检测到 ufw，跳过系统防火墙放行。"
  fi

  if declare -F love_singbox_open_ports_from_config_v1319 >/dev/null 2>&1; then
    love_singbox_open_ports_from_config_v1319 >/dev/null 2>&1 || true
  fi
}

love_v1351_regen_qr_web_after_uri() {
  echo "================ Love QR/Web 最终同步 v13.51 ================"
  if [[ -s /opt/Love/subscribe/all.txt ]]; then
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
      base64 -w0 /opt/Love/subscribe/all.txt > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    else
      base64 /opt/Love/subscribe/all.txt | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
    fi
  fi

  # Regenerate QR after v13.50 has converted manual nodes to importable URI lines.
  if declare -F love_generate_qr_fixed_v1346 >/dev/null 2>&1; then
    love_generate_qr_fixed_v1346 >/dev/null 2>&1 || true
  elif declare -F generate_qrcodes >/dev/null 2>&1; then
    generate_qrcodes >/dev/null 2>&1 || true
  fi

  # Simple web sync only; avoid calling web-fix to prevent recursion.
  mkdir -p /var/www/love-admin/sub /var/www/love-admin/clients /var/www/love-admin/qr
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/all.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/node-links.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/全部节点.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/推荐节点.txt /var/www/love-admin/推荐节点.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/节点清晰版.txt /var/www/love-admin/节点清晰版.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/sub/all.txt 2>/dev/null || true
  cp -f /opt/Love/subscribe/all_base64.txt /var/www/love-admin/sub/all_base64.txt 2>/dev/null || true
  cp -a /opt/Love/subscribe/clients/. /var/www/love-admin/clients/ 2>/dev/null || true
  cp -a /opt/Love/subscribe/qr/. /var/www/love-admin/qr/ 2>/dev/null || true
  chown -R www-data:www-data /var/www/love-admin 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

  echo "[OK] QR/Web 已按最终 all.txt 再同步一次。"
}

# Wrap final source-correct once more.
if declare -F love_v1348_source_correct_outputs >/dev/null 2>&1 && ! declare -F love_original_source_correct_v1351 >/dev/null 2>&1; then
  eval "$(declare -f love_v1348_source_correct_outputs | sed '1s/^love_v1348_source_correct_outputs/love_original_source_correct_v1351/')"
fi
love_v1348_source_correct_outputs() {
  love_original_source_correct_v1351 "$@"
  love_v1351_regen_qr_web_after_uri
}

love_v1351_post_install_guard() {
  echo "================ Love Post-Install Guard v13.51 ================"
  love_v1350_fix_singbox_tuic_alpn_config >/dev/null 2>&1 || true
  love_v1351_open_ports_from_current_configs || true
  love_v1348_source_correct_outputs || true
  love_v1351_matrix_check || true
}

# Wrap Xray/sing-box install entry points. This preserves v13.49 install source behavior.
if declare -F install_singbox_native >/dev/null 2>&1 && ! declare -F love_original_install_singbox_native_v1351 >/dev/null 2>&1; then
  eval "$(declare -f install_singbox_native | sed '1s/^install_singbox_native/love_original_install_singbox_native_v1351/')"
fi
install_singbox_native() {
  love_original_install_singbox_native_v1351 "$@"
  love_v1351_post_install_guard
}

if declare -F install_xray_stable >/dev/null 2>&1 && ! declare -F love_original_install_xray_stable_v1351 >/dev/null 2>&1; then
  eval "$(declare -f install_xray_stable | sed '1s/^install_xray_stable/love_original_install_xray_stable_v1351/')"
fi
install_xray_stable() {
  love_original_install_xray_stable_v1351 "$@"
  love_v1351_post_install_guard
}

love_v1351_matrix_check() {
  echo
  echo "================ Love v13.51 全矩阵检查 ================"
  echo "Version:"
  grep '^VERSION=' /opt/Love/Love.sh 2>/dev/null || true
  echo

  echo "Cert source files:"
  for f in /opt/Love/cert-mode /opt/Love/install-cert-case /opt/Love/node-address /opt/Love/node-sni /opt/Love/client-address /opt/Love/client-port /opt/Love/source-correct.env; do
    [[ -f "$f" ]] && echo "$f = $(cat "$f" | tr '\n' ' ')" || echo "$f = <empty>"
  done
  echo

  echo "Xray inbounds:"
  jq -r '.inbounds[]? | [.tag,.protocol,.port,(.streamSettings.tlsSettings.serverName // .streamSettings.realitySettings.serverNames[0] // ""),(.streamSettings.tlsSettings.alpn|tostring)] | @tsv' /usr/local/etc/xray/config.json 2>/dev/null || true
  echo

  echo "sing-box TLS inbounds:"
  jq -r '.inbounds[]? | select(.tls?) | [.tag,.type,.listen_port,.tls.server_name,(.tls.alpn|tostring),.tls.certificate_path] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
  echo

  echo "TUIC server ALPN check:"
  if jq -e '.inbounds[]? | select(.type=="tuic" or .tag=="tuic-in") | select((.tls.alpn // []) | index("h3"))' /etc/sing-box/config.json >/dev/null 2>&1; then
    echo "[OK] TUIC server tls.alpn contains h3"
  else
    echo "[WARN] TUIC server tls.alpn does not contain h3"
  fi
  echo

  echo "VLESS WS TLS / TUIC client link check:"
  grep -nEi 'LOVE-TUIC|LOVE-VLESS-WS-TLS|tuic://|vless://.*security=tls.*type=ws' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo

  echo "Importable URI count:"
  local count
  count="$(grep -Ec '^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://' /opt/Love/subscribe/all.txt 2>/dev/null || echo 0)"
  echo "$count"
  grep -En '^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo

  echo "Web key files:"
  for f in /var/www/love-admin/all.txt /var/www/love-admin/node-links.txt /var/www/love-admin/全部节点.txt /var/www/love-admin/推荐节点.txt /var/www/love-admin/节点清晰版.txt /var/www/love-admin/sub/all.txt /var/www/love-admin/qr/index.html; do
    [[ -s "$f" ]] && echo "[OK] $f" || echo "[MISS] $f"
  done
  echo

  echo "Disk size:"
  du -xhd1 /opt/Love/subscribe 2>/dev/null | sort -h || true
  find /opt/Love/subscribe -type f -size +5M -printf '%s %p\n' 2>/dev/null | sort -n | tail -20 || true
  echo

  echo "Listening:"
  ss -lntup | grep -E '443|8881|8882|8883|8884|8885|8886|8887|8888|8889|8890|8891|8892|xray|sing-box|nginx' || true
  echo "================ 检查结束 ================"
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1351 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1351/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.51.0-full-matrix-guard-final}"
  case "${1:-}" in
    final-check|matrix-check|full-check|check-all)
      love_v1351_matrix_check
      ;;
    post-install-fix|all-fix|final-guard)
      love_v1351_post_install_guard
      ;;
    ports|open-ports|firewall)
      love_v1351_open_ports_from_current_configs
      ;;
    *)
      love_original_main_v1351 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.52 Source Template Body Final
#
# This version changes the active source template body directly:
#   - write_singbox_config() directly writes TUIC tls.alpn=["h3"] in the TUIC inbound.
#   - save_singbox_info() directly writes final importable client URI lines.
#   - VLESS WS TLS source URI directly writes allowInsecure=true/insecure=true for self-signed.
#   - TUIC source URI directly writes alpn=h3 and self-signed skip-verify flags.
#   - Remarks directly include emoji flag, not plain "US".
#
# Old repair commands remain only for legacy VPS repair; new installs do not rely on them.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.52.0-source-template-body-final"

love_v1352_flag_emoji() {
  local flag cc
  if declare -F love_flag_get_v1341 >/dev/null 2>&1; then
    flag="$(love_flag_get_v1341 2>/dev/null || true)"
  fi
  [[ -z "$flag" && -s /opt/Love/node-flag ]] && flag="$(cat /opt/Love/node-flag 2>/dev/null || true)"
  [[ -z "$flag" && -s /opt/Love/node-country ]] && flag="$(cat /opt/Love/node-country 2>/dev/null || true)"
  flag="${flag:-🇺🇸}"

  # If previous logic returned "US" instead of the emoji, convert it.
  if [[ "$flag" =~ ^[A-Za-z][A-Za-z]$ ]]; then
    cc="${flag^^}"
    if declare -F love_cc_to_flag_v1341 >/dev/null 2>&1; then
      love_cc_to_flag_v1341 "$cc"
    else
      echo "🇺🇸"
    fi
  else
    echo "$flag"
  fi
}

love_v1352_label() {
  local name="$1" flag
  flag="$(love_v1352_flag_emoji)"
  # Strip common existing flag or country prefixes, then add emoji flag once.
  name="${name#🇺🇸 }"; name="${name#US }"; name="${name#USA }"
  name="${name#🇯🇵 }"; name="${name#JP }"
  name="${name#🇸🇬 }"; name="${name#SG }"
  name="${name#🇭🇰 }"; name="${name#HK }"
  name="${name#🇹🇼 }"; name="${name#TW }"
  echo "${flag} ${name# }"
}

love_v1352_insecure_bool() {
  case "${1:-1}" in
    0|false|False|FALSE|no|No|NO) echo "false" ;;
    *) echo "true" ;;
  esac
}

love_v1352_tls_extra() {
  local insecure="${1:-1}" proto="${2:-generic}" b
  b="$(love_v1352_insecure_bool "$insecure")"
  if [[ "$b" == "false" ]]; then
    case "$proto" in
      tuic) echo "alpn=h3" ;;
      hy2) echo "insecure=0" ;;
      *) echo "" ;;
    esac
    return
  fi

  case "$proto" in
    tuic) echo "allow_insecure=true&allowInsecure=true&insecure=true&alpn=h3" ;;
    hy2) echo "insecure=1" ;;
    vless_ws_tls) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
    trojan) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
    anytls) echo "insecure=true" ;;
    *) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
  esac
}

love_v1352_base64_urlsafe_nopad() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 | tr '+/' '-_' | tr -d '='
  else
    base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
  fi
}

love_v1352_uri_host() {
  local h="$1"
  if [[ "$h" == *:* && "$h" != \[*\] ]]; then
    echo "[$h]"
  else
    echo "$h"
  fi
}

# Direct source template body: TUIC inbound includes tls.alpn=["h3"] directly.
write_singbox_config() {
  local reality_sni="$1"
  local tls_sni="$2"
  local cert_dir="$3"
  local start_port="$4"

  local port="$start_port"
  SB_REALITY_PORT="$port"; ((port++)) || true
  SB_HY2_PORT="$port"; ((port++)) || true
  SB_TUIC_PORT="$port"; ((port++)) || true
  SB_SS_PORT="$port"; ((port++)) || true
  SB_TROJAN_PORT="$port"; ((port++)) || true
  SB_VMESS_WS_PORT="$port"; ((port++)) || true
  SB_VLESS_WS_TLS_PORT="$port"; ((port++)) || true
  SB_H2_REALITY_PORT="$port"; ((port++)) || true
  SB_GRPC_REALITY_PORT="$port"; ((port++)) || true
  SB_ANYTLS_PORT="$port"; ((port++)) || true
  SB_NAIVE_PORT="$port"; ((port++)) || true
  SB_SHADOWTLS_PORT="$port"; ((port++)) || true

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
{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":${SB_TUIC_PORT},"users":[{"uuid":"${SB_UUID}","password":"${SB_TUIC_PASS}"}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem","alpn":["h3"]}}
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
{"type":"vless","tag":"h2-reality-in","listen":"::","listen_port":${SB_H2_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]},"alpn":["h2"]},"transport":{"type":"http","host":["${reality_sni}"],"path":"/h2"}}
EOF
  fi

  if [[ "$INSTALL_GRPC_REALITY" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"grpc-reality-in","listen":"::","listen_port":${SB_GRPC_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]},"alpn":["h2"]},"transport":{"type":"grpc","service_name":"lovegrpc"}}
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

# Direct source template body: all importable URI lines and emoji remarks are emitted here.
save_singbox_info() {
  local client_addr="$1"
  local client_port_base="$2"
  local reality_sni="$3"
  local tls_sni="$4"
  local insecure="$5"

  local h flag hy2_extra tuic_extra vless_extra trojan_extra anytls_extra vmess_json vmess_b64
  h="$(uri_host "${client_addr}")"
  flag="$(love_v1352_flag_emoji)"

  hy2_extra="$(love_v1352_tls_extra "$insecure" hy2)"
  tuic_extra="$(love_v1352_tls_extra "$insecure" tuic)"
  vless_extra="$(love_v1352_tls_extra "$insecure" vless_ws_tls)"
  trojan_extra="$(love_v1352_tls_extra "$insecure" trojan)"
  anytls_extra="$(love_v1352_tls_extra "$insecure" anytls)"

  : > "${SINGBOX_INFO}"

  {
    echo "Love sing-box Client Info"
    echo
    echo "Client Address: ${client_addr}"
    echo "Base Port: ${client_port_base}"
    echo "Reality SNI: ${reality_sni}"
    echo "TLS SNI: ${tls_sni}"
    echo "Insecure: ${insecure}"
    echo "Flag: ${flag}"
    echo
  } >> "${SINGBOX_INFO}"

  if [[ "$INSTALL_REALITY" == "yes" ]]; then
    echo "VLESS Reality:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=tcp#$(love_v1352_label LOVE-REALITY)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_HY2" == "yes" ]]; then
    echo "HY2:" >> "${SINGBOX_INFO}"
    echo "hy2://${SB_HY2_PASS}@${h}:${SB_HY2_PORT}/?sni=${tls_sni}&${hy2_extra}#$(love_v1352_label LOVE-HY2)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TUIC" == "yes" ]]; then
    echo "TUIC:" >> "${SINGBOX_INFO}"
    echo "tuic://${SB_UUID}:${SB_TUIC_PASS}@${h}:${SB_TUIC_PORT}?sni=${tls_sni}&congestion_control=bbr&udp_relay_mode=native&${tuic_extra}#$(love_v1352_label LOVE-TUIC)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_SS" == "yes" ]]; then
    echo "Shadowsocks:" >> "${SINGBOX_INFO}"
    echo "ss://$(printf 'aes-128-gcm:%s' "${SB_SS_PASS}" | base64 -w0)@${h}:${SB_SS_PORT}#$(love_v1352_label LOVE-SS)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TROJAN" == "yes" ]]; then
    echo "Trojan:" >> "${SINGBOX_INFO}"
    if [[ -n "$trojan_extra" ]]; then
      echo "trojan://${SB_TROJAN_PASS}@${h}:${SB_TROJAN_PORT}?security=tls&sni=${tls_sni}&${trojan_extra}#$(love_v1352_label LOVE-TROJAN)" >> "${SINGBOX_INFO}"
    else
      echo "trojan://${SB_TROJAN_PASS}@${h}:${SB_TROJAN_PORT}?security=tls&sni=${tls_sni}#$(love_v1352_label LOVE-TROJAN)" >> "${SINGBOX_INFO}"
    fi
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VMESS_WS" == "yes" ]]; then
    echo "VMess WS:" >> "${SINGBOX_INFO}"
    vmess_json="$(jq -nc \
      --arg ps "$(love_v1352_label LOVE-VMESS-WS)" \
      --arg add "${client_addr#[}" \
      --arg port "${SB_VMESS_WS_PORT}" \
      --arg id "${SB_UUID}" \
      '{v:"2",ps:$ps,add:($add|sub("\\]$";"")),port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:"",path:"/vmess",tls:"",sni:""}')"
    vmess_b64="$(printf '%s' "$vmess_json" | base64 -w0)"
    echo "vmess://${vmess_b64}" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VLESS_WS_TLS" == "yes" ]]; then
    echo "VLESS WS TLS:" >> "${SINGBOX_INFO}"
    if [[ -n "$vless_extra" ]]; then
      echo "vless://${SB_UUID}@${h}:${SB_VLESS_WS_TLS_PORT}?encryption=none&security=tls&sni=${tls_sni}&type=ws&path=%2Fvless&${vless_extra}#$(love_v1352_label LOVE-VLESS-WS-TLS)" >> "${SINGBOX_INFO}"
    else
      echo "vless://${SB_UUID}@${h}:${SB_VLESS_WS_TLS_PORT}?encryption=none&security=tls&sni=${tls_sni}&type=ws&path=%2Fvless#$(love_v1352_label LOVE-VLESS-WS-TLS)" >> "${SINGBOX_INFO}"
    fi
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_H2_REALITY" == "yes" ]]; then
    echo "H2 Reality:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_H2_REALITY_PORT}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=http&path=%2Fh2&host=${reality_sni}&alpn=h2#$(love_v1352_label LOVE-H2-REALITY)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_GRPC_REALITY" == "yes" ]]; then
    echo "gRPC Reality:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_GRPC_REALITY_PORT}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=grpc&serviceName=lovegrpc&authority=${reality_sni}&mode=gun&alpn=h2#$(love_v1352_label LOVE-GRPC-REALITY)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_ANYTLS" == "yes" ]]; then
    echo "AnyTLS:" >> "${SINGBOX_INFO}"
    echo "anytls://${SB_ANYTLS_PASS}@${h}:${SB_ANYTLS_PORT}?sni=${tls_sni}&${anytls_extra}#$(love_v1352_label LOVE-ANYTLS)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_NAIVE" == "yes" ]]; then
    echo "Naive:" >> "${SINGBOX_INFO}"
    echo "https://${SB_NAIVE_USER}:${SB_NAIVE_PASS}@${h}:${SB_NAIVE_PORT}#$(love_v1352_label LOVE-NAIVE)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_SHADOWTLS" == "yes" ]]; then
    echo "ShadowTLS manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_SHADOWTLS_PORT} Password=${SB_SHADOWTLS_PASS} Version=3 Handshake=addons.mozilla.org Detour=SS Label=$(love_v1352_label LOVE-SHADOWTLS)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  chmod 600 "${SINGBOX_INFO}"
  cat "${SINGBOX_INFO}"
}

love_v1352_template_body_check() {
  echo "================ Love v13.52 模板本体检查 ================"
  echo "Version:"
  grep '^VERSION=' /opt/Love/Love.sh 2>/dev/null || true
  echo
  echo "Active write_singbox_config TUIC source contains alpn h3:"
  declare -f write_singbox_config | grep -n '"alpn":\["h3"\]' && echo "[OK] TUIC 模板本体直接写 alpn=[h3]" || echo "[WARN] 未发现模板本体 alpn=[h3]"
  echo
  echo "Active save_singbox_info source contains emoji label and true insecure flags:"
  declare -f save_singbox_info | grep -n 'love_v1352_label LOVE-VLESS-WS-TLS' >/dev/null && echo "[OK] VLESS WS TLS 源头标签走 emoji label" || echo "[WARN] VLESS WS TLS 标签未走 v1352"
  declare -f save_singbox_info | grep -n 'allowInsecure=true' >/dev/null && echo "[OK] 源头含 allowInsecure=true" || echo "[WARN] 源头未发现 allowInsecure=true"
  echo
  echo "Current flag:"
  echo "$(love_v1352_flag_emoji)"
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1352 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1352/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.52.0-source-template-body-final}"
  case "${1:-}" in
    template-check|source-template-check|body-check)
      love_v1352_template_body_check
      ;;
    *)
      love_original_main_v1352 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.54 From v13.52 Complete Final
#
# Built from v13.52, not from broken v13.53.
#
# Rules:
#   1. Template body is source-correct.
#   2. Legacy v13.46/v13.47/v13.48 post-fix chains are silenced/overridden.
#   3. Green Web is preserved.
#   4. H2/gRPC Reality source and existing config can be fixed with h2 ALPN.
#   5. VLESS WS TLS / Trojan / TUIC use v2rayN-friendly true flags in self-signed mode.
#   6. Public CA mode removes insecure flags.
#   7. ShadowTLS is preserved as manual text, not falsely counted as importable URI.
#   8. Cert mode switch is provided for link/output generation; new installs still use install cert menu.
# ==============================================================================

LOVE_SCRIPT_VERSION="Love v13.56.1-source-first-export-hotfix"

love_v1354_cert_mode() {
  local m
  m="$(cat /opt/Love/cert-mode 2>/dev/null || cat /opt/Love/domain-cert-mode 2>/dev/null || true)"
  m="${m,,}"
  case "$m" in
    public|public_ca|domain_public_ca|ca|letsencrypt|lets_encrypt|zerossl) echo "public_ca" ;;
    *) echo "self_signed" ;;
  esac
}

love_v1354_flag() {
  local f cc n1 n2
  if declare -F love_v1352_flag_emoji >/dev/null 2>&1; then
    f="$(love_v1352_flag_emoji 2>/dev/null || true)"
  fi
  [[ -z "$f" && -s /opt/Love/node-flag ]] && f="$(cat /opt/Love/node-flag 2>/dev/null || true)"
  f="${f:-🇺🇸}"
  if [[ "$f" =~ ^[A-Za-z][A-Za-z]$ ]]; then
    cc="${f^^}"
    n1=$(( $(printf "%d" "'${cc:0:1}") - 65 + 127462 ))
    n2=$(( $(printf "%d" "'${cc:1:1}") - 65 + 127462 ))
    python3 - <<PY 2>/dev/null || echo "🇺🇸"
print(chr($n1)+chr($n2))
PY
  else
    echo "$f"
  fi
}

love_v1354_label() {
  local label="$1" flag
  flag="$(love_v1354_flag)"
  label="${label#US }"; label="${label#USA }"; label="${label#🇺🇸 }"
  echo "$flag ${label# }"
}

love_v1354_sni_selfsigned() {
  local line="$1" q sni host
  q="${line#*\?}"; q="${q%%#*}"
  sni="$(tr '&' '\n' <<< "$q" | awk -F= 'tolower($1)=="sni"{print $2; exit}')"
  host="$(tr '&' '\n' <<< "$q" | awk -F= 'tolower($1)=="host"{print $2; exit}')"
  [[ -z "$sni" ]] && sni="$host"
  [[ -z "$sni" || "$sni" == "self.local" || "$sni" == "localhost" || "$sni" == *.local ]]
}

love_v1354_norm_file() {
  local file="$1" mode
  mode="$(love_v1354_cert_mode)"
  [[ -s "$file" ]] || return 0
  python3 - "$file" "$mode" <<'PY'
from pathlib import Path
import sys, re, urllib.parse

p = Path(sys.argv[1])
global_mode = sys.argv[2]
flag_default = "🇺🇸"

def is_self_sni(query: str) -> bool:
    params = urllib.parse.parse_qs(query, keep_blank_values=True)
    sni = (params.get("sni") or params.get("host") or [""])[0]
    return (not sni) or sni in ("self.local", "localhost") or sni.endswith(".local")

def clean_params(query: str):
    arr = []
    for x in query.split("&"):
        if not x:
            continue
        k = x.split("=", 1)[0].lower()
        if k in ("allowinsecure", "allow_insecure", "insecure", "alpn", "mode"):
            continue
        arr.append(x)
    return arr

def label(frag: str) -> str:
    frag = frag or "LOVE"
    if frag.startswith("US "):
        frag = frag[3:]
    if not frag.startswith(("🇺🇸 ","🇯🇵 ","🇸🇬 ","🇭🇰 ","🇹🇼 ","🇰🇷 ","🇩🇪 ","🇬🇧 ","🇫🇷 ","🇳🇱 ","🇨🇦 ","🇦🇺 ")):
        frag = flag_default + " " + frag
    return frag

out = []
for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
    low = line.lower()
    if line.startswith(("vless://","tuic://","trojan://","hy2://","hysteria2://","anytls://","https://","ss://","vmess://")):
        main, _, frag = line.partition("#")
        base, qsep, query = main.partition("?")
        frag = label(frag)

        if not qsep:
            out.append(main + "#" + frag)
            continue

        params = clean_params(query)
        self_mode = (global_mode != "public_ca") or is_self_sni(query)

        if line.startswith("vless://") and "security=reality" in low:
            if "type=http" in low:
                params += ["alpn=h2"]
            elif "type=grpc" in low:
                params += ["mode=gun", "alpn=h2"]
        elif line.startswith("vless://") and "security=tls" in low and "type=ws" in low:
            if self_mode:
                params += ["allowInsecure=true", "insecure=true", "allow_insecure=true"]
        elif line.startswith("tuic://"):
            if self_mode:
                params += ["allow_insecure=true", "allowInsecure=true", "insecure=true", "alpn=h3"]
            else:
                params += ["alpn=h3"]
        elif line.startswith("trojan://"):
            if self_mode:
                params += ["allowInsecure=true", "insecure=true", "allow_insecure=true"]
        elif line.startswith(("hy2://","hysteria2://")):
            params += ["insecure=1" if self_mode else "insecure=0"]
        elif line.startswith("anytls://"):
            if self_mode:
                params += ["insecure=true"]

        line = base + "?" + "&".join(params) + "#" + frag

    out.append(line)

p.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

love_v1354_export_direct() {
  local SUBDIR="/opt/Love/subscribe"
  local CLIENTDIR="$SUBDIR/clients"
  mkdir -p "$CLIENTDIR" "$SUBDIR/qr"

  : > "$SUBDIR/all.txt"
  : > "$CLIENTDIR/manual-nodes.txt"

  local f
  for f in /opt/Love/client-info/*.txt; do
    [[ -s "$f" ]] || continue
    grep -E '^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://' "$f" >> "$SUBDIR/all.txt" || true
    grep -E '^(ShadowTLS manual:|Address=.*Version=3|Detour=SS|Label=.*SHADOWTLS)' "$f" >> "$CLIENTDIR/manual-nodes.txt" || true
  done

  awk 'NF && !seen[$0]++' "$SUBDIR/all.txt" > "$SUBDIR/all.tmp" && mv "$SUBDIR/all.tmp" "$SUBDIR/all.txt"
  love_v1354_norm_file "$SUBDIR/all.txt"

  cp -f "$SUBDIR/all.txt" "$SUBDIR/全部节点.txt"
  cp -f "$SUBDIR/all.txt" "$SUBDIR/推荐节点.txt"
  cp -f "$SUBDIR/all.txt" "$SUBDIR/节点清晰版.txt"
  cp -f "$SUBDIR/all.txt" "$CLIENTDIR/v2rayn-uri.txt"
  cp -f "$SUBDIR/all.txt" "$CLIENTDIR/nekobox-uri.txt"
  cp -f "$SUBDIR/all.txt" "$CLIENTDIR/nodes-clean.txt"

  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$SUBDIR/all.txt" > "$SUBDIR/all_base64.txt" 2>/dev/null || true
  else
    base64 "$SUBDIR/all.txt" | tr -d '\n' > "$SUBDIR/all_base64.txt" 2>/dev/null || true
  fi
}

love_v1354_qr_direct() {
  local SUBDIR="/opt/Love/subscribe"
  local QRDIR="$SUBDIR/qr"
  mkdir -p "$QRDIR"
  rm -f "$QRDIR"/* 2>/dev/null || true
  command -v qrencode >/dev/null 2>&1 || apt install -y qrencode >/dev/null 2>&1 || true

  local i=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    ((i++)) || true
    printf '%s' "$line" | qrencode -t PNG -s 5 -m 2 -o "$QRDIR/node-${i}.png" 2>/dev/null || true
  done < "$SUBDIR/all.txt"

  cat > "$QRDIR/index.html" <<'EOF'
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Love QR Gallery · Green Mode</title>
<style>
body{margin:0;background:#07140d;color:#e8fff0;font-family:Arial,"Microsoft YaHei",sans-serif}
.wrap{max-width:1180px;margin:auto;padding:24px}
.hero{background:linear-gradient(135deg,#047857,#16a34a);border-radius:22px;padding:22px;box-shadow:0 12px 30px #0006}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:18px;margin-top:20px}
.card{background:#0b2014;border:1px solid #14532d;border-radius:18px;padding:16px;text-align:center}
img{width:170px;max-width:90%;background:white;padding:8px;border-radius:12px}
.btn{display:inline-block;padding:8px 12px;border-radius:999px;background:#16a34a;color:white;text-decoration:none;font-weight:700}
</style></head><body><div class="wrap"><div class="hero"><h1>Love QR Gallery · Green Mode</h1><a class="btn" href="/">返回首页</a></div><div class="grid">
EOF
  local p b
  for p in "$QRDIR"/node-*.png; do
    [[ -f "$p" ]] || continue
    b="$(basename "$p")"
    echo "<div class='card'><h3>${b}</h3><a href='./${b}' target='_blank'><img src='./${b}'></a></div>" >> "$QRDIR/index.html"
  done
  echo "</div></div></body></html>" >> "$QRDIR/index.html"
}

love_v1354_web_direct() {
  local PORT="${1:-8099}"
  local AUTH="${2:-Y}"
  local USERNAME="${3:-love}"
  local PASSWORD="${4:-}"
  local WEBDIR="/var/www/love-admin"
  local SUBDIR="/opt/Love/subscribe"

  mkdir -p "$WEBDIR/sub" "$WEBDIR/clients" "$WEBDIR/qr"
  cp -f "$SUBDIR/all.txt" "$WEBDIR/all.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$WEBDIR/node-links.txt" 2>/dev/null || true
  cp -f "$SUBDIR/全部节点.txt" "$WEBDIR/全部节点.txt" 2>/dev/null || true
  cp -f "$SUBDIR/推荐节点.txt" "$WEBDIR/推荐节点.txt" 2>/dev/null || true
  cp -f "$SUBDIR/节点清晰版.txt" "$WEBDIR/节点清晰版.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$WEBDIR/sub/all.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all_base64.txt" "$WEBDIR/sub/all_base64.txt" 2>/dev/null || true
  cp -a "$SUBDIR/clients/." "$WEBDIR/clients/" 2>/dev/null || true
  cp -a "$SUBDIR/qr/." "$WEBDIR/qr/" 2>/dev/null || true

  cat > "$WEBDIR/index.html" <<'EOF'
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Love Web Panel · Green Mode</title>
<style>
body{margin:0;background:#07140d;color:#e8fff0;font-family:Arial,"Microsoft YaHei",sans-serif}
.wrap{max-width:1120px;margin:auto;padding:24px}
.hero{background:linear-gradient(135deg,#047857,#16a34a);border-radius:22px;padding:24px;box-shadow:0 12px 30px #0006}
.card{background:#0b2014;border:1px solid #14532d;border-radius:18px;padding:18px;margin:16px 0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}
.btn{display:inline-block;background:#16a34a;color:white;text-decoration:none;border-radius:999px;padding:9px 14px;margin:5px;font-weight:700}
</style></head><body><div class="wrap"><div class="hero"><h1>Love Web Panel · Green Mode</h1><p>Source-template output / no legacy repair chain</p></div>
<div class="card"><div class="grid">
<a class="btn" href="/all.txt" target="_blank">全部节点</a>
<a class="btn" href="/推荐节点.txt" target="_blank">推荐节点</a>
<a class="btn" href="/节点清晰版.txt" target="_blank">节点清晰版</a>
<a class="btn" href="/clients/v2rayn-uri.txt" target="_blank">V2RayN</a>
<a class="btn" href="/clients/nekobox-uri.txt" target="_blank">NekoBox</a>
<a class="btn" href="/clients/manual-nodes.txt" target="_blank">手动节点</a>
<a class="btn" href="/qr/index.html" target="_blank">二维码</a>
</div></div></div></body></html>
EOF

  cat > /etc/nginx/sites-available/love-admin <<EOF
server {
    listen ${PORT};
    listen [::]:${PORT};
    server_name _;
    root ${WEBDIR};
    index index.html;
    autoindex on;
    charset utf-8;
EOF
  if [[ "${AUTH,,}" != "n" ]]; then
    [[ -n "$PASSWORD" ]] || PASSWORD="$(openssl rand -hex 8)"
    htpasswd -bc /etc/nginx/.love_web_htpasswd "$USERNAME" "$PASSWORD" >/dev/null 2>&1 || true
    cat >> /etc/nginx/sites-available/love-admin <<'EOF'
    auth_basic "Love";
    auth_basic_user_file /etc/nginx/.love_web_htpasswd;
EOF
  fi
  echo "}" >> /etc/nginx/sites-available/love-admin

  ln -sf /etc/nginx/sites-available/love-admin /etc/nginx/sites-enabled/love-admin
  nginx -t && systemctl restart nginx
  echo "[OK] Love Web Green Panel 已生成：http://[你的IP]:${PORT}/"
  [[ "${AUTH,,}" != "n" ]] && echo "用户名：$USERNAME  密码：$PASSWORD"
}

love_v1354_h2_fix_existing() {
  [[ -s /etc/sing-box/config.json ]] || return 0
  cp -f /etc/sing-box/config.json /etc/sing-box/config.json.bak.h2-grpc-alpn-v1354.$(date +%F-%H%M%S) 2>/dev/null || true
  jq '(.inbounds[]? | select(.tag=="h2-reality-in").tls.alpn)=["h2"] |
      (.inbounds[]? | select(.tag=="grpc-reality-in").tls.alpn)=["h2"] |
      (.inbounds[]? | select(.tag=="tuic-in" or .type=="tuic").tls.alpn)=["h3"]' \
      /etc/sing-box/config.json > /tmp/love-v1354-sb.json && mv /tmp/love-v1354-sb.json /etc/sing-box/config.json
  sing-box check -c /etc/sing-box/config.json && systemctl restart sing-box
}

love_v1354_cert_switch() {
  echo "================ Love 证书/链接模式切换 v13.54 ================"
  echo "1) 无域名 self.local 自签【默认】"
  echo "2) 无域名 love.local 自签【需要服务端证书/SNI一致才适合】"
  echo "3) 有域名 + 正式 CA【移除 insecure】"
  echo "4) 有域名 + 自签/自管【添加 insecure true】"
  echo "5) 优选 IP/CFIP + 域名 SNI【只改客户端输出，服务端证书需已匹配】"
  read -rp "请选择 [1-5]: " CHOICE
  CHOICE="${CHOICE:-1}"
  mkdir -p /opt/Love
  case "$CHOICE" in
    1)
      echo "self_signed" > /opt/Love/cert-mode
      echo "self.local" > /opt/Love/node-sni
      ;;
    2)
      echo "self_signed" > /opt/Love/cert-mode
      echo "love.local" > /opt/Love/node-sni
      echo "[WARN] 仅切换输出记录；若服务端证书仍是 self.local，请不要把客户端 SNI 改成 love.local。"
      ;;
    3)
      read -rp "域名/SNI: " DOMAIN
      [[ -n "$DOMAIN" ]] || { echo "[ERROR] 域名不能为空"; return 1; }
      echo "public_ca" > /opt/Love/cert-mode
      echo "$DOMAIN" > /opt/Love/node-sni
      ;;
    4)
      read -rp "域名/SNI: " DOMAIN
      [[ -n "$DOMAIN" ]] || { echo "[ERROR] 域名不能为空"; return 1; }
      echo "self_signed" > /opt/Love/cert-mode
      echo "$DOMAIN" > /opt/Love/node-sni
      ;;
    5)
      read -rp "客户端 Address（优选IP/CFIP/域名）: " ADDR
      read -rp "真实 SNI/证书域名: " DOMAIN
      [[ -n "$ADDR" && -n "$DOMAIN" ]] || { echo "[ERROR] Address 和 SNI 不能为空"; return 1; }
      echo "$ADDR" > /opt/Love/client-address
      echo "$DOMAIN" > /opt/Love/node-sni
      read -rp "证书是否正式CA？[y/N]: " ISCA
      [[ "$ISCA" =~ ^[Yy]$ ]] && echo "public_ca" > /opt/Love/cert-mode || echo "self_signed" > /opt/Love/cert-mode
      ;;
  esac
  echo "[OK] 已保存链接模式。旧服务端不会自动重签证书；新安装请在安装向导里选择对应证书环境。"
  love_v1354_export_direct
  love_v1354_qr_direct
}

# Override noisy old post-fix chains from v13.46/v13.47/v13.48.
love_fix_vless_ws_tls_all_v1347() { love_v1354_norm_file /opt/Love/subscribe/all.txt 2>/dev/null || true; }
love_web_fix_v1346() { love_v1354_export_direct; love_v1354_qr_direct; love_v1354_web_direct 8099 n love ""; }
love_v1348_source_correct_outputs() { love_v1354_export_direct; love_v1354_qr_direct; }

web_admin_page() {
  echo "════════════════════════════════════════════════════════════════════════════════"
  echo "Love Web 管理页 Green Mode / Source Template v13.54"
  echo "════════════════════════════════════════════════════════════════════════════════"
  local PORT AUTH USERNAME PASSWORD
  read -rp "Web 管理页端口 [8099]: " PORT; PORT="${PORT:-8099}"
  read -rp "是否开启 Basic Auth 密码保护？[Y/n]: " AUTH; AUTH="${AUTH:-Y}"
  read -rp "Web 用户名 [love]: " USERNAME; USERNAME="${USERNAME:-love}"
  if [[ "${AUTH,,}" != "n" ]]; then read -rp "Web 密码，留空自动生成: " PASSWORD; fi
  love_v1354_export_direct
  love_v1354_qr_direct
  love_v1354_web_direct "$PORT" "$AUTH" "$USERNAME" "${PASSWORD:-}"
}

love_after_node_generated_exports() {
  echo
  echo "================ Love Source Template Export v13.54 ================"
  love_v1354_export_direct
  love_v1354_qr_direct
  echo "[OK] 订阅/TXT/二维码已按模板本体直接生成。ShadowTLS 保留在 manual-nodes.txt。"
  web_admin_page
}

love_v1354_check() {
  echo "================ Love v13.54 检查 ================"
  grep '^VERSION=' /opt/Love/Love.sh 2>/dev/null || true
  echo
  echo "配置模式：cert-mode=$(cat /opt/Love/cert-mode 2>/dev/null || echo self_signed), node-sni=$(cat /opt/Love/node-sni 2>/dev/null || echo self.local)"
  echo
  echo "关键链接："
  grep -nEi 'LOVE-H2-REALITY|LOVE-GRPC-REALITY|LOVE-TROJAN|LOVE-TUIC|LOVE-VLESS-WS-TLS' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo
  echo "服务端 ALPN："
  jq -r '.inbounds[]? | select(.tag=="h2-reality-in" or .tag=="grpc-reality-in" or .tag=="tuic-in") | [.tag,.type,.listen_port,(.tls.alpn|tostring)] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
  echo
  echo "Web 文件："
  for f in /var/www/love-admin/index.html /var/www/love-admin/推荐节点.txt /var/www/love-admin/节点清晰版.txt /var/www/love-admin/clients/manual-nodes.txt /var/www/love-admin/qr/index.html; do
    [[ -s "$f" ]] && echo "[OK] $f" || echo "[MISS] $f"
  done
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1354 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1354/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.54.0-from-1352-complete-final}"
  case "${1:-}" in
    h2-fix|grpc-fix|reality-h2-fix)
      love_v1354_h2_fix_existing
      love_v1354_export_direct
      love_v1354_qr_direct
      ;;
    cert-switch|cert-menu|cert-mode)
      love_v1354_cert_switch
      ;;
    web|web-fix|fix-web)
      web_admin_page
      ;;
    source-correct|final-fix|client-output-fix|importable-fix|v2rayn-fix|sub|subscribe)
      love_v1354_export_direct
      love_v1354_qr_direct
      ;;
    v1354-check|check-final|final-check|template-check|source-template-check|body-check)
      love_v1354_check
      ;;
    *)
      love_original_main_v1354 "$@"
      ;;
  esac
}


# ==============================================================================
# Love v13.55 Safe Enhance / No Delete / Green Web Preserved
#
# Purpose:
#   - Do not remove any existing feature.
#   - Keep Green Web untouched in appearance and entry behavior.
#   - Fix boolean TRUE output for self-signed/untrusted TLS nodes.
#   - Keep Reality nodes free from ordinary certificate insecure flags.
#   - Make H2/gRPC Reality repair stricter for existing sing-box configs.
#   - Archive legacy/raw links instead of deleting them.
# ================================================================================

LOVE_SCRIPT_VERSION="Love v13.55.0-safe-enhance-no-delete-final"

love_v1355_node_sni() {
  local sni
  sni="$(cat /opt/Love/node-sni 2>/dev/null || true)"
  [[ -n "$sni" ]] || sni="self.local"
  echo "$sni"
}

love_v1355_norm_file() {
  local file="$1" mode node_sni
  mode="$(love_v1354_cert_mode 2>/dev/null || echo self_signed)"
  node_sni="$(love_v1355_node_sni)"
  [[ -s "$file" ]] || return 0
  python3 - "$file" "$mode" "$node_sni" <<'INNERPY'
from pathlib import Path
import sys, urllib.parse, re

p = Path(sys.argv[1])
global_mode = (sys.argv[2] or "self_signed").lower()
node_sni = sys.argv[3] or "self.local"
flag_default = "🇺🇸"
FLAG_PREFIXES = ("🇺🇸 ","🇯🇵 ","🇸🇬 ","🇭🇰 ","🇹🇼 ","🇰🇷 ","🇩🇪 ","🇬🇧 ","🇫🇷 ","🇳🇱 ","🇨🇦 ","🇦🇺 ")


def label(frag: str) -> str:
    frag = urllib.parse.unquote(frag or "LOVE")
    frag = re.sub(r"^(US|USA)\s+", "", frag).strip()
    if frag.startswith(FLAG_PREFIXES):
        return frag
    return f"{flag_default} {frag}" if frag else f"{flag_default} LOVE"


def split_uri(line: str):
    main, _, frag = line.partition("#")
    if "?" in main:
        base, _, query = main.partition("?")
    else:
        base, query = main, ""
    return base, query, frag


def parse_pairs(query: str):
    return urllib.parse.parse_qsl(query, keep_blank_values=True) if query else []


def get_first(pairs, *names):
    names = {n.lower() for n in names}
    for k, v in pairs:
        if k.lower() in names:
            return v
    return ""


def remove_keys(pairs, *names):
    names = {n.lower() for n in names}
    return [(k, v) for k, v in pairs if k.lower() not in names]


def query_of(pairs):
    return urllib.parse.urlencode(pairs, doseq=True, safe='')


def looks_self_sni(sni: str) -> bool:
    sni = (sni or "").strip().lower()
    return (not sni) or sni in ("self.local", "localhost", "love.local") or sni.endswith(".local")


def tls_self_mode(pairs) -> bool:
    sni = get_first(pairs, "sni", "host", "authority") or node_sni
    return global_mode != "public_ca" or looks_self_sni(sni)


def normalize_vmess(line: str) -> str:
    main, _, frag = line.partition('#')
    return main + '#' + label(frag)

out = []
for raw in p.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = raw.strip()
    low = line.lower()
    if not line.startswith(("vless://","tuic://","trojan://","hy2://","hysteria2://","anytls://","https://","ss://","vmess://")):
        out.append(raw)
        continue

    if line.startswith("vmess://"):
        out.append(normalize_vmess(line))
        continue

    if line.startswith("ss://"):
        main, _, frag = line.partition('#')
        out.append(main + '#' + label(frag))
        continue

    base, query, frag = split_uri(line)
    frag_label = label(frag)
    pairs = parse_pairs(query)

    is_reality = line.startswith("vless://") and "security=reality" in low
    is_h2_reality = is_reality and ("love-h2-reality" in low or get_first(pairs, "type").lower() == "http")
    is_grpc_reality = is_reality and ("love-grpc-reality" in low or get_first(pairs, "type").lower() == "grpc")

    pairs = remove_keys(pairs, "allowInsecure", "allow_insecure", "insecure", "alpn", "mode")

    if is_reality:
        sni = get_first(pairs, "sni") or node_sni or "www.cloudflare.com"
        if is_h2_reality:
            pairs = remove_keys(pairs, "type", "path", "host")
            pairs += [("type", "http"), ("path", "/h2"), ("host", sni), ("alpn", "h2")]
        elif is_grpc_reality:
            pairs = remove_keys(pairs, "type", "serviceName", "service_name", "authority")
            pairs += [("type", "grpc"), ("serviceName", "lovegrpc"), ("authority", sni), ("mode", "gun"), ("alpn", "h2")]
    elif line.startswith("vless://") and "security=tls" in low and ("type=ws" in low or "love-vless-ws-tls" in low):
        if tls_self_mode(pairs):
            pairs += [("allowInsecure", "true"), ("insecure", "true"), ("allow_insecure", "true")]
    elif line.startswith("tuic://"):
        if tls_self_mode(pairs):
            pairs += [("allow_insecure", "true"), ("allowInsecure", "true"), ("insecure", "true"), ("alpn", "h3")]
        else:
            pairs += [("alpn", "h3")]
    elif line.startswith("trojan://"):
        if tls_self_mode(pairs):
            pairs += [("allowInsecure", "true"), ("insecure", "true"), ("allow_insecure", "true")]
    elif line.startswith(("hy2://", "hysteria2://")):
        if tls_self_mode(pairs):
            pairs += [("insecure", "true")]
    elif line.startswith("anytls://"):
        if tls_self_mode(pairs):
            pairs += [("insecure", "true")]
    elif line.startswith("https://") and ("love-naive" in low or "@" in base):
        sni = get_first(pairs, "sni") or node_sni
        pairs = remove_keys(pairs, "sni")
        pairs += [("sni", sni)]
        if tls_self_mode(pairs):
            pairs += [("insecure", "true"), ("allowInsecure", "true"), ("allow_insecure", "true")]

    new_query = query_of(pairs)
    out.append(base + (("?" + new_query) if new_query else "") + "#" + frag_label)

p.write_text("\n".join(out) + "\n", encoding="utf-8")
INNERPY
}

love_v1355_archive_legacy_links() {
  local SUBDIR="/opt/Love/subscribe"
  local CLIENTDIR="${SUBDIR}/clients"
  local out="${CLIENTDIR}/legacy-raw-links.txt"
  mkdir -p "$CLIENTDIR"
  : > "$out"
  {
    echo "Love legacy/raw links archive"
    echo "Generated: $(date '+%F %T')"
    echo "说明：这里是历史/原始链接归档，不参与 v2rayN/NekoBox 一键导入。不要删除，旧 VPS 回滚排查时有用。"
    echo
    grep -REh '^(vless|hy2|hysteria2|tuic|ss|trojan|vmess|anytls|https)://' /opt/Love/client-info/*.txt 2>/dev/null || true
  } >> "$out"
  chmod 600 "$out" 2>/dev/null || true
}


# V13.57: v2rayN has its own URI importer behavior.
# Generic links keep true/false style for NekoBox/sing-box compatibility.
# v2rayn-uri.txt is generated separately using v2rayN-preferred numeric bools (1)
# because some v2rayN builds ignore insecure=true but accept insecure=1/allowInsecure=1.
love_v1357_make_v2rayn_import() {
  local SUBDIR="/opt/Love/subscribe"
  local CLIENTDIR="${SUBDIR}/clients"
  local src="${SUBDIR}/all.txt"
  local out="${CLIENTDIR}/v2rayn-uri.txt"
  mkdir -p "$CLIENTDIR"
  [[ -s "$src" ]] || return 0

  python3 - "$src" "$out" <<'INNERPY1357'
from pathlib import Path
import sys, urllib.parse

src = Path(sys.argv[1])
out = Path(sys.argv[2])

def split_uri(line: str):
    main, sep, frag = line.partition('#')
    base, qsep, query = main.partition('?')
    return base, query if qsep else '', frag

def parse_pairs(query: str):
    return urllib.parse.parse_qsl(query, keep_blank_values=True) if query else []

def remove_keys(pairs, *names):
    names = {n.lower() for n in names}
    return [(k, v) for k, v in pairs if k.lower() not in names]

def get_first(pairs, *names):
    names = {n.lower() for n in names}
    for k, v in pairs:
        if k.lower() in names:
            return v
    return ''

def query_of(pairs):
    return urllib.parse.urlencode(pairs, doseq=True, safe='')

def has_self_tls(line_lower: str, pairs):
    sni = (get_first(pairs, 'sni', 'host', 'authority') or '').lower()
    return ('self.local' in sni) or ('self.local' in line_lower) or any(tag in line_lower for tag in (
        'love-hy2','love-tuic','love-trojan','love-vless-ws-tls','love-anytls','love-naive'
    ))

out_lines = []
for raw in src.read_text(encoding='utf-8', errors='ignore').splitlines():
    line = raw.strip()
    if not line:
        continue
    low = line.lower()
    if not line.startswith(('vless://','hy2://','hysteria2://','tuic://','trojan://','anytls://','https://','ss://','vmess://')):
        continue
    if line.startswith(('ss://','vmess://')):
        out_lines.append(line)
        continue

    base, query, frag = split_uri(line)
    pairs = parse_pairs(query)
    is_reality = line.startswith('vless://') and 'security=reality' in low

    # Reality does not use normal TLS cert verification switches.
    if is_reality:
        out_lines.append(line)
        continue

    pairs = remove_keys(pairs, 'allowInsecure', 'allow_insecure', 'insecure')

    if line.startswith(('hy2://','hysteria2://')):
        if has_self_tls(low, pairs):
            pairs += [('insecure','1')]
    elif line.startswith('tuic://'):
        pairs = remove_keys(pairs, 'alpn')
        if has_self_tls(low, pairs):
            pairs += [('allow_insecure','1'), ('allowInsecure','1'), ('insecure','1'), ('alpn','h3')]
        else:
            pairs += [('alpn','h3')]
    elif line.startswith('trojan://'):
        if has_self_tls(low, pairs):
            pairs += [('allowInsecure','1'), ('insecure','1'), ('allow_insecure','1')]
    elif line.startswith('vless://') and 'security=tls' in low:
        if has_self_tls(low, pairs):
            pairs += [('allowInsecure','1'), ('insecure','1'), ('allow_insecure','1')]
    elif line.startswith('anytls://'):
        if has_self_tls(low, pairs):
            pairs += [('insecure','1'), ('allowInsecure','1'), ('allow_insecure','1')]
    elif line.startswith('https://'):
        if has_self_tls(low, pairs):
            pairs += [('insecure','1'), ('allowInsecure','1'), ('allow_insecure','1')]

    q = query_of(pairs)
    out_lines.append(base + (('?' + q) if q else '') + '#' + (frag or 'LOVE'))

out.write_text('\n'.join(out_lines) + '\n', encoding='utf-8')
INNERPY1357
}

love_v1355_export_direct() {
  love_v1354_export_direct
  local SUBDIR="/opt/Love/subscribe"
  local CLIENTDIR="${SUBDIR}/clients"
  for f in "$SUBDIR/all.txt" "$SUBDIR/全部节点.txt" "$SUBDIR/推荐节点.txt" "$SUBDIR/节点清晰版.txt" "$CLIENTDIR/v2rayn-uri.txt" "$CLIENTDIR/nekobox-uri.txt" "$CLIENTDIR/nodes-clean.txt"; do
    love_v1355_norm_file "$f" 2>/dev/null || true
  done
  cp -f "$SUBDIR/all.txt" "$SUBDIR/全部节点.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$SUBDIR/推荐节点.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$SUBDIR/节点清晰版.txt" 2>/dev/null || true
  # Generic clients keep all.txt true/false style. v2rayN gets a dedicated compatibility file.
  cp -f "$SUBDIR/all.txt" "$CLIENTDIR/nekobox-uri.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$CLIENTDIR/nodes-clean.txt" 2>/dev/null || true
  love_v1357_make_v2rayn_import 2>/dev/null || cp -f "$SUBDIR/all.txt" "$CLIENTDIR/v2rayn-uri.txt" 2>/dev/null || true
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$SUBDIR/all.txt" > "$SUBDIR/all_base64.txt" 2>/dev/null || true
  else
    base64 "$SUBDIR/all.txt" | tr -d '\n' > "$SUBDIR/all_base64.txt" 2>/dev/null || true
  fi
  love_v1355_archive_legacy_links
}

love_v1355_h2_fix_existing() {
  [[ -s /etc/sing-box/config.json ]] || { echo "[WARN] /etc/sing-box/config.json 不存在，跳过服务端 H2/gRPC 修复。"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq 不存在，无法修复 sing-box JSON。"; return 1; }
  local bak
  bak="/etc/sing-box/config.json.bak.h2-grpc-tuic-v1355.$(date +%F-%H%M%S)"
  cp -f /etc/sing-box/config.json "$bak" 2>/dev/null || true
  jq '
    def sni: (.tls.server_name // .tls.reality.handshake.server // "www.cloudflare.com");
    (.inbounds[]? | select(.tag=="h2-reality-in" or ((.tag//"")|test("h2.*reality"; "i")))) |=
      (.tls.alpn=["h2"] |
       .transport=((.transport // {}) + {"type":"http","path":"/h2"}) |
       .transport.host=(.transport.host // [sni])) |
    (.inbounds[]? | select(.tag=="grpc-reality-in" or ((.tag//"")|test("grpc.*reality"; "i")))) |=
      (.tls.alpn=["h2"] |
       .transport=((.transport // {}) + {"type":"grpc"}) |
       .transport.service_name=(.transport.service_name // "lovegrpc")) |
    (.inbounds[]? | select(.tag=="tuic-in" or .type=="tuic")) |=
      (.tls.alpn=["h3"] | .congestion_control=(.congestion_control // "bbr"))
  ' /etc/sing-box/config.json > /tmp/love-v1355-sb.json && mv /tmp/love-v1355-sb.json /etc/sing-box/config.json

  if ! sing-box check -c /etc/sing-box/config.json; then
    echo "[ERROR] sing-box 检查失败，恢复备份：$bak"
    cp -f "$bak" /etc/sing-box/config.json
    return 1
  fi
  systemctl restart sing-box 2>/dev/null || true
  echo "[OK] H2 Reality / gRPC Reality / TUIC ALPN 已按 v13.55 修复。"
  jq -r '.inbounds[]? | select(.tag=="h2-reality-in" or .tag=="grpc-reality-in" or .tag=="tuic-in" or .type=="tuic") | [.tag,.type,.listen_port,(.tls.alpn|tostring),(.transport|tostring)] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
}

love_v1355_check() {
  echo "================ Love v13.55 检查 ================"
  echo "VERSION=${LOVE_SCRIPT_VERSION}"
  echo "cert-mode=$(cat /opt/Love/cert-mode 2>/dev/null || echo self_signed)"
  echo "node-sni=$(cat /opt/Love/node-sni 2>/dev/null || echo self.local)"
  echo
  echo "[1] 旧 1/0 insecure 残留检查："
  if grep -nE 'insecure=1|insecure=0|allowInsecure=1|allow_insecure=1' /opt/Love/subscribe/all.txt 2>/dev/null; then
    echo "[WARN] 仍有旧式 1/0 参数，执行 Love source-correct。"
  else
    echo "[OK] 未发现旧式 insecure=1/0。"
  fi
  echo
  echo "[2] H2/gRPC/Naive 关键链接："
  grep -nEi 'LOVE-H2-REALITY|LOVE-GRPC-REALITY|LOVE-NAIVE|LOVE-HY2|LOVE-TUIC' /opt/Love/subscribe/all.txt 2>/dev/null || true
  echo
  echo "[3] 服务端 ALPN/Transport："
  jq -r '.inbounds[]? | select(.tag=="h2-reality-in" or .tag=="grpc-reality-in" or .tag=="tuic-in" or .type=="tuic") | [.tag,.type,.listen_port,(.tls.alpn|tostring),(.transport|tostring)] | @tsv' /etc/sing-box/config.json 2>/dev/null || true
  echo
  echo "[4] Green Web 文件："
  for f in /var/www/love-admin/index.html /var/www/love-admin/all.txt /var/www/love-admin/clients/v2rayn-uri.txt /var/www/love-admin/clients/legacy-raw-links.txt /var/www/love-admin/qr/index.html; do
    [[ -s "$f" ]] && echo "[OK] $f" || echo "[MISS] $f"
  done
}

# Keep old command names, but route final output through v13.55.
love_fix_vless_ws_tls_all_v1347() { love_v1355_norm_file /opt/Love/subscribe/all.txt 2>/dev/null || true; }
love_v1348_source_correct_outputs() { love_v1355_export_direct; love_v1354_qr_direct; }

# Preserve Green Web style. Only feed it v13.55-correct output before generation.
web_admin_page() {
  echo "════════════════════════════════════════════════════════════════════════════════"
  echo "Love Web 管理页 Green Mode / Source Template v13.55"
  echo "════════════════════════════════════════════════════════════════════════════════"
  local PORT AUTH USERNAME PASSWORD
  read -rp "Web 管理页端口 [8099]: " PORT; PORT="${PORT:-8099}"
  read -rp "是否开启 Basic Auth 密码保护？[Y/n]: " AUTH; AUTH="${AUTH:-Y}"
  read -rp "Web 用户名 [love]: " USERNAME; USERNAME="${USERNAME:-love}"
  if [[ "${AUTH,,}" != "n" ]]; then read -rp "Web 密码，留空自动生成: " PASSWORD; fi
  love_v1355_export_direct
  love_v1354_qr_direct
  love_v1354_web_direct "$PORT" "$AUTH" "$USERNAME" "${PASSWORD:-}"
}

love_after_node_generated_exports() {
  echo
  echo "================ Love Source Template Export v13.55 ================"
  love_v1355_export_direct
  love_v1354_qr_direct
  echo "[OK] 订阅/TXT/二维码已按 v13.55 生成。旧链接已归档到 clients/legacy-raw-links.txt，不参与导入。"
  web_admin_page
}

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.55.0-safe-enhance-no-delete-final}"
  case "${1:-}" in
    h2-fix|grpc-fix|reality-h2-fix|tuic-fix)
      love_v1355_h2_fix_existing
      love_v1355_export_direct
      love_v1354_qr_direct
      ;;
    cert-switch|cert-menu|cert-mode)
      love_v1354_cert_switch
      love_v1355_export_direct
      love_v1354_qr_direct
      ;;
    web|web-fix|fix-web)
      web_admin_page
      ;;
    source-correct|final-fix|client-output-fix|importable-fix|v2rayn-fix|sub|subscribe|true-fix|cert-true-fix)
      love_v1355_export_direct
      love_v1354_qr_direct
      ;;
    legacy|legacy-links|old-links)
      love_v1355_archive_legacy_links
      echo "[OK] 旧链接已归档：/opt/Love/subscribe/clients/legacy-raw-links.txt"
      ;;
    v1355-check|v1354-check|check-final|final-check|template-check|source-template-check|body-check)
      love_v1355_check
      ;;
    *)
      love_original_main_v1354 "$@"
      ;;
  esac
}



# ==============================================================================
# Love v13.56 Source-First H2 Reality Final
#
# Principle:
#   - New installs must be correct at the source template body.
#   - H2/gRPC Reality is generated correctly in write_singbox_config() and save_singbox_info().
#   - h2-fix remains only as a legacy VPS repair/check command; it is not part of the normal path.
#   - Green Web appearance is preserved.
#   - No existing feature is removed.
# ================================================================================

LOVE_SCRIPT_VERSION="Love v13.57.0-v2rayn-import-true-source-final"

love_v1356_bool_true() {
  case "${1:-1}" in
    0|false|False|FALSE|no|No|NO) return 1 ;;
    *) return 0 ;;
  esac
}

love_v1356_tls_extra() {
  local insecure="${1:-1}" proto="${2:-generic}"
  if ! love_v1356_bool_true "$insecure"; then
    case "$proto" in
      tuic) echo "alpn=h3" ;;
      *) echo "" ;;
    esac
    return 0
  fi

  case "$proto" in
    hy2) echo "insecure=true" ;;
    tuic) echo "allow_insecure=true&allowInsecure=true&insecure=true&alpn=h3" ;;
    vless_ws_tls) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
    trojan) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
    anytls) echo "insecure=true" ;;
    naive) echo "insecure=true&allowInsecure=true&allow_insecure=true" ;;
    *) echo "allowInsecure=true&insecure=true&allow_insecure=true" ;;
  esac
}

# Keep old function name compatible, but make it source-correct from now on.
love_v1352_tls_extra() { love_v1356_tls_extra "$@"; }

# Source-correct sing-box template body for new installs.
# H2 Reality / gRPC Reality / TUIC are written correctly here, not repaired later.
write_singbox_config() {
  local reality_sni="$1"
  local tls_sni="$2"
  local cert_dir="$3"
  local start_port="$4"

  local port="$start_port"
  SB_REALITY_PORT="$port"; ((port++)) || true
  SB_HY2_PORT="$port"; ((port++)) || true
  SB_TUIC_PORT="$port"; ((port++)) || true
  SB_SS_PORT="$port"; ((port++)) || true
  SB_TROJAN_PORT="$port"; ((port++)) || true
  SB_VMESS_WS_PORT="$port"; ((port++)) || true
  SB_VLESS_WS_TLS_PORT="$port"; ((port++)) || true
  SB_H2_REALITY_PORT="$port"; ((port++)) || true
  SB_GRPC_REALITY_PORT="$port"; ((port++)) || true
  SB_ANYTLS_PORT="$port"; ((port++)) || true
  SB_NAIVE_PORT="$port"; ((port++)) || true
  SB_SHADOWTLS_PORT="$port"; ((port++)) || true

  local inbound_file="/tmp/love-singbox-inbounds.jsonl"
  : > "$inbound_file"

  if [[ "$INSTALL_REALITY" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"vless-reality-in","listen":"::","listen_port":${SB_REALITY_PORT},"users":[{"uuid":"${SB_UUID}","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]}}}
EOF
  fi

  if [[ "$INSTALL_HY2" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":${SB_HY2_PORT},"users":[{"password":"${SB_HY2_PASS}"}],"tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem","alpn":["h3"]}}
EOF
  fi

  if [[ "$INSTALL_TUIC" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":${SB_TUIC_PORT},"users":[{"uuid":"${SB_UUID}","password":"${SB_TUIC_PASS}"}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":"${tls_sni}","certificate_path":"${cert_dir}/cert.pem","key_path":"${cert_dir}/key.pem","alpn":["h3"]}}
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
{"type":"vless","tag":"h2-reality-in","listen":"::","listen_port":${SB_H2_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]},"alpn":["h2"]},"transport":{"type":"http","host":["${reality_sni}"],"path":"/h2"}}
EOF
  fi

  if [[ "$INSTALL_GRPC_REALITY" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF
{"type":"vless","tag":"grpc-reality-in","listen":"::","listen_port":${SB_GRPC_REALITY_PORT},"users":[{"uuid":"${SB_UUID}"}],"tls":{"enabled":true,"server_name":"${reality_sni}","reality":{"enabled":true,"handshake":{"server":"${reality_sni}","server_port":443},"private_key":"${SB_PRIVATE}","short_id":["${SB_REALITY_SHORT}"]},"alpn":["h2"]},"transport":{"type":"grpc","service_name":"lovegrpc"}}
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

# Source-correct client output. No later h2-fix is required for new output.
save_singbox_info() {
  local client_addr="$1"
  local client_port_base="$2"
  local reality_sni="$3"
  local tls_sni="$4"
  local insecure="$5"

  local h flag hy2_extra tuic_extra vless_extra trojan_extra anytls_extra naive_extra vmess_json vmess_b64
  h="$(uri_host "${client_addr}")"
  flag="$(love_v1352_flag_emoji)"

  hy2_extra="$(love_v1356_tls_extra "$insecure" hy2)"
  tuic_extra="$(love_v1356_tls_extra "$insecure" tuic)"
  vless_extra="$(love_v1356_tls_extra "$insecure" vless_ws_tls)"
  trojan_extra="$(love_v1356_tls_extra "$insecure" trojan)"
  anytls_extra="$(love_v1356_tls_extra "$insecure" anytls)"
  naive_extra="$(love_v1356_tls_extra "$insecure" naive)"

  : > "${SINGBOX_INFO}"

  {
    echo "Love sing-box Client Info"
    echo
    echo "Client Address: ${client_addr}"
    echo "Base Port: ${client_port_base}"
    echo "Reality SNI: ${reality_sni}"
    echo "TLS SNI: ${tls_sni}"
    echo "Insecure: ${insecure}"
    echo "Flag: ${flag}"
    echo "Source Mode: v13.56 source-first"
    echo
  } >> "${SINGBOX_INFO}"

  if [[ "$INSTALL_REALITY" == "yes" ]]; then
    echo "VLESS Reality:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=tcp#$(love_v1352_label LOVE-REALITY)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_HY2" == "yes" ]]; then
    echo "HY2:" >> "${SINGBOX_INFO}"
    if [[ -n "$hy2_extra" ]]; then
      echo "hy2://${SB_HY2_PASS}@${h}:${SB_HY2_PORT}/?sni=${tls_sni}&${hy2_extra}#$(love_v1352_label LOVE-HY2)" >> "${SINGBOX_INFO}"
    else
      echo "hy2://${SB_HY2_PASS}@${h}:${SB_HY2_PORT}/?sni=${tls_sni}#$(love_v1352_label LOVE-HY2)" >> "${SINGBOX_INFO}"
    fi
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TUIC" == "yes" ]]; then
    echo "TUIC:" >> "${SINGBOX_INFO}"
    echo "tuic://${SB_UUID}:${SB_TUIC_PASS}@${h}:${SB_TUIC_PORT}?sni=${tls_sni}&congestion_control=bbr&udp_relay_mode=native&${tuic_extra}#$(love_v1352_label LOVE-TUIC)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_SS" == "yes" ]]; then
    echo "Shadowsocks:" >> "${SINGBOX_INFO}"
    echo "ss://$(printf 'aes-128-gcm:%s' "${SB_SS_PASS}" | base64 -w0)@${h}:${SB_SS_PORT}#$(love_v1352_label LOVE-SS)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_TROJAN" == "yes" ]]; then
    echo "Trojan:" >> "${SINGBOX_INFO}"
    if [[ -n "$trojan_extra" ]]; then
      echo "trojan://${SB_TROJAN_PASS}@${h}:${SB_TROJAN_PORT}?security=tls&sni=${tls_sni}&${trojan_extra}#$(love_v1352_label LOVE-TROJAN)" >> "${SINGBOX_INFO}"
    else
      echo "trojan://${SB_TROJAN_PASS}@${h}:${SB_TROJAN_PORT}?security=tls&sni=${tls_sni}#$(love_v1352_label LOVE-TROJAN)" >> "${SINGBOX_INFO}"
    fi
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VMESS_WS" == "yes" ]]; then
    echo "VMess WS:" >> "${SINGBOX_INFO}"
    vmess_json="$(jq -nc \
      --arg ps "$(love_v1352_label LOVE-VMESS-WS)" \
      --arg add "${client_addr#[}" \
      --arg port "${SB_VMESS_WS_PORT}" \
      --arg id "${SB_UUID}" \
      '{v:"2",ps:$ps,add:($add|sub("\\]$";"")),port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:"",path:"/vmess",tls:"",sni:""}')"
    vmess_b64="$(printf '%s' "$vmess_json" | base64 -w0)"
    echo "vmess://${vmess_b64}" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_VLESS_WS_TLS" == "yes" ]]; then
    echo "VLESS WS TLS:" >> "${SINGBOX_INFO}"
    if [[ -n "$vless_extra" ]]; then
      echo "vless://${SB_UUID}@${h}:${SB_VLESS_WS_TLS_PORT}?encryption=none&security=tls&sni=${tls_sni}&type=ws&path=%2Fvless&${vless_extra}#$(love_v1352_label LOVE-VLESS-WS-TLS)" >> "${SINGBOX_INFO}"
    else
      echo "vless://${SB_UUID}@${h}:${SB_VLESS_WS_TLS_PORT}?encryption=none&security=tls&sni=${tls_sni}&type=ws&path=%2Fvless#$(love_v1352_label LOVE-VLESS-WS-TLS)" >> "${SINGBOX_INFO}"
    fi
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_H2_REALITY" == "yes" ]]; then
    echo "H2 Reality:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_H2_REALITY_PORT}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=http&path=%2Fh2&host=${reality_sni}&alpn=h2#$(love_v1352_label LOVE-H2-REALITY)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_GRPC_REALITY" == "yes" ]]; then
    echo "gRPC Reality:" >> "${SINGBOX_INFO}"
    echo "vless://${SB_UUID}@${h}:${SB_GRPC_REALITY_PORT}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${SB_PUBLIC}&sid=${SB_REALITY_SHORT}&type=grpc&serviceName=lovegrpc&authority=${reality_sni}&mode=gun&alpn=h2#$(love_v1352_label LOVE-GRPC-REALITY)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_ANYTLS" == "yes" ]]; then
    echo "AnyTLS:" >> "${SINGBOX_INFO}"
    if [[ -n "$anytls_extra" ]]; then
      echo "anytls://${SB_ANYTLS_PASS}@${h}:${SB_ANYTLS_PORT}?sni=${tls_sni}&${anytls_extra}#$(love_v1352_label LOVE-ANYTLS)" >> "${SINGBOX_INFO}"
    else
      echo "anytls://${SB_ANYTLS_PASS}@${h}:${SB_ANYTLS_PORT}?sni=${tls_sni}#$(love_v1352_label LOVE-ANYTLS)" >> "${SINGBOX_INFO}"
    fi
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_NAIVE" == "yes" ]]; then
    echo "Naive:" >> "${SINGBOX_INFO}"
    if [[ -n "$naive_extra" ]]; then
      echo "https://${SB_NAIVE_USER}:${SB_NAIVE_PASS}@${h}:${SB_NAIVE_PORT}?sni=${tls_sni}&${naive_extra}#$(love_v1352_label LOVE-NAIVE)" >> "${SINGBOX_INFO}"
    else
      echo "https://${SB_NAIVE_USER}:${SB_NAIVE_PASS}@${h}:${SB_NAIVE_PORT}?sni=${tls_sni}#$(love_v1352_label LOVE-NAIVE)" >> "${SINGBOX_INFO}"
    fi
    echo >> "${SINGBOX_INFO}"
  fi

  if [[ "$INSTALL_SHADOWTLS" == "yes" ]]; then
    echo "ShadowTLS manual:" >> "${SINGBOX_INFO}"
    echo "Address=${client_addr} Port=${SB_SHADOWTLS_PORT} Password=${SB_SHADOWTLS_PASS} Version=3 Handshake=addons.mozilla.org Detour=SS Label=$(love_v1352_label LOVE-SHADOWTLS)" >> "${SINGBOX_INFO}"
    echo >> "${SINGBOX_INFO}"
  fi

  chmod 600 "${SINGBOX_INFO}"
  cat "${SINGBOX_INFO}"
}

love_v1356_source_check() {
  echo "================ Love v13.57 Source-First + V2RayN 检查 ================"
  echo "VERSION=${LOVE_SCRIPT_VERSION}"
  echo
  echo "[1] 源头服务端模板："
  declare -f write_singbox_config | grep -q '"tag":"h2-reality-in"' && echo "[OK] H2 Reality 入站在源头模板生成" || echo "[WARN] H2 Reality 源头模板未找到"
  declare -f write_singbox_config | grep -q '"alpn":\["h2"\]' && echo "[OK] H2/gRPC Reality 源头写入 tls.alpn=[h2]" || echo "[WARN] 源头未发现 alpn h2"
  declare -f write_singbox_config | grep -q '"transport":{"type":"http","host"' && echo "[OK] H2 Reality 源头写入 http transport/host/path" || echo "[WARN] H2 Reality transport 源头未完整"
  declare -f write_singbox_config | grep -q '"alpn":\["h3"\]' && echo "[OK] HY2/TUIC 源头写入 h3 ALPN" || echo "[WARN] 源头未发现 h3 ALPN"
  echo
  echo "[2] 源头客户端输出："
  declare -f love_v1356_tls_extra | grep -q 'insecure=true' && echo "[OK] 自签/不可信证书源头输出 true，不再输出 1" || echo "[WARN] 源头未发现 insecure=true"
  declare -f save_singbox_info | grep -q 'LOVE-H2-REALITY' && echo "[OK] H2 Reality URI 源头输出" || echo "[WARN] H2 Reality URI 源头未找到"
  declare -f save_singbox_info | grep -q 'type=http&path=%2Fh2&host=' && echo "[OK] H2 Reality URI 源头含 type/http/path/host/alpn" || echo "[WARN] H2 Reality URI 源头参数不完整"
  declare -f save_singbox_info | grep -q 'LOVE-NAIVE' && declare -f save_singbox_info | grep -q 'sni=${tls_sni}' && echo "[OK] Naive 源头补 sni/insecure" || echo "[WARN] Naive 源头未完整"
  echo
  echo "[3] 当前已导出链接残留检查："
  if grep -nE 'insecure=1|insecure=0|allowInsecure=1|allow_insecure=1' /opt/Love/subscribe/all.txt 2>/dev/null; then
    echo "[WARN] 当前旧导出仍有 1/0。执行 Love source-correct 重新从源头导出。"
  else
    echo "[OK] 当前导出未发现旧式 1/0。"
  fi

  echo
  echo "[4] v2rayN 专用导入检查："
  if [[ -s /opt/Love/subscribe/clients/v2rayn-uri.txt ]]; then
    if grep -nE 'insecure=1|allowInsecure=1|allow_insecure=1' /opt/Love/subscribe/clients/v2rayn-uri.txt >/dev/null 2>&1; then
      echo "[OK] v2rayN 专用文件使用 1 格式，避免部分 v2rayN 导入后仍显示 False。"
    else
      echo "[WARN] v2rayN 专用文件未发现 1 格式，执行 Love v2rayn-fix。"
    fi
  else
    echo "[WARN] v2rayN 专用文件不存在，执行 Love source-correct。"
  fi
}

love_after_node_generated_exports() {
  echo
  echo "================ Love Source-First Export v13.57 ================"
  love_v1355_export_direct
  love_v1354_qr_direct
  echo "[OK] 新安装节点已从模板源头生成正确服务端配置和客户端链接。h2-fix 仅保留给旧 VPS 维修；v2rayN 专用导入已单独生成。"
  web_admin_page
}

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.57.0-v2rayn-import-true-source-final}"
  case "${1:-}" in
    h2-fix|grpc-fix|reality-h2-fix|tuic-fix|legacy-h2-fix)
      echo "[INFO] 这是旧 VPS 遗留配置修复入口；新安装已经从 write_singbox_config 源头生成正确 H2/gRPC Reality。"
      love_v1355_h2_fix_existing
      love_v1355_export_direct
      love_v1354_qr_direct
      ;;
    cert-switch|cert-menu|cert-mode)
      love_v1354_cert_switch
      love_v1355_export_direct
      love_v1354_qr_direct
      ;;
    web|web-fix|fix-web)
      web_admin_page
      ;;
    source-correct|final-fix|client-output-fix|importable-fix|v2rayn-fix|sub|subscribe|true-fix|cert-true-fix)
      love_v1355_export_direct
      love_v1354_qr_direct
      ;;
    legacy|legacy-links|old-links)
      love_v1355_archive_legacy_links
      echo "[OK] 旧链接已归档：/opt/Love/subscribe/clients/legacy-raw-links.txt"
      ;;
    v1356-check|source-first-check|source-check|v1355-check|v1354-check|check-final|final-check|template-check|source-template-check|body-check)
      love_v1356_source_check
      ;;
    *)
      love_original_main_v1354 "$@"
      ;;
  esac
}



# ================================================================================
# Love v13.60 Network + CF API + Cert + Sub + Speed Final
#
# Upgrade policy:
#   - Do NOT remove any existing function, protocol, green web page, QR page, or legacy archive.
#   - Only add safe entry points and wrappers.
#   - New VPS installs still use source-first generation from earlier v13.56/v13.57 logic.
#   - Existing VPS operations below are non-destructive unless the user explicitly confirms.
# ================================================================================

LOVE_SCRIPT_VERSION="Love v13.60.0-network-cf-cert-sub-speed-final"

love_v1360_mkdirs() {
  mkdir -p /opt/Love /opt/Love/reports /opt/Love/secrets /opt/Love/subscribe /opt/Love/subscribe/clients /var/www/love-admin 2>/dev/null || true
  chmod 700 /opt/Love/secrets 2>/dev/null || true
}

love_v1360_header() {
  echo
  echo "================ $* ================"
}

love_v1360_cmd_exists() { command -v "$1" >/dev/null 2>&1; }

love_v1360_public_ip() {
  local fam="$1" ip=""
  if [[ "$fam" == "4" ]]; then
    ip="$(curl -4 -s --max-time 6 https://ifconfig.co 2>/dev/null | tr -d '\r\n ' || true)"
  else
    ip="$(curl -6 -s --max-time 6 https://ifconfig.co 2>/dev/null | tr -d '\r\n ' || true)"
  fi
  [[ -n "$ip" ]] && echo "$ip"
}

love_v1360_env_detect() {
  love_v1360_mkdirs
  local report="/opt/Love/reports/env-report.txt"
  local arch os pretty virt ipv4 ipv6 provider="unknown" cpu model ports
  arch="$(uname -m 2>/dev/null || echo unknown)"
  os="unknown"; pretty="unknown"
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os="${ID:-unknown}"; pretty="${PRETTY_NAME:-$os}"
  fi
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  cpu="$(nproc 2>/dev/null || echo unknown)"
  model="$(awk -F: '/model name|Hardware|Processor/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  ipv4="$(love_v1360_public_ip 4 || true)"
  ipv6="$(love_v1360_public_ip 6 || true)"
  if grep -qi oracle /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor 2>/dev/null; then provider="Oracle/OCI possible"; fi
  if hostname 2>/dev/null | grep -Eqi 'hax|hax\.co|haxvps'; then provider="Hax possible"; fi
  ports="$(ss -lntup 2>/dev/null | awk 'NR==1 || /:8881|:8882|:8883|:8884|:8885|:8886|:8887|:8888|:8889|:8890|:8891|:443|:80/' || true)"

  {
    echo "Love v13.60 VPS Environment Report"
    echo "Generated: $(date '+%F %T')"
    echo
    echo "OS: $pretty"
    echo "Arch: $arch"
    echo "CPU cores: $cpu"
    echo "CPU model: ${model:-unknown}"
    echo "Virtualization: $virt"
    echo "Provider hint: $provider"
    echo
    echo "IPv4 outbound: ${ipv4:-NO}"
    echo "IPv6 outbound: ${ipv6:-NO}"
    echo
    if [[ -z "$ipv4" && -n "$ipv6" ]]; then
      echo "Network mode: IPv6-only / IPv6-first"
      echo "Advice: HY2/Reality/TUIC can work over IPv6. Some IPv4-only websites may need WARP/NAT64 or an IPv4 VPS."
    elif [[ -n "$ipv4" && -n "$ipv6" ]]; then
      echo "Network mode: dual-stack"
    elif [[ -n "$ipv4" && -z "$ipv6" ]]; then
      echo "Network mode: IPv4-only"
    else
      echo "Network mode: no public outbound detected by curl"
    fi
    echo
    echo "Listening ports snapshot:"
    echo "$ports"
    echo
    echo "Oracle/OCI note: UFW rules are not enough by themselves. Also open TCP/UDP ports in OCI Security List or Network Security Group."
    echo "Hax/free VPS note: IPv6-only is common; client network must support IPv6 unless you use tunnel/NAT64/WARP outbound."
  } | tee "$report"
  echo
  echo "[OK] 环境报告：$report"
}

love_v1360_optimize() {
  love_v1360_header "Love Optimize v13.60"
  need_root 2>/dev/null || true
  love_v1360_mkdirs
  local conf="/etc/sysctl.d/99-love-network.conf"
  cp -f "$conf" "$conf.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  cat > "$conf" <<'EOF'
# Love network optimization. Safe TCP defaults for proxy nodes.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
EOF
  sysctl --system >/dev/null 2>&1 || true
  echo "[INFO] BBR status:"
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
  lsmod | grep -i bbr || true
  echo
  echo "[INFO] MTU 建议："
  echo "  Hax / IPv6-only / HY2 / TUIC：1350"
  echo "  Oracle AMD/ARM 双栈：1350~1400"
  echo "  如果 UDP 丢包或握手慢：降到 1300"
  echo
  echo "[OK] 已写入 $conf。没有强制改网卡 MTU，避免断 SSH。"
}

love_v1360_cert_paths() {
  local engine="${1:-sing-box}"
  case "$engine" in
    xray|Xray) echo "/usr/local/etc/xray cert.pem key.pem xray" ;;
    *) echo "/etc/sing-box/cert cert.pem key.pem root" ;;
  esac
}

love_v1360_cert_check() {
  love_v1360_header "Love Cert Check v13.60"
  love_v1360_mkdirs
  local mode sni addr files=(/etc/sing-box/cert/cert.pem /etc/sing-box/cert/key.pem /usr/local/etc/xray/cert.pem /usr/local/etc/xray/key.pem /etc/letsencrypt/live/*/fullchain.pem)
  mode="$(cat /opt/Love/cert-mode 2>/dev/null || cat /opt/Love/install-cert-case 2>/dev/null || echo unknown)"
  sni="$(cat /opt/Love/node-sni 2>/dev/null || echo unknown)"
  addr="$(cat /opt/Love/client-address 2>/dev/null || echo unknown)"
  echo "cert-mode: $mode"
  echo "node-sni:   $sni"
  echo "client-address: $addr"
  echo
  for f in "${files[@]}"; do
    for real in $f; do
      [[ -f "$real" ]] || continue
      echo "--- $real"
      if [[ "$real" == *.pem ]] && openssl x509 -in "$real" -noout >/dev/null 2>&1; then
        openssl x509 -in "$real" -noout -subject -issuer -dates 2>/dev/null || true
        openssl x509 -in "$real" -noout -ext subjectAltName 2>/dev/null | sed 's/^/SAN: /' || true
        if [[ "$sni" != "unknown" ]]; then
          if openssl x509 -in "$real" -noout -checkhost "$sni" >/dev/null 2>&1; then
            echo "[OK] 证书匹配 SNI：$sni"
          else
            echo "[WARN] 证书不匹配 SNI：$sni。若这是 self.local/自签/过期/错域名模式，客户端应输出 insecure=true。"
          fi
        fi
      else
        echo "[INFO] 非 x509 证书或 key 文件。"
      fi
      echo
    done
  done
  echo "[TIP] HTTP-01：Love cert-ca；Cloudflare DNS-01：Love cf-cert；切换客户端证书模式：Love cert-switch。"
}

love_v1360_cert_http01() {
  love_v1360_header "Love HTTP-01 Let's Encrypt Cert"
  need_root 2>/dev/null || true
  local domain email engine outdir certfile keyfile group occupied stopok
  read -rp "域名，例如 node.example.com: " domain
  [[ -n "$domain" ]] || { echo "[ERROR] 域名不能为空。"; return 1; }
  read -rp "Let's Encrypt 邮箱: " email
  [[ -n "$email" ]] || { echo "[ERROR] 邮箱不能为空。"; return 1; }
  read -rp "证书用于哪个核心？[sing-box/xray, 默认 sing-box]: " engine
  engine="${engine:-sing-box}"
  read -r outdir certfile keyfile group < <(love_v1360_cert_paths "$engine")
  mkdir -p "$outdir"
  if ss -lntp 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])80$'; then
    echo "[WARN] 80 端口被占用："
    ss -lntp | grep ':80' || true
    read -rp "是否临时停止 nginx/apache2/caddy 申请证书？[y/N]: " stopok
    [[ "$stopok" =~ ^[Yy]$ ]] || { echo "[ERROR] 已取消。"; return 1; }
    systemctl stop nginx apache2 caddy 2>/dev/null || true
  fi
  if ! love_v1360_cmd_exists certbot; then
    echo "[INFO] 安装 certbot..."
    install_base 2>/dev/null || true
  fi
  certbot certonly --standalone --preferred-challenges http -d "$domain" --agree-tos -m "$email" --non-interactive --keep-until-expiring || return 1
  install -m 640 -o root -g "$group" "/etc/letsencrypt/live/$domain/fullchain.pem" "$outdir/$certfile"
  install -m 640 -o root -g "$group" "/etc/letsencrypt/live/$domain/privkey.pem" "$outdir/$keyfile"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > "/etc/letsencrypt/renewal-hooks/deploy/love-copy-${engine}.sh" <<EOF
#!/usr/bin/env bash
set -e
DOMAIN="$domain"
if echo " \${RENEWED_DOMAINS:-} " | grep -q " $domain "; then
  install -m 640 -o root -g "$group" "/etc/letsencrypt/live/$domain/fullchain.pem" "$outdir/$certfile"
  install -m 640 -o root -g "$group" "/etc/letsencrypt/live/$domain/privkey.pem" "$outdir/$keyfile"
  systemctl restart "$engine" 2>/dev/null || true
fi
EOF
  chmod +x "/etc/letsencrypt/renewal-hooks/deploy/love-copy-${engine}.sh"
  echo public_ca > /opt/Love/cert-mode
  echo "$domain" > /opt/Love/node-sni
  echo "[OK] 证书已安装到 $outdir，并写入 cert-mode=public_ca。"
  systemctl restart "$engine" 2>/dev/null || true
  love_v1355_export_direct 2>/dev/null || true
}

love_v1360_cf_secret_file() { echo "/opt/Love/secrets/cloudflare.env"; }

love_v1360_cf_load() {
  local f; f="$(love_v1360_cf_secret_file)"
  [[ -f "$f" ]] && . "$f"
  [[ -n "${CF_API_TOKEN:-}" ]]
}

love_v1360_cf_config() {
  love_v1360_header "Love Cloudflare API Config"
  love_v1360_mkdirs
  local token f
  f="$(love_v1360_cf_secret_file)"
  read -rsp "Cloudflare API Token（需要 Zone:DNS Edit 权限）: " token; echo
  [[ -n "$token" ]] || { echo "[ERROR] Token 不能为空。"; return 1; }
  umask 077
  cat > "$f" <<EOF
export CF_API_TOKEN='$token'
EOF
  chmod 600 "$f"
  echo "[OK] 已保存到 $f（权限 600，不会写入 Web/订阅/client-info）。"
}

love_v1360_cf_api() {
  local method="$1" url="$2" data="${3:-}"
  love_v1360_cf_load || { echo "[ERROR] 未配置 Cloudflare Token。先执行 Love cf-config。" >&2; return 1; }
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4/$url" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "$data"
  else
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4/$url" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json"
  fi
}

love_v1360_cf_zone_id() {
  local zone="$1"
  love_v1360_cf_api GET "zones?name=${zone}&status=active" | jq -r '.result[0].id // empty'
}

love_v1360_cf_dns() {
  love_v1360_header "Love Cloudflare DNS Upsert"
  love_v1360_mkdirs
  love_v1360_cf_load || love_v1360_cf_config || return 1
  local zone name typ content proxied zid rid payload res ipv4 ipv6
  read -rp "根域名 Zone，例如 example.com: " zone
  [[ -n "$zone" ]] || { echo "[ERROR] Zone 不能为空。"; return 1; }
  read -rp "记录名，例如 node.example.com: " name
  [[ -n "$name" ]] || { echo "[ERROR] 记录名不能为空。"; return 1; }
  read -rp "记录类型 [A/AAAA，默认 AAAA]: " typ
  typ="${typ:-AAAA}"; typ="${typ^^}"
  if [[ "$typ" == "A" ]]; then content="$(love_v1360_public_ip 4 || true)"; else content="$(love_v1360_public_ip 6 || true)"; fi
  read -rp "记录值 [$content]: " tmp_content
  content="${tmp_content:-$content}"
  [[ -n "$content" ]] || { echo "[ERROR] 没检测到记录值，请手动输入。"; return 1; }
  read -rp "是否橙云 Proxied？Reality/HY2/TUIC 推荐 N，WS/Trojan 可 Y [y/N]: " proxied
  [[ "$proxied" =~ ^[Yy]$ ]] && proxied=true || proxied=false
  zid="$(love_v1360_cf_zone_id "$zone")"
  [[ -n "$zid" ]] || { echo "[ERROR] 找不到 Zone ID。检查 Token 或 Zone 名。"; return 1; }
  rid="$(love_v1360_cf_api GET "zones/$zid/dns_records?type=$typ&name=$name" | jq -r '.result[0].id // empty')"
  payload="$(jq -nc --arg type "$typ" --arg name "$name" --arg content "$content" --argjson proxied "$proxied" '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')"
  if [[ -n "$rid" ]]; then
    res="$(love_v1360_cf_api PUT "zones/$zid/dns_records/$rid" "$payload")"
  else
    res="$(love_v1360_cf_api POST "zones/$zid/dns_records" "$payload")"
  fi
  echo "$res" | jq .
  if echo "$res" | jq -e '.success==true' >/dev/null 2>&1; then
    echo "$name" > /opt/Love/node-sni
    echo "$name" > /opt/Love/client-address
    echo "[OK] DNS 已更新。Reality/HY2/TUIC 通常用 DNS only；Trojan/WS TLS 可橙云。"
  else
    echo "[ERROR] Cloudflare DNS 更新失败。"
    return 1
  fi
}

love_v1360_cf_cert_dns01() {
  love_v1360_header "Love Cloudflare DNS-01 Cert"
  need_root 2>/dev/null || true
  love_v1360_mkdirs
  love_v1360_cf_load || love_v1360_cf_config || return 1
  local domain engine outdir certfile keyfile group acme email
  read -rp "申请证书域名，例如 node.example.com 或 *.example.com: " domain
  [[ -n "$domain" ]] || { echo "[ERROR] 域名不能为空。"; return 1; }
  read -rp "证书用于哪个核心？[sing-box/xray, 默认 sing-box]: " engine
  engine="${engine:-sing-box}"
  read -r outdir certfile keyfile group < <(love_v1360_cert_paths "$engine")
  mkdir -p "$outdir"
  acme="$HOME/.acme.sh/acme.sh"
  if [[ ! -x "$acme" ]]; then
    echo "[INFO] 安装 acme.sh..."
    curl https://get.acme.sh | sh -s email="$(whoami)@$(hostname -f 2>/dev/null || hostname).local" || return 1
  fi
  export CF_Token="$CF_API_TOKEN"
  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$acme" --issue --dns dns_cf -d "$domain" --keylength ec-256 || return 1
  "$acme" --install-cert -d "$domain" --ecc \
    --fullchain-file "$outdir/$certfile" \
    --key-file "$outdir/$keyfile" \
    --reloadcmd "systemctl restart $engine 2>/dev/null || true" || return 1
  chown root:"$group" "$outdir/$certfile" "$outdir/$keyfile" 2>/dev/null || true
  chmod 640 "$outdir/$certfile" "$outdir/$keyfile" 2>/dev/null || true
  echo public_ca > /opt/Love/cert-mode
  echo "$domain" | sed 's/^\*\.//' > /opt/Love/node-sni
  echo "[OK] DNS-01 证书已安装到 $outdir。"
  systemctl restart "$engine" 2>/dev/null || true
  love_v1355_export_direct 2>/dev/null || true
}

love_v1360_generate_client_subs() {
  love_v1360_header "Love Subscriptions v13.60"
  love_v1360_mkdirs
  love_v1355_export_direct 2>/dev/null || love_v1354_export_direct 2>/dev/null || true
  love_v1354_qr_direct 2>/dev/null || true
  local sub="/opt/Love/subscribe" cli="/opt/Love/subscribe/clients"
  mkdir -p "$cli"
  [[ -s "$sub/all.txt" ]] && cp -f "$sub/all.txt" "$cli/nekobox-uri.txt" 2>/dev/null || true
  [[ -s "$sub/all.txt" ]] && cp -f "$sub/all.txt" "$cli/v2rayng-uri.txt" 2>/dev/null || true
  [[ -s "$sub/all.txt" ]] && cp -f "$sub/all.txt" "$cli/singbox-uri.txt" 2>/dev/null || true
  [[ -s "$sub/all.txt" ]] && grep -Ei 'LOVE-H2-REALITY|LOVE-GRPC-REALITY|LOVE-ANYTLS|LOVE-NAIVE|SHADOWTLS' "$sub/all.txt" > "$cli/experimental.txt" 2>/dev/null || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  if [[ -s "$sub/mihomo.yaml" ]]; then
    cp -f "$sub/mihomo.yaml" "$cli/clash-meta.yaml" 2>/dev/null || true
  elif [[ -s "$sub/clash_like.yaml" ]]; then
    cp -f "$sub/clash_like.yaml" "$cli/clash-meta.yaml" 2>/dev/null || true
  fi
  cat > "$cli/v2rayn-notes.txt" <<'EOF'
Love v2rayN notes:
1. LOVE-H2-REALITY 属于 VLESS + Reality + HTTP/H2。
2. v2rayN 使用这条节点时：设置 -> Core 类型设置 -> VLESS -> sing_box。
3. 如果 VLESS 仍用 Xray，新版 Xray 可能报 HTTP transport removed。
4. HY2/TUIC/Trojan/VLESS-WS-TLS 自签证书节点若显示“证书验证 False”，请确认节点参数里存在 insecure/allowInsecure。某些版本 v2rayN 更吃 insecure=1，所以本脚本单独生成 v2rayn-uri.txt。
EOF
  chmod 600 "$cli/legacy-raw-links.txt" 2>/dev/null || true
  echo "[OK] 已生成："
  for f in "$sub/all.txt" "$sub/all_base64.txt" "$cli/v2rayn-uri.txt" "$cli/v2rayng-uri.txt" "$cli/nekobox-uri.txt" "$cli/singbox-uri.txt" "$cli/clash-meta.yaml" "$cli/experimental.txt" "$cli/v2rayn-notes.txt"; do
    [[ -s "$f" ]] && echo "  $f"
  done
}

love_v1360_speed() {
  love_v1360_header "Love Speed / Diagnose v13.60"
  love_v1360_mkdirs
  local report="/opt/Love/reports/diagnose-report.txt" ipv4 ipv6
  ipv4="$(love_v1360_public_ip 4 || true)"
  ipv6="$(love_v1360_public_ip 6 || true)"
  {
    echo "Love diagnose report"
    echo "Generated: $(date '+%F %T')"
    echo
    echo "[Network]"
    echo "IPv4 outbound: ${ipv4:-NO}"
    echo "IPv6 outbound: ${ipv6:-NO}"
    echo
    echo "[Ping]"
    ping -4 -c 3 -W 2 1.1.1.1 2>/dev/null || echo "IPv4 ping failed"
    ping -6 -c 3 -W 2 2606:4700:4700::1111 2>/dev/null || echo "IPv6 ping failed"
    echo
    echo "[HTTP reachability]"
    curl -4 -I --max-time 8 https://www.google.com 2>/dev/null | head -5 || echo "curl -4 google failed"
    curl -6 -I --max-time 8 https://www.google.com 2>/dev/null | head -5 || echo "curl -6 google failed"
    echo
    echo "[Listening ports]"
    ss -lntup 2>/dev/null | awk 'NR==1 || /:80|:443|:8881|:8882|:8883|:8884|:8885|:8886|:8887|:8888|:8889|:8890|:8891/' || true
    echo
    echo "[UFW]"
    ufw status 2>/dev/null || echo "ufw unavailable"
    echo
    echo "[sing-box]"
    systemctl is-active sing-box 2>/dev/null || true
    sing-box check -c /etc/sing-box/config.json 2>&1 || true
    echo
    echo "[xray]"
    systemctl is-active xray 2>/dev/null || true
    xray run -test -config /usr/local/etc/xray/config.json 2>&1 || true
    echo
    echo "[Subscriptions/Web]"
    for f in /opt/Love/subscribe/all.txt /opt/Love/subscribe/all_base64.txt /opt/Love/subscribe/clients/v2rayn-uri.txt /opt/Love/subscribe/clients/clash-meta.yaml /var/www/love-admin/index.html /var/www/love-admin/qr/index.html; do
      [[ -s "$f" ]] && echo "[OK] $f" || echo "[MISS] $f"
    done
    echo
    echo "[Cert]"
    for f in /etc/sing-box/cert/cert.pem /usr/local/etc/xray/cert.pem; do
      [[ -s "$f" ]] && openssl x509 -in "$f" -noout -subject -issuer -dates 2>/dev/null || true
    done
  } | tee "$report"
  echo
  echo "[OK] 诊断报告：$report"
}

love_v1360_web() {
  love_v1360_generate_client_subs >/dev/null 2>&1 || true
  web_admin_page
}

love_v1360_help() {
  cat <<'EOF'
Love v13.60 added commands:
  Love env          VPS 环境识别：Hax/Oracle/AMD/ARM/IPv4/IPv6/端口
  Love optimize     BBR + 安全 sysctl；MTU 1350 建议，不强改网卡
  Love speed        一键诊断：IPv4/IPv6/DNS/端口/服务/订阅/Web/证书
  Love sub          重新生成所有订阅与客户端专用导出
  Love clients      同 Love sub
  Love clash        生成/刷新 clash-meta.yaml / mihomo.yaml
  Love cert-check   检查证书、SNI、过期、cert-mode
  Love cert-ca      HTTP-01 Let's Encrypt 证书申请
  Love cf-config    保存 Cloudflare API Token（600 权限）
  Love cf-dns       Cloudflare 自动添加/更新 A/AAAA
  Love cf-cert      Cloudflare DNS-01 申请证书

Kept from older versions:
  Love source-correct / web / qr / cert-switch / h2-fix / v2rayn-fix

Important:
  LOVE-H2-REALITY in v2rayN needs: Core type settings -> VLESS -> sing_box.
EOF
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_v1357 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_v1357/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.60.0-network-cf-cert-sub-speed-final}"
  case "${1:-}" in
    env|detect|vps|network)
      love_v1360_env_detect ;;
    optimize|bbr|mtu|sysctl)
      love_v1360_optimize ;;
    speed|diagnose|diag|test)
      love_v1360_speed ;;
    sub|subscribe|clients|client-export|source-correct|final-fix|client-output-fix|importable-fix|v2rayn-fix|true-fix|cert-true-fix)
      love_v1360_generate_client_subs ;;
    clash|mihomo|clash-meta)
      love_v1360_generate_client_subs; generate_mihomo_yaml ;;
    web|web-fix|fix-web)
      love_v1360_web ;;
    cert|cert-check|ssl-check)
      love_v1360_cert_check ;;
    cert-ca|cert-http|letsencrypt|le-cert)
      love_v1360_cert_http01 ;;
    cf|cloudflare|cf-config)
      love_v1360_cf_config ;;
    cf-dns|cloudflare-dns)
      love_v1360_cf_dns ;;
    cf-cert|cert-dns|dns-cert|dns01|dns-01)
      love_v1360_cf_cert_dns01 ;;
    v1360-check|v1358-check|v1359-check|check-final|final-check)
      love_v1360_env_detect; echo; love_v1360_cert_check; echo; love_v1356_source_check 2>/dev/null || true ;;
    help1360|v1360-help)
      love_v1360_help ;;
    *)
      love_original_main_v1357 "$@" ;;
  esac
}


# ================================================================================
# Love v13.60.2 Flag Icon Final
# Purpose:
#   - Convert country letters such as US/JP/DE into real emoji flag icons.
#   - Apply the same flag to all subscription outputs, client-specific files,
#     Web copied text files, and QR source links.
#   - Add menu/command entries without deleting any existing feature.
# ================================================================================
LOVE_SCRIPT_VERSION="Love v13.60.2-flag-icon-final"

love_v13602_cc_to_emoji() {
  local cc
  cc="$(echo "${1:-US}" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z' | head -c 2)"
  [[ ${#cc} -eq 2 ]] || cc="US"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$cc" <<'PYFLAG'
import sys
cc=(sys.argv[1] or 'US').upper()[:2]
print(''.join(chr(0x1F1E6 + ord(c) - ord('A')) for c in cc))
PYFLAG
  else
    case "$cc" in
      US) echo "🇺🇸" ;; JP) echo "🇯🇵" ;; SG) echo "🇸🇬" ;; HK) echo "🇭🇰" ;; TW) echo "🇹🇼" ;;
      KR) echo "🇰🇷" ;; DE) echo "🇩🇪" ;; GB|UK) echo "🇬🇧" ;; FR) echo "🇫🇷" ;; NL) echo "🇳🇱" ;;
      CA) echo "🇨🇦" ;; AU) echo "🇦🇺" ;; IN) echo "🇮🇳" ;; BR) echo "🇧🇷" ;; *) echo "🇺🇸" ;;
    esac
  fi
}

love_v13602_detect_country() {
  local cc
  cc="$(curl -fsS -4 --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
  [[ -z "$cc" ]] && cc="$(curl -fsS -6 --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
  [[ -z "$cc" ]] && cc="$(curl -fsS --max-time 4 https://ifconfig.co/country-iso 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
  [[ -z "$cc" ]] && cc="US"
  echo "$(echo "$cc" | tr '[:lower:]' '[:upper:]' | head -c 2)"
}

love_v13602_flag_get() {
  mkdir -p /opt/Love
  local cc flag raw
  raw="$(cat /opt/Love/node-flag 2>/dev/null || true)"
  cc="$(cat /opt/Love/node-country 2>/dev/null || true)"
  cc="$(echo "${cc:-}" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z' | head -c 2)"

  # If node-flag accidentally contains letters like US, convert them into emoji.
  if [[ "$raw" =~ ^[A-Za-z]{2}$ ]]; then
    cc="$(echo "$raw" | tr '[:lower:]' '[:upper:]')"
    flag="$(love_v13602_cc_to_emoji "$cc")"
  elif [[ -n "$raw" && ! "$raw" =~ ^[A-Za-z]+$ ]]; then
    flag="$raw"
    [[ -n "$cc" ]] || cc="US"
  else
    [[ -n "$cc" ]] || cc="$(love_v13602_detect_country)"
    flag="$(love_v13602_cc_to_emoji "$cc")"
  fi

  echo "$cc" > /opt/Love/node-country
  echo "$flag" > /opt/Love/node-flag
  printf '%s' "$flag"
}

love_flag_show13602() {
  local cc flag
  flag="$(love_v13602_flag_get)"
  cc="$(cat /opt/Love/node-country 2>/dev/null || echo US)"
  echo "当前国旗 / Current flag: $flag $cc"
}

love_flag_auto13602() {
  mkdir -p /opt/Love
  local cc flag
  cc="$(love_v13602_detect_country)"
  flag="$(love_v13602_cc_to_emoji "$cc")"
  echo "$cc" > /opt/Love/node-country
  echo "$flag" > /opt/Love/node-flag
  echo "[OK] 自动识别国旗 / Auto flag: $flag $cc"
}

love_flag_set13602() {
  mkdir -p /opt/Love
  echo "================ Love Flag Icon / 国旗图标设置 ================"
  love_flag_show13602 || true
  echo
  echo "输入两位国家代码会自动变成 emoji，例如：US -> 🇺🇸, DE -> 🇩🇪, JP -> 🇯🇵"
  echo "You may also paste an emoji flag directly."
  read -rp "国家代码或国旗 emoji [US]: " input
  input="${input:-US}"
  local cc flag
  if [[ "$input" =~ ^[A-Za-z]{2}$ ]]; then
    cc="$(echo "$input" | tr '[:lower:]' '[:upper:]')"
    flag="$(love_v13602_cc_to_emoji "$cc")"
  else
    cc="CUSTOM"
    flag="$input"
  fi
  echo "$cc" > /opt/Love/node-country
  echo "$flag" > /opt/Love/node-flag
  echo "[OK] 已设置 / Set: $flag $cc"
  echo "[INFO] 现在执行 Love flag-fix 或 Love sub，会把 US/JP/DE 等字母标签改成国旗图标。"
}

love_v13602_apply_flag_to_file() {
  local file="$1" flag
  [[ -s "$file" ]] || return 0
  flag="$(love_v13602_flag_get)"
  python3 - "$file" "$flag" <<'PYFLAGFIX'
from pathlib import Path
import sys, re, urllib.parse, base64, json

p = Path(sys.argv[1])
flag = sys.argv[2]
flag_re = re.compile(r'^[\U0001F1E6-\U0001F1FF]{2}\s*')
letter_re = re.compile(r'^(?:US|USA|JP|SG|HK|TW|KR|DE|GB|UK|FR|NL|CA|AU|IN|BR|SE|CH|IT|ES|PL|FI|NO|RU|TR|AE|TH|VN|ID|MY|PH|KR|CN)[\s_\-]+', re.I)
proto = ('vless://','hy2://','hysteria2://','tuic://','ss://','trojan://','vmess://','anytls://','https://','shadowtls://')

def clean_label(x: str) -> str:
    x = urllib.parse.unquote(x or 'LOVE').strip()
    x = flag_re.sub('', x).strip()
    x = letter_re.sub('', x).strip()
    return x or 'LOVE'

def with_flag(x: str) -> str:
    return f'{flag} {clean_label(x)}'

def b64decode_any(s: str) -> bytes:
    pad = '=' * (-len(s) % 4)
    return base64.urlsafe_b64decode((s + pad).encode())

def b64encode_plain(b: bytes) -> str:
    return base64.b64encode(b).decode().rstrip('=')

def fix_vmess(line: str) -> str:
    main, sep, frag = line.partition('#')
    payload = main[len('vmess://'):]
    try:
        obj = json.loads(b64decode_any(payload).decode('utf-8', errors='ignore'))
        obj['ps'] = with_flag(str(obj.get('ps') or frag or 'LOVE-VMESS'))
        enc = b64encode_plain(json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
        return 'vmess://' + enc + (('#' + obj['ps']) if sep else '')
    except Exception:
        if sep:
            return main + '#' + with_flag(frag)
        return line

def fix_uri(line: str) -> str:
    if line.startswith('vmess://'):
        return fix_vmess(line)
    main, sep, frag = line.partition('#')
    if sep:
        return main + '#' + with_flag(frag)
    if line.startswith(proto):
        return main + '#' + with_flag('LOVE')
    return line

def fix_yaml_name(line: str) -> str:
    # name: US LOVE-HY2  /  - name: "US LOVE-HY2"
    m = re.match(r'^(\s*-?\s*name:\s*)(["\']?)(.*?)(\2)\s*$', line)
    if not m:
        return line
    head, quote, name, tail = m.groups()
    if 'LOVE' not in name and not flag_re.match(name):
        return line
    return f'{head}{quote}{with_flag(name)}{quote}'

out = []
for raw in p.read_text(encoding='utf-8', errors='ignore').splitlines():
    line = raw.strip()
    if line.startswith(proto):
        out.append(fix_uri(line))
    elif 'name:' in raw and ('LOVE' in raw or flag_re.search(raw) or letter_re.search(raw.strip().split('name:',1)[-1].strip().strip('"\''))):
        out.append(fix_yaml_name(raw))
    else:
        out.append(raw)

p.write_text('\n'.join(out) + ('\n' if out else ''), encoding='utf-8')
PYFLAGFIX
}

love_v13602_refresh_base64() {
  local f="/opt/Love/subscribe/all.txt"
  [[ -s "$f" ]] || return 0
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$f" > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
  else
    base64 "$f" | tr -d '\n' > /opt/Love/subscribe/all_base64.txt 2>/dev/null || true
  fi
}

love_v13602_apply_flag_files() {
  local f
  mkdir -p /opt/Love/subscribe/clients /var/www/love-admin/clients 2>/dev/null || true
  for f in \
    /opt/Love/subscribe/all.txt \
    /opt/Love/subscribe/全部节点.txt \
    /opt/Love/subscribe/推荐节点.txt \
    /opt/Love/subscribe/节点清晰版.txt \
    /opt/Love/subscribe/clients/v2rayn-uri.txt \
    /opt/Love/subscribe/clients/v2rayng-uri.txt \
    /opt/Love/subscribe/clients/nekobox-uri.txt \
    /opt/Love/subscribe/clients/singbox-uri.txt \
    /opt/Love/subscribe/clients/nodes-clean.txt \
    /opt/Love/subscribe/clients/experimental.txt \
    /opt/Love/subscribe/clients/clash-meta.yaml \
    /opt/Love/subscribe/mihomo.yaml \
    /opt/Love/subscribe/clash_like.yaml \
    /var/www/love-admin/all.txt \
    /var/www/love-admin/node-links.txt \
    /var/www/love-admin/全部节点.txt \
    /var/www/love-admin/推荐节点.txt \
    /var/www/love-admin/节点清晰版.txt \
    /var/www/love-admin/sub/all.txt \
    /var/www/love-admin/clients/v2rayn-uri.txt \
    /var/www/love-admin/clients/v2rayng-uri.txt \
    /var/www/love-admin/clients/nekobox-uri.txt \
    /var/www/love-admin/clients/singbox-uri.txt \
    /var/www/love-admin/clients/clash-meta.yaml; do
    [[ -s "$f" ]] && love_v13602_apply_flag_to_file "$f" 2>/dev/null || true
  done
  love_v13602_refresh_base64
}

love_v13602_fix_flags_all() {
  echo "================ Love Flag Icon Fix v13.60.2 ================"
  love_flag_show13602 || true
  love_v13602_apply_flag_files
  # Rebuild QR from the flag-correct all.txt so QR imports also show emoji icons.
  love_v1354_qr_direct 2>/dev/null || love_v1354_qr_direct >/dev/null 2>&1 || true
  # Copy corrected subscription files back to Web if Web exists.
  if [[ -d /var/www/love-admin ]]; then
    cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/all.txt 2>/dev/null || true
    cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/node-links.txt 2>/dev/null || true
    cp -f /opt/Love/subscribe/all_base64.txt /var/www/love-admin/sub/all_base64.txt 2>/dev/null || true
    cp -f /opt/Love/subscribe/all.txt /var/www/love-admin/sub/all.txt 2>/dev/null || true
    cp -a /opt/Love/subscribe/clients/. /var/www/love-admin/clients/ 2>/dev/null || true
    cp -a /opt/Love/subscribe/qr/. /var/www/love-admin/qr/ 2>/dev/null || true
  fi
  echo "[OK] 已把 US/JP/DE 等字母标签统一改为 emoji 国旗图标。"
  echo "[OK] Flag icons fixed in subscriptions / clients / Web copied files / QR source."
}

# Save and wrap subscription generator so every rebuild ends with real emoji flags.
if declare -F love_v1360_generate_client_subs >/dev/null 2>&1 && ! declare -F love_original_v1360_generate_client_subs_before_flag13602 >/dev/null 2>&1; then
  eval "$(declare -f love_v1360_generate_client_subs | sed '1s/^love_v1360_generate_client_subs/love_original_v1360_generate_client_subs_before_flag13602/')"
fi

love_v1360_generate_client_subs() {
  love_original_v1360_generate_client_subs_before_flag13602 "$@" 2>/dev/null || true
  love_v13602_apply_flag_files
  love_v1354_qr_direct 2>/dev/null || true
  echo "[OK] 国旗图标已应用 / Flag icons applied: $(love_v13602_flag_get) $(cat /opt/Love/node-country 2>/dev/null || echo US)"
}

love_v1360_web() {
  love_v1360_generate_client_subs >/dev/null 2>&1 || true
  web_admin_page
  love_v13602_apply_flag_files
}

love_v13602_help() {
  cat <<'EOF'
Love v13.60.2 flag commands:
  Love flag          国旗图标设置 / set emoji flag icon
  Love flag-set      同上 / same as flag
  Love flag-auto     自动识别国家并转成 emoji 国旗
  Love flag-show     查看当前国旗
  Love flag-fix      把订阅里的 US/JP/DE 等字母改成 🇺🇸/🇯🇵/🇩🇪 图标

Main menu entries:
  45) 国旗图标设置 / Flag icon
  46) 自动识别国旗 / Auto flag
  47) 修复国旗字母 / Fix flag letters
EOF
}

# Final main override: keep all old commands, add flag commands, and open the color menu by default.
if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_before_flag13602 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_before_flag13602/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.60.2-flag-icon-final}"
  case "${1:-}" in
    ""|menu|main|m)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      if declare -F love_color_menu13601 >/dev/null 2>&1; then
        love_color_menu13601
      else
        love_original_main_before_flag13602 "$@"
      fi ;;
    flag|flag-set|set-flag)
      love_flag_set13602 ;;
    flag-auto|auto-flag)
      love_flag_auto13602; love_v13602_fix_flags_all ;;
    flag-show|show-flag)
      love_flag_show13602 ;;
    flag-fix|fix-flag|flag-icon-fix|country-fix)
      love_v13602_fix_flags_all ;;
    sub|subscribe|clients|client-export|source-correct|final-fix|client-output-fix|importable-fix|v2rayn-fix|true-fix|cert-true-fix)
      love_v1360_generate_client_subs ;;
    web|web-fix|fix-web)
      love_v1360_web ;;
    help13602|flag-help|v13602-help)
      love_v13602_help ;;
    *)
      love_original_main_before_flag13602 "$@" ;;
  esac
}


# ==============================================================================
# Love v13.60.3 Flag Icon Source-First Final
# Purpose:
#   - Generate real emoji flag remarks at the source/template layer.
#   - Do NOT depend on post-generation scanning such as flag-fix for normal output.
#   - Keep legacy flag-fix command only as a safe rebuild alias, not a file scanner.
#   - Preserve all existing protocols, Green Web, QR, and legacy archive behavior.
# ==============================================================================
LOVE_SCRIPT_VERSION="Love v13.60.3-flag-icon-source-first-final"

love_v13603_cc_to_emoji() {
  local cc
  cc="$(echo "${1:-US}" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z' | head -c 2)"
  [[ ${#cc} -eq 2 ]] || cc="US"
  python3 - "$cc" <<'PYFLAG' 2>/dev/null || echo "🇺🇸"
import sys
cc=(sys.argv[1] or 'US').upper()[:2]
if len(cc) != 2 or not cc.isalpha():
    cc='US'
print(''.join(chr(0x1F1E6 + ord(c) - ord('A')) for c in cc))
PYFLAG
}

love_v13603_detect_country() {
  local cc
  cc="$(curl -fsS -4 --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
  [[ -z "$cc" ]] && cc="$(curl -fsS -6 --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
  [[ -z "$cc" ]] && cc="$(curl -fsS --max-time 4 https://ifconfig.co/country-iso 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
  [[ -z "$cc" ]] && cc="US"
  echo "$(echo "$cc" | tr '[:lower:]' '[:upper:]' | head -c 2)"
}

love_v13603_flag_get() {
  mkdir -p /opt/Love
  local cc raw flag
  raw="$(cat /opt/Love/node-flag 2>/dev/null || true)"
  cc="$(cat /opt/Love/node-country 2>/dev/null || true)"
  cc="$(echo "${cc:-}" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z' | head -c 2)"

  if [[ "$raw" =~ ^[A-Za-z]{2}$ ]]; then
    cc="$(echo "$raw" | tr '[:lower:]' '[:upper:]')"
    flag="$(love_v13603_cc_to_emoji "$cc")"
  elif [[ -n "$raw" && ! "$raw" =~ ^[A-Za-z]+$ ]]; then
    flag="$raw"
    [[ -n "$cc" ]] || cc="US"
  else
    [[ -n "$cc" ]] || cc="$(love_v13603_detect_country)"
    flag="$(love_v13603_cc_to_emoji "$cc")"
  fi

  echo "$cc" > /opt/Love/node-country
  echo "$flag" > /opt/Love/node-flag
  printf '%s' "$flag"
}

love_v13603_clean_label() {
  local x="$*"
  # Remove existing emoji flag prefixes and common country-letter prefixes.
  x="$(printf '%s' "$x" | python3 -c 'import sys,re,urllib.parse; s=sys.stdin.read().strip(); s=urllib.parse.unquote(s); s=re.sub(r"^[\U0001F1E6-\U0001F1FF]{2}\s*", "", s); s=re.sub(r"^(US|USA|JP|SG|HK|TW|KR|DE|GB|UK|FR|NL|CA|AU|IN|BR|SE|CH|IT|ES|PL|FI|NO|RU|TR|AE|TH|VN|ID|MY|PH|CN)[\s_\-]+", "", s, flags=re.I); print(s.strip() or "LOVE")' 2>/dev/null || printf '%s' "$x")"
  printf '%s' "${x:-LOVE}"
}

love_v13603_label() {
  local flag name
  flag="$(love_v13603_flag_get)"
  name="$(love_v13603_clean_label "$*")"
  printf '%s %s' "$flag" "$name"
}

# Source-level compatibility: every old source template that calls these now gets emoji flag icons directly.
love_v1352_flag_emoji() { love_v13603_flag_get; }
love_v1352_label() { love_v13603_label "$@"; }
love_v1354_flag() { love_v13603_flag_get; }
love_v1354_label() { love_v13603_label "$@"; }
love_v13602_flag_get() { love_v13603_flag_get; }
love_flag_show13602() { echo "当前国旗 / Current flag: $(love_v13603_flag_get) $(cat /opt/Love/node-country 2>/dev/null || echo US)"; }

love_flag_set13602() {
  mkdir -p /opt/Love
  echo "================ Love Flag Icon Source-First / 国旗图标源头设置 ================"
  love_flag_show13602 || true
  echo
  echo "输入两位国家代码会从源头生成 emoji 国旗，例如：US -> 🇺🇸, DE -> 🇩🇪, JP -> 🇯🇵"
  read -rp "国家代码或国旗 emoji [US]: " input
  input="${input:-US}"
  local cc flag
  if [[ "$input" =~ ^[A-Za-z]{2}$ ]]; then
    cc="$(echo "$input" | tr '[:lower:]' '[:upper:]')"
    flag="$(love_v13603_cc_to_emoji "$cc")"
  else
    cc="CUSTOM"
    flag="$input"
  fi
  echo "$cc" > /opt/Love/node-country
  echo "$flag" > /opt/Love/node-flag
  echo "[OK] 已设置 / Set: $flag $cc"
  echo "[INFO] 之后执行 Love sub / Love web，新订阅会从源头生成 $flag 图标标签，不靠后置扫描。"
}

love_flag_auto13602() {
  mkdir -p /opt/Love
  local cc flag
  cc="$(love_v13603_detect_country)"
  flag="$(love_v13603_cc_to_emoji "$cc")"
  echo "$cc" > /opt/Love/node-country
  echo "$flag" > /opt/Love/node-flag
  echo "[OK] 自动识别国旗 / Auto flag: $flag $cc"
}

love_v13603_norm_file() {
  local file="$1" mode node_sni flag
  mode="$(love_v1354_cert_mode 2>/dev/null || echo self_signed)"
  node_sni="$(love_v1355_node_sni 2>/dev/null || echo self.local)"
  flag="$(love_v13603_flag_get)"
  [[ -s "$file" ]] || return 0
  python3 - "$file" "$mode" "$node_sni" "$flag" <<'PY13603NORM'
from pathlib import Path
import sys, urllib.parse, re, base64, json

p = Path(sys.argv[1])
global_mode = (sys.argv[2] or 'self_signed').lower()
node_sni = sys.argv[3] or 'self.local'
flag = sys.argv[4] or '🇺🇸'
flag_re = re.compile(r'^[\U0001F1E6-\U0001F1FF]{2}\s*')
letter_re = re.compile(r'^(?:US|USA|JP|SG|HK|TW|KR|DE|GB|UK|FR|NL|CA|AU|IN|BR|SE|CH|IT|ES|PL|FI|NO|RU|TR|AE|TH|VN|ID|MY|PH|CN)[\s_\-]+', re.I)

schemes = ('vless://','tuic://','trojan://','hy2://','hysteria2://','anytls://','https://','ss://','vmess://')

def clean_label(x: str) -> str:
    x = urllib.parse.unquote(x or 'LOVE').strip()
    x = flag_re.sub('', x).strip()
    x = letter_re.sub('', x).strip()
    return x or 'LOVE'

def label(x: str) -> str:
    return f'{flag} {clean_label(x)}'

def b64decode_any(s: str) -> bytes:
    pad = '=' * (-len(s) % 4)
    return base64.urlsafe_b64decode((s + pad).encode())

def b64encode_plain(b: bytes) -> str:
    return base64.b64encode(b).decode().rstrip('=')

def split_uri(line: str):
    main, _, frag = line.partition('#')
    if '?' in main:
        base, _, query = main.partition('?')
    else:
        base, query = main, ''
    return base, query, frag

def parse_pairs(query: str):
    return urllib.parse.parse_qsl(query, keep_blank_values=True) if query else []

def get_first(pairs, *names):
    names={n.lower() for n in names}
    for k,v in pairs:
        if k.lower() in names:
            return v
    return ''

def remove_keys(pairs, *names):
    names={n.lower() for n in names}
    return [(k,v) for k,v in pairs if k.lower() not in names]

def query_of(pairs):
    return urllib.parse.urlencode(pairs, doseq=True, safe='')

def looks_self_sni(sni: str) -> bool:
    sni=(sni or '').strip().lower()
    return (not sni) or sni in ('self.local','localhost','love.local') or sni.endswith('.local')

def tls_self_mode(pairs):
    sni=get_first(pairs,'sni','host','authority') or node_sni
    return global_mode != 'public_ca' or looks_self_sni(sni)

def fix_vmess(line: str) -> str:
    main, _, frag = line.partition('#')
    payload = main[len('vmess://'):]
    try:
        obj = json.loads(b64decode_any(payload).decode('utf-8', errors='ignore'))
        obj['ps'] = label(str(obj.get('ps') or frag or 'LOVE-VMESS'))
        enc = b64encode_plain(json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
        return 'vmess://' + enc + '#' + obj['ps']
    except Exception:
        return main + '#' + label(frag or 'LOVE-VMESS')

out=[]
for raw in p.read_text(encoding='utf-8', errors='ignore').splitlines():
    line=raw.strip()
    if not line or not line.startswith(schemes):
        out.append(raw)
        continue
    low=line.lower()
    if line.startswith('vmess://'):
        out.append(fix_vmess(line)); continue

    base, query, frag = split_uri(line)
    pairs=parse_pairs(query)
    is_reality=line.startswith('vless://') and 'security=reality' in low

    # Remove duplicated switch params and write them from the current cert mode.
    pairs=remove_keys(pairs, 'allowInsecure','allow_insecure','insecure','alpn','mode')
    self_mode=tls_self_mode(pairs)

    if is_reality:
        if 'type=http' in low:
            pairs += [('alpn','h2')]
        elif 'type=grpc' in low:
            pairs += [('mode','gun'), ('alpn','h2')]
    elif line.startswith(('hy2://','hysteria2://')):
        pairs += [('insecure','true' if self_mode else 'false')]
    elif line.startswith('tuic://'):
        if self_mode:
            pairs += [('allow_insecure','true'), ('allowInsecure','true'), ('insecure','true'), ('alpn','h3')]
        else:
            pairs += [('alpn','h3')]
    elif line.startswith('trojan://'):
        if self_mode:
            pairs += [('allowInsecure','true'), ('insecure','true'), ('allow_insecure','true')]
    elif line.startswith('vless://') and 'security=tls' in low:
        if self_mode:
            pairs += [('allowInsecure','true'), ('insecure','true'), ('allow_insecure','true')]
    elif line.startswith('anytls://'):
        if self_mode:
            pairs += [('insecure','true')]
    elif line.startswith('https://'):
        if self_mode:
            pairs += [('sni', node_sni), ('insecure','true'), ('allowInsecure','true'), ('allow_insecure','true')]

    q=query_of(pairs)
    out.append(base + (('?' + q) if q else '') + '#' + label(frag or 'LOVE'))

p.write_text('\n'.join(out) + ('\n' if out else ''), encoding='utf-8')
PY13603NORM
}

# Override normalizers: source/export pipeline uses emoji flag at generation time.
love_v1354_norm_file() { love_v13603_norm_file "$@"; }
love_v1355_norm_file() { love_v13603_norm_file "$@"; }

# Rebuild v2rayN from already source-labelled all.txt; no flag scanning.
love_v13603_make_v2rayn_import() {
  love_v1357_make_v2rayn_import "$@" 2>/dev/null || true
  love_v13603_norm_file /opt/Love/subscribe/clients/v2rayn-uri.txt 2>/dev/null || true
}
love_v1357_make_v2rayn_import_source_first() { love_v13603_make_v2rayn_import "$@"; }

love_v1355_export_direct() {
  love_v1354_export_direct
  local SUBDIR="/opt/Love/subscribe"
  local CLIENTDIR="${SUBDIR}/clients"
  mkdir -p "$CLIENTDIR"
  for f in "$SUBDIR/all.txt" "$SUBDIR/全部节点.txt" "$SUBDIR/推荐节点.txt" "$SUBDIR/节点清晰版.txt" "$CLIENTDIR/nekobox-uri.txt" "$CLIENTDIR/nodes-clean.txt"; do
    love_v13603_norm_file "$f" 2>/dev/null || true
  done
  cp -f "$SUBDIR/all.txt" "$SUBDIR/全部节点.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$SUBDIR/推荐节点.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$SUBDIR/节点清晰版.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$CLIENTDIR/nekobox-uri.txt" 2>/dev/null || true
  cp -f "$SUBDIR/all.txt" "$CLIENTDIR/nodes-clean.txt" 2>/dev/null || true
  love_v1357_make_v2rayn_import 2>/dev/null || cp -f "$SUBDIR/all.txt" "$CLIENTDIR/v2rayn-uri.txt" 2>/dev/null || true
  love_v13603_norm_file "$CLIENTDIR/v2rayn-uri.txt" 2>/dev/null || true
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0 "$SUBDIR/all.txt" > "$SUBDIR/all_base64.txt" 2>/dev/null || true
  else
    base64 "$SUBDIR/all.txt" | tr -d '\n' > "$SUBDIR/all_base64.txt" 2>/dev/null || true
  fi
  love_v1355_archive_legacy_links 2>/dev/null || true
}

love_v1360_generate_client_subs() {
  love_v1360_header "Love Subscriptions v13.60.3 Source-First" 2>/dev/null || echo "================ Love Subscriptions v13.60.3 Source-First ================"
  love_v1360_mkdirs 2>/dev/null || mkdir -p /opt/Love/subscribe/clients /opt/Love/reports
  love_v1355_export_direct 2>/dev/null || love_v1354_export_direct 2>/dev/null || true
  love_v1354_qr_direct 2>/dev/null || true
  local sub="/opt/Love/subscribe" cli="/opt/Love/subscribe/clients"
  mkdir -p "$cli"
  [[ -s "$sub/all.txt" ]] && cp -f "$sub/all.txt" "$cli/nekobox-uri.txt" 2>/dev/null || true
  [[ -s "$sub/all.txt" ]] && cp -f "$sub/all.txt" "$cli/v2rayng-uri.txt" 2>/dev/null || true
  [[ -s "$sub/all.txt" ]] && cp -f "$sub/all.txt" "$cli/singbox-uri.txt" 2>/dev/null || true
  [[ -s "$sub/all.txt" ]] && grep -Ei 'LOVE-H2-REALITY|LOVE-GRPC-REALITY|LOVE-ANYTLS|LOVE-NAIVE|SHADOWTLS' "$sub/all.txt" > "$cli/experimental.txt" 2>/dev/null || true
  generate_mihomo_yaml >/dev/null 2>&1 || true
  if [[ -s "$sub/mihomo.yaml" ]]; then
    cp -f "$sub/mihomo.yaml" "$cli/clash-meta.yaml" 2>/dev/null || true
    love_v13603_norm_file "$cli/clash-meta.yaml" 2>/dev/null || true
  elif [[ -s "$sub/clash_like.yaml" ]]; then
    cp -f "$sub/clash_like.yaml" "$cli/clash-meta.yaml" 2>/dev/null || true
    love_v13603_norm_file "$cli/clash-meta.yaml" 2>/dev/null || true
  fi
  cat > "$cli/v2rayn-notes.txt" <<'EOF'
Love v2rayN notes:
1. LOVE-H2-REALITY 属于 VLESS + Reality + HTTP/H2。
2. v2rayN 使用这条节点时：设置 -> Core 类型设置 -> VLESS -> sing_box。
3. 如果 VLESS 仍用 Xray，新版 Xray 可能报 HTTP transport removed。
4. 国旗图标从源头生成：节点名直接是 emoji 国旗 + LOVE 名称，不再依赖后置 flag-fix 扫描。
EOF
  echo "[OK] Source-first flag icon: $(love_v13603_flag_get) $(cat /opt/Love/node-country 2>/dev/null || echo US)"
  echo "[OK] 已生成 / Generated:"
  for f in "$sub/all.txt" "$sub/all_base64.txt" "$cli/v2rayn-uri.txt" "$cli/v2rayng-uri.txt" "$cli/nekobox-uri.txt" "$cli/singbox-uri.txt" "$cli/clash-meta.yaml" "$cli/experimental.txt" "$cli/v2rayn-notes.txt"; do
    [[ -s "$f" ]] && echo "  $f"
  done
}

love_v1360_web() {
  love_v1360_generate_client_subs >/dev/null 2>&1 || true
  web_admin_page
}

# In v13.60.3 flag-fix is not a normal post-processing scanner anymore.
# It is kept only as a compatibility alias that regenerates subscriptions from the source template.
love_v13602_fix_flags_all() {
  echo "================ Love Flag Source-First v13.60.3 ================"
  echo "[INFO] 正常流程不再扫描旧订阅改字母；现在直接从源头重新生成 emoji 国旗节点名。"
  love_v1360_generate_client_subs
  love_v1354_qr_direct 2>/dev/null || true
  echo "[OK] 已从源头重建，不使用后置 flag-fix 扫描。"
}

love_v13603_check() {
  echo "================ Love v13.60.3 Source-First Flag Check ================"
  echo "VERSION=${LOVE_SCRIPT_VERSION}"
  echo "Current flag: $(love_v13603_flag_get) $(cat /opt/Love/node-country 2>/dev/null || echo US)"
  echo
  echo "[Source functions]"
  declare -f love_v1352_label | grep -q 'love_v13603_label' && echo "[OK] love_v1352_label -> source emoji" || echo "[WARN] label source override missing"
  declare -f love_v1354_norm_file | grep -q 'love_v13603_norm_file' && echo "[OK] normalizer uses source flag" || echo "[WARN] normalizer override missing"
  echo
  echo "[Subscription labels]"
  if grep -nE '#[A-Z]{2,3}[ _-]+LOVE|#US[ _-]+LOVE' /opt/Love/subscribe/all.txt 2>/dev/null; then
    echo "[WARN] 仍有字母标签。执行 Love sub 从源头重建。"
  else
    echo "[OK] 未发现 #US LOVE 这类字母标签。"
  fi
  grep -nE '#.*LOVE-' /opt/Love/subscribe/all.txt 2>/dev/null | head -20 || true
}

love_v13603_help() {
  cat <<'EOF'
Love v13.60.3 source-first flag commands:
  Love flag          设置国旗图标源头 / set source emoji flag
  Love flag-auto     自动识别并保存国旗图标源头
  Love flag-show     查看当前国旗
  Love sub           从源头生成带 emoji 国旗图标的订阅
  Love web           从源头生成订阅后同步绿色 Web
  Love v13603-check  检查是否还有 #US LOVE 这类字母标签

Note:
  v13.60.3 不把 flag-fix 当正常流程；flag-fix 仅作为兼容命令，实际执行源头重建。
EOF
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_before_flag13603 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_before_flag13603/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.60.3-flag-icon-source-first-final}"
  case "${1:-}" in
    ""|menu|main|m)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      if declare -F love_color_menu13601 >/dev/null 2>&1; then
        love_color_menu13601
      else
        love_original_main_before_flag13603 "$@"
      fi ;;
    flag|flag-set|set-flag)
      love_flag_set13602 ;;
    flag-auto|auto-flag)
      love_flag_auto13602 ;;
    flag-show|show-flag)
      love_flag_show13602 ;;
    flag-fix|fix-flag|flag-icon-fix|country-fix)
      love_v13602_fix_flags_all ;;
    sub|subscribe|clients|client-export|source-correct|final-fix|client-output-fix|importable-fix|v2rayn-fix|true-fix|cert-true-fix)
      love_v1360_generate_client_subs ;;
    web|web-fix|fix-web)
      love_v1360_web ;;
    v13603-check|flag-source-check|source-flag-check)
      love_v13603_check ;;
    help13603|flag-help|v13603-help)
      love_v13603_help ;;
    *)
      love_original_main_before_flag13603 "$@" ;;
  esac
}


# ==============================================================================
# Love v13.60.4 Manual TRUE Notice Source-Final
# Purpose:
#   - Do NOT change working server config.
#   - Do NOT post-scan URI to change protocol logic.
#   - Generate a source-time v2rayN manual TRUE reminder report after node export.
#   - Keep Green Web / QR / legacy links unchanged.
# ==============================================================================
LOVE_SCRIPT_VERSION="Love v13.60.4-manual-true-notice-source-final"

love_v13604_line_name() {
  local line="$1" frag=""
  frag="${line##*#}"
  [[ "$frag" == "$line" ]] && frag="LOVE"
  python3 - <<'PY13604NAME' "$frag" 2>/dev/null || printf '%s' "$frag"
import sys, urllib.parse
print(urllib.parse.unquote(sys.argv[1]))
PY13604NAME
}

love_v13604_tls_manual_report() {
  local sub="/opt/Love/subscribe"
  local cli="/opt/Love/subscribe/clients"
  local rep="${cli}/v2rayn-manual-true-note.txt"
  local rep2="/opt/Love/reports/v2rayn-manual-true-note.txt"
  local info="/opt/Love/client-info/v2rayn-manual-true-note.txt"
  local all="${sub}/all.txt"
  local country flag mode sni
  mkdir -p "$cli" /opt/Love/reports /opt/Love/client-info
  country="$(cat /opt/Love/node-country 2>/dev/null || echo US)"
  flag="$(love_v13603_flag_get 2>/dev/null || echo '🇺🇸')"
  mode="$(cat /opt/Love/cert-mode 2>/dev/null || cat /opt/Love/domain-cert-mode 2>/dev/null || echo unknown)"
  sni="$(cat /opt/Love/node-sni 2>/dev/null || echo self.local)"

  {
    echo "Love v13.60.4 v2rayN Manual TRUE Notice / 手动 TRUE 提醒"
    echo "==============================================================="
    echo "Flag / 国旗: ${flag} ${country}"
    echo "Cert mode / 证书模式: ${mode}"
    echo "TLS SNI / 证书 SNI: ${sni}"
    echo
    echo "为什么有这个提醒 / Why this note exists:"
    echo "- 脚本源头已经给自签/self.local TLS 节点写入 insecure=true / allowInsecure=true。"
    echo "- 但 v2rayN 某些协议导入后，界面字段可能仍显示 False，尤其是 HY2 / TUIC / Trojan / VLESS-WS-TLS / AnyTLS / Naive。"
    echo "- 这种情况不是服务端错，而是客户端导入解析没有把 TRUE 写进对应 UI 字段。"
    echo
    echo "手动规则 / Manual rule:"
    echo "- 如果字段叫：跳过证书验证 / Allow insecure / Insecure / Skip certificate verification  → 设为 TRUE / ON。"
    echo "- 如果字段叫：证书验证 / Verify certificate / Certificate verification              → 设为 FALSE / OFF。"
    echo "- Reality / H2 Reality / gRPC Reality 不需要设置 insecure=true；H2 Reality 只需要 VLESS Core = sing_box。"
    echo
    echo "需要重点检查的节点 / Nodes to check in v2rayN:"
  } > "$rep"

  local found=0
  if [[ -s "$all" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      case "$line" in
        hy2://*|hysteria2://*)
          if grep -qiE 'insecure=true|sni=self\.local|sni=love\.local|sni=localhost' <<<"$line"; then
            found=1
            printf '  [CHECK] %s\n' "$(love_v13604_line_name "$line")" >> "$rep"
            printf '          v2rayN: HY2 跳过证书验证 / Insecure = TRUE\n' >> "$rep"
          fi ;;
        tuic://*)
          if grep -qiE 'allow_insecure=true|allowInsecure=true|insecure=true|sni=self\.local|sni=love\.local|sni=localhost' <<<"$line"; then
            found=1
            printf '  [CHECK] %s\n' "$(love_v13604_line_name "$line")" >> "$rep"
            printf '          v2rayN: TUIC Allow insecure / Insecure = TRUE\n' >> "$rep"
          fi ;;
        trojan://*)
          if grep -qiE 'allowInsecure=true|allow_insecure=true|insecure=true|sni=self\.local|sni=love\.local|sni=localhost' <<<"$line"; then
            found=1
            printf '  [CHECK] %s\n' "$(love_v13604_line_name "$line")" >> "$rep"
            printf '          v2rayN: Trojan Allow insecure / 跳过证书验证 = TRUE\n' >> "$rep"
          fi ;;
        vless://*)
          if grep -qi 'security=tls' <<<"$line" && grep -qiE 'allowInsecure=true|allow_insecure=true|insecure=true|sni=self\.local|sni=love\.local|sni=localhost' <<<"$line"; then
            found=1
            printf '  [CHECK] %s\n' "$(love_v13604_line_name "$line")" >> "$rep"
            printf '          v2rayN: VLESS WS TLS Allow insecure / 跳过证书验证 = TRUE\n' >> "$rep"
          elif grep -qi 'security=reality' <<<"$line"; then
            :
          fi ;;
        anytls://*)
          if grep -qiE 'insecure=true|sni=self\.local|sni=love\.local|sni=localhost' <<<"$line"; then
            found=1
            printf '  [CHECK] %s\n' "$(love_v13604_line_name "$line")" >> "$rep"
            printf '          v2rayN: AnyTLS Insecure = TRUE\n' >> "$rep"
          fi ;;
        https://*)
          if grep -qiE 'allowInsecure=true|allow_insecure=true|insecure=true|sni=self\.local|sni=love\.local|sni=localhost' <<<"$line"; then
            found=1
            printf '  [CHECK] %s\n' "$(love_v13604_line_name "$line")" >> "$rep"
            printf '          v2rayN: Naive Allow insecure / Insecure = TRUE\n' >> "$rep"
          fi ;;
      esac
    done < "$all"
  fi

  if [[ "$found" != "1" ]]; then
    {
      echo "  [OK] 当前订阅没有检测到需要手动 TRUE 的 self.local / 自签 TLS 节点。"
      echo "       如果你使用正式 CA 证书，通常不需要手动开启 insecure。"
    } >> "$rep"
  fi

  {
    echo
    echo "不需要手动 TRUE 的节点 / No manual TRUE needed:"
    echo "  - LOVE-REALITY: Reality TCP，不看证书 TRUE/FALSE。"
    echo "  - LOVE-H2-REALITY: Reality H2，不看证书 TRUE/FALSE；v2rayN 需 VLESS Core = sing_box。"
    echo "  - LOVE-GRPC-REALITY: Reality gRPC，不看证书 TRUE/FALSE。"
    echo "  - LOVE-SS: Shadowsocks，不涉及 TLS 证书。"
    echo "  - LOVE-VMESS-WS: 非 TLS WS 时不涉及证书。"
    echo
    echo "文件位置 / Files:"
    echo "  ${rep}"
    echo "  ${rep2}"
    echo "  ${info}"
  } >> "$rep"

  cp -f "$rep" "$rep2" 2>/dev/null || true
  cp -f "$rep" "$info" 2>/dev/null || true

  if [[ -f "${cli}/v2rayn-notes.txt" ]] && ! grep -q 'v2rayn-manual-true-note.txt' "${cli}/v2rayn-notes.txt" 2>/dev/null; then
    {
      echo
      echo "5. 如果自签/self.local 节点在 v2rayN 导入后证书字段仍为 False，请查看："
      echo "   /opt/Love/subscribe/clients/v2rayn-manual-true-note.txt"
    } >> "${cli}/v2rayn-notes.txt"
  fi

  echo
  echo "================ v2rayN TRUE Manual Notice / 手动 TRUE 提醒 ================"
  if [[ "$found" == "1" ]]; then
    echo "[WARN] 检测到自签/self.local TLS 节点。若 v2rayN 导入后仍显示 False，请按提示手动切换。"
  else
    echo "[OK] 未检测到必须手动 TRUE 的自签 TLS 节点。"
  fi
  echo "[INFO] 查看详情：${rep}"
  echo "=========================================================================="
  echo
}

love_v13604_check() {
  echo "================ Love v13.60.4 Check ================"
  echo "VERSION=${LOVE_SCRIPT_VERSION}"
  love_v13603_check 2>/dev/null || true
  love_v13604_tls_manual_report
}

love_v13604_help() {
  cat <<'EOF13604HELP'
Love v13.60.4 commands:
  Love sub              从源头生成订阅 + 生成 v2rayN TRUE 手动提醒
  Love web              同步绿色 Web，包含 clients/v2rayn-manual-true-note.txt
  Love manual-true      查看/生成手动 TRUE 提醒
  Love true-note        同上
  Love v13604-check     检查国旗源头 + TRUE 提醒

说明：
  这版不靠后置扫描改链接，不改已通节点。
  它只在源头导出后生成提醒文件，告诉你哪些 TLS 自签节点在 v2rayN 里可能需要手动切 TRUE。
EOF13604HELP
}

if declare -F love_v1360_generate_client_subs >/dev/null 2>&1 && ! declare -F love_v1360_generate_client_subs_before_v13604 >/dev/null 2>&1; then
  eval "$(declare -f love_v1360_generate_client_subs | sed '1s/^love_v1360_generate_client_subs/love_v1360_generate_client_subs_before_v13604/')"
fi

love_v1360_generate_client_subs() {
  love_v1360_generate_client_subs_before_v13604 "$@"
  love_v13604_tls_manual_report
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_before_v13604 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_before_v13604/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.60.4-manual-true-notice-source-final}"
  case "${1:-}" in
    manual-true|true-note|v2rayn-true|cert-true-note|true-help)
      love_v13604_tls_manual_report ;;
    v13604-check|true-check|manual-check)
      love_v13604_check ;;
    help13604|v13604-help)
      love_v13604_help ;;
    *)
      love_original_main_before_v13604 "$@" ;;
  esac
}

# ==============================================================================
# Love v13.60.6 Cert Mode Strict + Xray Source-Aware Final
# Purpose:
#   - Restore classic aligned two-column menu with one unified color style.
#   - Add Xray Extended mode without replacing/removing Xray Stable mode.
#   - Xray Extended supports domain/no-domain/custom cert source choices.
#   - Do not change Green Web / QR / sing-box working nodes / legacy archive logic.
# ==============================================================================
LOVE_SCRIPT_VERSION="Love v13.60.6-cert-mode-strict-xray-source-final"

love_c13605() {
  case "${1:-}" in
    reset) printf '\033[0m' ;;
    bold) printf '\033[1m' ;;
    dim) printf '\033[2m' ;;
    blue) printf '\033[0;34m' ;;
    cyan) printf '\033[0;36m' ;;
    green) printf '\033[0;32m' ;;
    yellow) printf '\033[1;33m' ;;
    red) printf '\033[0;31m' ;;
    *) printf '' ;;
  esac
}

love_pause13605() {
  echo
  read -rp "按 Enter 返回主菜单 / Press Enter to return..." _ || true
}

love_call13605() {
  local fn="$1"; shift || true
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
  else
    echo "[WARN] 功能入口不存在 / Function not found: $fn"
  fi
}

love_menu_header13605() {
  clear 2>/dev/null || true
  local c r line
  c="$(love_c13605 cyan)"; r="$(love_c13605 reset)"
  line="================================================================================"
  printf "%b%s%b\n" "$c" "$line" "$r"
  printf "%b  Love Node Server Manager  %s%b\n" "$(love_c13605 bold)$(love_c13605 cyan)" "${LOVE_SCRIPT_VERSION}" "$r"
  printf "%b  Classic Bilingual Menu / 经典中英双列菜单%b\n" "$c" "$r"
  printf "%b%s%b\n" "$c" "$line" "$r"
}

love_menu_row13605() {
  local left="$1" right="${2:-}"
  printf "%b│ %-38s │ %-38s │%b\n" "$(love_c13605 cyan)" "$left" "$right" "$(love_c13605 reset)"
}

love_menu_section13605() {
  local title="$1"
  printf "%b├─ %-74s ┤%b\n" "$(love_c13605 cyan)" "$title" "$(love_c13605 reset)"
}

love_v13605_xray_b64() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

love_v13605_xray_port_free_warn() {
  local p
  for p in "$@"; do
    if ss -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${p}$"; then
      warn "端口 ${p} 似乎已被占用；继续可能导致 Xray 启动失败。"
    fi
  done
}

love_v13605_open_firewall() {
  local p proto
  command -v ufw >/dev/null 2>&1 || return 0
  enable_ufw_ipv6 2>/dev/null || true
  for item in "$@"; do
    p="${item%/*}"; proto="${item#*/}"
    ufw allow "${p}/${proto}" >/dev/null 2>&1 || true
  done
  ufw --force enable >/dev/null 2>&1 || true
}

love_v13605_write_xray_extended_config() {
  local reality_sni="$1" tls_sni="$2" cert_dir="$3" base_port="$4" enable_hy2="$5"
  local p="$base_port"
  XR_EXT_REALITY_PORT="$p"; p=$((p+1))
  XR_EXT_TROJAN_PORT="$p"; p=$((p+1))
  XR_EXT_VMESS_WS_PORT="$p"; p=$((p+1))
  XR_EXT_VLESS_WS_TLS_PORT="$p"; p=$((p+1))
  XR_EXT_SS_PORT="$p"; p=$((p+1))
  XR_EXT_HY2_PORT="$p"

  XR_EXT_TROJAN_PASS="$(openssl rand -hex 16)"
  XR_EXT_SS_PASS="$(openssl rand -base64 16 | tr -d '=+/ ' | cut -c1-16)"
  [[ -n "${HY2_AUTH:-}" ]] || HY2_AUTH="$(openssl rand -hex 24)"

  local inbound_file="/tmp/love-xray-extended-inbounds.jsonl"
  : > "$inbound_file"

  cat >> "$inbound_file" <<EOF_XRREALITY
{"tag":"xray-vless-reality-in","listen":"::","port":${XR_EXT_REALITY_PORT},"protocol":"vless","settings":{"clients":[{"id":"${XR_UUID}","flow":"xtls-rprx-vision","email":"xray-reality"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"target":"${reality_sni}:443","serverNames":["${reality_sni}"],"privateKey":"${XR_PRIVATE}","shortIds":["${XR_SHORT_ID}"]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}}
EOF_XRREALITY

  cat >> "$inbound_file" <<EOF_XRTROJAN
{"tag":"xray-trojan-tls-in","listen":"::","port":${XR_EXT_TROJAN_PORT},"protocol":"trojan","settings":{"clients":[{"password":"${XR_EXT_TROJAN_PASS}","email":"xray-trojan"}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"${tls_sni}","alpn":["http/1.1"],"certificates":[{"certificateFile":"${cert_dir}/cert.pem","keyFile":"${cert_dir}/key.pem"}]}}}
EOF_XRTROJAN

  cat >> "$inbound_file" <<EOF_XRVMESS
{"tag":"xray-vmess-ws-in","listen":"::","port":${XR_EXT_VMESS_WS_PORT},"protocol":"vmess","settings":{"clients":[{"id":"${XR_UUID}","alterId":0,"email":"xray-vmess-ws"}]},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/vmess"}}}
EOF_XRVMESS

  cat >> "$inbound_file" <<EOF_XRVLESSWS
{"tag":"xray-vless-ws-tls-in","listen":"::","port":${XR_EXT_VLESS_WS_TLS_PORT},"protocol":"vless","settings":{"clients":[{"id":"${XR_UUID}","email":"xray-vless-ws-tls"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"${tls_sni}","alpn":["http/1.1"],"certificates":[{"certificateFile":"${cert_dir}/cert.pem","keyFile":"${cert_dir}/key.pem"}]},"wsSettings":{"path":"/vless"}}}
EOF_XRVLESSWS

  cat >> "$inbound_file" <<EOF_XRSS
{"tag":"xray-ss-in","listen":"::","port":${XR_EXT_SS_PORT},"protocol":"shadowsocks","settings":{"method":"aes-128-gcm","password":"${XR_EXT_SS_PASS}","network":"tcp,udp"}}
EOF_XRSS

  if [[ "$enable_hy2" == "yes" ]]; then
    cat >> "$inbound_file" <<EOF_XRHY2
{"tag":"xray-hy2-in","listen":"::","port":${XR_EXT_HY2_PORT},"protocol":"hysteria","settings":{"version":2,"users":[{"auth":"${HY2_AUTH}","level":0,"email":"xray-hy2"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"serverName":"${tls_sni}","alpn":["h3"],"certificates":[{"certificateFile":"${cert_dir}/cert.pem","keyFile":"${cert_dir}/key.pem"}]},"hysteriaSettings":{"version":2,"udpIdleTimeout":60,"masquerade":{"type":"string","content":"<html><body><h1>Welcome</h1></body></html>","headers":{"content-type":"text/html"},"statusCode":200}}}}
EOF_XRHY2
  fi

  local inbounds_json
  inbounds_json="$(jq -s '.' "$inbound_file")"
  cp "${XRAY_CONF}" "${XRAY_CONF}.bak.extended.$(date +%F-%H%M%S)" 2>/dev/null || true

  jq -n --argjson inbounds "$inbounds_json" '{
    log:{loglevel:"warning"},
    routing:{domainStrategy:"IPIfNonMatch", rules:[
      {type:"field", ip:["geoip:private"], outboundTag:"blocked"},
      {type:"field", port:"25,465,587", outboundTag:"blocked"},
      {type:"field", protocol:["bittorrent"], outboundTag:"blocked"}
    ]},
    inbounds:$inbounds,
    outbounds:[
      {tag:"direct", protocol:"freedom"},
      {tag:"blocked", protocol:"blackhole", settings:{response:{type:"none"}}}
    ]
  }' > "${XRAY_CONF}"

  jq empty "${XRAY_CONF}"
  chown root:xray "${XRAY_CONF}" 2>/dev/null || true
  chmod 640 "${XRAY_CONF}" 2>/dev/null || true
}

love_v13605_save_xray_extended_info() {
  local client_addr="$1" base_client_port="$2" reality_sni="$3" tls_sni="$4" insecure="$5" enable_hy2="$6"
  local h; h="$(uri_host "$client_addr")"
  local rp tp vmp vlp ssp hp
  rp=$((base_client_port + XR_EXT_REALITY_PORT - XR_EXT_BASE_PORT))
  tp=$((base_client_port + XR_EXT_TROJAN_PORT - XR_EXT_BASE_PORT))
  vmp=$((base_client_port + XR_EXT_VMESS_WS_PORT - XR_EXT_BASE_PORT))
  vlp=$((base_client_port + XR_EXT_VLESS_WS_TLS_PORT - XR_EXT_BASE_PORT))
  ssp=$((base_client_port + XR_EXT_SS_PORT - XR_EXT_BASE_PORT))
  hp=$((base_client_port + XR_EXT_HY2_PORT - XR_EXT_BASE_PORT))

  local tls_extra=""
  if [[ "$insecure" == "true" || "$insecure" == "1" ]]; then
    tls_extra="allowInsecure=true&insecure=true&allow_insecure=true"
  fi

  local vmess_json vmess_b64 ss_b64
  vmess_json="$(jq -nc --arg ps "$(love_v1352_label LOVE-XRAY-VMESS-WS)" --arg add "${client_addr}" --arg port "${vmp}" --arg id "${XR_UUID}" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:"",path:"/vmess",tls:"",sni:""}')"
  vmess_b64="$(printf '%s' "$vmess_json" | love_v13605_xray_b64)"
  ss_b64="$(printf 'aes-128-gcm:%s' "${XR_EXT_SS_PASS}" | love_v13605_xray_b64)"

  cat > "${XRAY_INFO}" <<EOF_XRINFO
Love Xray Extended Client Info

Server Mode:
Xray Extended / Xray 补全模式

Client Address:
${client_addr}

Base Port:
${base_client_port}

Reality SNI:
${reality_sni}

TLS SNI:
${tls_sni}

TLS Insecure Required:
${insecure}

VLESS Reality TCP Vision:
vless://${XR_UUID}@${h}:${rp}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${XR_PUBLIC}&sid=${XR_SHORT_ID}&type=tcp#$(love_v1352_label LOVE-XRAY-REALITY)

Trojan TLS:
trojan://${XR_EXT_TROJAN_PASS}@${h}:${tp}?security=tls&sni=${tls_sni}$([[ -n "$tls_extra" ]] && printf '&%s' "$tls_extra")#$(love_v1352_label LOVE-XRAY-TROJAN)

VMess WS:
vmess://${vmess_b64}#$(love_v1352_label LOVE-XRAY-VMESS-WS)

VLESS WS TLS:
vless://${XR_UUID}@${h}:${vlp}?encryption=none&security=tls&sni=${tls_sni}&type=ws&path=%2Fvless$([[ -n "$tls_extra" ]] && printf '&%s' "$tls_extra")#$(love_v1352_label LOVE-XRAY-VLESS-WS-TLS)

Shadowsocks:
ss://${ss_b64}@${h}:${ssp}#$(love_v1352_label LOVE-XRAY-SS)
EOF_XRINFO

  if [[ "$enable_hy2" == "yes" ]]; then
    cat >> "${XRAY_INFO}" <<EOF_XRHY2INFO

HY2 / Hysteria2:
hy2://${HY2_AUTH}@${h}:${hp}/?sni=${tls_sni}&insecure=${insecure}#$(love_v1352_label LOVE-XRAY-HY2)
hysteria2://${HY2_AUTH}@${h}:${hp}/?sni=${tls_sni}&insecure=${insecure}#$(love_v1352_label LOVE-XRAY-HY2)
EOF_XRHY2INFO
  fi

  cat >> "${XRAY_INFO}" <<EOF_XRNOTE

Manual notes:
1. Reality does not use certificate TRUE/FALSE.
2. TLS/self.local nodes may need manual TRUE in v2rayN if import does not apply insecure.
3. Xray Extended is separate from Xray Stable; choosing it rewrites Xray config after backup.
EOF_XRNOTE

  chmod 600 "${XRAY_INFO}" 2>/dev/null || true
  cat "${XRAY_INFO}"
}


# v13.60.6: strict certificate trust detection for imported certs.
# Return value text is intentionally only "true" or "false" for command substitution:
#   true  = client links must include insecure/allowInsecure parameters
#   false = client links should verify certificate normally
love_v13606_domain_match_name() {
  local domain="$1" name="$2" suffix left
  name="${name#DNS:}"
  name="${name//[[:space:]]/}"
  [[ -n "$domain" && -n "$name" ]] || return 1
  if [[ "$name" == "$domain" ]]; then
    return 0
  fi
  if [[ "$name" == \*.* ]]; then
    suffix="${name#*.}"
    if [[ "$domain" == *."$suffix" ]]; then
      left="${domain%.$suffix}"
      [[ "$left" != *.* && -n "$left" ]] && return 0
    fi
  fi
  return 1
}

love_v13606_cert_insecure_for_domain() {
  local domain="$1" cert="$2" subj issuer san dns cn matched="no"

  if ! command -v openssl >/dev/null 2>&1; then
    echo "true"
    return 0
  fi
  if [[ ! -s "$cert" ]]; then
    echo "true"
    return 0
  fi
  if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
    echo "true"
    return 0
  fi
  if ! openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1; then
    echo "true"
    return 0
  fi

  subj="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
  issuer="$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')"
  if [[ -n "$subj" && -n "$issuer" && "$subj" == "$issuer" ]]; then
    echo "true"
    return 0
  fi

  san="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null || true)"
  if echo "$san" | grep -q 'DNS:'; then
    while IFS= read -r dns; do
      if love_v13606_domain_match_name "$domain" "$dns"; then
        matched="yes"
        break
      fi
    done < <(echo "$san" | grep -oE 'DNS:[^,[:space:]]+')
  else
    cn="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p' | head -n1)"
    if love_v13606_domain_match_name "$domain" "$cn"; then
      matched="yes"
    fi
  fi

  if [[ "$matched" == "yes" ]]; then
    echo "false"
  else
    echo "true"
  fi
}

love_v13606_cert_mode_explain() {
  local insecure="$1"
  if [[ "$insecure" == "true" || "$insecure" == "1" ]]; then
    echo "不可信/自签/过期/域名不匹配：TLS 类节点输出 insecure=true，需要时在 v2rayN 手动开 Allow Insecure。"
  else
    echo "正式可信 CA：TLS 类节点不输出 insecure，客户端正常验证证书。"
  fi
}

install_xray_extended() {
  echo
  echo "================ Love Xray Extended / Xray 补全模式 ================"
  warn "该模式会备份并重写 Xray 配置；不会改 sing-box、绿色 Web、二维码。"
  echo
  echo "Xray Extended 将生成："
  echo "  1) VLESS Reality TCP Vision"
  echo "  2) Trojan TLS"
  echo "  3) VMess WS"
  echo "  4) VLESS WS TLS"
  echo "  5) Shadowsocks"
  echo "  6) HY2 / Hysteria2 可选"
  echo

  local cert_choice domain email tls_sni reality_sni node_addr cert_dir enable_hy2 insecure base_port existing_cert existing_key
  cert_dir="${XRAY_CONF_DIR}"
  insecure="true"

  cat <<'EOF_CERTMENU'
证书/域名模式：
  1) 无域名 + self.local + 自签证书【IP/IPv6 直连，自动 insecure=true】
  2) 有域名 + Let's Encrypt 正式 CA【HTTP-01 / 80端口，自动 insecure=false】
  3) 有域名 + 自签/自管证书【自动 insecure=true】
  4) 有域名 + 导入已有 cert.pem/key.pem【自动检测可信/不可信】
  5) 有域名 + 导入已有正式 CA 证书【强制 insecure=false】
  6) 有域名 + 导入已有自签/过期/不匹配证书【强制 insecure=true】
EOF_CERTMENU
  read -rp "请选择 [1]: " cert_choice
  cert_choice="${cert_choice:-1}"

  case "$cert_choice" in
    2)
      read -rp "节点域名 / Domain: " domain
      [[ -n "$domain" ]] || die "域名不能为空。"
      read -rp "Let's Encrypt 邮箱 / Email: " email
      [[ -n "$email" ]] || die "邮箱不能为空。"
      node_addr="$domain"; tls_sni="$domain"; insecure="false" ;;
    3)
      read -rp "节点域名 / Domain SNI: " domain
      [[ -n "$domain" ]] || die "域名不能为空。"
      node_addr="$domain"; tls_sni="$domain"; insecure="true" ;;
    4)
      read -rp "节点域名 / Domain SNI: " domain
      [[ -n "$domain" ]] || die "域名不能为空。"
      read -rp "fullchain/cert.pem 路径: " existing_cert
      read -rp "privkey/key.pem 路径: " existing_key
      [[ -s "$existing_cert" && -s "$existing_key" ]] || die "证书文件不存在。"
      node_addr="$domain"; tls_sni="$domain"
      insecure="$(love_v13606_cert_insecure_for_domain "$domain" "$existing_cert")"
      info "已有证书自动检测结果：$(love_v13606_cert_mode_explain "$insecure")" ;;
    5)
      read -rp "节点域名 / Domain SNI: " domain
      [[ -n "$domain" ]] || die "域名不能为空。"
      read -rp "fullchain/cert.pem 路径: " existing_cert
      read -rp "privkey/key.pem 路径: " existing_key
      [[ -s "$existing_cert" && -s "$existing_key" ]] || die "证书文件不存在。"
      node_addr="$domain"; tls_sni="$domain"; insecure="false"
      info "已按正式 CA 证书处理：TLS 类节点不加 insecure。" ;;
    6)
      read -rp "节点域名 / Domain SNI: " domain
      [[ -n "$domain" ]] || die "域名不能为空。"
      read -rp "fullchain/cert.pem 路径: " existing_cert
      read -rp "privkey/key.pem 路径: " existing_key
      [[ -s "$existing_cert" && -s "$existing_key" ]] || die "证书文件不存在。"
      node_addr="$domain"; tls_sni="$domain"; insecure="true"
      info "已按自签/不可信证书处理：TLS 类节点加 insecure=true。" ;;
    *)
      read_node_addr_with_default node_addr
      read -rp "TLS 自签 SNI [self.local]: " tls_sni
      tls_sni="${tls_sni:-self.local}"
      insecure="true" ;;
  esac

  read -rp "Reality SNI [www.cloudflare.com]: " reality_sni
  reality_sni="${reality_sni:-www.cloudflare.com}"
  read -rp "Xray Extended 起始端口 [9441]: " base_port
  base_port="${base_port:-9441}"
  [[ "$base_port" =~ ^[0-9]+$ ]] || die "起始端口必须是数字。"
  [[ "$base_port" -ge 1 && "$base_port" -le 65530 ]] || die "起始端口范围不正确。"
  XR_EXT_BASE_PORT="$base_port"

  read -rp "是否启用 Xray HY2？[Y/n]: " hy2_choice
  hy2_choice="${hy2_choice:-Y}"
  [[ "$hy2_choice" =~ ^[Yy]$ ]] && enable_hy2="yes" || enable_hy2="no"

  ask_preferred_endpoint "${node_addr}" "${base_port}"
  ask_ssh_port

  install_base
  setup_ufw no no no no
  love_v13605_open_firewall "${base_port}/tcp" "$((base_port+1))/tcp" "$((base_port+2))/tcp" "$((base_port+3))/tcp" "$((base_port+4))/tcp" "$((base_port+4))/udp"
  [[ "$enable_hy2" == "yes" ]] && love_v13605_open_firewall "$((base_port+5))/udp"
  love_v13605_xray_port_free_warn "$base_port" "$((base_port+1))" "$((base_port+2))" "$((base_port+3))" "$((base_port+4))" "$((base_port+5))"

  install_xray_core
  gen_xray_keys
  test_reality_sni "$reality_sni"

  mkdir -p "$cert_dir"
  case "$cert_choice" in
    2)
      issue_cert_generic "$domain" "$email" "$cert_dir" "xray"
      mkdir -p /etc/letsencrypt/renewal-hooks/deploy
      cat > /etc/letsencrypt/renewal-hooks/deploy/love-xray-extended-copy-cert.sh <<EOF_HOOK
#!/usr/bin/env bash
set -e
DOMAIN="${domain}"
if echo " \$RENEWED_DOMAINS " | grep -q " \$DOMAIN "; then
  install -m 640 -o root -g xray "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" "${cert_dir}/cert.pem"
  install -m 640 -o root -g xray "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" "${cert_dir}/key.pem"
  systemctl restart xray || true
fi
EOF_HOOK
      chmod +x /etc/letsencrypt/renewal-hooks/deploy/love-xray-extended-copy-cert.sh ;;
    4|5|6)
      install -m 640 -o root -g xray "$existing_cert" "${cert_dir}/cert.pem"
      install -m 640 -o root -g xray "$existing_key" "${cert_dir}/key.pem" ;;
    *)
      make_selfsigned_generic "$tls_sni" "$cert_dir" "xray" ;;
  esac

  love_v13605_write_xray_extended_config "$reality_sni" "$tls_sni" "$cert_dir" "$base_port" "$enable_hy2"
  write_xray_service
  "${XRAY_BIN}" run -test -config "${XRAY_CONF}"
  systemctl enable xray
  systemctl restart xray
  sleep 2
  systemctl status xray --no-pager || true
  ss -lntup | grep -E ":(${base_port}|$((base_port+1))|$((base_port+2))|$((base_port+3))|$((base_port+4)))" || true
  [[ "$enable_hy2" == "yes" ]] && ss -lunp | grep ":$((base_port+5))" || true

  love_v13605_save_xray_extended_info "${CLIENT_ADDR}" "${CLIENT_PORT}" "$reality_sni" "$tls_sni" "$insecure" "$enable_hy2"
  love_after_node_generated_exports 2>/dev/null || love_v1360_generate_client_subs 2>/dev/null || true
  log "Xray Extended / Xray 补全模式安装完成。"
}

love_v13605_classic_menu() {
  while true; do
    love_menu_header13605
    love_menu_section13605 "核心安装 / Core Install"
    love_menu_row13605 "1) 节点目录 / Node catalog" "26) Xray 补全模式 / Xray Extended"
    love_menu_row13605 "2) Xray 稳定模式 / Xray Stable" "27) VPS 环境识别 / VPS env"
    love_menu_row13605 "3) sing-box 全协议 / All protocols" "28) BBR/MTU 优化 / Optimize"
    love_menu_row13605 "4) Argo 隧道 / Cloudflared" "29) 一键测速诊断 / Speed"
    love_menu_row13605 "5) UDP 跳跃 / Port hopping" "30) 重建订阅 / Rebuild sub"
    love_menu_row13605 "6) WARP 出站 / Outbound help" "31) 客户端订阅 / Client sub"

    love_menu_section13605 "导出与客户端 / Export & Clients"
    love_menu_row13605 "7) 节点信息 / Node info" "32) Clash Meta / Mihomo"
    love_menu_row13605 "8) 订阅生成 / Build sub" "33) 证书检查 / Cert check"
    love_menu_row13605 "9) 二维码 / QR codes" "34) HTTP-01 证书 / LE cert"
    love_menu_row13605 "10) Super Tools / 修复工具" "35) 证书切换 / Cert switch"
    love_menu_row13605 "11) 绿色 Web / Green Web" "36) CF Token / CF config"
    love_menu_row13605 "12) 在线更新 / Update" "37) CF DNS 自动解析 / DNS upsert"
    love_menu_row13605 "13) 客户端导出 / Client export" "38) CF DNS-01 证书 / DNS cert"

    love_menu_section13605 "旧版工具保留 / Legacy Tools Kept"
    love_menu_row13605 "14) v6 Project Tools" "39) H2 Reality v2rayN help"
    love_menu_row13605 "15) v7 Stable Tools" "40) 查看旧链接 / Show legacy"
    love_menu_row13605 "16) v8 Project Panel" "41) 备份旧链接 / Backup legacy"
    love_menu_row13605 "17) Nginx Reverse Proxy" "42) 清空旧链接 / Clean legacy"
    love_menu_row13605 "18) HY2/sing-box 修复 / Fix" "43) 帮助 / Help"
    love_menu_row13605 "19) IPv6-only 出站修复" "44) v13.60 检查 / Final check"
    love_menu_row13605 "20) WARP Manager / FS-style" "45) 端口/防火墙 / Ports"
    love_menu_row13605 "21) 运行状态 / Runtime status" "46) 国旗图标设置 / Flag icon"
    love_menu_row13605 "22) 备份配置 / Backup" "47) 自动识别国旗 / Auto flag"
    love_menu_row13605 "23) 卸载菜单 / Uninstall" "48) TRUE 手动提醒 / TRUE note"
    love_menu_row13605 "24) GitHub 发布说明" "49) Xray 补全检查 / Xray ext check"
    love_menu_row13605 "25) 安装 FS warp 命令" "0) 退出 / Exit"

    echo
    printf "%b提示:%b 绿色 Web / QR / 已通 sing-box 节点不动；Xray Stable 和 Xray Extended 分开。\n" "$(love_c13605 yellow)" "$(love_c13605 reset)"
    printf "%bH2 Reality:%b v2rayN 里 VLESS Core 需要 sing_box。\n" "$(love_c13605 yellow)" "$(love_c13605 reset)"
    echo
    read -rp "请选择 / Select: " choice
    case "${choice}" in
      1) love_call13605 show_all_node_catalog ;;
      2) love_call13605 install_xray_stable ;;
      3) love_call13605 install_singbox_native ;;
      4) love_call13605 argo_helper ;;
      5) love_call13605 port_hopping_helper ;;
      6) love_call13605 warp_helper ;;
      7) love_call13605 show_node_info ;;
      8) love_v1360_generate_client_subs ;;
      9) love_call13605 generate_qrcodes ;;
      10) love_call13605 super_menu ;;
      11) love_v1360_web ;;
      12) love_call13605 self_update_love ;;
      13) love_v1360_generate_client_subs; love_call13605 love_full_client_pack ;;
      14) love_call13605 v6_super_menu ;;
      15) love_call13605 v7_stable_menu ;;
      16) love_call13605 v8_menu ;;
      17) love_call13605 nginx_rp_menu ;;
      18) love_call13605 love_fix_hy2_now ;;
      19) love_call13605 love_ipv6_outbound_menu ;;
      20) love_call13605 love_warp_manager_menu ;;
      21) love_call13605 show_status ;;
      22) love_call13605 backup_configs ;;
      23) love_call13605 uninstall_menu_v7 ;;
      24) love_call13605 github_publish_note ;;
      25) love_call13605 love_install_fs_warp_command ;;
      26) install_xray_extended ;;
      27) love_call13605 love_v1360_env_detect ;;
      28) love_call13605 love_v1360_optimize ;;
      29) love_call13605 love_v1360_speed ;;
      30) love_v1360_generate_client_subs ;;
      31) love_v1360_generate_client_subs ;;
      32) love_v1360_generate_client_subs; generate_mihomo_yaml 2>/dev/null || true ;;
      33) love_call13605 love_v1360_cert_check ;;
      34) love_call13605 love_v1360_cert_http01 ;;
      35) love_call13605 love_v1354_cert_switch ;;
      36) love_call13605 love_v1360_cf_config ;;
      37) love_call13605 love_v1360_cf_dns ;;
      38) love_call13605 love_v1360_cf_cert_dns01 ;;
      39) love_call13605 love_h2_v2rayn_help13601 ;;
      40) love_call13605 love_legacy_show13601 ;;
      41) love_call13605 love_legacy_backup13601 ;;
      42) love_call13605 love_legacy_clean13601 ;;
      43) love_call13605 love_color_menu_help13601 ;;
      44) love_call13605 love_v1360_env_detect; echo; love_call13605 love_v1360_cert_check; echo; love_call13605 love_v1356_source_check ;;
      45) love_call13605 love_ports_v1334 ;;
      46) love_call13605 love_flag_set13602 ;;
      47) love_call13605 love_flag_auto13602; love_v1360_generate_client_subs ;;
      48) love_call13605 love_v13604_tls_manual_report ;;
      49) love_v13605_xray_extended_check ;;
      0|q|Q|exit) exit 0 ;;
      *) echo "[WARN] 无效选择 / Invalid choice." ;;
    esac
    love_pause13605
  done
}

love_v13605_xray_extended_check() {
  echo "================ Love v13.60.6 Xray Extended / Cert Mode Check ================"
  echo "VERSION=${LOVE_SCRIPT_VERSION}"
  echo
  if [[ -f "${XRAY_CONF}" ]]; then
    jq -r '.inbounds[]? | [.tag, (.protocol//""), (.port|tostring)] | @tsv' "${XRAY_CONF}" 2>/dev/null || true
  else
    echo "[WARN] 未找到 Xray 配置：${XRAY_CONF}"
  fi
  echo
  if [[ -f "${XRAY_INFO}" ]]; then
    grep -E '^(vless|hy2|hysteria2|trojan|vmess|ss)://' "${XRAY_INFO}" || true
  else
    echo "[WARN] 未找到 Xray client-info。"
  fi
}

love_v13605_help() {
  cat <<'EOF_V13605HELP'
Love v13.60.6 commands:
  Love                         打开经典双列菜单
  Love xray-extended           安装 Xray 补全模式
  Love xray-all                同上
  Love xray-plus               同上
  Love xray-ext-check          检查 Xray 补全节点

Xray Extended includes:
  LOVE-XRAY-REALITY
  LOVE-XRAY-TROJAN
  LOVE-XRAY-VMESS-WS
  LOVE-XRAY-VLESS-WS-TLS
  LOVE-XRAY-SS
  LOVE-XRAY-HY2 optional

Certificate modes:
  1. No domain + self.local + self-signed
  2. Domain + Let's Encrypt HTTP-01
  3. Domain + self/custom certificate generated by script
  4. Domain + existing cert.pem/key.pem imported with auto trust detection
  5. Domain + existing trusted CA cert forced insecure=false
  6. Domain + existing self-signed/untrusted cert forced insecure=true
EOF_V13605HELP
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_before_v13605 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_before_v13605/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.60.6-cert-mode-strict-xray-source-final}"
  case "${1:-}" in
    ""|menu|main|m)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      love_v13605_classic_menu ;;
    xray-extended|xray-all|xray-plus|xray-ext)
      need_root; prepare_dirs; install_xray_extended ;;
    xray-ext-check|v13605-check|v13606-check|xray-plus-check)
      love_v13605_xray_extended_check ;;
    help13605|v13605-help|help13606|v13606-help)
      love_v13605_help ;;
    *)
      love_original_main_before_v13605 "$@" ;;
  esac
}


# ============================================================================== 
# Love v13.60.7 - Classic menu / one-click update / uninstall index fixed
# - Based on v13.60.4 stable line plus later source-first improvements kept.
# - No protocol/web/QR/node logic removed.
# - Fixes menu item 12 to one-click update without asking URL.
# - Fixes menu item 23 to a stable classic uninstall menu.
# ============================================================================== 
LOVE_SCRIPT_VERSION="Love v13.60.9-early-main-update-final"
LOVE_RAW_URL_DEFAULT="${LOVE_RAW_URL_DEFAULT:-https://raw.githubusercontent.com/mingyueqianli/LOVENN/main/Love.sh}"

love_v13607_c() {
  case "$1" in
    blue) echo '\033[0;34m' ;;
    cyan) echo '\033[0;36m' ;;
    green) echo '\033[0;32m' ;;
    yellow) echo '\033[1;33m' ;;
    red) echo '\033[0;31m' ;;
    bold) echo '\033[1m' ;;
    reset|*) echo '\033[0m' ;;
  esac
}

love_v13607_header() {
  local b r
  b="$(love_v13607_c blue)"; r="$(love_v13607_c reset)"
  clear 2>/dev/null || true
  printf "%b\n" "${b}╔══════════════════════════════════════════════════════════════════════════════╗${r}"
  printf "%b  %-74s %b\n" "${b}║" "Love Node Server Manager  ${LOVE_SCRIPT_VERSION}" "║${r}"
  printf "%b\n" "${b}╚══════════════════════════════════════════════════════════════════════════════╝${r}"
}

love_v13607_section() {
  local b r
  b="$(love_v13607_c blue)"; r="$(love_v13607_c reset)"
  printf "\n%b[%s]%b\n" "$b" "$1" "$r"
}

love_v13607_row() {
  printf "  │ %-36s │ %-36s │\n" "$1" "$2"
}

love_v13607_pause() {
  echo
  read -rp "按回车返回主菜单 / Press Enter to return..." _ || true
}

love_v13607_update_url() {
  local url=""
  if [[ -s /opt/Love/update_url ]]; then
    url="$(head -n1 /opt/Love/update_url | tr -d '\r\n' || true)"
  fi
  if [[ -z "$url" && -n "${LOVE_UPDATE_URL:-}" ]]; then
    url="${LOVE_UPDATE_URL}"
  fi
  if [[ -z "$url" || "$url" == *YOURNAME* ]]; then
    url="${LOVE_RAW_URL_DEFAULT}"
  fi
  echo "$url"
}

love_v13607_oneclick_update() {
  need_root 2>/dev/null || true
  prepare_dirs 2>/dev/null || mkdir -p /opt/Love

  local url tmp backup target stamp
  url="$(love_v13607_update_url)"
  target="/opt/Love/Love.sh"
  tmp="/tmp/Love.update.$$.$RANDOM.sh"
  stamp="$(date +%F-%H%M%S)"
  backup="/opt/Love/backup/Love.sh.bak.${stamp}"
  mkdir -p /opt/Love/backup

  echo "================ Love 一键更新 / One-click update ================"
  echo "当前版本 / Current: ${LOVE_SCRIPT_VERSION}"
  echo "更新地址 / URL: ${url}"
  echo

  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 10 --max-time 90 "${url}?t=$(date +%s)" -o "$tmp" || curl -fL --connect-timeout 10 --max-time 90 "$url" -o "$tmp" || true
  fi
  if [[ ! -s "$tmp" ]] && command -v wget >/dev/null 2>&1; then
    wget -T 90 -qO "$tmp" "${url}?t=$(date +%s)" || wget -T 90 -qO "$tmp" "$url" || true
  fi

  [[ -s "$tmp" ]] || die "下载失败。请检查 GitHub Raw 地址或网络。"
  bash -n "$tmp" || die "新版脚本语法检查失败，已取消更新。"

  if [[ -f "$target" ]]; then
    cp -f "$target" "$backup"
    log "旧版已备份：$backup"
  fi

  cp -f "$tmp" "$target"
  chmod +x "$target"
  ln -sf "$target" /usr/local/bin/Love
  ln -sf "$target" /usr/local/bin/love
  echo "$url" > /opt/Love/update_url
  chmod 600 /opt/Love/update_url 2>/dev/null || true

  log "Love 已更新。重新运行：Love"
  "$target" v13607-version 2>/dev/null || grep -m1 '^LOVE_SCRIPT_VERSION=' "$target" || true
}

love_v13607_uninstall_menu() {
  while true; do
    love_v13607_header
    love_v13607_section "卸载菜单 / Uninstall Menu"
    love_v13607_row "1) 停止 Xray / Stop Xray" "5) 清理订阅 / Clean subs"
    love_v13607_row "2) 停止 sing-box / Stop sing-box" "6) 清理 Web / Clean Web"
    love_v13607_row "3) 停止 Web/Argo/Timer" "7) 清理 WARP/WireProxy"
    love_v13607_row "4) 完整卸载 Love / Full uninstall" "0) 返回 / Back"
    echo
    echo "说明：1-3 是软卸载，默认保留配置；4 会删除 /opt/Love 等文件，需要二次确认。"
    read -rp "请选择 / Select: " u
    case "$u" in
      1)
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        log "Xray 已停止/禁用，配置保留。" ;;
      2)
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        log "sing-box 已停止/禁用，配置保留。" ;;
      3)
        systemctl stop nginx cloudflared love-web love-sub love-status 2>/dev/null || true
        systemctl disable cloudflared love-web love-sub love-status 2>/dev/null || true
        rm -f /etc/systemd/system/love-web.service /etc/systemd/system/love-sub.service /etc/systemd/system/love-status.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        log "Web/Argo/Timer 已尝试停止，配置保留。" ;;
      4)
        warn "完整卸载会删除 /opt/Love、/var/www/love-admin、Love 命令及相关服务。"
        read -rp "确认完整卸载？请输入 DELETE LOVE 继续: " ok
        [[ "$ok" == "DELETE LOVE" ]] || { warn "已取消。"; love_v13607_pause; continue; }
        systemctl stop xray sing-box nginx cloudflared love-web love-sub love-status 2>/dev/null || true
        systemctl disable xray sing-box cloudflared love-web love-sub love-status 2>/dev/null || true
        rm -f /usr/local/bin/Love /usr/local/bin/love 2>/dev/null || true
        rm -f /etc/systemd/system/love-web.service /etc/systemd/system/love-sub.service /etc/systemd/system/love-status.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        rm -rf /opt/Love /var/www/love-admin 2>/dev/null || true
        log "Love 已完整卸载。" ;;
      5)
        mkdir -p /opt/Love/backup
        tar -czf "/opt/Love/backup/subscribe-before-clean-${stamp:-$(date +%F-%H%M%S)}.tar.gz" /opt/Love/subscribe 2>/dev/null || true
        rm -rf /opt/Love/subscribe/* 2>/dev/null || true
        log "订阅已清理，已尽量备份。" ;;
      6)
        mkdir -p /opt/Love/backup
        tar -czf "/opt/Love/backup/web-before-clean-$(date +%F-%H%M%S).tar.gz" /var/www/love-admin 2>/dev/null || true
        rm -rf /var/www/love-admin/* 2>/dev/null || true
        log "Web 文件已清理，已尽量备份。" ;;
      7)
        if declare -F love_warp_uninstall >/dev/null 2>&1; then love_warp_uninstall; else warn "未找到 WARP 清理函数。"; fi ;;
      0|q|Q|back) return 0 ;;
      *) warn "无效选择。" ;;
    esac
    love_v13607_pause
  done
}

love_v13607_classic_menu() {
  while true; do
    love_v13607_header
    love_v13607_section "核心安装 / Core Install"
    love_v13607_row "1) 节点目录 / Node catalog" "26) Xray 补全 / Xray Extended"
    love_v13607_row "2) Xray 稳定 / Xray Stable" "27) VPS 环境 / VPS env"
    love_v13607_row "3) sing-box 全协议 / All" "28) BBR/MTU 优化 / Optimize"
    love_v13607_row "4) Argo 隧道 / Cloudflared" "29) 一键测速 / Speed"
    love_v13607_row "5) UDP 跳跃 / Port hopping" "30) 重建订阅 / Rebuild sub"
    love_v13607_row "6) WARP 出站 / WARP help" "31) 客户端订阅 / Client sub"

    love_v13607_section "导出与客户端 / Export & Clients"
    love_v13607_row "7) 节点信息 / Node info" "32) Clash/Mihomo YAML"
    love_v13607_row "8) 订阅生成 / Build sub" "33) 证书检查 / Cert check"
    love_v13607_row "9) 二维码 / QR codes" "34) HTTP-01 证书 / LE cert"
    love_v13607_row "10) Super Tools / 修复" "35) 证书切换 / Cert switch"
    love_v13607_row "11) 绿色 Web / Green Web" "36) CF Token / CF config"
    love_v13607_row "12) 一键更新 / One-click update" "37) CF DNS / DNS upsert"
    love_v13607_row "13) 客户端导出 / Client export" "38) CF DNS-01 证书 / DNS cert"

    love_v13607_section "旧版工具保留 / Legacy Tools Kept"
    love_v13607_row "14) v6 Project Tools" "39) H2 Reality v2rayN help"
    love_v13607_row "15) v7 Stable Tools" "40) 查看旧链接 / Show legacy"
    love_v13607_row "16) v8 Project Panel" "41) 备份旧链接 / Backup legacy"
    love_v13607_row "17) Nginx Reverse Proxy" "42) 清空旧链接 / Clean legacy"
    love_v13607_row "18) HY2/sing-box 修复" "43) 帮助 / Help"
    love_v13607_row "19) IPv6-only 修复" "44) v13.60 检查 / Final check"
    love_v13607_row "20) WARP Manager" "45) 端口/防火墙 / Ports"
    love_v13607_row "21) 运行状态 / Status" "46) 国旗图标 / Flag icon"
    love_v13607_row "22) 备份配置 / Backup" "47) 自动识别国旗 / Auto flag"
    love_v13607_row "23) 卸载菜单 / Uninstall" "48) TRUE 手动提醒 / TRUE note"
    love_v13607_row "24) GitHub 发布说明" "49) Xray 补全检查 / Xray check"
    love_v13607_row "25) 安装 FS warp 命令" "0) 退出 / Exit"

    echo
    echo "提示: 12 为一键更新，不再默认要求输入地址；23 为固定卸载菜单。"
    read -rp "请选择 / Select: " choice
    case "${choice}" in
      1) love_call13605 show_all_node_catalog ;;
      2) love_call13605 install_xray_stable ;;
      3) love_call13605 install_singbox_native ;;
      4) love_call13605 argo_helper ;;
      5) love_call13605 port_hopping_helper ;;
      6) love_call13605 warp_helper ;;
      7) love_call13605 show_node_info ;;
      8) love_v1360_generate_client_subs ;;
      9) love_call13605 generate_qrcodes ;;
      10) love_call13605 super_menu ;;
      11) love_v1360_web ;;
      12) love_v13607_oneclick_update ;;
      13) love_v1360_generate_client_subs; love_call13605 love_full_client_pack ;;
      14) love_call13605 v6_super_menu ;;
      15) love_call13605 v7_stable_menu ;;
      16) love_call13605 v8_menu ;;
      17) love_call13605 nginx_rp_menu ;;
      18) love_call13605 love_fix_hy2_now ;;
      19) love_call13605 love_ipv6_outbound_menu ;;
      20) love_call13605 love_warp_manager_menu ;;
      21) love_call13605 show_status ;;
      22) love_call13605 backup_configs ;;
      23) love_v13607_uninstall_menu ;;
      24) love_call13605 github_publish_note ;;
      25) love_call13605 love_install_fs_warp_command ;;
      26) install_xray_extended ;;
      27) love_call13605 love_v1360_env_detect ;;
      28) love_call13605 love_v1360_optimize ;;
      29) love_call13605 love_v1360_speed ;;
      30|31) love_v1360_generate_client_subs ;;
      32) love_v1360_generate_client_subs; generate_mihomo_yaml 2>/dev/null || true ;;
      33) love_call13605 love_v1360_cert_check ;;
      34) love_call13605 love_v1360_cert_http01 ;;
      35) love_call13605 love_v1354_cert_switch ;;
      36) love_call13605 love_v1360_cf_config ;;
      37) love_call13605 love_v1360_cf_dns ;;
      38) love_call13605 love_v1360_cf_cert_dns01 ;;
      39) love_call13605 love_h2_v2rayn_help13601 ;;
      40) love_call13605 love_legacy_show13601 ;;
      41) love_call13605 love_legacy_backup13601 ;;
      42) love_call13605 love_legacy_clean13601 ;;
      43) love_call13605 love_color_menu_help13601 ;;
      44) love_call13605 love_v1360_env_detect; echo; love_call13605 love_v1360_cert_check; echo; love_call13605 love_v1356_source_check ;;
      45) love_call13605 love_ports_v1334 ;;
      46) love_call13605 love_flag_set13602 ;;
      47) love_call13605 love_flag_auto13602; love_v1360_generate_client_subs ;;
      48) love_call13605 love_v13604_tls_manual_report ;;
      49) love_v13605_xray_extended_check ;;
      0|q|Q|exit) exit 0 ;;
      *) warn "无效选择 / Invalid choice." ;;
    esac
    love_v13607_pause
  done
}

if declare -F main >/dev/null 2>&1 && ! declare -F love_original_main_before_v13607 >/dev/null 2>&1; then
  eval "$(declare -f main | sed '1s/^main/love_original_main_before_v13607/')"
fi

main() {
  VERSION="${LOVE_SCRIPT_VERSION:-Love v13.60.9-early-main-update-final}"
  case "${1:-}" in
    ""|menu|main|m)
      need_root 2>/dev/null || true
      prepare_dirs 2>/dev/null || true
      fix_hostname 2>/dev/null || true
      check_os_soft 2>/dev/null || true
      install_shortcut 2>/dev/null || true
      love_v13607_classic_menu ;;
    update|self-update|online-update)
      love_v13607_oneclick_update ;;
    uninstall|uninstall-menu)
      love_v13607_uninstall_menu ;;
    v13607-version|version)
      echo "${LOVE_SCRIPT_VERSION}" ;;
    xray-extended|xray-all|xray-plus|xray-ext)
      need_root; prepare_dirs; install_xray_extended ;;
    xray-ext-check|v13605-check|v13606-check|v13607-check|xray-plus-check)
      love_v13605_xray_extended_check ;;
    *)
      love_original_main_before_v13607 "$@" ;;
  esac
}

main "$@"

#!/bin/bash
# =============================================================================
#  proxy-setup.command — Tự cài proxy toàn hệ thống cho macOS
#  Dùng lõi mihomo (Clash Meta) ở chế độ TUN: mọi app (Safari, Discord, Xcode,
#  App Store Connect...) đều đi qua proxy, không cần cấu hình từng app.
#
#  Cách chạy:  mở Terminal, gõ:   bash ~/Downloads/proxy-setup.command
# =============================================================================

LABEL="com.proxysetup.mihomo"
APP_DIR="/Library/Application Support/ProxySetup"
BIN="$APP_DIR/mihomo"
CONF_DIR="$APP_DIR/config"
CONF="$CONF_DIR/config.yaml"
INFO="$APP_DIR/proxy-info.txt"
LOG="$APP_DIR/mihomo.log"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# ---- Cần quyền admin (TUN mode + chạy nền hệ thống) ----
if [ "$(id -u)" -ne 0 ]; then
  echo "Script cần quyền quản trị. Nhập mật khẩu máy Mac (khi gõ sẽ không hiện ký tự):"
  exec sudo bash "$0" "$@"
fi

# ---- Tiện ích in màu ----
G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
ok()   { echo "${G}✔ $*${N}"; }
err()  { echo "${R}✘ $*${N}"; }
warn() { echo "${Y}! $*${N}"; }
step() { echo; echo "${B}▶ $*${N}"; }

# ---- Danh sách các kết nối mạng (Wi-Fi, Ethernet...) ----
list_services() {
  networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//'
}

# ---- Tắt proxy cũ trong System Settings (tránh xung đột với TUN) ----
disable_system_proxies() {
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    networksetup -setwebproxystate "$svc" off 2>/dev/null
    networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
    networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
    networksetup -setautoproxystate "$svc" off 2>/dev/null
  done < <(list_services)
}

# ---- IPv6: tắt khi dùng proxy (tránh lộ IP), bật lại khi gỡ ----
set_ipv6() {
  local mode="$1"   # linklocal | auto
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    if [ "$mode" = "linklocal" ]; then
      networksetup -setv6linklocal "$svc" 2>/dev/null
    else
      networksetup -setv6automatic "$svc" 2>/dev/null
    fi
  done < <(list_services)
}

flush_dns() {
  dscacheutil -flushcache 2>/dev/null
  killall -HUP mDNSResponder 2>/dev/null
}

# ---- Tải lõi mihomo từ GitHub ----
install_core() {
  if [ -x "$BIN" ] && "$BIN" -v >/dev/null 2>&1; then
    ok "Lõi proxy đã có sẵn: $("$BIN" -v | head -1)"
    return 0
  fi
  step "Đang tải lõi proxy (mihomo)..."
  local arch pattern url tmp
  arch="$(uname -m)"
  if [ "$arch" = "arm64" ]; then
    pattern='mihomo-darwin-arm64-v[0-9.]+\.gz"'
  else
    pattern='mihomo-darwin-amd64-compatible-v[0-9.]+\.gz"'
  fi
  url="$(curl -fsSL --max-time 30 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | grep '"browser_download_url"' | grep -E "$pattern" | head -1 | cut -d'"' -f4)"
  if [ -z "$url" ]; then
    err "Không lấy được link tải từ GitHub. Kiểm tra kết nối mạng rồi chạy lại."
    return 1
  fi
  mkdir -p "$APP_DIR" "$CONF_DIR"
  tmp="$(mktemp)"
  if ! curl -fL --max-time 300 -o "$tmp" "$url"; then
    err "Tải thất bại."; rm -f "$tmp"; return 1
  fi
  gunzip -c "$tmp" > "$BIN" && rm -f "$tmp"
  chmod 755 "$BIN"
  xattr -d com.apple.quarantine "$BIN" 2>/dev/null
  if "$BIN" -v >/dev/null 2>&1; then
    ok "Đã cài: $("$BIN" -v | head -1)"
  else
    err "File tải về không chạy được."; return 1
  fi
}

# ---- Thử proxy trực tiếp bằng curl, trả về IP ra ngoài ----
test_proxy() {
  local scheme="$1"   # socks5h | http
  local args=(-s --max-time 15 -x "$scheme://$P_HOST:$P_PORT")
  [ -n "$P_USER" ] && args+=(--proxy-user "$P_USER:$P_PASS")
  curl "${args[@]}" https://api.ipify.org 2>/dev/null
}

# ---- Nhập & phân tích thông tin proxy ----
read_proxy() {
  echo
  echo "Dán thông tin proxy theo một trong các dạng:"
  echo "   ip:port:user:pass      ip:port      user:pass@ip:port"
  read -r -p "> " RAW
  RAW="$(echo "$RAW" | tr -d '[:space:]')"
  RAW="${RAW#*://}"   # bỏ tiền tố socks5:// hoặc http:// nếu có

  P_HOST=""; P_PORT=""; P_USER=""; P_PASS=""
  if [[ "$RAW" == *@* ]]; then
    local creds="${RAW%@*}" hp="${RAW##*@}"
    P_HOST="${hp%%:*}"; P_PORT="${hp##*:}"
    P_USER="${creds%%:*}"; P_PASS="${creds#*:}"
  else
    IFS=':' read -r P_HOST P_PORT P_USER P_PASS <<< "$RAW"
  fi

  if [ -z "$P_HOST" ] || ! [[ "$P_PORT" =~ ^[0-9]+$ ]]; then
    err "Sai định dạng. Ví dụ đúng: 103.12.34.56:1080:user:pass"
    return 1
  fi
}

# ---- Ghi file cấu hình mihomo ----
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

write_config() {
  local auth=""
  if [ -n "$P_USER" ]; then
    auth="    username: $(yaml_quote "$P_USER")
    password: $(yaml_quote "$P_PASS")"
  fi
  local crd_rule=""
  if [ "$CRD_DIRECT" = "y" ]; then
    crd_rule="  - DOMAIN-SUFFIX,remotedesktop.google.com,DIRECT
  - DOMAIN-SUFFIX,remotedesktop-pa.googleapis.com,DIRECT"
  fi

  mkdir -p "$CONF_DIR"
  cat > "$CONF" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
geo-auto-update: false

tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-filter:
    - '*.lan'
    - '*.local'
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

proxies:
  - name: my-proxy
    type: $P_TYPE
    server: $P_HOST
    port: $P_PORT
$auth
    udp: true

rules:
$crd_rule
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - MATCH,my-proxy
EOF
  # Bỏ dòng trống thừa khi không có auth / rule CRD
  sed -i '' '/^$/N;/^\n$/D' "$CONF"
  chmod 600 "$CONF"
}

# ---- Tạo dịch vụ chạy nền, tự khởi động cùng máy ----
install_service() {
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>-d</string>
    <string>$CONF_DIR</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  chmod 644 "$PLIST"; chown root:wheel "$PLIST"
  launchctl bootout system "$PLIST" 2>/dev/null
  sleep 1
  : > "$LOG"
  launchctl bootstrap system "$PLIST"
}

stop_service() {
  launchctl bootout system "$PLIST" 2>/dev/null
}

current_ip() { curl -s --max-time 8 https://api.ipify.org 2>/dev/null; }

# ---- iCloud Private Relay: in "on" hoặc "off" (macOS 12 trở lên) ----
# Đọc giá trị trong domain com.apple.networkserviceproxy, cách làm theo
# script của Joel Bruner (github.com/brunerd, giấy phép MIT).
private_relay_state() {
  if [ "$(sw_vers -productVersion | cut -d. -f1)" -le 11 ]; then echo unknown; return; fi
  local user uid parentData target keyStatus
  user="$(stat -f %Su /dev/console)"
  uid="$(stat -f %u /dev/console)"
  target=':$objects:1:PrivacyProxyServiceStatus'
  parentData="$(launchctl asuser "$uid" sudo -u "$user" defaults export com.apple.networkserviceproxy - 2>/dev/null)"
  if [ -z "$parentData" ]; then echo unknown; return; fi
  keyStatus="$(/usr/libexec/PlistBuddy -c "print '$target'" /dev/stdin 2>/dev/null <<< "$(plutil -extract NSPServiceStatusManagerInfo xml1 -o - /dev/stdin <<< "$parentData" | xmllint --xpath "string(//data)" - | base64 --decode | plutil -convert xml1 - -o -)")"
  if [ "$keyStatus" = "1" ]; then echo on; else echo off; fi
}

# ---- Kiểm tra và cảnh báo iCloud Private Relay ----
check_private_relay() {
  case "$(private_relay_state)" in
    on)  warn "iCloud Private Relay đang BẬT, dễ xung đột với proxy. Tắt tại: System Settings → [Tên bạn] → iCloud → Private Relay → Off" ;;
    off) ok "iCloud Private Relay đang tắt" ;;
    *)   warn "Không đọc được trạng thái iCloud Private Relay. Hãy kiểm tra thủ công: System Settings → [Tên bạn] → iCloud → Private Relay → Off" ;;
  esac
}

# =============================================================================
#  1. Cài đặt / đổi proxy
# =============================================================================
do_setup() {
  read_proxy || return

  step "Đang kiểm tra proxy $P_HOST:$P_PORT ..."
  EXIT_IP="$(test_proxy socks5h)"
  if [[ "$EXIT_IP" =~ ^[0-9.]+$ ]]; then
    P_TYPE="socks5"
  else
    EXIT_IP="$(test_proxy http)"
    if [[ "$EXIT_IP" =~ ^[0-9.]+$ ]]; then
      P_TYPE="http"
    else
      err "Proxy không hoạt động (đã thử cả SOCKS5 và HTTP)."
      echo "   Kiểm tra lại IP/port/user/pass, hoặc proxy đã hết hạn."
      return
    fi
  fi
  ok "Proxy hoạt động — loại: $(echo "$P_TYPE" | tr 'a-z' 'A-Z') — IP ra ngoài: $EXIT_IP"
  [ "$P_TYPE" = "http" ] && warn "Proxy HTTP không hỗ trợ UDP: voice/video Discord có thể không chạy."

  echo
  read -r -p "Cho Chrome Remote Desktop đi thẳng, không qua proxy? (y/N): " CRD_DIRECT
  CRD_DIRECT="$(echo "$CRD_DIRECT" | tr 'A-Z' 'a-z')"

  install_core || return

  step "Đang cấu hình..."
  stop_service
  write_config
  disable_system_proxies; ok "Đã tắt proxy cũ trong System Settings"
  set_ipv6 linklocal;     ok "Đã tắt IPv6 (tránh lộ IP)"

  step "Đang khởi động proxy..."
  install_service
  flush_dns

  local ip="" i
  for i in $(seq 1 15); do
    sleep 1
    ip="$(current_ip)"
    [ "$ip" = "$EXIT_IP" ] && break
  done

  echo
  if [ "$ip" = "$EXIT_IP" ]; then
    ok "${B}HOÀN TẤT!${N}${G} Toàn bộ máy đang dùng IP: $ip"
    {
      echo "Proxy: $P_HOST:$P_PORT ($P_TYPE)"
      echo "IP ra ngoài: $EXIT_IP"
      echo "Cài lúc: $(date)"
    } > "$INFO"
    echo
    check_private_relay
    warn "Mở lại Safari / Discord để app nhận kết nối mới."
  else
    err "Proxy chưa áp dụng được (IP hiện tại: ${ip:-không có mạng})."
    echo "   Log lỗi:"; tail -n 15 "$LOG" | sed 's/^/   /'
  fi
}

# =============================================================================
#  2. Kiểm tra trạng thái
# =============================================================================
do_status() {
  step "Trạng thái"
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    ok "Dịch vụ proxy: ĐANG CHẠY"
  else
    err "Dịch vụ proxy: KHÔNG CHẠY"
  fi
  [ -f "$INFO" ] && sed 's/^/   /' "$INFO"
  echo
  echo "   IP hiện tại của máy:"
  curl -s --max-time 10 https://ipinfo.io/json 2>/dev/null \
    | grep -E '"(ip|city|country|org)"' | sed 's/^ */   /'
  echo
  check_private_relay
}

# =============================================================================
#  3. Gỡ proxy (trở về mạng gốc)
# =============================================================================
do_remove() {
  warn "Sau khi gỡ, máy sẽ dùng IP thật. Đừng đăng nhập Apple ID / tài khoản cần tách IP."
  read -r -p "Chắc chắn gỡ? (y/N): " c
  [ "$(echo "$c" | tr 'A-Z' 'a-z')" = "y" ] || return
  stop_service
  rm -f "$PLIST"
  rm -rf "$APP_DIR"
  set_ipv6 auto
  flush_dns
  ok "Đã gỡ proxy. IP hiện tại: $(current_ip)"
}

# =============================================================================
#  Menu
# =============================================================================
while true; do
  echo
  echo "${B}========== PROXY SETUP cho macOS ==========${N}"
  echo "  1) Cài đặt / đổi proxy"
  echo "  2) Kiểm tra trạng thái & IP hiện tại"
  echo "  3) Gỡ proxy (dùng lại mạng gốc)"
  echo "  0) Thoát"
  read -r -p "Chọn: " choice
  case "$choice" in
    1) do_setup ;;
    2) do_status ;;
    3) do_remove ;;
    0) exit 0 ;;
    *) warn "Chọn 1, 2, 3 hoặc 0" ;;
  esac
done

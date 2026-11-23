#!/usr/bin/env bash
#
# openvpn-rut.sh — быстрое развёртывание OpenVPN-сервера для удалённого
# доступа к устройствам за роутером Teltonika RUT950 (и другими RutOS-роутерами).
#
# Схема:
#   [Ваш ПК / телефон] --VPN--> [VPS: OpenVPN-сервер] <--VPN-- [RUT950] --LAN-- [Устройство]
#
# Роутер подключается к серверу как клиент и "анонсирует" свою LAN-подсеть
# (iroute). Остальные клиенты получают маршрут до этой подсети и могут
# обращаться к устройству по его локальному IP (например 192.168.1.100).
#
# Поддерживаемые ОС сервера: Ubuntu 22.04+, Debian 11+ (нужен OpenVPN 2.5+).
#
# Использование:
#   sudo ./openvpn-rut.sh install [--port 1194] [--proto udp] [--endpoint IP_или_домен] [--vpn-net 10.8.0.0]
#   sudo ./openvpn-rut.sh add-router <имя> <LAN-подсеть/маска>   # пример: add-router rut950 192.168.1.0/24
#   sudo ./openvpn-rut.sh add-client <имя>                       # пример: add-client laptop
#   sudo ./openvpn-rut.sh revoke <имя>
#   sudo ./openvpn-rut.sh list
#   sudo ./openvpn-rut.sh uninstall
#
set -euo pipefail

OVPN_DIR=/etc/openvpn/server
EASYRSA_DIR=/etc/openvpn/easy-rsa
CCD_DIR=$OVPN_DIR/ccd
STATE_FILE=$OVPN_DIR/rut-vpn.env
OUT_DIR=${OUT_DIR:-/root/openvpn-clients}
SERVICE=openvpn-server@server

c_green=$'\e[32m'; c_red=$'\e[31m'; c_yellow=$'\e[33m'; c_reset=$'\e[0m'
info() { echo "${c_green}[+]${c_reset} $*"; }
warn() { echo "${c_yellow}[!]${c_reset} $*" >&2; }
die()  { echo "${c_red}[x]${c_reset} $*" >&2; exit 1; }

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

need_root() { [[ $EUID -eq 0 ]] || die "Запустите от root (sudo)."; }

load_state() {
  [[ -f $STATE_FILE ]] || die "Сервер не установлен. Сначала: $0 install"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

valid_name() {
  [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "Имя '$1' недопустимо: только латиница, цифры, '-', '_' (до 32 символов)."
}

# 192.168.1.0/24 -> "192.168.1.0 255.255.255.0"
cidr_to_netmask() {
  local cidr=$1 ip bits mask="" i octet
  [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "Неверная подсеть '$cidr'. Формат: 192.168.1.0/24"
  ip=${cidr%/*}; bits=${cidr#*/}
  for i in 1 2 3 4; do
    if (( bits >= 8 )); then octet=255; bits=$((bits-8))
    else octet=$(( 256 - 2**(8-bits) )); bits=0; fi
    mask+=$octet; (( i < 4 )) && mask+=.
  done
  echo "$ip $mask"
}

detect_public_ip() {
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') && [[ -n $ip ]] && break
  done
  [[ -z $ip ]] && ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  echo "$ip"
}

# ---------------------------------------------------------------- install ---
cmd_install() {
  local port=1194 proto=udp endpoint="" vpn_net=10.8.0.0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) port=$2; shift 2;;
      --proto) proto=$2; shift 2;;
      --endpoint) endpoint=$2; shift 2;;
      --vpn-net) vpn_net=$2; shift 2;;
      *) die "Неизвестный параметр: $1";;
    esac
  done
  [[ $proto == udp || $proto == tcp ]] || die "--proto: udp или tcp"
  [[ -f $STATE_FILE ]] && die "Уже установлено ($STATE_FILE). Для переустановки: $0 uninstall"

  [[ -f /etc/debian_version ]] || die "Поддерживаются только Debian/Ubuntu."

  # Конфликты с уже работающими VPN (WireGuard/wg-easy часто тоже используют 10.8.0.0/24)
  if ip -4 route show | awk '{print $1}' | grep -q "^${vpn_net%.*}\."; then
    die "Подсеть $vpn_net/24 уже используется на сервере (WireGuard?): $(ip -4 route show | grep "^${vpn_net%.*}\." | head -1)
    Укажите другую: $0 install --vpn-net 10.9.0.0"
  fi
  local ss_flag=-lnu; [[ $proto == tcp ]] && ss_flag=-lnt
  if ss "$ss_flag" -H 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"; then
    die "Порт $port/$proto уже занят: $(ss -lnp | grep ":$port " | head -1)
    Укажите другой: --port 1195"
  fi

  info "Установка пакетов…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openvpn easy-rsa curl iptables ca-certificates >/dev/null

  local ver; ver=$(openvpn --version | awk 'NR==1{print $2}')
  [[ $(printf '%s\n2.5\n' "$ver" | sort -V | head -1) == 2.5 ]] \
    || die "Нужен OpenVPN 2.5+, установлен $ver. Используйте Ubuntu 22.04+ / Debian 11+."

  [[ -z $endpoint ]] && endpoint=$(detect_public_ip)
  [[ -n $endpoint ]] || die "Не удалось определить внешний IP. Укажите --endpoint"
  info "Адрес сервера для клиентов: $endpoint:$port/$proto"

  info "Создание PKI (Easy-RSA)…"
  rm -rf "$EASYRSA_DIR"
  mkdir -p "$EASYRSA_DIR"
  cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/"
  (
    cd "$EASYRSA_DIR"
    export EASYRSA_BATCH=1 EASYRSA_REQ_CN="rut-vpn-ca" EASYRSA_CERT_EXPIRE=3650 EASYRSA_CRL_DAYS=3650
    ./easyrsa init-pki >/dev/null
    ./easyrsa build-ca nopass >/dev/null 2>&1
    ./easyrsa build-server-full server nopass >/dev/null 2>&1
    ./easyrsa gen-crl >/dev/null 2>&1
  )

  mkdir -p "$OVPN_DIR" "$CCD_DIR" "$OUT_DIR"
  chmod 700 "$OUT_DIR"
  cp "$EASYRSA_DIR/pki/ca.crt" "$EASYRSA_DIR/pki/issued/server.crt" "$EASYRSA_DIR/pki/private/server.key" "$OVPN_DIR/"
  cp "$EASYRSA_DIR/pki/crl.pem" "$OVPN_DIR/crl.pem"; chmod 644 "$OVPN_DIR/crl.pem"
  openvpn --genkey secret "$OVPN_DIR/ta.key" 2>/dev/null || openvpn --genkey --secret "$OVPN_DIR/ta.key"

  local group=nogroup; getent group nogroup >/dev/null || group=nobody
  local explicit_exit=""; [[ $proto == udp ]] && explicit_exit="explicit-exit-notify 1"

  info "Конфигурация сервера…"
  cat > "$OVPN_DIR/server.conf" <<EOF
# Сгенерировано openvpn-rut.sh
port $port
proto $proto
dev tun
topology subnet
server $vpn_net 255.255.255.0

ca ca.crt
cert server.crt
key server.key
dh none
ecdh-curve prime256v1
tls-auth ta.key 0
crl-verify crl.pem
remote-cert-tls client

# Совместимость с RutOS (OpenVPN 2.4/2.5/2.6) и обычными клиентами
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC
data-ciphers-fallback AES-256-CBC
auth SHA256
tls-version-min 1.2

# Каталог с настройками клиентов (iroute для LAN-подсетей роутеров)
client-config-dir ccd
# Клиенты видят друг друга и подсети за роутерами
client-to-client

keepalive 10 60
persist-key
persist-tun
user nobody
group $group
status /var/log/openvpn-status.log 30
status-version 2
verb 3
$explicit_exit

# --- Подсети роутеров (управляется скриптом, не редактируйте вручную) ---
EOF

  cat > "$STATE_FILE" <<EOF
PORT=$port
PROTO=$proto
ENDPOINT=$endpoint
VPN_NET=$vpn_net
EOF

  info "Включение IP-форвардинга…"
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-rut.conf
  sysctl -q -p /etc/sysctl.d/99-openvpn-rut.conf

  setup_firewall "$port" "$proto"

  systemctl enable --now "$SERVICE" >/dev/null 2>&1
  sleep 1
  systemctl is-active --quiet "$SERVICE" || die "Сервис не запустился: journalctl -u $SERVICE"

  info "Готово! OpenVPN-сервер запущен."
  echo
  echo "Дальше:"
  echo "  1) Роутер:  $0 add-router rut950 192.168.1.0/24"
  echo "  2) Ваш ПК:  $0 add-client laptop"
}

setup_firewall() {
  local port=$1 proto=$2
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    info "Открываю порт $port/$proto в ufw…"
    ufw allow "$port/$proto" >/dev/null
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw reload >/dev/null
  fi
  # Отдельный systemd-юнит для правил iptables, чтобы переживать перезагрузку
  cat > /etc/systemd/system/openvpn-rut-iptables.service <<EOF
[Unit]
Description=iptables rules for openvpn-rut
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -I INPUT -p $proto --dport $port -j ACCEPT
ExecStart=/usr/sbin/iptables -I FORWARD -i tun+ -j ACCEPT
ExecStart=/usr/sbin/iptables -I FORWARD -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=/usr/sbin/iptables -D INPUT -p $proto --dport $port -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -i tun+ -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now openvpn-rut-iptables.service >/dev/null 2>&1
}

# ---------------------------------------------------------- certificates ---
build_cert() {
  local name=$1
  [[ -f $EASYRSA_DIR/pki/issued/$name.crt ]] && die "Клиент '$name' уже существует."
  ( cd "$EASYRSA_DIR" && EASYRSA_BATCH=1 EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$name" nopass >/dev/null 2>&1 )
}

# Создаёт .ovpn (всё в одном файле) и папку с отдельными файлами для RutOS
export_client() {
  local name=$1 dir=$OUT_DIR/$1
  mkdir -p "$dir"
  cp "$OVPN_DIR/ca.crt" "$dir/ca.crt"
  cp "$EASYRSA_DIR/pki/issued/$name.crt" "$dir/$name.crt"
  cp "$EASYRSA_DIR/pki/private/$name.key" "$dir/$name.key"
  cp "$OVPN_DIR/ta.key" "$dir/ta.key"

  {
    cat <<EOF
client
dev tun
proto $PROTO
remote $ENDPOINT $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
# OpenVPN 2.4 (старые прошивки RutOS) не знает data-ciphers — пропустит эти строки
ignore-unknown-option data-ciphers data-ciphers-fallback
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC
data-ciphers-fallback AES-256-CBC
cipher AES-256-CBC
auth SHA256
key-direction 1
verb 3
<ca>
$(cat "$OVPN_DIR/ca.crt")
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$EASYRSA_DIR/pki/issued/$name.crt")
</cert>
<key>
$(cat "$EASYRSA_DIR/pki/private/$name.key")
</key>
<tls-auth>
$(cat "$OVPN_DIR/ta.key")
</tls-auth>
EOF
  } > "$dir/$name.ovpn"
  chmod 600 "$dir"/*
  tar -C "$OUT_DIR" -czf "$OUT_DIR/$name.tar.gz" "$name"
  chmod 600 "$OUT_DIR/$name.tar.gz"
}

# Пересобирает блок route/push в конце server.conf по файлам ccd/ (iroute ...)
rebuild_routes() {
  local marker="# --- Подсети роутеров" f net mask
  sed -i "/^$marker/,\$d" "$OVPN_DIR/server.conf"
  echo "$marker (управляется скриптом, не редактируйте вручную) ---" >> "$OVPN_DIR/server.conf"
  for f in "$CCD_DIR"/*; do
    [[ -f $f ]] || continue
    read -r _ net mask < "$f"
    echo "route $net $mask" >> "$OVPN_DIR/server.conf"
    echo "push \"route $net $mask\"" >> "$OVPN_DIR/server.conf"
  done
}

cmd_add_router() {
  [[ $# -eq 2 ]] || die "Использование: $0 add-router <имя> <подсеть/маска>"
  local name=$1 net mask; valid_name "$name"; load_state
  read -r net mask < <(cidr_to_netmask "$2")

  grep -qx "iroute $net $mask" "$CCD_DIR"/* 2>/dev/null && die "Подсеть $2 уже привязана к другому роутеру."

  build_cert "$name"
  # iroute — подсеть живёт за этим клиентом; push-remove — не слать роутеру
  # маршрут на его же собственную LAN (иначе конфликт с локальным маршрутом)
  cat > "$CCD_DIR/$name" <<EOF
iroute $net $mask
push-remove "route $net"
EOF
  rebuild_routes
  export_client "$name"
  systemctl restart "$SERVICE"

  info "Роутер '$name' добавлен, подсеть $2 доступна через VPN."
  echo "Файлы для RUT950: $OUT_DIR/$name/  (архив: $OUT_DIR/$name.tar.gz)"
  echo "  ca.crt, $name.crt, $name.key, ta.key, $name.ovpn"
  echo "Инструкция по настройке роутера: docs/RUT950.md"
}

cmd_add_client() {
  [[ $# -eq 1 ]] || die "Использование: $0 add-client <имя>"
  local name=$1; valid_name "$name"; load_state
  build_cert "$name"
  export_client "$name"
  info "Клиент '$name' создан: $OUT_DIR/$name/$name.ovpn"
  echo "Импортируйте .ovpn в OpenVPN Connect / OpenVPN GUI."
}

cmd_revoke() {
  [[ $# -eq 1 ]] || die "Использование: $0 revoke <имя>"
  local name=$1; valid_name "$name"; load_state
  [[ -f $EASYRSA_DIR/pki/issued/$name.crt ]] || die "Клиент '$name' не найден."
  (
    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa revoke "$name" >/dev/null 2>&1
    EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl >/dev/null 2>&1
  )
  cp "$EASYRSA_DIR/pki/crl.pem" "$OVPN_DIR/crl.pem"; chmod 644 "$OVPN_DIR/crl.pem"
  rm -f "$CCD_DIR/$name"
  rebuild_routes
  rm -rf "${OUT_DIR:?}/$name" "$OUT_DIR/$name.tar.gz"
  systemctl restart "$SERVICE"
  info "Клиент '$name' отозван."
}

cmd_list() {
  load_state
  echo "Сервер: $ENDPOINT:$PORT/$PROTO   VPN-сеть: $VPN_NET/24"
  echo
  echo "Клиенты:"
  local f name status
  for f in "$EASYRSA_DIR"/pki/issued/*.crt; do
    name=$(basename "$f" .crt); [[ $name == server ]] && continue
    status="клиент"
    [[ -f $CCD_DIR/$name ]] && status="роутер, LAN $(awk 'NR==1{print $2"/"$3}' "$CCD_DIR/$name")"
    if grep -q "^CLIENT_LIST,$name," /var/log/openvpn-status.log 2>/dev/null; then
      status+=", ${c_green}online${c_reset} ($(grep "^CLIENT_LIST,$name," /var/log/openvpn-status.log | cut -d, -f4))"
    fi
    echo "  - $name ($status)"
  done
}

cmd_uninstall() {
  read -r -p "Удалить OpenVPN-сервер, все сертификаты и конфиги? [y/N] " ans
  [[ $ans =~ ^[Yy]$ ]] || exit 0
  systemctl disable --now "$SERVICE" openvpn-rut-iptables.service 2>/dev/null || true
  rm -f /etc/systemd/system/openvpn-rut-iptables.service /etc/sysctl.d/99-openvpn-rut.conf
  systemctl daemon-reload
  rm -rf "$OVPN_DIR" "$EASYRSA_DIR"
  warn "Клиентские файлы оставлены в $OUT_DIR"
  info "Удалено."
}

main() {
  [[ $# -ge 1 ]] || usage 1
  local cmd=$1; shift
  case $cmd in
    -h|--help|help) usage 0;;
  esac
  need_root
  case $cmd in
    install)    cmd_install "$@";;
    add-router) cmd_add_router "$@";;
    add-client) cmd_add_client "$@";;
    revoke)     cmd_revoke "$@";;
    list)       cmd_list;;
    uninstall)  cmd_uninstall;;
    *) usage 1;;
  esac
}

main "$@"

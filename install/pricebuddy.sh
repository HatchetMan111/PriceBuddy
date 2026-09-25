#!/usr/bin/env bash
#
# PriceBuddy – Proxmox VE Community Scripts Stil
# ============================================================
# Erstellt einen unprivilegierten LXC-Container und installiert
# PriceBuddy (https://github.com/jez500/pricebuddy) nativ:
#   PHP 8.4 + Nginx + MariaDB, Web-UI auf Port 8080
#
# Einzeiler (auf dem Proxmox-Host als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PriceBuddy/main/install/pricebuddy.sh)"
#
# Getestet gegen: Proxmox VE 8.x, Debian 12 Template
# App: Laravel 12, PHP ^8.4, MySQL/MariaDB, Vite-Frontend
#
set -euo pipefail

# ---------------- Variablen (oben, Community-Scripts-konform) ----------------
APP="pricebuddy"
APP_NAME="PriceBuddy"
# WICHTIG: eigene Variable – $HOSTNAME ist auf dem Proxmox-Host bereits
# auf den Node-Namen gesetzt und darf nicht als CT-Name dienen.
CT_HOSTNAME="${CT_HOSTNAME:-pricebuddy}"
INSTALL_URL="https://raw.githubusercontent.com/HatchetMan111/PriceBuddy/main/install/pricebuddy.sh"
REPO_URL="https://github.com/jez500/pricebuddy.git"
REPO_BRANCH="main"
APP_DIR="/opt/pricebuddy"
WEB_PORT="8080"

# CT-Defaults (1–2 vCPU, 2 GB RAM, 8 GB Disk – LXC reicht, keine VM nötig)
CT_CORES="${CT_CORES:-2}"
CT_MEMORY="${CT_MEMORY:-2048}"
CT_SWAP="${CT_SWAP:-512}"
CT_DISK="${CT_DISK:-8}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-local}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_TEMPLATE="${CT_TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-1}"
CT_ONBOOT="${CT_ONBOOT:-1}"
CT_NESTING="${CT_NESTING:-1}"
CT_TIMEZONE="${CT_TIMEZONE:-Europe/Berlin}"

# DB-Defaults (lokal im LXC, produktionsnah wie docker-compose.yml)
DB_NAME="${DB_NAME:-pricebuddy}"
DB_USER="${DB_USER:-pricebuddy}"
DB_PASS="${DB_PASS:-$(openssl rand -hex 12 2>/dev/null || echo pric3buddy)}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

CTID="${CTID:-}"          # leer = nächste freie ID ab 100
DEBUG="${DEBUG:-0}"       # DEBUG=1 oder --debug für bash -x

# ---------------- Farben / Logging ----------------
YW=$(printf '\033[33m'); GN=$(printf '\033[1;92m'); RD=$(printf '\033[01;31m'); CL=$(printf '\033[m')
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"

msg_info()  { echo -e "${YW}  • $*${CL}"; }
msg_ok()    { echo -e "${CM}  $*"; }
msg_error() { echo -e "${CROSS}  $*" >&2; }

# Vollständige Fehlermeldungskette – niemals nur die letzte Zeile
error_trap() {
  local ec=$? cmd="${BASH_COMMAND:-?}" line="${BASH_LINENO[0]:-?}"
  msg_error "FEHLER: Befehl '${cmd}' scheiterte mit Exit-Code ${ec} (Zeile ${line})."
  echo "--- Kontext ---" >&2
  echo "APP=${APP} CTID=${CTID:-?} CT_HOSTNAME=${CT_HOSTNAME} TEMPLATE=${CT_TEMPLATE}" >&2
  echo "Bash-Version: ${BASH_VERSION}; Host: $(hostname 2>/dev/null || echo ?)" >&2
  echo "Letzte 30 Kernel-/Syslog-Zeilen (falls verfügbar):" >&2
  (dmesg 2>/dev/null | tail -n 30 || journalctl -n 30 --no-pager 2>/dev/null || echo "(kein Log verfügbar)") >&2
  echo "Tipp: Re-run mit Debugging:" >&2
  echo "  curl -fsSL ${INSTALL_URL} -o /tmp/pricebuddy-install.sh && bash -x /tmp/pricebuddy-install.sh" >&2
}
trap 'error_trap' ERR

usage() {
  cat <<EOF
${APP_NAME} Proxmox Installer (Community-Scripts-Stil)

Verwendung: $0 [--ctid N] [--hostname NAME] [--storage NAME] [--bridge vmbr0] [--debug]

Env-Overrides: CTID, CT_HOSTNAME, CT_STORAGE, CT_BRIDGE, CT_CORES, CT_MEMORY, CT_DISK,
  DB_NAME, DB_USER, DB_PASS, ADMIN_EMAIL, ADMIN_PASSWORD, DEBUG=1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="${2:?}"; shift 2;;
    --hostname) CT_HOSTNAME="${2:?}"; shift 2;;
    --storage) CT_STORAGE="${2:?}"; shift 2;;
    --bridge) CT_BRIDGE="${2:?}"; shift 2;;
    --debug|-x) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done
[[ "${DEBUG}" == "1" ]] && set -x

# ---------------- Pre-Checks (Proxmox-Host) ----------------
[[ $EUID -eq 0 ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pveam >/dev/null || { msg_error "pveam nicht gefunden."; exit 1; }
if command -v pveversion >/dev/null; then msg_info "$(pveversion | head -n1)"; fi

# Eine ID gilt als belegt, wenn ein LXC *oder* eine VM sie nutzt
# (pct status sieht nur Container – eine QEMU-VM mit gleicher ID
#  würde sonst erst bei pct create auffallen).
id_in_use() {
  local id="$1"
  pct status "$id" >/dev/null 2>&1 && return 0
  if command -v qm >/dev/null 2>&1; then
    qm status "$id" >/dev/null 2>&1 && return 0
  fi
  [[ -e "/etc/pve/lxc/${id}.conf" ]] && return 0
  [[ -e "/etc/pve/qemu-server/${id}.conf" ]] && return 0
  return 1
}
next_ctid() {
  local id
  for id in $(seq 100 999); do
    if ! id_in_use "$id"; then echo "$id"; return 0; fi
  done
  msg_error "Keine freie CT-ID zwischen 100–999 gefunden."; return 1
}
if [[ -z "${CTID}" ]]; then CTID="$(next_ctid)"; msg_info "Nächste freie CT-ID: ${CTID}"; fi
if id_in_use "${CTID}"; then msg_error "ID ${CTID} ist bereits belegt (LXC oder VM). Andere --ctid wählen."; exit 1; fi

msg_info "Stelle sicher, dass LXC-Template ${CT_TEMPLATE} vorhanden ist …"
if ! pveam list "${CT_TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${CT_TEMPLATE}"; then
  msg_info "Lade Template (pveam download) …"
  pveam update
  pveam download "${CT_TEMPLATE_STORAGE}" "${CT_TEMPLATE}"
fi
msg_ok "Template bereit."

# ---------------- Container erstellen ----------------
msg_info "Erstelle LXC ${CTID} (${CT_HOSTNAME}, ${CT_CORES} vCPU / ${CT_MEMORY} MB / ${CT_DISK} GB) …"
pct create "${CTID}" "${CT_TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE}" \
  --hostname "${CT_HOSTNAME}" \
  --cores "${CT_CORES}" --memory "${CT_MEMORY}" --swap "${CT_SWAP}" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
  --unprivileged "${CT_UNPRIVILEGED}" \
  --features "nesting=${CT_NESTING}" \
  --onboot "${CT_ONBOOT}" \
  --timezone "${CT_TIMEZONE}" \
  --start 0
msg_ok "Container erstellt."

pct set "${CTID}" --onboot 1
pct start "${CTID}"
msg_info "Warte auf Container-Boot …"
sleep 8
for i in $(seq 1 30); do pct exec "${CTID}" -- true 2>/dev/null && break; sleep 2; done
msg_ok "Container läuft."

# ---------------- Setup im Container ----------------
# Idempotenter Payload: kann erneut laufen (prüft vorhandene Installationen).
msg_info "Installiere ${APP_NAME} in CT ${CTID} (das dauert einige Minuten) …"
INNER_PAYLOAD="$(cat <<'INNER_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APP_DIR="/opt/pricebuddy"; WEB_PORT="8080"
DB_NAME="__DB_NAME__"; DB_USER="__DB_USER__"; DB_PASS="__DB_PASS__"
ADMIN_EMAIL="__ADMIN_EMAIL__"; ADMIN_PASSWORD="__ADMIN_PASSWORD__"
REPO_URL="https://github.com/jez500/pricebuddy.git"; REPO_BRANCH="main"

trap 'ec=$?; echo "[LXC-FEHLER] Exit ${ec} bei: ${BASH_COMMAND} (Zeile ${BASH_LINENO[0]:-?})" >&2; exit ${ec}' ERR

echo "==> [1/8] Basis + PHP 8.4 (Sury) + Nginx + MariaDB + Node 20"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl wget gnupg2 lsb-release \
  git unzip openssl netcat-openbsd sudo iproute2
# Sury PHP-Repo (Debian 12 hat nur PHP 8.2, PriceBuddy braucht ^8.4)
if [ ! -f /etc/apt/sources.list.d/php-sury.list ]; then
  curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/deb.sury.org-php.gpg
  echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/php-sury.list
fi
# NodeSource 20
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
fi
apt-get update
apt-get install -y --no-install-recommends \
  nginx mariadb-server \
  php8.4-fpm php8.4-cli php8.4-mysql php8.4-xml php8.4-mbstring php8.4-curl \
  php8.4-zip php8.4-gd php8.4-intl php8.4-bcmath php8.4-redis php8.4-sqlite3 \
  nodejs
# Composer (idempotent)
if ! command -v composer >/dev/null 2>&1; then
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi
composer --version

echo "==> [2/8] MariaDB starten + DB/User anlegen (idempotent)"
systemctl enable --now mariadb
sleep 3
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
mysql -u "${DB_USER}" -p"${DB_PASS}" -e "SELECT 1;" "${DB_NAME}"

echo "==> [3/8] App-Code holen (${REPO_URL}@${REPO_BRANCH})"
if [ -d "${APP_DIR}/.git" ]; then git -C "${APP_DIR}" fetch --all --prune; git -C "${APP_DIR}" checkout "${REPO_BRANCH}"; git -C "${APP_DIR}" pull --ff-only
elif [ -d "${APP_DIR}" ] && [ -n "$(ls -A ${APP_DIR} 2>/dev/null)" ] && [ ! -d "${APP_DIR}/.git" ]; then
  echo "WARN: ${APP_DIR} existiert ohne .git – lasse liegen (idempotent)."; else git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${APP_DIR}"; fi

echo "==> [4/8] PHP-Deps + Frontend-Build"
cd "${APP_DIR}"
mkdir -p storage/framework/sessions storage/framework/views storage/framework/testing storage/logs storage/app/public bootstrap/cache
composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
npm ci --no-audit --no-fund || npm install --no-audit --no-fund
npm run build

echo "==> [5/8] .env konfigurieren"
if [ ! -s .env ]; then cp .env.example .env 2>/dev/null || touch .env; fi
if ! grep -q "^APP_KEY=.\+" .env 2>/dev/null; then php artisan key:generate --force; fi
set_kv() { k="$1"; v="$2"; grep -qE "^${k}=" .env && sed -i "s|^${k}=.*|${k}=${v}|" .env || echo "${k}=${v}" >> .env; }
CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
set_kv APP_NAME '"PriceBuddy"'
set_kv APP_ENV production
set_kv APP_DEBUG false
set_kv APP_URL "http://${CT_IP:-localhost}:${WEB_PORT}"
set_kv DB_CONNECTION mysql
set_kv DB_HOST 127.0.0.1
set_kv DB_PORT 3306
set_kv DB_DATABASE "${DB_NAME}"
set_kv DB_USERNAME "${DB_USER}"
set_kv DB_PASSWORD "${DB_PASS}"
set_kv SESSION_DRIVER database
set_kv CACHE_STORE database
set_kv QUEUE_CONNECTION database
set_kv APP_USER_EMAIL "${ADMIN_EMAIL}"
set_kv APP_USER_PASSWORD "${ADMIN_PASSWORD}"
set_kv SCRAPER_BASE_URL ""
set_kv AFFILIATE_ENABLED false
php artisan config:clear

echo "==> [6/8] Migration + Seed (buddy:init-db)"
php artisan storage:link || true
until mysqladmin -h127.0.0.1 -u"${DB_USER}" -p"${DB_PASS}" ping --silent; do echo "DB wartet …"; sleep 2; done
php artisan buddy:init-db --force --no-interaction
php artisan optimize:clear || true
php artisan optimize || true

echo "==> [7/8] Nginx-VHost :${WEB_PORT} + Berechtigungen"
PHP_SOCK="$(ls /run/php/php8.4-fpm.sock 2>/dev/null || echo /run/php/php8.4-fpm.sock)"
cat > /etc/nginx/sites-available/pricebuddy <<NGINX
server {
    listen ${WEB_PORT} default_server;
    listen [::]:${WEB_PORT} default_server;
    server_name _;
    root ${APP_DIR}/public;
    index index.php index.html;
    client_max_body_size 50M;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }
    location ~ /\\.(?!well-known).* { deny all; }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pricebuddy /etc/nginx/sites-enabled/pricebuddy
nginx -t
chown -R www-data:www-data "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache" || true
chmod -R 775 "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache" || true
systemctl enable --now php8.4-fpm nginx
systemctl reload nginx || systemctl restart nginx

echo "==> [8/8] systemd: Queue-Worker + Scheduler (reboot-sicher)"
cat > /etc/systemd/system/pricebuddy-queue.service <<UNIT
[Unit]
Description=PriceBuddy Queue Worker
After=network-online.target mariadb.service
Wants=network-online.target
[Service]
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/php ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/pricebuddy-schedule.service <<UNIT2
[Unit]
Description=PriceBuddy Scheduler (run once)
After=network-online.target mariadb.service
Wants=network-online.target
[Service]
Type=oneshot
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/php ${APP_DIR}/artisan schedule:run
UNIT2
cat > /etc/systemd/system/pricebuddy-schedule.timer <<TIMER
[Unit]
Description=PriceBuddy Scheduler every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=pricebuddy-schedule.service
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now pricebuddy-queue.service
systemctl enable --now pricebuddy-schedule.timer
systemctl enable --now php8.4-fpm nginx mariadb || true

echo "==> Verifikation im Container"
systemctl is-active --quiet php8.4-fpm || { echo "php-fpm inaktiv"; journalctl -u php8.4-fpm --no-pager -n 50 >&2; exit 1; }
systemctl is-active --quiet nginx || { echo "nginx inaktiv"; journalctl -u nginx --no-pager -n 50 >&2; exit 1; }
systemctl is-active --quiet mariadb || { echo "mariadb inaktiv"; journalctl -u mariadb --no-pager -n 50 >&2; exit 1; }
systemctl is-active --quiet pricebuddy-queue || { echo "queue inaktiv"; journalctl -u pricebuddy-queue --no-pager -n 50 >&2; exit 1; }
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost:${WEB_PORT}/ || echo 000)"
echo "HTTP localhost:${WEB_PORT} -> ${CODE}"
case "${CODE}" in 200|301|302) echo "Web-UI antwortet.";; *) echo "Web-UI antwortet nicht (Code ${CODE})"; curl -sv --max-time 15 http://localhost:${WEB_PORT}/ >&2 || true; exit 1;; esac
echo "SETUP_OK"
INNER_EOF
)"
# Platzhalter mit den oben definierten Variablen füllen (Passwörter: alphanumerisch halten, sed-Sonderzeichen vermeiden)
INNER_PAYLOAD="$(printf '%s\n' "${INNER_PAYLOAD}" \
  | sed -e "s/__DB_NAME__/${DB_NAME}/g" \
        -e "s/__DB_USER__/${DB_USER}/g" \
        -e "s/__DB_PASS__/${DB_PASS}/g" \
        -e "s/__ADMIN_EMAIL__/${ADMIN_EMAIL}/g" \
        -e "s#__ADMIN_PASSWORD__#${ADMIN_PASSWORD}#g")"
printf '%s\n' "${INNER_PAYLOAD}" | pct exec "${CTID}" -- bash -s
msg_ok "Installation im Container abgeschlossen."

# ---------------- IP + Verifikation vom Host ----------------
msg_info "Ermittle Container-IP …"
CT_IP=""
for i in $(seq 1 30); do
  CT_IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "${CT_IP}" ]] && break
  sleep 2
done
[[ -n "${CT_IP}" ]] || { msg_error "Keine IP für CT ${CTID} gefunden (DHCP?). Prüfe: pct exec ${CTID} -- ip a"; exit 1; }

URL="http://${CT_IP}:${WEB_PORT}"
msg_info "HTTP-Check auf ${URL} …"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${URL}" || echo 000)"
if [[ "${HTTP_CODE}" =~ ^(200|301|302)$ ]]; then
  msg_ok "Web UI antwortet (HTTP ${HTTP_CODE})."
else
  msg_error "Web UI antwortet nicht (HTTP ${HTTP_CODE}). Diagnose im Container:"
  pct exec "${CTID}" -- bash -c "systemctl is-active nginx php8.4-fpm mariadb pricebuddy-queue; curl -sv --max-time 15 http://localhost:${WEB_PORT}/ || true" || true
  exit 1
fi

for svc in nginx php8.4-fpm mariadb pricebuddy-queue; do
  if pct exec "${CTID}" -- systemctl is-active --quiet "$svc"; then msg_ok "Service aktiv: $svc"; else msg_error "Service inaktiv: $svc"; fi
done

# ---------------- Finale Ausgabe ----------------
cat <<EOF

${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}
${GN}  ${APP_NAME} ist bereit!${CL}
${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}
  Web UI:      ${URL}
  Container:   CT ${CTID} (${CT_HOSTNAME}), onboot=1
  Login:       ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}
               (sofort ändern!)
  DB im LXC:   ${DB_NAME} / User ${DB_USER}
               Passwort: ${DB_PASS}

  Update im Container:
    pct enter ${CTID}
    cd ${APP_DIR} && git pull && composer install --no-dev && npm ci && npm run build \\
      && php artisan migrate --force && php artisan optimize

  Deinstallieren:
    pct stop ${CTID} && pct destroy ${CTID}

  Reboot-Test:
    pct reboot ${CTID}  # danach ${URL} erneut öffnen
EOF

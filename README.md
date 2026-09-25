# PriceBuddy auf Proxmox (Community-Scripts-Stil)

Unprivilegierter LXC mit nativer Installation (PHP 8.4 + Nginx + MariaDB).
Kein Docker-in-LXC nötig. Web-UI auf Port **8080**.

## Einzeiler (Proxmox-Host, als root)

> `HatchetMan111/PriceBuddy` – Script liegt in diesem Repo unter `install/pricebuddy.sh`:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PriceBuddy/main/install/pricebuddy.sh)"
```

Mit Optionen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PriceBuddy/main/install/pricebuddy.sh)" -- --ctid 150 --storage local-lvm --bridge vmbr0
# oder: CTID=150 DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PriceBuddy/main/install/pricebuddy.sh)"
```

Das Script:
- nimmt die nächste freie CT-ID (100–999) wenn keine angegeben,
- lädt ggf. das Debian-12-Template,
- erstellt LXC `pricebuddy` (2 vCPU / 2 GB RAM / 8 GB, `onboot: 1`),
- installiert alles im Container (idempotent, `set -euo pipefail`),
- gibt am Ende `http://[LXC-IP]:8080` aus und prüft Service + HTTP selbst.

Standard-Login: `admin@example.com` / `admin` – sofort ändern.
Per Env änderbar: `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `DB_PASS`.

## Was installiert wird (im LXC)

- PHP 8.4-FPM (Sury), Nginx auf `:8080`, MariaDB, Node 20, Composer
- App nach `/opt/pricebuddy` (Clone von `jez500/pricebuddy`)
- `composer install --no-dev`, `npm ci && npm run build`
- `.env` (MySQL localhost, `APP_URL=http://<CT-IP>:8080`), `artisan buddy:init-db`
- systemd: `pricebuddy-queue.service` + `pricebuddy-schedule.timer` (`enable`, `Restart=always`)
- Nginx-VHost + `php8.4-fpm`, `mariadb`, `nginx` auf `enable`

## Update

```bash
pct enter <CTID>
cd /opt/pricebuddy && git pull --ff-only \
  && composer install --no-dev --optimize-autoloader \
  && npm ci && npm run build \
  && php artisan buddy:init-db --force \
  && php artisan optimize \
  && systemctl restart pricebuddy-queue
```

## Deinstallieren

```bash
pct stop <CTID> && pct destroy <CTID>
```

## Reboot-Test

```bash
pct reboot <CTID>
# 1–2 Min warten, dann:
pct exec <CTID> -- systemctl is-active nginx php8.4-fpm mariadb pricebuddy-queue
curl -s -o /dev/null -w '%{http_code}\n' http://<LXC-IP>:8080
# Erwartet: 200/301/302 + http://<LXC-IP>:8080 im Browser
```

## Debugging

Bei Fehlern gibt das Script die komplette Kette aus (Befehl, Exit-Code, Zeile, Logs).
Mit Trace erneut laufen lassen:

```bash
bash -x install/pricebuddy.sh -- --ctid 150
# oder
DEBUG=1 bash install/pricebuddy.sh
```

Im Container nachschauen:

```bash
pct exec <CTID> -- journalctl -u pricebuddy-queue -n 100 --no-pager
pct exec <CTID> -- journalctl -u nginx -n 100 --no-pager
pct exec <CTID> -- curl -sv http://localhost:8080/
```

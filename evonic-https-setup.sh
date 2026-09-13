#!/usr/bin/env bash
# ============================================================================
#  evonic-https-setup.sh — pasang HTTPS + domain untuk dashboard Evonic
#  (nginx reverse proxy + Let's Encrypt). Dashboard jadi bisa diakses
#  https://domain-anda  TANPA port, cookie kembali Secure.
#
#  Pakai:
#    sudo evonic-https-setup.sh --domain evonic.example.com --email admin@example.com
#    sudo evonic-https-setup.sh --domain evonic.example.com --yes     (tanpa konfirmasi)
#
#  Opsi:
#    --domain <fqdn>     domain/subdomain (wajib)
#    --email <email>     email untuk Let's Encrypt (disarankan)
#    --port <n>          port dashboard lokal (default 8080)
#    --yes               jangan tanya konfirmasi
#    --force-dns         lanjut walau A record belum cocok dengan IP server
#    --no-certbot        hanya pasang reverse proxy (pakai cert sendiri)
#    --help
#
#  PRASYARAT: A record domain HARUS sudah mengarah ke IP publik VPS ini,
#  dan port 80 + 443 harus terbuka (Let's Encrypt verifikasi lewat port 80).
#  Bash >= 4.2
# ============================================================================
set -u -o pipefail

VERSION_HELPER="1.0.1"
PORT="${EVONIC_PORT:-8080}"
EVONIC_HOME="${EVONIC_HOME:-/opt/evonic}"
SERVICE_NAME="${EVONIC_SERVICE:-evonic}"
DOMAIN=""; EMAIL=""; ASSUME_YES=0; FORCE_DNS=0; USE_CERTBOT=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'; GRN=$'\033[38;5;42m'
  YLW=$'\033[38;5;220m'; RED=$'\033[38;5;203m'; CYN=$'\033[38;5;45m'; GRY=$'\033[38;5;245m'
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; GRY=""
fi
step() { printf "  ${CYN}▸${R} ${B}%s${R}\n" "$1"; }
ok()   { printf "    ${GRN}✓${R} %s\n" "$1"; }
warn() { printf "    ${YLW}!${R} %s\n" "$1"; }
bad()  { printf "    ${RED}✗${R} %s\n" "$1"; }
info() { printf "    ${GRY}·${R} %s\n" "$1"; }
kv()   { printf "    ${GRY}%-11s${R} %s\n" "$1" "$2"; }
die()  { printf "\n  ${RED}${B}✗ %s${R}\n\n" "$1" >&2; exit 1; }

usage() {
  printf "\n  ${B}evonic-https-setup.sh v%s${R}\n\n" "$VERSION_HELPER"
  printf "  Pasang HTTPS + domain untuk dashboard Evonic (nginx + Let's Encrypt).\n\n"
  printf "  Pakai:  sudo evonic-https-setup.sh --domain evonic.example.com --email you@example.com\n\n"
  printf "  Opsi: --domain <fqdn>  --email <email>  --port <n>  --yes  --force-dns  --no-certbot  --help\n\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) shift; DOMAIN="${1:-}" ;;
    --domain=*) DOMAIN="${1#*=}" ;;
    --email) shift; EMAIL="${1:-}" ;;
    --email=*) EMAIL="${1#*=}" ;;
    --port) shift; PORT="${1:-8080}" ;;
    --port=*) PORT="${1#*=}" ;;
    --yes|-y) ASSUME_YES=1 ;;
    --force-dns) FORCE_DNS=1 ;;
    --no-certbot) USE_CERTBOT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: $1  (pakai --help)" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root (sudo)."
[ -n "$DOMAIN" ] || die "Wajib: --domain <domain-atau-subdomain>"
DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##')
case "$DOMAIN" in *.*) ;; *) die "Domain tidak valid: $DOMAIN" ;; esac
command -v curl >/dev/null 2>&1 || die "curl belum terpasang"

printf "\n  ${B}${CYN}Evonic HTTPS setup${R} ${GRY}v%s${R}\n" "$VERSION_HELPER"

# ── 1. IP publik server ─────────────────────────────────────────────────────
step "[1/6] Deteksi IP publik server"
PUB=$(curl -s -m 8 ifconfig.me 2>/dev/null | tr -d ' \n')
[ -n "$PUB" ] || PUB=$(curl -s -m 8 https://api.ipify.org 2>/dev/null | tr -d ' \n')
[ -n "$PUB" ] || PUB=$(hostname -I 2>/dev/null | awk '{print $1}')
kv "IP server" "$PUB"

# ── 2. Verifikasi A record ──────────────────────────────────────────────────
step "[2/6] Verifikasi A record $DOMAIN"
RESOLVED=""
if command -v dig >/dev/null 2>&1; then
  RESOLVED=$(dig +short @1.1.1.1 A "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ')
elif command -v getent >/dev/null 2>&1; then
  RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
fi
RESOLVED=$(printf '%s' "$RESOLVED" | xargs 2>/dev/null || printf '%s' "$RESOLVED")
info "DNS publik: ${RESOLVED:-<tidak ada A record>}"

if [ -z "$RESOLVED" ]; then
  bad "Domain belum punya A record."
  printf "\n  ${YLW}${B}  Tambahkan dulu di DNS management domainmu:${R}\n"
  kv "Type" "A"
  kv "Name" "$(printf '%s' "$DOMAIN" | cut -d. -f1)"
  kv "Value" "$PUB"
  kv "TTL" "14400 (default)"
  printf "  ${GRY}  Setelah propagasi (biasanya 5-30 menit), jalankan ulang perintah ini.${R}\n\n"
  [ "$FORCE_DNS" -eq 1 ] || exit 1
elif ! printf '%s' "$RESOLVED" | tr ' ' '\n' | grep -qx "$PUB"; then
  bad "A record $DOMAIN → $RESOLVED, bukan IP server ini ($PUB)."
  printf "  ${GRY}  Perbaiki A record dulu, atau pakai --force-dns kalau IP-nya di belakang proxy/CDN.${R}\n\n"
  [ "$FORCE_DNS" -eq 1 ] || exit 1
else
  ok "A record cocok dengan IP server ($PUB)"
fi

# ── 3. Port 80/443 ──────────────────────────────────────────────────────────
step "[3/6] Cek port 80 & 443 terbuka dari internet"
if [ "$USE_CERTBOT" -eq 1 ]; then
  for p in 80 443; do
    if ss -tlnH "sport = :$p" 2>/dev/null | grep -q . || ! ss -tln >/dev/null 2>&1; then
      info "port $p: tidak ada listener lokal (akan dibuka oleh nginx)"
    fi
  done
  warn "Pastikan firewall/security group VPS membuka port 80 & 443, jika tidak Let's Encrypt akan gagal"
fi

# ── 4. Install nginx + certbot ──────────────────────────────────────────────
step "[4/6] Siapkan nginx"
APT_LOG=/tmp/evonic_apt.log
# Deteksi IPv6: banyak VPS (termasuk IDCloudHost) IPv6-nya nonaktif, sementara
# nginx.conf bawaan Ubuntu listen di [::]:80 → service gagal start
# ("socket() [::]:80 failed (97: Address family not supported by protocol)").
IPV6_OK=0
if [ -s /proc/net/if_inet6 ]; then IPV6_OK=1; fi
if command -v ip >/dev/null 2>&1; then ip -6 route show 2>/dev/null | grep -q . && IPV6_OK=1; fi
[ "$IPV6_OK" -eq 0 ] && info "IPv6 tidak tersedia di VPS ini — listen [::] akan dinonaktifkan"

if ! command -v nginx >/dev/null 2>&1; then
  info "install nginx..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >"$APT_LOG" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >>"$APT_LOG" 2>&1 || true
fi

# netralkan listen [::] bawaan sebelum dpkg mencoba start service
if [ "$IPV6_OK" -eq 0 ] && [ -f /etc/nginx/nginx.conf ]; then
  if grep -qE '^[[:space:]]*listen[[:space:]]+\[::\]' /etc/nginx/nginx.conf; then
    sed -i -E 's|^([[:space:]]*)(listen[[:space:]]+\[::\][^;]*;)|\1# \2  # IPv6 tidak tersedia|' /etc/nginx/nginx.conf
    ok "listen [::] di nginx.conf dinonaktifkan"
  fi
fi
# selesaikan paket yang tertinggal setengah terpasang (percobaan gagal sebelumnya)
DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$APT_LOG" 2>&1 || true

if ! command -v nginx >/dev/null 2>&1; then
  tail -8 "$APT_LOG" | sed 's/^/      /'
  die "gagal install nginx — detail: $APT_LOG"
fi
# kalau masih gagal start, bersihkan listen [::] di vhost yang aktif lalu coba lagi
if ! systemctl start nginx 2>/dev/null; then
  for f in /etc/nginx/sites-enabled/*; do
    [ -f "$f" ] || continue
    grep -qE 'listen[[:space:]]+\[::\]' "$f" 2>/dev/null && \
      sed -i -E 's|^([[:space:]]*)(listen[[:space:]]+\[::\][^;]*;)|\1# \2|' "$f"
  done
  systemctl start nginx 2>/dev/null || true
fi
systemctl is-active nginx >/dev/null 2>&1 \
  && ok "nginx $(nginx -v 2>&1 | sed 's#nginx version: ##') aktif" \
  || warn "nginx belum aktif — cek: journalctl -u nginx -n 20"
if [ "$USE_CERTBOT" -eq 1 ] && ! command -v certbot >/dev/null 2>&1; then
  info "install certbot..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx >>"$APT_LOG" 2>&1 \
    || warn "certbot gagal diinstall — lanjut tanpa sertifikat otomatis"
fi

CONF="/etc/nginx/sites-available/evonic-${DOMAIN}.conf"
step "[5/6] Tulis reverse proxy $DOMAIN → 127.0.0.1:$PORT"
LISTEN6=""
[ "$IPV6_OK" -eq 1 ] && LISTEN6="    listen [::]:80;"
cat > "$CONF" <<NGINX
# Evonic dashboard — dibuat oleh evonic-https-setup.sh
server {
    listen 80;
${LISTEN6}
    server_name ${DOMAIN};

    client_max_body_size 200m;
    access_log /var/log/nginx/evonic-${DOMAIN}.access.log;
    error_log  /var/log/nginx/evonic-${DOMAIN}.error.log;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;

        # SSE / streaming (log viewer, progress agen) — jangan di-buffer
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        chunked_transfer_encoding on;
        add_header X-Accel-Buffering no;
    }
}
NGINX
ln -sf "$CONF" /etc/nginx/sites-enabled/"evonic-${DOMAIN}.conf"
[ -e /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
if nginx -t >/tmp/evonic_nginx_test.log 2>&1; then
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  ok "nginx aktif, vhost: $CONF"
else
  tail -5 /tmp/evonic_nginx_test.log >&2
  rm -f /etc/nginx/sites-enabled/"evonic-${DOMAIN}.conf"
  die "konfigurasi nginx tidak valid — vhost dibatalkan"
fi

# ── 6. Sertifikat Let's Encrypt ─────────────────────────────────────────────
step "[6/6] Sertifikat HTTPS"
CERT_OK=0
if [ "$USE_CERTBOT" -eq 1 ] && command -v certbot >/dev/null 2>&1; then
  CB_ARGS=(--nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect --keep-until-expiring)
  if [ -n "$EMAIL" ]; then CB_ARGS+=(-m "$EMAIL"); else CB_ARGS+=(--register-unsafely-without-email); fi
  if certbot "${CB_ARGS[@]}" >/tmp/evonic_certbot.log 2>&1; then
    ok "sertifikat terpasang (auto-renew via systemd timer)"
    CERT_OK=1
  else
    warn "certbot gagal — cek /tmp/evonic_certbot.log"
    tail -6 /tmp/evonic_certbot.log | sed 's/^/      /'
    info "penyebab umum: port 80 terblokir firewall, atau A record belum propagasi"
  fi
else
  warn "certbot dilewati — dashboard tetap di HTTP sampai sertifikat dipasang manual"
fi

# ── Cookie mode + restart ───────────────────────────────────────────────────
if [ "$CERT_OK" -eq 1 ]; then
  ENVF="$EVONIC_HOME/.env"
  if [ -f "$ENVF" ]; then
    if grep -q '^FORCE_INSECURE_COOKIES=' "$ENVF"; then
      sed -i 's/^FORCE_INSECURE_COOKIES=.*/FORCE_INSECURE_COOKIES=0/' "$ENVF"
    else
      echo 'FORCE_INSECURE_COOKIES=0' >> "$ENVF"
    fi
    chown "${SERVICE_NAME}:${SERVICE_NAME}" "$ENVF" 2>/dev/null || true
    ok "cookie kembali Secure (FORCE_INSECURE_COOKIES=0)"
  fi
fi
systemctl restart "$SERVICE_NAME" 2>/dev/null || true
sleep 4
# pastikan X-Forwarded-Proto diteruskan (ProxyFix di app.py)

printf "\n"
if [ "$CERT_OK" -eq 1 ]; then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 12 "https://${DOMAIN}/login" 2>/dev/null || echo 000)
  printf "  ${GRN}${B}╭────────────────────────────────────────────────────────────╮${R}\n"
  printf "  ${GRN}${B}│  ✓ Dashboard Evonic kini di HTTPS, tanpa port              │${R}\n"
  printf "  ${GRN}${B}╰────────────────────────────────────────────────────────────╯${R}\n\n"
  kv "URL baru"   "https://${DOMAIN}   (HTTP ${CODE})"
  kv "redirect"   "http://${DOMAIN} → https://${DOMAIN}"
  kv "cookie"     "Secure aktif (aman)"
  kv "renew"      "otomatis 60 hari sebelum kedaluwarsa"
  printf "\n  ${GRY}  Port 8080 masih terbuka lokal/direct — bisa ditutup dari security group setelah HTTPS jalan.${R}\n"
  printf "  ${GRY}  Relay Evonet tetap di port 8081 (jangan ditutup kalau pakai Tunnel Workplace).${R}\n\n"
else
  printf "  ${YLW}${B}Reverse proxy terpasang, tapi belum HTTPS (sertifikat belum ada).${R}\n"
  kv "URL" "http://${DOMAIN} (proxy) / http://$(hostname -I | awk '{print $1}'):${PORT}"
  printf "\n"
fi
exit 0

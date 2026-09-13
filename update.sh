#!/usr/bin/env bash
# ============================================================================
#  Evonic Updater — one-command updater untuk instalasi Evonic
#  Repo: https://github.com/ujang0311/evonic
#
#  Pakai:
#    curl -sS https://raw.githubusercontent.com/ujang0311/evonic/main/update.sh | bash
#
#  Opsi:
#    bash update.sh --check            cek versi saja, tidak mengubah apa pun
#    bash update.sh --dry-run          lihat apa yang akan berubah + list file lokal yang dimodifikasi
#    bash update.sh --tag v1.2.0       paksa update/rollback ke tag tertentu
#    bash update.sh --force            jalankan walau sudah versi terbaru
#    bash update.sh --no-backup        lewati backup (tidak disarankan)
#    bash update.sh --http-only        akses lewat http://IP:8080 (csrf/cookie disesuaikan)
#    bash update.sh --https --domain d --email e   langsung pasang HTTPS + domain
#    bash update.sh --no-prompt        lewati tanya HTTP/HTTPS di akhir update
#    bash update.sh --quiet            output ringkas
#    bash update.sh --help
#
#  Bash >= 4.2
# ============================================================================

set -u -o pipefail

VERSION_SCRIPT="1.1.0"
SELF_URL="${EVONIC_UPDATE_URL:-https://raw.githubusercontent.com/ujang0311/evonic/main/update.sh}"
BASE_URL="${SELF_URL%/*}"
REPO_URL="${EVONIC_REPO_URL:-https://github.com/anvie/evonic.git}"
EVONIC_HOME="${EVONIC_HOME:-/opt/evonic}"
BACKUP_ROOT="${EVONIC_BACKUP_DIR:-/var/backups/evonic}"
SERVICE_NAME="${EVONIC_SERVICE:-evonic}"
DASH_PORT="${EVONIC_PORT:-8080}"

CHECK_ONLY=0; DRY_RUN=0; FORCE=0; DO_BACKUP=1; QUIET=0; TARGET_TAG=""
RESTORE_MODIFIED=0
MODE_HTTP_ONLY=0; MODE_HTTPS=0; NO_PROMPT=0; HTTPS_DOMAIN=""; HTTPS_EMAIL=""

# ── Wajib root — CEK DI SINI, sebelum argumen diparsing ────────────────────
# (kalau dipindah ke bawah, $@ sudah habis di-shift oleh loop parsing dan
#  re-exec sudo akan kehilangan opsi seperti --check / --dry-run)
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    printf "  Butuh root — mengulang lewat sudo...\n"
    if [ $# -gt 0 ]; then
      exec sudo -E bash -c "curl -sS '$SELF_URL' | bash -s -- $(printf '%q ' "$@")"
    else
      exec sudo -E bash -c "curl -sS '$SELF_URL' | bash"
    fi
  fi
  printf "\n  ✗ Jalankan sebagai root:  curl -sS %s | sudo bash\n\n" "$SELF_URL" >&2
  exit 1
fi

# ── Output helpers ──────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[38;5;42m'; YLW=$'\033[38;5;220m'; RED=$'\033[38;5;203m'
  CYN=$'\033[38;5;45m'; PRP=$'\033[38;5;141m'; GRY=$'\033[38;5;245m'
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; PRP=""; GRY=""
fi

W=64
rule()  { printf "${GRY}%s${R}\n" "$(printf '─%.0s' $(seq 1 $W))"; }
# padding manual: printf "%-*s" menghitung byte, karakter multibyte (✓ ╭ ★) merusak lebar kotak
boxline() {
  local txt="$1" pad
  pad=$(( W - 6 - ${#txt} ))
  [ "$pad" -lt 1 ] && pad=1
  printf "${HDR:-$PRP}${B}  │${R}  ${B}%s${R}%*s${HDR:-$PRP}${B}│${R}\n" "$txt" "$pad" ""
}
title() {
  printf "\n${PRP}${B}  ╭%s╮${R}\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"
  HDR="$PRP" boxline "$1"
  printf "${PRP}${B}  ╰%s╯${R}\n\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"
}
step()  { printf "  ${CYN}▸${R} ${B}%s${R}\n" "$1"; }
ok()    { printf "    ${GRN}✓${R} %s\n" "$1"; }
warn()  { printf "    ${YLW}!${R} %s\n" "$1"; }
bad()   { printf "    ${RED}✗${R} %s\n" "$1"; }
info()  { printf "    ${GRY}·${R} %s\n" "$1"; }
die()   { printf "\n  ${RED}${B}✗ %s${R}\n\n" "$1" >&2; exit 1; }
kv()    { printf "    ${GRY}%-12s${R} %s\n" "$1" "$2"; }

T_START=$(date +%s)
elapsed() { local e=$(( $(date +%s) - T_START )); printf "%dm%02ds" $((e/60)) $((e%60)); }

on_signal() { printf "\n  ${RED}${B}✗ Dibatalkan${R}\n\n"; exit 130; }
trap on_signal INT TERM

usage() {
  title "Evonic Updater v$VERSION_SCRIPT"
  cat <<EOF
  Update instalasi Evonic ke rilis stabil terbaru (mode git, aman untuk
  instalasi App Catalog yang belum punya .git).

  Pakai:
    curl -sS $SELF_URL | bash

  Opsi:
    --check           cek versi lokal vs terbaru, lalu keluar
    --dry-run         tampilkan rencana + file yang dimodifikasi lokal
    --tag <vX.Y.Z>    update / rollback ke tag tertentu
    --force           jalankan walau sudah versi terbaru
    --restore-modified  kembalikan file tracked yang kamu modifikasi
    --no-backup       lewati backup (tidak disarankan)
    --quiet           output ringkas
    -h, --help        bantuan ini

  Env:
    EVONIC_HOME         default /opt/evonic
    EVONIC_REPO_URL     default https://github.com/anvie/evonic.git
    EVONIC_BACKUP_DIR   default /var/backups/evonic
    EVONIC_SERVICE      default evonic
    EVONIC_PORT         default 8080
    NOTIFY_TELEGRAM_TOKEN + NOTIFY_TELEGRAM_CHAT   kirim notif hasil update
EOF
  printf "\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --dry-run|--dry) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --no-backup) DO_BACKUP=0 ;;
    --restore-modified) RESTORE_MODIFIED=1 ;;
    --http-only) MODE_HTTP_ONLY=1 ;;
    --https) MODE_HTTPS=1 ;;
    --no-prompt) NO_PROMPT=1 ;;
    --domain) shift; HTTPS_DOMAIN="${1:-}" ;;
    --domain=*) HTTPS_DOMAIN="${1#*=}" ;;
    --email) shift; HTTPS_EMAIL="${1:-}" ;;
    --email=*) HTTPS_EMAIL="${1#*=}" ;;
    --quiet|-q) QUIET=1 ;;
    --tag) shift; TARGET_TAG="${1:-}"; [ -n "$TARGET_TAG" ] || die "--tag butuh nilai, contoh: --tag v1.2.0" ;;
    --tag=*) TARGET_TAG="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: $1  (pakai --help)" ;;
  esac
  shift
done

# ── Prasyarat ───────────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || die "git belum terpasang (apt install git)"
command -v curl >/dev/null 2>&1 || die "curl belum terpasang (apt install curl)"

[ -d "$EVONIC_HOME" ] || die "Direktori Evonic tidak ditemukan: $EVONIC_HOME (set EVONIC_HOME=...)"

# deteksi folder yang benar kalau default tidak dipakai template
if [ ! -f "$EVONIC_HOME/cli.py" ] && [ ! -f "$EVONIC_HOME/app.py" ]; then
  for cand in /opt/evonic /usr/local/evonic /srv/evonic "$HOME/evonic"; do
    if [ -f "$cand/app.py" ]; then EVONIC_HOME="$cand"; break; fi
  done
fi

SVC_USER=$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)
[ -n "$SVC_USER" ] || SVC_USER="evonic"
id "$SVC_USER" >/dev/null 2>&1 || SVC_USER="root"

export GIT_TERMINAL_PROMPT=0
git config --global --get-all safe.directory 2>/dev/null | grep -qx "$EVONIC_HOME" \
  || git config --global --add safe.directory "$EVONIC_HOME" 2>/dev/null || true
git config --global --get-all safe.directory 2>/dev/null | grep -qx "*" \
  || true

run_as_svc() { # jalankan perintah git sebagai user service supaya ownership file tetap konsisten
  if [ "$SVC_USER" = "root" ]; then bash -c "$*"; else runuser -u "$SVC_USER" -- bash -c "$*"; fi
}
g() { run_as_svc "cd '$EVONIC_HOME' && git $*"; }

notify_telegram() { # $1 = judul, $2 = isi
  [ -n "${NOTIFY_TELEGRAM_TOKEN:-}" ] && [ -n "${NOTIFY_TELEGRAM_CHAT:-}" ] || return 0
  curl -sS -m 15 "https://api.telegram.org/bot${NOTIFY_TELEGRAM_TOKEN}/sendMessage" \
    -d "chat_id=${NOTIFY_TELEGRAM_CHAT}" -d "parse_mode=HTML" \
    -d "text=<b>$1</b>%0A$2" >/dev/null 2>&1 || true
}

# baca input dari terminal — penting karena `curl | bash` memakai stdin untuk script
have_tty() { { exec 9</dev/tty; } 2>/dev/null && { exec 9<&-; return 0; }; return 1; }

ask() { # $1 prompt, $2 default
  local prompt="$1" def="${2:-}" ans=""
  printf "%s" "$prompt"
  if have_tty; then IFS= read -r ans < /dev/tty 2>/dev/null || ans=""; fi
  printf "\n"
  [ -n "$ans" ] || ans="$def"
  printf '%s' "$ans"
}

# pasang/segarkan helper dari repo (BASE_URL diturunkan dari SELF_URL)
fetch_helper() { # $1 nama file, $2 tujuan
  local name="$1" dest="$2"
  if [ -s "$dest" ] && [ "${REFRESH_HELPERS:-1}" -eq 0 ]; then return 0; fi
  if curl -fsS -m 30 "$BASE_URL/$name" -o "$dest.tmp" 2>/dev/null && [ -s "$dest.tmp" ]; then
    mv "$dest.tmp" "$dest"; chmod 755 "$dest"; return 0
  fi
  rm -f "$dest.tmp" 2>/dev/null
  [ -x "$dest" ] && return 0
  return 1
}

# mode cookie: HTTPS aktif → Secure; HTTP saja → cookie non-Secure supaya login jalan
ensure_cookie_mode() { # $1 = https|http
  local want="$1" val="1" f="$EVONIC_HOME/.env"
  [ "$want" = "https" ] && val="0"
  [ -f "$f" ] || return 0
  if grep -q '^FORCE_INSECURE_COOKIES=' "$f"; then
    cur=$(grep '^FORCE_INSECURE_COOKIES=' "$f" | head -1 | cut -d= -f2)
    if [ "$cur" = "$val" ]; then set_env_cookie_note="sudah"; return 0; fi
    sed -i "s/^FORCE_INSECURE_COOKIES=.*/FORCE_INSECURE_COOKIES=$val/" "$f"
  else
    echo "FORCE_INSECURE_COOKIES=$val" >> "$f"
  fi
  chown "$SVC_USER:$SVC_USER" "$f" 2>/dev/null || true
  set_env_cookie_note="diubah"
}

# apakah sudah ada vhost HTTPS yang mem-proxy port dashboard?
https_configured() {
  [ -d /etc/nginx/sites-enabled ] || return 1
  grep -rls "proxy_pass http://127.0.0.1:$DASH_PORT" /etc/nginx/sites-enabled/ 2>/dev/null | while read -r c; do
    grep -q "ssl_certificate" "$c" && echo yes
  done | grep -q yes
}

# nama domain dari vhost HTTPS yang aktif (untuk ditampilkan di ringkasan)
https_domain() {
  grep -rls "proxy_pass http://127.0.0.1:$DASH_PORT" /etc/nginx/sites-enabled/ 2>/dev/null \
    | xargs -r grep -h "server_name" 2>/dev/null | awk '{print $2}' | tr -d ';' | grep -v '_' | head -1
}

# ── Mulai ───────────────────────────────────────────────────────────────────
[ "$QUIET" -eq 1 ] || title "Evonic Updater v$VERSION_SCRIPT"
[ "$QUIET" -eq 1 ] || { info "host      $(hostname)"; info "home      $EVONIC_HOME"; }

S_VERSION_FILE="$EVONIC_HOME/VERSION"
OLD_VERSION=$( [ -f "$S_VERSION_FILE" ] && cat "$S_VERSION_FILE" || echo "unknown" )
WAS_GIT=0
[ -d "$EVONIC_HOME/.git" ] && WAS_GIT=1

# ── [1/8] Cek jaringan + tag terbaru ────────────────────────────────────────
step "[1/8] Cek rilis terbaru di GitHub"
LATEST_TAG=$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null \
  | sed 's|.*refs/tags/||' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V | tail -1)
[ -n "$LATEST_TAG" ] || die "Tidak bisa membaca tag rilis dari $REPO_URL (cek koneksi internet server)"
[ -n "$TARGET_TAG" ] && LATEST_TAG="$TARGET_TAG"
ok "target rilis: ${B}$LATEST_TAG${R}"
kv "versi lokal" "$OLD_VERSION"
[ "$WAS_GIT" -eq 1 ] && kv "mode" "git repo" || kv "mode" "non-git (App Catalog) → akan dikonversi"

if [ "$CHECK_ONLY" -eq 1 ]; then
  printf "\n"
  if [ "$OLD_VERSION" = "${LATEST_TAG#v}" ]; then
    printf "  ${GRN}${B}✓ Sudah versi terbaru ($LATEST_TAG)${R}\n\n"
  else
    printf "  ${YLW}${B}↑ Update tersedia: $OLD_VERSION → ${LATEST_TAG#v}${R}\n"
    printf "  ${GRY}  Jalankan tanpa --check untuk update.${R}\n\n"
  fi
  exit 0
fi

if [ "$OLD_VERSION" = "${LATEST_TAG#v}" ] && [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$WAS_GIT" -eq 1 ]; then
  printf "\n  ${GRN}${B}✓ Sudah di versi terbaru ($LATEST_TAG) — tidak ada yang perlu diupdate.${R}\n"
  printf "  ${GRY}  Pakai --force kalau ingin memaksa pasang ulang.${R}\n\n"
  exit 0
fi
if [ "$WAS_GIT" -eq 0 ] && [ "$OLD_VERSION" = "${LATEST_TAG#v}" ]; then
  info "versi kode sudah terbaru, tapi repo git belum ada → repo akan disiapkan"
fi

# ── [2/8] Backup ────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
BK="$BACKUP_ROOT/update_$TS"
SKILL_CFG="$EVONIC_HOME/skills/config.json"

if [ "$DO_BACKUP" -eq 1 ]; then
  step "[2/8] Backup data & konfigurasi"
  mkdir -p "$BK/keep" "$BK/modified"
  chmod 700 "$BK" 2>/dev/null || true

  # config runtime (semua untracked → tidak akan disentuh checkout, tapi tetap diamankan)
  for p in .env skills/config.json; do
    [ -e "$EVONIC_HOME/$p" ] && cp -a "$EVONIC_HOME/$p" "$BK/keep/$(basename "$p")" 2>/dev/null && ok "config  $p"
  done

  # snapshot kode + data penting supaya bisa rollback penuh
  # (--warning=no-file-changed: log service yang aktif berubah saat dibaca → bukan kegagalan nyata)
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: snapshot penuh dilewati"
  else
    tar czf "$BK/evonic-full.tar.gz" -C "$(dirname "$EVONIC_HOME")" "$(basename "$EVONIC_HOME")" \
        --exclude='.venv' --exclude='.git' --exclude='__pycache__' \
        --warning=no-file-changed --ignore-failed-read 2>/tmp/evonic_tar.log
    if [ -s "$BK/evonic-full.tar.gz" ] && tar tzf "$BK/evonic-full.tar.gz" >/dev/null 2>&1; then
      ok "snapshot  $BK/evonic-full.tar.gz ($(du -h "$BK/evonic-full.tar.gz" | cut -f1))"
    else
      warn "snapshot gagal — cek /tmp/evonic_tar.log (lanjut tanpa snapshot penuh)"
    fi
  fi
  kv "lokasi" "$BK"
else
  step "[2/8] Backup dilewati (--no-backup)"
fi

# ── [3/8] Siapkan git repo (konversi kalau perlu) ───────────────────────────
step "[3/8] Siapkan repository git"
if [ "$WAS_GIT" -eq 0 ]; then
  g "init -q" || die "git init gagal di $EVONIC_HOME"
  g "remote add origin $REPO_URL" 2>/dev/null || g "remote set-url origin $REPO_URL"
  ok "git repo dibuat (instalasi lama tanpa .git)"
else
  g "remote set-url origin $REPO_URL" 2>/dev/null || true
fi
# pastikan remote fetch menangkap branch + tag (tanpa duplikat refspec)
g "config --replace-all remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'" 2>/dev/null || true
g "config --get-all remote.origin.fetch" 2>/dev/null | grep -q 'refs/tags' \
  || g "config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'" 2>/dev/null || true
if g "fetch --tags --force origin" >/tmp/evonic_fetch.log 2>&1; then
  ok "fetch tags OK ($(g 'tag -l' | wc -l) tag)"
else
  tail -5 /tmp/evonic_fetch.log >&2
  die "git fetch gagal — cek koneksi/GitHub access dari server"
fi

CUR_TAG=$(g "describe --tags --abbrev=0" 2>/dev/null || echo "")
if [ -z "$CUR_TAG" ]; then
  CUR_TAG=$(g "tag -l" 2>/dev/null | grep -x "v$OLD_VERSION" || true)
fi

# ── [4/8] Deteksi modifikasi lokal pada file tracked ───────────────────────
step "[4/8] Periksa modifikasi lokal (file yang akan ditimpa checkout)"
MODLIST="$BK/modified/modified.txt"
MODLIST_RAW="${MODLIST%.txt}.raw.txt"
: > "$MODLIST_RAW" 2>/dev/null || { MODLIST=/tmp/evonic_modified.txt; MODLIST_RAW=/tmp/evonic_modified.raw.txt; }
# artefak yang rutin di-rebuild/dinormalisasi app sendiri → bukan modifikasi user, jangan bikin panik
NOISE_RE='^(skills/config\.json|static/js/chat-ui\.js|static/css/(evonic|tailwind)\.css|backend/promptpurify/.*\.onnx|backend/tools/runpy_helpers/bin/rg|\.githooks/.*|install\.sh)$'
MODIFIED_COUNT=0
SKIPPED_NOISE=0
if [ -n "$CUR_TAG" ]; then
  run_as_svc "cd '$EVONIC_HOME' && git ls-tree -r '$CUR_TAG' | while read m t sha p; do
      [ \"\$t\" = blob ] || continue
      if [ ! -f \"\$p\" ]; then echo \"MISSING \$p\";
      else [ \"\$(git hash-object \"\$p\" 2>/dev/null)\" = \"\$sha\" ] || echo \"MODIFIED \$p\"; fi
    done" > "$MODLIST_RAW" 2>/dev/null || true
  awk -v re="$NOISE_RE" '{ p=$2; if (p !~ re) print }' "$MODLIST_RAW" > "$MODLIST" 2>/dev/null || : > "$MODLIST"
  MODIFIED_COUNT=$(grep -c '^MODIFIED' "$MODLIST" 2>/dev/null)
  case "$MODIFIED_COUNT" in ''|*[!0-9]*) MODIFIED_COUNT=0 ;; esac
  NOISE_ONLY=$(grep -c '^MODIFIED' "$MODLIST_RAW" 2>/dev/null)
  case "$NOISE_ONLY" in ''|*[!0-9]*) NOISE_ONLY=0 ;; esac
  SKIPPED_NOISE=$(( NOISE_ONLY - MODIFIED_COUNT ))
  [ "$SKIPPED_NOISE" -lt 0 ] && SKIPPED_NOISE=0
  while read -r kind p; do
    [ "$kind" = "MODIFIED" ] || continue
    mkdir -p "$BK/modified/$(dirname "$p")" 2>/dev/null
    cp -a "$EVONIC_HOME/$p" "$BK/modified/$p" 2>/dev/null || true
    run_as_svc "cd '$EVONIC_HOME' && git show '$CUR_TAG:$p'" > /tmp/evonic_orig.tmp 2>/dev/null || true
    diff -u /tmp/evonic_orig.tmp "$EVONIC_HOME/$p" >> "$BK/modified/modified.patch" 2>/dev/null || true
  done < "$MODLIST"
  if [ "$MODIFIED_COUNT" -gt 0 ]; then
    warn "$MODIFIED_COUNT file lokal berbeda dari $CUR_TAG (disalin ke backup)"
    head -12 "$MODLIST" | sed 's/^/      /'
    [ "$MODIFIED_COUNT" -gt 12 ] && info "... dan $((MODIFIED_COUNT-12)) lainnya — lihat $MODLIST"
    [ "$RESTORE_MODIFIED" -eq 1 ] && info "akan dikembalikan setelah update (--restore-modified)"
  else
    ok "tidak ada modifikasi lokal — instalasi bersih (aman)"
  fi
  [ "${SKIPPED_NOISE:-0}" -gt 0 ] 2>/dev/null && info "$SKIPPED_NOISE artefak build/config internal diabaikan (config skill tetap diamankan + dipulihkan)"
else
  warn "tag versi lokal tidak dikenali — lewati pemeriksaan"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf "\n  ${CYN}${B}DRY-RUN — tidak ada perubahan yang diterapkan.${R}\n"
  kv "update" "$OLD_VERSION → ${LATEST_TAG#v} ($LATEST_TAG)"
  kv "yang di-restore" "skills/config.json"
  kv "backup" "$BK"
  printf "\n"
  exit 0
fi

# ── [5/8] Hentikan service + checkout tag ──────────────────────────────────
step "[5/8] Hentikan service & pasang $LATEST_TAG"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
ok "service dihentikan"

if ! g "checkout -f '$LATEST_TAG'" >/tmp/evonic_checkout.log 2>&1; then
  tail -8 /tmp/evonic_checkout.log >&2
  bad "checkout gagal — mengembalikan backup"
  if [ -f "$BK/evonic-full.tar.gz" ]; then
    tar xzf "$BK/evonic-full.tar.gz" -C "$(dirname "$EVONIC_HOME")" && ok "backup dipulihkan"
  fi
  systemctl start "$SERVICE_NAME" 2>/dev/null || true
  notify_telegram "Evonic update GAGAL" "rollback otomatis dijalankan pada $(hostname)"
  die "Update gagal. Versi lama sudah dipulihkan."
fi
NEW_VERSION=$( [ -f "$S_VERSION_FILE" ] && cat "$S_VERSION_FILE" || echo "${LATEST_TAG#v}" )
ok "kode dipasang: ${B}$OLD_VERSION → $NEW_VERSION${R}"

# restore config penting yang tracked & ikut tertimpa checkout
if [ -f "$BK/keep/config.json" ]; then
  if [ "$(cat "$BK/keep/config.json")" != "$(cat "$SKILL_CFG" 2>/dev/null)" ]; then
    cp -a "$BK/keep/config.json" "$SKILL_CFG" && ok "skills/config.json dikembalikan (konfigurasi skill kamu)"
  else
    ok "skills/config.json tidak berubah"
  fi
fi
[ -f "$BK/keep/.env" ] && [ ! -f "$EVONIC_HOME/.env" ] && cp -a "$BK/keep/.env" "$EVONIC_HOME/.env" && ok ".env dipulihkan"

if [ "$RESTORE_MODIFIED" -eq 1 ] && [ "$MODIFIED_COUNT" -gt 0 ]; then
  while read -r kind p; do
    [ "$kind" = "MODIFIED" ] || continue
    [ -f "$BK/modified/$p" ] && cp -a "$BK/modified/$p" "$EVONIC_HOME/$p" 2>/dev/null && ok "dikembalikan: $p"
  done < "$MODLIST"
fi

# ── [6/8] Dependensi + sandbox image ───────────────────────────────────────
step "[6/8] Pasang dependensi"
PIP=""
[ -x "$EVONIC_HOME/.venv/bin/pip" ] && PIP="$EVONIC_HOME/.venv/bin/pip"
if [ -n "$PIP" ] && [ -f "$EVONIC_HOME/requirements.txt" ]; then
  if run_as_svc "'$PIP' install -q -r '$EVONIC_HOME/requirements.txt'" >/tmp/evonic_pip.log 2>&1; then
    ok "python deps OK"
  else
    warn "pip install bermasalah — cek /tmp/evonic_pip.log"
  fi
else
  warn "venv/requirements.txt tidak ditemukan — lewati"
fi

if command -v docker >/dev/null 2>&1 && [ -d "$EVONIC_HOME/docker/tools" ]; then
  if docker build -q -t evonic-sandbox:latest "$EVONIC_HOME/docker/tools/" >/tmp/evonic_docker.log 2>&1; then
    ok "sandbox image evonic-sandbox:latest dibangun ulang"
  else
    warn "rebuild sandbox gagal (tidak fatal) — cek /tmp/evonic_docker.log"
  fi
else
  info "docker tidak ada — sandbox image dilewati"
fi

# ── [7/8] Normalisasi izin, unit, start service ────────────────────────────
step "[7/8] Rapikan izin & jalankan service"
[ -x /usr/local/bin/evonic-fix-perms ] && /usr/local/bin/evonic-fix-perms >/dev/null 2>&1 && ok "helper izin dijalankan"
chown -R "$SVC_USER:$SVC_USER" "$EVONIC_HOME" 2>/dev/null && ok "ownership → $SVC_USER"
[ -x /usr/local/bin/evonic-normalize-unit ] && /usr/local/bin/evonic-normalize-unit >/dev/null 2>&1 && ok "unit systemd dinormalisasi"

systemctl daemon-reload 2>/dev/null || true
systemctl start "$SERVICE_NAME" 2>/dev/null || true
ok "service dijalankan"

# helper: banner App Catalog (/etc/idch-app-info) ditulis sekali saat deploy → versinya
# harus disinkronkan tiap update, otomatis lewat ExecStartPost
if fetch_helper "evonic-refresh-app-info" /usr/local/bin/evonic-refresh-app-info; then
  ok "helper banner versi dipasang/diperbarui"
  mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
  printf '[Service]\nExecStartPost=/usr/local/bin/evonic-refresh-app-info\n' \
    > "/etc/systemd/system/${SERVICE_NAME}.service.d/10-refresh-app-info.conf"
  systemctl daemon-reload 2>/dev/null || true
  /usr/local/bin/evonic-refresh-app-info >/dev/null 2>&1 && ok "banner login disinkronkan (Version/Status/IP)"
else
  info "helper banner tidak tersedia (offline?) — dilewati"
fi

# helper HTTPS+domain (dipanggil nanti kalau user memilih opsi itu)
fetch_helper "evonic-https-setup.sh" /usr/local/bin/evonic-https-setup.sh \
  && info "helper HTTPS tersedia: /usr/local/bin/evonic-https-setup.sh" || true

#mode cookie: HTTPS aktif → Secure; HTTP saja → cookie non-Secure supaya login jalan
if https_configured; then COOKIE_MODE="https"; else COOKIE_MODE="http"; fi
set_env_cookie_note=""
ensure_cookie_mode "$COOKIE_MODE"
case "${set_env_cookie_note:-}" in
  diubah)
    ok "cookie disesuaikan untuk mode $COOKIE_MODE (FORCE_INSECURE_COOKIES=$( [ "$COOKIE_MODE" = https ] && echo 0 || echo 1 ))"
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true; sleep 5 ;;
  sudah) ok "cookie sudah sesuai mode $COOKIE_MODE" ;;
  *) ;;
esac

# ── [8/8] Smoke test ───────────────────────────────────────────────────────
step "[8/8] Uji dasbor di port $DASH_PORT"
HTTP=""
for i in $(seq 1 15); do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$DASH_PORT/login" 2>/dev/null) || HTTP=000
  HTTP=$(printf '%s' "$HTTP" | tr -cd '0-9')
  [ -n "$HTTP" ] || HTTP=000
  [ "$HTTP" != "000" ] && break
  sleep 2
done
[ -n "$HTTP" ] || HTTP=000
SVC_STATE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)

# ── Ringkasan ──────────────────────────────────────────────────────────────
printf "\n"
IP=$(curl -s -m 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
HDR="$GRN"; [ "$HTTP" = "200" ] || HDR="$YLW"
printf "${HDR}${B}  ╭%s╮${R}\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"
boxline "$( [ "$HTTP" = "200" ] && echo '✓ Evonic berhasil diupdate' || echo '! Update selesai, perlu dicek' )"
printf "${HDR}${B}  ╰%s╯${R}\n\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"

if https_configured; then
  CUR_URL="https://$(https_domain)  (tanpa port)"
else
  CUR_URL="http://${IP:-<ip-server>}:$DASH_PORT"
fi
kv "versi"      "${B}$OLD_VERSION → $NEW_VERSION${R}  ($LATEST_TAG)"
kv "service"   "$SVC_STATE"
kv "akses"     "$CUR_URL"
kv "durasi"    "$(elapsed)"
kv "backup"    "$BK"
kv "log"       "/var/log/evonic/evonic-update.log"
[ "$MODIFIED_COUNT" -gt 0 ] && kv "catatan" "$MODIFIED_COUNT file lokal dimodifikasi — lihat $MODLIST"
grep -q '^MISSING' "$MODLIST" 2>/dev/null && kv "catatan" "ada file tracked hilang — lihat $MODLIST"

if [ "$HTTP" != "200" ]; then
  printf "\n  ${YLW}${B}Dasbor belum merespons di port $DASH_PORT.${R}\n"
  printf "  ${GRY}  Cek: systemctl status $SERVICE_NAME ; tail -50 /var/log/evonic/evonic.service.log${R}\n"
  printf "  ${GRY}  Rollback: tar xzf $BK/evonic-full.tar.gz -C $(dirname "$EVONIC_HOME") && systemctl restart $SERVICE_NAME${R}\n\n"
  notify_telegram "Evonic update: dashboard belum merespons" \
    "host: $(hostname)%0Aversi: $OLD_VERSION → $NEW_VERSION%0Aservice: $SVC_STATE%0Adashboard HTTP: $HTTP"
  exit 1
fi

notify_telegram "Evonic updated: $OLD_VERSION → $NEW_VERSION" \
  "host: $(hostname)%0Aservice: $SVC_STATE%0Aakses: $CUR_URL%0Adurasi: $(elapsed)%0Abackup: $BK"

# ── Pilih mode akses: HTTP saja atau HTTPS + domain ────────────────────────
HTTPS_FLOW=0
[ "$MODE_HTTPS" -eq 1 ] && HTTPS_FLOW=1
[ -n "$HTTPS_DOMAIN" ] && HTTPS_FLOW=1

if [ "$HTTPS_FLOW" -eq 0 ] && [ "$MODE_HTTP_ONLY" -eq 0 ] && [ "$NO_PROMPT" -eq 0 ] \
   && ! https_configured && have_tty; then
  printf "\n"
  rule
  printf "  ${B}${PRP}Akses dashboard — pilih mode${R}\n\n"
  printf "    ${CYN}1${R}) ${B}HTTP saja${R}          ${GRY}→ $CUR_URL  (cookie non-Secure, cukup untuk testing/internal)${R}\n"
  printf "    ${CYN}2${R}) ${B}HTTPS + domain${R}     ${GRY}→ https://domain-anda (tanpa port, cookie Secure)${R}\n\n"
  printf "  ${GRY}  Mode HTTP tetap bisa diubah ke HTTPS kapan saja tanpa update ulang.${R}\n"
  CH=$(ask "  Pilih [1/2] (enter = 1): " "1")
  case "$CH" in 2|https|HTTPS|Https) HTTPS_FLOW=1 ;; *) HTTPS_FLOW=0 ;; esac
fi

if [ "$HTTPS_FLOW" -eq 1 ]; then
  printf "\n"
  rule
  printf "  ${YLW}${B}SEBELUM LANJUT — A record harus diarahkan ke IP publik VPS ini${R}\n\n"
  printf "  ${GRY}  Di DNS management domainmu, tambahkan record:${R}\n"
  printf "    ${B}Type${R}   : A\n"
  printf "    ${B}Name${R}   : %s   ${GRY}(subdomain, mis. evonic.domainmu.com → isi \"evonic\")${R}\n" "${HTTPS_DOMAIN:-evonic}"
  printf "    ${B}Value${R}  : %s   ${GRY}(IP publik VPS ini)${R}\n" "${IP:-<ip-server>}"
  printf "    ${B}TTL${R}    : 14400 (default)\n\n"
  printf "  ${GRY}  Propagasi 5-30 menit. Port ${B}80${R}${GRY} & ${B}443${R}${GRY} harus terbuka di security group VPS,${R}\n"
  printf "  ${GRY}  kalau tidak Let's Encrypt gagal memverifikasi.${R}\n\n"

  [ -z "$HTTPS_DOMAIN" ] && HTTPS_DOMAIN=$(ask "  Domain/subdomain Evonic (mis. evonic.domainmu.com): " "")
  if [ -z "$HTTPS_DOMAIN" ]; then
    warn "domain kosong — HTTPS dilewati, dashboard tetap di $CUR_URL"
    printf "  ${GRY}  Jalankan kapan saja: sudo /usr/local/bin/evonic-https-setup.sh --domain domainmu.com${R}\n"
  elif ! printf '%s' "$HTTPS_DOMAIN" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
    warn "format domain tidak valid: $HTTPS_DOMAIN — HTTPS dilewati"
  else
    [ -z "$HTTPS_EMAIL" ] && HTTPS_EMAIL=$(ask "  Email untuk Let's Encrypt (enter = lewati): " "")
    printf "\n"
    step "Pasang HTTPS + domain: $HTTPS_DOMAIN"
    HSCRIPT="/usr/local/bin/evonic-https-setup.sh"
    if [ ! -x "$HSCRIPT" ]; then
      T=$(mktemp)
      if curl -fsS -m 30 "$BASE_URL/evonic-https-setup.sh" -o "$T" 2>/dev/null; then
        chmod 755 "$T"; HSCRIPT="$T"
      else
        warn "helper HTTPS tidak bisa diambil (offline?)"
        HSCRIPT=""
      fi
    fi
    if [ -n "$HSCRIPT" ]; then
      HS_ARGS=(--domain "$HTTPS_DOMAIN" --yes)
      [ -n "$HTTPS_EMAIL" ] && HS_ARGS+=(--email "$HTTPS_EMAIL")
      bash "$HSCRIPT" "${HS_ARGS[@]}" || warn "setup HTTPS berhenti — dashboard tetap di $CUR_URL"
    fi
  fi
fi

# ── Penutup ────────────────────────────────────────────────────────────────
printf "\n"
if https_configured; then
  D=$(https_domain)
  printf "  ${GRN}${B}✓ Selesai.${R} ${GRN}Buka ${B}https://%s${R}${GRN} — tanpa port, cookie Secure.${R}\n" "$D"
  printf "  ${GRY}  HTTP otomatis dialihkan ke HTTPS. Config & data agen tidak berubah.${R}\n\n"
else
  printf "  ${GRN}${B}✓ Selesai.${R} ${GRN}Buka ${B}http://%s:%s${R}${GRN} — config & data agen tidak berubah.${R}\n" "${IP:-ip-server}" "$DASH_PORT"
  printf "  ${GRY}  Mau HTTPS + domain nanti? ${R}${GRY}sudo /usr/local/bin/evonic-https-setup.sh --domain domainmu.com${R}\n\n"
fi
exit 0

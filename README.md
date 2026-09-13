# Evonic Updater

One-command updater untuk instalasi **Evonic** (`/opt/evonic`), termasuk VPS **App Catalog IDCloudHost** yang tidak punya `.git` (penyebab `evonic update` gagal `fatal: not a git repository`).

```bash
curl -sS https://raw.githubusercontent.com/ujang0311/evonic/main/update.sh | bash
```

Selesai. Script otomatis mengecek rilis stabil terbaru di GitHub, backup, memperbaiki repo git kalau belum ada, memasang versi baru, membangun ulang sandbox, menyalakan service, dan menampilkan ringkasan.

## Kenapa perlu script ini

Instalasi dari release archive / App Catalog tidak punya `.git`, sementara `evonic update` bekerja dengan `git fetch --tags` + `git checkout <tag>`. Akibatnya:

```
$ evonic update
Fetching tags from origin...
Git fetch failed: fatal: not a git repository (or any of the parent directories): .git
```

Script ini mengonversi instalasi jadi git repo **in-place** (tanpa menghapus `/opt/evonic`), jadi setelah itu `evonic update` dan `evonic-update` bekerja normal.

## Yang dilakukan script

1. Cek rilis stabil terbaru (`git ls-remote --tags`)
2. Backup: `.env`, `skills/config.json`, dan snapshot penuh kode+data ke `/var/backups/evonic/update_<timestamp>/`
3. Siapkan repo git (`init` + remote + fetch tags) kalau belum ada
4. Deteksi file lokal yang berbeda dari tag → disalin + dibuat `.patch`
5. Stop service → `git checkout -f <tag>` → pulihkan `skills/config.json`
6. `pip install -r requirements.txt` + rebuild image `evonic-sandbox:latest`
7. Normalisasi izin/ownership + `systemctl start`
8. Smoke test dasbor `:8080` + ringkasan (versi, service, URL, durasi, lokasi backup)

Kalau langkah 5 gagal, script otomatis memulihkan snapshot dan menyalakan service kembali.

## Data yang TIDAK tersentuh

`git checkout` hanya menulis file yang di-track. Semua ini untracked/gitignored → aman:

| Path | Isi |
|---|---|
| `.env` | Konfigurasi server |
| `agents/` | System prompt, KB, artifacts, sesi agen |
| `shared/` | `evonic.db`, evomem, rate-limit DB |
| `state/`, `run/`, `logs/` | State runtime, PID, log |
| `skills/<nama-skill>` | Skill yang kamu install sendiri |
| `plugins/<nama-plugin>` | Plugin + konfigurasinya |

Satu-satunya config yang tracked dan ikut tertimpa checkout adalah `skills/config.json` → script mem-backup dan mengembalikannya otomatis.

## Opsi

| Perintah | Fungsi |
|---|---|
| `... \| bash` | update ke rilis stabil terbaru |
| `... \| bash -s -- --check` | cek versi lokal vs terbaru, tidak mengubah apa pun |
| `... \| bash -s -- --dry-run` | tampilkan rencana + daftar file lokal yang dimodifikasi |
| `... \| bash -s -- --tag v1.2.0` | pasang tag tertentu (bisa untuk rollback) |
| `... \| bash -s -- --force` | jalankan walau sudah versi terbaru |
| `... \| bash -s -- --restore-modified` | kembalikan file tracked yang kamu modifikasi |
| `... \| bash -s -- --no-backup` | lewati backup (tidak disarankan) |
| `... \| bash -s -- --quiet` | output ringkas |
| `... \| bash -s -- --help` | bantuan |

## Environment

| Variabel | Default | Fungsi |
|---|---|---|
| `EVONIC_HOME` | `/opt/evonic` | Lokasi instalasi |
| `EVONIC_REPO_URL` | `https://github.com/anvie/evonic.git` | Repo upstream |
| `EVONIC_BACKUP_DIR` | `/var/backups/evonic` | Lokasi backup |
| `EVONIC_SERVICE` | `evonic` | Nama unit systemd |
| `EVONIC_PORT` | `8080` | Port dasbor untuk smoke test |
| `NOTIFY_TELEGRAM_TOKEN` + `NOTIFY_TELEGRAM_CHAT` | — | Kirim notifikasi hasil update ke Telegram |

Contoh dengan notifikasi Telegram:

```bash
curl -sS https://raw.githubusercontent.com/ujang0311/evonic/main/update.sh | \
  NOTIFY_TELEGRAM_TOKEN=123456:ABC NOTIFY_TELEGRAM_CHAT=123456789 bash
```

## Rollback manual

```bash
BK=/var/backups/evonic/update_<timestamp>
tar xzf $BK/evonic-full.tar.gz -C /opt && systemctl restart evonic

# atau lewat tag
bash update.sh --tag v0.8.0
```

## Prasyarat

- Linux + root (`sudo` didukung, script akan re-exec sendiri)
- `git`, `curl`
- Docker (opsional — untuk rebuild sandbox image)
- Bash >= 4.2

## Catatan

- Default non-interaktif supaya aman dijalankan via `curl | bash`.
- Tidak menyentuh unit systemd, konfigurasi `/etc/evonic/`, port, maupun layout path instalasi.
- Repo ini berisi script updater saja; kode Evonic-nya ada di [anvie/evonic](https://github.com/anvie/evonic).

## Troubleshooting

| Gejala | Sebab / solusi |
|---|---|
| `404` saat curl URL tanpa segmen branch | raw.githubusercontent wajib menyertakan ref. Pakai `.../evonic/main/update.sh`, `.../evonic/HEAD/update.sh`, atau `.../evonic/refs/heads/main/update.sh` |
| Output script masih versi lama setelah repo diubah | CDN raw.githubusercontent punya cache beberapa menit. Pakai bentuk `refs/heads/main` untuk konten paling baru |
| `.env` bertambah key setelah update | Itu ditulis aplikasi Evonic sendiri (key fitur baru), bukan oleh script. Nilai key lama tidak hilang |
| `warning: remote.origin.fetch has multiple values` | Sudah ditangani otomatis (`--replace-all`) sejak v1.0.1 |
| `detected dubious ownership in repository` | Script otomatis menambahkan `safe.directory`. Manual: `git config --global --add safe.directory /opt/evonic` |
| `git status` menunjukkan file `M` (`.githooks/*`, `bin/rg`, dll) | Perubahan mode executable dari `evonic-fix-perms` — bukan perubahan isi, tidak memengaruhi update |

## Hasil uji

Diuji pada Cloud VPS IDCloudHost (Evonic v0.8.0 non-git → v1.2.0, dan v1.2.0 git repo):

| Skenario | Hasil |
|---|---|
| Instalasi App Catalog tanpa `.git` | konversi + update berhasil, exit 0 |
| Instalasi git repo normal | update berhasil, exit 0, dashboard HTTP 200 |
| `skills/config.json` dimodifikasi user | terdeteksi, ditimpa checkout, **dikembalikan otomatis** |
| File `agents/<id>/` (prompt + KB) | utuh setelah update |
| `shared/db/evonic.db` | checksum identik sebelum/sesudah |
| File tracked dimodifikasi lokal | terdeteksi, disalin + `.patch` ke folder backup |

## Helper: `evonic-refresh-app-info`

Menyalin `evonic-refresh-app-info` ke `/usr/local/bin/` supaya banner login IDCloudHost
(`/etc/idch-app-info`) tidak lagi menampilkan versi basi setelah update:

```bash
sudo install -m 755 evonic-refresh-app-info /usr/local/bin/evonic-refresh-app-info
sudo mkdir -p /etc/systemd/system/evonic.service.d
sudo tee /etc/systemd/system/evonic.service.d/10-refresh-app-info.conf >/dev/null <<'EOF'
[Service]
ExecStartPost=/usr/local/bin/evonic-refresh-app-info
EOF
sudo systemctl daemon-reload
sudo systemctl restart evonic
```

`update.sh` memanggil helper ini otomatis setelah update (kalau helper ada).

## Mode akses: HTTP saja atau HTTPS + domain

Setelah update selesai, script menawarkan pilihan (hanya kalau ada terminal):

```
  1) HTTP saja          → http://IP:8080   (cookie non-Secure, cukup untuk testing/internal)
  2) HTTPS + domain     → https://domain   (nginx + Let's Encrypt, tanpa port, cookie Secure)
```

Pilih `2` → script menampilkan peringatan A record dulu, minta domain (+ email opsional),
lalu memasang nginx reverse proxy dan sertifikat Let's Encrypt secara otomatis.

**Sebelum memilih opsi 2, wajib:**

| Syarat | Detail |
|---|---|
| A record | `A` → `Value` = IP publik VPS (TTL 14400). Script memverifikasi lewat DNS publik dan berhenti kalau belum cocok |
| Propagasi | 5–30 menit |
| Port 80 & 443 | Harus terbuka di firewall/security group VPS (Let's Encrypt verifikasi via port 80) |

Non-interaktif (cocok untuk cron/CI):

```bash
# tetap HTTP
curl -sS .../main/update.sh | bash -s -- --http-only

# langsung pasang HTTPS + domain
curl -sS .../main/update.sh | bash -s -- --https --domain evonic.domainmu.com --email you@domainmu.com
```

### Helper standalone: `evonic-https-setup.sh`

```bash
sudo evonic-https-setup.sh --domain evonic.domainmu.com --email you@domainmu.com
sudo evonic-https-setup.sh --domain evonic.domainmu.com --yes        # tanpa konfirmasi
```

Yang dilakukan: deteksi IP publik → verifikasi A record → install nginx + certbot →
vhost reverse proxy (SSE/streaming friendly: `proxy_buffering off`, timeout 3600s,
WebSocket upgrade, upload 200m) → sertifikat Let's Encrypt + redirect HTTP→HTTPS →
set `FORCE_INSECURE_COOKIES=0` → restart service.

### Cookie & login (penting)

`app.py` menandai cookie session `Secure` secara default. Browser **menolak menyimpan
cookie Secure dari koneksi HTTP**, jadi login seolah gagal (padahal password benar).
Script menyesuaikan otomatis:

| Mode akses | `FORCE_INSECURE_COOKIES` | Efek |
|---|---|---|
| `http://IP:8080` | `1` | cookie non-Secure → login jalan, tapi sesi bisa disadap di jaringan tidak aman |
| `https://domain` | `0` (dihapus) | cookie Secure → aman, dipakai untuk produksi |

Script mendeteksi vhost HTTPS yang aktif dan menyetel nilainya sendiri tiap update.

### VPS tanpa IPv6

nginx bawaan Ubuntu listen di `[::]:80`. Di VPS yang IPv6-nya nonaktif service gagal
start (`socket() [::]:80 failed (97: Address family not supported by protocol)`) dan
`dpkg` ikut gagal. `evonic-https-setup.sh` mendeteksi ini, menonaktifkan baris
`listen [::]` di `nginx.conf` + vhost, lalu merapikan paket setengah terpasang
(`dpkg --configure -a`).

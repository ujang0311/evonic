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

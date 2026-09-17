# DevX Fedora Migration — Context for Claude CLI

## Cara pakai dokumen ini (baca dulu sebelum eksekusi apapun)
Dokumen ini ditulis oleh sesi Claude lain yang **belum pernah baca isi penuh
`bin/dev`** (~1000 baris) — hanya kerja dari ringkasan sesi sebelumnya dan
hasil `grep`. Semua nama fungsi yang disebut di sini (`cmd_trust`,
`cmd_doctor`, `db_port_for`, `allocate_db_port`, `write_generated_compose`,
dst) adalah **hint, bukan fakta terverifikasi**. Yang sudah benar-benar
diverifikasi langsung dari source (lewat `cat`/`find` di Mac) dan boleh
dipercaya 100%: struktur folder, isi `compose.global.yml`, isi `Corefile`,
isi `bin/` (cuma `dev` + `dev-db-all`), `templates/` kosong.

**Langkah wajib pertama, sebelum patch apapun**: `Read` penuh
`~/workspace/.devx/bin/dev`, `bin/dev-db-all`, `lib/parse-manifest.py`, dan
`README.md` dari hasil extract tar. Jangan asumsikan nama fungsi dari
dokumen ini benar — cross-check dulu. Kalau ada nama fungsi/logic yang beda
dari yang disebut di sini, ikuti yang ada di source asli, dan sesuaikan
target patch berdasarkan apa yang benar-benar ada (misal kalau logic trust
CA ada di fungsi dengan nama lain, patch fungsi itu, bukan cari-cari nama
`cmd_trust` yang mungkin gak ada).

## Tujuan
Port tool dev-environment custom "DevX" dari Mac (OrbStack-based) ke Fedora
(native Docker), dengan goal: begitu project baru di-clone/dibuat, stack
ter-detect otomatis, image/container ter-generate otomatis, reverse proxy +
SSL otomatis aktif di `https://<project>.test` — sisanya (nyala/matiin
container harian) tetap manual command, bukan auto-trigger per `cd`.

Sumber asli ada di Mac: `~/workspace/.devx/` (bin/dev, bin/dev-db-all,
lib/parse-manifest.py, compose.global.yml, Corefile, README.md, templates/
kosong — tidak ada template file terpisah, semua di-generate inline via
heredoc di dalam `bin/dev`). Source files akan disalin ke Fedora di
`~/workspace/.devx/` (path harus sama persis karena ada path relatif di
dalam script).

**Struktur workspace (WAJIB diikuti, jangan bikin struktur baru):**
```
~/workspace/
├── .devx/              ← tool-nya sendiri
├── work/
│   └── <project>/       ← project kerjaan
└── personal/
    └── <project>/       ← project pribadi
```
`bin/dev-db-all` meng-iterate project HANYA di bawah `work/` dan
`personal/`. Project baru (hasil `gclone`/`dev new`) harus dibuat di
salah satu dari dua folder ini, bukan langsung di root `~/workspace/`.

## Constraint penting
- Laptop: MSI Cyborg 14 A13VF, Fedora Workstation GNOME, NVIDIA RTX 4060,
  msi-ec sudah terpasang & permanen — tidak relevan untuk task ini, jangan
  disentuh.
- User berpengalaman, komunikasi santai (Bahasa Indonesia + istilah teknis
  Inggris), lebih suka rekomendasi langsung/opinionated daripada dihedge.
- Jangan bikin auto-trigger yang nempel ke `cd` (chpwd hook) — sudah dibahas
  dan ditolak karena bikin lifecycle container ambigu (kapan mulai/berhenti
  gak jelas kalau diiket ke posisi shell). Trigger otomatis HANYA boleh
  terjadi sekali, di titik create/clone project, lewat wrapper command,
  BUKAN via directory-watch/hook permanen.
- Semua workaround yang spesifik untuk bug OrbStack (port renegotiation)
  BOLEH dihapus/disederhanakan karena tidak relevan di native Docker Linux.
  Tapi pola "stable port lock per project di `.env`" itu sendiri tetap
  dipertahankan (bukan bug workaround, itu desain yang valid).

## Keputusan desain yang sudah difinalkan (jangan didiskusikan ulang, langsung eksekusi)
1. **Reverse proxy + SSL**: tetap Caddy + `caddy-docker-proxy` (label-based
   auto-discovery via Docker events + `tls internal` buat auto SSL lokal).
   Nginx ditolak — kalah jauh untuk auto-discovery & auto-SSL tanpa
   companion container tambahan.
2. **DNS `*.test`**: ganti `/etc/resolver/test` (macOS-only) dengan
   `systemd-resolved` drop-in config yang route domain `.test` ke CoreDNS di
   `127.0.0.1:53`. CoreDNS logic-nya sendiri (Corefile) tidak berubah.
3. **Trust CA lokal**: ganti `cmd_trust()` yang pakai macOS Keychain
   (`security add-trusted-cert`) dengan `update-ca-trust` (system-wide) +
   `certutil`/NSS (browser trust store: Chrome, Chromium snap, Firefox
   profile).
4. **Trigger project baru**: bukan chpwd hook. Pakai wrapper command
   eksplisit, misal `gclone <repo>` (git clone + auto `dev up`) dan/atau
   `dev new <name>` untuk project baru dari scratch. Lifecycle harian
   (nyala/mati) tetap manual via `dev up`/`dev down`.
5. **DB**: pertahankan pola stable-port-lock dari Mac (`.devx/.env` per
   project), tapi hapus retry-loop yang khusus nangani OrbStack port bug.
   (Opsional fase 2, jangan dikerjakan dulu kecuali diminta: ganti ke
   Caddy L4 hostname-based DB access seperti `db.<project>.test` supaya
   gak perlu inget port sama sekali.)
6. **Stack auto-detection**: logic marker-file (composer.json,
   package.json, requirements.txt/pyproject.toml/manage.py, go.mod,
   Gemfile, mix.exs) + version-file detection dipertahankan persis dari
   Mac, portable tanpa perubahan. Tambahkan caching hasil deteksi ke
   `.devx/state` biar command harian (logs/restart/dll) gak re-scan
   filesystem tiap kali dipanggil.
7. **Build speed**: tambahkan BuildKit cache mounts
   (`--mount=type=cache,target=...`) di Dockerfile yang di-generate
   `write_generated_php_assets`/setara untuk stack lain, karena native
   Linux Docker bisa manfaatin ini jauh lebih baik daripada di OrbStack.

## Urutan eksekusi end-to-end di Fedora

### Fase 0 — Prasyarat sistem
```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # perlu logout/login atau `newgrp docker`
sudo dnf install nss-tools      # buat certutil (browser trust)
```
Verifikasi: `docker version`, `docker compose version` (pastikan >=2.22
kalau mau pakai `docker compose watch` nanti), `groups` include `docker`.

### Fase 1 — Extract source dari Mac
User akan taruh `devx-source.tar.gz` (hasil `tar czf` dari `~/workspace/.devx`
di Mac) di suatu tempat yang bisa diakses Claude CLI di Fedora (misal
`~/Downloads/devx-source.tar.gz`). Extract ke `~/workspace/.devx` (path
harus persis sama karena ada referensi path relatif di script).

### Fase 2 — DNS setup
```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/devx-test-tld.conf <<'EOF'
[Resolve]
DNS=127.0.0.1
Domains=~test
EOF
sudo systemctl restart systemd-resolved
```
CoreDNS di `compose.global.yml` harus bind ke `127.0.0.1:53` (bukan
`0.0.0.0:53`) supaya gak bentrok sama stub listener systemd-resolved di
`127.0.0.53:53`.

Verifikasi setelah infra global nyala (Fase 4): `resolvectl query
anything.test` harus resolve ke `127.0.0.1`.

### Fase 3 — Discovery, lalu patch source code

**3a. Discovery (wajib, jangan skip).** Baca penuh `bin/dev`,
`bin/dev-db-all`, `lib/parse-manifest.py`, `README.md`. Cari (grep) semua
titik yang macOS/OrbStack-specific: `OSTYPE`, `darwin`, `security`,
`Keychain`, `orbstack`/`OrbStack`, `/etc/resolver`, dan baca konteks
sekitarnya. Susun daftar titik yang perlu dipatch berdasarkan apa yang
BENAR-BENAR ditemukan — bukan daftar di bawah ini. Daftar di bawah ini
adalah ekspektasi dari sesi sebelumnya (kemungkinan besar akurat karena
sudah pernah di-grep, tapi verifikasi ulang):

1. Fungsi yang handle trust CA lokal (kemungkinan nama `cmd_trust`) — ganti
   branch `[[ "${OSTYPE:-}" == darwin* ]]` + `security add-trusted-cert`
   dengan implementasi `update-ca-trust` (system-wide) + `certutil`/NSS
   (`~/.pki/nssdb` + tiap profile Firefox yang ketemu di
   `~/.mozilla/firefox/*.default*`).
2. Fungsi diagnostic (kemungkinan nama `cmd_doctor`) — ganti pengecekan
   `/etc/resolver/test` dengan `resolvectl query nonexistent.test`.
3. Pesan error yang menyebut "orbstack" — ganti jadi cek
   `systemctl is-active docker` dan saran `sudo systemctl start docker`.
4. Comment/logic port-renegotiation workaround (kemungkinan sekitar fungsi
   alokasi port DB) — sederhanakan, hapus bagian yang spesifik menangani
   OrbStack quirk, pertahankan stable-port-lock mechanism-nya sendiri
   (jangan dihapus, itu desain yang valid terlepas dari OrbStack).
5. `compose.global.yml` — SUDAH DIVERIFIKASI benar persis, TIDAK PERLU
   diubah sama sekali. Isinya sudah bind CoreDNS ke `127.0.0.1:53:53`
   (udp+tcp), pakai `caddy-docker-proxy` dengan `CADDY_INGRESS_NETWORKS=
   devx_ingress`, network `devx_ingress` + 2 named volume
   (`devx_caddy_data`, `devx_caddy_config`). Copy-paste apa adanya.
6. Tambahkan wrapper trigger command — INI HARUS DIBUAT BARU DARI NOL,
   Mac tidak punya ini (`bin/` di Mac cuma isi `dev` dan `dev-db-all`,
   `templates/` kosong). Buat:
   - `gclone <repo>`: `git clone "$@"` lalu `cd` ke folder hasil clone
     lalu jalankan `dev up`.
   - (opsional) `dev new <name>`: scaffold folder project baru + trigger
     `dev up`.
   Taruh sebagai shell function di `.zshrc`, atau file executable baru di
   `bin/` — putuskan sendiri mana yang lebih konsisten dengan gaya
   `bin/dev` yang sudah ada.
7. (Opsional, kerjakan kalau waktu memungkinkan) Tambahkan BuildKit cache
   mount ke template Dockerfile yang di-generate inline di dalam
   `bin/dev` (fungsi `write_generated_php_assets` dan setaranya untuk
   stack Node/Python/Go/Ruby kalau ada) — ingat, tidak ada file template
   terpisah, semua di-generate via heredoc/string di dalam script.

### Fase 4 — Nyalakan infra & pasang PATH
```bash
cd ~/workspace/.devx
docker compose -f compose.global.yml up -d
echo 'export PATH="$HOME/workspace/.devx/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Fase 5 — Trust CA
Jalankan `dev trust` (versi yang sudah dipatch) setelah ada minimal satu
project yang sudah pernah di-`dev up` (supaya root CA Caddy sudah
ke-generate di volume-nya).

### Fase 6 — Test end-to-end
1. `gclone <salah satu repo test>` (atau clone manual + `dev up`).
2. `resolvectl query <project>.test` → harus resolve ke `127.0.0.1`.
3. Buka `https://<project>.test` di browser → harus tanpa warning SSL.
4. Cek DB accessible sesuai pola port-lock (`cat <project>/.devx/.env`).
5. `dev doctor` (versi patched) → semua check harus hijau.
6. `dev down` lalu `dev up` lagi di project yang sama → pastikan port DB
   yang dipakai konsisten sama seperti sebelumnya (stable-lock bekerja).

### Fase 7 — Verifikasi akhir
- Buat 2-3 project dummy dengan stack berbeda (PHP/Laravel, Node, Python)
  untuk memastikan auto-detection & compose generation benar untuk semua
  stack yang biasa dipakai user.
- Pastikan `docker compose watch` (kalau diimplementasikan) benar-benar
  auto-rebuild saat file dependency berubah.
- Laporkan ke user: bagian mana yang portable 1:1, bagian mana yang
  dipatch, dan hasil test end-to-end di atas.

## Yang TIDAK perlu dikerjakan ulang (sudah settled, jangan didesain ulang)
- Logic `find_project_root`, `parse_manifest`/`mf()`, semua stack/version
  detector, `write_generated_compose`, `write_generated_php_assets` (selain
  penambahan cache mount di poin 7), label generation Caddy,
  `sync_project_env` — semuanya portable langsung, treat sebagai given.

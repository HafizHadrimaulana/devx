# DevX — Environment & Infra (Fedora)

Dokumen ini ngejelasin **arsitektur infra lokal**, cara **onboarding device baru**,
dan **portabilitas** setup ini. Buat referensi command sehari-hari (`dev up`,
`dev artisan`, dst), lihat [README.md](README.md) — dokumen itu murni reference
command, dokumen ini konteks arsitektur + operasional.

## 1. Arsitektur (gambaran umum)

```
                         ┌─────────────────────────────┐
  browser / curl  ──────▶│  Caddy (caddy-docker-proxy)  │  :80 / :443
  https://*.test         │  auto-discovery via labels   │  auto-TLS (internal CA)
                         └──────────────┬───────────────┘
                                        │ devx_ingress (network, shared)
                    ┌───────────────────┼───────────────────┐
                    │                   │                   │
             project A app       project B app        project C app
          (php/node/python/…)  (php/node/python/…)  (php/node/python/…)
                    │                   │                   │
             devx_internal        devx_internal        devx_internal
          (network, per-project — DB/cache tinggal di sini, TIDAK di ingress)

  Resolusi domain *.test:
  browser/app ──▶ systemd-resolved (stub 127.0.0.53) ──▶ CoreDNS (127.0.0.1:53)
                  (drop-in: /etc/systemd/resolved.conf.d/devx-test-tld.conf)
```

**Komponen inti** (semua jalan sebagai container Docker, didefinisikan di
`compose.global.yml`, project name `devx-global`):

| Komponen | Image | Peran |
|---|---|---|
| **CoreDNS** | `coredns/coredns` | Jawab semua query `*.test` → `127.0.0.1` (lihat `Corefile`) |
| **Caddy** (caddy-docker-proxy) | `lucaslorentz/caddy-docker-proxy` | Reverse proxy + auto-TLS internal, auto-discovery lewat Docker label, tanpa perlu restart |

**Per-project** (di-generate otomatis oleh `bin/dev`, satu compose per project):
- Container app sesuai stack terdeteksi (PHP-FPM+nginx, Node, Python, Go, Ruby, …)
- Database (opsional): MySQL/MariaDB/Postgres/Redis, host port terkunci permanen di `.devx/.env`
- Dua network: `devx_internal` (privat per-project) dan `devx_ingress` (dipakai bareng, cuma buat service yang HARUS diakses Caddy — database dilarang join network ini, biar gak ke-route ke project lain)

## 2. One-time host setup (device baru)

**Cara tercepat, di OS manapun (Linux/macOS):**

```bash
# 1. Copy folder ini ke path yang SAMA PERSIS di device baru:
#      ~/workspace/.devx
# 2. Jalankan installer — dia deteksi OS/distro otomatis dan idempotent
#    (aman di-re-run kalau ada step yang gagal di tengah jalan):
~/workspace/.devx/install.sh
```

Installer-nya ngerjain persis urutan manual di bawah, buat 3 OS: Fedora/RHEL
(`dnf`), Debian/Ubuntu (`apt`), dan macOS (`brew` — install Docker Desktop-nya
sendiri manual dulu, GUI app gak bisa di-script). **Windows**: gak ada native
support (`bin/dev` itu bash, bukan PowerShell) — jalanin di dalam **WSL2**
(distro Linux di bawah Windows), yang otomatis kena jalur Linux di atas
karena WSL2 punya kernel Linux beneran (`uname -s` = `Linux`). Docker Desktop
di Windows sendiri sebenarnya sudah pakai WSL2 sebagai backend, jadi ini
bukan workaround tambahan — itu memang cara Docker jalan di Windows.

### Manual, step-by-step (kalau mau kontrol tiap langkah / installer gagal)

**Fedora / RHEL family:**
```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nss-tools
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```
`dnf config-manager addrepo --from-repofile=` (bukan `--add-repo`) itu wajib
di Fedora 41+ karena DNF5 ganti syntax — jangan pakai command lama dari
tutorial berbasis DNF4.

**Debian / Ubuntu family:**
```bash
sudo apt-get update && sudo apt-get -y install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin libnss3-tools
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

**macOS:**
```bash
brew install --cask docker      # Docker Desktop, atau:
brew install --cask orbstack    # alternatif lebih ringan
brew install nss                # certutil, buat trust Firefox
# Buka Docker Desktop/OrbStack sekali dari Applications sebelum lanjut.
```

Semua OS di atas: **WAJIB logout/login penuh sesi** (bukan cuma buka terminal
baru) biar grup `docker` ke-apply ke semua shell baru. Workaround sementara
per-shell: `newgrp docker`. (macOS gak butuh ini — Docker Desktop gak pakai
grup Unix.)

**DNS `*.test` — beda per OS:**

| OS | Mekanisme |
|---|---|
| Linux (systemd-resolved, termasuk WSL2 kalau systemd aktif) | Drop-in `/etc/systemd/resolved.conf.d/devx-test-tld.conf` |
| macOS | `/etc/resolver/test` |
| WSL2 tanpa systemd | Gak ada DNS wildcard native — lihat §8 |

```bash
# Linux (systemd-resolved):
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/devx-test-tld.conf <<'EOF'
[Resolve]
DNS=127.0.0.1
Domains=~test
EOF
sudo systemctl restart systemd-resolved

# macOS:
sudo mkdir -p /etc/resolver && echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/test
```

**Sisanya sama di semua OS:**
```bash
# PATH + alias + gclone → masuk ~/.zshrc (lihat §4), atau salin blok
# "--- DevX shell integration ---" dari device lama.

cd ~/workspace/.devx && docker compose -p devx-global -f compose.global.yml up -d

resolvectl query anything.test   # Linux — harus resolve ke 127.0.0.1
dev doctor                        # dari dalam sebuah project — semua harus OK
dev trust                         # setelah minimal 1 project pernah `dev up`
```

## 3. Struktur workspace (wajib diikuti)

```
~/workspace/
├── .devx/              ← tool-nya sendiri (bin/dev, compose.global.yml, dst) — JANGAN duplikat per-device path-nya
├── work/<project>/      ← project kerjaan kantor
└── personal/<project>/  ← project pribadi
```

Domain otomatis: `<project>.<work|personal>.test` — jadi dua project bernama
sama di `work/` dan `personal/` tetap gak tabrakan.

## 4. Legend alias

Ditambahin ke `~/.zshrc` (bukan bagian dari `bin/dev` itu sendiri):

| Alias | Expands to | Kegunaan |
|---|---|---|
| `dcup` | `dev up` | Nyalain infra + stack project |
| `dcdown` | `dev down` | Matiin stack project |
| `dl` / `dclogs` | `dev logs -f` | Tail log semua service |
| `dps` | `dev ps` | Status container project |
| `dsh` | `dev shell` | Masuk shell ke service app utama |
| `drestart` | `dev restart` | Down lalu up (regenerate compose) |
| `dart` | `dev artisan` | Laravel artisan lewat container |
| `dcomp` | `dev composer` | Composer lewat container |
| `ddb` | `dev db` | Info koneksi DB (host/port/kredensial) buat DBeaver dkk |
| `ddball` | `dev-db-all` | `dev db info` buat SEMUA project sekaligus, tanpa `cd` satu-satu |
| `ddoc` | `dev doctor` | Diagnostic lengkap (stack, resolver, docker, CA) |

Plus dua **shell function** (bukan alias biasa, karena perlu `cd` shell interaktif):

| Command | Fungsi |
|---|---|
| `gclone <repo>` | Clone GitHub repo ke `work/` (default) + `dev up` otomatis. Tambah `--personal` buat ke `personal/` |
| `dev new [--personal] <nama>` | Scaffold folder project baru dari nol + `dev up`. Karena `dev` sendiri bukan shell function, dia gak bisa `cd`-in shell kamu — dia print path + instruksi `cd` manual |

## 5. Alur clone / bikin project baru

**Clone project existing (paling umum):**
```bash
gclone HafizHadrimaulana/nama-repo              # → ~/workspace/work/nama-repo, auto dev up
gclone --personal HafizHadrimaulana/nama-repo   # → ~/workspace/personal/nama-repo
```
Setelah itu jalanin bootstrap manual sesuai stack (`dev composer install`,
`dev npm install` / `dev pnpm install`, `dev artisan migrate` / `dev node ace migration:run`,
generate `APP_KEY`, dst) — DevX **sengaja** gak pernah nge-otomatis-in ini.

**Project baru dari nol:**
```bash
dev new nama-project              # ~/workspace/work/nama-project
dev new --personal nama-project   # ~/workspace/personal/nama-project
```

**Kalau `gh repo clone` manual** (bukan `gclone`): sama aja, tinggal `cd` ke
foldernya lalu `dev up` manual — `gclone` cuma nge-otomatisin dua langkah itu.

## 6. Konvensi per-project yang perlu diinget

- **`.env` DevX-managed vs app-managed**: DevX nulis key generic (`APP_URL`,
  `DB_HOST/PORT/DATABASE`, `DB_USERNAME`, `VITE_*`) ke `.env` project secara
  otomatis. Tapi **penamaan key DB spesifik-framework** (mis. AdonisJS/Lucid
  pakai `DB_USER`, bukan `DB_USERNAME` ala Laravel) **gak** ditangani DevX —
  cek manual kalau app-nya crash soal env var DB pas pertama kali `dev up`.
- **APP_KEY / secret app**: DevX gak pernah generate ini. Laravel:
  `dev artisan key:generate`. AdonisJS: `dev node ace generate:key`.
- **Container idle sebelum deps ke-install**: kalau `dev up` duluan sebelum
  `dev npm/pnpm install`, container app (Node/Python/Go/Ruby) cuma idle
  nunggu dan Caddy bakal 502. Setelah install deps, **wajib** `dev restart`
  (bukan cuma nunggu) biar start-script-nya re-check dan actually jalan.
- **Ekstensi PHP dari dependency transitive** (mis. package butuh `ext-gd`/
  `ext-zip` tapi cuma dideklarasikan tersirat lewat dependency lain): DevX
  cuma baca `composer.json` project sendiri. Kalau `composer install` minta
  extension yang "missing", declare eksplisit di `composer.json` project
  (`"ext-gd": "*"`) lalu `dev restart` buat regenerate Dockerfile-nya.

## 7. Troubleshooting cepat

| Gejala | Penyebab | Fix |
|---|---|---|
| `docker is running but not reachable — check group membership` | Grup `docker` belum ke-apply ke shell ini | `newgrp docker` (per-shell), atau logout/login penuh (permanen) |
| `dev up`/`dev restart` mati mendadak, exit 1, gak ada pesan sama sekali | Bug lama `has_db` di `write_generated_compose` (project tanpa Postgres) — **sudah di-fix** per {tanggal patch ini} | Update `~/workspace/.devx/bin/dev` ke versi terbaru |
| Domain `.test` gak resolve | CoreDNS mati, atau drop-in systemd-resolved belum ke-apply | `docker compose -p devx-global -f compose.global.yml ps`; `resolvectl query anything.test` |
| Browser SSL warning di `https://*.test` | Root CA belum di-trust di browser/OS | `dev trust` (butuh sudo interaktif — jalankan di terminal biasa, bukan otomatis) |
| Container app 502 padahal `dev up` sukses | Dependency belum di-install (`node_modules`/`vendor` kosong) | Install deps lewat `dev <pm> install`, lalu **`dev restart`** |
| `docker compose build` gagal instan tanpa output sama sekali | Kadang muncul kalau dipanggil dari automation/non-TTY context | Coba `BUILDKIT_PROGRESS=plain` di env, atau jalankan langsung dari terminal interaktif biasa |

## 8. Portabilitas — bisa dipakai di device baru? Di server?

**Ke device Fedora/RHEL baru: ya, sepenuhnya portable.** Semua yang dipakai
(Docker CE, systemd-resolved, DNF, bash) adalah standar distro, bukan
sesuatu yang spesifik ke laptop ini. Langkah-langkahnya persis §2 di atas —
copy folder `~/workspace/.devx` ke path yang sama, jalanin setup sekali,
selesai. Satu-satunya hal yang perlu diinget: path `~/workspace/.devx` itu
**hardcoded** di beberapa tempat di `bin/dev` (`DEVX_HOME`), jadi harus
persis sama di device baru — bukan sesuatu yang dikonfigurasi via env var.

**Ke distro Linux lain (Ubuntu/Debian dll): ya, `install.sh` deteksi otomatis.**
`bin/dev` sendiri sudah distro-agnostic (deteksi `update-ca-trust` vs
`update-ca-certificates` buat trust CA, `systemd-resolved` biasanya identik
di semua distro desktop modern). Cuma paket dependensi awal (`nss-tools` vs
`libnss3-tools`) yang beda nama — `install.sh` sudah nangani ini otomatis.

**Ke macOS: ya, native, sudah diimplementasikan** (`bin/dev` deteksi
`uname -s == Darwin` dan cabang ke `security`/Keychain buat trust CA, cek
`/etc/resolver/test` buat diagnostic, dst). **Catatan jujur:** ini dikerjain
lewat pembacaan kode yang cermat (tahu behavior macOS Keychain, NSS Firefox,
systemd vs launchd), **bukan hasil test langsung di mesin Mac** — belum ada
akses ke Mac buat verifikasi live. Kalau kamu/temen kamu pakai Mac, jalanin
`dev doctor` dan `dev trust` dulu buat mastiin, terus laporin kalau ada yang
meleset.

**Ke Windows: ya, lewat WSL2** (bukan native PowerShell — `bin/dev` itu bash,
nulis ulang ke PowerShell adalah proyek terpisah yang jauh lebih besar).
Di dalam WSL2, `uname -s` tetap `Linux`, jadi otomatis kena jalur Linux di
atas tanpa kode tambahan. Docker Desktop di Windows sendiri sudah pakai WSL2
sebagai backend — install Docker Desktop, aktifkan **WSL Integration** buat
distro WSL2 kamu, lalu ikutin langkah Linux biasa **di dalam** WSL2. Satu
catatan: kalau WSL2 kamu gak punya `systemd` aktif (`systemctl` gak ada),
setup DNS `systemd-resolved` gak akan jalan — `dev doctor` bakal bilang
"UNKNOWN" buat resolver, dan kamu perlu fallback manual (tambah entry
eksplisit per-project ke hosts file Windows, `C:\Windows\System32\drivers\etc\hosts`,
karena Windows gak punya wildcard DNS native tanpa software tambahan).

**Ke server (headless, tanpa GUI): ya, tapi dengan penyesuaian tujuan.**
Yang **langsung jalan tanpa ubahan**: Docker, CoreDNS, Caddy, generate
compose per-project, DB port-lock — semuanya headless-native, gak butuh GUI
sama sekali.

Yang **perlu dipikir ulang** kalau target-nya server (bukan cuma "laptop dev
tapi kebetulan gak ada monitor"):
1. **`dev trust`** — bagian `certutil`/browser trust store gak relevan
   (server gak punya browser lokal). Bagian `update-ca-trust` (system-wide)
   tetap berguna kalau ada service lain di server yang perlu percaya sertifikat
   internal ini.
2. **`*.test` DNS** — di server, domain `.test` cuma resolve ke `127.0.0.1`
   buat proses **di server itu sendiri**. Kalau mau diakses dari luar
   (device lain di jaringan/tim), CoreDNS-nya harus di-bind ke IP yang bisa
   diakses jaringan (bukan `127.0.0.1:53`), dan DNS server itu didaftarkan
   di resolver client-nya (router/`/etc/resolv.conf` tim) — bukan
   `resolved.conf.d` lokal per-mesin lagi.
3. **Port publish DB ke `127.0.0.1`** — desain sekarang sengaja cuma bind ke
   loopback (aman buat single-user laptop). Di server multi-tenant, ini
   perlu firewall/binding policy tambahan kalau mau tetap diakses (mis. lewat
   VPN/SSH tunnel, bukan expose langsung).
4. **`gclone`/`dev new` auto-`dev up`** — di server biasanya deployment
   dikontrol CI/CD, bukan clone interaktif manual. Pola ini tetap valid buat
   *staging/dev server bersama*, tapi bukan pengganti pipeline produksi.
5. **Workspace `work/`+`personal/`** — konvensi ini masuk akal buat laptop
   personal; di server tim, mungkin lebih pas jadi `work/` doang (gak ada
   konsep "personal" di server bersama).

**Ringkasnya:** inti arsitekturnya (Docker + Caddy + CoreDNS + generate
compose per-project) portable dan headless-native tanpa syarat. Yang perlu
disesuaikan itu spesifik ke **skala pemakaian** (single laptop vs server
bersama), bukan ke OS/platform-nya.

## 9. Riwayat perubahan penting (changelog ringkas)

| Tanggal | Perubahan |
|---|---|
| 2026-09-17 | Migrasi dari macOS/OrbStack ke Fedora native Docker. Ganti trust CA (Keychain → `update-ca-trust`+NSS), DNS (`/etc/resolver` → systemd-resolved), diagnostic OrbStack → `systemctl`/`resolvectl`. Tambah `dev new`, `gclone`, BuildKit cache mount di Dockerfile PHP. |
| 2026-09-17 | Fix bug `write_generated_compose()`: project tanpa Postgres bikin `dev up`/`restart` mati diam-diam (`set -e` + pola `has_db X && printf` yang salah). Fix serupa di `cmd_init`. Fix quoting label `caddy.respond` di fallback placeholder. |
| 2026-09-17 | Tambah dukungan **native macOS** (belum di-test live di Mac) + **cross-distro Linux** (Fedora/RHEL & Debian/Ubuntu) ke `require_docker`/`cmd_doctor`/`cmd_trust`. Windows didukung lewat WSL2 (otomatis kena jalur Linux). Tambah `install.sh` (bootstrap one-shot, idempotent). Repo dirapikan buat di-publish: `templates/` kosong dihapus, `CLAUDE.md`→`docs/MIGRATION-NOTES.md`, `.gitignore` ditambah. |

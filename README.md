# DevX

Author: [HafizHadrimaulana](https://github.com/HafizHadrimaulana) · © 2026,
all rights reserved — see [LICENSE](LICENSE). Public for reference/portfolio,
not for reuse/redistribution without permission.

Local polyglot project runtime wrapper for:

- `~/workspace/work/<project>`
- `~/workspace/personal/<project>`

Built on native Docker + Docker Compose, with a global Caddy edge (TLS) and
CoreDNS serving `*.test` to `127.0.0.1`.

> Setup dari nol? Lihat [SETUP.md](SETUP.md) — arsitektur, host setup,
> portabilitas. Riwayat migrasinya ada di
> [docs/MIGRATION-NOTES.md](docs/MIGRATION-NOTES.md). README ini murni
> reference command sehari-hari.

## Principle

`dev` automates **infra/runtime only**.

Automatic:

- detect the stack (multi-language) and generate a compose stack when needed
- sync safe base `.env` values (URLs, Vite host) — and DB creds **only** for
  generated stacks
- local domain + internal TLS
- start project containers
- stable, host-reachable DB ports for GUI tools (DBeaver etc.) — no proxy
  container, see [Database host access](#database-host-access--no-proxy-container)

Always manual (on purpose):

- `composer install`
- `npm install` / `pnpm install` / `yarn install` / `bun install`
- `pip install -r requirements.txt`
- `php artisan key:generate`, `migrate`, `db:seed`
- `go mod download`, `bundle install`, etc.

## Main flow

Fresh clone:

```bash
dev init      # detect + generate config (no containers)
dev up        # start infra + project stack
```

Then review `.env` and run the bootstrap commands your stack needs, e.g.:

```bash
dev composer install
dev npm install
dev artisan key:generate
dev artisan migrate
```

## Commands

Lifecycle:

- `dev init [--php-server=apache|nginx]`
- `dev up [--php-server=apache|nginx]`
- `dev down [--global]`
- `dev restart`
- `dev rebuild`
- `dev ps`
- `dev logs [args...]`   (e.g. `dev logs -f`)
- `dev shell`
- `dev exec <service> <cmd...>`
- `dev open`
- `dev doctor`
- `dev trust`

Runtime (executed inside the matching service container):

- `dev npm|npx|node|pnpm|yarn|bun <args...>`
- `dev php|artisan|composer <args...>`
- `dev python|py|pip <args...>`
- `dev go <args...>`
- `dev ruby|bundle|rails <args...>`

Runtime commands **start their service automatically** if it isn't running, so
`dev up` first is optional. This matters most for CLI-only projects, which have
no long-running server and are normally stopped between uses — there, a runtime
command is the only entry point. Starting a container is infra (dev's job);
installing dependencies inside it stays manual (yours).

Database (for host tools):

- `dev db info` — print host/port/credentials for the project's DB(s)

Database ports are published directly by the DB container itself, bound to
`127.0.0.1`, the moment the stack is up — no separate proxy step or container.
The host port is picked once per project (first `dev init`/`dev up`) and
locked in `.devx/.env` (`DEVX_DB_PORT_<SERVICE>`), so it never changes again —
not across `dev down`/`dev up`, not across a stop/start of just that one
container. Same shape as Laravel Sail's `FORWARD_DB_PORT` or DDEV's assigned
port: chosen once, persisted, reused, so a GUI client's saved connection never
needs re-editing.

## Shell aliases

Defined in `~/.zshrc` (not part of `dev` itself — user-local convenience):

| Alias | Expands to |
|---|---|
| `dcup` / `dcdown` | `dev up` / `dev down` |
| `dl` / `dclogs` | `dev logs -f` |
| `dps` | `dev ps` |
| `dsh` | `dev shell` |
| `drestart` | `dev restart` |
| `dart` | `dev artisan` |
| `dcomp` | `dev composer` |
| `ddb` | `dev db` |
| `ddball` | `dev-db-all` (DB info for every project at once) |
| `ddoc` | `dev doctor` |

## How detection works

`dev` looks at marker files in the project root:

| Stack   | Detected by                                   | Service name |
|---------|-----------------------------------------------|--------------|
| PHP     | `composer.json` (Laravel: `artisan`+dirs)     | `php` (+`web` in nginx mode) |
| Node    | `package.json`                                | `node`       |
| Python  | `requirements.txt` / `pyproject.toml` / `manage.py` | `python` |
| Go      | `go.mod`                                       | `go`         |
| Ruby    | `Gemfile`                                      | `ruby`       |
| Elixir  | `mix.exs`                                      | `elixir`     |

Node framework is auto-detected (Adonis / Nest / Next / Nuxt / Vite / generic)
to choose the right dev command and port. Python (Django/FastAPI/Flask) and
Ruby (Rails) similarly.

**Polyglot projects** get one container per language. The "web entry" (the
service that owns `https://<project>.<ws>.test`) is chosen automatically;
every other HTTP stack is exposed on a subdomain
`https://<service>.<project>.<ws>.test` (e.g. `go.myapp.work.test`).

**Versions** come from `.nvmrc` / `.node-version`, `.php-version` or composer
platform, `.python-version`, `.ruby-version`, `go.mod` — falling back to sane
defaults. Each project gets its own image tag, so multiple versions coexist
across projects.

**Databases**: MySQL, MariaDB, Postgres, Redis — multiple at once. Each is a
regular service (always started with the stack) with its own named volume.

## Generated PHP mode

- PHP extensions are detected from **both `composer.json` and `composer.lock`**
  — platform requirements (`ext-gd`, `ext-intl`, …) are usually declared by
  dependencies, not the root manifest, so scanning only the root builds an
  image that `composer install` then refuses to run on. Handled: bcmath, intl,
  gd, exif, pcntl, zip, redis (pecl), plus pdo_mysql/pdo_pgsql.
- default `nginx` (php-fpm + nginx), optional `apache`
- document root auto-set to `public/` for Laravel or when a `public/` dir
  exists; otherwise served from the project root
- opcache enabled in dev mode (revalidates on every request)

```bash
dev init --php-server=nginx
dev up   --php-server=nginx
```

## Laravel: writable directories

`dev init`/`dev up` recreate the runtime directories Laravel needs but git
doesn't carry — `storage/framework/{cache/data,sessions,testing,views}`,
`storage/app/public`, `storage/logs`, `bootstrap/cache`.

Many repos ignore these so broadly (a bare `/storage/framework/*` with no
`.gitkeep` escape) that they're simply absent after a clone, and Laravel then
500s with a message that names no path at all:

```
InvalidArgumentException: Please provide a valid cache path.
```

Creating them is idempotent, so this is a no-op where they already exist — it
just means a fresh clone never has to rediscover it, on any machine.

## Per-project override: `.devx.yml`

Drop a `.devx.yml` in the project root to override auto-detection. Everything
is optional. Requires `python3` on the host (used only to parse the file).

```yaml
web: php                       # service that owns the public domain
                                # ("none" = no Caddy/domain at all — for
                                # CLI/script-only projects with no HTTP server)
databases: [mysql, postgres, redis]   # which DBs to run (multi)

php:
  version: "8.3"
  server: nginx                # apache | nginx
  docroot: public              # public | .

node:
  version: "20"
  framework: adonis            # override auto-detect
  command: "node ace serve --hmr"
  port: 3333

python:
  version: "3.12"
  command: "python manage.py runserver 0.0.0.0:8000"
  port: 8000

go:
  version: "1.22"
  command: "go run ./cmd/server"
  port: 8090

ruby:
  version: "3.3"
  command: "bundle exec rails s -b 0.0.0.0"
  port: 3000
```

`databases` also accepts block-list form:

```yaml
databases:
  - mysql
  - redis
```

## Existing compose projects

If a project ships its own `docker-compose.yml` (or `compose.yml`), DevX keeps
its architecture and only writes a small `compose.override.yml` to wire it into
the `devx_ingress` network + Caddy. For these projects DevX **does not** touch
DB credentials in `.env` — they belong to the project's own compose.

## One-time host setup

Full step-by-step (Docker install, DNS, PATH) is in [SETUP.md](SETUP.md).
Short version:

- `*.test` resolver: route `.test` to `127.0.0.1` via systemd-resolved
  (drop-in at `/etc/systemd/resolved.conf.d/devx-test-tld.conf`)
- Trust the local CA (after the first `dev up`): `dev trust`

`dev doctor` checks both, plus two runtime health checks: whether the app
image's platform matches the one `node_modules` was installed for, and how many
running containers have this project mounted (it should be one — see Gotchas).

## Network topology (important)

Every generated project gets **two** networks:

| Network | Scope | Who joins |
|---|---|---|
| `devx_internal` | **private, per-project** (Compose prefixes it with the project name) | **every** service |
| `devx_ingress` | **shared by all projects** | **only** services Caddy must reach |

All inter-service traffic (app → database, nginx → php-fpm) resolves on
`devx_internal`, so service names are unique per project.

**Databases must never join `devx_ingress`.** If two projects both put a
container aliased `postgres` (or `redis`, `mysql`, `db`) on the shared network,
Docker's DNS returns both IPs and round-robins between them — roughly half the
queries silently land in the *other* project's database. The symptom is nasty:
intermittent `database "x" does not exist` errors, while `dev logs postgres`
stays clean because the error is produced by a container you aren't looking at.
Projects that ship their own compose keep their own private network; DevX's
override only attaches app-tier services (`app`/`web`/`api`/`frontend`/
`backend`/`node`) to `devx_ingress`, never databases. Databases get a
published host port added instead (see below) — a completely separate
mechanism from network membership.

### Database host access — no proxy container

Earlier versions used an on-demand `docker run` proxy (`alpine/socat`)
attached manually to the DB's network so DBeaver could reach it. That was
dropped: a container created outside Compose's lifecycle doesn't get
recreated when the project's network is regenerated, so it silently went
stale and started failing with `network ... not found` after any topology
change. It was also solving a problem that doesn't really exist on a single
local machine — the equivalent of Kubernetes' `kubectl port-forward`, which
exists because you don't want to expose a port on a *shared remote* cluster.
Locally there's nothing to protect.

Instead, DB services publish their port directly in compose, same as every
mainstream local-dev tool (Sail, DDEV, Lando) does:

```yaml
ports:
  - "127.0.0.1:5433:5432"
```

The host port isn't left to Docker to assign fresh on every start — that
would mean a GUI client's saved connection needs re-editing after every
`dev down`/`dev up`. Instead, `dev` picks
a free port once (`db_port_for` in `bin/dev`, scanning from 3307/5433/6380 for
mysql/postgres/redis) and locks it into `.devx/.env`. Every regeneration
reuses that same value, so the address is stable for the project's lifetime.
`dev db info` reads it straight from `.devx/.env` — no live Docker query
needed at all. To see every project's DB connection info at once (without
`cd`-ing into each one), run `dev-db-all` (aliased `ddball`) — it's a separate
script in `bin/`, not a `dev` subcommand.

## Where dependencies live

Node (`node_modules/`) and PHP (`vendor/`) install into the project directory,
which is bind-mounted, so they survive `dev down` for free. Python normally
doesn't — `pip` writes into the container's own site-packages, which dies with
the container, so a `dev down` silently wiped them and the next run failed with
`ModuleNotFoundError`. The generated Python service therefore sets
`PYTHONUSERBASE=/workspace/.devx/python-packages` + `PIP_USER=1`, putting
packages in the bind-mounted project dir like every other stack.

Note this dir can be large (a pandas/numpy install is ~150 MB), which is why
`<project>/.devx/` carries its own `.gitignore` containing `*` — the whole
folder is machine-local generated state and self-ignores, without DevX having
to edit the project's own `.gitignore`.

### Two different `.devx` folders — don't confuse them

- `~/workspace/.devx/` — **the tool itself** (`bin/dev`, this README,
  `lib/parse-manifest.py`, the Caddy CA). No `.env` lives here.
- `<project>/.devx/` — **generated config for that one project**
  (`.env`, `compose.generated.yml` or `compose.override.yml`, plus
  `python-packages/` where applicable). This is where `DEVX_DB_PORT_*` and
  everything else per-project actually lives. Self-ignoring via its own
  `.gitignore`.

If a project is deleted, its `<project>/.devx/` goes with it and its DB port
becomes free again for the next project. A fresh `dev init` allocates a new,
non-colliding port from scratch.

## Gotchas

- **Always install deps via `dev` (inside the container), never on the host.**
  Running `npm/pnpm install` on the host writes native binaries (esbuild,
  sharp, bcrypt, …) for the host's OS/arch, which then fail inside the Linux
  container if they differ (e.g. installing on macOS/arm64, running in a
  Linux/x86_64 container), with errors like
  `esbuild: Host version X does not match binary version Y`. Fix:
  `dev exec <svc> rm -rf node_modules && dev pnpm install` (or `dev npm install`).
- **pnpm/corepack vs Node version**: `dev pnpm`/`dev yarn` auto-bootstrap a
  Node-compatible package manager. If a project pins a specific one, add
  `"packageManager": "pnpm@x"` to package.json.
- **DBeaver "read 0 bytes" / can't connect**: the DB container is probably
  stopped. Start the stack (`dev up`) — the port itself won't have changed
  (it's locked in `.devx/.env`), so no need to re-check it unless that file
  was deleted or the project was re-inited from scratch.
- **Never run a second dev server against the same checkout.** `node_modules`
  is bind-mounted, so any on-disk cache a tool keeps inside it — Vite's
  `node_modules/.vite` is the usual one — is **shared by every container that
  mounts the project**. Two running servers/optimizers write it concurrently
  and corrupt it: chunk names change while the browser still holds the old
  `?v=` hash, so dep chunks start returning 504 and pages fail with
  `Failed to fetch dynamically imported module`. Run one-off tooling
  (audits, screenshots, scripts) **against the server that is already up**
  (`dev exec <svc> …`) instead of starting another one. Fix when it happens:
  `dev down && rm -rf node_modules/.vite && dev up`, then **hard-reload** the
  tab (it still holds the stale URLs).
- **A service image's platform must match what `node_modules` was installed
  for.** If a floating tag resolves to a different architecture than the one
  the deps were installed on — e.g. `node:24-alpine` pulled as `amd64` on an
  `arm64` host — the container dies on boot with a missing native binding
  (`Cannot find module '@swc/core-linux-x64-musl'`, similar for
  esbuild/rollup/lightningcss). Check with
  `docker image inspect <image> --format '{{.Architecture}} {{.Os}}'`, then
  either re-pull the native arch (`docker pull --platform linux/arm64
  <image>`) or reinstall deps inside the container.

## Notes

- Generated repos use the detected runtime stack.
- Existing repos with their own compose keep their architecture.
- Fix edge cases in `dev`, not per-project.
- Manifest parser: `~/workspace/.devx/lib/parse-manifest.py`

#!/usr/bin/env bash
# DevX — one-shot host bootstrap.
#
# Idempotent: safe to re-run on an already-set-up machine (every step checks
# "is this already done?" before doing it). Detects the OS/distro and runs
# the matching setup from SETUP.md end to end:
#   Docker engine → nss-tools/certutil → *.test DNS → shell PATH/aliases →
#   global infra (Caddy + CoreDNS) → verification.
#
# Usage:
#   ~/workspace/.devx/install.sh
#
# Must be run from the FINAL location (~/workspace/.devx) — bin/dev has this
# path hardcoded, it's not configurable via env var.

set -euo pipefail

DEVX_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
STEP=0

step() {
  STEP=$((STEP + 1))
  echo ""
  echo "── [${STEP}] $* ─────────────────────────────────────────"
}

ok()   { echo "  ✓ $*"; }
skip() { echo "  · $* (already done, skipping)"; }
warn() { echo "  ! $*"; }

require_expected_path() {
  local expected="${HOME}/workspace/.devx"
  if [[ "${DEVX_HOME}" != "${expected}" ]]; then
    warn "This script is running from ${DEVX_HOME}, but bin/dev hardcodes"
    warn "DEVX_HOME=${expected} — DevX will not work unless it's exactly there."
    warn "Move this whole folder to ${expected} and re-run."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker already installed and running"
    return
  fi

  case "${OS}" in
    Darwin)
      if command -v docker >/dev/null 2>&1; then
        warn "Docker CLI found but daemon not reachable — start Docker Desktop (or OrbStack) manually, then re-run this script."
        exit 1
      fi
      warn "Docker not found. Install Docker Desktop or OrbStack manually (GUI apps aren't scriptable here):"
      echo "      brew install --cask docker      # Docker Desktop, or:"
      echo "      brew install --cask orbstack    # lighter alternative"
      echo "    Then start it once from Applications, and re-run this script."
      exit 1
      ;;
    Linux)
      if command -v dnf >/dev/null 2>&1; then
        echo "  Fedora/RHEL family detected (dnf)."
        sudo dnf -y install dnf-plugins-core
        sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nss-tools
      elif command -v apt-get >/dev/null 2>&1; then
        echo "  Debian/Ubuntu family detected (apt)."
        sudo apt-get update
        sudo apt-get -y install ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
          | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update
        sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin libnss3-tools
      else
        warn "Unknown Linux distro (no dnf or apt-get). Install Docker Engine manually: https://docs.docker.com/engine/install/"
        exit 1
      fi
      sudo systemctl enable --now docker
      sudo usermod -aG docker "${USER}"
      warn "Added ${USER} to the 'docker' group. This needs a fresh login session"
      warn "to take effect everywhere (a plain 'newgrp docker' only fixes THIS shell)."
      ;;
    *)
      warn "Unrecognized OS: ${OS}. Install Docker manually, then re-run."
      exit 1
      ;;
  esac
  ok "Docker installed"
}

# ---------------------------------------------------------------------------
# 2. *.test DNS
# ---------------------------------------------------------------------------
setup_dns() {
  case "${OS}" in
    Darwin)
      if [[ -f /etc/resolver/test ]] && grep -q '127\.0\.0\.1' /etc/resolver/test 2>/dev/null; then
        skip "*.test resolver"
        return
      fi
      sudo mkdir -p /etc/resolver
      echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/test >/dev/null
      ok "*.test → 127.0.0.1 (macOS resolver)"
      ;;
    Linux)
      if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        warn "systemd-resolved not active (WSL2 without systemd?). Skipping DNS setup —"
        warn "see SETUP.md for the hosts-file fallback."
        return
      fi
      local conf=/etc/systemd/resolved.conf.d/devx-test-tld.conf
      if [[ -f "${conf}" ]] && grep -q '^Domains=~test' "${conf}" 2>/dev/null; then
        skip "*.test resolver"
        return
      fi
      sudo mkdir -p /etc/systemd/resolved.conf.d
      sudo tee "${conf}" >/dev/null <<'EOF'
[Resolve]
DNS=127.0.0.1
Domains=~test
EOF
      sudo systemctl restart systemd-resolved
      ok "*.test → 127.0.0.1 (systemd-resolved)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 3. Shell integration (PATH, aliases, gclone, dev new is built into bin/dev)
# ---------------------------------------------------------------------------
setup_shell() {
  local rc="${HOME}/.zshrc"
  [[ "${SHELL:-}" == */bash ]] && rc="${HOME}/.bashrc"

  if grep -q "# --- DevX shell integration ---" "${rc}" 2>/dev/null; then
    skip "shell integration in ${rc}"
    return
  fi

  cat >> "${rc}" <<'DEVXRC'

# --- DevX shell integration ---
export PATH="$HOME/workspace/.devx/bin:$PATH"

alias dcup="dev up"
alias dcdown="dev down"
alias dl="dev logs -f"
alias dclogs="dev logs -f"
alias dps="dev ps"
alias dsh="dev shell"
alias drestart="dev restart"
alias dart="dev artisan"
alias dcomp="dev composer"
alias ddb="dev db"
alias ddball="dev-db-all"
alias ddoc="dev doctor"

# Clone a repo into ~/workspace/{work,personal}/<repo> and bring it up.
# A shell function (not a bin/ script) on purpose — it needs to `cd` the
# interactive shell into the cloned project, which a subprocess can't do.
gclone() {
  local group="work"
  local args=()
  local a
  for a in "$@"; do
    if [[ "${a}" == "--personal" ]]; then
      group="personal"
    else
      args+=("${a}")
    fi
  done
  if [[ ${#args[@]} -eq 0 ]]; then
    echo "gclone: usage: gclone [--personal] <git-clone-args...>" >&2
    return 1
  fi

  local target_dir="${HOME}/workspace/${group}"
  mkdir -p "${target_dir}"

  local tmp_log
  tmp_log="$(mktemp)"
  ( cd "${target_dir}" && git clone "${args[@]}" ) 2> >(tee "${tmp_log}" >&2)
  local status=$?
  if [[ ${status} -ne 0 ]]; then
    rm -f "${tmp_log}"
    return ${status}
  fi

  local dirname
  dirname="$(sed -n "s/^Cloning into '\(.*\)'\.\.\.\$/\1/p" "${tmp_log}" | head -n1)"
  rm -f "${tmp_log}"
  if [[ -z "${dirname}" ]]; then
    echo "gclone: couldn't determine cloned directory name" >&2
    return 1
  fi

  cd "${target_dir}/${dirname}" || return 1
  dev up
}
# --- end DevX shell integration ---
DEVXRC
  ok "Shell integration appended to ${rc} (restart your shell, or 'source ${rc}')"
}

# ---------------------------------------------------------------------------
# 4. Global infra
# ---------------------------------------------------------------------------
bring_up_infra() {
  mkdir -p "${HOME}/workspace/work" "${HOME}/workspace/personal"
  if ! docker info >/dev/null 2>&1; then
    warn "Docker isn't reachable in THIS shell yet (group membership needs a"
    warn "fresh login on Linux). Run manually once that's sorted:"
    echo "      cd ${DEVX_HOME} && docker compose -p devx-global -f compose.global.yml up -d"
    return
  fi
  (cd "${DEVX_HOME}" && docker compose -p devx-global -f compose.global.yml up -d)
  ok "Global infra (Caddy + CoreDNS) is up"
}

# ---------------------------------------------------------------------------
main() {
  echo "DevX bootstrap — detected OS: ${OS}"
  require_expected_path
  step "Docker"; install_docker
  step "*.test DNS"; setup_dns
  step "Shell integration (PATH, aliases, gclone)"; setup_shell
  step "Global infra"; bring_up_infra

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo " Next steps:"
  echo "  1. Restart your terminal (or 'newgrp docker' for THIS shell only)"
  echo "  2. gclone <owner>/<repo>          # clone + auto dev up"
  echo "  3. dev trust                      # after the first project is up"
  echo "  4. dev doctor                     # verify everything is green"
  echo " Full reference: README.md · SETUP.md"
  echo "════════════════════════════════════════════════════════════"
}

main "$@"

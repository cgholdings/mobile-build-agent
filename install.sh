#!/bin/bash
# install.sh — set up (or refresh) this Mac as a cg mobile build agent.
#
# Safe + idempotent: re-running on an already-configured machine won't clobber config.yaml, an
# existing base image, or your AppRole secret_id. It renders host-specific files from templates
# based on WHERE this repo is cloned and WHICH user runs it, so it works on any path / username.
#
#   ./install.sh                 # full guided setup
#   AGENT_NAME=mac-m4-02 ./install.sh
#   SKIP_IMAGE=1 ./install.sh    # skip the ~45-min base-image build (do it later: make image)
#
# What it does NOT do (needs your sudo / a decision — see GO-LIVE.md):
#   headless hardening (FileVault/auto-login/power), the pf VM->Vault bridge (make bridge-install).
set -uo pipefail

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$AGENT_DIR"
export PATH="/opt/homebrew/bin:$PATH"
BREW="/opt/homebrew/bin/brew"
: "${AGENT_NAME:=$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
: "${WORKSPACE:=$HOME/build-workspace}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33m!!\033[0m  %s\n' "$*"; }
ask()  { local a; read -r -p "    $1 [y/N] " a; [[ "$a" == [yY]* ]]; }

say "cg build agent installer"
echo "    dir:       $AGENT_DIR"
echo "    user:      $(id -un) (uid $(id -u))"
echo "    agent name: $AGENT_NAME"
echo "    workspace: $WORKSPACE"

# ---- 1. host prerequisites (Homebrew packages) ------------------------------
say "1/7  host tools"
if [ ! -x "$BREW" ]; then
  warn "Homebrew not found at $BREW."
  warn "Install it first (needs your password): https://brew.sh — then re-run this script."
  exit 1
fi
for pkg in tart hashicorp/tap/vault python@3.12 git; do
  name="${pkg##*/}"
  if "$BREW" list "$name" >/dev/null 2>&1 || command -v "$name" >/dev/null 2>&1; then
    ok "$name present"
  else
    say "    installing $pkg (brew — no sudo)"
    "$BREW" install "$pkg" || warn "brew install $pkg failed — install it manually and re-run"
  fi
done
command -v tart  >/dev/null 2>&1 && ok "tart  $(tart --version 2>/dev/null)"
command -v vault >/dev/null 2>&1 && ok "vault $(vault version 2>/dev/null | head -1)"

# ---- 2. python venv ---------------------------------------------------------
say "2/7  python venv + deps"
make -s deps && ok "venv ready" || { warn "make deps failed"; exit 1; }

# ---- 3. bootstrap CA --------------------------------------------------------
say "3/7  bootstrap CA (for initial TLS to Vault)"
mkdir -p vault secrets logs
if [ -s vault/platform-ca.crt ]; then
  ok "vault/platform-ca.crt already present (Vault Agent keeps it fresh)"
elif [ -s platform-ca.crt ]; then
  cp platform-ca.crt vault/platform-ca.crt && ok "seeded vault/platform-ca.crt from bootstrap CA"
else
  warn "no platform-ca.crt to seed — copy the internal platform CA to vault/platform-ca.crt"
fi

# ---- 4. render config + vault-agent.hcl -------------------------------------
say "4/7  render config.yaml + vault-agent.hcl"
AGENT_NAME="$AGENT_NAME" WORKSPACE="$WORKSPACE" make -s config
mkdir -p "$WORKSPACE" && ok "workspace $WORKSPACE"

# ---- 5. AppRole credentials -------------------------------------------------
say "5/7  Vault AppRole credentials (mobile-build-agent)"
if [ -s secrets/vault_role_id ]; then ok "secrets/vault_role_id present"
else
  warn "secrets/vault_role_id missing."
  read -r -p "    paste the AppRole role_id (or leave blank to add later): " rid
  [ -n "$rid" ] && { printf '%s' "$rid" > secrets/vault_role_id; chmod 600 secrets/vault_role_id; ok "role_id written"; }
fi
if [ -s secrets/vault_secret_id ]; then ok "secrets/vault_secret_id present"
else
  warn "secrets/vault_secret_id missing (this is the sensitive one; get a fresh response-wrapped token)."
  read -r -p "    paste a Vault wrapping token to unwrap now (or leave blank): " wrap
  if [ -n "$wrap" ]; then
    make -s secret-id WRAP="$wrap" && ok "secret_id unwrapped" || warn "unwrap failed — check the token/CA and run: make secret-id WRAP=..."
  fi
fi

# ---- 6. base VM image -------------------------------------------------------
say "6/7  base VM image (mobile-builder-base)"
if tart list 2>/dev/null | grep -q mobile-builder-base; then
  ok "mobile-builder-base already built"
elif [ "${SKIP_IMAGE:-0}" = "1" ]; then
  warn "skipped (SKIP_IMAGE=1). Build later with: make image  (~45 min, large download)"
elif ask "build the base image now? (~45 min, ~90 GB download)"; then
  make image
else
  warn "skipped. Build later with: make image"
fi

# ---- 7. install + start services -------------------------------------------
say "7/7  launchd services (Vault Agent + build agent)"
if [ ! -s secrets/vault_secret_id ]; then
  warn "no secret_id yet — Vault Agent can't authenticate, so the build agent won't get creds."
  warn "Add it (make secret-id WRAP=...) then run: make install"
elif ask "install and start the LaunchAgents now?"; then
  make install
else
  warn "skipped. Start later with: make install"
fi

say "done"
cat <<EOF
    Next steps / verification:
      make status                 # services + Vault renders
      make verify                 # venv, image, broker reachability, seeds
      tail -f logs/agent.out.log  # expect: "connected; ... Agent online."

    Still manual (need sudo / a decision — see GO-LIVE.md):
      make bridge-install         # pf VM->Vault bridge (so build VMs can reach internal Vault)
      make harden-all             # FileVault off + auto-login + no-sleep (headless auto-start)

    A new machine also needs, cluster-side: the RabbitMQ user + this agent's AppRole seeded in Vault.
EOF

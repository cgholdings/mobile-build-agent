#!/bin/bash
# One-shot health check + repair for the whole build-agent chain, restarting each service cleanly
# in dependency order. Idempotent: every step checks first and skips when already healthy, so it is
# safe to run any time — as a diagnosis tool as much as a fix.
#
# Order is not arbitrary; each layer depends on the one above it:
#   1. VPN          the host must reach Vault and the broker at all
#   2. pf bridge    /etc/pf.conf anchor reference + the NAT rule, so *VMs* can reach Vault
#   3. Vault Agent  authenticates, renders the CA + RabbitMQ creds the build agent reads
#   4. VM check     proves the VM->Vault path end to end — no static check on the host can
#   5. build agent  consumes the rendered creds; stopped first, started last
#
# Usage:  make repair              full run (prompts for sudo at step 2)
#         make repair FORCE=1      proceed even if builds are in flight (they get killed)
#         make repair SKIP_VM=1    skip the ~2 min end-to-end VM check
set -u
export PATH=/opt/homebrew/bin:$PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANCHOR="cgh-vault-bridge"
PFCONF="/etc/pf.conf"
VAULT_HOST="vault.tech.cgholdings.internal"
BROKER_HOST="rabbitmq.tech.cgholdings.internal"
BRIDGE_SVC="com.cgholdings.vault-bridge"
VAULT_SVC="com.cgholdings.vault-agent"
BUILD_SVC="com.cgholdings.buildagent"
GUI="gui/$(id -u)"
LA="$HOME/Library/LaunchAgents"
DAEMON_PLIST="/Library/LaunchDaemons/$BRIDGE_SVC.plist"
FORCE="${FORCE:-0}"
SKIP_VM="${SKIP_VM:-0}"

FAILED=0
step() { echo; echo "=== $* ==="; }
ok()   { echo "  ok    $*"; }
info() { echo "  ..    $*"; }
warn() { echo "  WARN  $*"; }
bad()  { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
die()  { echo; echo "ABORTED: $*"; exit 1; }

# Wait until `cmd` succeeds, up to $1 seconds. Usage: wait_for <secs> <label> <cmd...>
# `cmd` runs in this shell, so the predicates below can be plain functions.
wait_for() {
  local secs=$1 label=$2; shift 2
  local deadline=$((SECONDS + secs))
  while [ $SECONDS -lt $deadline ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  warn "timed out after ${secs}s waiting for $label"
  return 1
}

running_build_vms() { tart list 2>/dev/null | awk '$NF == "running" && $2 ~ /^build-/ { print $2 }'; }

# start-agent.sh execs `python agent.py` with a *relative* path, so the agent dir never appears in
# the command line — match the bare script name, scoped to this user, and trust launchd first.
build_agent_stopped() {
  launchctl list 2>/dev/null | grep -q "$BUILD_SVC" && return 1
  pgrep -qU "$(id -u)" -f 'agent\.py' && return 1
  return 0
}
nat_rule_on_utun() { sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q 'on utun'; }
token_is_fresh()   { [ "$(stat -f %m "$HERE/vault/token" 2>/dev/null || echo 0)" -gt "$TOKEN_MTIME_BEFORE" ]; }
agent_online()     { tail -5 "$HERE/logs/agent.out.log" 2>/dev/null | grep -q 'Agent online'; }

# ---- 1. VPN -------------------------------------------------------------------------------
step "1/6  VPN reachability (host)"
if nc -z -G 6 "$VAULT_HOST" 443 >/dev/null 2>&1; then
  ok "$VAULT_HOST:443 reachable"
else
  die "host cannot reach $VAULT_HOST:443 — the VPN is down. Nothing below can work; reconnect and re-run."
fi
if nc -z -G 6 "$BROKER_HOST" 5671 >/dev/null 2>&1; then
  ok "$BROKER_HOST:5671 reachable"
else
  warn "$BROKER_HOST:5671 unreachable — the build agent will idle and retry until it comes back"
fi

# Gate BEFORE anything disruptive. Reloading pf and bouncing the bridge daemon are both far less
# invasive than killing the agent, but they still touch the network path a running build depends on
# — so nothing gets restarted until we know the machine is idle.
vms=$(running_build_vms)
if [ -n "$vms" ]; then
  echo "  builds are in flight:"; echo "$vms" | sed 's/^/    /'
  if [ "$FORCE" != 1 ]; then
    die "refusing to touch a machine mid-build. Wait for these to finish, or re-run with: make repair FORCE=1
        (to inspect without changing anything: make bridge-status)"
  fi
  warn "FORCE=1 — proceeding; these builds will be killed"
else
  ok "no builds in flight"
fi

# ---- 2. pf bridge (SUDO) ------------------------------------------------------------------
# The failure this whole script exists for: /etc/pf.conf gets reset to stock by a macOS update and
# loses the anchor reference. The rule still loads into the anchor, pf just never evaluates it.
step "2/6  pf VM->Vault bridge  (needs sudo)"
sudo -v || die "sudo is required to inspect and load pf rules"

# Delegated to the daemon script's one-shot mode so the pf-editing logic exists in one place only.
# It reloads the main ruleset when it repairs, which flushes the anchor — step 3 re-adds the rule.
if sudo bash "$HERE/bridge-vault.sh" --ensure-anchor; then
  ok "anchor '$ANCHOR' is referenced by the live ruleset"
else
  bad "anchor '$ANCHOR' still not referenced — pf will ignore the NAT rule; see $PFCONF"
fi

sudo pfctl -s info 2>/dev/null | grep -q '^Status: Enabled' \
  && ok "pf is enabled" \
  || { info "pf was disabled — enabling"; sudo pfctl -e 2>/dev/null; }

# ---- 3. bridge daemon ----------------------------------------------------------------------
step "3/6  bridge daemon ($BRIDGE_SVC)"
if [ ! -f "$DAEMON_PLIST" ]; then
  warn "daemon not installed — installing"
  sed -e "s|__AGENT_DIR__|$HERE|g" "$HERE/$BRIDGE_SVC.plist.tmpl" > "/tmp/$BRIDGE_SVC.plist"
  sudo cp "/tmp/$BRIDGE_SVC.plist" "$DAEMON_PLIST"
  sudo chown root:wheel "$DAEMON_PLIST"
  sudo chmod 644 "$DAEMON_PLIST"
  sudo launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null
else
  # Restart unconditionally: step 2 may have flushed the anchor, and this reloads it in seconds.
  info "restarting to reload the NAT rule"
  sudo launchctl kickstart -k "system/$BRIDGE_SVC" 2>/dev/null \
    || sudo launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null
fi

wait_for 40 "the NAT rule to load on a utun interface" nat_rule_on_utun
# pfctl expands the IP list into one rule per Vault IP, so this is normally 2 lines — print them
# as lines rather than folding them into the message.
if rules=$(sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep 'on utun'); then
  ok "NAT rule active ($(echo "$rules" | grep -c .) rules):"
  echo "$rules" | sed 's/^/          /'
else
  bad "no NAT rule on a utun interface — check /var/log/cgh-vault-bridge.log"
fi

# ---- 4. stop the build agent cleanly --------------------------------------------------------
step "4/6  stopping the build agent"
if launchctl list | grep -q "$BUILD_SVC"; then
  # The agent handles SIGTERM by finishing its current job first, so give it room before we move on.
  launchctl bootout "$GUI/$BUILD_SVC" 2>/dev/null
  wait_for 30 "the build agent to exit" build_agent_stopped
fi
build_agent_stopped && ok "build agent stopped" || warn "build agent process still alive — continuing anyway"

# ---- 5. Vault Agent -------------------------------------------------------------------------
step "5/6  Vault Agent ($VAULT_SVC)"
TOKEN_MTIME_BEFORE=$(stat -f %m "$HERE/vault/token" 2>/dev/null || echo 0)
if launchctl list | grep -q "$VAULT_SVC"; then
  launchctl kickstart -k "$GUI/$VAULT_SVC"
else
  warn "not loaded — bootstrapping"
  launchctl bootstrap "$GUI" "$LA/$VAULT_SVC.plist" 2>/dev/null
fi
# A fresh token mtime proves it re-authenticated against Vault, not just that the process restarted.
wait_for 30 "a freshly written token" token_is_fresh \
  && ok "re-authenticated (token rewritten)" \
  || bad "no fresh token — AppRole creds expired? see logs/vault-agent.err.log"

for f in vault/token vault/platform-ca.crt vault/rabbitmq.env; do
  [ -s "$HERE/$f" ] && ok "rendered $f" || bad "missing/empty $f — see logs/vault-agent.err.log"
done

# ---- 6. end-to-end VM check -----------------------------------------------------------------
# The one check that would have caught the outage: everything on the host looks healthy when the
# anchor is unreferenced, because the host reaches Vault directly and never needs the NAT.
if [ "$SKIP_VM" = 1 ]; then
  step "6/6  VM->Vault check  (skipped: SKIP_VM=1)"
elif ! tart list 2>/dev/null | grep -q mobile-builder-base; then
  step "6/6  VM->Vault check"
  warn "base image 'mobile-builder-base' missing — skipping (make image)"
else
  step "6/6  VM->Vault check  (boots a throwaway VM, ~2 min)"
  # 'verify-' prefix so a stranded probe is swept up by `make clean`.
  probe="verify-vault-$$"
  cleanup_probe() { tart stop "$probe" >/dev/null 2>&1; sleep 1; tart delete "$probe" >/dev/null 2>&1; }
  trap cleanup_probe EXIT
  tart clone mobile-builder-base "$probe" >/dev/null 2>&1
  tart run "$probe" --no-graphics >/dev/null 2>&1 &
  ip=""
  for _ in $(seq 1 40); do ip=$(tart ip "$probe" 2>/dev/null); [ -n "$ip" ] && break; sleep 3; done
  if [ -z "$ip" ]; then
    bad "probe VM never got an IP — cannot verify the VM->Vault path"
  else
    info "probe VM at $ip — connecting to Vault through the bridge"
    # -k on purpose: this probes reachability through the NAT, not TLS trust (the probe VM has no
    # platform CA). curl prints "HTTP 000" when the connection never lands — that is the failure.
    if "$HERE/.venv/bin/python" "$HERE/vmexec.py" "$ip" \
         "curl -sS -k --max-time 15 -o /dev/null -w 'HTTP %{http_code}\n' https://$VAULT_HOST/v1/sys/health" 2>&1 \
         | grep -q 'HTTP [1-9]'; then
      ok "VM reached $VAULT_HOST — the bridge works end to end"
    else
      bad "VM still cannot reach $VAULT_HOST:443 — builds will fail at load_vault_secrets"
    fi
  fi
  cleanup_probe
  trap - EXIT
fi

# ---- start the build agent last --------------------------------------------------------------
step "starting the build agent"
launchctl bootstrap "$GUI" "$LA/$BUILD_SVC.plist" 2>/dev/null || launchctl kickstart -k "$GUI/$BUILD_SVC"
wait_for 40 "the agent to connect to the broker" agent_online \
  && ok "agent online and consuming" \
  || bad "agent did not come online — see logs/agent.out.log"
tail -2 "$HERE/logs/agent.out.log" 2>/dev/null | sed 's/^/  /'

echo
if [ "$FAILED" -eq 0 ]; then
  echo "repair complete — chain healthy (VPN -> pf bridge -> Vault Agent -> VM -> build agent)"
else
  echo "repair finished with $FAILED unresolved problem(s) — see FAIL lines above"
fi
exit $((FAILED > 0))

#!/bin/bash
# LaunchDaemon worker (runs as root). Keeps the scoped VM->Vault pf NAT loaded on the *live* VPN
# interface, so ephemeral Tart build VMs can reach the internal Vault after a reboot / VPN reconnect.
#
# Self-healing: it detects the VPN tunnel by which interface carries the route to Vault (handles
# utunN renumbering), (re)loads the anchor whenever that changes, and keeps pf enabled. Scoped to
# Vault's IPs only — no other internal host becomes reachable from VMs.
#
# Requires /etc/pf.conf to reference the anchor once (persists across reboot):
#     nat-anchor "cgh-vault-bridge"
set -u

VAULT_IPS="10.10.2.142, 10.10.3.165"   # Vault LB IPs — keep in sync if they change
VMNET="192.168.64.0/24"                 # Tart vmnet subnet
ANCHOR="cgh-vault-bridge"
PROBE_IP="10.10.3.165"                  # any Vault IP; used to discover the VPN interface
LOG="/var/log/cgh-vault-bridge.log"

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }

log "vault-bridge daemon started"
last_if=""
while true; do
  # Which interface currently routes to Vault? (the VPN tunnel; empty if VPN is down)
  vpn_if=$(route -n get "$PROBE_IP" 2>/dev/null | awk '/interface:/{print $2}')
  if [ -n "$vpn_if" ]; then
    rule="nat on $vpn_if inet from $VMNET to { $VAULT_IPS } -> ($vpn_if)"
    if [ "$vpn_if" != "$last_if" ] || ! pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q "on $vpn_if "; then
      if echo "$rule" | pfctl -a "$ANCHOR" -f - 2>>"$LOG"; then
        pfctl -e 2>/dev/null || true      # ensure pf is enabled (no-op if already on)
        log "loaded VM->Vault bridge on $vpn_if"
        last_if="$vpn_if"
      else
        log "WARN: failed to load anchor on $vpn_if (is 'nat-anchor \"$ANCHOR\"' in /etc/pf.conf?)"
      fi
    fi
  elif [ -n "$last_if" ]; then
    log "VPN interface gone; bridge inactive until it returns"
    last_if=""
  fi
  sleep 30
done

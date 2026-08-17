#!/bin/bash
# LaunchDaemon worker (runs as root). Keeps the scoped VM->Vault pf NAT loaded on the *live* VPN
# interface, so ephemeral Tart build VMs can reach the internal Vault after a reboot / VPN reconnect.
#
# Self-heals three separate things. Each has broken in production:
#   1. the VPN interface  — utunN renumbers across reconnects
#   2. the anchor rule    — flushed whenever anything reloads the main pf ruleset
#   3. the anchor *reference* in /etc/pf.conf — a macOS update resets that file to stock. pf never
#      evaluates an unreferenced anchor, yet `pfctl -a <anchor> -f -` still reports success, so the
#      check for (2) passes while the NAT is dead. That silently broke every build for three days
#      after the 2026-08-14 update: VMs timed out on Vault, the host was unaffected (it routes to
#      Vault directly and needs no NAT), and this log kept saying "loaded".
#
# Scoped to Vault's IPs only — no other internal host becomes reachable from VMs.
#
# Knobs (set via EnvironmentVariables in the plist):
#   REPAIR_PFCONF=0   report a missing anchor reference, but never edit /etc/pf.conf
#
# Also usable as a one-shot: `bridge-vault.sh --ensure-anchor` checks/repairs the anchor reference,
# prints what it did and exits (repair.sh and `make bridge-anchor` use this, so the pf-editing
# logic lives in exactly one place).
set -u

VAULT_IPS="10.10.2.142, 10.10.3.165"   # Vault LB IPs — keep in sync if they change
VMNET="192.168.64.0/24"                 # Tart vmnet subnet
ANCHOR="cgh-vault-bridge"
PROBE_IP="10.10.3.165"                  # any Vault IP; used to discover the VPN interface
PFCONF="/etc/pf.conf"
INTERVAL=30
REPAIR_PFCONF="${REPAIR_PFCONF:-1}"
LOG="/var/log/cgh-vault-bridge.log"
ONESHOT=0; [ "${1:-}" = "--ensure-anchor" ] && ONESHOT=1
# A failed redirect prints to the terminal *before* `2>/dev/null` applies, so probe the log once
# here and fall back rather than letting every write spray "Permission denied" when not root.
touch "$LOG" 2>/dev/null || LOG=/dev/null

log() {
  echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null
  [ "$ONESHOT" = 1 ] && echo "  $*"
  return 0
}

# Log *persistent* failures once per state change, then only every FAIL_RELOG_TICKS ticks.
# Some failures (a pf.conf we cannot safely edit) never clear on their own, and at one tick per 30s
# the naive version buries the log in thousands of lines a day.
#
# Failures are buffered per tick and keyed on the tick's whole signature set, not per message: one
# bad tick emits several different messages, and rate-limiting them individually rate-limits
# nothing — the signatures just alternate and every one looks new.
#
# Everything a tick has to say — successes included — goes into one ordered buffer, flushed at the
# end of the tick. Buffering only the failures would print them after the successes they preceded,
# so a self-heal would read "...fixed it" followed by "...it is broken".
FAIL_RELOG_TICKS=60          # ~30 min at INTERVAL=30
last_fail=""
fail_ticks=0
cycle_sig=""
tick_msgs=()
emit() {                     # emit <message...>  — ordinary in-loop message
  if [ "$ONESHOT" = 1 ]; then log "$*"; return 0; fi   # one-shot: nothing flushes, so log now
  tick_msgs+=("$*")
  return 0
}
log_fail() {                 # log_fail <signature> <message...>
  local sig=$1; shift
  cycle_sig="$cycle_sig|$sig"
  emit "$@"
}
flush_fails() {
  # A tick with no failures always prints. A repeat of the previous tick's failure set stays quiet.
  if [ -z "$cycle_sig" ] || [ "$cycle_sig" != "$last_fail" ] || [ "$fail_ticks" -ge "$FAIL_RELOG_TICKS" ]; then
    # Guard the count: /bin/bash here is 3.2, where "${arr[@]}" on an empty array is an unbound
    # variable under `set -u` — which would kill the daemon on the first quiet tick.
    local m
    if [ ${#tick_msgs[@]} -gt 0 ]; then
      for m in "${tick_msgs[@]}"; do log "$m"; done
    fi
    last_fail="$cycle_sig"
    fail_ticks=0
  fi
  cycle_sig=""
  tick_msgs=()
}
clear_fail() { last_fail=""; fail_ticks=0; }
tick_end()   { flush_fails; sleep "$INTERVAL"; }

# Is the anchor referenced by the *live* main ruleset? (not just present in the file — the file can
# be correct while the loaded ruleset predates the edit)
anchor_referenced() { pfctl -s nat 2>/dev/null | grep -q "\"$ANCHOR\""; }
pf_enabled()        { pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; }
rule_loaded()       { pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q "on $1 "; }

# Insert `nat-anchor "cgh-vault-bridge"` into /etc/pf.conf, immediately after the com.apple
# nat-anchor. Position matters: pf requires translation rules before filter rules, so appending
# at EOF (after `anchor "com.apple/*"`) fails to parse.
repair_pfconf_file() {
  if ! grep -q '^nat-anchor "com\.apple/\*"$' "$PFCONF"; then
    log_fail noapple "ERROR: no 'nat-anchor \"com.apple/*\"' line in $PFCONF — cannot place the anchor safely; fix by hand"
    return 1
  fi
  local tmp backup
  backup="$PFCONF.bak-$(date '+%F-%H%M%S')"
  tmp=$(mktemp) || return 1
  awk -v a="$ANCHOR" '
    { print }
    /^nat-anchor "com\.apple\/\*"$/ && !ins { print "nat-anchor \"" a "\""; ins = 1 }
  ' "$PFCONF" >"$tmp" || { rm -f "$tmp"; return 1; }

  # Never install a ruleset we have not parsed — a bad /etc/pf.conf breaks pf for the whole host.
  if ! pfctl -n -f "$tmp" 2>>"$LOG"; then
    log_fail badparse "ERROR: repaired $PFCONF failed 'pfctl -n -f' validation — leaving the original in place"
    rm -f "$tmp"
    return 1
  fi
  cp "$PFCONF" "$backup" && cat "$tmp" >"$PFCONF" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  emit "repaired $PFCONF (backup: $backup)"
}

# Make sure the live ruleset references the anchor, repairing the file first if needed.
# Returns 0 when it reloaded the main ruleset — which flushes anchor contents, so the caller must
# then re-load the NAT rule. Returns 1 when nothing needed doing (or the repair failed).
ensure_anchor_ref() {
  anchor_referenced && return 1

  if ! grep -q "^nat-anchor \"$ANCHOR\"" "$PFCONF"; then
    if [ "$REPAIR_PFCONF" != 1 ]; then
      log_fail norepair "WARN: $PFCONF does not reference anchor '$ANCHOR' and REPAIR_PFCONF=0 — VM->Vault NAT is INACTIVE"
      return 1
    fi
    log_fail noref "WARN: $PFCONF lost its '$ANCHOR' reference (OS update reset it?) — VM->Vault NAT is inactive; repairing"
    repair_pfconf_file || return 1
  else
    log_fail stale "anchor '$ANCHOR' is in $PFCONF but not in the live ruleset — reloading"
  fi

  if pfctl -f "$PFCONF" 2>>"$LOG" && anchor_referenced; then
    emit "main ruleset reloaded; anchor '$ANCHOR' is referenced again"
    return 0
  fi
  log_fail stillnoref "ERROR: reloaded $PFCONF but anchor '$ANCHOR' still is not referenced"
  return 1
}

if [ "$ONESHOT" = 1 ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "  --ensure-anchor needs root (pf inspection + /etc/pf.conf) — use: make bridge-anchor"
    exit 1
  fi
  if anchor_referenced; then
    echo "  anchor '$ANCHOR' already referenced by the live ruleset"
    exit 0
  fi
  ensure_anchor_ref
  anchor_referenced && exit 0 || exit 1
fi

log "vault-bridge daemon started (pfconf repair: $([ "$REPAIR_PFCONF" = 1 ] && echo on || echo off))"
last_if="?"   # sentinel, not "": makes the first tick log its verdict even if the VPN is already down
while true; do
  fail_ticks=$((fail_ticks + 1))
  # Which interface currently routes to Vault? With the VPN down this does NOT go empty — the
  # lookup falls through to the default route and returns the LAN interface, so match on utun*
  # rather than on "non-empty". Loading the NAT on en1 would be useless (no route to Vault that
  # way) and, worse, would make this log read healthy while the VPN was down.
  vpn_if=$(route -n get "$PROBE_IP" 2>/dev/null | awk '/interface:/{print $2}')
  case "$vpn_if" in
    utun*) ;;
    *)
      log_fail "vpndown-$vpn_if" \
        "VPN down (route to Vault now via '${vpn_if:-none}'); bridge inactive until the tunnel returns"
      last_if=""
      tick_end; continue ;;
  esac

  # A reference repair reloads the main ruleset, which flushes the anchor — force a rule reload.
  forced=0
  ensure_anchor_ref && forced=1

  if [ "$forced" = 1 ] || [ "$vpn_if" != "$last_if" ] || ! rule_loaded "$vpn_if" || ! pf_enabled; then
    rule="nat on $vpn_if inet from $VMNET to { $VAULT_IPS } -> ($vpn_if)"
    if echo "$rule" | pfctl -a "$ANCHOR" -f - 2>>"$LOG"; then
      pfctl -e 2>/dev/null || true      # ensure pf is enabled (no-op if already on)
      if anchor_referenced; then
        emit "loaded VM->Vault bridge on $vpn_if"
        last_if="$vpn_if"
        clear_fail
      else
        # Belt and braces: never report success for a rule pf will not evaluate.
        log_fail unref "WARN: rule loaded on $vpn_if but anchor '$ANCHOR' is unreferenced — NAT is INACTIVE"
        last_if=""
      fi
    else
      log_fail loadfail "WARN: failed to load anchor on $vpn_if"
      last_if=""
    fi
  fi
  tick_end
done

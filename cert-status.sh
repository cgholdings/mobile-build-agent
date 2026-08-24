#!/bin/bash
# Platform CA / internal-TLS status for the build agent.
#
# There are TWO platform-ca.crt files with very different jobs, and conflating them is the trap this
# script exists to prevent:
#
#   vault/platform-ca.crt   RUNTIME trust anchor. Vault Agent renders it from secret/platform/ca-cert
#                           and keeps it fresh automatically. This is what Vault Agent's own TLS and
#                           the RabbitMQ connection actually use. On a CA rotation there is nothing
#                           to do by hand — the agent re-renders it, usually well before expiry.
#
#   platform-ca.crt         BOOTSTRAP seed, git-tracked. install.sh copies it to the runtime path
#                           ONLY when that file is missing. It therefore matters exactly once per new
#                           machine: a stale seed silently breaks the NEXT fresh install while every
#                           running agent stays perfectly healthy — so it never shows up as an
#                           incident, just as a machine that won't come up months later.
#
# Exit 0 = healthy (warnings allowed), 1 = something is expired or does not verify.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

WARN_DAYS="${WARN_DAYS:-30}"
VAULT_HOST="${VAULT_HOST:-vault.tech.cgholdings.internal}"
BROKER_HOST="${BROKER_HOST:-rabbitmq.tech.cgholdings.internal}"
RUNTIME_CA="vault/platform-ca.crt"
SEED_CA="platform-ca.crt"
RC=0

fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'; }

# Report validity using openssl's own -checkend rather than parsing dates: BSD `date` cannot read
# openssl's "Jul  8" double-space day without special-casing, and -checkend needs no parsing at all.
cert_line() {
  local label=$1 f=$2 subj end
  if [ ! -s "$f" ]; then
    echo "  MISS  $label — absent or empty"
    RC=1; return
  fi
  if ! openssl x509 -in "$f" -noout -subject >/dev/null 2>&1; then
    echo "  FAIL  $label — not a readable certificate"
    RC=1; return
  fi
  subj=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=*//')
  end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
  if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1; then
    echo "  FAIL  $label — EXPIRED $end  [$subj]"
    RC=1
  elif ! openssl x509 -in "$f" -noout -checkend $((WARN_DAYS * 86400)) >/dev/null 2>&1; then
    echo "  WARN  $label — expires within ${WARN_DAYS}d, on $end  [$subj]"
  else
    echo "  ok    $label — valid to $end  [$subj]"
  fi
}

echo "runtime trust (what the agents actually use):"
cert_line "vault/platform-ca.crt" "$RUNTIME_CA"

echo "bootstrap seed (only used by install.sh on a NEW machine):"
cert_line "platform-ca.crt" "$SEED_CA"
if [ -s "$RUNTIME_CA" ] && [ -s "$SEED_CA" ]; then
  # Compare fingerprints, not bytes: Vault Agent renders without a trailing newline, so a correct
  # seed and a correct runtime file routinely differ by one byte.
  if [ "$(fp "$RUNTIME_CA")" = "$(fp "$SEED_CA")" ]; then
    echo "  ok    seed matches runtime CA"
  else
    echo "  WARN  seed does NOT match the runtime CA — a fresh 'install.sh' on a new Mac would"
    echo "        bootstrap with the wrong CA. Refresh it:  make cert-seed"
  fi
fi

# Both internal endpoints are issued by this CA and both matter: Vault Agent needs one, the build
# agent's RabbitMQ connection needs the other. Each server sends only its leaf, so the CA file is
# the whole trust path — an expired CA here fails as "certificate has expired" even though the
# server's own cert is perfectly valid. That is what an out-of-date CA bundle looks like.
check_endpoint() {
  local label=$1 host=$2 port=$3 chain leaf
  if ! nc -z -G 6 "$host" "$port" >/dev/null 2>&1; then
    echo "  WARN  $label ($host:$port) unreachable (VPN down?) — cannot verify the chain"
    return
  fi
  chain=$(openssl s_client -connect "$host:$port" -CAfile "$RUNTIME_CA" -brief </dev/null 2>&1)
  if echo "$chain" | grep -q "Verification: OK"; then
    echo "  ok    $label — certificate verifies against the runtime CA"
  else
    echo "  FAIL  $label — does NOT verify against $RUNTIME_CA"
    echo "$chain" | grep -i -E "verif|error" | sed 's/^/        /'
    RC=1
  fi
  # The leaf rotates far more often than the CA, so it is the more likely thing to lapse.
  leaf=$(openssl s_client -connect "$host:$port" -showcerts </dev/null 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
  [ -n "$leaf" ] && echo "  ..    $label server leaf expires $leaf"
}

echo "live TLS to the internal endpoints:"
check_endpoint "Vault"    "$VAULT_HOST"  443
check_endpoint "RabbitMQ" "$BROKER_HOST" 5671

exit $RC

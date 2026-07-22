#!/bin/bash
# Incrementally add the firebase CLI to mobile-builder-base (needed by the fastlane
# firebase_app_distribution plugin when authenticating with a cli_token).
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/tech/mobile-build-agent
TMP="fb-update"
echo "[$(date)] cloning base -> $TMP"
tart delete "$TMP" 2>/dev/null || true
tart clone mobile-builder-base "$TMP"
tart run "$TMP" --no-graphics &
for i in $(seq 1 40); do IP=$(tart ip "$TMP" 2>/dev/null); [ -n "$IP" ] && break; sleep 3; done
[ -z "${IP:-}" ] && { echo "no IP"; exit 1; }
echo "[$(date)] installing firebase CLI on $IP"
./.venv/bin/python vmexec.py "$IP" 'set -e; exec </dev/null
sudo curl -fsSL https://firebase.tools/bin/macos/latest -o /usr/local/bin/firebase
sudo chmod +x /usr/local/bin/firebase
firebase --version'
rc=$?
echo "[$(date)] firebase install rc=$rc; snapshotting"
tart stop "$TMP"; sleep 2
tart delete mobile-builder-base
tart clone "$TMP" mobile-builder-base
tart delete "$TMP"
echo "[$(date)] done — firebase CLI baked into mobile-builder-base"

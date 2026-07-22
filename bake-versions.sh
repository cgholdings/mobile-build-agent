#!/bin/bash
# Bake the app's pinned toolchain versions (Flutter via fvm + Ruby via rbenv) into the base image,
# so per-build `fvm install` / `rbenv install` are instant (the caches live in the VM's $HOME, which
# a full clone inherits). Re-run when the app bumps .fvmrc or app/.ruby-version.
#   ./bake-versions.sh [flutter_version] [ruby_version]
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")"
FLUTTER_PIN="${1:-3.44.4}"
RUBY_PIN="${2:-4.0.5}"
TMP="versions-bake"
PY="${PY:-./.venv/bin/python}"
TART="${TART:-/opt/homebrew/bin/tart}"

echo "[$(date)] cloning base -> $TMP (Flutter $FLUTTER_PIN, Ruby $RUBY_PIN)"
"$TART" delete "$TMP" 2>/dev/null || true
"$TART" clone mobile-builder-base "$TMP"
"$TART" run "$TMP" --no-graphics &
for i in $(seq 1 40); do IP=$("$TART" ip "$TMP" 2>/dev/null || true); [ -n "${IP:-}" ] && break; sleep 3; done
[ -z "${IP:-}" ] && { echo "no IP"; exit 1; }

echo "[$(date)] installing toolchain on $IP (Ruby compile can take several minutes)"
"$PY" vmexec.py "$IP" "exec </dev/null
export PATH=/opt/homebrew/bin:\$PATH
echo '-- fvm install $FLUTTER_PIN (+ set global for bare dart/flutter) --'
fvm install $FLUTTER_PIN && fvm global $FLUTTER_PIN && fvm list
echo '-- rbenv install $RUBY_PIN --'; rbenv install -s $RUBY_PIN
echo '-- gems into $RUBY_PIN (cocoapods/bundler/fastlane) --'
RBENV_VERSION=$RUBY_PIN gem install cocoapods bundler fastlane
RBENV_VERSION=$RUBY_PIN gem install fastlane-plugin-firebase_app_distribution || true
rbenv rehash; rbenv versions; RBENV_VERSION=$RUBY_PIN gem list cocoapods"
rc=$?
echo "[$(date)] install rc=$rc; snapshotting"
"$TART" stop "$TMP"; sleep 2
"$TART" delete mobile-builder-base
"$TART" clone "$TMP" mobile-builder-base
"$TART" delete "$TMP"
echo "[$(date)] done — Flutter $FLUTTER_PIN + Ruby $RUBY_PIN (+ cocoapods/bundler/fastlane) baked into mobile-builder-base"

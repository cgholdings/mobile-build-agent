#!/bin/bash
# Bake Android SDK platform(s) + build-tools into the EXISTING base image, so builds never depend on
# the per-build runtime sdkmanager download (which corrupts over the VPN/softnet path:
# "Error on ZipFile unknown archive"). Re-run when the app bumps compileSdk/targetSdk or build-tools.
#   ./bake-android.sh [api_level] [build_tools_version]
# Defaults track cgholdings/mobile-app app/android/app/build.gradle.kts (SDK 35).
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")"
API="${1:-35}"
BT="${2:-35.0.0}"
TMP="android-bake"
PY="${PY:-./.venv/bin/python}"
TART="${TART:-/opt/homebrew/bin/tart}"

echo "[$(date)] cloning base -> $TMP (Android platforms;android-$API + build-tools;$BT)"
"$TART" delete "$TMP" 2>/dev/null || true
"$TART" clone mobile-builder-base "$TMP"
"$TART" run "$TMP" --no-graphics &
for i in $(seq 1 40); do IP=$("$TART" ip "$TMP" 2>/dev/null || true); [ -n "${IP:-}" ] && break; sleep 3; done
[ -z "${IP:-}" ] && { echo "no IP"; exit 1; }

echo "[$(date)] installing SDK on $IP"
"$PY" vmexec.py "$IP" "exec </dev/null
export PATH=/opt/homebrew/bin:\$PATH
SDK=\$(brew --prefix)/share/android-commandlinetools
export ANDROID_SDK_ROOT=\$SDK ANDROID_HOME=\$SDK
# clear any half-downloaded/corrupt state first so we don't reuse a truncated zip
rm -rf \"\$SDK/.temp\" \"\$SDK/.downloadIntermediates\" \"\$SDK/platforms/android-$API\" 2>/dev/null || true
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager \"platform-tools\" \"platforms;android-$API\" \"build-tools;$BT\"
echo '-- installed packages --'; sdkmanager --list_installed 2>/dev/null | grep -E 'android-$API|build-tools;$BT' || sdkmanager --list 2>/dev/null | grep -E 'android-$API|build-tools;$BT'"
rc=$?
echo "[$(date)] install rc=$rc; snapshotting"
"$TART" stop "$TMP"; sleep 2
"$TART" delete mobile-builder-base
"$TART" clone "$TMP" mobile-builder-base
"$TART" delete "$TMP"
echo "[$(date)] done — Android SDK platforms;android-$API + build-tools;$BT baked into mobile-builder-base"

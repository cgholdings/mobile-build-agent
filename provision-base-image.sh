#!/bin/bash
# Build the reusable builder VM image `mobile-builder-base` from a Cirrus macOS+Xcode image.
# Run ONCE on the host (re-run to rebuild). Bakes in: FVM/Flutter, Android SDK, CocoaPods,
# fastlane + firebase plugin, firebase CLI. Per-job clones of this image are fast (APFS CoW).
#
#   ./provision-base-image.sh
#
# Requires: tart installed, the host .venv (for vmexec.py), and network to ghcr.io.
set -euo pipefail
cd "$(dirname "$0")"

# Image must match/precede the host macOS. Host here is macOS 26 (Tahoe) -> macos-tahoe-xcode.
# Tags: https://github.com/cirruslabs/macos-image-templates  (:latest = newest stable)
SRC="${SRC:-ghcr.io/cirruslabs/macos-tahoe-xcode:latest}"
BASE="${BASE:-mobile-builder-base}"
TMP="builder-provision"
PY="${PY:-./.venv/bin/python}"
TART="${TART:-/opt/homebrew/bin/tart}"

echo ">> pulling & cloning $SRC -> $TMP (this is large, ~50-90GB)"
"$TART" delete "$TMP" 2>/dev/null || true
"$TART" clone "$SRC" "$TMP"
"$TART" set "$TMP" --cpu 6 --memory 12288

echo ">> booting provisioning VM (headless)"
"$TART" run "$TMP" --no-graphics &
RUNPID=$!
trap '"$TART" stop "$TMP" 2>/dev/null || true; kill $RUNPID 2>/dev/null || true' EXIT

echo ">> waiting for VM IP"
for i in $(seq 1 60); do IP=$("$TART" ip "$TMP" 2>/dev/null || true); [ -n "${IP:-}" ] && break; sleep 3; done
[ -z "${IP:-}" ] && { echo "VM never got an IP"; exit 1; }
echo ">> VM at $IP; provisioning toolchain"

"$PY" vmexec.py "$IP" <<'PROVISION'
set -e
exec </dev/null   # detach stdin: the real fix — tools (brew/gem/sdkmanager) go non-interactive
# Belt-and-suspenders env: Homebrew 6 otherwise prompts "proceed? [y/n]" and gates untrusted taps.
export CI=1 NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_REQUIRE_TAP_TRUST=1 \
       HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALL_UPGRADE=1
brew update || true

echo "== FVM + Flutter =="   # cocoapods + fastlane already present via rbenv in the Cirrus image
brew tap leoafarias/fvm || true
brew install fvm || true
fvm install stable
fvm install 3.44.4 || true      # app's pinned Flutter (.fvmrc); keep in sync with the repo
# Global = pinned version so bare `dart`/`flutter` (via ~/fvm/default/bin) match the project —
# the Fastfile's `melos run gen` calls bare `dart`, not `fvm exec`.
fvm global 3.44.4 || fvm global stable
fvm flutter --version
# Melos (the cgholdings/mobile-app monorepo needs it for bootstrap + codegen)
fvm dart pub global activate melos || true
echo 'export PATH="$PATH:$HOME/fvm/default/bin:$HOME/.pub-cache/bin"' >> ~/.zprofile

echo "== Android SDK =="
brew install --cask temurin@17 || true
brew install --cask android-commandlinetools || true
SDK="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
# The app targets compileSdk/targetSdk = 35 (app/android/app/build.gradle.kts), so android-35 +
# build-tools;35.0.0 MUST be baked in — the per-build runtime download corrupts over the VPN/softnet
# path ("Error on ZipFile unknown archive"). Keep 34 too (harmless, some transitive deps still ask).
sdkmanager "platform-tools" \
  "platforms;android-35" "build-tools;35.0.0" \
  "platforms;android-34" "build-tools;34.0.0" || true
fvm flutter config --android-sdk "$SDK" || true
yes | fvm flutter doctor --android-licenses || true
{ echo "export ANDROID_SDK_ROOT=$SDK"; echo "export ANDROID_HOME=$SDK"; \
  echo 'export PATH=$PATH:$ANDROID_SDK_ROOT/platform-tools'; } >> ~/.zprofile

echo "== app-pinned Ruby (rbenv) + its gems =="   # app/.ruby-version pins this Ruby; a fresh rbenv
rbenv install -s 4.0.5 || true                   # Ruby has no gems, so install pod/bundler/fastlane
# INTO 4.0.5 or `pod install` fails. Keep 4.0.5 in sync with cgholdings/mobile-app app/.ruby-version.
RBENV_VERSION=4.0.5 gem install cocoapods bundler fastlane || true
RBENV_VERSION=4.0.5 gem install fastlane-plugin-firebase_app_distribution || true
rbenv rehash 2>/dev/null || true
# NB: no firebase CLI — the fastlane plugin uploads via service_credentials_file (see Fastfile).

echo "== precache engine artifacts =="
fvm flutter precache --ios --android || true
echo "PROVISION COMPLETE"
PROVISION

echo ">> stopping VM and snapshotting as $BASE"
"$TART" stop "$TMP"
sleep 2
"$TART" delete "$BASE" 2>/dev/null || true
"$TART" clone "$TMP" "$BASE"
"$TART" delete "$TMP"
trap - EXIT
echo ">> done. Base image ready: $BASE"
echo ">> verify with:  tart run $BASE   (login admin/admin, run: fvm flutter doctor -v)"

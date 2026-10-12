#!/bin/bash
# Install the Android emulator on the HOST, for Android E2E jobs (android_e2e.py).
#
# The emulator needs a hypervisor and macOS VMs cannot nest one (Tart's nested virtualization is
# Linux-guest only), so Android E2E is the one thing that runs on the host: the VM builds the APKs
# and the host only boots this emulator, installs them and runs the instrumentation. No Flutter on
# the host. Re-run to change the system image (keep it in step with the app's compileSdk).
#   ./setup-android-host.sh [api_level]
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
API="${1:-35}"
IMAGE="system-images;android-$API;google_apis;arm64-v8a"
AVD="${AVD:-cgh-e2e}"

# sdkmanager/avdmanager are Java tools
brew list --cask temurin@17 >/dev/null 2>&1 || brew install --cask temurin@17
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools
SDK="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"

yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "platform-tools" "emulator" "$IMAGE"
echo no | avdmanager create avd -n "$AVD" -k "$IMAGE" -d pixel_6 --force

"$SDK/emulator/emulator" -accel-check
echo "done — AVD $AVD ($IMAGE). Android E2E jobs boot it headless as emulator-5580."

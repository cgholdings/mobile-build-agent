#!/bin/bash
# Install the Android emulator and the AndroidX Test Orchestrator on the HOST, for Android E2E jobs
# (android_e2e.py).
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
MAVEN="https://dl.google.com/android/maven2"

# sdkmanager/avdmanager are Java tools
brew list --cask temurin@17 >/dev/null 2>&1 || brew install --cask temurin@17
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools
SDK="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"

yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "platform-tools" "emulator" "$IMAGE"
echo no | avdmanager create avd -n "$AVD" -k "$IMAGE" -d pixel_6 --force

fetch_test_util() { # fetch_test_util <maven path> <sha256> <saved as>
  local dir="$SDK/androidx-test"
  mkdir -p "$dir"
  curl -fsSL -o "$dir/$3.download" "$MAVEN/$1"
  echo "$2  $dir/$3.download" | shasum -a 256 -c -q -
  mv "$dir/$3.download" "$dir/$3"
}
# The orchestrator the app declares (mobile-app app/android/app/build.gradle.kts androidTestUtil)
# and the test services its POM depends on. Keep in step with the app.
fetch_test_util androidx/test/services/test-services/1.5.0/test-services-1.5.0.apk \
  69893d87f3682a2abf95757bfa57c062a491d34f316cb55dc99a022e9c1dbbbe test-services.apk
fetch_test_util androidx/test/orchestrator/1.5.1/orchestrator-1.5.1.apk \
  417ec891e0f548870ab15675b7610061af04ddd3fd17f5a5954b9c00fb38ba4f orchestrator.apk

"$SDK/emulator/emulator" -accel-check
echo "done — AVD $AVD ($IMAGE) + test orchestrator. Android E2E jobs boot it as emulator-5580."

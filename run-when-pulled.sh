#!/bin/bash
# Waits for the in-flight tart pull, retries it if the network dropped, then provisions the
# base image. Launched detached (nohup) so a session/process restart doesn't kill it.
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/tech/mobile-build-agent
IMG="ghcr.io/cirruslabs/macos-tahoe-xcode:latest"

echo "[$(date)] watcher started; waiting for any in-flight pull"
while pgrep -f "tart pull $IMG" >/dev/null 2>&1; do sleep 30; done

tries=0
until tart list 2>/dev/null | grep -q macos-tahoe-xcode; do
  tries=$((tries + 1))
  if [ "$tries" -gt 8 ]; then echo "[$(date)] ERROR: pull failed after $tries tries"; exit 1; fi
  echo "[$(date)] image not present; (re)pulling attempt $tries"
  tart pull "$IMG" >> logs/tart-pull.log 2>&1
done

echo "[$(date)] base image present; starting provisioning"
./provision-base-image.sh
echo "[$(date)] provisioning exit code: $?"

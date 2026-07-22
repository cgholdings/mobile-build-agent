# mobile-build-agent — Go-Live Runbook

Complete instructions to take this Mac from "code staged" to "producing signed builds published
from Argo." Steps 1–4 are the remaining **manual** actions (they need your `sudo`/approval);
steps 5–6 verify; step 7 is day-to-day ops.

Path prefix throughout: `/Users/tech/mobile-build-agent` (call it `$AGENT`).
If `tart`/`vault` aren't on your PATH in a new shell: `export PATH=/opt/homebrew/bin:$PATH`.

---

## Already done (automated, verified)
- Homebrew, **Tart 2.32.1**, **Vault CLI**, Python 3.12 venv, agent code.
- **Base VM image `mobile-builder-base`** — Flutter, melos, fastlane, Android SDK 34, cocoapods, iOS SDK.
- **Vault Agent** (AppRole) renders + refreshes: CA, `vault/rabbitmq.env`, `vault/publish.env`,
  `secrets/asc_key.p8`, `secrets/play-sa.json`, `secrets/upload-keystore.jks`.
- **Build agent online** — connected to `rabbitmq.tech.cgholdings.internal:5671` (TLS), consuming
  `mobile.builds` as `mac-m4-01`. Both LaunchAgents installed (`RunAtLoad`+`KeepAlive`).
- Build pipeline: checkout → `melos bootstrap` → `melos run gen` → build in `app/` → signed AAB
  (`android/key.properties`) → fastlane (Play / TestFlight / Firebase) → status back to RabbitMQ.

---

## 1. Bake the Firebase CLI into the image  *(only needed for the Firebase publish target)*
The fastlane firebase plugin authenticates with a `cli_token`, which requires the `firebase` binary
in the VM. The script downloads it from `firebase.tools` (review it first — that's why it's manual):
```bash
cd $AGENT
./fb-update.sh          # ~3 min; clones base → installs firebase CLI → re-snapshots. Logs: logs/fb-update.log
```
Skip this if you only publish to Play/TestFlight for now.

## 2. FileVault — required decision for unattended boot
`fdesetup status` currently shows **On**, which blocks auto-login (disk needs a password at boot).
For a headless auto-starting agent, disable it (standard for CI build Macs; disk no longer encrypted
at rest):
```bash
sudo fdesetup disable
```
If policy requires FileVault, you cannot auto-start headless — you'd unlock the disk + log in
manually after each reboot, and the agents come up after that login.

## 3. Auto-login (creates the GUI session Tart needs)
```bash
sudo sysadminctl -autologin set -userName tech      # prompts for tech's password
# GUI alternative: System Settings → Users & Groups → Automatically log in as → tech
```

## 4. Headless power hygiene
```bash
sudo pmset -a sleep 0 disksleep 0 displaysleep 0 powernap 0   # never sleep
sudo pmset -a autorestart 1                                   # power on after outage
sudo systemsetup -setrestartfreeze on 2>/dev/null            # reboot if hung
sudo systemsetup -setremotelogin on                          # (optional) SSH access
# (optional) System Settings → General → Sharing → Screen Sharing for remote GUI
```

---

## 5. Verify locally
```bash
export PATH=/opt/homebrew/bin:$PATH
launchctl list | grep cgholdings          # both services present, 3rd col = 0
tail -3 $AGENT/logs/agent.out.log         # "connected; consuming 'mobile.builds'. Agent online."
tail -3 $AGENT/logs/vault-agent.err.log   # "renewed auth token", no errors
nc -vz rabbitmq.tech.cgholdings.internal 5671    # broker reachable
```
Then reboot once and re-run the above — proves auto-login + auto-start actually work.

Also confirm it's visible as a consumer: RabbitMQ mgmt UI `https://rabbitmq-mgmt.tech.cgholdings.internal`
(over VPN) → Connections/Consumers → `cg-build-agent/mac-m4-01`.

## 6. Test the full pipe from Argo (run on the cluster / machine with `argo`)
Job schema is `{job_id, repo, ref, make_target}` — the agent runs `git checkout <ref>` →
`make init` → `make <make_target>`; the **repo's Makefile owns build + publish**.
`make_target` ∈ `deploy-staging` (Firebase) · `deploy-production` (TestFlight + Play internal) ·
`promote-release` (App Store + Play production).
```bash
argo submit --from workflowtemplate/run-mobile-build -n argo \
  -p job-json='{"repo":"https://github.com/cgholdings/mobile-app.git","ref":"main","make_target":"deploy-staging"}'
```
Watch it on the Mac:
```bash
tail -f $AGENT/logs/agent.out.log        # job pickup + phase status
ls -lt $AGENT/build-workspace/*/out/     # per-job build.log
```
The Argo node streams `accepted → building (checkout, init) → publishing (make target) → succeeded`.

**Prerequisites for a real build to pass** (both cluster/repo-side):
- **Git auth** for the private repo — a deploy key in Vault (rendered to `_creds.git_ssh_key`).
- **Gradle URL** pinned to GitHub in the repo (the default CDN fails from this VPN — see below).
- The **mobile-app Makefile's cred contract**: it must read the Vault creds under the env-var names
  the agent exports (see the credentials block in `vm-build.sh`) — confirm/align with the repo owner.

---

## 7. Day-to-day operations
**Restart / stop:**
```bash
launchctl kickstart -k gui/$(id -u)/com.cgholdings.buildagent      # restart build agent
launchctl kickstart -k gui/$(id -u)/com.cgholdings.vault-agent     # restart vault agent
launchctl bootout   gui/$(id -u)/com.cgholdings.buildagent         # stop (until next login/bootstrap)
```
**Logs:** `$AGENT/logs/{agent.out.log, agent.err.log, vault-agent.err.log}`; per-job under
`$AGENT/build-workspace/<job_id>/out/`.

**Secret rotation:** rotate in Vault; Vault Agent re-renders and auto-bounces the build agent.
If the AppRole `secret_id` is rotated, drop the new one into `$AGENT/secrets/vault_secret_id`
(unwrap a fresh wrapping token) and `launchctl kickstart -k gui/$(id -u)/com.cgholdings.vault-agent`.

**Update the base image** (new Flutter/tooling): edit `provision-base-image.sh`, then
`./provision-base-image.sh` (rebuilds + re-snapshots `mobile-builder-base`). In-flight builds
clone the old image until it swaps.

**Concurrency / more Macs:** raise `agent.prefetch` (max 2 VMs/Apple host) in `config.yaml`; or set
up another Mac the same way with a unique `agent.name` — it consumes the same queue automatically.

**Manually inspect a VM:** `tart clone mobile-builder-base scratch && tart run scratch --no-graphics &`
then `ssh -o StrictHostKeyChecking=no admin@$(tart ip scratch)` (admin/admin); `tart delete scratch` after.

---

## Troubleshooting
- **Agent not online:** VPN up (`ifconfig | grep utun`); `nc -vz rabbitmq.tech.cgholdings.internal 5671`;
  `cat vault/rabbitmq.env` (should have RABBIT_USER/PASS); `tail logs/agent.err.log`.
- **Vault Agent errors:** `tail logs/vault-agent.err.log`; re-check `secrets/vault_secret_id` valid;
  CA at `vault/platform-ca.crt` (fingerprint `C3:3B:2A:…:65:E5`).
- **Build fails at signing (Android):** ensure the repo's `android/app/build.gradle` reads
  `key.properties` (standard Flutter convention); the agent writes that file from the Vault keystore.
- **VM won't boot / no IP:** must be in a GUI login session (auto-login on, not just SSH); `tart list`.
- **After reboot nothing runs:** FileVault must be OFF and auto-login ON (steps 2–3).

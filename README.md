# cg-build-agent — macOS Tart mobile build agent

A **build agent** for Flutter apps. It runs a small native daemon that consumes build jobs from
**RabbitMQ** and, for each job, boots a **fresh ephemeral macOS VM (Tart)** with Xcode + Flutter +
Android SDK baked in, builds **iOS + Android**, publishes to **TestFlight / Google Play / Firebase
App Distribution**, then destroys the VM. Build status **and full line-level logs** stream back to
RabbitMQ so the dispatching **Argo Workflow** shows live progress.

```
RabbitMQ (EKS) ──job──▶ agent.py (host, launchd) ──▶ Tart VM (Xcode+Flutter) ──▶ TestFlight/Play/Firebase
       ▲                        │
       └──status + logs(job_id)─┘   (one Argo workflow node == one build, with live logs)
```

- Host stays minimal: **Homebrew, tart, vault, python3 + pika/paramiko, git**. No Xcode/signing on the host.
- Heavy toolchain + signing live **inside the VM image** (`mobile-builder-base`).
- Signing/publish creds are read from **Vault inside the VM** (fastlane `load_vault_secrets`); the host
  only forwards `VAULT_ADDR` + a short-lived Vault token. No signing secrets ever touch host disk.
- The cluster half (RabbitMQ + Argo dispatch) is set up separately — the job/status contract there
  **must match** `config.yaml` + `vm-build.sh` here.

---

## Install on a new machine

Prereqs: an Apple-Silicon Mac on the corporate **VPN** (so it can reach `*.tech.cgholdings.internal`),
with **Homebrew** installed. You'll also need, from the platform/cluster owners:
its **AppRole** (`mobile-build-agent`) `role_id` + a response-wrapped `secret_id`, and a RabbitMQ user.

```bash
git clone <this-repo-url> ~/mobile-build-agent
cd ~/mobile-build-agent
./install.sh                      # guided, idempotent — see below
```

`install.sh` is safe to re-run and works from any clone path / username (it renders host-specific
files from templates). It walks through:

1. **Host tools** — `brew install tart vault python@3.12 git` (no sudo).
2. **Python venv** — `.venv` + `requirements.txt` (`make deps`).
3. **Bootstrap CA** — seeds `vault/platform-ca.crt` (needed for the first TLS handshake to Vault).
4. **Render config** — `config.yaml` + `vault-agent.hcl` from templates, using this machine's path,
   `AGENT_NAME` (defaults to the hostname; override: `AGENT_NAME=mac-m4-02 ./install.sh`), and workspace.
5. **AppRole creds** — prompts to paste `role_id` and unwrap the `secret_id` into `secrets/`.
6. **Base VM image** — offers to build `mobile-builder-base` (`~45 min`, ~90 GB; skip with `SKIP_IMAGE=1`).
7. **Services** — renders + loads the two LaunchAgents (Vault Agent + build agent).

Then finish the parts that need **sudo / a policy decision** (see `GO-LIVE.md`):

```bash
make bridge-install     # pf VM->Vault bridge, so build VMs can reach internal Vault (persists across reboot)
make harden-all         # FileVault off + auto-login + never-sleep — required for headless auto-start
```

Verify:

```bash
make verify             # venv, image, broker reachability, seeds, service status
make status             # launchd services + what Vault Agent has rendered
tail -f logs/agent.out.log     # expect: "connected; consuming 'mobile.builds'. Agent online."
```

The agent is "visible" (Argo has no node registry) when it shows up as a **consumer** of
`mobile.builds` in the RabbitMQ management UI.

---

## Day-to-day (Makefile)

`make` with no target lists everything. Common ones:

| Command | Does |
|---|---|
| `make status` / `make verify` | health / readiness checks |
| `make logs` / `make logs-vault` | tail the build-agent / vault-agent log |
| `make restart` | restart both services (**needed after editing `agent.py`/`vmrunner.py`/`creds.py`**) |
| `make image` | build/rebuild the base VM image (`FORCE=1` to rebuild) |
| `make bake-versions FV=3.44.4 RV=4.0.5` | cache pinned Flutter + Ruby (+ gems) into the image |
| `make bake-android API=35 BT=35.0.0` | bake an Android SDK platform + build-tools into the image |
| `make secret-id WRAP=hvs.xxxx` | unwrap a fresh AppRole `secret_id` |
| `make scratch` / `make scratch-clean` | boot / delete a throwaway clone of the base image to poke at |
| `make cert-status` | platform-CA + Vault leaf expiry, and whether the chain verifies |
| `make repair` | check + fix the whole chain and restart it cleanly, in order |

> **Gotcha:** editing the Python daemon has no effect until `make restart` (launchd `KeepAlive` keeps
> the old process). `vm-build.sh` is copied fresh into each VM per job, so its edits apply immediately.

---

## Files

| File | Role |
|---|---|
| `install.sh` | **New-machine installer** — renders templates, installs deps, wires launchd |
| `Makefile` | All ops (setup, services, image baking, hardening, bridge) — `make help` |
| `agent.py` | Host daemon: RabbitMQ consumer, status + **log** publisher, per-job orchestration |
| `vmrunner.py` | Boots/tears down the ephemeral Tart VM, streams the build over SSH |
| `vm-build.sh` | Runs **inside** the VM: git checkout → `make init` → `make <target>` (fastlane) |
| `vmexec.py` | Run commands in a Tart VM over password SSH (used by provisioning/baking) |
| `creds.py` | RabbitMQ creds from the Vault-rendered env (`vault/rabbitmq.env`) |
| `provision-base-image.sh` | One-time: builds `mobile-builder-base` (Flutter/Android/Ruby/fastlane) |
| `bake-versions.sh` / `bake-android.sh` | Incrementally cache toolchain/SDK into the existing image |
| `config.example.yaml` | Template → `config.yaml` (broker, VM sizing, Vault access) |
| `vault-agent.hcl.tmpl` | Template → `vault-agent.hcl` (AppRole login, renders CA + rabbitmq.env + token) |
| `*.plist.tmpl` | Templates → LaunchAgents (build agent, Vault Agent) + LaunchDaemon (pf bridge) |
| `start-agent.sh` | launchd entrypoint: sources the Vault-rendered env, execs `agent.py` |
| `bridge-vault.sh` / `bridge-vault.pf` | pf source-NAT so build VMs reach internal Vault over the VPN |
| `repair.sh` | `make repair` — checks + fixes the chain in dependency order, restarts cleanly |
| `cert-status.sh` | `make cert-status` — platform-CA / internal-TLS expiry + chain verification |
| `platform-ca.crt` | Bootstrap internal CA (public cert) — seeds TLS trust before Vault Agent runs |
| `GO-LIVE.md` | Detailed runbook: hardening, bridge, first Argo submit, troubleshooting |

Runtime/secret files are git-ignored: `config.yaml`, `vault-agent.hcl`, rendered `*.plist`,
`secrets/`, `vault/`, `.venv/`, `logs/`, `build-workspace/`.

---

## Job & status contract

A job is `{job_id, repo, ref, make_target, github_token}`. The agent does
`git checkout <ref>` → `make init` → `make <make_target>` inside the VM — the **mobile-app repo's
Makefile + fastlane own the actual build + publish**. `make_target` is e.g. `deploy-staging`
(Firebase), `deploy-production` (TestFlight + Play internal), `promote-release` (App Store + Play prod).

The agent publishes to exchange `mobile.status` (routing key = `job_id`): coarse
`accepted → building → publishing → succeeded|failed` status messages, plus batched
`{"type":"log","lines":[...]}` messages carrying the raw build output for the Argo node logs.

---

## Scaling / concurrency

Apple permits **2 macOS VMs per host** — a hard per-Mac cap. To run 2 concurrent builds, set
`agent.prefetch: 2` and size `vm.cpus/memory_gb` so two VMs fit (e.g. 5 CPU / 18 GB each on a
12-core / 48 GB M4 Pro). For more throughput, add more Macs — each with a unique `agent.name`,
all consuming the same `mobile.builds` queue (RabbitMQ load-balances).

## Internal TLS / platform CA

Two files named `platform-ca.crt`, with very different jobs. Confusing them costs an afternoon:

| file | role | who maintains it |
|---|---|---|
| `vault/platform-ca.crt` | **Runtime** trust anchor — what Vault Agent and the RabbitMQ TLS actually use | Vault Agent, from `secret/platform/ca-cert`. Automatic. |
| `platform-ca.crt` (repo root) | **Bootstrap seed**, git-tracked. `install.sh` copies it to the runtime path *only when that file is missing* | You, by hand — see below |

Check both, plus whether Vault's cert actually verifies, any time:

```bash
make cert-status
```

### When the platform CA rotates

**Normally: nothing to do.** The platform team publishes the new CA to `secret/platform/ca-cert`;
Vault Agent notices and re-renders `vault/platform-ca.crt` within minutes. Because the platform
issues the replacement well before the old one lapses, the runtime file is already correct by the
time the old cert expires — no restart, no downtime, no build failures.

Two things still need a human:

1. **Refresh the git-tracked seed** so the *next* new Mac bootstraps correctly. A stale seed is
   invisible on every running machine and only bites months later, when someone provisions a new
   builder and Vault Agent can't establish TLS to fetch anything:
   ```bash
   make cert-seed
   ```
   Then commit the result. `make cert-status` warns whenever the seed and runtime CA disagree.

2. **Bootstrap deadlock — only if the CA rotates to a new key pair while the runtime file is
   already expired.** Vault Agent's `ca_cert` *is* the file it renders, so it cannot fetch a new CA
   it does not yet trust. Break the loop by writing the new CA in by hand, then restarting:
   ```bash
   # get the new CA out-of-band from the platform team, then:
   cp /path/to/new-platform-ca.crt vault/platform-ca.crt
   make start-vault && make cert-status
   ```
   A same-key renewal (the usual case) never deadlocks: the old cert's public key still verifies a
   chain signed by the new one, so the agent can reach Vault and re-render on its own.

3. **Update the cluster side too — it is a separate copy.** The Argo dispatch pod has its own CA
   bundle (image or k8s secret), which nothing here maintains. On 2026-08-20 that copy lapsed while
   every Mac stayed healthy, and dispatch stopped being able to reach RabbitMQ:
   ```
   ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED]
       certificate verify failed: certificate has expired
   ```
   Read that carefully — the **CA in the client's bundle** expired, not the broker's certificate.
   The tell is that the server's own leaf is still valid, so the same endpoint verifies fine from a
   host with a current CA. No jobs get enqueued, so it looks like "builds are failing" even though
   the agents are idle and fine. Confirm which side is at fault from any machine:
   ```bash
   make cert-status        # green here => the CA is fine and the stale bundle is the client's
   ```

The **Vault server leaf** cert is separate, issued by this CA, and rotates far more often — it is
the more likely thing to lapse. `make cert-status` prints its expiry too.

Build VMs are not part of this. `vm-build.sh` passes only `VAULT_ADDR` and `VAULT_TOKEN` into the
VM; nothing here installs the platform CA into the guest or its keychain, so a CA rotation never
requires re-baking the base image. How the app's Fastfile trusts Vault inside the VM lives in the
mobile-app repo.

## Troubleshooting

**Start here — `make repair`.** It checks and fixes the whole chain in dependency order (VPN → pf
bridge → Vault Agent → an end-to-end VM→Vault probe → build agent), restarting each service cleanly
and refusing to run mid-build unless you pass `FORCE=1`. It is idempotent, so it doubles as a
diagnosis tool. Use `SKIP_VM=1` to skip the ~2 min probe VM.

- **Agent won't connect**: VPN up (`ifconfig | grep utun`); `nc -vz rabbitmq.tech.cgholdings.internal 5671`;
  `cat vault/rabbitmq.env` (should have RABBIT_USER/PASS); `tail logs/agent.err.log`.
- **Vault Agent errors**: `make logs-vault`; check `secrets/vault_secret_id` is valid (unwrap a fresh one);
  ensure `vault/platform-ca.crt` exists.
- **VM never gets an IP**: must be in a GUI login session (auto-login on, not just SSH); `tart list`;
  try `make scratch`.
- **Build VM can't reach Vault** (`Net::OpenTimeout ... vault.tech.cgholdings.internal:443` in the
  build log, while the *host* reaches Vault fine): the pf bridge is down. Run `make bridge-status` —
  if it says `anchor referenced: NO`, `/etc/pf.conf` lost its `nat-anchor "cgh-vault-bridge"` line,
  which a **macOS update does silently** by resetting the file to stock. pf never evaluates an
  unreferenced anchor, so the NAT rule loads "successfully" and does nothing. Fix: `make repair`
  (or just `make bridge-anchor`). The bridge daemon also self-heals this within 30s of noticing.
- **No live logs in Argo**: build output must reach `vm-build.sh`'s stdout — its `run()` helper `tee`s
  to both stdout (streamed) and `build.log`. Per-job stream is also saved to
  `build-workspace/<job_id>/out/stream.log`.
- Per-job logs/artifacts: `build-workspace/<job_id>/out/` (kept for the last `agent.keep_jobs`).

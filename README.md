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

## Troubleshooting

- **Agent won't connect**: VPN up (`ifconfig | grep utun`); `nc -vz rabbitmq.tech.cgholdings.internal 5671`;
  `cat vault/rabbitmq.env` (should have RABBIT_USER/PASS); `tail logs/agent.err.log`.
- **Vault Agent errors**: `make logs-vault`; check `secrets/vault_secret_id` is valid (unwrap a fresh one);
  ensure `vault/platform-ca.crt` exists.
- **VM never gets an IP**: must be in a GUI login session (auto-login on, not just SSH); `tart list`;
  try `make scratch`.
- **Build VM can't reach Vault**: install the pf bridge (`make bridge-install`); `make bridge-status`.
- **No live logs in Argo**: build output must reach `vm-build.sh`'s stdout — its `run()` helper `tee`s
  to both stdout (streamed) and `build.log`. Per-job stream is also saved to
  `build-workspace/<job_id>/out/stream.log`.
- Per-job logs/artifacts: `build-workspace/<job_id>/out/` (kept for the last `agent.keep_jobs`).

"""
TartRunner — boots an ephemeral macOS VM per job, runs the build inside it, tears it down.

Host responsibilities (here):
  * clone the base image to a throwaway VM
  * stage job context + publish secrets into a shared dir mounted into the VM
  * boot, SSH in, run vm-build.sh, stream its @@STATUS lines back to the caller
  * for Android E2E jobs, run the APKs the VM built on a host emulator (android_e2e.py) —
    macOS VMs cannot nest the hypervisor the emulator needs
  * collect out/result.json, ship out/artifacts/* (E2E failure screenshots) back to the caller,
    then destroy the VM and prune old job dirs

Guest responsibilities live in vm-build.sh (git checkout, fvm flutter build, fastlane publish).
"""
import json
import os
import shutil
import subprocess
import time

import paramiko

from android_e2e import AndroidE2E, AndroidE2EError

HERE = os.path.dirname(os.path.abspath(__file__))
GUEST_MOUNT = "/Volumes/My Shared Files/io"   # where Tart mounts our --dir=io:...
ARTIFACT_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".txt": "text/plain"}


class BuildError(Exception):
    def __init__(self, message, phase="build", platform=None, progress=0.0, log_tail=""):
        super().__init__(message)
        self.phase = phase
        self.platform = platform
        self.progress = progress
        self.log_tail = log_tail


class TartRunner:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        v = cfg["vm"]
        self.tart = v.get("tart_bin", "tart")
        self.base = v["base_image"]
        self.cpus = int(v.get("cpus", 6))
        self.mem = int(v.get("memory_gb", 20))
        self.boot_timeout = int(v.get("boot_timeout_sec", 180))
        self.max_seconds = int(v.get("max_job_seconds", 3600))
        self.ssh_user = v.get("ssh_user", "admin")
        self.ssh_pass = v.get("ssh_password", "admin")
        self.workspace = cfg["agent"]["workspace"]
        self.keep_jobs = int(cfg["agent"].get("keep_jobs", 5))
        self.android_e2e = AndroidE2E(cfg)
        a = cfg.get("artifacts") or {}
        self.max_artifacts = int(a.get("max_files", 10))
        self.max_artifact_bytes = int(a.get("max_file_bytes", 4 * 1024 * 1024))

    # -- tart helpers ----------------------------------------------------------
    def _tart(self, *args, check=True, capture=False):
        return subprocess.run([self.tart, *args], check=check,
                              capture_output=capture, text=True)

    def _vm_ip(self, vm: str) -> str:
        deadline = time.time() + self.boot_timeout
        while time.time() < deadline:
            r = self._tart("ip", vm, check=False, capture=True)
            ip = (r.stdout or "").strip()
            if r.returncode == 0 and ip:
                return ip
            time.sleep(3)
        raise BuildError(f"VM {vm} did not get an IP within {self.boot_timeout}s", phase="boot")

    def _ssh(self, ip: str) -> paramiko.SSHClient:
        deadline = time.time() + self.boot_timeout
        last = None
        while time.time() < deadline:
            try:
                cli = paramiko.SSHClient()
                cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                cli.connect(ip, username=self.ssh_user, password=self.ssh_pass,
                            timeout=10, banner_timeout=15, auth_timeout=15,
                            look_for_keys=False, allow_agent=False)
                return cli
            except Exception as e:  # noqa: BLE001
                last = e
                time.sleep(3)
        raise BuildError(f"SSH to VM never came up: {last}", phase="boot")

    # -- staging ---------------------------------------------------------------
    def _stage(self, job: dict, jobdir: str) -> None:
        in_dir = os.path.join(jobdir, "in")
        sec_dir = os.path.join(in_dir, "secrets")
        os.makedirs(sec_dir, exist_ok=True)
        os.makedirs(os.path.join(jobdir, "out"), exist_ok=True)

        # context.json = the job + Vault access for the VM's fastlane (which reads creds from Vault
        # itself). Inject VAULT_ADDR + the current Vault Agent token; optionally an SSH deploy key.
        vb = self.cfg.get("vault_bridge", {})
        ctx = dict(job)
        ctx["vault_addr"] = vb.get("addr", "https://vault.tech.cgholdings.internal")
        token_file = vb.get("token_file", os.path.join(HERE, "vault", "token"))
        try:
            with open(token_file) as tf:
                ctx["vault_token"] = tf.read().strip()
        except OSError:
            ctx["vault_token"] = ""
        # optional SSH deploy-key fallback (used only if the job carries no github_token)
        ctx["_creds"] = {"git_ssh_key": None}
        sshk = (self.cfg.get("git") or {}).get("ssh_key")
        if sshk and os.path.exists(sshk):
            dst = os.path.join(sec_dir, "git_ssh_key")
            shutil.copy2(sshk, dst)
            os.chmod(dst, 0o600)
            ctx["_creds"]["git_ssh_key"] = f"{GUEST_MOUNT}/in/secrets/git_ssh_key"
        with open(os.path.join(in_dir, "context.json"), "w") as f:
            json.dump(ctx, f, indent=2)
        shutil.copy2(os.path.join(HERE, "vm-build.sh"), os.path.join(in_dir, "vm-build.sh"))

    def _prune(self):
        try:
            jobs = sorted(
                (os.path.join(self.workspace, d) for d in os.listdir(self.workspace)
                 if os.path.isdir(os.path.join(self.workspace, d))),
                key=os.path.getmtime, reverse=True)
            for old in jobs[self.keep_jobs:]:
                shutil.rmtree(old, ignore_errors=True)
        except Exception:  # noqa: BLE001
            pass

    def _ship_artifacts(self, jobdir: str, artifact_cb) -> None:
        """Hand files the job left in out/artifacts/ (E2E failure screenshots) to the caller.

        Capped in count and size: they travel as RabbitMQ messages, and a runaway test must not
        flood the broker. Skipped files are reported in the log instead.
        """
        art_dir = os.path.join(jobdir, "out", "artifacts")
        if not artifact_cb or not os.path.isdir(art_dir):
            return
        names = sorted(n for n in os.listdir(art_dir)
                       if os.path.splitext(n)[1].lower() in ARTIFACT_TYPES)
        shipped = 0
        for name in names:
            path = os.path.join(art_dir, name)
            size = os.path.getsize(path)
            if size > self.max_artifact_bytes:
                artifact_cb(name, None, None, f"skipped: {size} bytes > {self.max_artifact_bytes}")
                continue
            if shipped >= self.max_artifacts:
                artifact_cb(name, None, None, f"skipped: over the {self.max_artifacts}-file cap")
                continue
            with open(path, "rb") as f:
                artifact_cb(name, f.read(), ARTIFACT_TYPES[os.path.splitext(name)[1].lower()], None)
            shipped += 1

    # -- main entry ------------------------------------------------------------
    def run(self, job: dict, status_cb, should_stop, log_cb=None, artifact_cb=None) -> dict:
        job_id = job["job_id"]
        vm = f"build-{job_id[:8]}"
        jobdir = os.path.join(self.workspace, job_id)
        os.makedirs(jobdir, exist_ok=True)
        log_tail: list[str] = []
        run_proc = None
        stream_fp = None
        vm_up = [False]

        def teardown_vm():
            if not vm_up[0]:
                return
            vm_up[0] = False
            try:
                if run_proc:
                    run_proc.terminate()
                self._tart("stop", vm, check=False)
                time.sleep(1)
                self._tart("delete", vm, check=False)
            except Exception:  # noqa: BLE001
                pass

        def keep_tail(line):
            log_tail.append(line)
            if len(log_tail) > 200:
                del log_tail[0]

        # Batch raw build output back to the caller so it streams into the Argo node logs.
        # xcodebuild/gradle are chatty, so flush by size (40 lines) or time (~200ms), never
        # one AMQP message per line. Contract: {"type":"log","lines":[...]} on mobile.status.
        pending: list[str] = []
        last_flush = [time.time()]

        def flush_logs(force=False):
            if not log_cb or not pending:
                return
            now = time.time()
            if force or len(pending) >= 40 or (now - last_flush[0]) >= 0.2:
                batch = list(pending)
                pending.clear()
                last_flush[0] = now
                try:
                    log_cb(batch)
                except Exception:  # noqa: BLE001
                    pass

        def on_log(line):
            keep_tail(line)
            if stream_fp:
                try:
                    stream_fp.write(line + "\n")
                    stream_fp.flush()
                except Exception:  # noqa: BLE001
                    pass
            pending.append(line)
            flush_logs()

        try:
            self._stage(job, jobdir)   # creates jobdir/out before we open a log in it
            # host-side combined-output log; survives VM teardown (kept until _prune rotates it)
            try:
                stream_fp = open(os.path.join(jobdir, "out", "stream.log"), "w", buffering=1)
            except OSError:
                stream_fp = None
            status_cb(state="building", phase="boot", progress=0.02, message=f"cloning VM {vm}")
            self._tart("clone", self.base, vm)
            vm_up[0] = True
            self._tart("set", vm, "--cpu", str(self.cpus), "--memory", str(self.mem * 1024))

            run_proc = subprocess.Popen(
                [self.tart, "run", vm, "--no-graphics", f"--dir=io:{jobdir}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            ip = self._vm_ip(vm)
            status_cb(state="building", phase="boot", progress=0.05, message=f"VM up at {ip}")
            cli = self._ssh(ip)

            # run the build script inside the VM; stream its output
            cmd = f'bash "{GUEST_MOUNT}/in/vm-build.sh" 2>&1'
            chan = cli.get_transport().open_session()
            chan.exec_command(cmd)
            deadline = time.time() + self.max_seconds
            buf = ""
            while True:
                if should_stop():
                    raise BuildError("agent shutting down", phase="build")
                if time.time() > deadline:
                    raise BuildError(f"build exceeded {self.max_seconds}s", phase="build",
                                     log_tail="\n".join(log_tail))
                if chan.recv_ready():
                    buf += chan.recv(65536).decode("utf-8", "replace")
                    while "\n" in buf:
                        line, buf = buf.split("\n", 1)
                        self._handle_line(line, status_cb, on_log)
                elif chan.exit_status_ready():
                    break
                else:
                    flush_logs()   # time-based flush while the build is quiet
                    time.sleep(0.3)
            rc = chan.recv_exit_status()
            if buf:
                self._handle_line(buf, status_cb, on_log)
            flush_logs(force=True)
            cli.close()

            result_path = os.path.join(jobdir, "out", "result.json")
            result = {}
            if os.path.exists(result_path):
                with open(result_path) as f:
                    result = json.load(f)
            if rc != 0 or result.get("status") == "failed":
                raise BuildError(result.get("message", f"build exited {rc}"),
                                 phase=result.get("phase", "build"),
                                 platform=result.get("platform"),
                                 progress=result.get("progress", 0.5),
                                 log_tail="\n".join(log_tail[-80:]))

            handoff = os.path.join(jobdir, "out", "android-e2e")
            if os.path.exists(os.path.join(handoff, "run.json")):
                teardown_vm()   # free the VM's CPU/RAM before booting the emulator
                flush_logs(force=True)
                status_cb(state="building", phase="e2e", platform="android", progress=0.8,
                          message="running Android E2E on the host emulator")
                try:
                    failures = self.android_e2e.run(
                        handoff, os.path.join(jobdir, "out", "artifacts"), on_log)
                except AndroidE2EError as e:
                    raise BuildError(f"Android E2E could not run: {e}", phase="e2e",
                                     platform="android", progress=0.8,
                                     log_tail="\n".join(log_tail[-80:])) from e
                finally:
                    flush_logs(force=True)
                if failures:
                    summary = ["==== E2E FAILURES · android ===="]
                    for name, message in failures:
                        summary.append(f"❌ {name}")
                        # Android prefixes the exception class: "java.lang.AssertionError: ..."
                        for l in message.splitlines():
                            for mark in ("Failed at step:", "On screen:"):
                                if mark in l:
                                    summary.append(l[l.index(mark):])
                    for line in summary:
                        on_log(line)
                    flush_logs(force=True)
                    raise BuildError(f"Android E2E: {len(failures)} test(s) failed", phase="e2e",
                                     platform="android", progress=0.9,
                                     log_tail="\n".join(log_tail[-80:]))

            return {"artifacts": result.get("artifacts", {}),
                    "log_tail": "\n".join(log_tail[-40:])}

        finally:
            try:
                flush_logs(force=True)
            except Exception:  # noqa: BLE001
                pass
            # before the terminal status, so the dispatcher has them when it stops listening
            try:
                self._ship_artifacts(jobdir, artifact_cb)
            except Exception:  # noqa: BLE001
                pass
            if stream_fp:
                try:
                    stream_fp.close()
                except Exception:  # noqa: BLE001
                    pass
            teardown_vm()
            self._prune()

    @staticmethod
    def _handle_line(line, status_cb, on_log):
        line = line.rstrip("\r")
        if not line:
            return
        if line.startswith("@@STATUS "):
            try:
                status_cb(**json.loads(line[len("@@STATUS "):]))
                return
            except Exception:  # noqa: BLE001
                pass
        on_log(line)

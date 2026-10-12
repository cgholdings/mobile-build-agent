"""
AndroidE2E — runs a prebuilt Patrol Android suite on an emulator on the HOST.

The Android emulator needs a hypervisor, and macOS VMs cannot nest one (Tart supports nested
virtualization for Linux guests only). So for `android-e2e-*` jobs the VM only BUILDS: the
mobile-app's scripts/e2e.sh runs `patrol build android` and leaves, in out/android-e2e/:
    app.apk, test.apk, run.json  {"package": "...", "flavor": "...", "tags": "..."}
and this runner, on the host, does what `patrol test` would have done on a device:
    boot a fresh headless emulator -> adb install both APKs -> am instrument -> report.

PR code still never runs on the host itself: only inside the emulator's sandbox. The host only
needs the Android SDK (`make android-host`), not Flutter.

Output mirrors `patrol test`: patrol's PATROL_LOG entries are read from logcat and printed as
step/log lines, and each test reports ✅ / ❌ / ⏩ with its failure message. When a test logs
`E2E_SCREENSHOT <name>` (the suite does this on failure, then holds the screen), the screen is
captured into the job's artifacts dir.
"""
import json
import os
import re
import subprocess
import threading
import time

_RESULT = {0: "✅", -2: "❌", -1: "❌", -3: "⏩", -4: "⏩"}
_SHOT_MARK = "E2E_SCREENSHOT "


class AndroidE2EError(Exception):
    pass


class AndroidE2E:
    # One host emulator: concurrent Android E2E jobs (prefetch 2) take turns.
    _lock = threading.Lock()

    def __init__(self, cfg: dict):
        a = cfg.get("android_e2e") or {}
        sdk = a.get("sdk_root", "/opt/homebrew/share/android-commandlinetools")
        self.adb = os.path.join(sdk, "platform-tools", "adb")
        self.emulator = os.path.join(sdk, "emulator", "emulator")
        self.avd = a.get("avd", "cgh-e2e")
        self.port = int(a.get("port", 5580))
        self.serial = f"emulator-{self.port}"
        self.boot_timeout = int(a.get("boot_timeout_sec", 300))
        self.test_timeout = int(a.get("test_timeout_sec", 3000))
        self.max_shots = int((cfg.get("artifacts") or {}).get("max_files", 10))

    # -- adb helpers -------------------------------------------------------------
    def _adb(self, *args, check=True, timeout=120):
        r = subprocess.run([self.adb, "-s", self.serial, *args], capture_output=True,
                           text=True, timeout=timeout)
        if check and r.returncode != 0:
            raise AndroidE2EError(f"adb {' '.join(args)} failed: {(r.stderr or r.stdout).strip()}")
        return r.stdout

    def _boot(self, on_log):
        on_log(f"[android-e2e] booting {self.avd} headless as {self.serial}")
        proc = subprocess.Popen(
            [self.emulator, "-avd", self.avd, "-port", str(self.port), "-no-window", "-no-audio",
             "-no-boot-anim", "-no-snapshot", "-wipe-data", "-gpu", "swiftshader_indirect"],
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        deadline = time.time() + self.boot_timeout
        while time.time() < deadline:
            if proc.poll() is not None:
                raise AndroidE2EError(f"emulator exited during boot (rc {proc.returncode}); "
                                      f"run `emulator -avd {self.avd}` on the host to see why")
            r = subprocess.run([self.adb, "-s", self.serial, "shell", "getprop",
                                "sys.boot_completed"], capture_output=True, text=True)
            if r.stdout.strip() == "1":
                for s in ("window_animation_scale", "transition_animation_scale",
                          "animator_duration_scale"):
                    self._adb("shell", "settings", "put", "global", s, "0", check=False)
                on_log("[android-e2e] emulator booted")
                return proc
            time.sleep(3)
        proc.kill()
        raise AndroidE2EError(f"emulator did not boot within {self.boot_timeout}s")

    def _instrumentation(self, package: str) -> str:
        out = self._adb("shell", "pm", "list", "instrumentation", check=False)
        for line in out.splitlines():
            m = re.match(r"instrumentation:(\S+) \(target=(\S+)\)", line.strip())
            if m and m.group(2) == package:
                return m.group(1)
        return f"{package}.test/pl.leancode.patrol.PatrolJUnitRunner"

    # -- logcat: patrol log entries + screenshot markers -----------------------
    def _follow_logcat(self, artifact_dir, on_log, stop: threading.Event):
        proc = subprocess.Popen(
            [self.adb, "-s", self.serial, "logcat", "-T", "1", "-v", "raw",
             "PatrolServer:I", "Patrol:I", "flutter:I", "*:S"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace")
        shots = 0
        try:
            for line in proc.stdout:
                if stop.is_set():
                    break
                line = line.rstrip("\n")
                idx = line.find("PATROL_LOG ")
                if idx < 0:
                    continue
                try:
                    entry = json.loads(line[idx + len("PATROL_LOG "):])
                except ValueError:
                    continue   # long entries can be split by logcat; results come from am instrument
                kind = entry.get("type")
                if kind == "log":
                    msg = entry.get("message", "")
                    on_log(f"📝 {msg}")
                    if msg.startswith(_SHOT_MARK) and shots < self.max_shots:
                        shots += 1
                        self._screenshot(artifact_dir, shots, msg[len(_SHOT_MARK):], on_log)
                elif kind == "step" and entry.get("status") in ("success", "failure"):
                    mark = "✓" if entry["status"] == "success" else "✗"
                    on_log(f"   {mark} {entry.get('action', '')}")
        finally:
            proc.kill()

    def _screenshot(self, artifact_dir, n, name, on_log):
        safe = re.sub(r"[^A-Za-z0-9._-]+", "-", name)[:80].strip("-") or "failure"
        path = os.path.join(artifact_dir, f"android-{n:02d}-{safe}.png")
        try:
            os.makedirs(artifact_dir, exist_ok=True)
            with open(path, "wb") as f:
                subprocess.run([self.adb, "-s", self.serial, "exec-out", "screencap", "-p"],
                               stdout=f, timeout=30, check=True)
            on_log(f"[android-e2e] screenshot saved: {os.path.basename(path)}")
        except Exception as e:  # noqa: BLE001
            on_log(f"[android-e2e] screenshot failed: {e}")

    # -- main entry ---------------------------------------------------------------
    def run(self, handoff_dir: str, artifact_dir: str, on_log) -> list:
        """Runs the suite; returns the failures as [(test, message)], [] when all passed."""
        with open(os.path.join(handoff_dir, "run.json")) as f:
            spec = json.load(f)
        package = spec["package"]
        on_log(f"[android-e2e] waiting for the host emulator (one Android E2E run at a time)")
        with AndroidE2E._lock:
            emu = self._boot(on_log)
            stop = threading.Event()
            follower = None
            try:
                for apk in ("app.apk", "test.apk"):
                    self._adb("install", "-r", "-t", os.path.join(handoff_dir, apk), timeout=300)
                runner = self._instrumentation(package)
                on_log(f"[android-e2e] {runner} · flavor={spec.get('flavor')} "
                       f"tags={spec.get('tags') or 'all'}")

                follower = threading.Thread(target=self._follow_logcat,
                                            args=(artifact_dir, on_log, stop), daemon=True)
                follower.start()
                return self._instrument(runner, on_log)
            finally:
                stop.set()
                subprocess.run([self.adb, "-s", self.serial, "emu", "kill"],
                               capture_output=True, timeout=30)
                try:
                    emu.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    emu.kill()
                if follower:
                    follower.join(timeout=5)

    def _instrument(self, runner: str, on_log) -> list:
        """`am instrument -r` exits 0 even when tests fail; results come from its status lines."""
        proc = subprocess.Popen(
            [self.adb, "-s", self.serial, "shell", "am", "instrument", "-w", "-r", runner],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        timer = threading.Timer(self.test_timeout, proc.kill)
        timer.start()
        failures, status, stack, in_stack, crashed = [], {}, [], False, False
        counts = {"✅": 0, "❌": 0, "⏩": 0}
        try:
            for raw in proc.stdout:
                line = raw.rstrip("\n")
                if line.startswith("INSTRUMENTATION_STATUS: "):
                    in_stack = False
                    key, _, val = line[len("INSTRUMENTATION_STATUS: "):].partition("=")
                    status[key] = val
                    if key == "stack":
                        stack, in_stack = [val], True
                elif line.startswith("INSTRUMENTATION_STATUS_CODE: "):
                    in_stack = False
                    code = int(line.split(": ", 1)[1])
                    name = status.get("test", "?")
                    m = re.match(r"runDartTest\[(.*)\]$", name)
                    name = m.group(1) if m else name
                    if code == 1:
                        on_log(f"🧪 {name}")
                    elif code in _RESULT:
                        mark = _RESULT[code]
                        counts[mark] += 1
                        on_log(f"{mark} {name}")
                        if mark == "❌":
                            message = "\n".join(stack).strip() or "(no failure message)"
                            failures.append((name, message))
                            for l in message.splitlines()[:12]:
                                on_log(f"    {l}")
                    status, stack = {}, []
                elif in_stack:
                    stack.append(line)
                elif "INSTRUMENTATION_FAILED" in line or "Process crashed" in line:
                    crashed = True
                    on_log(line)
                elif line.startswith("INSTRUMENTATION_RESULT: shortMsg="):
                    on_log(line)
        finally:
            timer.cancel()
            proc.wait()

        on_log(f"[android-e2e] passed {counts['✅']}, failed {counts['❌']}, "
               f"skipped {counts['⏩']}")
        if crashed and not failures:
            failures.append(("(instrumentation)", "the app or test runner crashed — see log above"))
        if not any(counts.values()) and not failures:
            failures.append(("(no tests)", "no tests ran — wrong tags, or the test APK is empty"))
        return failures

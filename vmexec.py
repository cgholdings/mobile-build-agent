#!/usr/bin/env python3
"""Run a command (from argv or stdin) inside a Tart VM over password SSH, streaming output.
Usage:  python vmexec.py <ip> "command"      or      python vmexec.py <ip> < script.sh
Creds come from config.yaml (vm.ssh_user/ssh_password), default admin/admin."""
import os
import sys
import time

import paramiko
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: vmexec.py <ip> [command]   (command may come from stdin)")
    ip = sys.argv[1]
    cmd = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()

    cfg_path = os.environ.get("AGENT_CONFIG", os.path.join(HERE, "config.yaml"))
    vm = {}
    if os.path.exists(cfg_path):
        vm = (yaml.safe_load(open(cfg_path)) or {}).get("vm", {})
    user = vm.get("ssh_user", "admin")
    pw = vm.get("ssh_password", "admin")

    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    # A freshly-booted VM may not have sshd/auth ready the instant it gets an IP — retry.
    deadline, last = time.time() + 180, None
    while time.time() < deadline:
        try:
            cli.connect(ip, username=user, password=pw, look_for_keys=False, allow_agent=False,
                        timeout=15, banner_timeout=20, auth_timeout=20)
            break
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(5)
    else:
        sys.exit(f"could not SSH to {ip} within 180s: {last}")
    chan = cli.get_transport().open_session()
    chan.get_pty()
    chan.exec_command(f"bash -lc {shell_quote(cmd)}")
    while True:
        if chan.recv_ready():
            sys.stdout.write(chan.recv(65536).decode("utf-8", "replace"))
            sys.stdout.flush()
        elif chan.exit_status_ready():
            break
    rc = chan.recv_exit_status()
    cli.close()
    sys.exit(rc)


def shell_quote(s: str) -> str:
    return "'" + s.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    main()

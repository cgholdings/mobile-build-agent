"""Broker credential resolution for the host agent.

The RabbitMQ password comes from env (RABBIT_USER / RABBIT_PASS), rendered by Vault Agent to
vault/rabbitmq.env and sourced by start-agent.sh; falls back to config. (Publish/signing creds are
NOT handled here anymore — the mobile-app Fastfiles read those from Vault directly inside the VM.)
"""
import os


def broker_creds(cfg: dict):
    b = cfg["broker"]
    user = os.environ.get("RABBIT_USER") or b.get("username")
    pw = os.environ.get("RABBIT_PASS") or b.get("password")
    return user, pw

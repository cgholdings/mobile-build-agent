#!/bin/bash
# launchd entrypoint for the build agent. Sources the env files that Vault Agent renders
# (RabbitMQ creds + publish scalars), then execs the daemon. When Vault Agent re-renders an env
# file it runs `launchctl kickstart`, which re-runs this script so fresh values are picked up.
cd "$(dirname "$0")" || exit 1            # portable: resolve to wherever the agent is cloned
set -a
[ -f vault/rabbitmq.env ] && . vault/rabbitmq.env   # RABBIT_USER/RABBIT_PASS for the broker
set +a
export AGENT_CONFIG="$(pwd)/config.yaml"
exec ./.venv/bin/python agent.py

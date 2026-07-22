#!/usr/bin/env python3
"""
cg-build-agent — macOS Tart build agent.

Runs natively on an Apple Silicon Mac. Consumes Flutter build jobs from RabbitMQ, and for each
job boots a fresh ephemeral macOS VM (via Tart) that builds iOS + Android and publishes to
TestFlight / Play / Firebase, then destroys the VM. Build status is streamed back to RabbitMQ
(exchange `mobile.status`, routing key = job_id) so the dispatching Argo workflow can display it.

The host talks to RabbitMQ; the VM does the building. See config.example.yaml and README.md.
"""
import json
import os
import signal
import ssl
import sys
import threading
import time
from datetime import datetime, timezone

import pika
import yaml

import creds
from vmrunner import TartRunner, BuildError

HERE = os.path.dirname(os.path.abspath(__file__))


def log(msg: str) -> None:
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {msg}", flush=True)


def load_config() -> dict:
    path = os.environ.get("AGENT_CONFIG", os.path.join(HERE, "config.yaml"))
    if not os.path.exists(path):
        log(f"FATAL: config not found at {path} (copy config.example.yaml -> config.yaml)")
        sys.exit(2)
    with open(path) as f:
        return yaml.safe_load(f)


class Agent:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.name = cfg["agent"]["name"]
        self.status_exchange = cfg["queues"]["status_exchange"]
        self.jobs_queue = cfg["queues"]["jobs"]
        self.runner = TartRunner(cfg)
        self._stopping = threading.Event()
        self._conn = None
        self._channel = None

    # ---- connection ----------------------------------------------------------
    def _connect(self):
        b = self.cfg["broker"]
        username, password = creds.broker_creds(self.cfg)
        ssl_options = None
        if b.get("tls", True):
            ctx = ssl.create_default_context(cafile=b.get("tls_ca_file"))
            if not b.get("tls_verify", True):
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            ssl_options = pika.SSLOptions(ctx, server_hostname=b["host"])
        params = pika.ConnectionParameters(
            host=b["host"],
            port=int(b.get("port", 5671)),
            virtual_host=b.get("vhost", "/mobile"),
            credentials=pika.PlainCredentials(username, password),
            ssl_options=ssl_options,
            heartbeat=int(b.get("heartbeat", 60)),
            blocked_connection_timeout=30,
            client_properties={"connection_name": f"cg-build-agent/{self.name}"},
        )
        self._conn = pika.BlockingConnection(params)
        self._channel = self._conn.channel()
        # exchange is created by the cluster session; declare passively so we fail loudly if missing
        self._channel.exchange_declare(self.status_exchange, exchange_type="direct",
                                       durable=True, passive=True)
        self._channel.basic_qos(prefetch_count=int(self.cfg["agent"].get("prefetch", 1)))
        self._channel.basic_consume(self.jobs_queue, self._on_message, auto_ack=False)

    # ---- status publishing (thread-safe) ------------------------------------
    def publish_status(self, job_id: str, **fields):
        body = {"job_id": job_id, "agent": self.name,
                "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), **fields}
        payload = json.dumps(body)

        def _do():
            try:
                self._channel.basic_publish(
                    self.status_exchange, routing_key=job_id, body=payload,
                    properties=pika.BasicProperties(delivery_mode=2, content_type="application/json"))
            except Exception as e:  # noqa: BLE001
                log(f"WARN: failed to publish status for {job_id}: {e}")

        # marshal onto the connection's IO thread
        self._conn.add_callback_threadsafe(_do)

    def _ack(self, delivery_tag: int, requeue_on_fail: bool = False, nack: bool = False):
        def _do():
            try:
                if nack:
                    self._channel.basic_nack(delivery_tag, requeue=requeue_on_fail)
                else:
                    self._channel.basic_ack(delivery_tag)
            except Exception as e:  # noqa: BLE001
                log(f"WARN: ack/nack failed (tag {delivery_tag}): {e}")
        self._conn.add_callback_threadsafe(_do)

    # ---- message handling ----------------------------------------------------
    def _on_message(self, ch, method, props, body):
        # Run each job on its own thread so long builds never block AMQP heartbeats.
        t = threading.Thread(target=self._process, args=(body, method.delivery_tag), daemon=True)
        t.start()

    def _process(self, body: bytes, delivery_tag: int):
        try:
            job = json.loads(body)
        except Exception as e:  # noqa: BLE001
            log(f"ERROR: undecodable job message, dead-lettering: {e}")
            self._ack(delivery_tag, requeue_on_fail=False, nack=True)  # -> DLX
            return

        job_id = job.get("job_id", "unknown")
        log(f"picked up job {job_id} make_target={job.get('make_target')} ref={job.get('ref')}")
        self.publish_status(job_id, state="accepted", phase="checkout", progress=0.0,
                            message=f"accepted by {self.name}")

        try:
            result = self.runner.run(
                job,
                status_cb=lambda **kw: self.publish_status(job_id, **kw),
                should_stop=self._stopping.is_set,
                # raw build output → Argo node logs (batched by the runner). The coarse
                # phase/progress status messages above still drive the headline.
                log_cb=lambda lines: self.publish_status(job_id, type="log", lines=lines),
            )
            self.publish_status(job_id, state="succeeded", phase="done", progress=1.0,
                                platform=None, message="build + publish complete",
                                artifacts=result.get("artifacts", {}),
                                log_tail=result.get("log_tail", ""))
            self._ack(delivery_tag)
            log(f"job {job_id} SUCCEEDED")
        except BuildError as e:
            # a genuine build/publish failure — do not requeue (would just fail again)
            self.publish_status(job_id, state="failed", phase=e.phase, progress=e.progress,
                                platform=e.platform, message=str(e), log_tail=e.log_tail)
            self._ack(delivery_tag)
            log(f"job {job_id} FAILED: {e}")
        except Exception as e:  # noqa: BLE001 — infra/transient error: requeue once via redelivery
            self.publish_status(job_id, state="failed", phase="infra", progress=0.0,
                                message=f"agent/infra error: {e}")
            self._ack(delivery_tag, requeue_on_fail=True, nack=True)
            log(f"job {job_id} infra error (requeued): {e}")

    # ---- lifecycle -----------------------------------------------------------
    def run_forever(self):
        backoff = 2
        while not self._stopping.is_set():
            try:
                log(f"connecting to {self.cfg['broker']['host']} as {self.name} ...")
                self._connect()
                log(f"connected; consuming '{self.jobs_queue}'. Agent online.")
                backoff = 2
                self._channel.start_consuming()
            except pika.exceptions.AMQPConnectionError as e:
                if self._stopping.is_set():
                    break
                log(f"connection lost: {e}; retrying in {backoff}s")
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
            except Exception as e:  # noqa: BLE001
                log(f"unexpected loop error: {e}; retrying in {backoff}s")
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
            finally:
                try:
                    if self._conn and self._conn.is_open:
                        self._conn.close()
                except Exception:  # noqa: BLE001
                    pass
        log("agent stopped.")

    def stop(self, *_):
        log("shutdown requested; will stop after current job.")
        self._stopping.set()
        try:
            self._conn.add_callback_threadsafe(self._channel.stop_consuming)
        except Exception:  # noqa: BLE001
            pass


def main():
    cfg = load_config()
    agent = Agent(cfg)
    signal.signal(signal.SIGTERM, agent.stop)
    signal.signal(signal.SIGINT, agent.stop)
    agent.run_forever()


if __name__ == "__main__":
    main()

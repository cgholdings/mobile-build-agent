#!/usr/bin/env python3
"""
cg-build-agent — macOS Tart build agent.

Runs natively on an Apple Silicon Mac. Consumes Flutter build jobs from RabbitMQ, and for each
job boots a fresh ephemeral macOS VM (via Tart) that builds iOS + Android and publishes to
TestFlight / Play / Firebase, then destroys the VM. Build status is streamed back to RabbitMQ
(exchange `mobile.status`, routing key = job_id) so the dispatching Argo workflow can display it.

The host talks to RabbitMQ; the VM does the building. See config.example.yaml and README.md.
"""
import base64
import contextlib
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


class JobLost(Exception):
    """The channel that delivered the job closed, so RabbitMQ has requeued it."""


class Lease:
    """The agent's hold on one delivered job: valid while the delivering channel is open and the
    job is within its time bound (counted from delivery). Everything about the job goes through
    that channel, so an execution that lost it can neither ack another job nor end a dispatch."""

    def __init__(self, channel, delivery_tag: int, max_seconds: int):
        self.channel = channel
        self.delivery_tag = delivery_tag
        self.max_seconds = max_seconds
        self._deadline = time.monotonic() + max_seconds

    def check(self) -> None:
        if not self.channel.is_open:
            raise JobLost()
        if time.monotonic() > self._deadline:
            raise BuildError(f"job exceeded {self.max_seconds}s")

    def run_on_channel(self, fn, on_lost=lambda: None) -> None:
        """Runs fn(channel) on the connection's IO thread if the channel is still open, else
        on_lost()."""
        def guarded():
            if self.channel.is_open:
                fn(self.channel)
            else:
                on_lost()
        try:
            self.channel.connection.add_callback_threadsafe(guarded)
        except pika.exceptions.ConnectionWrongStateError:
            on_lost()


def _ack(channel, delivery_tag):
    channel.basic_ack(delivery_tag)


def _requeue(channel, delivery_tag):
    channel.basic_nack(delivery_tag, requeue=True)


def _dead_letter(channel, delivery_tag):
    channel.basic_nack(delivery_tag, requeue=False)


class Agent:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.name = cfg["agent"]["name"]
        self.max_job_seconds = int(cfg["agent"].get("max_job_seconds", 5400))
        self.prefetch = int(cfg["agent"].get("prefetch", 1))
        self.status_exchange = cfg["queues"]["status_exchange"]
        self.jobs_queue = cfg["queues"]["jobs"]
        self.runner = TartRunner(cfg, vm_slots=self.prefetch)
        self._stopping = threading.Event()
        self._conn = None
        self._channel = None
        self._executions: dict[str, list[threading.Thread]] = {}
        self._executions_lock = threading.Lock()

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
        self._channel.basic_qos(prefetch_count=self.prefetch)
        self._channel.basic_consume(self.jobs_queue, self._on_message, auto_ack=False)

    # ---- messages about a job (thread-safe; only through its delivering channel) ----------
    def _status_body(self, job_id: str, fields: dict) -> str:
        ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
        return json.dumps({"job_id": job_id, "agent": self.name, "ts": ts, **fields})

    def _send(self, channel, job_id: str, payload: str) -> None:
        channel.basic_publish(
            self.status_exchange, routing_key=job_id, body=payload,
            properties=pika.BasicProperties(delivery_mode=2, content_type="application/json"))

    def _publish(self, lease: Lease, job_id: str, **fields):
        payload = self._status_body(job_id, fields)

        def publish(channel):
            try:
                self._send(channel, job_id, payload)
            except Exception as e:  # noqa: BLE001
                log(f"WARN: failed to publish status for {job_id}: {e}")

        lease.run_on_channel(publish)

    def _publish_artifact(self, lease, job_id, name, data, content_type, skipped):
        # Contract: {"type":"artifact","name","content_type","encoding":"base64","data"} on
        # mobile.status; the dispatcher stores them as the Argo node's output artifacts.
        if skipped:
            self._publish(lease, job_id, type="log", lines=[f"[agent] artifact {name} {skipped}"])
            return
        log(f"job {job_id}: sending artifact {name} ({len(data)} bytes)")
        self._publish(lease, job_id, type="artifact", name=name, content_type=content_type,
                      encoding="base64", data=base64.b64encode(data).decode("ascii"))

    def _finish(self, lease: Lease, job_id: str, settle, **fields):
        """Publishes the terminal status and settles the delivery in one IO-thread step, so neither
        happens once the delivering channel has closed."""
        payload = self._status_body(job_id, fields)

        def finish(channel):
            try:
                self._send(channel, job_id, payload)
                settle(channel, lease.delivery_tag)
            except Exception as e:  # noqa: BLE001
                log(f"WARN: terminal status/ack failed for {job_id}: {e}")

        lease.run_on_channel(finish, on_lost=lambda: log(
            f"job {job_id}: delivery requeued before the outcome could be reported"))

    # ---- message handling ----------------------------------------------------
    def _on_message(self, ch, method, props, body):
        lease = Lease(ch, method.delivery_tag, self.max_job_seconds)
        # Run each job on its own thread so long builds never block AMQP heartbeats.
        threading.Thread(target=self._process, args=(body, lease), daemon=True).start()

    def _process(self, body: bytes, lease: Lease):
        try:
            job = json.loads(body)
        except Exception as e:  # noqa: BLE001
            log(f"ERROR: undecodable job message, dead-lettering: {e}")
            lease.run_on_channel(lambda ch: _dead_letter(ch, lease.delivery_tag))
            return

        job_id = job.get("job_id", "unknown")
        log(f"picked up job {job_id} make_target={job.get('make_target')} ref={job.get('ref')}")
        self._execute(job_id, job, lease)

    @contextlib.contextmanager
    def _sole_execution(self, job_id: str, lease: Lease):
        """One execution of a job at a time on this Mac: waits, polling the lease, until the job's
        earlier executions (whose deliveries were requeued) have stopped."""
        me = threading.current_thread()
        with self._executions_lock:
            earlier = list(self._executions.setdefault(job_id, []))
            self._executions[job_id].append(me)
        try:
            if earlier:
                log(f"job {job_id}: waiting for its earlier execution to stop")
            for thread in earlier:
                while thread.is_alive():
                    lease.check()
                    thread.join(timeout=3)
            yield
        finally:
            with self._executions_lock:
                self._executions[job_id].remove(me)
                if not self._executions[job_id]:
                    del self._executions[job_id]

    def _execute(self, job_id: str, job: dict, lease: Lease):
        try:
            with self._sole_execution(job_id, lease):
                self._publish(lease, job_id, state="accepted", phase="checkout", progress=0.0,
                              message=f"accepted by {self.name}")
                result = self.runner.run(
                    job, lease,
                    status_cb=lambda **kw: self._publish(lease, job_id, **kw),
                    # raw build output → Argo node logs (batched by the runner). The coarse
                    # phase/progress status messages above still drive the headline.
                    log_cb=lambda lines: self._publish(lease, job_id, type="log", lines=lines),
                    artifact_cb=lambda name, data, content_type, skipped: self._publish_artifact(
                        lease, job_id, name, data, content_type, skipped),
                )
        except JobLost:
            log(f"job {job_id}: delivery requeued (channel closed); stopped this execution")
        except BuildError as e:
            # a genuine build/publish failure — do not requeue (would just fail again)
            self._finish(lease, job_id, _ack, state="failed", phase=e.phase,
                         progress=e.progress, platform=e.platform, message=str(e),
                         log_tail=e.log_tail)
            log(f"job {job_id} FAILED: {e}")
        except Exception as e:  # noqa: BLE001 — infra/transient error: the broker redelivers it
            self._finish(lease, job_id, _requeue, state="failed", phase="infra", progress=0.0,
                         message=f"agent/infra error: {e}")
            log(f"job {job_id} infra error (requeued): {e}")
        else:
            self._finish(lease, job_id, _ack, state="succeeded", phase="done", progress=1.0,
                         platform=None, message="build + publish complete",
                         artifacts=result.get("artifacts", {}),
                         log_tail=result.get("log_tail", ""))
            log(f"job {job_id} SUCCEEDED")

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

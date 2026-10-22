#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""A loopback Git origin whose outage can end without moving a repository ref."""

from __future__ import annotations

import argparse
import contextlib
import datetime
import http.server
import json
import os
import pathlib
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse


def utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def atomic_json(path: pathlib.Path, value: dict) -> None:
    temporary = path.with_name(path.name + "." + str(os.getpid()) + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def stop_backend(process: subprocess.Popen) -> None:
    if os.name == "nt":
        if process.poll() is None:
            subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
    else:
        # The backend can finish before an upload-pack descendant closes stdout.
        # Its process group remains the cancellation boundary in that case.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        until = time.monotonic() + 0.2
        while time.monotonic() < until:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.01)
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        process.wait(timeout=5)


class Fixture:
    def __init__(self, config: dict):
        self.control = pathlib.Path(config["controlPath"]).resolve()
        self.evidence_path = pathlib.Path(config["evidencePath"]).resolve()
        self.repositories = {}
        for name, value in config["repositories"].items():
            if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*", name):
                raise ValueError("invalid fixture repository identity")
            path = pathlib.Path(value).resolve(strict=True)
            if not path.is_dir() or not (path / "HEAD").is_file() or not (path / "objects").is_dir():
                raise ValueError("fixture requires existing bare repositories")
            self.repositories[name] = path
        if not 1 <= len(self.repositories) <= 4:
            raise ValueError("fixture requires one through four repositories")
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.processes: set[subprocess.Popen] = set()
        self.evidence = {"schema": "yuruna.git-mirror.outage-fixture/v1", "startedAt": utc(),
                         "transitions": [], "resetRequests": 0, "healthyRequests": 0,
                         "completedRequests": 0, "backendFailures": 0}
        self.probe = socket.socket()
        self.probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.probe.bind(("127.0.0.1", 0))
        self.probe_port = self.probe.getsockname()[1]
        self.probe_listening = False
        self.mode_value = ""

    def mode(self) -> str:
        try:
            if self.control.stat().st_size > 4096:
                return "reset"
            value = json.loads(self.control.read_text(encoding="utf-8"))["mode"]
            return value if value in ("reset", "healthy") else "reset"
        except (OSError, ValueError, KeyError, TypeError):
            return "reset"

    def record(self, counter: str) -> None:
        with self.lock:
            self.evidence[counter] += 1
            self.evidence["lastRequestAt"] = utc()
            atomic_json(self.evidence_path, self.evidence)

    def probe_loop(self) -> None:
        while not self.stopping.is_set():
            mode = self.mode()
            if mode == "healthy" and not self.probe_listening:
                self.probe.listen(8)
                self.probe.settimeout(0.1)
                self.probe_listening = True
            elif mode == "reset" and self.probe_listening:
                self.probe.close()
                self.probe = socket.socket()
                self.probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.probe.bind(("127.0.0.1", self.probe_port))
                self.probe_listening = False
            if mode != self.mode_value:
                # An observation also promises that the independent TCP probe
                # has reached the same state as the Git transport.
                with self.lock:
                    self.evidence["transitions"].append({"mode": mode, "observedAt": utc()})
                    atomic_json(self.evidence_path, self.evidence)
                self.mode_value = mode
            if self.probe_listening:
                try:
                    client, _ = self.probe.accept()
                    client.close()
                except socket.timeout:
                    pass
            else:
                self.stopping.wait(0.05)

    def close(self) -> None:
        self.stopping.set()
        with self.lock:
            active = list(self.processes)
        for process in active:
            stop_backend(process)
        self.probe_thread.join(timeout=2)
        self.probe.close()
        with self.lock:
            self.evidence["stoppedAt"] = utc()
            atomic_json(self.evidence_path, self.evidence)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.serve_git()

    def do_POST(self):
        self.serve_git()

    def serve_git(self):
        fixture = self.server.fixture
        mode = fixture.mode()
        fixture.record("resetRequests" if mode == "reset" else "healthyRequests")
        if mode == "reset":
            # Reset an established Git connection, independently of the reserved
            # non-listening TCP probe endpoint.
            layout = "hh" if os.name == "nt" else "ii"
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack(layout, 1, 0))
            self.close_connection = True
            return
        url = urllib.parse.urlsplit(self.path)
        match = re.fullmatch(r"/([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*?)\.git/(info/refs|git-upload-pack)", url.path)
        if not match or match[1] not in fixture.repositories or url.query not in ("", "service=git-upload-pack"):
            self.send_error(403)
            return
        repository = fixture.repositories[match[1]]
        if self.headers.get("Transfer-Encoding"):
            self.send_error(411)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if not 0 <= length <= 4 * 1024 * 1024:
            self.send_error(413)
            return
        self.connection.settimeout(3)
        body = self.rfile.read(length)
        if len(body) != length:
            self.send_error(400)
            return
        env = {key: value for key, value in os.environ.items()
               if not key.upper().startswith("GIT_") and key.upper() not in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")}
        env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": str(repository),
                    "GIT_PROJECT_ROOT": str(repository.parent), "GIT_HTTP_EXPORT_ALL": "1",
                    "PATH_INFO": "/" + repository.name + "/" + match[2], "QUERY_STRING": url.query,
                    "REQUEST_METHOD": self.command, "CONTENT_LENGTH": str(length),
                    "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                    "REMOTE_ADDR": "127.0.0.1", "GIT_PROTOCOL": self.headers.get("Git-Protocol", "")})
        process = subprocess.Popen(["git", "http-backend"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=env, start_new_session=os.name != "nt")
        with fixture.lock:
            fixture.processes.add(process)
        def cancel():
            stop_backend(process)
            with contextlib.suppress(OSError):
                self.connection.shutdown(socket.SHUT_RDWR)
        timer = threading.Timer(120, cancel)
        timer.start()
        try:
            process.stdin.write(body)
            process.stdin.close()
            headers, total = [], 0
            while True:
                line = process.stdout.readline(65537)
                total += len(line)
                if total > 65536 or not line:
                    raise ValueError("invalid Git backend response")
                if line in (b"\r\n", b"\n"):
                    break
                headers.append(line.decode("ascii").rstrip("\r\n").split(":", 1))
            status = next((int(value.strip().split()[0]) for key, value in headers if key.lower() == "status"), 200)
            self.send_response(status)
            for key, value in headers:
                if key.lower() not in ("status", "connection", "transfer-encoding"):
                    self.send_header(key, value.strip())
            self.end_headers()
            while chunk := process.stdout.read1(65536):
                self.wfile.write(chunk)
            process.wait(timeout=5)
            fixture.record("completedRequests" if process.returncode == 0 else "backendFailures")
        except (OSError, ValueError, subprocess.TimeoutExpired):
            fixture.record("backendFailures")
        finally:
            timer.cancel()
            stop_backend(process)
            with fixture.lock:
                fixture.processes.discard(process)
            process.stdout.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=pathlib.Path)
    parser.add_argument("--exit-on-stdin-close", action="store_true")
    args = parser.parse_args()
    fixture = Fixture(json.loads(args.config.read_text(encoding="utf-8")))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.fixture = fixture
    fixture.probe_thread = threading.Thread(target=fixture.probe_loop, daemon=True)
    fixture.probe_thread.start()
    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    if args.exit_on_stdin_close:
        def watch_controller():
            sys.stdin.buffer.read()
            stop()
        threading.Thread(target=watch_controller, daemon=True).start()
    print(json.dumps({"baseURL": f"http://127.0.0.1:{server.server_port}",
                      "probeEndpoint": f"http://127.0.0.1:{fixture.probe_port}", "pid": os.getpid()}), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
        fixture.close()


if __name__ == "__main__":
    main()

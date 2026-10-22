#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Exercise the seed's real Apache/CGI routes against a disposable Go worker."""

from __future__ import annotations

import argparse
import base64
import contextlib
import http.server
import json
import os
import pathlib
import pwd
import grp
import fcntl
import shlex
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import urllib.parse


def seed_body(seed: str, path: str) -> str:
    lines = seed.splitlines()
    start = lines.index(f"  - path: {path}")
    while lines[start] != "    content: |":
        start += 1
    body = []
    for line in lines[start + 1 :]:
        if line and not line.startswith("      "):
            break
        body.append(line[6:] if line else "")
    return "\n".join(body).rstrip() + "\n"


def command(args: list[str], **kwargs) -> str:
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True, **kwargs).strip()


def request(url: str, data: bytes | None = None, headers: dict | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=25) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def run(root: pathlib.Path, binary: pathlib.Path) -> dict:
    results = {}
    with tempfile.TemporaryDirectory(prefix="yuruna-apache-mirror-") as temporary:
        work = pathlib.Path(temporary)
        origin = work / "origin"
        origin.mkdir()
        command(["git", "-C", str(origin), "init", "-q", "-b", "main"])
        command(["git", "-C", str(origin), "config", "user.name", "Fixture"])
        command(["git", "-C", str(origin), "config", "user.email", "fixture@example.invalid"])
        (origin / "payload.txt").write_text("production CGI fixture\n")
        (origin / "large.bin").write_bytes(b"fixture bytes" * 700000)
        command(["git", "-C", str(origin), "add", "."])
        command(["git", "-C", str(origin), "commit", "-qm", "fixture"])
        sha = command(["git", "-C", str(origin), "rev-parse", "HEAD"])
        fixture = {
            "root": str(work / "published"),
            "stateRoot": str(work / "state"),
            "readerRoot": str(work / "readers"),
            "signingKey": str(root / "test/extension/caching-proxy-service/testdata/git-mirror/receipts/test-key.pem"),
            "repositories": ["example/repo"],
            "readMilliseconds": 300,
        }
        config = work / "fixture.json"
        config.write_text(json.dumps(fixture))
        env = os.environ.copy()
        count = int(env.get("GIT_CONFIG_COUNT", "0"))
        env[f"GIT_CONFIG_KEY_{count}"] = f"url.{origin.as_uri()}.insteadOf"
        env[f"GIT_CONFIG_VALUE_{count}"] = "https://github.com/example/repo.git"
        env["GIT_CONFIG_COUNT"] = str(count + 1)
        env["YURUNA_GIT_MIRROR_FIXTURE_CONFIG"] = str(config)
        go_log = open(work / "go.log", "w", encoding="utf-8")
        worker = subprocess.Popen(
            [str(binary), "-test.run=^TestGitMirrorFixtureProcess$"], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=go_log, text=True,
            start_new_session=True,
        )
        apache = None
        backend = None
        try:
            assert worker.stdout
            worker_url = json.loads(worker.stdout.readline())["baseURL"]
            worker_port = urllib.parse.urlsplit(worker_url).port

            class Backend(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path in ("/git-mirror/delay", "/landing"):
                        time.sleep(6)
                        code, body = 200, b"delayed"
                    else:
                        code, body = request(worker_url + self.path)
                    self.send_response(code)
                    self.end_headers()
                    with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                        self.wfile.write(body)

                def do_POST(self):
                    body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                    code, result = request(worker_url + self.path, body)
                    self.send_response(code)
                    self.end_headers()
                    self.wfile.write(result)

                def log_message(self, *_):
                    pass

            class Server(http.server.ThreadingHTTPServer):
                allow_reuse_address = True
                daemon_threads = True

            backend = Server(("127.0.0.1", 0), Backend)
            backend_port = backend.server_port
            threading.Thread(target=backend.serve_forever, daemon=True).start()
            # Keep the frontend reservation until its configuration is complete.
            reservation = socket.socket()
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
            script_dir = work / "cgi"
            script_dir.mkdir()
            wrapper = script_dir / "git-mirror-http-backend.sh"
            wrapper_body = (root / "test/extension/caching-proxy-service/git-mirror-http-backend.sh").read_text()
            wrapper_body = wrapper_body.replace("/usr/local/bin/caching-proxy-service", shlex.quote(str(binary)))
            wrapper_body = wrapper_body.replace("--mirror-role=cgi", "--mirror-role=cgi " +
                shlex.quote("--mirror-root=" + fixture["root"]) + " " +
                shlex.quote("--mirror-reader-root=" + fixture["readerRoot"]))
            wrapper.write_text(wrapper_body)
            wrapper.chmod(0o755)
            document = work / "www"
            document.mkdir()
            (document / "index.html").write_text("landing")
            seed = (root / "host/vmconfig/caching-proxy-service.base.user-data").read_text()
            routes = seed_body(seed, "/etc/apache2/conf-available/yuruna-git-mirror.conf")
            routes = routes.replace("127.0.0.1:9310", f"127.0.0.1:{backend_port}")
            routes = routes.replace("127.0.0.1:9311", f"127.0.0.1:{worker_port}")
            routes = routes.replace("/usr/local/libexec/yuruna", str(script_dir))
            routes = routes.replace("/var/lib/yuruna/git", fixture["root"])
            landing = seed_body(seed, "/etc/apache2/conf-available/yuruna-landing.conf")
            landing = landing.replace("/var/www/html", str(document))
            landing = landing.replace("127.0.0.1:9310", f"127.0.0.1:{backend_port}")
            modules = ["mpm_event", "authz_core", "authz_host", "alias", "env", "setenvif",
                       "proxy", "proxy_http", "rewrite", "cgid", "reqtimeout"]
            configuration = work / "apache.conf"
            configuration.write_text(
                "".join(f"LoadModule {module}_module /usr/lib/apache2/modules/mod_{module}.so\n" for module in modules)
                + f'ServerRoot "{work}"\nListen 127.0.0.1:{port}\nServerName localhost\n'
                f'PidFile "{work / "apache.pid"}"\nErrorLog "{work / "apache.log"}"\n'
                f'ScriptSock "{work / "cgi.sock"}"\nDocumentRoot "{document}"\n'
                f'User {pwd.getpwuid(os.getuid()).pw_name}\nGroup {grp.getgrgid(os.getgid()).gr_name}\n'
                + "<Directory />\nRequire all granted\n</Directory>\n" + routes + landing
            )
            command(["apache2", "-t", "-f", str(configuration)])
            reservation.close()
            apache = subprocess.Popen(["apache2", "-f", str(configuration), "-DFOREGROUND"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                      start_new_session=True)
            base = f"http://127.0.0.1:{port}"
            for _ in range(100):
                try:
                    if request(base + "/git-mirror/status.json")[0] == 200:
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError("Apache did not become ready")

            body = json.dumps({"repository": "example/repo", "ref": "HEAD", "nonce": "AAAAAAAAAAAAAAAAAAAAAA"}).encode()
            for _ in range(100):
                code, response = request(base + "/git-mirror/v1/resolve", body)
                assert code == 200, response
                receipt = json.loads(base64.b64decode(json.loads(response)["payload"]))
                if receipt["status"] == "ready":
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("Worker did not publish fixture")
            assert receipt["selectedSha"] == sha
            for protocol in ["0", "1", "2"]:
                checkout = work / ("checkout-" + protocol)
                command(["git", "init", "-q", str(checkout)])
                command(["git", "-C", str(checkout), "-c", f"protocol.version={protocol}", "fetch",
                         "--depth=1", base + "/git/example/repo.git", receipt["fetchRef"]], env=env)
                assert command(["git", "-C", str(checkout), "rev-parse", "FETCH_HEAD"]) == sha
                assert command(["git", "-C", str(checkout), "rev-parse", "--is-shallow-repository"]) == "true"
            results["smartHttpProtocols"] = True
            assert request(base + "/git/example/repo.git/info/refs?service=git-receive-pack")[0] == 403
            assert request(base + "/git/example/repo.git/git-receive-pack", b"0000")[0] == 403
            results["pushDenied"] = True
            assert request(base + f"/git-raw/example/repo/{sha}/payload.txt") == (200, b"production CGI fixture\n")
            results["rawPinned"] = True
            oversized = request(base + "/git-mirror/v1/resolve", b"x" * 4097)
            assert oversized[0] in (400, 413), oversized
            # Upload-pack has its own streaming request contract, not the resolver cap.
            assert request(base + "/git/example/repo.git/git-upload-pack", b"0" * 65536,
                           {"Content-Type": "application/x-git-upload-pack-request"})[0] != 413
            results["bodyLimits"] = True
            # The reader uses a scaled absolute deadline; Apache retains the
            # seed's real socket timeout so it cannot hide a blocked Go writer.
            barrier_path = pathlib.Path(fixture["readerRoot"]) / base64.urlsafe_b64encode(b"example/repo").decode().rstrip("=") / "barrier"
            for disconnect in [False, True]:
                reader = socket.create_connection(("127.0.0.1", port))
                reader.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                reader.sendall(f"GET /git-raw/example/repo/{sha}/large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
                active = False
                started = time.monotonic()
                with open(barrier_path, "rb") as barrier:
                    while time.monotonic() - started < 2:
                        try:
                            fcntl.flock(barrier, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            fcntl.flock(barrier, fcntl.LOCK_UN)
                        except BlockingIOError:
                            active = True
                            break
                        time.sleep(0.005)
                    assert active, "raw request never acquired a reader lease"
                    if disconnect:
                        reader.close()
                    while time.monotonic() - started < 2:
                        try:
                            fcntl.flock(barrier, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            fcntl.flock(barrier, fcntl.LOCK_UN)
                            break
                        except BlockingIOError:
                            time.sleep(0.01)
                    else:
                        raise AssertionError("raw request retained its lease past the absolute read/cancel budget")
                reader.close()
            results["boundedBlockedReaders"] = True
            slow = socket.create_connection(("127.0.0.1", port))
            slow.settimeout(25)
            started = time.monotonic()
            slow.sendall(b"POST /git-mirror/v1/resolve HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n{")
            reply = slow.recv(4096)
            slow.close()
            assert b"408" in reply.split(b"\r\n", 1)[0], reply
            results["slowBodySeconds"] = time.monotonic() - started
            assert results["slowBodySeconds"] < 23
            started = time.monotonic()
            assert request(base + "/git-mirror/delay") == (200, b"delayed")
            results["backendDelaySeconds"] = time.monotonic() - started
            started = time.monotonic()
            assert request(base + "/")[0] in (502, 503, 504)
            results["landingDeadlineSeconds"] = time.monotonic() - started
            assert results["landingDeadlineSeconds"] < 6
            backend.shutdown()
            backend.server_close()
            assert request(base + "/git-mirror/status.json")[0] in (502, 503)
            backend = Server(("127.0.0.1", backend_port), Backend)
            threading.Thread(target=backend.serve_forever, daemon=True).start()
            assert request(base + "/git-mirror/status.json")[0] == 200
            results["immediateBackendRecovery"] = True
            logs = (work / "apache.log").read_text()
            assert "Sharing worker" not in logs and "Ignoring parameter" not in logs, logs
            results["workerIsolation"] = True
            results["servingIdentity"] = pwd.getpwuid(os.getuid()).pw_name
            results["sandboxQualified"] = False
            return results
        finally:
            if backend:
                backend.shutdown()
                backend.server_close()
            for process in [apache, worker]:
                if process and process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
            go_log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    print(json.dumps(run(arguments.root.resolve(), arguments.binary.resolve()), sort_keys=True))

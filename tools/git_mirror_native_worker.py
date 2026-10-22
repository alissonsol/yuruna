#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Bounded fault controls for an explicitly disposable provisioned proxy VM."""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request

UNIT = "git-mirror-worker.service"
BASE = Path("/run/yuruna-gitmirror-qualification")
UNIT_DROPINS = Path("/run/systemd/system/git-mirror-worker.service.d")


def command(*args, timeout=30, check=True):
    return subprocess.run(args, check=check, timeout=timeout, capture_output=True, text=True).stdout.strip()


def worker_pid():
    value = int(command("systemctl", "show", UNIT, "--property=MainPID", "--value"))
    if value <= 0:
        raise RuntimeError("mirror worker is not running")
    return value


def encode_request(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode()


def environment_assignments(raw, endpoint):
    current = dict(item.split(b"=", 1) for item in raw.split(b"\0") if b"=" in item)
    count = int(current.get(b"GIT_CONFIG_COUNT", b"0"))
    if count < 0 or count > 1024:
        raise ValueError("invalid existing Git configuration count")
    result = {}
    for index in range(count):
        key = current[f"GIT_CONFIG_KEY_{index}".encode()].decode()
        value = current[f"GIT_CONFIG_VALUE_{index}".encode()].decode()
        # Exact fixture rewrites would otherwise outrank the broad outage URL.
        if key.startswith("url.") and key.endswith(".insteadOf") and value.startswith("https://github.com/"):
            key = f"url.{endpoint}.insteadOf"
        result[f"GIT_CONFIG_KEY_{index}"] = key
        result[f"GIT_CONFIG_VALUE_{index}"] = value
    result[f"GIT_CONFIG_KEY_{count}"] = f"url.{endpoint}.insteadOf"
    result[f"GIT_CONFIG_VALUE_{count}"] = "https://github.com/"
    result["GIT_CONFIG_COUNT"] = str(count + 1)
    return result


def environment_file(values):
    def quote(value):
        if "\0" in value or "\n" in value or "\r" in value:
            raise ValueError("multiline environment value is not supported by the fault fixture")
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$") + '"'
    return "".join(f"{key}={quote(value)}\n" for key, value in values.items())


def restore(request, directory):
    state_path = directory / "state.json"
    if not state_path.exists():
        return {"passed": True, "restored": False}
    state = json.loads(state_path.read_text())
    dropin = Path(state["dropin"])
    expected = UNIT_DROPINS / ("zzzz-qualification-" + request["runId"] + ".conf")
    if dropin != expected:
        raise RuntimeError("fault state names an unowned drop-in")
    dropin.unlink(missing_ok=True)
    command("systemctl", "stop", "yuruna-mirror-restore-" + request["runId"] + ".timer", check=False)
    command("systemctl", "stop", "yuruna-mirror-socket-" + request["runId"] + ".service", check=False)
    command("systemctl", "daemon-reload")
    command("systemctl", "restart", UNIT, timeout=45)
    pid = worker_pid()
    shutil.rmtree(directory)
    return {"passed": True, "restored": True, "workerPid": pid}


def enable(request, directory):
    if directory.exists():
        raise RuntimeError("this fault run already exists; restore it before reuse")
    directory.mkdir(mode=0o700, parents=True)
    os.chmod(BASE, 0o700)
    helper = directory / "worker.py"
    helper.write_text(globals().get("_PROGRAM") or Path(__file__).read_text())
    os.chmod(helper, 0o700)
    dropin = UNIT_DROPINS / ("zzzz-qualification-" + request["runId"] + ".conf")
    if dropin.exists():
        raise RuntimeError("fault drop-in already exists")
    state = {"dropin": str(dropin), "previousPid": worker_pid(), "expiresAt": time.time() + 900}
    (directory / "state.json").write_text(json.dumps(state))
    try:
        # Cleanup also runs if the remote controller disconnects or is killed.
        cleanup = dict(request, action="RestoreOutage")
        command("systemd-run", "--quiet", "--unit=yuruna-mirror-restore-" + request["runId"],
                "--on-active=15m", "/usr/bin/python3", str(helper), encode_request(cleanup))
        hold = dict(request, action="HoldSocket")
        command("systemd-run", "--quiet", "--unit=yuruna-mirror-socket-" + request["runId"],
                "--property=RuntimeMaxSec=16min", "/usr/bin/python3", str(helper), encode_request(hold))
        deadline = time.monotonic() + 10
        while not (directory / "endpoint.json").exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("fault socket did not become ready")
            time.sleep(0.1)
        endpoint = json.loads((directory / "endpoint.json").read_text())["endpoint"]
        values = environment_assignments(Path(f"/proc/{state['previousPid']}/environ").read_bytes(), endpoint)
        env_path = directory / "worker.env"
        env_path.write_text(environment_file(values))
        os.chmod(env_path, 0o600)
        dropin.parent.mkdir(parents=True, exist_ok=True)
        with dropin.open("x") as stream:
            stream.write("[Service]\nEnvironmentFile=" + str(env_path) + "\n")
        command("systemctl", "daemon-reload")
        command("systemctl", "restart", UNIT, timeout=45)
        pid = worker_pid()
        actual = dict(item.split(b"=", 1) for item in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0") if b"=" in item)
        if any(actual.get(key.encode()) != value.encode() for key, value in values.items()):
            raise RuntimeError("another unit setting overrides the bounded fault environment")
        return {"passed": True, "workerPid": pid, "endpoint": endpoint, "expiresAt": state["expiresAt"], "mode": request.get("mode", "Reset")}
    except BaseException:
        restore(request, directory)
        raise


def hold_socket(request, directory):
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        endpoint = f"http://127.0.0.1:{reserved.getsockname()[1]}/"
        (directory / "endpoint.json").write_text(json.dumps({"endpoint": endpoint}))
        if request.get("mode", "Reset") == "Unauthorized":
            reserved.listen()
            while True:
                client, _ = reserved.accept()
                with client:
                    client.sendall(b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="qualification"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
        else:
            # Bound without listen: the socket remains reserved and refuses TCP.
            time.sleep(960)


def resolve(request, timeout):
    body = {"repository": request["repository"], "ref": request.get("ref", "HEAD"),
            "nonce": base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip("=")}
    deadline = time.monotonic() + timeout
    while True:
        req = urllib.request.Request("http://127.0.0.1/git-mirror/v1/resolve", json.dumps(body).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=18) as response:
            envelope = json.load(response)
        receipt = json.loads(base64.b64decode(envelope["payload"], validate=True))
        if receipt["status"] != "pending":
            return receipt
        if time.monotonic() >= deadline:
            raise TimeoutError("worker operation did not finish within its qualification deadline")
        body["operationId"] = receipt["operationId"]
        time.sleep(0.2)


def worker_scenario(request):
    repository = request["repository"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or ".." in repository.split("/"):
        raise ValueError("invalid canonical repository")
    repo = Path("/var/lib/yuruna/git") / (repository + ".git")
    action = request["action"]
    started = time.monotonic()
    if action == "NoUpstream":
        switch = Path("/etc/squid/conf.d/yuruna-no-upstream.conf")
        previous = switch.exists()
        try:
            command("/usr/local/sbin/yuruna-no-upstream", "on")
            receipt = resolve(request, 130)
            passed = receipt["upstreamOutcome"] == "transport" and receipt["reason"] == "upstream-blocked-by-switch"
        finally:
            if not previous:
                command("/usr/local/sbin/yuruna-no-upstream", "off")
        return {"passed": passed, "receipt": receipt, "restoredSwitch": not previous, "durationSeconds": time.monotonic() - started}
    if action == "Populate":
        if repo.exists():
            raise RuntimeError("population requires an unpopulated registered repository")
        with urllib.request.urlopen("http://127.0.0.1/git-mirror/status.json", timeout=5) as response:
            status = json.load(response)
        other_sizes = {}
        for item in status["repositories"]:
            if item["name"] == repository:
                continue
            if item["state"] != "ready":
                raise RuntimeError("populate the other registered repositories before measuring the largest one")
            other = Path("/var/lib/yuruna/git") / (item["name"] + ".git")
            other_sizes[item["name"]] = int(command("du", "-sb", str(other)).split()[0])
        receipt = resolve(request, 1800)
        command("runuser", "-u", "yuruna-git-worker", "--", "git", "-c", "safe.directory=" + str(repo),
                "-C", str(repo), "fsck", "--connectivity-only", "--no-dangling", timeout=120)
        size = int(command("du", "-sb", str(repo)).split()[0])
        return {"passed": receipt["status"] == "ready" and receipt["objectReady"] and size >= max(other_sizes.values(), default=0),
                "receipt": receipt, "durationSeconds": time.monotonic() - started, "repositoryBytes": size,
                "otherRegisteredRepositoryBytes": other_sizes}
    if action == "KillMidFetch":
        if not repo.exists():
            raise RuntimeError("mid-fetch recovery requires an existing mirror and an advanced upstream ref")
        before = worker_pid()
        request_error = []
        def initiate():
            try:
                resolve(request, 130)
            except Exception as error:
                request_error.append(type(error).__name__)
        caller = threading.Thread(target=initiate, daemon=True)
        caller.start()
        cgroup = command("systemctl", "show", UNIT, "--property=ControlGroup", "--value")
        deadline = time.monotonic() + 30
        fetching = None
        while time.monotonic() < deadline:
            for value in (Path("/sys/fs/cgroup") / cgroup.lstrip("/") / "cgroup.procs").read_text().split():
                try:
                    arguments = Path(f"/proc/{value}/cmdline").read_bytes().split(b"\0")
                    if arguments and Path(os.fsdecode(arguments[0])).name == "git" and b"fetch" in arguments:
                        fetching = int(value)
                        break
                except FileNotFoundError:
                    continue
            if fetching and (repo / "yuruna-in-progress").exists():
                break
            fetching = None
            time.sleep(0.02)
        if not fetching:
            raise RuntimeError("no marked fetch observed; use an advanced upstream with a deliberately slow disposable transport")
        command("systemctl", "kill", "--kill-whom=all", "--signal=SIGKILL", UNIT)
        deadline = time.monotonic() + 45
        while True:
            try:
                after = worker_pid()
                if after != before:
                    break
            except RuntimeError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError("worker did not restart after the marked fetch was killed")
            time.sleep(0.2)
        receipt = resolve(request, 130)
        command("runuser", "-u", "yuruna-git-worker", "--", "git", "-c", "safe.directory=" + str(repo),
                "-C", str(repo), "fsck", "--connectivity-only", "--no-dangling", timeout=120)
        locks = [str(path.relative_to(repo)) for path in repo.rglob("*.lock")]
        return {"passed": receipt["status"] == "ready" and not locks and not (repo / "yuruna-in-progress").exists(),
                "beforePid": before, "afterPid": after, "killedFetchPid": fetching, "markerObserved": True,
                "remainingLocks": locks, "receipt": receipt, "interruptedRequest": request_error,
                "durationSeconds": time.monotonic() - started}
    raise ValueError("unsupported worker scenario")


def main(request):
    if os.geteuid() != 0:
        raise RuntimeError("worker controls require root on the disposable proxy")
    run_id = request.get("runId", "")
    if not re.fullmatch(r"[0-9a-f]{32}", run_id):
        raise ValueError("runId must be 32 lowercase hexadecimal characters")
    directory = BASE / run_id
    if BASE.is_symlink() or directory.is_symlink():
        raise RuntimeError("fault runtime paths cannot be symbolic links")
    action = request["action"]
    if action == "EnableOutage":
        return enable(request, directory)
    if action == "RestoreOutage":
        return restore(request, directory)
    if action == "HoldSocket":
        return hold_socket(request, directory)
    return worker_scenario(request)


if __name__ == "__main__":
    response = main(json.loads(base64.urlsafe_b64decode(sys.argv[1])))
    print(json.dumps(response))

#!/usr/bin/python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Send a paced text burst through one libvirt connection.

The caller supervises this process with a wall-clock cap. A failed or killed
send has an unknown guest outcome and must never be replayed automatically.
"""

import json
import sys
import time

KEY_HOLD_MS = 1
MIN_CHAR_DELAY_MS = 10


def validate_request(request):
    """Reject the complete request before opening a connection or sending keys."""
    if not isinstance(request, dict) or not isinstance(request.get("vmName"), str):
        raise ValueError("invalid VM name")
    delay = request.get("charDelayMs")
    if type(delay) is not int or not 0 <= delay <= 2147483647:
        raise ValueError("invalid character delay")
    chords = request.get("chords")
    if not isinstance(chords, list):
        raise ValueError("invalid chords")
    for chord in chords:
        if not isinstance(chord, list) or not 1 <= len(chord) <= 2:
            raise ValueError("invalid chord")
        if any(type(key) is not int or not 1 <= key <= 65535 for key in chord):
            raise ValueError("invalid key code")


def send(request, libvirt, sleep=time.sleep):
    sent = 0
    connection = None
    try:
        validate_request(request)
        connection = libvirt.open("qemu:///system")
        if connection is None:
            raise RuntimeError("libvirt connection was not opened")
        domain = connection.lookupByName(request["vmName"])
        for chord in request["chords"]:
            # A zero hold selects QEMU's default 10ms delay after EVERY key
            # down/up, making a shifted chord consume 40ms of queued input.
            # Rapid bursts can overflow that queue and drop Shift release.
            # Explicit 1ms pulses consume at most 4ms per chord; keep a 10ms
            # floor, including after the last chord, to let releases drain.
            domain.sendKey(
                libvirt.VIR_KEYCODE_SET_LINUX, KEY_HOLD_MS, chord, len(chord), 0
            )
            sent += 1
            sleep(max(request["charDelayMs"], MIN_CHAR_DELAY_MS) / 1000.0)
        return {"status": "ok", "sent": sent}
    except Exception as error:
        return {"status": "failed", "sent": sent, "error": str(error)}
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass


def main():
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            request = json.load(source)
        validate_request(request)
    except Exception as error:
        print(json.dumps({"status": "failed", "sent": 0, "error": str(error)}))
        return 1
    try:
        import libvirt
    except ImportError:
        # This is the sole fallback signal. No connection or key RPC has
        # been attempted, so the caller may safely use the virsh backend.
        print(json.dumps({"status": "unavailable", "sent": 0}))
        return 78
    libvirt.registerErrorHandler(lambda _context, _error: None, None)
    result = send(request, libvirt)
    print(json.dumps(result))
    return 0 if result["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())

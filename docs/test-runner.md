# Test runner — unattended continuous cycles setup

Please read the **Administrator Risk Warning** section of the [Yuruna License](../LICENSE.md).

`test/Invoke-TestRunner.ps1` is the daily-driver loop: it pulls the
repository, re-reads `test.config.yml`, refreshes base images on a
configurable cadence, then walks each entry of `guestSequence` —
creating a fresh VM, driving its sequences, and recording results — in
a loop that is meant to run for hours or days without an operator
present.

See [test-config.md](test-config.md) for the `test.config.yml` parameter
reference, including the optional `networkStorage` NAS replication tier and how to
set its SMB password in the vault; [pool-storage.md](pool-storage.md) covers that
tier's architecture and operations.

This document covers what to do **once per machine** before leaving
the runner unattended. For the architecture of the loop itself see
[Test harness — architecture](test-harness.md).

## Why unattended cycles

Continuous validation across hours or days catches intermittent
failures — timing-sensitive UI hangs, transient network issues,
cumulative resource leaks, upstream-mirror rate limits, OS auto-update
windows — that a single interactive run misses. The unattended runner
in this document trades human monitoring for coverage breadth: it
runs against the same `guestSequence` every cycle, surfaces every
fault through the same `last_failure.json` + NDJSON event channels,
and absorbs each transient via the
[failure-pause loop](runner-outer-loop.md#failure-pause-break-out-triggers)
without operator intervention. The lab environment described below
(test account, isolated network, no personal data) is what makes that
unattended-by-design contract safe to leave running.

## Prepare the host

**Do not run unattended test automation using a personal account.**

It is assumed that unattended machines will be in a physically protected
environment, like a test lab, with controlled access. Despite that, it is
important to use test accounts with limited network access and
no access to personal data in the local machine.

### Create a test account

  - Use the script `test/New-LocalTestUser.ps1` to create a local test account.
  - Reset the password to a known value. **Do not leave this information in open text files and sticky notes.**
  - Make the local test account a machine administrator.
  - Log in using the test account.
  - Execute the install script one-liners for your host, as per the [install](../install/README.md) instructions.
  - Run the `Enable-TestAutomation.ps1` script that ships under your host type:

    | Host type | Script |
    |-----------|--------|
    | `host.windows.hyper-v` | [`host/windows.hyper-v/Enable-TestAutomation.ps1`](../host/windows.hyper-v/Enable-TestAutomation.ps1) |
    | `host.macos.utm`       | [`host/macos.utm/Enable-TestAutomation.ps1`](../host/macos.utm/Enable-TestAutomation.ps1) |
    | `host.ubuntu.kvm`      | [`host/ubuntu.kvm/Enable-TestAutomation.ps1`](../host/ubuntu.kvm/Enable-TestAutomation.ps1) |

    You may be asked the administrator (sudo) password (multiple times,
    depending on the operating system).

    Each variant configures the host-side settings that would otherwise
    interrupt a long run — display timeout, machine inactivity lock, lock
    screen on resume, ICMP / status-service firewall rules, display scale
    (HiDPI laptops up-scale screenshots and break Tesseract OCR). The
    scripts are idempotent; re-running them is safe.

## First interactive run

Before the first unattended run, execute `test/Invoke-TestRunner.ps1`
at least once **interactively** on the machine. Two things only the
operator can do happen on that first execution:

- **Approve runtime permissions.** Some platform prompts (Hyper-V
  service, accessibility / screen-recording on macOS, virsh / libvirt
  group membership on Linux) only fire on first use and cannot be
  pre-accepted from a script.
- **Seed the base-image cache.** The runner's image-refresh step
  downloads each guest's base image on first execution; subsequent
  cycles re-use the cached copy and re-download only on the configured
  refresh cadence. Pre-seeding lets the unattended loop recover from a
  later failure (or a step that needs manual intervention) without
  blocking on a multi-gigabyte download mid-cycle.
  - **macOS and Windows base images must be downloaded manually.** 
  Due to limitations imposed by the image providers, the runner 
  cannot fetch them. Follow the instructions in each `Get-Image.ps1`.

## Run unattended

Once the host is prepared and the first interactive cycle has
completed, launch the runner:

```
pwsh test/Invoke-TestRunner.ps1
```

The script self-supervises: stale-heartbeat detection, single-instance
guard, and the failure-pause back-off all live in
[Watchdog](watchdog.md). Per-step visibility is controlled by
[Log levels](loglevels.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.14

Back to [Yuruna](../README.md)

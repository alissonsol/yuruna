# Yuruna Contributor Opportunities

Prioritized work the project would welcome help on. New contributors:
pick something at a priority level that matches the time you have, and
read [Contributing](../CONTRIBUTING.md) for the workflow.

Status legend: 🚧 in progress · ⏸ paused / deferred ·
no marker = open. Last reviewed 2026-06-04.

## Verb-handler migration progress

The move from the inline switch in `Invoke-Sequence.psm1` to the
per-verb registry in `Test.SequenceAction.psm1` +
`Test.SequenceHandler.psm1` is complete — all 21 verbs are registry
handlers. `retry` and `recoverFromSnapshot` were the last two; their
engine-private failure state was lifted into the shared
`Test.SequenceFailureState` store (`$script:Fail`), so they now live in
`Test.SequenceHandler.psm1` with the rest of the catalog and
`Invoke-Sequence.psm1` is purely the executor.

✓ H-10 (`Invoke-Sequence` verb-handler split) — done.

## Architecture as of 2026-06

What the test harness's structural building blocks look like today;
each is a module you can grep for if you want to extend it.

- Shared cross-entry-point helpers:
  [`Test.LogLevel`](../test/modules/Test.LogLevel.psm1) ([cascade
  semantics](loglevels.md)), `Test.Config` (mtime-cached YAML reader),
  `Test.InnerSpawn` (type-preserving argv builder), `Test.ConfigPreflight`
  (pre-cycle Test-Config gate), `Test.Prelude` (canonical entry-point
  path bundle).
- [Host I/O registry](host-io.md) — `Send-Key` / `Send-Text` /
  `Send-Click` dispatch through `Test.HostIO` so a new host or a new
  action verb is one registration, not three edits in the engine.
  Platform keystroke / mouse / VNC backends live in `Test.Transport`.
- [Deployment-kind catalog](../automation/Yuruna.DeploymentKind.psm1) —
  the `chart` / `kubectl` / `helm` / `shell` detection, the kinds error
  text, the tool-expression mapping and the retry gating resolve through
  one `Yuruna.DeploymentKind` catalog shared by the validator
  (`Confirm-WorkloadList`) and the publisher (`Publish-WorkloadList`), so
  a new tool-expression kind is one `Register-YurunaDeploymentKind` line,
  not parallel edits in two modules.
- [Capability matrix](capability-matrix.md) — startup banner + per-cycle
  gate that refuses cycles referencing host I/O backends not wired on
  the current host. Replaces the prior silent "Unknown host: …" mode.
- `Test.SequenceAction` — per-verb registry with `Handler` scriptblocks,
  failure-label builders, and `FailureClass` / `Severity` /
  `SuggestedRecoveries` metadata consumed by the
  [failure-schema v2](../test/modules/Invoke-Sequence.psm1) writer.
  Contract reference: [handler schema](handler-schema.md).
- [`New-YurunaRegistry`](../test/modules/Test.Registry.psm1) — the shared,
  eviction-safe in-memory registry primitive (Register/Get/Has/GetMatrix/Clear
  closures over a `$global:`-anchored store). The Host I/O, `Test.SequenceAction`,
  screenshot-provider, and VNC-provider registries are all built on it, so every
  domain registry shows up in one introspection call
  (`Get-YurunaRegistryDirectory`) instead of each module owning a private anchor.
- Module decomposition under `test/modules/`: `Test.Output`,
  `Test.ConfigValidator`, `Test.PortOwner`,
  `Test.ScreenshotProvider` / `Test.VncProvider` /
  `Test.CredentialProvider` (paired registry + recovery primitives).
- Telemetry: per-cycle NDJSON event log
  (`<cycleFolder>/cycle.events.ndjson`); `Send-Notification`
  supports an `-EventData` structured payload and runs async by
  default.
- Mobile / dark-mode: status pages use CSS custom properties and
  `prefers-color-scheme: dark`; the dashboard pauses polling when the
  tab is hidden.
- Operator docs: [log levels](loglevels.md), [OCR providers](ocr.md),
  [watchdog](watchdog.md), [host I/O](host-io.md),
  [capability matrix](capability-matrix.md),
  [extensions API](extensions-api.md),
  [guest image setup (common pattern)](guest-image-setup.md).

## Global

### P0

- Get to at most one "framework incident" every 24 hours.
- SSH support across hosts.
- Windows sequence for startup and minimal workload test.
- **Installer & in-guest script integrity.** The bootstrap installers
  ([`install/windows.hyper-v.ps1`](../install/windows.hyper-v.ps1),
  [`install/macos.utm.sh`](../install/macos.utm.sh),
  [`install/ubuntu.kvm.sh`](../install/ubuntu.kvm.sh)) are fetched and
  executed via `irm | iex` / `curl | bash` with no integrity check, and
  all three then `git clone --branch main` — a moving target. The
  Windows installer also re-fetches the same URL inside its elevated
  relaunch (TOCTOU window between the two fetches). The in-guest
  [`fetch-and-execute.sh`](../automation/fetch-and-execute.sh) has the
  same shape — `wget -qO- … | bash` of working-tree content served by
  the status server, see `feedback_status_server_working_tree_rename_race.md`.
  Changes needed:
  - Publish `install.sha256` alongside each installer; one-liners in
    [`install/README.md`](../install/README.md) print the expected hash
    so an operator can `sha256sum -c` before piping.
  - Pin clones to release tags rather than `main`; fall back to `main`
    only with an explicit warning.
  - Collapse the Windows-installer double-fetch — materialize the
    fetched source ONCE to a single BOM-less temp file and relaunch the
    elevated child via `-File` (NOT `-EncodedCommand`: the ~44 KB
    installer base64-encodes ~3.6× over the 32,767 CreateProcess
    command-line cap, see `feedback_createprocess_cmdline_limit.md`).
  - Guest-side per-fetch verification in `fetch-and-execute.sh` is
    declined (disposable test VM fetching from the same trust domain);
    the shipped change is a one-line transparency message before the
    download, and the working-tree-rename race is handled operationally
    by the capture self-heal (`feedback_status_server_working_tree_rename_race.md`).
  - Pin GPG fingerprints for the MS / GitHub CLI keys added in
    [`install/ubuntu.kvm.sh`](../install/ubuntu.kvm.sh) (otherwise a
    MITM on first install installs an attacker-controlled key).
  - Add a tiny `Test-AsciiNoBom.ps1` CI gate so the
    `feedback_bootstrap_installer_no_bom.md` constraint on
    `install/windows.hyper-v.ps1` is enforced automatically.

### P1

- Need something like: loop: _number(001-003)
- Before "cloud-based" scripts execute, validate session
- Validation: repeated resource names and other duplications like context names

### P2

- Time zone still wrong in Ubuntu
- Check if tofu requires variable and not provide it if not needed (avoids warnings).
- Documentation
  - How to start new project from the "template".
  - How to use a single PowerShell script for the several commands in a repeated block until someday implementing loop: _number(001-003)
- Finish testing and publish the resources for AWS and GCP
  - More resource templates in general

### P3+

- Mobile framework integration (Maestro, etc.)
- For resources created using tofu `local-exec`: destroy when doing `tofu destroy`
- Create Visual Studio Code extension to start projects, run commands, etc.
  - Visual Studio Code: [Your First Extension](https://code.visualstudio.com/api/get-started/your-first-extension)
- Graph from YML: Python [graphviz 0.15](https://pypi.org/project/graphviz/)
- Decide on copying all code during component setup (`automation/Yuruna.Component.psm1`)

## AWS

- Fix issue with Windows (/bin/sh) when executing `tofu apply` [Works for macOS]
  - <https://github.com/terraform-aws-modules/terraform-aws-eks/issues/757>
- import-clusters: get created registry credentials
- Cluster IP?
  - <https://docs.aws.amazon.com/vpc/latest/userguide/vpc-ip-addressing.html#vpc-public-ipv4-addresses>
  - public_subnet_map_public_ip_on_launch

## Azure

- Global improvements

## GCP

- Global improvements
- Fix the cluster.min_master_version: creating with v1.19+ failed
  - Consequence: hack to deploy the ingress, since today it depends on v1.19+ syntax
- IP load balancer not working.

## Host / guest

- Document Hyper-V Amazon Linux nested virtualization setup (`host/windows.hyper-v/guest.amazon.linux.2023/read.more.md`)

### Host-driver shared helpers

Each virtualization backend has its own
`host/<host>/modules/Yuruna.Host.psm1` driver implementing the canonical
contract ([`Yuruna.Host.Contract.psm1`](../host/Yuruna.Host.Contract.psm1),
enforced at module load by `Assert-YurunaHostContractCoverage`). The contract
verbs are platform-specific by design: Hyper-V cmdlets, libvirt/`virsh`, and
the UTM CLI are genuinely different backends, as are the three host-proxy,
screen-capture, and disk-snapshot stacks.

Logic that is *not* platform-specific is factored into shared modules under
[`host/modules/`](../host/modules/) so a fix lands once instead of drifting
across drivers — injecting the one varying platform detail as a scriptblock or
a plain parameter rather than reaching across a module boundary by name:

- [`Yuruna.HostDownload`](../host/modules/Yuruna.HostDownload.psm1) — the squid
  caching-proxy download stack (HTTP proxy + HTTPS SSL-bump with per-process CA
  trust); the cache-VM IP discovery is injected as `-ResolveCacheHostIp`.
- [`Yuruna.HostProvision`](../host/modules/Yuruna.HostProvision.psm1) — the
  cross-driver helpers that differ only in one platform detail: the per-guest
  `New-VM.ps1` / `Get-Image.ps1` child-runners (`Invoke-PerGuestNewVm`,
  `Invoke-GetImage` — host subdir as a plain parameter, `Get-ImagePath` and the
  log writer injected), the guest-IP poll (`Invoke-WaitVmIp`, with `Get-VMIp`
  injected), and the squid-reachability probe (`Invoke-CachingProxyAvailableProbe`,
  win/mac). Each driver's `New-VM` / `Get-Image` / `Wait-VMIp` /
  `Test-CachingProxyAvailable` is a thin wrapper supplying its one platform
  variable — a host-subdir or verify-hint string, or a driver-private command
  captured as `CommandInfo` (`Get-VMIp`, `Get-ImagePath`) so the shared body
  never resolves a name across a module boundary.
- `Yuruna.Image` / `Yuruna.UbuntuImage` (image integrity + checksum) and
  `Yuruna.VMCleanup`; `test/modules/Test.VMUtility` and `Test.CachingProxy`
  hold the host-proxy-path and cache-state primitives the drivers share.

What stays driver-local is the irreducibly platform-specific backend code (three
VM backends, three host-proxy / capture / snapshot stacks). The cross-driver
duplication worth extracting is now factored out; what remains is deliberately
left per-platform — the host-proxy, firewall, and bridge paths are
routing/security-adjacent and only validatable by a live cycle on each host, so
the cost of a shared abstraction there outweighs the lines it would save. (The
KVM `Test-CachingProxyAvailable` is intentionally *not* folded into the shared
probe: it omits the IPv6 host-bracketing the guests rely on, so converging it
would change the proxy URL they trust.)

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)

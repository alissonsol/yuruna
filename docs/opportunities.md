# Yuruna Contributor Opportunities

Prioritized work the project would welcome help on. New contributors:
pick something at a priority level that matches the time you have, and
read [Contributing](../CONTRIBUTING.md) for the workflow.

Status legend: ✓ done · 🚧 in progress · ⏸ paused / deferred ·
no marker = open. Last reviewed 2026-05-29.

## Audit-cycle outcomes (2026-05)

Four cycles ran during the 2026-05 architectural review. All
Critical, High, and Medium issues resolved or verified as false
positives; the Low batch + R-* resilience mechanisms also closed.

- ✓ Criticals (8): atomic state-sidecar writes, crash-safe `New-VM`
  cleanup, cycle-folder `.incomplete` marker, dark-mode WCAG-AA
  contrast lift, 4-digit temp-path entropy, GUID-uniqueness scan.
- ✓ Highs (10): watchdog heartbeat freshness, atomic pidfile +
  sidecar, FailureClass enum coverage, centralised NDJSON guard,
  failure-time host diagnostic, NDJSON-on-init-failure, image
  SHA-256 (warn-only), cycle-log rotation at CYCLE_HISTORY_LIMIT.
- ✓ Mediums (11): unified registry shapes, Get-PollDelay extraction,
  Test.KeyCodeRegistry split, caching-proxy YAML corruption signal,
  snapshot existence pre-validation, copyright headers, extension
  enumeration, cycleId stamping, sidecar inventory docs, config-
  snapshot infrastructure.
- ✓ Resilience mechanisms (R-1, R-4..R-12, partial R-2): atomic
  state-file primitive, failure-class dispatcher, boot recovery
  sweep, snapshot manifest sidecars, NDJSON schema validator,
  cycle correlation IDs, image-integrity gateway (6/9 Get-Image
  scripts wired), log rotation, runner state machine, key-code
  registry.
- ⏸ H-10 (Invoke-Sequence verb-handler split, ~2461 LOC) —
  deferred pending the comment-to-markdown migration.

## Verb-handler migration progress

Tracking the move from inline switch in `Invoke-Sequence.psm1` to
the per-verb registry in `Test.SequenceAction.psm1` +
`Test.SequenceHandler.psm1`:

| Status | Verb | Notes |
| --- | --- | --- |
| ✓ | `waitForSeconds` | In `Test.SequenceHandler.psm1`. |
| ✓ | `pressKey` | In `Test.SequenceHandler.psm1`. |
| ✓ | `break` | In `Test.SequenceHandler.psm1`. |
| ✓ | `saveDiskSnapshot` | In `Test.SequenceHandler.psm1`. R-6 wires manifest write. |
| ✓ | `loadDiskSnapshot` | In `Test.SequenceHandler.psm1`. M-5 + R-6 wire validation. |
| ✓ | `saveSystemDiagnostic` | In `Test.SequenceHandler.psm1`. |
| ✓ | `callExtension` | In `Test.SequenceHandler.psm1`. |
| ✓ | `inputText` / `inputTextAndEnter` | In `Test.SequenceHandler.psm1`. |
| ✓ | `waitForText` / `waitForAndEnter` | In `Test.SequenceHandler.psm1`. |
| ✓ | `passwdPrompt` | In `Test.SequenceHandler.psm1`. |
| ✓ | `tapOn` | In `Test.SequenceHandler.psm1`. |
| ✓ | `takeScreenshot` | In `Test.SequenceHandler.psm1`. |
| ✓ | `fetchAndExecute` | In `Test.SequenceHandler.psm1`. |
| ✓ | `sshWaitReady` / `sshExec` / `sshFetchAndExecute` | In `Test.SequenceHandler.psm1`. |
| 🚧 | `retry` | Inlined in `Invoke-Sequence.psm1` because it reads/writes engine-private `$script:LastFailure*` slots. H-10. |
| 🚧 | `recoverFromSnapshot` | Same engine-state coupling as `retry`. H-10. |

17 of 19 verbs migrated. Remaining two are blocked on the
engine-state-extraction prerequisite tracked under H-10.

## Architecture as of 2026-05

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
- [Capability matrix](capability-matrix.md) — startup banner + per-cycle
  gate that refuses cycles referencing host I/O backends not wired on
  the current host. Replaces the prior silent "Unknown host: …" mode.
- `Test.SequenceAction` — per-verb registry with `Handler` scriptblocks,
  failure-label builders, and `FailureClass` / `Severity` /
  `SuggestedRecoveries` metadata consumed by the
  [failure-schema v2](../test/modules/Invoke-Sequence.psm1) writer.
  Contract reference: [handler schema](handler-schema.md).
- Module decomposition under `test/modules/`: `Test.Output`,
  `Test.ConfigValidator`, `Test.PortOwner`,
  `Test.ScreenshotProvider` / `Test.VncProvider` /
  `Test.CachingProxyProvider` / `Test.CredentialProvider` (paired
  registry + recovery primitives).
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
- Generic registry login approach in `automation/Yuruna.Component.psm1`
  (today only `*.azurecr.io` is handled via `az acr login`; needs
  ECR / GAR / Docker Hub / generic-docker-login coverage; the
  scaffolding now lives in
  [`Test.CredentialProvider`](../test/modules/Test.CredentialProvider.psm1)
  — wire the missing providers there).
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
  Track of changes needed:
  - Publish `install.sha256` alongside each installer; one-liners in
    [`install/README.md`](../install/README.md) print the expected hash
    so an operator can `sha256sum -c` before piping.
  - Pin clones to release tags rather than `main`; fall back to `main`
    only with an explicit warning.
  - Collapse the Windows-installer double-fetch — pass the already-
    fetched script via `-EncodedCommand` to the elevated child instead
    of re-`irm`ing the URL.
  - Add a `?sha=…` parameter to `fetch-and-execute.sh` that the guest
    verifies before exec, so a host-side mid-edit cannot deliver
    partial content.
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

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.

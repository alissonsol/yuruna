# Changelog

Yuruna uses [Calendar Versioning](https://calver.org/): `YYYY.MM.DD`.
Tags are cut from the `main` branch; entries below summarize each
tagged release.

## 2026.08.07

- **Converting a standalone machine into a pool worker.** New
  `test/Convert-ToPoolWorker.ps1` syncs the lab's configuration, then retires
  the four local service VMs that would otherwise keep winning over the lab's,
  drops their hosts-file aliases, and verifies the end state. `-WhatIf`
  previews.

- **Pool Control is the only place hostnames appear.** Its Hosts table gains
  sortable **Hostname** and **Type** columns, read from each host's own record
  — the aggregator stays deliberately hostname-free. **Show hostnames** takes
  the Lab token. Re-run `test/Start-PoolControlServiceVM.ps1`.

- **Also in this release.** Shared cycle results now travel as a `.zip`. The
  host dump page becomes **Diagnostics** (`host.html` → `diagnostics.html`). A
  converting host no longer keeps self-minted passwords. New
  `test/Clear-LocalLabStorage.ps1` withdraws a former storage server's shares,
  deleting no data.

## 2026.08.06

- **Share cycle results.** New menu option from the Yuruna hosts dashboard
   enables sharing the results for a test cycle via a ".tar.gz" file.

- **Also in this release.** Style fixes across service pages. Reduced
  memory for VMs in standalone mode. The cache VM's zot registry moves to
  v2.1.20.

## 2026.08.05

- **One way to build an extension service.** Four hand-copied beacons, write
  gates and hardcoded framework lists become one `service:` manifest per area,
  a shared Go SDK and one host module — a new extension service is discovered
  by existing. See
  [extensions-api.md](docs/extensions-api.md#the-extension-interface).

- **Anything that changes host or pool configuration now needs the Lab token.**
  Pool-control's write routes shipped behind a `--passcode` nothing ever set,
  open LAN-wide. They now take the rotating **Lab token** or the bearer
  `lab-auth-token`. Reads stay open. See
  [pool-admin.md](docs/pool-admin.md#unlocking-the-actions).

- **Also in this release.** Three fixes came along: the download-agent's
  auto-seed now reads the aggregator with the trusted-LAN client, fixing its
  certificate failures against the proxy's own CA; pool-control's login
  throttle no longer hands every IPv6 peer a fresh bucket; and pool-supplied
  URLs are scheme-checked before rendering as links.

## 2026.08.04

- **One machine downloads the image, the whole lab has it.** The new
  `yuruna-download-agent-service` VM holds images on the pool share,
  re-checking them against the origin on a timer. Its board's per-image
  actions unlock with the rotating **Lab token**. See
  [download-agent.md](docs/download-agent.md).

- **And the other machines stop downloading it.** `Get-Image.ps1` asks the
  agent before the publisher: an already-current copy ends the run without a
  byte, otherwise bytes arrive checksum-verified over the LAN. A lab without an
  agent sees no difference. See
  [guest-image-setup.md](docs/guest-image-setup.md#agent-first-image-downloads).

- **Also in this release.** The Windows 11 and virtio-win ISOs can come from
  the pool too, best effort. `Sync-PoolDashboardOnProxy.ps1` corrects the hosts
  dashboard without a proxy rebuild. `users.yml` gains later services' users.
  *Pool hosts* now shows **runner stopped** and pending pauses instead of stale
  green. **Needs a caching-proxy service rebuild.**


## 2026.08.03

- **A setup run can be told to say everything.** `install/setup.ps1` takes
  `-logLevel Error|Warning|Information|Verbose|Debug`, and the level reaches
  every script the run starts — down to the per-guest image and VM builders — so
  a bring-up that failed inside a child can be repeated with the whole chain
  verbose. The run log is written in full at every level; the level decides what
  also reaches the terminal. See
  [loglevels.md](docs/loglevels.md#a-setup-run-is-the-deepest-chain-of-it).

## 2026.08.02

- **A setup run leaves a record.** `install/setup.ps1` now writes
  `test/status/log/setup.<yyyy.MM.dd.HH.mm>.log` — every question and where its
  answer came from, every step, child command line, and exit code. The elevated
  Windows relaunch continues the same file. See
  [install/README.md](install/README.md#guided-setup).

- **Also in this release.** The pool advertises only stash addresses it has
  itself reached, dropping ones unanswered for 5 minutes; `Test-Config.ps1`
  gained an *Extension services (pool registry)* section. **Needs a
  caching-proxy service rebuild.** See
  [extensions-api.md](docs/extensions-api.md#only-an-address-the-pool-has-reached-is-answered)
  and
  [test-config.md](docs/test-config.md#extension-services-pool-registry--where-this-hosts-stash-actually-is).

## 2026.07.31

- **Sequence steps get their console keystrokes back.** The integrity envelope
  shrank from 281 to 223 characters, returning 58 of the ~400 a VM console
  carries intact. **Needs a guest rebuild:** older VMs refuse the digest rather
  than run unverified code. See
  [definition.md](docs/definition.md#defining-the-fetch-and-execute-typed-envelope).
- **Kubernetes guests pull container images through the cache again.** On
  containerd 2.2 the `certs.d` edit matched nothing, so images bypassed the
  caching-proxy zot, hanging flannel and leaving nodes `NotReady`. It now
  matches, and fails loudly if the shape changes. See
  [definition.md](docs/definition.md#defining-containerd-hoststoml-cache-mirror).
- **Also in this release.** `pwsh install/setup.ps1` takes a standalone host or
  a lab beacon from clone to running, asking only what it cannot infer. The
  dashboard's **Lab token** tile now turns red when the collector stops
  reporting. See
  [operator.md](docs/operator.md#a0-shortcut-the-standalone-setup-script).

## 2026.07.29

- **The dashboard says which hosts you can drive, before you click.** A
  **Control** column in *Pool hosts* reads `remote`, `onsite`, or `unknown`,
  and is now the host link — one cell per row grants control. The verdict
  comes from a new open read route, `GET /control/control-status`. Needs a
  caching-proxy rebuild. See [control-routes.md](docs/control-routes.md).
- **A lab with no NAS sets up its storage in one command.**
  `pwsh test/New-LocalLabStorage.ps1` creates the folders, accounts, SMB
  shares, vault entries, mounts, and `networkStorage.*` config — idempotent
  and `-WhatIf`-able. A second lab on the same machine reuses it:
  `New-Lab.ps1` infers `-Root` and keeps existing share credentials. See
  [operator.md](docs/operator.md#b7-local-shares-for-pool-and-stash-storage).
- **Renaming.** Renaming artifacts for better consistency. Services,
  scripts, and documentation impacted.

## 2026.07.28

- **Every dashboard host link now grants the control token, and refusals say
  why.** Table Host ID links now route through `/go/host`, over plain http
  (the aggregator answers TLS and HTTP on `:9400`), and the "Control refused"
  notice names the failing precondition. Deploying needs a caching-proxy
  rebuild. See [control-routes.md](docs/control-routes.md).
- **Enrolling a host in the lab is one command and a glance at the dashboard.**
  Read the rotating code off the **Lab token** tile;
  `pwsh test/Set-LabToken.ps1 -LabToken <code>` redeems it for the shared
  `lab-auth-token` and stores it in the host vault, replacing
  `Set-PoolAuthToken.ps1`. Needs a caching-proxy rebuild. See
  [control-routes.md](docs/control-routes.md).

## 2026.07.26

- **The host clock is reported by a cycle, repaired by an operator.** Cycles
  no longer sync it or refuse a drifted host — the repair needs sudo nobody
  can type unattended. A cycle warns once; `Test-Config.ps1` offers the fix.
  See [test-harness.md](docs/test-harness.md#the-host-clock).

## 2026.07.26

- **Pool control runs as its own service.** `Start-PoolControlVM.ps1` and
  `Stop-PoolControlVM.ps1` build and run it on a dedicated VM, matching the
  caching-proxy and stash scripts. It now reports version, build, environment,
  and a pass/fail check list on a `/diagnostics` page, and `Remove-PoolHost.ps1`
  retires decommissioned hosts. See
  [pool-admin.md](docs/pool-admin.md#pool-control-service).
- **Teardown actually destroys again: `Invoke-Clear.ps1`.** Clearing a
  configuration reported success while destroying nothing, so cloud resources
  kept billing: it looked for a `resources:` list that `resources.output.yml`
  never carries. Teardown now walks the deployed resource keys and runs
  `tofu destroy` in each work folder. See
  [cleanup](docs/kubernetes.md#cleaning-up-cloud-resources).
- **Also in this release**: leftover VMs swept at cycle start rather than
  aborting the run; VM starts without a VNC display now fail; dedicated test
  user; the status document surviving per-cycle re-import; quieter steady-state
  warnings; hardened UTM keystrokes; and fixes across KVM snapshots, pool-share
  deletes, host IP, and Ubuntu setup.

## 2026.07.24

- **Each service VM now has its own administrator account.** The
  caching-proxy, pool-control, and stash VMs shared one seeded account, so
  all three passwords resolved to one vault entry: building any one overwrote
  the other two's credential. They now use `caching-proxy-admin`,
  `pool-control-admin`, and `stash-admin`, each with its own vault key. VMs
  seeded with the old account keep it until rebuilt; `Move-CachingProxy.ps1`
  takes `-OldUser` for a source VM whose account differs. See
  [operator.md](docs/operator.md).
- **Scripts that build a VM now say so**: `Start-CachingProxyVM.ps1`,
  `Start-PoolControlVM.ps1`, `Start-StashVM.ps1` (with matching `Stop-`
  counterparts). `Start-StatusService.ps1` and `Start-HostConfigService.ps1`
  start host-side services and keep their names. `Set-PoolAuthToken.ps1` and
  `Sync-HostConfiguration.ps1` renamed `-BounceStatusServer` to
  `-BounceStatusService`.
- **Also in this release**: Breaking schema change for test sequences with
  matching project adjustment (and a 2026.07.22 early release for cross-release tests),
  `memoryStartupBytes` sequence variable.

## 2026.07.21

- **A test sequence can name its guest: `variables.hostname` now sets the VM's hostname**. The chain cascade carried `username` to cloud-init but dropped `hostname`; declaring it on any sequence now reaches the guest's `local-hostname` on all three hypervisors. Sequences declaring none follow the VM name. See [vmconfig.md](docs/vmconfig.md).
- **Also in this release**: the npm requirement now matches pinned Node 24 LTS (`11.16.0`, was `12.0.1`), so provisioned hosts stop failing their own check; `docs/syntax.md` folded into [architecture.md](docs/architecture.md) and [loglevels.md](docs/loglevels.md), completing the CLI reference. A supply-chain and resilience sweep landed too: the Microsoft RPM signing key and guest PowerShell tarball are verified against published hashes, managed-cluster API endpoints restricted, guests quarantine after repeated failures, late-step failures warm-resume in place, and stale-lease IP discovery falls back to `utmctl`/ARP. Retry paths gained jitter and transient/permanent telemetry.

## 2026.07.17

- **The cache VM's IP can be pinned across rebuilds: `-MacAddress` on
  `Start-CachingProxy.ps1`.** Each rebuild booted with a random [MAC address](https://en.wikipedia.org/wiki/MAC_address), so [DHCP](https://en.wikipedia.org/wiki/Dynamic_Host_Configuration_Protocol) leased a new IP. The optional parameter pins the MAC on all three
  hypervisors; a one-time DHCP reservation keeps the cache IP stable. See
  [caching.md](docs/caching.md#caching-proxy-service--test-harness-operator-reference).
- **`gh auth login` (or `GH_TOKEN`) now works for git, everywhere the runner
  talks to GitHub.** Plain `git` reads neither, so fresh hosts failed the
  first cycle's framework pull. Every network git call now chains the host's
  credential sources — github.com-scoped `GH_TOKEN`, then
  `gh auth git-credential`, then plain git.
- **Also in this release:** `Sync-HostConfiguration` installs the Linux
  sudoers drop-in and converges aliases/credentials on the reference host;
  on-host control clicks work again; stash DELETE requires an authorized
  source; `Set-PoolAuthToken.ps1` reports progress and no longer hangs; new
  guest VMs ask for 12 GB instead of 16 GB.

## 2026.07.14

- **Yuruna hosts dashboard panels fit the pool.** The caching-proxy VM now ships Python scripts that every 5 minutes will read the live host count from Prometheus + Loki on loopback,
  recompute each panel's `gridPos.h` from the dashboard grid geometry, re-stack
  the panels below it, and rewrite the provisioned dashboard, which the Grafana
  provider re-reads within 30s.
- **Driving a host remotely now takes a proof.** The mutating `/control/*`
  routes now demand loopback or a short-lived HMAC in `X-Yuruna-Control`, minted
  from the shared pool-auth-token by the aggregator's `/go/host` deep-link; reads
  stay open. `test/Set-PoolAuthToken.ps1` provisions the token. See
  [control-routes.md](docs/control-routes.md).
- **Three silent failures fixed.** The dispatcher shared the extension contract's
  `Send-Notification` name, so alerts bound to a transport and vanished (it is now
  `Send-YurunaNotification`); snapshot manifests and runner state fell back to
  `$env:TEMP`, undefined on POSIX, so they threw on macOS and Ubuntu; and
  `Clear-CredentialProvider` rebound its own name instead of emptying the shared
  registry.

## 2026.07.10

- **Sync-HostConfiguration.** New per-host-type operator script
  (`host/<type>/Sync-HostConfiguration.ps1 -ReferenceHost <host>`) that copies a
  working pool host's `test.config.yml` onto this host — converting the
  networkStorage values across host types (UNC slash style; `y:`/`z:` vs
  `/mnt/<server>` vs `~/Shares/<server>` local-mount conventions), preserving the
  local `secrets` node, adding a missing NAS hosts-file alias from the reference
  host's resolution, and fetching missing vault credentials over the status
  server's new `pool-auth-token`-gated, encrypted `/control/vault-credential`
  route (with `/control/host-aliases` supplying the name→IP mappings). Shared
  logic in `test/modules/Test.HostConfigSync.psm1`. See
  [pool-storage.md](docs/pool-storage.md) (Syncing a new host's config from a
  reference host).
- **Stash presence beacon.** The stash server now self-announces to the
  pool-aggregator (`POST /announce`) on boot, every 15 minutes
  (configurable via `--presence-interval` / `STASH_PRESENCE_INTERVAL`), and
  at shutdown, so the *Yuruna hosts* dashboard's **Extension hosts** row no
  longer depends on the owning host's status server being up — the row now
  survives host reboots and aggregator restarts (announces are journaled to
  Loki and rehydrated on startup). The aggregator also serves pool-status
  `stashBaseUrl` (registration target with announce fallback), completing
  the stash UI's remote-host resolution. See the [pool-aggregator README](test/extension/pool-aggregator-service/README.md).

## 2026.07.07

- **Reliability & self-healing hardening sweep.** Ended the code sweep. Mid-week test release to verify automated scripts and hardening.
- **Region tags.** Added region tags across the code to ease detection of behavior drift across hosts, guests and tests.

## 2026.07.03

- **Hosts auto-update the framework by default.** Fresh installs now clone the
  moving `main` branch, so the runner's per-cycle `git pull --ff-only`
  fast-forwards each host to the latest framework every cycle — previously the
  installers cloned a release tag, leaving a detached HEAD that the pull
  silently no-op'd, freezing hosts at their install-time version. Pinning is now
  opt-in via `-PinVersion` (Windows) / `PIN_VERSION=1` / `--pin-version`
  (macOS, Ubuntu), which reads the repo's own `VERSION` as the single source of
  truth. See [install.md](docs/install.md) and
  [opportunities.md](docs/opportunities.md).
- **Reliability & self-healing hardening sweep.** Roughly 66 review findings plus
  targeted fixes across the automation and diagnostic paths: hard wall-clock
  bounds on the VNC handshake, `Wait-SshReady`, and the persistent OCR WinRT
  worker; safer macOS/UTM teardown (verified deregistration, powered-off before
  delete); bounded retries on guest provisioning; crash-counter persistence
  across respawn; stale-PID and stale `last_failure.json` misattribution guards;
  and more diagnosable OCR, transport, and workload failure paths. See
  [opportunities.md](docs/opportunities.md).
- **Commit column on the Yuruna hosts dashboard.** The Pool hosts table now shows
  each host's current framework and project short SHAs with per-repo deep-links,
  sourced from every host's `status.json` — the same data the host status page's
  Commit block renders. See [pool-admin.md](docs/pool-admin.md).

## 2026.06.30

- **Stash stop now leaves no VM files behind.** `Stop-StashServer` gracefully
  stops the VM and then removes it together with every on-disk file it owns (the
  disk image, the cloud-init seed, and the host bundle), so the next
  `Start-StashServer` builds from a clean slate. The durable stash data is
  unaffected — received files, sidecar records, and the persisted SSH host key
  live on the NAS share, not the disposable VM disk. See
  [stash-guide.md](docs/stash-guide.md).
- **Dashboards update.** Extension hosts panel added to the Yuruna hosts dashboard. The Pool hosts panel now reports the paused status. Other minor visual updates.
- **Mid-week release.** Test release to verify automated scripts.

## 2026.06.26

- **Slip-proof release tagging.** The release tool now creates, pushes, and
  validates the bare-CalVer tag itself (read from `VERSION`, never hand-typed;
  refuses a `v`-prefixed variant or a moved tag), and the installers resolve a
  pinned tag whether it was published with or without a `v` prefix — closing a
  tag-drift break that may break one-line installs. See
  [install.md](docs/install.md).
- **Installer and fetch resilience.** Transient-HTTP retries now cover bare
  `500`s on helm/kubectl/tofu fetches, in-guest Kubernetes install steps retry,
  and the three platform installers are hardened (arm64 hard gate, brew
  `NONINTERACTIVE`, Windows `git clone` exit-code checks). See
  [install.md](docs/install.md) and [opportunities.md](docs/opportunities.md).

## 2026.06.19

- **Stash Service available.** The Stash Service is functional end-to-end — start
  it, then guests upload artifacts to it and you browse and serve them from the
  host. See [stash-guide.md](docs/stash-guide.md).
- **Independent stash and pool storage.** The Stash Service and the pool network
  storage can now live on **different NAS shares with different accounts**. Where a
  host's OS refuses two credentials to one server, define a **machine alias** (a
  second hostname for the same NAS) so each tier mounts under its own server name.
  See [pool-storage.md](docs/pool-storage.md) and [test-config.md](docs/test-config.md).
- **Clearer host-configuration preflight.** Several `Test-Config.ps1` refinements
  guide the operator more directly toward validating and fixing the host setup
  (storage mounts, stale SMB alias mappings, credentials) before a run. See
  [test-config.md](docs/test-config.md).

## 2026.06.12

- **Multi-host pool harness.** Test hosts can run as a named **pool** sharing
  sequences and reporting under one `poolId`, driven by a read-only intent store
  with no central dispatcher (default-off, falls back to standalone). A
  self-discovering aggregator feeds the **Yuruna hosts** Grafana dashboard. See
  [pool-admin.md](docs/pool-admin.md) and [opportunities.md](docs/opportunities.md).
- **poolStorage (ypsp) NAS replication.** Pool observability data replicates to a
  NAS share over SMB on Windows, Ubuntu, and macOS — async, fail-fast, atomic,
  hardware-fingerprinted identity. See [pool-storage.md](docs/pool-storage.md).
- **Signed installer integrity.** The three platform installers gain a SHA-256
  manifest with a detached release signature, verified against a committed
  RSA-4096 key, plus in-guest hash checks and an ASCII/BOM pre-commit gate. See
  [install.md](docs/install.md) and [opportunities.md](docs/opportunities.md).
- **Converged cloud-init.** AL2023 and Ubuntu guests collapse drifting per-platform
  `user-data`/`meta-data` into one shared base plus per-host overlays; orphaned
  anchors throw at merge time. See [vmconfig.md](docs/vmconfig.md#how-user-data-is-rendered).
- **Actionable failure telemetry.** First-failure records carry a shared taxonomy,
  copy-paste repro command, classified-cause enrichment, and remediation routing.
  See [failure-schema.md](docs/failure-schema.md).

## 2026.06.05

- **Multi-registry login for component pushes.** Adds ECR, GAR, Docker Hub, and generic Docker login alongside azurecr; the registryLogin phase now shares the build/tag/push log capture.
- **Ctrl+C cleanup in Test-Sequence.** Interrupts now stop the VM cleanly instead of orphaning a half-baked guest; the disk is retained for post-mortem via virsh/vmconnect/utmctl.
- **Single-instance guard for dev entry points.** Test-Sequence and Test-Project refuse to start when an Invoke-TestRunner already owns `runner.pid`, avoiding pidfile/status.json races on the same runtime dir.
- **Shared cloud-init base + per-host overlays for Ubuntu Server.** Six drifting per-platform user-data files collapse to one base plus three overlays; orphan/undefined anchors throw at merge time so a typo can't ship a broken guest install.
- **Removed broken `test/Train-Screenshots.ps1`.** Runtime screenshot testing stays via `Invoke-ScreenshotTest`.

## 2026.05.29

- **Self-healing reliability features.** Adds the runner state machine, snapshot manifest sidecars, and a remediation dispatcher.
- **Stash service.** New extension to receive SCP'd guest artifacts (diagnostic bundles, screenshots) into a host-side stash; PowerShell wrapper over a Go daemon.
- **Jittered backoff between retry attempts.** The `retry` verb no longer burns all attempts in milliseconds; it waits a jittered, capped delay and refreshes the heartbeat so the watchdog stays aligned.
- **Concurrent-write safety for `status.json`.** Atomic writers now use per-writer PID+GUID temp names so one process's rename can't clobber another's half-written temp.
- **Atomic `last_failure.json`.** Both normal and crash paths write through `Write-YurunaStateFile`, closing the window where a reader could see a truncated record.

## 2026.05.22

- **Username cascade + corporate identity mapping.** New `users.yml` maps logical sequence usernames onto corporate identities (AD/Entra) plus the vault keys holding their passwords.
- **`test/status/` reorganization (breaking layout change).** All harness runtime state moves under one tree with at most two subfolder levels before data.

## 2026.05.15

- **Initial release.** First release with working hosts and guests.

---

LICENSEURI <https://yuruna.link/license>

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.07

Back to [Yuruna](README.md)

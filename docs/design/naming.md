# Naming conventions

> One sentence: the rules every Yuruna name follows -- components, config keys,
> durations, booleans, acronyms, PowerShell verbs, and pages -- plus the foreign
> contracts that are deliberately exempt.

A name is read far more often than it is written, and a name that disagrees
with a neighboring one costs a reader a lookup every time. These rules exist
so a name can be *derived* rather than remembered: knowing the component and
the shape of the thing is enough to predict what it is called.

## Components: every long-running network component is a service

The word **server** does not name a Yuruna component. Prose says
"<name> service" in sentence case; slugs, extension areas, VM names and
systemd units say `<name>-service`.

| Component | Prose | Slug / area / VM |
| --- | --- | --- |
| Squid front on the cache VM | the caching-proxy service | `caching-proxy-service` |
| Squid access-log parser | the caching-proxy-parser service | `caching-proxy-parser-service` |
| Squid Prometheus exporter | the squid-exporter service | `squid-exporter` (upstream binary name) |
| Pool intent UI + API | the pool-control service | `pool-control-service` |
| Fleet telemetry aggregator | the pool-aggregator service | `pool-aggregator-service` |
| Artifact store daemon | the stash service | `stash-service` |
| Pool-wide guest-image downloader | the download-agent service | `download-agent-service` (`downloadAgentService` config key) |
| Per-host status HTTP daemon | the status service | `statusService` (config key) |
| Per-host mTLS credential daemon | the config service | `configService` (config key) |

Two words keep a narrower meaning: **the stash** is the artifact store as a
*place* ("upload binaries to the stash"), not the daemon; **dashboard** is
Grafana, while `index.html` is **the status page**.

## Durations: two units, spelled out

`<name>Ms` for sub-second values, `<name>Seconds` for everything else. There is
no `Minutes`, `Hours`, `Sec`, `Millis`, or unsuffixed duration. Environment
variables follow with `YURUNA_*_SECONDS` / `YURUNA_*_MS`.

A value carried in a **type that already names its unit** -- .NET `TimeSpan`,
Go `time.Duration` -- takes no suffix: `hostTtl`, `pushTimeout`,
`$sw.Elapsed`. The suffix exists to disambiguate a bare number, and there is
nothing bare about `2 * time.Hour`.

## Booleans: a bare adjective or verb phrase

`enabled`, `stopOnFailure`, `moveLogsToPoolStorage`, `alwaysRedownload`. No `is` or
`should` prefix, and no `Enabled` suffix on a compound -- nest it instead:

```yaml
autoRemediation:
  enabled: false
  maxAttemptsPerCycle: 2
```

PowerShell locals are the exception that proves the rule: `$isRunning` /
`$shouldRetry` are idiomatic *there* and stay.

## Acronyms are words in camelCase

`Ip`, `Url`, `Vm`, `Ca`, `Ocr`, `Ttl` -- so `cachingProxyIp`, `ghToken`,
`Get-CachingProxyServiceVmIp`, `announceTtl`. SCREAMING_SNAKE is for
environment variables only; a YAML key is never SCREAMING_SNAKE.

The host-contract verbs are the exception, and deliberately so: `New-VM`,
`Remove-VM`, `Get-VMIp`, `Get-VMState` and their siblings keep `VM` because a
host driver sits directly beside the Hyper-V cmdlets of the same name, and one
of the two spellings being different would be a worse trap than the
inconsistency. The list lives in
[`host/Yuruna.Host.Contract.psm1`](../../host/Yuruna.Host.Contract.psm1); a name
outside it follows the rule.

## PowerShell verbs and module namespaces

- `Test-` is a **validation predicate** and nothing else: it answers a
  question, it does not run work. `Test-Config.ps1` validates; the thing that
  *runs* a sequence is `Debug-TestSequence.ps1`.
- `Invoke-` runs something to completion and returns; `Start-` launches a
  long-running process that owns the host until it is stopped -- whether it
  detaches (`Start-StatusService.ps1`) or holds the terminal until Ctrl+C
  (`Start-TestRunner.ps1`); `Debug-` also runs to completion but is built for
  a human in the loop -- it reuses existing state and takes a step window so a
  failure can be re-entered, which is why the sequence dev helper is
  `Debug-TestSequence.ps1`.
- Module namespaces: `Test.*` is the test harness, `Yuruna.*` is product
  automation and the host drivers.

## Config keys

camelCase, nested under the block that owns them, named for what they mean
rather than for the file they came from. "pool" unqualified means the host
fleet; the NAS that fleet shares is **pool storage**
(`poolStorageNetworkPath`), which is what the code calls it.

Only the current spellings are accepted. `test/Test-Config.ps1` fails a config
carrying a retired key and names the replacement;
`pwsh tools/Update-TestConfigNaming.ps1` converts a whole file, values and
nesting included. The retired-key table lives in
[`test/modules/Test.ConfigNaming.psm1`](../../test/modules/Test.ConfigNaming.psm1),
which is what both of those read.

## Test-VM names

`<testVmNamePrefix><guestKey>[-<hostId8>]-<NN>`, with the guest key **verbatim**
-- `test-guest.ubuntu.server.24-01`. See
[host/README.md](../../host/README.md) for what a host implementation may
assume about it.

## Host ids: one key, two renderings

The host id is `42` plus 30 hex, and the **undashed 32-hex** form is the only one
that is ever a key -- `runtime/host.uuid`, `POOL.members`, every telemetry label.
Two renderings exist and neither may be written back to a store:

| Form | Where | Produced by |
| --- | --- | --- |
| `42a1b2c3d4e5...` (32 hex) | every store, join and label | `Get-YurunaHostId` |
| `42a1b2c3-d4e5-...` (8-4-4-4-12) | any surface showing an operator a **full** id | `Format-YurunaHostId`, JS `guid` |
| `42a1b2c3` (first 8) | dense surfaces -- dashboard columns, `<hostId8>` in a VM name | JS `Y.shortHost` |

The dashes are not decoration: a lab holds a dozen ids that share the `42`
prefix, and 32 undifferentiated hex characters cannot be checked against another
screen by eye. Because the dashed form is what an operator copies, every
pool-admin entry point canonicalizes on the way in through
`ConvertTo-YurunaHostId`.

Render and canonicalize are not inverses. A renderer passes anything that is not
32 bare hex through untouched, so a pool GUID keeps its own dashes; the
canonicalizer strips braces and dashes first and returns `$null` on anything that
is not `42` + 30 hex. Never feed a rendering back to a store, and never hand a
pool GUID to the canonicalizer.

## Pages

Named for their function, not their file history: `config.html`,
`diagnostics.html`, `performance.html`. `index.html` is the status page.

## Exempt: foreign contracts

These look like rule violations and are not. They belong to somebody else's
schema, and "fixing" them breaks the contract:

| Name | Owner |
| --- | --- |
| `AddSeconds`, `TotalSeconds`, `ElapsedMilliseconds` | .NET API surface |
| `periodSeconds`, `initialDelaySeconds`, `timeoutSeconds` in manifests | Kubernetes schema |
| `squid-exporter`, `squid.service`, `/var/log/squid` | upstream squid + boynux/squid-exporter |
| `GH_TOKEN` as an **environment variable** | `gh(1)` convention (the config *key* is `ghToken`) |
| `ypool-nas`, `ystash-nas` | external NAS hostnames |
| `RestartSec`, `OnBootSec`, `OnUnitActiveSec`, `AccuracySec` | systemd unit/timer directives |
| `-TimeoutSec` as a cmdlet **argument** | PowerShell (`Invoke-WebRequest`); our own parameters are `-TimeoutSeconds` |
| `New-VM`, `Get-VMIp`, `Remove-VM`, ... | the host-contract verbs that mirror Hyper-V (see above) |
| `TEST-NET-1/2/3` | RFC 5737 documentation ranges |

Cycle-artifact files under `status/log/` and the entries in the changelog
record what was true when they were written; they keep their original
spellings.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.18

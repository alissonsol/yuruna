# Pool admin

The whole pool-admin CLI -- everything that reads or writes a lab's pool
intent store -- plus the sample intent files under [`examples/`](examples/).

| Script | Purpose |
|---|---|
| `New-Pool.ps1` | create a pool |
| `Remove-Pool.ps1` | delete one |
| `Add-HostToPool.ps1` | add a host to a pool's members |
| `Remove-HostFromPool.ps1` | remove a host from ONE pool's members |
| `Remove-PoolHost.ps1` | purge a stale host: delete its NAS records and strip ALL memberships |
| `Set-PoolTestSet.ps1` | assign the pool's one test-set (framework + project repo pair); replaces any previous one |
| `Set-PoolTestSetDefinition.ps1` | upsert or delete a library test-set |
| `Set-PoolDesiredState.ps1` | flip a pool between `run`, `paused` and `drain` |
| `Get-PoolIntent.ps1` | dump the whole intent store as JSON |
| `Get-PoolStatus.ps1` | read a pool's members and assigned test-set |
| `Test-PoolIntent.ps1` | schema-validate `pools.yml` (+ `guests.compatibility.yml`) and enforce the one-pool-per-host invariant |
| `Convert-ToPoolWorker.ps1` | turn a standalone machine into a worker of an existing lab |
| `Sync-PoolDashboardOnProxy.ps1` | push the canonical dashboard assets to the lab's caching-proxy-service |

```
pwsh test/pool/Test-PoolIntent.ps1
pwsh test/pool/Set-PoolDesiredState.ps1 -PoolId lab -State paused -IntentGitUrl <writable-url>
```

Full command table, parameters and workflow:
[Pool admin](../../docs/pool-admin.md).

## The pool-control-service daemon shells out to these

`test/extension/pool-control-service/` drives this CLI rather than
reimplementing git + YAML + schema validation in Go. It carries each script
as a `test/`-relative path -- the `exec` calls in
`server/internal/intent/intent.go`, the `poolAdminCLIs` presence probe in
`server/internal/httpsrv/diagnostics.go`, and the skip guard in
`server/internal/intent/cliargs_test.go`. Moving a script out of this folder
means editing all three, and the last one matters most: it guards the only
check that catches Go/PowerShell parameter drift, and a wrong path there
makes that check *skip* rather than fail.

The daemon is `go build`-ed inside its guest at VM bring-up, so a running
pool-control-service VM keeps the paths it was built with until rebuilt.

## Cross-folder callers

`Convert-ToPoolWorker.ps1` reaches outside this folder for
`../lab/Sync-HostConfiguration.ps1` and `../Test-Config.ps1`, and hands
`$paths.TestRoot` (never `$PSScriptRoot`) to the `Test.PoolWorker` teardown
helpers, which resolve service scripts under `test/service/`.

## Path base

Each script resolves its roots through
`Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder`,
which walks one level up to `test/`. Pre-prelude module imports use
`Join-Path $PSScriptRoot '../modules/<name>.psm1'`.

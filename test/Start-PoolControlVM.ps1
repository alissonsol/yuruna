<#PSScriptInfo
.VERSION 2026.07.28
.GUID 42e5f6a7-b8c9-4d01-8234-5f6a7b8c9d0e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool control extension service
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Bring up the Pool control service on THIS host by building + launching it on
    its OWN VM, and publish its marker.
.DESCRIPTION
    Like Start-CachingProxyVM / Start-StashVM, the default path brings the
    service up on a dedicated VM (guest.pool-control): it runs the pool-storage
    pre-flight, then delegates to the per-host New-VM.ps1, whose cloud-init fetches
    the framework and runs the bring-up script that builds the Go daemon, installs
    pwsh + the pool-admin CLIs, CIFS-mounts the pool NAS for its state dir, and
    launches the daemon under systemd (UI + API on :80) INSIDE the guest -- no Go
    toolchain is needed on the host.

    Writes runtime/pool-control.json (the marker Test.Capability folds into
    host.registration.json so the service shows up in the Extension hosts table)
    and refreshes the registration record so the host appears within one
    aggregator poll. The Go service also self-announces to the aggregator via its
    beacon, so the Extension-hosts row appears by marker AND by beacon
    independently.
.PARAMETER VMName
    Name of the pool-control VM. Default: yuruna-pool-control.
.PARAMETER HostSideProof
    Build the Go binary from test/extension/pool-control/server and run it
    directly on THIS host (no VM), serving the UI/API on -Port. This needs a local
    Go toolchain and is a quick proof / fallback for when a VM is unavailable. Omit
    it to use the default VM path.
.PARAMETER Port
    UI/API port for -HostSideProof only (the VM serves on :80). Default 8090 (kept
    clear of the status server's 8080).
.PARAMETER AggregatorUrl
    Pool aggregator base URL for the beacon, -HostSideProof only (the VM reads its
    aggregator URL from config via the seed). Optional (empty disables the beacon;
    the marker path still works).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VMName = 'yuruna-pool-control',
    [switch]$HostSideProof,
    [int]$Port = 8090,
    [string]$AggregatorUrl = ''
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

$repoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir

# Initialize-YurunaEntryPoint returns only paths -- it imports no modules -- so
# pull in Test.YurunaDir explicitly for Initialize-YurunaRuntimeDir /
# Get-YurunaHostId. Initialize-YurunaRuntimeDir DEFAULTS + creates
# <testRoot>/status/runtime when $env:YURUNA_RUNTIME_DIR is unset, so the marker
# always has a home on a fresh shell instead of depending on an inherited env var.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }

if (-not $HostSideProof) {
    # --- REGION: default -- bring the service up on its OWN VM (guest.pool-control)
    # Mirrors Start-StashVM / Start-CachingProxyVM: pool-storage pre-flight, then
    # delegate to the per-host New-VM.ps1 whose cloud-init builds + launches the
    # daemon inside the guest. -HostSideProof (below) is the no-VM fallback.
    if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
        exit $ExitFailure
    }
    Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
    Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

    $HostType = Get-HostType
    if (-not $HostType) { exit $ExitFailure }
    Write-Information "Host type: $HostType" -InformationAction Continue
    [void](Initialize-YurunaHost -RepoRoot $repoRoot -HostType $HostType)

    # --- REGION: pool storage pre-flight
    # The pool-control daemon persists its audit log + status.json under the pool
    # NAS (poolNetworkPath/pool-control/). Refuse to bring up a VM that would have
    # nowhere durable to write: fail fast HERE, before the long VM build, when the
    # pool storage is unconfigured or its NAS credential is not stored.
    Import-Module (Join-Path $ModulesDir 'Test.Config.psm1')      -Global -Force
    Import-Module (Join-Path $ModulesDir 'Test.PoolStorage.psm1') -Global -Force
    Import-Module (Join-Path $ModulesDir 'Test.Extension.psm1')   -Global -Force
    $null = @(Import-Extension -Area 'authentication' -RequireSingle)
    $tcPath = Join-Path $repoRoot 'test/test.config.yml'
    $tc = $null
    if (Test-Path -LiteralPath $tcPath) {
        try { $tc = Read-TestConfig -Path $tcPath } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
    }
    $poolCfg = $null
    if ($tc) {
        try { $poolCfg = Get-YurunaPoolStorageConfig -Config $tc -IgnoreReplicate } catch { Write-Verbose "pool storage config: $($_.Exception.Message)" }
    }
    if (-not $poolCfg) {
        Write-Error @"
Start-PoolControlVM requires the pool storage to be configured:
set networkStorage.poolNetworkPath / poolNetworkUser / poolLocalPath in
test/test.config.yml and Set-Password the poolNetworkUser. See docs/test-config.md
and the Pool control service section of docs/pool-admin.md.
"@
        exit $ExitFailure
    }
    # Hard gate: a REAL password must already be stored for the pool SMB user.
    # A mapped-but-unstored vaultKey would make the seed bake an AUTO-GENERATED
    # junk password the NAS rejects (cifs mount error(13)); the SMB user
    # authenticates to a PRE-EXISTING NAS account, so require a stored entry.
    if (-not (Test-PoolStorageStoredCredential -Config $poolCfg)) {
        Write-Error @"
pool networkUser '$($poolCfg.NetworkUser)' has NO password stored in the vault.
The pool-control VM mounts the pool NAS with this account; without a stored credential
the VM seed bakes an auto-generated value the NAS rejects (cifs mount error(13)), so the
state dir never mounts. Store the real NAS password first, then re-run:
    Set-Password -Username '$($poolCfg.NetworkUser)' -NewPassword '<the real NAS password>'
See docs/test-config.md (networkStorage credentials).
"@
        exit $ExitFailure
    }
    # Soft gate: a credential IS stored -- verify it actually AUTHENTICATES to the
    # pool share. WARNING, not a hard stop: the daemon degrades to no persistence
    # when the share is offline, and the NAS may merely be transiently unreachable.
    if (Connect-YurunaPoolStorage -Config $poolCfg -Confirm:$false) {
        Write-Information "pool storage pre-flight OK (networkUser='$($poolCfg.NetworkUser)'; credential authenticates)." -InformationAction Continue
    } else {
        Write-Warning @"
pool networkUser '$($poolCfg.NetworkUser)' has a stored credential, but it did NOT
authenticate to the pool share '$($poolCfg.NetworkPath)' just now (wrong/stale password,
or the NAS is unreachable). Bringing the VM up anyway: the daemon will START but persist
NOTHING until this is fixed. If the password is stale, update it and rebuild:
    Set-Password -Username '$($poolCfg.NetworkUser)' -NewPassword '<the real NAS password>'
"@
    }

    # --- REGION: resolve the per-host New-VM
    $hostFolder = Get-HostFolder $HostType
    $guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.pool-control'
    $newVm      = Join-Path $guestDir 'New-VM.ps1'
    if (-not (Test-Path -LiteralPath $newVm)) {
        Write-Error "New-VM.ps1 not found for $HostType at $newVm"
        exit $ExitFailure
    }

    # --- REGION: host status service (serves the local repo to the guest) -- BEFORE the build
    # Mirrors Start-StashVM / Start-CachingProxyVM: the pool-control guest's cloud-init
    # fetches the framework from http://<host>:<port>/yuruna-archive.tar.gz at first boot,
    # and falls back to a public github clone when that server is down -- so it must be up
    # BEFORE New-VM bakes and boots the guest, not after (a server started later is one the
    # guest never saw). Best-effort; honors statusService.isEnabled + port.
    try {
        $statusScript = Join-Path $repoRoot 'test/Start-StatusService.ps1'
        if ($tc -and (Test-Path -LiteralPath $statusScript)) {
            [void](Start-YurunaStatusServiceIfEnabled -Config $tc -StartScript $statusScript)
        }
    } catch { Write-Verbose "status service ensure: $($_.Exception.Message)" }

    # --- REGION: delegate to the per-host New-VM (build + start the VM)
    # Each New-VM runs Get-Image auto-fetch when the base image is missing, tears down any
    # prior VM, creates the new one, and (Hyper-V + KVM) starts it. UTM only builds the
    # bundle -- register + start below.
    Write-Information "== Bringing up '$VMName' on $HostType ==" -InformationAction Continue
    & pwsh -NoProfile -File $newVm -VMName $VMName
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Error "$newVm exited $rc -- aborting."
        exit $rc
    }

    # --- REGION: UTM register + start (Hyper-V/KVM already started in New-VM)
    # Hyper-V and KVM already started the VM inside New-VM.ps1; only UTM needs
    # registration + start here.
    if ($HostType -eq 'host.macos.utm') {
        $UtmDir = "$HOME/yuruna/guest.nosync/$VMName.utm"
        if (-not (Test-Path $UtmDir)) {
            Write-Error "UTM bundle missing at $UtmDir after New-VM."
            exit $ExitFailure
        }
        & utmctl status $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Information "Registering bundle with UTM (open $UtmDir)..." -InformationAction Continue
            & /usr/bin/open $UtmDir
            $waitDeadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $waitDeadline) {
                & utmctl status $VMName 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { break }
                Start-Sleep -Seconds 2
            }
            & utmctl status $VMName 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Error "UTM did not register '$VMName' within 60s. Open UTM manually, accept the bundle, then re-run."
                exit $ExitFailure
            }
        }
        Write-Information "Starting '$VMName' via utmctl..." -InformationAction Continue
        & utmctl start $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "utmctl start '$VMName' returned non-zero -- check UTM."
        }
    }

    # --- REGION: post-boot readiness probe on :80 + on-failure guest diagnostics
    # New-VM confirmed the VM has an IP, but the daemon still has to build INSIDE
    # the guest (apt golang + pwsh, go build, systemd start), which takes several
    # minutes on first boot -- so an IP alone is NOT "the service is up". Probe :80
    # until it actually serves before declaring success. If it never comes up, pull
    # the in-guest build log + cloud-init status + service journal over the harness
    # SSH key so the operator sees WHY without SSHing in blind. pool-control-admin
    # has NOPASSWD sudo in the seed, so `sudo tail` reads
    # /var/log/cloud-init-output.log (root-only -- a plain `tail` as
    # pool-control-admin returns Permission denied).
    Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
    $vmIp = try { Get-VMIp -VMName $VMName } catch { Write-Verbose "Get-VMIp: $($_.Exception.Message)"; $null }

    # Generous default so a slow first build (golang + pwsh install + go build over
    # the caching proxy) is not mis-reported as a failure; exits early the moment
    # :80 accepts. YURUNA_POOL_CONTROL_READY_TIMEOUT overrides (e.g. a short value
    # for a quick re-check on a VM that is already up).
    $readyTimeoutSeconds = 900
    if ($env:YURUNA_POOL_CONTROL_READY_TIMEOUT) {
        $parsed = 0
        if ([int]::TryParse($env:YURUNA_POOL_CONTROL_READY_TIMEOUT, [ref]$parsed) -and $parsed -gt 0) { $readyTimeoutSeconds = $parsed }
    }
    $readyTimeoutMin = [int]($readyTimeoutSeconds / 60)

    $daemonReady = $false
    if ($vmIp) {
        Write-Information "VM '$VMName' is at $vmIp. Waiting up to $readyTimeoutMin min for the pool-control daemon to serve on :80 (first boot builds it in-guest)..." -InformationAction Continue
        $readyDeadline = (Get-Date).AddSeconds($readyTimeoutSeconds)
        $probeStart    = Get-Date
        $nextTick      = 30
        while ((Get-Date) -lt $readyDeadline) {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            try {
                $async = $tcp.BeginConnect($vmIp, 80, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(1000) -and $tcp.Connected) { $daemonReady = $true; break }
            } catch { Write-Verbose "pool-control :80 probe: $($_.Exception.Message)" }
            finally { $tcp.Close() }
            $elapsed = [int]((Get-Date) - $probeStart).TotalSeconds
            if ($elapsed -ge $nextTick) {
                # Floor, not [int]: the cast rounds half-to-even, so 90s printed
                # as "02m30s" and the tick sequence read as though it went
                # backwards (04m30s before 04m00s).
                Write-Information ("  [{0:D2}m{1:D2}s / {2}m] still waiting for the daemon on :80..." -f [int][math]::Floor($elapsed / 60), ($elapsed % 60), $readyTimeoutMin) -InformationAction Continue
                $nextTick += 30
            }
            Start-Sleep -Seconds 3
        }
    } else {
        Write-Warning "Could not resolve the VM's IP via the host contract (Get-VMIp). New-VM reported the VM booted, so this is unusual; skipping the :80 probe and going straight to guest diagnostics."
    }

    # Publish the marker + refresh registration (mirrors Start-StashVM's publish
    # step): write runtime/pool-control.json, then regenerate host.registration.json
    # so the aggregator lists this host under Extension hosts on its next poll --
    # not only after the next test cycle. poolControlBaseUrl gives the Extension
    # cell a deep-link even before the daemon's first beacon; an IPv6 literal is
    # bracketed for the URL authority. The registration refresh is best-effort
    # telemetry and must never fail the bring-up. Write-HostRegistrationRecord reads
    # $global:__YurunaHostId; Set-Variable -Scope Global keeps PSAvoidGlobalVars quiet.
    $poolControlBaseUrl = if (-not $vmIp) { '' } elseif ($vmIp -match ':') { "http://[$vmIp]/" } else { "http://$vmIp/" }
    $marker = [ordered]@{
        active       = $true
        vmName       = $VMName
        hostType     = $HostType
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    if ($poolControlBaseUrl) { $marker['poolControlBaseUrl'] = $poolControlBaseUrl }
    [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'pool-control.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    try {
        Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
        Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
        [void](Write-HostRegistrationRecord -HostType $HostType -RepoRoot $repoRoot)
    } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

    if ($daemonReady) {
        # The guest seeds its intent store on the pool NAS; point the proxy's
        # read-only /pool-intent.git route at that same store so runners pull
        # exactly what this UI writes. Runs HERE, on the host, because the host
        # holds the harness SSH key -- a guest carries only an authorized public
        # key, so doing it from the VM would mean baking a private key with
        # sudo-capable proxy access into a web-facing guest. Reported, never
        # fatal: a serving-path optimization must not fail a successful bring-up.
        try {
            Import-Module (Join-Path $ModulesDir 'Test.CachingProxy.psm1') -Global -Force
            $aliasSync = Sync-PoolIntentAliasOnProxy -Confirm:$false
            if ($aliasSync.Changed) {
                Write-Information "  Proxy: /pool-intent.git now serves the pool NAS store (runners pull what this UI writes)." -InformationAction Continue
            } elseif (-not $aliasSync.Ok) {
                Write-Warning "pool-intent alias not reconciled on the caching proxy: $($aliasSync.Message). Runners may still pull the proxy's older local store; the Pool control UI is unaffected."
            } else {
                Write-Verbose "pool-intent alias: $($aliasSync.Message)"
            }
        } catch { Write-Verbose "pool-intent alias sync: $($_.Exception.Message)" }

        Write-Information "" -InformationAction Continue
        Write-Information "== pool-control is READY (daemon serving on :80) ==" -InformationAction Continue
        Write-Information "  VM:   $VMName ($HostType)" -InformationAction Continue
        Write-Information "  UI:   $poolControlBaseUrl  (Assign / Pools / Test sets)" -InformationAction Continue
        Write-Information "  SSH:  ssh pool-control-admin@$vmIp  (harness key authorized)" -InformationAction Continue
        Write-Information "  Stop: test/Stop-PoolControlVM.ps1" -InformationAction Continue
        exit $ExitOk
    }

    # Not serving. Collect the in-guest build log + service state over the harness
    # key (pool-control-admin, NOPASSWD sudo) so the operator sees the actual failure
    # instead of a dead URL. -User pins the account the cloud-init seed created:
    # it is the only login this VM has, and Get-GuestSshUser would otherwise return
    # a per-cycle cascade override that an earlier run in this same shell session
    # left registered for guest.pool-control.
    Write-Warning "pool-control daemon is NOT serving on :80 (VM $vmIp) after $readyTimeoutMin min. Collecting in-guest diagnostics over the harness SSH key..."
    $diagCmd = @(
        'echo "=== cloud-init status ==="; cloud-init status --long 2>&1 | head -n 20',
        'echo "=== systemctl status pool-control.service ==="; systemctl --no-pager --full status pool-control.service 2>&1 | head -n 25',
        'echo "=== journalctl -u pool-control.service (last 40) ==="; sudo journalctl -u pool-control.service --no-pager -n 40 2>&1',
        'echo "=== listening on :80? ==="; ss -ltn 2>/dev/null | grep -E ":80\b" || echo "(nothing listening on :80)"',
        'echo "=== /var/log/cloud-init-output.log (tail 120) ==="; sudo tail -n 120 /var/log/cloud-init-output.log 2>&1'
    ) -join "`n"
    $diag = $null
    if ($vmIp -and (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
        try { $diag = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.pool-control' -User 'pool-control-admin' -Command $diagCmd -TimeoutSeconds 120 }
        catch { Write-Verbose "guest diagnostics ssh: $($_.Exception.Message)" }
    }
    Write-Information "" -InformationAction Continue
    Write-Information "================= pool-control guest diagnostics =================" -InformationAction Continue
    if ($diag -and -not [string]::IsNullOrWhiteSpace([string]$diag.output)) {
        foreach ($line in ([string]$diag.output -split "`r?`n")) { Write-Information "  $line" -InformationAction Continue }
        if (-not $diag.success) {
            Write-Information "  (ssh ended with exit=$($diag.exitCode); the capture above is what completed before it did)" -InformationAction Continue
        }
    } else {
        Write-Information "  Could not reach the VM over SSH (sshd may still be starting, or networking is broken)." -InformationAction Continue
        if ($vmIp) { Write-Information "  Try manually:  ssh pool-control-admin@$vmIp 'sudo tail -n 120 /var/log/cloud-init-output.log'" -InformationAction Continue }
    }
    Write-Information "==================================================================" -InformationAction Continue
    Write-Information "" -InformationAction Continue
    Write-Information "The pool-control daemon did not come up on :80. Reading the capture above:" -InformationAction Continue
    Write-Information "  * cloud-init status 'running'  -> the in-guest build (go/pwsh) is still going; wait, then" -InformationAction Continue
    Write-Information "                                    re-run to re-check (or raise YURUNA_POOL_CONTROL_READY_TIMEOUT)." -InformationAction Continue
    Write-Information "  * a 'go build' / apt error     -> a package or source problem; the log tail shows the line." -InformationAction Continue
    Write-Information "  * 'NAS mount failed'           -> pool NAS unreachable; re-check the pool storage credential." -InformationAction Continue
    if ($vmIp) { Write-Information "Re-check any time:  ssh pool-control-admin@$vmIp 'systemctl status pool-control.service'" -InformationAction Continue }
    Write-Information "See https://yuruna.link/pool-control." -InformationAction Continue
    exit $ExitFailure
}

# --- REGION: -HostSideProof -- build + run the daemon directly on THIS host (no VM)
# A quick proof / fallback that needs a local Go toolchain; the VM path above is
# the default.
$serverDir = Join-Path $repoRoot 'test/extension/pool-control/server'
$go = (Get-Command go -ErrorAction SilentlyContinue)?.Source
if (-not $go) { Write-Error 'go toolchain not found on PATH; cannot build the pool-control service. Omit -HostSideProof to bring the service up on its own VM, which builds the daemon inside the guest (no host Go toolchain needed).'; exit $ExitFailure }
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshExe) { $pwshExe = 'pwsh' }

$binName = if ($IsWindows) { 'pool-control.exe' } else { 'pool-control' }
$binPath = Join-Path $serverDir $binName
if ($PSCmdlet.ShouldProcess($binPath, 'go build pool-control')) {
    Push-Location $serverDir
    try {
        & $go build -o $binName . 2>&1 | ForEach-Object { Write-Verbose $_ }
        if ($LASTEXITCODE -ne 0) { Write-Error "go build failed (exit $LASTEXITCODE)."; exit $ExitFailure }
    } finally { Pop-Location }
}

# The intent URL + host id come from config / the runtime identity.
$intentGitUrl = ''
try {
    if ($env:YURUNA_CONFIG_PATH -and (Test-Path -LiteralPath $env:YURUNA_CONFIG_PATH) -and (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        $cfg = Get-Content -Raw -LiteralPath $env:YURUNA_CONFIG_PATH | ConvertFrom-Yaml -Ordered
        if ($cfg -and $cfg['pool'] -and $cfg['pool']['intentGitUrl']) { $intentGitUrl = [string]$cfg['pool']['intentGitUrl'] }
    }
} catch { Write-Verbose "intentGitUrl lookup: $($_.Exception.Message)" }
# Get-Variable -Scope Global reads the cross-host identity channel without a
# $global: reference (keeps PSAvoidGlobalVars quiet); absent -> $null.
$hostId = [string](Get-Variable -Name '__YurunaHostId' -Scope Global -ValueOnly -ErrorAction SilentlyContinue)

$goArgs = @('--http-addr', "0.0.0.0:$Port", '--repo-dir', $repoRoot, '--pwsh', $pwshExe)
if ($intentGitUrl)  { $goArgs += @('--intent-git-url', $intentGitUrl) }
if ($AggregatorUrl) { $goArgs += @('--aggregator-url', $AggregatorUrl) }
if ($hostId)        { $goArgs += @('--host-id', $hostId) }

if ($PSCmdlet.ShouldProcess($binPath, "launch pool-control on :$Port")) {
    $proc = Start-Process -FilePath $binPath -ArgumentList $goArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 1
    $localIp = try { (Test-Connection -TargetName ([System.Net.Dns]::GetHostName()) -Count 1 -ErrorAction SilentlyContinue).Address.IPAddressToString } catch { $null }
    if ([string]::IsNullOrWhiteSpace($localIp)) { $localIp = '127.0.0.1' }
    $marker = [ordered]@{
        active            = $true
        pid               = $proc.Id
        port              = $Port
        poolControlBaseUrl = "http://${localIp}:$Port/"
        startedAtUtc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'pool-control.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
        try { Write-HostRegistrationRecord -HostType (Get-HostType) | Out-Null } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }
    }
    Write-Information "Pool control running (pid $($proc.Id)) at http://${localIp}:$Port/  (UI: /, /pools, /test-sets)." -InformationAction Continue
}
exit $ExitOk

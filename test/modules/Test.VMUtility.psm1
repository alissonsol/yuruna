<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e92
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cross-host
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Cross-host test helpers. Functions land here when they are used by
    tests but are NOT host-specific (i.e. wouldn't fit in any single
    host/<x>/modules/Yuruna.Host.psm1).
#>

#requires -version 7

<#
.SYNOPSIS
    Cross-host test helpers shared across all hosts.

.DESCRIPTION
    Sibling to host/<host-tag>/modules/Yuruna.Host.psm1. Where a host
    driver implements the host-specific contract, this module collects
    helpers that are part of test orchestration but are themselves
    platform-agnostic -- e.g. SSH key-pair management (uses ssh-keygen
    the same way on every host), git-pull plumbing, pure parsing, etc.

    Cross-host helpers that satisfy the placement rule above land here.
#>

# Test.YurunaDir.psm1 owns $env:YURUNA_RUNTIME_DIR + Initialize-YurunaRuntimeDir;
# import here so Get-PortMapStatePath can resolve the state file even when
# a caller hasn't bootstrapped the full runner path. -Global so a caller
# that already imported Test.YurunaDir into its own session keeps seeing
# Initialize-YurunaRuntimeDir afterwards -- a -Force re-import without
# -Global evicts the caller's binding into Test.VMUtility's private scope,
# which is exactly what broke Start-StatusService.ps1 at "Initialize-
# YurunaRuntimeDir is not recognized".
Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -Force -Global

# The 10 cross-host pure helpers (IP validation, proxy/port parsing, crypt hash,
# state-file paths, admin check) now live in automation/Yuruna.Common.psm1 as the
# single definition. Re-import it -Global here so those movers stay visible to
# Test.VMUtility's own callers AND to Get-CachingProxyExposedPort below, which
# calls the now-moved Get-CachingProxyPort. -Global mirrors the Test.YurunaDir
# import above so a re-import does not evict the caller's binding into a private scope.
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1') -Global -Force

function Wait-VMRunning {
<#
.SYNOPSIS
    Polls Get-VMState until the VM is running, then optionally waits a
    boot delay. Host-agnostic; relies entirely on the host driver's
    Get-VMState contract.
.DESCRIPTION
    The polling is identical on every host -- only the underlying
    state probe differs, and that difference lives behind Get-VMState
    in host/<host-tag>/modules/Yuruna.Host.psm1.
.PARAMETER VMName
    Guest VM name as registered with the host hypervisor.
.PARAMETER TimeoutSeconds
    Total time budget. Default 120; the runner overrides this from
    test.config.yml's vmStart.startTimeoutSeconds.
.PARAMETER PollSeconds
    Interval between Get-VMState calls. Default 5 -- enough granularity
    for the VM-start window without burning CPU.
.PARAMETER BootDelaySeconds
    Additional sleep AFTER the VM reaches 'running'. Used to let
    cloud-init / first-boot scripts settle before the runner starts
    sending OCR-driven keystrokes. Default 0 (no delay).
.OUTPUTS
    [bool] -- $true on running before timeout, $false on timeout.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds   = 120,
        [int]$PollSeconds      = 5,
        [int]$BootDelaySeconds = 0
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        # A transient Get-VMState throw (e.g. WMI/virsh hiccup during boot) must not abort the
        # wait under ErrorActionPreference=Stop; treat it as "not running yet" and keep polling
        # until the deadline.
        $state = $null
        try { $state = Get-VMState -VMName $VMName } catch { Write-Verbose "Wait-VMRunning: Get-VMState threw: $($_.Exception.Message)" }
        if ($state -eq 'running') {
            Write-Verbose "Verified: VM '$VMName' is running"
            if ($BootDelaySeconds -gt 0) {
                Write-Verbose "VM is running. Waiting ${BootDelaySeconds}s for guest OS to initialize..."
                Start-Sleep -Seconds $BootDelaySeconds
            }
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Warning "VM '$VMName' did not reach running state within ${TimeoutSeconds}s"
    return $false
}

function Compare-Screenshot {
<#
.SYNOPSIS
    Compares two PNG images and returns a similarity score (0.0 to 1.0).
.DESCRIPTION
    Pixel-level comparison via System.Drawing. Returns 1.0 for identical
    images. Host-agnostic -- callers on either host pass paths to PNGs
    captured via the contract's Get-VMScreenshot.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ReferencePath,
        [string]$ActualPath,
        [double]$Threshold = 0.85
    )
    if (-not (Test-Path $ReferencePath)) {
        Write-Error "Reference screenshot not found: $ReferencePath"
        return @{ match=$false; similarity=0.0; error="Reference not found" }
    }
    if (-not (Test-Path $ActualPath)) {
        Write-Error "Actual screenshot not found: $ActualPath"
        return @{ match=$false; similarity=0.0; error="Actual not found" }
    }
    $ref = $null
    $act = $null
    try {
        Add-Type -AssemblyName System.Drawing
        try {
            $ref = [System.Drawing.Bitmap]::new($ReferencePath)
            $act = [System.Drawing.Bitmap]::new($ActualPath)
            if ($ref.Width -ne $act.Width -or $ref.Height -ne $act.Height) {
                $resized = [System.Drawing.Bitmap]::new($act, $ref.Width, $ref.Height)
                $act.Dispose()
                $act = $resized
            }

            # LockBits + Marshal.Copy into managed byte[]. Each Bitmap.GetPixel
            # is a P/Invoke through GDI+ (microseconds per call); a 1024x768 at
            # step=4 needs ~49k pairs of calls and ran 1-3 s. Reading the whole
            # pixel buffer once and indexing into a byte[] is 10-50x faster.
            # Format32bppArgb byte order is B, G, R, A; stride is row-aligned.
            $rect = [System.Drawing.Rectangle]::new(0, 0, $ref.Width, $ref.Height)
            $pf   = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
            $lock = [System.Drawing.Imaging.ImageLockMode]::ReadOnly
            $refData = $ref.LockBits($rect, $lock, $pf)
            $actData = $act.LockBits($rect, $lock, $pf)
            try {
                $stride    = $refData.Stride
                $byteCount = $stride * $ref.Height
                $refBytes  = [byte[]]::new($byteCount)
                $actBytes  = [byte[]]::new($byteCount)
                [System.Runtime.InteropServices.Marshal]::Copy($refData.Scan0, $refBytes, 0, $byteCount)
                [System.Runtime.InteropServices.Marshal]::Copy($actData.Scan0, $actBytes, 0, $byteCount)
            } finally {
                $ref.UnlockBits($refData)
                $act.UnlockBits($actData)
            }

            $matchingPixels = 0
            $step = 4
            $sampled = 0
            for ($y = 0; $y -lt $ref.Height; $y += $step) {
                $rowStart = $y * $stride
                for ($x = 0; $x -lt $ref.Width; $x += $step) {
                    $sampled++
                    $i = $rowStart + ($x * 4)
                    $diff = [Math]::Abs([int]$refBytes[$i]     - [int]$actBytes[$i]) +
                            [Math]::Abs([int]$refBytes[$i + 1] - [int]$actBytes[$i + 1]) +
                            [Math]::Abs([int]$refBytes[$i + 2] - [int]$actBytes[$i + 2])
                    if ($diff -lt 30) { $matchingPixels++ }
                }
            }
            $similarity = $sampled -gt 0 ? [Math]::Round($matchingPixels / $sampled, 4) : 0.0
            $isMatch = $similarity -ge $Threshold
            Write-Information "Screenshot comparison: similarity=$similarity threshold=$Threshold match=$isMatch"
            return @{ match=$isMatch; similarity=$similarity; error=$null }
        } finally {
            # Dispose both source bitmaps on EVERY path: a LockBits / Marshal.Copy
            # throw would otherwise bypass the release and leak native GDI+ handles
            # across the per-cycle screenshot compares. Null-guarded because a
            # failed Bitmap::new leaves its variable $null; $act may already hold
            # the resized copy (the original is disposed at swap time).
            if ($ref) { $ref.Dispose() }
            if ($act) { $act.Dispose() }
        }
    } catch {
        Write-Error "Screenshot comparison failed: $_"
        return @{ match=$false; similarity=0.0; error="$_" }
    }
}

function Get-ScreenshotSchedule {
<#
.SYNOPSIS
    Reads the screenshot schedule JSON for a guest. Host-agnostic.
#>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([string]$GuestKey, [string]$ScreenshotsDir)
    $scheduleFile = Join-Path $ScreenshotsDir "$GuestKey/schedule.json"
    if (-not (Test-Path $scheduleFile)) { return @() }
    try {
        $schedule = Get-Content -Raw $scheduleFile | ConvertFrom-Json
        return @($schedule.checkpoints)
    } catch {
        Write-Warning "Failed to read screenshot schedule: $scheduleFile -- $_"
        return @()
    }
}

function Invoke-ScreenshotTest {
<#
.SYNOPSIS
    Executes all screenshot checkpoints for a running VM via the contract.
.DESCRIPTION
    Host-agnostic test orchestrator: relies on the host driver's
    Get-VMScreenshot (Yuruna.Host) for capture and on Compare-Screenshot
    here for the pixel comparison.

    Reference PNGs live under $ScreenshotsDir/<guestKey>/reference/
    in the source tree (one PNG per checkpoint named in schedule.json,
    captured manually and committed by the operator). Runtime captures
    (compared against the references each cycle) land under
    test/status/captures/training/<guestKey>/ -- gitignored, wiped when
    cleaning the host.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$GuestKey,
        [string]$VMName,
        [string]$ScreenshotsDir
    )
    $schedule = Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir
    if ($schedule.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    $guestDir = Join-Path $ScreenshotsDir $GuestKey
    # Module file lives at test/modules/Test.VMUtility.psm1; one Split-Path
    # -Parent reaches test/. Runtime captures separate from reference PNGs
    # so cleaning status/ never wipes operator training output. Files are
    # written with the guest key prefixed onto the filename (one flat
    # captures/training/ folder; no per-guest subdir, to honor the
    # "max two subfolder levels under status/" rule).
    $testRoot   = Split-Path -Parent $PSScriptRoot
    $captureDir = Join-Path -Path $testRoot -ChildPath 'status' `
                       -AdditionalChildPath 'captures', 'training'
    if (-not (Test-Path $captureDir)) { New-Item -ItemType Directory -Force -Path $captureDir | Out-Null }
    foreach ($cp in $schedule) {
        $cpName    = $cp.name
        $delay     = [int]$cp.delaySeconds
        $threshold = $cp.threshold ? [double]$cp.threshold : 0.85
        $refFile   = Join-Path $guestDir "reference/$cpName.png"
        if (-not (Test-Path $refFile)) {
            return @{ success=$false; skipped=$false; errorMessage="Reference screenshot missing: $refFile. Commit a PNG at that path (one per checkpoint in schedule.json) or remove the checkpoint." }
        }
        Write-Information "  Screenshot checkpoint '$cpName': waiting ${delay}s..."
        Start-Sleep -Seconds $delay
        $capFile = Join-Path $captureDir "${GuestKey}__${cpName}.png"
        $captured = Get-VMScreenshot -VMName $VMName -OutFile $capFile
        if (-not $captured) {
            return @{ success=$false; skipped=$false; errorMessage="Failed to capture screenshot for checkpoint '$cpName'" }
        }
        $result = Compare-Screenshot -ReferencePath $refFile -ActualPath $capFile -Threshold $threshold
        if (-not $result.match) {
            $msg = "Screenshot '$cpName' mismatch: similarity=$($result.similarity) threshold=$threshold"
            if ($result.error) { $msg += " error=$($result.error)" }
            return @{ success=$false; skipped=$false; errorMessage=$msg }
        }
        Write-Information "  Screenshot checkpoint '$cpName': PASS (similarity=$($result.similarity))"
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

function Get-CachingProxyExposedPort {
<#
.SYNOPSIS
    The TCP ports the caching proxy exposes to the LAN, resolved in one place so
    the parent status-service port-map setup, the inner cycle-start gate, and
    Start-CachingProxy's install list cannot drift apart on the shared set.
.DESCRIPTION
    Returns the fixed service ports -- 80 (Apache CA cert), 3000 (Grafana),
    9302 (caching-proxy-parser live tail) -- plus the client-facing squid
    HTTP/HTTPS ports (each defaulting to Get-CachingProxyPort). Add-PortMap is
    clear-all-first on Windows, so any port dropped from this set goes dark on
    the next map; owning the set here keeps the callers in lockstep. A caller
    that re-maps a reduced set on a platform (e.g. macOS, where only Grafana is
    re-mapped) keeps that branch and does not call this.
.OUTPUTS
    [int[]]
#>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [int]$HttpPort  = (Get-CachingProxyPort -Scheme http),
        [int]$HttpsPort = (Get-CachingProxyPort -Scheme https)
    )
    [int[]]@(80, 3000, 9302, $HttpPort, $HttpsPort)
}

function Remove-GuestVMQuietly {
    <#
    .SYNOPSIS
        Tear down a guest VM with the Hyper-V progress bar suppressed.
    .DESCRIPTION
        Wraps the ProgressPreference save/restore around the Yuruna.Host
        contract Stop-VM + Remove-VM so the ~dozen teardown sites in the inner
        runner share one implementation -- one place to evolve VM teardown, the
        path that matters most when a cycle is failing. Stop-VM / Remove-VM are
        the -Global contract exports (resolved at call time after
        Initialize-YurunaHost); this helper never re-imports the host driver.
    .PARAMETER SkipStop
        Remove without stopping first (the pre-spawn cleanup of a leftover VM).
    .PARAMETER BestEffort
        Add -ErrorAction SilentlyContinue (emergency / catch-all teardown paths
        that must never throw on an already-gone VM).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Thin wrapper over the host contract Stop-VM/Remove-VM, which own the -Confirm:$false teardown semantics.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$SkipStop,
        [switch]$BestEffort
    )
    $savedProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        if ($BestEffort) {
            if (-not $SkipStop) { Stop-VM -VMName $VMName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
            Remove-VM -VMName $VMName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } else {
            if (-not $SkipStop) { Stop-VM -VMName $VMName -Confirm:$false | Out-Null }
            Remove-VM -VMName $VMName -Confirm:$false | Out-Null
            # Don't silently trust the teardown. On a real removal path (not the
            # pre-spawn same-name sweep, which runs against an absent VM), a VM
            # still 'running' here means the next guest could start concurrently.
            # Surface it -- the caller's next-guest step and the cycle-start
            # concurrency guard are the backstops. Get-VMState is the probe, not
            # Remove-VM's return, whose [bool] cast is corrupted by the host
            # driver's status Write-Output lines.
            if (-not $SkipStop -and (Get-VMState -VMName $VMName) -eq 'running') {
                Write-Warning "Remove-GuestVMQuietly: '$VMName' is still running after teardown (possible serialization hazard)."
            }
        }
    } finally {
        $global:ProgressPreference = $savedProgress
    }
}

function Update-StashServerMarkerAddress {
    <#
    .SYNOPSIS
        Resolve the stash VM's current IPv4 and record it as `stashBaseUrl`
        (http://<ip>) in the stash-server.json marker, so the pool-aggregator
        can deep-link the Extension hosts cell to the stash VM's UI.
    .DESCRIPTION
        Best-effort and never throws -- telemetry must not fail a bring-up or a
        cycle. The stash VM's guest address is not known until the host's
        virtualization stack reports it (KVP / dhcpd_leases / utmctl), which can
        lag minutes after boot on a Hyper-V External vSwitch, so callers poll:
        pass a -TimeoutSeconds budget when the VM may have just started
        (Start-StashServer), or 0 for a single-shot refresh on an established VM
        (the per-cycle runner call). Resolution goes through the host contract
        Get-VMIp resolved at call time after Initialize-YurunaHost (the same
        late-bind the teardown helpers use); a host without it loaded is a no-op.
        The marker is rewritten only when the URL changes, atomic temp+rename so a
        polling aggregator never reads a torn file. Format-IpUrlHost brackets an
        IPv6 literal for the URL authority.
    .OUTPUTS
        System.String -- the resolved stash base URL, or $null when unresolved.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort single-file marker refresh; never throws, overwrite is idempotent.')]
    [OutputType([string])]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [string]$VMName,
        [int]$TimeoutSeconds = 0
    )
    try {
        if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
        $markerPath = Join-Path $RuntimeDir 'stash-server.json'
        if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
        $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json -ErrorAction Stop
        # A marker being torn down (active:false) must not be re-advertised.
        if ($null -ne $marker.active -and -not [bool]$marker.active) { return $null }
        if (-not $VMName) { $VMName = [string]$marker.vmName }
        if ([string]::IsNullOrWhiteSpace($VMName)) { return $null }
        if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) { return $null }

        $ip = $null
        $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
        while (-not $ip) {
            $candidate = $null
            try { $candidate = [string](Get-VMIp -VMName $VMName) }
            catch { Write-Verbose "Update-StashServerMarkerAddress: Get-VMIp '$VMName' failed: $($_.Exception.Message)" }
            if ($candidate -and (Test-IpAddress $candidate)) { $ip = $candidate }
            elseif ((Get-Date) -ge $deadline) { break }
            else { Start-Sleep -Seconds 3 }
        }
        if (-not $ip) { return $null }

        $url = "http://$(Format-IpUrlHost $ip)"
        if ([string]$marker.stashBaseUrl -eq $url) { return $url }

        # Preserve every existing marker field; set/replace stashBaseUrl only.
        $record = [ordered]@{}
        foreach ($prop in $marker.PSObject.Properties) { $record[$prop.Name] = $prop.Value }
        $record['stashBaseUrl'] = $url
        $tmp = "$markerPath.tmp"
        [System.IO.File]::WriteAllText($tmp, ($record | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $markerPath -Force -ErrorAction Stop
        return $url
    } catch {
        Write-Verbose "Update-StashServerMarkerAddress: $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function Wait-VMRunning, Get-ScreenshotSchedule, Invoke-ScreenshotTest, Compare-Screenshot, Get-CachingProxyExposedPort, Remove-GuestVMQuietly, Update-StashServerMarkerAddress

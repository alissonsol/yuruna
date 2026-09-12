<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42cfa437-bd81-47fb-8d48-e2ca1335fa07
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

# The cross-host pure helpers (IP validation, proxy/port parsing, crypt hash,
# state-file paths, admin check) are defined once in automation/Yuruna.Common.psm1.
# Import it -Global so they stay visible to Test.VMUtility's own callers AND to
# Get-CachingProxyServiceExposedPort below, which calls Get-CachingProxyServicePort. -Global
# mirrors the Test.YurunaDir import above so a re-import does not evict the
# caller's binding into a private scope.
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

function Get-CachingProxyServiceExposedPort {
<#
.SYNOPSIS
    The TCP ports the caching-proxy service exposes to the LAN, resolved in one place so
    the parent status-service port-map setup, the inner cycle-start gate, and
    Start-CachingProxyServiceVM's install list cannot drift apart on the shared set.
.DESCRIPTION
    Returns the fixed service ports -- 80 (Apache CA cert), 3000 (Grafana),
    9302 (caching-proxy-parser-service live tail), 9400 (pool-aggregator-service: /metrics,
    /api/v1/pool-status, the /go/* dashboard redirects, and the bearer-gated
    /ingest) -- plus the client-facing squid HTTP/HTTPS ports (each defaulting
    to Get-CachingProxyServicePort). Add-PortMap is clear-all-first on Windows, so any
    port dropped from this set goes dark on the next map; owning the set here
    keeps the callers in lockstep. A caller that re-maps a reduced set on a
    platform (e.g. macOS, where only Grafana is re-mapped) keeps that branch and
    does not call this.

    NOTE: forwarding 9400 makes the aggregator's LAN surface reachable on the
    NAT-fallback path, but it does NOT make the pool dashboard populate there --
    the userspace forwarder (systemd-socket-proxyd) re-originates every
    connection from the host, so squid sees one client (the NAT gateway) for the
    whole LAN and the aggregator, which discovers hosts by their real client IP,
    finds none. The pool view needs a bridged cache VM (real client IPs); see
    host/ubuntu.kvm/guest.caching-proxy-service/README.md.
.OUTPUTS
    [int[]]
#>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [int]$HttpPort  = (Get-CachingProxyServicePort -Scheme http),
        [int]$HttpsPort = (Get-CachingProxyServicePort -Scheme https)
    )
    [int[]]@(80, 3000, 9302, 9400, $HttpPort, $HttpsPort)
}

function Invoke-GuestDhcpRelease {
    <#
    .SYNOPSIS
        Best-effort: ask a guest to hand its DHCP lease back before it is killed.
    .DESCRIPTION
        Teardown is a hard power-off -- a guest that has wedged must never be able
        to stall the cycle sweep -- so no guest ever sends a DHCPRELEASE of its own.
        Its address therefore stays allocated on the server until the lease expires,
        long after the VM is gone.

        With MACs derived from (host, VM name) this is no longer a leak: the next
        build of that same slot presents the same MAC and is handed the same address
        back. What releasing still buys is TIME -- the address returns to the pool
        now rather than at lease expiry, which matters on a lab whose DHCP server an
        operator cannot reconfigure to a shorter lease.

        Strictly best-effort and tightly bounded. It runs before the kill, so every
        second here is paid by every cycle: one short SSH attempt, no address wait,
        no retry, every failure swallowed. A guest that is already unreachable --
        the common case for the failure paths that call this -- costs the connect
        timeout and nothing more.

        The release itself is NOT reimplemented here. The guest already carries a
        tested one -- network_release() in yuruna-network.sh, deployed to
        /usr/local/lib/yuruna/ at install time and also reachable as the
        `networkRelease` sequence action -- which knows the systemd-networkd,
        dhclient and dhcpcd paths and skips virtual interfaces. Calling it by path
        keeps one implementation of "how a guest gives a lease back", so a stack
        added there is picked up here for free.

.OUTPUTS
        [bool] $true when the release command was delivered.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$GuestKey,
        [int]$TimeoutSeconds = 8
    )
    $script:DhcpReleaseAttempted++
    if (-not (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) { return $false }
    # `|| true` throughout, and the guest is destroyed on the next line, so a guest
    # whose lib is missing or whose release path fails is never left stranded.
    $cmd = 'bash /usr/local/lib/yuruna/yuruna-network.sh release 2>/dev/null || true; exit 0'
    try {
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $cmd `
                -TimeoutSeconds $TimeoutSeconds -AddressWaitSeconds 0 -ErrorAction SilentlyContinue
        $ok = ($null -ne $r -and $r.exitCode -eq 0)
        if ($ok) { $script:DhcpReleaseSucceeded++; Write-Verbose "DHCP release requested on '$VMName' before teardown." }
        else     { Write-Verbose "DHCP release on '$VMName' did not complete; the deterministic MAC reclaims the lease on the next build." }
        return $ok
    } catch {
        Write-Verbose "DHCP release on '$VMName' failed: $($_.Exception.Message)"
        return $false
    }
}

# Every outcome above is swallowed at Verbose, which is the right volume for one
# guest and the wrong one for the whole cycle: "released none of nine" and
# "released nine of nine" print identically, and the first is how a teardown
# path that lost its guest key went unnoticed while the lease pool drained. The
# tally is the cycle-level statement those per-guest lines cannot make.
$script:DhcpReleaseAttempted = 0
$script:DhcpReleaseSucceeded = 0

function Get-GuestDhcpReleaseTally {
<#
.SYNOPSIS
    How many pre-teardown DHCP releases were asked for this cycle, and how many
    landed.
.OUTPUTS
    [hashtable] attempted, succeeded.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{ attempted = $script:DhcpReleaseAttempted; succeeded = $script:DhcpReleaseSucceeded }
}

function Reset-GuestDhcpReleaseTally {
<#
.SYNOPSIS
    Zero the tally at a cycle boundary so each cycle reports its own number.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    if (-not $PSCmdlet.ShouldProcess('DHCP release tally', 'Reset')) { return }
    $script:DhcpReleaseAttempted = 0
    $script:DhcpReleaseSucceeded = 0
}

# --- REGION: https://yuruna.link/4220a755-000b
# Releasing a lease is an optimization and can always miss; the BOUND is what
# decides whether a long lease is survivable. The bound says a guest asks for a
# new address only when its identity is new -- so the way to test it is to
# rebuild the same identity and see whether the same address comes back.
#
# Observed, not configured, deliberately. A pin that is present and a pin the
# server honors look identical from the guest's own files, and only one of them
# bounds anything. This measures the outcome, which is the half that cannot be
# faked by a correct-looking setting.
$script:GuestAddressChecked   = 0
$script:GuestAddressUnbounded = 0
$script:GuestAddressMoves     = [System.Collections.Generic.List[object]]::new()

function Get-GuestAddressLedgerPath {
<#
.SYNOPSIS
    Where this host records the address each guest identity last held.
.PARAMETER RuntimeDir
    The runtime directory the runner already keeps its per-host state in.
.OUTPUTS
    [string]
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    return (Join-Path $RuntimeDir 'guestaddress.ledger.json')
}

function Register-GuestAddressObservation {
<#
.SYNOPSIS
    Record the address a guest identity holds now, and say whether that identity
    has moved since it was last seen.
.DESCRIPTION
    Keyed on the identity the guest keeps for its whole life -- the same key its
    deterministic MAC is derived from -- NOT on the VM name of the moment. A
    guest is built in a per-kind slot and promoted out of it, so keying on the
    transient name would report a rename as a renumbering and cry wolf on every
    promotion.

    A first sighting is never a move: an identity with no prior address is being
    recorded, not judged. That is the difference between a lab that has just
    added a guest and one that is leaking addresses, and only the second is
    worth stopping for.
.PARAMETER RuntimeDir
    The runtime directory holding the ledger.
.PARAMETER Identity
    The guest's lifelong identity key.
.PARAMETER Address
    The IPv4 address it holds now.
.OUTPUTS
    [hashtable] bounded, firstSighting, previous, current.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Address
    )
    $result = @{ bounded = $true; firstSighting = $true; previous = ''; current = $Address }
    $path = Get-GuestAddressLedgerPath -RuntimeDir $RuntimeDir
    if (-not $PSCmdlet.ShouldProcess($path, "Record $Identity at $Address")) { return $result }

    $ledger = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $raw = [string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                # A ledger that cannot be read is treated as empty rather than
                # fatal. Losing the history costs one cycle of detection; failing
                # here would cost the teardown it runs inside.
                ($raw | ConvertFrom-Json -ErrorAction Stop).PSObject.Properties |
                    ForEach-Object { $ledger[$_.Name] = [string]$_.Value }
            }
        } catch {
            Write-Verbose "guest address ledger: unreadable, starting fresh -- $($_.Exception.Message)"
        }
    }

    if ($ledger.ContainsKey($Identity) -and $ledger[$Identity]) {
        $result.firstSighting = $false
        $result.previous = [string]$ledger[$Identity]
        $result.bounded  = ($result.previous -eq $Address)
    }
    $ledger[$Identity] = $Address
    try {
        ($ledger | ConvertTo-Json -Depth 3) |
            Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Verbose "guest address ledger: could not write '$path' -- $($_.Exception.Message)"
    }
    return $result
}

function Assert-GuestAddressBounded {
<#
.SYNOPSIS
    Check that a guest came back on the address its identity already owns, and
    record the answer for the cycle.
.DESCRIPTION
    Runs where the guest is still alive and still addressable -- before the
    teardown kill -- because that is the last moment the question can be asked
    at all.

    A guest whose address cannot be resolved is counted as UNCHECKED, never as
    passing. Coverage and compliance are different facts: an unreachable guest
    is the ordinary case on a failure path, and letting it report as bounded
    would make a cycle where nothing could be checked look exactly like a cycle
    where everything was.
.PARAMETER VMName
    The VM to resolve an address for.
.PARAMETER Identity
    The guest's lifelong identity key; defaults to the VM name for guests that
    carry one name for life.
.PARAMETER RuntimeDir
    The runtime directory holding the ledger.
.OUTPUTS
    [hashtable] checked, bounded, previous, current, identity.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter()][AllowEmptyString()][string]$Identity = '',
        [Parameter(Mandatory)][string]$RuntimeDir
    )
    $key = if ([string]::IsNullOrWhiteSpace($Identity)) { $VMName } else { $Identity }
    $outcome = @{ checked = $false; bounded = $true; previous = ''; current = ''; identity = $key }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Check guest address is bounded by identity')) { return $outcome }
    if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) { return $outcome }

    $address = ''
    try { $address = [string](Get-VMIp -VMName $VMName -ErrorAction SilentlyContinue) }
    catch { Write-Verbose "guest address check: '$VMName' has no resolvable address -- $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace($address)) { return $outcome }

    $obs = Register-GuestAddressObservation -RuntimeDir $RuntimeDir -Identity $key -Address $address -Confirm:$false
    $outcome.checked  = $true
    $outcome.bounded  = [bool]$obs.bounded
    $outcome.previous = [string]$obs.previous
    $outcome.current  = [string]$obs.current
    $script:GuestAddressChecked++
    if (-not $obs.bounded) {
        $script:GuestAddressUnbounded++
        $script:GuestAddressMoves.Add([pscustomobject]@{
            identity = $key; vmName = $VMName
            previous = [string]$obs.previous; current = [string]$obs.current
        })
    }
    return $outcome
}

function Get-GuestAddressFootprintTally {
<#
.SYNOPSIS
    How many guests could be checked against their own identity this cycle, and
    how many came back on an address that identity did not already own.
.OUTPUTS
    [hashtable] checked, unbounded, moves.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        checked   = $script:GuestAddressChecked
        unbounded = $script:GuestAddressUnbounded
        moves     = @($script:GuestAddressMoves)
    }
}

function Reset-GuestAddressFootprintTally {
<#
.SYNOPSIS
    Zero the guest-address tally at a cycle boundary.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    if (-not $PSCmdlet.ShouldProcess('guest address footprint tally', 'Reset')) { return }
    $script:GuestAddressChecked   = 0
    $script:GuestAddressUnbounded = 0
    $script:GuestAddressMoves     = [System.Collections.Generic.List[object]]::new()
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
        [switch]$BestEffort,
        # Enables the pre-kill DHCP release. Omitted, teardown behaves exactly as
        # before -- the release needs a guest key to pick the SSH login user, and a
        # caller that has none has nothing to log in as.
        [string]$GuestKey = ''
    )
    # Ask for the lease back before the power is cut. -SkipStop means the VM is not
    # running (a leftover being swept before a rebuild), so there is nobody to ask.
    if (-not $SkipStop -and -not [string]::IsNullOrWhiteSpace($GuestKey)) {
        # Read the address BEFORE the release: a guest that has just handed its
        # lease back no longer has one to report, so asking afterwards would
        # measure nothing on exactly the guests that behaved correctly.
        #
        # Keyed on the name the VM carries at TEARDOWN, which is the closest
        # identity available here and not quite the one the MAC is derived from
        # (that is the cloud-init hostname the sequence declares, which this
        # layer never sees). The approximation is safe in the direction that
        # matters: a guest built and promoted the same way each cycle ends at
        # the same name, so like is compared with like. Where a hostname is
        # shared across tiers of a chain, several names map onto one address and
        # each simply reads as bounded -- extra rows, no false alarm. Callers
        # that DO know the lifelong identity should pass it as -Identity.
        $addressRuntimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR }
                             else { Join-Path (Split-Path -Parent $PSScriptRoot) 'status' -AdditionalChildPath 'runtime' }
        try {
            $null = Assert-GuestAddressBounded -VMName $VMName -Identity $VMName `
                        -RuntimeDir $addressRuntimeDir -Confirm:$false
        } catch {
            Write-Verbose "guest address check on '$VMName' failed: $($_.Exception.Message)"
        }
        $null = Invoke-GuestDhcpRelease -VMName $VMName -GuestKey $GuestKey
    }
    $savedProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    # -Force: this is a stop-then-DELETE. The guest's disk is removed on the very
    # next line, so there is nothing to flush and nothing a clean shutdown could
    # protect -- while waiting one out costs the full guest-shutdown time (tens of
    # seconds on a k8s guest, which must stop kubelet/containerd) on every cycle.
    # The graceful Stop-VM is for the paths that KEEP the disk: snapshotting it, or
    # leaving it behind for inspection.
    try {
        if ($BestEffort) {
            if (-not $SkipStop) { Stop-VM -VMName $VMName -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
            Remove-VM -VMName $VMName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } else {
            if (-not $SkipStop) { Stop-VM -VMName $VMName -Force -Confirm:$false | Out-Null }
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
    } catch {
        # -ErrorAction SilentlyContinue silences a NON-terminating error; it does
        # nothing about one that throws, and the host drivers do throw (the UTM
        # inventory raises rather than answer "nothing registered" when it cannot
        # reach UTM.app). Without this, -BestEffort could not keep the promise its
        # own parameter makes -- teardown paths that must never fail on an
        # already-gone VM would still take a teardown fault all the way out to the
        # caller. Reported as a warning so the fault is visible and skippable.
        if (-not $BestEffort) { throw }
        Write-Warning "Remove-GuestVMQuietly: teardown of '$VMName' did not complete ($($_.Exception.Message)); continuing (-BestEffort)."
    } finally {
        $global:ProgressPreference = $savedProgress
    }
}

function Get-StashServiceProbeCommand {
    <#
    .SYNOPSIS
        The stash-service /healthz reachability probe (Test-StashServiceHost),
        imported on demand, or $null when the extension is not on disk.
    .DESCRIPTION
        Update-StashServiceMarkerAddress has to tell "this address IS the stash
        VM" from "this address merely parses", and the extension already owns
        that judgment -- HTTP :80 answering /healthz is the same gate the cycle
        pre-flight and the guest workloads apply. Borrowing it keeps one
        definition of what reachable means instead of a second, subtly
        different probe here.

        Resolved by name first so a session that already loaded the extension
        keeps its copy. The on-demand import is deliberately NOT -Global: only
        this module calls the probe, and a -Force import into the global scope
        would evict a caller's binding (feedback_module_force_import_evicts_global).
    .OUTPUTS
        [System.Management.Automation.CommandInfo] or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo])]
    param()
    $cmd = Get-Command Test-StashServiceHost -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd }
    # test/modules/ -> test/extension/stash-service/default.psm1
    $module = Join-Path (Split-Path -Parent $PSScriptRoot) 'extension' -AdditionalChildPath 'stash-service', 'default.psm1'
    if (-not (Test-Path -LiteralPath $module)) { return $null }
    try { Import-Module $module -Force -DisableNameChecking -Verbose:$false }
    catch {
        Write-Verbose "Get-StashServiceProbeCommand: loading '$module' failed: $($_.Exception.Message)"
        return $null
    }
    return (Get-Command Test-StashServiceHost -ErrorAction SilentlyContinue)
}

function Update-StashServiceMarkerAddress {
    <#
    .SYNOPSIS
        Resolve the stash-service VM's current IPv4 and record it as `stashBaseUrl`
        (http://<ip>) in the stash-service.json marker, so the pool-aggregator-service
        can deep-link the Extension hosts cell to the stash-service VM's UI.
    .DESCRIPTION
        Best-effort and never throws -- telemetry must not fail a bring-up or a
        cycle. The stash-service VM's guest address is not known until the host's
        virtualization stack reports it (KVP / dhcpd_leases / utmctl), which can
        lag minutes after boot on a Hyper-V External vSwitch, so callers poll:
        pass a -TimeoutSeconds budget when the VM may have just started
        (Start-StashServiceVM), or 0 for a single-shot refresh on an established VM
        (the per-cycle runner call). Resolution goes through the host contract
        Get-VMIp resolved at call time after Initialize-YurunaHost (the same
        late-bind the teardown helpers use); a host without it loaded is a no-op.
        The marker is rewritten only when the URL changes, atomic temp+rename so a
        polling aggregator never reads a torn file. Format-IpUrlHost brackets an
        IPv6 literal for the URL authority.

        An address is confirmed against /healthz before it is published, because
        a rebuilt VM's first seconds are exactly when the discovery layer can
        return a dead predecessor's lease (see the poll loop). A budget that runs
        out with nothing confirmed still publishes the last address reported, and
        warns.

        Answering /healthz HERE is not enough to advertise an address to the
        POOL. A stash VM that came up on a hypervisor-private network -- the
        macOS shared vmnet, a Hyper-V Default Switch, libvirt's virbr0 -- answers
        its own host perfectly and no one else, so this marker is where a
        host-only address would otherwise become every other host's stash
        address, through host.registration.json. An address off this host's
        pool-facing segment is therefore refused, and one previously published is
        retracted. The service is left running and locally usable; only the claim
        to the pool is withdrawn, and the daemon's own announce still registers
        it if it is genuinely reachable (the pool confirms that by probing).
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
        [int]$TimeoutSeconds = 0,
        # Pre-resolved pool-facing segment (Get-PoolFacingIpv4Segment). Passed by
        # tests so the verdict does not depend on the network the suite runs on;
        # resolved live otherwise.
        [pscustomobject]$PoolSegment
    )
    try {
        if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
        $markerPath = Join-Path $RuntimeDir 'stash-service.json'
        if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
        $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json -ErrorAction Stop
        # A marker being torn down (active:false) must not be re-advertised.
        if ($null -ne $marker.active -and -not [bool]$marker.active) { return $null }
        if (-not $VMName) { $VMName = [string]$marker.vmName }
        if ([string]::IsNullOrWhiteSpace($VMName)) { return $null }
        if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) { return $null }

        # A candidate address has to be PROVEN before it is advertised. For the
        # first seconds of a freshly built VM's life the guest has not completed
        # DHCP, and macOS files every lease under the name the guest sends and
        # never prunes -- so the lease file still holds blocks filed under this
        # VM's name by the incarnations it replaced. Get-VMIp then hands back a
        # dead predecessor's address that is syntactically perfect, on-link, and
        # indistinguishable from a good answer. Taking the first non-empty reply
        # spends the whole poll budget on its first tick and publishes the
        # previous incarnation, which the dashboard's deep-link then points at
        # for the rest of the cycle.
        #
        # /healthz answering is what separates the two, so the poll keeps going
        # until a candidate proves it is a stash service. The real address shows
        # up within seconds of its lease being issued.
        $probe = Get-StashServiceProbeCommand
        if (-not $probe) {
            Write-Verbose 'Update-StashServiceMarkerAddress: no stash-service probe available; publishing the first address Get-VMIp reports without confirming it.'
        }
        $ip            = $null
        $lastCandidate = $null
        $deadline      = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
        while ($true) {
            $candidate = $null
            try { $candidate = [string](Get-VMIp -VMName $VMName) }
            catch { Write-Verbose "Update-StashServiceMarkerAddress: Get-VMIp '$VMName' failed: $($_.Exception.Message)" }
            if ($candidate -and (Test-IpAddress $candidate)) {
                $lastCandidate = $candidate
                if (-not $probe) { $ip = $candidate; break }
                # Two short attempts, not one wide one: this loop is already the
                # outer retry, and a generous per-probe deadline would spend the
                # entire budget confirming a single dead predecessor. The second
                # attempt absorbs the connect-latency tail a first packet pays
                # (feedback_wifi-connect-timeout-tail.md).
                if (& $probe -Address $candidate -Attempts 2 -TimeoutSeconds 3 -BackoffMs 250) {
                    $ip = $candidate
                    break
                }
                Write-Verbose "Update-StashServiceMarkerAddress: '$candidate' did not answer /healthz; still waiting for '$VMName'."
            }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 3
        }
        # Budget gone with nothing confirmed: fall back to the last address
        # Get-VMIp reported rather than publishing nothing. By this point the
        # stale-lease window is long past, so the candidate is the current VM's
        # address whose daemon is merely slower than the budget -- dropping a
        # correct address because the service had not finished starting would
        # trade this bug for the opposite one.
        $unconfirmed = $false
        if (-not $ip -and $lastCandidate) {
            $ip = $lastCandidate
            $unconfirmed = $true
        }
        if (-not $ip) { return $null }

        # Only 'offsegment' refuses. 'unknown' (no route resolved, no mask
        # available) proves nothing and must not withdraw a working service, and
        # a lab whose stash genuinely lives on another routed subnet keeps its
        # pool registration through the daemon's own announce.
        #
        # Resolved BEFORE anything is said about publishing an unconfirmed
        # address, because on an off-segment host nothing is published at all --
        # announcing that an address is being advertised unconfirmed, and then
        # withholding it two lines later, describes an outcome that never happens.
        $segment = if ($PSBoundParameters.ContainsKey('PoolSegment')) { $PoolSegment } else { Get-PoolFacingIpv4Segment }
        $poolVerdict = Get-Ipv4PoolSegmentVerdict -Address $ip -Segment $segment
        if ($poolVerdict -eq 'offsegment') {
            # Retract an address published before the VM moved onto (or was
            # rebuilt on) the private network: leaving it in place would keep
            # feeding the pool an address it cannot reach.
            $hadAddress = (-not [string]::IsNullOrWhiteSpace([string]$marker.stashBaseUrl) -or
                           -not [string]::IsNullOrWhiteSpace([string]$marker.baseUrl))
            # Said once per time the host ENTERS this state, not once per refresh.
            # A stash on a hypervisor-private network is in this branch on every
            # refresh for the life of the VM -- on the per-cycle path that is a
            # warning every cycle, forever, about a condition that has not changed
            # and that the operator can do nothing about mid-run. Repeating it is
            # how a real warning becomes something people filter out.
            #
            # The marker is where the memory lives, because the marker is already
            # this function's state file and nothing else survives between runs.
            # poolWithheld records the verdict; the entry into it is news, the
            # steady state after it is not.
            $alreadyWithheld = ($marker.PSObject.Properties.Name -contains 'poolWithheld') -and [bool]$marker.poolWithheld
            $isNewsWorthy = ($hadAddress -or -not $alreadyWithheld)
            $withholdMessage = ("Update-StashServiceMarkerAddress: '$VMName' answers at $ip, which is NOT on this host's pool-facing network" +
                $(if ($segment) { " ($($segment.Address)/$($segment.PrefixLength))" } else { '' }) +
                ". That address is reachable from this host only -- a stash VM on a hypervisor-private network (macOS shared vmnet, Hyper-V Default Switch, libvirt virbr0) -- so it is NOT advertised to the pool; other hosts would resolve it and time out. Rebuild the stash VM on a bridged interface to serve the pool. The service stays usable from this host, and the daemon's own announce still registers it with the pool.")
            if ($isNewsWorthy) { Write-Warning $withholdMessage } else { Write-Verbose $withholdMessage }
            if ($isNewsWorthy) {
                # Both keys, together. A marker carries the uniform `baseUrl` and
                # the area's own `stashBaseUrl`; retracting one and leaving the
                # other would keep feeding the pool the address this branch
                # exists to withdraw.
                $record = [ordered]@{}
                foreach ($prop in $marker.PSObject.Properties) {
                    if ($prop.Name -in @('stashBaseUrl', 'baseUrl', 'poolWithheld')) { continue }
                    $record[$prop.Name] = $prop.Value
                }
                $record['poolWithheld'] = $true
                $tmp = "$markerPath.tmp"
                [System.IO.File]::WriteAllText($tmp, ($record | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $tmp -Destination $markerPath -Force -ErrorAction Stop
            }
            return $null
        }

        $url = "http://$(Format-IpUrlHost $ip)"
        # Said HERE, where the address really is about to be published, and only
        # about a publication that really happens -- the off-segment branch above
        # returns without publishing anything, so an unconfirmed notice there
        # would describe an outcome that never occurs.
        #
        # Once per address, not once per refresh: publishing an address this host
        # could not confirm is worth flagging, and the per-cycle refresh re-runs
        # the same unconfirmed publish of the same address for as long as the
        # daemon takes to build. The address already being on the marker means
        # this was said when it was first published and nothing has changed since.
        if ($unconfirmed -and [string]$marker.stashBaseUrl -ne $url) {
            Write-Warning ("Update-StashServiceMarkerAddress: '$VMName' reports $ip but nothing answered $url/healthz" +
                $(if ($TimeoutSeconds -gt 0) { " within the ${TimeoutSeconds}s budget" } else { ' on a single unbudgeted probe' }) +
                ". Publishing it unconfirmed -- if the dashboard's stash link is dead, this address is the reason.")
        }
        if ([string]$marker.stashBaseUrl -eq $url -and [string]$marker.baseUrl -eq $url -and
            -not (($marker.PSObject.Properties.Name -contains 'poolWithheld') -and [bool]$marker.poolWithheld)) { return $url }

        # Preserve every existing marker field; set/replace the address only --
        # under BOTH the uniform key every extension marker carries and this
        # area's own, so a consumer reading either sees the same answer.
        $record = [ordered]@{}
        foreach ($prop in $marker.PSObject.Properties) {
            # poolWithheld is dropped rather than carried: this branch IS the
            # address being advertised, so the withholding it recorded is over.
            # Clearing it also re-arms the notice, so a VM that later moves back
            # onto a private network says so again instead of staying quiet
            # because it was withheld once, months ago.
            if ($prop.Name -eq 'poolWithheld') { continue }
            $record[$prop.Name] = $prop.Value
        }
        $record['baseUrl'] = $url
        $record['stashBaseUrl'] = $url
        $tmp = "$markerPath.tmp"
        [System.IO.File]::WriteAllText($tmp, ($record | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $markerPath -Force -ErrorAction Stop
        return $url
    } catch {
        Write-Verbose "Update-StashServiceMarkerAddress: $($_.Exception.Message)"
        return $null
    }
}

function Wait-YurunaServiceVmEndpoint {
<#
.SYNOPSIS
    Wait for a service VM's TCP port to answer, RE-RESOLVING the guest's address
    on every poll so the wait follows a guest whose address moves.
.DESCRIPTION
    A guest's address is not stable while it boots. Its DHCP client identity is
    derived from the machine-id and hostname by default, and cloud-init changes
    both -- so systemd-networkd re-requests under a new identity, the DHCP server
    treats it as a different client, and the guest lands on a different address
    two or three times within the first seconds. macOS `bootpd` additionally
    never prunes lease blocks, so every one of those addresses stays on file
    under the same guest name.

    Resolving the address ONCE and probing it for the rest of the bring-up
    therefore probes an address the guest abandoned, for the whole budget, while
    the service answers perfectly somewhere else. Re-resolving each poll costs a
    lease-file read and removes the entire class: whatever the guest moved to is
    what gets probed next.

    Resolution goes through Get-GuestAddress -- the SAME resolver Invoke-GuestSsh
    uses. That is deliberate and load-bearing for the verdict below: when the
    port probe and the SSH check disagree about where the guest is, "the daemon
    is up but unreachable" is indistinguishable from "I am probing the wrong
    address", and the second is the far more common fault. Sharing one resolver
    makes them agree by construction.

    The in-guest check answers the two questions waiting cannot. Is the daemon
    actually bound? A daemon that IS bound while this host cannot open a socket
    to it is reported as Unreachable rather than NotReady -- the service is
    RUNNING, and on a hypervisor-private network it still reaches the pool
    through its own announce, so a caller is right to treat that as a degraded
    success rather than a failed bring-up.

    And: is the guest still WORKING? A first boot installs a Go toolchain and
    compiles the daemon from source, which takes anywhere from a few minutes to
    the better part of an hour depending on the host, the arch and how cold the
    package mirror is. No fixed budget is right for that range: too small fails
    a build that was progressing, too large turns a genuinely dead guest into a
    long silence. So the budget is not fixed. While cloud-init reports `running`
    the guest is demonstrably making progress, and the deadline is extended --
    bounded by -MaxTimeoutSeconds, which is what keeps a guest whose cloud-init
    has itself hung from waiting forever. Once cloud-init reports done or error,
    extension stops: the build is over, and a daemon that is not bound by then is
    a real failure rather than a slow one.

    Reaching that cap while the guest is still building is reported as
    StillBuilding, and it is NOT a failure either. The build finishes on its own
    afterwards and the daemon registers itself with the pool through its own
    announce; a caller that failed the bring-up here would be reporting a broken
    service over one that was merely not finished yet.
.PARAMETER OnAddressChanged
    Invoked with the new address whenever the guest moves, so a caller can
    re-point a host port-forwarder that would otherwise keep dialing the address
    the guest left. Best-effort: a throw here is logged and the wait continues.
.PARAMETER MaxTimeoutSeconds
    Absolute ceiling on the extended wait. Defaults to twice -TimeoutSeconds.
.PARAMETER InGuestCheckEverySeconds
    How often to re-ask the guest once it is answering. The answer drives both
    the extension decision and the progress reporting, so it has to be a repeated
    question rather than a single verdict -- but each one costs an SSH round
    trip, so it is deliberately far coarser than -PollSeconds.
.PARAMETER ResolveAddress
.PARAMETER TestPortOpen
.PARAMETER InvokeInGuest
    The three outside effects -- resolve, probe, ask the guest -- as injectable
    scriptblocks, defaulting to the real ones. Same reason Invoke-WaitVmIp takes
    -ResolveVmIp: they are the only parts of this function that need a running
    VM, so injecting them is what lets the ordering and the verdict logic (which
    is where the faults have been) be tested without one.
.OUTPUTS
    [pscustomobject] Ready, Address, WaitedSeconds, Unreachable, ListeningInGuest,
    StillBuilding, CloudInitStatus, LastProgress, ExtendedSeconds, AddressChanges
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$Port = 80,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [int]$MaxTimeoutSeconds = 0,
        [string]$Address = '',
        [string]$GuestKey = '',
        [string]$User = '',
        [int]$InGuestCheckAfterSeconds = 120,
        [int]$InGuestCheckEverySeconds = 60,
        [int]$PollSeconds = 3,
        [string]$ProgressLabel = '',
        [ValidateSet('auto', 'inplace', 'lines', 'none')][string]$ProgressMode = 'auto',
        [scriptblock]$OnAddressChanged,
        [scriptblock]$OnTick,
        [scriptblock]$ResolveAddress,
        [scriptblock]$TestPortOpen,
        [scriptblock]$InvokeInGuest
    )
    if ($MaxTimeoutSeconds -le 0) { $MaxTimeoutSeconds = $TimeoutSeconds * 2 }
    if ($MaxTimeoutSeconds -lt $TimeoutSeconds) { $MaxTimeoutSeconds = $TimeoutSeconds }
    if (-not $ResolveAddress) {
        $ResolveAddress = {
            param($name)
            if (Get-Command Get-GuestAddress -ErrorAction SilentlyContinue) { return [string](Get-GuestAddress -VMName $name) }
            return ''
        }
    }
    if (-not $TestPortOpen) {
        $TestPortOpen = { param($addr, $p) Test-TcpEndpointOpen -Address $addr -Port $p -TimeoutMilliseconds 1000 }
    }
    if (-not $InvokeInGuest) {
        $InvokeInGuest = {
            param($name, $key, $account, $cmd)
            if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
                return Invoke-GuestSsh -VMName $name -GuestKey $key -User $account -TimeoutSeconds 30 -Command $cmd
            }
            return $null
        }
    }
    $probeStart      = Get-Date
    $deadline        = $probeStart.AddSeconds($TimeoutSeconds)
    $hardDeadline    = $probeStart.AddSeconds($MaxTimeoutSeconds)
    $current         = $Address
    $addressChanges  = 0
    $ready           = $false
    $listeningInGuest = $false
    $unreachable     = $false
    $stillBuilding   = $false
    $cloudInitStatus = ''
    $cloudInitErrored = $false
    $lastProgress    = ''
    $extendedSeconds = 0
    $nextTick        = 30
    $nextInGuestCheck = $InGuestCheckAfterSeconds

    while ((Get-Date) -lt $deadline) {
        # Re-resolve first, so a guest that moved is probed at its new address on
        # this very pass. Get-GuestAddress returns the VM NAME when it can
        # discover no address -- a documented fallback for ssh, useless as a
        # probe target -- so that answer is discarded rather than dialed.
        $resolved = ''
        try { $resolved = [string](& $ResolveAddress $VMName) } catch { Write-Verbose "Wait-YurunaServiceVmEndpoint: address resolve: $($_.Exception.Message)" }
        if ($resolved -eq $VMName) { $resolved = '' }
        if ($resolved -and $resolved -ne $current) {
            if ($current) {
                Close-YurunaWaitProgress
                Write-Information "  '$VMName' moved from $current to $resolved -- following it (a guest re-requests DHCP under a new identity while cloud-init runs)." -InformationAction Continue
                $addressChanges++
                # A new address deserves a fresh verdict now, not at the next
                # interval: a listener check made against the old one proves
                # nothing about this one.
                $nextInGuestCheck = [int]((Get-Date) - $probeStart).TotalSeconds
            }
            $current = $resolved
            if ($OnAddressChanged) {
                try { & $OnAddressChanged $current } catch { Write-Warning "Re-pointing host-side forwarding to ${current} failed: $($_.Exception.Message). The service is unaffected; peers may still be sent to the previous address." }
            }
        }

        if ($current -and (& $TestPortOpen $current $Port)) {
            $ready = $true
            break
        }

        $elapsed = [int]((Get-Date) - $probeStart).TotalSeconds
        # The liveness line turns on EVERY pass, not on the 30s tick: a character
        # that moves once every thirty seconds proves nothing an operator is
        # willing to wait for. It costs one carriage return.
        if ($ProgressMode -ne 'none' -and $ProgressLabel) {
            $budgetMinutes = [int]([Math]::Ceiling(($deadline - $probeStart).TotalSeconds / 60))
            $detail = if ($lastProgress) { " -- $lastProgress" } elseif ($cloudInitStatus) { " -- cloud-init: $cloudInitStatus" } else { '' }
            $line = "{0:D2}m{1:D2}s / {2}m  {3}{4}" -f [int][math]::Floor($elapsed / 60), ($elapsed % 60), $budgetMinutes, $ProgressLabel, $detail
            # Throttled on everything BUT the clock. The clock is what makes the
            # line worth looking at on a terminal and what makes it worthless in
            # a log: ticking every poll, it would defeat the collapse and put one
            # entry per poll in the file for the whole wait. This wait's start is
            # in the key too, because the throttle state is module-scoped -- a
            # later wait opening on the same text as an earlier one's last line
            # would otherwise stay silent until the interval elapsed.
            Write-YurunaWaitProgress -Message $line -Mode $(if ($ProgressMode -eq 'auto') { 'auto' } else { $ProgressMode }) `
                -IdentityKey "$VMName|$($probeStart.Ticks)|$ProgressLabel|$detail"
        }
        if ($elapsed -ge $nextTick) {
            if ($OnTick) {
                Close-YurunaWaitProgress
                try { & $OnTick $elapsed } catch { Write-Verbose "Wait-YurunaServiceVmEndpoint: tick: $($_.Exception.Message)" }
            }
            $nextTick += 30
        }

        # Deferred, then REPEATED: sshd is not up instantly, so an early
        # no-answer would prove nothing -- and one answer is not enough either,
        # because this is what tracks the build's progress and decides whether to
        # extend. Only a COMPLETED answer settles anything; SSH that did not
        # connect means the guest is still coming up, so a later pass asks again.
        # Three facts in one round trip: is the port bound, is cloud-init still
        # working, and what was the last thing it printed.
        if ($elapsed -ge $nextInGuestCheck -and $GuestKey -and $User) {
            $inGuest = $null
            try {
                $inGuest = & $InvokeInGuest $VMName $GuestKey $User (@(
                    "ss -ltn 2>/dev/null | grep -qE '(^|[^0-9]):$Port\b' && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING",
                    'echo "YURUNA_CLOUDINIT=$(cloud-init status 2>/dev/null | head -n 1 | sed -e "s/^status: //")"',
                    # The LAST MEANINGFUL line, not simply the last one. A bare
                    # tail -n 1 reports whatever happened to be printed last, and
                    # cloud-init ends by generating host keys -- so a failed
                    # build showed the operator the top border of an SSH
                    # randomart box for the whole wait while the real error sat
                    # a few lines above. Drop blanks and lines made only of the
                    # box-drawing and randomart glyphs, then take the last.
                    ('echo "YURUNA_PROGRESS=$(sudo tail -n 60 /var/log/cloud-init-output.log 2>/dev/null' +
                     ' | tr -d "\r"' +
                     ' | grep -vE "^[[:space:]]*$"' +
                     ' | grep -vE "^[[:space:]]*[+|][-+| .oOE=*@%&#SB^~:]*[+|]?[[:space:]]*$"' +
                     ' | tail -n 1)"')
                ) -join "`n")
            } catch { Write-Verbose "Wait-YurunaServiceVmEndpoint: in-guest probe: $($_.Exception.Message)" }
            if ($inGuest -and "$($inGuest.output)" -match 'YURUNA_(NOT_)?LISTENING') {
                $nextInGuestCheck = $elapsed + [Math]::Max(1, $InGuestCheckEverySeconds)
                $answer = "$($inGuest.output)"
                if ($answer -match 'YURUNA_CLOUDINIT=(.*)') { $cloudInitStatus = $Matches[1].Trim() }
                if ($answer -match 'YURUNA_PROGRESS=(.*)') {
                    $progress = $Matches[1].Trim()
                    # Only on CHANGE. A repeated line means the same step is still
                    # running, and reprinting it every minute would bury the ones
                    # that do move.
                    if ($progress -and $progress -ne $lastProgress) {
                        $lastProgress = $progress
                        Close-YurunaWaitProgress
                        Write-Information "  [guest] cloud-init: $cloudInitStatus -- $progress" -InformationAction Continue
                    }
                }
                if ($answer -match 'YURUNA_LISTENING') {
                    # One more resolve before concluding anything. SSH just
                    # succeeded, so if it reached a DIFFERENT address than the one
                    # being probed, the probe target is simply stale -- adopt the
                    # working one and keep waiting instead of reporting a fault.
                    $sshAddress = ''
                    try { $sshAddress = [string](& $ResolveAddress $VMName) } catch { Write-Verbose "Wait-YurunaServiceVmEndpoint: post-SSH resolve: $($_.Exception.Message)" }
                    if ($sshAddress -and $sshAddress -ne $VMName -and $sshAddress -ne $current) {
                        Close-YurunaWaitProgress
                        Write-Information "  SSH reached '$VMName' at $sshAddress while :$Port was being probed at $current -- adopting $sshAddress." -InformationAction Continue
                        $current = $sshAddress
                        $addressChanges++
                        $nextInGuestCheck = $elapsed
                        if ($OnAddressChanged) {
                            try { & $OnAddressChanged $current } catch { Write-Warning "Re-pointing host-side forwarding to ${current} failed: $($_.Exception.Message)." }
                        }
                        continue
                    }
                    $listeningInGuest = $true
                    $unreachable = $true
                    break
                }
                # Not bound yet. Extend ONLY on evidence the guest is still
                # working: cloud-init `running` means the build is progressing, so
                # the budget was simply too small for this host. Any other status
                # means the build is over and a missing daemon is a real failure,
                # which must not be papered over by waiting longer.
                # cloud-init ERROR is terminal, so stop rather than serve out
                # the budget. Nothing re-runs cloud-init on this boot: every
                # remaining poll asks a question already answered, and the
                # operator watches a progress bar for up to 45 more minutes
                # before being told what the guest knew at minute two. 'done'
                # deliberately keeps waiting -- the daemon can still be binding
                # its port in the seconds after cloud-init finishes.
                if ($cloudInitStatus -match '^error$') {
                    Close-YurunaWaitProgress
                    Write-Information "  cloud-init on '$VMName' ERRORED and :$Port is not bound -- ending the wait; more time cannot help." -InformationAction Continue
                    $cloudInitErrored = $true
                    break
                }
                if ($cloudInitStatus -match '^(running|not started)$' -and (Get-Date) -lt $hardDeadline) {
                    $grow = [Math]::Max(1, $InGuestCheckEverySeconds) * 2
                    $wanted = $deadline.AddSeconds($grow)
                    if ($wanted -gt $hardDeadline) { $wanted = $hardDeadline }
                    if ($wanted -gt $deadline) {
                        $extendedSeconds += [int]($wanted - $deadline).TotalSeconds
                        $deadline = $wanted
                        Write-Verbose "Wait-YurunaServiceVmEndpoint: cloud-init still running; extended to $([int](($deadline - $probeStart)).TotalSeconds)s (cap ${MaxTimeoutSeconds}s)."
                    }
                }
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    # The line is a liveness indicator, not a result. Retire it here so the
    # caller's verdict starts on a clean row rather than landing on top of a
    # half-drawn frame.
    Close-YurunaWaitProgress

    # Out of budget with the guest still working is NOT a failed bring-up: the
    # build finishes on its own and the daemon registers itself with the pool.
    if (-not $ready -and -not $unreachable -and $cloudInitStatus -match '^(running|not started)$') {
        $stillBuilding = $true
    }

    return [pscustomobject]@{
        Ready            = $ready
        Address          = $current
        WaitedSeconds    = [int]((Get-Date) - $probeStart).TotalSeconds
        Unreachable      = $unreachable
        ListeningInGuest = $listeningInGuest
        StillBuilding    = $stillBuilding
        CloudInitStatus  = $cloudInitStatus
        CloudInitErrored = $cloudInitErrored
        LastProgress     = $lastProgress
        ExtendedSeconds  = $extendedSeconds
        AddressChanges   = $addressChanges
    }
}

# State for the one-line wait indicator below. Module-scoped because the line is
# a property of the CONSOLE, not of any single call: whoever writes to the
# console next has to know whether a transient line is currently sitting there
# unterminated.
$script:WaitProgressOpen       = $false
$script:WaitProgressLastLength = 0
$script:WaitProgressLastText   = ''
$script:WaitProgressLastEmit   = [datetime]::MinValue
$script:WaitProgressFrame      = 0

function Test-YurunaProgressLineSupported {
<#
.SYNOPSIS
    Can this session rewrite a line in place, or must progress be separate lines?
.DESCRIPTION
    Rewriting in place means emitting a carriage return and overwriting. On a
    terminal that is one live line. Into a redirected stream it is the opposite
    of readable: every frame is retained, and the whole wait arrives as one
    enormous line with no separators -- which is exactly what a setup log would
    capture, since the installer drains its children's stdout into a file.

    So the console decides. YURUNA_NONINTERACTIVE is honored as well as the
    redirect check: an installer sets it on children whose output it is
    collecting, and that intent is worth trusting even in the cases where the
    handle still looks like a terminal.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($env:YURUNA_NONINTERACTIVE) { return $false }
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
    return $true
}

function Write-YurunaWaitProgress {
<#
.SYNOPSIS
    One line of "still working" feedback during a long wait, rewritten in place
    on a terminal and emitted as throttled separate lines when it cannot be.
.DESCRIPTION
    A long wait with no output is indistinguishable from a hung one, and that is
    the reading an operator acts on -- by killing it. The point of this line is
    only to be visibly ALIVE: a turning character plus how long it has been and
    what the guest is doing.

    In place on a terminal, so a half-hour wait costs one line rather than sixty
    of near-identical text scrolling the real output off the screen.

    Where it cannot be in place, the same information is emitted as ordinary
    lines -- but only when what is being SAID changes or the throttle elapses,
    because the destination there is a log file that someone reads afterwards,
    and sixty near-identical entries in it are worse than none.
.PARAMETER Mode
    'auto' asks the console (the normal case). 'inplace' and 'lines' force one
    behavior, which is what makes both paths testable off a terminal.
.PARAMETER IdentityKey
    What counts as "the same line" for the throttle. Defaults to the message.

    A progress line usually carries a clock, and a clock ticking every poll
    changes the message every poll -- so throttling on the message alone
    collapses nothing and a three-quarter-hour wait arrives as several hundred
    log entries. Passing the part that actually means something (the state being
    reported) restores the collapse and, better than the default ever could,
    emits IMMEDIATELY when that state changes instead of on the next tick.

    It also separates one wait from the next. This state is module-scoped
    because the console is, so without a key a later wait whose first line
    happens to match the previous wait's last one would print nothing at all for
    a full throttle interval.
#>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes transient console feedback; there is no state to confirm or roll back.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The console is the point: rewriting a line in place needs a carriage return with no newline, which no PowerShell write cmdlet can emit -- they terminate every record. The call is reached only in inplace mode, which Test-YurunaProgressLineSupported grants only when a real console is attached; every other caller takes the Write-Information path below.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('auto', 'inplace', 'lines')][string]$Mode = 'auto',
        [int]$RedirectedEverySeconds = 60,
        [AllowEmptyString()][string]$IdentityKey = ''
    )
    if ($Mode -eq 'auto') { $Mode = if (Test-YurunaProgressLineSupported) { 'inplace' } else { 'lines' } }
    if ($Mode -eq 'inplace') {
        $spinner = '-\|/'[$script:WaitProgressFrame % 4]
        $script:WaitProgressFrame++
        $text = "  $spinner $Message"
        # Pad to the previous width: a shorter frame would otherwise leave the
        # tail of the longer one behind it and the line would read as garbage.
        $pad = [Math]::Max(0, $script:WaitProgressLastLength - $text.Length)
        [Console]::Write("`r" + $text + (' ' * $pad))
        $script:WaitProgressLastLength = $text.Length
        $script:WaitProgressOpen = $true
        return
    }
    $now = Get-Date
    $identity = if ($IdentityKey) { $IdentityKey } else { $Message }
    if ($identity -eq $script:WaitProgressLastText -and
        ($now - $script:WaitProgressLastEmit).TotalSeconds -lt $RedirectedEverySeconds) { return }
    $script:WaitProgressLastText = $identity
    $script:WaitProgressLastEmit = $now
    Write-Information "  $Message" -InformationAction Continue
}

function Close-YurunaWaitProgress {
<#
.SYNOPSIS
    Retire the in-place wait line so the next output starts on a clean row.
.DESCRIPTION
    Erased rather than left behind: it is a liveness indicator, not a result, and
    the caller prints the actual outcome immediately after. Leaving the last
    frame on screen would put a half-finished progress line directly above the
    verdict that supersedes it.

    Must be called before ANY other console write while a wait is running --
    otherwise that write lands in the middle of the transient line and both are
    unreadable. Idempotent, so a caller can call it defensively.
#>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Clears transient console feedback; there is no state to confirm or roll back.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Erasing a line in place needs a carriage return with no newline, which no PowerShell write cmdlet can emit. Reached only when Write-YurunaWaitProgress opened an in-place line, which happens only with a real console attached.')]
    param()
    if (-not $script:WaitProgressOpen) { return }
    [Console]::Write("`r" + (' ' * ($script:WaitProgressLastLength + 1)) + "`r")
    $script:WaitProgressOpen = $false
    $script:WaitProgressLastLength = 0
}

function Test-TcpEndpointOpen {
<#
.SYNOPSIS
    Can this host open a TCP connection to <Address>:<Port> within the timeout?
.DESCRIPTION
    Bounded by the caller's timeout rather than the OS connect timeout, which on
    a dropped SYN is tens of seconds -- long enough that a poll loop built on it
    stops being a poll loop. Never throws: an unreachable address is the ANSWER
    here, not an error.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 1000
    )
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $tcp.BeginConnect($Address, $Port, $null, $null)
        return ($async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds) -and $tcp.Connected)
    } catch {
        Write-Verbose "Test-TcpEndpointOpen ${Address}:${Port}: $($_.Exception.Message)"
        return $false
    } finally {
        $tcp.Close()
    }
}

Export-ModuleMember -Function Wait-VMRunning, Get-ScreenshotSchedule, Invoke-ScreenshotTest, Compare-Screenshot, Get-CachingProxyServiceExposedPort, Remove-GuestVMQuietly, Invoke-GuestDhcpRelease, Get-GuestDhcpReleaseTally, Reset-GuestDhcpReleaseTally, Get-GuestAddressLedgerPath, Register-GuestAddressObservation, Assert-GuestAddressBounded, Get-GuestAddressFootprintTally, Reset-GuestAddressFootprintTally, Update-StashServiceMarkerAddress, Wait-YurunaServiceVmEndpoint, Test-TcpEndpointOpen, Write-YurunaWaitProgress, Close-YurunaWaitProgress, Test-YurunaProgressLineSupported

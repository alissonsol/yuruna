<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456742
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Brings up the squid-cache VM for the current host environment.

.DESCRIPTION
    Cross-platform driver that orchestrates the squid HTTP-caching proxy VM
    the yuruna guest installers rely on. Detects the host (macOS/UTM or
    Windows/Hyper-V) and runs the right Get-Image.ps1 + New-VM.ps1 pair
    under vde/host.*/guest.squid-cache/.

    Flow:
      1. Stop and delete any prior squid-cache VM + its disk.
      2. Run Get-Image.ps1 only if the base cloud image is not already
         present (the existence check lives here, not in Get-Image.ps1,
         so Get-Image.ps1 stays a pure "(re)download" script).
      3. Run New-VM.ps1 for the platform.
      4. macOS only: register the .utm bundle with UTM (`open -g -a UTM`)
         and `utmctl start` — Hyper-V's New-VM.ps1 already starts the VM
         natively, so no equivalent step is needed there.
      5. Wait for port 3128 to respond, then print IP, proxy URL,
         cachemgr URL, username, and password.

.PARAMETER VMName
    Name for the squid-cache VM. Default: squid-cache.

.EXAMPLE
    ./Start-SquidCache.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "squid-cache"
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

# Repo root sits one level above test/.
$RepoRoot = Split-Path -Parent $PSScriptRoot

if ($IsMacOS) {
    $HostDir      = Join-Path $RepoRoot 'vde/host.macos.utm/guest.squid-cache'
    $downloadDir  = Join-Path $HOME 'virtual/squid-cache'
    $ImageFile    = Join-Path $downloadDir 'host.macos.utm.guest.squid-cache.raw'
    $PasswordFile = Join-Path $downloadDir 'squid-cache-password.txt'
    $UtmDir       = "$HOME/Desktop/Yuruna.VDE/$(hostname -s).nosync/$VMName.utm"
} elseif ($IsWindows) {
    $HostDir      = Join-Path $RepoRoot 'vde/host.windows.hyper-v/guest.squid-cache'
    # (Get-VMHost) loads the Hyper-V module on first use; fails cleanly if
    # Hyper-V isn't installed — the underlying New-VM.ps1 has the same
    # dependency, so surfacing it here keeps the error close to the user.
    $downloadDir  = (Get-VMHost).VirtualHardDiskPath
    $ImageFile    = Join-Path $downloadDir 'host.windows.hyper-v.guest.squid-cache.vhdx'
    $PasswordFile = Join-Path $downloadDir "$VMName/squid-cache-password.txt"
} else {
    Write-Error "Unsupported host. Start-SquidCache.ps1 runs on macOS (UTM) or Windows (Hyper-V)."
    exit 1
}

$GetImageScript = Join-Path $HostDir 'Get-Image.ps1'
$NewVMScript    = Join-Path $HostDir 'New-VM.ps1'

foreach ($p in @($GetImageScript, $NewVMScript)) {
    if (-not (Test-Path $p)) { Write-Error "Missing required script: $p"; exit 1 }
}

# === Step 1: stop + remove any prior VM =====================================

Write-Output ""
Write-Output "=== Step 1: cleanup previous '$VMName' VM ==="
if ($IsMacOS) {
    # `utmctl status <name>` exits non-zero with "Virtual machine not found"
    # when the VM isn't registered — cheap probe, no need to parse `utmctl list`.
    & utmctl status $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  Prior VM registered with UTM — stopping and deleting..."
        & utmctl stop $VMName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & utmctl delete $VMName 2>&1 | Out-Null
    } else {
        Write-Output "  No prior VM registered with UTM."
    }
    if (Test-Path $UtmDir) {
        Write-Output "  Removing stale bundle $UtmDir"
        Remove-Item -Recurse -Force $UtmDir
    }
} elseif ($IsWindows) {
    $existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "  Prior VM found (state: $($existing.State)) — stopping and removing..."
        Stop-VM -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-VM -Name $VMName -Force
    } else {
        Write-Output "  No prior VM registered with Hyper-V."
    }
    $vmDir = Join-Path $downloadDir $VMName
    if (Test-Path $vmDir) {
        Write-Output "  Removing stale VM disk directory $vmDir"
        Remove-Item -Recurse -Force $vmDir
    }
}

# === Step 2: base image =====================================================

Write-Output ""
Write-Output "=== Step 2: base image ==="
if (Test-Path $ImageFile) {
    $sizeMB = [math]::Round((Get-Item $ImageFile).Length / 1MB, 0)
    Write-Output "  Present: $ImageFile ($sizeMB MB) — skipping Get-Image.ps1."
} else {
    Write-Output "  Missing: $ImageFile"
    Write-Output "  Running Get-Image.ps1 (downloads + converts; ~600 MB transfer)..."
    & $GetImageScript
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Get-Image.ps1 failed (exit $LASTEXITCODE)."
        exit 1
    }
    if (-not (Test-Path $ImageFile)) {
        Write-Error "Get-Image.ps1 exited 0 but '$ImageFile' is still missing."
        exit 1
    }
}

# === Step 3: create the VM ==================================================

Write-Output ""
Write-Output "=== Step 3: create VM '$VMName' ==="
& $NewVMScript $VMName
if ($LASTEXITCODE -ne 0) {
    Write-Error "New-VM.ps1 failed (exit $LASTEXITCODE)."
    exit 1
}

# === Step 4: macOS — register with UTM and start ===========================
# (Hyper-V's New-VM.ps1 already starts the VM and waits for :3128.)

$cacheIp = $null
if ($IsMacOS) {
    Write-Output ""
    Write-Output "=== Step 4: register '$VMName' with UTM and start ==="
    if (-not (Test-Path $UtmDir)) {
        Write-Error "Expected bundle '$UtmDir' missing after New-VM.ps1 ran."
        exit 1
    }
    # `open -g -a UTM` launches UTM in background and imports the bundle.
    # utmctl has no 'import' verb — `open` is the only way to register a
    # freshly-built .utm bundle from the CLI.
    & open -g -a UTM $UtmDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "'open -g -a UTM $UtmDir' failed (exit $LASTEXITCODE)."
        exit 1
    }

    # UTM registers asynchronously after import — poll for up to 30 s.
    $registered = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        & utmctl status $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $registered = $true; break }
    }
    if (-not $registered) {
        Write-Error "UTM did not register '$VMName' within 30 s. Open UTM manually to continue."
        exit 1
    }
    # On a freshly-imported bundle, `utmctl start` can return 0 at the RPC
    # level while UTM is still finalizing bundle ingestion, and the start
    # request is silently dropped — the VM stays in 'stopped'. Verify the
    # transition by parsing `utmctl status` output and retry a few times.
    # `utmctl status` prints one of: started / paused / stopped / suspended.
    Write-Output "  Registered. Starting VM..."
    $started = $false
    for ($attempt = 1; $attempt -le 3 -and -not $started; $attempt++) {
        & utmctl start $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "'utmctl start $VMName' failed (exit $LASTEXITCODE)."
            exit 1
        }
        # Poll up to 15 s for the VM to leave 'stopped'. A state of 'started'
        # (or any non-stopped/paused state) means the start actually took.
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $state = (& utmctl status $VMName 2>&1 | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $state -and "$state".Trim() -notmatch '^(stopped|paused)\s*$') {
                $started = $true
                break
            }
        }
        if (-not $started) {
            Write-Warning "  'utmctl start' attempt $attempt returned 0 but VM still reports '$state' — retrying."
        }
    }
    if (-not $started) {
        Write-Error "UTM did not transition '$VMName' out of 'stopped' after 3 start attempts. Open UTM manually and start the VM, then re-run."
        exit 1
    }

    # `utmctl ip-address` returns "Operation not supported by the backend"
    # for Apple Virtualization VMs — port-scan Shared-NAT's 192.168.64.0/24
    # for a :3128 listener instead. This is also how guest.ubuntu.desktop
    # discovers the cache, so the same path is exercised here.
    Write-Output ""
    Write-Output "=== Step 5: wait for squid on :3128 (up to 15 min) ==="
    Write-Output "  (first boot = cloud-init installs squid + apache2 + squid-cgi,"
    Write-Output "   then pre-warms by pulling linux-firmware through the proxy)"
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline -and -not $cacheIp) {
        for ($octet = 2; $octet -le 30; $octet++) {
            $candidate = "192.168.64.$octet"
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($candidate, 3128, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(200) -and $tcp.Connected) {
                    $cacheIp = $candidate
                    break
                }
            } catch {
                Write-Verbose "probe ${candidate}:3128 failed: $($_.Exception.Message)"
            } finally { $tcp.Close() }
        }
        if (-not $cacheIp) { Start-Sleep -Seconds 5 }
    }
    if (-not $cacheIp) {
        Write-Warning "squid did not answer on :3128 after 15 min."
        Write-Warning "VM is still running — log in through the UTM window and run:"
        Write-Warning "  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40"
    }

    # === Step 6: host-side TCP forwarder ====================================
    # Apple Virtualization shared-NAT isolates guest↔guest traffic: guests on
    # 192.168.64.0/24 can reach the host/gateway (192.168.64.1) but not each
    # other. So a fresh guest cannot reach the squid VM at $cacheIp directly —
    # apt times out with "No route to host", subiquity reverts to offline
    # install, and ubuntu-desktop is then unresolvable because it only lives
    # behind the proxy. The fix is a forwarder on the HOST that binds :3128
    # and tunnels to $cacheIp:3128; guests point at 192.168.64.1:3128 and
    # traffic reaches squid via the host.
    # Keep it alive across Start-SquidCache.ps1 exit (it's a detached pwsh
    # subprocess with its pid at $HOME/virtual/squid-cache/forwarder.pid).
    # Stop-SquidCache.ps1 tears it down symmetrically.
    if ($cacheIp) {
        Write-Output ""
        Write-Output "=== Step 6: host-side :3128 forwarder ==="
        $vmCommon = Join-Path $RepoRoot "vde/host.macos.utm/VM.common.psm1"
        Import-Module $vmCommon -Force
        [void](Start-SquidForwarder -CacheIp $cacheIp)
    }
} elseif ($IsWindows) {
    # New-VM.ps1 only exits 0 after :3128 responds — KVP should be warm too.
    # Retry a handful of times in case the KVP scrape races the exit.
    for ($i = 0; $i -lt 6 -and -not $cacheIp; $i++) {
        $ips = (Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        if ($ips) { $cacheIp = $ips[0] } else { Start-Sleep -Seconds 2 }
    }
}

# === Final summary ==========================================================

$UbuntuPassword = if (Test-Path $PasswordFile) { (Get-Content -Raw $PasswordFile).Trim() } else { '(not available)' }

Write-Output ""
Write-Output "================================================================="
Write-Output "=== squid-cache is READY ==="
Write-Output "================================================================="
Write-Output "  VM name:     $VMName"
if ($cacheIp) {
    Write-Output "  VM IP:       $cacheIp"
    if ($IsMacOS) {
        # On macOS VZ, guests cannot reach $cacheIp directly — they must
        # use the host-side :3128 forwarder at 192.168.64.1 instead.
        Write-Output "  Proxy URL:   http://192.168.64.1:3128  (host forwarder → $cacheIp)"
        Write-Output "  cachemgr:    http://${cacheIp}/cgi-bin/cachemgr.cgi  (host-only; guests can't reach this)"
    } else {
        Write-Output "  Proxy URL:   http://${cacheIp}:3128"
        Write-Output "  cachemgr:    http://${cacheIp}/cgi-bin/cachemgr.cgi"
    }
} else {
    Write-Output "  IP address:  (discovery failed — see warnings above)"
}
Write-Output ""
Write-Output "  SSH / console login:"
Write-Output "    user:     ubuntu"
Write-Output "    password: $UbuntuPassword"
Write-Output "    (saved at $PasswordFile)"
Write-Output "================================================================="

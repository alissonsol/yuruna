<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456713
.AUTHOR Alisson Sol
.COMPANYNAME None
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

# ── Start VM ─────────────────────────────────────────────────────────────────

# Starts a VM that was previously created by New-VM.ps1.
# Returns a hashtable: { success, errorMessage }
function Invoke-StartVM {
    param([string]$HostType, [string]$VMName)
    switch ($HostType) {
        "host.macos.utm"       { return Start-UtmVM    -VMName $VMName }
        "host.windows.hyper-v" { return Start-HyperVVM -VMName $VMName }
        default { return @{ success=$false; errorMessage="Unknown host type for StartVM: $HostType" } }
    }
}

function Start-UtmVM {
    param([string]$VMName)
    $hostname = if ($IsMacOS) { (& hostname -s 2>$null).Trim() } else { (& hostname).Trim() }
    $utmBundle = "$HOME/Desktop/Yuruna.VDE/$hostname.nosync/$VMName.utm"
    if (-not (Test-Path $utmBundle)) {
        return @{ success=$false; errorMessage="UTM bundle not found: $utmBundle" }
    }
    try {
        & open "$utmBundle"
        Start-Sleep -Seconds 5
        & utmctl start "$VMName" 2>&1 | Write-Output
        if ($LASTEXITCODE -ne 0) {
            return @{ success=$false; errorMessage="utmctl start failed for '$VMName' (exit code $LASTEXITCODE)" }
        }
        return @{ success=$true; errorMessage=$null }
    } catch {
        return @{ success=$false; errorMessage="Failed to start UTM VM '$VMName': $_" }
    }
}

function Start-HyperVVM {
    param([string]$VMName)
    try {
        Start-VM -Name $VMName -ErrorAction Stop
        return @{ success=$true; errorMessage=$null }
    } catch {
        return @{ success=$false; errorMessage="Start-VM failed for '$VMName': $_" }
    }
}

# ── Verify running ───────────────────────────────────────────────────────────

# Polls until the VM reaches a running state or the timeout expires.
# Returns $true on success.
function Confirm-VMStarted {
    param([string]$HostType, [string]$VMName, [int]$TimeoutSeconds = 120)
    switch ($HostType) {
        "host.macos.utm"       { return Confirm-UtmVMStarted    -VMName $VMName -TimeoutSeconds $TimeoutSeconds }
        "host.windows.hyper-v" { return Confirm-HyperVVMStarted -VMName $VMName -TimeoutSeconds $TimeoutSeconds }
        default { Write-Error "Unknown host type for start verification: $HostType"; return $false }
    }
}

function Confirm-UtmVMStarted {
    param([string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $output = & utmctl status "$VMName" 2>&1
        if ($output -match "started|running") {
            Write-Output "Verified: UTM VM '$VMName' is running"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "UTM VM '$VMName' did not reach running state within ${TimeoutSeconds}s"
    return $false
}

function Confirm-HyperVVMStarted {
    param([string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running') {
            Write-Output "Verified: Hyper-V VM '$VMName' is running (State: $($vm.State))"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "Hyper-V VM '$VMName' did not reach Running state within ${TimeoutSeconds}s"
    return $false
}

# ── Custom test extensions ───────────────────────────────────────────────────

# Discovers extension test scripts for a guest under the extensions/ directory.
# Naming convention:
#   Test-Workload.guest.amazon.linux.ps1               (single test)
#   Test-Workload.guest.amazon.linux.check-ssh.ps1     (named test)
# Returns an array of FileInfo objects, sorted alphabetically.
function Get-GuestTestScripts {
    param([string]$GuestKey, [string]$ExtensionsDir)
    if (-not (Test-Path $ExtensionsDir)) { return @() }
    $prefix   = "Test-Workload.$GuestKey"
    $exact    = Join-Path $ExtensionsDir "$prefix.ps1"
    $extra    = Get-ChildItem -Path $ExtensionsDir -Filter "$prefix.*.ps1" -ErrorAction SilentlyContinue
    $scripts  = @()
    if (Test-Path $exact) { $scripts += Get-Item $exact }
    if ($extra)           { $scripts += @($extra) }
    return @($scripts | Sort-Object Name)
}

# Runs all extension test scripts for a guest.
# Each script is executed as a child process and receives:
#   -HostType, -GuestKey, -VMName
# Returns a hashtable: { success, skipped, errorMessage }
function Invoke-GuestTests {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$ExtensionsDir
    )
    $scripts = Get-GuestTestScripts -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir
    if ($scripts.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    foreach ($s in $scripts) {
        Write-Output "Running test: $($s.Name)"
        & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName
        if ($LASTEXITCODE -ne 0) {
            return @{ success=$false; skipped=$false; errorMessage="Test '$($s.Name)' failed (exit code $LASTEXITCODE)" }
        }
        Write-Output "  $($s.Name): PASS"
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Invoke-StartVM, Confirm-VMStarted, Get-GuestTestScripts, Invoke-GuestTests

<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456750
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
Responsibility split
--------------------
The module separates "is it installed on this machine?" from "is it running
right now?" so the UI and the CLI scripts can reason about each axis
independently.

  Test-SshServerSupported  — does this host type have an implementation?
  Test-SshServerInstalled  — is OpenSSH installed on the local machine?
  Test-SshServerEnabled    — is the sshd service currently Running?

  Install-SshServer        — Add-WindowsCapability + Enable-SshServer (slow).
  Uninstall-SshServer      — Disable-SshServer + Remove-WindowsCapability.
  Enable-SshServer         — Start-Service sshd + StartupType Automatic.
  Disable-SshServer        — Stop-Service sshd  + StartupType Manual.

Install/Uninstall are the heavyweight operations and are wrapped by the CLI
scripts test/Start-SshServer.ps1 and test/Stop-SshServer.ps1. Enable/Disable
are the quick runtime toggles driven by the status-page button; they
presuppose that OpenSSH is already installed (the UI enforces this by
disabling the button otherwise).

Progress output uses Write-Information (stream 6) with
-InformationAction Continue throughout. Callers that capture the return
value via `$null = ...` silence Write-Output (stream 1) but leave stream 6
intact, so the user still sees what's happening during the multi-minute
Add-WindowsCapability call.

macOS/UTM: every function returns $false / is a no-op placeholder. The
Remote Login integration (sysadminctl / defaults) is deferred.
#>


# ── Test-* helpers ──────────────────────────────────────────────────────────

<#
.SYNOPSIS
Reports whether the SSH-server functionality is implemented for the given
host type.

.DESCRIPTION
Returns $false on host.macos.utm (deferred) and on any unknown host.
Does NOT check whether OpenSSH is actually installed or running. It answers
"does the code path exist?", not "is it ready?".
#>
function Test-SshServerSupported {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)
    switch ($HostType) {
        "host.windows.hyper-v" { return $true }
        "host.macos.utm"       { return $false }
        default                { return $false }
    }
}

<#
.SYNOPSIS
Returns $true when OpenSSH Server is installed on the local machine.

.DESCRIPTION
Fast, non-invasive check. On Hyper-V hosts, the presence of the sshd service
proves the OpenSSH.Server Windows capability is installed — which avoids
the 30+ second Get-WindowsCapability -Online query. On any unsupported host
type, returns $false.
#>
function Test-SshServerInstalled {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)
    if (-not (Test-SshServerSupported -HostType $HostType)) { return $false }
    if ($HostType -eq "host.windows.hyper-v") {
        return ($null -ne (Get-Service -Name sshd -ErrorAction SilentlyContinue))
    }
    return $false
}

<#
.SYNOPSIS
Returns $true when the sshd service is currently Running.

.DESCRIPTION
Non-invasive — does not start or install anything. Returns $false when SSH
isn't installed or when the host type is unsupported.
#>
function Test-SshServerEnabled {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)
    if (-not (Test-SshServerInstalled -HostType $HostType)) { return $false }
    if ($HostType -eq "host.windows.hyper-v") {
        try {
            $svc = Get-Service -Name sshd -ErrorAction Stop
            return $svc.Status -eq 'Running'
        } catch { return $false }
    }
    return $false
}


# ── Enable / Disable (runtime service toggle) ───────────────────────────────

<#
.SYNOPSIS
Starts the sshd service and sets it to auto-start on boot.

.DESCRIPTION
Assumes OpenSSH is already installed; returns $false with a clear warning
otherwise. This is the "soft" toggle invoked by the status-page UI button
when the user clicks "Enable SSH Server". To do the full install, use
Install-SshServer (or the test/Start-SshServer.ps1 script).
#>
function Enable-SshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)

    switch ($HostType) {
        "host.windows.hyper-v" { return Enable-WindowsSshServer }
        "host.macos.utm" {
            Write-Information "SSH server enable on host.macos.utm: not yet implemented (placeholder)." -InformationAction Continue
            return $true
        }
        default {
            Write-Warning "Enable-SshServer: unknown host type '$HostType'; skipping."
            return $false
        }
    }
}

function Enable-WindowsSshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Warning "Enable-WindowsSshServer: not running as Administrator — skipping."
        return $false
    }

    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warning "sshd service not installed. Run test/Start-SshServer.ps1 to install OpenSSH Server first."
        return $false
    }

    try {
        if ($svc.Status -ne 'Running') {
            Start-Service -Name sshd -ErrorAction Stop
            Write-Information "sshd service started." -InformationAction Continue
        } else {
            Write-Information "sshd service is already running." -InformationAction Continue
        }
        if ($svc.StartType -ne 'Automatic') {
            Set-Service -Name sshd -StartupType 'Automatic' -ErrorAction Stop
            Write-Information "sshd startup type set to Automatic." -InformationAction Continue
        }
        return $true
    } catch {
        Write-Warning "Failed to start/configure sshd service: $_"
        return $false
    }
}

<#
.SYNOPSIS
Stops the sshd service and sets its startup type to Manual so it won't come
back on boot.

.DESCRIPTION
Inverse of Enable-SshServer. Does NOT uninstall OpenSSH — use
Uninstall-SshServer (or test/Stop-SshServer.ps1) for that. This is the
quick toggle driven by the status-page UI button.
#>
function Disable-SshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)

    switch ($HostType) {
        "host.windows.hyper-v" { return Disable-WindowsSshServer }
        "host.macos.utm" {
            Write-Information "SSH server disable on host.macos.utm: not yet implemented (placeholder)." -InformationAction Continue
            return $true
        }
        default {
            Write-Warning "Disable-SshServer: unknown host type '$HostType'; skipping."
            return $false
        }
    }
}

function Disable-WindowsSshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Warning "Disable-WindowsSshServer: not running as Administrator — skipping."
        return $false
    }

    try {
        $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Information "sshd service is not installed — nothing to disable." -InformationAction Continue
            return $true
        }
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name sshd -ErrorAction Stop
            Write-Information "sshd service stopped." -InformationAction Continue
        } else {
            Write-Information "sshd service is already stopped." -InformationAction Continue
        }
        if ($svc.StartType -ne 'Manual' -and $svc.StartType -ne 'Disabled') {
            Set-Service -Name sshd -StartupType 'Manual' -ErrorAction Stop
            Write-Information "sshd startup type set to Manual (won't auto-start on boot)." -InformationAction Continue
        }
        return $true
    } catch {
        Write-Warning "Failed to stop/configure sshd service: $_"
        return $false
    }
}


# ── Install / Uninstall (heavy operations, CLI-facing) ──────────────────────

<#
.SYNOPSIS
Installs OpenSSH Server and enables it.

.DESCRIPTION
Wraps Add-WindowsCapability (which can take several minutes) plus
Enable-SshServer. Invoked by test/Start-SshServer.ps1. Idempotent — returns
quickly if OpenSSH is already installed.
#>
function Install-SshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)

    switch ($HostType) {
        "host.windows.hyper-v" { return Install-WindowsSshServer }
        "host.macos.utm" {
            Write-Information "SSH server install on host.macos.utm: not yet implemented (placeholder)." -InformationAction Continue
            return $true
        }
        default {
            Write-Warning "Install-SshServer: unknown host type '$HostType'; skipping."
            return $false
        }
    }
}

function Install-WindowsSshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Warning "Install-WindowsSshServer: not running as Administrator — skipping."
        return $false
    }

    # Fast-path: skip Get-WindowsCapability -Online (30+ seconds) when the
    # sshd service is already registered, which guarantees the capability is
    # installed.
    $sshService = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshService) {
        Write-Information "OpenSSH Server already installed (sshd service present)." -InformationAction Continue
    } else {
        try {
            Write-Information "OpenSSH Server not detected. Querying Windows capability store (this can take 30+ seconds)..." -InformationAction Continue
            $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction Stop |
                Select-Object -First 1
            if (-not $cap) {
                Write-Warning "Could not enumerate OpenSSH.Server capability."
                return $false
            }
            if ($cap.State -ne 'Installed') {
                Write-Information "Installing OpenSSH Server capability ($($cap.Name)). This may take SEVERAL MINUTES — please wait..." -InformationAction Continue
                $null = Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                Write-Information "OpenSSH Server capability install complete." -InformationAction Continue
            } else {
                # Rare: capability marked Installed but sshd service missing.
                # Usually transient post-install state.
                Write-Information "OpenSSH Server capability is marked Installed but sshd service is not yet registered." -InformationAction Continue
            }
        } catch {
            Write-Warning "Failed to install OpenSSH Server capability: $_"
            return $false
        }
    }

    # Now start it (Enable-WindowsSshServer handles the service-management
    # half and the firewall-rule audit).
    if (-not (Enable-WindowsSshServer)) { return $false }

    # Verify the firewall rule is present + enabled. Windows normally creates
    # 'OpenSSH-Server-In-TCP' automatically when the capability is added; a
    # missing/disabled rule is a warning, not a fatal error.
    try {
        $rules = Get-NetFirewallRule -Name "*OpenSSH-Server*" -ErrorAction SilentlyContinue
        if (-not $rules) {
            Write-Warning "No OpenSSH-Server firewall rule found. SSH on port 22 may be blocked."
        } else {
            $enabledRules = $rules | Where-Object { $_.Enabled -eq 'True' }
            if (-not $enabledRules) {
                Write-Warning "OpenSSH-Server firewall rule(s) exist but none are enabled."
            } else {
                Write-Information "OpenSSH-Server firewall rule is enabled." -InformationAction Continue
            }
        }
    } catch {
        Write-Warning "Firewall rule check failed: $_"
    }

    return $true
}

<#
.SYNOPSIS
Stops and uninstalls OpenSSH Server.

.DESCRIPTION
Wraps Disable-SshServer (stop sshd) plus Remove-WindowsCapability. Invoked
by test/Stop-SshServer.ps1. Safe to re-run: missing capability is treated
as a no-op. The firewall rule is left in place; Windows cleans it up when
the capability is re-added/removed via DISM.
#>
function Uninstall-SshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)

    switch ($HostType) {
        "host.windows.hyper-v" { return Uninstall-WindowsSshServer }
        "host.macos.utm" {
            Write-Information "SSH server uninstall on host.macos.utm: not yet implemented (placeholder)." -InformationAction Continue
            return $true
        }
        default {
            Write-Warning "Uninstall-SshServer: unknown host type '$HostType'; skipping."
            return $false
        }
    }
}

function Uninstall-WindowsSshServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Warning "Uninstall-WindowsSshServer: not running as Administrator — skipping."
        return $false
    }

    # Best-effort stop first so Remove-WindowsCapability doesn't fight an
    # active service. Disable-WindowsSshServer handles the "not installed"
    # path internally.
    $null = Disable-WindowsSshServer

    try {
        $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction Stop |
            Select-Object -First 1
        if (-not $cap) {
            Write-Information "Could not enumerate OpenSSH.Server capability; nothing to remove." -InformationAction Continue
            return $true
        }
        if ($cap.State -eq 'Installed') {
            Write-Information "Removing OpenSSH Server capability ($($cap.Name)). This may take a minute..." -InformationAction Continue
            $null = Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
            Write-Information "OpenSSH Server capability removed." -InformationAction Continue
        } else {
            Write-Information "OpenSSH Server capability not installed — nothing to remove." -InformationAction Continue
        }
        return $true
    } catch {
        Write-Warning "Failed to remove OpenSSH Server capability: $_"
        return $false
    }
}


Export-ModuleMember -Function `
    Test-SshServerSupported, Test-SshServerInstalled, Test-SshServerEnabled, `
    Enable-SshServer, Disable-SshServer, `
    Install-SshServer, Uninstall-SshServer

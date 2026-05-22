<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456820
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Default host-ssh-server extension: delegates to the active Yuruna.Host
    driver's SSH-server contract (Test-SshServerSupported,
    Test-SshServerInstalled, Start-SshServer, Stop-SshServer,
    Get-SshServerStatus).

.DESCRIPTION
    The host SSH server feature used to live as a UI button in the status
    dashboard. It has moved to a config-driven extension area so that:
      * the operator's intent ("should this host expose SSH this cycle?")
        is declared once in test.config.yml under hostSshServer.enabled
        instead of being toggled out-of-band from a browser tab;
      * a future provider can swap the host-local OpenSSH server for a
        VM-based SSH endpoint (squid-cache style) without any caller
        changes -- the runner only sees the extension's verbs.

    This default provider is the host-local OpenSSH path: it asks the
    Yuruna.Host contract whether SSH is supported on this host type and
    installed, and starts/stops the OS service. Install remains a manual
    one-time step (test/Start-SshServer.ps1) -- the extension reports
    installed=false and ok=false rather than installing on its own.

    Exports three verbs, all returning the same hashtable shape so the
    caller can treat them uniformly:
        @{ supported = $bool   # host driver implements the contract
           installed = $bool   # OpenSSH actually present on this host
           enabled   = $bool   # service currently running
           ok        = $bool   # the operation (or status read) succeeded
           message   = $string # human-readable note when ok = $false }
#>

# === Helpers =================================================================

# Builds the result shape uniformly so callers never have to null-guard
# individual fields. Errors that prevent even probing supported/installed
# come back as ok=$false with the message set.
function Format-SshServerInfo {
    param(
        [bool]$Supported = $false,
        [bool]$Installed = $false,
        [bool]$Enabled   = $false,
        [bool]$Ok        = $true,
        [string]$Message = ''
    )
    return @{
        supported = $Supported
        installed = $Installed
        enabled   = $Enabled
        ok        = $Ok
        message   = $Message
    }
}

# Captures the current host's SSH-server picture from Yuruna.Host. The
# contract functions are imported into the global scope at runner startup
# by Initialize-YurunaHost, so they are reachable by name here. Wrapped
# in try/catch because the driver throws (rather than returns $false) on
# some failure modes (e.g. Get-Service permission denied on Hyper-V).
function Get-SshServerInfoFromHost {
    $supported = $false
    $installed = $false
    $enabled   = $false
    $ok        = $true
    $message   = ''
    try {
        if (Get-Command Test-SshServerSupported -ErrorAction SilentlyContinue) {
            $supported = [bool](Test-SshServerSupported)
        }
        if ($supported -and (Get-Command Test-SshServerInstalled -ErrorAction SilentlyContinue)) {
            $installed = [bool](Test-SshServerInstalled)
        }
        if ($supported -and $installed -and (Get-Command Get-SshServerStatus -ErrorAction SilentlyContinue)) {
            $enabled = ((Get-SshServerStatus) -eq 'running')
        }
    } catch {
        $ok      = $false
        $message = $_.Exception.Message
    }
    return (Format-SshServerInfo -Supported $supported -Installed $installed -Enabled $enabled -Ok $ok -Message $message)
}

# === Public API ==============================================================

<#
.SYNOPSIS
    Returns the current host SSH server state. Pure observation; no side
    effects. Always returns a populated hashtable, never $null.
#>
function Get-SshServerInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return (Get-SshServerInfoFromHost)
}

<#
.SYNOPSIS
    Brings the host SSH server to the "enabled" state via the Yuruna.Host
    driver. Returns the post-operation info hashtable.
.DESCRIPTION
    Short-circuits with ok=$false when the host type does not implement
    SSH server support, or when OpenSSH is not installed. Idempotent on
    the "already running" path: the underlying Start-SshServer call is a
    no-op when the service is already running.
#>
function Enable-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param()
    $info = Get-SshServerInfoFromHost
    if (-not $info.ok) { return $info }
    if (-not $info.supported) {
        return (Format-SshServerInfo -Supported $false -Ok $false -Message 'SSH server toggle not supported on this host.')
    }
    if (-not $info.installed) {
        return (Format-SshServerInfo -Supported $true -Installed $false -Ok $false -Message 'OpenSSH is not installed. Run test/Start-SshServer.ps1 first.')
    }
    if ($info.enabled) { return $info }
    if (-not $PSCmdlet.ShouldProcess('host SSH server', 'Start')) { return $info }
    try {
        $ok = [bool](Start-SshServer -Confirm:$false)
        $post = Get-SshServerInfoFromHost
        if (-not $ok) { $post.ok = $false; $post.message = 'Start-SshServer returned false.' }
        return $post
    } catch {
        return (Format-SshServerInfo -Supported $true -Installed $true -Enabled $false -Ok $false -Message $_.Exception.Message)
    }
}

<#
.SYNOPSIS
    Brings the host SSH server to the "disabled" state via the Yuruna.Host
    driver. Returns the post-operation info hashtable.
.DESCRIPTION
    Idempotent on the "already stopped" path. Reports ok=$false (with the
    underlying message) on driver errors so the caller can log it; does
    not throw.
#>
function Disable-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param()
    $info = Get-SshServerInfoFromHost
    if (-not $info.ok) { return $info }
    if (-not $info.supported) {
        return (Format-SshServerInfo -Supported $false -Ok $false -Message 'SSH server toggle not supported on this host.')
    }
    if (-not $info.installed) {
        return (Format-SshServerInfo -Supported $true -Installed $false -Ok $true -Message 'OpenSSH is not installed; nothing to disable.')
    }
    if (-not $info.enabled) { return $info }
    if (-not $PSCmdlet.ShouldProcess('host SSH server', 'Stop')) { return $info }
    try {
        $ok = [bool](Stop-SshServer -Confirm:$false)
        $post = Get-SshServerInfoFromHost
        if (-not $ok) { $post.ok = $false; $post.message = 'Stop-SshServer returned false.' }
        return $post
    } catch {
        return (Format-SshServerInfo -Supported $true -Installed $true -Enabled $true -Ok $false -Message $_.Exception.Message)
    }
}

Export-ModuleMember -Function Get-SshServerInfo, Enable-SshServer, Disable-SshServer

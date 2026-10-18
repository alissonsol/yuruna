<#PSScriptInfo
.VERSION 2026.10.18
.GUID 428d485e-047b-4cc1-8ed5-93ab18e050f7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna guest seed new-vm shared
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

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking


# See https://yuruna.link/42e220c4-0006

# --- REGION: New-AptProxyBlock
function New-AptProxyBlock {
    <#
    .SYNOPSIS
        Build the autoinstall `apt:` block for the cloud-init seed.
    .DESCRIPTION
        Builds deterministic mirror, proxy, and retry settings.
        See https://yuruna.link/429f3d06-000a for platform mirror selection.
    .OUTPUTS
        [string] the apt block, byte-identical across the three platform scripts.
    #>
    # Pure builder: returns the apt-block text and changes no host/system state,
    # exactly like the shipped pure New-* cmdlets (New-Guid, New-Object,
    # New-TimeSpan), none of which support ShouldProcess. The verb-based rule is a
    # false positive here; adding -WhatIf/-Confirm would misrepresent the function.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure text builder with no state change; New- matches New-Guid/New-Object, which also do not support ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PrimaryUri,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CachingProxyServiceUrl
    )
    $AptProxyLine = if ($CachingProxyServiceUrl) { "`n    proxy: $CachingProxyServiceUrl" } else { "" }
    # --- REGION: https://yuruna.link/42d69dfa-0007
    # The closing "@ must stay on its own line at column 0; inlining $(...)"@
    # raises "The string is missing the terminator" (PowerShell here-string rule).
    return @"
  apt:
    geoip: false
    primary:
      - arches: [default]
        uri: $PrimaryUri$($AptProxyLine)
    conf: |
      Acquire::Retries "2";
      Acquire::http::Timeout "30";
      Acquire::https::Timeout "30";
      Acquire::Languages "none";
"@
}

# --- REGION: New-WindowsGuestBootstrap
function New-WindowsGuestBootstrap {
    <#
    .SYNOPSIS
        Build the Windows guest's seed scripts and compact first-logon launcher.
    .DESCRIPTION
        Builds trusted seed media for host discovery and optional Git credentials.
        See https://yuruna.link/4220a755-002d and https://yuruna.link/42e220c4-0006.
    .PARAMETER RepoRoot
        Absolute path to the repository root; windows-guest-bootstrap.ps1 and
        yuruna-host-locate.ps1 are read from $RepoRoot/automation.
    .PARAMETER StatusServiceIp
        Best-known host address at seed time. A hint; may be empty.
    .PARAMETER StatusServicePort
        The port the host's status service listens on.
    .PARAMETER HostId
        The host's stable hostId. Defaults to $env:YURUNA_RUNTIME_DIR/host.uuid.
    .PARAMETER CachingProxyIp
        The pool directory's address. Defaults to
        $env:YURUNA_CACHING_PROXY_SERVICE_IP. Empty means no directory in this
        lab, and the guest simply keeps the seeded hint.
    .PARAMETER FrameworkUrl
        Configured framework repository URL, retained when the host is unavailable.
    .PARAMETER ProjectUrl
        Configured project repository URL, retained when the host is unavailable.
    .PARAMETER GhToken
        repositories.ghToken, or empty to skip the credential half entirely.
    .OUTPUTS
        [pscustomobject] Files maps seed filenames to script text; EncodedCommand
        is a small UTF-16LE launcher that finds the seed CD at first logon.
    #>
    # Pure builder: returns seed file text and a launcher, and changes no
    # host/system state. Same false positive, and same rationale, as
    # New-AptProxyBlock above.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure text builder with no state change; New- matches New-Guid/New-Object, which also do not support ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][AllowEmptyString()][string]$StatusServiceIp = '',
        [Parameter()][AllowEmptyString()][string]$StatusServicePort = '8080',
        [Parameter()][AllowEmptyString()][string]$HostId = '',
        [Parameter()][AllowEmptyString()][string]$CachingProxyIp = '',
        [Parameter()][AllowEmptyString()][string]$FrameworkUrl = '',
        [Parameter()][AllowEmptyString()][string]$ProjectUrl = '',
        [Parameter()][AllowEmptyString()][string]$GhToken = ''
    )

    # --- REGION: https://yuruna.link/4220a755-002d
    # Ambient defaults, read the same way the cloud-init seeds resolve theirs
    # so a Windows guest and a Linux guest provisioned in one cycle cannot
    # disagree about which host they belong to.
    if ([string]::IsNullOrWhiteSpace($HostId) -and $env:YURUNA_RUNTIME_DIR) {
        $uuidPath = Join-Path $env:YURUNA_RUNTIME_DIR 'host.uuid'
        if (Test-Path -LiteralPath $uuidPath -PathType Leaf) {
            $HostId = ([string](Get-Content -LiteralPath $uuidPath -Raw -ErrorAction SilentlyContinue)).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($CachingProxyIp)) {
        $CachingProxyIp = "$($env:YURUNA_CACHING_PROXY_SERVICE_IP)".Trim()
    }

    # Seeded, never fetched. This script decides WHERE the guest fetches from,
    # so it has to arrive over the same trusted channel as the answer file
    # rather than over the network it exists to repair.
    $locatePath = Join-Path $RepoRoot 'automation' | Join-Path -ChildPath 'yuruna-host-locate.ps1'
    if (-not (Test-Path -LiteralPath $locatePath -PathType Leaf)) {
        throw (Format-YurunaOperatorMessage -Key 'automation.operator_0b62c1c9d3cf7476' -Arguments @{ locatePath = "$locatePath" })
    }

    # The bootstrap body is a FILE, not a here-string here: it needs nested
    # here-strings of its own, and a here-string containing here-strings ends
    # at the first inner terminator at column zero. As a file it also parses
    # and lints like any other script instead of being opaque text.
    $templatePath = Join-Path $RepoRoot 'automation' | Join-Path -ChildPath 'windows-guest-bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw (Format-YurunaOperatorMessage -Key 'automation.operator_fac07c9b40638bff' -Arguments @{ templatePath = "$templatePath" })
    }
    $script = Get-Content -LiteralPath $templatePath -Raw

    # __TOKEN__ and __ASKPASS__ inside the nested $profileText here-string are
    # replaced by the GUEST at run time -- they must survive into the profile
    # as the literal text that script substitutes. So the token is filled in by
    # matching its assignment line specifically, never globally.
    $script = $script.Replace('__STATUS_IP__',   $StatusServiceIp).
                      Replace('__STATUS_PORT__', $StatusServicePort).
                      Replace('__HOST_ID__',     $HostId).
                      Replace('__CACHE_IP__',    $CachingProxyIp).
                      Replace('__FRAMEWORK_URL__', $FrameworkUrl).
                      Replace('__PROJECT_URL__', $ProjectUrl).
                      Replace("`$token = '__TOKEN__'", "`$token = '$GhToken'")

    # Setup's command-line field is small. Keep only CD discovery here; the
    # trusted seed media carries both full scripts, independent of networking.
    $launcher = '$p=@(Get-CimInstance Win32_LogicalDisk -Filter ''DriveType=5''|ForEach-Object{Join-Path $_.DeviceID ''yuruna-bootstrap.ps1''}|Where-Object{Test-Path -LiteralPath $_});if($p.Count-ne 1){throw ''Expected one Yuruna seed CD''};& $p[0]'
    return [pscustomobject]@{
        EncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($launcher))
        Files = [ordered]@{
            'yuruna-bootstrap.ps1' = $script
            'yuruna-host-locate.ps1' = [System.IO.File]::ReadAllText($locatePath)
        }
    }
}

Export-ModuleMember -Function New-AptProxyBlock, New-WindowsGuestBootstrap

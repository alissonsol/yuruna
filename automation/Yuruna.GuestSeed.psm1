<#PSScriptInfo
.VERSION 2026.09.24
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


<#
.SYNOPSIS
    Platform-agnostic guest-seed helpers shared by the three per-guest
    New-VM.ps1 scripts (Hyper-V, KVM, UTM).
.DESCRIPTION
    Each host platform's guest.ubuntu.server.<release>/New-VM.ps1 builds the same
    autoinstall seed from the same inputs, differing only in platform knobs
    (mirror URI, image name, VM-creation calls). A step that is identical across
    all three drifts whenever a fix lands in one copy and not the others -- the
    same duplication class as the shared cloud-init base
    ([[feedback_cache_userdata_three_platforms]]). This module owns such steps
    so a fix lands once.

    Deliberately narrow: only steps whose OUTPUT is byte-identical across the
    three platforms live here. Steps that merely look similar but diverge (the
    password/vault resolution honoring $env:YURUNA_GUEST_PASSWORD only on KVM,
    the caching-proxy-service CA fetch with UTM's VZ-bridge path, the SSH-key load and
    image auto-fetch that differ in import flags / error text, the host-IP
    resolution, and every VM-creation call) stay in the per-guest scripts:
    unifying them would change behavior on the Hyper-V and UTM platforms that the
    KVM-only test pool cannot exercise, which a pure dedup must not risk.
#>

<#
.SYNOPSIS
    Build the autoinstall `apt:` block for the cloud-init seed.
.DESCRIPTION
    Always emits `geoip: false` + a pinned `primary:` mirror (deterministic
    election; `primary:` not `sources_list:`, see
    feedback_macos_utm_apt_block_resolute_curtin_trap.md). When a caching-proxy service
    is configured its `proxy:` line is appended to the `uri:` line with a leading
    newline + 4-space indent so it lands at the same YAML level; with no proxy
    the expansion is empty. -PrimaryUri is the one platform knob (UTM pins the
    aarch64 ports mirror; Hyper-V and KVM resolve it by arch, since
    archive.ubuntu.com carries amd64 only).
.OUTPUTS
    [string] the apt block, byte-identical across the three platform scripts.
#>
function New-AptProxyBlock {
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

<#
.SYNOPSIS
    Build the first-logon bootstrap a Windows guest's answer file runs, as the
    base64 an `-EncodedCommand` slot takes.
.DESCRIPTION
    Establishes the guest's Yuruna coordinates and, when a token is supplied,
    its git credentials. Byte-identical across Hyper-V, UTM and KVM given the
    same inputs, which is what puts it in this module: only the resolution of
    those inputs differs per platform, and that stays in the per-guest scripts.

    The coordinates are split by whether DHCP can invalidate them. A seed ISO
    is burned BEFORE Windows Setup runs, and Setup takes longer than a short
    lease, so an address written into it can already name a host that has
    moved by the time the guest first reads it -- the ordinary outcome on a
    lab whose router hands out 30-minute leases, not an edge case. An address
    cannot be the contract when the medium carrying it outlives its validity.

    What survives is identity: -HostId is permanent across reboots, reimages
    and renumbering, and -CachingProxyIp is pinned by MAC reservation. Those
    are seeded as facts. -StatusServiceIp is seeded as a HINT -- right in the
    common case, cheap to check, and repaired against the pool directory by
    the resolver when it is not.

    The generated script does the coordinate work UNCONDITIONALLY and gates
    only the token work. A guest in a token-free lab is the one that can least
    afford to be left with no coordinates at all.

    The bootstrap body lives in automation/windows-guest-bootstrap.ps1 and is
    read and token-substituted here. It is a file because it needs nested
    here-strings of its own, and a here-string containing here-strings is
    terminated by the first inner `'@` at column zero; building it by escaping
    instead yields a first-logon script whose failures are silent, on a VM
    nobody is watching. As a file it also parses and lints like any other
    script.
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
.PARAMETER GhToken
    repositories.ghToken, or empty to skip the credential half entirely.
.OUTPUTS
    [string] base64 of the UTF-16LE script, for -EncodedCommand.
#>
function New-WindowsGuestBootstrap {
    # Pure builder: returns the bootstrap text as base64 and changes no
    # host/system state. Same false positive, and same rationale, as
    # New-AptProxyBlock above.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure text builder with no state change; New- matches New-Guid/New-Object, which also do not support ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][AllowEmptyString()][string]$StatusServiceIp = '',
        [Parameter()][AllowEmptyString()][string]$StatusServicePort = '8080',
        [Parameter()][AllowEmptyString()][string]$HostId = '',
        [Parameter()][AllowEmptyString()][string]$CachingProxyIp = '',
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
    $locateB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($locatePath))

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
                      Replace('__LOCATE_B64__',  $locateB64).
                      Replace("`$token = '__TOKEN__'", "`$token = '$GhToken'")

    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
}

Export-ModuleMember -Function New-AptProxyBlock, New-WindowsGuestBootstrap

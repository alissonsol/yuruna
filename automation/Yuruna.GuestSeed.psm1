<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42b7c8d9-e0f1-4a23-9b45-6c7d8e9f0a12
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

<#
.SYNOPSIS
    Platform-agnostic guest-seed helpers shared by the three per-guest
    New-VM.ps1 scripts (Hyper-V, KVM, UTM).
.DESCRIPTION
    Each host platform's guest.ubuntu.server.26/New-VM.ps1 builds the same
    autoinstall seed from the same inputs, differing only in platform knobs
    (mirror URI, image name, VM-creation calls). A step that is identical across
    all three drifts whenever a fix lands in one copy and not the others -- the
    same duplication class as the shared cloud-init base
    ([[feedback_cache_userdata_three_platforms]]). This module owns such steps
    so a fix lands once.

    Deliberately narrow: only steps whose OUTPUT is byte-identical across the
    three platforms live here. Steps that merely look similar but diverge (the
    password/vault resolution honoring $env:YURUNA_GUEST_PASSWORD only on KVM,
    the caching-proxy CA fetch with UTM's VZ-bridge path, the SSH-key load and
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
    feedback_macos_utm_apt_block_resolute_curtin_trap.md). When a caching proxy
    is configured its `proxy:` line is appended to the `uri:` line with a leading
    newline + 4-space indent so it lands at the same YAML level; with no proxy
    the expansion is empty. -PrimaryUri is the one platform knob (Hyper-V pins
    archive.ubuntu.com, UTM pins the aarch64 ports mirror, KVM resolves it by
    arch).
.OUTPUTS
    [string] the apt block, byte-identical across the three platform scripts.
#>
function Build-AptProxyBlock {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PrimaryUri,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CachingProxyUrl
    )
    $AptProxyLine = if ($CachingProxyUrl) { "`n    proxy: $CachingProxyUrl" } else { "" }
    # The closing "@ must stay on its own line at column 0; inlining $(...)"@
    # raises "The string is missing the terminator" (PowerShell here-string rule).
    return @"
  apt:
    geoip: false
    primary:
      - arches: [default]
        uri: $PrimaryUri$($AptProxyLine)
    conf: |
      Acquire::Retries "5";
      Acquire::http::Timeout "120";
      Acquire::https::Timeout "120";
"@
}

Export-ModuleMember -Function Build-AptProxyBlock

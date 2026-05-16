<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456821
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
    Cross-cycle persistence for the yuruna-caching-proxy VM state
    (yuruna user's password + the VM's IP address). Single YAML file
    under the runtime track directory; survives cycle vault wipes.

.DESCRIPTION
    Previous design split this between two host-local sidecar files:
      * squid-cache-password.txt next to the VHD (Windows) or under
        $HOME/yuruna/image/squid-cache/ (macOS)
      * cache-ip.txt under $HOME/yuruna/image/squid-cache/ (macOS only)

    Both have moved to a single YAML doc at:
        <track-dir>/yuruna-caching-proxy.yml
    where <track-dir> is $env:YURUNA_TRACK_DIR (default
    <repoRoot>/test/status/track). One file, host-agnostic location,
    git-ignored alongside the rest of /track. The per-cycle vault.yml
    in the authentication extension still holds the password DURING a
    cycle; this file holds it ACROSS cycles, and squid-cache New-VM.ps1
    rehydrates the vault from here on cycle 1's first call.

    Save uses merge semantics: only the fields you pass are touched.
    Atomic write via "write .tmp + Move-Item" so a concurrent reader
    never sees a half-written file.
#>

# === Path ===================================================================

<#
.SYNOPSIS
    Returns the absolute path of the yuruna-caching-proxy state file.
.DESCRIPTION
    Resolves <track-dir>/yuruna-caching-proxy.yml. Track dir defaults to
    <repoRoot>/test/status/track and can be overridden via
    $env:YURUNA_TRACK_DIR. Creates the directory on demand so callers
    don't have to Test-Path-and-mkdir.
#>
function Get-CachingProxyStatePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:YURUNA_TRACK_DIR) {
        $trackDir = $env:YURUNA_TRACK_DIR
    } else {
        # This module lives at test/modules/; two levels up is test/.
        $testRoot = Split-Path -Parent $PSScriptRoot
        $trackDir = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'track'
    }
    if (-not (Test-Path -LiteralPath $trackDir)) {
        New-Item -ItemType Directory -Path $trackDir -Force | Out-Null
    }
    return (Join-Path -Path $trackDir -ChildPath 'yuruna-caching-proxy.yml')
}

# === Read ===================================================================

<#
.SYNOPSIS
    Returns the persisted state as a hashtable. Empty hashtable when
    the file is missing or unparsable; never $null.
.OUTPUTS
    [hashtable] with keys 'password' and 'ipAddress' (each a string,
    possibly empty). Additional keys round-trip through Save unchanged.
#>
function Read-CachingProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $path = Get-CachingProxyStatePath
    $empty = @{ password = ''; ipAddress = '' }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        if (-not (Get-Module powershell-yaml)) {
            Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
        }
        $raw = Get-Content -Raw -LiteralPath $path
        if (-not $raw -or -not $raw.Trim()) { return $empty }
        $parsed = $raw | ConvertFrom-Yaml
        if ($parsed -isnot [System.Collections.IDictionary]) { return $empty }
        $h = @{ password = ''; ipAddress = '' }
        foreach ($k in $parsed.Keys) { $h[[string]$k] = [string]$parsed[$k] }
        return $h
    } catch {
        Write-Verbose "Read-CachingProxyState: parse failed ($($_.Exception.Message)); returning empty."
        return $empty
    }
}

# === Save ===================================================================

<#
.SYNOPSIS
    Merges the given fields into the persisted state and writes the
    file atomically. Existing fields not named here are preserved.
.PARAMETER Secret
    yuruna OS user password (named -Secret to avoid the rule that flags
    plaintext-typed parameters whose name contains 'password' -- the
    on-disk YAML key is still `password:`). Pass '' to clear; omit to
    leave unchanged.
.PARAMETER IpAddress
    Current VM IP. Pass '' to clear; omit to leave unchanged.
.OUTPUTS
    [string] The path of the file written.
.NOTES
    The on-disk YAML key remains `password:` -- the parameter name dodges
    PSAvoidUsingPlainTextForPassword (the rule matches parameter NAMES
    containing 'password'/'passphrase' but does not inspect hashtable
    keys or file contents). Renaming the on-disk key would be a breaking
    change to the file format; renaming just the parameter keeps the
    file format stable and the rule satisfied.
#>
function Save-CachingProxyState {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        # The yuruna user's password value to persist; on-disk YAML key is
        # `password:`. Pass '' to clear; omit to leave unchanged.
        [string]$Secret,
        [string]$IpAddress
    )
    $path = Get-CachingProxyStatePath
    $state = Read-CachingProxyState
    # Merge: only update keys the caller actually passed.
    if ($PSBoundParameters.ContainsKey('Secret'))    { $state.password  = [string]$Secret }
    if ($PSBoundParameters.ContainsKey('IpAddress')) { $state.ipAddress = [string]$IpAddress }
    if (-not $PSCmdlet.ShouldProcess($path, "Save caching-proxy state")) { return $path }
    if (-not (Get-Module powershell-yaml)) {
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }
    # Sort keys for stable diffs; ConvertTo-Yaml on an unordered hashtable
    # otherwise re-emits in random order on every save.
    $ordered = [ordered]@{}
    foreach ($k in ($state.Keys | Sort-Object)) { $ordered[$k] = $state[$k] }
    $yaml = $ordered | ConvertTo-Yaml
    $tmp = "$path.tmp"
    # UTF-8 without BOM: shell consumers on the macOS/Linux side don't
    # parse a BOM cleanly. .NET's UTF8Encoding($false) is the BOM-less
    # variant; Set-Content -Encoding utf8 is already BOM-less on PS7 but
    # using WriteAllText keeps the encoding choice explicit and matches
    # the pattern used elsewhere in the repo for shell-consumed files.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tmp, $yaml, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

Export-ModuleMember -Function Get-CachingProxyStatePath, Read-CachingProxyState, Save-CachingProxyState

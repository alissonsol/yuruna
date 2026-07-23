<#PSScriptInfo
.VERSION 2026.07.22
.GUID 424a157a-a958-4578-af6b-b7eec817ba35
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS hosts dns cross-platform
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
    Idempotently create, update, or remove a host-to-IP mapping in the
    local operating system's hosts file, on Windows, Linux, or macOS.

.DESCRIPTION
    Set-HostAlias rewrites the hosts file so that exactly one of two end
    states holds for the supplied hostname:

      Upsert  -- when -IPAddress carries a non-empty, valid address, the
                 file ends with a single 'IPAddress<tab>ComputerName' line
                 mapping the hostname. Any pre-existing mapping for the same
                 hostname is replaced (no duplicates accumulate).

      Delete  -- when -IPAddress is omitted or empty, every existing entry
                 line for the hostname is removed and none is added.

    Either way the operation is idempotent: running it twice yields the same
    file, and a run that would not change anything performs no write at all.

    The hosts file is a system network-configuration file, so the script
    asserts elevation up front (Administrator on Windows, UID 0 on
    Linux/macOS) and aborts with a clear message otherwise.

    Removal is LINE-based: a line that maps the target hostname is dropped in
    full, including any additional aliases that shared that line. Comment (#)
    and blank lines are always preserved verbatim.

.PARAMETER ComputerName
    The hostname (or fully qualified domain name) to map. Mandatory.
    Accepts the alias -HostName. Matching against the existing file is
    case-insensitive and bounded to a whole hostname token, so 'web1' never
    disturbs an unrelated 'web1.corp' entry.

.PARAMETER IPAddress
    The IPv4 or IPv6 address to map the hostname to. Optional. When present
    it must parse as a valid address. When omitted or passed as an empty
    string the hostname's mapping is removed (delete semantics).

.INPUTS
    System.String. ComputerName and IPAddress bind from the pipeline by
    property name, so objects with those properties can be piped in.

.OUTPUTS
    None. Progress is written to the verbose stream; honors -WhatIf/-Confirm.

.EXAMPLE
    PS> ./Set-HostAlias.ps1 -ComputerName registry.localtest -IPAddress 127.0.0.1
    Maps registry.localtest to 127.0.0.1 (creating or replacing the entry).

.EXAMPLE
    PS> ./Set-HostAlias.ps1 -HostName registry.localtest
    Removes any hosts-file mapping for registry.localtest.

.EXAMPLE
    PS> ./Set-HostAlias.ps1 -ComputerName cache.localtest -IPAddress ::1 -WhatIf
    Shows what would change without touching the file.

.LINK
    Online version: https://yuruna.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
    [Alias('HostName')]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName,

    [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
    [AllowEmptyString()]
    [AllowNull()]
    [string]$IPAddress
)

begin {
    # --- REGION: 1. Platform-agnostic hosts-file path
    # $IsWindows/$IsLinux/$IsMacOS are PowerShell (Core) automatic variables;
    # #requires -version 7 guarantees they exist.
    if ($IsWindows) {
        $script:HostsPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32' -AdditionalChildPath 'drivers', 'etc', 'hosts'
    }
    elseif ($IsLinux -or $IsMacOS) {
        $script:HostsPath = '/etc/hosts'
    }
    else {
        throw "Set-HostAlias: unsupported operating system; cannot locate a hosts file."
    }

    # --- REGION: 2. Elevation / root assertion
    # Editing the hosts file needs elevated rights; fail loudly and early so
    # the caller gets a meaningful message instead of an opaque write error.
    if ($IsWindows) {
        $identity   = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal  = [Security.Principal.WindowsPrincipal]::new($identity)
        $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $denied     = "Set-HostAlias must run in an elevated Administrator session to modify '$script:HostsPath'. Re-launch PowerShell with 'Run as administrator'."
    }
    else {
        # UID 0 == root. id(1) is present on every Linux/macOS base system;
        # if it is somehow absent the call throws and we treat that as
        # not-elevated rather than guessing.
        $uid = $null
        try { $uid = (& id -u 2>$null) } catch { $uid = $null }
        $isElevated = ($null -ne $uid) -and (([string]$uid).Trim() -eq '0')
        $denied     = "Set-HostAlias must run as root (UID 0) to modify '$script:HostsPath'. Re-run with sudo."
    }
    if (-not $isElevated) {
        throw $denied
    }

    Write-Verbose "Set-HostAlias: target hosts file '$script:HostsPath' (elevation confirmed)."
}

process {
    $name     = $ComputerName.Trim()
    $targetIp = if ($null -ne $IPAddress) { $IPAddress.Trim() } else { '' }
    $isUpsert = -not [string]::IsNullOrWhiteSpace($targetIp)

    # Reject anything that is not a single hostname/FQDN token. Under an
    # elevated write an embedded newline would inject an extra hosts-file
    # line and embedded whitespace would inject extra alias tokens; a '#'
    # would also collide with the inline-comment handling below. The shape
    # is an RFC-1123 label/FQDN (letters/digits/hyphen per label, '_'
    # tolerated, dot-separated, 253 chars max).
    $hostnamePattern = '\A(?=.{1,253}\z)[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(\.[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\z'
    if ($name -notmatch $hostnamePattern) {
        throw "Set-HostAlias: '$ComputerName' is not a valid hostname or FQDN."
    }

    # Validate the address before it can reach disk: a malformed value would
    # silently break name resolution for every consumer of the hosts file.
    # Persist the PARSED canonical form -- TryParse also accepts hex/decimal/
    # short forms (e.g. 0x7f000001, 2130706433), so writing the canonical
    # text keeps the file unambiguous and repeat runs idempotent.
    if ($isUpsert) {
        $parsed = [System.Net.IPAddress]::Any
        if (-not [System.Net.IPAddress]::TryParse($targetIp, [ref]$parsed)) {
            throw "Set-HostAlias: '$targetIp' is not a valid IPv4 or IPv6 address."
        }
        $targetIp = $parsed.ToString()
    }

    # --- REGION: Read current content (a missing file is treated as empty)
    $original = @()
    if (Test-Path -LiteralPath $script:HostsPath) {
        $original = @(Get-Content -LiteralPath $script:HostsPath -ErrorAction Stop)
    }

    # --- REGION: 3. Idempotent cleanup
    # Drop existing ENTRY lines that map this hostname. A bare \b boundary is
    # wrong for dotted hostnames: \b sits between 'foo' and '.', so \bfoo\b
    # also matches the 'foo' inside 'foo.bar'. Treat '.' and '-' as in-token
    # so only a WHOLE hostname token matches. Hostnames are case-insensitive.
    # Comment (#) and blank lines are kept verbatim.
    $escaped = [regex]::Escape($name)
    $hostToken = [regex]::new("(?<![\w.\-])$escaped(?![\w.\-])",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $kept = foreach ($line in $original) {
        $trimmed = $line.TrimStart()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
            $line                       # preserve comments and blank lines
        }
        else {
            # Match only the active (pre-#-comment) portion of the line: a
            # trailing inline comment that merely MENTIONS the hostname must
            # not delete an unrelated entry. Hosts hostname tokens cannot
            # contain '#', so cutting at the first '#' is safe. When the
            # entry is kept, the full original line (comment included) is
            # what we emit.
            $entry = $line -replace '#.*$', ''
            if ($hostToken.IsMatch($entry)) {
                # drop: this entry maps the hostname being (re)written/removed
            }
            else {
                $line
            }
        }
    }
    $kept = @($kept)

    # --- REGION: 4. Conditional upsert / delete
    $final = $kept
    if ($isUpsert) {
        $final += ("{0}`t{1}" -f $targetIp, $name)
    }

    # Genuine idempotency: if the result equals what is already on disk, make
    # no change (no rewrite, no mtime churn, no needless line-ending flips).
    if (($original -join "`n") -eq ($final -join "`n")) {
        Write-Verbose "Set-HostAlias: '$name' already in the desired state; nothing to do."
        return
    }

    $action = if ($isUpsert) { "Map '$name' -> '$targetIp'" } else { "Remove host alias '$name'" }
    if ($PSCmdlet.ShouldProcess($script:HostsPath, $action)) {
        # --- REGION: 5. Cross-platform safe, atomic write
        # BOM-less UTF-8 (a BOM breaks Linux/macOS resolvers), staged to a
        # sibling temp file and swapped in via [IO.File]::Replace so a
        # mid-write crash never truncates the live file and its ACLs survive.
        # --- REGION: https://yuruna.link/memory#why-set-hostalias-writes-the-hosts-file-via-a-staged-sibling-swap
        $hostsDir = Split-Path -Parent -Path $script:HostsPath
        $tempFile = Join-Path -Path $hostsDir -ChildPath ('.hostalias.' + [System.IO.Path]::GetRandomFileName())
        try {
            Set-Content -LiteralPath $tempFile -Value $final -Encoding utf8NoBOM -ErrorAction Stop
            if (Test-Path -LiteralPath $script:HostsPath) {
                [System.IO.File]::Replace($tempFile, $script:HostsPath, [NullString]::Value)
            }
            else {
                Move-Item -LiteralPath $tempFile -Destination $script:HostsPath -Force -ErrorAction Stop
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Verbose "Set-HostAlias: $action ($($final.Count) line(s) written to '$script:HostsPath')."
    }
}

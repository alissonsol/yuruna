<#PSScriptInfo
.VERSION 2026.10.11
.GUID 428d03de-5680-40f0-8f54-b0a9cc822c77
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# --- REGION: Digest extension
# See https://yuruna.link/42e220c4-0013
function Get-DigestRepoRoot {
    <#
    .SYNOPSIS
        The framework checkout root: the base the status service serves at
        /yuruna-repo, three levels above this module (test/extension/digest/).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function ConvertTo-HexDigest {
    <#
    .SYNOPSIS
        Lowercase hexadecimal form of a hash, the spelling sha256sum prints
        and a guest compares against.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Hash)
    return [Convert]::ToHexString($Hash).ToLowerInvariant()
}

function Get-FileSha256 {
    <#
    .SYNOPSIS
        SHA-256 of a file under the framework checkout, for
        ${ext:digest.GetFileSha256(<path>)}.
    .DESCRIPTION
        The path is relative to the checkout root, the same base the status
        service serves at /yuruna-repo and fetch-and-execute hashes its payload
        from, so the digest is of the bytes a guest receives from
        /yuruna-repo/<path>: the working-tree file, byte for byte, line endings
        included.

        Only a plain relative path is accepted. A rooted path, a '..' segment, a
        wildcard or a colon (a drive, or an NTFS stream) is refused: the value
        ends up in a command line a guest trusts, so it must name exactly one
        file inside the checkout.
    .PARAMETER Path
        Checkout-relative path, '/' or '\' separated.
    .PARAMETER RepoRoot
        Checkout root to resolve against. Defaults to this checkout; a test
        points it at a fixture tree.
    .OUTPUTS
        [string] 64 lowercase hex characters, or '' (with a warning) when the
        path is not acceptable or names no file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string]$RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-DigestRepoRoot }
    $relative = $Path.Trim().Replace('\', '/')
    if ($relative -eq '' -or [IO.Path]::IsPathRooted($relative) -or $relative.StartsWith('/') -or
        $relative -match '(^|/)\.\.?(/|$)' -or $relative -match '[*?\[\]:]') {
        Write-Warning "digest.GetFileSha256: '$Path' is not a plain path relative to the checkout root (no leading slash, '..', wildcard or colon)."
        return ''
    }
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
        Write-Warning "digest.GetFileSha256: '$Path' resolves outside the checkout."
        return ''
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Write-Warning "digest.GetFileSha256: '$Path' is not a file in the checkout ($root); the guest could not download it either."
        return ''
    }
    try {
        return (ConvertTo-HexDigest -Hash ([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($full))))
    } catch {
        Write-Warning "digest.GetFileSha256: reading '$Path' failed: $($_.Exception.Message)"
        return ''
    }
}

function Get-StatusServiceLoopbackUrl {
    <#
    .SYNOPSIS
        Base URL of THIS host's status service on the loopback interface.
    .DESCRIPTION
        The port is test.config.yml's statusService.port (8080 when unset), the
        value the service itself binds. The loopback address is used instead of
        a LAN address because the service always answers on it and the question
        asked here ("what do you serve?") has the same answer from anywhere.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $port = 8080
    try {
        $repoRoot = Get-DigestRepoRoot
        if (-not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1') -Global -DisableNameChecking -Verbose:$false
        }
        $configPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } else { Join-Path $repoRoot 'test/test.config.yml' }
        if (Test-Path -LiteralPath $configPath) {
            $configured = Get-TestConfigValue -Config (Read-TestConfig -Path $configPath) -Path 'statusService.port'
            if ($configured -and [int]::TryParse([string]$configured, [ref]$null)) { $port = [int]$configured }
        }
    } catch {
        Write-Verbose "digest: the configured status port is unreadable, using $port ($($_.Exception.Message))."
    }
    return "http://127.0.0.1:$port"
}

function Get-ArchiveSha256 {
    <#
    .SYNOPSIS
        SHA-256 of the committed-content tarball the status service serves, for
        ${ext:digest.GetArchiveSha256(project)}.
    .DESCRIPTION
        The tarball is cut on demand from the clone's HEAD (git archive), so
        there is no file on disk to hash. This asks the status service itself
        for it over loopback and hashes the bytes it answers with. A digest
        means something only if the bytes hashed are the bytes served, and
        asking the server removes the possibility of a second, drifting
        implementation of how the tarball is cut.

        The server keeps what it cut, keyed by commit, and a re-cut is
        byte-identical for the same commit: tar entries carry the commit time
        and fixed ownership and the gzip header carries no timestamp (the
        status-service archive suite holds that property). So the guest's
        later download gets the bytes hashed here for as long as the clone's
        HEAD is the commit that was hashed. If HEAD moves in between, the
        guest's digest check refuses the download; the step is re-run to
        re-hash.
    .PARAMETER Name
        'project' for /yuruna-project-archive.tar.gz (the project clone's HEAD)
        or 'framework' for /yuruna-archive.tar.gz (this checkout's HEAD).
    .PARAMETER BaseUrl
        Status service base URL. Defaults to this host's, on loopback.
    .PARAMETER TimeoutSeconds
        Per-attempt deadline for the request.
    .PARAMETER Attempts
        Tries before giving up on a transport failure. A status that says no
        (404, 500) is final and not retried.
    .OUTPUTS
        [string] 64 lowercase hex characters, or '' (with a warning) when the
        archive could not be obtained.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [string]$BaseUrl,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
        [ValidateRange(1, 10)][int]$Attempts = 3
    )
    $route = switch ($Name.Trim()) {
        'project'   { 'yuruna-project-archive.tar.gz' }
        'framework' { 'yuruna-archive.tar.gz' }
        default     { $null }
    }
    if (-not $route) {
        Write-Warning "digest.GetArchiveSha256: '$Name' is not an archive name; use 'project' or 'framework'."
        return ''
    }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = Get-StatusServiceLoopbackUrl }
    $uri = $BaseUrl.TrimEnd('/') + '/' + $route
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try {
        $lastReason = ''
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                $response = $client.GetAsync($uri).GetAwaiter().GetResult()
                try {
                    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    if (-not $response.IsSuccessStatusCode) {
                        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min($bytes.Length, 200)).Trim()
                        Write-Warning "digest.GetArchiveSha256: $uri answered $([int]$response.StatusCode): $text"
                        return ''
                    }
                } finally { $response.Dispose() }
                if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x1F -or $bytes[1] -ne 0x8B) {
                    Write-Warning "digest.GetArchiveSha256: $uri answered $($bytes.Length) bytes that are not a gzip stream."
                    return ''
                }
                return (ConvertTo-HexDigest -Hash ([Security.Cryptography.SHA256]::HashData($bytes)))
            } catch {
                $lastReason = $_.Exception.Message
                if ($_.Exception.InnerException) { $lastReason = $_.Exception.InnerException.Message }
                if ($attempt -lt $Attempts) { Start-Sleep -Seconds 2 }
            }
        }
        Write-Warning "digest.GetArchiveSha256: $uri could not be fetched after $Attempts attempt(s): $lastReason. The status service must be running on this host; it serves the same bytes to the guest."
        return ''
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-DigestPublicationPath {
    <#
    .SYNOPSIS
        Where the digest published under a name lives:
        <runtime-dir>/digest/<name>.json.
    .DESCRIPTION
        The runtime directory is $env:YURUNA_RUNTIME_DIR, defaulting to
        test/status/runtime beside the other per-host sidecar state (the same
        place stash-host.txt is published). Everything there is gitignored.
        The file is public by design: a digest is not a secret, and the status
        service never accepts a write into this directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "digest: '$Name' is not a publishable name (letters, digits, '.', '_' and '-'; at most 64 characters)."
    }
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) {
        $runtimeDir = Join-Path (Get-DigestRepoRoot) 'test/status/runtime'
    }
    return (Join-Path (Join-Path $runtimeDir 'digest') "$Name.json")
}

function Publish-GuestFileSha256 {
    <#
    .SYNOPSIS
        Records the SHA-256 of a file inside a guest, read over the harness SSH
        channel, for later steps to carry to another guest. Meant for a
        callExtension step.
    .DESCRIPTION
        An artifact one guest produces and another guest later downloads (the
        build VM's binaries, the core VM's deploy) has no copy on the host to
        hash. The authoritative digest is the producing guest's own, so the host
        asks it, over the same authenticated channel it already drives that
        guest with, right after the step that produced the file; consumers read
        it back with ${ext:digest.GetPublishedSha256(<name>)} in their launch
        command. Whatever the transport between the two guests does to the
        bytes (a stash that was tampered with, a truncated upload), the
        consumer's check against this digest catches it.

        Re-publishing a name replaces its record. A failed read leaves the
        previous record untouched, so a stale value is never mistaken for the
        new artifact's: the step fails instead.
    .PARAMETER Name
        Publication name, e.g. 'amisad-binaries'.
    .PARAMETER VMName
        VM to read from.
    .PARAMETER Path
        Absolute path of the file inside the guest. One '*' is allowed, to
        name a file whose name carries something only the guest knows (its
        architecture); the glob must match exactly one file.
    .PARAMETER User
        Guest login user. Empty keeps the harness's lookup for the guest key.
    .PARAMETER GuestKey
        Guest key, used only for the login user lookup when -User is empty.
    .PARAMETER TimeoutSeconds
        Deadline for the SSH command.
    .OUTPUTS
        [string] the published digest. Throws when the guest cannot be read or
        does not answer with exactly one digest.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Path,
        [string]$User = '',
        [string]$GuestKey = '',
        [ValidateRange(5, 900)][int]$TimeoutSeconds = 120
    )
    $target = Get-DigestPublicationPath -Name $Name
    if ($Path -cnotmatch '^/[A-Za-z0-9._+/*-]+$' -or $Path -match '(^|/)\.\.?(/|$)' -or ([regex]::Matches($Path, '\*').Count -gt 1)) {
        throw "digest: '$Path' is not an acceptable guest path (absolute, letters, digits and . _ + - /, at most one '*', no '..')."
    }
    if ($VMName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') {
        throw "digest: '$VMName' is not an acceptable VM name or address."
    }
    # The login user becomes the left side of user@host on the ssh command line,
    # where a leading '-' would be read as an option, not a name.
    if (($User -and $User -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') -or $GuestKey -cnotmatch '^[A-Za-z0-9._-]*$') {
        throw "digest: the login user '$User' or guest key '$GuestKey' is not an acceptable name."
    }
    if (-not (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path (Get-DigestRepoRoot) 'test/modules/Test.Ssh.psm1') -Global -DisableNameChecking -Verbose:$false
    }
    $result = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -User $User -Command "sha256sum -- $Path" -TimeoutSeconds $TimeoutSeconds
    if (-not $result.success) {
        throw "digest: reading the digest of '$Path' on $VMName failed (exit $($result.exitCode)): $($result.output)"
    }
    $lines = @(([string]$result.output) -split "`r?`n" | Where-Object { $_.Trim() })
    $found = @($lines | ForEach-Object { [regex]::Match($_, '^([0-9a-fA-F]{64})\s+\*?(\S.*)$') } | Where-Object { $_.Success })
    if ($lines.Count -ne 1 -or $found.Count -ne 1) {
        throw "digest: expected exactly one file for '$Path' on $VMName, got: $($lines -join ' | ')"
    }
    $digest = $found[0].Groups[1].Value.ToLowerInvariant()
    if (-not $PSCmdlet.ShouldProcess($target, "Publish sha256 $digest for '$Name'")) { return '' }
    $record = [ordered]@{
        name         = $Name
        sha256       = $digest
        source       = "${VMName}:$($found[0].Groups[2].Value.Trim())"
        publishedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
    $temporary = "$target.tmp"
    Set-Content -LiteralPath $temporary -Value (ConvertTo-Json -InputObject $record) -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $target -Force
    Write-Information "digest: published sha256 $digest as '$Name' (read from $($record.source))." -InformationAction Continue
    return $digest
}

function Get-PublishedSha256 {
    <#
    .SYNOPSIS
        The digest published under a name, for
        ${ext:digest.GetPublishedSha256(<name>)}.
    .PARAMETER Name
        Publication name given to Publish-GuestFileSha256.
    .OUTPUTS
        [string] 64 lowercase hex characters, or '' (with a warning) when
        nothing valid is published under the name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    try {
        $path = Get-DigestPublicationPath -Name $Name.Trim()
    } catch {
        Write-Warning "digest.GetPublishedSha256: $($_.Exception.Message)"
        return ''
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Warning "digest.GetPublishedSha256: nothing is published as '$Name' ($path); the step that produces the artifact has to run first."
        return ''
    }
    try {
        $record = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $digest = ([string]$record.sha256).ToLowerInvariant()
        if ($digest -cmatch '^[0-9a-f]{64}$') { return $digest }
        Write-Warning "digest.GetPublishedSha256: the record for '$Name' holds no valid SHA-256 ($path)."
    } catch {
        Write-Warning "digest.GetPublishedSha256: the record for '$Name' is unreadable ($path): $($_.Exception.Message)"
    }
    return ''
}

Export-ModuleMember -Function Get-FileSha256, Get-ArchiveSha256, Get-PublishedSha256, Publish-GuestFileSha256

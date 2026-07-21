<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42c9d0e1-b3a4-4f56-9b67-78c2e3f4d5a6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna cloud-init template overlay
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

# Get-YurunaGitHubSource: which repository/commit this host serves, and the token
# that opens it. New-CloudInitUserData bakes those into every guest seed.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.GitHubSource.psm1') -Force -DisableNameChecking

<#
.SYNOPSIS
    Merge a shared cloud-init user-data base file with a per-host overlay.
.DESCRIPTION
    Three host platforms (Hyper-V, KVM, UTM) otherwise need three
    near-identical autoinstall user-data files per guest, which drift
    whenever a fix lands in one copy and not the others
    ([[feedback_cache_userdata_three_platforms]]). This module shares one
    base file across hosts and applies a per-host overlay at New-VM time.

    The substitution is line-based (not YAML deep-merge) so comments and
    indentation -- which the autoinstall installer relies on for readability
    when uploading via error-commands -- survive a round-trip. The base
    file embeds anchor lines that are YAML comments, so the base file
    itself remains a valid cloud-init template (it round-trips through a
    YAML parser, ignoring the anchor comments) and CI can syntax-check it
    in isolation.

    Anchor contract: each anchor line in the base file looks like
    `# === YURUNA_OVERLAY_<NAME> ===` (case-sensitive ASCII). The overlay
    file uses the same line format as section headers; the lines between
    one header and the next (or end-of-file) are the substitution payload
    for that anchor. An empty payload deletes the anchor line outright.
    Anchors not represented in the overlay are a hard error -- a silent
    miss would let a removed anchor leak the literal marker into the
    final user-data and confuse cloud-init.
#>

function Read-OverlaySection {
    <#
    .SYNOPSIS
        Parse an overlay file into an ordered hashtable of anchor name -> lines.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Section is a kind of object (overlay-section dict); the parsed result is one dict, not a collection.')]
    param(
        [Parameter(Mandatory)][string]$OverlayPath
    )
    if (-not (Test-Path -LiteralPath $OverlayPath)) {
        throw "Overlay file not found: $OverlayPath"
    }
    $sections   = [ordered]@{}
    $currentKey = $null
    $current    = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $OverlayPath)) {
        if ($line -match '^\s*#\s*===\s*YURUNA_OVERLAY_([A-Z0-9_]+)\s*===\s*$') {
            if ($null -ne $currentKey) {
                $sections[$currentKey] = $current.ToArray()
            }
            $currentKey = $Matches[1]
            # A repeated header would silently overwrite the earlier payload (and the merge-time
            # consumed/orphan validation cannot see the loss); fail loudly instead.
            if ($sections.Contains($currentKey)) {
                throw "Duplicate overlay section '$currentKey' in ${OverlayPath}: a repeated header would silently overwrite the earlier payload."
            }
            $current    = New-Object System.Collections.Generic.List[string]
            continue
        }
        if ($null -ne $currentKey) {
            $current.Add($line)
        }
    }
    if ($null -ne $currentKey) {
        $sections[$currentKey] = $current.ToArray()
    }
    return $sections
}

function Merge-CloudInitUserData {
    <#
    .SYNOPSIS
        Render a cloud-init user-data file from a shared base + per-host overlay.
    .DESCRIPTION
        Walks the base file line by line. Each line matching the anchor
        pattern is replaced with the corresponding section from the
        overlay file. All other lines pass through unchanged.
    .PARAMETER BasePath
        Absolute path to the shared base user-data template.
    .PARAMETER OverlayPath
        Absolute path to the per-host overlay file.
    .PARAMETER OutputPath
        Optional. When set, write the merged result here (UTF-8 without
        BOM, LF line endings -- cloud-init parses LF reliably across
        UTM/KVM/Hyper-V seed mounts).
    .OUTPUTS
        [string] The merged user-data content. When -OutputPath is set,
        the same string is also written to disk.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'ShouldProcess gates the on-disk write; the in-memory merge is side-effect free and always returns the string.')]
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$OverlayPath,
        [string]$OutputPath
    )
    if (-not (Test-Path -LiteralPath $BasePath)) {
        throw "Base user-data file not found: $BasePath"
    }
    $sections     = Read-OverlaySection -OverlayPath $OverlayPath
    $baseLines    = Get-Content -LiteralPath $BasePath
    $result       = New-Object System.Collections.Generic.List[string]
    $anchorRegex  = '^\s*#\s*===\s*YURUNA_OVERLAY_([A-Z0-9_]+)\s*===\s*$'
    $consumed     = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $baseLines) {
        if ($line -match $anchorRegex) {
            $key = $Matches[1]
            if (-not $sections.Contains($key)) {
                throw "Base file '$BasePath' anchors YURUNA_OVERLAY_$key but overlay '$OverlayPath' does not define this section."
            }
            foreach ($payloadLine in $sections[$key]) {
                $result.Add($payloadLine)
            }
            [void]$consumed.Add($key)
            continue
        }
        $result.Add($line)
    }
    # Overlay-only keys (defined in the overlay but never referenced by
    # the base) are almost always typos -- catch them at merge time so a
    # silent miss does not ship a guest install that the operator thinks
    # is host-tuned but is actually running on the base.
    $orphan = @($sections.Keys | Where-Object { -not $consumed.Contains($_) })
    if ($orphan.Count -gt 0) {
        throw "Overlay '$OverlayPath' defines section(s) the base never anchors: $($orphan -join ', '). Remove them or add the matching anchor to the base."
    }
    # Cloud-init reads YAML; LF terminators are universally portable.
    # \r\n is tolerated by cloud-init >= 22 but trips older guests on
    # CR-sensitive shell heredocs in the rendered late-commands.
    $merged = ($result -join "`n") + "`n"
    if ($OutputPath) {
        if ($PSCmdlet.ShouldProcess($OutputPath, 'Write merged cloud-init user-data')) {
            [System.IO.File]::WriteAllText($OutputPath, $merged, [System.Text.UTF8Encoding]::new($false))
        }
    }
    return $merged
}

function Get-YurunaGuestScriptBase64 {
    <#
    .SYNOPSIS
        Read the guest-side shell scripts every cloud-init seed bakes in via
        base64 -- yuruna-retry.sh, yuruna-versions.sh, fetch-and-execute.sh,
        and yuruna-network.sh -- and return them as a hashtable keyed by purpose.
    .DESCRIPTION
        Centralises the `[Convert]::ToBase64String([File]::ReadAllBytes(...))`
        read otherwise duplicated across all six New-VM.ps1 scripts
        (3 platforms x {24, 26}) for the same files, so the eventual
        swap to a signed-bundle distribution (or another guest-side
        script) is one edit.
    .PARAMETER RepoRoot
        Absolute path to the repository root. The scripts live under
        $RepoRoot/automation/.
    .OUTPUTS
        [hashtable] @{ RetryLib = '<base64>'; VersionsLib = '<base64>'; FetchAndExecute = '<base64>'; NetworkLib = '<base64>' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $automationDir = Join-Path $RepoRoot 'automation'
    $retryPath     = Join-Path $automationDir 'yuruna-retry.sh'
    $versionsPath  = Join-Path $automationDir 'yuruna-versions.sh'
    $faePath       = Join-Path $automationDir 'fetch-and-execute.sh'
    $networkPath   = Join-Path $automationDir 'yuruna-network.sh'
    foreach ($p in @($retryPath, $versionsPath, $faePath, $networkPath)) {
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Get-YurunaGuestScriptBase64: required guest script missing: $p"
        }
    }
    return @{
        RetryLib        = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($retryPath))
        VersionsLib     = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($versionsPath))
        FetchAndExecute = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($faePath))
        NetworkLib      = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($networkPath))
    }
}

function Resolve-CloudInitPlaceholder {
    <#
    .SYNOPSIS
        Substitute every `<NAME>_PLACEHOLDER` token in a cloud-init
        template with the matching value from -Replacement.
    .DESCRIPTION
        Centralises the placeholder iteration otherwise spelled as a
        600-character `.Replace(...).Replace(...)...` chain in each of
        the six New-VM.ps1 scripts, which buried the placeholder list
        in one line. Pulling the iteration here lets each caller
        spell out the substitution map line-by-line, AND adds an
        unresolved-placeholder safety net: after the substitution, any
        `*_PLACEHOLDER` token left in the result throws -- a typo in
        the base / overlay file or a forgotten entry in the caller's
        -Replacement aborts at New-VM time instead of failing
        mid-autoinstall when the guest sees a literal placeholder
        string in its environment.
    .PARAMETER TemplateContent
        Merged user-data string (typically the return of
        Merge-CloudInitUserData).
    .PARAMETER Replacement
        Hashtable keyed by placeholder name (`HOSTNAME_PLACEHOLDER`,
        `USERNAME_PLACEHOLDER`, ...) mapping to the string value to
        substitute. $null values are coerced to '' so the caller can
        pass an optional setting without a guard.
    .PARAMETER AllowedUnresolved
        Placeholder names that are intentionally left in the output
        (rare; reserved for templates that bake a placeholder for a
        downstream tool to fill in). The unresolved-placeholder safety
        net ignores tokens in this list.
    .OUTPUTS
        [string] resolved template.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TemplateContent,
        [Parameter(Mandatory)][hashtable]$Replacement,
        [string[]]$AllowedUnresolved = @()
    )
    $result = $TemplateContent
    # Replace longer placeholder names first. A shorter name that is a tail-substring of a
    # longer one (e.g. PASSWORD_PLACEHOLDER inside YSTASH_NAS_PASSWORD_PLACEHOLDER) would
    # otherwise rewrite the inside of the longer token and silently bake in the wrong value;
    # hashtable key order is unspecified, so the ordering must be made explicit here.
    foreach ($key in ($Replacement.Keys | Sort-Object -Property Length -Descending)) {
        $value = if ($null -eq $Replacement[$key]) { '' } else { [string]$Replacement[$key] }
        $result = $result.Replace([string]$key, $value)
    }
    $remainingTokens = @(
        [regex]::Matches($result, '\b[A-Z][A-Z0-9_]*_PLACEHOLDER\b') |
            ForEach-Object { $_.Value } |
            Sort-Object -Unique
    )
    $unexpected = @($remainingTokens | Where-Object { $AllowedUnresolved -notcontains $_ })
    if ($unexpected.Count -gt 0) {
        throw "Resolve-CloudInitPlaceholder: template still contains unresolved placeholder(s) after substitution: $($unexpected -join ', '). Add them to -Replacement (with empty value if intentional) or pass -AllowedUnresolved."
    }
    return $result
}

function New-CloudInitUserData {
    <#
    .SYNOPSIS
        End-to-end cloud-init user-data render: merge the shared base
        with the per-host overlay, populate the guest-script base64
        placeholders from $RepoRoot/automation/, then resolve every
        other placeholder from -Replacement.
    .DESCRIPTION
        High-level helper every per-guest New-VM.ps1 calls. Wraps
        Merge-CloudInitUserData + Get-YurunaGuestScriptBase64 +
        Resolve-CloudInitPlaceholder so the caller does not have to
        chain them by hand. Caller still owns the per-platform
        $BasePath / $OverlayPath choice and the per-cycle replacement
        values (VMName, Username, password hash, host IP / port, ...).
        The YURUNA_RETRY_LIB_BASE64_PLACEHOLDER, YURUNA_VERSIONS_BASE64_PLACEHOLDER,
        YURUNA_FAE_BASE64_PLACEHOLDER, and YURUNA_NETWORK_BASE64_PLACEHOLDER entries
        are populated automatically -- a caller that passes them in -Replacement
        will override the auto-populated values, but this is rarely what you want.
    .PARAMETER BasePath
        Absolute path to the shared base user-data template (e.g.
        $RepoRoot/host/vmconfig/ubuntu.server.base.user-data).
    .PARAMETER OverlayPath
        Absolute path to the per-host overlay (e.g. ubuntu.server.hyperv.overlay.yml).
    .PARAMETER RepoRoot
        Absolute path to the repository root. Used to locate the
        guest-side shell scripts under $RepoRoot/automation/.
    .PARAMETER Replacement
        Hashtable keyed by placeholder name. The caller spells out
        every placeholder it cares about; missing tokens (a placeholder
        in the template that the caller forgot) throw via the
        Resolve-CloudInitPlaceholder safety net.
    .PARAMETER AllowedUnresolved
        Placeholder names the template intentionally leaves unresolved for
        a downstream consumer to fill in (e.g. AGGREGATOR_BASE_PLACEHOLDER,
        which the caching-proxy guest resolves at boot via sed once its
        DHCP IP is known). Forwarded to Resolve-CloudInitPlaceholder so the
        unresolved-placeholder safety net ignores these tokens.
    .PARAMETER OutputPath
        Optional. When set, also write the resolved user-data to this
        path (UTF-8 without BOM, LF line endings).
    .OUTPUTS
        [string] resolved user-data.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'ShouldProcess gates the optional on-disk write; the in-memory render is side-effect free.')]
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$OverlayPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Replacement,
        [string[]]$AllowedUnresolved = @(),
        [string]$OutputPath
    )
    $merged = Merge-CloudInitUserData -BasePath $BasePath -OverlayPath $OverlayPath
    $b64    = Get-YurunaGuestScriptBase64 -RepoRoot $RepoRoot
    # Clone the caller's hashtable so we do not mutate it; auto-populate
    # the base64 placeholders only when the caller did not supply them.
    $fullReplacement = @{}
    foreach ($key in $Replacement.Keys) { $fullReplacement[$key] = $Replacement[$key] }
    if (-not $fullReplacement.ContainsKey('YURUNA_RETRY_LIB_BASE64_PLACEHOLDER')) {
        $fullReplacement['YURUNA_RETRY_LIB_BASE64_PLACEHOLDER'] = $b64.RetryLib
    }
    if (-not $fullReplacement.ContainsKey('YURUNA_VERSIONS_BASE64_PLACEHOLDER')) {
        $fullReplacement['YURUNA_VERSIONS_BASE64_PLACEHOLDER'] = $b64.VersionsLib
    }
    if (-not $fullReplacement.ContainsKey('YURUNA_FAE_BASE64_PLACEHOLDER')) {
        $fullReplacement['YURUNA_FAE_BASE64_PLACEHOLDER'] = $b64.FetchAndExecute
    }
    if (-not $fullReplacement.ContainsKey('YURUNA_NETWORK_BASE64_PLACEHOLDER')) {
        $fullReplacement['YURUNA_NETWORK_BASE64_PLACEHOLDER'] = $b64.NetworkLib
    }
    # The guest's GitHub coordinates: which repository this host is serving, the
    # commit it is at, and the token that opens it when it is private. Resolved
    # here, from $RepoRoot, for the same reason the base64 script bodies are --
    # every New-VM.ps1 needs the identical answer, and a per-caller copy is a
    # per-caller chance to name a different repository than the one the runner
    # types at fetch time. Templates that do not carry these placeholders (the
    # caching-proxy and stash-service seeds) simply never consume them.
    $ghSource = Get-YurunaGitHubSource -RepoRoot $RepoRoot
    if (-not $fullReplacement.ContainsKey('YURUNA_GITHUB_REPO_PLACEHOLDER')) {
        $fullReplacement['YURUNA_GITHUB_REPO_PLACEHOLDER'] = $ghSource.Repo
    }
    if (-not $fullReplacement.ContainsKey('YURUNA_GITHUB_REF_PLACEHOLDER')) {
        $fullReplacement['YURUNA_GITHUB_REF_PLACEHOLDER'] = $ghSource.Ref
    }
    if (-not $fullReplacement.ContainsKey('GH_TOKEN_PLACEHOLDER')) {
        $fullReplacement['GH_TOKEN_PLACEHOLDER'] = $ghSource.Token
    }
    if (-not $fullReplacement.ContainsKey('YURUNA_FRAMEWORK_URL_PLACEHOLDER')) {
        $fullReplacement['YURUNA_FRAMEWORK_URL_PLACEHOLDER'] = $ghSource.FrameworkUrl
    }
    if (-not $fullReplacement.ContainsKey('YURUNA_PROJECT_URL_PLACEHOLDER')) {
        $fullReplacement['YURUNA_PROJECT_URL_PLACEHOLDER'] = $ghSource.ProjectUrl
    }
    $resolved = Resolve-CloudInitPlaceholder -TemplateContent $merged -Replacement $fullReplacement -AllowedUnresolved $AllowedUnresolved
    if ($OutputPath) {
        if ($PSCmdlet.ShouldProcess($OutputPath, 'Write resolved cloud-init user-data')) {
            [System.IO.File]::WriteAllText($OutputPath, $resolved, [System.Text.UTF8Encoding]::new($false))
        }
    }
    return $resolved
}

Export-ModuleMember -Function Merge-CloudInitUserData, Read-OverlaySection, Get-YurunaGuestScriptBase64, Resolve-CloudInitPlaceholder, New-CloudInitUserData

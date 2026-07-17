<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456728
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Reusable validation primitives -- schema validation, emptiness check,
# git-tree freshness -- that any check script (Test-Config.ps1 included)
# can call without re-implementing.
#
# All callers reach Write-Pass / Write-Fail / Write-Warn / Write-Info
# from Test.Output.psm1, which this module imports at load time. The
# PASS/FAIL counters survive across Test.Output's $global: anchor so
# Test-Config's summary at end-of-run reflects every Test-AgainstSchema
# and Test-RepoFreshness call regardless of import order.

Import-Module (Join-Path $PSScriptRoot 'Test.Output.psm1') -Global -Force
# Test.HostGit owns Get-GitUpstreamStatus, the shared upstream classifier that
# Test-RepoFreshness reports on (Invoke-GitPull acts on the same result). Import
# -Global so a -Force reimport here cannot evict it from the global session.
Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -Global -Force
# Test-AgainstSchema parses the config through Read-TestConfig (Test.Config) so schema
# validation reuses the hardened reader (root-shape check, the macOS Resolve-Path
# fallback, the shared mtime-keyed cache). Import it here so every consumer of this
# module has the reader -- the validator is also called by the standalone Test-Config.ps1.
Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force

function Test-IsSet {
    <#
    .SYNOPSIS
        $true when $Value is a non-empty string (after trim). Used as a
        guard before -match / Test-Path calls so a $null or '' field does
        not silently pass the check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][Parameter(Position=0)]$Value)
    return ($null -ne $Value -and "$Value".Trim() -ne '')
}

function Test-AgainstSchema {
    <#
    .SYNOPSIS
        Best-effort JSON-Schema validation of a YAML config. When
        Test-Json (PS 7.4+) is unavailable, falls back to a parse-only
        check so the validator still surfaces malformed YAML. Never
        blocks the cycle on missing schema tooling -- only on actual
        content errors.
    .DESCRIPTION
        Resolves YamlPath to an absolute path so every FAIL row carries
        an operator-actionable location: a bare label like "vault.yml"
        would force the operator to guess which of the several vault.yml
        locations was meant.
    .PARAMETER Label
        Display label for the section (e.g. 'vault.yml', 'users.yml').
    .PARAMETER YamlPath
        Path to the YAML document under test.
    .PARAMETER SchemaPath
        Path to the JSON-Schema-compatible YAML schema.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Writes PASS/FAIL via Test.Output; no externally observable state change.')]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    $YamlFull = try { [System.IO.Path]::GetFullPath($YamlPath) } catch { $YamlPath }
    if (-not (Test-Path $YamlPath))   { Write-Fail "${Label}: file not found ($YamlFull)" -FullPath $YamlFull; return }
    if (-not (Test-Path $SchemaPath)) { Write-Warn "${Label}: schema not found ($SchemaPath)"; return }
    try {
        # Route through the hardened reader (root-shape check + the macOS Resolve-Path
        # fallback + the shared cache) instead of a second, divergent parse path.
        $doc = Read-TestConfig -Path $YamlPath -ThrowOnError
    } catch {
        Write-Fail "${Label}: YAML parse error in ${YamlFull} -- $($_.Exception.Message)" -FullPath $YamlFull
        return
    }
    $hasTestJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ($hasTestJson) {
        try {
            # Depth 32 (matching Publish-TestConfigSnapshot) so deep nodes are not silently
            # serialized as '@{...}' strings, which would hand Test-Json a truncated document.
            $schemaJson = Get-Content -Raw $SchemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
            $docJson    = $doc | ConvertTo-Json -Depth 32
            if (Test-Json -Json $docJson -Schema $schemaJson -ErrorAction Stop) {
                Write-Pass "${Label}: schema-valid ($YamlFull)"
            } else {
                Write-Fail "${Label}: schema-invalid -- ${YamlFull}" -FullPath $YamlFull
            }
        } catch {
            Write-Fail "${Label}: schema validation failed in ${YamlFull} -- $($_.Exception.Message)" -FullPath $YamlFull
        }
    } else {
        Write-Pass "${Label}: parse-only check passed (Test-Json unavailable; schema not enforced)"
    }
}

function Test-RepoFreshness {
    <#
    .SYNOPSIS
        Report a git working tree's relation to its upstream: up-to-date,
        ahead, behind, diverged, or no-upstream. Fetches first so the
        comparison is meaningful; tolerates offline (`git fetch` failure
        becomes a WARN, not a FAIL).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Writes PASS/WARN via Test.Output; no externally observable state change beyond a git fetch (read-only).')]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path (Join-Path $Path '.git'))) {
        Write-Warn "${Label}: not a git working tree ($Path) -- skipping freshness check."
        return
    }
    # Fetch through the shared network-git helper: it neutralizes every
    # interactive credential prompt (so a private/rate-limited remote can't stop
    # this check dead on a 'Username for https://github.com:' prompt -- a config
    # sync that runs this as its final validation would otherwise hang on a
    # GitHub question unrelated to the sync) AND chains the host's GitHub
    # credential sources (GH_TOKEN, the gh CLI login), which plain git does not
    # read on its own. See Invoke-GitNetworkCommand.
    try {
        $fetch = Invoke-GitNetworkCommand -GitArgs @('-C', $Path, 'fetch', '--quiet') -TimeoutSeconds 60
        if ($fetch.ExitCode -ne 0) {
            Write-Warn "${Label}: git fetch failed (offline, or the remote needs credentials this host does not have); cannot determine staleness."
            return
        }
        $st = Get-GitUpstreamStatus -Path $Path
        switch ($st.State) {
            'no-upstream' { Write-Info "${Label}: no upstream tracking branch -- skipping ahead/behind." }
            'up-to-date'  { Write-Pass "${Label}: up to date with $($st.Remote)." }
            'behind'      { Write-Warn "${Label}: $($st.Behind) commit(s) behind upstream -- 'git pull --ff-only' before next cycle." }
            'ahead'       { Write-Pass "${Label}: $($st.Ahead) commit(s) ahead of upstream (unpushed local work)." }
            default       { Write-Warn "${Label}: diverged ($($st.Ahead) ahead, $($st.Behind) behind). Rebase or merge manually." }
        }
    } catch {
        Write-Warn "${Label}: freshness check threw -- $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Test-IsSet, Test-AgainstSchema, Test-RepoFreshness

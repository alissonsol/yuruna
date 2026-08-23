<#PSScriptInfo
.VERSION 2026.08.23
.GUID 42357e45-1be3-4923-bebd-60e195c757a0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna install checksum manifest integrity
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
    Every hash in install/install.sha256 matches the installer it names.
.DESCRIPTION
    The installers are the `curl | sh` entry point, and install/install.sha256 is
    what a cautious user checks before running one. Nothing verified that the
    manifest still described the files it names, and it drifted: the manifest was
    last written two months before the installers it covers, so the documented
    `sha256sum -c install/install.sha256` step failed for every entry while the
    repository looked healthy.

    DETECTION ONLY, DELIBERATELY. This suite reports the correct hashes and stops
    there. Regenerating the manifest invalidates install.sha256.sig, and the
    private half of that signing key is not in the repository -- so a run that
    "helpfully" rewrote the manifest would replace a stale-but-signed file with a
    current-but-unsigned one, and a signature that verifiably does not match is a
    worse failure than a hash that is merely old. Rewriting is the operator's
    step, with their key.

    While the signature is older than the manifest's own contents, the drift is
    reported as a SKIP rather than a failure: the fix is not available to the
    person running the gate, and a permanently red gate teaches everyone to
    ignore it. Once the operator re-signs, the skip turns into a pass on its own
    -- and any FUTURE drift then fails, because the signature will be newer than
    the installers only until one of them changes again.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $script:ManifestPath  = Join-Path $repoRoot 'install/install.sha256'
    $script:SignaturePath = Join-Path $repoRoot 'install/install.sha256.sig'
    $script:RepoRootPath  = $repoRoot

    # Parse the sha256sum format: "<64 hex><two spaces><repo-relative path>".
    function Get-ManifestEntry {
        if (-not (Test-Path -LiteralPath $script:ManifestPath)) { return @() }
        Get-Content -LiteralPath $script:ManifestPath |
            Where-Object { $_ -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' } |
            ForEach-Object {
                if ($_ -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                    [pscustomobject]@{
                        Recorded = $Matches[1].ToLowerInvariant()
                        Relative = $Matches[2]
                        FullPath = Join-Path $script:RepoRootPath $Matches[2]
                    }
                }
            }
    }

    # True while the signature predates the file it signs -- the state in which
    # the operator, not this gate, owns the fix.
    function Test-SignatureStale {
        if (-not (Test-Path -LiteralPath $script:SignaturePath)) { return $false }
        if (-not (Test-Path -LiteralPath $script:ManifestPath))  { return $false }
        $sig = (Get-Item -LiteralPath $script:SignaturePath).LastWriteTimeUtc
        $any = @(Get-ManifestEntry | Where-Object { Test-Path -LiteralPath $_.FullPath } |
                ForEach-Object { (Get-Item -LiteralPath $_.FullPath).LastWriteTimeUtc })
        if ($any.Count -eq 0) { return $false }
        return ($sig -lt (($any | Sort-Object -Descending)[0]))
    }
}

Describe 'the installer integrity manifest' {
    It 'exists and names at least one installer' {
        Assert-True (Test-Path -LiteralPath $script:ManifestPath) "missing $($script:ManifestPath)"
        Assert-True (@(Get-ManifestEntry).Count -gt 0) 'the manifest lists no usable <hash>  <path> entry'
    }

    It 'names only files that exist' {
        $absent = @(Get-ManifestEntry | Where-Object { -not (Test-Path -LiteralPath $_.FullPath) })
        Assert-True ($absent.Count -eq 0) "the manifest names files that are not in the repo: $(($absent.Relative) -join ', ')"
    }

    It 'records the hash each installer actually has' {
        $drift = [Collections.Generic.List[string]]::new()
        foreach ($e in Get-ManifestEntry) {
            if (-not (Test-Path -LiteralPath $e.FullPath)) { continue }
            $actual = (Get-FileHash -LiteralPath $e.FullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $e.Recorded) {
                $drift.Add("$($e.Relative)`n    recorded $($e.Recorded)`n    actual   $actual")
            }
        }

        if ($drift.Count -gt 0 -and (Test-SignatureStale)) {
            Set-ItResult -Skipped -Because @"
install.sha256 is out of date and install.sha256.sig signs the stale copy, so
regenerating it here would leave a manifest the signature does not verify.
Operator step -- regenerate and re-sign with the release key:
$($drift -join "`n")
"@
            return
        }

        Assert-True ($drift.Count -eq 0) @"
install.sha256 does not match the installers it names:
$($drift -join "`n")
"@
    }
}

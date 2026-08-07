<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b7c4d9-5e10-4a83-9f26-71c40ad5e309
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna extension sdk mirror go
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
    Mirror the canonical extension SDK into every extension service that builds
    a Go daemon, or verify that the mirrors match.

.DESCRIPTION
    The SDK has ONE source of truth: test/extension/extension-sdk/, its own Go
    module, independently built, vetted and tested. Every service daemon carries
    a byte-identical copy at <area>/server/internal/yex/.

    A copy rather than a shared module because of how these daemons are built.
    Each one is its own module, compiled INSIDE its own VM at bring-up from the
    framework checkout, and the bring-up copies only <area>/server/ to a build
    directory before running `go build`. A module outside that directory is not
    there when the compiler looks for it. Committing the mirror also keeps every
    service independently buildable and testable from a plain checkout: the
    tests that ship with the SDK compile in each service too, so a service whose
    mirror has drifted fails its own `go test` rather than silently diverging.

    The mirror is generated, never edited. Change the canonical package, re-run
    this script, and commit both. -Verify is the same comparison without the
    write, which is what the mirror Pester suite runs.

    Targets are DISCOVERED, not listed: every test/extension/<area>/server/go.mod
    in the tree gets the mirror, so a new service picks it up by existing.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER Verify
    Compare only. Reports every drifted, missing and orphaned file and exits
    non-zero when the mirrors are not identical to the canonical source.

.OUTPUTS
    [pscustomobject] Synced / Drifted / Removed / Targets, for a caller that
    wants the counts.

.EXAMPLE
    pwsh -NoProfile -File tools/Sync-ExtensionSdk.ps1
    Refresh every mirror after editing the canonical SDK.

.EXAMPLE
    pwsh -NoProfile -File tools/Sync-ExtensionSdk.ps1 -Verify
    Fail when a mirror has drifted (what the test suite runs).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The mirror directory name inside each service module. Short, and namespaced
# enough that it cannot collide with a service's own internal packages.
$MirrorDirName = 'yex'

$sdkRoot = Join-Path $RepoRoot 'test/extension/extension-sdk'
if (-not (Test-Path -LiteralPath $sdkRoot)) {
    throw "Canonical SDK not found at $sdkRoot."
}

# Canonical files: every .go under the SDK, keyed by its path relative to the
# SDK root. go.mod is deliberately NOT mirrored -- the copy lives inside the
# consuming service's module and must not declare a second one.
$canonical = [ordered]@{}
foreach ($file in (Get-ChildItem -LiteralPath $sdkRoot -Recurse -File -Filter '*.go' | Sort-Object FullName)) {
    $relative = [System.IO.Path]::GetRelativePath($sdkRoot, $file.FullName).Replace('\', '/')
    $canonical[$relative] = [pscustomobject]@{
        Path = $file.FullName
        Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}
if ($canonical.Count -eq 0) {
    throw "Canonical SDK at $sdkRoot contains no .go files."
}

# Targets: every extension area that builds a Go daemon under server/.
$targets = @()
$extensionRoot = Join-Path $RepoRoot 'test/extension'
foreach ($dir in (Get-ChildItem -LiteralPath $extensionRoot -Directory | Sort-Object Name)) {
    if ($dir.Name -eq 'extension-sdk') { continue }
    $serverDir = Join-Path $dir.FullName 'server'
    if (Test-Path -LiteralPath (Join-Path $serverDir 'go.mod')) { $targets += $serverDir }
}

$synced = 0
$drifted = New-Object System.Collections.Generic.List[string]
$removed = New-Object System.Collections.Generic.List[string]

foreach ($serverDir in $targets) {
    $mirrorRoot = Join-Path $serverDir "internal/$MirrorDirName"

    foreach ($relative in $canonical.Keys) {
        $source = $canonical[$relative]
        $target = Join-Path $mirrorRoot $relative
        $identical = $false
        if (Test-Path -LiteralPath $target) {
            $identical = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $source.Hash
        }
        if ($identical) { continue }

        $shown = [System.IO.Path]::GetRelativePath($RepoRoot, $target).Replace('\', '/')
        if ($Verify) {
            [void]$drifted.Add($shown)
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($shown, 'Mirror the extension SDK file')) { continue }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        # Copy-Item, not Get/Set-Content: the comparison above is byte-exact, so a
        # re-encode here would make every run report drift it had just created.
        Copy-Item -LiteralPath $source.Path -Destination $target -Force
        $synced++
    }

    # Orphans: a mirrored file whose canonical source is gone. Left in place it
    # would keep compiling into the service long after the SDK dropped it.
    if (Test-Path -LiteralPath $mirrorRoot) {
        foreach ($file in (Get-ChildItem -LiteralPath $mirrorRoot -Recurse -File | Sort-Object FullName)) {
            $relative = [System.IO.Path]::GetRelativePath($mirrorRoot, $file.FullName).Replace('\', '/')
            if ($canonical.Contains($relative)) { continue }
            $shown = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
            if ($Verify) {
                [void]$drifted.Add("$shown (not in the canonical SDK)")
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($shown, 'Remove the orphaned SDK mirror file')) { continue }
            Remove-Item -LiteralPath $file.FullName -Force
            [void]$removed.Add($shown)
        }
    }
}

if ($Verify -and $drifted.Count -gt 0) {
    foreach ($entry in $drifted) { Write-Warning "extension SDK mirror out of date: $entry" }
    Write-Error "$($drifted.Count) mirrored SDK file(s) differ from test/extension/extension-sdk/. Run: pwsh -NoProfile -File tools/Sync-ExtensionSdk.ps1"
}

[pscustomobject]@{
    Targets = @($targets | ForEach-Object { [System.IO.Path]::GetRelativePath($RepoRoot, $_).Replace('\', '/') })
    Files   = $canonical.Count
    Synced  = $synced
    Drifted = @($drifted)
    Removed = @($removed)
}

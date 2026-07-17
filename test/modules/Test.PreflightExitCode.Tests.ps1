<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42f1c7a4-9b3e-4d21-8c05-6ea41d9b73c2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation preflight exitcode pester
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
    Guard: a deploy entrypoint that refuses to deploy must exit NON-ZERO.
.DESCRIPTION
    The Set-* entrypoints are launched from guest bash wrappers running under
    `set -euo pipefail`, so the PROCESS exit code is the only signal bash reads.
    A bare `return $false` at script scope leaves that code at 0 -- bash then
    treats a refused deploy as a successful one, the sequence marches on, and the
    real fault resurfaces steps later somewhere else entirely (an unreachable
    endpoint, a `kubectl wait` timeout) with none of the original diagnosis.

    Two guards can refuse before any work happens: the runtime pre-flight
    (Set-Workload) and the root resolution (all three). Both must exit 1.

    Behavioural: run each entrypoint against a project root that cannot resolve
    and assert the process exit code is non-zero. Structural: assert the guards
    do not regress to `return $false`. Nothing here needs docker or a cluster.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'preflight-exit-code' {
    It 'a refused deploy exits non-zero (Set-Resource, Set-Component, Set-Workload)' {
        # A project root that cannot resolve: every entrypoint must refuse here,
        # and refusing is only visible to `set -e` as a non-zero exit code.
        $missingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-no-such-root-$([guid]::NewGuid())"
        foreach ($e in 'Set-Resource', 'Set-Component', 'Set-Workload') {
            $script = Join-Path $autoDir "$e.ps1"
            & pwsh -NoProfile -File $script $missingRoot 'localhost' *> $null
            Assert-True ($LASTEXITCODE -ne 0) `
                "$e exited $LASTEXITCODE on a refused deploy; bash 'set -e' reads 0 as success and marches on"
        }
    }
    It 'the refusal guards exit 1 rather than returning $false' {
        # `return $false` at script scope does NOT set the process exit code.
        foreach ($e in 'Set-Resource', 'Set-Component', 'Set-Workload') {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            Assert-True (-not ($src -match '(?m)^\s*if \(-not \$roots\) \{ return \$false \}')) `
                "$e must not return `$false from the root guard -- that exits the process 0"
            Assert-True ($src -match '(?s)if \(-not \$roots\) \{[^}]*\bexit 1\b') `
                "$e root guard must exit 1"
        }
    }
    It 'Set-Workload exits 1 when the runtime pre-flight refuses' {
        $src = Get-Content -LiteralPath (Join-Path $autoDir 'Set-Workload.ps1') -Raw
        Assert-True ($src -match '(?s)if \(-not \$runtimeOk\) \{[^}]*\bexit 1\b') `
            'the runtime pre-flight guard must exit 1, not return $false'
    }
    It 'Set-Workload reads the pre-flight verdict as the LAST object, not the whole capture' {
        # Test-Runtime streams its docker images/containers tables to stdout on the
        # healthy path, so `& Test-Runtime.ps1` yields a collection. Testing the
        # collection for truthiness reads any non-empty table as a pass.
        $src = Get-Content -LiteralPath (Join-Path $autoDir 'Set-Workload.ps1') -Raw
        Assert-True ($src -match '\$runtimeOutput\[-1\]') `
            'the verdict must be taken from the last emitted object'
    }
    It 'Test-Runtime reports its problems on a stream the default logLevel cannot silence' {
        # logLevel 'Error' (the entrypoints' default) silences Information AND
        # Warning; a pre-flight that reported problems there printed nothing at all.
        $src = Get-Content -LiteralPath (Join-Path $autoDir 'Test-Runtime.ps1') -Raw
        Assert-True ($src -match '(?s)if \(\$problems\.Count -gt 0\) \{[^}]*Write-Error') `
            'the PROBLEMS FOUND report must reach the error stream'
    }
    It 'Test-Runtime rejects a tool that is present but not runnable' {
        # A zero-length file with the +x bit satisfies Get-Command and even runs as
        # an empty script under bash (exit 0, no output). The probe must treat "no
        # output" as "not usable", and must not let the execve failure escape raw.
        $src = Get-Content -LiteralPath (Join-Path $autoDir 'Test-Runtime.ps1') -Raw
        Assert-True ($src -match 'function Get-ToolProbeOutput') `
            'Test-Runtime must probe tools through the runnable-check helper'
        Assert-True ($src -match "Get-ToolProbeOutput -Name 'helm'") `
            'helm must be probed: every chart deployment shells out to it'
        Assert-True ($src -match "Get-ToolProbeOutput -Name 'mkcert'") `
            'mkcert must be probed through the same helper'
    }
}

<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42b1e7d4-9a3c-4f60-8b2e-5c1d0a9f3e26
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status atomic-write race pester
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
    Guards that the detached status server publishes every shared-state file with a
    gap-free atomic replace, so a concurrent reader never catches a half-written or
    momentarily-absent file.
.DESCRIPTION
    The status server here-string in Start-StatusService.ps1 writes several
    read-by-others files (test.config.yml from the UI, perf checkpoints, status.json,
    streamed diagnostics). A write-.tmp-then-Move-Item -Force publish deletes the
    destination before renaming, so a reader that lands in the gap sees no file (or,
    with a fixed .tmp name, a second writer's partial content) -- which can spuriously
    fire the config-changed pause trigger or parse truncated YAML. The fix publishes
    via [System.IO.File]::Move(tmp, dst, $true), an in-place rename with no unlink gap
    (MoveFileEx REPLACE_EXISTING on Windows, rename(2) on Unix), off a per-writer unique
    temp. These tests pin: no shared-state publish uses Move-Item (only the server-log
    rotation may), each publish uses the atomic overload, the temp names
    are unique, and the overwrite overload behaves as relied upon.

    The throw-based Assert-* helpers are defined at script scope and referenced from It
    blocks, so this runs under Pester 4.10.1 (Pester 5's scope split hides top-level
    helpers from It blocks).
#>

$here = Split-Path -Parent $PSCommandPath
$sss  = Join-Path (Split-Path -Parent $here) 'Start-StatusService.ps1'
$txt  = Get-Content -Raw -LiteralPath $sss

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'status-service shared-state writes are atomic and collision-free' {

    It 'publishes shared state via [IO.File]::Move, never a non-atomic Move-Item' {
        # The only Move-Item allowed is the server-log rotation ($serverLogFile.old);
        # every shared-state publish must use the gap-free atomic replace instead.
        foreach ($m in [regex]::Matches($txt, 'Move-Item[^\r\n]*')) {
            Assert-True ($m.Value -match 'serverLogFile') "non-atomic Move-Item on shared state: $($m.Value.Trim())"
        }
        $atomic = [regex]::Matches($txt, '\[System\.IO\.File\]::Move\(').Count
        Assert-True ($atomic -ge 5) "expected >= 5 atomic [IO.File]::Move publishes (test-config, perf-ckpt, status.json x2, diagnostics); found $atomic"
    }

    It 'uses a per-writer unique temp for each publish (no fixed .tmp collision target)' {
        # A fixed "$file.tmp" lets two concurrent writers share -- and clobber -- one temp.
        Assert-True ($txt -notmatch '"`\$testConfigFile\.tmp"') 'test-config temp must be unique, not a fixed .tmp'
        Assert-True ($txt -notmatch '"`\$filePath\.tmp"')       'diagnostics temp must be unique, not a fixed .tmp'
    }

    It '[IO.File]::Move overwrite atomically replaces an existing destination and consumes the temp' {
        $dir = Join-Path $env:TEMP ('rel9-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $dst = Join-Path $dir 'target.txt'
            Set-Content -LiteralPath $dst -Value 'OLD' -NoNewline
            $tmp = Join-Path $dir ('target.txt.' + $PID + '-' + [guid]::NewGuid().ToString('N') + '.tmp')
            Set-Content -LiteralPath $tmp -Value 'NEW' -NoNewline
            # The 2-arg overload throws on an existing destination -- which is why the
            # publish uses the 3-arg overwrite overload rather than delete-then-rename.
            $threw = $false
            try { [System.IO.File]::Move($tmp, $dst) } catch { $threw = $true }
            Assert-True $threw 'the 2-arg Move must fail on an existing destination'
            [System.IO.File]::Move($tmp, $dst, $true)
            Assert-Equal -Expected 'NEW' -Actual (Get-Content -Raw -LiteralPath $dst)
            Assert-True (-not (Test-Path -LiteralPath $tmp)) 'the temp is consumed by the move'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

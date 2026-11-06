<#PSScriptInfo
.VERSION 2026.11.05
.GUID 420bd99b-9a43-48a6-9d05-9d19abdacd2d
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
    Guards that the detached status service publishes every shared-state file with a
    gap-free atomic replace, so a concurrent reader never catches a half-written or
    momentarily-absent file.
.DESCRIPTION
    The status service runtime (test/service/Invoke-StatusServiceRuntime.ps1) writes several
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

    The start-cycle status.json rewrite runs in the detached start-cycle worker
    (test/modules/Invoke-StartCycleWorker.ps1), not in the listener, so its
    publish is pinned there: through Write-YurunaStateFile, which is the same
    per-writer temp plus [IO.File]::Move replace.

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$sss  = Join-Path (Split-Path -Parent $here) 'service/Invoke-StatusServiceRuntime.ps1'
$script:txt  = Get-Content -Raw -LiteralPath $sss
$script:startCycleWorker = Get-Content -Raw -LiteralPath (Join-Path $here 'Invoke-StartCycleWorker.ps1')
$script:startService = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $here) 'service/Start-StatusService.ps1')

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'status-service shared-state writes are atomic and collision-free' {

    It 'publishes shared state via [IO.File]::Move, never a non-atomic Move-Item' {
        # The only Move-Item allowed is the server-log rotation ($serverLogFile.old);
        # every shared-state publish must use the gap-free atomic replace instead.
        foreach ($m in [regex]::Matches($script:txt, 'Move-Item[^\r\n]*')) {
            Assert-True ($m.Value -match 'serverLogFile') "non-atomic Move-Item on shared state: $($m.Value.Trim())"
        }
        $atomic = [regex]::Matches($script:txt, '\[(?:System\.)?IO\.File\]::Move\(').Count
        Assert-True ($atomic -ge 3) "expected >= 3 atomic [IO.File]::Move publishes (test-config, perf-ckpt, diagnostics); found $atomic"
        # The pause routes stamp status.json through the locked field update,
        # whose writer is the same per-writer temp plus [IO.File]::Move replace.
        Assert-True ($script:txt -match 'Update-StatusDocumentField -StatusPath \$statusJsonFile') 'the pause routes must stamp status.json through Update-StatusDocumentField'
    }

    It 'publishes the start-cycle status.json rewrite atomically from its worker' {
        # The listener no longer touches status.json for a start-cycle; the
        # worker rewrites the pause and lab-hold fields, and it must do so with
        # the same gap-free replace, never a delete-then-write.
        Assert-True ($script:startCycleWorker -match "Update-StatusDocumentField -StatusPath \`$statusPath") `
            'the start-cycle worker must publish status.json through the locked Update-StatusDocumentField'
        foreach ($pattern in @('Move-Item', 'Set-Content', 'Out-File', 'WriteAllText\(\$statusPath')) {
            Assert-True ($script:startCycleWorker -notmatch $pattern) "the start-cycle worker must not write shared state with $pattern"
        }
        Assert-True ($script:txt -notmatch 'cyclePausedSinceUtc''\]\s*=\s*''''') `
            'the listener must not rewrite the start-cycle status.json fields itself'
    }

    It 'uses a per-writer unique temp for each publish (no fixed .tmp collision target)' {
        # A fixed "$file.tmp" lets two concurrent writers share -- and clobber -- one temp.
        Assert-True ($script:txt -notmatch '"\$testConfigFile\.tmp"') 'test-config temp must be unique, not a fixed .tmp'
        Assert-True ($script:txt -notmatch '"\$filePath\.tmp"')       'diagnostics temp must be unique, not a fixed .tmp'
    }

    It '[IO.File]::Move overwrite atomically replaces an existing destination and consumes the temp' {
        $dir = New-YurunaTestTempDir -Prefix 'rel9'
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
            Remove-YurunaTestTempDir $dir
        }
    }
}

Describe 'status.json writers outside the listener hold the shared status-file lock' {
    # The outer runner's fault stamp and the configuration gate's fault clear
    # replace the whole document, as the pause routes and the start-cycle
    # worker do. Every such writer has to hold the same status-file lock, or
    # a stamp one side makes between another side's read and write is lost.
    # The fixture plays a pause route with its read-modify-write held open:
    # the lock taken, the document read, and the pause fields written only
    # after the writer under test has had its turn.
    BeforeAll {
        Import-Module (Join-Path $here 'Test.Status.psm1')          -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $here 'Test.ConfigPreflight.psm1') -Force -DisableNameChecking
        function Start-HeldPauseStamp {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: a thread job that stamps the pause fields under a lock it holds open for a while.')]
            param([string]$StatusPath, [int]$HoldMilliseconds)
            $module = Join-Path $here 'Test.Status.psm1'
            $null = $HoldMilliseconds # Read by the thread job through $using:.
            $job = Start-ThreadJob -ScriptBlock {
                Import-Module $using:module -DisableNameChecking
                $lock = Enter-StatusLock -Path $using:StatusPath -TimeoutMs 2000
                try {
                    $doc = Read-StatusDocFromDisk -StatusPath $using:StatusPath
                    Start-Sleep -Milliseconds $using:HoldMilliseconds
                    $doc['stepPaused'] = $true
                    $doc['stepPausedSinceUtc'] = 'since-fixture'
                    $null = Write-YurunaStateFileJson -Path $using:StatusPath -InputObject $doc -Depth 20 -Compress:$false -Confirm:$false
                } finally { Exit-StatusLock -Lock $lock }
            }
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath "$StatusPath.lock") -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            return $job
        }
    }
    BeforeEach { $script:lockDir = New-YurunaTestTempDir -Prefix 'status-lock' }
    AfterEach  { Remove-YurunaTestTempDir $script:lockDir }

    It 'keeps both the pause stamp and the runner fault stamp when they interleave' {
        $sf = Join-Path $script:lockDir 'status.json'
        [IO.File]::WriteAllText($sf, (@{ schemaVersion = 1; overallStatus = 'pass'; stepPaused = $false; guests = @(); history = @() } | ConvertTo-Json))
        $job = Start-HeldPauseStamp -StatusPath $sf -HoldMilliseconds 1200
        try {
            $written = Update-RunnerFaultStatus -RuntimeDir $script:lockDir -RunnerState 'fault' -Reason 'inner exited 3' -Confirm:$false
        } finally { $null = Wait-Job -Job $job -Timeout 15; Remove-Job -Job $job -Force }
        Assert-True $written 'the fault stamp is written'
        $doc = Get-Content -Raw -LiteralPath $sf | ConvertFrom-Json
        Assert-Equal -Expected 'fault' -Actual $doc.runnerState -Because 'the fault stamp survives the pause route writing after it'
        Assert-True ($null -ne $doc.runnerFault) 'the fault record survives the pause route writing after it'
        Assert-True $doc.stepPaused 'the pause route''s stamp survives the fault writer'
        Assert-Equal -Expected 'since-fixture' -Actual $doc.stepPausedSinceUtc
        Assert-False (Test-Path -LiteralPath "$sf.lock") 'the lock is released'
    }

    It 'keeps the pause stamp when the configuration gate clears a prior fault under it' {
        $sf = Join-Path $script:lockDir 'status.json'
        [IO.File]::WriteAllText($sf, (@{ overallStatus = 'pass'; cycle = 7; stepPaused = $false; runnerFault = @{ failureClass = 'config_gate_failed' }; runnerState = 'paused' } | ConvertTo-Json))
        $gate = @{ passed = $true; skipped = $false; exitCode = 0; startedAtUtc = [DateTime]::UtcNow.ToString('o'); lines = @('ok'); failureLines = @(); structuredResult = $null }
        $job = Start-HeldPauseStamp -StatusPath $sf -HoldMilliseconds 1200
        try {
            $null = Write-ConfigGateArtifact -RuntimeDir $script:lockDir -Gate $gate -AttemptGeneration 'runner:1' -Confirm:$false
        } finally { $null = Wait-Job -Job $job -Timeout 15; Remove-Job -Job $job -Force }
        $doc = Get-Content -Raw -LiteralPath $sf | ConvertFrom-Json
        Assert-True ($null -eq $doc.runnerFault) 'the gate''s fault clear survives the pause route writing after it'
        Assert-Equal -Expected 'in-cycle' -Actual $doc.runnerState
        Assert-True $doc.stepPaused 'the pause route''s stamp survives the gate'
        Assert-Equal -Expected 7 -Actual $doc.cycle
        Assert-False (Test-Path -LiteralPath "$sf.lock") 'the lock is released'
    }

    It 'publishes the start''s repoUrl rewrite through the locked field update, never a bare write' {
        $region = [regex]::Match($script:startService, '(?s)REGION: Ensure repoUrl is set in status\.json(.*?)# --- REGION:').Groups[1].Value
        Assert-True ($region.Length -gt 0) 'the repoUrl region is locatable in Start-StatusService.ps1'
        Assert-True ($region -match 'Update-StatusDocumentField -StatusPath \$StatusFile') 'the start must rewrite repoUrl through the locked Update-StatusDocumentField'
        foreach ($pattern in @('WriteAllText\(\$StatusFile', 'Set-Content', 'Out-File', 'Move-Item')) {
            Assert-True ($region -notmatch $pattern) "the start must not write status.json with $pattern"
        }
    }
}

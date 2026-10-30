<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42d8224a-16b3-4ad0-a97f-6ead899f0487
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config lock journal reconcile cycle-counter pester
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
    Pester coverage for the state a runner host keeps across writers and
    processes: test.config.yml's write lock, its journal of earlier versions
    and the restore from it, the one reconciliation both template entry points
    share, and the cycle counter kept beside status.json.
.DESCRIPTION
    test.config.yml had more than ten read-modify-write writers with no lock
    between them, all sharing one test.config.yml.backup, so an interleaved
    pair lost a change and a second write overwrote the first one's backup.
    The cycle-start overlay and the validator reconciled the file each in its
    own way. And the cycle counter lived only in status.json, which is moved
    aside when it does not parse, so numbering restarted at 1.

    The lock is exercised with real processes, because what it guards is what
    the operating system does with two of them.
    Run: Invoke-Pester -Path test/modules/Test.ConfigWriteSerialization.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Prelude.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $here 'Test.ConfigSync.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Status.psm1') -Force -DisableNameChecking
    Import-Module powershell-yaml -ErrorAction Stop
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RealTemplate = Join-Path (Split-Path -Parent $here) 'test.config.yml.template'

    # A config beside a copy of the real template, as Write-DocumentedTestConfig
    # finds it (<config>.template), with the counter knob at Start.
    function script:New-ConfigFixture {
        param([int]$Start = 0)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $dir
        $config = Join-Path $dir 'test.config.yml'
        Copy-Item -LiteralPath $script:RealTemplate -Destination "$config.template"
        $doc = Get-Content -Raw -LiteralPath $script:RealTemplate | ConvertFrom-Yaml -Ordered
        $doc.notification.successesBeforeRearm = $Start
        $null = Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Writer 'fixture' -Confirm:$false
        return $config
    }
    function script:Get-Counter {
        param([string]$ConfigPath)
        return [int](Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Yaml -Ordered).notification.successesBeforeRearm
    }
}

Describe 'test.config.yml writers are serialized by one lock' {
    It 'loses no increment when four processes read, change and write it at once' {
        $config = New-ConfigFixture -Start 0
        $worker = Join-Path $TestDrive 'increment.ps1'
        Set-Content -LiteralPath $worker -Encoding utf8 -Value @'
param([string]$ConfigPath, [string]$ModulesDir, [int]$Count)
Import-Module powershell-yaml -ErrorAction Stop
Import-Module (Join-Path $ModulesDir 'Test.ConfigSync.psm1') -DisableNameChecking
for ($i = 0; $i -lt $Count; $i++) {
    Use-TestConfigLock -Path $ConfigPath -Action {
        $doc = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Yaml -Ordered
        $doc.notification.successesBeforeRearm = [int]$doc.notification.successesBeforeRearm + 1
        $null = Write-DocumentedTestConfig -ConfigPath $ConfigPath -Config $doc -Writer "w$PID" -Confirm:$false
    }
}
'@
        $procs = @(1..4 | ForEach-Object {
            Start-Process -FilePath ([Environment]::ProcessPath) -PassThru -NoNewWindow `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $worker, '-ConfigPath', $config, '-ModulesDir', $here, '-Count', '5') `
                -RedirectStandardError (Join-Path $TestDrive "w$_.err") -RedirectStandardOutput (Join-Path $TestDrive "w$_.out")
        })
        foreach ($p in $procs) { $null = $p.WaitForExit(180000) }
        foreach ($p in $procs) { Assert-Equal -Expected 0 -Actual $p.ExitCode -Because "worker $($p.Id) failed: $(Get-Content -Raw -LiteralPath (Join-Path $TestDrive "w$([array]::IndexOf($procs, $p) + 1).err"))" }
        Assert-Equal -Expected 20 -Actual (Get-Counter -ConfigPath $config) -Because 'every read-modify-write saw the one before it'
    }

    It 'lets a block that holds the lock call the documented writer' {
        $config = New-ConfigFixture -Start 3
        $result = Use-TestConfigLock -Path $config -Action {
            $doc = Get-Content -Raw -LiteralPath $config | ConvertFrom-Yaml -Ordered
            $doc.notification.successesBeforeRearm = 4
            Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Confirm:$false
        }
        Assert-True $result 'the nested write landed'
        Assert-Equal -Expected 4 -Actual (Get-Counter -ConfigPath $config)
    }

    It 'refuses to write while another process holds the lock past the wait' {
        $config = New-ConfigFixture -Start 1
        $holder = Join-Path $TestDrive 'hold.ps1'
        $ready = Join-Path $TestDrive 'held'
        Set-Content -LiteralPath $holder -Encoding utf8 -Value @'
param([string]$ConfigPath, [string]$ModulesDir, [string]$Ready)
Import-Module (Join-Path $ModulesDir 'Test.ConfigSync.psm1') -DisableNameChecking
Use-TestConfigLock -Path $ConfigPath -Action { Set-Content -LiteralPath $Ready -Value 'held'; Start-Sleep -Seconds 8 }
'@
        $proc = Start-Process -FilePath ([Environment]::ProcessPath) -PassThru -NoNewWindow `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $holder, '-ConfigPath', $config, '-ModulesDir', $here, '-Ready', $ready)
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Assert-True (Test-Path -LiteralPath $ready) 'the holder took the lock'
            $before = Get-Content -Raw -LiteralPath $config
            $thrown = $null
            try { $null = Use-TestConfigLock -Path $config -WaitMilliseconds 500 -Action { Set-Content -LiteralPath $config -Value 'written' } } catch { $thrown = $_.Exception.Message }
            Assert-True ($thrown -match '^config-lock-busy') "a busy lock refuses: $thrown"
            Assert-Equal -Expected $before -Actual (Get-Content -Raw -LiteralPath $config) -Because 'nothing was written'
        } finally {
            $null = $proc.WaitForExit(30000)
            if (-not $proc.HasExited) { $proc.Kill() }
        }
    }
}

Describe 'every config write keeps the version it replaces' {
    It 'keeps one distinct journal entry per write, holding the replaced bytes' {
        $config = New-ConfigFixture -Start 0
        $first = Get-Content -Raw -LiteralPath $config
        $doc = $first | ConvertFrom-Yaml -Ordered
        $doc.notification.successesBeforeRearm = 1
        $null = Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Writer 'one' -Confirm:$false
        $second = Get-Content -Raw -LiteralPath $config
        $doc.notification.successesBeforeRearm = 2
        $null = Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Writer 'two' -Confirm:$false
        $journal = @(Get-TestConfigJournal -ConfigPath $config)
        Assert-Equal -Expected 2 -Actual $journal.Count -Because 'the fixture write found no file to keep; each later write kept one'
        Assert-Equal -Expected 'two' -Actual $journal[0].Writer -Because 'newest first, named for its writer'
        Assert-Equal -Expected $second -Actual ([IO.File]::ReadAllText($journal[0].Path))
        Assert-Equal -Expected $first -Actual ([IO.File]::ReadAllText($journal[1].Path)) -Because 'the second write did not overwrite the first one''s copy'
        Assert-True ($journal[0].Path -like '*.backup') 'entries carry the name the status service refuses to serve'
        if (-not $IsWindows) {
            $mode = [IO.File]::GetUnixFileMode($journal[0].Path)
            Assert-Equal -Expected ([IO.UnixFileMode]'UserRead, UserWrite') -Actual $mode -Because 'an entry holds the config''s credentials'
        }
    }

    It 'keeps nothing for a write that changes nothing' {
        $config = New-ConfigFixture -Start 5
        $doc = Get-Content -Raw -LiteralPath $config | ConvertFrom-Yaml -Ordered
        $null = Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Confirm:$false
        Assert-Equal -Expected 0 -Actual @(Get-TestConfigJournal -ConfigPath $config).Count
    }

    It 'prunes only beyond the newest twenty' {
        $config = New-ConfigFixture -Start 0
        $doc = Get-Content -Raw -LiteralPath $config | ConvertFrom-Yaml -Ordered
        foreach ($n in 1..23) {
            $doc.notification.successesBeforeRearm = $n
            $null = Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Writer "w$n" -Confirm:$false
        }
        $journal = @(Get-TestConfigJournal -ConfigPath $config)
        Assert-Equal -Expected 20 -Actual $journal.Count
        Assert-Equal -Expected 'w23' -Actual $journal[0].Writer -Because 'the newest entry survives the prune'
    }

    It 'restores the last version that parsed over a broken file, keeping the broken one' {
        $config = New-ConfigFixture -Start 7
        $doc = Get-Content -Raw -LiteralPath $config | ConvertFrom-Yaml -Ordered
        $doc.notification.successesBeforeRearm = 8
        $null = Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Writer 'edit' -Confirm:$false
        Set-Content -LiteralPath $config -Value "notification: [unclosed`n"
        $result = Restore-TestConfigFromJournal -ConfigPath $config -Confirm:$false
        Assert-True $result.Wrote 'the restore wrote'
        Assert-Equal -Expected 7 -Actual (Get-Counter -ConfigPath $config) -Because 'the newest entry that parses is the version before the last write'
        Assert-True ($result.Saved -and (Get-Content -Raw -LiteralPath $result.Saved) -match 'unclosed') 'the replaced broken file is journaled, so the restore is undoable'
    }

    It 'reports each value a restore replaces as previous -> restored, before writing' {
        $config = New-ConfigFixture -Start 0
        $doc = Get-Content -Raw -LiteralPath $config | ConvertFrom-Yaml -Ordered
        $doc.repositories.projectUrl = 'file:///srv/project'
        $null = Write-DocumentedTestConfig -ConfigPath $config -Config $doc -Writer 'operator' -Confirm:$false
        $older = @(Get-TestConfigJournal -ConfigPath $config)[0].Path
        $warnings = @(Restore-TestConfigFromJournal -ConfigPath $config -EntryPath $older -Confirm:$false 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        Assert-True (@($warnings | Where-Object { $_ -match 'repositories\.projectUrl: file:///srv/project -> ' }).Count -eq 1) `
            "the replaced operator value is on record: $($warnings -join ' | ')"
        $kept = @(Get-TestConfigJournal -ConfigPath $config)[0].Path
        Assert-True ((Get-Content -Raw -LiteralPath $kept) -match 'file:///srv/project') 'and recoverable from the journal'
    }
}

Describe 'the cycle-start overlay and the validator reconcile alike' {
    BeforeAll {
        $script:ReconcileTemplate = @"
vmStart:
  startTimeoutSeconds: 120
testCycle:
  cycleDelaySeconds: 30
"@
    }

    It 'writes the same file from the same input' {
        $dir = Join-Path $TestDrive 'parity'
        $null = New-Item -ItemType Directory -Path $dir
        $template = Join-Path $dir 'template.yml'
        Set-Content -LiteralPath $template -Value $script:ReconcileTemplate
        $seed = "hostSshServer: retired`nvmStart:`n  startTimeoutSeconds: 90`ntestCycle:`n  cycleDelaySeconds: 30`n"
        $overlayPath = Join-Path $dir 'overlay.yml'
        $validatorPath = Join-Path $dir 'validator.yml'
        Set-Content -LiteralPath $overlayPath -Value $seed
        Set-Content -LiteralPath $validatorPath -Value $seed
        $null = Update-TestConfigFromTemplate -ConfigPath $overlayPath -TemplatePath $template 6>$null
        $current = Get-Content -Raw -LiteralPath $validatorPath | ConvertFrom-Yaml -Ordered
        $templateDoc = Get-Content -Raw -LiteralPath $template | ConvertFrom-Yaml -Ordered
        $null = Sync-TestConfigToTemplate -Template $templateDoc -Current $current -ConfigPath $validatorPath -TemplatePath $template
        Assert-Equal -Expected (Get-Content -Raw -LiteralPath $overlayPath) -Actual (Get-Content -Raw -LiteralPath $validatorPath) `
            -Because 'the two entry points apply one reconciliation'
        Assert-False ((Get-Content -Raw -LiteralPath $validatorPath) -match 'hostSshServer') 'a deprecated key is dropped without being parked'
    }

    It 'reports the same changes to both' {
        $templateDoc = $script:ReconcileTemplate | ConvertFrom-Yaml -Ordered
        $current = "hostSshServer: retired`nextra:`n  key: kept-in-obsolete`nvmStart:`n  startTimeoutSeconds: 90`n" | ConvertFrom-Yaml -Ordered
        $r = Get-TestConfigReconciliation -Template $templateDoc -Current $current
        Assert-Equal -Expected 'extra.key' -Actual ($r.Dropped -join ',') -Because 'a populated orphan is dropped and listed; the deprecated key is not'
        Assert-Equal -Expected 'testCycle.cycleDelaySeconds' -Actual ($r.Added -join ',')
        Assert-Equal -Expected 90 -Actual $r.Config.vmStart.startTimeoutSeconds -Because 'operator values survive'
        Assert-True $current.Contains('hostSshServer') 'the caller''s object keeps its keys'
    }
}

Describe 'the cycle counter survives a status.json that does not parse' {
    BeforeAll {
        $script:SavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
        $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force
    }
    AfterAll {
        Restore-YurunaTestEnvironment -Saved $script:SavedRuntime
    }

    It 'continues numbering from the counter kept beside status.json' {
        $status = Join-Path $TestDrive 'status.json'
        Set-Content -LiteralPath $status -Value '{"cycle": 41, "history": []}'
        Initialize-StatusDocument -StatusFilePath $status -Hostname 'fixture' -GuestList @('g') -Confirm:$false 3>$null 6>$null
        Assert-Equal -Expected 42 -Actual (Read-StatusCycleCounter -StatusFilePath $status)
        Assert-Equal -Expected '42' -Actual (Get-Content -Raw -LiteralPath "$status.cycle").Trim() -Because 'the number the cycle took is kept beside status.json'
        Set-Content -LiteralPath $status -Value '{ broken'
        Reset-StatusDocumentForCycleStart -StatusFilePath $status -Confirm:$false 3>$null
        Initialize-StatusDocument -StatusFilePath $status -Hostname 'fixture' -GuestList @('g') -Confirm:$false 3>$null 6>$null
        $doc = Get-Content -Raw -LiteralPath $status | ConvertFrom-Json
        Assert-Equal -Expected 43 -Actual ([int]$doc.cycle) -Because 'a corrupt status.json no longer restarts the numbering at 1'
    }

    It 'reads the larger of the two when they disagree' {
        $status = Join-Path $TestDrive 'status2.json'
        Set-Content -LiteralPath $status -Value '{"cycle": 9}'
        Set-Content -LiteralPath "$status.cycle" -Value '12'
        Assert-Equal -Expected 12 -Actual (Read-StatusCycleCounter -StatusFilePath $status)
        Set-Content -LiteralPath "$status.cycle" -Value 'not a number'
        Assert-Equal -Expected 9 -Actual (Read-StatusCycleCounter -StatusFilePath $status)
    }
}

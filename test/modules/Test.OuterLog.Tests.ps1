<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4218a8b5-0788-4d72-b8ee-d63d1a86be71
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer-log pester
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
    Test.OuterLog's Write-OuterLog: the timestamped line lands in
    $env:YURUNA_RUNTIME_DIR/outer.log; an unset runtime directory or an
    unwritable log never throws and warns once; a fresh -NoProfile process
    resolves the writer from this module alone; and Test.RunnerOuterLoop,
    which existing callers and mocks name, still exposes it.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.OuterLog.psm1') -Force -DisableNameChecking
    $script:ModulePath = Join-Path $here 'Test.OuterLog.psm1'
    $script:OuterLoopPath = Join-Path $here 'Test.RunnerOuterLoop.psm1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }
    $script:HadRuntimeDir = Test-Path -LiteralPath Env:YURUNA_RUNTIME_DIR
    $script:SavedRuntimeDir = $env:YURUNA_RUNTIME_DIR

    function Reset-OuterLogWarning {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: resets the once-per-process warning flags of the module between cases.')]
        param()
        & (Get-Module Test.OuterLog) {
            $script:OuterLogRuntimeDirWarned = $false
            $script:OuterLogWriteWarned = $false
        }
    }

    # Removed, not set to '' or $null: an empty variable is still inherited
    # by every child process (feedback_setenvironmentvariable-null-sets-empty.md).
    function Restore-RuntimeDir {
        param()
        if ($script:HadRuntimeDir) { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntimeDir }
        else { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    }
}

Describe 'Write-OuterLog' {
    AfterEach { Restore-RuntimeDir }

    It 'appends a timestamped line to outer.log in the runtime directory' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-outerlog'
        try {
            $env:YURUNA_RUNTIME_DIR = $dir
            Write-OuterLog -Message 'cycle 12 started'
            Write-OuterLog -Message 'cycle 12 finished'
            $lines = @(Get-Content -LiteralPath (Join-Path $dir 'outer.log'))
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\S* cycle 12 started$'
            $lines[1] | Should -Match ' cycle 12 finished$'
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'warns once and never throws when the runtime directory is unset' {
        Reset-OuterLogWarning
        Mock -ModuleName Test.OuterLog Format-YurunaOperatorMessage { $Key }
        Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue
        # Called directly, not inside a { } | Should -Not -Throw block, so the
        # warning variables land in this scope; a throw fails the test anyway.
        $first = $null
        $second = $null
        Write-OuterLog -Message 'first' -WarningVariable first -WarningAction SilentlyContinue
        Write-OuterLog -Message 'second' -WarningVariable second -WarningAction SilentlyContinue
        $warnings = @(@($first) + @($second) | Where-Object { $_ })
        @($warnings).Count | Should -Be 1
        "$($warnings[0])" | Should -Be 'runner.outer_log_runtime_dir_unset'
        Should -Invoke -ModuleName Test.OuterLog Format-YurunaOperatorMessage -Times 1 -Exactly -ParameterFilter {
            $Key -eq 'runner.outer_log_runtime_dir_unset' -and $Arguments.message -eq 'first'
        }
    }

    It 'treats a blank runtime directory like an unset one' {
        Reset-OuterLogWarning
        Mock -ModuleName Test.OuterLog Format-YurunaOperatorMessage { $Key }
        $env:YURUNA_RUNTIME_DIR = ' '
        $w = $null
        Write-OuterLog -Message 'blank' -WarningVariable w -WarningAction SilentlyContinue
        "$(@($w)[0])" | Should -Be 'runner.outer_log_runtime_dir_unset'
    }

    It 'warns once, then only writes Verbose, when outer.log cannot be written' {
        Reset-OuterLogWarning
        Mock -ModuleName Test.OuterLog Format-YurunaOperatorMessage { $Key }
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-outerlog'
        try {
            $env:YURUNA_RUNTIME_DIR = Join-Path $dir 'missing/runtime'
            $first = $null
            $second = $null
            Write-OuterLog -Message 'lost' -WarningVariable first -WarningAction SilentlyContinue
            Write-OuterLog -Message 'lost again' -WarningVariable second -WarningAction SilentlyContinue
            @(@($first) | Where-Object { $_ }).Count | Should -Be 1
            "$(@($first)[0])" | Should -Be 'runner.operator_4ceb90c3873a42c7'
            @(@($second) | Where-Object { $_ }).Count | Should -Be 0
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'never throws under ErrorActionPreference Stop when the runtime directory names a drive that does not exist' {
        # Composing the path through the provider would raise "cannot find
        # drive" before any try, which a Stop preference turns into a throw.
        Reset-OuterLogWarning
        Mock -ModuleName Test.OuterLog Format-YurunaOperatorMessage { $Key }
        $env:YURUNA_RUNTIME_DIR = 'yurunanosuchdrive:/runtime'
        $savedPreference = $ErrorActionPreference
        $threw = $null
        $w = $null
        try {
            $ErrorActionPreference = 'Stop'
            Write-OuterLog -Message 'no drive' -WarningVariable w -WarningAction SilentlyContinue
        } catch {
            $threw = $_
        } finally { $ErrorActionPreference = $savedPreference }
        $threw | Should -BeNullOrEmpty
        "$(@($w)[0])" | Should -Be 'runner.operator_4ceb90c3873a42c7' -Because 'the unwritable log takes the warn-once path'
    }

    It 'resolves and writes in a fresh process that imports only this module' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-outerlog'
        try {
            $path = $script:ModulePath -replace "'", "''"
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 60 -Environment @{ YURUNA_RUNTIME_DIR = $dir } `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "Import-Module '$path' -DisableNameChecking; Write-OuterLog -Message 'fresh process'; exit 0")
            $r.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $dir 'outer.log') -Raw) | Should -Match ' fresh process'
        } finally { Remove-YurunaTestTempDir $dir }
    }
}

Describe 'Test.RunnerOuterLoop keeps exposing Write-OuterLog' {
    AfterEach { Restore-RuntimeDir }

    It 'resolves Write-OuterLog and lets a module-scoped mock intercept calls made inside that module' {
        Import-Module $script:OuterLoopPath -Force -DisableNameChecking
        (Get-Command -Module Test.RunnerOuterLoop -Name Write-OuterLog -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        & (Get-Module Test.RunnerOuterLoop) { Write-OuterLog -Message 'intercepted' }
        Should -Invoke -ModuleName Test.RunnerOuterLoop Write-OuterLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'intercepted' }
    }

    It 'serves the Test.OuterLog definition to a fresh process that imports only Test.RunnerOuterLoop' {
        $path = $script:OuterLoopPath -replace "'", "''"
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 90 `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-Command',
                "Import-Module '$path' -DisableNameChecking; `$c = Get-Command Write-OuterLog -ErrorAction Stop; Write-Output ('FILE=' + `$c.ScriptBlock.File); exit 0")
        $r.ExitCode | Should -Be 0
        $line = @(Get-BoundedNativeOutputLine -Result $r | Where-Object { $_ -like 'FILE=*' })
        $line.Count | Should -Be 1
        $line[0] | Should -Match 'Test\.OuterLog\.psm1$' -Because 'the outer loop re-exports the shared writer instead of carrying its own copy'
    }
}

<#PSScriptInfo
.VERSION 2026.10.30
.GUID 4237ad83-6e92-4eb7-a7bf-243c8271c38d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester runner
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Behavior of tools/Invoke-TestSuite.ps1: containment: per-suite temp folders, the single-suite shim, worker failures, leftover processes, the alone rerun and the startup JIT profile.
.DESCRIPTION
    Every case drives the real runner against a throwaway fixture tree through
    its -Root parameter (Test.SuiteRunnerFixture.psm1), so nothing depends on
    the state of this repository's own suites. A test runner that reports green
    when it should not is worse than none, because it is trusted, which is why
    failure cases outnumber success cases across the Test.SuiteRunner* suites.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.SuiteRunnerFixture.psm1') -Force -DisableNameChecking
    $script:Runner = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../tools/Invoke-TestSuite.ps1'))
    $script:PassingSuite = "Describe 'ok' { It 'a' { 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"
    $script:ThisPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $script:OtherPlatform = if ($script:ThisPlatform -eq 'windows') { 'linux' } else { 'windows' }
}

Describe 'each suite runs in a temp folder of its own that the runner removes' {
    BeforeAll {
        # What the fixture suite saw, written to the fixture root (outside the
        # suite's temp folder, which is gone by the time the test reads it).
        $script:ObserveTemp = @'
BeforeAll {
$record = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'temp-observed.txt'
$child = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -Command '[IO.Path]::GetTempPath()'
$tempPath = [IO.Path]::GetTempPath()
Set-Content -LiteralPath (Join-Path $tempPath 'left-by-a-test.txt') -Value 'leak'
@(
    "root=$env:YURUNA_TEST_TEMP_ROOT"
    "tmpdir=$env:TMPDIR"
    "tmp=$env:TMP"
    "temp=$env:TEMP"
    "diagnostics=$env:DOTNET_EnableDiagnostics"
    "path=$tempPath"
    "child=$child"
) | Set-Content -LiteralPath $record
}
'@
        function Read-ObservedTemp {
            param([string]$Root)
            $map = @{}
            foreach ($line in Get-Content -LiteralPath (Join-Path $Root 'temp-observed.txt')) {
                $name, $value = $line -split '=', 2
                $map[$name] = $value
            }
            $map
        }
        function Get-TrimmedPath { param([string]$Path) $Path.TrimEnd('/', '\') }
    }

    It 'points the suite and every child it starts at the same run-owned folder, keeps it until the run ends, then removes it' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body ($script:ObserveTemp + "`nDescribe 'contained' { It 'runs' { 1 | Should -Be 1 } }")
            # Beta starts alongside Alpha, waits for Alpha's record, then checks that
            # Alpha's folder survived Alpha's exit: the folder lives until the run ends.
            $beta = @'
BeforeAll {
    $fixtureRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $record = Join-Path $fixtureRoot 'temp-observed.txt'
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Test-Path -LiteralPath $record) -and @(Get-Content -LiteralPath $record).Count -ge 7) { break }
        Start-Sleep -Milliseconds 200
    }
    $alphaRoot = (@(Get-Content -LiteralPath $record) | Where-Object { $_ -like 'root=*' } | Select-Object -First 1).Substring(5)
    Start-Sleep -Seconds 3
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'beta-saw.txt') -Value ([string](Test-Path -LiteralPath $alphaRoot))
}
Describe 'b' { It 'c' { 1 | Should -Be 1 } }
'@
            Set-FixtureSuite -Root $root -Name 'Beta' -Body $beta
            $run = Invoke-Runner -Root $root -ThrottleLimit 2
            $run.ExitCode | Should -Be 0 -Because $run.Output
            Get-Content -LiteralPath (Join-Path $root 'beta-saw.txt') -Raw | Should -Match 'True' -Because 'Alpha''s folder outlived Alpha'
            $seen = Read-ObservedTemp -Root $root
            [IO.Path]::GetFileName($seen.root) | Should -Match '^yrn-suite-[0-9a-f]{12}$'
            $master = Split-Path -Parent $seen.root
            [IO.Path]::GetFileName($master) | Should -Match '^yrn-run-[0-9a-f]{12}$' -Because 'each suite folder sits in the run master'
            if (-not $IsWindows) {
                Split-Path -Parent $master | Should -Be '/tmp' -Because 'a short base keeps runtime socket paths under the Unix length cap'
            }
            foreach ($name in 'tmpdir', 'tmp', 'temp') { $seen[$name] | Should -BeExactly $seen.root -Because "$name must name the suite folder" }
            Get-TrimmedPath $seen.path | Should -BeExactly $seen.root
            Get-TrimmedPath $seen.child | Should -BeExactly $seen.root -Because 'a child process inherits the containment'
            $seen.diagnostics | Should -BeExactly '0'
            Test-Path -LiteralPath $seen.root | Should -BeFalse -Because 'the run removes the suite folder and what a test left in it when the run ends'
            Test-Path -LiteralPath $master | Should -BeFalse -Because 'the run removes its master folder when the run ends'
            @($run.Result.suites)[0].message | Should -Not -Match 'not fully removed'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'removes the folder of a suite it killed at the timeout' {
        $root = New-FixtureTree
        try {
            $body = $script:ObserveTemp + "`nDescribe 'hung' { It 'never returns' { Start-Sleep -Seconds 120 } }"
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $body
            $run = Invoke-Runner -Root $root -TimeoutSeconds 15
            $run.ExitCode | Should -Not -Be 0
            ($run.Result.problems -join ' ') | Should -Match 'rc=124'
            $seen = Read-ObservedTemp -Root $root
            [IO.Path]::GetFileName($seen.root) | Should -Match '^yrn-suite-[0-9a-f]{12}$'
            Test-Path -LiteralPath $seen.root | Should -BeFalse -Because 'nothing inside a killed worker can clean up, so the run must, when it ends'
            Test-Path -LiteralPath (Split-Path -Parent $seen.root) | Should -BeFalse -Because 'the run master goes with it'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the single-suite shim contains a direct run the same way' {
    It 'gives a direct run its own folder, restores the environment and removes the folder' {
        $root = New-FixtureTree
        try {
            $record = Join-Path $root 'shim-observed.txt'
            $suite = Join-Path $root 'test/modules/Alpha.Tests.ps1'
            $body = @'
Describe 'direct' {
    It 'records its temp root' {
        $record = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'shim-observed.txt'
        Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'left-by-a-test.txt') -Value 'leak'
        Set-Content -LiteralPath $record -Value "$env:YURUNA_TEST_TEMP_ROOT|$env:TMPDIR|$env:DOTNET_EnableDiagnostics"
    }
}
'@
            Set-Content -LiteralPath $suite -Value $body -Encoding utf8NoBOM
            $shim = Join-Path (Split-Path -Parent $script:Runner) '_InvokeOneSuite.ps1'
            $xml = Join-Path $root 'direct.xml'
            # Clear the variables a surrounding runner set, so the shim sees a direct run.
            $saved = @{}
            foreach ($name in 'YURUNA_TEST_TEMP_ROOT', 'TMPDIR', 'TMP', 'TEMP', 'DOTNET_EnableDiagnostics') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
            try {
                [Environment]::SetEnvironmentVariable('YURUNA_TEST_TEMP_ROOT', $null)
                $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $shim -Suite $suite -Xml $xml 2>&1 | Out-String
            } finally {
                foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
            }
            Test-Path -LiteralPath $record | Should -BeTrue -Because $output
            $folder, $tmpdir, $diagnostics = (Get-Content -LiteralPath $record -Raw).Trim() -split '\|'
            [IO.Path]::GetFileName($folder) | Should -Match '^yrn-suite-[0-9a-f]{12}$'
            $tmpdir | Should -BeExactly $folder
            $diagnostics | Should -BeExactly '0'
            Test-Path -LiteralPath $folder | Should -BeFalse
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'a worker failure or a leftover process never escapes the run' {
    It 'reports a failing worker as an incomplete suite and still finishes every other suite' {
        $root = New-FixtureTree
        try {
            $pidFile = Join-Path $root 'alpha.pid'
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body (@'
Describe 'alpha' {
    It 'runs while the other worker fails' {
        [IO.File]::WriteAllText('PIDFILE', "$PID")
        Start-Sleep -Seconds 6
        1 | Should -Be 1
    }
}
'@ -replace 'PIDFILE', ($pidFile -replace "'", "''"))
            Set-FixtureSuite -Root $root -Name 'Beta' -Body $script:PassingSuite
            # A directory with content where Beta's result file goes: clearing the
            # stale result fails inside Beta's worker before its suite starts.
            $blocked = Join-Path $root '.test-results/nunit-test_modules_Beta.Tests.ps1.xml'
            $null = New-Item -ItemType Directory -Force -Path $blocked
            [IO.File]::WriteAllText((Join-Path $blocked 'keep.txt'), 'in the way')
            $run = Invoke-Runner -Root $root -ThrottleLimit 2
            $run.ExitCode | Should -Be 1 -Because $run.Output
            $run.Result | Should -Not -BeNullOrEmpty -Because "the run must finish and report: $($run.Output)"
            $alpha = @($run.Result.suites | Where-Object path -EQ 'test/modules/Alpha.Tests.ps1')
            $alpha.Count | Should -Be 1
            $alpha[0].rc | Should -Be 0
            $alpha[0].failed | Should -Be 0
            $beta = @($run.Result.suites | Where-Object path -EQ 'test/modules/Beta.Tests.ps1')
            ($beta.Count -eq 1 -and -not $beta[0].haveXml) -or (@($run.Result.problems) -match 'suite worker error').Count -gt 0 |
                Should -BeTrue -Because ($run.Result.problems -join ' | ')
            $alphaPid = [int][IO.File]::ReadAllText($pidFile)
            Get-Process -Id $alphaPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'no suite process outlives the run'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stops and reports a process a passing suite left running, without changing its verdict' {
        $root = New-FixtureTree
        $leftPid = 0
        try {
            $pidFile = Join-Path $root 'left.pid'
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body (@'
Describe 'alpha' {
    It 'leaves a detached process behind' {
        $child = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') -PassThru
        [IO.File]::WriteAllText('PIDFILE', "$($child.Id)")
        1 | Should -Be 1
    }
}
'@ -replace 'PIDFILE', ($pidFile -replace "'", "''"))
            $run = Invoke-Runner -Root $root
            $run.ExitCode | Should -Be 0 -Because $run.Output
            $leftPid = [int][IO.File]::ReadAllText($pidFile)
            $row = @($run.Result.suites)[0]
            if ($IsWindows) {
                # Windows offers no read of another process's environment, so
                # nothing is found; the verdict is unchanged either way.
                @($row.leftovers).Count | Should -Be 0
            } else {
                @($row.leftovers) -join ' ' | Should -Match "\b$leftPid\b"
                @($run.Result.leftovers).Count | Should -Be 1
                Get-Process -Id $leftPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the leftover is stopped'
            }
        } finally {
            if ($leftPid) { Stop-Process -Id $leftPid -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'a failure in the parallel run is labeled by a run alone' {
    It 'labels a suite that passes alone load-sensitive and one that fails again as such, keeping both failures' {
        $root = New-FixtureTree
        try {
            $marker = Join-Path $root 'first-run.marker'
            # Fails while the marker is absent: the parallel run fails, the run alone passes.
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body (@'
Describe 'alpha' {
    It 'fails only the first time' {
        $first = -not (Test-Path -LiteralPath 'MARKER')
        [IO.File]::WriteAllText('MARKER', 'seen')
        $first | Should -BeFalse
    }
}
'@ -replace 'MARKER', ($marker -replace "'", "''"))
            Set-FixtureSuite -Root $root -Name 'Beta' -Body "Describe 'beta' { It 'always fails' { 1 | Should -Be 2 } }"
            Set-FixtureSuite -Root $root -Name 'Gamma' -Body $script:PassingSuite
            $run = Invoke-Runner -Root $root -ThrottleLimit 2
            $run.ExitCode | Should -Be 1 -Because 'the first result stays the verdict'
            $rows = @{}
            foreach ($row in @($run.Result.suites)) { $rows[[IO.Path]::GetFileName($row.path)] = $row }
            $rows['Alpha.Tests.ps1'].alone | Should -BeExactly 'passed'
            $rows['Alpha.Tests.ps1'].failed | Should -Be 1 -Because 'the parallel run''s failure is the row''s evidence'
            $rows['Beta.Tests.ps1'].alone | Should -BeExactly 'failed'
            $rows['Gamma.Tests.ps1'].PSObject.Properties['alone'] | Should -BeNullOrEmpty -Because 'a passing suite is not rerun'
            @($run.Result.loadSensitive) | Should -Be @('test/modules/Alpha.Tests.ps1')
            (@($run.Result.problems) -join "`n") | Should -Match 'Alpha\.Tests\.ps1: 1 failed, 0 error\(s\) -- passed when run alone after the parallel run: load-sensitive'
            (@($run.Result.problems) -join "`n") | Should -Match 'Beta\.Tests\.ps1: 1 failed, 0 error\(s\) -- failed again when run alone'
            Test-Path -LiteralPath (Join-Path $root '.test-results/nunit-test_modules_Alpha.Tests.ps1.alone.xml') | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the single-suite shim leaves the suite only its Pester preference' {
    It 'shows a directly run suite none of its working variables' {
        # A mock body or -ParameterFilter that reads an unbound name resolves it
        # by dynamic scope; a shim variable set only on a direct run (no temp
        # root handed down) would then answer differently than under the runner.
        $root = New-FixtureTree
        try {
            $suite = Join-Path $root 'test/modules/Alpha.Tests.ps1'
            $body = @'
Describe 'shim scope' {
    It 'sees none of the shim variables' {
        $seen = @(Get-Variable -Name name, value, tempBase, root, ownedTempRoot, savedTempEnvironment, savedStartupProfile, pesterModule, result, suitePath, xmlPath, Suite, Xml -ErrorAction SilentlyContinue | ForEach-Object Name)
        $seen | Should -BeNullOrEmpty
    }
    It 'still reads the Pester preference the shim set' {
        $PesterPreference.TestResult.Enabled.Value | Should -BeTrue
    }
}
'@
            Set-Content -LiteralPath $suite -Value $body -Encoding utf8NoBOM
            $shim = Join-Path (Split-Path -Parent $script:Runner) '_InvokeOneSuite.ps1'
            $xmlPath = Join-Path $root 'direct.xml'
            $savedTempRoot = [Environment]::GetEnvironmentVariable('YURUNA_TEST_TEMP_ROOT')
            try {
                [Environment]::SetEnvironmentVariable('YURUNA_TEST_TEMP_ROOT', $null)
                $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $shim -Suite $suite -Xml $xmlPath 2>&1 | Out-String
                $LASTEXITCODE | Should -Be 0 -Because $output
            } finally { [Environment]::SetEnvironmentVariable('YURUNA_TEST_TEMP_ROOT', $savedTempRoot) }
            $xml = [xml](Get-Content -LiteralPath $xmlPath -Raw)
            $xml.'test-results'.total | Should -Be '2'
            $xml.'test-results'.failures | Should -Be '0' -Because $xml.OuterXml
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'parallel suite workers avoid the shared startup JIT profile' {
    It 'disables startup profile reads and writes in the suite and its descendants through <Launcher>' -ForEach @(
        @{ Launcher = 'coordinator' }
        @{ Launcher = 'direct shim' }
    ) {
        $root = New-FixtureTree
        $savedProfile = [Environment]::GetEnvironmentVariable('DOTNET_MultiCoreJitProfile')
        $savedCache = [Environment]::GetEnvironmentVariable('XDG_CACHE_HOME')
        try {
            # A surrounding runner must not supply the protection under test.
            [Environment]::SetEnvironmentVariable('DOTNET_MultiCoreJitProfile', $null)
            [Environment]::SetEnvironmentVariable('XDG_CACHE_HOME', (Join-Path $root 'runner-cache'))
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body @'
Describe 'startup JIT profile containment' {
    It 'disables shared profile playback and recording in the worker' {
        $env:DOTNET_MultiCoreJitProfile | Should -BeExactly '(D)'
    }
    It 'does not create a startup profile in fresh descendant caches' {
        $cache = Join-Path $TestDrive 'child-cache'
        $null = New-Item -ItemType Directory -Path $cache
        $info = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $info.UseShellExecute = $false
        $info.Environment['XDG_CACHE_HOME'] = $cache
        foreach ($arg in @('-NoProfile', '-NonInteractive', '-Command',
            '1..20 | ForEach-Object { [Math]::Sqrt($_) } | Out-Null')) {
            $info.ArgumentList.Add($arg)
        }
        $child = [Diagnostics.Process]::Start($info)
        try {
            $child.WaitForExit(15000) | Should -BeTrue
            $child.ExitCode | Should -Be 0
        } finally {
            if (-not $child.HasExited) { $child.Kill($true) }
            $child.Dispose()
        }
        if (-not $IsWindows) { Test-Path -LiteralPath (Join-Path $cache 'powershell') | Should -BeTrue }
        @(Get-ChildItem -LiteralPath $cache -Recurse -File | Where-Object Name -Like 'StartupProfileData-*').Count | Should -Be 0
    }
}
'@
            if ($Launcher -eq 'coordinator') {
                $run = Invoke-Runner -Root $root
                $run.ExitCode | Should -Be 0 -Because $run.Output
                $run.Result.totals.tests | Should -Be 2
                $run.Result.totals.failed | Should -Be 0
            } else {
                $shim = Join-Path (Split-Path -Parent $script:Runner) '_InvokeOneSuite.ps1'
                $xmlPath = Join-Path $root 'direct.xml'
                $savedTempRoot = [Environment]::GetEnvironmentVariable('YURUNA_TEST_TEMP_ROOT')
                try {
                    [Environment]::SetEnvironmentVariable('YURUNA_TEST_TEMP_ROOT', $null)
                    $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $shim `
                        -Suite (Join-Path $root 'test/modules/Alpha.Tests.ps1') -Xml $xmlPath 2>&1 | Out-String
                    $LASTEXITCODE | Should -Be 0 -Because $output
                } finally { [Environment]::SetEnvironmentVariable('YURUNA_TEST_TEMP_ROOT', $savedTempRoot) }
                $xml = [xml](Get-Content -LiteralPath $xmlPath -Raw)
                $xml.'test-results'.total | Should -Be '2'
                $xml.'test-results'.failures | Should -Be '0' -Because $xml.OuterXml
            }
            [Environment]::GetEnvironmentVariable('DOTNET_MultiCoreJitProfile') | Should -BeNullOrEmpty -Because 'child containment must leave the calling environment unchanged'
        } finally {
            [Environment]::SetEnvironmentVariable('DOTNET_MultiCoreJitProfile', $savedProfile)
            [Environment]::SetEnvironmentVariable('XDG_CACHE_HOME', $savedCache)
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

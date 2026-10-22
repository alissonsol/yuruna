<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4201387d-cf87-45af-987c-08f11f4a809c
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
    Behavior of tools/Invoke-TestSuite.ps1 -- the five conditions that must fail
    a run, and the discovery contract underneath them.
.DESCRIPTION
    Every case here drives the real runner against a throwaway fixture tree via
    its -Root parameter, so nothing depends on the state of this repo's own
    suites.

    The reason the failure cases outnumber the success case: a test runner that
    reports green when it should not is worse than no runner, because it is
    trusted. Four of the five conditions are forms of SILENT test loss, none of
    which an exit code can express -- see the runner's own header for why rc is
    unusable on the standalone Pester path.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $script:Runner = Join-Path $repoRoot 'tools/Invoke-TestSuite.ps1'

    # A fixture tree, not this repo: the runner must be exercised against
    # suites whose pass/fail shape is chosen by the test, not inherited.
    function New-FixtureTree {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates a throwaway temp tree; nothing to confirm.')]
        [CmdletBinding()]
        param()
        $root = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-runner-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'test/modules')
        $root
    }

    function Set-FixtureSuite {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Writes into a throwaway temp tree; nothing to confirm.')]
        [CmdletBinding()]
        param([string]$Root, [string]$Name, [string]$Body)
        Set-Content -LiteralPath (Join-Path $Root "test/modules/$Name.Tests.ps1") -Value $Body -Encoding utf8NoBOM
    }

    # NUnit metadata must not make fixture execution depend on a live-host CIM query.
    function New-FixtureRunner {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Copies tools only into a throwaway suite fixture tree.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Root)
        $fixtureRoot = (Resolve-Path -LiteralPath $Root).Path
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $fixtureRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($fixtureRoot) -notlike 'yuruna-runner-*') {
            throw 'The private runner copy requires a throwaway SuiteRunner fixture root.'
        }
        $directory = Join-Path $fixtureRoot '.runner-tools'
        $null = New-Item -ItemType Directory -Force -Path $directory
        $runner = Join-Path $directory 'Invoke-TestSuite.ps1'
        $shim = Join-Path $directory '_InvokeOneSuite.ps1'
        [IO.File]::WriteAllBytes($runner, [IO.File]::ReadAllBytes($script:Runner))
        $shimText = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $script:Runner) '_InvokeOneSuite.ps1'))
        $marker = '    Import-Module $pesterModule.Path -Force -ErrorAction Stop'
        if ([regex]::Matches($shimText, [regex]::Escape($marker)).Count -ne 1) {
            throw 'The fixture shim cannot identify exactly one Pester import.'
        }
        $fixtureMetadata = @(
            '    if ($IsWindows) {'
            '        & (Get-Module Pester) {'
            '            if ($null -eq $script:SafeCommands -or -not $script:SafeCommands.ContainsKey(''Get-CimInstance'')) {'
            '                throw ''The fixture Pester exporter has no guarded OS query slot.'''
            '            }'
            '            $script:SafeCommands[''Get-CimInstance''] = {'
            '                [CmdletBinding()]'
            '                param([Parameter(Mandatory, Position=0)][string]$ClassName)'
            '                if ($ClassName -cne ''Win32_OperatingSystem'' -or $PSBoundParameters.Count -ne 1) {'
            '                    throw ''The fixture exporter permits only its OS metadata query.'''
            '                }'
            '                [pscustomobject]@{ Name=''SuiteRunner fixture OS''; Version=''0.0.0.0'' }'
            '            }'
            '        }'
            '    }'
        ) -join "`n"
        $separator = if ($shimText.Contains("`r`n")) { "`r`n" } else { "`n" }
        $fixtureMetadata = ($fixtureMetadata -replace "`r?`n", $separator)
        [IO.File]::WriteAllText($shim, $shimText.Replace($marker, $marker + $separator + $fixtureMetadata), [Text.UTF8Encoding]::new($false))
        return $runner
    }

    # Returns the parsed suite-results.json plus the exit code, which is the
    # pair every caller of the runner actually consumes.
    function Invoke-Runner {
        param([string]$Root, [switch]$UpdateBaseline, [switch]$RegisterNewSuites, [switch]$ListOnly, [string]$Filter, [string]$Path, [int]$TimeoutSeconds,
            [switch]$FailFast, [ValidateRange(1, 8)][int]$ThrottleLimit = 1)
        $fixtureRunner = New-FixtureRunner -Root $Root
        $argv = @('-NoProfile', '-File', $fixtureRunner, '-Root', $Root, '-ThrottleLimit', [string]$ThrottleLimit, '-Quiet')
        if ($FailFast) { $argv += '-FailFast' }
        if ($TimeoutSeconds) { $argv += @('-TimeoutSeconds', "$TimeoutSeconds") }
        if ($UpdateBaseline) { $argv += '-UpdateBaseline' }
        if ($RegisterNewSuites) { $argv += '-RegisterNewSuites' }
        if ($ListOnly) { $argv += '-ListOnly' }
        if ($Filter) { $argv += @('-Filter', $Filter) }
        if ($Path) { $argv += @('-Path', $Path) }
        $output = & (Get-Process -Id $PID).Path @argv 2>&1 | Out-String
        $rc = $LASTEXITCODE
        $output = ($output -replace '\e\[[0-9;?]*[A-Za-z]', '') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
        $resultFile = Join-Path $Root '.test-results/suite-results.json'
        $json = if (Test-Path -LiteralPath $resultFile) {
            Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        } else { $null }
        [pscustomobject]@{ ExitCode = $rc; Result = $json; Output = $output }
    }

    $script:PassingSuite = "Describe 'ok' { It 'a' { 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"
    $script:ThisPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $script:OtherPlatform = if ($script:ThisPlatform -eq 'windows') { 'linux' } else { 'windows' }

    # The reviewed hand edit a baseline row gets: set fields on one row, then make the
    # totals block agree with the rows again, as the runner requires of a baseline it refreshes.
    function Set-BaselineRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Edits a baseline inside a throwaway temp tree; nothing to confirm.')]
        [CmdletBinding()]
        param([string]$Root, [string]$Suite, [hashtable]$Field)
        $path = Join-Path $Root 'test/modules/suite-baseline.json'
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $row = $document.suites.PSObject.Properties["test/modules/$Suite.Tests.ps1"].Value
        foreach ($name in $Field.Keys) { $row | Add-Member -NotePropertyName $name -NotePropertyValue $Field[$name] -Force }
        $rows = @($document.suites.PSObject.Properties.Value)
        $document.totals.tests = [int]($rows | Measure-Object total -Sum).Sum
        $document.totals.skipped = [int]($rows | Measure-Object skipped -Sum).Sum
        $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    }
    function Get-BaselineRow {
        param([string]$Root, [string]$Suite)
        $document = Get-Content -LiteralPath (Join-Path $Root 'test/modules/suite-baseline.json') -Raw | ConvertFrom-Json
        [pscustomobject]@{ Row = $document.suites.PSObject.Properties["test/modules/$Suite.Tests.ps1"].Value; Totals = $document.totals }
    }
}

Describe 'fail-fast never turns cancelled work into passing evidence' {
    BeforeEach { $script:FailFastRoot = New-FixtureTree }
    AfterEach {
        $absolute = [IO.Path]::GetFullPath($script:FailFastRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $absolute.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($absolute) -notlike 'yuruna-runner-*') { throw 'invalid fail-fast fixture cleanup path' }
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }

    It 'retains the full suite census while refusing to launch work after a serial failure' {
        Set-FixtureSuite -Root $script:FailFastRoot -Name Alpha -Body "Describe 'fail' { It 'fails' { 1 | Should -Be 2 } }"
        Set-FixtureSuite -Root $script:FailFastRoot -Name Beta -Body @'
BeforeAll { [IO.File]::WriteAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'unexpected-launch'), 'launched') }
Describe 'slow' { It 'waits' { Start-Sleep -Seconds 30 } }
'@
        $run = Invoke-Runner -Root $script:FailFastRoot -FailFast -UpdateBaseline
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Result.suites | Should -HaveCount 2
        $run.Result.totals.failed | Should -Be 1
        $run.Result.totals.incomplete | Should -Be 1
        $cancelled = $run.Result.suites | Where-Object path -LIKE '*Beta*'
        $cancelled.rc | Should -Be 125
        $cancelled.haveXml | Should -BeFalse
        $cancelled.message | Should -Match 'not launched'
        $run.Result.problems[0] | Should -Match 'Alpha.Tests.ps1.*1 failed'
        $run.Result.problems[0] | Should -Match 'FAIL  fail.fails'
        Test-Path -LiteralPath (Join-Path $script:FailFastRoot 'test/unexpected-launch') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:FailFastRoot 'test/modules/suite-baseline.json') | Should -BeFalse
    }

    It 'stops only its running owned sibling and preserves the original failure' {
        Set-FixtureSuite -Root $script:FailFastRoot -Name Alpha -Body @'
BeforeAll {
    $ready = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'beta-owner.json'
    $limit = [DateTime]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($ready)) {
        if ([DateTime]::UtcNow -gt $limit) { throw 'the sibling did not start' }
        Start-Sleep -Milliseconds 20
    }
}
Describe 'fail' { It 'fails' { 1 | Should -Be 2 } }
'@
        Set-FixtureSuite -Root $script:FailFastRoot -Name Beta -Body @'
BeforeAll {
    $owned = [Diagnostics.Process]::GetCurrentProcess()
    try {
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'beta-owner.json'),
            (@{ pid = $PID; started = $owned.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json))
    } finally { $owned.Dispose() }
    Start-Sleep -Seconds 30
}
Describe 'slow' { It 'passes' { 1 | Should -Be 1 } }
'@
        $run = Invoke-Runner -Root $script:FailFastRoot -FailFast -ThrottleLimit 2
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Result.suites | Should -HaveCount 2
        $run.Result.totals.failed | Should -Be 1
        $row = $run.Result.suites | Where-Object path -LIKE '*Beta*'
        $row.rc | Should -Be 125
        $row.haveXml | Should -BeFalse
        $row.message | Should -Match 'cancelled after another suite failed'
        $identity = Get-Content -LiteralPath (Join-Path $script:FailFastRoot 'test/beta-owner.json') -Raw | ConvertFrom-Json
        $probe = $null
        try { $probe = [Diagnostics.Process]::GetProcessById($identity.pid) }
        catch [ArgumentException] { Write-Debug 'the cancelled owned sibling is absent' }
        if ($probe) {
            try { $probe.StartTime.ToUniversalTime().Ticks | Should -Not -Be $identity.started }
            finally { $probe.Dispose() }
        }
    }

    It 'executes every suite and permits a baseline refresh when all suites pass' {
        foreach ($name in @('Alpha', 'Beta')) { Set-FixtureSuite -Root $script:FailFastRoot -Name $name -Body $script:PassingSuite }
        $run = Invoke-Runner -Root $script:FailFastRoot -FailFast -ThrottleLimit 2 -UpdateBaseline
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Result.suites | Should -HaveCount 2
        $run.Result.totals.tests | Should -Be 4
        $run.Result.totals.incomplete | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:FailFastRoot 'test/modules/suite-baseline.json') | Should -BeTrue
    }
}

Describe 'a clean tree passes and reports what ran' {
    It 'exits 0 and counts every test' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-FixtureSuite -Root $root -Name 'Beta'  -Body 'Describe ''b'' { It ''c'' { 1 | Should -Be 1 } }'
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Be 0
            $r.Result.totals.suites | Should -Be 2
            $r.Result.totals.tests  | Should -Be 3
            $r.Result.totals.failed | Should -Be 0
            $r.Result.problems      | Should -BeNullOrEmpty
            if ($IsWindows) {
                [xml]$xml = Get-Content -LiteralPath (Join-Path $root '.test-results/nunit-test_modules_Alpha.Tests.ps1.xml') -Raw
                $xml.'test-results'.environment.platform | Should -BeExactly 'SuiteRunner fixture OS'
                $xml.'test-results'.environment.'os-version' | Should -BeExactly '0.0.0.0'
            }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes one result row per discovered suite' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            $r = Invoke-Runner -Root $root
            @($r.Result.suites).Count | Should -Be 1
            @($r.Result.suites)[0].path | Should -Match 'Alpha\.Tests\.ps1$'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the five conditions that must fail a run' {
    It 'fails when a suite reports failing tests' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Bad' -Body "Describe 'bad' { It 'fails' { throw 'boom' } }"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'failed'

            Set-FixtureSuite -Root $root -Name 'Bad' -Body "Describe 'background input' { It 'requests operator input' { Read-Host 'No operator can answer this' } }"
            $prompt = Invoke-Runner -Root $root -TimeoutSeconds 5
            $prompt.ExitCode | Should -Be 1
            $prompt.Result.totals.incomplete | Should -Be 0 -Because 'an input request must fail before the suite timeout'
            $prompt.Result.totals.failed | Should -Be 1
            [xml]$evidence = Get-Content -LiteralPath (Join-Path $root '.test-results/nunit-test_modules_Bad.Tests.ps1.xml') -Raw
            $evidence.SelectSingleNode('//test-case/failure/message').InnerText | Should -Match 'NonInteractive'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a suite discovers zero tests, which otherwise reads as green' {
        $root = New-FixtureTree
        try {
            # The shape a BeforeAll that quietly empties a fixture set produces:
            # the file parses, Pester runs, and nothing is collected.
            Set-FixtureSuite -Root $root -Name 'Empty' -Body "Describe 'nothing' { if (`$false) { It 'never' { } } }"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'discovered 0 tests'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a suite process dies before writing a result file' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Crash' -Body "throw 'exploded before any Describe'"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'no result file'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a suite in the baseline has vanished' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-FixtureSuite -Root $root -Name 'Beta'  -Body 'Describe ''b'' { It ''c'' { 1 | Should -Be 1 } }'
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0

            Remove-Item -LiteralPath (Join-Path $root 'test/modules/Beta.Tests.ps1') -Force
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'not in this run'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails when a surviving suite quietly lost tests' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0

            Set-FixtureSuite -Root $root -Name 'Alpha' -Body "Describe 'ok' { It 'a' { 1 | Should -Be 1 } }"
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Not -Be 0
            ($r.Result.problems -join ' ') | Should -Match 'tests disappeared'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'a baseline row can carry a platform floor and a timeout of its own' {
    It 'holds a platform to its own floor, and only that platform' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0

            # The reference host had three tests here; this platform legitimately defines two.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ total = 3; platformTotal = [pscustomobject]@{ $script:ThisPlatform = 2 } }
            $met = Invoke-Runner -Root $root
            ($met.Result.problems -join ' ') | Should -Not -Match 'tests disappeared'
            $met.ExitCode | Should -Be 0

            # The same floor is still a floor: a suite under it has lost tests.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ platformTotal = [pscustomobject]@{ $script:ThisPlatform = 3 } }
            $below = Invoke-Runner -Root $root
            $below.ExitCode | Should -Not -Be 0
            ($below.Result.problems -join ' ') | Should -Match 'tests disappeared'

            # A floor for another platform does not excuse this one: it is held to `total`.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ platformTotal = [pscustomobject]@{ $script:OtherPlatform = 1 } }
            $other = Invoke-Runner -Root $root
            $other.ExitCode | Should -Not -Be 0
            ($other.Result.problems -join ' ') | Should -Match 'tests disappeared'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps both fields and the reference count when the baseline is refreshed' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ total = 3; platformTotal = [pscustomobject]@{ $script:ThisPlatform = 2 }; timeoutSeconds = 77 }

            $refresh = Invoke-Runner -Root $root -UpdateBaseline
            $refresh.ExitCode | Should -Be 0 -Because $refresh.Output
            $kept = Get-BaselineRow -Root $root -Suite 'Alpha'
            $kept.Row.total | Should -Be 3 -Because 'a run on a platform with a lower floor must not lower the reference count'
            $kept.Row.platformTotal.$($script:ThisPlatform) | Should -Be 2
            $kept.Row.timeoutSeconds | Should -Be 77
            $kept.Totals.tests | Should -Be 3 -Because 'the totals are the sum of the rows written'

            # And a row with no floor of its own is still refused when it loses tests.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ platformTotal = $null }
            $document = Get-Content -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json') -Raw | ConvertFrom-Json
            $document.suites.PSObject.Properties['test/modules/Alpha.Tests.ps1'].Value.PSObject.Properties.Remove('platformTotal')
            $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json') -Encoding utf8NoBOM
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Not -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'gives one suite a longer cap than its recorded cost earns, and never a shorter one' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            # A recorded cost of zero makes the cap exactly -TimeoutSeconds.
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ seconds = 0 }
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body "Describe 'slow' { It 'a' { Start-Sleep -Seconds 6; 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"

            $capped = Invoke-Runner -Root $root -TimeoutSeconds 2
            $capped.ExitCode | Should -Not -Be 0
            ($capped.Result.problems -join ' ') | Should -Match 'rc=124'

            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ timeoutSeconds = 120 }
            $raised = Invoke-Runner -Root $root -TimeoutSeconds 2
            $raised.ExitCode | Should -Be 0 -Because "the row names 120 s; output: $($raised.Output)"

            # A row cannot shorten the cap the flat allowance gives: a normal start takes over a second.
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field @{ timeoutSeconds = 1 }
            (Invoke-Runner -Root $root -TimeoutSeconds 120).ExitCode | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to refresh a baseline whose row carries a malformed <Kind>' -TestCases @(
        @{ Kind = 'platform name'; Field = @{ platformTotal = [pscustomobject]@{ solaris = 1 } } }
        @{ Kind = 'platform floor'; Field = @{ platformTotal = [pscustomobject]@{ macos = 0 } } }
        @{ Kind = 'timeout'; Field = @{ timeoutSeconds = 'soon' } }
    ) {
        param($Kind, $Field)
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            Set-BaselineRow -Root $root -Suite 'Alpha' -Field $Field
            $before = (Get-FileHash -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json')).Hash
            $refused = Invoke-Runner -Root $root -UpdateBaseline
            $refused.ExitCode | Should -Not -Be 0 -Because "a malformed $Kind must not be refreshed over"
            $refused.Output | Should -Match 'baseline is unreadable'
            (Get-FileHash -LiteralPath (Join-Path $root 'test/modules/suite-baseline.json')).Hash | Should -Be $before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the invocation contract the three file-scope-fixture suites depend on' {
    It 'runs a suite whose fixtures are assigned at file scope' {
        # This is the shape that fails under Invoke-Pester -Path: the fixture is
        # bound during discovery and is gone by the time the It body runs. The
        # runner must keep such a suite working, because the repo has three.
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'FileScope' -Body @'
$fixture = 'bound-at-file-scope'
Describe 'file-scope fixture' {
    It 'sees the fixture' { $fixture | Should -Be 'bound-at-file-scope' }
}
'@
            $r = Invoke-Runner -Root $root
            $r.ExitCode | Should -Be 0
            $r.Result.totals.tests  | Should -Be 1
            $r.Result.totals.failed | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'discovery' {
    It 'checks only selected baseline suites while retaining missing-suite detection' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-FixtureSuite -Root $root -Name 'Beta' -Body $script:PassingSuite
            $hostDir = Join-Path $root 'host/modules'
            $null = New-Item -ItemType Directory -Path $hostDir -Force
            Set-Content -LiteralPath (Join-Path $hostDir 'Host.Tests.ps1') -Value $script:PassingSuite
            (Invoke-Runner -Root $root -UpdateBaseline).ExitCode | Should -Be 0
            (Invoke-Runner -Root $root -Filter 'Alpha*').ExitCode | Should -Be 0
            (Invoke-Runner -Root $root -Path 'test/modules').ExitCode | Should -Be 0
            Remove-Item -LiteralPath (Join-Path $root 'test/modules/Beta.Tests.ps1') -Force
            $missing = Invoke-Runner -Root $root -Filter '*.Tests.ps1' -Path 'test/modules'
            $missing.ExitCode | Should -Not -Be 0
            ($missing.Result.problems -join ' ') | Should -Match 'Beta.Tests.ps1.*not in this run'
            ($missing.Result.problems -join ' ') | Should -Not -Match 'Host.Tests.ps1'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'honors -Filter on the suite file name' {
        $root = New-FixtureTree
        try {
            Set-FixtureSuite -Root $root -Name 'Alpha' -Body $script:PassingSuite
            Set-FixtureSuite -Root $root -Name 'Beta'  -Body $script:PassingSuite
            $fixtureRunner = New-FixtureRunner -Root $root
            $null = & (Get-Process -Id $PID).Path -NoProfile -File $fixtureRunner -Root $root -Filter 'Alpha*' -Quiet 2>&1
            $json = Get-Content -LiteralPath (Join-Path $root '.test-results/suite-results.json') -Raw | ConvertFrom-Json
            $json.totals.suites | Should -Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'finds every tracked suite in this repo' {
        # Discovery only (-ListOnly), so this neither re-runs the suite set nor
        # reads a previous run's artifact -- an artifact written before the last
        # suite was added would race against the git listing below.
        $here     = Split-Path -Parent $PSCommandPath
        $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
        Push-Location $repoRoot
        try {
            # The runner's own selector: tracked PLUS new-but-uncommitted,
            # minus anything .gitignore covers. A suite must be runnable the
            # moment it is written, not the moment it is committed, so a bare
            # `git ls-files` here would under-count by exactly the new files.
            $tracked = @(git ls-files --cached --others --exclude-standard |
                    Where-Object { $_ -match '\.Tests\.ps1$' } |
                    Where-Object { $_ -like 'test/modules/*' -or $_ -like 'host/modules/*' } |
                    Sort-Object -Unique)
            $found = @(& (Get-Process -Id $PID).Path -NoProfile -File $script:Runner -ListOnly)
            $tracked.Count | Should -BeGreaterThan 100
            $found.Count   | Should -Be $tracked.Count
            (Compare-Object $tracked $found) | Should -BeNullOrEmpty
        } finally { Pop-Location }
    }
}

Describe 'new suite registration preserves the historical protection floor' {
    BeforeEach {
        $script:RegistrationRoot = New-FixtureTree
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Alpha -Body $script:PassingSuite
        $script:RegistrationBaseline = Join-Path $script:RegistrationRoot 'test/modules/suite-baseline.json'
        $historical = [ordered]@{
            schemaVersion=1; recordedUtc='2026-09-01T00:00:00Z'; pesterVersion='6.2.0'
            totals=[ordered]@{suites=1;tests=2;failed=0;skipped=0}
            suites=[ordered]@{'test/modules/Alpha.Tests.ps1'=[ordered]@{total=2;skipped=0;seconds=7.25}}
        }
        $script:RegistrationBefore = $historical | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($script:RegistrationBaseline, $script:RegistrationBefore)
    }
    AfterEach {
        Remove-Item -LiteralPath $script:RegistrationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'registers every new passing suite without rewriting old rows or claiming a full run' {
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Alpha -Body "Describe 'old failure' { It 'still fails' { throw 'existing failure' } }"
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Beta -Body $script:PassingSuite
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Gamma -Body $script:PassingSuite
        $result = Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites
        $result.ExitCode | Should -Be 0
        $result.Result.scope | Should -Be 'new-suite-registration'
        $result.Result.totals.suites | Should -Be 2
        $result.Result.totals.tests | Should -Be 4
        $after = Get-Content -Raw $script:RegistrationBaseline | ConvertFrom-Json
        $before = $script:RegistrationBefore | ConvertFrom-Json
        ($after.suites.'test/modules/Alpha.Tests.ps1' | ConvertTo-Json) | Should -Be ($before.suites.'test/modules/Alpha.Tests.ps1' | ConvertTo-Json)
        $after.recordedUtc | Should -Be $before.recordedUtc
        $after.totals.suites | Should -Be 3
        $after.totals.tests | Should -Be 6
        $after.totals.skipped | Should -Be 0
        $after.registrations.Count | Should -Be 1
        $after.registrations[0].suites | Should -Be @('test/modules/Beta.Tests.ps1','test/modules/Gamma.Tests.ps1')
        $after.registrations[0].sourceSha256.'test/modules/Beta.Tests.ps1' | Should -Be (Get-FileHash (Join-Path $script:RegistrationRoot 'test/modules/Beta.Tests.ps1')).Hash
        $full = Invoke-Runner -Root $script:RegistrationRoot
        $full.ExitCode | Should -Be 1
        ($full.Result.problems -join ' ') | Should -Match 'Alpha.Tests.ps1.*failed'
        ($full.Result.problems -join ' ') | Should -Match 'tests disappeared'
    }
    It 'preserves the file byte for byte when any new suite is <Kind>' -TestCases @(
        @{Kind='failing';Body="Describe 'bad' { It 'fails' { throw 'fixture failure' } }"}
        @{Kind='skipped';Body="Describe 'skip' { It 'not verified' -Skip { } }"}
        @{Kind='empty';Body="Describe 'empty' { }"}
        @{Kind='crashed';Body="throw 'discovery crash'"}
    ) {
        param($Kind, $Body)
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Good -Body $script:PassingSuite
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Unverified -Body $Body
        $result = Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites
        $result.ExitCode | Should -Be 1 -Because $Kind
        Get-Content -Raw $script:RegistrationBaseline | Should -BeExactly $script:RegistrationBefore
    }
    It 'refuses deleted historical suites before running new suites' {
        Remove-Item (Join-Path $script:RegistrationRoot 'test/modules/Alpha.Tests.ps1')
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Beta -Body $script:PassingSuite
        (Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites).ExitCode | Should -Be 1
        Test-Path (Join-Path $script:RegistrationRoot '.test-results') | Should -BeFalse
        Get-Content -Raw $script:RegistrationBaseline | Should -BeExactly $script:RegistrationBefore
    }
    It 'refuses restricted discovery and incompatible update modes' -TestCases @(
        @{Extra=@{Filter='Beta*'}}, @{Extra=@{Path='test/modules'}},
        @{Extra=@{ListOnly=$true}}, @{Extra=@{UpdateBaseline=$true}}
    ) {
        param($Extra)
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Beta -Body $script:PassingSuite
        (Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites @Extra).ExitCode | Should -Be 2
        Get-Content -Raw $script:RegistrationBaseline | Should -BeExactly $script:RegistrationBefore
    }
    It 'requires an existing valid baseline' {
        Remove-Item $script:RegistrationBaseline
        (Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites).ExitCode | Should -Be 2
        Test-Path $script:RegistrationBaseline | Should -BeFalse
        Set-Content $script:RegistrationBaseline '{invalid json'
        (Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites).ExitCode | Should -Be 2
        (Get-Content -Raw $script:RegistrationBaseline).Trim() | Should -Be '{invalid json'
    }
    It 'does nothing when every suite is already registered' {
        (Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites).ExitCode | Should -Be 0
        Get-Content -Raw $script:RegistrationBaseline | Should -BeExactly $script:RegistrationBefore
        Test-Path (Join-Path $script:RegistrationRoot '.test-results') | Should -BeFalse
    }
    It 'refuses source changes made by the suite while it is running' {
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Beta -Body @'
Describe 'changing source' {
    It 'passes' { 1 | Should -Be 1 }
    AfterAll { Add-Content -LiteralPath $PSCommandPath -Value '# modified during execution' }
}
'@
        $result = Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites
        $result.ExitCode | Should -Be 1
        ($result.Result.problems -join ' ') | Should -Match 'Suite source changed'
        Get-Content -Raw $script:RegistrationBaseline | Should -BeExactly $script:RegistrationBefore
    }
    It 'refuses discovery changes made by the suite while it is running' {
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Beta -Body @'
Describe 'changing discovery' {
    It 'passes' { 1 | Should -Be 1 }
    AfterAll { Set-Content (Join-Path $PSScriptRoot 'Extra.Tests.ps1') "Describe 'extra' { It 'unverified' { } }" }
}
'@
        $result = Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites
        $result.ExitCode | Should -Be 1
        ($result.Result.problems -join ' ') | Should -BeLike '*discovery changed*'
        Get-Content -Raw $script:RegistrationBaseline | Should -BeExactly $script:RegistrationBefore
    }
    It 'preserves a concurrent baseline edit instead of overwriting it' {
        Set-FixtureSuite -Root $script:RegistrationRoot -Name Beta -Body @'
Describe 'changing baseline' {
    It 'passes' { 1 | Should -Be 1 }
    AfterAll { Add-Content (Join-Path $PSScriptRoot 'suite-baseline.json') ' ' }
}
'@
        $result = Invoke-Runner -Root $script:RegistrationRoot -RegisterNewSuites
        $result.ExitCode | Should -Be 1
        ($result.Result.problems -join ' ') | Should -BeLike '*Baseline changed*'
        (Get-Content -Raw $script:RegistrationBaseline | ConvertFrom-Json).totals.suites | Should -Be 1
    }
}


Describe 'result reporting failures preserve diagnostics and evidence' {
    BeforeEach {
        $script:ReportingRoot = New-FixtureTree
        $script:ReportingDirectory = Join-Path $script:ReportingRoot '.test-results'
        $script:ReportingBaseline = Join-Path $script:ReportingRoot 'test/modules/suite-baseline.json'
        $script:ReportingXml = Join-Path $script:ReportingDirectory 'nunit-test_modules_Alpha.Tests.ps1.xml'
        $baseline = [ordered]@{
            schemaVersion = 1; recordedUtc = '2026-09-01T00:00:00Z'; pesterVersion = '6.2.0'
            totals = [ordered]@{ suites = 1; tests = 45; failed = 0; skipped = 0 }
            suites = [ordered]@{ 'test/modules/Alpha.Tests.ps1' = [ordered]@{ total = 45; skipped = 0; seconds = 1 } }
        }
        [IO.File]::WriteAllText($script:ReportingBaseline, ($baseline | ConvertTo-Json -Depth 6))
        $script:ReportingBaselineHash = (Get-FileHash -LiteralPath $script:ReportingBaseline).Hash
    }

    AfterEach {
        Remove-Item -LiteralPath $script:ReportingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'publishes a passing result and baseline while releasing its result-directory lock' {
        Remove-Item -LiteralPath $script:ReportingBaseline
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body "Describe 'new passing producer' { It 'passes' { 3 | Should -Be 3 } }"
        $run = Invoke-Runner -Root $script:ReportingRoot -UpdateBaseline
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Result.totals.tests | Should -Be 1
        $run.Result.totals.failed | Should -Be 0
        $run.Result.totals.incomplete | Should -Be 0
        $run.Result.problems | Should -BeNullOrEmpty
        $row = @($run.Result.suites)[0]
        $row.rc | Should -Be 0
        $row.haveXml | Should -BeTrue
        $baseline = Get-Content -LiteralPath $script:ReportingBaseline -Raw | ConvertFrom-Json
        $baseline.totals.suites | Should -Be 1
        $baseline.totals.tests | Should -Be 1
        $baseline.suites.'test/modules/Alpha.Tests.ps1'.total | Should -Be 1
        Test-Path -LiteralPath $row.stdoutLog -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $row.stderrLog -PathType Leaf | Should -BeTrue
        $archive = Join-Path (Split-Path -Parent $row.stdoutLog) 'suite-results.json'
        $current = Join-Path $script:ReportingDirectory 'suite-results.json'
        (Get-FileHash -LiteralPath $archive).Hash | Should -BeExactly (Get-FileHash -LiteralPath $current).Hash
        $lockPath = Join-Path $script:ReportingDirectory '.runner.lock'
        $released = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $released.CanWrite | Should -BeTrue
        } finally {
            $released.Dispose()
        }
    }

    It 'retains both diagnostic streams and refuses a baseline update when a suite returns without XML' {
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body @'
[Console]::Out.WriteLine('fixture stdout: result export never completed')
[Console]::Error.WriteLine('fixture stderr: writer detail')
'@
        $run = Invoke-Runner -Root $script:ReportingRoot -UpdateBaseline
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $row = @($run.Result.suites)[0]
        $row.rc | Should -Be 2
        $row.haveXml | Should -BeFalse
        $run.Result.totals.incomplete | Should -Be 1
        $run.Output | Should -Match '1 incomplete'
        $row.message | Should -Match 'fixture stdout: result export never completed'
        $row.message | Should -Match 'fixture stderr: writer detail'
        Get-Content -LiteralPath $row.stdoutLog -Raw | Should -Match 'fixture stdout: result export never completed'
        Get-Content -LiteralPath $row.stderrLog -Raw | Should -Match 'fixture stderr: writer detail'
        ($run.Result.problems -join ' ') | Should -Match 'fixture stdout: result export never completed'
        ($run.Result.problems -join ' ') | Should -Not -Match 'tests disappeared'
        (Get-FileHash -LiteralPath $script:ReportingBaseline).Hash | Should -BeExactly $script:ReportingBaselineHash
    }

    It 'retains Pester export diagnostics when the assertion passes but the result path is a directory' {
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body @'
$null = [IO.Directory]::CreateDirectory($Xml)
Describe 'result export failure' {
    It 'finishes its assertion before result export' {
        1 | Should -Be 1
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'assertion-completed'), 'assertion completed')
    }
}
'@
        $run = Invoke-Runner -Root $script:ReportingRoot -UpdateBaseline
        $run.ExitCode | Should -Be 1 -Because $run.Output
        Get-Content -LiteralPath (Join-Path $script:ReportingRoot 'test/modules/assertion-completed') -Raw |
            Should -BeExactly 'assertion completed'
        $row = @($run.Result.suites)[0]
        $row.rc | Should -Be 2
        $row.haveXml | Should -BeFalse
        $run.Result.totals.incomplete | Should -Be 1
        $diagnosticPattern = [regex]::Escape($script:ReportingXml) + '|UnauthorizedAccess|denied|directory'
        Get-Content -LiteralPath $row.stdoutLog -Raw | Should -Match $diagnosticPattern
        $row.message | Should -Match $diagnosticPattern
        ($run.Result.problems -join ' ') | Should -Not -Match 'tests disappeared'
        (Get-FileHash -LiteralPath $script:ReportingBaseline).Hash | Should -BeExactly $script:ReportingBaselineHash
    }

    It 'rejects a process that exits zero before the child can validate its result' {
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body @'
[Console]::Out.WriteLine('fixture abrupt zero exit')
[Environment]::Exit(0)
'@
        $run = Invoke-Runner -Root $script:ReportingRoot -UpdateBaseline
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $row = @($run.Result.suites)[0]
        $row.rc | Should -Be 0
        $row.haveXml | Should -BeFalse
        $run.Result.totals.incomplete | Should -Be 1
        ($run.Result.problems -join ' ') | Should -Match 'fixture abrupt zero exit'
        ($run.Result.problems -join ' ') | Should -Not -Match 'tests disappeared'
        (Get-FileHash -LiteralPath $script:ReportingBaseline).Hash | Should -BeExactly $script:ReportingBaselineHash
    }

    It 'rejects <Kind> XML without accepting missing test counts' -TestCases @(
        @{ Kind = 'malformed'; Xml = '<broken' }
        @{ Kind = 'a non-NUnit root in'; Xml = '<unrelated total="45" failures="0" errors="0" />' }
    ) {
        param($Kind, $Xml)
        $body = "[IO.File]::WriteAllText(`$PesterPreference.TestResult.OutputPath.Value, '" + $Xml.Replace("'", "''") + "')"
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body $body
        $run = Invoke-Runner -Root $script:ReportingRoot -UpdateBaseline
        $run.ExitCode | Should -Be 1 -Because "$Kind XML: $($run.Output)"
        @($run.Result.suites)[0].rc | Should -Be 2
        @($run.Result.suites)[0].haveXml | Should -BeFalse
        $run.Result.totals.incomplete | Should -Be 1
        ($run.Result.problems -join ' ') | Should -Not -Match 'tests disappeared'
        (Get-FileHash -LiteralPath $script:ReportingBaseline).Hash | Should -BeExactly $script:ReportingBaselineHash
    }

    It 'refuses an occupied result directory before replacing any existing evidence' {
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body "throw 'occupied result directory must prevent suite launch'"
        $null = New-Item -ItemType Directory -Path $script:ReportingDirectory
        [IO.File]::WriteAllText($script:ReportingXml, '<test-results total="45" failures="0" />')
        $reportPath = Join-Path $script:ReportingDirectory 'suite-results.json'
        [IO.File]::WriteAllText($reportPath, '{"previous":"result evidence"}')
        $xmlHash = (Get-FileHash -LiteralPath $script:ReportingXml).Hash
        $reportHash = (Get-FileHash -LiteralPath $reportPath).Hash
        $lockPath = Join-Path $script:ReportingDirectory '.runner.lock'
        $held = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $run = Invoke-Runner -Root $script:ReportingRoot -UpdateBaseline
            $run.ExitCode | Should -Be 1 -Because $run.Output
            $run.Output | Should -Match 'lock|already.*use|already.*running'
            $run.Output | Should -Not -Match 'must prevent suite launch'
            (Get-FileHash -LiteralPath $script:ReportingXml).Hash | Should -BeExactly $xmlHash
            (Get-FileHash -LiteralPath $reportPath).Hash | Should -BeExactly $reportHash
            (Get-FileHash -LiteralPath $script:ReportingBaseline).Hash | Should -BeExactly $script:ReportingBaselineHash
        } finally {
            $held.Dispose()
        }
    }

    It 'clears only selected stale XML and preserves results for suites excluded by a filter' {
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body "[Console]::Out.WriteLine('selected suite has no new XML')"
        Set-FixtureSuite -Root $script:ReportingRoot -Name Beta -Body "throw 'excluded suite must not execute'"
        $null = New-Item -ItemType Directory -Path $script:ReportingDirectory
        [IO.File]::WriteAllText($script:ReportingXml, '<test-results total="45" failures="0" errors="0" />')
        $otherXml = Join-Path $script:ReportingDirectory 'nunit-test_modules_Beta.Tests.ps1.xml'
        [IO.File]::WriteAllText($otherXml, '<test-results total="7" failures="0" errors="0" />')
        $otherHash = (Get-FileHash -LiteralPath $otherXml).Hash
        $run = Invoke-Runner -Root $script:ReportingRoot -Filter 'Alpha*'
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Result.totals.suites | Should -Be 1
        $run.Result.totals.incomplete | Should -Be 1
        @($run.Result.suites)[0].haveXml | Should -BeFalse
        Test-Path -LiteralPath $script:ReportingXml | Should -BeFalse
        (Get-FileHash -LiteralPath $otherXml).Hash | Should -BeExactly $otherHash
    }

    It 'keeps valid XML and the zero process status for ordinary assertion failures' {
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body "Describe 'reported assertion failure' { It 'fails' { 1 | Should -Be 2 } }"
        $run = Invoke-Runner -Root $script:ReportingRoot
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $row = @($run.Result.suites)[0]
        $row.rc | Should -Be 0
        $row.haveXml | Should -BeTrue
        $row.failed | Should -Be 1
        $row.total | Should -Be 1
        $run.Result.totals.incomplete | Should -Be 0
        ($run.Result.problems -join ' ') | Should -Match '1 failed'
        ($run.Result.problems -join ' ') | Should -Not -Match 'no result file'
        $row.message | Should -Match 'FAIL  reported assertion failure.fails'
        $row.message | Should -Match 'Expected 2, but got 1'
        $row.message | Should -Match 'Alpha.Tests.ps1:1'
        $row.message | Should -Match 'NUnit results:.*nunit-test_modules_Alpha.Tests.ps1.xml'
        $row.message | Should -Match 'Worker logs:'
        $run.Output | Should -Match 'Expected 2, but got 1'
    }

    It 'reports unexecuted tests when setup fails' {
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body "BeforeAll { throw 'fixture setup failed' }; Describe 'setup' { It 'cannot run' { 1 | Should -Be 1 } }"
        $run = Invoke-Runner -Root $script:ReportingRoot
        $run.ExitCode | Should -Be 1
        $row = @($run.Result.suites)[0]
        $row.haveXml | Should -BeTrue
        $row.message | Should -Match 'FAIL  setup.cannot run'
        $row.message | Should -Match 'Most likely a setup in some parent block failed'
        $run.Output | Should -Match 'FAIL  setup.cannot run'
    }

    It 'bounds console diagnostics while retaining every failure in NUnit' {
        $body = "Describe 'many failures' { " + ((1..12 | ForEach-Object { "It 'case $_' { throw ('oversized detail ' + ('x' * 3000)) }" }) -join '; ') + ' }'
        Set-FixtureSuite -Root $script:ReportingRoot -Name Alpha -Body $body
        $run = Invoke-Runner -Root $script:ReportingRoot
        $run.ExitCode | Should -Be 1
        $row = @($run.Result.suites)[0]
        $row.failed | Should -Be 12
        ([regex]::Matches($row.message, '(?m)^FAIL  ')).Count | Should -Be 10
        $row.message | Should -Match '2 more failure'
        $row.message | Should -Match 'truncated; see NUnit results'
        $row.message.Length | Should -BeLessThan 30000
        $xml = [xml]([IO.File]::ReadAllText($script:ReportingXml))
        @($xml.SelectNodes('//test-case[failure]')).Count | Should -Be 12
        $xml.SelectSingleNode('//test-case/failure/message').InnerText.Length | Should -BeGreaterThan 3000
    }
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

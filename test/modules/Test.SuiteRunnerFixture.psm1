<#PSScriptInfo
.VERSION 2026.11.05
.GUID 427dfb8c-82bb-4431-af76-61f416d968b1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester runner fixture
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
    The fixture trees and the private runner copy the Test.SuiteRunner* suites
    drive tools/Invoke-TestSuite.ps1 with.
.DESCRIPTION
    Every case of those suites runs the real runner against a throwaway tree
    whose suites the case writes, so nothing depends on this repository's own
    suites. The suites are split so their runner processes run in parallel;
    these helpers are what they share.
#>

$script:Runner = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../tools/Invoke-TestSuite.ps1'))

function New-FixtureTree {
    <#
    .SYNOPSIS
        A throwaway tree with an empty test/modules, under the temp folder.
    .DESCRIPTION
        A fixture tree, not this repository: the runner is exercised against
        suites whose pass/fail shape the test chooses, not one it inherits.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates a throwaway temp tree; nothing to confirm.')]
    [CmdletBinding()]
    param()
    $root = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-runner-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'test/modules')
    $root
}

function Set-FixtureSuite {
    <#
    .SYNOPSIS
        Write test/modules/<Name>.Tests.ps1 into a fixture tree.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Writes into a throwaway temp tree; nothing to confirm.')]
    [CmdletBinding()]
    param([string]$Root, [string]$Name, [string]$Body)
    Set-Content -LiteralPath (Join-Path $Root "test/modules/$Name.Tests.ps1") -Value $Body -Encoding utf8NoBOM
}

function New-FixtureRunner {
    <#
    .SYNOPSIS
        Copy the runner and the single-suite shim into a fixture tree; returns
        the copied runner's path.
    .DESCRIPTION
        The shim copy answers Pester's Windows OS metadata query itself, so
        NUnit metadata never makes a fixture run depend on a live-host CIM query.
    #>
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
        '                # The exporter supplies -ErrorAction Ignore with its OS query.'
        '                if ($ClassName -cne ''Win32_OperatingSystem'' -or @($PSBoundParameters.Keys | Where-Object { $_ -cnotin @(''ClassName'', ''ErrorAction'') }).Count -ne 0 -or'
        '                    ($PSBoundParameters.ContainsKey(''ErrorAction'') -and [string]$PSBoundParameters[''ErrorAction''] -cne ''Ignore'')) {'
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

function Invoke-Runner {
    <#
    .SYNOPSIS
        Run the fixture runner over a tree; returns the exit code, the parsed
        suite-results.json and the console output.
    .DESCRIPTION
        The exit code and suite-results.json are the pair every caller of the
        runner actually consumes.
    #>
    param([string]$Root, [switch]$UpdateBaseline, [switch]$RegisterNewSuites, [switch]$ListOnly, [string]$Filter, [string]$Path, [int]$TimeoutSeconds,
        [switch]$FailFast, [ValidateRange(1, 8)][int]$ThrottleLimit = 1, [int]$SlowdownAllowanceSeconds = -1, [switch]$AllowSkipGrowth)
    $fixtureRunner = New-FixtureRunner -Root $Root
    $argv = @('-NoProfile', '-File', $fixtureRunner, '-Root', $Root, '-ThrottleLimit', [string]$ThrottleLimit, '-Quiet')
    if ($FailFast) { $argv += '-FailFast' }
    if ($TimeoutSeconds) { $argv += @('-TimeoutSeconds', "$TimeoutSeconds") }
    if ($SlowdownAllowanceSeconds -ge 0) { $argv += @('-SlowdownAllowanceSeconds', "$SlowdownAllowanceSeconds") }
    if ($AllowSkipGrowth) { $argv += '-AllowSkipGrowth' }
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


function Set-BaselineRow {
    <#
    .SYNOPSIS
        The reviewed hand edit a baseline row gets: set fields on one row, then
        make the totals agree with the rows again, as the runner requires of a
        baseline it refreshes.
    #>
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
    <#
    .SYNOPSIS
        One suite's row of a fixture tree's baseline, with the totals.
    #>
    param([string]$Root, [string]$Suite)
    $document = Get-Content -LiteralPath (Join-Path $Root 'test/modules/suite-baseline.json') -Raw | ConvertFrom-Json
    [pscustomobject]@{ Row = $document.suites.PSObject.Properties["test/modules/$Suite.Tests.ps1"].Value; Totals = $document.totals }
}

Export-ModuleMember -Function New-FixtureTree, Set-FixtureSuite, New-FixtureRunner, Invoke-Runner, Set-BaselineRow, Get-BaselineRow

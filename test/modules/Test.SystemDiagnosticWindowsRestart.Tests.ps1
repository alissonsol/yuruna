<#PSScriptInfo
.VERSION 2026.11.16
.GUID 420b7f4c-f7a7-4d74-adbd-98df8429a2ce
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test system diagnostic windows update restart pester
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
    Guards the Windows build and pending-restart reading in
    Get-SystemDiagnostic.ps1.
.DESCRIPTION
    Windows installs a cumulative update while it runs and restarts on its own
    schedule, which lands in the middle of a cycle. Win32_OperatingSystem's
    BuildNumber is the same on both sides of that restart, so the HOST section
    reads from the registry the update build revision, which tells the two
    sides apart, and DisplayVersion, which names the feature release, and
    whether a servicing key says a restart is owed; the JSON sidecar carries
    the same reading, where the boot sweep of a later runner looks for the
    build an aborted cycle ran on.

    The helpers are lifted out of the shipped script and driven with a mocked
    registry, so nothing is read from the machine running the suite and the
    cases run on every platform. The message renderer answers with its key and
    arguments, so no assertion depends on catalog wording.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $PSScriptRoot
    $script:DiagPath = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'

    # Get-SystemDiagnostic is a top-to-bottom script, so dot-sourcing it would
    # run every probe. Only the helpers under test are lifted out of it.
    foreach ($helper in 'Get-WindowsOsFact', 'Get-WindowsRestartPendingLine', 'Get-ProblemJson') {
        $definition = Get-YurunaTestFunctionAst -Path $script:DiagPath -Name $helper
        if (-not $definition) { throw "Get-SystemDiagnostic.ps1 no longer defines $helper." }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function Format-YurunaOperatorMessage {
        param([string]$Key, [hashtable]$Arguments = @{})
        $pairs = @($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" })
        return ((@('MSG', $Key) + $pairs) -join '|')
    }

    $script:VersionKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $script:RequiredKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $script:PendingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

Describe 'the Windows build and pending restart' {

    BeforeEach {
        Mock Get-ItemProperty { [pscustomobject]@{ CurrentBuild = '26300'; UBR = 9974; DisplayVersion = '26H2' } } -ParameterFilter { $LiteralPath -eq $script:VersionKey }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like 'HKLM:*' }
    }

    It 'reads the build with its update revision, and DisplayVersion, from the CurrentVersion key' {
        $fact = Get-WindowsOsFact
        $fact.build | Should -BeExactly '26300.9974'
        $fact.displayVersion | Should -BeExactly '26H2'
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $script:VersionKey }
    }

    It 'probes exactly the two servicing keys that mark an owed restart' {
        $null = Get-WindowsOsFact
        Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $script:RequiredKey }
        Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $script:PendingKey }
        Should -Invoke Test-Path -Times 2 -Exactly -ParameterFilter { $LiteralPath -like 'HKLM:*' }
    }

    It 'says no restart is pending when neither key exists' {
        $fact = Get-WindowsOsFact
        $fact.restartPending | Should -BeFalse
        @($fact.restartPendingSources).Count | Should -Be 0
        Get-WindowsRestartPendingLine -Fact $fact | Should -BeExactly 'MSG|automation.system_diagnostic_restart_not_pending'
    }

    It 'says a restart is pending and names the keys that say so: <Case>' -TestCases @(
        @{ Case = 'Windows Update'; Present = @('RebootRequired'); Sources = 'WindowsUpdate\Auto Update\RebootRequired' }
        @{ Case = 'component servicing'; Present = @('RebootPending'); Sources = 'Component Based Servicing\RebootPending' }
        @{ Case = 'both'; Present = @('RebootRequired', 'RebootPending'); Sources = 'WindowsUpdate\Auto Update\RebootRequired, Component Based Servicing\RebootPending' }
    ) {
        param($Case, $Present, $Sources)
        $null = $Case
        $script:Present = $Present
        Mock Test-Path { $script:Present -contains (Split-Path -Leaf $LiteralPath) } -ParameterFilter { $LiteralPath -like 'HKLM:*' }
        $fact = Get-WindowsOsFact
        $fact.restartPending | Should -BeTrue
        (@($fact.restartPendingSources) -join ', ') | Should -BeExactly $Sources
        Get-WindowsRestartPendingLine -Fact $fact | Should -BeExactly "MSG|automation.system_diagnostic_restart_pending|sources=$Sources"
    }

    It 'never fails: an unreadable version leaves the build empty, and a key that cannot be read counts as absent' {
        Mock Get-ItemProperty { throw 'Requested registry access is not allowed.' } -ParameterFilter { $LiteralPath -eq $script:VersionKey }
        Mock Test-Path { throw 'Requested registry access is not allowed.' } -ParameterFilter { $LiteralPath -eq $script:RequiredKey }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:PendingKey }
        $fact = Get-WindowsOsFact
        $fact.build | Should -BeExactly ''
        $fact.displayVersion | Should -BeExactly ''
        @($fact.restartPendingSources) | Should -Be @('Component Based Servicing\RebootPending')
        $fact.restartPending | Should -BeTrue
    }

    It 'keeps the build without a revision when the key has no UBR' {
        Mock Get-ItemProperty { [pscustomobject]@{ CurrentBuild = '26300'; DisplayVersion = '' } } -ParameterFilter { $LiteralPath -eq $script:VersionKey }
        (Get-WindowsOsFact).build | Should -BeExactly '26300'
    }
}

Describe 'the JSON sidecar carries the reading' {

    BeforeEach {
        $script:Problems = [System.Collections.Generic.List[string]]::new()
        $script:ProblemRecords = [System.Collections.Generic.List[hashtable]]::new()
    }

    It 'as windowsOs when the HOST section took it' {
        $script:WindowsOsFact = [ordered]@{ build = '26300.9711'; displayVersion = '26H2'; restartPending = $true
            restartPendingSources = @('WindowsUpdate\Auto Update\RebootRequired') }
        $doc = Get-ProblemJson | ConvertFrom-Json -AsHashtable
        $doc.schema | Should -BeExactly 'yuruna.diagnostic.problems/v1' -Because 'the field is additive; readers of the problems keep working'
        $doc.count | Should -Be 0
        $doc.windowsOs.build | Should -BeExactly '26300.9711'
        $doc.windowsOs.displayVersion | Should -BeExactly '26H2'
        $doc.windowsOs.restartPending | Should -BeTrue
        @($doc.windowsOs.restartPendingSources) | Should -Be @('WindowsUpdate\Auto Update\RebootRequired')
    }

    It 'without windowsOs on a host that is not Windows' {
        $script:WindowsOsFact = $null
        $doc = Get-ProblemJson | ConvertFrom-Json -AsHashtable
        $doc.ContainsKey('windowsOs') | Should -BeFalse
    }
}

Describe 'the Windows HOST section prints it' {

    BeforeAll {
        $diagAst = Get-YurunaTestFileAst -Path $script:DiagPath
        $section = $diagAst.Find({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-DiagnosticSection' -and
                $node.CommandElements[1].Value -eq 'HOST' }, $true)
        if (-not $section) { throw "Get-SystemDiagnostic.ps1 has no HOST section." }
        $windows = $section.CommandElements[2].Find({ param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '$IsWindows' -and
                $node.Clauses[0].Item2.Extent.Text.Contains("'automation.operator_a4e0c8c241287bb7'") }, $true)
        if (-not $windows) { throw "The HOST section has no Windows OS branch." }
        $script:WindowsBranch = $windows.Clauses[0].Item2
    }

    It 'in the OS line, with the full build and the DisplayVersion' {
        $text = $script:WindowsBranch.Extent.Text
        $text | Should -Match '\$script:WindowsOsFact = Get-WindowsOsFact'
        $text | Should -Match '-Key ''automation\.operator_a4e0c8c241287bb7'' -FormatValues \(\$caption, \$build\)'
    }

    It 'with the pending restart line after the OS lines, whether or not the OS query answered' {
        $text = $script:WindowsBranch.Extent.Text
        $osLine = $text.IndexOf("'automation.operator_a4e0c8c241287bb7'", [StringComparison]::Ordinal)
        $pending = $text.IndexOf('Get-WindowsRestartPendingLine -Fact $script:WindowsOsFact', [StringComparison]::Ordinal)
        $pending | Should -BeGreaterThan $osLine
        $osBlock = $script:WindowsBranch.Find({ param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$osi' }, $true)
        $osBlock | Should -Not -BeNullOrEmpty
        $osBlock.Extent.Text | Should -Not -Match 'Get-WindowsRestartPendingLine' -Because 'a host whose CIM query failed still says whether a restart is owed'
    }
}

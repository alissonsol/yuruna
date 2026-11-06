<#PSScriptInfo
.VERSION 2026.11.05
.GUID 429f04bf-a5ca-4a27-a5fb-dc219396205b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test system diagnostic windows memory commit pester
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
    Guards the Windows commit reading in Get-SystemDiagnostic.ps1: how much of
    the commit charge no process's private bytes hold.
.DESCRIPTION
    Windows refuses a VM start once the commit charge reaches its limit. A
    process's private bytes are its own share of that charge, which is why
    TOP PROCESSES ranks them, but commit held by shared memory sections and
    kernel allocations is in no process's row: a leak there raises the charge
    while every row of the table stays flat. The MEMORY section therefore
    prints the charge less the private bytes of every process.

    The helper is lifted out of the shipped script and driven with fixed
    numbers and stand-in process objects, so nothing is read from the machine
    running the suite and the cases run on every platform. The message
    renderer answers with its key and arguments, so no assertion depends on
    catalog wording, and the expected sizes come from the script's own
    Format-ByteCount, so they hold in any culture.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $PSScriptRoot
    $script:DiagPath = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'

    # Get-SystemDiagnostic is a top-to-bottom script, so dot-sourcing it would
    # run every probe. Only the helpers under test are lifted out of it.
    foreach ($helper in 'Format-ByteCount', 'Get-CommitOutsideProcessLine') {
        $definition = Get-YurunaTestFunctionAst -Path $script:DiagPath -Name $helper
        if (-not $definition) { throw "Get-SystemDiagnostic.ps1 no longer defines $helper." }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function Format-YurunaOperatorMessage {
        param([string]$Key, [hashtable]$Arguments = @{})
        $pairs = @($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" })
        return ((@('MSG', $Key) + $pairs) -join '|')
    }

    # The two properties Get-Process gives every process that matter here:
    # PrivateMemorySize64 is its commit charge, WorkingSet64 only the resident
    # part of its memory, which the reading must not add up instead.
    function New-ProcessStandIn {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: returns an object; changes nothing.')]
        param([long]$PrivateBytes, [long]$WorkingSetBytes = 0)
        return [pscustomobject]@{ PrivateMemorySize64 = $PrivateBytes; WorkingSet64 = $WorkingSetBytes }
    }
}

Describe 'the commit charged outside every process' {

    It 'is the charge less the private bytes of every process' {
        # The shape of the leak this reading exists for: 43.55 GiB charged while
        # every process together held 3.25 GiB of private bytes.
        $processes = @(
            New-ProcessStandIn -PrivateBytes 3221225472 -WorkingSetBytes 1048576
            New-ProcessStandIn -PrivateBytes 268435456 -WorkingSetBytes 2147483648
        )
        $lines = @(Get-CommitOutsideProcessLine -ChargedBytes 46761456435 -Process $processes)
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly ('MSG|automation.memory_commit_outside_processes|charged={0}|outside={1}|private={2}|processes=2' -f
            (Format-ByteCount 46761456435), (Format-ByteCount 43271795507), (Format-ByteCount 3489660928))
    }

    It 'reports none outside when the processes, listed after the charge was read, hold more than it' {
        $line = Get-CommitOutsideProcessLine -ChargedBytes 1GB -Process @(New-ProcessStandIn -PrivateBytes 2GB)
        $line | Should -Match ('\|outside=' + [regex]::Escape((Format-ByteCount 0)) + '\|')
        $line | Should -Match ('\|private=' + [regex]::Escape((Format-ByteCount 2GB)) + '\|')
    }

    It 'counts a process that reports no private bytes as holding none' {
        # A process whose private bytes could not be read answers $null.
        $line = Get-CommitOutsideProcessLine -ChargedBytes 4GB -Process @(
            New-ProcessStandIn -PrivateBytes 1GB
            [pscustomobject]@{ PrivateMemorySize64 = $null; WorkingSet64 = $null }
        )
        $line | Should -BeExactly ('MSG|automation.memory_commit_outside_processes|charged={0}|outside={1}|private={2}|processes=2' -f
            (Format-ByteCount 4GB), (Format-ByteCount 3GB), (Format-ByteCount 1GB))
    }
}

Describe 'the Windows MEMORY section prints it' {

    BeforeAll {
        $diagAst = Get-YurunaTestFileAst -Path $script:DiagPath
        $section = $diagAst.Find({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-DiagnosticSection' -and
                $node.CommandElements[1].Value -eq 'MEMORY' }, $true)
        if (-not $section) { throw "Get-SystemDiagnostic.ps1 has no MEMORY section." }
        $script:MemoryBody = $section.CommandElements[2]
    }

    It 'right after the Commit line, from the list of every process' {
        $text = $script:MemoryBody.Extent.Text
        $charge = $text.IndexOf("'automation.memory_commit_charge'", [StringComparison]::Ordinal)
        $charge | Should -BeGreaterThan -1
        $text.IndexOf('Get-CommitOutsideProcessLine', [StringComparison]::Ordinal) | Should -BeGreaterThan $charge
        $call = $script:MemoryBody.Find({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Get-CommitOutsideProcessLine' }, $true)
        $call | Should -Not -BeNullOrEmpty
        # The commands that build the call's arguments: the process listing and
        # nothing that sorts, filters or cuts it.
        $listing = @($call.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $_ -ne $call } | ForEach-Object { $_.GetCommandName() })
        $listing | Should -Be @('Get-Process') -Because 'a top-N cut of the list would count the processes it drops as outside them'
    }
}

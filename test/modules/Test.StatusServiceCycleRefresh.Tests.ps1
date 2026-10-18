<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 423f54e6-56bb-471f-b619-23c0a5564178
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service cycle refresh pester
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
    Verify the inner runner's per-cycle status-service refresh stopped
    forcing a relaunch, while the launcher's own relaunch-when-stale
    machinery (what makes that safe) and the other two callers' flags stay
    exactly as they were.
.DESCRIPTION
    Start-StatusService.ps1 already compares its persisted server.sha
    against the current framework HEAD and relaunches on a mismatch or an
    unanswered probe; config, pages, logs and archives are read per
    request. The per-cycle call in Invoke-GuestProvisionIteration no longer
    needs -Restart to pick up a mid-cycle git pull -- the launcher's own
    compare-and-skip already does that, for free, on the common no-change
    cycle.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -DisableNameChecking

    function Test-CommandBindsSwitch {
        param([Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command, [Parameter(Mandatory)][string]$Name)
        @($Command.CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq $Name
            }).Count -gt 0
    }
}

Describe 'the per-cycle status-service refresh no longer forces a relaunch' {
    It 'binds no Start-YurunaStatusServiceIfEnabled call to -Restart' {
        $ast = Get-YurunaTestFileAst -Path (Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1')
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-YurunaStatusServiceIfEnabled' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            Test-CommandBindsSwitch -Command $call -Name 'Restart' | Should -BeFalse -Because "$($call.Extent.Text) still forces a relaunch every cycle"
        }
    }
}

Describe 'the launcher still relaunches on stale code or a dead server, which is what makes dropping -Restart safe' {
    It 'still compares the persisted commit against the current framework HEAD' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1')
        $text | Should -Match ([regex]::Escape('if ($currentSha -and $persistedSha -and ($currentSha -eq $persistedSha))'))
    }
    It 'still imports Test.Config.psm1, so an operator edit to test.config.yml needs no restart either' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1')
        $text | Should -Match "Import-Module \(Join-Path .*RepoRoot 'test/modules/Test\.Config\.psm1'\)"
    }
}

Describe 'the other two callers keep their own relaunch flags' {
    It 'Debug-TestSequence still passes -Restart' {
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/Debug-TestSequence.ps1')
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-YurunaStatusServiceIfEnabled' }, $true))
        $calls.Count | Should -Be 1
        Test-CommandBindsSwitch -Command $calls[0] -Name 'Restart' | Should -BeTrue
    }
    It 'the startup path still omits -Restart' {
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/modules/Invoke-TestRunnerInnerLoop.ps1')
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-YurunaStatusServiceIfEnabled' }, $true))
        $calls.Count | Should -Be 1
        Test-CommandBindsSwitch -Command $calls[0] -Name 'Restart' | Should -BeFalse
    }
}

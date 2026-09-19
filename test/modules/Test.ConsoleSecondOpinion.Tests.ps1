<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42c1aae0-6851-429a-a359-f13d409e76c0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test console capture framebuffer verdict utm pester
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
    Coverage for the verdict Get-VMConsoleSecondOpinion reaches on
    host.macos.utm when every captured frame came back byte-identical.
.DESCRIPTION
    The verdict is what an operator acts on -- restart the VM, capture the
    guest's state, or go look at the capture path -- and the three answers
    send them to different machines, so the decision table is worth holding
    to explicitly.

    The driver is macOS-only, so the function under test is lifted out of it
    by AST and run against stubs standing in for utmctl, the VNC read and
    the emulator process. That keeps the table checked on every platform
    rather than only where UTM exists.
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4
    and Pester 5+.
    Run: Invoke-Pester -Path test/modules/Test.ConsoleSecondOpinion.Tests.ps1
#>

# CPU pairs are seconds-of-processor-time samples one second apart, so the
# second minus the first is directly the percent of one core.
$script:VerdictCase = @(
    @{ name = 'running, unchanged screen, a core burning'; state = 'running'; qemuPid = 4242; frames = @('A', 'A'); cpu = @(100.0, 102.0); vncOk = $true;  expect = 'guest-wedged' }
    @{ name = 'running, unchanged screen, nothing burning'; state = 'running'; qemuPid = 4242; frames = @('A', 'A'); cpu = @(100.0, 100.02); vncOk = $true;  expect = 'guest-static' }
    @{ name = 'direct reads differ'; state = 'running'; qemuPid = 4242; frames = @('A', 'B'); cpu = @(100.0, 102.0); vncOk = $true;  expect = 'guest-live' }
    @{ name = 'VM not running'; state = 'stopped'; qemuPid = 4242; frames = @('A', 'A'); cpu = @(100.0, 102.0); vncOk = $true;  expect = 'guest-static' }
    @{ name = 'utmctl does not know the VM'; state = 'absent';  qemuPid = 4242; frames = @('A', 'A'); cpu = @(100.0, 102.0); vncOk = $true;  expect = 'unavailable' }
    @{ name = 'emulator process not found'; state = 'running'; qemuPid = 0; frames = @('A', 'A'); cpu = @(100.0, 102.0); vncOk = $true;  expect = 'guest-static' }
    @{ name = 'VNC unreadable but a core burning'; state = 'running'; qemuPid = 4242; frames = @('A', 'A'); cpu = @(100.0, 102.0); vncOk = $false; expect = 'guest-wedged' }
    @{ name = 'pid reused mid-window'; state = 'running'; qemuPid = 4242; frames = @('A', 'A'); cpu = @(500.0, 3.0); vncOk = $true;  expect = 'guest-static' }
)

BeforeAll {
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:DriverPath = Join-Path (Get-YurunaTestRepoRoot -SuiteDirectory (Split-Path -Parent $PSCommandPath)) 'host/macos.utm/modules/Yuruna.Host.psm1'
Import-Module (Join-Path (Get-YurunaTestRepoRoot -SuiteDirectory (Split-Path -Parent $PSCommandPath)) 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
$script:FnAst = Get-YurunaTestFunctionAst -Path $script:DriverPath -Name 'Get-VMConsoleSecondOpinion'

# Every host dependency is stubbed inside the invoking scope, so the lifted
# function resolves the stubs the same way it resolves its real siblings and
# nothing leaks into the shared suite runspace -- a Get-Process left behind
# in a global scope would break every file that runs after this one.
function Invoke-SecondOpinionCase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is read by the stub functions declared in this scope; the analyzer does not follow references into a nested function body.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Get-Process is shadowed on purpose and only for the length of this call, so the emulator CPU samples are deterministic. The stub goes out of scope with the function and nothing else in the suite sees it.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($FnText, $State, $QemuPid, $Frames, $Cpu, $VncOk)
    $seq = [pscustomobject]@{ FrameIdx = 0; CpuIdx = 0 }
    function Get-VMState { param($VMName) $State }
    function Get-VncPortForVm { param($VMName) 5961 }
    function Get-UtmVMProcessId { param($VMName) $QemuPid }
    function Get-VncScreenshot {
        param($OutputPath, $Port, $TimeoutMs)
        if (-not $VncOk) { return $false }
        Set-Content -LiteralPath $OutputPath -Value $Frames[$seq.FrameIdx] -NoNewline
        $seq.FrameIdx++
        return $true
    }
    function Get-Process {
        param([int]$Id, [switch]$ErrorAction)
        if ($QemuPid -le 0) { return $null }
        $value = $Cpu[[math]::Min($seq.CpuIdx, $Cpu.Count - 1)]
        $seq.CpuIdx++
        return [pscustomobject]@{ CPU = $value }
    }
    . ([scriptblock]::Create($FnText))
    return (Get-VMConsoleSecondOpinion -VMName 'test-guest.ubuntu.server.24-01' -IntervalSeconds 1)
}

}

Describe 'Get-VMConsoleSecondOpinion (host.macos.utm)' {

    It 'is published by the driver so the sequence engine can feature-detect it' {
        Assert-NotNull $script:FnAst "Get-VMConsoleSecondOpinion must exist in $($script:DriverPath)"
        $source = Get-Content -Raw -LiteralPath $script:DriverPath
        $export = [regex]::Match($source, '(?s)Export-ModuleMember\s+-Function\s+(?<names>.+?)\r?\n\r?\n')
        Assert-True $export.Success 'the driver must carry an Export-ModuleMember block'
        Assert-Match 'Get-VMConsoleSecondOpinion' $export.Groups['names'].Value `
            'an unexported function is invisible to the engine Get-Command probe, which then skips the second opinion in silence'
    }

    It 'names <name> as <expect>' -TestCases $script:VerdictCase {
        param($name, $state, $qemuPid, $frames, $cpu, $vncOk, $expect)
        $result = Invoke-SecondOpinionCase -FnText $script:FnAst.Extent.Text -State $state -QemuPid $qemuPid -Frames $frames -Cpu $cpu -VncOk $vncOk
        Assert-NotNull $result "'$name' must return a verdict object"
        Assert-StringEqual $expect $result.Verdict "case: $name"
        Assert-True ([bool]$result.Detail) "'$name' must explain the verdict, not just assert it"
        if ($expect -ne 'guest-live' -and $expect -ne 'unavailable') {
            Assert-Match 'capture pipeline is not the fault' $result.Detail `
                "case '$name': a guest-side verdict has to clear the capture path by name, or the operator is left with both suspects"
        }
    }

    It 'separates a wedged guest from a halted one in the detail text' {
        $wedged = Invoke-SecondOpinionCase -FnText $script:FnAst.Extent.Text -State 'running' -QemuPid 4242 -Frames @('A', 'A') -Cpu @(100.0, 102.0) -VncOk $true
        $halted = Invoke-SecondOpinionCase -FnText $script:FnAst.Extent.Text -State 'running' -QemuPid 4242 -Frames @('A', 'A') -Cpu @(100.0, 100.02) -VncOk $true
        Assert-Match '200% of one core' $wedged.Detail 'the burn rate is the evidence the verdict rests on'
        Assert-Match '2% of one core'   $halted.Detail 'the burn rate is the evidence the verdict rests on'
    }

    It 'reaches every verdict, so none of them is unreachable in practice' {
        $text = $script:FnAst.Extent.Text
        $seen = @(
            (Invoke-SecondOpinionCase -FnText $text -State 'running' -QemuPid 4242 -Frames @('A', 'A') -Cpu @(100.0, 102.0) -VncOk $true).Verdict
            (Invoke-SecondOpinionCase -FnText $text -State 'running' -QemuPid 4242 -Frames @('A', 'A') -Cpu @(100.0, 100.02) -VncOk $true).Verdict
            (Invoke-SecondOpinionCase -FnText $text -State 'running' -QemuPid 4242 -Frames @('A', 'B') -Cpu @(100.0, 102.0) -VncOk $true).Verdict
            (Invoke-SecondOpinionCase -FnText $text -State 'absent' -QemuPid 4242 -Frames @('A', 'A') -Cpu @(100.0, 102.0) -VncOk $true).Verdict
        )
        Assert-StringEqual 'guest-live,guest-static,guest-wedged,unavailable' (($seen | Sort-Object -Unique) -join ',') `
            'a verdict no input can produce is a branch the operator will never be shown'
    }
}

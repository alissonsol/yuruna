<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42b6e05d-3c74-4a19-9f28-1d7ac6e5b840
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host hyper-v snapshot pester
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
    Guard: the Hyper-V host must let a guest flush before it snapshots it.
.DESCRIPTION
    Checkpoint-VM freezes whatever is on the disk. If the VM was stopped with
    -TurnOff (a virtual power cut) the guest never flushed, so the checkpoint is
    crash-consistent: an ext4 guest with delayed allocation loses every write
    still inside its writeback window, and the files created in that window come
    back with their metadata intact and size 0. Those zero-length files are then
    baked into the baseline and reappear on EVERY later restore -- and a 0-byte
    binary with the +x bit still executes as an empty script under bash (exit 0,
    no output), so nothing downstream complains until something execve()s it.

    Stop-HyperVVM is the "graceful" leg of the Stop-VM contract (Stop-VM without
    -Force; the Save-VMDiskSnapshot path). It must ask the guest to shut down
    first and only escalate to the power cut when the guest will not answer.

    Source-level guards: these paths need a live hypervisor to exercise, and the
    regression they protect against is a call-shape regression. AST-based, so a
    comment mentioning -TurnOff cannot satisfy or break them.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$hostFile = Join-Path $repoRoot 'host' -AdditionalChildPath 'windows.hyper-v', 'modules', 'Yuruna.Host.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Parse once; each test reads the function bodies out of the AST so that comments
# and strings can never be mistaken for calls.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($hostFile, [ref]$null, [ref]$null)

function Get-FunctionAst {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    param([string]$Name)
    $fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true) | Select-Object -First 1
    return $fn
}

function Get-CommandNameList {
    param($FunctionAst)
    return @($FunctionAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}

Describe 'hyper-v-graceful-stop' {
    It 'Request-HyperVVMShutdown exists and asks the GUEST to shut down (no -TurnOff)' {
        $fn = Get-FunctionAst -Name 'Request-HyperVVMShutdown'
        Assert-True ($null -ne $fn) 'the graceful shutdown request must exist'

        $stopCalls = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -match 'Stop-VM$'
        }, $true))
        Assert-True ($stopCalls.Count -ge 1) 'it must issue a Stop-VM'
        foreach ($call in $stopCalls) {
            $params = @($call.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object { $_.ParameterName })
            Assert-True ($params -notcontains 'TurnOff') `
                '-TurnOff is a power cut: the guest never flushes, and the checkpoint taken after it is crash-consistent'
        }
    }
    It 'Stop-HyperVVM requests a guest shutdown BEFORE any force-stop' {
        $fn = Get-FunctionAst -Name 'Stop-HyperVVM'
        Assert-True ($null -ne $fn) 'Stop-HyperVVM must exist'
        $names = Get-CommandNameList -FunctionAst $fn
        $requestIdx = [array]::IndexOf($names, 'Request-HyperVVMShutdown')
        $forceIdx   = [array]::IndexOf($names, 'Stop-HyperVVMForce')
        Assert-True ($requestIdx -ge 0) `
            'the graceful leg of the Stop-VM contract must actually request a guest shutdown'
        Assert-True ($forceIdx -lt 0 -or $requestIdx -lt $forceIdx) `
            'the force-stop may only be an escalation, never the first move'
    }
    It 'Save-VMDiskSnapshot stops the VM through the graceful path' {
        $fn = Get-FunctionAst -Name 'Save-VMDiskSnapshot'
        Assert-True ($null -ne $fn) 'Save-VMDiskSnapshot must exist'
        $names = Get-CommandNameList -FunctionAst $fn
        Assert-True ($names -contains 'Stop-VM') `
            'the snapshot path must go through Stop-VM (graceful), not straight to a force-stop'
        $stopIdx  = [array]::IndexOf($names, 'Stop-VM')
        $forceIdx = [array]::IndexOf($names, 'Stop-VMForce')
        Assert-True ($forceIdx -lt 0 -or $stopIdx -lt $forceIdx) `
            'a force-stop before the snapshot may only be the fallback'
    }
    It 'Restore-VMDiskSnapshot may force-stop (the disk is about to be rolled back)' {
        # The mirror of the rule above: on restore the guest's disk state is
        # discarded, so a graceful shutdown buys nothing and would add its full
        # timeout to every restore. This asserts the asymmetry is deliberate.
        $fn = Get-FunctionAst -Name 'Restore-VMDiskSnapshot'
        Assert-True ($null -ne $fn) 'Restore-VMDiskSnapshot must exist'
        $names = Get-CommandNameList -FunctionAst $fn
        Assert-True ($names -contains 'Stop-VMForce') 'the restore path force-stops by design'
    }
}

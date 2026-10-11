<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 4211664b-fb87-4dab-a225-c1006746d404
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dhcp capture pktmon hyper-v pester
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
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    A guest whose lease never came leaves the wire's side of the story in its
    failure folder, and the capture that records it can never become a fault
    of its own.
.DESCRIPTION
    WHY THIS EXISTS. The guest-side network diagnostic bottoms out at "no
    IPv4 lease" -- it cannot see whether its DISCOVER ever left the vSwitch,
    died at the uplink, or went out and was ignored, and each of those shapes
    indicts a DIFFERENT machine. The host-side pktmon capture is the only
    artifact that answers it, and it only answers if four properties hold,
    each of which fails silently when it does not:

      * Armed at Start-VM: the first DISCOVER lands seconds after firmware,
        before any sequence step runs, so a capture armed anywhere later
        records the retries and misses the first ask.
      * Bounded: pktmon allows one session per system and nothing stops a
        session whose flow never removes its VM, so an unbounded capture
        grows with host uptime.
      * Collected where the failure diagnostics are collected, and only by
        feature detection: most host drivers do not implement it, and the
        collection block must not turn a failed step into a failed cycle.
      * Ownership-scoped teardown: the cycle-start sweep removes leftover
        VMs by prefix, and a discard there that did not check ownership
        would kill the capture just armed for the guest actually under test.

    Static assertions over the sources, because the thing under test is what
    a failing cycle is BUILT to leave behind; there is no failing cycle to run.
    Run: Invoke-Pester -Path test/modules/Test.HyperVDhcpCapture.Tests.ps1
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.CatalogSource.psm1') -DisableNameChecking
    # test/modules/<this file> -> test/modules -> test -> repo root.
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:DriverPath = Join-Path $script:RepoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
    $script:RunnerPath = Join-Path $script:RepoRoot 'test/modules/Test.RunnerInnerLoop.psm1'
    $script:DriverText = Get-Content -Raw -LiteralPath $script:DriverPath
    $script:RunnerText = Get-Content -Raw -LiteralPath $script:RunnerPath

    # Function bodies close at column 0 in this module, so the first
    # column-0 brace after the header is the function's end.
    function Get-PsFunctionText {
        param([string]$Source, [string]$Name)
        $m = [regex]::Match($Source, "(?ms)^function $([regex]::Escape($Name)) \{.*?^\}")
        if (-not $m.Success) { throw "function $Name not found" }
        return $m.Value
    }
}

Describe 'hyper-v DHCP capture: armed at the only moment that sees the first DISCOVER' {

    It 'arms inside Start-VM, gated on the start actually succeeding' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VM'
        $fn | Should -Match 'Start-VMDhcpCapture' -Because 'no later hook runs before the guest first asks for a lease'
        $armAt   = $fn.IndexOf('Start-VMDhcpCapture')
        $startAt = $fn.IndexOf('Start-HyperVVM')
        ($startAt -ge 0 -and $armAt -gt $startAt) | Should -BeTrue -Because 'a capture for a VM that failed to start records nothing and still claims the one pktmon session'
        $fn | Should -Match '\.success' -Because 'the arm must read the start result, not assume it'
    }

    It 'clears whatever session preceded it, because pktmon allows exactly one' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $stopAt  = $fn.IndexOf('pktmon stop')
        $startAt = $fn.IndexOf('pktmon start')
        ($stopAt -ge 0 -and $startAt -gt $stopAt) | Should -BeTrue -Because 'a leftover session makes every later arm fail silently, forever'
    }

    It 'stays bounded even when nothing ever stops it' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $fn | Should -Match '--log-mode circular' -Because 'a flow that starts a VM and never removes it must not grow a capture with host uptime'
        $fn | Should -Match '--file-size' -Because 'circular mode without a size cap is not bounded'
    }
}

Describe 'hyper-v DHCP capture: collected with the failure, discarded with the guest' {

    It 'lands beside the failure diagnostics, by feature detection' {
        $script:RunnerText | Should -Match 'Get-Command Save-VMDhcpCapture' -Because 'most host drivers do not implement the capture; a bare call fails the collection on all of them'
        $script:RunnerText | Should -Match 'Save-VMDhcpCapture -VMName \$VMName -OutputDirectory \$destSeqDir' -Because 'the wire evidence must sit next to the diagnostics that point at it'
        ((Get-CatalogSourceMessage -Source $script:RunnerText) -join "`n") | Should -Match 'DHCP capture collection skipped' -Because 'the collection must soft-fail like its neighbors, never the step'
    }

    It 'discards at Remove-VM only a capture the removed VM owns' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Remove-VM'
        $fn | Should -Match 'Stop-VMDhcpCapture' -Because 'the no-failure teardown must not leak a running session'
        $fn | Should -Match '\.VMName -eq \$VMName' -Because 'the cycle-start sweep removes leftover VMs; an unowned discard there kills the capture of the guest under test'
    }

    It 'never lets a capture failure escape into the step' {
        foreach ($name in 'Start-VMDhcpCapture', 'Stop-VMDhcpCapture', 'Save-VMDhcpCapture') {
            $fn = Get-PsFunctionText -Source $script:DriverText -Name $name
            $fn | Should -Match '(?ms)\}\s*catch\s*\{' -Because "$name is a diagnostic; a throw here fails the cycle it exists to explain"
        }
    }

    It 'exports all three verbs so the feature detection can find them' {
        foreach ($name in 'Start-VMDhcpCapture', 'Save-VMDhcpCapture', 'Stop-VMDhcpCapture') {
            $script:DriverText | Should -Match "Export-ModuleMember[\s\S]*$name" -Because "an unexported $name reads as `"driver does not implement it`" and the capture silently never lands"
        }
    }
}

Describe 'hyper-v DHCP capture: one line says whether the guest ever asked' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DriverText, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DhcpCaptureSummary' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        # pktmon etl2txt shape: a header naming the component, then the frame,
        # once per component the packet crossed, in UTF-16 with a BOM.
        function Get-PktmonLine {
            param([string]$Time, [string]$Source, [string]$Destination, [int]$Component, [switch]$Drop)
            $prefix = if ($Drop) { 'Drop: ' } else { '' }
            "[00]0000.0000::2026-10-06 $Time [Microsoft-Windows-PktMon] ${prefix}PktGroupId 8855$Component, PktNumber 1, Appearance 0, Direction Rx , Type Ethernet , Component $Component, Edge 1, Filter 1, OriginalSize 335, LoggedSize 335"
            "`t$prefix$Source > $Destination, ethertype IPv4 (0x0800), length 335: 0.0.0.0.68 > 255.255.255.255.67: UDP, length 293"
        }
        $lines = @(
            Get-PktmonLine -Time '13:08:48.465603600' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 8
            Get-PktmonLine -Time '13:08:48.465614700' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 31
            Get-PktmonLine -Time '13:08:48.465657800' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 597 -Drop
            Get-PktmonLine -Time '13:08:52.100000000' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 8
            Get-PktmonLine -Time '13:08:52.300000000' -Source '00-15-5D-01-02-03' -Destination '42-54-43-AE-01-19' -Component 8
            Get-PktmonLine -Time '13:09:10.000000000' -Source '38-05-25-3A-94-BA' -Destination 'FF-FF-FF-FF-FF-FF' -Component 8
            Get-PktmonLine -Time '13:09:10.000010000' -Source '38-05-25-3A-94-BA' -Destination 'FF-FF-FF-FF-FF-FF' -Component 31
        )
        $script:PktmonPath = Join-Path $TestDrive 'dhcp.capture.txt'
        [IO.File]::WriteAllLines($script:PktmonPath, [string[]]$lines, [Text.UnicodeEncoding]::new($false, $true))
    }

    It 'counts packets, not the lines pktmon writes for every component they cross' {
        $summary = Get-DhcpCaptureSummary -Path $script:PktmonPath -GuestMac '42:54:43:AE:01:19'
        $summary.sentByGuest | Should -Be 2 -Because 'one DISCOVER seen at three components, then a retransmit seconds later'
        $summary.unicastToGuest | Should -Be 1
        $summary.fromOtherClients | Should -Be 1
        $summary.otherClients | Should -Be 1
    }

    It 'reads a guest that never transmitted as zero beside a live capture' {
        $summary = Get-DhcpCaptureSummary -Path $script:PktmonPath -GuestMac '42-54-43-00-00-01'
        $summary.sentByGuest | Should -Be 0
        $summary.fromOtherClients | Should -BeGreaterThan 0 -Because 'zero from the guest means something only beside traffic that proves the capture was live'
    }

    It 'lands the summary beside the capture and prints it with the failure evidence' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMDhcpCapture'
        $fn | Should -Match 'Get-DhcpCaptureSummary' -Because 'the five-megabyte text is the evidence; the one line is what a reader looks at first'
        $fn | Should -Match 'dhcp\.capture\.summary\.json'
        $script:RunnerText | Should -Match 'dhcp\.capture\.summary\.json' -Because 'the runner states the result in the cycle log'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.

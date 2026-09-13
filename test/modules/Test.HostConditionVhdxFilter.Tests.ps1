<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42dd9774-3fb6-49d6-bbf8-2c38c8ffd5a2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host condition vhdx filter antivirus shadow copy
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
    What the storage filter stack report says about a host, decided from a
    profile hashtable rather than from the host it is running on.
.DESCRIPTION
    Get-WindowsVhdxFilterIssue is deliberately a pure function of the reading
    Get-WindowsVhdxFilterProfile takes, so the rule that decides whether a
    guest's writes are being inspected can be exercised on a machine with no
    Hyper-V, no anti-virus product and no elevation. These cases pin the
    distinctions that matter, and in particular the one between "measured
    nothing attached" and "could not measure" -- an unelevated host cannot
    list filter instances, and a report that called that clean would be
    asserting the opposite of what it saw.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.Windows.psm1') -Force -DisableNameChecking

    # Defined here rather than at file scope: an It body runs in the
    # run-phase scope, which sees BeforeAll but not functions declared
    # beside the Describe.
    function Get-StubFilterProfile {
        param(
            [string]$VhdxPath = 'C:\ProgramData\Microsoft\Windows\Virtual Hard Disks',
            [string]$VhdxVolume = 'C:',
            [array]$Filters = @(),
            [array]$Exclusions = @(),
            [object]$ShadowUsedBytes = $null,
            [object]$ShadowMaxBytes = $null,
            [object]$ShadowCount = $null
        )
        return @{
            VhdxPath        = $VhdxPath
            VhdxVolume      = $VhdxVolume
            Filters         = $Filters
            AntiVirus       = @()
            DefenderPassive = $null
            Exclusions      = $Exclusions
            ShadowUsedBytes = $ShadowUsedBytes
            ShadowMaxBytes  = $ShadowMaxBytes
            ShadowCount     = $ShadowCount
            Errors          = @()
        }
    }

    # Read inside It bodies, so these belong to the run-phase scope with the
    # helper above. Only -TestCases data has to sit at file scope, where
    # discovery can reach it.
    $script:QosOnly = @(@{ Name = 'storqosflt'; Altitude = 244000.0 })
    $script:AvAttached = @(
        @{ Name = 'storqosflt'; Altitude = 244000.0 }
        @{ Name = 'mfesec';     Altitude = 321150.5 }
    )
}

# Altitudes are Microsoft's allocation, not this lab's: 320000-329998 is the
# anti-virus band. The values below are real ones seen on a Hyper-V host --
# a passive Defender and a third-party scanner both sit in the band, while
# the storage-QoS and bind filters sit well below it.
$script:AvBandCase = @(
    @{ Name = 'WdFilter';      Altitude = 328010.0;  InBand = $true }
    @{ Name = 'mfesec';        Altitude = 321150.5;  InBand = $true }
    @{ Name = 'bandEdgeLow';   Altitude = 320000.0;  InBand = $true }
    @{ Name = 'bandEdgeHigh';  Altitude = 329998.0;  InBand = $true }
    @{ Name = 'storqosflt';    Altitude = 244000.0;  InBand = $false }
    @{ Name = 'bindflt';       Altitude = 409800.0;  InBand = $false }
    @{ Name = 'CldFlt';        Altitude = 180451.0;  InBand = $false }
)

Describe 'Get-WindowsVhdxFilterIssue' {

    It 'cannot call a host clean when it was never allowed to look' {
        # No filters listed means fltmc was refused, which needs elevation --
        # the one reading whose absence must not be read as an all-clear.
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters @())
        Assert-Equal -Expected 'Unknown' -Actual $r.Status
    }

    It 'reports Unknown when the virtual hard disk path itself could not be read' {
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -VhdxPath $null -Filters $script:AvAttached)
        Assert-Equal -Expected 'Unknown' -Actual $r.Status
    }

    It 'passes a volume whose filters are all below the anti-virus band' {
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters $script:QosOnly)
        Assert-Equal -Expected 'Clean' -Actual $r.Status
    }

    It 'classifies a filter by its allocated altitude, not by its name' -TestCases $script:AvBandCase {
        param($Name, $Altitude, $InBand)
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters @(@{ Name = $Name; Altitude = $Altitude }))
        $expected = if ($InBand) { 'Issue' } else { 'Clean' }
        Assert-Equal -Expected $expected -Actual $r.Status
    }

    It 'names the filter and the path it sits in front of' {
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters $script:AvAttached)
        Assert-Equal -Expected 'Issue' -Actual $r.Status
        Assert-True (($r.Issue -join ' ') -match 'mfesec') 'the scanner is named'
        Assert-True (($r.Issue -join ' ') -match 'Virtual Hard Disks') 'the filtered path is named'
        Assert-True (($r.Issue -join ' ') -notmatch 'storqosflt') 'a filter below the band is not reported as a scanner'
    }

    It 'treats an exclusion that does not cover the virtual hard disk path as no exclusion' {
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters $script:AvAttached -Exclusions @('C:\Users\someone\Downloads'))
        Assert-True (($r.Issue -join ' ') -match 'No Microsoft Defender exclusion') 'an unrelated exclusion does not count as coverage'
    }

    It 'stops asking for an exclusion once one covers the path' {
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters $script:AvAttached -Exclusions @('C:\ProgramData\Microsoft\Windows\Virtual Hard Disks'))
        Assert-True (($r.Issue -join ' ') -notmatch 'No Microsoft Defender exclusion') 'a covering exclusion is recognized'
    }

    It 'matches a parent-folder exclusion, since a scanner exclusion covers the tree below it' {
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters $script:AvAttached -Exclusions @('C:\ProgramData'))
        Assert-True (($r.Issue -join ' ') -notmatch 'No Microsoft Defender exclusion') 'a parent exclusion covers the path below it'
    }

    It 'reports shadow-copy pressure even on a volume with no scanner on it' {
        # The two costs are independent: copy-on-write lands on the guest's
        # first touch of every new block whether or not anything scans it.
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters $script:QosOnly -ShadowUsedBytes 11068046540 -ShadowMaxBytes 20401094656 -ShadowCount 5)
        Assert-Equal -Expected 'Issue' -Actual $r.Status
        Assert-True (($r.Issue -join ' ') -match 'shadow copies') 'shadow copies are reported on their own'
    }

    It 'says nothing about shadow copies on a volume that has none' {
        $r = Get-WindowsVhdxFilterIssue -FilterProfile (Get-StubFilterProfile -Filters $script:QosOnly -ShadowUsedBytes 0 -ShadowCount 0)
        Assert-Equal -Expected 'Clean' -Actual $r.Status
    }
}

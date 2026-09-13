<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42aa791a-a124-4a3c-98f2-d6d34623c3d2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install preflight architecture arm64 pester
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
    Behavioral Pester guard on the Windows installer's system preflight: the
    architecture it detects, and which shortfalls are allowed to stop an
    install.
.DESCRIPTION
    Two properties, neither reproducible on the machines this suite normally
    runs on, both asserted against the real function bodies lifted out of
    install/windows.hyper-v.ps1.

      * THE DETECTOR MUST NEVER PRODUCE AN EMPTY NAME. The preflight is the
        one part of the installer that runs under Windows PowerShell 5.1,
        before the relaunch into pwsh -- so a .NET API present on pwsh 7's
        runtime may be absent there. PowerShell answers a missing static
        member with $null and NO error, at any ErrorActionPreference (see
        memory feedback_missing-static-member-returns-null-silently.md for
        the trap class), so a detector that reads one directly does not fail:
        it reports architecture '' and reads to the operator as broken
        hardware. Both absent shapes are exercised for real here by pointing
        the detector's type lookup at a type that resolves but lacks the
        member, and at a name that resolves to nothing at all.
      * PHYSICAL CORE COUNT ADVISES, IT NEVER GATES. Edition, architecture,
        RAM and free disk put the install behind a confirmation prompt. Core
        count does not, at any value: the harness runs correctly on a smaller
        machine, only slower, and no ARM64 Windows host on the market reaches
        16 physical cores, so a gate there would refuse a whole supported host
        class over a speed difference.

    Everything the preflight touches -- CIM, the registry, the environment
    block, every output stream and the prompt itself -- is stubbed, so the
    suite runs anywhere pwsh does and reads nothing about the host it is on.

    Stub configuration is kept in explicitly $script:-scoped variables. A stub
    parameter named like a local of the function under test would be found by
    PowerShell's dynamic scoping in the CALLER's frame first, and silently
    return that local's value (0, at the point the stub is reached) instead of
    the case's.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: Invoke-Pester -Path test/modules/Test.InstallSystemRequirement.Tests.ps1
#>

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$repoRoot  = Get-YurunaTestRepoRoot -SuiteDirectory $here
$installer = Join-Path $repoRoot 'install/windows.hyper-v.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found: $installer" }

# The installer is a top-to-bottom script that elevates, installs packages and
# rewrites the checkout -- it cannot be dot-sourced. Lift the functions under
# test out of its AST, so this suite exercises the shipped bodies rather than a
# copy that drifts.
function Get-InstallerFunctionText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $fn = Get-YurunaTestFunctionAst -Path $installer -Name $Name
    if (-not $fn) { throw "Function '$Name' not found in $installer." }
    return $fn.Extent.Text
}

$script:DetectorText  = Get-InstallerFunctionText 'Get-HostArchitecture'
$script:RequirentText = Get-InstallerFunctionText 'Test-SystemRequirement'
$script:EditionGateText = Get-InstallerFunctionText 'Assert-HyperVCapableEdition'

# The two shapes the managed lookup takes under .NET Framework, built by
# repointing the detector's own type name -- the guard code runs for real
# rather than being edited out.
#   System.Math resolves and has no OSArchitecture: the member-absent shape.
#   An unresolvable name yields $null from -as [type]: the type-absent shape.
function ConvertTo-DetectorVariant {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$TypeName)
    $original = "'System.Runtime.InteropServices.RuntimeInformation'"
    if ($script:DetectorText -notlike "*$original*") {
        throw "The detector no longer resolves its type from the literal $original; this suite cannot build its .NET Framework variants."
    }
    return $script:DetectorText.Replace($original, "'$TypeName'")
}

# --- REGION: Stubbed requirement sources
# Every stub uses script scope; see the file header.
$script:StubRegistry = $null   # $null means the read fails, as on a locked-down or non-Windows box

function Set-StubSource {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets three script-scoped stub values and two environment variables inside this suite; -WhatIf is meaningless and there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    param([AllowNull()][string]$Registry, [hashtable]$Environment = @{})
    $script:StubRegistry = $Registry
    foreach ($name in 'PROCESSOR_ARCHITEW6432', 'PROCESSOR_ARCHITECTURE') {
        if (Test-Path -LiteralPath "Env:$name") { Remove-Item -LiteralPath "Env:$name" }
    }
    foreach ($name in $Environment.Keys) { Set-Item -LiteralPath "Env:$name" -Value $Environment[$name] }
}

function Get-ItemProperty {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Shadowing the registry read is the point: the detector must be exercised against a machine value this suite chooses, on a host that has no HKLM at all.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'The parameters exist to absorb the real call signature; the stub answers from script scope.')]
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    if ($null -eq $script:StubRegistry) { throw "Cannot find path '$LiteralPath' because it does not exist." }
    [pscustomobject]@{ PROCESSOR_ARCHITECTURE = $script:StubRegistry }
}

function Invoke-Detector {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Source)
    . ([scriptblock]::Create($Source))
    return (Get-HostArchitecture)
}

# --- REGION: Stubbed system requirements
$script:StubArch    = 'AMD64'
$script:StubCores   = 32
$script:StubMemGB   = 32
$script:StubFreeGB  = 600
$script:StubCaption = 'Microsoft Windows 11 Pro'
$script:StubBuild = '26100'
$script:StubProductType = 1
$script:StubSku = 48
$script:Said        = New-Object System.Collections.Generic.List[string]
$script:Prompted    = $false

function Get-HostArchitecture { $script:StubArch }
function Write-Step    { param([string]$m) $script:Said.Add("STEP $m") }
function Write-Warn    { param([string]$m) $script:Said.Add("WARN $m") }
function Write-Die     { param([string]$m) $script:Said.Add("DIE $m"); throw $m }

function Write-Warning {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'The preflight writes its issue list straight to the warning stream, so capturing what the operator is told means shadowing it.')]
    param([Parameter(Position = 0)][string]$Message)
    $script:Said.Add("WARN $Message")
}

# The prompt under test. Answering 'y' keeps a case that DOES gate running to
# the end, so the suite can assert on everything printed after the question.
function Read-Host {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Whether this prompt is reached at all is the property under test; a real Read-Host would hang the suite.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'The prompt text is irrelevant; only the fact that the prompt was reached is recorded.')]
    param([Parameter(Position = 0)][string]$Prompt)
    $script:Prompted = $true
    'y'
}

function Get-CimInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'The suite describes a machine the host is not: an 8-core ARM64 laptop. CIM is where the preflight reads that, so CIM is what it must be told.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Filter absorbs the real call signature; the stubbed disk answer does not depend on it.')]
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    switch ($ClassName) {
        'Win32_OperatingSystem' {
            [pscustomobject]@{
                Caption = $script:StubCaption
                TotalVisibleMemorySize = [double]$script:StubMemGB * 1MB
                BuildNumber = $script:StubBuild
                ProductType = $script:StubProductType
                OperatingSystemSKU = $script:StubSku
            }
        }
        'Win32_Processor' {
            if ($script:StubCores -gt 0) { 1..$script:StubCores | ForEach-Object { [pscustomobject]@{ NumberOfCores = 1 } } }
        }
        'Win32_LogicalDisk' {
            [pscustomobject]@{ FreeSpace = [double]$script:StubFreeGB * 1GB }
        }
    }
}

function Invoke-Preflight {
    [CmdletBinding()]
    param([string]$Arch = 'AMD64', [int]$Cores = 32, [int]$MemGB = 32, [int]$FreeGB = 600,
          [string]$Caption = 'Microsoft Windows 11 Pro', [string]$Build = '26100',
          [int]$ProductType = 1, [int]$Sku = 48)
    $script:StubArch    = $Arch
    $script:StubCores   = $Cores
    $script:StubMemGB   = $MemGB
    $script:StubFreeGB  = $FreeGB
    $script:StubCaption = $Caption
    $script:StubBuild = $Build
    $script:StubProductType = $ProductType
    $script:StubSku = $Sku
    $script:Said.Clear()
    $script:Prompted = $false
    $env:SystemDrive = 'C:'
    . ([scriptblock]::Create($script:RequirentText))
    Test-SystemRequirement
    return ($script:Said -join "`n")
}
}

Describe 'installer preflight -- host architecture detection' {

    It 'a missing static member is $null with no error, which is why the read is guarded' {
        # The premise the detector is built around. Contrast an unresolvable
        # TYPE, which throws a terminating RuntimeException under Stop -- a
        # missing MEMBER is silent, so "empty value, run continued" is the
        # symptom to recognize.
        $ErrorActionPreference = 'Stop'
        $silent = [System.Math]::NoSuchProperty
        Assert-Null $silent 'a missing static member must read as $null'
        Assert-Throw { $null = [No.Such.Type.Here]::Anything } 'Unable to find type' `
            'an unresolvable type must throw, unlike a missing member'
    }

    It 'reads the managed API only behind a presence check, never as a bare static' {
        $bare = [regex]::Matches($script:DetectorText, '\[[^\]]*RuntimeInformation\s*\]\s*::')
        Assert-Equal -Expected 0 -Actual $bare.Count `
            'a bare [RuntimeInformation]::Member read returns $null silently when the member is absent; resolve the type and check GetProperty first'
        Assert-Match "GetProperty\(\s*'OSArchitecture'\s*\)" $script:DetectorText `
            'the presence check on OSArchitecture is what keeps an absent member from becoming an empty architecture name'
    }

    Context 'the managed API answers (pwsh 7)' {
        It 'prefers the machine registry over the emulated view of the process' {
            Set-StubSource -Registry 'ARM64' -Environment @{ PROCESSOR_ARCHITECTURE = 'AMD64' }
            Assert-StringEqual -Expected 'ARM64' -Actual (Invoke-Detector $script:DetectorText) `
                'an x64 shell emulated on an ARM64 host reports AMD64 for itself; the machine value wins'
        }

        It 'falls through an unreadable registry to the managed answer' {
            Set-StubSource -Registry $null -Environment @{}
            Assert-Match '^(AMD64|ARM64)$' (Invoke-Detector $script:DetectorText) `
                'the managed API alone must still name the architecture of the machine running this suite'
        }

        It 'skips a source that answers with an empty string' {
            Set-StubSource -Registry '' -Environment @{}
            Assert-Match '^(AMD64|ARM64)$' (Invoke-Detector $script:DetectorText) `
                'an empty registry value must be passed over, not returned'
        }
    }

    Context 'OSArchitecture is absent (Windows PowerShell 5.1 on .NET Framework)' {
        BeforeAll {
            $script:NoMember = ConvertTo-DetectorVariant 'System.Math'
            $script:NoType   = ConvertTo-DetectorVariant 'No.Such.Type.Here'
        }

        It 'names ARM64 from the machine registry when the member does not exist' {
            Set-StubSource -Registry 'ARM64' -Environment @{ PROCESSOR_ARCHITECTURE = 'AMD64' }
            Assert-StringEqual -Expected 'ARM64' -Actual (Invoke-Detector $script:NoMember) 'the registry must carry the answer'
        }

        It 'names ARM64 from the machine registry when the type does not resolve' {
            Set-StubSource -Registry 'ARM64' -Environment @{ PROCESSOR_ARCHITECTURE = 'AMD64' }
            Assert-StringEqual -Expected 'ARM64' -Actual (Invoke-Detector $script:NoType) 'an unloadable assembly must not cost the answer'
        }

        It 'reaches the environment block when the registry is unreadable too' {
            Set-StubSource -Registry $null -Environment @{ PROCESSOR_ARCHITEW6432 = 'ARM64'; PROCESSOR_ARCHITECTURE = 'x86' }
            Assert-StringEqual -Expected 'ARM64' -Actual (Invoke-Detector $script:NoMember) `
                'PROCESSOR_ARCHITEW6432 holds the machine value whenever the process is the emulated one'
        }

        It 'NEVER returns an empty name when no source answers at all' {
            Set-StubSource -Registry $null -Environment @{}
            $arch = Invoke-Detector $script:NoMember
            Assert-True ($arch.Length -gt 0) 'an empty architecture name reaches the operator as "architecture $()" and reads as broken hardware'
            Assert-StringEqual -Expected 'unknown' -Actual $arch 'a name nothing answered must still be nameable'
        }

        It 'names an unsupported architecture instead of hiding it' {
            Set-StubSource -Registry 'x86' -Environment @{}
            Assert-StringEqual -Expected 'x86' -Actual (Invoke-Detector $script:NoMember) `
                'the operator has to be told which architecture was found, not merely that it was refused'
        }

        It 'normalizes the spellings the different sources use' {
            Set-StubSource -Registry 'x86_64' -Environment @{}
            Assert-StringEqual -Expected 'AMD64' -Actual (Invoke-Detector $script:NoMember) 'x86_64 is AMD64'
            Set-StubSource -Registry 'aarch64' -Environment @{}
            Assert-StringEqual -Expected 'ARM64' -Actual (Invoke-Detector $script:NoMember) 'aarch64 is ARM64'
            Set-StubSource -Registry 'Arm64' -Environment @{}
            Assert-StringEqual -Expected 'ARM64' -Actual (Invoke-Detector $script:NoMember) 'the managed enum spelling is ARM64'
        }
    }
}

Describe 'installer preflight -- what blocks an install and what only advises' {

    It 'decides edition support from stable CIM values, not the translated caption' {
        Assert-False ($script:RequirentText -match '\$caption\s+-match') 'the requirements check still branches on translated caption prose'
        Assert-False ($script:EditionGateText -match '\$caption\s+-match') 'the hard edition gate still branches on translated caption prose'

        $said = Invoke-Preflight -Caption 'Microsoft Windows 11 Profissional' -Build '26100' -ProductType 1 -Sku 48
        Assert-False $script:Prompted 'a supported edition became unsupported when only its caption language changed'
        Assert-Match 'STEP System OK' $said
    }

    It 'lets stable values overrule a misleading English caption' {
        $null = Invoke-Preflight -Caption 'Microsoft Windows 11 Pro' -Build '19045' -ProductType 1 -Sku 48
        Assert-True $script:Prompted 'the English product name overruled the pre-Windows-11 build value'

        $null = Invoke-Preflight -Caption 'Microsoft Windows 10 Home' -Build '26100' -ProductType 1 -Sku 101
        Assert-True $script:Prompted 'a known incapable SKU was accepted because the build looked current'
    }

    It 'rejects server SKUs that do not contain the Hyper-V platform' {
        foreach ($sku in 36, 37, 38, 39, 40, 41, 64) {
            $null = Invoke-Preflight -Caption 'Microsoft Windows Server' -Build '26100' -ProductType 3 -Sku $sku
            Assert-True $script:Prompted "server SKU $sku was accepted even though it cannot host Hyper-V"

            $script:StubCaption = 'Microsoft Windows Server'
            $script:StubProductType = 3
            $script:StubSku = $sku
            Assert-Throw {
                . ([scriptblock]::Create($script:EditionGateText))
                Assert-HyperVCapableEdition
            } 'cannot run Hyper-V' "the hard edition gate accepted server SKU $sku"
        }
    }

    It 'accepts a Hyper-V-capable Windows Server SKU' {
        $said = Invoke-Preflight -Caption 'Microsoft Windows Server Standard' -Build '26100' -ProductType 3 -Sku 7
        Assert-False $script:Prompted 'a Hyper-V-capable server SKU was rejected'
        Assert-Match 'STEP System OK' $said

        $script:StubCaption = 'Microsoft Windows Server Standard'
        $script:StubProductType = 3
        $script:StubSku = 7
        . ([scriptblock]::Create($script:EditionGateText))
        Assert-HyperVCapableEdition
    }

    It 'an 8-core ARM64 host that meets everything else installs without a prompt' {
        $said = Invoke-Preflight -Arch 'ARM64' -Cores 8
        Assert-False $script:Prompted 'core count must never put the install behind a confirmation'
        Assert-Match 'STEP System OK' $said 'the host must be reported as OK'
        Assert-Match 'ARM64' $said 'the architecture must be named in the summary'
    }

    It 'still tells the operator the core count is below the recommendation' {
        $said = Invoke-Preflight -Arch 'ARM64' -Cores 8
        Assert-Match 'Recommended.*8 physical cores' $said 'advising is not the same as staying silent'
    }

    It 'does not gate at any core count' {
        foreach ($n in 1, 2, 4, 15) {
            $null = Invoke-Preflight -Arch 'ARM64' -Cores $n
            Assert-False $script:Prompted "a $n-core host must not be prompted; the harness runs there, only slower"
        }
    }

    It 'says nothing about cores when the recommendation is met' {
        $said = Invoke-Preflight -Arch 'ARM64' -Cores 32
        Assert-False ($said -match 'Recommended') 'a host at or above the recommendation has nothing to be told'
        Assert-Match 'STEP System OK' $said 'the check is silent when every requirement is met'
    }

    It 'keeps RAM, free disk, edition and architecture as blocking issues' {
        $cases = @(
            @{ Name = 'RAM';          Splat = @{ MemGB = 16 } },
            @{ Name = 'free disk';    Splat = @{ FreeGB = 400 } },
            @{ Name = 'edition';      Splat = @{ Build = '19045' } },
            @{ Name = 'architecture'; Splat = @{ Arch = 'x86' } }
        )
        foreach ($case in $cases) {
            $null = Invoke-Preflight @($case.Splat)[0]
            Assert-True $script:Prompted "a shortfall in $($case.Name) must still ask the operator to confirm"
        }
    }

    It 'separates the recommendation from the issues when it does prompt' {
        $said = Invoke-Preflight -Arch 'ARM64' -Cores 8 -MemGB 16
        Assert-True $script:Prompted 'RAM below the baseline still prompts'
        Assert-Match 'Recommended, but not blocking' $said `
            'the core count must not read as one of the reasons the install stopped to ask'
        Assert-False ($said -match 'does not meet Yuruna TESTED requirements:\r?\n.*physical cores') `
            'the core count must not be listed among the blocking issues'
    }

    It 'names an unsupported architecture in the issue it raises' {
        $said = Invoke-Preflight -Arch 'unknown'
        Assert-Match "architecture 'unknown' detected" $said `
            'the issue text carries whatever the detector named, so an empty name would surface here'
    }
}

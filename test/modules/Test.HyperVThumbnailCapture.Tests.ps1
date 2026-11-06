<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42af6d3c-e562-4e6b-a3bc-b8dafa97a167
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hyper-v screenshot thumbnail cim pester
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
    The Hyper-V driver's WMI thumbnail capture keeps the objects it resolves
    between frames, and resolves them again when a capture through them fails.
.DESCRIPTION
    Runs on any host. The CIM cmdlets are shadowed inside the driver module's
    own scope -- they do not exist off Windows, so Pester cannot mock them --
    and the shadows count the queries and answer as the VM's current
    generation would. Nothing here talks to Hyper-V.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    $script:DriverPath = Join-Path $repoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
    Import-Module $script:DriverPath -Force -DisableNameChecking -WarningAction SilentlyContinue
    $script:Driver = Get-Module Yuruna.Host
    & $script:Driver {
        function script:Get-CimInstance {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Shadow stub; the driver binds these by name and the stub answers from the fixture.')]
            param($Namespace, $ClassName, $Filter)
            if ($ClassName -eq 'Msvm_VirtualSystemManagementService') {
                $script:CimQueries.Add('service')
                return [pscustomobject]@{ Service = $script:VmGeneration }
            }
            $script:CimQueries.Add('settings')
            [pscustomobject]@{ VirtualSystemType = 'Microsoft:Hyper-V:System:Realized'; Generation = $script:VmGeneration }
        }
        function script:Invoke-CimMethod {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Shadow stub; the driver binds these by name and the stub answers from the fixture.')]
            param($InputObject, $MethodName, $Arguments)
            $script:CimCalls++
            # Settings from an earlier generation of the VM name a VM that is gone.
            if ($Arguments.TargetSystem.Generation -ne $script:VmGeneration) { return [pscustomobject]@{ ReturnValue = 32775; ImageData = $null } }
            if ($script:RefuseCapture) { return [pscustomobject]@{ ReturnValue = 32768; ImageData = $null } }
            [pscustomobject]@{ ReturnValue = 0; ImageData = [byte[]](1, 2, 3, $script:VmGeneration) }
        }
    }
    function Reset-CaptureFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: resets in-memory fixture state inside the driver module scope.')]
        param([int]$Generation = 1, [switch]$Refuse)
        & $script:Driver { param($g, $r)
            $script:CimQueries = [System.Collections.Generic.List[string]]::new()
            $script:CimCalls = 0
            $script:VmGeneration = $g
            $script:RefuseCapture = $r
        } $Generation ([bool]$Refuse)
    }
    function Get-CaptureFixture { & $script:Driver { [pscustomobject]@{ Queries = @($script:CimQueries); Calls = $script:CimCalls } } }
}

AfterAll {
    Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Hyper-V thumbnail capture' {
    BeforeEach {
        & $script:Driver { $script:HyperVThumbnailTargets.Clear(); $script:HyperVManagementService = $null }
    }

    It 'resolves the VM and the service once, then captures later frames with no query' {
        Reset-CaptureFixture
        $first = & $script:Driver { Get-HyperVThumbnailByte -VMName 'vm1' -Width 640 -Height 480 }
        $second = & $script:Driver { Get-HyperVThumbnailByte -VMName 'vm1' -Width 640 -Height 480 }
        Assert-Equal -Expected 4 -Actual $first.Length
        Assert-Equal -Expected 4 -Actual $second.Length
        $fixture = Get-CaptureFixture
        Assert-Equal -Expected 'settings,service' -Actual ($fixture.Queries -join ',') -Because 'the second frame reuses what the first resolved'
        Assert-Equal -Expected 2 -Actual $fixture.Calls
    }

    It 'resolves again when the VM was rebuilt under the same name, and captures the new one' {
        Reset-CaptureFixture
        $null = & $script:Driver { Get-HyperVThumbnailByte -VMName 'vm1' -Width 640 -Height 480 }
        & $script:Driver { $script:VmGeneration = 2 }
        $bytes = & $script:Driver { Get-HyperVThumbnailByte -VMName 'vm1' -Width 640 -Height 480 }
        Assert-Equal -Expected 2 -Actual ([int]$bytes[3]) -Because 'the frame comes from the VM as it exists now'
        Assert-Equal -Expected 'settings,service,settings,service' -Actual ((Get-CaptureFixture).Queries -join ',')
    }

    It 'gives up after one resolution when a freshly resolved capture is refused' {
        Reset-CaptureFixture -Refuse
        $bytes = & $script:Driver { Get-HyperVThumbnailByte -VMName 'vm1' -Width 1920 -Height 1080 }
        Assert-True ($null -eq $bytes) 'a refused size returns nothing, so the caller tries a smaller one'
        $fixture = Get-CaptureFixture
        Assert-Equal -Expected 'settings,service' -Actual ($fixture.Queries -join ',') -Because 'fresh objects are not resolved twice'
        Assert-Equal -Expected 1 -Actual $fixture.Calls
    }

    It 'imports the log-dir module only when its helper is missing' {
        $text = (Get-Command -Module Yuruna.Host -Name Get-HyperVScreenshot).ScriptBlock.ToString()
        Assert-Match -Pattern "if \(-not \(Get-Command Initialize-YurunaLogDir" -Actual $text -Because 'a forced import per frame re-read the module on every poll'
        Assert-False ($text -match "Test\.YurunaDir\.psm1'\) -Force") 'the import must not be forced'
    }
}

<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42c869eb-bcb1-4640-9d26-b9f3f7fbc926
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool admin
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Set or clear the framework and project repositories a pool's hosts run.
.DESCRIPTION
    See https://yuruna.link/42010605-0004.
.PARAMETER PoolId
    Target pool id.
.PARAMETER FrameworkUrl
    Yuruna framework repository URL each pooled host clones for the cycle.
.PARAMETER ProjectUrl
    Project repository URL each pooled host tests.
.PARAMETER Clear
    Remove the pool's repositories, so each member runs its own configured
    repositories from its next cycle.
.PARAMETER ConfigurationGitUrl
    Writable URL/path of the bare configuration repo. Defaults to pool.configurationGitUrl from
    test.config.yml.
.PARAMETER ConfigurationDir
    Local working clone. Defaults to <runtime>/pool-configuration-admin.
.EXAMPLE
    test/pool/Set-PoolRepository.ps1 -PoolId lab -FrameworkUrl https://github.com/alissonsol/yuruna -ProjectUrl https://github.com/alissonsol/yuruna-project
.EXAMPLE
    test/pool/Set-PoolRepository.ps1 -PoolId lab -Clear
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Set')]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory, ParameterSetName = 'Set')][string]$FrameworkUrl,
    [Parameter(Mandatory, ParameterSetName = 'Set')][string]$ProjectUrl,
    [Parameter(Mandatory, ParameterSetName = 'Clear')][switch]$Clear,
    [string]$ConfigurationGitUrl,
    [string]$ConfigurationDir
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ModulesDir  = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
# The failure paths below pass -ErrorAction Continue: under the strict
# preference above, a bare Write-Error would itself terminate and skip
# the clean exit-code path.
Import-Module powershell-yaml -ErrorAction Stop

# --- REGION: Validate the arguments
# Each URL reaches every member's `git clone` and, from the pool-control
# service, a `pwsh -File` argument list: a value with whitespace would be split
# or rejected downstream, and one starting with '-' binds as a parameter name.
# Checked before the store is opened, so a bad value never costs a clone.
if (-not $Clear) {
    $urls = [ordered]@{ FrameworkUrl = $FrameworkUrl.Trim(); ProjectUrl = $ProjectUrl.Trim() }
    foreach ($name in @($urls.Keys)) {
        $value = [string]$urls[$name]
        if ((-not $value) -or ($value -match '[\s\p{Cc}]') -or $value.StartsWith('-', [StringComparison]::Ordinal)) {
            Write-Error (Format-YurunaOperatorMessage -Key 'runner.pool_repositories_url_invalid' -Arguments @{ parameter = "$name" }) -ErrorAction Continue
            exit $ExitFailure
        }
    }
    $FrameworkUrl = $urls['FrameworkUrl']
    $ProjectUrl   = $urls['ProjectUrl']
}

# --- REGION: Open the configuration store
$open = Open-YurunaPoolAdminStore -ConfigurationGitUrl $ConfigurationGitUrl -ConfigurationDir $ConfigurationDir -Confirm:$false
$t = $open.Target
if (-not $open.Ok) { Write-Error $open.Error -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Apply the change
$doc  = Read-YurunaPoolsDoc -ConfigurationDir $t.ConfigurationDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if (-not $pool) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_945821c2fef42ae6' -Arguments @{ poolId = "$PoolId" }) -ErrorAction Continue; exit $ExitFailure }

if ($Clear) {
    # Allowed on every pool, the auto-enrollment target included: clearing is
    # how a store that gave the target pool repositories gets repaired.
    if ($pool.Contains('repositories')) { $pool.Remove('repositories') }
    $message = "pool: clear repositories on $PoolId"
} else {
    # See https://yuruna.link/42010605-0004
    $targetPoolId = if ($doc['autoEnrollment'] -is [System.Collections.IDictionary]) { [string]$doc['autoEnrollment']['targetPoolId'] } else { '' }
    if ($targetPoolId -and [string]::Equals([string]$pool['poolId'], $targetPoolId, [StringComparison]::Ordinal)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f1dc62bfb0f61720' -Arguments @{ poolId = "$PoolId"; frameworkUrl = "$FrameworkUrl"; projectUrl = "$ProjectUrl" }) -ErrorAction Continue
        exit $ExitFailure
    }
    $pool['repositories'] = [ordered]@{ frameworkUrl = $FrameworkUrl; projectUrl = $ProjectUrl }
    $message = "pool: set repositories on $PoolId"
}

# --- REGION: Save, commit and push
$pub = Publish-YurunaPoolDocChange -ConfigurationDir $t.ConfigurationDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Message $message -Confirm:$false
if (-not $pub.Ok) { Write-Error $pub.Error -ErrorAction Continue; exit $ExitFailure }

if ($Clear) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.pool_repositories_cleared' -Arguments @{ poolId = "$PoolId" }) -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c11b4fa818b922ab' -Arguments @{ poolId = "$PoolId"; frameworkUrl = "$FrameworkUrl"; projectUrl = "$ProjectUrl" }) -InformationAction Continue
}
exit $ExitOk

<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42ea8af8-5cff-4141-a7b1-74224e2ce4d0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool enrollment exclusion
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module powershell-yaml -Force
    $script:hostId = '42abcdef0123456789abcdef01234567'
    $script:peerId = '42bbbbbb0123456789abcdef01234567'
    $repoRoot = Split-Path (Split-Path $PSScriptRoot)
    $source = Get-Content -Raw (Join-Path $repoRoot 'test/pool/Remove-HostFromPool.ps1')
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    # Run the actual parameter contract and all validation/mutation/save code in
    # a child. Only git transport and entrypoint discovery are fixture stubs.
    $helper = @'
$ErrorActionPreference = 'Stop'
Import-Module '__ADMIN__' -Force -DisableNameChecking
Import-Module '__GLOBAL__' -Force -DisableNameChecking
Import-Module powershell-yaml
$ExitOk = 0
$ExitFailure = 1
function Format-YurunaHostId { param($HostId) return $HostId }
function Resolve-YurunaPoolAdminTarget { param($IntentGitUrl, $IntentDir) return @{ IntentGitUrl = 'fixture'; IntentDir = $IntentDir } }
function Open-YurunaPoolIntent { param($IntentGitUrl, $IntentDir, $Confirm) return @{ Ok = $true } }
function Publish-YurunaPoolIntent {
    param($IntentDir, $Message, $Confirm)
    if (Test-Path (Join-Path $IntentDir 'publish.fail')) { return @{ Ok = $false; Error = 'fixture publication refused' } }
    Add-Content -LiteralPath (Join-Path $IntentDir 'published') -Value $Message
    return @{ Ok = $true; Pushed = $true }
}
'@
    $helper = $helper.Replace('__ADMIN__', (Join-Path $PSScriptRoot 'Test.PoolAdmin.psm1').Replace("'", "''")).Replace('__GLOBAL__', (Join-Path $repoRoot 'automation/Yuruna.Globalization.psm1').Replace("'", "''"))
    $script:child = Join-Path $TestDrive 'remove-host.ps1'
    $body = $source.Substring($source.IndexOf('# --- REGION: Validate the arguments'))
    Set-Content -LiteralPath $script:child -Value ($ast.ParamBlock.Extent.Text + "`n" + $helper + "`n" + $body)
    function New-ExclusionFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only isolated test fixtures.')]
        [CmdletBinding()]
        param([bool]$Member = $true, [bool]$Policy = $true)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        $members = @($script:peerId)
        if ($Member) { $members += $script:hostId }
        $doc = [ordered]@{ schemaVersion = 2; pools = @([ordered]@{ poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; members = $members }) }
        if ($Policy) { $doc['autoEnrollment'] = [ordered]@{ enabled = $true; targetPoolId = 'lab'; excluded = @($script:peerId) } }
        Set-Content -LiteralPath (Join-Path $dir 'pools.yml') -Value (ConvertTo-Yaml $doc)
        return $dir
    }
}
Describe 'durable auto-enrollment exclusions' {
    It 'excludes a host and removes membership in one publication (member=<Member>, policy=<Policy>)' -ForEach @(
        @{ Member = $true; Policy = $true }
        @{ Member = $false; Policy = $true }
        @{ Member = $false; Policy = $false }
    ) {
        $dir = New-ExclusionFixture -Member $Member -Policy $Policy
        $output = & pwsh -NoProfile -NonInteractive -File $script:child -HostId $script:hostId -Exclude -IntentDir $dir 2>&1
        Assert-Equal 0 $LASTEXITCODE ($output -join "`n")
        $saved = Get-Content -Raw (Join-Path $dir 'pools.yml') | ConvertFrom-Yaml
        Assert-False ($saved.pools[0].members -contains $script:hostId)
        Assert-True ($saved.pools[0].members -contains $script:peerId)
        Assert-True ($saved.autoEnrollment.excluded -contains $script:hostId)
        if ($Policy) {
            Assert-True ($saved.autoEnrollment.excluded -contains $script:peerId)
            Assert-True $saved.autoEnrollment.enabled
        }
        Assert-Equal 1 @(Get-Content (Join-Path $dir 'published')).Count
        $output = & pwsh -NoProfile -NonInteractive -File $script:child -HostId $script:hostId -Exclude -IntentDir $dir 2>&1
        Assert-Equal 0 $LASTEXITCODE ($output -join "`n")
        Assert-Equal 1 @(Get-Content (Join-Path $dir 'published')).Count 'repeated exclusion must not publish again'
    }
    It 'retains ordinary pool-only removal semantics without the switch' {
        $dir = New-ExclusionFixture -Policy $false
        $output = & pwsh -NoProfile -NonInteractive -File $script:child -PoolId lab -HostId $script:hostId -IntentDir $dir 2>&1
        Assert-Equal 0 $LASTEXITCODE ($output -join "`n")
        $saved = Get-Content -Raw (Join-Path $dir 'pools.yml') | ConvertFrom-Yaml
        Assert-False ($saved.pools[0].members -contains $script:hostId)
        Assert-False $saved.ContainsKey('autoEnrollment')
    }
    It 'reports a publication refusal instead of promising a durable exclusion' {
        $dir = New-ExclusionFixture
        Set-Content -LiteralPath (Join-Path $dir 'publish.fail') -Value 'refuse'
        $null = & pwsh -NoProfile -NonInteractive -File $script:child -HostId $script:hostId -Exclude -IntentDir $dir 2>&1
        Assert-NotEqual 0 $LASTEXITCODE
        Assert-False (Test-Path (Join-Path $dir 'published'))
    }
}

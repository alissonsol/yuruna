<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42f6a2c8-1d3e-4b90-8a7f-2e3d4c5b6a7e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config sync pester
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
    Pester coverage for Test.HostConfigSync.psm1: the cross-host-type
    networkStorage conversion, the reference-config merge rules (secrets,
    non-portable values), and the shared-token credential envelope.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Run: Invoke-Pester -Path test/modules/Test.HostConfigSync.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Prelude.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.HostConfigSync.psm1') -Force -DisableNameChecking
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning "powershell-yaml unavailable; YAML round-trip tests will fail." }

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'Get-ConfigSyncLocalPathDefault' {
    It 'uses the y:/z: drive-letter convention on Windows' {
        Assert-Equal -Expected 'y:' -Actual (Get-ConfigSyncLocalPathDefault -HostType 'host.windows.hyper-v' -Tier pool  -ServerName 'ypool-nas')
        Assert-Equal -Expected 'z:' -Actual (Get-ConfigSyncLocalPathDefault -HostType 'host.windows.hyper-v' -Tier stash -ServerName 'ystash-nas')
    }
    It 'uses /mnt/<server> on Ubuntu and ~/Shares/<server> on macOS' {
        Assert-Equal -Expected '/mnt/ypool-nas'      -Actual (Get-ConfigSyncLocalPathDefault -HostType 'host.ubuntu.kvm' -Tier pool -ServerName 'ypool-nas')
        Assert-Equal -Expected '~/Shares/ystash-nas' -Actual (Get-ConfigSyncLocalPathDefault -HostType 'host.macos.utm' -Tier stash -ServerName 'ystash-nas')
    }
    It 'returns empty when a POSIX default has no server name to build from' {
        Assert-Equal -Expected '' -Actual (Get-ConfigSyncLocalPathDefault -HostType 'host.ubuntu.kvm' -Tier pool -ServerName '')
    }
}

Describe 'Convert-ConfigSyncNetworkStorage' {
    $unixRef = [ordered]@{
        poolLocalPath   = '/mnt/ypool-nas'
        poolNetworkPath = '//ypool-nas/work/yuruna.pool'
        poolNetworkUser = 'yuruna-pool'
        stashLocalPath   = '~/Shares/ystash-nas'
        stashNetworkPath = '//ystash-nas/work/yuruna.stash'
        stashNetworkUser = 'yuruna-stash'
    }
    It 'converts a unix-style reference for a Windows host: UNC slashes + drive-letter defaults' {
        $r = Convert-ConfigSyncNetworkStorage -Reference $unixRef -Local $null -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected '\\ypool-nas\work\yuruna.pool'   -Actual $r.NetworkStorage['poolNetworkPath']
        Assert-Equal -Expected '\\ystash-nas\work\yuruna.stash' -Actual $r.NetworkStorage['stashNetworkPath']
        Assert-Equal -Expected 'y:' -Actual $r.NetworkStorage['poolLocalPath']
        Assert-Equal -Expected 'z:' -Actual $r.NetworkStorage['stashLocalPath']
        Assert-Equal -Expected 'yuruna-pool' -Actual $r.NetworkStorage['poolNetworkUser']
        Assert-Equal -Expected 0 -Actual @($r.Warnings).Count -Because 'a clean conversion warns about nothing'
    }
    It 'converts a Windows-style reference for a Linux host' {
        $winRef = [ordered]@{
            poolLocalPath = 'y:'; poolNetworkPath = '\\ypool-nas\work\yuruna.pool'; poolNetworkUser = 'yuruna-pool'
            stashLocalPath = ''; stashNetworkPath = ''; stashNetworkUser = ''
        }
        $r = Convert-ConfigSyncNetworkStorage -Reference $winRef -Local $null -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected '//ypool-nas/work/yuruna.pool' -Actual $r.NetworkStorage['poolNetworkPath']
        Assert-Equal -Expected '/mnt/ypool-nas' -Actual $r.NetworkStorage['poolLocalPath']
        Assert-Equal -Expected '' -Actual $r.NetworkStorage['stashNetworkPath'] -Because 'an unconfigured reference tier stays unconfigured'
    }
    It 'keeps a populated local mount path instead of the derived default' {
        $local = [ordered]@{ poolLocalPath = 'x:'; poolNetworkPath = '\\old\share'; poolNetworkUser = 'old' }
        $r = Convert-ConfigSyncNetworkStorage -Reference $unixRef -Local $local -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected 'x:' -Actual $r.NetworkStorage['poolLocalPath'] -Because 'a working local mount point survives the sync'
        Assert-Equal -Expected 'z:' -Actual $r.NetworkStorage['stashLocalPath'] -Because 'a tier with no local value still gets the default'
    }
    It 'clears a locally-populated tier the reference does not configure, with a warning' {
        $ref   = [ordered]@{ poolNetworkPath = '//ypool-nas/work/yuruna.pool'; poolNetworkUser = 'yuruna-pool'; poolLocalPath = '/mnt/ypool-nas' }
        $local = [ordered]@{ stashLocalPath = 'z:'; stashNetworkPath = '\\ystash-nas\work\yuruna.stash'; stashNetworkUser = 'yuruna-stash' }
        $r = Convert-ConfigSyncNetworkStorage -Reference $ref -Local $local -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected '' -Actual $r.NetworkStorage['stashNetworkPath']
        Assert-True (@($r.Warnings) -match 'stash') 'clearing a populated tier is warned about'
    }
}

Describe 'Merge-ConfigSyncReferenceConfig' {
    function New-ReferenceDoc {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: pure fixture constructor, no system state touched.')]
        [CmdletBinding()] [OutputType([hashtable])] param()
        return @{
            networkStorage = @{
                poolLocalPath = '/mnt/ypool-nas'; poolNetworkPath = '//ypool-nas/work/yuruna.pool'; poolNetworkUser = 'yuruna-pool'
                stashLocalPath = ''; stashNetworkPath = ''; stashNetworkUser = ''
            }
            repositories = @{ frameworkUrl = 'https://example/framework'; projectUrl = 'https://example/project' }
            pool         = @{ enabled = $false; localClonePath = ''; networkReplicate = $true }
            vmStart      = @{ cachingProxyIP = '192.168.7.229' }
        }
    }
    It 'copies host-agnostic values verbatim and converts networkStorage' {
        $m = Merge-ConfigSyncReferenceConfig -Reference (New-ReferenceDoc) -Local $null -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected '192.168.7.229' -Actual $m.Config['vmStart']['cachingProxyIP'] -Because 'the caching proxy is shared LAN infrastructure'
        Assert-Equal -Expected '\\ypool-nas\work\yuruna.pool' -Actual $m.Config['networkStorage']['poolNetworkPath']
    }
    It 'never adopts the reference secrets node and preserves the local one' {
        $ref = New-ReferenceDoc
        $ref['secrets'] = @{ resend = @{ apiKey = 'REMOTE' } }
        $local = @{ secrets = @{ resend = @{ apiKey = 'LOCAL' } } }
        $m = Merge-ConfigSyncReferenceConfig -Reference $ref -Local $local -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'LOCAL' -Actual $m.Config['secrets']['resend']['apiKey']
        Assert-True (@($m.Warnings) -match 'secrets') 'dropping the reference secrets is warned about'
    }
    It 'keeps the local projectUrl when the reference value is a non-portable local path' {
        $ref = New-ReferenceDoc
        $ref['repositories']['projectUrl'] = 'file:///home/ref/project'
        $local = @{ repositories = @{ projectUrl = 'https://example/local-project' } }
        $m = Merge-ConfigSyncReferenceConfig -Reference $ref -Local $local -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'https://example/local-project' -Actual $m.Config['repositories']['projectUrl']
        Assert-True (@($m.Warnings) -match 'projectUrl') 'the non-portable projectUrl is warned about'
    }
    It 'blanks a populated reference localClonePath (host-specific absolute path)' {
        $ref = New-ReferenceDoc
        $ref['pool']['localClonePath'] = 'C:\clones\pool-intent'
        $m = Merge-ConfigSyncReferenceConfig -Reference $ref -Local $null -HostType 'host.macos.utm'
        Assert-Equal -Expected '' -Actual $m.Config['pool']['localClonePath']
        Assert-True (@($m.Warnings) -match 'localClonePath') 'the non-portable clone path is warned about'
    }
}

Describe 'Shared-token credential envelope' {
    It 'round-trips a password through Protect/Unprotect with the same token' {
        $env = Protect-ConfigSyncCredential -Token 'tok-1' -User 'yuruna-pool' -ClientNonce 'nonce-1' -Password 'p@ss w0rd+yes'
        $pw = Unprotect-ConfigSyncCredential -Token 'tok-1' -User 'yuruna-pool' -ClientNonce 'nonce-1' -Envelope ([pscustomobject]$env)
        Assert-Equal -Expected 'p@ss w0rd+yes' -Actual $pw
    }
    It 'fails to decrypt with a different token, user, or nonce' {
        $env = [pscustomobject](Protect-ConfigSyncCredential -Token 'tok-1' -User 'u' -ClientNonce 'n' -Password 'secret')
        foreach ($case in @(
            @{ Token = 'tok-2'; User = 'u';  Nonce = 'n'  },
            @{ Token = 'tok-1'; User = 'u2'; Nonce = 'n'  },
            @{ Token = 'tok-1'; User = 'u';  Nonce = 'n2' }
        )) {
            $threw = $false
            try { $null = Unprotect-ConfigSyncCredential -Token $case.Token -User $case.User -ClientNonce $case.Nonce -Envelope $env } catch { $threw = $true }
            Assert-True $threw "decrypt must fail for token=$($case.Token) user=$($case.User) nonce=$($case.Nonce)"
        }
    }
    It 'fails to decrypt a tampered ciphertext' {
        $env = Protect-ConfigSyncCredential -Token 'tok-1' -User 'u' -ClientNonce 'n' -Password 'secret'
        $bytes = [Convert]::FromBase64String($env['ciphertext'])
        $bytes[0] = $bytes[0] -bxor 0xFF
        $env['ciphertext'] = [Convert]::ToBase64String($bytes)
        $threw = $false
        try { $null = Unprotect-ConfigSyncCredential -Token 'tok-1' -User 'u' -ClientNonce 'n' -Envelope ([pscustomobject]$env) } catch { $threw = $true }
        Assert-True $threw 'GCM tag must reject a flipped ciphertext bit'
    }
    It 'verifies and rejects proofs' {
        $proof = Get-ConfigSyncProof -Token 'tok-1' -User 'yuruna-pool' -Nonce 'abc'
        Assert-True  (Test-ConfigSyncProof -Token 'tok-1' -User 'yuruna-pool' -Nonce 'abc' -Proof $proof)
        Assert-True  (-not (Test-ConfigSyncProof -Token 'tok-2' -User 'yuruna-pool' -Nonce 'abc' -Proof $proof)) 'wrong token'
        Assert-True  (-not (Test-ConfigSyncProof -Token 'tok-1' -User 'other'      -Nonce 'abc' -Proof $proof)) 'wrong user'
        Assert-True  (-not (Test-ConfigSyncProof -Token 'tok-1' -User 'yuruna-pool' -Nonce 'xyz' -Proof $proof)) 'wrong nonce'
        Assert-True  (-not (Test-ConfigSyncProof -Token 'tok-1' -User 'yuruna-pool' -Nonce 'abc' -Proof 'not-base64!')) 'malformed proof'
    }
}

Describe 'Windows drive-letter YAML round-trip' {
    It 'serializes a drive-letter localPath so it parses back intact' {
        # An unquoted `poolLocalPath: y:` is invalid YAML and would break the
        # whole config parse; the serializer must quote it.
        $doc  = [ordered]@{ networkStorage = [ordered]@{ poolLocalPath = 'y:' } }
        $back = ($doc | ConvertTo-Yaml) | ConvertFrom-Yaml -Ordered
        Assert-Equal -Expected 'y:' -Actual $back['networkStorage']['poolLocalPath']
    }
}

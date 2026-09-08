<#PSScriptInfo
.VERSION 2026.09.08
.GUID 424a2e17-dfe4-4ca3-ae90-6837265945f9
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
    Pester coverage for Test.ConfigServiceSync.psm1: the cross-host-type
    networkStorage conversion, the reference-config merge rules (secrets,
    non-portable values), and the shared-token credential envelope.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Run: Invoke-Pester -Path test/modules/Test.ConfigServiceSync.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $here)
Import-Module (Join-Path $here 'Test.Prelude.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.ConfigServiceSync.psm1') -Force -DisableNameChecking
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning "powershell-yaml unavailable; YAML round-trip tests will fail." }

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Fixtures live at FILE scope, not inside a Describe. Pester runs a Describe body
# during discovery and throws its variables and functions away before any It runs,
# so a fixture declared in there reaches the assertions as $null (or, for a
# function, as "command not found") -- and the test then quietly exercises the
# empty path instead of the one it names.
$script:unixRef = [ordered]@{
    poolStorageLocalPath   = '/mnt/ypool-nas'
    poolStorageNetworkPath = '//ypool-nas/work/yuruna.pool'
    poolStorageNetworkUser = 'yuruna-pool'
    stashStorageLocalPath   = '~/Shares/ystash-nas'
    stashStorageNetworkPath = '//ystash-nas/work/yuruna.stash'
    stashStorageNetworkUser = 'yuruna-stash'
}

function New-ReferenceDoc {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: pure fixture constructor, no system state touched.')]
    [CmdletBinding()] [OutputType([hashtable])] param()
    return @{
        networkStorage = @{
            poolStorageLocalPath = '/mnt/ypool-nas'; poolStorageNetworkPath = '//ypool-nas/work/yuruna.pool'; poolStorageNetworkUser = 'yuruna-pool'
            stashStorageLocalPath = ''; stashStorageNetworkPath = ''; stashStorageNetworkUser = ''
        }
        repositories = @{ frameworkUrl = 'https://example/framework'; projectUrl = 'https://example/project' }
        pool         = @{ enabled = $false; localClonePath = ''; networkReplicate = $true }
        vmStart      = @{ cachingProxyIp = '192.168.7.229' }
    }
}

}

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
    It 'converts a unix-style reference for a Windows host: UNC slashes + drive-letter defaults' {
        $r = Convert-ConfigSyncNetworkStorage -Reference $script:unixRef -Local $null -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected '\\ypool-nas\work\yuruna.pool'   -Actual $r.NetworkStorage['poolStorageNetworkPath']
        Assert-Equal -Expected '\\ystash-nas\work\yuruna.stash' -Actual $r.NetworkStorage['stashStorageNetworkPath']
        Assert-Equal -Expected 'y:' -Actual $r.NetworkStorage['poolStorageLocalPath']
        Assert-Equal -Expected 'z:' -Actual $r.NetworkStorage['stashStorageLocalPath']
        Assert-Equal -Expected 'yuruna-pool' -Actual $r.NetworkStorage['poolStorageNetworkUser']
        Assert-Equal -Expected 0 -Actual @($r.Warnings).Count -Because 'a clean conversion warns about nothing'
    }
    It 'converts a Windows-style reference for a Linux host' {
        $winRef = [ordered]@{
            poolStorageLocalPath = 'y:'; poolStorageNetworkPath = '\\ypool-nas\work\yuruna.pool'; poolStorageNetworkUser = 'yuruna-pool'
            stashStorageLocalPath = ''; stashStorageNetworkPath = ''; stashStorageNetworkUser = ''
        }
        $r = Convert-ConfigSyncNetworkStorage -Reference $winRef -Local $null -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected '//ypool-nas/work/yuruna.pool' -Actual $r.NetworkStorage['poolStorageNetworkPath']
        Assert-Equal -Expected '/mnt/ypool-nas' -Actual $r.NetworkStorage['poolStorageLocalPath']
        Assert-Equal -Expected '' -Actual $r.NetworkStorage['stashStorageNetworkPath'] -Because 'an unconfigured reference tier stays unconfigured'
    }
    It 'keeps a populated local mount path instead of the derived default' {
        $local = [ordered]@{ poolStorageLocalPath = 'x:'; poolStorageNetworkPath = '\\old\share'; poolStorageNetworkUser = 'old' }
        $r = Convert-ConfigSyncNetworkStorage -Reference $script:unixRef -Local $local -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected 'x:' -Actual $r.NetworkStorage['poolStorageLocalPath'] -Because 'a working local mount point survives the sync'
        Assert-Equal -Expected 'z:' -Actual $r.NetworkStorage['stashStorageLocalPath'] -Because 'a tier with no local value still gets the default'
    }
    It 'clears a locally-populated tier the reference does not configure, with a warning' {
        $ref   = [ordered]@{ poolStorageNetworkPath = '//ypool-nas/work/yuruna.pool'; poolStorageNetworkUser = 'yuruna-pool'; poolStorageLocalPath = '/mnt/ypool-nas' }
        $local = [ordered]@{ stashStorageLocalPath = 'z:'; stashStorageNetworkPath = '\\ystash-nas\work\yuruna.stash'; stashStorageNetworkUser = 'yuruna-stash' }
        $r = Convert-ConfigSyncNetworkStorage -Reference $ref -Local $local -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected '' -Actual $r.NetworkStorage['stashStorageNetworkPath']
        Assert-True (@($r.Warnings) -match 'stash') 'clearing a populated tier is warned about'
    }
}

Describe 'Merge-ConfigSyncReferenceConfig' {
    It 'copies host-agnostic values verbatim and converts networkStorage' {
        $m = Merge-ConfigSyncReferenceConfig -Reference (New-ReferenceDoc) -Local $null -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected '192.168.7.229' -Actual $m.Config['vmStart']['cachingProxyIp'] -Because 'the caching-proxy service is shared LAN infrastructure'
        Assert-Equal -Expected '\\ypool-nas\work\yuruna.pool' -Actual $m.Config['networkStorage']['poolStorageNetworkPath']
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

    It '-NoPool drops the pool + networkStorage nodes but keeps the cache + repos' {
        $m = Merge-ConfigSyncReferenceConfig -Reference (New-ReferenceDoc) -Local $null -HostType 'host.windows.hyper-v' -NoPool
        Assert-True (-not $m.Config.Contains('pool'))           'pool node is dropped (-NoPool = no pool membership / registration)'
        Assert-True (-not $m.Config.Contains('networkStorage')) 'networkStorage node is dropped (-NoPool = no NAS mount / replication)'
        Assert-Equal -Expected '192.168.7.229' -Actual $m.Config['vmStart']['cachingProxyIp'] -Because 'cache reuse survives -NoPool'
        Assert-Equal -Expected 'https://example/framework' -Actual $m.Config['repositories']['frameworkUrl'] -Because 'repository settings survive -NoPool'
        Assert-True (@($m.Warnings) -match 'NoPool') 'dropping the pool nodes is warned about'
    }

    # The sync is a FULL copy with a short list of named exceptions, not an
    # allowlist of keys to carry over. That distinction is the whole contract: an
    # allowlist silently drops every setting added to the config after it was
    # written, and the pool host then runs on a default while the operator reads
    # the reference host's value and believes it is in effect. The exceptions are
    # enumerated here so that adding one without saying so breaks this test.
    It 'copies EVERY key from the reference, including ones it has never heard of' {
        $ref = New-ReferenceDoc
        $ref['repositories']['ghToken'] = 'github_pat_FROM_REFERENCE'
        $ref['someFutureSection']        = @{ someFutureKey = 'future-value' }
        $ref['logLevel']                 = 'Debug'

        $m = Merge-ConfigSyncReferenceConfig -Reference $ref -Local $null -HostType 'host.windows.hyper-v'

        Assert-Equal -Expected 'github_pat_FROM_REFERENCE' -Actual $m.Config['repositories']['ghToken'] `
            -Because 'a private-repo token set on the reference must reach the pool host, or its guests cannot clone'
        Assert-Equal -Expected 'future-value' -Actual $m.Config['someFutureSection']['someFutureKey'] `
            -Because 'a section this merge has never heard of still has to survive it'
        Assert-Equal -Expected 'Debug' -Actual $m.Config['logLevel']
        Assert-Equal -Expected 'https://example/framework' -Actual $m.Config['repositories']['frameworkUrl']
    }

    # The exceptions, stated as a closed set. Every key of the reference must come
    # through untouched EXCEPT these -- each deliberately host-local, each warned about.
    It 'alters only the documented exceptions: networkStorage, secrets, non-portable projectUrl / localClonePath' {
        $ref = New-ReferenceDoc
        $ref['repositories']['ghToken'] = 'tok'
        $ref['testCycle'] = @{ cycleDelaySeconds = 300; stopOnFailure = $true }
        $ref['vmImage']   = @{ refreshSeconds = 168 }

        $m = Merge-ConfigSyncReferenceConfig -Reference $ref -Local $null -HostType 'host.ubuntu.kvm'

        # Portable values are byte-for-byte what the reference had.
        Assert-Equal -Expected 300  -Actual $m.Config['testCycle']['cycleDelaySeconds']
        Assert-Equal -Expected $true -Actual $m.Config['testCycle']['stopOnFailure']
        Assert-Equal -Expected 168  -Actual $m.Config['vmImage']['refreshSeconds']
        Assert-Equal -Expected 'tok' -Actual $m.Config['repositories']['ghToken']

        # No key the reference had went missing.
        foreach ($k in $ref.Keys) {
            Assert-True $m.Config.Contains($k) "reference key '$k' must survive the merge"
        }
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
        # An unquoted `poolStorageLocalPath: y:` is invalid YAML and would break the
        # whole config parse; the serializer must quote it.
        $doc  = [ordered]@{ networkStorage = [ordered]@{ poolStorageLocalPath = 'y:' } }
        $back = ($doc | ConvertTo-Yaml) | ConvertFrom-Yaml -Ordered
        Assert-Equal -Expected 'y:' -Actual $back['networkStorage']['poolStorageLocalPath']
    }
}

Describe 'Yuruna control proof (status-service control-route auth)' {
    # The proof the pool-aggregator service mints (Go) and the status service verifies (PowerShell)
    # to gate the mutating /control/* routes. The golden vector is shared with the Go test
    # (test/extension/pool-aggregator-service/control_proof_test.go) so the two mints cannot drift.
    It 'mints the shared golden wire (must equal the Go controlProofFor vector)' {
        Assert-Equal -Expected '1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs=' `
            -Actual (Get-YurunaControlProof -Token 'yuruna-net1-golden-token' -ExpiryUnixSeconds 1900000000)
    }
    It 'accepts a fresh proof and rejects wrong token / tamper / malformed / no-token' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $wire = Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds ($now + 120)
        Assert-True (Test-YurunaControlProof -Token 'tok-1' -Wire $wire) 'fresh proof accepted'
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-2' -Wire $wire)) 'wrong token rejected'
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire (($now + 120).ToString() + '.AAAA'))) 'tampered proof rejected'
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire 'no-dot')) 'malformed wire rejected'
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire '')) 'empty wire rejected'
        Assert-True (-not (Test-YurunaControlProof -Token '' -Wire $wire)) 'no token configured -> reject'
    }
    It 'accepts a proof minted at the aggregator TTL, so the cap stays above the mint' {
        # The aggregator mints expiry = now + 15 min. The verifier window has no skew
        # grace, so an acceptance cap equal to the mint would reject a freshly minted
        # proof on any host whose clock trails the proxy by a second. Pin the surplus:
        # mint-length proof accepted, and a proof past the cap still rejected.
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $mintTtl = 15 * 60
        $atMint = Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds ($now + $mintTtl)
        Assert-True (Test-YurunaControlProof -Token 'tok-1' -Wire $atMint) 'proof minted at the aggregator TTL is accepted'
        $beyondCap = Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds ($now + 1800)
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire $beyondCap)) 'proof beyond the acceptance cap is still rejected'
    }
    It 'rejects an expired proof and a far-future (beyond MaxTtl) proof' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire (Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds ($now - 60)))) 'expired rejected'
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire (Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds ($now + 100000)))) 'far-future (beyond MaxTtl) rejected'
    }
}

Describe 'Yuruna control tag (dashboard Control column)' {
    # The non-secret name for an internal authentication key that /control/control-status
    # publishes and the pool-aggregator service compares with its own, to tell
    # "this host is enrolled here" from "this host is enrolled against a proxy
    # that has since been rebuilt". The golden vector is shared with the Go test
    # (test/extension/pool-aggregator-service/control_state_test.go) so the two derivations
    # cannot drift -- a drift would read as the whole pool being onsite-only.
    It 'derives the shared golden tag (must equal the Go controlTagFor vector)' {
        Assert-Equal -Expected 'cCF1hq19qKkDIatix94HUWPtVrMYO3lw5YZetYYqLF4=' `
            -Actual (Get-YurunaControlTag -Token 'yuruna-net1-golden-token')
    }
    It 'is stable per token and distinguishes different tokens' {
        Assert-Equal -Expected (Get-YurunaControlTag -Token 'tok-1') -Actual (Get-YurunaControlTag -Token 'tok-1')
        Assert-True ((Get-YurunaControlTag -Token 'tok-1') -ne (Get-YurunaControlTag -Token 'tok-2')) 'a different token yields a different tag'
    }
    It 'publishes nothing for a host holding no token' {
        Assert-Equal -Expected '' -Actual (Get-YurunaControlTag -Token '')
        Assert-Equal -Expected '' -Actual (Get-YurunaControlTag -Token '   ')
    }
    It 'is domain-separated from the control proof' {
        # The tag rides on an OPEN read route, so anything on the LAN can fetch
        # it. It must therefore be worthless for forging a proof: the proof signs
        # "yuruna-control|proof|<expiry>", the tag signs a fixed "...|tag|v1"
        # message no expiry can produce.
        $tag = Get-YurunaControlTag -Token 'tok-1'
        foreach ($exp in @(0, 1, 1900000000)) {
            $proof = Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds $exp
            Assert-True (-not $proof.Contains($tag)) "tag must not appear inside the proof for expiry $exp"
        }
    }
}

# --- REGION: internal-auth-key provisioning (Set-UserVaultKey + Set-InternalAuthKey)
# The auth extension's vault + users.yml paths are redirected into a throwaway
# temp dir so the tests never touch the real vault. The redirect brackets the
# Its from BeforeAll/AfterAll rather than file scope -- a file-scope teardown
# would fire during discovery and leave the Its writing fixtures into the
# operator's live credential store. Why discovery runs it early:
# https://yuruna.link/42d69dfa-0015
Describe 'internal-auth-key provisioning' {
    BeforeAll {
        # $PSScriptRoot, not the file-scope $here: discovery-phase variables are
        # not reliably visible from a run-phase block.
        $patAuthModule = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'extension', 'authentication', 'default.psm1'
        # Eight extension areas each ship a module named 'default', and the
        # suite shares one runspace. With more than one resident, Pester cannot
        # tell which module a -ModuleName 'default' mock or an InModuleScope
        # block means, and refuses -- so this file's module is made the only
        # one loaded. The failure is order-dependent, which is why it shows up
        # in a full run and not when this file is run by itself.
        Get-Module -Name 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $patAuthModule -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $patTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-pat-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $patTmpDir -Force | Out-Null
        $env:YURUNA_TEST_PAT_DIR = $patTmpDir
        $patReady = [bool](Get-Command Set-InternalAuthKey -ErrorAction SilentlyContinue) -and `
                    [bool](Get-Command Set-UserVaultKey -ErrorAction SilentlyContinue)
        if ($patReady) {
            InModuleScope default {
                $script:VaultDir    = $env:YURUNA_TEST_PAT_DIR
                $script:VaultPath   = Join-Path $env:YURUNA_TEST_PAT_DIR 'vault.yml'
                $script:LogPath     = Join-Path $env:YURUNA_TEST_PAT_DIR 'events.log'
                $script:UsersPath   = Join-Path $env:YURUNA_TEST_PAT_DIR 'users.yml'
                $script:UsersConfig = $null
            }
        }
    }

    AfterAll {
        # Restore the real vault paths (the -Force re-import recomputes them from
        # the module location) and drop the throwaway dir so a later suite in the
        # same runspace sees the real vault.
        Import-Module $patAuthModule -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
        if ($patTmpDir -and (Test-Path -LiteralPath $patTmpDir)) { Remove-Item -LiteralPath $patTmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item Env:\YURUNA_TEST_PAT_DIR -ErrorAction SilentlyContinue
    }

    It 'Get-InternalAuthKeyValue serves a legacy pool-auth-token entry when the newer names are absent' {
        Assert-True $patReady 'auth extension (Set-InternalAuthKey / Set-UserVaultKey) must be importable'
        $null = Set-UserVaultKey -LogicalUser 'pool-auth-token' -VaultKey 'pool-auth-token' -Confirm:$false
        $null = Set-Password -Username 'pool-auth-token' -NewPassword 'legacy-tok'
        $null = Reset-UsersConfigCache -Confirm:$false
        Assert-Equal -Expected 'legacy-tok' -Actual (Get-InternalAuthKeyValue) -Because 'a host provisioned under the legacy logical name keeps verifying'
    }
    It 'stores + verifies the token with vaultKey == username (closes the mismatch class)' {
        Assert-True $patReady 'auth extension (Set-InternalAuthKey / Set-UserVaultKey) must be importable'
        $tok = 'xp2e&Klq52-test'
        $r = Set-InternalAuthKey -Token $tok -Confirm:$false
        Assert-True  $r.ok 'Set-InternalAuthKey verifies the round-trip'
        Assert-Equal 'internal-auth-key' $r.vaultKey
        Assert-True  $r.verified
        Assert-Equal $tok (Get-Password -Username 'internal-auth-key')
        Assert-Equal 'internal-auth-key' (Get-EffectiveUser -LogicalUser 'internal-auth-key').vaultKey
        Assert-True  (Test-VaultEntry -VaultKey 'internal-auth-key') 'vault entry present under the resolved key'
        Assert-Equal -Expected $tok -Actual (Get-InternalAuthKeyValue) -Because 'the new logical name wins over the legacy entry'
    }
    It 'is idempotent on the vaultKey and rotates the token value' {
        $null = Set-InternalAuthKey -Token 'aaa' -Confirm:$false
        $r2   = Set-InternalAuthKey -Token 'bbb' -Confirm:$false
        Assert-True (-not $r2.keyChanged) 'vaultKey already set -> keyChanged is false'
        Assert-Equal -Expected 'bbb' -Actual (Get-Password -Username 'internal-auth-key') -Because 'token rotates to the new value'
    }
    It 'honors -WhatIf (stores nothing)' {
        $null = Set-InternalAuthKey -Token 'zzz-should-not-store' -WhatIf
        Assert-Equal -Expected 'bbb' -Actual (Get-Password -Username 'internal-auth-key') -Because 'WhatIf left the prior value intact'
    }
    It 'Set-UserVaultKey is idempotent (identical re-set is a no-op)' {
        $first  = Set-UserVaultKey -LogicalUser 'demo-user' -VaultKey 'demo.key' -Confirm:$false
        $second = Set-UserVaultKey -LogicalUser 'demo-user' -VaultKey 'demo.key' -Confirm:$false
        Assert-True $first         'first set writes the file'
        Assert-True (-not $second) 'identical second set makes no change'
    }
    It 'retires a superseded entry once the new one verifies, leaving ONE copy of the key' {
        Assert-True $patReady 'auth extension must be importable'
        $null = Set-UserVaultKey -LogicalUser 'lab-auth-token' -VaultKey 'lab-auth-token' -Confirm:$false
        $null = Set-Password -Username 'lab-auth-token' -NewPassword 'superseded-value'
        $null = Reset-UsersConfigCache -Confirm:$false
        Assert-True (Test-VaultEntry -VaultKey 'lab-auth-token') 'the superseded entry is planted'

        $r = Set-InternalAuthKey -Token 'migrated-key' -Confirm:$false
        Assert-True $r.ok 'the new entry verifies'
        Assert-True (-not (Test-VaultEntry -VaultKey 'lab-auth-token')) 'the superseded vault entry is gone'
        Assert-True ($r.retired -contains 'lab-auth-token') 'the run reports what it retired'
        Assert-Equal -Expected 'migrated-key' -Actual (Get-InternalAuthKeyValue) -Because 'the surviving copy is the one under the new name'
    }
    It 'Remove-VaultEntry deletes a stored entry and answers false for an absent one' {
        $null = Set-Password -Username 'throwaway.key' -NewPassword 'gone-soon'
        Assert-True (Test-VaultEntry -VaultKey 'throwaway.key') 'entry present before removal'
        Assert-True  (Remove-VaultEntry -VaultKey 'throwaway.key' -Confirm:$false) 'removal reports the change'
        Assert-True (-not (Test-VaultEntry -VaultKey 'throwaway.key')) 'entry is gone'
        Assert-True (-not (Remove-VaultEntry -VaultKey 'throwaway.key' -Confirm:$false)) 'removing nothing is not a change'
    }
    It 'Remove-UserEntry drops the logical name rather than blanking its vaultKey' {
        $null = Set-UserVaultKey -LogicalUser 'retire-me' -VaultKey 'retire.me' -Confirm:$false
        $null = Reset-UsersConfigCache -Confirm:$false
        Assert-Equal 'retire.me' (Get-EffectiveUser -LogicalUser 'retire-me').vaultKey
        Assert-True (Remove-UserEntry -LogicalUser 'retire-me' -Confirm:$false) 'removal reports the change'
        $null = Reset-UsersConfigCache -Confirm:$false
        Assert-True (-not ((Get-EffectiveUser -LogicalUser 'retire-me').vaultKey)) 'the name no longer resolves to a vault key'
        Assert-True (-not (Remove-UserEntry -LogicalUser 'retire-me' -Confirm:$false)) 'removing nothing is not a change'
    }
    It 'honors -WhatIf on both removals' {
        $null = Set-Password -Username 'keepme.key' -NewPassword 'still-here'
        $null = Remove-VaultEntry -VaultKey 'keepme.key' -WhatIf
        Assert-True (Test-VaultEntry -VaultKey 'keepme.key') 'WhatIf removed nothing from the vault'
        $null = Set-UserVaultKey -LogicalUser 'keep-user' -VaultKey 'keepme.key' -Confirm:$false
        $null = Remove-UserEntry -LogicalUser 'keep-user' -WhatIf
        $null = Reset-UsersConfigCache -Confirm:$false
        Assert-Equal 'keepme.key' (Get-EffectiveUser -LogicalUser 'keep-user').vaultKey
    }
}

# --- REGION: Status-service bounce
# The status-service bounce must be bounded by the CHILD it starts, never by the
# status service that child detaches.
#
# Start-StatusService.ps1 launches the server as a process that outlives it by
# design. Windows turns handle inheritance ON for a child whenever a std stream
# is redirected, so a bounce spawned that way (`& pwsh ... *> $null` redirects)
# hands the detached server the write end of the caller's stdout pipe. The server
# holds it for its whole lifetime, the caller's read never sees EOF, and the
# bounce blocks on the SERVER instead of the child that exited seconds ago --
# silently, because the same redirection swallowed every progress line. This
# drives the real code path against a stand-in start script that detaches a
# long-lived grandchild the same way the real one does.
Describe 'status-service bounce' {
    BeforeAll {
        $bnDir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-bounce-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bnDir -Force | Out-Null
        $bnPidFile = Join-Path $bnDir 'grandchild.pid'
        $bnScript  = Join-Path $bnDir 'Start-StatusService.ps1'
        # Single-quoted here-string + placeholder: the generated script needs no
        # escaping, so what runs is exactly what is written here.
        $bnBody = @'
param([switch]$Restart)
Write-Output 'Stopped existing status service (PID 1234).'
Write-Output 'Caching-proxy service: detected, port map OK'
$dir  = '<BNDIR>'
$sink = Join-Path $dir 'stdin.empty'
if (-not (Test-Path $sink)) { [System.IO.File]::WriteAllBytes($sink, [byte[]]@()) }
$spawn = @{
    FilePath               = 'pwsh'
    ArgumentList           = @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', 'Start-Sleep -Seconds 30')
    RedirectStandardInput  = $sink
    RedirectStandardOutput = (Join-Path $dir 'gc.out')
    RedirectStandardError  = (Join-Path $dir 'gc.err')
    PassThru               = $true
}
$p = Start-Process @spawn
Set-Content -Path '<BNPIDFILE>' -Value $p.Id
Write-Output "Status service started (PID $($p.Id))."
exit 0
'@
        Set-Content -LiteralPath $bnScript -Encoding utf8 `
            -Value (($bnBody -replace '<BNDIR>', $bnDir) -replace '<BNPIDFILE>', $bnPidFile)
    }

    AfterAll {
        if (Test-Path -LiteralPath $bnPidFile) {
            $gcPid = (Get-Content -LiteralPath $bnPidFile -Raw).Trim()
            if ($gcPid) { Stop-Process -Id $gcPid -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $bnDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns when the bounce child exits, not when the detached server does' {
        $mod = Get-Module Test.ConfigServiceSync
        Assert-True $mod 'Test.ConfigServiceSync must be imported'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # Invoke-StatusServiceBounce is module-private; call it in module scope.
        $r = & $mod { param($e, $s) Invoke-StatusServiceBounce -PwshExe $e -StartScript $s -TimeoutSeconds 60 } `
                ([System.Environment]::ProcessPath) $bnScript
        $sw.Stop()
        Assert-True $r.ok "bounce reports success (exitCode=$($r.exitCode))"
        Assert-True (-not $r.timedOut) 'bounce did not hit its timeout'
        # The stand-in's grandchild lives 30 s while the child itself exits at
        # once, so a caller pinned to the grandchild's handles sits here for 30 s.
        Assert-True ($sw.Elapsed.TotalSeconds -lt 15) `
            "bounce returned in $([int]$sw.Elapsed.TotalSeconds)s -- it is not waiting on the detached server"
        Assert-True (Test-Path -LiteralPath $r.logPath) 'the child transcript is left for the operator'
        Assert-True ((Get-Content -LiteralPath $r.logPath -Raw) -match 'Caching-proxy service') `
            'the transcript carries the child progress lines the operator needs'
    }
}

# --- REGION: Reference-host response classifiers
# Pure; the HTTP is a thin wrapper around them. Every value these decide about
# is one the operator would otherwise type by hand, so the tests pin the two
# behaviors that keep the sync from prompting for input it could have obtained:
# a serving reference is recognized as serving, and a reference that cannot
# answer says WHY rather than returning a silent $null.
Describe 'Get-ConfigSyncCredentialReadiness (credential capability verdict)' {
    # A wrong-proof probe that comes back 403 is the GO signal: the reference
    # holds a token and has a credential path for this user, so the only missing
    # piece is the right token -- exactly what makes it safe to then ask for one.
    It 'reads a 403 (proof mismatch) as "a correct token would work"' {
        $r = Get-ConfigSyncCredentialReadiness -StatusCode 403 -ReferenceHost 'ref' -User 'yuruna-pool'
        Assert-True $r.Ready 'a 403 proof-mismatch means the endpoint would serve with the right token'
        Assert-Equal 403 $r.Status
    }

    # 503 == the reference has no token of its OWN, so no operator-supplied token
    # can ever unlock it. The verdict must be not-ready AND name the fix.
    It 'reads a 503 as not-ready and names the provisioning fix' {
        $r = Get-ConfigSyncCredentialReadiness -StatusCode 503 -ServerError 'internal authentication key not configured on this host' -ReferenceHost 'refbox' -User 'yuruna-pool'
        Assert-True (-not $r.Ready) 'a reference with no token of its own can never serve a credential'
        Assert-Equal 503 $r.Status
        Assert-True ($r.Error -match 'Set-LabToken') 'the not-ready message points at the enrollment command'
        Assert-True ($r.Error -match 'refbox') 'the message names the reference host'
    }

    It 'reads a transport failure (status 0) as not-ready and not-answering' {
        $r = Get-ConfigSyncCredentialReadiness -StatusCode 0 -ServerError 'No such host is known.' -ReferenceHost 'gone' -User 'yuruna-pool'
        Assert-True (-not $r.Ready) 'an unreachable host is not ready'
        Assert-Equal -Expected 0 -Actual $r.Status -Because 'a transport failure has no HTTP status'
        Assert-True ($r.Error -match 'not answering') 'the message says the host is not answering'
    }

    It 'reads a 404 as not-ready for the specific user' {
        $r = Get-ConfigSyncCredentialReadiness -StatusCode 404 -ServerError "user not referenced by this host's networkStorage config" -ReferenceHost 'ref' -User 'ghost'
        Assert-True (-not $r.Ready) 'a 404 means the reference will not serve this user'
        Assert-True ($r.Error -match 'ghost') 'the message names the user'
    }
}

# --- REGION: Lab-token exchange verdict
# Pure; Request-LabTokenExchange is a thin HTTP wrapper around it. Every status
# the aggregator's /api/v1/lab-token can answer maps to one operator-actionable
# sentence, so a failed enrollment never dead-ends in a bare status code.
Describe 'Get-LabTokenExchangeVerdict (lab-token exchange verdict)' {
    It 'accepts a 200 that carries the shared token' {
        $r = Get-LabTokenExchangeVerdict -StatusCode 200 -Token 'the-shared-token' -AggregatorUrl 'https://proxy:9400/api/v1/lab-token'
        Assert-True  $r.Ok 'a 200 with a token is the success case'
        Assert-Equal 'the-shared-token' $r.Token
    }
    # An envelope that does not authenticate reaches the verdict as an empty
    # token: a 200 alone must never enroll the host, or an on-path responder
    # could plant a token by answering the exchange.
    It 'refuses a 200 whose envelope did not unseal' {
        $r = Get-LabTokenExchangeVerdict -StatusCode 200 -AggregatorUrl 'https://proxy:9400/api/v1/lab-token'
        Assert-True (-not $r.Ok) 'an unopened 200 must not enroll the host'
        Assert-True ($r.Error -match 'did not unseal') 'the message says the reply did not authenticate'
    }
    It 'reads a 403 as an expired/wrong code and points at the dashboard' {
        $r = Get-LabTokenExchangeVerdict -StatusCode 403 -AggregatorUrl 'https://proxy:9400/api/v1/lab-token'
        Assert-True (-not $r.Ok) 'a refused code does not enroll'
        Assert-True ($r.Error -match 'rotates') 'the message explains the rotation'
        Assert-True ($r.Error -match 'dashboard') 'the message points at the dashboard'
    }
    It 'reads a 429 as the per-address throttle' {
        $r = Get-LabTokenExchangeVerdict -StatusCode 429 -AggregatorUrl 'https://proxy:9400/api/v1/lab-token'
        Assert-True (-not $r.Ok) 'a throttled attempt does not enroll'
        Assert-True ($r.Error -match 'Wait') 'the message says to wait'
    }
    It 'reads a 503 as exchange-disabled and names the rebuild path' {
        $r = Get-LabTokenExchangeVerdict -StatusCode 503 -AggregatorUrl 'https://proxy:9400/api/v1/lab-token'
        Assert-True (-not $r.Ok) 'a disabled exchange does not enroll'
        Assert-True ($r.Error -match 'disabled') 'the message says the exchange is off'
        Assert-True ($r.Error -match 'Rebuild') 'the message names the proxy rebuild fix'
    }
    It 'reads a transport failure (status 0) as not-answering' {
        $r = Get-LabTokenExchangeVerdict -StatusCode 0 -ServerError 'No such host is known.' -AggregatorUrl 'https://gone:9400/api/v1/lab-token'
        Assert-True (-not $r.Ok) 'an unreachable aggregator does not enroll'
        Assert-True ($r.Error -match 'not answering') 'the message says the aggregator is not answering'
    }
}

# --- REGION: Lab-token envelope
# The seal is what authenticates the exchange's ANSWER to a host that cannot
# verify the aggregator's TLS leaf, so the vector below is produced by the Go
# side (pool-aggregator-service sealLabToken) and MUST open here: if it stops
# opening, the two implementations have drifted on the KDF, the iteration count,
# the AEAD label, or the envelope framing, and enrollment would fail closed
# against a correctly-behaving aggregator.
# --- REGION: Which of the two secrets is in hand
# The dashboard's Lab token and the internal authentication key have disjoint
# shapes, which is what lets a prompt accept either one without guessing.
Describe 'Test-LabTokenShape (which of the two secrets is in hand)' {
    It 'recognizes the 6-character dashboard code, in any case, with padding' {
        Assert-True (Test-LabTokenShape -Value 'abc123')   'lowercase alphanumeric code'
        Assert-True (Test-LabTokenShape -Value 'ABC123')   'the tile is read by eye; case is the operator shift key'
        Assert-True (Test-LabTokenShape -Value '  abc123 ') 'a pasted code carries whitespace'
        Assert-True (Test-LabTokenShape -Value '234567')   'digits only is still a code'
    }
    It 'does not mistake an internal authentication key for a code' {
        $key = ([Convert]::ToHexString([byte[]]::new(24))).ToLowerInvariant()
        Assert-Equal 48 $key.Length
        Assert-True (-not (Test-LabTokenShape -Value $key)) 'a 48-hex key is not a 6-character code'
    }
    It 'answers false for empty, whitespace, and wrong-length input instead of throwing' {
        foreach ($v in @('', '   ', 'abc12', 'abc1234', 'abc-12')) {
            Assert-True (-not (Test-LabTokenShape -Value $v)) "'$v' is not a Lab token"
        }
    }
}

Describe 'Resolve-ConfigSyncInternalAuthKey (what the operator typed at the prompt)' {
    It 'passes a key straight through, trimmed, without reaching the network' {
        $key = ([Convert]::ToHexString([byte[]]::new(24))).ToLowerInvariant()
        $r = Resolve-ConfigSyncInternalAuthKey -RepoRoot $script:repoRoot -Value "  $key  "
        Assert-Equal $key $r.Key
        Assert-True (-not $r.Redeemed) 'nothing to redeem'
        Assert-True (-not $r.Enrolled) 'nothing to enroll'
        Assert-True (-not $r.Error)    'a key is not an error'
    }
    It 'treats an empty entry as a skip, not a failure' {
        $r = Resolve-ConfigSyncInternalAuthKey -RepoRoot $script:repoRoot -Value '   '
        Assert-Equal '' $r.Key
        Assert-True (-not $r.Error) 'pressing Enter is a skip'
    }
}

Describe 'Unprotect-LabTokenEnvelope (cross-language lab-token envelope)' {
    # Golden envelope produced by the Go seal (pool-aggregator-service sealLabToken) for
    # code 'k3v9qa' over token 'shared-lab-auth-token-value'.
    It 'opens an envelope sealed by the Go aggregator' {
        $sealed = @{ v = 1; salt = 'yT24bD+x3HZVDkOALTexCg=='; nonce = '/iAQHzfHH/htU/rS'
                     ciphertext = 'vOQlHLZBdDmIlVDekcIwFZZ8WOC8QueH5g4k'; tag = 'FQ8hfyZ2CEB1/37eFFLmqQ==' }
        Assert-Equal -Expected 'shared-lab-auth-token-value' `
            -Actual (Unprotect-LabTokenEnvelope -LabToken 'k3v9qa' -Envelope $sealed) `
            -Because 'the PowerShell open and the Go seal must agree byte-for-byte'
    }
    It 'returns empty for a different lab token (an on-path responder cannot plant one)' {
        $sealed = @{ v = 1; salt = 'yT24bD+x3HZVDkOALTexCg=='; nonce = '/iAQHzfHH/htU/rS'
                     ciphertext = 'vOQlHLZBdDmIlVDekcIwFZZ8WOC8QueH5g4k'; tag = 'FQ8hfyZ2CEB1/37eFFLmqQ==' }
        Assert-Equal -Expected '' -Actual (Unprotect-LabTokenEnvelope -LabToken 'zzz999' -Envelope $sealed)
    }
    It 'returns empty when the ciphertext is tampered with' {
        $bytes = [Convert]::FromBase64String('vOQlHLZBdDmIlVDekcIwFZZ8WOC8QueH5g4k')
        $bytes[0] = $bytes[0] -bxor 1
        $tampered = @{ v = 1; salt = 'yT24bD+x3HZVDkOALTexCg=='; nonce = '/iAQHzfHH/htU/rS'
                       ciphertext = [Convert]::ToBase64String($bytes); tag = 'FQ8hfyZ2CEB1/37eFFLmqQ==' }
        Assert-Equal -Expected '' -Actual (Unprotect-LabTokenEnvelope -LabToken 'k3v9qa' -Envelope $tampered)
    }
    It 'returns empty for a malformed envelope instead of throwing' {
        Assert-Equal -Expected '' -Actual (Unprotect-LabTokenEnvelope -LabToken 'k3v9qa' -Envelope @{ v = 1 })
        Assert-Equal -Expected '' -Actual (Unprotect-LabTokenEnvelope -LabToken 'k3v9qa' -Envelope @{
            v = 1; salt = 'not-base64!!'; nonce = '/iAQHzfHH/htU/rS'
            ciphertext = 'vOQlHLZBdDmIlVDekcIwFZZ8WOC8QueH5g4k'; tag = 'FQ8hfyZ2CEB1/37eFFLmqQ==' })
    }
}

Describe 'Resolve-ConfigSyncAliasResponse (alias response verdict)' {
    It 'returns the name->IP map on a healthy 200 ok:true response' {
        $doc = @{ ok = $true; aliases = @{ 'ypool-nas' = '192.168.7.25' }; unresolved = @() }
        $r = Resolve-ConfigSyncAliasResponse -StatusCode 200 -Doc $doc -ReferenceHost 'ref'
        Assert-True ($r.Map -is [System.Collections.IDictionary]) 'a 200 yields the alias map'
        Assert-Equal '192.168.7.25' "$($r.Map['ypool-nas'])"
        Assert-True ($null -eq $r.Warning) 'a healthy response carries no warning'
    }

    # The regression this guards: the route 500s ('not loaded in the server
    # runspace') and the client used to swallow it with Write-Verbose and drop
    # straight to a hand-entry prompt. It must now yield a null Map AND a warning
    # carrying the server's own reason so the operator can fix the reference.
    It 'yields a warning with the server reason (not a silent $null) on a 500' {
        $doc = @{ ok = $false; error = 'Test.PoolStorage / Test.Config could not be loaded in the server runspace (see runtime/server.err)' }
        $r = Resolve-ConfigSyncAliasResponse -StatusCode 500 -Doc $doc -ReferenceHost 'ref'
        Assert-True ($null -eq $r.Map) 'the map is null so the caller still degrades to a prompt'
        Assert-True ($r.Warning -match 'could not supply') 'a failure is surfaced with an explanation, not swallowed'
        Assert-True ($r.Warning -match 'runspace') 'the warning carries the server''s own reason'
    }

    It 'warns with an HTTP-code reason when the body has no error text' {
        $r = Resolve-ConfigSyncAliasResponse -StatusCode 503 -Doc $null -ReferenceHost 'ref'
        Assert-True ($null -eq $r.Map) 'no map on a non-200'
        Assert-True ($r.Warning -match 'HTTP 503') 'falls back to the status code when there is no server error text'
    }
}

Describe 'the AES-GCM capability gate' {
    It 'passes a runtime that reports the algorithm, and one too old to be asked' {
        # $null means the runtime does not expose IsSupported. That is not
        # evidence the algorithm is absent, and failing a working host on an
        # unanswerable question is worse than missing a broken one.
        foreach ($probe in @($true, $null)) {
            $verdict = Get-ConfigSyncEnvelopeSupport -IsSupported $probe
            Assert-True $verdict.Supported "probe '$probe' must be treated as supported"
            Assert-Equal '' $verdict.Reason
        }
    }

    It 'refuses a runtime without the algorithm, and says what actually breaks' {
        # The message is the whole point of this gate. The failure it replaces
        # read as a wrong Lab token, which sent an operator back to the
        # dashboard for a fresh code that could not work either.
        $verdict = Get-ConfigSyncEnvelopeSupport -IsSupported $false
        Assert-False $verdict.Supported
        Assert-Match 'AES-GCM' $verdict.Reason 'the reason names the algorithm'
        Assert-Match 'upgraded' $verdict.Reason 'the reason names the fix'
        Assert-Match 'Lab token enrollment and every config-sync' $verdict.Reason `
            'the reason names BOTH surfaces this breaks, not just the one the operator hit'
        Assert-Match 'Nothing about the code, the proxy or the vault' $verdict.Reason `
            'the reason rules out the things the old message wrongly blamed'
    }

    It 'reports what this host actually has, without throwing' {
        # The live probe. Whatever it says, it must answer rather than fail:
        # a capability check that throws is one nobody can run.
        $live = Test-ConfigSyncEnvelopeSupport
        Assert-True ($live.Supported -is [bool]) 'the probe answers with a verdict'
        if (-not $live.Supported) {
            Assert-True ($live.Reason.Length -gt 0) 'an unsupported runtime must say so'
        }
    }
}

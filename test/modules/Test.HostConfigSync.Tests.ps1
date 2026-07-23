<#PSScriptInfo
.VERSION 2026.07.22
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

# Fixtures live at FILE scope, not inside a Describe. Pester runs a Describe body
# during discovery and throws its variables and functions away before any It runs,
# so a fixture declared in there reaches the assertions as $null (or, for a
# function, as "command not found") -- and the test then quietly exercises the
# empty path instead of the one it names.
$unixRef = [ordered]@{
    poolLocalPath   = '/mnt/ypool-nas'
    poolNetworkPath = '//ypool-nas/work/yuruna.pool'
    poolNetworkUser = 'yuruna-pool'
    stashLocalPath   = '~/Shares/ystash-nas'
    stashNetworkPath = '//ystash-nas/work/yuruna.stash'
    stashNetworkUser = 'yuruna-stash'
}

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

    # The sync is a FULL copy with a short list of named exceptions, not an
    # allowlist of keys to carry over. That distinction is the whole contract: an
    # allowlist silently drops every setting added to the config after it was
    # written, and the pool host then runs on a default while the operator reads
    # the reference host's value and believes it is in effect. The exceptions are
    # enumerated here so that adding one without saying so breaks this test.
    It 'copies EVERY key from the reference, including ones it has never heard of' {
        $ref = New-ReferenceDoc
        $ref['repositories']['GH_TOKEN'] = 'github_pat_FROM_REFERENCE'
        $ref['someFutureSection']        = @{ someFutureKey = 'future-value' }
        $ref['logLevel']                 = 'Debug'

        $m = Merge-ConfigSyncReferenceConfig -Reference $ref -Local $null -HostType 'host.windows.hyper-v'

        Assert-Equal -Expected 'github_pat_FROM_REFERENCE' -Actual $m.Config['repositories']['GH_TOKEN'] `
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
        $ref['repositories']['GH_TOKEN'] = 'tok'
        $ref['testCycle'] = @{ cycleDelaySeconds = 300; shouldStopOnFailure = $true }
        $ref['vmImage']   = @{ refreshHours = 168 }

        $m = Merge-ConfigSyncReferenceConfig -Reference $ref -Local $null -HostType 'host.ubuntu.kvm'

        # Portable values are byte-for-byte what the reference had.
        Assert-Equal -Expected 300  -Actual $m.Config['testCycle']['cycleDelaySeconds']
        Assert-Equal -Expected $true -Actual $m.Config['testCycle']['shouldStopOnFailure']
        Assert-Equal -Expected 168  -Actual $m.Config['vmImage']['refreshHours']
        Assert-Equal -Expected 'tok' -Actual $m.Config['repositories']['GH_TOKEN']

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
        # An unquoted `poolLocalPath: y:` is invalid YAML and would break the
        # whole config parse; the serializer must quote it.
        $doc  = [ordered]@{ networkStorage = [ordered]@{ poolLocalPath = 'y:' } }
        $back = ($doc | ConvertTo-Yaml) | ConvertFrom-Yaml -Ordered
        Assert-Equal -Expected 'y:' -Actual $back['networkStorage']['poolLocalPath']
    }
}

Describe 'Yuruna control proof (status-server control-route auth)' {
    # The proof the pool aggregator mints (Go) and the status server verifies (PowerShell)
    # to gate the mutating /control/* routes. The golden vector is shared with the Go test
    # (pool-aggregator/control_proof_test.go) so the two mints cannot drift.
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
    It 'rejects an expired proof and a far-future (beyond MaxTtl) proof' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire (Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds ($now - 60)))) 'expired rejected'
        Assert-True (-not (Test-YurunaControlProof -Token 'tok-1' -Wire (Get-YurunaControlProof -Token 'tok-1' -ExpiryUnixSeconds ($now + 100000)))) 'far-future (beyond MaxTtl) rejected'
    }
}

# ---------------------------------------------------------------------------
# pool-auth-token provisioning (Set-UserVaultKey + Set-PoolAuthToken). The auth
# extension's vault + users.yml paths are redirected into a throwaway temp dir
# so the tests never touch the real vault.
#
# Setup and teardown MUST live in BeforeAll/AfterAll, not at file scope. Pester
# executes the whole file top-level during DISCOVERY, before any It runs -- so a
# file-scope teardown tears the redirect down (the -Force re-import re-runs the
# module prologue and recomputes the paths from the module location) while the
# tests are still pending. The Its then run against the REAL vault and write
# their fixtures into the operator's live credential store. BeforeAll/AfterAll
# are run-phase, so the redirect brackets the Its the way it reads.
# ---------------------------------------------------------------------------
Describe 'pool-auth-token provisioning' {
    BeforeAll {
        # $PSScriptRoot, not the file-scope $here: discovery-phase variables are
        # not reliably visible from a run-phase block.
        $patAuthModule = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'extension', 'authentication', 'default.psm1'
        Import-Module $patAuthModule -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $patTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-pat-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $patTmpDir -Force | Out-Null
        $env:YURUNA_TEST_PAT_DIR = $patTmpDir
        $patReady = [bool](Get-Command Set-PoolAuthToken -ErrorAction SilentlyContinue) -and `
                    [bool](Get-Command Set-UserVaultKey  -ErrorAction SilentlyContinue)
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

    It 'stores + verifies the token with vaultKey == username (closes the mismatch class)' {
        Assert-True $patReady 'auth extension (Set-PoolAuthToken / Set-UserVaultKey) must be importable'
        $tok = 'xp2e&Klq52-test'
        $r = Set-PoolAuthToken -Token $tok -Confirm:$false
        Assert-True  $r.ok 'Set-PoolAuthToken verifies the round-trip'
        Assert-Equal 'pool-auth-token' $r.vaultKey
        Assert-True  $r.verified
        Assert-Equal $tok (Get-Password -Username 'pool-auth-token')
        Assert-Equal 'pool-auth-token' (Get-EffectiveUser -LogicalUser 'pool-auth-token').vaultKey
        Assert-True  (Test-VaultEntry -VaultKey 'pool-auth-token') 'vault entry present under the resolved key'
    }
    It 'is idempotent on the vaultKey and rotates the token value' {
        $null = Set-PoolAuthToken -Token 'aaa' -Confirm:$false
        $r2   = Set-PoolAuthToken -Token 'bbb' -Confirm:$false
        Assert-True (-not $r2.keyChanged) 'vaultKey already set -> keyChanged is false'
        Assert-Equal -Expected 'bbb' -Actual (Get-Password -Username 'pool-auth-token') -Because 'token rotates to the new value'
    }
    It 'honors -WhatIf (stores nothing)' {
        $null = Set-PoolAuthToken -Token 'zzz-should-not-store' -WhatIf
        Assert-Equal -Expected 'bbb' -Actual (Get-Password -Username 'pool-auth-token') -Because 'WhatIf left the prior value intact'
    }
    It 'Set-UserVaultKey is idempotent (identical re-set is a no-op)' {
        $first  = Set-UserVaultKey -LogicalUser 'demo-user' -VaultKey 'demo.key' -Confirm:$false
        $second = Set-UserVaultKey -LogicalUser 'demo-user' -VaultKey 'demo.key' -Confirm:$false
        Assert-True $first         'first set writes the file'
        Assert-True (-not $second) 'identical second set makes no change'
    }
}

# ---------------------------------------------------------------------------
# The status-server bounce must be bounded by the CHILD it starts, never by the
# status server that child detaches.
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
# ---------------------------------------------------------------------------
Describe 'status-server bounce' {
    BeforeAll {
        $bnDir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-bounce-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bnDir -Force | Out-Null
        $bnPidFile = Join-Path $bnDir 'grandchild.pid'
        $bnScript  = Join-Path $bnDir 'Start-StatusService.ps1'
        # Single-quoted here-string + placeholder: the generated script needs no
        # escaping, so what runs is exactly what is written here.
        $bnBody = @'
param([switch]$Restart)
Write-Output 'Stopped existing status server (PID 1234).'
Write-Output 'Caching proxy: detected, port map OK'
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
Write-Output "Status server started (PID $($p.Id))."
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
        $mod = Get-Module Test.HostConfigSync
        Assert-True $mod 'Test.HostConfigSync must be imported'
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
        Assert-True ((Get-Content -LiteralPath $r.logPath -Raw) -match 'Caching proxy') `
            'the transcript carries the child progress lines the operator needs'
    }
}

# ---------------------------------------------------------------------------
# Reference-host response classifiers (pure; the HTTP is a thin wrapper around
# these). Every value these decide about is one the operator would otherwise
# type by hand, so the tests pin the two behaviors that keep the sync from
# prompting for input it could have obtained: a serving reference is recognized
# as serving, and a reference that cannot answer says WHY rather than returning
# a silent $null.
# ---------------------------------------------------------------------------
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
        $r = Get-ConfigSyncCredentialReadiness -StatusCode 503 -ServerError 'shared pool-auth-token not configured on this host' -ReferenceHost 'refbox' -User 'yuruna-pool'
        Assert-True (-not $r.Ready) 'a reference with no token of its own can never serve a credential'
        Assert-Equal 503 $r.Status
        Assert-True ($r.Error -match 'Set-PoolAuthToken') 'the not-ready message points at the provisioning command'
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

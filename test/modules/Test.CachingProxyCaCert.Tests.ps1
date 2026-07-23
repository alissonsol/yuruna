<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42a4c5d6-e7f8-4a90-8b12-3c4d5e6f7081
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cachingproxy cacert selfheal rc60 pester
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
    Guards the durable fix for the SSL-bump empty-CA amplifier: the CA-source
    helpers in Test.CachingProxy.psm1, the guest CA self-heal in the ubuntu
    update scripts, and the /ca.crt status-server endpoint.
.DESCRIPTION
    Behavioural tests exercise Test-CachingProxyCaPem / the caCert state
    round-trip / Resolve-CachingProxyCaCertPem / Get-CachingProxyCaCertBase64
    against a temp YURUNA_RUNTIME_DIR (never the live runtime file). Structural
    guards assert the self-heal SHAPE in the bash update scripts (bump-port
    boundary, --no-proxy fetch, non-lying re-probe) and the /ca.crt HEAD-body
    guard in Start-StatusService.ps1 -- shape, so a comment cannot satisfy them.

    The throw-based Assert-* helpers live at script scope and are referenced
    from It blocks, so this runs under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $testDir
$module  = Join-Path $here 'Test.CachingProxy.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" } }

function Get-TestCaPem {
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=yuruna-test-ca",
        [System.Security.Cryptography.RSA]::Create(2048),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(3650))
    $der  = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    return "-----BEGIN CERTIFICATE-----`n" + ([Convert]::ToBase64String($der, 'InsertLineBreaks')) + "`n-----END CERTIFICATE-----`n"
}

# The structural guards read their subject file's text from these file-scope fixtures. A
# Describe/Context body is executed during test discovery and its variables are discarded
# before any It runs, so a body-local $body would reach the assertion as $null -- and a
# -match against $null passes vacuously, which is exactly the silent false-pass these
# shape guards exist to prevent. The per-script bodies are keyed by path and the key is
# handed to each It as test-case data, since the discovery-time loop variable is gone too.
$updateScripts = @(
    (Join-Path $repoRoot 'guest/ubuntu.server.24/ubuntu.server.24.update.sh'),
    (Join-Path $repoRoot 'guest/ubuntu.server.26/ubuntu.server.26.update.sh')
)
$updateScriptBody = @{}
foreach ($updateScript in $updateScripts) {
    $updateScriptBody[$updateScript] = Get-Content -Raw -LiteralPath $updateScript
}
$statusServicePath = Join-Path $repoRoot 'test/Start-StatusService.ps1'
$statusServiceBody = Get-Content -Raw -LiteralPath $statusServicePath

Describe 'Test.CachingProxy CA-source helpers' {
    BeforeEach {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("cpca_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:YURUNA_RUNTIME_DIR = $script:sandbox
        $env:YURUNA_CACHING_PROXY_IP = ''
        Import-Module $module -Force -DisableNameChecking
        Import-Module powershell-yaml -Force -ErrorAction SilentlyContinue
    }

    Context 'Test-CachingProxyCaPem' {
        It 'accepts a valid PEM certificate' {
            Assert-True (Test-CachingProxyCaPem -Pem (Get-TestCaPem)) 'valid self-signed PEM'
        }
        It 'rejects a non-certificate string' {
            Assert-False (Test-CachingProxyCaPem -Pem 'not a certificate') 'garbage'
        }
        It 'rejects an empty string' {
            Assert-False (Test-CachingProxyCaPem -Pem '') 'empty'
        }
        It 'rejects PEM markers wrapping non-base64 junk' {
            Assert-False (Test-CachingProxyCaPem -Pem "-----BEGIN CERTIFICATE-----`n!!!!`n-----END CERTIFICATE-----") 'bad body'
        }
    }

    Context 'caCert state round-trip' {
        It 'persists and reads back caCert + caCertSourceHost' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyState -CaCert $b64 -CaCertSourceHost '10.1.2.3' -Confirm:$false
            $s = Read-CachingProxyState
            Assert-Equal -Expected $b64 -Actual $s.caCert -Because 'caCert round-trips'
            Assert-Equal -Expected '10.1.2.3' -Actual $s.caCertSourceHost -Because 'sourceHost round-trips'
        }
        It 'merge-writes: saving password does not wipe caCert' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyState -CaCert $b64 -CaCertSourceHost '10.1.2.3' -Confirm:$false
            $null = Save-CachingProxyState -Secret 'pw' -Confirm:$false
            $s = Read-CachingProxyState
            Assert-Equal -Expected $b64 -Actual $s.caCert -Because 'caCert preserved across an unrelated save'
        }
    }

    Context 'Resolve-CachingProxyCaCertPem' {
        It 'returns none when no host and no persisted CA' {
            $r = Resolve-CachingProxyCaCertPem -LiveTimeoutSec 1
            Assert-Equal -Expected 'none' -Actual $r.Source -Because 'nothing to serve'
            Assert-True ([string]::IsNullOrEmpty($r.Pem)) 'empty PEM'
        }
        It 'falls back to a persisted CA when no live host is reachable' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyState -CaCert $b64 -CaCertSourceHost '10.9.9.9' -Confirm:$false
            $r = Resolve-CachingProxyCaCertPem -LiveTimeoutSec 1
            Assert-Equal -Expected 'persisted' -Actual $r.Source -Because 'served persisted fallback'
            Assert-True (Test-CachingProxyCaPem -Pem $r.Pem) 'fallback PEM is valid'
        }
    }

    Context 'Get-CachingProxyCaCertBase64 fallback keying' {
        It 'reuses a persisted CA when the cache host matches' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyState -CaCert $b64 -CaCertSourceHost '127.0.0.1' -Confirm:$false
            $r = Get-CachingProxyCaCertBase64 -CacheCaUrl 'http://127.0.0.1:9/yuruna-squid-ca.crt' -CacheHost '127.0.0.1' -MaxAttempts 1
            Assert-Equal -Expected 'persisted' -Actual $r.Source -Because 'matched host reuses persisted CA'
            Assert-False $r.Exhausted 'not exhausted'
            Assert-Equal -Expected $b64 -Actual $r.CaCertBase64 -Because 'returns the persisted b64'
        }
        It 'refuses a persisted CA saved for a different cache host' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyState -CaCert $b64 -CaCertSourceHost '10.0.0.1' -Confirm:$false
            $r = Get-CachingProxyCaCertBase64 -CacheCaUrl 'http://127.0.0.1:9/yuruna-squid-ca.crt' -CacheHost '127.0.0.1' -MaxAttempts 1
            Assert-Equal -Expected 'none' -Actual $r.Source -Because 'mismatched host refuses the fallback'
            Assert-True $r.Exhausted 'exhausted -> caller decides'
            Assert-True ([string]::IsNullOrEmpty($r.CaCertBase64)) 'no CA baked'
        }
    }
}

Describe 'Guest CA self-heal shape (ubuntu update scripts)' {
    foreach ($s in $updateScripts) {
        Context (Split-Path $s -Leaf) {
            It 'guards on the :3129 bump port with a boundary' -TestCases @(@{ ScriptPath = $s }) {
                param($ScriptPath)
                Assert-True ($updateScriptBody[$ScriptPath] -match ':3129/\?\(\$\|\[\^0-9\]\)') 'port-boundary grep present'
            }
            It 'fetches the CA over --no-proxy' -TestCases @(@{ ScriptPath = $s }) {
                param($ScriptPath)
                Assert-True ($updateScriptBody[$ScriptPath] -match 'wget --no-proxy[\s\S]{0,200}/ca\.crt') '--no-proxy /ca.crt fetch'
            }
            It 'runs update-ca-certificates after installing the cert' -TestCases @(@{ ScriptPath = $s }) {
                param($ScriptPath)
                Assert-True ($updateScriptBody[$ScriptPath] -match 'update-ca-certificates') 'installs into trust store'
            }
            It 'emits a non-lying diagnostic when the bump is still untrusted' -TestCases @(@{ ScriptPath = $s }) {
                param($ScriptPath)
                Assert-True ($updateScriptBody[$ScriptPath] -match 'CA installed but bump still untrusted') 'never an unqualified success'
            }
            It 'never relaxes egress (no direct :443 / iptables edit in the self-heal)' -TestCases @(@{ ScriptPath = $s }) {
                param($ScriptPath)
                Assert-False ($updateScriptBody[$ScriptPath] -match 'yuruna_ca_selfheal[\s\S]*?iptables') 'self-heal does not touch iptables'
            }
        }
    }
}

Describe '/ca.crt status-server endpoint shape' {
    It 'defines the /ca.crt route' {
        Assert-True ($statusServiceBody -match "path -eq 'ca\.crt'") 'route present'
    }
    It 'resolves the CA via the live-read-first resolver' {
        Assert-True ($statusServiceBody -match 'Resolve-CachingProxyCaCertPem') 'uses the shared resolver'
    }
    It 'guards HEAD so no body is written (HTTP.sys RST trap)' {
        Assert-True ($statusServiceBody -match "ca\.crt[\s\S]*?HttpMethod -ne 'HEAD'[\s\S]*?OutputStream\.Write") 'HEAD body guard'
    }
    It '404s when no CA is resolvable' {
        Assert-True ($statusServiceBody -match "ca\.crt[\s\S]*?StatusCode = 404") 'diagnosed degrade, not a silent pass'
    }
}

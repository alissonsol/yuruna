<#PSScriptInfo
.VERSION 2026.08.21
.GUID 42fd45e3-d490-4fe2-a3d8-49d6577c6a35
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
    helpers in Test.CachingProxyService.psm1, the guest CA self-heal in the shared
    retry lib and the callers that invoke it, and the /ca.crt status-service endpoint.
.DESCRIPTION
    Behavioral tests exercise Test-CachingProxyServiceCaPem / the caCert state
    round-trip / Resolve-CachingProxyServiceCaCertPem / Get-CachingProxyServiceCaCertBase64
    against a temp YURUNA_RUNTIME_DIR (never the live runtime file). Structural
    guards assert the self-heal SHAPE in the bash update scripts (bump-port
    boundary, --no-proxy fetch, non-lying re-probe) and the /ca.crt HEAD-body
    guard in Start-StatusService.ps1 -- shape, so a comment cannot satisfy them.

    The throw-based Assert-* helpers live at script scope and are referenced
    from It blocks, so this runs under Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
# Resolved outside BeforeAll on purpose: the per-script Contexts below are built
# while Pester is DISCOVERING tests, and a BeforeAll body has not run by then. A
# loop over a not-yet-assigned list generates no Contexts at all and reports a
# clean pass having asserted nothing -- the same vacuous-pass failure mode the
# fixture comment below guards against, one scope up.
$script:updateScripts = @(
    (Join-Path $repoRoot 'guest/ubuntu.server.24/ubuntu.server.24.update.sh'),
    (Join-Path $repoRoot 'guest/ubuntu.server.26/ubuntu.server.26.update.sh')
)

BeforeAll {
$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $testDir
$script:module  = Join-Path $here 'Test.CachingProxyService.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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
# shape guards exist to prevent. A guard whose subject varies per Context takes the PATH
# as test-case data and reads the file itself, so nothing has to survive the phase change.
$script:retryLibBody = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'automation/yuruna-retry.sh')
$script:fetchExecBody = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'automation/fetch-and-execute.sh')
$statusServicePath = Join-Path $repoRoot 'test/service/Start-StatusService.ps1'
$script:statusServiceBody = Get-Content -Raw -LiteralPath $statusServicePath

}

Describe 'Test.CachingProxyService CA-source helpers' {
    BeforeEach {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("cpca_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:YURUNA_RUNTIME_DIR = $script:sandbox
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        Import-Module $script:module -Force -DisableNameChecking
        Import-Module powershell-yaml -Force -ErrorAction SilentlyContinue
    }

    Context 'Test-CachingProxyServiceCaPem' {
        It 'accepts a valid PEM certificate' {
            Assert-True (Test-CachingProxyServiceCaPem -Pem (Get-TestCaPem)) 'valid self-signed PEM'
        }
        It 'rejects a non-certificate string' {
            Assert-False (Test-CachingProxyServiceCaPem -Pem 'not a certificate') 'garbage'
        }
        It 'rejects an empty string' {
            Assert-False (Test-CachingProxyServiceCaPem -Pem '') 'empty'
        }
        It 'rejects PEM markers wrapping non-base64 junk' {
            Assert-False (Test-CachingProxyServiceCaPem -Pem "-----BEGIN CERTIFICATE-----`n!!!!`n-----END CERTIFICATE-----") 'bad body'
        }
    }

    Context 'caCert state round-trip' {
        It 'persists and reads back caCert + caCertSourceHost' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyServiceState -CaCert $b64 -CaCertSourceHost '10.1.2.3' -Confirm:$false
            $s = Read-CachingProxyServiceState
            Assert-Equal -Expected $b64 -Actual $s.caCert -Because 'caCert round-trips'
            Assert-Equal -Expected '10.1.2.3' -Actual $s.caCertSourceHost -Because 'sourceHost round-trips'
        }
        It 'merge-writes: saving password does not wipe caCert' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyServiceState -CaCert $b64 -CaCertSourceHost '10.1.2.3' -Confirm:$false
            $null = Save-CachingProxyServiceState -Secret 'pw' -Confirm:$false
            $s = Read-CachingProxyServiceState
            Assert-Equal -Expected $b64 -Actual $s.caCert -Because 'caCert preserved across an unrelated save'
        }
    }

    Context 'Resolve-CachingProxyServiceCaCertPem' {
        It 'returns none when no host and no persisted CA' {
            $r = Resolve-CachingProxyServiceCaCertPem -LiveTimeoutSeconds 1
            Assert-Equal -Expected 'none' -Actual $r.Source -Because 'nothing to serve'
            Assert-True ([string]::IsNullOrEmpty($r.Pem)) 'empty PEM'
        }
        It 'falls back to a persisted CA when no live host is reachable' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyServiceState -CaCert $b64 -CaCertSourceHost '10.9.9.9' -Confirm:$false
            $r = Resolve-CachingProxyServiceCaCertPem -LiveTimeoutSeconds 1
            Assert-Equal -Expected 'persisted' -Actual $r.Source -Because 'served persisted fallback'
            Assert-True (Test-CachingProxyServiceCaPem -Pem $r.Pem) 'fallback PEM is valid'
        }
    }

    Context 'Get-CachingProxyServiceCaCertBase64 fallback keying' {
        It 'reuses a persisted CA when the cache host matches' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyServiceState -CaCert $b64 -CaCertSourceHost '127.0.0.1' -Confirm:$false
            $r = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl 'http://127.0.0.1:9/yuruna-squid-ca.crt' -CacheHost '127.0.0.1' -MaxAttempts 1
            Assert-Equal -Expected 'persisted' -Actual $r.Source -Because 'matched host reuses persisted CA'
            Assert-False $r.Exhausted 'not exhausted'
            Assert-Equal -Expected $b64 -Actual $r.CaCertBase64 -Because 'returns the persisted b64'
        }
        It 'refuses a persisted CA saved for a different cache host' {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-TestCaPem)))
            $null = Save-CachingProxyServiceState -CaCert $b64 -CaCertSourceHost '10.0.0.1' -Confirm:$false
            $r = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl 'http://127.0.0.1:9/yuruna-squid-ca.crt' -CacheHost '127.0.0.1' -MaxAttempts 1
            Assert-Equal -Expected 'none' -Actual $r.Source -Because 'mismatched host refuses the fallback'
            Assert-True $r.Exhausted 'exhausted -> caller decides'
            Assert-True ([string]::IsNullOrEmpty($r.CaCertBase64)) 'no CA baked'
        }
    }
}

Describe 'Guest CA self-heal shape (yuruna-retry.sh)' {
    It 'guards on the :3129 bump port with a boundary' {
        Assert-True ($script:retryLibBody -match ':3129/\?\(\$\|\[\^0-9\]\)') 'port-boundary grep present'
    }
    It 'fetches the CA over --no-proxy' {
        Assert-True ($script:retryLibBody -match 'wget --no-proxy[\s\S]{0,200}/ca\.crt') '--no-proxy /ca.crt fetch'
    }
    It 'runs update-ca-certificates after installing the cert' {
        Assert-True ($script:retryLibBody -match 'update-ca-certificates') 'installs into trust store'
    }
    It 'emits a non-lying diagnostic when the bump is still untrusted' {
        Assert-True ($script:retryLibBody -match 'CA installed but bump still untrusted') 'never an unqualified success'
    }
    It 'never relaxes egress (no direct :443 / iptables edit in the self-heal)' {
        Assert-False ($script:retryLibBody -match 'yuruna_ca_selfheal[\s\S]*?iptables') 'self-heal does not touch iptables'
    }
    It 'separates repaired from nothing-to-repair from tried-and-failed' {
        # The rc=60 gate spends a retry only on the repaired case, so collapsing
        # the three outcomes into one exit code would either retry a cert failure
        # that can never clear or refuse to retry one that just did.
        Assert-True ($script:retryLibBody -match 'yuruna_ca_selfheal\(\)[\s\S]*?local ca_tmp rc=2') 'tried-and-failed is the default outcome'
        Assert-True ($script:retryLibBody -match 'CA self-heal: OK[\s\S]{0,120}rc=0') 'repaired is reported distinctly'
    }
    It 'routes a certificate failure through the re-anchor rather than the backoff ladder' {
        Assert-True ($script:retryLibBody -match 'rc" -eq 60 \D[\s\S]{0,120}yuruna_ca_selfheal') 'curl 60 re-anchors'
        Assert-True ($script:retryLibBody -match 'rc" -eq 5 \D[\s\S]{0,120}yuruna_ca_selfheal') 'wget 5 re-anchors'
        Assert-False ($script:retryLibBody -match '\|60\|') 'curl 60 is no longer an unconditional transient'
    }
}

Describe 'CA re-anchor runs at every fetched-script boundary' {
    # A trust anchor that only gets checked once per guest goes stale the moment
    # the cache is rebuilt mid-run: every step that already passed stays passed,
    # and the next one fails on a certificate nobody touched. fetch-and-execute
    # is the one file a resumed run re-enters through, so the check belongs there.
    It 'fetch-and-execute re-anchors before handing control to the payload' {
        Assert-True ($script:fetchExecBody -match 'yuruna_ca_selfheal') 'fetch-and-execute calls the re-anchor'
        Assert-True ($script:fetchExecBody -match 'yuruna_ca_selfheal[\s\S]{0,80}\|\| true') 'non-fatal: a payload still fails with its own diagnosis'
    }
    It 'the re-anchor is sourced before it is called' {
        Assert-True ($script:fetchExecBody -match 'YURUNA_RETRY_LIB"[\s\S]{0,1200}yuruna_ca_selfheal') 'lib sourced first'
    }
    foreach ($s in $script:updateScripts) {
        Context (Split-Path $s -Leaf) {
            It 'calls the shared re-anchor and does not carry its own copy' -TestCases @(@{ ScriptPath = $s }) {
                param($ScriptPath)
                $body = Get-Content -Raw -LiteralPath $ScriptPath
                Assert-True ($body -match 'yuruna_ca_selfheal \|\| true') 'calls the shared re-anchor'
                Assert-False ($body -match 'yuruna_ca_selfheal\(\)') 'no second copy to drift from the lib'
            }
        }
    }
}

Describe '/ca.crt status-service endpoint shape' {
    It 'defines the /ca.crt route' {
        Assert-True ($script:statusServiceBody -match "path -eq 'ca\.crt'") 'route present'
    }
    It 'resolves the CA via the live-read-first resolver' {
        Assert-True ($script:statusServiceBody -match 'Resolve-CachingProxyServiceCaCertPem') 'uses the shared resolver'
    }
    It 'guards HEAD so no body is written (HTTP.sys RST trap)' {
        Assert-True ($script:statusServiceBody -match "ca\.crt[\s\S]*?HttpMethod -ne 'HEAD'[\s\S]*?OutputStream\.Write") 'HEAD body guard'
    }
    It '404s when no CA is resolvable' {
        Assert-True ($script:statusServiceBody -match "ca\.crt[\s\S]*?StatusCode = 404") 'diagnosed degrade, not a silent pass'
    }
}

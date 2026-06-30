<#PSScriptInfo
.VERSION 2026.06.27
.GUID 42a3b6c9-1d4e-4f82-9a05-3b6c7d8e9f04
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host config ca mtls pester
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
    Pester coverage for Test.HostConfigCA.psm1: the per-host Config CA mints a
    CA + server leaf + per-VM client leaf, and validates a client cert only when
    it chains to this host's CA.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Uses an isolated $env:YURUNA_RUNTIME_DIR so the test mints into a
    throwaway directory. Run: Invoke-Pester -Path test/modules/Test.HostConfigCA.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$script:CaTestRuntime = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-configca-" + [guid]::NewGuid().ToString('N'))
$env:YURUNA_RUNTIME_DIR = $script:CaTestRuntime
New-Item -ItemType Directory -Force -Path $script:CaTestRuntime | Out-Null
Import-Module (Join-Path $here 'Test.HostConfigCA.psm1') -Force -DisableNameChecking

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'Test.HostConfigCA' {
    It 'mints a CA with a private key and the CA basic constraint, and persists it idempotently' {
        $ca = Initialize-YurunaConfigCA -Confirm:$false
        Assert-True ($ca.HasPrivateKey) 'CA must carry its signing key'
        $bc = $ca.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] } | Select-Object -First 1
        Assert-True ($bc -and $bc.CertificateAuthority) 'CA must assert the certificate-authority basic constraint'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:CaTestRuntime 'host-config-ca/ca.pfx')) 'ca.pfx persisted'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:CaTestRuntime 'host-config-ca/ca.crt')) 'ca.crt persisted'
        $ca2 = Initialize-YurunaConfigCA -Confirm:$false
        Assert-True ($ca2.Thumbprint -eq $ca.Thumbprint) 'second call returns the same persisted CA (idempotent)'
    }

    It 'mints a server leaf with a private key, serverAuth EKU, and the stable SAN' {
        $srv = New-YurunaConfigServerCertificate -Confirm:$false
        Assert-True ($srv.HasPrivateKey) 'server leaf must carry its key for SslStream'
        $eku = $srv.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | Select-Object -First 1
        $hasServerAuth = @($eku.EnhancedKeyUsages.Value) -contains '1.3.6.1.5.5.7.3.1'
        Assert-True $hasServerAuth 'server leaf must declare serverAuth EKU'
        Assert-True ($srv.DnsNameList.Unicode -contains 'yuruna-host-config') 'server leaf SAN must carry the stable hostname'
    }

    It 'issues a per-VM client leaf that validates as chaining to this host CA' {
        $client = New-YurunaConfigClientCertificate -SubjectName 'yuruna-caching-proxy' -HostId '42deadbeefdeadbeefdeadbeefdead01'
        Assert-True ($client.CertificatePem -match 'BEGIN CERTIFICATE') 'client cert PEM emitted'
        Assert-True ($client.PrivateKeyPem -match 'BEGIN PRIVATE KEY') 'client key PEM emitted'
        Assert-True ($client.CaCertificatePem -match 'BEGIN CERTIFICATE') 'CA PEM bundled for the guest trust store'
        $caPublic   = Get-YurunaConfigCaPublicCertificate
        # PowerShell can't bind a [string] to CreateFromPem's ReadOnlySpan<char>
        # overload, so reconstruct the cert from its DER bytes.
        $b64 = (($client.CertificatePem -split "`n") | Where-Object { $_ -and ($_ -notmatch 'CERTIFICATE') }) -join ''
        $clientCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($b64))
        Assert-True (Test-YurunaConfigClientCertificate -Certificate $clientCert -CaCertificate $caPublic) 'a client leaf signed by this CA must validate'
    }

    It 'rejects a foreign (self-signed) certificate' {
        $caPublic = Get-YurunaConfigCaPublicCertificate
        $ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
        try {
            $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=impostor', $ec, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
            $foreign = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        } finally { $ec.Dispose() }
        Assert-True (-not (Test-YurunaConfigClientCertificate -Certificate $foreign -CaCertificate $caPublic)) 'a cert not chaining to this host CA must be rejected'
        Assert-True (-not (Test-YurunaConfigClientCertificate -Certificate $null -CaCertificate $caPublic)) 'a null cert (no client cert presented) must be rejected'
    }
}

# Best-effort cleanup of the throwaway runtime dir.
Remove-Item -LiteralPath $script:CaTestRuntime -Recurse -Force -ErrorAction SilentlyContinue

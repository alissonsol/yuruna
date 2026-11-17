<#PSScriptInfo
.VERSION 2026.11.16
.GUID 42b8d3f0-6e21-4c7a-8f45-9d1a2c6e7b30
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache squid store-id github-release pester
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
    Guards how the caching proxy serves a stored GitHub release asset without
    asking GitHub.
.DESCRIPTION
    GitHub answers a release download with a 302 to a signed CDN URL. squid
    cannot store the redirect, and the signature changes, so without a Store ID
    every download asks GitHub first and fails whenever its redirect endpoint
    does, although the asset is in the cache. squid logs each redirect, a learner
    turns them into Store ID rules, and the release URL is then served from the
    stored CDN object. squid itself is not available here, so the directives
    and the build order are read from the seed, and the learner runs against
    stand-ins.
    See https://yuruna.link/42f6b05f-005d
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:repoRoot = $repoRoot
    $script:seedLines = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data')) -replace "`r`n", "`n" -split "`n"

    # The body of one write_files entry, dedented the way cloud-init writes it.
    function Get-SeedFileBody {
        param([Parameter(Mandatory)][string]$Path)
        $lines = $script:seedLines
        $at = [array]::IndexOf($lines, "  - path: $Path")
        if ($at -lt 0) { throw "The seed writes no $Path." }
        while ($at -lt $lines.Count -and $lines[$at] -ne '    content: |') { $at++ }
        $body = [Collections.Generic.List[string]]::new()
        for ($i = $at + 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.Length -gt 0 -and -not $line.StartsWith('      ')) { break }
            $body.Add($(if ($line.Length -ge 6) { $line.Substring(6) } else { '' }))
        }
        return ($body -join "`n").TrimEnd() + "`n"
    }

    $script:squidConf = Get-SeedFileBody -Path '/etc/squid/conf.d/yuruna.conf'
    $script:learner = Get-SeedFileBody -Path '/usr/local/bin/yuruna-release-asset-learn.py'
    $script:learnLine = '  - /usr/local/bin/yuruna-release-asset-learn.py --no-reconfigure || install -m 0644 /etc/squid/yuruna-store-id.static.rules /etc/squid/yuruna-store-id.rules'
}

Describe 'squid serves a learned release download from the CDN object it was redirected to' {
    It 'stores the release CDN''s signed URLs for a year' {
        # yuruna.conf is included ahead of the stock zero-freshness query-string rule.
        $script:squidConf | Should -Match '(?m)^refresh_pattern -i \^https\?://release-assets\\\.githubusercontent\\\.com/\s+525600 100% 525600 override-expire override-lastmod ignore-reload ignore-no-store ignore-private$'
    }

    It 'sends release downloads to the store ID helper and never stores GitHub''s answer to them' {
        $script:squidConf | Should -Match '(?m)^acl yuruna_github_release_download url_regex -i \^https\?://github\\\.com/\[\^/\]\+/\[\^/\]\+/releases/download/$'
        $allow = $script:squidConf.IndexOf('store_id_access allow yuruna_github_release_download')
        $allow | Should -BeGreaterThan -1
        $allow | Should -BeLessThan $script:squidConf.IndexOf('store_id_access deny all') -Because 'store_id_access is first-match-wins'
        # The redirect would otherwise land under the asset's key, or reach a CDN
        # request collapsed onto it, and send that URL back to itself.
        $script:squidConf | Should -Match '(?m)^store_miss deny yuruna_github_release_download$'
        $script:squidConf | Should -Match '(?m)^collapsed_forwarding_access deny yuruna_github_release_download$'
    }

    It 'logs each redirect in the fields the learner reads, only for transactions with a request' {
        $script:squidConf | Should -Match '(?m)^logformat yuruna_release_redirect %ts\.%03tu %<Hs %>ru %\{Location\}<h$'
        $script:squidConf | Should -Match '(?m)^acl yuruna_has_request has request$'
        # `has request` first: a URL ACL evaluated for a request-less log event warns in cache.log.
        $script:squidConf | Should -Match '(?m)^access_log stdio:/var/log/squid/yuruna_release_redirects\.log yuruna_release_redirect yuruna_has_request yuruna_github_release_download$'
        $script:learner | Should -Match "(?m)^\s+parser\.add_argument\('--log', default='/var/log/squid/yuruna_release_redirects\.log'\)$"
    }

    It 'logs every URL the learner may learn' {
        $acl = [regex]::Match($script:squidConf, '(?m)^acl yuruna_github_release_download url_regex -i (\S+)$').Groups[1].Value
        $learnable = [regex]::Match($script:learner, "(?m)^REQUEST = re\.compile\(r'([^']+)'\)$").Groups[1].Value
        $learnable | Should -Not -BeNullOrEmpty
        foreach ($url in @(
                'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/powershell-7.6.9-linux-x64.tar.gz',
                'https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_linux_amd64.zip',
                'https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-arm64')) {
            $url | Should -Match $learnable -Because 'the learner takes it'
            [regex]::IsMatch($url, $acl, 'IgnoreCase') | Should -BeTrue -Because "squid must log $url for the learner to see it"
        }
        foreach ($url in @('https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/hashes.sha256?nocache=7',
                'https://github.com/PowerShell/PowerShell/releases/latest')) {
            $url | Should -Not -Match $learnable -Because 'a query or a moving target is never learned'
        }
    }
}

Describe 'the build writes the rules before squid starts and keeps them current' {
    It 'ships the learner, its unit and a timer the build enables' {
        $script:learner | Should -Match '(?m)^def rule_for\('
        Get-SeedFileBody -Path '/etc/systemd/system/yuruna-release-asset-learn.service' | Should -Match '(?m)^ExecStart=/usr/local/bin/yuruna-release-asset-learn\.py$'
        Get-SeedFileBody -Path '/etc/systemd/system/yuruna-release-asset-learn.timer' | Should -Match '(?m)^Unit=yuruna-release-asset-learn\.service$'
        ($script:seedLines -contains '  - systemctl enable --now yuruna-release-asset-learn.timer || true') | Should -BeTrue
    }

    It 'leaves the rules file squid reads to the learner, seeded from the static rules' {
        $script:squidConf | Should -Match '(?m)^store_id_program /usr/lib/squid/storeid_file_rewrite /etc/squid/yuruna-store-id\.rules$'
        $script:learner | Should -Match "(?m)^\s+parser\.add_argument\('--rules', default='/etc/squid/yuruna-store-id\.rules'\)$"
        $script:learner | Should -Match "(?m)^\s+parser\.add_argument\('--static-rules', default='/etc/squid/yuruna-store-id\.static\.rules'\)$"
        ($script:seedLines -contains '  - path: /etc/squid/yuruna-store-id.static.rules') | Should -BeTrue
        ($script:seedLines -contains '  - path: /etc/squid/yuruna-store-id.rules') | Should -BeFalse -Because 'a seeded copy would drift from what the learner writes'
    }

    It 'writes the rules file before squid first starts its helpers' {
        $learn = [array]::IndexOf($script:seedLines, $script:learnLine)
        $learn | Should -BeGreaterThan -1
        $learn | Should -BeLessThan ([array]::IndexOf($script:seedLines, '  - systemctl start squid || true')) -Because 'the helper reads its rules once, as squid starts it'
        $parse = @(0..($script:seedLines.Count - 1) | Where-Object { $script:seedLines[$_] -match '^\s+/usr/sbin/squid -k parse \|\| echo' })
        $parse.Count | Should -Be 1
        $learn | Should -BeLessThan $parse[0] -Because 'the build parses the configuration it starts squid with'
    }

    It 'passes its own unit tests against stand-in logs' {
        # A candidate must answer --version: the Windows Store alias for python3
        # resolves as an application yet exits 9009 without running anything.
        $python = @('python3', 'python') | ForEach-Object {
                Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue
            } | Where-Object {
                $version = & $_.Source --version 2>&1
                $LASTEXITCODE -eq 0 -and "$version" -match '^Python 3\.([89]|1\d)'
            } | Select-Object -First 1
        if (-not $python) { Set-ItResult -Skipped -Because 'Python 3.8 or newer is unavailable on this host.'; return }
        $suite = Join-Path $script:repoRoot 'host/vmconfig/tests/test_release_asset_learn.py'
        $output = (& $python.Source $suite -v 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'Ran 13 tests'
    }
}

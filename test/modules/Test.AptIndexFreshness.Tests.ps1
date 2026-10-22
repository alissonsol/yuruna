<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4245d8ae-72c4-4ea3-87f6-c420ac0eb0f8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache squid apt offline-mode pester
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
    Guards how the caching proxy keeps apt metadata in step with its InRelease.
.DESCRIPTION
    offline_mode serves a stored object as first fetched, so a cached InRelease
    and an index from a later publish of a repository without by-hash can stay
    apart for good; every guest of that architecture then fails apt-get update.
    yuruna.conf answers that metadata from the origin, no-upstream mode serves
    the stored copies again, and a self-test reports any pair the cache still
    serves out of step. squid itself is not available here, so the rule's
    shape is read from the seed and the self-test runs against stand-ins.
    See https://yuruna.link/42f6b05f-0057
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:seedPath = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data'
    $script:seedLines = (Get-Content -Raw -LiteralPath $script:seedPath) -replace "`r`n", "`n" -split "`n"

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
    $script:noUpstream = Get-SeedFileBody -Path '/usr/local/sbin/yuruna-no-upstream'
}

Describe 'yuruna.conf answers mutable apt metadata from the origin' {
    It 'denies cache hits for dists/ metadata and keeps by-hash content cached' {
        $script:squidConf | Should -Match '(?m)^acl yuruna_apt_index urlpath_regex -i /dists/ '
        $script:squidConf | Should -Match '(?m)^acl yuruna_apt_index .*\(InRelease\|Release\|Release\\\.gpg\)\$'
        $script:squidConf | Should -Match '(?m)^acl yuruna_apt_by_hash urlpath_regex -i /by-hash/$'
        $script:squidConf | Should -Match '(?m)^send_hit deny yuruna_apt_index !yuruna_apt_by_hash !yuruna_no_upstream$'
    }

    It 'keeps storing that metadata, so no-upstream mode has a copy to serve' {
        # A cache deny or store_miss deny would leave nothing stored for the
        # switch to fall back on.
        $script:squidConf | Should -Not -Match '(?m)^(cache|store_miss) deny yuruna_apt_index'
    }

    It 'defines yuruna_no_upstream before the rule, with a value no client has' {
        $acl = [regex]::Match($script:squidConf, '(?m)^acl yuruna_no_upstream src (.+)$')
        $acl.Success | Should -BeTrue
        $acl.Groups[1].Value | Should -Be '255.255.255.255/32'
        $script:squidConf.IndexOf('acl yuruna_no_upstream') | Should -BeLessThan $script:squidConf.IndexOf('send_hit deny yuruna_apt_index')
    }
}

Describe 'no-upstream mode serves the stored apt metadata again' {
    It 'widens yuruna_no_upstream to every client range the cache admits' {
        $acl = [regex]::Match($script:noUpstream, '(?m)^acl yuruna_no_upstream src (.+)$')
        $acl.Success | Should -BeTrue -Because 'without it the send_hit rule turns every apt-get update into a refused miss'
        $values = $acl.Groups[1].Value -split '\s+'
        foreach ($range in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8') { $values | Should -Contain $range }
    }

    It 'adds no range that overlaps the never-matching value' {
        # squid drops one of two overlapping entries in the same list, and which
        # one depends on the order it reads conf.d: an overlap would leave the
        # switch working on one host and not on another.
        $values = [regex]::Match($script:noUpstream, '(?m)^acl yuruna_no_upstream src (.+)$').Groups[1].Value -split '\s+'
        foreach ($wide in 'all', '0.0.0.0/0', '::/0', '128.0.0.0/1', '255.0.0.0/8') { $values | Should -Not -Contain $wide }
    }
}

Describe 'the apt index self-test is installed, scheduled and published' {
    It 'ships the script, its probe list and a timer the build enables' {
        Get-SeedFileBody -Path '/usr/local/bin/yuruna-apt-index-selftest.py' | Should -Match '(?m)^def check_pair\('
        Get-SeedFileBody -Path '/etc/squid/yuruna-apt-index-probes.list' | Should -Match '(?m)^https://download\.docker\.com/linux/ubuntu\s+noble\s+stable\s+amd64 arm64$'
        Get-SeedFileBody -Path '/etc/systemd/system/yuruna-apt-index-selftest.service' | Should -Match '(?m)^ExecStart=/usr/local/bin/yuruna-apt-index-selftest\.py --quiet$'
        Get-SeedFileBody -Path '/etc/systemd/system/yuruna-apt-index-selftest.timer' | Should -Match '(?m)^Unit=yuruna-apt-index-selftest\.service$'
        ($script:seedLines -contains '  - systemctl enable --now yuruna-apt-index-selftest.timer || true') | Should -BeTrue
    }

    It 'reaches /squid-meta and /cache-health, with a stand-in until the first run' {
        $squidMeta = Get-SeedFileBody -Path '/usr/local/bin/squid-meta-exporter.sh'
        $squidMeta | Should -Match 'cat "\$APT_SELFTEST_PROM" >> "\$TMP"'
        $squidMeta | Should -Match "echo 'yuruna_apt_index_selftest_available 0'"
        $page = Get-SeedFileBody -Path '/usr/local/bin/zot-meta-exporter.sh'
        $page | Should -Match 'cat /var/lib/yuruna/apt-index-selftest\.txt'
        $page | Should -Match 'apt index pairs\s+: not run yet'
    }

    It 'draws the dashboard panel from the series the script writes' {
        $script = Get-SeedFileBody -Path '/usr/local/bin/yuruna-apt-index-selftest.py'
        $script | Should -Match "'yuruna_apt_index_consistent\{"
        $dashboard = Get-SeedFileBody -Path '/var/lib/grafana/dashboards/cache-health.json' | ConvertFrom-Json
        $panel = @($dashboard.panels | Where-Object { $_.title -eq 'Apt index pairs out of step' })
        $panel.Count | Should -Be 1
        $panel[0].targets[0].expr | Should -Be 'sum(1 - yuruna_apt_index_consistent)'
    }

    It 'passes its own unit tests against stand-in repositories' {
        # A candidate must answer --version: the Windows Store alias for python3
        # resolves as an application yet exits 9009 without running anything.
        $python = @('python3', 'python') | ForEach-Object {
                Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue
            } | Where-Object {
                $version = & $_.Source --version 2>&1
                $LASTEXITCODE -eq 0 -and "$version" -match '^Python 3\.([89]|1\d)'
            } | Select-Object -First 1
        if (-not $python) { Set-ItResult -Skipped -Because 'Python 3.8 or newer is unavailable on this host.'; return }
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $suite = Join-Path $repoRoot 'host/vmconfig/tests/test_apt_index_selftest.py'
        $output = (& $python.Source $suite -v 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'Ran 8 tests'
    }
}

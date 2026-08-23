<#PSScriptInfo
.VERSION 2026.08.23
.GUID 42782448-e44d-4353-957b-a836ffda43e7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache proxy guest topology pester
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
    Guards the two-topology contract: every guest provisions whether or not the
    lab has a caching proxy, and no step addresses a cache without first asking
    whether one is there.
.DESCRIPTION
    A caching proxy is an optimization. Labs run without one, and a lab that had
    one can lose it between cycles, so each guest has to decide at run time which
    topology it is in and configure only what that topology supports. The failure
    this pins is quiet and expensive: a step that addresses the cache
    unconditionally fails with "could not resolve host", which reads as a broken
    proxy VM and sends the reader to a machine that was never meant to exist,
    after burning the step's timeout first.

    The guards are structural, over the shipped script text, because the guests
    run on hosts this suite cannot reach. The k8s guests are checked by nesting
    rather than by enumerating today's steps, so a cache-addressed step added
    later is caught without this file being updated.

    Should assertions only, so the suite runs under Pester 4.10.1 as well as 5.
#>

BeforeAll {
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$script:k8sPaths = @(
    (Join-Path $repoRoot 'guest/ubuntu.server.24/ubuntu.server.24.k8s.sh')
    (Join-Path $repoRoot 'guest/ubuntu.server.26/ubuntu.server.26.k8s.sh')
)
$script:al2023Update = Join-Path $repoRoot 'guest/amazon.linux.2023/amazon.linux.2023.update.sh'
$script:retryLib     = Join-Path $repoRoot 'automation/yuruna-retry.sh'
}

Describe 'A lab with no caching proxy provisions on the direct path' {
    # The cache is an optimization, not a prerequisite: a lab without one pulls
    # from the upstreams, the same way the guest's proxy-egress rules skip
    # themselves when no cache URL was seeded. Every mirror-shaped step names an
    # address that does not exist in such a lab, so an ungated one fails with
    # "could not resolve host" -- which reads as a broken proxy and sends the
    # reader to a machine that was never meant to exist.
    It 'probes the bare service name rather than adopting it unresolved' {
        foreach ($g in $script:k8sPaths) {
            $t = Get-Content -LiteralPath $g -Raw
            $t | Should -Not -Match '(?m)^\[ -z "\$CACHE_HOST" \] && CACHE_HOST='
            $t | Should -Match 'curl [^\r\n]*http://yuruna-caching-proxy-service:5000/v2/'
        }
    }
    It 'writes the registry mirror only when a cache was named' {
        foreach ($g in $script:k8sPaths) {
            $t = Get-Content -LiteralPath $g -Raw
            $guardAt  = $t.IndexOf('if [ -n "$CACHE_HOST" ]; then')
            $daemonAt = $t.IndexOf('/etc/docker/daemon.json')
            $certsAt  = $t.IndexOf('/etc/containerd/certs.d/docker.io')
            $guardAt | Should -BeGreaterThan 0
            $guardAt | Should -BeLessThan $daemonAt
            $guardAt | Should -BeLessThan $certsAt
        }
    }
    It 'skips both warm passes when no cache was named' {
        foreach ($g in $script:k8sPaths) {
            $t = Get-Content -LiteralPath $g -Raw
            $skipAt = $t.IndexOf('if [ -z "$CACHE_HOST" ]; then' + "`n" + '    echo "No caching proxy')
            $skipAt | Should -BeGreaterThan 0
            $skipAt | Should -BeLessThan $t.IndexOf('yuruna_warm_refs "control-plane"')
            $t | Should -Match '(?m)^if \[ -n "\$CACHE_HOST" \] && \[ -n "\$_cni_refs" \]; then'
        }
    }
    It 'expands CACHE_HOST only where the variable has been tested' {
        # Structural rather than by enumeration: a step added later that
        # addresses the cache without asking whether there is one is exactly the
        # regression this pins, and naming today's steps would not catch it.
        foreach ($g in $script:k8sPaths) {
            $depth = 0
            $inTested = $false
            $inWarmFunc = $false
            $ungated = @()
            foreach ($line in (Get-Content -LiteralPath $g)) {
                $s = $line.Trim()
                if ($s -eq 'yuruna_warm_refs() {') { $inWarmFunc = $true; continue }
                if ($inWarmFunc) {
                    if ($s -eq '}') { $inWarmFunc = $false }
                    continue
                }
                if ($inTested) {
                    if ($s -match '^(if|until|while|for|case) ') { $depth++ }
                    elseif ($s -in @('fi', 'done', 'esac')) {
                        $depth--
                        if ($depth -eq 0) { $inTested = $false; continue }
                    }
                } elseif ($s -match '^if \[ -[nz] "\$CACHE_HOST" \]') {
                    $inTested = $true
                    $depth = 1
                    continue
                }
                if (-not $inTested -and $line -match '\$\{CACHE_HOST\}') { $ungated += $s }
            }
            $ungated -join ' | ' | Should -BeExactly ''
        }
    }
}

Describe 'Amazon Linux 2023 finds the cache at run time, or does without it' {
    # This guest boots a prebuilt cloud image, so the address cannot be
    # templated into the seed the way the Ubuntu installer path does it: a
    # templated proxy is written before anything can confirm it still answers.
    It 'derives the address from the environment and host.env, never from the seed' {
        $t = Get-Content -LiteralPath $script:al2023Update -Raw
        $t | Should -Match 'CACHE_HOST=\$\(echo "\$\{http_proxy:-\}"'
        $t | Should -Match 'YURUNA_CACHING_PROXY_SERVICE_IP=\(\[\^\[:space:\]\]\+\).*/etc/yuruna/host\.env'
        # The seed placeholder the Ubuntu path uses must not reappear here.
        $t | Should -Not -Match 'CACHING_PROXY_URL_PLACEHOLDER'
    }
    It 'probes every candidate, including one read off disk' {
        # An address that was right when the seed was written is no evidence the
        # cache is up now, so the probe sits after the whole fallback chain
        # rather than only guarding the bare-hostname branch.
        $t = Get-Content -LiteralPath $script:al2023Update -Raw
        $probeAt  = $t.IndexOf('curl -s --max-time 10 -o /dev/null "http://${CACHE_HOST}:3128"')
        $bareAt   = $t.IndexOf('CACHE_HOST="yuruna-caching-proxy-service"')
        $configAt = $t.IndexOf('proxy=http://${CACHE_HOST}:3128')
        $bareAt   | Should -BeGreaterThan 0
        $bareAt   | Should -BeLessThan $probeAt
        $probeAt  | Should -BeLessThan $configAt
    }
    It 'writes the dnf proxy under [main] rather than appending it' {
        # Appended, the key lands in whatever section happens to be last, and a
        # proxy set under a repo section binds to that repo alone.
        $t = Get-Content -LiteralPath $script:al2023Update -Raw
        $t.IndexOf('sed -i "/^\[main\]/a proxy=http://${CACHE_HOST}:3128"') | Should -BeGreaterThan 0
    }
    It 'checks that the dnf proxy key actually landed' {
        # An insert whose address never matched writes nothing and reports
        # success, so a dnf.conf that lost its [main] header would go direct
        # while the log claims the cache is in use.
        $t = Get-Content -LiteralPath $script:al2023Update -Raw
        $t | Should -Match 'if ! grep -q "\^proxy=http://\$\{CACHE_HOST\}:3128'
        $t | Should -Match 'no \[main\] section to hold the proxy key'
    }
    It 'clears the dnf proxy and the profile drop-in when nothing answers' {
        # Clearing is as load-bearing as setting: a guest whose cache was rebuilt
        # or moved would otherwise keep pointing dnf at a dead address, and the
        # direct path it should fall back to is the one stale config removes.
        $t = Get-Content -LiteralPath $script:al2023Update -Raw
        $elseAt = $t.IndexOf("`nelse`n")
        $elseAt | Should -BeGreaterThan 0
        $tail = $t.Substring($elseAt)
        $tail | Should -Match "sed -i '/\^proxy\[\[:space:\]\]\*=/d' /etc/dnf/dnf\.conf"
        $tail | Should -Match 'rm -f /etc/profile\.d/yuruna-proxy\.sh'
    }
    It 'falls back to the CONNECT port when the bump CA cannot be trusted' {
        # Exit 2 from the shared re-anchor is the one outcome meaning the bump
        # will keep failing. Tunneling HTTPS unbumped is uncached but working,
        # which beats a guest that cannot fetch at all.
        $t = Get-Content -LiteralPath $script:al2023Update -Raw
        $t | Should -Match 'yuruna_ca_selfheal \|\| _ca_rc=\$\?'
        $t | Should -Match 'if \[ "\$_ca_rc" -eq 2 \]; then'
        $t | Should -Match 'export https_proxy="http://\$\{CACHE_HOST\}:3128/"'
    }
    It 'carries no private copy of the shared re-anchor' {
        (Get-Content -LiteralPath $script:al2023Update -Raw) | Should -Not -Match 'yuruna_ca_selfheal\(\)'
    }
    It 'is not fatal when no cache answers' {
        # Unlike the k8s registry gate, nothing here routes exclusively through
        # the cache, so its absence costs bandwidth rather than the run.
        $lines = Get-Content -LiteralPath $script:al2023Update
        $start = ($lines | Select-String -SimpleMatch 'REGION: Point dnf at the caching proxy').LineNumber
        $end   = ($lines | Select-String -SimpleMatch 'REGION: Ensure PowerShell is installed').LineNumber
        $start | Should -BeGreaterThan 0
        $end   | Should -BeGreaterThan $start
        ($lines[($start - 1)..($end - 1)] -match '^\s*exit 1\s*$') | Should -BeNullOrEmpty
    }
}

Describe 'The shared trust anchor reaches both guest families' {
    # The retry lib is sourced by Debian-family and RHEL-family guests alike.
    # The anchor directory and the command that re-hashes the store differ
    # between them and have to be chosen together -- a Debian-layout drop on a
    # RHEL guest leaves a file nothing reads and still reports success.
    It 'installs through one helper rather than a hardcoded Debian path' {
        $t = Get-Content -LiteralPath $script:retryLib -Raw
        $t | Should -Match '_yuruna_ca_trust\(\) \{'
        $t | Should -Match '_yuruna_ca_trust "\$ca_tmp" \|\| true'
    }
    It 'pairs each anchor directory with the refresh command that reads it' {
        $t = Get-Content -LiteralPath $script:retryLib -Raw
        $fn = [regex]::Match($t, '(?s)_yuruna_ca_trust\(\) \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        # Split on the elif so each branch is checked for its OWN pair and for
        # the absence of the other family's -- the mix-up this guards against.
        $parts = $fn -split '(?m)^\s*elif command -v update-ca-trust'
        $parts.Count | Should -Be 2
        $parts[0] | Should -Match '/usr/local/share/ca-certificates/yuruna-squid-ca\.crt'
        $parts[0] | Should -Match 'sudo update-ca-certificates'
        $parts[0] | Should -Not -Match '/etc/pki/ca-trust'
        $parts[1] | Should -Match '/etc/pki/ca-trust/source/anchors/yuruna-squid-ca\.crt'
        $parts[1] | Should -Match 'sudo update-ca-trust extract'
        $parts[1] | Should -Not -Match '/usr/local/share/ca-certificates'
    }
    It 'keeps the .crt extension update-ca-certificates requires' {
        # Every other extension is ignored by the Debian refresh, silently.
        $t = Get-Content -LiteralPath $script:retryLib -Raw
        ([regex]::Matches($t, 'yuruna-squid-ca\.crt')).Count | Should -BeGreaterThan 1
    }
    It 'says so rather than reporting success when neither command exists' {
        $t = Get-Content -LiteralPath $script:retryLib -Raw
        $fn = [regex]::Match($t, '(?s)_yuruna_ca_trust\(\) \{.*?\n\}').Value
        $fn | Should -Match 'cannot add a trust anchor here'
        $fn | Should -Match 'return 1'
    }
}

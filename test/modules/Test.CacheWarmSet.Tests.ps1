<#PSScriptInfo
.VERSION 2026.08.20
.GUID 429e84c5-0bc5-487b-b851-b34fccf102c0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache registry prewarm pester
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
    Guards the warm-set contract: the cache publishes image residency, the guest
    diagnostic reads it as text and lifts a shortfall into the problems summary,
    and every warm request names its upstream.
.DESCRIPTION
    Three properties are covered, each of which fails silently in production.

    The page format lives in the caching-proxy seed and the patterns that read
    it live in Get-SystemDiagnostic.ps1, so the two are extracted from their own
    files and matched against each other rather than against a hand-written
    fixture -- a format change on either side has to keep them agreeing.

    A response body carrying no text content type arrives as a byte[], and
    casting that to string yields space-joined decimal byte values. The page
    then renders as digits and every pattern below silently stops matching, so
    the decode branch is pinned.

    A cache request that omits the ns= query parameter leaves the registry to
    guess which upstream a repository belongs to, and the fallback is the one
    metered upstream in the lab. Nothing fails visibly; the budget just drains.

    Should assertions only, so the suite runs under Pester 4.10.1 as well as 5.
#>

BeforeAll {
$repoRoot   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$diagPath   = Join-Path $repoRoot 'automation/Get-SystemDiagnostic.ps1'
$seedPath   = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data'
$script:guestPaths = @(
    (Join-Path $repoRoot 'guest/ubuntu.server.24/ubuntu.server.24.k8s.sh')
    (Join-Path $repoRoot 'guest/ubuntu.server.26/ubuntu.server.26.k8s.sh')
)

$script:seedText = Get-Content -LiteralPath $seedPath -Raw

# --- REGION: Patterns lifted from the reader, format lifted from the writer
function Get-DiagAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($diagPath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($diagPath): $($errs[0].Message)" }
    return $ast
}
function Get-DiagStringLiteral {
    @((Get-DiagAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true)) | ForEach-Object { $_.Value }
}
# Identified by shape rather than by position: the header pattern is the only
# literal carrying a named capture next to "image set", and the residency
# pattern the only one anchoring on "resident".
$script:setHeaderPattern = @(Get-DiagStringLiteral |
    Where-Object { $_ -like '*image set*' -and $_ -like '*(?<name>*' })[0]
$script:residentPattern  = @(Get-DiagStringLiteral |
    Where-Object { $_ -like '^\s*resident*' })[0]

# The published lines, taken from the seed that writes them. Shell expansions
# are replaced with representative values so the result is what a guest reads.
function Expand-SeedEcho {
    param([string]$EchoLine)
    $t = $EchoLine -replace '^\s*echo\s+"', '' -replace '"\s*$', ''
    # ${VAR:-default} keeps its default; a bare ${VAR} gets a sample value.
    $t = [regex]::Replace($t, '\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}', '$1')
    $t = [regex]::Replace($t, '\$\{[A-Za-z_][A-Za-z0-9_]*\}', '3')
    $t = [regex]::Replace($t, '\$\(\([^)]*\)\)', '4')
    return $t
}
function Get-SeedEchoLine {
    param([string]$Like)
    @($script:seedText -split "`r?`n" |
        Where-Object { $_ -match '^\s*echo\s+"' -and $_ -like $Like } |
        ForEach-Object { Expand-SeedEcho $_ })
}

# Reproduces the scan in Get-SystemDiagnostic.ps1 using ITS patterns, so a
# pattern edit is exercised here even though the loop itself sits in a script
# body that cannot be invoked without running a full capture.
function Get-ResidencyShortfall {
    param([string]$PageText)
    $found = @()
    $set = $null
    foreach ($line in ($PageText -split "`r?`n")) {
        if ($line -match $script:setHeaderPattern) {
            $set = @{ Name = $Matches['name']; Version = $Matches['ver'] }
        } elseif ($set -and $line -match $script:residentPattern) {
            $held = [int]$Matches[1]; $total = [int]$Matches[2]
            if ($total -gt 0 -and $held -lt $total) {
                $found += @{ Name = $set.Name; Held = $held; Total = $total }
            }
            $set = $null
        }
    }
    return , $found
}

$script:warmPage = @"
yuruna caching-proxy health -- 2026-08-14T17:15:45Z

zot /v2/ liveness            : up
zot resident-tag revalidation: OK -- answered inside the 30s a pull waits for response headers

Warm sets, last warmed 2026-08-14T16:10:04Z (versions resolved via local host status service):
  Kubernetes image set (v1.36.3, pinned minor 1.36):
    resident                 : 7 of 7
  CNI image set (flannel v0.28.1):
    resident                 : 2 of 2

Docker Hub budget            : 100 of 100 left
"@

$script:coldPage = $script:warmPage -replace 'resident                 : 7 of 7', `
    'resident                 : 3 of 7   <-- a kubeadm init pays 4 cold sync(s)'
}

Describe 'The published residency lines are the ones the diagnostic reads' {
    It 'extracts a residency pattern and a set-header pattern from the diagnostic' {
        $script:setHeaderPattern | Should -Not -BeNullOrEmpty
        $script:residentPattern  | Should -Not -BeNullOrEmpty
    }
    It 'matches every "<name> image set (...)" header the seed publishes' {
        $headers = Get-SeedEchoLine -Like '*image set (*'
        $headers.Count | Should -BeGreaterOrEqual 2
        foreach ($h in $headers) { $h | Should -Match $script:setHeaderPattern }
    }
    It 'matches every "resident : N of M" line the seed publishes' {
        $rows = Get-SeedEchoLine -Like '*resident *: *'
        $rows.Count | Should -BeGreaterOrEqual 2
        foreach ($r in $rows) { $r | Should -Match $script:residentPattern }
    }
    It 'does not read the no-warm-run line as a set header' {
        # That line names no version, so treating it as a header would leave the
        # scan waiting for a count that never comes.
        'Warm sets                    : no warm run has recorded residency yet.' |
            Should -Not -Match $script:setHeaderPattern
    }
}

Describe 'A shortfall reaches the problems summary and a warm cache does not' {
    It 'reports nothing while every set is held' {
        (Get-ResidencyShortfall -PageText $script:warmPage).Count | Should -Be 0
    }
    It 'reports the short set only, naming the count a guest would pay for' {
        $s = Get-ResidencyShortfall -PageText $script:coldPage
        $s.Count | Should -Be 1
        $s[0].Name  | Should -Be 'Kubernetes'
        $s[0].Held  | Should -Be 3
        $s[0].Total | Should -Be 7
    }
    It 'keeps reading later sets after a short one' {
        $both = $script:coldPage -replace 'resident                 : 2 of 2', `
            'resident                 : 0 of 2'
        (Get-ResidencyShortfall -PageText $both).Count | Should -Be 2
    }
}

Describe 'The health page is decoded rather than cast' {
    It 'tests the response body for byte[] before using it' {
        $diagText = Get-Content -LiteralPath $diagPath -Raw
        $diagText | Should -Match '\$healthResp\.Content\s+-is\s+\[byte\[\]\]'
    }
    It 'decodes that body as UTF8 text' {
        $diagText = Get-Content -LiteralPath $diagPath -Raw
        $diagText | Should -Match '\[System\.Text\.Encoding\]::UTF8\.GetString\(\$healthResp\.Content\)'
    }
    It 'a bare cast would have produced digits, which no pattern here matches' {
        # Pins why the branch exists: the failure mode is a readable-looking
        # page of numbers, not an error.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:coldPage)
        $naive = [string]$bytes
        (Get-ResidencyShortfall -PageText $naive).Count | Should -Be 0
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Be $script:coldPage
    }
}

Describe 'Every warm request names the upstream it belongs to' {
    It 'the cache-side warm request carries ns=' {
        # Omitting it leaves the registry walking its upstream list, where Docker
        # Hub is the catch-all: the lookup lands on the one metered budget in the
        # lab, for an image Docker Hub never served.
        $script:seedText | Should -Match '/manifests/\$\{W_TAG\}\?ns=\$\{W_UPSTREAM\}'
    }
    It 'the guest-side warm request carries ns=' {
        foreach ($g in $script:guestPaths) {
            (Get-Content -LiteralPath $g -Raw) |
                Should -Match '/manifests/\$\{_wr_tag\}\?ns=\$\{_wr_upstream\}'
        }
    }
}

Describe 'The warm job is installed and armed by the seed' {
    It 'writes the prewarm script and its units' {
        foreach ($p in @('/usr/local/bin/zot-prewarm.sh',
                         '/etc/systemd/system/zot-prewarm.service',
                         '/etc/systemd/system/zot-prewarm.timer')) {
            $script:seedText | Should -Match ([regex]::Escape("path: $p"))
        }
    }
    It 'enables the timer during boot' {
        $script:seedText | Should -Match 'systemctl enable --now zot-prewarm\.timer'
    }
    It 'gives the unit a start timeout wide enough for a cold multi-arch set' {
        # systemd's default would kill a first warm mid-sync, leaving partial
        # content for the next run to redo from the start.
        $script:seedText | Should -Match 'TimeoutStartSec=3h'
    }
}

Describe 'A guest stops on a cold control plane instead of timing out' {
    It 'exits non-zero when the control-plane set did not arrive' {
        foreach ($g in $script:guestPaths) {
            $t = Get-Content -LiteralPath $g -Raw
            $t | Should -Match 'yuruna_warm_refs "control-plane"'
            $t | Should -Match 'the cache is still cold'
        }
    }
    It 'warms the CNI images before applying the manifest that pulls them' {
        foreach ($g in $script:guestPaths) {
            $t = Get-Content -LiteralPath $g -Raw
            $warmAt  = $t.IndexOf('yuruna_warm_refs "flannel"')
            $applyAt = $t.IndexOf('apply -f "$FLANNEL_MANIFEST"')
            $warmAt  | Should -BeGreaterThan 0
            $warmAt  | Should -BeLessThan $applyAt
        }
    }
    It 'takes the control-plane list from kubeadm rather than composing one' {
        # coredns, pause and etcd carry tags of their own, so any list built from
        # the Kubernetes version would miss exactly the images that arrive cold.
        foreach ($g in $script:guestPaths) {
            (Get-Content -LiteralPath $g -Raw) | Should -Match 'kubeadm config images list'
        }
    }
}

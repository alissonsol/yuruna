<#PSScriptInfo
.VERSION 2026.10.14
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

    Should assertions only, so the suite runs under Pester 5.x.
#>

BeforeAll {
$repoRoot   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$diagPath   = Join-Path $repoRoot 'automation/Get-SystemDiagnostic.ps1'
$seedPath   = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data'
$script:guestPaths = @(
    (Join-Path $repoRoot 'guest/shared/ubuntu.k8s.sh')
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
# The residency reader itself, lifted from the diagnostic so the behavior under
# test is the shipped one. Dot-sourcing the script would run a whole capture.
function Get-DiagFunctionText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name is used inside the FindAll predicate, which the analyzer does not follow.')]
    param([Parameter(Mandatory)][string]$Name)
    $found = @((Get-DiagAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $found) { return '' }
    return $found.Extent.Text
}
$script:ResidencyReader = (Get-DiagFunctionText -Name 'Get-PrometheusReading') + "`n" +
    (Get-DiagFunctionText -Name 'Get-PrometheusValue') + "`n" +
    (Get-DiagFunctionText -Name 'Get-RegistryResidencyShortfall')

# Keep the collection boundary identical to the report's foreach. An extra
# scriptblock output boundary can flatten an empty nested array and hide a
# false row before the assertion sees it.
$registryLoop = (Get-DiagAst).Find({ param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $node.Variable.VariablePath.UserPath -eq 'short'
}, $true)
$statements = @($registryLoop.Parent.Statements)
$loopIndex = [array]::IndexOf($statements, $registryLoop)
$setup = if ($loopIndex -gt 0 -and $statements[$loopIndex - 1] -is [System.Management.Automation.Language.AssignmentStatementAst]) {
    $statements[$loopIndex - 1].Extent.Text
} else { '' }
$script:ResidencyCollection = $setup + "`nforeach (`$short in $($registryLoop.Condition.Extent.Text)) { `$captured.Add(`$short) }"
# The report loop itself, so which problems a reading raises is observed.
$script:ResidencyReport = $setup + "`n" + $registryLoop.Extent.Text

# Drives the shipped reader over a published document.
function Get-ResidencyShortfall {
    param([string]$MetricText)
    $run = [scriptblock]::Create($script:ResidencyReader + @'

$reading = Get-PrometheusReading -Text $args[0]
$captured = [Collections.Generic.List[object]]::new()
'@ + "`n" + $script:ResidencyCollection + "`nreturn , @(`$captured.ToArray())")
    return , (& $run $MetricText)
}

# Runs the shipped report loop with the problem sink and the message lookup
# stubbed, and returns '<class>|<message key>' per problem raised.
function Get-ResidencyProblem {
    param([string]$MetricText)
    $run = [scriptblock]::Create($script:ResidencyReader + @'

function Format-YurunaOperatorMessage { param([string]$Key, $Arguments, $FormatValues, $FormatBindings) $Key }
$raised = [Collections.Generic.List[string]]::new()
function Add-Problem { param([string]$Message, [string]$Class) $raised.Add("$Class|$Message") }
$reading = Get-PrometheusReading -Text $args[0]
'@ + "`n" + $script:ResidencyReport + "`nreturn , @(`$raised.ToArray())")
    return , (& $run $MetricText)
}

# The metric names the diagnostic depends on, taken from the reader itself.
$script:ReadMetricName = @([regex]::Matches($script:ResidencyReader, "'(?<m>yuruna_[a-z_]+)'") |
    ForEach-Object { $_.Groups['m'].Value } | Sort-Object -Unique)

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
# The machine document the classification reads. Same readings as the page.
$script:warmMetrics = @'
# HELP yuruna_prewarm_state_available 1 if a warm run has recorded residency
# TYPE yuruna_prewarm_state_available gauge
yuruna_prewarm_state_available 1
yuruna_prewarm_images_total{set="k8s"} 7
yuruna_prewarm_images_resident{set="k8s"} 7
yuruna_prewarm_images_total{set="cni"} 2
yuruna_prewarm_images_resident{set="cni"} 2
'@
$script:coldMetrics = $script:warmMetrics -replace 'yuruna_prewarm_images_resident\{set="k8s"\} 7',
    'yuruna_prewarm_images_resident{set="k8s"} 3'
# The state a cache is in before its first warm run: totals published, counts
# absent rather than zero.
$script:unwarmedMetrics = $script:warmMetrics -replace 'yuruna_prewarm_state_available 1',
    'yuruna_prewarm_state_available 0'
# Per-image warm rows as every exporter publishes them; state "failed" is an
# HTTP error the cache answered with.
function Get-FailedRow {
    param([int]$Count)
    (1..$Count | ForEach-Object { "yuruna_prewarm_manifest_seconds{set=""k8s"",image=""registry.k8s.io/image$($_):v1"",state=""failed""} 0.1" }) -join "`n"
}
# Every control-plane image answered with an error, as a cache does that
# cannot store what its upstream serves -- read from an exporter that does
# not publish the statuses, and from one that does.
$script:refusedUnlabeledMetrics = ($script:warmMetrics -replace 'yuruna_prewarm_images_resident\{set="k8s"\} 7',
    'yuruna_prewarm_images_resident{set="k8s"} 0') + "`n" + (Get-FailedRow 7) + "`n"
$script:refusedMetrics = $script:refusedUnlabeledMetrics + "yuruna_prewarm_images_refused{set=""k8s"",status=""503""} 7`n"
# Three held, two refused under two statuses, two still to copy.
$script:mixedMetrics = $script:coldMetrics + "`n" + (Get-FailedRow 2) + "`nyuruna_prewarm_images_refused{set=""k8s"",status=""404""} 1`n" +
    "yuruna_prewarm_images_refused{set=""k8s"",status=""503""} 1`n"

}

Describe 'The published residency lines are the ones the diagnostic reads' {
    It 'lifts the shipped residency reader rather than restating it' {
        $script:ResidencyReader | Should -Not -BeNullOrEmpty
        $script:ResidencyReader | Should -Match 'function Get-RegistryResidencyShortfall'
    }
    It 'reads only metrics the cache actually publishes' {
        # The writer/reader agreement this suite exists for, now expressed
        # against the machine document: every reading the diagnostic depends on
        # has to be a series the seed emits, or the classification is asking
        # for something nobody writes and will always find nothing.
        $script:ReadMetricName.Count | Should -BeGreaterOrEqual 3
        foreach ($metric in $script:ReadMetricName) {
            $script:seedText | Should -Match ([regex]::Escape($metric))
        }
    }
    It 'classifies nothing from the health page' {
        # The page is written for a person during an incident. Its wording is
        # free to change and to be translated, so a check that recognized a
        # sentence there would go quiet on the day someone improved it.
        $diagText = Get-Content -LiteralPath $diagPath -Raw
        $diagText | Should -Not -Match '\$healthText\s+-c?match'
    }
    It 'reports nothing before the first warm run, when counts are absent not zero' {
        # The exporter says so itself: with state_available 0 the counts below
        # are absent. Reading them anyway reports a cache that has merely not
        # warmed yet as one missing every image a guest needs.
        (Get-ResidencyShortfall -MetricText $script:unwarmedMetrics).Count | Should -Be 0
    }
}

Describe 'A shortfall reaches the problems summary and a warm cache does not' {
    It 'reports nothing while every set is held' {
        (Get-ResidencyShortfall -MetricText $script:warmMetrics).Count | Should -Be 0
    }
    It 'reports the short set only, naming the count a guest would pay for' {
        $found = Get-ResidencyShortfall -MetricText $script:coldMetrics
        $found.Count | Should -Be 1
        $found[0] | Should -BeOfType [hashtable]
        $found[0].Set   | Should -Be 'k8s'
        $found[0].Held  | Should -Be 3
        $found[0].Total | Should -Be 7
    }
    It 'keeps reading later sets after a short one' {
        $both = $script:coldMetrics -replace 'yuruna_prewarm_images_resident\{set="cni"\} 2',
            'yuruna_prewarm_images_resident{set="cni"} 0'
        $found = Get-ResidencyShortfall -MetricText $both
        $found.Count | Should -Be 2
        @($found | Where-Object { $_ -isnot [hashtable] }).Count | Should -Be 0
        @($found | ForEach-Object { $_['Set'] } | Sort-Object) | Should -Be @('cni', 'k8s')
    }
}

Describe 'A refused image is reported as refused, not as a copy a guest waits on' {
    It 'counts the refusals of a set apart from the copies still owed' {
        $found = Get-ResidencyShortfall -MetricText $script:refusedMetrics
        $found.Count | Should -Be 1
        $found[0].Refused  | Should -Be 7
        $found[0].Copying  | Should -Be 0
        $found[0].Statuses | Should -Be '503'
    }
    It 'splits a set that is partly refused and partly still to copy' {
        $found = Get-ResidencyShortfall -MetricText $script:mixedMetrics
        $found[0].Held     | Should -Be 3
        $found[0].Refused  | Should -Be 2
        $found[0].Copying  | Should -Be 2
        $found[0].Statuses | Should -Be '404, 503'
    }
    It 'reads a cache that publishes no refusals as one that refused nothing' {
        $found = Get-ResidencyShortfall -MetricText $script:coldMetrics
        $found[0].Refused | Should -Be 0
        $found[0].Copying | Should -Be 4
    }
    It 'counts refusals from an exporter that does not publish their statuses' {
        # The per-image rows predate the status series, so a cache built from
        # an older seed still reads as refusing rather than as copying.
        $found = Get-ResidencyShortfall -MetricText $script:refusedUnlabeledMetrics
        $found[0].Refused  | Should -Be 7
        $found[0].Copying  | Should -Be 0
        $found[0].Statuses | Should -BeNullOrEmpty
        $raised = Get-ResidencyProblem -MetricText $script:refusedUnlabeledMetrics
        $raised.Count | Should -Be 1
        $raised[0] | Should -Be 'REGISTRY.image-set-refused|automation.system_diagnostic_registry_images_refused_status_unknown'
    }
    It 'raises only the refusal when nothing is left to copy' {
        $raised = Get-ResidencyProblem -MetricText $script:refusedMetrics
        $raised.Count | Should -Be 1
        $raised[0] | Should -Be 'REGISTRY.image-set-refused|automation.system_diagnostic_registry_images_refused'
    }
    It 'raises both when a set is short for both reasons' {
        $raised = Get-ResidencyProblem -MetricText $script:mixedMetrics
        $raised.Count | Should -Be 2
        $raised[0] | Should -Be 'REGISTRY.image-set-refused|automation.system_diagnostic_registry_images_refused'
        $raised[1] | Should -Be 'REGISTRY.image-set-incomplete|automation.operator_5376c9efd7b38f35'
    }
    It 'raises only the copy wait when nothing was refused' {
        $raised = Get-ResidencyProblem -MetricText $script:coldMetrics
        $raised.Count | Should -Be 1
        $raised[0] | Should -Be 'REGISTRY.image-set-incomplete|automation.operator_5376c9efd7b38f35'
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
    It 'a bare cast would have produced digits, which no reading survives' {
        # Pins why the branch exists: the failure mode is a readable-looking
        # document of numbers, not an error. The metric document decodes the
        # same way the page does, and a cast instead of a decode leaves the
        # classification silent on a cache that has something to report.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:coldMetrics)
        $naive = [string]$bytes
        (Get-ResidencyShortfall -MetricText $naive).Count | Should -Be 0
        (Get-ResidencyShortfall -MetricText ([System.Text.Encoding]::UTF8.GetString($bytes))).Count |
            Should -Be 1
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
        # One request line serves the tag and then the guest's platform child.
        foreach ($g in $script:guestPaths) {
            (Get-Content -LiteralPath $g -Raw) |
                Should -Match '/manifests/\$\{_wr_reference\}\?ns=\$\{_wr_upstream\}'
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

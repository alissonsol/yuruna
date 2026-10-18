<#PSScriptInfo
.VERSION 2026.10.18
.GUID 4230f2fc-1a17-4a20-b766-368eff24c01c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache registry zot sync pester
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
    Guards what the cache's registry does with the images the lab pulls: it
    stores Docker manifest lists, warms the platforms guests run, and reports
    a refusal as a refusal.
.DESCRIPTION
    zot 2.1.22 and later refuse to sync a Docker manifest unless http.compat
    lists docker2s2. registry.k8s.io and mcr.microsoft.com serve Docker
    manifest lists, so a config without it answers HTTP 503 for every
    control-plane image while GET /v2/ answers and `zot verify` accepts the
    file. Only the config itself shows the gap, so it is read here.

    On-demand sync stores a multi-arch tag as its index alone and copies a
    platform's manifest and layers only when that child is asked for by
    digest. A warm run that asks only for tags holds no layers while the
    health page reports the set resident.

    A refusal is the cache's answer, not a copy in progress. Describing it as a
    slow or cold cache that a re-run will warm sends the reader after latency
    instead of the cause.

    The shipped scripts are lifted out of the seed and the guest scripts and
    run under bash with curl stubbed, so what is observed is the shipped
    behavior. Should assertions only, so the suite runs under Pester 5.x.
#>

BeforeDiscovery {
    $script:CanRunBash = -not $IsWindows -and $null -ne (Get-Command bash -CommandType Application -ErrorAction SilentlyContinue)
    $script:CanRunJq = $script:CanRunBash -and $null -ne (Get-Command jq -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$script:seedLines = Get-Content -LiteralPath (Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data')
$script:guestPaths = @(
    (Join-Path $repoRoot 'guest/shared/ubuntu.k8s.sh')
)

# The body of one write_files entry. The seed writes each as "  - path: <p>",
# then "    content: |", then the body indented six spaces; the body ends at
# the first non-empty line indented less.
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

# Runs a bash script in a scratch directory whose bin/ shadows curl (and any
# command named in -Stubs), and returns its combined output and exit code.
# @TMP@ in the script and the stubs stands for that directory.
function Invoke-StubbedBash {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$CurlStub,
        [hashtable]$Environment = @{},
        [hashtable]$Files = @{},
        [hashtable]$Stubs = @{}
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path (Join-Path $tmp 'bin') -Force | Out-Null
    try {
        foreach ($name in $Files.Keys) {
            $target = Join-Path $tmp $name
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Set-Content -LiteralPath $target -Value $Files[$name].Replace('@TMP@', $tmp) -NoNewline
        }
        $Stubs['curl'] = $CurlStub
        foreach ($name in $Stubs.Keys) {
            $stub = Join-Path $tmp "bin/$name"
            Set-Content -LiteralPath $stub -Value $Stubs[$name].Replace('@TMP@', $tmp) -NoNewline
            & chmod +x $stub
        }
        $exports = ($Environment.Keys | ForEach-Object { "export $_='$($Environment[$_])'" }) -join "`n"
        $runner = Join-Path $tmp 'run.sh'
        Set-Content -LiteralPath $runner -Value ("#!/bin/bash`nexport PATH='$tmp/bin':`"`$PATH`"`n$exports`n" + $Script.Replace('@TMP@', $tmp)) -NoNewline
        $output = (& bash $runner 2>&1) -join "`n"
        $exitCode = $LASTEXITCODE
        $state = @{}
        foreach ($leaf in @('rows', 'curl.log', 'www/cache-health', 'www/zot-meta')) {
            $p = Join-Path $tmp $leaf
            $state[$leaf] = if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw } else { '' }
        }
        return [pscustomobject]@{ Output = $output; ExitCode = $exitCode; Rows = $state['rows']; CurlLog = $state['curl.log']
            Page = $state['www/cache-health']; Meta = $state['www/zot-meta'] }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- REGION: The warm run's own function, with its settings
$prewarm = (Get-SeedFileBody -Path '/usr/local/bin/zot-prewarm.sh') -split "`n"
$settings = @($prewarm | Where-Object { $_ -match '^(ACCEPT|PREWARM_MAX|COLD_FLOOR|WARM_PLATFORMS)=' })
$start = [array]::IndexOf($prewarm, 'warm_one() {')
if ($start -lt 0) { throw 'The prewarm script defines no warm_one function.' }
$end = $start
while ($end -lt $prewarm.Count -and $prewarm[$end] -ne '}') { $end++ }
$script:warmOne = ($settings + $prewarm[$start..$end]) -join "`n"

$script:childDigest = @{ amd64 = 'sha256:' + ('a' * 64); arm64 = 'sha256:' + ('b' * 64); s390x = 'sha256:' + ('c' * 64); attestation = 'sha256:' + ('d' * 64) }
$script:indexFixture = @{
    schemaVersion = 2
    mediaType     = 'application/vnd.docker.distribution.manifest.list.v2+json'
    manifests     = @(
        @{ mediaType = 'application/vnd.docker.distribution.manifest.v2+json'; digest = $script:childDigest.amd64; size = 1; platform = @{ os = 'linux'; architecture = 'amd64' } }
        @{ mediaType = 'application/vnd.docker.distribution.manifest.v2+json'; digest = $script:childDigest.arm64; size = 1; platform = @{ os = 'linux'; architecture = 'arm64'; variant = 'v8' } }
        @{ mediaType = 'application/vnd.docker.distribution.manifest.v2+json'; digest = $script:childDigest.s390x; size = 1; platform = @{ os = 'linux'; architecture = 's390x' } }
        @{ mediaType = 'application/vnd.oci.image.manifest.v1+json'; digest = $script:childDigest.attestation; size = 1; platform = @{ os = 'unknown'; architecture = 'unknown' } }
    )
} | ConvertTo-Json -Depth 5

# Answers the tag with the fixture index and every child with CHILD_CODE,
# logging each URL it was asked for.
$script:registryStub = @'
#!/bin/bash
out=/dev/null; url=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -m|-H|-w|--noproxy) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >> '@TMP@/curl.log'
case "$url" in
    */manifests/sha256:*) code=$CHILD_CODE ;;
    *) code=$INDEX_CODE; [ "$code" = 200 ] && cp '@TMP@/index.json' "$out" ;;
esac
printf '%s' "$code"
'@

function Invoke-WarmOne {
    param([string]$IndexCode = '200', [string]$ChildCode = '200', [string[]]$Held = @())
    $files = @{ 'index.json' = $script:indexFixture }
    foreach ($digest in $Held) { $files["zot/pause/blobs/sha256/$($digest.Substring(7))"] = '{}' }
    $body = @"
ZOT='http://127.0.0.1:5000'
ZOT_ROOT='@TMP@/zot'
BODY_TMP='@TMP@/body'
ROWS_TMP='@TMP@/rows'
PROGRESS_FILE='@TMP@/progress'
$($script:warmOne)
warm_one k8s registry.k8s.io/pause:3.10.2
"@
    return Invoke-StubbedBash -Script $body -CurlStub $script:registryStub -Files $files `
        -Environment @{ INDEX_CODE = $IndexCode; CHILD_CODE = $ChildCode }
}

# --- REGION: The exporter, redirected into a scratch root
$script:exporter = (Get-SeedFileBody -Path '/usr/local/bin/zot-meta-exporter.sh').
    Replace('/var/www/html/', '@TMP@/www/').
    Replace('/var/lib/yuruna/', '@TMP@/state/').
    Replace('/etc/zot/sync-credentials.json', '@TMP@/no-credentials.json')

# Every manifest request answers MANIFEST_CODE after MANIFEST_SECONDS; every
# /v2/ answers; the Docker Hub budget probe is left unreadable.
$script:exporterStub = @'
#!/bin/bash
fmt=; url=
while [ $# -gt 0 ]; do
    case "$1" in
        -w) fmt=$2; shift 2 ;;
        -o|-m|-H|--noproxy|--netrc-file) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
case "$url" in
    */v2/) code=200 ;;
    */manifests/*) code=$MANIFEST_CODE ;;
    *) exit 22 ;;
esac
[ -n "$fmt" ] && printf '%s' "$fmt" | sed -e "s/%{http_code}/$code/" -e "s/%{time_total}/$MANIFEST_SECONDS/"
exit 0
'@

function Invoke-Exporter {
    param([string]$ManifestCode, [string]$ManifestSeconds, [string[]]$Rows, [hashtable]$SelfTest)
    $files = @{ 'www/.keep' = '' }
    if ($Rows) { $files['state/prewarm-rows.tsv'] = ($Rows -join "`n") + "`n" }
    if ($SelfTest) {
        $files['state/zot-selftest.prom'] = $SelfTest.Prom
        $files['state/zot-selftest.txt'] = $SelfTest.Text
    }
    return Invoke-StubbedBash -Script $script:exporter -CurlStub $script:exporterStub -Files $files `
        -Environment @{ MANIFEST_CODE = $ManifestCode; MANIFEST_SECONDS = $ManifestSeconds }
}
$script:k8sRefs = @('kube-apiserver:v1.37.1', 'kube-controller-manager:v1.37.1', 'kube-scheduler:v1.37.1',
    'kube-proxy:v1.37.1', 'coredns/coredns:v1.14.6', 'pause:3.10.2', 'etcd:3.7.0-0')
$script:cniRows = @("cni`tghcr.io/flannel-io/flannel-cni-plugin:v1.9.1-flannel3`t200`t0.050`tresident",
    "cni`tghcr.io/flannel-io/flannel:v0.28.10`t200`t0.050`tresident")

# --- REGION: The guest's warm pass and its verdict
function Get-GuestWarmPass {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    $from = $text.IndexOf('YURUNA_IMAGE_WARM_BUDGET=')
    $to = $text.IndexOf('sudo kubeadm config images pull')
    if ($from -lt 0 -or $to -lt $from) { throw "No warm pass in $Path." }
    return $text.Substring($from, $to - $from).Replace('sudo kubeadm config images list 2>/dev/null || true',
        "printf '%s\n' registry.k8s.io/kube-apiserver:v1.37.1 registry.k8s.io/pause:3.10.2 registry.k8s.io/etcd:3.7.0-0")
}
$script:guestStub = "#!/bin/bash`nprintf '%s' `"`$STUB_CODE`"`nexit `"`$STUB_RC`"`n"

function Invoke-GuestWarmPass {
    param([string]$Path, [string]$Code, [string]$CurlExit)
    $body = "set -euo pipefail`nCACHE_HOST=cache.invalid`n" + (Get-GuestWarmPass -Path $Path)
    return Invoke-StubbedBash -Script $body -CurlStub $script:guestStub `
        -Environment @{ STUB_CODE = $Code; STUB_RC = $CurlExit; YURUNA_IMAGE_WARM_ATTEMPTS = '1' }
}

# A registry that answers each tag with -IndexBody and each digest with
# CHILD_CODE, logging every URL; dpkg names the guest's architecture.
$script:guestRegistryStub = @'
#!/bin/bash
out=/dev/null; url=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        --max-time|-w|-H) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >> '@TMP@/curl.log'
case "$url" in
    */manifests/sha256:*) printf '%s' "$CHILD_CODE" ;;
    *) cp '@TMP@/index.json' "$out"; printf '200' ;;
esac
'@

function Invoke-GuestPlatformWarm {
    param([string]$Path, [string]$Arch, [string]$ChildCode = '200', [string]$IndexBody = $script:indexFixture)
    $body = "set -euo pipefail`nCACHE_HOST=cache.invalid`n" + (Get-GuestWarmPass -Path $Path)
    return Invoke-StubbedBash -Script $body -CurlStub $script:guestRegistryStub -Files @{ 'index.json' = $IndexBody } `
        -Stubs @{ dpkg = "#!/bin/sh`necho $Arch`n" } -Environment @{ CHILD_CODE = $ChildCode; YURUNA_IMAGE_WARM_ATTEMPTS = '1' }
}

# --- REGION: The diagnostic's own residency reader
$diagnosticAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'automation/Get-SystemDiagnostic.ps1'), [ref]$null, [ref]$null)
$script:residencyReader = (@('Get-PrometheusReading', 'Get-PrometheusValue', 'Get-RegistryResidencyShortfall') | ForEach-Object {
    $name = $_
    $diagnosticAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true).Extent.Text
}) -join "`n"

function Get-DiagnosticShortfall {
    param([string]$MetricText)
    # The reader returns its array comma-wrapped already; wrapping it again
    # would hand back an array whose one element is that array.
    $run = [scriptblock]::Create($script:residencyReader + "`nreturn , (Get-RegistryResidencyShortfall -Reading (Get-PrometheusReading -Text `$args[0]))")
    return , (& $run $MetricText)
}

# The diagnostic's zot verdict reader, with the message lookup stubbed to
# '<key>|<argument>=<value>;...' so a test sees which message and what it names.
$script:zotProblemReader = (@('Get-PrometheusReading', 'Get-PrometheusValue', 'Get-ZotSelfTestProblem') | ForEach-Object {
    $name = $_
    $diagnosticAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true).Extent.Text
}) -join "`n"
function Get-DiagnosticZotProblem {
    param([string]$MetricText)
    $run = [scriptblock]::Create($script:zotProblemReader + @'

function Format-YurunaOperatorMessage {
    param([string]$Key, [hashtable]$Arguments)
    "$Key|" + (($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" }) -join ';')
}
return , (Get-ZotSelfTestProblem -Reading (Get-PrometheusReading -Text $args[0]) -HealthUrl 'http://192.0.2.7/cache-health')
'@)
    return , (& $run $MetricText)
}
# The series zot-sync-selftest.py writes, as the exporter passes them on.
$script:selfTestProm = @{
    incompatible = "yuruna_zot_selftest_available 1`nyuruna_zot_selftest_ok 0`nyuruna_zot_selftest_verdict{verdict=`"incompatible`"} 1`n" +
        "yuruna_zot_selftest_release_info{version=`"v2.1.23`",pinned=`"v2.1.23`",override=`"0`"} 1`n" +
        "yuruna_zot_selftest_probe_failed{image=`"registry.k8s.io/pause:3.10.2`",stage=`"tag`",status=`"503`",outcome=`"rejected`",compat=`"docker2s2`"} 1`n" +
        "yuruna_zot_selftest_probe_failed{image=`"mcr.microsoft.com/dotnet/runtime-deps:10.0`",stage=`"tag`",status=`"503`",outcome=`"rejected`",compat=`"docker2s2`"} 1`n" +
        "yuruna_zot_selftest_probe_failed{image=`"quay.io/x:1`",stage=`"tag`",status=`"0`",outcome=`"unanswered`",compat=`"`"} 1`n"
    unexplained = "yuruna_zot_selftest_available 1`nyuruna_zot_selftest_ok 0`nyuruna_zot_selftest_verdict{verdict=`"incompatible`"} 1`n" +
        "yuruna_zot_selftest_release_info{version=`"v2.1.23`",pinned=`"v2.1.22`",override=`"1`"} 1`n" +
        "yuruna_zot_selftest_probe_failed{image=`"ghcr.io/flannel-io/flannel:v0.28.10`",stage=`"config blob`",status=`"500`",outcome=`"rejected`",compat=`"`"} 1`n"
    repaired = "yuruna_zot_selftest_available 1`nyuruna_zot_selftest_ok 1`nyuruna_zot_selftest_verdict{verdict=`"healed`"} 1`n" +
        "yuruna_zot_selftest_release_info{version=`"v2.1.23`",pinned=`"v2.1.23`",override=`"0`"} 1`n" +
        "yuruna_zot_selftest_compat_added{mode=`"docker2s2`"} 1`n"
    ok = "yuruna_zot_selftest_available 1`nyuruna_zot_selftest_ok 1`nyuruna_zot_selftest_verdict{verdict=`"ok`"} 1`n"
    unanswered = "yuruna_zot_selftest_available 1`nyuruna_zot_selftest_ok 0`nyuruna_zot_selftest_verdict{verdict=`"unanswered`"} 1`n"
}
}

Describe 'The registry can store the Docker manifests the lab pulls' {
    It 'enables the docker2s2 compatibility mode' {
        # Without it zot 2.1.22 and later refuse every Docker manifest list,
        # which is what registry.k8s.io serves for each control-plane image.
        $config = Get-SeedFileBody -Path '/etc/zot/config.json' | ConvertFrom-Json
        @($config.http.compat) | Should -Contain 'docker2s2'
    }
    It 'routes sparse images on demand and warms catalog-free upstreams without polling them' {
        # Periodic sync begins with /v2/_catalog. mirror.gcr.io deliberately
        # returns 405 there, so its one fixed image belongs in the direct warm
        # set while the registry table keeps only its on-demand route.
        $config = Get-SeedFileBody -Path '/etc/zot/config.json' | ConvertFrom-Json
        $k8s = @($config.extensions.sync.registries | Where-Object { $_.urls -contains 'https://registry.k8s.io' })
        $k8s.Count | Should -Be 1
        $k8s[0].onDemand | Should -BeTrue

        $mirror = @($config.extensions.sync.registries | Where-Object { $_.urls -contains 'https://mirror.gcr.io' })
        $mirror.Count | Should -Be 1
        $mirror[0].onDemand | Should -BeTrue
        $mirror[0].PSObject.Properties.Name | Should -Not -Contain 'pollInterval'
        @($mirror[0].content).prefix | Should -Contain 'library/**'

        $prewarm = Get-SeedFileBody -Path '/usr/local/bin/zot-prewarm.sh'
        $prewarm | Should -Match "(?m)^WORKLOAD_REFS='mirror\.gcr\.io/library/registry:2'$"
        $prewarm | Should -Match '(?m)^for r in \$WORKLOAD_REFS; do warm_one workload "\$r"; done$'
    }
}

Describe 'A warm run holds the platforms guests run, not only the index' -Skip:(-not $script:CanRunJq) {
    It 'asks for the tag, then for each guest platform child by digest, with ns=' {
        $run = Invoke-WarmOne
        $asked = @($run.CurlLog -split "`n" | Where-Object { $_ })
        $asked | Should -Be @(
            'http://127.0.0.1:5000/v2/pause/manifests/3.10.2?ns=registry.k8s.io'
            "http://127.0.0.1:5000/v2/pause/manifests/$($script:childDigest.amd64)?ns=registry.k8s.io"
            "http://127.0.0.1:5000/v2/pause/manifests/$($script:childDigest.arm64)?ns=registry.k8s.io"
        )
    }
    It 'counts an image whose children were already held as resident' {
        $run = Invoke-WarmOne -Held @($script:childDigest.amd64, $script:childDigest.arm64)
        ($run.Rows -split "`t")[4].Trim() | Should -Be 'resident'
    }
    It 'counts a child this run had to copy as cold, however quick the copy was' {
        $run = Invoke-WarmOne -Held @($script:childDigest.amd64)
        $row = $run.Rows -split "`t"
        $row[2] | Should -Be '200'
        $row[4].Trim() | Should -Be 'cold'
    }
    It 'records a refused child with its status and stops asking' {
        $run = Invoke-WarmOne -ChildCode '503'
        $row = $run.Rows -split "`t"
        $row[2] | Should -Be '503'
        $row[4].Trim() | Should -Be 'failed'
        @($run.CurlLog -split "`n" | Where-Object { $_ }).Count | Should -Be 2
    }
    It 'records a refused tag without asking for any child' {
        $run = Invoke-WarmOne -IndexCode '503'
        ($run.Rows -split "`t")[4].Trim() | Should -Be 'failed'
        @($run.CurlLog -split "`n" | Where-Object { $_ }).Count | Should -Be 1
    }
}

Describe 'The health page reports a refusal as a refusal' -Skip:(-not $script:CanRunBash) {
    It 'names an error status as a refusal rather than a missed deadline' {
        $run = Invoke-Exporter -ManifestCode '503' -ManifestSeconds '0.150'
        $run.ExitCode | Should -Be 0
        $run.Page | Should -Match 'resident-tag revalidation: FAILING -- refused with HTTP 503'
        $run.Page | Should -Not -Match 'revalidation: FAILING -- a pull gives up after'
    }
    It 'still blames the deadline for an answer that came too late' {
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '55.000'
        $run.Page | Should -Match 'resident-tag revalidation: FAILING -- a pull gives up after 30s'
    }
    It 'lists refused warm-set images apart from the cold shortfall' {
        $rows = @("workload`tmirror.gcr.io/library/registry:2`t200`t0.050`tresident") +
            @($script:k8sRefs | ForEach-Object { "k8s`tregistry.k8s.io/$_`t503`t0.100`tfailed" }) + $script:cniRows
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.050' -Rows $rows
        $run.Page | Should -Match '(?m)^  Workload support image set \(mirror\.gcr\.io/library/registry:2\):$'
        $run.Page | Should -Match '(?m)^    resident {17}: 1 of 1 held$'
        $run.Page | Should -Match '(?m)^    resident {17}: 0 of 7 held$'
        $run.Page | Should -Match '(?m)^      refused \(HTTP 503\) {5}: 7   <-- a kubeadm init gets the same refusal$'
        $run.Page | Should -Not -Match 'a kubeadm init pays'
        $run.Page | Should -Match 'A refused image is not being copied'
    }
    It 'still prices an image that timed out as a cold sync' {
        $rows = @($script:k8sRefs | Select-Object -First 2 | ForEach-Object { "k8s`tregistry.k8s.io/$_`t000`t900.000`ttimeout" }) +
            @($script:k8sRefs | Select-Object -Skip 2 | ForEach-Object { "k8s`tregistry.k8s.io/$_`t200`t0.100`tresident" }) + $script:cniRows
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.050' -Rows $rows
        $run.Page | Should -Match 'resident {17}: 5 of 7 held   <-- a kubeadm init pays 2 cold sync\(s\)'
        $run.Page | Should -Not -Match 'refused'
    }
}

Describe 'The cache publishes its refusals for the diagnostic to read' -Skip:(-not $script:CanRunBash) {
    It 'publishes one series per set and status' {
        $rows = @("workload`tmirror.gcr.io/library/registry:2`t405`t0.100`tfailed") +
            @($script:k8sRefs | ForEach-Object { "k8s`tregistry.k8s.io/$_`t503`t0.100`tfailed" }) + $script:cniRows
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.050' -Rows $rows
        $run.Meta | Should -Match '(?m)^yuruna_prewarm_images_total\{set="workload"\} 1$'
        $run.Meta | Should -Match '(?m)^yuruna_prewarm_images_resident\{set="workload"\} 0$'
        $run.Meta | Should -Match '(?m)^yuruna_prewarm_images_refused\{set="workload",status="405"\} 1$'
        $run.Meta | Should -Match '(?m)^yuruna_prewarm_images_refused\{set="k8s",status="503"\} 7$'
        $run.Meta | Should -Not -Match '(?m)^yuruna_prewarm_images_refused\{set="cni"'
    }
    It 'publishes no refusal series when nothing was refused' {
        $rows = @($script:k8sRefs | ForEach-Object { "k8s`tregistry.k8s.io/$_`t200`t0.100`tresident" }) + $script:cniRows
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.050' -Rows $rows
        $run.Meta | Should -Match '(?m)^# TYPE yuruna_prewarm_images_refused gauge$'
        $run.Meta | Should -Not -Match '(?m)^yuruna_prewarm_images_refused\{'
    }
    It 'gives the diagnostic a refusal it reports as one, not as a copy' {
        # The exporter's document read by the diagnostic's shipped reader.
        $rows = @($script:k8sRefs | ForEach-Object { "k8s`tregistry.k8s.io/$_`t503`t0.100`tfailed" }) + $script:cniRows
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.050' -Rows $rows
        $found = Get-DiagnosticShortfall -MetricText $run.Meta
        $found.Count | Should -Be 1
        $found[0].Set | Should -Be 'k8s'
        $found[0].Refused | Should -Be 7
        $found[0].Copying | Should -Be 0
        $found[0].Statuses | Should -Be '503'
    }
}

Describe 'A guest warms its own platform, not only the index' -Skip:(-not ($script:CanRunBash -and $null -ne (Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue))) {
    It 'asks for its platform child after each tag, by digest and with ns=' {
        foreach ($path in $script:guestPaths) {
            $run = Invoke-GuestPlatformWarm -Path $path -Arch 'arm64'
            $run.ExitCode | Should -Be 0 -Because $path
            $asked = @($run.CurlLog -split "`n" | Where-Object { $_ })
            $asked.Count | Should -Be 6 -Because $path
            $asked[0] | Should -Be 'http://cache.invalid:5000/v2/kube-apiserver/manifests/v1.37.1?ns=registry.k8s.io'
            $asked[1] | Should -Be "http://cache.invalid:5000/v2/kube-apiserver/manifests/$($script:childDigest.arm64)?ns=registry.k8s.io"
            ($asked -join "`n") | Should -Not -Match ([regex]::Escape($script:childDigest.amd64)) -Because 'an arm64 guest pulls no amd64 layers'
        }
    }
    It 'names the platform manifest the cache refused' {
        foreach ($path in $script:guestPaths) {
            $run = Invoke-GuestPlatformWarm -Path $path -Arch 'amd64' -ChildCode '503'
            $run.ExitCode | Should -Be 1 -Because $path
            $run.Output | Should -Match 'NOT CACHED -- linux/amd64 manifest HTTP 503' -Because $path
            $run.Output | Should -Match 'the cache refused 3 of 3 control-plane images' -Because $path
        }
    }
    It 'asks once for an image published for one platform only' {
        $single = '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"digest":"sha256:' + ('e' * 64) + '"},"layers":[]}'
        foreach ($path in $script:guestPaths) {
            $run = Invoke-GuestPlatformWarm -Path $path -Arch 'amd64' -IndexBody $single
            $run.ExitCode | Should -Be 0 -Because $path
            @($run.CurlLog -split "`n" | Where-Object { $_ }).Count | Should -Be 3 -Because $path
        }
    }
}

Describe 'A guest reports a refused control plane as refused' -Skip:(-not $script:CanRunBash) {
    It 'names the refusal and promises no warm re-run' {
        foreach ($path in $script:guestPaths) {
            $run = Invoke-GuestWarmPass -Path $path -Code '503' -CurlExit '0'
            $run.ExitCode | Should -Be 1 -Because $path
            $run.Output | Should -Match 'the cache refused 3 of 3 control-plane images' -Because $path
            $run.Output | Should -Match 'A refused image is not an interrupted copy' -Because $path
            $run.Output | Should -Not -Match 'so a re-run lands warm' -Because $path
        }
    }
    It 'keeps the warm re-run promise for a request that got no answer' {
        foreach ($path in $script:guestPaths) {
            $run = Invoke-GuestWarmPass -Path $path -Code '000' -CurlExit '28'
            $run.ExitCode | Should -Be 1 -Because $path
            $run.Output | Should -Match 'the cache was not reached' -Because $path
            $run.Output | Should -Match 'so a re-run lands warm' -Because $path
        }
    }
    It 'passes a control plane the cache answered' {
        foreach ($path in $script:guestPaths) {
            $run = Invoke-GuestWarmPass -Path $path -Code '200' -CurlExit '0'
            $run.ExitCode | Should -Be 0 -Because $path
            $run.Output | Should -Match '== control-plane: 3 of 3 images cached ==' -Because $path
        }
    }
    It "shows the cache's verdict on its own zot release, and its fixes, next to the refusal" {
        $stub = "#!/bin/bash`nfor a in `"`$@`"; do case `"`$a`" in */cache-health) cat '@TMP@/cache-health'; exit 0 ;; esac; done`n" +
            "printf '%s' `"`$STUB_CODE`"`nexit `"`$STUB_RC`"`n"
        $page = "zot /v2/ liveness            : up`n" +
            "zot sync self-test           : INCOMPATIBLE -- zot v9.9.9 refused 2 of 4 probe images`n" +
            "  registry.k8s.io/pause:3.10.2: HTTP 503 for the tag; zot's log: docker media type requires http.compat docker2s2`n" +
            "    1. Let the self-test add what zot asks for, restart zot, and test again:`n`n" +
            "Docker Hub budget            : 100 of 100 left`n"
        foreach ($path in $script:guestPaths) {
            $body = "set -euo pipefail`nCACHE_HOST=cache.invalid`n" + (Get-GuestWarmPass -Path $path)
            $run = Invoke-StubbedBash -Script $body -CurlStub $stub -Files @{ 'cache-health' = $page } `
                -Environment @{ STUB_CODE = '503'; STUB_RC = '0'; YURUNA_IMAGE_WARM_ATTEMPTS = '1' }
            $run.ExitCode | Should -Be 1 -Because $path
            $run.Output | Should -Match "The cache's own verdict on its zot release" -Because $path
            $run.Output | Should -Match 'zot sync self-test\s+: INCOMPATIBLE -- zot v9\.9\.9' -Because $path
            $run.Output | Should -Match 'requires http\.compat docker2s2' -Because $path
            $run.Output | Should -Match 'Let the self-test add what zot asks for' -Because $path
            $run.Output | Should -Not -Match 'Docker Hub budget' -Because $path
        }
    }
}

Describe 'The cache publishes its zot sync self-test' -Skip:(-not $script:CanRunBash) {
    It 'puts the verdict right under liveness on the health page, and its series in zot-meta' {
        $prom = "# HELP yuruna_zot_selftest_available x`nyuruna_zot_selftest_available 1`nyuruna_zot_selftest_ok 0`n" +
            "yuruna_zot_selftest_probe_failed{image=`"registry.k8s.io/pause:3.10.2`",stage=`"tag`",status=`"503`",outcome=`"rejected`",compat=`"docker2s2`"} 1`n"
        $text = "zot sync self-test           : INCOMPATIBLE -- zot v9.9.9 refused 1 of 4 probe images`n  sudo /usr/local/bin/zot-sync-selftest.py --heal`n"
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.100' -SelfTest @{ Prom = $prom; Text = $text }
        $run.Meta | Should -Match '(?m)^yuruna_zot_selftest_ok 0$'
        $run.Meta | Should -Match 'compat="docker2s2"'
        $page = @($run.Page -split "`n")
        $liveness = [array]::IndexOf(@($page | ForEach-Object { $_ -match '^zot /v2/ liveness' }), $true)
        $page[$liveness + 1] | Should -Match '^zot sync self-test\s+: INCOMPATIBLE'
        $page[$liveness + 2] | Should -Match 'zot-sync-selftest\.py --heal'
    }
    It 'says the self-test has not run yet when it has no result' {
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.100'
        $run.Meta | Should -Match '(?m)^yuruna_zot_selftest_available 0$'
        $run.Page | Should -Match 'zot sync self-test\s+: not run yet'
    }
}

Describe 'The sync self-test names an incompatible zot release and how to fix it' {
    It 'passes its suite against a stand-in registry, and the record qualifies the seed' {
        # A candidate must answer --version: the Windows Store alias for python3
        # resolves as an application yet exits 9009 without running anything.
        $python = @('python3', 'python') | ForEach-Object {
                Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue
            } | Where-Object {
                $version = & $_.Source --version 2>&1
                $LASTEXITCODE -eq 0 -and "$version" -match '^Python 3\.([89]|1\d)'
            } | Select-Object -First 1
        if (-not $python) { Set-ItResult -Skipped -Because 'Python 3.8 or newer is unavailable on this host.'; return }
        $suite = Join-Path $repoRoot 'host/vmconfig/tests/test_zot_selftest.py'
        $output = (& $python.Source $suite -v 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'Ran 13 tests'
    }
}

Describe 'The diagnostic names an incompatible zot release, and the fixes, in its problems summary' -Skip:(-not $script:CanRunBash) {
    It 'reads the verdict the exporter passes on, and names the release, the image and the mode zot asks for' {
        $run = Invoke-Exporter -ManifestCode '200' -ManifestSeconds '0.050' -SelfTest @{ Prom = $script:selfTestProm.incompatible; Text = '' }
        $found = Get-DiagnosticZotProblem -MetricText $run.Meta
        $found.Count | Should -Be 1
        $found[0].Class | Should -Be 'REGISTRY.zot-incompatible'
        $found[0].Message | Should -Be ('automation.system_diagnostic_registry_zot_incompatible|healthUrl=http://192.0.2.7/cache-health;' +
            'image=registry.k8s.io/pause:3.10.2;modes=docker2s2;refused=2;status=503;version=v2.1.23')
    }
    It 'falls back to the health page when zot named no mode' {
        $found = Get-DiagnosticZotProblem -MetricText $script:selfTestProm.unexplained
        $found[0].Class | Should -Be 'REGISTRY.zot-incompatible'
        $found[0].Message | Should -BeLike 'automation.system_diagnostic_registry_zot_incompatible_unexplained|*image=ghcr.io/flannel-io/flannel:v0.28.10;refused=1;status=500;version=v2.1.23'
    }
    It 'reports a repaired configuration so a release ships the mode' {
        $found = Get-DiagnosticZotProblem -MetricText $script:selfTestProm.repaired
        $found[0].Class | Should -Be 'REGISTRY.zot-compat-repaired'
        $found[0].Message | Should -BeLike '*modes=docker2s2;version=v2.1.23'
    }
    It 'raises nothing for a release that syncs, a run without a verdict, or a cache without the self-test' {
        foreach ($text in @($script:selfTestProm.ok, $script:selfTestProm.unanswered, 'yuruna_zot_selftest_available 0', '')) {
            $found = Get-DiagnosticZotProblem -MetricText $text
            $found.Count | Should -Be 0
        }
    }
    It 'tells the reader every fix that needs no code change, in English and in each supported locale' {
        $catalogs = Join-Path $repoRoot 'globalization/catalogs'
        $english = (Get-Content -Raw (Join-Path $catalogs 'en-US/automation.json') | ConvertFrom-Json -AsHashtable).messages
        foreach ($key in 'automation.system_diagnostic_registry_zot_incompatible', 'automation.system_diagnostic_registry_zot_incompatible_unexplained') {
            $message = $english[$key].message
            foreach ($fix in 'zot-sync-selftest.py', 'vmStart.cachingProxyZotVersion', 'vmStart.cachingProxyZotSha256', 'test/test.config.yml', 'Yuruna') {
                $message | Should -Match ([regex]::Escape($fix)) -Because "$key names that fix"
            }
            foreach ($locale in 'pt-BR', 'he-IL', 'zh-CN') {
                $translated = (Get-Content -Raw (Join-Path $catalogs "$locale/automation.json") | ConvertFrom-Json -AsHashtable).messages[$key].message
                foreach ($literal in 'zot-sync-selftest.py', 'vmStart.cachingProxyZotVersion', 'vmStart.cachingProxyZotSha256', '{healthUrl}') {
                    $translated | Should -Match ([regex]::Escape($literal)) -Because "the $locale text keeps what the operator types"
                }
            }
        }
        $english['automation.system_diagnostic_registry_zot_incompatible'].message | Should -Match '--heal'
    }
}

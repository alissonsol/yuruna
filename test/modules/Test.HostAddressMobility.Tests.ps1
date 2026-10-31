<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42f363d0-c7d5-4dcc-941a-c4422523b7e4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host address dhcp locate beacon pester
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

# A missing Pester turns every Describe into CommandNotFoundException, the
# engine keeps going, and the file exits 0 -- a harness shelling this out then
# records a PASS for a suite that asserted nothing. Say so in the exit code.
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    The host-address mobility chain: the guest resolver's ordering and safety
    gates, the host beacon's state machine, and the coordinate names the two
    ends agree on.
.DESCRIPTION
    WHY THIS EXISTS. Under DHCP the host's address is the one coordinate that
    rots, and every guest was provisioned with a copy of it. The repair path
    crosses four languages and three platforms -- a shell library, a
    PowerShell peer, a Go route, and five cloud-init seeds -- so the couplings
    that matter are exactly the ones no single file can enforce:

      * The resolver must PROBE before it asks. That ordering is what makes
        the call affordable in front of every fetch; lose it and every guest
        pays a directory round trip per step.
      * It must refuse an answer it cannot itself reach. The directory reports
        where IT reached the host, and adopting that blindly replaces a stale
        address with a wrong one.
      * The beacon must not conflate "records rewritten" with "pool accepted".
        Sharing one field makes an unreachable directory re-log and rewrite on
        every tick forever, which is how a quiet failure becomes a noisy one
        that still tells you nothing.
      * The host.env key names are a wire contract between the seeds, the
        shell library and the Windows peer. A rename in one place is silent:
        the guest simply never resolves.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:LocateSh   = Join-Path $script:RepoRoot 'automation/yuruna-host-locate.sh'
    $script:LocatePs   = Join-Path $script:RepoRoot 'automation/yuruna-host-locate.ps1'
    $script:BeaconPsm  = Join-Path $script:RepoRoot 'test/modules/Test.HostAddressBeacon.psm1'

    # The shell library is driven through bash against fixture files: it is the
    # artifact that actually ships into a Linux guest, so exercising the real
    # file is the only assertion that means anything about that guest.
    function Invoke-LocateShell {
        param(
            [Parameter(Mandatory)][string]$Fixture,
            [string]$DirectoryAnswer = '',
            [string]$Body = 'yuruna_host_locate; echo "rc=$?"',
            # Extra exports placed BEFORE the library is sourced, so a knob the
            # library reads with ${VAR:-default} sees the test's value.
            [hashtable]$Env = @{}
        )
        $stub = if ($DirectoryAnswer) {
            "__yhl_query_directory() { printf '%s' '$DirectoryAnswer'; }"
        } else {
            "__yhl_query_directory() { return 1; }"
        }
        $extra = ($Env.GetEnumerator() | ForEach-Object { "export $($_.Key)='$($_.Value)'" }) -join "`n"
        $shell = @"
export YURUNA_HOST_ENV_FILE='$Fixture/host.env'
export YURUNA_HOSTS_FILE='$Fixture/hosts'
export YURUNA_WGETRC_FILE='$Fixture/wgetrc'
$extra
. '$($script:LocateSh)'
$stub
$Body
"@
        return (& bash -c $shell 2>&1) -join "`n"
    }

    function New-LocateFixture {
        # A -WhatIf on a temp fixture nobody outside this file can observe would
        # be ceremony: the "state" is a directory created and removed inside one
        # It block. Same call the shipped New-* pure builders make.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a self-contained temp fixture removed by the same test; no caller-visible state.')]
        param([string]$StatusIp = '10.99.99.99', [string]$HostId = '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', [string]$CacheIp = '10.99.99.1')
        $dir = New-YurunaTestTempDir -Prefix 'yhl'
        @(
            "YURUNA_STATUS_SERVICE_IP=$StatusIp"
            'YURUNA_STATUS_SERVICE_PORT=8080'
            "YURUNA_HOST_ID=$HostId"
            "YURUNA_CACHING_PROXY_SERVICE_IP=$CacheIp"
        ) | Set-Content -LiteralPath (Join-Path $dir 'host.env')
        "127.0.0.1`tlocalhost`n$StatusIp`tyuruna-host" | Set-Content -LiteralPath (Join-Path $dir 'hosts')
        "no_proxy = $StatusIp" | Set-Content -LiteralPath (Join-Path $dir 'wgetrc')
        return $dir
    }
}

Describe 'guest resolver (yuruna-host-locate.sh)' {

    It 're-asks the directory instead of accepting one unreachable answer' {
        # The directory learns the host's new address from the host, so a guest
        # that starts resolving at the moment of a renumber can be handed the
        # address that just died -- both ends are racing the same change. A
        # single question loses that race and sends the caller to a fallback
        # that cannot help it, which costs the whole cycle. Counting the
        # questions is what pins the retry: the answer here never becomes
        # reachable, so the resolver must still decline, but it must have
        # asked more than once before doing so.
        $fx = New-LocateFixture
        try {
            $asked = (Join-Path $fx 'asked') -replace '\\', '/'
            $body = "__yhl_query_directory() { echo x >> '$asked'; printf '%s' 'http://10.99.99.98:8080'; }; " +
                    "yuruna_host_locate; echo `"rc=`$?`"; echo `"asked=`$(wc -l < '$asked' | tr -d ' ')`""
            # Retry timing is overridable precisely so this costs no wall clock.
            $out = Invoke-LocateShell -Fixture $fx -Body $body -Env @{
                YURUNA_LOCATE_RETRY_ATTEMPTS = '3'
                YURUNA_LOCATE_RETRY_DELAY    = '0'
            }
            $out | Should -Match 'rc=1'
            ([regex]::Match($out, 'asked=(\d+)').Groups[1].Value -as [int]) |
                Should -Be 3 -Because 'the resolver must re-ask the directory before giving up on a renumber it is still learning'
        } finally { Remove-YurunaTestTempDir $fx }
    }

    It 'refuses a directory answer this guest cannot reach' {
        # 10.99.99.98 is unroutable from the runner, so the confirm probe must
        # fail and the resolver must decline rather than adopt it. This is the
        # gate that keeps a stale directory from replacing a dead address with
        # a differently dead one.
        $fx = New-LocateFixture
        try {
            $out = Invoke-LocateShell -Fixture $fx -DirectoryAnswer 'http://10.99.99.98:8080'
            $out | Should -Match 'rc=1'
            (Get-Content -Raw (Join-Path $fx 'host.env')) | Should -Match 'YURUNA_STATUS_SERVICE_IP=10\.99\.99\.99'
        } finally { Remove-YurunaTestTempDir $fx }
    }

    It 'refuses answers that are wrong on their face, without probing them' {
        $fx = New-LocateFixture
        try {
            foreach ($bad in @('http://127.0.0.1:8080', 'http://169.254.9.9:8080', 'http://224.0.0.1:8080', 'ftp://10.99.99.5/', 'not-a-url')) {
                $out = Invoke-LocateShell -Fixture $fx -Body "__yhl_plausible '$bad'; echo `"rc=`$?`""
                $out | Should -Match 'rc=1' -Because "'$bad' must be rejected before a probe is spent on it"
            }
            $out = Invoke-LocateShell -Fixture $fx -Body "__yhl_plausible 'http://10.99.99.5:8080'; echo `"rc=`$?`""
            $out | Should -Match 'rc=0'
        } finally { Remove-YurunaTestTempDir $fx }
    }

    It 'rejects hostile origins even on the final directory attempt and never persists shell syntax' {
        $fx = New-LocateFixture
        try {
            $marker = (Join-Path $fx 'executed') -replace '\\', '/'
            $probed = (Join-Path $fx 'probed') -replace '\\', '/'
            $before = @{}
            foreach ($name in @('host.env', 'hosts', 'wgetrc')) { $before[$name] = [IO.File]::ReadAllText((Join-Path $fx $name)) }
            $answers = @(
                ('http://a$(touch${IFS}' + $marker + ')b@192.0.2.10:8080'),
                ('http://192.0.2.10:8080?$(touch${IFS}' + $marker + ')'),
                'http://192.0.2.10:0', 'http://192.0.2.10:65536',
                'http://999.0.2.10:8080', 'http://192.0.2.10:8080/path',
                'http://192.0.2.10:8080#fragment'
            )
            $body = @"
__yhl_livecheck() { case "`$1" in http://10.99.99.99:8080) return 1;; *) printf x >> '$probed'; return 0;; esac; }
yuruna_host_locate; echo "rc=`$?"
. "`$YURUNA_HOST_ENV_FILE"
"@
            foreach ($answer in $answers) {
                $out = Invoke-LocateShell -Fixture $fx -DirectoryAnswer $answer -Body $body -Env @{
                    YURUNA_LOCATE_RETRY_ATTEMPTS = '1'; YURUNA_LOCATE_RETRY_DELAY = '0'
                }
                $out | Should -Match 'rc=1'
                foreach ($name in $before.Keys) { [IO.File]::ReadAllText((Join-Path $fx $name)) | Should -BeExactly $before[$name] }
                Test-Path -LiteralPath $marker | Should -BeFalse
                Test-Path -LiteralPath $probed | Should -BeFalse
            }
        } finally { Remove-YurunaTestTempDir $fx }
    }

    It 'persists a validated literal endpoint and rejects unsafe direct persistence' {
        $fx = New-LocateFixture
        try {
            $body = @'
__yhl_livecheck() { [ "$1" = 'http://192.0.2.10:8443' ]; }
yuruna_host_locate; echo "rc=$?"
'@
            $out = Invoke-LocateShell -Fixture $fx -DirectoryAnswer 'http://192.0.2.10:8443' -Body $body -Env @{
                YURUNA_LOCATE_RETRY_ATTEMPTS = '1'; YURUNA_LOCATE_RETRY_DELAY = '0'
            }
            $out | Should -Match 'rc=0'
            (Get-Content -Raw (Join-Path $fx 'host.env')) | Should -Match 'YURUNA_STATUS_SERVICE_IP=192\.0\.2\.10'
            (Get-Content -Raw (Join-Path $fx 'host.env')) | Should -Match 'YURUNA_STATUS_SERVICE_PORT=8443'
            $before = [IO.File]::ReadAllText((Join-Path $fx 'host.env'))
            $out = Invoke-LocateShell -Fixture $fx -Body '__yhl_persist "192.0.2.10" "80;false"; echo "rc=$?"'
            $out | Should -Match 'rc=1'
            [IO.File]::ReadAllText((Join-Path $fx 'host.env')) | Should -BeExactly $before
        } finally { Remove-YurunaTestTempDir $fx }
    }

    It 'declines without touching the directory when the identity coordinates are absent' {
        # A guest imaged before this mechanism existed carries neither key. It
        # must behave exactly as it did then -- decline -- rather than fail in
        # some new way.
        $fx = New-LocateFixture
        try {
            @('YURUNA_STATUS_SERVICE_IP=10.99.99.99', 'YURUNA_STATUS_SERVICE_PORT=8080') |
                Set-Content -LiteralPath (Join-Path $fx 'host.env')
            $out = Invoke-LocateShell -Fixture $fx -Body '__yhl_query_directory() { echo "DIRECTORY WAS ASKED"; }; yuruna_host_locate; echo "rc=$?"'
            $out | Should -Match 'rc=1'
            $out | Should -Not -Match 'DIRECTORY WAS ASKED'
        } finally { Remove-YurunaTestTempDir $fx }
    }

    It 'parses one host out of a multi-host pool-status body by hostId' {
        # The compatibility leg: no jq on a bootstrapping guest, so the body is
        # split on '{' and both keys must land on one fragment. A nested status
        # object repeating hostId is exactly what that split exists to survive.
        $fx = New-LocateFixture
        try {
            $body = '{"pool":"default","hosts":[' +
                    '{"hostId":"42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","currentIp":"10.0.0.1","baseUrl":"http://10.0.0.1:8080","status":{"hostId":"42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},' +
                    '{"hostId":"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","currentIp":"10.0.0.2","baseUrl":"http://10.0.0.2:8080","status":{"hostId":"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}'
            $body | Set-Content -LiteralPath (Join-Path $fx 'pool.json')
            $parse = @"
printf '%s' "`$(cat '$fx/pool.json')" | tr '{' '\n' | grep -F '"hostId":"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' | sed -n 's/.*"baseUrl":"\([^"]*\)".*/\1/p' | head -n 1
"@
            (& bash -c $parse 2>&1) -join '' | Should -Be 'http://10.0.0.2:8080'
        } finally { Remove-YurunaTestTempDir $fx }
    }
}

Describe 'Windows guest resolver origin validation' {
    BeforeAll { . $script:LocatePs }

    It 'accepts only literal, reachable IPv4 origins with valid ports' {
        foreach ($good in @('http://10.99.99.5:8080', 'https://192.0.2.10/', 'http://192.0.2.10')) {
            Test-YhlPlausibleBaseUrl -BaseUrl $good | Should -BeTrue -Because "'$good' is a valid origin"
        }
        foreach ($bad in @(
            'http://example.com:8080', 'http://127.0.0.1:8080', 'http://169.254.9.9:8080',
            'http://224.0.0.1:8080', 'http://999.0.2.10:8080', 'http://10.99.99.5:0',
            'http://10.99.99.5:65536', 'http://10.99.99.5:8080/path',
            'http://10.99.99.5:8080?query', 'http://user@10.99.99.5:8080',
            'ftp://10.99.99.5:8080'
        )) {
            Test-YhlPlausibleBaseUrl -BaseUrl $bad | Should -BeFalse -Because "'$bad' must never become a guest coordinate"
        }
    }
}

Describe 'host beacon (Test.HostAddressBeacon.psm1)' {

    BeforeEach {
        Import-Module $script:BeaconPsm -Force -DisableNameChecking
        Reset-HostAddressBeaconState -Confirm:$false
    }

    It 'keeps recorded and announced state apart when the directory is unreachable' {
        # The regression this exists for: sharing one field made an
        # unreachable directory re-log the change and rewrite the same files on
        # EVERY tick, forever, because the announce never advanced it.
        $rt = New-YurunaTestTempDir -Prefix 'yhb'
        try {
            '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | Set-Content -LiteralPath (Join-Path $rt 'host.uuid')
            # 10.99.99.1 answers nothing, so every announce fails.
            $null = Invoke-HostAddressBeaconTick -RuntimeDir $rt -CurrentAddress '10.0.0.7' -CacheAddress '10.99.99.1' -Confirm:$false
            $s1 = Get-HostAddressBeaconState
            $s1.LastRecordedAddress  | Should -Be '10.0.0.7'
            $s1.LastAnnouncedAddress | Should -Be ''

            $before = (Get-Item (Join-Path $rt 'ipaddresses.txt')).LastWriteTimeUtc
            Start-Sleep -Milliseconds 1100
            $null = Invoke-HostAddressBeaconTick -RuntimeDir $rt -CurrentAddress '10.0.0.7' -CacheAddress '10.99.99.1' -Confirm:$false
            $after = (Get-Item (Join-Path $rt 'ipaddresses.txt')).LastWriteTimeUtc
            $after | Should -Be $before -Because 'an unchanged address must not rewrite the record on every tick'
        } finally { Remove-YurunaTestTempDir $rt }
    }

    It 'does nothing at all when the address has not moved and no beacon is due' {
        $rt = New-YurunaTestTempDir -Prefix 'yhb'
        try {
            # No directory configured: the tick advances both states locally,
            # so the second call has nothing left to do.
            Invoke-HostAddressBeaconTick -RuntimeDir $rt -CurrentAddress '10.0.0.9' -CacheAddress '' -Confirm:$false | Should -BeTrue
            Invoke-HostAddressBeaconTick -RuntimeDir $rt -CurrentAddress '10.0.0.9' -CacheAddress '' -Confirm:$false | Should -BeFalse
        } finally { Remove-YurunaTestTempDir $rt }
    }

    It 'ignores an empty address rather than publishing one' {
        Invoke-HostAddressBeaconTick -RuntimeDir ([System.IO.Path]::GetTempPath()) -CurrentAddress '' -Confirm:$false | Should -BeFalse
    }
}

Describe 'host beacon directory lookup (Resolve-HostAddressBeaconDirectory)' {

    BeforeAll {
        # The real resolver lives in Test.CachingProxyService, which a beacon
        # gets from its host driver. A stand-in is enough to mock: these cases
        # are about when the beacon asks and what it keeps, not how it probes.
        $script:StubbedSeedUrl = -not (Get-Command -Name 'Get-PoolAggregatorServiceSeedUrl' -ErrorAction SilentlyContinue)
        if ($script:StubbedSeedUrl) {
            function global:Get-PoolAggregatorServiceSeedUrl { '' }
        }
    }

    AfterAll {
        if ($script:StubbedSeedUrl) {
            Remove-Item -LiteralPath 'Function:\Get-PoolAggregatorServiceSeedUrl' -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        Import-Module $script:BeaconPsm -Force -DisableNameChecking
        Reset-HostAddressBeaconState -Confirm:$false
    }

    It 'announces to the address it was started with and never looks one up' {
        Mock -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl { 'https://10.1.2.3:9400' }
        Resolve-HostAddressBeaconDirectory -Pinned ' 10.9.9.9 ' | Should -Be '10.9.9.9'
        Should -Invoke -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl -Times 0 -Exactly
    }

    It 'adopts the first aggregator that answers when started without one, and keeps it' {
        # The regression: a beacon spawned while the proxy VM was still being
        # built started with no directory and never announced the host.
        Mock -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl { 'https://10.1.2.3:9400' }
        Resolve-HostAddressBeaconDirectory -Pinned '' | Should -Be '10.1.2.3'
        # Expire the lookup interval, so only the adoption can explain a
        # second call that does not ask again.
        InModuleScope Test.HostAddressBeacon { $script:LastDirectoryLookupUtc = [datetime]::MinValue }
        Resolve-HostAddressBeaconDirectory -Pinned '' | Should -Be '10.1.2.3' -Because 'an adopted directory is kept, as a pinned one is'
        Should -Invoke -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl -Times 1 -Exactly
    }

    It 'asks at most once per interval while no aggregator answers' {
        Mock -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl { '' }
        Resolve-HostAddressBeaconDirectory -Pinned '' | Should -Be ''
        Resolve-HostAddressBeaconDirectory -Pinned '' | Should -Be ''
        Should -Invoke -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl -Times 1 -Exactly
    }

    It 'announces on the tick right after adopting, not a beacon period later' {
        $rt = New-YurunaTestTempDir -Prefix 'yhb'
        try {
            # With no directory the tick marks the address as announced, which
            # would otherwise hold the first real announce back a whole period.
            $null = Invoke-HostAddressBeaconTick -RuntimeDir $rt -CurrentAddress '10.0.0.9' -CacheAddress '' -Confirm:$false
            (Get-HostAddressBeaconState).LastAnnouncedAddress | Should -Be '10.0.0.9'
            Mock -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl { 'https://10.1.2.3:9400' }
            Resolve-HostAddressBeaconDirectory -Pinned '' | Should -Be '10.1.2.3'
            (Get-HostAddressBeaconState).LastAnnouncedAddress | Should -Be ''
        } finally { Remove-YurunaTestTempDir $rt }
    }

    It 'treats a failing lookup as no directory yet' {
        Mock -ModuleName Test.HostAddressBeacon Get-PoolAggregatorServiceSeedUrl { throw 'probe exploded' }
        Resolve-HostAddressBeaconDirectory -Pinned '' | Should -Be ''
    }
}

Describe 'coordinate names are one contract across seeds and both resolvers' {

    It 'uses the same four host.env keys everywhere a guest reads or is given them' {
        # A rename in any one of these is silent: the seed writes a key the
        # resolver never reads, and the guest simply never resolves.
        $keys = @('YURUNA_STATUS_SERVICE_IP', 'YURUNA_STATUS_SERVICE_PORT', 'YURUNA_HOST_ID', 'YURUNA_CACHING_PROXY_SERVICE_IP')

        $shell = Get-Content -Raw $script:LocateSh
        $ps    = Get-Content -Raw $script:LocatePs
        $winBs = Get-Content -Raw (Join-Path $script:RepoRoot 'automation/windows-guest-bootstrap.ps1')
        foreach ($k in $keys) {
            $shell | Should -Match ([regex]::Escape($k)) -Because "the shell resolver must know '$k'"
            $winBs | Should -Match ([regex]::Escape($k)) -Because "the Windows bootstrap must seed '$k'"
        }
        # The Windows peer reads the identity pair out of the parsed map and
        # the address pair from the environment it just populated.
        foreach ($k in @('YURUNA_HOST_ID', 'YURUNA_CACHING_PROXY_SERVICE_IP')) {
            $ps | Should -Match ([regex]::Escape($k)) -Because "the Windows resolver must know '$k'"
        }

        foreach ($seed in @('ubuntu.server', 'amazon.linux.2023', 'stash-service', 'pool-control-service', 'download-agent-service', 'caching-proxy-service')) {
            $text = Get-Content -Raw (Join-Path $script:RepoRoot "host/vmconfig/$seed.base.user-data")
            foreach ($k in @('YURUNA_HOST_ID', 'YURUNA_CACHING_PROXY_SERVICE_IP')) {
                $text | Should -Match ([regex]::Escape($k)) -Because "seed '$seed' must carry '$k' or its guests cannot re-resolve"
            }
        }
    }

    It 'never sends a guest to the proof-minting /go/host route' {
        # /go/host mints a short-lived control proof into its redirect. A guest
        # holding one is the capability the status service's control-route
        # authentication exists to deny, so the resolvers must use the
        # read-only routes and only those.
        # Both resolvers DISCUSS /go/host in their documentation -- explaining
        # why they must not use it is exactly the knowledge worth keeping -- so
        # the assertion has to see code, not prose. The PowerShell peer is
        # tokenized (its docs are block comments a line filter cannot strip);
        # the shell library has only line comments.
        $psTokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $script:LocatePs).Path, [ref]$psTokens, [ref]$null)
        $psCode = ($psTokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join "`n"

        $shText = Get-Content -Raw $script:LocateSh
        $shCode = ($shText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        foreach ($pair in @(@{ Name = 'yuruna-host-locate.ps1'; Code = $psCode },
                            @{ Name = 'yuruna-host-locate.sh';  Code = $shCode })) {
            $pair.Code | Should -Not -Match '/go/host' -Because "$($pair.Name) must not request a control proof"
            $pair.Code | Should -Match '/api/v1/host-address'
            $pair.Code | Should -Match '/api/v1/pool-status'
        }
    }
}

Describe 'a guest accepts only its own host (guest-channel key)' -Skip:($IsWindows -or -not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    # A directory answer, or a stale seeded address now held by someone else,
    # must not re-home a guest onto another responder. A guest seeded with its
    # host's guest-channel key accepts a status service only when it answers a
    # fresh nonce with the key's HMAC, bound to the host id.
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
        $script:GuestKey = 'a1' * 32
        $script:OtherKey = 'b2' * 32
        $script:ChannelHostId = '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        # A status service emulated in the shell: it answers the nonce in the URL
        # with an HMAC under SERVER_KEY for SERVER_HOST_ID, or with no proof.
        $script:ServerStub = @'
__yhl_http_get() {
  case "$1" in
    *"/livecheck?nonce="*)
      n="${1##*nonce=}"
      if [ "$SERVER_MODE" = noproof ]; then printf '{"ok":true,"service":"yuruna-status-service"}'; return 0; fi
      p="$(printf 'yuruna-livecheck/1\n%s\n%s' "$SERVER_HOST_ID" "$n" | openssl dgst -sha256 -hmac "$SERVER_KEY" | awk '{ print $NF }')"
      printf '{"ok":true,"service":"yuruna-status-service","time":"t","hostId":"%s","proof":"%s"}' "$SERVER_HOST_ID" "$p" ;;
    *"/livecheck") printf '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
'@
        function Invoke-ChannelProbe {
            param([string]$ServerKey, [string]$ServerHostId, [string]$Mode = 'proof', [switch]$NoGuestKey)
            $fx = New-LocateFixture -HostId $script:ChannelHostId
            if (-not $NoGuestKey) { Set-Content -LiteralPath (Join-Path $fx 'guest-channel.key') -Value $script:GuestKey }
            try {
                $body = @(
                    $script:ServerStub,
                    "export SERVER_KEY='$ServerKey' SERVER_HOST_ID='$ServerHostId' SERVER_MODE='$Mode'",
                    '. "$YURUNA_HOST_ENV_FILE" 2>/dev/null || true',
                    '__yhl_livecheck "http://10.99.99.99:8080"; echo "rc=$?"'
                ) -join "`n"
                return Invoke-LocateShell -Fixture $fx -Body $body -Env @{ YURUNA_GUEST_CHANNEL_KEY_FILE = (Join-Path $fx 'guest-channel.key') }
            } finally { Remove-YurunaTestTempDir $fx }
        }
    }

    It 'accepts the host that proves the key for this guest''s host id' {
        Invoke-ChannelProbe -ServerKey $script:GuestKey -ServerHostId $script:ChannelHostId | Should -Match 'rc=0'
    }

    It 'refuses a responder that does not hold the key' {
        $out = Invoke-ChannelProbe -ServerKey $script:OtherKey -ServerHostId $script:ChannelHostId
        $out | Should -Match 'rc=1'
        $out | Should -Match 'did not prove this host''s guest-channel key'
    }

    It 'refuses a status service that answers without a proof' {
        $out = Invoke-ChannelProbe -ServerKey $script:GuestKey -ServerHostId $script:ChannelHostId -Mode noproof
        $out | Should -Match 'rc=1'
        $out | Should -Match 'answered without proving'
    }

    It 'refuses a proof for another host id' {
        $out = Invoke-ChannelProbe -ServerKey $script:GuestKey -ServerHostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $out | Should -Match 'rc=1'
        $out | Should -Match 'speaks for host'
    }

    It 'keeps the plain probe for a guest built before the key existed' {
        Invoke-ChannelProbe -ServerKey $script:OtherKey -ServerHostId 'x' -Mode noproof -NoGuestKey | Should -Match 'rc=0'
    }

    It 'computes the same proof on the host, in the shell resolver and in the Windows resolver' {
        $nonce = '0123456789abcdef0123456789abcdef'
        $hostProof = Get-YurunaGuestChannelProof -Key $script:GuestKey -HostId $script:ChannelHostId -Nonce $nonce
        $hostProof | Should -Match '^[0-9a-f]{64}$'
        $shellProof = (Invoke-LocateShell -Fixture ([IO.Path]::GetTempPath()) -Body "__yhl_channel_proof '$($script:GuestKey)' '$($script:ChannelHostId)' '$nonce'").Trim()
        $shellProof | Should -BeExactly $hostProof
        . $script:LocatePs
        Get-YhlChannelProof -Key $script:GuestKey -HostId $script:ChannelHostId -Nonce $nonce | Should -BeExactly $hostProof
        Get-YurunaGuestChannelProof -Key $script:GuestKey -HostId $script:ChannelHostId -Nonce $nonce -Scope 'archive-digest' | Should -Not -Be $hostProof
    }

    It 'has the Windows resolver accept only the proving host' {
        . $script:LocatePs
        $keyFile = Join-Path $TestDrive 'guest-channel.key'
        Set-Content -LiteralPath $keyFile -Value $script:GuestKey
        foreach ($case in @(
                @{ Key = $script:GuestKey; HostId = $script:ChannelHostId; Expect = $true }
                @{ Key = $script:OtherKey; HostId = $script:ChannelHostId; Expect = $false }
                @{ Key = $script:GuestKey; HostId = '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; Expect = $false })) {
            $script:Server = $case
            function Get-YhlHttpString {
                param([string]$Uri, [int]$TimeoutSec)
                [void]$TimeoutSec
                $nonce = ($Uri -split 'nonce=')[1]
                $proof = Get-YurunaGuestChannelProof -Key $script:Server.Key -HostId $script:Server.HostId -Nonce $nonce
                return (@{ ok = $true; hostId = $script:Server.HostId; proof = $proof } | ConvertTo-Json -Compress)
            }
            Test-YhlLivecheck -BaseUrl 'http://10.99.99.99:8080' -KeyPath $keyFile -HostId $script:ChannelHostId | Should -Be $case.Expect
        }
    }

    It 'has fetch-and-execute refuse an unverified host when the key is present and the resolver is not' {
        $fae = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'automation/fetch-and-execute.sh') -Raw
        $fn = Get-YurunaTestShellFunction -Text $fae -Name 'fae_host_answers'
        $keyFile = Join-Path $TestDrive 'fae-guest-channel.key'
        Set-Content -LiteralPath $keyFile -Value $script:GuestKey
        $run = Invoke-YurunaTestShell -Body (@("wget() { return 0; }", $fn, "YURUNA_GUEST_CHANNEL_KEY_FILE='$keyFile' fae_host_answers http://10.99.99.99:8080; echo rc=`$?") -join "`n")
        $run.Output | Should -Match 'rc=1'
        $fae | Should -Match 'if fae_host_answers "http://\$\{YURUNA_STATUS_SERVICE_IP\}:\$\{YURUNA_STATUS_SERVICE_PORT\}"; then'
    }
}

Describe 'the host side of the guest channel' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    }

    It 'creates one owner-only key on first use and returns it unchanged after' {
        $home1 = Join-Path $TestDrive 'home-key'
        $null = New-Item -ItemType Directory -Path $home1
        Get-YurunaGuestChannelKey -HomePath $home1 | Should -BeExactly '' -Because 'without -Create nothing is generated'
        $key = Get-YurunaGuestChannelKey -Create -HomePath $home1 -Confirm:$false
        $key | Should -Match '^[0-9a-f]{64}$'
        Get-YurunaGuestChannelKey -HomePath $home1 | Should -BeExactly $key
        Get-YurunaGuestChannelKey -Create -HomePath $home1 -Confirm:$false | Should -BeExactly $key
        if (-not $IsWindows) {
            $file = Get-ChildItem -LiteralPath $home1 -Recurse -Filter 'guest-channel.key' -Force | Select-Object -First 1
            ([int][IO.File]::GetUnixFileMode($file.FullName) -band 0x3F) | Should -Be 0
        }
    }

    It 'answers /livecheck?nonce= with the proof, and a probe without a nonce as before' {
        $runtime = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'test/service/Invoke-StatusServiceRuntime.ps1') -Raw
        $route = $runtime.Substring($runtime.IndexOf('# --- REGION: /livecheck'))
        $route = $route.Substring(0, $route.IndexOf('# --- REGION: /ca.crt'))
        $route | Should -Match ([regex]::Escape("`$nonce = [string]`$req.QueryString['nonce']"))
        $route | Should -Match ([regex]::Escape("`$livecheck.proof = Get-YurunaGuestChannelProof -Key `$channelKey -HostId `$livecheckHostId -Nonce `$nonce"))
        $route | Should -Match ([regex]::Escape("`$livecheckHostId = Get-ArchiveHostId"))
    }

    It 'seeds the key into every guest that runs the resolver' {
        foreach ($name in @('ubuntu.server', 'amazon.linux.2023', 'stash-service', 'pool-control-service', 'download-agent-service', 'caching-proxy-service')) {
            $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot "host/vmconfig/$name.base.user-data") -Raw
            $text | Should -Match 'guest-channel\.key' -Because "$name runs host-locate or fetch-and-execute"
            $text | Should -Match 'YURUNA_GUEST_CHANNEL_KEY_PLACEHOLDER'
        }
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force -DisableNameChecking
        $seed = New-WindowsGuestBootstrap -RepoRoot $script:RepoRoot -GuestChannelKey ('c3' * 32)
        $seed.Files['yuruna-bootstrap.ps1'] | Should -Match ([regex]::Escape("-Value '$('c3' * 32)'"))
        $bad = New-WindowsGuestBootstrap -RepoRoot $script:RepoRoot -GuestChannelKey "x'; Remove-Item C:\ -Recurse #"
        $bad.Files['yuruna-bootstrap.ps1'] | Should -Not -Match 'Remove-Item C:'
    }
}

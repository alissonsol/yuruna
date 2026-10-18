<#PSScriptInfo
.VERSION 2026.10.18
.GUID 422dbaf3-8d25-41fa-abc0-e70b2229b2b7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner diagnostics network cross-check pester
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
    The host-side cross-check names the end that went silent -- the caching
    proxy or the guest -- and can never become a fault of its own.
.DESCRIPTION
    WHY THIS EXISTS. A guest that loses its address mid-cycle and a proxy that
    stops answering leave the same console behind, and a failure record built
    from the console alone blames whichever of the two it happened to mention,
    even when the host could reach the proxy the whole time; without this
    check nothing records that. The check runs inside the failure
    path, so every probe is mocked here and the properties under test are:

      * the verdict matrix, with an explicit "unknown" for an end that had no
        address -- a missing address must never read as a silent machine;
      * both files land in the failure folder and the cycle event carries
        the verdict, with the types the event schema pins;
      * the cache host and the guest address resolve in the documented order
        (parameter, then the cycle's environment / the proven SSH address,
        then the host driver);
      * nothing thrown by any probe -- or by the file system -- escapes.

    Run: Invoke-Pester -Path test/modules/Test.GuestNetworkCrossCheck.Tests.ps1
#>

# The module resolves Send-CycleEventSafely from the global command table at
# call time, so the collector stub the event test asserts through must live
# in the global scope or the module would never see it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The global scope is the resolution contract under test: Invoke-GuestNetworkCrossCheck finds Send-CycleEventSafely in the global table, so the collector stub and its assertion must straddle that scope.')]
param()

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.GuestNetworkCrossCheck.psm1') -Force -DisableNameChecking
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $script:ModuleName = 'Test.GuestNetworkCrossCheck'
    $script:ModulePath = Join-Path $here 'Test.GuestNetworkCrossCheck.psm1'
    $script:RunnerText = Get-Content -Raw -LiteralPath (Join-Path $here 'Test.RunnerInnerLoop.psm1')

    $script:OpenProbe = { param($Address, $Port) [ordered]@{ address = $Address; port = $Port; open = $true; ms = 3; error = $null } }
    $script:ClosedProbe = { param($Address, $Port) [ordered]@{ address = $Address; port = $Port; open = $false; ms = 2000; error = 'timeout' } }
    $script:ThrowingProbe = { param($Address, $Port) throw "socket exploded for ${Address}:$Port" }

    function New-CrossCheckDirectory {
        [CmdletBinding()]
        [OutputType([string])]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: creates a throwaway folder under TestDrive.')]
        param()
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        return $path
    }
    # Every probe mocked at once, so each It states only what differs.
    function Set-ProbeMock {
        [CmdletBinding()]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: installs Pester mocks for one It block.')]
        param([ValidateSet('up', 'down', 'status404', 'throwing')][string]$Http = 'down', [object]$Ping = $false, [string]$Neighbor = 'absent')
        switch ($Http) {
            'up' { Mock -CommandName Invoke-WebRequest -ModuleName $script:ModuleName -MockWith { [pscustomobject]@{ StatusCode = 200; Content = "ok: pull budget 92%`nsecond line" } } }
            'down' { Mock -CommandName Invoke-WebRequest -ModuleName $script:ModuleName -MockWith { throw [System.Net.Http.HttpRequestException]::new('connection refused') } }
            'status404' { Mock -CommandName Invoke-WebRequest -ModuleName $script:ModuleName -MockWith {
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('404', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)) } }
            'throwing' { Mock -CommandName Invoke-WebRequest -ModuleName $script:ModuleName -MockWith { throw 'web client exploded' } }
        }
        if ($Ping -is [scriptblock]) { Mock -CommandName Test-Connection -ModuleName $script:ModuleName -MockWith $Ping }
        else { $value = [bool]$Ping; Mock -CommandName Test-Connection -ModuleName $script:ModuleName -MockWith { $value }.GetNewClosure() }
        if ($Neighbor -eq 'throw') { Mock -CommandName Get-GuestNetworkCrossCheckNeighborState -ModuleName $script:ModuleName -MockWith { throw 'neighbor exploded' } }
        else { $state = $Neighbor; Mock -CommandName Get-GuestNetworkCrossCheckNeighborState -ModuleName $script:ModuleName -MockWith { $state }.GetNewClosure() }
    }
}

Describe 'the verdict names which end the host could reach' {
    It 'answers <Expected> for cache=<HasCacheHost> guest=<HasGuestAddress> proxy=<ProxyReachable> guestUp=<GuestReachable>' -TestCases @(
        @{ HasCacheHost = $true;  HasGuestAddress = $true;  ProxyReachable = $true;  GuestReachable = $false; Expected = 'proxy-reachable-guest-unreachable' }
        @{ HasCacheHost = $true;  HasGuestAddress = $true;  ProxyReachable = $false; GuestReachable = $true;  Expected = 'proxy-unreachable-guest-reachable' }
        @{ HasCacheHost = $true;  HasGuestAddress = $true;  ProxyReachable = $true;  GuestReachable = $true;  Expected = 'both-reachable' }
        @{ HasCacheHost = $true;  HasGuestAddress = $true;  ProxyReachable = $false; GuestReachable = $false; Expected = 'both-unreachable' }
        @{ HasCacheHost = $false; HasGuestAddress = $true;  ProxyReachable = $false; GuestReachable = $false; Expected = 'guest-unreachable-proxy-unknown' }
        @{ HasCacheHost = $false; HasGuestAddress = $true;  ProxyReachable = $false; GuestReachable = $true;  Expected = 'guest-reachable-proxy-unknown' }
        @{ HasCacheHost = $true;  HasGuestAddress = $false; ProxyReachable = $true;  GuestReachable = $false; Expected = 'proxy-reachable-guest-unknown' }
        @{ HasCacheHost = $true;  HasGuestAddress = $false; ProxyReachable = $false; GuestReachable = $false; Expected = 'proxy-unreachable-guest-unknown' }
        @{ HasCacheHost = $false; HasGuestAddress = $false; ProxyReachable = $false; GuestReachable = $false; Expected = 'unavailable' }
    ) {
        Get-GuestNetworkCrossCheckVerdict -HasCacheHost $HasCacheHost -HasGuestAddress $HasGuestAddress `
            -ProxyReachable $ProxyReachable -GuestReachable $GuestReachable | Should -Be $Expected
    }

    It 'never lets a reachable reading leak into a side that had no address' {
        # The pure function cannot know whether a probe ran; the caller passes
        # false for an unprobed side, and the verdict must still say unknown.
        Get-GuestNetworkCrossCheckVerdict -HasCacheHost $false -HasGuestAddress $true -ProxyReachable $true -GuestReachable $true |
            Should -Be 'guest-reachable-proxy-unknown' -Because 'no cache host means the proxy was never probed, whatever the flag says'
    }
}

Describe 'the check probes both ends and lands its files' {

    It 'reads proxy-reachable-guest-unreachable when the proxy answers and the guest does not' {
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        $dir = New-CrossCheckDirectory
        $result = Invoke-GuestNetworkCrossCheck -VMName 'yuruna-k8s-a' -GuestKey 'k8s-a' -OutputDirectory $dir `
            -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe
        $result.verdict | Should -Be 'proxy-reachable-guest-unreachable'
        $result.cacheV2.status | Should -Be 200
        $result.cacheV2.uri | Should -Be 'http://192.0.2.42:5000/v2/'
        $result.cacheHealth.uri | Should -Be 'http://192.0.2.42/cache-health'
        $result.cacheHealth.firstLine | Should -Be 'ok: pull budget 92%' -Because 'only the first line of cache-health is kept'
        $result.guestTcp22.open | Should -BeFalse
        $result.guestPingOk | Should -BeFalse
        $result.neighborState | Should -Be 'absent'
        Test-Path (Join-Path $dir 'network-cross-check.json') | Should -BeTrue
        Test-Path (Join-Path $dir 'network-cross-check.txt') | Should -BeTrue
        (Get-Content (Join-Path $dir 'network-cross-check.json') -Raw | ConvertFrom-Json).verdict | Should -Be 'proxy-reachable-guest-unreachable'
        $text = Get-Content -Raw (Join-Path $dir 'network-cross-check.txt')
        $text | Should -Match '(?m)^verdict:\s+proxy-reachable-guest-unreachable'
        $text | Should -Match '192\.0\.2\.129 \(from parameter\)'
        $text | Should -Match '(?m)^tcp22:\s+open=False'
    }

    It 'reads proxy-unreachable-guest-reachable when only the guest answers' {
        Set-ProbeMock -Http down -Ping $false -Neighbor 'Reachable 02-42-AC-11-00-02'
        $dir = New-CrossCheckDirectory
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory $dir `
            -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:OpenProbe
        $result.verdict | Should -Be 'proxy-unreachable-guest-reachable'
        $result.cacheV2.answered | Should -BeFalse
        $result.cacheV2.error | Should -Match 'connection refused'
        $result.cacheV2.status | Should -BeNullOrEmpty
    }

    It 'reads both-reachable and both-unreachable from the two probes alone' {
        Set-ProbeMock -Http up -Ping $true -Neighbor 'Reachable'
        $both = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) `
            -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:OpenProbe
        $both.verdict | Should -Be 'both-reachable'
        Set-ProbeMock -Http down -Ping $false -Neighbor 'absent'
        $none = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) `
            -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe
        $none.verdict | Should -Be 'both-unreachable'
    }

    It 'counts an HTTP error status as a proxy that answered, and keeps the status for the reader' {
        Set-ProbeMock -Http status404 -Ping $false -Neighbor 'absent'
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) `
            -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe
        $result.cacheV2.status | Should -Be 404
        $result.cacheV2.answered | Should -BeTrue -Because 'the question is whether the host reaches the proxy, not whether the path exists'
        $result.cacheV2.ok | Should -BeFalse
        $result.verdict | Should -Be 'proxy-reachable-guest-unreachable'
    }

    It 'treats a ping reply as a reachable guest even when sshd is not listening' {
        Set-ProbeMock -Http up -Ping $true -Neighbor 'Reachable'
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) `
            -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe
        $result.guestReachable | Should -BeTrue
        $result.guestTcp22.open | Should -BeFalse
        $result.verdict | Should -Be 'both-reachable'
    }

    It 'uses the built-in TCP probe when no seam is injected, with a closed socket as the answer' {
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        # TEST-NET-1 (RFC 5737) is never routed, so the connect times out or is refused.
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) `
            -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129'
        $result.guestTcp22.open | Should -BeFalse
        $result.guestTcp22.port | Should -Be 22
        $result.guestTcp22.ms | Should -Not -BeNullOrEmpty
    }
}

Describe 'missing inputs are readings, not faults' {
    BeforeEach { $script:SavedCacheIp = $env:YURUNA_CACHING_PROXY_SERVICE_IP }
    AfterEach { $env:YURUNA_CACHING_PROXY_SERVICE_IP = $script:SavedCacheIp }

    It 'reads guest-unreachable-proxy-unknown with no cache host anywhere, without probing HTTP' {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        $dir = New-CrossCheckDirectory
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory $dir -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe
        $result.verdict | Should -Be 'guest-unreachable-proxy-unknown'
        $result.cacheHost | Should -Be ''
        $result.cacheV2 | Should -BeNullOrEmpty
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName $script:ModuleName -Times 0 -Exactly
        Get-Content -Raw (Join-Path $dir 'network-cross-check.txt') | Should -Match 'cacheHost:\s+\(none'
    }

    It 'falls back to the cycle''s YURUNA_CACHING_PROXY_SERVICE_IP when no cache host is passed' {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ' 192.0.2.42 '
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe
        $result.cacheHost | Should -Be '192.0.2.42' -Because 'the runner process already holds the cache address for this cycle'
        $result.verdict | Should -Be 'proxy-reachable-guest-unreachable'
    }

    It 'reads proxy-reachable-guest-unknown with no guest address from any source, and still writes the files' {
        Set-ProbeMock -Http up -Ping $true -Neighbor 'Reachable'
        $dir = New-CrossCheckDirectory
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm-with-no-address' -GuestKey 'g' -OutputDirectory $dir -CacheHost '192.0.2.42' -TcpProbe $script:OpenProbe
        $result.verdict | Should -Be 'proxy-reachable-guest-unknown'
        $result.guestAddress | Should -Be ''
        $result.guestAddressSource | Should -Be 'none'
        $result.guestTcp22 | Should -BeNullOrEmpty -Because 'nothing was probed; an open reading here would be invented'
        Test-Path (Join-Path $dir 'network-cross-check.json') | Should -BeTrue
        Get-Content -Raw (Join-Path $dir 'network-cross-check.txt') | Should -Match 'guest:\s+\(no address'
    }

    It 'reads unavailable with neither end known' {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        Set-ProbeMock -Http up -Ping $true -Neighbor 'Reachable'
        $result = Invoke-GuestNetworkCrossCheck -VMName 'vm-with-no-address' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) -TcpProbe $script:OpenProbe
        $result.verdict | Should -Be 'unavailable'
    }

    It 'takes the address SSH last proved before asking the host driver' {
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        $sshStub = New-Module -Name Test.Ssh -ScriptBlock { function Get-ProvenGuestAddress { param([string]$VMName) if ($VMName) { '192.0.2.9' } } } | Import-Module -Global -PassThru
        function global:Get-VMIp { param([string]$VMName) if ($VMName) { '192.0.2.10' } }
        try {
            $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) -CacheHost '192.0.2.42' -TcpProbe $script:ClosedProbe
            $result.guestAddress | Should -Be '192.0.2.9'
            $result.guestAddressSource | Should -Be 'proven-ssh'
        } finally {
            Remove-Module -ModuleInfo $sshStub -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath Function:\Global:Get-VMIp -ErrorAction SilentlyContinue
        }
    }

    It 'asks the host driver when nothing was proved by SSH' {
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        function global:Get-VMIp { param([string]$VMName) if ($VMName) { '192.0.2.10' } }
        try {
            $result = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) -CacheHost '192.0.2.42' -TcpProbe $script:ClosedProbe
            $result.guestAddress | Should -Be '192.0.2.10'
            $result.guestAddressSource | Should -Be 'host-driver'
        } finally {
            Remove-Item -LiteralPath Function:\Global:Get-VMIp -ErrorAction SilentlyContinue
        }
    }
}

Describe 'nothing a probe does can fail the cycle' {

    It 'never throws when every probe throws, and still lands a verdict and both files' {
        Set-ProbeMock -Http throwing -Ping { throw 'ping exploded' } -Neighbor 'throw'
        $dir = New-CrossCheckDirectory
        $result = $null
        { $script:ThrowingResult = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory $dir `
                -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ThrowingProbe } | Should -Not -Throw
        $result = $script:ThrowingResult
        $result.verdict | Should -Be 'both-unreachable'
        $result.guestTcp22.open | Should -BeFalse
        $result.guestTcp22.error | Should -Match 'socket exploded'
        $result.guestPingOk | Should -BeNullOrEmpty -Because 'a probe that could not run is unknown, not a silent guest'
        $result.neighborState | Should -Be 'unavailable'
        $result.cacheV2.error | Should -Match 'web client exploded'
        Test-Path (Join-Path $dir 'network-cross-check.json') | Should -BeTrue
        Test-Path (Join-Path $dir 'network-cross-check.txt') | Should -BeTrue
    }

    It 'never throws when the output folder cannot be created' {
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        $blocker = Join-Path $TestDrive 'not-a-folder.txt'
        Set-Content -LiteralPath $blocker -Value 'x'
        { $script:BlockedResult = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (Join-Path $blocker 'sub') `
                -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe } | Should -Not -Throw
        $script:BlockedResult.verdict | Should -Be 'proxy-reachable-guest-unreachable' -Because 'the reading survives even when it cannot be written'
    }
}

Describe 'the cycle event carries the verdict with the types the schema pins' {

    It 'emits one schema-valid network_cross_check event through the global Send-CycleEventSafely' {
        Set-ProbeMock -Http up -Ping $false -Neighbor 'Stale 02-42-AC-11-00-02'
        $global:__XcEmitted = @()
        function global:Send-CycleEventSafely { param([hashtable]$EventRecord) $global:__XcEmitted += , $EventRecord }
        try {
            $null = Invoke-GuestNetworkCrossCheck -VMName 'yuruna-k8s-a' -GuestKey 'k8s-a' -OutputDirectory (New-CrossCheckDirectory) `
                -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe
            @($global:__XcEmitted).Count | Should -Be 1
            $record = $global:__XcEmitted[0]
            $record.event | Should -Be 'network_cross_check'
            $record.vmName | Should -BeOfType [string]
            $record.guestKey | Should -BeOfType [string]
            $record.verdict | Should -Be 'proxy-reachable-guest-unreachable'
            $record.cacheHost | Should -Be '192.0.2.42'
            $record.cacheV2Status | Should -Be 200
            $record.cacheV2Ms | Should -Not -BeNullOrEmpty
            $record.cacheHealthOk | Should -BeTrue
            $record.guestAddress | Should -Be '192.0.2.129'
            $record.guestTcp22Ok | Should -BeFalse
            $record.guestPingOk | Should -BeFalse
            $record.neighborState | Should -Be 'Stale 02-42-AC-11-00-02'
            @(Test-CycleEventSchema -Record $record) | Should -BeNullOrEmpty -Because 'the emit site must satisfy the envelope and typed-field contract'
        } finally {
            Remove-Item -LiteralPath Function:\Global:Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __XcEmitted -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'keeps its reading when the event writer itself throws' {
        Set-ProbeMock -Http up -Ping $false -Neighbor 'absent'
        function global:Send-CycleEventSafely { param([hashtable]$EventRecord) throw "writer exploded on $($EventRecord.event)" }
        try {
            { $script:WriterResult = Invoke-GuestNetworkCrossCheck -VMName 'vm' -GuestKey 'g' -OutputDirectory (New-CrossCheckDirectory) `
                    -CacheHost '192.0.2.42' -GuestAddress '192.0.2.129' -TcpProbe $script:ClosedProbe } | Should -Not -Throw
            $script:WriterResult.verdict | Should -Be 'proxy-reachable-guest-unreachable' -Because 'telemetry failing must not cost the reading'
        } finally {
            Remove-Item -LiteralPath Function:\Global:Send-CycleEventSafely -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the runner runs the check where the failure evidence is gathered' {

    It 'imports the leaf module lazily and globally, and runs the check before the guest diagnostic' {
        $script:RunnerText | Should -Match "Import-Module \(Join-Path \`$ModulesDir 'Test\.GuestNetworkCrossCheck\.psm1'\) -Force -Global"
        $script:RunnerText | Should -Match 'Invoke-GuestNetworkCrossCheck -VMName \$VMName -GuestKey \$GuestKey -OutputDirectory \$destSeqDir'
        $check = $script:RunnerText.IndexOf('Invoke-GuestNetworkCrossCheck -VMName')
        $diag = $script:RunnerText.IndexOf('Save-GuestDiagnostic -VMName $VMName -GuestKey $GuestKey -OutputFolder $destSeqDir')
        ($check -ge 0 -and $diag -gt $check) | Should -BeTrue -Because 'the check must read the network before the diagnostic spends minutes on SSH'
    }

    It 'carries the verdict and the SSH readiness on the failure_diagnostic event' {
        $script:RunnerText | Should -Match "networkCrossCheck=\`$\(if \(\`$networkCrossCheck -and \`$networkCrossCheck\.verdict\)"
        $script:RunnerText | Should -Match 'sshReadiness=\$failureSshReadiness'
        $block = [regex]::Match($script:RunnerText, "(?s)event='failure_diagnostic'.*?\n        \}").Value
        $block | Should -Match 'networkCrossCheck='
        $block | Should -Match 'sshReadiness='
    }

    It 'guards the check with try/catch so a probe can never fail the step' {
        $block = [regex]::Match($script:RunnerText, '(?s)\$networkCrossCheck = \$null\s*try \{.*?Invoke-GuestNetworkCrossCheck.*?\} catch \{').Success
        $block | Should -BeTrue
    }

    It 'ships the module and this suite with 42-prefixed GUIDs and the license link' {
        foreach ($path in @($script:ModulePath, $PSCommandPath)) {
            $text = Get-Content -Raw -LiteralPath $path
            $text | Should -Match '(?m)^\.GUID 42[0-9a-f]{6}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            $text | Should -Match '(?m)^\.LICENSEURI https://yuruna\.link/license$'
        }
    }
}

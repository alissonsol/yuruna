<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42fa8d36-e7cb-4b28-93b8-d483c23cdcb4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test extension area contract schema authority pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Pester coverage for the extension areas AS THEY SHIP: every area under
    test/extension/ loaded through the real loader, validated against the real
    schema, and probed through the real host pre-flights.
.DESCRIPTION
    Test.Extension.Tests.ps1 covers the loader against a synthetic area tree,
    which is the right way to test the loader and the wrong way to notice that
    a shipped area drifted. Nothing imported the real areas, so a contract verb
    renamed on one side of the pair warned into a log nobody reads and shipped;
    and only two of the seven configs were schema-checked, leaving the
    `service:` blocks that feed the VM roster validated by nothing.

    Three properties, each of them a regression that reached a guest before:

      - every shipped area loads with its declared contract fully covered;
      - every shipped area's config.yml validates against the schema the
        manifest reader assumes; and
      - the three service host pre-flights build the same URL from the same
        authority, including the host:port form the UTM Shared-NAT forward
        produces.

    The probe addresses are the documentation ranges (RFC 5737 TEST-NET-1 and
    RFC 3849 2001:db8::/32): they cannot route anywhere, so the probe always
    fails and the URL it tried is read back off the verbose stream. That
    exercises the shipping code path rather than a restatement of it.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.ExtensionArea.Tests.ps1
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$TestRoot = Split-Path -Parent $here
$script:RepoRoot = Split-Path -Parent $TestRoot

Import-Module (Join-Path $here 'Test.Extension.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# The three areas whose default.psm1 ships a reachability pre-flight, paired
# with the verb each one exports for it.
$script:HostProbeArea = [ordered]@{
    'stash-service'          = 'Test-StashServiceHost'
    'pool-control-service'   = 'Test-PoolControlServiceHost'
    'download-agent-service' = 'Test-DownloadAgentServiceHost'
}

# Authority forms a caller can hand a pre-flight, and the URL each must
# produce. host:port is the UTM Shared-NAT forward; the bare IPv6 literal is
# the only form that needs brackets added; the bracketed one is already a legal
# authority and must survive untouched.
$script:AuthorityCase = [ordered]@{
    '192.0.2.10'          = 'http://192.0.2.10/healthz'
    '192.0.2.10:8080'     = 'http://192.0.2.10:8080/healthz'
    '2001:db8::10'        = 'http://[2001:db8::10]/healthz'
    '[2001:db8::10]:8080' = 'http://[2001:db8::10]:8080/healthz'
}

function Get-AreaProbeUrl {
    <#
    .SYNOPSIS
        The URL an area's host pre-flight actually requested for one address.
    .DESCRIPTION
        Invokes the command through its own module object rather than by name.
        Every area ships its implementation as `default.psm1`, so all seven
        register under the PowerShell module name 'default' and a name-based
        call would reach whichever one was imported last.
    .OUTPUTS
        [string] the requested URL, or '' when the probe logged nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Function,
        [Parameter(Mandatory)][string]$Address
    )
    $psm1 = Join-Path (Join-Path (Join-Path $script:RepoRoot 'test') 'extension') $Area |
        Join-Path -ChildPath 'default.psm1'
    $module = Import-Module -Name $psm1 -Force -PassThru -DisableNameChecking
    try {
        $command = $module.ExportedCommands[$Function]
        if (-not $command) { throw "$Area does not export $Function" }
        # One attempt, one second: the address cannot route, so every attempt
        # spends the full deadline and adds nothing.
        $records = & $command -Address $Address -Attempts 1 -TimeoutSeconds 1 -BackoffMs 0 -Verbose 4>&1
        $line = ($records |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
            Select-Object -First 1).Message
        if ("$line" -match '(http://\S+/healthz)') { return $Matches[1] }
        return ''
    } finally {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}

}

Describe 'every shipped extension area' {
    It 'loads through the loader with its contract fully covered' {
        # Coverage is warn-and-continue at load by design -- one broken area
        # must not take an unrelated cycle down -- which also means nothing
        # fails when a verb is renamed on one side of the contract. Here the
        # warning IS the failure.
        $areas = @(Get-ExtensionAreaName)
        Assert-True ($areas.Count -ge 7) "expected the shipped areas, found $($areas.Count)"
        foreach ($area in $areas) {
            $captured = $null
            $null = Import-Extension -Area $area -WarningVariable captured -WarningAction SilentlyContinue
            $gaps = @($captured | Where-Object { "$($_.Message)" -match 'contract verb' })
            Assert-Equal 0 $gaps.Count "area '$area': $(($gaps | ForEach-Object { $_.Message }) -join ' | ')"
        }
    }

    It 'declares a config.yml that validates against the extension schema' {
        # The schema is what the manifest reader assumes it is reading. A
        # mistyped service key parses as YAML, reads back as $null, and turns
        # into a missing VM in a roster the reboot sweep trusts.
        Import-Module powershell-yaml -Verbose:$false -ErrorAction Stop
        $schemaPath = Join-Path (Join-Path (Join-Path $script:RepoRoot 'test') 'schemas') 'extension-config.schema.yml'
        Assert-True (Test-Path -LiteralPath $schemaPath) "the extension schema exists at $schemaPath"
        $schemaJson = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32

        $areas = @(Get-ExtensionAreaName)
        Assert-True ($areas.Count -ge 7) "expected the shipped areas, found $($areas.Count)"
        foreach ($area in $areas) {
            $config = Join-Path (Join-Path (Join-Path $script:RepoRoot 'test') 'extension') $area |
                Join-Path -ChildPath "$area.config.yml"
            $docJson = Get-Content -Raw -LiteralPath $config | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
            $valid = $false
            $reason = ''
            try { $valid = Test-Json -Json $docJson -Schema $schemaJson -ErrorAction Stop }
            catch { $reason = $_.Exception.Message }
            Assert-True $valid "$area.config.yml is schema-valid $reason"
        }
    }
}

Describe 'the caching-proxy host pre-flight' {
    It 'appends the daemon port to a bare authority and brackets a bare IPv6 literal' {
        # This one is NOT in the three-area identity check above, and the
        # difference is real rather than drift: its siblings all listen on :80,
        # so a bare address probes the right port by doing nothing. This daemon
        # listens on 9310 beside a squid that WILL accept a connection on :80
        # and :3128 -- so a bare address with no port added would report the
        # cache's liveness as the daemon's.
        $expected = [ordered]@{
            '192.0.2.10'          = 'http://192.0.2.10:9310/healthz'
            '192.0.2.10:8080'     = 'http://192.0.2.10:8080/healthz'
            '2001:db8::10'        = 'http://[2001:db8::10]:9310/healthz'
            '[2001:db8::10]:8080' = 'http://[2001:db8::10]:8080/healthz'
        }
        foreach ($address in $expected.Keys) {
            $url = Get-AreaProbeUrl -Area 'caching-proxy-service' `
                -Function 'Test-CachingProxyServiceHost' -Address $address
            Assert-Equal $expected[$address] $url "caching-proxy-service probing '$address'"
        }
    }
}

Describe 'every declared beacon cadence' {
    It 'stays under the aggregator extension health grace' {
        # The cadence cross-check in Test.ExtensionService.Tests.ps1 covers the
        # three areas whose bring-up script, daemon constant and manifest must
        # agree. This is the weaker rule that applies to EVERY area, including
        # one built from a cloud-init seed with no guest script to compare
        # against: whatever it declares has to be shorter than the grace, or a
        # renumbered service is unresolvable between the refusal of its old
        # address and its next announce.
        $mainGo = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'pool-aggregator-service', 'main.go')
        $source = Get-Content -Raw -LiteralPath $mainGo
        # Matched here rather than through Assert-Match: $Matches from a call
        # inside the assertion helper never reaches this scope.
        Assert-True ($source -match 'extensionHealthGrace\s*=\s*([0-9]+)\s*\*\s*time\.Minute') `
            'the aggregator declares a health grace in minutes'
        $graceSeconds = [double]$Matches[1] * 60

        $unit = @{ ns = 1e-9; us = 1e-6; ms = 1e-3; s = 1; m = 60; h = 3600 }
        $checked = 0
        foreach ($area in (Get-ExtensionAreaName)) {
            $config = Join-Path (Join-Path (Join-Path $script:RepoRoot 'test') 'extension') $area |
                Join-Path -ChildPath "$area.config.yml"
            $text = Get-Content -Raw -LiteralPath $config
            if ($text -notmatch '(?m)^\s*beaconInterval:\s*([0-9]+)([a-z]+)\s*$') { continue }
            $checked++
            $seconds = [double]$Matches[1] * $unit[$Matches[2]]
            Assert-True ($seconds -lt $graceSeconds) `
                "$area declares a ${seconds}s beacon, not under the ${graceSeconds}s health grace"
        }
        Assert-True ($checked -ge 4) "expected every beaconing area to be checked, saw $checked"
    }
}

Describe 'the pool-aggregator route names' {
    It 'match the constants the daemon registers' {
        # The PowerShell client and the Go mux are wired independently. A
        # rename on one side answers 404 to a host asking the right question,
        # and nothing fails until a cycle cannot find the service it needs.
        # The Go half of this pair is route_names_test.go, which pins the same
        # five values; this half proves the client still asks for them.
        $expected = [ordered]@{
            Health         = '/healthz'
            Metrics        = '/metrics'
            Status         = '/api/v1/pool-status'
            ExtensionHosts = '/api/v1/extension-hosts'
            LabToken       = '/api/v1/lab-token'
        }
        $psm1 = Join-Path (Join-Path (Join-Path $script:RepoRoot 'test') 'extension') 'pool-aggregator-service' |
            Join-Path -ChildPath 'default.psm1'
        $module = Import-Module -Name $psm1 -Force -PassThru -DisableNameChecking
        try {
            $endpoints = (& $module.ExportedCommands['Get-PoolAggregatorServiceManifest']).Endpoints
            Assert-Equal $expected.Count $endpoints.Count 'the client pins every vectored route and no others'
            foreach ($name in $expected.Keys) {
                Assert-Equal $expected[$name] $endpoints[$name] "endpoint '$name'"
            }
        } finally {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
        }

        # The Go side must carry the identical vector, by constant. Reading it
        # here is what makes this a cross-language guard rather than two
        # independent restatements that can drift apart in silence.
        $mainGo = Join-Path (Join-Path (Join-Path $script:RepoRoot 'test') 'extension') 'pool-aggregator-service' |
            Join-Path -ChildPath 'main.go'
        $source = Get-Content -Raw -LiteralPath $mainGo
        $goConstant = [ordered]@{
            Health = 'routeHealth'; Metrics = 'routeMetrics'; Status = 'routePoolStatus'
            ExtensionHosts = 'routeExtensionHosts'; LabToken = 'routeLabToken'
        }
        foreach ($name in $expected.Keys) {
            $pattern = '(?m)^\s*' + [regex]::Escape($goConstant[$name]) + '\s*=\s*"' +
                [regex]::Escape($expected[$name]) + '"\s*$'
            Assert-Match $pattern $source "$($goConstant[$name]) must be $($expected[$name])"
        }
    }
}

Describe 'the service host pre-flights' {
    It 'brackets a bare IPv6 literal and leaves every other authority alone' {
        foreach ($area in $script:HostProbeArea.Keys) {
            foreach ($address in $script:AuthorityCase.Keys) {
                $url = Get-AreaProbeUrl -Area $area -Function $script:HostProbeArea[$area] -Address $address
                Assert-Equal $script:AuthorityCase[$address] $url "$area probing '$address'"
            }
        }
    }

    It 'builds identical URLs across the three areas' {
        # The three are copies of one design. When they diverge it is silent:
        # each area is exercised by a different cycle path, so the odd one out
        # only fails on the host that happens to use it.
        foreach ($address in $script:AuthorityCase.Keys) {
            $urls = @(foreach ($area in $script:HostProbeArea.Keys) {
                Get-AreaProbeUrl -Area $area -Function $script:HostProbeArea[$area] -Address $address
            })
            $distinct = @($urls | Sort-Object -Unique)
            Assert-Equal 1 $distinct.Count "'$address' produced $($distinct -join ' vs ')"
        }
    }
}

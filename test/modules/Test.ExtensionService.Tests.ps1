<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42b86905-6f08-4020-9f8c-68c7b31b76ef
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test extension service manifest marker sdk pester
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
    Pester coverage for the extension-service interface: the area manifests,
    the shared runtime marker, the derived VM roster, and the guard that keeps
    each service's mirrored copy of the Go SDK identical to the canonical one.
.DESCRIPTION
    Four properties carry the whole interface, and each of them is one wrong
    line away from failing silently:

      - the manifest reads WITHOUT a YAML parser, because the roster is imported
        on its own by the reboot sweep and by cleanup paths;
      - a marker advertises its address under both the uniform key and the
        area's own, so a consumer written against either resolves it;
      - the SDK mirrors are byte-identical to test/extension/extension-sdk/,
        or three services quietly drift apart again; and
      - the presence beacon runs at one cadence, declared identically wherever
        it is written down and bounded by the aggregator's health grace.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.ExtensionService.Tests.ps1
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$TestRoot = Split-Path -Parent $here
$script:RepoRoot = Split-Path -Parent $TestRoot
Import-Module (Join-Path $here 'Test.ExtensionService.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Go duration literals, limited to the units the extension-config schema's
# beaconInterval pattern admits.
function ConvertFrom-GoDuration {
    param(
        [Parameter(Position = 0)][string]$Duration,
        [Parameter(Position = 1)][string]$Site
    )
    if ($Duration -notmatch '^([0-9]+)(ns|us|ms|s|m|h)$') {
        throw "$Site is not a Go duration literal: '$Duration'"
    }
    $count = [double]$Matches[1]
    $unit  = $Matches[2]
    $scale = @{ ns = 1e-9; us = 1e-6; ms = 1e-3; s = 1; m = 60; h = 3600 }
    $count * $scale[$unit]
}


function ConvertFrom-GoConstDuration {
    param(
        [Parameter(Position = 0)][string]$Text,
        [Parameter(Position = 1)][string]$Pattern,
        [Parameter(Position = 2)][string]$Site
    )
    if ($Text -notmatch $Pattern) { throw "no $Site" }
    $count = [double]$Matches[1]
    $unit  = $Matches[2]
    $scale = @{ Nanosecond = 1e-9; Microsecond = 1e-6; Millisecond = 1e-3; Second = 1; Minute = 60; Hour = 3600 }
    if (-not $scale.ContainsKey($unit)) { throw "$Site names an unknown time unit '$unit'" }
    $count * $scale[$unit]
}

# Every place the three beaconing services write their cadence down. The
# aggregator is absent by design: it is the endpoint beacons are sent TO.
function Get-BeaconCadenceSite {
    param([Parameter(Position = 0)][string]$RepoRoot)

    foreach ($area in @('stash-service', 'pool-control-service', 'download-agent-service')) {
        $seed = [IO.Path]::Combine($RepoRoot, 'guest', 'ubuntu.server.26', "ubuntu.server.26.$area.sh")
        $text = Get-Content -Raw -LiteralPath $seed
        if ($text -notmatch 'PRESENCE_INTERVAL="\$\{[A-Z_]+:-([0-9a-z]+)\}"') {
            throw "no PRESENCE_INTERVAL default in $seed"
        }
        $literal = $Matches[1]
        [pscustomobject]@{
            Site    = "$area bring-up PRESENCE_INTERVAL"
            Literal = $literal
            Seconds = ConvertFrom-GoDuration -Duration $literal -Site "$area bring-up PRESENCE_INTERVAL"
        }

        $configGo = [IO.Path]::Combine($RepoRoot, 'test', 'extension', $area, 'server', 'internal', 'config', 'config.go')
        [pscustomobject]@{
            Site    = "$area DefaultPresenceInterval"
            Literal = 'the daemon constant'
            Seconds = ConvertFrom-GoConstDuration -Text (Get-Content -Raw -LiteralPath $configGo) `
                -Pattern 'DefaultPresenceInterval\s*=\s*([0-9]+)\s*\*\s*time\.([A-Za-z]+)' `
                -Site "DefaultPresenceInterval in $configGo"
        }

        $manifest = [IO.Path]::Combine($RepoRoot, 'test', 'extension', $area, "$area.config.yml")
        $text = Get-Content -Raw -LiteralPath $manifest
        if ($text -notmatch '(?m)^\s*beaconInterval:\s*([0-9a-z]+)\s*$') {
            throw "no beaconInterval in $manifest"
        }
        $literal = $Matches[1]
        [pscustomobject]@{
            Site    = "$area beaconInterval"
            Literal = $literal
            Seconds = ConvertFrom-GoDuration -Duration $literal -Site "$area beaconInterval"
        }
    }
}

}

Describe 'Get-ExtensionServiceManifest' {
    It 'reads a service block without a YAML parser' {
        # The reader never calls one: the roster is imported standalone by the
        # reboot sweep, where nothing has loaded a parser, and an empty roster
        # leaves a rebooted host's service VMs off.
        $body = Get-Content -Raw -LiteralPath (Join-Path $here 'Test.ExtensionService.psm1')
        Assert-False ($body -match 'ConvertFrom-Yaml') 'the manifest reader depends on no YAML parser'

        $m = Get-ExtensionServiceManifest -Area 'stash-service'
        Assert-True ($null -ne $m) 'stash-service declares a service manifest'
        Assert-Equal 'yuruna-stash-service' $m.VMName
        Assert-Equal 80 $m.HealthPort
        Assert-Equal 'Start-StashServiceVM.ps1' $m.StartScript
        Assert-Equal 'stashBaseUrl' $m.MarkerBaseUrlKey
        Assert-Equal '/healthz' $m.HealthPath
    }
    It 'returns nothing for an area that is not a service' {
        foreach ($area in @('authentication', 'notification')) {
            Assert-Equal $null (Get-ExtensionServiceManifest -Area $area) -Because "$area is code the cycle loads, not a service"
        }
    }
    It 'returns nothing for an area that does not exist' {
        Assert-Equal $null (Get-ExtensionServiceManifest -Area 'no-such-area')
    }
    It 'declares a write gate for every service with a destructive route' {
        # The rule the interface exists to make checkable: a route that rewrites
        # host or pool configuration, or destroys stored artifacts, takes the
        # lab token.
        $gates = @{}
        foreach ($m in (Get-ExtensionServiceManifestAll)) { $gates[$m.Area] = $m.WriteGate }
        foreach ($area in @('pool-control-service', 'download-agent-service', 'pool-aggregator-service')) {
            Assert-Equal 'lab-token' $gates[$area] -Because "$area changes host or pool configuration"
        }
        Assert-Equal 'lab-token' $gates['stash-service'] -Because 'deleting a stash destroys stored artifacts, pool-wide'
    }
    It 'gives every declared service a display name' {
        foreach ($m in (Get-ExtensionServiceManifestAll)) {
            Assert-True (-not [string]::IsNullOrWhiteSpace($m.DisplayName)) "$($m.Area) declares a displayName"
        }
    }
}

Describe 'Get-ExtensionServiceManifestAll' {
    It 'excludes a service that runs inside another area''s VM' {
        # The pool aggregator has no VM of its own -- it lives in the
        # caching-proxy VM -- so it must not appear in a roster of VMs to start.
        $withVm = @(Get-ExtensionServiceManifestAll -WithVMOnly | ForEach-Object { $_.Area })
        $all    = @(Get-ExtensionServiceManifestAll | ForEach-Object { $_.Area })
        Assert-True ($all -contains 'pool-aggregator-service')
        Assert-False ($withVm -contains 'pool-aggregator-service')
    }
    It 'covers the three service VMs' {
        $areas = @(Get-ExtensionServiceManifestAll -WithVMOnly | ForEach-Object { $_.Area })
        foreach ($area in @('stash-service', 'pool-control-service', 'download-agent-service')) {
            Assert-True ($areas -contains $area) "$area declares a VM"
        }
    }
}

Describe 'Get-ExtensionServiceVmRoster' {
    It 'keys each row by the area slug without its -service suffix' {
        $keys = @(Get-ExtensionServiceVmRoster | ForEach-Object { $_.Key })
        foreach ($key in @('stash', 'pool-control', 'download-agent')) {
            Assert-True ($keys -contains $key) "roster carries '$key'"
        }
    }
    It 'names a start script that exists' {
        # A manifest names the bare file; the service lifecycle scripts all live
        # in test/service/, so supplying the folder is the caller's job -- the
        # same resolution Invoke-PoolWorkerServiceTeardown performs on StopScript.
        $serviceDir = Join-Path $TestRoot 'service'
        foreach ($row in (Get-ExtensionServiceVmRoster)) {
            Assert-True (Test-Path -LiteralPath (Join-Path $serviceDir $row.StartScript)) "$($row.StartScript) exists"
        }
    }
}

Describe 'the runtime marker' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ext-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:dir -Force
    }
    AfterEach {
        if ($script:dir -and (Test-Path -LiteralPath $script:dir)) {
            Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes the address under BOTH the uniform key and the area''s own' {
        # A consumer built before the uniform key reads only the per-service one,
        # and a host can run a framework newer than the aggregator it reports to.
        $path = Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir `
            -Active $true -HostType 'host.windows.hyper-v' -BaseUrl 'http://10.0.0.9'
        Assert-True (Test-Path -LiteralPath $path)
        $m = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        Assert-Equal 'http://10.0.0.9' $m.baseUrl
        Assert-Equal 'http://10.0.0.9' $m.stashBaseUrl
        Assert-Equal 'yuruna-stash-service' $m.vmName -Because 'the VM name defaults from the manifest'
        Assert-Equal 'stash-service' $m.area
    }
    It 'is byte-stable across a re-write that changes nothing' {
        $stamp  = '2026-08-03T12:00:00Z'
        $params = @{ Area = 'stash-service'; RuntimeDir = $script:dir; Active = $true; BaseUrl = 'http://10.0.0.9'; StartedAtUtc = $stamp }
        $first  = Get-Content -Raw -LiteralPath (Write-ExtensionServiceMarker @params)
        $second = Get-Content -Raw -LiteralPath (Write-ExtensionServiceMarker @params)
        Assert-Equal $first $second -Because 'a marker rewritten with reshuffled keys reads as a change to everything that diffs it'
    }
    It 'appends service-specific extras in order' {
        $path = Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $script:dir `
            -Active $true -Extra ([ordered]@{ pid = 4242; port = 8081 })
        $m = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        Assert-Equal 4242 $m.pid
        Assert-Equal 8081 $m.port
    }
    It 'resolves the address from a legacy marker that has only the per-service key' {
        $legacy = [ordered]@{ active = $true; vmName = 'yuruna-stash-service'; stashBaseUrl = 'http://10.0.0.9' }
        [System.IO.File]::WriteAllText((Join-Path $script:dir 'stash-service.json'), ($legacy | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
        $m = Read-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir
        Assert-Equal 'http://10.0.0.9' (Get-ExtensionServiceMarkerBaseUrl -Marker $m -Area 'stash-service')
    }
    It 'reads nothing from an absent or malformed marker rather than throwing' {
        Assert-Equal $null (Read-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir)
        Set-Content -LiteralPath (Join-Path $script:dir 'stash-service.json') -Value '{not json'
        Assert-Equal $null (Read-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir)
        Assert-Equal '' (Get-ExtensionServiceMarkerBaseUrl -Marker $null -Area 'stash-service')
    }
    It 'removes a marker and reports whether one was there' {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir -Active $true)
        Assert-True  (Remove-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir -Confirm:$false)
        Assert-False (Remove-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir -Confirm:$false)
    }
}

Describe 'Get-ActiveExtensionService' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ext-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:dir -Force
    }
    AfterEach {
        if ($script:dir -and (Test-Path -LiteralPath $script:dir)) {
            Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports every marked service and its advertised target' {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir -Active $true -BaseUrl 'http://10.0.0.9')
        [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $script:dir -Active $true -BaseUrl 'http://10.0.0.11/')
        $active = Get-ActiveExtensionService -RuntimeDir $script:dir
        Assert-Equal 2 @($active.Areas).Count
        Assert-Equal 'http://10.0.0.9'  $active.Targets['stash-service']
        Assert-Equal 'http://10.0.0.11/' $active.Targets['pool-control-service']
    }
    It 'treats an explicit active:false as not running' {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:dir -Active $false -BaseUrl 'http://10.0.0.9')
        Assert-Equal 0 @((Get-ActiveExtensionService -RuntimeDir $script:dir).Areas).Count
    }
    It 'ignores a runtime file that is not an extension marker' {
        # The registration writer's runtime dir holds project.access.json and
        # host-network.json alongside the markers; reading either as a service
        # would advertise an area that does not exist.
        foreach ($name in @('project.access.json', 'host-network.json', 'status.json')) {
            Set-Content -LiteralPath (Join-Path $script:dir $name) -Value '{"active":true}'
        }
        Assert-Equal 0 @((Get-ActiveExtensionService -RuntimeDir $script:dir).Areas).Count
    }
    It 'reports nothing for an absent runtime dir rather than throwing' {
        $active = Get-ActiveExtensionService -RuntimeDir (Join-Path $script:dir 'nope')
        Assert-Equal 0 @($active.Areas).Count
    }
}

Describe 'the Go SDK is shared, not mirrored' {

    It 'leaves no copy of the SDK inside any service module' {
        # Mirroring the SDK into <service>/server/internal/yex would let each
        # daemon build from a copy of server/ alone -- at the price of 4,290
        # duplicated lines whose only guard is a byte-identity check. It stays
        # beside server/ as its own module instead.
        foreach ($goMod in (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test/extension') -Directory |
                ForEach-Object { Join-Path $_.FullName 'server/go.mod' } | Where-Object { Test-Path -LiteralPath $_ })) {
            $mirror = Join-Path (Split-Path -Parent $goMod) 'internal/yex'
            Assert-True (-not (Test-Path -LiteralPath $mirror)) "$mirror is a reintroduced SDK mirror; stage the module instead"
        }
    }

    It 'wires every Go service to the SDK module by path, not by copy' {
        # The three pieces that make the shared module resolve. A service with
        # the require but no replace builds only where the module is published;
        # one with neither silently falls back to looking for a directory that
        # is no longer there.
        $sdkPath = 'yuruna.com/test/extension/extension-sdk'
        $wired = 0
        foreach ($goMod in (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test/extension') -Directory |
                ForEach-Object { Join-Path $_.FullName 'server/go.mod' } | Where-Object { Test-Path -LiteralPath $_ })) {
            $text = Get-Content -Raw -LiteralPath $goMod
            $dir  = Split-Path -Parent $goMod
            $usesSdk = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.go' -ErrorAction SilentlyContinue |
                    Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match [regex]::Escape($sdkPath) })
            if ($usesSdk.Count -eq 0) { continue }
            $wired++
            Assert-Match -Pattern ([regex]::Escape($sdkPath)) -Actual $text -Because "$goMod imports the SDK but does not require it"
            Assert-Match -Pattern 'replace\s+yuruna\.com/test/extension/extension-sdk\s*=>\s*\.\./extension-sdk' -Actual $text `
                -Because "$goMod must resolve the SDK from the sibling the guest stages"
        }
        Assert-True ($wired -ge 3) "expected at least three services wired to the SDK, found $wired"
    }

    It 'installs the binary from the directory it built in' {
        # The bug this caught, in the only place it could be caught: moving the
        # build into $BUILD/server left `install "$BUILD/<name>"` pointing at the
        # old layout. go build succeeded, the binary existed, and the bring-up
        # died one line later with "install: No such file or directory" -- on the
        # guest, minutes into a VM boot. Build dir and install source must agree.
        $guestDir = Join-Path $script:RepoRoot 'guest/ubuntu.server.26'
        foreach ($s in (Get-ChildItem -LiteralPath $guestDir -File -Filter '*-service.sh' -ErrorAction SilentlyContinue)) {
            $text = Get-Content -Raw -LiteralPath $s.FullName
            if ($text -notmatch '\$BUILD/server') { continue }
            foreach ($m in [regex]::Matches($text, 'install[^\n]*?"(\$BUILD[^"]*)"')) {
                Assert-Match -Pattern '^\$BUILD/server/' -Actual $m.Groups[1].Value `
                    -Because "$($s.Name) builds in `$BUILD/server but installs from $($m.Groups[1].Value)"
            }
        }
    }

    It 'stages the SDK beside server in every guest bring-up' {
        # The replace directive points at ../extension-sdk, so the build dir must
        # hold BOTH. A bring-up that copies only server/ would fail to resolve
        # the module -- and would do so on the guest, long after the change.
        $guestDir = Join-Path $script:RepoRoot 'guest/ubuntu.server.26'
        $scripts  = @(Get-ChildItem -LiteralPath $guestDir -File -Filter '*-service.sh' -ErrorAction SilentlyContinue)
        Assert-True ($scripts.Count -ge 3) "expected the service bring-up scripts, found $($scripts.Count)"
        foreach ($s in $scripts) {
            $text = Get-Content -Raw -LiteralPath $s.FullName
            Assert-Match -Pattern 'SDK_DIR'                 -Actual $text -Because "$($s.Name) must locate the SDK"
            Assert-Match -Pattern '\$BUILD/extension-sdk'   -Actual $text -Because "$($s.Name) must stage the SDK beside server/"
            Assert-Match -Pattern '\$BUILD/server'          -Actual $text -Because "$($s.Name) must build from \$BUILD/server"
        }
    }
}

Describe 'the presence beacon cadence' {
    It 'is one value across bring-up, daemon default and manifest' {
        # Three kinds of file carry it and only two of them are code: the
        # bring-up default is what ships, the daemon constant applies when the
        # flag is absent, and the manifest value is read by nothing at runtime
        # -- so a manifest that drifts stays invisible until someone trusts it.
        $sites = @(Get-BeaconCadenceSite -RepoRoot $script:RepoRoot)
        Assert-Equal 9 $sites.Count 'three beaconing services, three declarations each'
        $spread = @($sites | ForEach-Object { $_.Seconds } | Sort-Object -Unique)
        Assert-Equal 1 $spread.Count ('one cadence expected; found ' +
            (($sites | ForEach-Object { "$($_.Site)=$($_.Seconds)s" }) -join ', '))
    }

    It 'stays under the aggregator extension health grace' {
        # A re-announce is also how a renumbered service reports its new
        # address. Beacon slower than the grace and the pool holds neither the
        # refused old address nor the unannounced new one, for the difference --
        # an area that resolves to nothing while the service is up the whole time.
        $mainGo = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'pool-aggregator-service', 'main.go')
        $grace = ConvertFrom-GoConstDuration -Text (Get-Content -Raw -LiteralPath $mainGo) `
            -Pattern 'extensionHealthGrace\s*=\s*([0-9]+)\s*\*\s*time\.([A-Za-z]+)' `
            -Site "extensionHealthGrace in $mainGo"
        Assert-True ($grace -gt 0) 'the aggregator declares a health grace'
        foreach ($site in (Get-BeaconCadenceSite -RepoRoot $script:RepoRoot)) {
            Assert-True ($site.Seconds -lt $grace) `
                "$($site.Site) is $($site.Seconds)s, not under the ${grace}s health grace"
        }
    }

    It 'is not declared by the aggregator, which never beacons' {
        # The aggregator links none of the beacon code, so a cadence in its
        # manifest would describe behavior the service does not have.
        $dir = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'pool-aggregator-service')
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $dir 'pool-aggregator-service.config.yml')
        Assert-False ($manifest -match '(?m)^\s*beaconInterval:') 'the aggregator manifest declares no beaconInterval'
        $beaconing = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.go' |
                Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'extension-sdk/beacon' })
        Assert-Equal 0 $beaconing.Count 'the aggregator imports no beacon package'
    }
}

Describe 'the caching-proxy seed fetches the sources it builds' {
    It 'names every Go file on disk, and none that is not' {
        # The seed fetches a NAMED list of files, one wget each, then runs
        # `go build .` over whatever landed. A source file added to -- or
        # renamed in -- the repo and not added here is simply never fetched:
        # the build fails on a 404-emptied file, the daemon is never installed,
        # and the only symptom is the panel it feeds staying empty on a VM that
        # otherwise came up clean.
        $seed = [IO.Path]::Combine($script:RepoRoot, 'host', 'vmconfig', 'caching-proxy-service.base.user-data')
        $text = Get-Content -Raw -LiteralPath $seed
        $loops = [regex]::Matches($text,
            'for f in (?<files>[^;]+); do\s+wget[^\n]*\$\{YR_BASE\}test/extension/(?<area>[A-Za-z0-9._-]+)/\$f')
        Assert-True ($loops.Count -ge 2) "expected the seed's per-service fetch loops, found $($loops.Count)"

        # What the daemons in this seed actually import from the shared SDK. The
        # SDK holds packages no VM here builds -- webui ships the browser
        # runtime for the three extension service UIs, which are separate VMs --
        # and fetching one of those would add a wget that can fail for a file
        # `go build` never opens.
        $daemonAreas = @($loops | ForEach-Object { $_.Groups['area'].Value } |
                Where-Object { $_ -ne 'extension-sdk' })
        $sdkImportPattern = 'yuruna\.com/test/extension/extension-sdk/(?<pkg>[A-Za-z0-9._-]+)'
        $importedPackages = [Collections.Generic.HashSet[string]]::new()
        foreach ($area in $daemonAreas) {
            $dir = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', $area)
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $dir -File -Filter '*.go' -Recurse -ErrorAction SilentlyContinue)) {
                foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $file.FullName), $sdkImportPattern)) {
                    [void]$importedPackages.Add($m.Groups['pkg'].Value)
                }
            }
        }
        # The set has to be what `go build` RESOLVES, not what the daemons name.
        # One SDK package importing another is compiled just the same, and a
        # package reached only that way appears in no file this seed fetches --
        # so a direct-imports-only set leaves it unstaged, the guest build fails
        # on a package nothing here mentions, and this gate passes while it does.
        # Walk to a fixed point. Test files are skipped: the guest compiles none
        # of them, so an import that only a test makes is not the seed's to stage.
        $sdkDir = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk')
        $pending = [Collections.Generic.Queue[string]]::new()
        foreach ($pkg in $importedPackages) { $pending.Enqueue($pkg) }
        while ($pending.Count -gt 0) {
            $pkgDir = [IO.Path]::Combine($sdkDir, $pending.Dequeue())
            if (-not (Test-Path -LiteralPath $pkgDir)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $pkgDir -File -Filter '*.go' -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notlike '*_test.go' })) {
                foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $file.FullName), $sdkImportPattern)) {
                    if ($importedPackages.Add($m.Groups['pkg'].Value)) { $pending.Enqueue($m.Groups['pkg'].Value) }
                }
            }
        }

        foreach ($loop in $loops) {
            $area   = $loop.Groups['area'].Value
            $listed = @($loop.Groups['files'].Value -split '\s+' | Where-Object { $_ })
            $dir    = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', $area)
            Assert-True (Test-Path -LiteralPath $dir) "the seed fetches from test/extension/$area, which exists"

            foreach ($name in $listed) {
                Assert-True (Test-Path -LiteralPath (Join-Path $dir $name)) `
                    "$area : the seed fetches '$name', which is not in the repo"
            }
            # Test files are deliberately absent: `go build` never compiles
            # them, and fetching them would only add wgets that can fail.
            #
            # A loop whose names carry a slash is fetching a package tree -- the
            # shared SDK is fetched that way -- so the on-disk side has to walk
            # the tree too. Checking only the root would pass an SDK loop
            # vacuously, which is the shape of the bug this test exists for.
            $nested  = @($listed | Where-Object { $_ -match '/' }).Count -gt 0
            $params  = @{ LiteralPath = $dir; File = $true; Filter = '*.go'; ErrorAction = 'SilentlyContinue' }
            if ($nested) { $params['Recurse'] = $true }
            $sources = @(Get-ChildItem @params |
                    Where-Object { $_.Name -notlike '*_test.go' } |
                    ForEach-Object { ([IO.Path]::GetRelativePath($dir, $_.FullName)) -replace '\\', '/' })
            foreach ($name in $sources) {
                # An SDK package nothing here imports is not this seed's to
                # fetch. It is still covered: it has to be imported by SOME
                # daemon to exist, and that daemon's own bring-up stages the
                # whole SDK directory.
                if ($area -eq 'extension-sdk' -and $name -match '/') {
                    $pkg = ($name -split '/')[0]
                    if (-not $importedPackages.Contains($pkg)) { continue }
                }
                Assert-True ($listed -contains $name) `
                    "$area : $name is part of the daemon but the seed never fetches it"
            }
        }

        # The narrowing above must not be able to swallow the whole check: at
        # least one SDK package has to be reached this way, or a seed that
        # fetched nothing from the SDK would pass in silence.
        Assert-True ($importedPackages.Count -gt 0) 'the daemons in this seed import no SDK package at all'
    }
}

Describe 'the caching-proxy management daemon ships runnable' {
    It 'permits the address family its own hostinfo route needs' {
        # /api/hostinfo enumerates this host's addresses, and Go reads the
        # interface table over a NETLINK socket. A unit that lists only
        # AF_INET/AF_INET6/AF_UNIX makes net.Interfaces() fail with "address
        # family not supported by protocol", and the daemon then reports no
        # addresses at all -- silently, because the enumeration error is folded
        # into an empty result by design. Its two neighbors in that VM never
        # enumerate, which is why they can restrict harder.
        $unit = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'caching-proxy-service', 'caching-proxy-service.service')
        $text = Get-Content -Raw -LiteralPath $unit
        if ($text -match '(?m)^RestrictAddressFamilies=(.*)$') {
            $families = @($Matches[1] -split '\s+' | Where-Object { $_ })
            Assert-True ($families -contains 'AF_NETLINK') `
                "the unit restricts address families to '$($families -join ' ')' but the daemon enumerates interfaces"
        }
    }

    It 'is told an aggregator it can actually announce to' {
        # The caching-proxy VM has NO /etc/yuruna/pool.env -- that file is baked
        # into the service VMs that must be told where the aggregator is, and
        # this VM is where the aggregator runs. Reading it here yielded an empty
        # URL, which disables the beacon, and the area then never appears in the
        # pool at all while every endpoint still answers.
        #
        # Loopback is equally wrong and fails differently: the announce handler
        # derives the advertised URL from the request's source address and
        # refuses a loopback one, so the beacon would be sent and rejected.
        $seed = [IO.Path]::Combine($script:RepoRoot, 'host', 'vmconfig', 'caching-proxy-service.base.user-data')
        $text = Get-Content -Raw -LiteralPath $seed
        Assert-True ($text -match '(?m)^\s*CPS_AGG=.*$') 'the seed sets an aggregator URL for the daemon'
        Assert-False ($text -match 'CPS_AGG=[^\n]*pool\.env') `
            'the caching-proxy VM has no pool.env; deriving the aggregator URL from it yields an empty value and kills the beacon'
        Assert-False ($text -match 'CACHING_PROXY_AGGREGATOR_URL=[^\n]*127\.0\.0\.1') `
            'the announce handler refuses a loopback source address, so a loopback aggregator URL beacons into a rejection'
    }
}

Describe 'no built binary is tracked under test/extension' {
    It 'keeps compiled output out of the repository' {
        # The two area-ROOT Go modules build into a tracked directory, so
        # `go build` in the enlistment drops a binary beside the source. Each
        # needs its own .gitignore line; the module under server/ does not,
        # which is why the omission is easy to make and invisible once made --
        # nothing fails, the repository just grows by ten megabytes.
        $tracked = @(git -C $script:RepoRoot ls-files 'test/extension' |
                Where-Object { $_ -and $_ -notmatch '\.(go|mod|sum|yml|yaml|md|psm1|ps1|json|service|html|css|js|txt|template|png|svg|ico)$' })
        $binaries = @($tracked | Where-Object {
                $full = Join-Path $script:RepoRoot $_
                (Test-Path -LiteralPath $full) -and ((Get-Item -LiteralPath $full).Length -gt 1MB)
            })
        Assert-Equal 0 $binaries.Count "these look like build output and are tracked: $($binaries -join ', ')"
    }
}

Describe 'service readiness timeout overrides' {
    It 'shares positive-integer override behavior across the service areas' {
        foreach ($area in 'stash-service', 'pool-control-service', 'download-agent-service') {
            $variable = 'YURUNA_' + $area.ToUpperInvariant().Replace('-', '_') + '_READY_TIMEOUT_SECONDS'
            $previous = [Environment]::GetEnvironmentVariable($variable)
            try {
                foreach ($value in @('', ' ', 'invalid', '0', '-1', '2147483648')) {
                    [Environment]::SetEnvironmentVariable($variable, $value)
                    Assert-Equal -Expected 2700 -Actual (Get-ExtensionServiceReadyTimeoutSeconds -Area $area) `
                        -Because "$area must retain its default for '$value'"
                }
                [Environment]::SetEnvironmentVariable($variable, '120')
                Assert-Equal -Expected 120 -Actual (Get-ExtensionServiceReadyTimeoutSeconds -Area $area) `
                    -Because "$area must honor a valid override"
                [Environment]::SetEnvironmentVariable($variable, '')
                Assert-Equal -Expected 90 -Actual (Get-ExtensionServiceReadyTimeoutSeconds -Area $area -DefaultSeconds 90) `
                    -Because "$area must honor the caller's fallback"
            } finally { [Environment]::SetEnvironmentVariable($variable, $previous) }
        }
    }
}

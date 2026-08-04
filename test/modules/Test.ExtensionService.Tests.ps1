<#PSScriptInfo
.VERSION 2026.08.04
.GUID 4290bd41-6c73-4e58-a12f-95b0e3c7d846
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
    Three properties carry the whole interface, and each of them is one wrong
    line away from failing silently:

      - the manifest reads WITHOUT a YAML parser, because the roster is imported
        on its own by the reboot sweep and by cleanup paths;
      - a marker advertises its address under both the uniform key and the
        area's own, so a consumer written against either resolves it; and
      - the SDK mirrors are byte-identical to test/extension/extension-sdk/,
        or three services quietly drift apart again.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.ExtensionService.Tests.ps1
#>

$here     = Split-Path -Parent $PSCommandPath
$TestRoot = Split-Path -Parent $here
$RepoRoot = Split-Path -Parent $TestRoot
Import-Module (Join-Path $here 'Test.ExtensionService.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

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
    It 'declares a write gate for every service that changes configuration' {
        # The rule the interface exists to make checkable: a route that rewrites
        # host or pool configuration takes the lab token.
        $gates = @{}
        foreach ($m in (Get-ExtensionServiceManifestAll)) { $gates[$m.Area] = $m.WriteGate }
        foreach ($area in @('pool-control-service', 'download-agent-service', 'pool-aggregator-service')) {
            Assert-Equal 'lab-token' $gates[$area] -Because "$area changes host or pool configuration"
        }
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
        foreach ($row in (Get-ExtensionServiceVmRoster)) {
            Assert-True (Test-Path -LiteralPath (Join-Path $TestRoot $row.StartScript)) "$($row.StartScript) exists"
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

Describe 'the Go SDK mirrors' {
    It 'are byte-identical to the canonical extension-sdk' {
        # One SDK, copied into each service module because each daemon is built
        # inside its own VM from a copy of <area>/server/ alone. The copy is
        # generated (tools/Sync-ExtensionSdk.ps1); this is what keeps it honest.
        $sync = Join-Path $RepoRoot 'tools/Sync-ExtensionSdk.ps1'
        Assert-True (Test-Path -LiteralPath $sync) 'the sync script exists'
        & pwsh -NoProfile -File $sync -RepoRoot $RepoRoot -Verify 2>&1 | Out-Null
        Assert-Equal 0 $LASTEXITCODE -Because 'run: pwsh -NoProfile -File tools/Sync-ExtensionSdk.ps1'
    }
    It 'reach every service that builds a Go daemon' {
        $sdk = Join-Path $RepoRoot 'test/extension/extension-sdk'
        Assert-True (Test-Path -LiteralPath $sdk) 'the canonical SDK exists'
        foreach ($goMod in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'test/extension') -Directory |
                ForEach-Object { Join-Path $_.FullName 'server/go.mod' } | Where-Object { Test-Path -LiteralPath $_ })) {
            $mirror = Join-Path (Split-Path -Parent $goMod) 'internal/yex'
            Assert-True (Test-Path -LiteralPath $mirror) "$mirror carries the SDK mirror"
        }
    }
}

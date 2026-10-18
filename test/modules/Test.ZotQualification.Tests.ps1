<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42888b3c-4df7-4b33-bf5a-50441fbf3725
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache registry zot release qualification pester
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
    Refuses a caching-proxy seed whose zot pin, zot configuration or probe
    list has no passing live sync on record.
.DESCRIPTION
    A zot release can accept the seed's configuration and still refuse every
    image of a manifest format that configuration does not allow: zot 2.1.22
    answered HTTP 503 for every registry.k8s.io image until http.compat listed
    docker2s2, while GET /v2/ and `zot verify` both passed. Only a real sync
    qualifies a release, and that needs the network and a zot binary.
    tools/Test-ZotRelease.py runs it and records the pass with a fingerprint of
    what it tested.

    This suite needs neither: it recomputes the fingerprint from the seed the
    way the tool does and compares it with the record, so it runs on every host
    the release gate runs on, Windows included. A failure here means the pin,
    the configuration or the probe list changed without a live sync -- the
    pre-commit hook was bypassed or not installed.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RecordPath = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.zot-qualified.json'
    $script:SeedLines = @(Get-Content -LiteralPath (Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data'))
    $script:SeedText = $script:SeedLines -join "`n"
    $script:Remedy = 'run python3 tools/Test-ZotRelease.py (it needs internet and downloads the pinned zot release once), ' +
        'then commit host/vmconfig/caching-proxy-service.zot-qualified.json; with the pre-commit hook active, ' +
        'committing the seed does both'

    # The dedented body of one write_files entry, read exactly as
    # tools/Test-ZotRelease.py reads it, so both fingerprint the same text.
    function Get-SeedFileBody {
        param([Parameter(Mandatory)][string]$Path)
        $lines = $script:SeedLines
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

    function Get-SeedPin {
        param([Parameter(Mandatory)][string]$Name)
        $found = [regex]::Matches($script:SeedText, '(?m)^\s*' + $Name + '="([^"]+)"\s*$')
        if ($found.Count -ne 1) { throw "The seed must set $Name=`"...`" exactly once; it does so $($found.Count) times." }
        return $found[0].Groups[1].Value
    }

    $script:Pin = [ordered]@{
        Version = Get-SeedPin -Name 'ZOT_VERSION'
        Amd64   = Get-SeedPin -Name 'ZOT_SHA256_AMD64'
        Arm64   = Get-SeedPin -Name 'ZOT_SHA256_ARM64'
    }
    $script:Probes = Get-SeedFileBody -Path '/etc/zot/yuruna-sync-probes.list'
    $fingerprintText = "zot_version=$($script:Pin.Version)`nzot_sha256_amd64=$($script:Pin.Amd64)`nzot_sha256_arm64=$($script:Pin.Arm64)`n" +
        "[/etc/zot/config.json]`n$(Get-SeedFileBody -Path '/etc/zot/config.json')" +
        "[/etc/zot/yuruna-sync-probes.list]`n$($script:Probes)"
    $script:Fingerprint = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprintText))).ToLowerInvariant()
    $script:Record = if (Test-Path -LiteralPath $script:RecordPath) {
        Get-Content -Raw -LiteralPath $script:RecordPath | ConvertFrom-Json -AsHashtable
    }
}

Describe 'The zot release the caching-proxy seed pins passed a live sync' {
    It 'has a qualification record' {
        $script:Record | Should -Not -BeNullOrEmpty -Because "a seed without one was never synced through its zot release; $($script:Remedy)"
    }

    It 'records a pass for exactly this pin, zot configuration and probe list' {
        $script:Record.fingerprint | Should -Be $script:Fingerprint -Because (
            "the zot pin, the zot configuration or the probe list changed after zot $($script:Record.zotVersion) was qualified, " +
            "and a zot release can accept a configuration it then refuses to sync with; $($script:Remedy)")
    }

    It 'records the release and both binary checksums the seed installs' {
        $script:Record.zotVersion | Should -Be $script:Pin.Version
        $script:Record.sha256.amd64 | Should -Be $script:Pin.Amd64
        $script:Record.sha256.arm64 | Should -Be $script:Pin.Arm64
    }

    It 'records a sync of every probe image the seed lists' {
        $listed = @(foreach ($line in $script:Probes -split "`n") {
                $fields = @(($line -replace '#.*$', '').Trim() -split '\s+' | Where-Object { $_ })
                if ($fields.Count -eq 3) { '{0}/{1}:{2}' -f $fields[0], $fields[1], $fields[2] }
            })
        $listed.Count | Should -BeGreaterThan 0
        @($script:Record.probes | ForEach-Object { $_.image }) | Should -Be $listed
        # Both manifest formats the lab's registries publish: a release that
        # refuses one refuses every image in it.
        $formats = @($script:Record.probes | ForEach-Object { $_.mediaType } | Sort-Object -Unique)
        $formats | Should -Contain 'application/vnd.docker.distribution.manifest.list.v2+json'
        $formats | Should -Contain 'application/vnd.oci.image.index.v1+json'
    }
}

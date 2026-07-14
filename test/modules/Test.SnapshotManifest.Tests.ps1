<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42bf9cc9-1b2b-499b-90cc-a4c2c9b939aa
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test snapshot manifest sidecar pester
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
    Pester coverage for Test.SnapshotManifest.psm1: the manifest sidecar that
    lets loadDiskSnapshot / recoverFromSnapshot refuse a snapshot Yuruna no
    longer recognizes.
.DESCRIPTION
    The restore-gate policy is the contract under test:

      * missing   -> warn and PROCEED (snapshots taken by older builds have
                     no manifest; the operator's expectation is not to abort).
      * mismatch  -> REFUSE (identity drift: different VM, different snapshot
                     id, or a different hypervisor platform).
      * ok        -> restore.

    So the tests exercise the write/read round-trip, the provenance fields, the
    three Status outcomes and the edges around them (case-insensitive HostType,
    a manifest written before HostType existed, a corrupt file, a hand-edited
    file at the canonical path), plus the -WhatIf paths.

    All state lands under a temp YURUNA_RUNTIME_DIR created in BeforeAll and
    removed in AfterAll. Nothing is written into the repo tree.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.SnapshotManifest.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.SnapshotManifest.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures and helpers at FILE scope, above the first Describe: a Describe body
# runs during discovery and its variables/functions never reach an It. The temp
# directory itself is a side effect, so it is created in BeforeAll instead --
# a file-scope temp dir is built and torn down during discovery, and the It then
# probes a path that no longer exists.

function Set-YurunaProvenanceGlobal {
    <#
    .SYNOPSIS
        Set (or clear, with $null) the cycle/run provenance globals that
        Write-SnapshotManifest stamps into the manifest.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: the module reads global:__YurunaCycleId / __YurunaRunId by design.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([AllowNull()][string]$CycleId, [AllowNull()][string]$RunId)
    if (-not $PSCmdlet.ShouldProcess('Yuruna provenance globals', 'Set')) { return }
    $global:__YurunaCycleId = $CycleId
    $global:__YurunaRunId   = $RunId
}

function Write-RawManifest {
    <#
    .SYNOPSIS
        Drop arbitrary bytes at the canonical manifest path for
        (VMName, SnapshotId), bypassing Write-SnapshotManifest. Models a
        hand-edited / truncated / cross-VM-copied sidecar.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writing into a temp dir owned by this suite.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $path = Get-SnapshotManifestPath -VMName $VMName -SnapshotId $SnapshotId
    Set-Content -LiteralPath $path -Value $Content -NoNewline
    return $path
}

BeforeAll {
    $runtimeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-snapman-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    $savedRuntimeDir = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = $runtimeRoot
    $snapshotDir = Join-Path $runtimeRoot 'snapshots'
    # AfterAll restores the displaced value: a leaked YURUNA_RUNTIME_DIR would
    # silently relocate the state of everything that runs after this file.
    Write-Verbose "YURUNA_RUNTIME_DIR: '$savedRuntimeDir' -> '$runtimeRoot'; manifests expected under '$snapshotDir'"
    if (Test-Path -LiteralPath $snapshotDir) { throw "Precondition: '$snapshotDir' must not exist before the first Get-SnapshotManifestDir call." }
}

AfterAll {
    $env:YURUNA_RUNTIME_DIR = $savedRuntimeDir
    Set-YurunaProvenanceGlobal -CycleId $null -RunId $null -Confirm:$false
    if ($runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot)) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-SnapshotManifestDir / Get-SnapshotManifestPath' {
    It 'creates the snapshots subdirectory under the runtime dir on first use' {
        $dir = Get-SnapshotManifestDir -Confirm:$false
        Assert-Equal -Expected $snapshotDir -Actual $dir
        Assert-True (Test-Path -LiteralPath $dir) 'the directory must exist after the call'
        # Snapshots outlive the cycle that took them, so the directory has to
        # survive being asked for twice.
        Assert-Equal -Expected $dir -Actual (Get-SnapshotManifestDir -Confirm:$false)
        Assert-True (Test-Path -LiteralPath $dir) 'a second call must not disturb the directory'
    }
    It 'names the manifest <vm>__<snapshot>.manifest.json' {
        $path = Get-SnapshotManifestPath -VMName 'yuruna-ubuntu-01' -SnapshotId 'pre-upgrade'
        Assert-Equal -Expected (Join-Path $snapshotDir 'yuruna-ubuntu-01__pre-upgrade.manifest.json') -Actual $path
    }
    It 'keeps the double-underscore separator unambiguous when the VM name has dots and dashes' {
        # The separator exists so the file name stays greppable: a VM named
        # 'web.stage-01' must not be confusable with a snapshot id.
        $path = Get-SnapshotManifestPath -VMName 'web.stage-01' -SnapshotId '2026-07-13.pre-patch'
        Assert-Equal -Expected 'web.stage-01__2026-07-13.pre-patch.manifest.json' -Actual (Split-Path -Leaf $path)
        Assert-Equal -Expected 1 -Actual ([regex]::Matches((Split-Path -Leaf $path), '__').Count) `
            -Because 'exactly one separator, so a split on __ recovers (vmName, snapshotId)'
    }
    It 'is a pure function of (VMName, SnapshotId)' {
        Assert-Equal -Expected (Get-SnapshotManifestPath -VMName 'vm1' -SnapshotId 's1') `
                     -Actual   (Get-SnapshotManifestPath -VMName 'vm1' -SnapshotId 's1')
        Assert-True ((Get-SnapshotManifestPath -VMName 'vm1' -SnapshotId 's1') -ne
                     (Get-SnapshotManifestPath -VMName 'vm2' -SnapshotId 's1')) 'a different VM is a different manifest'
        Assert-True ((Get-SnapshotManifestPath -VMName 'vm1' -SnapshotId 's1') -ne
                     (Get-SnapshotManifestPath -VMName 'vm1' -SnapshotId 's2')) 'a different snapshot is a different manifest'
    }
}

Describe 'Write-SnapshotManifest / Get-SnapshotManifest' {
    AfterEach { Set-YurunaProvenanceGlobal -CycleId $null -RunId $null -Confirm:$false }

    It 'round-trips the identity and provenance a restore has to check' {
        Set-YurunaProvenanceGlobal -CycleId 'cycle-000123' -RunId 'run-abc' -Confirm:$false
        $path = Write-SnapshotManifest -VMName 'vm-roundtrip' -SnapshotId 'snap-1' -HostType 'host.windows.hyper-v' -Confirm:$false
        Assert-True ($null -ne $path) 'a successful write returns the manifest path'
        Assert-True (Test-Path -LiteralPath $path) 'the manifest file must exist on disk'

        $m = Get-SnapshotManifest -VMName 'vm-roundtrip' -SnapshotId 'snap-1'
        Assert-True ($m -is [hashtable]) 'the manifest reads back as a hashtable'
        Assert-Equal -Expected 'vm-roundtrip'          -Actual $m['vmName']
        Assert-Equal -Expected 'snap-1'                -Actual $m['snapshotId']
        Assert-Equal -Expected 'host.windows.hyper-v'  -Actual $m['hostType']
        Assert-Equal -Expected ([System.Net.Dns]::GetHostName()) -Actual $m['hostName']
        Assert-Equal -Expected $PID                    -Actual $m['writerPid']
        Assert-Equal -Expected 1                       -Actual $m['manifestVersion']
        Assert-Equal -Expected 'cycle-000123'          -Actual $m['cycleId'] -Because 'the taking cycle is the audit trail'
        Assert-Equal -Expected 'run-abc'               -Actual $m['runId']
        Assert-True  ([datetime]::Parse([string]$m['takenAtUtc'], $null, [Globalization.DateTimeStyles]::RoundtripKind) -le (Get-Date).ToUniversalTime().AddMinutes(1)) `
            'takenAtUtc must be a parseable instant, not in the future'
    }
    It 'records a null cycleId / runId when the cycle globals are not set' {
        Set-YurunaProvenanceGlobal -CycleId $null -RunId $null -Confirm:$false
        $null = Write-SnapshotManifest -VMName 'vm-nocycle' -SnapshotId 'snap-1' -Confirm:$false
        $m = Get-SnapshotManifest -VMName 'vm-nocycle' -SnapshotId 'snap-1'
        Assert-Equal -Expected $null -Actual $m['cycleId'] -Because 'a snapshot taken outside a cycle has no cycle id to claim'
        Assert-Equal -Expected $null -Actual $m['runId']
        Assert-Equal -Expected ''    -Actual $m['hostType'] -Because 'HostType defaults to empty, not absent'
    }
    It 'merges the Extra fields into the manifest' {
        $null = Write-SnapshotManifest -VMName 'vm-extra' -SnapshotId 'snap-1' -HostType 'host.ubuntu.kvm' `
            -Extra @{ cycleHostInfoSha = 'deadbeef'; guestOs = 'ubuntu-24.04' } -Confirm:$false
        $m = Get-SnapshotManifest -VMName 'vm-extra' -SnapshotId 'snap-1'
        Assert-Equal -Expected 'deadbeef'     -Actual $m['cycleHostInfoSha']
        Assert-Equal -Expected 'ubuntu-24.04' -Actual $m['guestOs']
        Assert-Equal -Expected 'vm-extra'     -Actual $m['vmName'] -Because 'Extra must not displace the identity fields'
    }
    It 'overwrites the manifest in place when the same snapshot id is retaken' {
        $null = Write-SnapshotManifest -VMName 'vm-retake' -SnapshotId 'snap-1' -HostType 'host.macos.utm' -Extra @{ gen = 'first' } -Confirm:$false
        $null = Write-SnapshotManifest -VMName 'vm-retake' -SnapshotId 'snap-1' -HostType 'host.macos.utm' -Extra @{ gen = 'second' } -Confirm:$false
        $m = Get-SnapshotManifest -VMName 'vm-retake' -SnapshotId 'snap-1'
        Assert-Equal -Expected 'second' -Actual $m['gen'] -Because 'the manifest describes the snapshot that is on disk now'
    }
    It 'leaves no temp file behind: the write is temp+rename' {
        $null = Write-SnapshotManifest -VMName 'vm-atomic' -SnapshotId 'snap-1' -Confirm:$false
        $orphans = @(Get-ChildItem -LiteralPath $snapshotDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
        Assert-Equal -Expected 0 -Actual $orphans.Count -Because 'a stale .tmp means the rename leg failed'
    }
    It 'writes nothing under -WhatIf' {
        $path = Get-SnapshotManifestPath -VMName 'vm-whatif' -SnapshotId 'snap-1'
        $r = Write-SnapshotManifest -VMName 'vm-whatif' -SnapshotId 'snap-1' -HostType 'host.ubuntu.kvm' -WhatIf
        Assert-Equal -Expected $null -Actual $r -Because 'a declined write reports no path'
        Assert-True (-not (Test-Path -LiteralPath $path)) '-WhatIf must not touch the filesystem'
    }
    It 'returns $null for a snapshot that has no manifest' {
        Assert-Equal -Expected $null -Actual (Get-SnapshotManifest -VMName 'vm-never-written' -SnapshotId 'nope')
    }
    It 'returns $null for a corrupt or empty sidecar instead of throwing' {
        # A half-written manifest must not take the restore handler down with a
        # parse exception; it degrades to "no manifest".
        foreach ($garbage in @('not json {{', '', '   ', '[1,2,3]')) {
            $null = Write-RawManifest -VMName 'vm-corrupt' -SnapshotId 'snap-1' -Content $garbage
            Assert-Equal -Expected $null -Actual (Get-SnapshotManifest -VMName 'vm-corrupt' -SnapshotId 'snap-1') `
                -Because "unparseable payload [$garbage] must read back as no manifest"
        }
    }
}

Describe 'Test-SnapshotManifestMatch: the restore gate' {
    It 'reports ok when the manifest matches the requested tuple' {
        $null = Write-SnapshotManifest -VMName 'vm-ok' -SnapshotId 'snap-1' -HostType 'host.windows.hyper-v' -Confirm:$false
        $r = Test-SnapshotManifestMatch -VMName 'vm-ok' -SnapshotId 'snap-1' -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected 'ok' -Actual $r.Status
        Assert-Equal -Expected 0 -Actual @($r.Violations).Count
        Assert-Equal -Expected 'vm-ok' -Actual $r.Manifest['vmName'] -Because 'the caller gets the manifest it validated'
        Assert-Equal -Expected (Get-SnapshotManifestPath -VMName 'vm-ok' -SnapshotId 'snap-1') -Actual $r.ManifestPath
    }
    It 'compares the platform case-insensitively' {
        $null = Write-SnapshotManifest -VMName 'vm-case' -SnapshotId 'snap-1' -HostType 'host.windows.hyper-v' -Confirm:$false
        Assert-Equal -Expected 'ok' -Actual (Test-SnapshotManifestMatch -VMName 'vm-case' -SnapshotId 'snap-1' -HostType 'HOST.Windows.Hyper-V').Status
    }
    It 'reports missing (not mismatch) when there is no manifest at all' {
        # Policy: pre-existing snapshots from older builds have no sidecar. The
        # handler warns and proceeds -- so this must never be reported as drift.
        $r = Test-SnapshotManifestMatch -VMName 'vm-legacy' -SnapshotId 'snap-1' -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'missing' -Actual $r.Status
        Assert-Equal -Expected $null -Actual $r.Manifest
        Assert-Equal -Expected 0 -Actual @($r.Violations).Count
        Assert-True ($r.ManifestPath -match 'vm-legacy__snap-1\.manifest\.json$') 'the caller still gets the path it looked for'
    }
    It 'refuses a snapshot taken on a different hypervisor platform' {
        # The binary may still exist under a UTM bundle name; restoring it on a
        # Hyper-V host is what this gate is for.
        $null = Write-SnapshotManifest -VMName 'vm-cross' -SnapshotId 'snap-1' -HostType 'host.macos.utm' -Confirm:$false
        $r = Test-SnapshotManifestMatch -VMName 'vm-cross' -SnapshotId 'snap-1' -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected 'mismatch' -Actual $r.Status
        Assert-Equal -Expected 1 -Actual @($r.Violations).Count
        Assert-True (@($r.Violations) -match 'hostType mismatch') 'the violation must name the field'
        Assert-True (@($r.Violations) -match 'host\.macos\.utm')  'the violation must quote the manifest value'
        Assert-True (@($r.Violations) -match 'host\.windows\.hyper-v') 'the violation must quote the current platform'
    }
    It 'refuses a manifest whose recorded identity drifted from the file it sits next to' {
        # Same canonical path, different contents: a sidecar copied across VMs,
        # or hand-edited. The snapshot is no longer the one Yuruna took.
        $null = Write-RawManifest -VMName 'vm-drift' -SnapshotId 'snap-1' `
            -Content '{"vmName":"some-other-vm","snapshotId":"some-other-snap","hostType":"host.ubuntu.kvm","manifestVersion":1}'
        $r = Test-SnapshotManifestMatch -VMName 'vm-drift' -SnapshotId 'snap-1' -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'mismatch' -Actual $r.Status
        Assert-Equal -Expected 2 -Actual @($r.Violations).Count -Because 'both the vmName and the snapshotId drifted'
        Assert-True (@($r.Violations) -match 'vmName mismatch')     'vmName drift must be reported'
        Assert-True (@($r.Violations) -match 'snapshotId mismatch') 'snapshotId drift must be reported'
    }
    It 'collects every violation, not just the first' {
        $null = Write-RawManifest -VMName 'vm-multi' -SnapshotId 'snap-1' `
            -Content '{"vmName":"nope","snapshotId":"nope","hostType":"host.macos.utm","manifestVersion":1}'
        $r = Test-SnapshotManifestMatch -VMName 'vm-multi' -SnapshotId 'snap-1' -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected 3 -Actual @($r.Violations).Count -Because 'the operator should see the whole delta in one refusal'
    }
    It 'skips the platform check for a manifest written before hostType existed' {
        # Documented allowance: a manifest with no (or empty) hostType is treated
        # as a missing field, not as drift. Only an actively-different platform
        # is a mismatch.
        $null = Write-RawManifest -VMName 'vm-earlyadopter' -SnapshotId 'snap-1' `
            -Content '{"vmName":"vm-earlyadopter","snapshotId":"snap-1","manifestVersion":1}'
        Assert-Equal -Expected 'ok' -Actual (Test-SnapshotManifestMatch -VMName 'vm-earlyadopter' -SnapshotId 'snap-1' -HostType 'host.windows.hyper-v').Status

        $null = Write-RawManifest -VMName 'vm-blankhost' -SnapshotId 'snap-1' `
            -Content '{"vmName":"vm-blankhost","snapshotId":"snap-1","hostType":"","manifestVersion":1}'
        Assert-Equal -Expected 'ok' -Actual (Test-SnapshotManifestMatch -VMName 'vm-blankhost' -SnapshotId 'snap-1' -HostType 'host.ubuntu.kvm').Status
    }
    It 'skips the platform check when the caller does not supply a HostType' {
        $null = Write-SnapshotManifest -VMName 'vm-nohosttype' -SnapshotId 'snap-1' -HostType 'host.macos.utm' -Confirm:$false
        Assert-Equal -Expected 'ok' -Actual (Test-SnapshotManifestMatch -VMName 'vm-nohosttype' -SnapshotId 'snap-1').Status `
            -Because 'a caller that cannot name its platform must not be told the snapshot drifted'
    }
    It 'degrades a corrupt manifest to missing, so the restore is warned about but not blocked' {
        $null = Write-RawManifest -VMName 'vm-badjson' -SnapshotId 'snap-1' -Content '{"vmName":"vm-badjson",'
        $r = Test-SnapshotManifestMatch -VMName 'vm-badjson' -SnapshotId 'snap-1' -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 'missing' -Actual $r.Status
        Assert-True (Test-Path -LiteralPath $r.ManifestPath) 'the file is there; it just cannot be read'
    }
}

Describe 'Remove-SnapshotManifest' {
    It 'removes an existing manifest once and reports nothing to do the second time' {
        $null = Write-SnapshotManifest -VMName 'vm-remove' -SnapshotId 'snap-1' -Confirm:$false
        $path = Get-SnapshotManifestPath -VMName 'vm-remove' -SnapshotId 'snap-1'
        Assert-Equal -Expected $true  -Actual (Remove-SnapshotManifest -VMName 'vm-remove' -SnapshotId 'snap-1' -Confirm:$false)
        Assert-True (-not (Test-Path -LiteralPath $path)) 'the file must be gone'
        Assert-Equal -Expected $false -Actual (Remove-SnapshotManifest -VMName 'vm-remove' -SnapshotId 'snap-1' -Confirm:$false) `
            -Because 'removing an absent manifest is a no-op, not a failure'
        Assert-Equal -Expected 'missing' -Actual (Test-SnapshotManifestMatch -VMName 'vm-remove' -SnapshotId 'snap-1').Status
    }
    It 'keeps the manifest under -WhatIf' {
        $null = Write-SnapshotManifest -VMName 'vm-keepwhatif' -SnapshotId 'snap-1' -Confirm:$false
        $path = Get-SnapshotManifestPath -VMName 'vm-keepwhatif' -SnapshotId 'snap-1'
        Assert-Equal -Expected $false -Actual (Remove-SnapshotManifest -VMName 'vm-keepwhatif' -SnapshotId 'snap-1' -WhatIf)
        Assert-True (Test-Path -LiteralPath $path) '-WhatIf must not delete the sidecar'
    }
}

Describe 'Runtime-directory resolution' {
    It 'honours YURUNA_RUNTIME_DIR and creates the tree under it' {
        $alt = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-snapman-alt-" + [guid]::NewGuid().ToString('N'))
        $saved = $env:YURUNA_RUNTIME_DIR
        try {
            $env:YURUNA_RUNTIME_DIR = $alt
            $dir = Get-SnapshotManifestDir -Confirm:$false
            Assert-Equal -Expected (Join-Path $alt 'snapshots') -Actual $dir -Because 'the runtime dir is the operator-controlled root'
            Assert-True (Test-Path -LiteralPath $dir) 'the whole path is created, not just the last segment'
        } finally {
            $env:YURUNA_RUNTIME_DIR = $saved
            if (Test-Path -LiteralPath $alt) { Remove-Item -LiteralPath $alt -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'falls back to the platform temp directory when YURUNA_RUNTIME_DIR is unset' {
        # Yuruna runs its cycles on host.macos.utm and host.ubuntu.kvm as well as
        # on Windows, and POSIX PowerShell does not define $env:TEMP. Clearing it
        # here reproduces exactly what the module sees on those hosts.
        $savedRuntime = $env:YURUNA_RUNTIME_DIR
        $savedTemp    = $env:TEMP
        try {
            $env:YURUNA_RUNTIME_DIR = $null
            $env:TEMP = $null
            $dir = Get-SnapshotManifestDir -Confirm:$false
            Assert-True ($dir -is [string] -and $dir.Length -gt 0) 'a snapshot manifest dir must resolve without $env:TEMP'
            Assert-True (Test-Path -LiteralPath $dir) 'and it must be usable'
            Assert-Equal -Expected 'snapshots' -Actual (Split-Path -Leaf $dir)
        } finally {
            $env:TEMP = $savedTemp
            $env:YURUNA_RUNTIME_DIR = $savedRuntime
        }
    }
}

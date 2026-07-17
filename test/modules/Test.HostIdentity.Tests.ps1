<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a1c2d3-e4f5-4061-9273-8495a6b7c8d9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool host identity fingerprint pester
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
    Pester coverage for the pure (no-I/O) host-identity helpers in
    Test.HostIdentity.psm1 -- fingerprint normalization, the weighted match
    score, the reclaim decision policy, the info-record YAML round-trip, and
    the file-touching registry helpers (Write-HostInfoRecord /
    Find-PriorHostIdentity / Set-ReclaimedHostUuid) exercised against a temp
    directory. The OS fingerprint GATHER + the live mount path are
    integration-verified on a real host.
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.HostIdentity.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning "powershell-yaml unavailable; YAML round-trip tests will fail." }

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway temp directory the calling It block deletes in its finally.')]
    [CmdletBinding()] [OutputType([string])] param()
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-hostid-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $d
    return $d
}

# A full, strong fingerprint for the "this is me" side of the comparisons.
function Get-TestFingerprint {
    param(
        [string]$Smbios = '550e8400-e29b-41d4-a716-446655440000',
        [string]$Serial = 'BOARDSERIAL123',
        [string[]]$Mac  = @('00:1A:2B:3C:4D:5E'),
        [int]$Cpu = 8, [int64]$Ram = 17179869184
    )
    return @{
        smbiosUuid = $Smbios; baseboardSerial = $Serial; cpuModel = 'Test CPU @ 3.0GHz'
        cpuCount = $Cpu; ramBytes = $Ram; macAddresses = [string[]]$Mac
        platform = 'linux'; hostType = 'ubuntu.kvm'; hostname = 'box-a'
    }
}

# A ranked-candidate row for the reclaim-decision policy. It lives at file scope
# rather than inside its Describe: a Describe body is executed during discovery
# and everything it declares is discarded before any It runs, so a helper defined
# there is a CommandNotFoundException by the time the assertions need it.
function New-Cand {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure test-data constructor; mutates no state.')]
    [CmdletBinding()] param([int]$Score, [bool]$Strong, [string]$Uuid = '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    [pscustomobject]@{ uuid=$Uuid; hostname='h'; lastSeenUtc='2026-06-01T00:00:00Z'; score=$Score; matchedFields=@(); strong=$Strong }
}

Describe 'Test-HostFingerprintValueUsable + ConvertTo-NormalizedFingerprintValue' {
    It 'rejects empty + firmware placeholder values' {
        Assert-False (Test-HostFingerprintValueUsable -Value '') 'empty unusable'
        Assert-False (Test-HostFingerprintValueUsable -Value '  ') 'whitespace unusable'
        Assert-False (Test-HostFingerprintValueUsable -Value '00000000-0000-0000-0000-000000000000') 'all-zero uuid unusable'
        Assert-False (Test-HostFingerprintValueUsable -Value 'To Be Filled By O.E.M.') 'OEM placeholder unusable'
        Assert-False (Test-HostFingerprintValueUsable -Value 'Default string') 'default string unusable'
    }
    It 'accepts a real value' {
        Assert-True (Test-HostFingerprintValueUsable -Value 'ABC-123') 'real value usable'
    }
    It 'normalizes case + trims, collapses junk to empty' {
        Assert-Equal -Expected 'abc-123' -Actual (ConvertTo-NormalizedFingerprintValue -Value '  ABC-123 ') -Because 'lowercased + trimmed'
        Assert-Equal -Expected '' -Actual (ConvertTo-NormalizedFingerprintValue -Value 'Default String') -Because 'junk -> empty'
    }
}

Describe 'ConvertTo-NormalizedMacList' {
    It 'lowercases, strips separators, de-dups, drops junk, sorts' {
        $r = ConvertTo-NormalizedMacList -Mac @('00:1A:2B:3C:4D:5E', '001a2b3c4d5e', 'AA-BB-CC-DD-EE-FF', '00:00:00:00:00:00', 'garbage', '')
        Assert-Equal -Expected 2 -Actual $r.Count -Because 'two unique MACs survive'
        Assert-Equal -Expected '001a2b3c4d5e' -Actual $r[0] -Because 'sorted first'
        Assert-Equal -Expected 'aabbccddeeff' -Actual $r[1] -Because 'sorted second'
    }
    It 'yields nothing usable for no usable input (wraps cleanly to empty)' {
        $r = ConvertTo-NormalizedMacList -Mac @('', '00:00:00:00:00:00')
        Assert-Equal -Expected 0 -Actual @($r).Count -Because 'wraps to empty'
    }
}

Describe 'Get-HostIdentityMatchScore' {
    It 'scores a strong identical fingerprint high and flags strong' {
        $me = Get-TestFingerprint
        $m = Get-HostIdentityMatchScore -Mine $me -Candidate $me
        Assert-True ($m.score -ge 100) "score $($m.score) >= 100"
        Assert-True $m.strong 'smbios/serial matched -> strong'
        Assert-True ($m.matchedFields -contains 'smbiosUuid') 'smbiosUuid matched'
        Assert-True ($m.matchedFields -contains 'macAddresses') 'mac matched'
    }
    It 'matches strong keys case-insensitively' {
        $me  = Get-TestFingerprint -Smbios '550E8400-E29B-41D4-A716-446655440000'
        $cand = Get-TestFingerprint -Smbios '550e8400-e29b-41d4-a716-446655440000'
        $m = Get-HostIdentityMatchScore -Mine $me -Candidate $cand
        Assert-True ($m.matchedFields -contains 'smbiosUuid') 'case-insensitive smbios match'
    }
    It 'does not count junk strong keys even when byte-identical' {
        $me   = Get-TestFingerprint -Smbios '00000000-0000-0000-0000-000000000000' -Serial 'Default string'
        $cand = Get-TestFingerprint -Smbios '00000000-0000-0000-0000-000000000000' -Serial 'Default string' -Mac @('99:99:99:99:99:99')
        $m = Get-HostIdentityMatchScore -Mine $me -Candidate $cand
        Assert-False $m.strong 'junk smbios/serial do not make it strong'
        Assert-False ($m.matchedFields -contains 'smbiosUuid') 'junk smbios not matched'
    }
    It 'scores a MAC overlap as medium, not strong' {
        $me   = Get-TestFingerprint -Smbios 'aaaa' -Serial 'aaa' -Mac @('00:1A:2B:3C:4D:5E')
        $cand = Get-TestFingerprint -Smbios 'bbbb' -Serial 'bbb' -Mac @('00:1A:2B:3C:4D:5E')
        $m = Get-HostIdentityMatchScore -Mine $me -Candidate $cand
        Assert-True ($m.matchedFields -contains 'macAddresses') 'mac matched'
        Assert-False $m.strong 'mac overlap is not strong'
    }
    It 'ignores zero/blank numeric fields' {
        $me   = @{ smbiosUuid=''; baseboardSerial=''; cpuModel=''; cpuCount=0; ramBytes=0; macAddresses=@(); platform='linux'; hostType='ubuntu.kvm' }
        $cand = @{ smbiosUuid=''; baseboardSerial=''; cpuModel=''; cpuCount=0; ramBytes=0; macAddresses=@(); platform='linux'; hostType='ubuntu.kvm' }
        $m = Get-HostIdentityMatchScore -Mine $me -Candidate $cand
        Assert-False ($m.matchedFields -contains 'cpuCount') 'zero cpuCount not matched'
        Assert-False ($m.matchedFields -contains 'ramBytes') 'zero ramBytes not matched'
        Assert-Equal -Expected 4 -Actual $m.score -Because 'only platform(2)+hostType(2) corroborate'
    }
}

Describe 'Get-HostIdentityReclaimDecision' {
    It 'none for an empty list' {
        Assert-Equal -Expected 'none' -Actual (Get-HostIdentityReclaimDecision -Ranked @()).action -Because 'empty -> none'
    }
    It 'none when the top score is below threshold' {
        Assert-Equal -Expected 'none' -Actual (Get-HostIdentityReclaimDecision -Ranked @((New-Cand -Score 10 -Strong $false))).action -Because 'below threshold -> none'
    }
    It 'suggest for a single clear strong front-runner' {
        $d = Get-HostIdentityReclaimDecision -Ranked @((New-Cand -Score 100 -Strong $true -Uuid '42ffffffffffffffffffffffffffffff'))
        Assert-Equal -Expected 'suggest' -Actual $d.action -Because 'one strong -> suggest'
        Assert-Equal -Expected '42ffffffffffffffffffffffffffffff' -Actual $d.candidate.uuid -Because 'candidate is the front-runner'
    }
    It 'suggest when only one candidate clears the threshold' {
        $d = Get-HostIdentityReclaimDecision -Ranked @((New-Cand -Score 80 -Strong $true -Uuid '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), (New-Cand -Score 10 -Strong $false -Uuid '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'))
        Assert-Equal -Expected 'suggest' -Actual $d.action -Because 'second below threshold -> still suggest'
    }
    It 'ambiguous for two strong candidates' {
        $d = Get-HostIdentityReclaimDecision -Ranked @((New-Cand -Score 100 -Strong $true -Uuid '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), (New-Cand -Score 60 -Strong $true -Uuid '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'))
        Assert-Equal -Expected 'ambiguous' -Actual $d.action -Because 'two strong -> ambiguous'
        Assert-Equal -Expected 2 -Actual $d.candidates.Count -Because 'lists both'
    }
    It 'ambiguous for a near-tie at the top' {
        $d = Get-HostIdentityReclaimDecision -Ranked @((New-Cand -Score 29 -Strong $false -Uuid '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), (New-Cand -Score 27 -Strong $false -Uuid '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'))
        Assert-Equal -Expected 'ambiguous' -Actual $d.action -Because 'near-tie -> ambiguous'
    }
    It 'suggest when the front-runner clears the runner-up by the gap' {
        $d = Get-HostIdentityReclaimDecision -Ranked @((New-Cand -Score 50 -Strong $true -Uuid '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), (New-Cand -Score 28 -Strong $false -Uuid '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'))
        Assert-Equal -Expected 'suggest' -Actual $d.action -Because 'clear gap + single strong -> suggest'
    }
}

Describe 'New-HostInfoRecordObject + ConvertFrom-HostInfoRecord (YAML round-trip)' {
    It 'round-trips through ConvertTo/ConvertFrom-Yaml with fields intact' {
        $fp = Get-TestFingerprint -Mac @('00:1A:2B:3C:4D:5E', 'aa-bb-cc-dd-ee-ff')
        $rec = New-HostInfoRecordObject -HostId '42abcabcabcabcabcabcabcabcabcabc' -Fingerprint $fp -LastSeenUtc '2026-06-09T12:00:00Z'
        Assert-Equal -Expected '42abcabcabcabcabcabcabcabcabcabc' -Actual $rec.hostUuid -Because 'uuid set'
        Assert-Equal -Expected 2 -Actual $rec.hardware.macAddresses.Count -Because 'macs normalized into record'
        $yaml = ConvertTo-Yaml $rec
        $back = $yaml | ConvertFrom-Yaml -Ordered
        $flat = ConvertFrom-HostInfoRecord -Record $back
        Assert-Equal -Expected $fp.smbiosUuid -Actual $flat.smbiosUuid -Because 'smbios survives'
        Assert-Equal -Expected 'boardserial123' -Actual (ConvertTo-NormalizedFingerprintValue -Value $flat.baseboardSerial) -Because 'serial survives'
        # The reconstructed candidate scores as a strong self-match.
        $m = Get-HostIdentityMatchScore -Mine $fp -Candidate $flat
        Assert-True $m.strong 'round-tripped record self-matches strongly'
    }
}

Describe 'Write-HostInfoRecord + Find-PriorHostIdentity (temp share)' {
    It 'writes hosts/info.<uuid>.yml and finds + ranks it back' {
        $root = New-TempDir
        try {
            $fp = Get-TestFingerprint
            $myUuid = '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $p = Write-HostInfoRecord -MountRoot $root -HostId $myUuid -Fingerprint $fp -Confirm:$false
            Assert-True ($null -ne $p) 'returns a path'
            Assert-True (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'hosts' -AdditionalChildPath "info.$myUuid.yml")) 'record file exists'

            # A second, unrelated host record (no shared keys) must NOT rank.
            $other = @{ smbiosUuid='11111111-1111-1111-1111-111111111111'; baseboardSerial='ZZZ'; cpuModel='Other'; cpuCount=4; ramBytes=8589934592; macAddresses=@('99:99:99:99:99:99'); platform='windows'; hostType='windows.hyper-v'; hostname='box-b' }
            $null = Write-HostInfoRecord -MountRoot $root -HostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -Fingerprint $other -Confirm:$false

            # Search with MY fingerprint, excluding nothing: the strong self-match wins.
            $ranked = @(Find-PriorHostIdentity -MountRoot $root -Fingerprint $fp)
            Assert-True ($ranked.Count -ge 1) 'at least one match'
            Assert-Equal -Expected $myUuid -Actual $ranked[0].uuid -Because 'strong self-match ranks first'
            Assert-True $ranked[0].strong 'top match is strong'

            # Excluding my own uuid drops the self-match; the unrelated host does not score.
            $rankedEx = @(Find-PriorHostIdentity -MountRoot $root -Fingerprint $fp -ExcludeHostId $myUuid)
            Assert-False ($rankedEx.uuid -contains $myUuid) 'excluded uuid is gone'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'returns empty when the hosts/ folder is absent' {
        $root = New-TempDir
        try {
            $ranked = @(Find-PriorHostIdentity -MountRoot $root -Fingerprint (Get-TestFingerprint))
            Assert-Equal -Expected 0 -Actual $ranked.Count -Because 'no folder -> empty'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Set-ReclaimedHostUuid (uuid shape gate)' {
    It 'rejects a malformed uuid and writes nothing' {
        $root = New-TempDir
        try {
            $f = Join-Path $root 'host.uuid'
            Assert-False (Set-ReclaimedHostUuid -UuidFile $f -Uuid 'not-a-uuid' -Confirm:$false) 'bad shape rejected'
            Assert-False (Test-Path -LiteralPath $f) 'nothing written'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'accepts a 42-prefixed 32-hex uuid and persists it' {
        $root = New-TempDir
        try {
            $f = Join-Path $root 'host.uuid'
            $u = '42abcdef0123456789abcdef01234567'
            Assert-True (Set-ReclaimedHostUuid -UuidFile $f -Uuid $u -Confirm:$false) 'good shape accepted'
            Assert-Equal -Expected $u -Actual ([System.IO.File]::ReadAllText($f)).Trim() -Because 'uuid persisted verbatim'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

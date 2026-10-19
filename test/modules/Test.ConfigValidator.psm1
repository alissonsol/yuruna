<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 4233bb36-0ed5-4529-acff-23258b23fec0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# See https://yuruna.link/4213a0b3-0047

Import-Module (Join-Path $PSScriptRoot 'Test.Output.psm1') -Global -Force
# Test.HostGit owns Get-GitUpstreamStatus, the shared upstream classifier that
# Test-RepoFreshness reports on (Invoke-GitPull acts on the same result). Import
# -Global so a -Force reimport here cannot evict it from the global session.
Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -Global -Force
# Test-AgainstSchema parses the config through Read-TestConfig (Test.Config) so schema
# validation reuses the hardened reader (root-shape check, the macOS Resolve-Path
# fallback, the shared mtime-keyed cache). Import it here so every consumer of this
# module has the reader -- the validator is also called by the standalone Test-Config.ps1.
Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force
# Get-YurunaJsonSchemaError names the violation Test-Json reports without a record.
Import-Module (Join-Path $PSScriptRoot 'Test.LocalizationExchange.psm1') -DisableNameChecking

function Test-IsSet {
    <#
    .SYNOPSIS
        $true when $Value is a non-empty string (after trim). Used as a
        guard before -match / Test-Path calls so a $null or '' field does
        not silently pass the check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][Parameter(Position=0)]$Value)
    return ($null -ne $Value -and "$Value".Trim() -ne '')
}

function Test-AgainstSchema {
    <#
    .SYNOPSIS
        Best-effort JSON-Schema validation of a YAML config. When
        Test-Json (PS 7.4+) is unavailable, falls back to a parse-only
        check so the validator still surfaces malformed YAML. Never
        blocks the cycle on missing schema tooling -- only on actual
        content errors.
    .DESCRIPTION
        Resolves YamlPath to an absolute path so every FAIL row carries
        an operator-actionable location: a bare label like "vault.yml"
        would force the operator to guess which of the several vault.yml
        locations was meant.
    .PARAMETER Label
        Display label for the section (e.g. 'vault.yml', 'users.yml').
    .PARAMETER YamlPath
        Path to the YAML document under test.
    .PARAMETER SchemaPath
        Path to the JSON-Schema-compatible YAML schema.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Writes PASS/FAIL via Test.Output; no externally observable state change.')]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    $YamlFull = try { [System.IO.Path]::GetFullPath($YamlPath) } catch { $YamlPath }
    if (-not (Test-Path $YamlPath))   { Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_8e99318e4c9efaea' -Arguments @{ label = "${Label}"; yamlFull = "$YamlFull" }) -FullPath $YamlFull; return }
    if (-not (Test-Path $SchemaPath)) { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_a355b1e1a1867c72' -Arguments @{ label = "${Label}"; schemaPath = "$SchemaPath" }); return }
    try {
        # Route through the hardened reader (root-shape check + the macOS Resolve-Path
        # fallback + the shared cache) instead of a second, divergent parse path.
        $doc = Read-TestConfig -Path $YamlPath -ThrowOnError
    } catch {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_2fae4316e7c5107a' -Arguments @{ label = "${Label}"; yamlFull = "${YamlFull}"; message = "$($_.Exception.Message)" }) -FullPath $YamlFull
        return
    }
    $hasTestJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ($hasTestJson) {
        try {
            # Depth 32 (matching Publish-TestConfigSnapshot) so deep nodes are not silently
            # serialized as '@{...}' strings, which would hand Test-Json a truncated document.
            $schemaJson = Get-Content -Raw $SchemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
            $docJson    = $doc | ConvertTo-Json -Depth 32
            if (Test-Json -Json $docJson -Schema $schemaJson -ErrorAction Stop) {
                Write-Pass "${Label}: schema-valid ($YamlFull)"
            } else {
                # A violation Test-Json reports with a record throws above; PowerShell
                # 7.6.7 answers $false with none for one nested below the first level.
                $reason = Get-YurunaJsonSchemaError -Json $docJson -Schema $schemaJson
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_f815487911dc3595' -Arguments @{ label = "${Label}"; yamlFull = "${YamlFull}"; message = "$reason" }) -FullPath $YamlFull
            }
        } catch {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_f815487911dc3595' -Arguments @{ label = "${Label}"; yamlFull = "${YamlFull}"; message = "$($_.Exception.Message)" }) -FullPath $YamlFull
        }
    } else {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_4b7205979bd3ff32' -Arguments @{ label = "${Label}" })
    }
}

function Test-RepoFreshness {
    <#
    .SYNOPSIS
        Report a git working tree's relation to its upstream: up-to-date,
        ahead, behind, diverged, or no-upstream. Fetches first so the
        comparison is meaningful; tolerates offline (`git fetch` failure
        becomes a WARN, not a FAIL).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Writes PASS/WARN via Test.Output; no externally observable state change beyond a git fetch (read-only).')]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path (Join-Path $Path '.git'))) {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_34ae6df2f15089e2' -Arguments @{ label = "${Label}"; path = "$Path" })
        return
    }
    # Fetch through the shared network-git helper: it neutralizes every
    # interactive credential prompt (so a private/rate-limited remote can't stop
    # this check dead on a 'Username for https://github.com:' prompt -- a config
    # sync that runs this as its final validation would otherwise hang on a
    # GitHub question unrelated to the sync) AND chains the host's GitHub
    # credential sources (GH_TOKEN, the gh CLI login), which plain git does not
    # read on its own. See Invoke-GitNetworkCommand.
    try {
        $fetch = Invoke-GitNetworkCommand -GitArgs @('-C', $Path, 'fetch', '--quiet') -TimeoutSeconds 60
        if ($fetch.ExitCode -ne 0) {
            if (Test-GitRemoteAuthFailure -Output $fetch.Output) {
                # "offline, or maybe credentials" reads as an ambient condition to
                # wait out. A refused credential is neither ambient nor
                # self-healing, and it takes down every other remote-touching
                # check in the same report -- so name it, with the fix, rather
                # than leaving a reader to guess which half of an either/or they
                # are in.
                $remedy = (@(Get-GitAuthRefreshRemedy) -join '; ')
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_e4106fbdb61cf353' -Arguments @{ label = "${Label}"; remedy = "$remedy"; output = "$(Get-GitFirstOutputLine -Output $fetch.Output)" })
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_ee4f9562277e1df3' -Arguments @{ label = "${Label}" })
            }
            return
        }
        $st = Get-GitUpstreamStatus -Path $Path
        switch ($st.State) {
            'no-upstream' { Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_683bf2c36f24325c' -Arguments @{ label = "${Label}" }) }
            'up-to-date'  { Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_d6f51da4e1e89388' -Arguments @{ label = "${Label}"; remote = "$($st.Remote)" }) }
            'behind'      { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_e6cadf29b3937ddf' -Arguments @{ label = "${Label}"; behind = "$($st.Behind)" }) }
            'ahead'       { Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_317c6bd9520041bd' -Arguments @{ label = "${Label}"; ahead = "$($st.Ahead)" }) }
            default       { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_6ca71048f9914bc3' -Arguments @{ label = "${Label}"; ahead = "$($st.Ahead)"; behind = "$($st.Behind)" }) }
        }
    } catch {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_5e66ae4d5f5ea1e5' -Arguments @{ label = "${Label}"; message = "$($_.Exception.Message)" })
    }
}

function Test-ProjectHostStorage {
    <#
    .SYNOPSIS
        Evaluate a project's declared VM storage allowance on the applicable host.
    .DESCRIPTION
        The declaration is read-only admission policy. An unavailable volume probe
        is not a measured shortage; each VM start still checks its actual storage.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$HostType,
        [string]$RepoRoot
    )
    $path = Join-Path $ProjectRoot 'test/host-storage.requirements.json'
    $result = @{ allowed = $true; status = 'not-applicable'; reason = ''; path = $path; hostStorage = $null }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
    try {
        if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw 'The storage declaration exceeds 64 KiB.' }
        $policy = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -Depth 12 -ErrorAction Stop
        if ($policy -isnot [System.Collections.IDictionary] -or $policy.schemaVersion -ne 1) { throw 'Expected storage schemaVersion 1.' }
        if ($policy.hostType -notin @('host.windows.hyper-v', 'host.ubuntu.kvm', 'host.macos.utm')) { throw 'A supported hostType is required.' }
        if ($policy.hostType -ne $HostType) { return $result }
        $readBytes = {
            param($Value)
            if (($Value -isnot [long] -and $Value -isnot [int]) -or $Value -lt 0) { throw 'Storage byte counts must be nonnegative Int64 integers.' }
            return [long]$Value
        }
        $reserve = & $readBytes $policy.reserveBytes
        $provisioning = if ($policy.Contains('provisioningMemoryBytes')) { & $readBytes $policy.provisioningMemoryBytes } else { [long]0 }
        if ($policy.virtualMachines -isnot [array] -or $policy.virtualMachines.Count -lt 1 -or $policy.virtualMachines.Count -gt 128) {
            throw 'virtualMachines must contain between 1 and 128 VM requirements.'
        }
        $memory = @{}
        $growth = @{}
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($vm in $policy.virtualMachines) {
            if ($vm -isnot [System.Collections.IDictionary] -or $vm.name -isnot [string]) { throw 'Each VM requirement must have a name.' }
            $name = $vm.name.Trim()
            if (-not $name -or $name -in @('.', '..') -or $name -match '[\\/:*?"<>|]' -or $memory.ContainsKey($name)) { throw 'VM names must be unique, nonempty names without path separators.' }
            $memory[$name] = & $readBytes $vm.startupMemoryBytes
            $growth[$name] = & $readBytes $vm.additionalStorageBytes
            $names.Add($name)
        }
    } catch {
        $result.allowed = $false
        $result.status = 'invalid'
        $result.reason = "Invalid host storage requirements: $($_.Exception.Message)"
        return $result
    }
    try {
        if (-not (Get-Command Test-VMStorageCapacity -ErrorAction SilentlyContinue) -and $RepoRoot) {
            $null = Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType
        }
        $capacityCommand = Get-Command Test-VMStorageCapacity -ErrorAction SilentlyContinue
        if (-not $capacityCommand) { throw 'The host driver does not provide storage capacity measurements.' }
        $capacityArgs = @{ VMName = $names.ToArray(); StartupMemoryBytes = $memory; AdditionalStorageBytes = $growth; ReserveBytes = $reserve }
        if ($provisioning -gt 0) {
            if (-not $capacityCommand.Parameters.ContainsKey('ProvisioningMemoryBytes')) { throw 'The host driver cannot measure the declared provisioning memory allowance.' }
            $capacityArgs.ProvisioningMemoryBytes = $provisioning
        }
        $reading = Test-VMStorageCapacity @capacityArgs
        if ($reading -isnot [System.Collections.IDictionary] -or $reading.status -notin @('ready', 'insufficient', 'unknown')) { throw 'The host driver returned no valid storage capacity measurement.' }
        $result.status = [string]$reading.status
        $result.allowed = $reading.status -ne 'insufficient'
        $result.reason = [string]$reading.reason
        if ($reading.status -eq 'ready' -and -not $result.reason) { $result.reason = "Host storage: capacity is available for $($names.Count) declared VM(s), including growth allowances and reserve." }
        $result.hostStorage = $reading
    } catch {
        $result.status = 'unknown'
        $result.reason = "Host storage capacity is unavailable: $($_.Exception.Message)"
    }
    return $result
}

Export-ModuleMember -Function Test-IsSet, Test-AgainstSchema, Test-RepoFreshness, Test-ProjectHostStorage

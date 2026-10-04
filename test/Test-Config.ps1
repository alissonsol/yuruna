<#PSScriptInfo
.VERSION 2026.10.04
.GUID 4210d385-d4df-4f13-9344-d649676c6dc4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Validates test.config.yml plus the test/extension/* configs and
    sends a smoke-test notification to confirm transports work.

.DESCRIPTION
    Checks that test.config.yml exists and is well-formed, validates
    the per-area extension configs (authentication, notification) under
    test/extension/, probes Resend reachability, and finally fires a
    'config.smoke' notification. The smoke event has its own subscriber
    list (separate from cycle.failure) so this validator does not spam
    real failure recipients.

.PARAMETER ConfigPath
    Path to the config file. Defaults to test/test.config.yml next to this script.

.PARAMETER SkipSend
    Validate the config but do not actually send a notification.

.PARAMETER OnConfigSchemaDrift
    Severity when test.config.yml carries populated keys that are NOT part of the
    current template schema (for example a renamed section's old keys, left in
    place by the default additive fill): 'Warn' (default -- surfaces the orphaned
    keys but lets the run continue) or 'Fail' (records a FAIL so CI / the operator
    must resolve it before the cycle). When every key still maps to the schema (a
    purely additive drift) the result is always a PASS regardless of this flag.

.PARAMETER ApplyConfigMigration
    Run the runner's HARD cycle-start reconciliation now instead of the default
    additive fill: test.config.yml is copied to test.config.yml.backup, the
    template replaces it, and every value that still maps to the new schema is
    copied back (reusing Update-TestConfigFromTemplate). If a value no longer maps,
    the migrated file is still written but the run stops so the remaining fields
    can be hand-migrated from the backup. Without this switch a schema drift is
    resolved additively: the missing template fields are written into the file
    (empty defaults, ready to fill in) and the operator's existing keys -- including
    a renamed section's old keys -- are left untouched for hand-migration.

.PARAMETER ExpectStorageConfigured
    Declares that shared storage was supposed to have been configured before this
    check ran, which turns an unconfigured networkStorage pool tier from an
    optional-feature note into a FAILURE.

    The same absent block means two opposite things and nothing in the file tells
    them apart: to an operator who has no NAS and never wanted one it is correct
    and complete, and to a run that just stood up local shares or mounted a NAS it
    is proof the work did not land. Only the caller knows which, so the caller
    says so. Without this switch the checks below behave exactly as they always
    have, which is what an operator running this by hand needs.

.EXAMPLE
    pwsh test/Test-Config.ps1

.EXAMPLE
    pwsh test/Test-Config.ps1 -SkipSend

.EXAMPLE
    pwsh test/Test-Config.ps1 -OnConfigSchemaDrift Fail

.EXAMPLE
    pwsh test/Test-Config.ps1 -ApplyConfigMigration
#>

param(
    [string]$ConfigPath = $null,
    [switch]$SkipSend,
    [ValidateSet('Warn', 'Fail')]
    [string]$OnConfigSchemaDrift = 'Warn',
    [switch]$ApplyConfigMigration,
    [switch]$ExpectStorageConfigured
)

# A Windows console code page prints Chinese and Hebrew catalog text as
# question marks; YURUNA_KEEP_CONSOLE_ENCODING=1 keeps the console's own.
if ($IsWindows -and $env:YURUNA_KEEP_CONSOLE_ENCODING -ne '1') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }

Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$TestRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test.config.yml" }
$TemplatePath         = Join-Path $TestRoot "test.config.yml.template"
$ExtensionRoot        = Join-Path $TestRoot "extension"
$ExtensionStateRoot   = Join-Path -Path $TestRoot -ChildPath "status" -AdditionalChildPath "extension"
$SchemasRoot          = Join-Path $TestRoot "schemas"
$NotificationCfgPath  = Join-Path $ExtensionStateRoot "notification/transports.yml"
$NotificationTmplPath = Join-Path $ExtensionRoot      "notification/transports.yml.template"

# --- REGION: Helpers
# See https://yuruna.link/42010605-0002
$script:ModulesDir = Join-Path $TestRoot "modules"
Import-Module (Join-Path $script:ModulesDir 'Test.Output.psm1')          -Global -Force
Import-Module (Join-Path $script:ModulesDir 'Test.ConfigValidator.psm1') -Global -Force
# Read-TestConfig is the single source of truth for the
# `Get-Content -Raw | ConvertFrom-Yaml -Ordered` flow; it caches by
# absolute-path + mtime + content-hash so the repeated reads here (and
# per-cycle re-spawns) reuse one parse.
Import-Module (Join-Path $script:ModulesDir 'Test.Config.psm1')          -Global -Force
# Test.InnerSpawn exports Get-PwshExePath, the macOS-hardened resolver the
# bootstrap-encoding gate below uses to re-spawn an identical child pwsh. A
# bare (Get-Process -Id $PID).Path is null on macOS (no /proc), so this gate
# must route through the shared resolver. Leaf module (no transitive deps).
Import-Module (Join-Path $script:ModulesDir 'Test.InnerSpawn.psm1')      -Global -Force
# Test-YurunaCanPrompt / Assert-YurunaPromptable: the one predicate for "can a
# question asked here reach a person". Every interactive offer below is gated on
# it, so the answer is the same one the rest of the harness gets -- including the
# environment contract a parent publishes, which a console probe alone cannot see.
Import-Module (Join-Path (Split-Path -Parent $TestRoot) 'automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
Initialize-OutputState

# --- REGION: Test-TcpReachable
function Test-TcpReachable {
    <#
    .SYNOPSIS
        Bounded TCP reachability probe that always disposes its socket.
    .DESCRIPTION
        Delegates the bounded probe and socket disposal to Test-TcpConnectOutcome.
        Returns $true on connect and $false on timeout or refusal. The GitHub
        and Resend probes differ only in host name, so both route through here.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 443,
        [int]$TimeoutMs = 5000
    )
    return [bool](Test-TcpConnectOutcome -IpAddress $HostName -Port $Port -TimeoutMs $TimeoutMs).Reachable
}

# --- REGION: ConvertTo-YurunaBool
function ConvertTo-YurunaBool {
    <#
    .SYNOPSIS
        Normalize a config flag to [bool], mapping quoted/typo'd boolean spellings.
    .DESCRIPTION
        The YAML parser already yields a real [bool] for an unquoted true/false, so the
        common case is correct; this only hardens a QUOTED or typo'd scalar, where a
        bare [bool] cast reads any non-empty string -- including 'false'/'0'/'no' -- as
        $true. Map the common spellings explicitly; otherwise fall back to the [bool]
        cast so real booleans, numbers, and $null keep their existing coercion.
    #>
    [OutputType([bool])]
    param([AllowNull()]$Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        switch -Regex ($Value.Trim()) {
            '^(?i)(false|0|no|off)$' { return $false }
            '^(?i)(true|1|yes|on)$'  { return $true }
        }
    }
    return [bool]$Value
}

# --- REGION: Section 1: Config file
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_b705515c07a5e9a8')

if (-not (Test-Path $ConfigPath)) {
    if (Test-Path $TemplatePath) {
        try {
            Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_d13d6f9c4e2630f3' -Arguments @{ templatePath = "$TemplatePath"; configPath = "$ConfigPath" })
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_af63e61533afab65' -Arguments @{ configPath = "$ConfigPath" })
        } catch {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_9a0f4180f6bc4690' -Arguments @{ templatePath = "$TemplatePath"; configPath = "${ConfigPath}"; message = "$($_.Exception.Message)" }) -FullPath $ConfigPath
            Exit-WithSummary 1
        }
    } else {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_9a19efa0e81d08cd' -Arguments @{ configPath = "$ConfigPath" }) -FullPath $ConfigPath
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_181168cad549912c' -Arguments @{ templatePath = "$TemplatePath" })
        Exit-WithSummary 1
    }
} else {
    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_f9451eb8ca95adac' -Arguments @{ configPath = "$ConfigPath" })
}

# --- REGION: Section 2: YAML parsing
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_616e3566ba5ee01a')

try {
    $Config = Read-TestConfig -Path $ConfigPath -ThrowOnError
    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_0a36a817624fdfc8')
} catch {
    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_c57debb1f06af38a' -Arguments @{ configPath = "${ConfigPath}"; value = "$_" }) -FullPath $ConfigPath
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_1365c99cb0e8efff')
    Exit-WithSummary 1
}

# --- REGION: Section 2a: Retired key names
# Only the current key names are accepted. A retired key that merely warned
# would keep working by accident on the host that still carries it while the
# code reads the new name and silently falls back to a default -- the config
# would look honored and be ignored. Each failure line names the replacement,
# and the whole file converts in one command.

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_72e8483f6f8d909a')

$configNamingMod = Join-Path $script:ModulesDir 'Test.ConfigNaming.psm1'
if (-not (Test-Path $configNamingMod)) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_45634295eef1edce' -Arguments @{ configNamingMod = "${configNamingMod}" })
} else {
    Import-Module $configNamingMod -Global -Force
    $rawConfigText = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
    $retired = @(Get-RetiredConfigKeyPresent -Text ([string]$rawConfigText))
    if ($retired.Count -eq 0) {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_bada71e7f386bac2')
    } else {
        foreach ($r in $retired) {
            $unit = if ($r.Factor -ne 1) { " (value converts: old x $($r.Factor))" } else { "" }
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_5701bff77c2c62cc' -Arguments @{ old = "$($r.Old)"; new = "$($r.New)"; unit = "$unit" }) -FullPath $ConfigPath
        }
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_5366e41cd6eece52')
    }
}

# --- REGION: Section 2b: Config schema vs template
# The template is the schema source of truth: Sync-TestConfigToTemplate fully
# reconciles the live test.config.yml to it (add missing fields, remove
# dropped keys with a .backup, rewrite alphabetically); at cycle start the
# runner does the same via Update-TestConfigFromTemplate.
# See docs/test-config.md (Template reconciliation).

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_0cbff397669c09e4')

$configSyncMod = Join-Path $script:ModulesDir 'Test.ConfigSync.psm1'
if (-not (Test-Path $TemplatePath)) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_c9343e3d94183a5f' -Arguments @{ templatePath = "$TemplatePath" })
} elseif (-not (Test-Path $configSyncMod)) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_6b771250445f1e80' -Arguments @{ configSyncMod = "${configSyncMod}" })
} else {
    Import-Module $configSyncMod -Global -Force
    try {
        $templateDoc  = Read-TestConfig -Path $TemplatePath -ThrowOnError
        $shapeMatches = Test-ConfigMatchesTemplateShape -Template $templateDoc -Current $Config

        if ($ApplyConfigMigration -and -not $shapeMatches) {
            # Opt-in HARD migration matching the runner's cycle-start reconciliation:
            # back up to test.config.yml.backup, reset to the template shape, carry
            # every still-mapping value forward, and -- if a populated value no longer
            # maps -- write the migrated file then STOP for hand-migration
            # (Get-EntryPointExitCode Failure). Test.Prelude supplies that helper.
            $backupPath = "$ConfigPath.backup"
            $preludeMod = Join-Path $script:ModulesDir 'Test.Prelude.psm1'
            if ((Test-Path $preludeMod) -and -not (Get-Command Get-EntryPointExitCode -ErrorAction SilentlyContinue)) {
                Import-Module $preludeMod -Global -Force
            }
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_b1f8d0c2e7161b4e')
            $Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_3ea856621a49f7a4' -Arguments @{ backupPath = "$backupPath" })
        } else {
            # Default: reconcile the file to the template -- add missing fields,
            # drop keys the template no longer defines (backing up first when a
            # populated key is dropped), and rewrite in canonical alphabetical
            # order. Operator values that still map are kept; 'secrets' untouched.
            $res = Sync-TestConfigToTemplate -Template $templateDoc -Current $Config -ConfigPath $ConfigPath -TemplatePath $TemplatePath
            $Config = $res.Config

            if ($res.Wrote) {
                $summary = [System.Collections.Generic.List[string]]::new()
                if ($res.Added.Count   -gt 0) { [void]$summary.Add("added $($res.Added.Count) missing field(s)") }
                if ($res.Removed.Count -gt 0) { [void]$summary.Add("removed $($res.Removed.Count) key(s) not in the schema") }
                [void]$summary.Add("sorted to alphabetical order")
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_f1c4363daf483d7c' -Arguments @{ join = "$($summary -join '; ')" })
                if ($res.Added.Count -gt 0) {
                    $addedList = ($res.Added | ForEach-Object { "          - $_" }) -join "`n"
                    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_9f261d271fd76a51' -Arguments @{ addedList = "$addedList" })
                }
            } elseif ($shapeMatches) {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_1b4678701df4b2f4')
            } else {
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_9d70cd3adcc52aa8')
            }

            if ($res.Removed.Count -gt 0) {
                $removedList = ($res.Removed | ForEach-Object { "          - $_" }) -join "`n"
                $msg = "test.config.yml had $($res.Removed.Count) populated key(s) that are NOT part of the current schema (for example, left over from a renamed section). They were REMOVED from the file; the previous file was backed up to $($res.BackupPath) so you can copy any value across by hand. Removed keys:`n$removedList"
                if ($OnConfigSchemaDrift -eq 'Fail') {
                    Write-Fail $msg -FullPath $ConfigPath
                } else {
                    Write-Warn $msg
                }
            }
        }
    } catch {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_588f793a5bce2c4e' -Arguments @{ message = "$($_.Exception.Message)" }) -FullPath $ConfigPath
    }
}

# --- REGION: Section 3: Host requirements (quick)
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_0eaac625cae7caa8')

$ModulesDir  = Join-Path $TestRoot "modules"
$hostModPath = Join-Path $ModulesDir "Test.HostContract.psm1"
$HostType    = $null
if (-not (Test-Path $hostModPath)) {
    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_c9a0622a7c0cf589' -Arguments @{ hostModPath = "$hostModPath" })
} else {
    Import-Module -Name $hostModPath -Force -Global
    $HostType = Get-HostType
    if (-not $HostType) {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_cf973fdec9d6f1dd')
    } else {
        # Auto-relaunch under sg libvirt on host.ubuntu.kvm when this
        # shell's group set is stale. Most of Test-Config's later probes
        # (libvirt VM listing, host-feature checks) need libvirt-socket
        # access. No-op on other hosts / fresh shells.
        Invoke-LibvirtGroupReExecIfNeeded -HostType $HostType -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_7ad9a8cd1a9709db' -Arguments @{ hostType = "$HostType" })
        # See https://yuruna.link/42010605-0002
        $reqWarns = $null
        $reqOk = Test-HostRequirement -HostType $HostType -InformationAction SilentlyContinue -WarningAction SilentlyContinue -WarningVariable reqWarns
        foreach ($w in $reqWarns) { Write-Warn "$w" }
        if ($reqOk) {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_7d1e9cbc4ff500f6')
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_ad0f9b65a3b27ef4')
        }
    }
}

# --- REGION: Section 3b: Host clock
# See https://yuruna.link/42010605-0002

# --- REGION: Invoke-HostClockSyncOffer
# See https://yuruna.link/42010605-0002
function Invoke-HostClockSyncOffer {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)
    if (-not (Get-Command Sync-HostClock -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Test-YurunaCanPrompt)) { return $false }
    $ans = Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_b911fd964c58192d')
    if ($ans -notmatch '^\s*(y|yes)\s*$') { return $false }
    # Prime the sudo credential cache first. Every platform's sync calls
    # `sudo -n` so it can never hang a caller on a hidden prompt -- which on
    # macOS/Linux would make the answer just given fail with "a password is
    # required". Priming asks once, visibly, and the cached timestamp carries
    # the calls that follow. No-op on Windows and when already root.
    if (Get-Command Initialize-SudoCache -ErrorAction SilentlyContinue) {
        if (-not (Initialize-SudoCache -Reasons @('resynchronize the host clock against NTP'))) {
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_e5f6d0ead5f8eede')
            return $false
        }
    }
    $result = Sync-HostClock -HostType $HostType -Confirm:$false
    if ($result.Succeeded) {
        Write-Info "  $($result.Message)"
        return $true
    }
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_e4d6767baee05dac' -Arguments @{ message = "$($result.Message)" })
    return $false
}

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_fc2930c1a5a1aa8e')

if (-not $HostType) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_4f34d35ef3aa3f62')
} elseif (-not (Get-Command Get-HostClockSkew -ErrorAction SilentlyContinue)) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_d26654091a43fd36')
} else {
    $skewLimit = Get-HostClockSkewLimit
    $skew      = Get-HostClockSkew
    if ($null -eq $skew) {
        # Unmeasured is not the same as bad: an isolated lab has no route to
        # a time server and still runs.
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_7a9e854f1db429d5')
    } elseif ([math]::Abs($skew) -le $skewLimit) {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_2cd575ec280d67bf' -Arguments @{ skew = "$([math]::Round($skew, 1))"; skewLimit = "${skewLimit}" })
    } else {
        $direction = if ($skew -gt 0) { 'ahead of' } else { 'behind' }
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_3208bd90808538c6' -Arguments @{ skew = "$([math]::Round([math]::Abs($skew), 1))"; direction = "$direction"; skewLimit = "${skewLimit}" })
        if (Invoke-HostClockSyncOffer -HostType $HostType) {
            $skew = Get-HostClockSkew
            if ($null -ne $skew -and [math]::Abs($skew) -le $skewLimit) {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_68c1fa0e68b90635' -Arguments @{ skew = "$([math]::Round($skew, 1))" })
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_ec7e0200dab2628f')
            }
        } else {
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_e63b1a967d2939be')
        }
    }
}

# --- REGION: Section 3c: Host setup freshness
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_6b34b3231afbc220')

$hostStateMod = Join-Path $script:ModulesDir 'Test.HostAutomationState.psm1'
if (-not (Test-Path -LiteralPath $hostStateMod)) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_16231ab6576eea45' -Arguments @{ hostStateMod = "$hostStateMod" })
} else {
    try {
        Import-Module $hostStateMod -Global -Force -DisableNameChecking -ErrorAction Stop
        $hostSetupState = Read-HostAutomationState
        if (-not $hostSetupState) {
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_1cfaa5f7efe3352b')
        } elseif (-not $hostSetupState.PSObject.Properties['os']) {
            # Silence from a capture that never held an opinion is not agreement,
            # and reporting it as a match would be inventing one.
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_13a64a29700e4dfa')
        } else {
            $osDrift = Get-HostAutomationOsDrift -State $hostSetupState
            if ($osDrift) {
                Write-Warn $osDrift
            } else {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_fbe761e4aca4bde7')
            }
        }
    } catch {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_c9576c60463f615c' -Arguments @{ message = "$($_.Exception.Message)" })
    }
}

# --- REGION: Section 4: Host capacity
# RAM + CPU. Below the per-platform threshold = WARN (the harness still
# runs but risks OOM kills inside guests / slow OCR). The 16 GiB and
# 4-core thresholds match the "three concurrent 2-vCPU/4 GiB guests + an
# OCR worker on the host" calibration the cycle is sized for.

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_ae9514864e3cfad4')

try {
    $ramGiB     = $null
    $logicalCpu = $null
    $cpuModel   = ''
    if ($IsWindows) {
        $cs   = Get-CimInstance Win32_ComputerSystem
        $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
        $ramGiB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $logicalCpu = [int]$cs.NumberOfLogicalProcessors
        $cpuModel   = "$($cpu.Name)".Trim()
    } elseif ($IsLinux) {
        $memKb      = (Select-String -Path /proc/meminfo -Pattern '^MemTotal:\s+(\d+)' | Select-Object -First 1).Matches[0].Groups[1].Value
        $ramGiB     = [math]::Round([int64]$memKb * 1KB / 1GB, 1)
        $logicalCpu = (& nproc 2>$null) -as [int]
        $cpuModel   = ((Select-String -Path /proc/cpuinfo -Pattern '^model name\s*:\s*(.+)$' | Select-Object -First 1).Matches[0].Groups[1].Value).Trim()
    } elseif ($IsMacOS) {
        $memBytes   = (& sysctl -n hw.memsize)  -as [int64]
        $ramGiB     = [math]::Round($memBytes / 1GB, 1)
        $logicalCpu = (& sysctl -n hw.logicalcpu) -as [int]
        $cpuModel   = (& sysctl -n machdep.cpu.brand_string).Trim()
    }
    if ($null -ne $ramGiB) {
        if ($ramGiB -lt 16) {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_c86a34181a6e7290' -Arguments @{ ramGiB = "${ramGiB}" })
        } else {
            Write-Pass "RAM = ${ramGiB} GiB."
        }
    }
    if ($null -ne $logicalCpu -and $logicalCpu -gt 0) {
        if ($logicalCpu -lt 4) {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_eca5cda0ca30d7a8' -Arguments @{ logicalCpu = "$logicalCpu" })
        } else {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_f8b9b097470ee897' -Arguments @{ logicalCpu = "$logicalCpu"; cpuModel = "$cpuModel" })
        }
    }
} catch {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_2ec32a8a3612315f' -Arguments @{ message = "$($_.Exception.Message)" })
}

# --- REGION: Section 5: Host-specific feature state
# Deeper, host-type-specific verification beyond the "command/service
# exists" gate in Test-HostRequirement: Hyper-V feature state (DISM)
# on Windows, libvirtd active + qemu installed on Linux, UTM helper
# installed on macOS. Catches "Hyper-V is half-enabled, reboot pending"
# (memory: dism_enable_pending_trap) before a cycle hits it.

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_9d62f276492b34f0')

switch ($HostType) {
    'host.windows.hyper-v' {
        try {
            $featureLine = & dism.exe /online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1 |
                Select-String -Pattern '^\s*State\s*:\s*(.+)$' |
                Select-Object -First 1
            if ($featureLine) {
                $state = $featureLine.Matches[0].Groups[1].Value.Trim()
                if ($state -eq 'Enabled') {
                    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_895abfd57f7672a7')
                } else {
                    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_c5be34e9077c81b6' -Arguments @{ state = "$state" })
                }
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_44963937e5dae96e')
            }
        } catch {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_e5e2b6cb5e0446ce' -Arguments @{ message = "$($_.Exception.Message)" })
        }
        $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if ($vmms -and $vmms.Status -eq 'Running') {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_67bdf7a52b9c83a4')
        } else {
            $vmmsState = if ($vmms) { "$($vmms.Status)" } else { 'not installed' }
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_2351701b37c22396' -Arguments @{ vmmsState = "$vmmsState" })
        }
    }
    'host.ubuntu.kvm' {
        if (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue) {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_9012bfc1395ad8f0')
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_ddfdfd1aaf528d2e')
        }
        # Distinguish "the service is stopped" from "the package that provides the
        # service was never installed": 'systemctl start' is useless advice for a
        # unit that does not exist, and sends the operator down the wrong path.
        $libvirtd = (& systemctl is-active libvirtd 2>$null)
        if ("$libvirtd".Trim() -eq 'active') {
            Write-Pass "libvirtd: active."
        } else {
            $unitFiles = & systemctl list-unit-files libvirtd.service 2>$null
            if ("$unitFiles" -match 'libvirtd\.service') {
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_b9c7d8855a1c978a' -Arguments @{ libvirtd = "$libvirtd" })
            } else {
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_3200a5db7804abee')
            }
        }
        if (Test-Path '/dev/kvm') {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_29160309e2dd574e')
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_858ff13ef34eb20c')
        }
    }
    'host.macos.utm' {
        if (Test-Path '/Applications/UTM.app') {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_0c010045ce278885')
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_1a355714114b86a7')
        }
        if (Get-Command utmctl -ErrorAction SilentlyContinue) {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_592b951962ee6c49')
        } else {
            # See https://yuruna.link/42010605-0002
            $utmctlFix = if (Get-Command Get-MacUtmctlRemediation -ErrorAction SilentlyContinue) {
                Get-MacUtmctlRemediation
            } else {
                'sudo mkdir -p /usr/local/bin && sudo ln -sfn /Applications/UTM.app/Contents/MacOS/utmctl /usr/local/bin/utmctl'
            }
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_4f4e5a1eb5b7cde5' -Arguments @{ utmctlFix = "$utmctlFix" })
        }
    }
}

# --- REGION: Section 5a: macOS permissions only a person can give
# See https://yuruna.link/42010605-0002

if ($HostType -eq 'host.macos.utm' -and (Get-Command Get-MacOperatorGrantState -ErrorAction SilentlyContinue)) {
    Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_6bcdcf9aad9c55be')

    $grantSession = Get-MacSessionKind
    $grantSubject = Get-MacTccSubjectName
    if ($grantSession -eq 'Remote') {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_7080fa67fbe7d466')
    }

    foreach ($grantState in Get-MacOperatorGrantState) {
        $compactFix = @(Get-MacOperatorGrantInstruction -Grant $grantState.Grant -Compact)[0]
        switch ($grantState.State) {
            'granted' {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_f1955d86617ebb46' -Arguments @{ title = "$($grantState.Title)"; grantSubject = "$grantSubject" })
            }
            'overridden' {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_3158e5a38ea4268f' -Arguments @{ title = "$($grantState.Title)"; skipEnvVar = "$($grantState.Grant.SkipEnvVar)" })
            }
            'unprobed' {
                # No probe exists that does not itself raise the dialog, and a
                # gate that pops a modal before every cycle hangs an unattended
                # host. Listed so the prompt is expected rather than a surprise
                # mid-cycle; Enable-TestAutomation triggers and confirms it.
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_f812696e3639649c' -Arguments @{ title = "$($grantState.Title)"; pane = "$($grantState.Grant.Pane)"; grantSubject = "$grantSubject" })
            }
            default {
                $stateNote = if ($grantState.State -eq 'unknown') {
                    "The $($grantState.Title) probe returned no usable answer, which the cycle gate treats as not granted. "
                } else { '' }
                if ($grantSession -eq 'Remote' -or -not $grantState.Blocking) {
                    Write-Warn "$stateNote$compactFix"
                } else {
                    Write-Fail "$stateNote$compactFix"
                    foreach ($line in (Get-MacOperatorGrantInstruction -Grant $grantState.Grant)) { Write-Info $line }
                }
            }
        }
    }
}

# --- REGION: Section 5a2: macOS screen lock / display sleep
# See https://yuruna.link/42010605-0002

if ($HostType -eq 'host.macos.utm' -and (Get-Command Get-MacScreenLockIssue -ErrorAction SilentlyContinue)) {
    Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_ff747670f88f9812')

    $screenLockIssues = @(Get-MacScreenLockIssue)
    if ($screenLockIssues.Count -eq 0) {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_6f4b582f73d5b9a7')
    } else {
        # Inside the failure for the same reason the UTM lifetime section below
        # does it: the FAILURES block carries the message and nothing else.
        foreach ($screenLockIssue in $screenLockIssues) {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_67ce0ab8e4cf372e' -Arguments @{ screenLockIssue = "$screenLockIssue" })
        }
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_9a4d5ce04643bf5f')
    }
}

# --- REGION: Section 5a3: UTM app lifetime
# See https://yuruna.link/42010605-0002

if ($HostType -eq 'host.macos.utm' -and (Get-Command Get-MacUtmLifetimeIssue -ErrorAction SilentlyContinue)) {
    Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_9849668785458289')

    $utmLifetimeIssues = @(Get-MacUtmLifetimeIssue)
    if ($utmLifetimeIssues.Count -eq 0) {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_ec3f20e506fd78d7')
    } else {
        # The remedy rides INSIDE the failure. Write-Summary's FAILURES block
        # re-emits the failure message and nothing else -- an info line that
        # follows it is not recorded at all -- and that block is the whole of
        # what an operator reads when a cycle is refused. A fix written beside
        # the finding reaches only whoever watched the report scroll past.
        foreach ($utmLifetimeIssue in $utmLifetimeIssues) {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_545d6bd235331d52' -Arguments @{ utmLifetimeIssue = "$utmLifetimeIssue" })
        }
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_df9915184f95ea4a')
    }
}

# --- REGION: Section 5b: Host address stability
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_31308c32d6152537')

$beaconMod = Join-Path $script:ModulesDir 'Test.HostAddressBeacon.psm1'
if (-not (Test-Path -LiteralPath $beaconMod)) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_1f6dfcebaead2912' -Arguments @{ beaconMod = "$beaconMod" })
} else {
    try {
        Import-Module $beaconMod -Global -Force -DisableNameChecking -ErrorAction Stop
        $runtimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR }
                      else { Join-Path $TestRoot 'status' -AdditionalChildPath 'runtime' }
        $stability = Get-HostAddressStabilityReport -RuntimeDir $runtimeDir
        switch ($stability.severity) {
            'warning'  { Write-Warn $stability.message }
            'advisory' { Write-Info $stability.message }
            default    { Write-Pass $stability.message }
        }
        # See https://yuruna.link/42010605-0002
        if ($stability.identity.backend -eq 'networkmanager' -and $stability.identity.pinned -eq $false) {
            $pin = Set-HostBridgeDhcpIdentity -Confirm:$false
            if ($pin.verified) {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_57f365ecb6da1349' -Arguments @{ reason = "$($pin.reason)" })
            } elseif ($pin.applied) {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_d36520d366e5684b' -Arguments @{ reason = "$($pin.reason)"; remedy = "$($stability.remedy)" })
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_c29d00df1b36fde9' -Arguments @{ reason = "$($pin.reason)"; remedy = "$($stability.remedy)" })
            }
        } elseif ($stability.remedy) {
            Write-Info "  Remedy: $($stability.remedy)"
        }
    } catch {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_3b73b0337a497028' -Arguments @{ message = "$($_.Exception.Message)" })
    }
}

# --- REGION: Section 5c: Display scaling (OCR)
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_c4c48bd5e5d1638b')

$scaleReport = $null
if (-not $HostType) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_3f1c5859eb0fc0d7')
} elseif ($HostType -eq 'host.ubuntu.kvm') {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_994ef92cd96e4483')
} elseif ($HostType -eq 'host.windows.hyper-v' -and (Get-Command Get-WindowsDisplayScaleIssue -ErrorAction SilentlyContinue)) {
    $scaleReport = Get-WindowsDisplayScaleIssue
    if ($scaleReport.Status -eq 'Clean') {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_f1d89780c596a9dc')
    } elseif ($scaleReport.Status -eq 'Issue') {
        foreach ($scaleIssue in @($scaleReport.Issue)) { Write-Warn $scaleIssue }
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_5fa4b4be805499ca')
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_5a1fbbd3e27b9097')
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_1395b068573e4406')
    } else {
        Write-Info $scaleReport.Detail
    }
} elseif ($HostType -eq 'host.macos.utm' -and (Get-Command Get-MacDisplayScaleIssue -ErrorAction SilentlyContinue)) {
    $scaleReport = Get-MacDisplayScaleIssue -Json (Get-MacDisplayScaleProfile)
    if ($scaleReport.Status -eq 'Clean') {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_35b361a85b3df9f8')
    } elseif ($scaleReport.Status -eq 'Issue') {
        foreach ($scaleIssue in @($scaleReport.Issue)) { Write-Warn $scaleIssue }
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_2a85bda1cd1209c1')
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_bbac623528774da5')
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_605d8136a02536bc')
    } else {
        Write-Info $scaleReport.Detail
    }
} else {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_ced3fcccb0541704' -Arguments @{ hostType = "$HostType" })
}

# --- REGION: Section 5d: Storage filter stack (guest throughput)
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_e2f867223580bc4d')

if (-not $HostType) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_eeb6776b5bd64d89')
} elseif ($HostType -ne 'host.windows.hyper-v') {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_72d89cb5c073471b' -Arguments @{ hostType = "${HostType}" })
} elseif (Get-Command Get-WindowsVhdxFilterProfile -ErrorAction SilentlyContinue) {
    $filterReport = Get-WindowsVhdxFilterIssue -FilterProfile (Get-WindowsVhdxFilterProfile)
    if ($filterReport.Status -eq 'Clean') {
        Write-Pass $filterReport.Detail
    } elseif ($filterReport.Status -eq 'Issue') {
        foreach ($filterIssue in @($filterReport.Issue)) { Write-Warn $filterIssue }
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_0f22cab8656d5071')
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_d0f51031b8e3e54e')
    } else {
        Write-Info $filterReport.Detail
    }
} else {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_232cfca70f56875f')
}

# --- REGION: Section 6: Framework / project staleness
# git fetch + compare HEAD to upstream. WARN (not FAIL) when the local
# clone is behind: the harness can still run, but its runner / index.html
# is older than what landed on main. Repeat for the project clone when
# one exists under <RepoRoot>/project/ (Update-ProjectClone path).

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_b1165d978837552e')

$RepoRoot = Split-Path -Parent $TestRoot

Test-RepoFreshness -Label "framework ($RepoRoot)" -Path $RepoRoot

# projectUrl is needed to classify the <RepoRoot>/project/ state below
# (empty dir + projectUrl set = post-failure leftover from a prior cycle;
# empty dir + no projectUrl = operator never populated the in-tree layout)
# AND for the reachability probe that follows.
$projectUrlConfigured = $null
if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains('projectUrl')) {
    $projectUrlConfigured = [string]$Config.repositories.projectUrl
}

$projectClone = Join-Path $RepoRoot 'project'
if (Test-Path (Join-Path $projectClone '.git')) {
    Test-RepoFreshness -Label "project ($projectClone)" -Path $projectClone
} elseif (Test-Path $projectClone) {
    # See https://yuruna.link/42010605-0002
    $entries = (Get-ChildItem -LiteralPath $projectClone -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($entries -eq 0) {
        $hint = if (Test-IsSet $projectUrlConfigured) {
            (Format-YurunaOperatorMessage -Key 'runner.operator_e36eb642e8f00a48' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured" })
        } else {
            "<RepoRoot>/project/ is empty AND repositories.projectUrl is unset -- nothing will populate it. Either commit the in-tree project layout under project/, or set repositories.projectUrl."
        }
        Write-Fail "<RepoRoot>/project/ exists but is empty (no .git, no files): $projectClone. $hint" -FullPath $projectClone
    } else {
        Write-Info "<RepoRoot>/project/ has $entries entries but no .git -- treating as in-tree project layout (no clone to check)."
    }
} else {
    if (Test-IsSet $projectUrlConfigured) {
        Write-Info "<RepoRoot>/project/ not present -- will be created at cycle start by Update-ProjectClone from '$projectUrlConfigured'."
    } else {
        Write-Info "<RepoRoot>/project/ not present and repositories.projectUrl is unset -- in-tree project layout assumed."
    }
}

# projectUrl reachability probe. Catches three classes of operator
# error before a cycle wastes ~30 s on Update-ProjectClone:
#   * typo / private repo / non-existent repo  -> ls-remote fails fast
#   * file:// URL pointing at a non-existent or non-git path -> Test-Path
#   * file:// URL semantics: host-only, guest fallback structurally broken
if (Test-IsSet $projectUrlConfigured) {
    if ($projectUrlConfigured -match '^(?i)file://') {
        $localPath = $null
        try { $localPath = ([System.Uri]::new($projectUrlConfigured)).LocalPath } catch { $localPath = $null }
        if (-not $localPath) {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_862ae0516e939949' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured" }) -FullPath $ConfigPath
        } elseif (-not (Test-Path -LiteralPath $localPath)) {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_17689903bb502dcb' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured"; localPath = "$localPath" }) -FullPath $ConfigPath
        } elseif (-not (Test-Path -LiteralPath (Join-Path $localPath '.git'))) {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_5886f5f135754edf' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured"; localPath = "$localPath" }) -FullPath $localPath
        } else {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_cfcc5664cd584b70' -Arguments @{ localPath = "$localPath" })
        }
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_1c454b2f57b2a09f' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured" })
    } elseif ($projectUrlConfigured -match '^(?i)(https?|ssh|git)://') {
        # Cheap, no-fetch reachability probe routed through the shared network-git
        # helper: it is prompt-proof (a private/missing repo exits non-zero instead
        # of blocking on a Git Credential Manager dialog) AND authenticates with
        # GH_TOKEN when set, which plain git does not do on its own -- so a private
        # projectUrl reachable only via the token no longer reports as unreachable.
        try {
            $ls  = Invoke-GitNetworkCommand -GitArgs @('ls-remote', '--exit-code', '--quiet', $projectUrlConfigured, 'HEAD') -TimeoutSeconds 30
            if ($ls.ExitCode -eq 0) {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_c382467dc6401b1e' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured" })
            } elseif (Test-GitRemoteAuthFailure -Output $ls.Output) {
                # See https://yuruna.link/42010605-0002
                $remedy = (@(Get-GitAuthRefreshRemedy) -join '; ')
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_53eb2318a1df9482' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured"; exitCode = "$($ls.ExitCode)"; remedy = "$remedy"; output = "$($ls.Output)" }) -FullPath $ConfigPath
            } else {
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_8f1650c0562eb4a1' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured"; exitCode = "$($ls.ExitCode)"; output = "$($ls.Output)" }) -FullPath $ConfigPath
            }
        } catch {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_f4cd25b85f333709' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured"; message = "$($_.Exception.Message)" }) -FullPath $ConfigPath
        }
    } else {
        # No scheme -- accept a bare local path (rare, but git clone
        # treats it identically to file://). Same host-only caveat.
        if (Test-Path -LiteralPath $projectUrlConfigured) {
            if (Test-Path -LiteralPath (Join-Path $projectUrlConfigured '.git')) {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_09fdc948e3ecea79' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured" })
            } else {
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_d7415f48e6da1668' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured" }) -FullPath $projectUrlConfigured
            }
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_aeb2c450546713d2')
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_90e84c1a4288e408' -Arguments @{ projectUrlConfigured = "$projectUrlConfigured" }) -FullPath $ConfigPath
        }
    }
}

# --- REGION: Section 7: GitHub connectivity
# DNS + TCP probes of github.com:443. Surfaces a bad network state HERE
# rather than later when Invoke-GitPull retries inside a running cycle.

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_3c765aa340080677')

try {
    $resolved = [System.Net.Dns]::GetHostAddresses("github.com")
    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_48b1d6d4d9dcda06' -Arguments @{ iPAddressToString = "$($resolved[0].IPAddressToString)" })
    try {
        if (Test-TcpReachable -HostName "github.com" -Port 443 -TimeoutMs 5000) {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_3640b6d07a2b9f5c')
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_6829a064da0c5779')
        }
    } catch {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_11876ad9b473f46f' -Arguments @{ message = "$($_.Exception.Message)" })
    }
} catch {
    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_88fcb4dc7bd3cb87' -Arguments @{ message = "$($_.Exception.Message)" })
}

# --- REGION: Section 8: Top-level fields
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_33144fc4aa1c041f')

if ($Config.Contains("notification")) {
    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_78b1b85cec599efd')
} else {
    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_e9ad154c8280de71')
}

if ($Config.vmImage -is [System.Collections.IDictionary] -and $Config.vmImage.Contains("alwaysRedownload")) {
    Write-Pass "'vmImage.alwaysRedownload' = $($Config.vmImage.alwaysRedownload)"
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_46136d6c5cefc867')
}

if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains("testVmNamePrefix")) {
    Write-Pass "'vmStart.testVmNamePrefix' = '$($Config.vmStart.testVmNamePrefix)'"
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_734940dcb0b577b7')
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("recentDisplayCount")) {
    $rdc = [int]$Config.testCycle.recentDisplayCount
    if ($rdc -gt 0) { Write-Pass "'testCycle.recentDisplayCount' = $rdc" }
    else            { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_a565ade81af18324' -Arguments @{ rdc = "$rdc" }) }
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_b89f268b331febff')
}

if ($Config.Contains("statusService")) {
    $ss = $Config.statusService
    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_0585c7357ad852f5' -Arguments @{ enabled = "$($ss.enabled)"; port = "$($ss.port)" })
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_7769fd67a358d3fe')
}

if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains("frameworkUrl")) {
    Write-Pass "'repositories.frameworkUrl' = '$($Config.repositories.frameworkUrl)'"
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_47d0c2e1e976d3e2')
}

# Deeper validation (URL reachability, <RepoRoot>/project/ state) lives in
# Section 6; here we only flag presence so the top-level summary matches
# frameworkUrl's treatment.
if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains("projectUrl")) {
    $projectUrlVal = [string]$Config.repositories.projectUrl
    if (Test-IsSet $projectUrlVal) {
        Write-Pass "'repositories.projectUrl' = '$projectUrlVal'"
    } else {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_63fc67bee35b878c')
    }
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_c3ffd789e9bc70d8')
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("stopOnFailure")) {
    Write-Pass "'testCycle.stopOnFailure' = $($Config.testCycle.stopOnFailure)"
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_0c04aa1d42c0413b')
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("autoRefreshAfterStalls")) {
    # TryParse, not an [int] cast: a cast throws on a non-number and ends the
    # whole check over one knob, while the runner reads the same value as 0
    # and keeps cycling -- so this reports what the runner will do instead.
    $arasRaw = $Config.testCycle.autoRefreshAfterStalls
    $arasVal = 0
    if (-not [int]::TryParse("$arasRaw".Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$arasVal)) {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_value_not_integer' -Arguments @{ value = "$arasRaw" })
    } elseif ($arasVal -lt 0) {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_fffaa1debcc46863' -Arguments @{ arasVal = "$arasVal" })
    } else {
        Write-Pass "'testCycle.autoRefreshAfterStalls' = $arasVal"
        if ($arasVal -eq 1) {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_threshold_raised')
        }
        # The knob is honored only where automatic repair has been qualified
        # on real hardware; elsewhere the runner counts the evidence and says
        # why it does not act, and this check says so up front.
        $triggerModule = Join-Path $ModulesDir 'Test.HostRefreshTrigger.psm1'
        if ($arasVal -gt 0 -and $HostType -and (Test-Path -LiteralPath $triggerModule)) {
            try {
                Import-Module -Name $triggerModule -Global -Force -DisableNameChecking -ErrorAction Stop
                $arasSupport = Get-HostRefreshAutoTriggerSupport -HostType $HostType
                if (-not $arasSupport.Available) {
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_unavailable_on_host' -Arguments @{ value = "$arasVal"; reason = "$($arasSupport.Reason)" })
                }
            } catch {
                Write-Verbose "autoRefreshAfterStalls availability check skipped: $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_677303e3823afe8d')
}

# Abort here if notification block is missing; nothing more to check.
if (-not $Config.Contains("notification")) { Exit-WithSummary 1 }

$notif = $Config.notification

# Soft migration: surface legacy keys that have moved to status/extension/notification/transports.yml.
if ($notif.Contains('toEmailAddress') -and (Test-IsSet $notif.toEmailAddress)) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_591e6636a34d644a')
}
if ($Config.Contains('secrets') -and $Config.secrets -is [System.Collections.IDictionary] -and $Config.secrets.Contains('resend')) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_38846d9c2742bec3')
}

# --- REGION: Section 9: Extension configs
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_c22d6962ceef7096')

# Enumerated, not listed: an area is anything under test/extension/ that
# carries its own <area>.config.yml, which is the same rule the loader
# discovers by. Naming two of them here left the service areas -- the ones
# whose `service:` blocks feed the VM roster -- validated by nothing, so a
# mistyped key reached a bring-up instead of this report.
$ExtensionSchema = Join-Path $SchemasRoot "extension-config.schema.yml"
foreach ($AreaDir in (Get-ChildItem -LiteralPath $ExtensionRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $AreaConfig = Join-Path $AreaDir.FullName "$($AreaDir.Name).config.yml"
    if (-not (Test-Path -LiteralPath $AreaConfig)) { continue }
    Test-AgainstSchema -Label "$($AreaDir.Name)/$($AreaDir.Name).config.yml" `
        -YamlPath   $AreaConfig `
        -SchemaPath $ExtensionSchema
}

if (-not (Test-Path $NotificationCfgPath)) {
    if (Test-Path $NotificationTmplPath) {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_026b26a8abe44831' -Arguments @{ notificationTmplPath = "$NotificationTmplPath"; notificationCfgPath = "$NotificationCfgPath" })
    } else {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_ea6267baeb75b8d8' -Arguments @{ notificationTmplPath = "$NotificationTmplPath" }) -FullPath $NotificationCfgPath
    }
} else {
    Test-AgainstSchema -Label "transports.yml" `
        -YamlPath   $NotificationCfgPath `
        -SchemaPath (Join-Path $SchemasRoot "notification.transports.schema.yml")
}

$VaultPath = Join-Path $ExtensionStateRoot "authentication/vault.yml"
if (Test-Path $VaultPath) {
    Test-AgainstSchema -Label "vault.yml" `
        -YamlPath   $VaultPath `
        -SchemaPath (Join-Path $SchemasRoot "vault.schema.yml")
} else {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_e378492dce49f390')
}

# --- REGION: Section 9b: Authentication users mapping (users.yml)
# users.yml model + strict-mode rules:
# docs/test-config.md#usersyml--authentication-users-mapping

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_fc89ba8b6dd7e701')

$UsersTemplate = Join-Path $ExtensionRoot      "authentication/users.yml.template"
$UsersPath     = Join-Path $ExtensionStateRoot "authentication/users.yml"
$UsersSchema   = Join-Path $SchemasRoot        "users.schema.yml"

if (-not (Test-Path $UsersPath)) {
    if (Test-Path $UsersTemplate) {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_b4842fc06ed557e0' -Arguments @{ usersTemplate = "$UsersTemplate"; usersPath = "$UsersPath" })
    } else {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_39df6dc9ec54e3b4' -Arguments @{ usersTemplate = "$UsersTemplate" }) -FullPath $UsersTemplate
    }
}

# A runtime users.yml that predates a service VM lacks that service's logical
# user, and the template is copied only when the file is absent -- so the strict
# scan below would refuse a name the operator was never asked about. Loading the
# authentication area reconciles the file first, using the same guarded import
# this script applies to the vault cross-checks further down.
if (Test-Path $UsersPath) {
    try {
        $authExtMod = Join-Path $ModulesDir 'Test.Extension.psm1'
        if ((Test-Path $authExtMod) -and -not (Get-Command Import-Extension -ErrorAction SilentlyContinue)) {
            Import-Module $authExtMod -Force -DisableNameChecking -ErrorAction SilentlyContinue
        }
        if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
            $null = Import-Extension -Area 'authentication' -RequireSingle
            if (Get-Command Read-UsersConfig -ErrorAction SilentlyContinue) { $null = Read-UsersConfig }
        }
    } catch { Write-Verbose "users.yml reconcile skipped: $($_.Exception.Message)" }
}

if (Test-Path $UsersPath) {
    Test-AgainstSchema -Label "users.yml" `
        -YamlPath   $UsersPath `
        -SchemaPath $UsersSchema

    # Parse the file ourselves (Test-AgainstSchema only validates; we
    # need the data structure for the completeness checks below).
    $usersDoc = $null
    try {
        $usersDoc = Read-TestConfig -Path $UsersPath -ThrowOnError
    } catch {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_a3d2174b6f0894d4' -Arguments @{ usersPath = "${UsersPath}"; message = "$($_.Exception.Message)" }) -FullPath $UsersPath
    }

    if ($usersDoc) {
        $strict   = $true
        if ($usersDoc.Contains('strict')) { $strict = ConvertTo-YurunaBool $usersDoc['strict'] }
        $declared = [ordered]@{}
        if ($usersDoc.Contains('users') -and $usersDoc['users'] -is [System.Collections.IDictionary]) {
            foreach ($k in $usersDoc['users'].Keys) { $declared[$k] = $usersDoc['users'][$k] }
        }
        Write-Pass ((Format-YurunaOperatorMessage -Key 'runner.operator_1be4d809249b202a' -Arguments @{ strict = "$strict"; count = "$($declared.Keys.Count)" }))

        # Per-entry shape: forbid half-populated corporate fields. A
        # `sam` without a matching `domain` is almost always an operator
        # mistake (AD prompts want DOMAIN\sam, never bare `sam`); same
        # for `upn` with the @host part missing. Empty-everything is
        # fine (local-only mode).
        foreach ($logical in $declared.Keys) {
            $e = $declared[$logical]
            if ($e -isnot [System.Collections.IDictionary]) { continue }
            $corp = if ($e.Contains('corporate') -and $e['corporate'] -is [System.Collections.IDictionary]) { $e['corporate'] } else { $null }
            if ($corp) {
                $d = if ($corp.Contains('domain')) { [string]$corp['domain'] } else { '' }
                $s = if ($corp.Contains('sam'))    { [string]$corp['sam']    } else { '' }
                $u = if ($corp.Contains('upn'))    { [string]$corp['upn']    } else { '' }
                if ($s -and -not $d -and -not $u) {
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_bddc4f061c193ff1' -Arguments @{ logical = "$logical"; s = "$s" })
                }
                if ($d -and -not $s) {
                    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_10a751722d711129' -Arguments @{ logical = "$logical"; d = "$d" }) -FullPath $UsersPath
                }
                if ($u -and ($u -notmatch '@')) {
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_29607e704f43acdc' -Arguments @{ logical = "$logical"; u = "$u" })
                }
            }
        }

        # vaultKey resolution: a populated vaultKey MUST exist in
        # vault.yml (the vault NEVER auto-generates for an operator-
        # supplied key -- the password is the operator's, not ours).
        # localOsPasswordRef can auto-gen, so we only warn there.
        $vaultDoc = $null
        if (Test-Path $VaultPath) {
            try { $vaultDoc = Read-TestConfig -Path $VaultPath } catch { Write-Verbose "vault.yml parse for users.yml cross-check failed: $_" }
        }
        $vaultUsers = if ($vaultDoc -and $vaultDoc.Contains('users') -and $vaultDoc['users'] -is [System.Collections.IDictionary]) { $vaultDoc['users'] } else { $null }
        foreach ($logical in $declared.Keys) {
            $e = $declared[$logical]
            if ($e -isnot [System.Collections.IDictionary]) { continue }
            $vk = if ($e.Contains('vaultKey')) { [string]$e['vaultKey'] } else { '' }
            if (-not $vk) { continue }
            if (-not $vaultUsers -or -not $vaultUsers.Contains($vk)) {
                if ($strict) {
                    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_a17f41e212009056' -Arguments @{ logical = "$logical"; vk = "$vk"; vaultPath = "$VaultPath" }) -FullPath $VaultPath
                } else {
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_177930a4e66ef405' -Arguments @{ logical = "$logical"; vk = "$vk" })
                }
            } else {
                $pwEntry = $vaultUsers[$vk]
                if ($pwEntry -isnot [System.Collections.IDictionary] -or -not "$($pwEntry['password'])".Trim()) {
                    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_5d9eafcc24be162c' -Arguments @{ logical = "$logical"; vk = "$vk"; vaultPath = "${VaultPath}" }) -FullPath $VaultPath
                } else {
                    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_ab12b4ffc5b9ba50' -Arguments @{ logical = "$logical"; vk = "$vk" })
                }
            }
        }

        # See https://yuruna.link/42010605-0002
        if ($strict) {
            $RepoRoot = Split-Path -Parent $TestRoot
            $sequencesDirs = New-Object System.Collections.Generic.List[string]
            [void]$sequencesDirs.Add((Join-Path $TestRoot 'sequences'))
            # Project tree: every directory named 'test' anywhere under
            # <repo>/project/. Matches Get-ProjectFlatTestSearchDir.
            $projectRoot = Join-Path $RepoRoot 'project'
            if (Test-Path -LiteralPath $projectRoot) {
                Get-ChildItem -LiteralPath $projectRoot -Directory -Recurse -Filter 'test' -ErrorAction SilentlyContinue |
                    ForEach-Object { [void]$sequencesDirs.Add($_.FullName) }
            }
            $referenced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $referencedBy = @{}   # logical user -> first sequence file that introduced it (for the diagnostic)
            foreach ($sd in $sequencesDirs) {
                if (-not (Test-Path -LiteralPath $sd)) { continue }
                Get-ChildItem -LiteralPath $sd -Recurse -File -Include '*.yml' -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        try {
                            $seq = Read-TestConfig -Path $_.FullName
                            if ($seq -is [System.Collections.IDictionary] -and $seq.Contains('variables') -and $seq['variables'] -is [System.Collections.IDictionary]) {
                                if ($seq['variables'].Contains('username')) {
                                    $u = [string]$seq['variables']['username']
                                    if ($u.Trim()) {
                                        $uTrim = $u.Trim()
                                        # Do not [void] the Add() whose Boolean result gates the map: HashSet.Add returns
                                        # $true only on first insert, which is exactly when we want to record the source file.
                                        if ($referenced.Add($uTrim)) { $referencedBy[$uTrim] = $_.FullName }
                                    }
                                }
                            }
                        } catch { Write-Verbose "Skipped unparseable sequence $($_.FullName): $_" }
                    }
            }
            $missing = @($referenced | Where-Object { -not $declared.Contains($_) })
            if ($missing.Count -gt 0) {
                $details = ($missing | ForEach-Object {
                    $by = $referencedBy[$_]
                    if ($by) { "$_ (first seen in $by)" } else { $_ }
                }) -join '; '
                Write-Fail ((Format-YurunaOperatorMessage -Key 'runner.operator_454f982610b474fe' -Arguments @{ usersPath = "$UsersPath"; details = "$details" })) -FullPath $UsersPath
            } else {
                $scannedDirs = ($sequencesDirs | ForEach-Object { $_ }) -join ', '
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_33f3e8bbf91dae40' -Arguments @{ scannedDirs = "$scannedDirs" })
            }
        }
    }
}

# --- REGION: Section 9b2: Sequence files (parse + snippet expansion)
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_6f57742886048a0c')

$seqResolveMod = Join-Path $ModulesDir 'Test.SequenceResolve.psm1'
if (-not (Test-Path $seqResolveMod)) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_2aa6c28c09400b29' -Arguments @{ seqResolveMod = "${seqResolveMod}" })
} else {
    Import-Module $seqResolveMod -Global -Force
    $RepoRoot = Split-Path -Parent $TestRoot
    # Same dir set the runtime resolver walks: the flat framework test/sequences/
    # plus every project <...>/test/ dir (matches Get-ProjectFlatTestSearchDir).
    $seqDirs = New-Object System.Collections.Generic.List[string]
    [void]$seqDirs.Add((Join-Path $TestRoot 'sequences'))
    $projectRoot = Join-Path $RepoRoot 'project'
    if (Test-Path -LiteralPath $projectRoot) {
        Get-ChildItem -LiteralPath $projectRoot -Directory -Recurse -Filter 'test' -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$seqDirs.Add($_.FullName) }
    }

    $seqOk = 0
    $seqDirsScanned = 0
    foreach ($sd in $seqDirs) {
        if (-not (Test-Path -LiteralPath $sd)) { continue }
        $seqDirsScanned++
        Get-ChildItem -LiteralPath $sd -File -Filter '*.yml' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('_snippets.yml', 'actions.yml') } |
            ForEach-Object {
                $sequenceFile = $_
                try {
                    $null = Read-SequenceFile -Path $sequenceFile.FullName -NoCache
                    $seqOk++
                } catch {
                    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_e77f47f87173b4b2' -Arguments @{ name = "$($sequenceFile.Name)"; message = "$($_.Exception.Message)" }) -FullPath $sequenceFile.FullName
                }
            }
        # Shape-check the snippet library in this dir even when no sequence
        # references it yet (a broken library otherwise stays invisible).
        $libPath = Join-Path $sd '_snippets.yml'
        if (Test-Path -LiteralPath $libPath) {
            try {
                $lib = Read-TestConfig -Path $libPath -ThrowOnError
                if ($lib -isnot [System.Collections.IDictionary] -or $lib.Keys.Count -eq 0) {
                    Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_84438f498d1117e7') -FullPath $libPath
                } else {
                    $libBad = $false
                    foreach ($snipName in $lib.Keys) {
                        $val = $lib[$snipName]
                        if ($val -isnot [System.Collections.IEnumerable] -or $val -is [string] -or @($val).Count -eq 0) {
                            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_ae8d65a75135365d' -Arguments @{ snipName = "$snipName" }) -FullPath $libPath
                            $libBad = $true
                        }
                    }
                    if (-not $libBad) { Write-Pass "_snippets.yml: $($lib.Keys.Count) snippet(s) in $sd." }
                }
            } catch {
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_28e8e9b79ddad7c6' -Arguments @{ message = "$($_.Exception.Message)" }) -FullPath $libPath
            }
        }
    }
    if ($seqDirsScanned -eq 0) {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_b9316184e6e485e7' -Arguments @{ testRoot = "$TestRoot" })
    } else {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_ad68246ca1c72839' -Arguments @{ seqOk = "$seqOk"; seqDirsScanned = "$seqDirsScanned" })
    }
}

# --- REGION: Section 9b3: Stale SMB alias mappings (Windows)
# See https://yuruna.link/42010605-0002
if ($IsWindows) {
    $smbMod = Join-Path $ModulesDir 'Test.PoolStorage.psm1'
    if (Test-Path $smbMod) {
        Import-Module $smbMod -Global -Force
        Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_54ee1bd625685124')
        $stale = @(Get-PoolStorageStaleAliasMount)
        if ($stale.Count -eq 0) {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_097d3c2b155e207c')
        } else {
            $smbInteractive = Test-YurunaCanPrompt
            foreach ($s in $stale) {
                $label = if ($s.LocalPath) { "$($s.LocalPath) -> $($s.RemotePath)" } else { $s.RemotePath }
                $removed = $false
                if ($smbInteractive) {
                    $ans = Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_a9a23fce8657fc58' -Arguments @{ label = "$label"; serverName = "$($s.ServerName)" })
                    if ($ans.Trim() -match '^(y|yes)$') {
                        $removed = Remove-PoolStorageStaleAliasMount -LocalPath $s.LocalPath -RemotePath $s.RemotePath -Confirm:$false
                    }
                }
                if ($removed) {
                    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_d11a2ae621d88853' -Arguments @{ label = "$label"; serverName = "$($s.ServerName)" })
                } else {
                    $fix = if ($s.LocalPath) { "net use $($s.LocalPath) /delete" } else { "net use `"$($s.RemotePath)`" /delete" }
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_01700f1923eea4fd' -Arguments @{ label = "$label"; serverName = "$($s.ServerName)"; fix = "$fix" })
                }
            }
        }
    }
}

# See https://yuruna.link/42010605-0002
$script:LinuxSudoHintShown = $false
# --- REGION: Show-LinuxSudoHintOnce
function Show-LinuxSudoHintOnce {
    if (-not $IsLinux -or $script:LinuxSudoHintShown) { return }
    if (-not (Get-Command Get-PoolStorageLinuxSudoHint -ErrorAction SilentlyContinue)) { return }
    # A mount can fail at the mount STAGE for reasons that have nothing to do with
    # sudo. Printing the drop-in instructions to an operator whose drop-in is
    # already installed and working reads as "the install silently failed", and
    # sends them to redo the one thing that is not broken. Probe first; when
    # passwordless sudo is already in effect, say so and name what is left.
    if ((Get-Command Test-PoolStorageSudoReady -ErrorAction SilentlyContinue) -and (Test-PoolStorageSudoReady)) {
        $script:LinuxSudoHintShown = $true
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_fd00846b1ca24525')
        if ((Get-Command Test-PoolStorageCifsHelper -ErrorAction SilentlyContinue) -and -not (Test-PoolStorageCifsHelper)) {
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_8876dbd248f20ffb')
        }
        return
    }
    $script:LinuxSudoHintShown = $true
    $acct = ''
    try { $acct = [string](& id -un 2>$null | Select-Object -First 1) } catch { $null = $_ }
    if ([string]::IsNullOrWhiteSpace($acct)) { $acct = [string]$env:USER }
    $p = Get-PoolStorageSudoCommandPath
    $hint = Get-PoolStorageLinuxSudoHint -User ($acct.Trim()) `
        -MkdirPath $p.Mkdir -MountPath $p.Mount -UmountPath $p.Umount
    foreach ($line in $hint) { Write-Info $line }
}

# --- REGION: Invoke-LinuxSudoInstallOffer
# See https://yuruna.link/42010605-0002
function Invoke-LinuxSudoInstallOffer {
    if (-not $IsLinux) { return $false }
    if (-not (Get-Command Set-PoolStorageSudoers -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Test-YurunaCanPrompt)) { return $false }
    $ans = Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_13739a97fa0dd2d6')
    if ($ans -notmatch '^\s*(y|yes)\s*$') { return $false }
    try {
        $result = Set-PoolStorageSudoers -Confirm:$false
    } catch {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_8da15c4079305665' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    switch ($result.Action) {
        'installed' { Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_f604a60885fe8ac0' -Arguments @{ dropInPath = "$($result.DropInPath)" }); return $true }
        'present'   { Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_cd539eb724df3b7b'); return $false }
        default     { Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_89bc789c5a9bf8b6' -Arguments @{ action = "$($result.Action)"; message = "$($result.Message)" }); return $false }
    }
}

# --- REGION: Invoke-PoolStorageVaultCredentialOffer
# See https://yuruna.link/42010605-0002
function Invoke-PoolStorageVaultCredentialOffer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The password is read as a SecureString; the brief plaintext only feeds the vault Set-Password, which stores plaintext by design.')]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Config)

    $who = [string]$Config.NetworkUser
    if ([string]::IsNullOrWhiteSpace($who)) { return $false }
    if (-not (Test-YurunaCanPrompt)) { return $false }
    if (-not (Get-Command Set-Password -ErrorAction SilentlyContinue)) {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_6c376ecc3b030b2b')
        return $false
    }

    $ans = Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_4fedc1c554253c53' -Arguments @{ who = "$who" })
    if ($ans -notmatch '^\s*(y|yes)\s*$') { return $false }

    # These two reads are the only ones here with no fallback value: every other
    # offer above degrades to "not offered, here are the manual steps", while a
    # secure read that cannot reach anybody just blocks. Re-assert rather than
    # trust the guard at the top of the function, because the distance between
    # them is where a future edit puts a new early return.
    Assert-YurunaPromptable -Question "networkStorage pool: the NAS password for '$who'" `
        -ConfigKey "a vaultKey for '$who' in users.yml, with the password stored by Set-Password"

    # Typed twice: with the NAS offline nothing in this run reads the value back,
    # so a typo would otherwise sit in the vault until a cycle's mount fails.
    $plain   = ''
    $confirm = ''
    try {
        $plain   = [System.Net.NetworkCredential]::new('', (Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_8ea75e717f95ddea' -Arguments @{ who = "$who" }) -AsSecureString)).Password
        $confirm = [System.Net.NetworkCredential]::new('', (Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_479872781526f6ad') -AsSecureString)).Password
    } catch {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_8c7d39a3f7c000e6' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    if ([string]::IsNullOrEmpty($plain)) {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_c3ac8715e2a04f7c')
        return $false
    }
    if ($plain -cne $confirm) {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_8d6716d9de6b4e1f')
        return $false
    }

    # Map the account to a vault key equal to its own name when users.yml carries
    # none: that is the same slot Set-Password writes below, and a non-empty
    # vaultKey is what keeps Get-Password off the auto-generate path from here on.
    $vaultKey = ''
    if (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) {
        try { $vaultKey = [string](Get-EffectiveUser -LogicalUser $who).vaultKey } catch { $null = $_ }
    }
    if ([string]::IsNullOrWhiteSpace($vaultKey)) {
        $vaultKey = $who
        if (Get-Command Set-UserVaultKey -ErrorAction SilentlyContinue) {
            try {
                if (Set-UserVaultKey -LogicalUser $who -VaultKey $vaultKey -Confirm:$false) {
                    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_4e969d1c3be24d52' -Arguments @{ who = "$who"; vaultKey = "$vaultKey" })
                }
            } catch {
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_37ec87c9e9d924bd' -Arguments @{ message = "$($_.Exception.Message)"; vaultKey = "$vaultKey" })
            }
        }
    }

    try { Set-Password -Username $vaultKey -NewPassword $plain }
    catch {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_a505fe65d0a4d0bd' -Arguments @{ who = "$who"; message = "$($_.Exception.Message)" })
        return $false
    }
    # This process resolved users.yml before the vaultKey write, so drop the
    # cached parse; the re-check below must read the mapping just written.
    if (Get-Command Reset-UsersConfigCache -ErrorAction SilentlyContinue) { $null = Reset-UsersConfigCache -Confirm:$false }
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_8e2f7fcb0f42a7f2' -Arguments @{ who = "$who"; vaultKey = "$vaultKey" })
    # A single quote survives the vault fine but unbalances the single-quoted
    # cifs credential/env entries the guest seeds are built from, so the pool
    # share would never mount inside the caching-proxy-service and pool-control-service VMs.
    if ($plain -match "'") {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_fef8036135271420')
    }
    return $true
}

# --- REGION: Show-NetworkStorageFieldSwapWarning
# See https://yuruna.link/42010605-0002
function Show-NetworkStorageFieldSwapWarning {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('pool', 'stash')][string]$Prefix
    )
    if ([string]::IsNullOrWhiteSpace($Config.NetworkUser)) { return }
    if ($Config.NetworkUser.Trim() -notmatch '^[A-Za-z]:\\?$') { return }
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_3e39dac627850b07' -FormatValues ($Prefix, $Config.NetworkUser.Trim()) -FormatBindings @{ prefix = '0'; trim = '1' })
}

# --- REGION: Section 9c: networkStorage pool (ypool-nas) archiving
# See https://yuruna.link/42010605-0002

Write-Section "networkStorage: pool (ypool-nas) archiving"

$poolMod = Join-Path $ModulesDir 'Test.PoolStorage.psm1'
if (-not (Test-Path $poolMod)) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_c178ba624b770623' -Arguments @{ poolMod = "${poolMod}" })
} else {
    Import-Module $poolMod -Global -Force
    # See https://yuruna.link/42010605-0002
    $storageGap = "Shared storage was configured in this run, but $ConfigPath records none of it"
    $psRaw = if ($Config.Contains('networkStorage')) { $Config['networkStorage'] } else { $null }
    if ($psRaw -isnot [System.Collections.IDictionary]) {
        if ($ExpectStorageConfigured) {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_821dd1b41692b0f2' -Arguments @{ storageGap = "$storageGap" }) -FullPath $ConfigPath
        } else {
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_2879ced5085e2e16')
        }
    } else {
        # Deprecated kill switch. It no longer means anything: the three populated
        # paths are the opt-in, and moveLogsToPoolStorage selects the mode. Say so
        # once and move on -- failing on a key that has lost its meaning would take
        # down every host in the field at upgrade, for a value nothing reads.
        if ($Config.Contains('pool') -and $Config['pool'] -is [System.Collections.IDictionary] -and
            $Config['pool'].Contains('networkReplicate')) {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_c3aa027f622ca873')
        }
        # The three paths ARE the opt-in; moveLogsToPoolStorage selects the MODE and
        # therefore the severity here. In move mode a broken share is a FAIL (the
        # local copy is about to be deleted, so archiving has to work); in copy mode
        # it is advisory (WARN) -- the cycle runs fine and the backlog waits.
        $psMove = $false
        if ($Config['networkStorage'] -is [System.Collections.IDictionary]) {
            $psMove = ConvertTo-YurunaBool $Config['networkStorage']['moveLogsToPoolStorage']
        }
        $psCfg = Get-YurunaPoolStorageConfig -Config $Config -WarningAction SilentlyContinue
        if (-not $psCfg) {
            $incomplete = "networkStorage poolStorageNetworkPath / poolStorageNetworkUser / poolStorageLocalPath are not all set"
            if ($psMove) {
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_bb84cf73d6dede95' -Arguments @{ incomplete = "$incomplete" }) -FullPath $ConfigPath
            } elseif ($ExpectStorageConfigured) {
                Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_429270c31c75cd44' -Arguments @{ storageGap = "$storageGap"; incomplete = "$incomplete" }) -FullPath $ConfigPath
            } else {
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_381e378016d0a748' -Arguments @{ incomplete = "$incomplete" })
            }
        } else {
            $psState = if ($psMove) { 'move -- local folders deleted after archiving' } else { 'copy -- local folders kept' }
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_9cbd07715695576e' -Arguments @{ psState = "$psState"; networkPath = "$($psCfg.NetworkPath)"; localPath = "$($psCfg.LocalPath)"; networkUser = "$($psCfg.NetworkUser)" })
            Show-NetworkStorageFieldSwapWarning -Config $psCfg -Prefix 'pool'

            # Vault credential readiness (read-only loud-fail pre-check). Needs the
            # authentication extension for Get-EffectiveUser + Test-VaultEntry.
            if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue)) {
                $extMod = Join-Path $ModulesDir 'Test.Extension.psm1'
                if ((Test-Path $extMod) -and -not (Get-Command Import-Extension -ErrorAction SilentlyContinue)) {
                    Import-Module $extMod -Global -Force -ErrorAction SilentlyContinue
                }
                if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
                    try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
                }
            }
            # Captured for the ACTIVE mount + per-host-folder pre-flight below: it
            # is only attempted when a real credential is configured AND the server
            # answered on :445, so a merely-offline NAS stays a transient WARN and
            # never triggers a doomed mount that would FAIL a healthy cycle.
            $psVaultReady = $false
            $psReachable  = $false
            if (Get-Command Test-PoolStorageVaultReady -ErrorAction SilentlyContinue) {
                $psVaultReady = [bool](Test-PoolStorageVaultReady -Config $psCfg -WarningAction SilentlyContinue)
                # Missing credential + an operator at the keyboard: ask for the
                # password now, then re-run the same read-only pre-check so what
                # is reported is what the mount path can actually resolve.
                if (-not $psVaultReady -and (Invoke-PoolStorageVaultCredentialOffer -Config $psCfg)) {
                    $psVaultReady = [bool](Test-PoolStorageVaultReady -Config $psCfg -WarningAction SilentlyContinue)
                }
                if ($psVaultReady) {
                    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_ea5ac83c77e1137f' -Arguments @{ networkUser = "$($psCfg.NetworkUser)" })
                } else {
                    # Naming the command matters: run through a gate or a runner
                    # this check's stdout is captured, so the offer above never
                    # fires no matter how interactive the terminal that started
                    # the run looks. `pwsh test/Test-Config.ps1` is the only
                    # invocation that can still ask.
                    $vmsg = "networkStorage pool: '$($psCfg.NetworkUser)' has no usable vault credential -- mounting would auto-generate a junk SMB password the NAS rejects. Run 'pwsh test/Test-Config.ps1' directly from a terminal to be prompted for the password, or map a non-empty vaultKey in users.yml and Set-Password it. See docs/test-config.md."
                    if ($psMove) { Write-Fail $vmsg -FullPath $ConfigPath }
                    else         { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_d59d71dd492c6417' -Arguments @{ vmsg = "$vmsg" }) }
                }
            }

            # SMB server reachability (best-effort; WARN either way -- the NAS may be
            # intentionally offline at config-check time).
            if (Get-Command Test-PoolStorageServerReachable -ErrorAction SilentlyContinue) {
                $poolSrv = Get-PoolStorageServerName -NetworkPath $psCfg.NetworkPath
                if (Test-PoolStorageServerReachable -Config $psCfg -TimeoutSeconds 5) {
                    $psReachable = $true
                    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_3a6055c5ca48a3d6' -Arguments @{ poolSrv = "${poolSrv}" })
                } else {
                    $tail = 'Archiving will fail-fast and retry next cycle'
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_74af72f98d8ae98f' -Arguments @{ poolSrv = "${poolSrv}"; tail = "$tail" })
                }
            }

            # See https://yuruna.link/42010605-0002
            $psCanMount = $true
            if ($IsLinux) {
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_a8133f2805b1809a')
                if ((Get-Command Test-PoolStorageCifsHelper -ErrorAction SilentlyContinue) -and -not (Test-PoolStorageCifsHelper)) {
                    $psCanMount = $false
                    $cmsg = "networkStorage pool: the mount.cifs helper (package cifs-utils) is not installed, so 'mount -t cifs' cannot mount '$($psCfg.NetworkPath)' at all -- archiving would silently never happen. Fix: sudo apt-get install -y cifs-utils"
                    if ($psMove) { Write-Fail $cmsg -FullPath $ConfigPath }
                    else         { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_a0fd1e82ea401724' -Arguments @{ cmsg = "$cmsg" }) }
                }
            }

            # See https://yuruna.link/42010605-0002
            if ($psVaultReady -and $psReachable -and $psCanMount -and (Get-Command Initialize-PoolStorageHostFolder -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
                    $ydMod = Join-Path $ModulesDir 'Test.YurunaDir.psm1'
                    if (Test-Path $ydMod) { Import-Module $ydMod -Global -Force -ErrorAction SilentlyContinue }
                }
                $poolHostId = ''
                if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) {
                    try { $poolHostId = [string](Get-YurunaHostId) } catch { $null = $_ }
                }
                if ([string]::IsNullOrWhiteSpace($poolHostId)) {
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_dbcd555c3728cb0c')
                } else {
                    $poolReady = Initialize-PoolStorageHostFolder -Config $psCfg -HostId $poolHostId -Confirm:$false
                    # A mount-stage failure on Linux is the passwordless-sudo
                    # precondition. From an interactive session, offer to install
                    # the drop-in now (sudo prompts once) and retry, so the
                    # operator ends with a working mount instead of instructions.
                    if (-not $poolReady.ok -and $poolReady.stage -eq 'mount' -and (Invoke-LinuxSudoInstallOffer)) {
                        $poolReady = Initialize-PoolStorageHostFolder -Config $psCfg -HostId $poolHostId -Confirm:$false
                    }
                    if ($poolReady.ok) {
                        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_c7ba05194a3bd438' -Arguments @{ folder = "$($poolReady.folder)" })
                        # See https://yuruna.link/42010605-0002
                        if ((Get-Command Get-PoolStorageFreeSpace -ErrorAction SilentlyContinue) -and
                            (Get-Command Test-PoolStorageSpaceSufficient -ErrorAction SilentlyContinue)) {
                            $psFree = Get-PoolStorageFreeSpace -Config $psCfg
                            $psProjected = [long]0
                            if (Get-Command Get-PoolStorageProjectedSize -ErrorAction SilentlyContinue) {
                                $psLedger = $null
                                if ((Get-Command Read-PoolStorageLedger -ErrorAction SilentlyContinue) -and $env:YURUNA_RUNTIME_DIR) {
                                    try { $psLedger = Read-PoolStorageLedger -RuntimeDir $env:YURUNA_RUNTIME_DIR } catch { $null = $_ }
                                }
                                $psProjected = Get-PoolStorageProjectedSize -Ledger $psLedger
                            }
                            $psSpace = Test-PoolStorageSpaceSufficient -FreeBytes $psFree -NeedBytes $psProjected
                            if ($psFree -lt 0) {
                                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_7bb3da38a5d7e7db' -Arguments @{ localPath = "$($psCfg.LocalPath)" })
                            } elseif ($psSpace.ok) {
                                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_f9bd7402f4afe362' -Arguments @{ psFree = "$(Format-PoolStorageSize -Bytes $psFree)"; required = "$(Format-PoolStorageSize -Bytes ([long]$psSpace.required))" })
                            } else {
                                $smsg = "networkStorage pool: the share is FULL -- $(Format-PoolStorageSize -Bytes $psFree) free but the next cycle needs $(Format-PoolStorageSize -Bytes ([long]$psSpace.required)) (a $(Format-PoolStorageSize -Bytes ([long]$psSpace.reserve)) reserve plus the projected cycle). Delete old cycle archives under '$($psCfg.LocalPath)/hosts/' to continue."
                                if ($psMove) { Write-Fail $smsg -FullPath $ConfigPath }
                                else         { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_3e0f575b80a127ef' -Arguments @{ smsg = "$smsg" }) }
                            }
                        }
                    } else {
                        $rmsg = "networkStorage pool: localPath '$($psCfg.LocalPath)' / per-host folder pre-flight FAILED -- $($poolReady.error). Archiving would silently never happen this way."
                        if ($psMove) { Write-Fail $rmsg -FullPath $ConfigPath }
                        else         { Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_ba1fbebc7e7c674e' -Arguments @{ rmsg = "$rmsg" }) }
                        # Interactive install was declined/unavailable or did not
                        # resolve it; print the exact one-time manual fix (a
                        # folder-stage failure is a share-permission issue, not sudo).
                        if ($poolReady.stage -eq 'mount') { Show-LinuxSudoHintOnce }
                    }
                }
            }
        }
    }
}

# --- REGION: Section 9c-stash: networkStorage stash (stash service)
# The stash storage is ISOLATED from the pool (its own share + account). It is
# optional (only the stash service uses it); issues here are advisory WARN, not
# FAIL -- Start-StashServiceVM hard-fails at build time when it is misconfigured.
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_7c3b74aee8065b96')

if (-not (Test-Path $poolMod)) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_7802715aece5a427' -Arguments @{ poolMod = "${poolMod}" })
} else {
    $stashCfg = Get-YurunaStashStorageConfig -Config $Config
    if (-not $stashCfg) {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_ffdf0ec57b7c1018')
    } else {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_9915e940a1da77b3' -Arguments @{ networkPath = "$($stashCfg.NetworkPath)"; localPath = "$($stashCfg.LocalPath)"; networkUser = "$($stashCfg.NetworkUser)" })
        Show-NetworkStorageFieldSwapWarning -Config $stashCfg -Prefix 'stash'
        if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue)) {
            $extMod = Join-Path $ModulesDir 'Test.Extension.psm1'
            if ((Test-Path $extMod) -and -not (Get-Command Import-Extension -ErrorAction SilentlyContinue)) {
                Import-Module $extMod -Global -Force -ErrorAction SilentlyContinue
            }
            if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
                try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
            }
        }
        # A stored credential is REQUIRED for the stash SMB user (a pre-existing NAS
        # account); a missing one bakes a junk password the NAS rejects.
        $stashCredStored = $false
        if (Get-Command Test-PoolStorageStoredCredential -ErrorAction SilentlyContinue) {
            if (Test-PoolStorageStoredCredential -Config $stashCfg) {
                $stashCredStored = $true
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_36a0c0c3f00220da' -Arguments @{ networkUser = "$($stashCfg.NetworkUser)" })
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_049237316d77c7da' -Arguments @{ networkUser = "$($stashCfg.NetworkUser)" })
            }
        }
        $stashReachable = $false
        if (Get-Command Test-PoolStorageServerReachable -ErrorAction SilentlyContinue) {
            $stashSrv = Get-PoolStorageServerName -NetworkPath $stashCfg.NetworkPath
            if (Test-PoolStorageServerReachable -Config $stashCfg -TimeoutSeconds 5) {
                $stashReachable = $true
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_495de90c02dcebfa' -Arguments @{ stashSrv = "${stashSrv}" })
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_5aeee726766bfcc2' -Arguments @{ stashSrv = "${stashSrv}" })
            }
        }
        # See https://yuruna.link/42010605-0002
        if ($stashCredStored -and $stashReachable -and (Get-Command Initialize-PoolStorageTargetFolder -ErrorAction SilentlyContinue)) {
            $mk = Initialize-PoolStorageTargetFolder -Config $stashCfg -Confirm:$false
            if ($mk.ok) {
                if ($mk.created) {
                    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_2d081dc4f844e0a1' -Arguments @{ networkPath = "$($stashCfg.NetworkPath)" })
                } else {
                    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_8c146a9b7bdc38e4' -Arguments @{ networkPath = "$($stashCfg.NetworkPath)" })
                }
                if (Get-Command Connect-YurunaPoolStorage -ErrorAction SilentlyContinue) {
                    if (Connect-YurunaPoolStorage -Config $stashCfg -Confirm:$false) {
                        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_f269de2ad6ee350e' -Arguments @{ localPath = "$($stashCfg.LocalPath)"; networkPath = "$($stashCfg.NetworkPath)" })
                    } else {
                        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_f333ab0d208b4279' -Arguments @{ localPath = "$($stashCfg.LocalPath)"; networkPath = "$($stashCfg.NetworkPath)"; networkUser = "$($stashCfg.NetworkUser)" })
                        Show-LinuxSudoHintOnce
                    }
                }
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_f16b33065df96aff' -Arguments @{ networkPath = "$($stashCfg.NetworkPath)"; error = "$($mk.error)" })
                if ($mk.error -match 'mount') { Show-LinuxSudoHintOnce }
            }
        }
    }
}

# --- REGION: Section 9c2: Extension services registered with the pool
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_396ff2b33b372c04')

$aggregatorMod = Join-Path $ExtensionRoot 'pool-aggregator-service/default.psm1'
$cachingProxyMod = Join-Path $ModulesDir 'Test.CachingProxyService.psm1'
if (-not (Test-Path $aggregatorMod)) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_af99c7ba81671188' -Arguments @{ aggregatorMod = "${aggregatorMod}" })
} else {
    Import-Module $aggregatorMod -Global -Force -DisableNameChecking
    if (Test-Path $cachingProxyMod) { Import-Module $cachingProxyMod -Global -Force -DisableNameChecking }
    # Test-StashServiceHost is the same /healthz gate the cycle pre-flight and
    # the guest workloads apply; borrowing it keeps one definition of reachable.
    $stashExtensionMod = Join-Path $ExtensionRoot 'stash-service/default.psm1'
    if (Test-Path $stashExtensionMod) { Import-Module $stashExtensionMod -Global -Force -DisableNameChecking }
    $aggregatorBase = ''
    if (Get-Command Get-PoolAggregatorServiceSeedUrl -ErrorAction SilentlyContinue) {
        try { $aggregatorBase = [string](Get-PoolAggregatorServiceSeedUrl) } catch { $aggregatorBase = '' }
    }
    if ([string]::IsNullOrWhiteSpace($aggregatorBase)) {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_7baf67dc0d2b3c7e')
    } else {
        $registry = $null
        try {
            $registryResponse = Invoke-WebRequest -Uri "$($aggregatorBase.TrimEnd('/'))/api/v1/extension-hosts" `
                -TimeoutSec 8 -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
            if ([int]$registryResponse.StatusCode -eq 200) {
                $registry = $registryResponse.Content | ConvertFrom-Json
            } else {
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_7a587dcfad92db2b' -Arguments @{ aggregatorBase = "$aggregatorBase"; statusCode = "$([int]$registryResponse.StatusCode)" })
            }
        } catch {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_b3bd312c3840b48b' -Arguments @{ aggregatorBase = "$aggregatorBase"; message = "$($_.Exception.Message)" })
        }
        if ($registry) {
            # services carries every (hostId, area) the pool knows, including the
            # ones it has refused; older aggregators answer with areas only, and
            # then only the resolvable entries can be reported.
            $services = @()
            if ($registry.PSObject.Properties.Name -contains 'services' -and $registry.services) {
                $services = @($registry.services)
            } elseif ($registry.PSObject.Properties.Name -contains 'areas' -and $registry.areas) {
                $services = @($registry.areas.PSObject.Properties | ForEach-Object { $_.Value })
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_af08cdf0a2ea5eb0')
            }
            $stashServices = @($services | Where-Object { [string]$_.area -eq 'stash-service' })
            if ($stashServices.Count -eq 0) {
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_ca2d9cb6ab58a961')
            } else {
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_53abe225fc1d2a82' -FormatValues ($stashServices.Count, $aggregatorBase) -FormatBindings @{ count = '0'; aggregatorBase = '1' })
                $stashReachableCount = 0
                foreach ($service in $stashServices) {
                    # The pool's own verdict comes first: it refuses an address
                    # it cannot reach, and says why.
                    $advertised = [string]$service.target
                    if ([string]::IsNullOrWhiteSpace($advertised)) { $advertised = [string]$service.suppressedTarget }
                    $who = "hostId $([string]$service.hostId)"
                    if ([bool]$service.suppressed) {
                        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_e255a2fa4ebf8560' -FormatValues ($who, $advertised, [string]$service.suppressReason) -FormatBindings @{ who = '0'; advertised = '1'; suppressReason = '2' })
                        continue
                    }
                    if ([string]::IsNullOrWhiteSpace($advertised)) {
                        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_189c612ee620b50b' -Arguments @{ who = "$who" })
                        continue
                    }
                    # See https://yuruna.link/42010605-0002
                    $stashAddress = [string]$service.host
                    if ([string]::IsNullOrWhiteSpace($stashAddress)) {
                        $parsed = $null
                        if ([uri]::TryCreate($advertised, [System.UriKind]::Absolute, [ref]$parsed)) { $stashAddress = $parsed.Host }
                    }
                    if ([string]::IsNullOrWhiteSpace($stashAddress)) {
                        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_f2261fdec6afa6d4' -Arguments @{ who = "$who"; advertised = "$advertised" })
                        continue
                    }
                    $stashAnswers = $false
                    if (Get-Command Test-StashServiceHost -ErrorAction SilentlyContinue) {
                        $stashAnswers = Test-StashServiceHost -Address $stashAddress -Attempts 2 -TimeoutSeconds 4 -BackoffMs 250
                    } else {
                        $stashAnswers = Test-TcpReachable -HostName $stashAddress -Port 80 -TimeoutMs 4000
                    }
                    if ($stashAnswers) {
                        $stashReachableCount++
                        Write-Pass ((Format-YurunaOperatorMessage -Key 'runner.operator_91539d8a51701986' -Arguments @{ advertised = "$advertised"; who = "$who"; source = "$([string]$service.source)" }))
                    } else {
                        Write-Warn ((Format-YurunaOperatorMessage -Key 'runner.operator_ce1a66ba81c93de0' -Arguments @{ advertised = "$advertised"; who = "$who" }))
                    }
                }
                if ($stashReachableCount -eq 0) {
                    # Advisory, not a gate. This gate REFUSES TO START the runner
                    # loop on a FAIL, and whether a stash is needed at all is the
                    # project's business, not the framework's -- so a service on
                    # another machine being down must not wedge a lab that would
                    # otherwise keep cycling and recover on its own.
                    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_47513825bfb62345')
                }
            }
            # Other areas are reported too, but only as a refusal: nothing in a
            # cycle's critical path resolves them, so an unreachable one is
            # information rather than a warning.
            foreach ($service in @($services | Where-Object { [string]$_.area -ne 'stash-service' -and [bool]$_.suppressed })) {
                Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_46a6457a7fba0801' -FormatValues ([string]$service.area, [string]$service.hostId, [string]$service.suppressedTarget, [string]$service.suppressReason) -FormatBindings @{ area = '0'; hostId = '1'; suppressedTarget = '2'; suppressReason = '3' })
            }
        }
    }
}

# --- REGION: Section 9d: Pool (intent sync)
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_cd4a2a8be6258515')

$poolSyncMod = Join-Path $ModulesDir 'Test.PoolSync.psm1'
if (-not (Test-Path $poolSyncMod)) {
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_e5337260a89228ec' -Arguments @{ poolSyncMod = "${poolSyncMod}" })
} else {
    Import-Module $poolSyncMod -Global -Force
    $plRaw = if ($Config.Contains('pool')) { $Config['pool'] } else { $null }
    if ($plRaw -isnot [System.Collections.IDictionary]) {
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_11155c290bdca317')
    } else {
        $plEnabled = ConvertTo-YurunaBool $plRaw['enabled']
        $plUrl     = [string]$plRaw['intentGitUrl']
        if ([string]::IsNullOrWhiteSpace($plUrl)) {
            if ($plEnabled) { Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_af0aca34836ac8bb') -FullPath $ConfigPath }
            else            { Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_93ef9f12e66f06e9') }
        } else {
            $plState = if ($plEnabled) { 'enabled' } else { 'configured (disabled)' }
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_ccfb3b8777922241' -Arguments @{ plState = "$plState"; plUrl = "$plUrl" })
            # Bounded, credential-prompt-proof reachability probe (read-only).
            $rc = Invoke-PoolSyncGit -ArgumentList @('ls-remote', '--quiet', $plUrl) -TimeoutSeconds 15
            if ($rc -eq 0) {
                Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_1d0efcf0a84c0f0f' -Arguments @{ plUrl = "$plUrl" })
            } else {
                $why = if ($rc -eq 124) { 'timed out' } elseif ($rc -eq -1) { 'git not available' } else { "git ls-remote exit $rc" }
                Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_205f4d4b991b0dd3' -Arguments @{ plUrl = "$plUrl"; why = "$why" })
            }
        }
    }
}

# --- REGION: Section 10: Resend transport settings
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_aae122a5ae775d3f')

$resend = $null
if (-not (Test-Path $NotificationCfgPath)) {
    # The missing FILE is already a warning under 'Extension configs', with the
    # consequence and the fix. Warning again that a section is absent from a
    # file that does not exist would be the same fact reported twice.
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_7031f8ba704491cb')
} else {
    $notifCfgReadable = $true
    try {
        $notifCfg = Read-TestConfig -Path $NotificationCfgPath -ThrowOnError
        if ($notifCfg.Contains('transports') -and $notifCfg.transports.Contains('resend')) {
            $resend = $notifCfg.transports.resend
        }
    } catch {
        # The parse failure is the finding; a "not configured" warning on top
        # of it would blame the operator's settings for a broken file.
        $notifCfgReadable = $false
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_0aebef8687ba03fa' -Arguments @{ notificationCfgPath = "${NotificationCfgPath}"; message = "$($_.Exception.Message)" }) -FullPath $NotificationCfgPath
    }
    if ($notifCfgReadable -and -not $resend) {
        Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_8d79f90037a3385d' -Arguments @{ notificationCfgPath = "${NotificationCfgPath}" })
    }
}

if ($resend) {
    if (Test-IsSet $resend.apiKey) {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_525e3b2708c8c8c4')
        if (-not "$($resend.apiKey)".StartsWith("re_")) {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_88f8f80282f86157')
        }
    } else {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_aef2f9a13448261f' -Arguments @{ notificationCfgPath = "${NotificationCfgPath}" }) -FullPath $NotificationCfgPath
    }

    if (Test-IsSet $resend.fromEmail) {
        Write-Pass "transports.resend.fromEmail = '$($resend.fromEmail)'"
    } else {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_139103d928215a34' -Arguments @{ notificationCfgPath = "${NotificationCfgPath}" }) -FullPath $NotificationCfgPath
    }
}

# Abort if any FAIL was recorded before network checks. Use
# Exit-WithSummary so the FAILURES block is printed at the bottom of
# the transcript -- this is the most common exit path, hit when a
# config-file or schema check failed early.
if ((Get-OutputState).FailCount -gt 0) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_aca819dc2a9378d9')
    Exit-WithSummary -Code 1
}

# --- REGION: Section 11: Resend API connectivity
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_61a4fe98fbdf2430')

if (-not $resend) {
    # Nothing on this host uses api.resend.com until transports.resend exists,
    # so reachability proves nothing -- and an unreachable endpoint must not be
    # able to stop the gate over a transport that is not in use.
    Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_371f960ea43e6a08')
} else {
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses("api.resend.com")
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_d2796cb83cb35520' -Arguments @{ iPAddressToString = "$($resolved[0].IPAddressToString)" })
    } catch {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_597562df237744b4' -Arguments @{ value = "$_" })
        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_01c558aec8401b3a')
        Exit-WithSummary 1
    }

    try {
        if (Test-TcpReachable -HostName "api.resend.com" -Port 443 -TimeoutMs 5000) {
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_fe959a3beaa79700')
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_273c68c1f3b3ad2b')
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_772f1c43a8c05088')
        }
    } catch {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_4de0fab94997dc0d' -Arguments @{ value = "$_" })
    }
}

# --- REGION: Section 12: Live smoke notification
Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_ed29092b14c4dbed')

if ($SkipSend) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_75594d9ffdb15fa0')
} elseif ((Get-OutputState).FailCount -gt 0) {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_f0a38f34d7f17a3a')
} else {
    $notifyMod  = Join-Path $ModulesDir "Test.Notify.psm1"
    if (-not (Test-Path $notifyMod)) {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_7ed5d4468308e1fd' -Arguments @{ notifyMod = "$notifyMod" })
    } else {
        Import-Module -Name $notifyMod -Force

        $message = (Format-YurunaOperatorMessage -Key 'runner.operator_92b9603e0796d4fe')
        $note    = @"
This is a smoke notification fired by Test-Config.ps1 against the
'config.smoke' event code. If you received it, the active notification
extensions and their transports are wired correctly.

Add subscribers under subscribers.config.smoke in
test/status/extension/notification/transports.yml to receive these.
With no subscribers, this run is a verbose no-op (which is fine).

Sent: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)) UTC
"@

        Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_6c8b0e098ab8cc27')
        try {
            Send-YurunaNotification -EventCode 'config.smoke' -EventMessage $message -EventNote $note
            Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_a551655b57821d09')
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_7e6ec0ebf7eb79ee')
        } catch {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_1d07d8486807df5b' -Arguments @{ value = "$_" })
            Write-Info (Format-YurunaOperatorMessage -Key 'runner.operator_0e8ca595acd6197f')
        }
    }
}

# --- REGION: Section 13: Bootstrap script encoding (ASCII, no BOM)
# See https://yuruna.link/42010605-0002

Write-Section (Format-YurunaOperatorMessage -Key 'runner.operator_2d5e1292ca5d9fc6')

$asciiGate = Join-Path $RepoRoot "tools/Test-AsciiNoBom.ps1"
if (-not (Test-Path -LiteralPath $asciiGate)) {
    Write-Info "Test-AsciiNoBom.ps1 not found at ${asciiGate}; encoding gate skipped."
} else {
    $asciiPwsh = Get-PwshExePath
    # See https://yuruna.link/42010605-0002
    $asciiOut  = & $asciiPwsh -NoProfile -ExecutionPolicy Bypass -File $asciiGate -Quiet -Bootstrap 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_0ee5a858a1d212de')
    } else {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_9211a1599fcfa2a7') -FullPath $asciiGate
        foreach ($asciiLine in $asciiOut) { Write-Info ([string]$asciiLine) }
    }
}

# --- REGION: Summary
# See https://yuruna.link/42010605-0002

Exit-WithSummary -Code ((Get-OutputState).FailCount -gt 0 ? 1 : 0)

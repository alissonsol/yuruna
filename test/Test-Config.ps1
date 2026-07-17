<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456709
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
    [switch]$ApplyConfigMigration
)

$TestRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test.config.yml" }
$TemplatePath         = Join-Path $TestRoot "test.config.yml.template"
$ExtensionRoot        = Join-Path $TestRoot "extension"
$ExtensionStateRoot   = Join-Path -Path $TestRoot -ChildPath "status" -AdditionalChildPath "extension"
$SchemasRoot          = Join-Path $TestRoot "schemas"
$NotificationCfgPath  = Join-Path $ExtensionStateRoot "notification/transports.yml"
$NotificationTmplPath = Join-Path $ExtensionRoot      "notification/transports.yml.template"

# -- helpers ------------------------------------------------------------------
# Write-Pass / Write-Fail / Write-Warn / Write-Info / Write-Section /
# Write-Summary / Exit-WithSummary are exported by Test.Output.psm1.
# Test-IsSet / Test-AgainstSchema / Test-RepoFreshness are exported by
# Test.ConfigValidator.psm1. Both modules share a $global: counters
# anchor so every Write-Fail / Write-Pass from either module lands in
# the same end-of-run summary.
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
Initialize-OutputState

function Test-TcpReachable {
    <#
    .SYNOPSIS
        Bounded TCP reachability probe that always disposes its socket.
    .DESCRIPTION
        BeginConnect + a WaitOne timeout so a black-holed host fails in TimeoutMs
        instead of the OS default. Returns $true on connect, $false on timeout or a
        refused connection. The TcpClient is disposed in a finally so no path -- a
        timeout, a refused connection, or a throw -- leaks the socket handle for the
        life of this long-running validator process. The two near-identical GitHub and
        Resend probes differ only in host name, so both route through here.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 443,
        [int]$TimeoutMs = 5000
    )
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            return $true
        }
        return $false
    } finally {
        $tcp.Dispose()
    }
}

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

# -- Section 1: Config file ----------------------------------------------------

Write-Section "Config file"

if (-not (Test-Path $ConfigPath)) {
    if (Test-Path $TemplatePath) {
        try {
            Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
            Write-Pass "Config file bootstrapped from template: $TemplatePath -> $ConfigPath"
            Write-Info "Defaults applied. Edit $ConfigPath later to customize notification, repositories, etc."
        } catch {
            Write-Fail "Config file not found and template copy failed ($TemplatePath -> ${ConfigPath}): $($_.Exception.Message)" -FullPath $ConfigPath
            Exit-WithSummary 1
        }
    } else {
        Write-Fail "Config file not found: $ConfigPath" -FullPath $ConfigPath
        Write-Info "Template not found either ($TemplatePath). Check your repository."
        Exit-WithSummary 1
    }
} else {
    Write-Pass "Config file found: $ConfigPath"
}

# -- Section 2: YAML parsing ---------------------------------------------------

Write-Section "YAML structure"

try {
    $Config = Read-TestConfig -Path $ConfigPath -ThrowOnError
    Write-Pass "YAML is valid and parsed successfully."
} catch {
    Write-Fail "YAML parse error in ${ConfigPath}: $_" -FullPath $ConfigPath
    Write-Info "Open test.config.yml and fix the syntax error above."
    Exit-WithSummary 1
}

# -- Section 2b: Config schema vs template ------------------------------------
# The template is the schema source of truth. By default this validator fully
# reconciles the live test.config.yml to it (Sync-TestConfigToTemplate in
# Test.ConfigSync.psm1):
#   * every template field the file lacks is added with its empty/default value
#   * every key the template no longer defines (e.g. a renamed section's old keys)
#     is REMOVED -- and when the removed key carried a value the previous file is
#     first backed up to test.config.yml.backup so it is always recoverable
#   * the file is rewritten with every map key AND scalar-array element in
#     alphabetical order, so it is byte-stable and diff-friendly
# Operator values for keys that still map are kept; the out-of-band 'secrets' node
# is preserved untouched. Outcomes:
#   * already canonical, shape matches        -> PASS (no rewrite)
#   * fields added / re-sorted                -> PASS, listing any new fields to fill in
#   * populated keys dropped from the schema  -> WARN or FAIL per -OnConfigSchemaDrift
#                                                (recover from the .backup if needed)
# Separately, at cycle start the runner does the same reconciliation via
# Update-TestConfigFromTemplate (the path Invoke-TestRunner uses), which also STOPS
# the run if a populated value no longer maps. -ApplyConfigMigration runs that
# stop-on-unmappable reconciliation now instead of the validator's report-only one.

Write-Section "Config schema vs template"

$configSyncMod = Join-Path $script:ModulesDir 'Test.ConfigSync.psm1'
if (-not (Test-Path $TemplatePath)) {
    Write-Warn "Template not found ($TemplatePath) -- cannot compare schema; the runner will load test.config.yml as-is."
} elseif (-not (Test-Path $configSyncMod)) {
    Write-Info "Test.ConfigSync.psm1 not found at ${configSyncMod}; schema-vs-template check skipped."
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
            Write-Info "Applying config migration (backup -> template -> carry matching values forward)..."
            $Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
            Write-Pass "Config migrated to the template schema; previous file backed up to $backupPath. Re-run Test-Config to validate the migrated file."
        } else {
            # Default: reconcile the file to the template -- add missing fields,
            # drop keys the template no longer defines (backing up first when a
            # populated key is dropped), and rewrite in canonical alphabetical
            # order. Operator values that still map are kept; 'secrets' untouched.
            $res = Sync-TestConfigToTemplate -Template $templateDoc -Current $Config -ConfigPath $ConfigPath
            $Config = $res.Config

            if ($res.Wrote) {
                $summary = [System.Collections.Generic.List[string]]::new()
                if ($res.Added.Count   -gt 0) { [void]$summary.Add("added $($res.Added.Count) missing field(s)") }
                if ($res.Removed.Count -gt 0) { [void]$summary.Add("removed $($res.Removed.Count) key(s) not in the schema") }
                [void]$summary.Add("sorted to alphabetical order")
                Write-Pass "test.config.yml reconciled to the template: $($summary -join '; ')."
                if ($res.Added.Count -gt 0) {
                    $addedList = ($res.Added | ForEach-Object { "          - $_" }) -join "`n"
                    Write-Info "New fields written with empty/default values -- fill these in:`n$addedList"
                }
            } elseif ($shapeMatches) {
                Write-Pass "test.config.yml matches the template's nested schema."
            } else {
                Write-Info "test.config.yml already carries every current-schema field in canonical order; nothing to change."
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
        Write-Fail "Schema-vs-template comparison failed: $($_.Exception.Message)" -FullPath $ConfigPath
    }
}

# -- Section 3: Host requirements (quick) -------------------------------------
# Imports Test.HostContract.psm1 and runs the same fast pre-flight that
# operator-facing helpers (Remove-TestVMFiles.ps1, ...) call: detects
# the host type and verifies the absolute minimum (Administrator +
# vmms on Hyper-V, virsh + /dev/kvm on Ubuntu, UTM.app + utmctl on
# macOS). The pointer Write-Information inside Test-HostRequirement
# is suppressed here because THIS script IS the deeper check it would
# otherwise advertise.

Write-Section "Host requirements (quick)"

$ModulesDir  = Join-Path $TestRoot "modules"
$hostModPath = Join-Path $ModulesDir "Test.HostContract.psm1"
$HostType    = $null
if (-not (Test-Path $hostModPath)) {
    Write-Fail "Test.HostContract.psm1 not found at: $hostModPath"
} else {
    Import-Module -Name $hostModPath -Force -Global
    $HostType = Get-HostType
    if (-not $HostType) {
        Write-Fail "Could not detect host type (unsupported platform)."
    } else {
        # Auto-relaunch under sg libvirt on host.ubuntu.kvm when this
        # shell's group set is stale. Most of Test-Config's later probes
        # (libvirt VM listing, host-feature checks) need libvirt-socket
        # access. No-op on other hosts / fresh shells.
        Invoke-LibvirtGroupReExecIfNeeded -HostType $HostType -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
        Write-Pass "Host type detected: $HostType"
        # Capture Test-HostRequirement's Write-Warning lines via -WarningVariable
        # and re-emit them through Write-Warn so they land under the current
        # section in Test.Output's state. Without this, those warnings reach
        # the host's Warning stream directly and never make it into the
        # FAILURES-summary block, leaving the operator with a bare "see
        # warnings above" pointer at content that has scrolled off.
        $reqWarns = $null
        $reqOk = Test-HostRequirement -HostType $HostType -InformationAction SilentlyContinue -WarningAction SilentlyContinue -WarningVariable reqWarns
        foreach ($w in $reqWarns) { Write-Warn "$w" }
        if ($reqOk) {
            Write-Pass "Host requirements quick check passed."
        } else {
            Write-Fail "Host requirements quick check failed -- see the [WARN] line(s) in this section."
        }
    }
}

# -- Section 4: Host capacity -------------------------------------------------
# RAM + CPU. Below the per-platform threshold = WARN (the harness still
# runs but risks OOM kills inside guests / slow OCR). The 16 GiB and
# 4-core thresholds match the "three concurrent 2-vCPU/4 GiB guests + an
# OCR worker on the host" calibration the cycle is sized for.

Write-Section "Host capacity"

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
            Write-Warn "RAM = ${ramGiB} GiB -- below 16 GiB calibration; consider running fewer guests in parallel."
        } else {
            Write-Pass "RAM = ${ramGiB} GiB."
        }
    }
    if ($null -ne $logicalCpu -and $logicalCpu -gt 0) {
        if ($logicalCpu -lt 4) {
            Write-Warn "Logical CPUs = $logicalCpu -- below 4-core calibration; cycles will be slow."
        } else {
            Write-Pass "Logical CPUs = $logicalCpu ($cpuModel)."
        }
    }
} catch {
    Write-Warn "Could not read host capacity: $($_.Exception.Message)"
}

# -- Section 5: Host-specific feature state -----------------------------------
# Deeper, host-type-specific verification beyond the "command/service
# exists" gate in Test-HostRequirement: Hyper-V feature state (DISM)
# on Windows, libvirtd active + qemu installed on Linux, UTM helper
# installed on macOS. Catches "Hyper-V is half-enabled, reboot pending"
# (memory: dism_enable_pending_trap) before a cycle hits it.

Write-Section "Host-specific feature state"

switch ($HostType) {
    'host.windows.hyper-v' {
        try {
            $featureLine = & dism.exe /online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1 |
                Select-String -Pattern '^\s*State\s*:\s*(.+)$' |
                Select-Object -First 1
            if ($featureLine) {
                $state = $featureLine.Matches[0].Groups[1].Value.Trim()
                if ($state -eq 'Enabled') {
                    Write-Pass "Microsoft-Hyper-V-All feature state = Enabled."
                } else {
                    Write-Fail "Microsoft-Hyper-V-All feature state = $state. Enable from elevated PowerShell: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All  (then reboot)."
                }
            } else {
                Write-Warn "DISM did not return a Hyper-V feature state (DISM.exe needs Administrator to query feature state; the Section 3 quick check above will already have flagged elevation if that's the cause)."
            }
        } catch {
            Write-Warn "DISM Hyper-V feature query failed: $($_.Exception.Message)"
        }
        $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if ($vmms -and $vmms.Status -eq 'Running') {
            Write-Pass "Hyper-V vmms service: Running."
        } else {
            $vmmsState = if ($vmms) { "$($vmms.Status)" } else { 'not installed' }
            Write-Fail "Hyper-V vmms service: $vmmsState."
        }
    }
    'host.ubuntu.kvm' {
        if (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue) {
            Write-Pass "qemu-system-x86_64 found on PATH."
        } else {
            Write-Fail "qemu-system-x86_64 not found. Install with: sudo apt install qemu-kvm"
        }
        $libvirtd = (& systemctl is-active libvirtd 2>$null)
        if ("$libvirtd".Trim() -eq 'active') {
            Write-Pass "libvirtd: active."
        } else {
            Write-Fail "libvirtd: $libvirtd. Start with: sudo systemctl start libvirtd"
        }
        if (Test-Path '/dev/kvm') {
            Write-Pass "/dev/kvm present."
        } else {
            Write-Fail "/dev/kvm missing. Enable VT-x/SVM in firmware and load the kvm module."
        }
    }
    'host.macos.utm' {
        if (Test-Path '/Applications/UTM.app') {
            Write-Pass "UTM.app installed."
        } else {
            Write-Fail "UTM.app missing -- install from https://mac.getutm.app"
        }
        if (Get-Command utmctl -ErrorAction SilentlyContinue) {
            Write-Pass "utmctl reachable on PATH."
        } else {
            Write-Fail "utmctl missing on PATH -- symlink from /Applications/UTM.app/Contents/MacOS/utmctl"
        }
    }
}

# -- Section 6: Framework / project staleness ---------------------------------
# git fetch + compare HEAD to upstream. WARN (not FAIL) when the local
# clone is behind: the harness can still run, but its runner / index.html
# is older than what landed on main. Repeat for the project clone when
# one exists under <RepoRoot>/project/ (Update-ProjectClone path).

Write-Section "Framework / project staleness"

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
    # No .git -- could be the in-tree project layout (files committed to
    # the framework repo) OR the post-failure empty-dir state where
    # Update-ProjectClone wiped the previous clone and then `git clone`
    # failed, leaving an empty target dir. Status-server then 404s
    # /yuruna-project-archive.tar.gz and guests fall through to their
    # own (also-broken) clone -- which is the cascade the operator hit.
    $entries = (Get-ChildItem -LiteralPath $projectClone -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($entries -eq 0) {
        $hint = if (Test-IsSet $projectUrlConfigured) {
            "Last cycle's Update-ProjectClone removed the previous clone and then 'git clone $projectUrlConfigured' failed, leaving an empty target dir. Status server will 404 /yuruna-project-archive.tar.gz and guests will fall through to their own clone of the same URL. Delete this folder and fix repositories.projectUrl before rerunning."
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
            Write-Fail "projectUrl='$projectUrlConfigured' is not a parseable file:// URL." -FullPath $ConfigPath
        } elseif (-not (Test-Path -LiteralPath $localPath)) {
            Write-Fail "projectUrl='$projectUrlConfigured' points to '$localPath' which does not exist on this host. Fix repositories.projectUrl in test.config.yml." -FullPath $ConfigPath
        } elseif (-not (Test-Path -LiteralPath (Join-Path $localPath '.git'))) {
            Write-Fail "projectUrl='$projectUrlConfigured' resolves to '$localPath' which exists but has no .git -- 'git clone' will fail with 'does not appear to be a git repository'." -FullPath $localPath
        } else {
            Write-Pass "projectUrl resolves to local git repo: $localPath"
        }
        Write-Warn "projectUrl is a file:// URL -- only the host can resolve it. Guests that hit the tarball-fallback path (status server 404 on /yuruna-project-archive.tar.gz) will attempt 'git clone $projectUrlConfigured' on their OWN Linux filesystem and fail. Use an HTTPS/SSH URL guests can reach if you rely on the guest fallback."
    } elseif ($projectUrlConfigured -match '^(?i)(https?|ssh|git)://') {
        # Cheap, no-fetch reachability probe routed through the shared network-git
        # helper: it is prompt-proof (a private/missing repo exits non-zero instead
        # of blocking on a Git Credential Manager dialog) AND authenticates with
        # GH_TOKEN when set, which plain git does not do on its own -- so a private
        # projectUrl reachable only via the token no longer reports as unreachable.
        try {
            $ls  = Invoke-GitNetworkCommand -GitArgs @('ls-remote', '--exit-code', '--quiet', $projectUrlConfigured, 'HEAD') -TimeoutSeconds 30
            if ($ls.ExitCode -eq 0) {
                Write-Pass "projectUrl reachable (git ls-remote HEAD exit 0): $projectUrlConfigured"
            } else {
                Write-Fail "projectUrl='$projectUrlConfigured' is not reachable (git ls-remote exit $($ls.ExitCode)). Common causes: typo, private repo without cached credentials, or repo doesn't exist. ls-remote output: $($ls.Output)" -FullPath $ConfigPath
            }
        } catch {
            Write-Fail "projectUrl='$projectUrlConfigured': ls-remote threw -- $($_.Exception.Message)" -FullPath $ConfigPath
        }
    } else {
        # No scheme -- accept a bare local path (rare, but git clone
        # treats it identically to file://). Same host-only caveat.
        if (Test-Path -LiteralPath $projectUrlConfigured) {
            if (Test-Path -LiteralPath (Join-Path $projectUrlConfigured '.git')) {
                Write-Pass "projectUrl resolves to local git repo (no scheme): $projectUrlConfigured"
            } else {
                Write-Fail "projectUrl='$projectUrlConfigured' exists but has no .git." -FullPath $projectUrlConfigured
            }
            Write-Warn "projectUrl is a local path -- guests cannot resolve it on their own filesystem. Use an HTTPS/SSH URL if guests need the fallback clone path."
        } else {
            Write-Fail "projectUrl='$projectUrlConfigured' has no recognized scheme (http/https/ssh/git/file) and isn't a local path. Update-ProjectClone will fail at cycle start." -FullPath $ConfigPath
        }
    }
}

# -- Section 7: GitHub connectivity -------------------------------------------
# DNS + TCP probes of github.com:443. Surfaces a bad network state HERE
# rather than later when Invoke-GitPull retries inside a running cycle.

Write-Section "GitHub connectivity"

try {
    $resolved = [System.Net.Dns]::GetHostAddresses("github.com")
    Write-Pass "DNS resolved 'github.com' -> $($resolved[0].IPAddressToString)"
    try {
        if (Test-TcpReachable -HostName "github.com" -Port 443 -TimeoutMs 5000) {
            Write-Pass "TCP connection to github.com:443 succeeded."
        } else {
            Write-Fail "TCP connection to github.com:443 timed out -- check firewall / VPN / captive portal."
        }
    } catch {
        Write-Fail "TCP connection to github.com:443 failed: $($_.Exception.Message)"
    }
} catch {
    Write-Fail "DNS resolution failed for 'github.com': $($_.Exception.Message)"
}

# -- Section 8: Top-level fields -----------------------------------------------

Write-Section "Top-level settings"

if ($Config.Contains("notification")) {
    Write-Pass "'notification' block is present."
} else {
    Write-Fail "'notification' block is missing."
}

if ($Config.vmImage -is [System.Collections.IDictionary] -and $Config.vmImage.Contains("alwaysRedownload")) {
    Write-Pass "'vmImage.alwaysRedownload' = $($Config.vmImage.alwaysRedownload)"
} else {
    Write-Warn "'vmImage.alwaysRedownload' not set -- defaults to false."
}

if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains("testVmNamePrefix")) {
    Write-Pass "'vmStart.testVmNamePrefix' = '$($Config.vmStart.testVmNamePrefix)'"
} else {
    Write-Warn "'vmStart.testVmNamePrefix' not set -- defaults to 'test-'."
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("recentDisplayCount")) {
    $rdc = [int]$Config.testCycle.recentDisplayCount
    if ($rdc -gt 0) { Write-Pass "'testCycle.recentDisplayCount' = $rdc" }
    else            { Write-Warn "'testCycle.recentDisplayCount' is $rdc -- should be a positive integer." }
} else {
    Write-Warn "'testCycle.recentDisplayCount' not set -- defaults to 30."
}

if ($Config.Contains("statusService")) {
    $ss = $Config.statusService
    Write-Pass "'statusService' block present (isEnabled=$($ss.isEnabled), port=$($ss.port))."
} else {
    Write-Warn "'statusService' not set -- status HTTP server will be disabled."
}

if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains("frameworkUrl")) {
    Write-Pass "'repositories.frameworkUrl' = '$($Config.repositories.frameworkUrl)'"
} else {
    Write-Warn "'repositories.frameworkUrl' not set -- status page commit links may not work, and the failure-pause break-out trigger that watches the framework repo will be a no-op."
}

# Deeper validation (URL reachability, <RepoRoot>/project/ state) lives in
# Section 6; here we only flag presence so the top-level summary matches
# frameworkUrl's treatment.
if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains("projectUrl")) {
    $projectUrlVal = [string]$Config.repositories.projectUrl
    if (Test-IsSet $projectUrlVal) {
        Write-Pass "'repositories.projectUrl' = '$projectUrlVal'"
    } else {
        Write-Warn "'repositories.projectUrl' is empty -- in-tree <RepoRoot>/project/ will be used (no clone)."
    }
} else {
    Write-Warn "'repositories.projectUrl' not set -- in-tree <RepoRoot>/project/ will be used (no clone)."
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("shouldStopOnFailure")) {
    Write-Pass "'testCycle.shouldStopOnFailure' = $($Config.testCycle.shouldStopOnFailure)"
} else {
    Write-Warn "'testCycle.shouldStopOnFailure' not set -- defaults to false (continues on failure)."
}

# Abort here if notification block is missing; nothing more to check.
if (-not $Config.Contains("notification")) { Exit-WithSummary 1 }

$notif = $Config.notification

# Soft migration: surface legacy keys that have moved to status/extension/notification/transports.yml.
if ($notif.Contains('toEmailAddress') -and (Test-IsSet $notif.toEmailAddress)) {
    Write-Warn "notification.toEmailAddress is set in test.config.yml -- this key has moved to test/status/extension/notification/transports.yml (subscribers list). Move it manually before the next cycle."
}
if ($Config.Contains('secrets') -and $Config.secrets -is [System.Collections.IDictionary] -and $Config.secrets.Contains('resend')) {
    Write-Warn "secrets.resend is set in test.config.yml -- this block has moved to test/status/extension/notification/transports.yml (transports.resend). Move it manually before the next cycle."
}

# -- Section 9: Extension configs ---------------------------------------------

Write-Section "Extension configs"

Test-AgainstSchema -Label "authentication/authentication.config.yml" `
    -YamlPath   (Join-Path $ExtensionRoot "authentication/authentication.config.yml") `
    -SchemaPath (Join-Path $SchemasRoot   "extension-config.schema.yml")

Test-AgainstSchema -Label "notification/notification.config.yml" `
    -YamlPath   (Join-Path $ExtensionRoot "notification/notification.config.yml") `
    -SchemaPath (Join-Path $SchemasRoot   "extension-config.schema.yml")

if (-not (Test-Path $NotificationCfgPath)) {
    if (Test-Path $NotificationTmplPath) {
        Write-Warn "status/extension/notification/transports.yml missing -- copy from transports.yml.template and populate before the next cycle: $NotificationTmplPath -> $NotificationCfgPath"
    } else {
        Write-Fail "status/extension/notification/transports.yml missing and no template found at $NotificationTmplPath" -FullPath $NotificationCfgPath
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
    Write-Info "vault.yml not present (expected; created on cycle start)."
}

# -- Section 9b: Authentication users mapping (users.yml) --------------------
#
# users.yml maps logical (sequence-level) usernames onto corporate
# identities (AD/Entra/...) plus the vault keys that hold the
# corresponding passwords. Bootstrap-from-template runs on first cycle,
# so a fresh checkout has a runtime file pre-seeded with the four
# bundled logical users + the cache-VM 'yuruna' user, all with empty
# corporate fields (today's local-only behavior).
#
# Strict-mode (default) blocks the cycle when an active sequence
# references a logical username that's missing from users.yml, when
# corporate fields are half-populated (sam set without domain etc.),
# or when a populated vaultKey doesn't exist in vault.yml. The dev
# path therefore exercises the production AD-join path every cycle.

Write-Section "Authentication users mapping (users.yml)"

$UsersTemplate = Join-Path $ExtensionRoot      "authentication/users.yml.template"
$UsersPath     = Join-Path $ExtensionStateRoot "authentication/users.yml"
$UsersSchema   = Join-Path $SchemasRoot        "users.schema.yml"

if (-not (Test-Path $UsersPath)) {
    if (Test-Path $UsersTemplate) {
        Write-Warn "status/extension/authentication/users.yml missing -- will be bootstrapped from template on first cycle. To customize corporate mappings ahead of that, copy: $UsersTemplate -> $UsersPath"
    } else {
        Write-Fail "status/extension/authentication/users.yml AND its template are both missing. Restore $UsersTemplate from the repository." -FullPath $UsersTemplate
    }
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
        Write-Fail "users.yml parse error in ${UsersPath}: $($_.Exception.Message)" -FullPath $UsersPath
    }

    if ($usersDoc) {
        $strict   = $true
        if ($usersDoc.Contains('strict')) { $strict = ConvertTo-YurunaBool $usersDoc['strict'] }
        $declared = [ordered]@{}
        if ($usersDoc.Contains('users') -and $usersDoc['users'] -is [System.Collections.IDictionary]) {
            foreach ($k in $usersDoc['users'].Keys) { $declared[$k] = $usersDoc['users'][$k] }
        }
        Write-Pass ("users.yml: strict=$strict, $($declared.Keys.Count) logical user(s) declared.")

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
                    Write-Warn "users.yml[$logical]: corporate.sam='$s' is set but corporate.domain is empty and corporate.upn is empty. Provide one of (sam + domain) or (upn) -- bare 'sam' won't render a usable loginUser."
                }
                if ($d -and -not $s) {
                    Write-Fail "users.yml[$logical]: corporate.domain='$d' is set but corporate.sam is empty. Provide both or neither." -FullPath $UsersPath
                }
                if ($u -and ($u -notmatch '@')) {
                    Write-Warn "users.yml[$logical]: corporate.upn='$u' doesn't contain '@'. UPNs are typically of the form 'user@domain.example'."
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
                    Write-Fail "users.yml[$logical]: vaultKey='$vk' has no matching entry in vault.yml ($VaultPath). The vault NEVER auto-generates for an operator-supplied key. Add the corporate password manually: vault.yml -> users.$vk.password." -FullPath $VaultPath
                } else {
                    Write-Warn "users.yml[$logical]: vaultKey='$vk' has no entry in vault.yml (lenient mode). Cycle will throw at the first Get-Password call against '$logical'."
                }
            } else {
                $pwEntry = $vaultUsers[$vk]
                if ($pwEntry -isnot [System.Collections.IDictionary] -or -not "$($pwEntry['password'])".Trim()) {
                    Write-Fail "users.yml[$logical]: vaultKey='$vk' resolves but its 'password' is empty in ${VaultPath}." -FullPath $VaultPath
                } else {
                    Write-Pass "users.yml[$logical]: vaultKey='$vk' resolves -> vault entry present."
                }
            }
        }

        # Strict-mode completeness: every logical username referenced
        # by an active sequence must be declared. Scan framework
        # sequences under test/sequences/ AND project-tree sequences
        # under <repoRoot>/project/**/test/{gui,ssh}/. The project layout
        # is `project/<category>/<name>/test/<mode>/*.yml` (e.g.
        # `project/example/website/test/gui/...`) -- the same shape
        # Get-ProjectTestSearchDir walks at runtime, replicated here so
        # Test-Config stays standalone and doesn't have to import the
        # sequence engine module.
        if ($strict) {
            $RepoRoot = Split-Path -Parent $TestRoot
            $sequencesDirs = New-Object System.Collections.Generic.List[string]
            [void]$sequencesDirs.Add((Join-Path $TestRoot 'sequences'))
            # Project tree: every directory whose name is 'gui' or 'ssh'
            # AND whose immediate parent is 'test', anywhere under
            # <repo>/project/. Matches the runtime resolver exactly.
            $projectRoot = Join-Path $RepoRoot 'project'
            if (Test-Path -LiteralPath $projectRoot) {
                Get-ChildItem -LiteralPath $projectRoot -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object {
                        ($_.Name -eq 'gui' -or $_.Name -eq 'ssh') -and
                        ((Split-Path -Leaf (Split-Path -Parent $_.FullName)) -eq 'test')
                    } |
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
                Write-Fail ("users.yml strict mode: the following logical username(s) are referenced by sequence files but not declared in users.yml ($UsersPath): $details. Add each as a users.yml entry (copy an existing one and adjust localOsUser/corporate fields), or set 'strict: false' in users.yml to skip this check (lenient mode).") -FullPath $UsersPath
            } else {
                $scannedDirs = ($sequencesDirs | ForEach-Object { $_ }) -join ', '
                Write-Pass "users.yml strict mode: every sequence-referenced logical username is declared (scanned: $scannedDirs)."
            }
        }
    }
}

# -- Section 9b2: Sequence files (parse + snippet expansion) ------------------
# Read every sequence in the framework AND the default test project through the
# same loader the runner uses (Read-SequenceFile, which splices `snippet:`
# references from the _snippets.yml libraries). A YAML error, an unknown or
# duplicate snippet name, or a snippet cycle FAILs the gate here -- before a
# cycle starts -- instead of dropping steps or aborting mid-guest. Snippet
# libraries are also shape-checked directly so a broken-but-unreferenced library
# doesn't hide until first use.

Write-Section "Sequence files (parse + snippets)"

$seqResolveMod = Join-Path $ModulesDir 'Test.SequenceResolve.psm1'
if (-not (Test-Path $seqResolveMod)) {
    Write-Info "Test.SequenceResolve.psm1 not found at ${seqResolveMod}; sequence check skipped."
} else {
    Import-Module $seqResolveMod -Global -Force
    $RepoRoot = Split-Path -Parent $TestRoot
    # Same dir set the runtime resolver walks: framework test/sequences/{gui,ssh}
    # plus every project <...>/test/{gui,ssh} (matches Get-ProjectTestSearchDir).
    $seqDirs = New-Object System.Collections.Generic.List[string]
    foreach ($m in @('gui', 'ssh')) { [void]$seqDirs.Add((Join-Path (Join-Path $TestRoot 'sequences') $m)) }
    $projectRoot = Join-Path $RepoRoot 'project'
    if (Test-Path -LiteralPath $projectRoot) {
        Get-ChildItem -LiteralPath $projectRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -eq 'gui' -or $_.Name -eq 'ssh') -and
                ((Split-Path -Leaf (Split-Path -Parent $_.FullName)) -eq 'test')
            } |
            ForEach-Object { [void]$seqDirs.Add($_.FullName) }
    }

    $seqOk = 0
    $seqDirsScanned = 0
    foreach ($sd in $seqDirs) {
        if (-not (Test-Path -LiteralPath $sd)) { continue }
        $seqDirsScanned++
        Get-ChildItem -LiteralPath $sd -File -Filter '*.yml' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '_snippets.yml' } |
            ForEach-Object {
                try {
                    $null = Read-SequenceFile -Path $_.FullName -NoCache
                    $seqOk++
                } catch {
                    Write-Fail "Sequence '$($_.Name)' failed to load: $($_.Exception.Message)" -FullPath $_.FullName
                }
            }
        # Shape-check the snippet library in this dir even when no sequence
        # references it yet (a broken library otherwise stays invisible).
        $libPath = Join-Path $sd '_snippets.yml'
        if (Test-Path -LiteralPath $libPath) {
            try {
                $lib = Read-TestConfig -Path $libPath -ThrowOnError
                if ($lib -isnot [System.Collections.IDictionary] -or $lib.Keys.Count -eq 0) {
                    Write-Fail "_snippets.yml is not a non-empty map of snippet name -> steps." -FullPath $libPath
                } else {
                    $libBad = $false
                    foreach ($snipName in $lib.Keys) {
                        $val = $lib[$snipName]
                        if ($val -isnot [System.Collections.IEnumerable] -or $val -is [string] -or @($val).Count -eq 0) {
                            Write-Fail "_snippets.yml snippet '$snipName' is not a non-empty list of steps." -FullPath $libPath
                            $libBad = $true
                        }
                    }
                    if (-not $libBad) { Write-Pass "_snippets.yml: $($lib.Keys.Count) snippet(s) in $sd." }
                }
            } catch {
                Write-Fail "_snippets.yml parse error: $($_.Exception.Message)" -FullPath $libPath
            }
        }
    }
    if ($seqDirsScanned -eq 0) {
        Write-Warn "No sequence directories found under $TestRoot/sequences or the project tree."
    } else {
        Write-Pass "Sequence files loaded + snippet-expanded OK: $seqOk file(s) across $seqDirsScanned dir(s)."
    }
}

# -- Section 9b3: stale SMB alias mappings (Windows) --------------------------
# A persistent Windows drive mapping can outlive the hosts-file alias it points
# at: after a NAS alias is renamed/removed, the mapping still shows Status OK from
# its cached connection, yet the dead-name session it holds BLOCKS a fresh mount
# of the same physical NAS under a current alias (the redirector refuses a second
# credentialed session to a server it is already stale-connected to). Mapping two
# aliases of ONE NAS to the SAME IP is intentional and fine -- an UNRESOLVABLE
# alias is the actual blocker. List them and, only with an operator at the
# keyboard, offer to unmount each so the pool/stash mounts below are not
# pre-empted. Headless runs never prompt: advisory WARN + the one-line manual fix.
if ($IsWindows) {
    $smbMod = Join-Path $ModulesDir 'Test.PoolStorage.psm1'
    if (Test-Path $smbMod) {
        Import-Module $smbMod -Global -Force
        Write-Section "networkStorage: stale SMB alias mappings"
        $stale = @(Get-PoolStorageStaleAliasMount)
        if ($stale.Count -eq 0) {
            Write-Pass "no stale SMB drive mappings (every mapped server name still resolves)."
        } else {
            $smbInteractive = $false
            try { $smbInteractive = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { $smbInteractive = $false }
            foreach ($s in $stale) {
                $label = if ($s.LocalPath) { "$($s.LocalPath) -> $($s.RemotePath)" } else { $s.RemotePath }
                $removed = $false
                if ($smbInteractive) {
                    $ans = Read-Host "Stale SMB mapping '$label' (server '$($s.ServerName)' no longer resolves) can block NAS mounts. Unmount it now? [y/N]"
                    if ($ans.Trim() -match '^(y|yes)$') {
                        $removed = Remove-PoolStorageStaleAliasMount -LocalPath $s.LocalPath -RemotePath $s.RemotePath -Confirm:$false
                    }
                }
                if ($removed) {
                    Write-Pass "stale SMB mapping unmounted: $label (server '$($s.ServerName)' unresolvable)."
                } else {
                    $fix = if ($s.LocalPath) { "net use $($s.LocalPath) /delete" } else { "net use `"$($s.RemotePath)`" /delete" }
                    Write-Warn "stale SMB mapping '$label': server '$($s.ServerName)' no longer resolves -- this can block a fresh mount of the same NAS under a current alias. Unmount it: $fix"
                }
            }
        }
    }
}

# Linux-only: print the EXACT one-time passwordless-sudo setup the mount path
# needs (resolved to this account + binary paths) the first time a mount-stage
# pre-flight fails. Once per run -- the pool and stash shares share one drop-in.
# The unattended RUNNER cannot self-apply it (`sudo -n` never prompts and
# /etc/sudoers.d needs root), so this hint is its fallback; an INTERACTIVE
# operator is offered the install directly by Invoke-LinuxSudoInstallOffer.
$script:LinuxSudoHintShown = $false
function Show-LinuxSudoHintOnce {
    if (-not $IsLinux -or $script:LinuxSudoHintShown) { return }
    if (-not (Get-Command Get-PoolStorageLinuxSudoHint -ErrorAction SilentlyContinue)) { return }
    $script:LinuxSudoHintShown = $true
    $acct = ''
    try { $acct = [string](& id -un 2>$null | Select-Object -First 1) } catch { $null = $_ }
    if ([string]::IsNullOrWhiteSpace($acct)) { $acct = [string]$env:USER }
    $resolve = {
        param($cmd, $fallback)
        $src = (Get-Command -CommandType Application -Name $cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if ([string]::IsNullOrWhiteSpace($src)) { $fallback } else { $src }
    }
    $hint = Get-PoolStorageLinuxSudoHint -User ($acct.Trim()) `
        -MkdirPath  (& $resolve 'mkdir'  '/usr/bin/mkdir') `
        -MountPath  (& $resolve 'mount'  '/usr/bin/mount') `
        -UmountPath (& $resolve 'umount' '/usr/bin/umount')
    foreach ($line in $hint) { Write-Info $line }
}

# Linux + interactive only: offer to install the passwordless-sudo drop-in the
# mount needs, right now, prompting once for sudo. Returns $true ONLY when the
# drop-in was actually installed (so the caller retries the mount); a decline, a
# headless session, or any non-install outcome returns $false and the caller
# falls through to Show-LinuxSudoHintOnce. The unattended runner never reaches
# this (not interactive) and must not self-elevate.
function Invoke-LinuxSudoInstallOffer {
    if (-not $IsLinux) { return $false }
    if (-not (Get-Command Set-PoolStorageSudoers -ErrorAction SilentlyContinue)) { return $false }
    $canPrompt = $false
    try { $canPrompt = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { $canPrompt = $false }
    if (-not $canPrompt) { return $false }
    $ans = Read-Host "networkStorage: install the passwordless-sudo drop-in now so the mount works (sudo will prompt once for your password)? [y/N]"
    if ($ans -notmatch '^\s*(y|yes)\s*$') { return $false }
    try {
        $result = Set-PoolStorageSudoers -Confirm:$false
    } catch {
        Write-Info "Interactive sudoers install could not run: $($_.Exception.Message) -- use the manual steps below."
        return $false
    }
    switch ($result.Action) {
        'installed' { Write-Info "Installed $($result.DropInPath). Retrying the mount pre-flight..."; return $true }
        'present'   { Write-Info "Passwordless sudo is already configured -- the mount is failing for another reason (share name / credential); see the details below."; return $false }
        default     { Write-Info "Passwordless-sudo install did not complete ($($result.Action)): $($result.Message)"; return $false }
    }
}

# A bare drive-letter (e.g. 'z:') is a localPath value, never a valid SMB
# username -- finding one in <prefix>NetworkUser means <prefix>NetworkUser and
# <prefix>LocalPath were transposed in test.config.yml. A value swap keeps the
# schema valid (both are strings), so nothing else flags it; the only visible
# symptom is a misleading "no stored vault credential" warning keyed on the
# drive letter, while the real account's password sits unused in the vault.
function Show-NetworkStorageFieldSwapWarning {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('pool', 'stash')][string]$Prefix
    )
    if ([string]::IsNullOrWhiteSpace($Config.NetworkUser)) { return }
    if ($Config.NetworkUser.Trim() -notmatch '^[A-Za-z]:\\?$') { return }
    Write-Warn ("networkStorage {0}: {0}NetworkUser is set to a drive letter ('{1}') -- that's a {0}LocalPath value, not an SMB username. {0}NetworkUser and {0}LocalPath are almost certainly swapped in test.config.yml. See docs/test-config.md." -f $Prefix, $Config.NetworkUser.Trim())
}

# -- Section 9c: networkStorage pool (ypool-nas) replication -----------------------
# Validate the optional NAS replication tier when it's switched on: all three
# paths set, a usable vault credential (so the mount won't silently auto-generate
# a junk SMB password), that the SMB server answers on :445, and -- when both of
# those pass -- an ACTIVE mount of localPath plus creation of the per-host folder
# '<localPath>/<hostId>'. The active step is what proves replication will actually
# work (credentials, share name, Linux sudo, write permission) instead of silently
# failing in the detached drain; with replicate on it FAILs the gate (stopping the
# cycle), and the reachability probe stays a WARN so a merely-offline NAS -- which
# the loop retries each cycle -- never blocks a healthy run.

Write-Section "networkStorage: pool (ypool-nas) replication"

$poolMod = Join-Path $ModulesDir 'Test.PoolStorage.psm1'
if (-not (Test-Path $poolMod)) {
    Write-Info "Test.PoolStorage.psm1 not found at ${poolMod}; networkStorage check skipped."
} else {
    Import-Module $poolMod -Global -Force
    $psRaw = if ($Config.Contains('networkStorage')) { $Config['networkStorage'] } else { $null }
    if ($psRaw -isnot [System.Collections.IDictionary]) {
        Write-Info "networkStorage block not present -- NAS replication is off (optional)."
    } else {
        # networkReplicate is a pool behavior (pool node), not a networkStorage key.
        $psReplicate = $false
        if ($Config.Contains('pool') -and $Config['pool'] -is [System.Collections.IDictionary]) { $psReplicate = ConvertTo-YurunaBool $Config['pool']['networkReplicate'] }
        # Validate the connection parameters REGARDLESS of the replicate flag, so an
        # operator can confirm the share + credential work BEFORE flipping replicate
        # to true. When replicate is on a problem FAILs (it will actually run next
        # cycle); when off it is advisory (WARN) -- the cycle runs fine without it.
        $psCfg = Get-YurunaPoolStorageConfig -Config $Config -IgnoreReplicate -WarningAction SilentlyContinue
        if (-not $psCfg) {
            $incomplete = "networkStorage poolNetworkPath / poolNetworkUser / poolLocalPath are not all set"
            if ($psReplicate) {
                Write-Fail "pool.networkReplicate is true but $incomplete -- replication stays OFF until all three are populated. See docs/test-config.md." -FullPath $ConfigPath
            } else {
                Write-Info "pool.networkReplicate = false and $incomplete -- replication is off (optional). Populate all three to pre-validate the share before enabling."
            }
        } else {
            $psState = if ($psReplicate) { 'enabled' } else { 'disabled -- pre-validating' }
            Write-Pass "networkStorage pool [$psState]: '$($psCfg.NetworkPath)' -> '$($psCfg.LocalPath)' as user '$($psCfg.NetworkUser)'."
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
                if (Test-PoolStorageVaultReady -Config $psCfg -WarningAction SilentlyContinue) {
                    $psVaultReady = $true
                    Write-Pass "networkStorage pool: a vault credential is configured for '$($psCfg.NetworkUser)'."
                } else {
                    $vmsg = "networkStorage pool: '$($psCfg.NetworkUser)' has no usable vault credential -- mounting would auto-generate a junk SMB password the NAS rejects. Map a non-empty vaultKey in users.yml and Set-Password it. See docs/test-config.md."
                    if ($psReplicate) { Write-Fail $vmsg -FullPath $ConfigPath }
                    else              { Write-Warn "$vmsg (Advisory: replicate is false, so this won't block the cycle -- fix before enabling.)" }
                }
            }

            # SMB server reachability (best-effort; WARN either way -- the NAS may be
            # intentionally offline at config-check time).
            if (Get-Command Test-PoolStorageServerReachable -ErrorAction SilentlyContinue) {
                $poolSrv = Get-PoolStorageServerName -NetworkPath $psCfg.NetworkPath
                if (Test-PoolStorageServerReachable -Config $psCfg -TimeoutSeconds 5) {
                    $psReachable = $true
                    Write-Pass "networkStorage pool: SMB server reachable (${poolSrv}:445)."
                } else {
                    $tail = if ($psReplicate) { 'Replication will fail-fast and retry next cycle' } else { 'Replication is disabled' }
                    Write-Warn "networkStorage pool: SMB server '${poolSrv}:445' is not reachable right now. $tail -- fine if the NAS is intentionally offline; otherwise check networkPath / firewall / VPN."
                }
            }

            if ($IsLinux) {
                Write-Info "networkStorage on Linux needs passwordless sudo for 'mount'/'umount' (and 'mkdir' when localPath is under a root-owned dir like /mnt) -- an /etc/sudoers.d drop-in. See docs/pool-storage.md."
            }

            # ACTIVE write-path pre-flight: actually mount localPath and create the
            # per-host folder '<localPath>/<hostId>'. This is the check that catches
            # the "reachable NAS, replicate=true, but replication silently never
            # happens" class -- a wrong SMB password, a share-name typo, missing
            # Linux passwordless sudo, or a read-only share -- which the passive
            # reachability probe above cannot see (the host-side drain runs detached
            # and only records the failure in the ledger, where no operator sees it).
            # Only attempted when a credential is configured AND the server is
            # reachable, so a merely-offline NAS stays the transient WARN above.
            # FAIL (block the cycle) when replicate is on; advisory WARN when off.
            if ($psVaultReady -and $psReachable -and (Get-Command Initialize-PoolStorageHostFolder -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
                    $ydMod = Join-Path $ModulesDir 'Test.YurunaDir.psm1'
                    if (Test-Path $ydMod) { Import-Module $ydMod -Global -Force -ErrorAction SilentlyContinue }
                }
                $poolHostId = ''
                if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) {
                    try { $poolHostId = [string](Get-YurunaHostId) } catch { $null = $_ }
                }
                if ([string]::IsNullOrWhiteSpace($poolHostId)) {
                    Write-Warn "networkStorage pool: could not resolve this host's id (runtime/host.uuid) -- skipping the mount + per-host-folder pre-flight. Replication still runs at cycle end; check it has not silently failed."
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
                        Write-Pass "networkStorage pool: localPath mounted and per-host folder ready ('$($poolReady.folder)')."
                    } else {
                        $rmsg = "networkStorage pool: localPath '$($psCfg.LocalPath)' / per-host folder pre-flight FAILED -- $($poolReady.error). Replication would silently never happen this way."
                        if ($psReplicate) { Write-Fail $rmsg -FullPath $ConfigPath }
                        else              { Write-Warn "$rmsg (Advisory: replicate is false, so this won't block the cycle -- fix before enabling.)" }
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

# -- Section 9c-stash: networkStorage stash (Stash Service) -------------------
# The stash storage is ISOLATED from the pool (its own share + account). It is
# optional (only the Stash Service uses it); issues here are advisory WARN, not
# FAIL -- Start-StashServer hard-fails at build time when it is misconfigured.
Write-Section "networkStorage: stash (Stash Service)"

if (-not (Test-Path $poolMod)) {
    Write-Info "Test.PoolStorage.psm1 not found at ${poolMod}; stash storage check skipped."
} else {
    $stashCfg = Get-YurunaStashStorageConfig -Config $Config
    if (-not $stashCfg) {
        Write-Info "networkStorage stash* not fully set -- the Stash Service is off (optional). Set stashNetworkPath / stashNetworkUser / stashLocalPath to enable it."
    } else {
        Write-Pass "networkStorage stash: '$($stashCfg.NetworkPath)' -> '$($stashCfg.LocalPath)' as user '$($stashCfg.NetworkUser)'."
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
                Write-Pass "networkStorage stash: a vault credential is stored for '$($stashCfg.NetworkUser)'."
            } else {
                Write-Warn "networkStorage stash: '$($stashCfg.NetworkUser)' has NO stored vault credential -- the stash VM would bake a junk SMB password the NAS rejects. Set-Password it before Start-StashServer. See docs/test-config.md."
            }
        }
        $stashReachable = $false
        if (Get-Command Test-PoolStorageServerReachable -ErrorAction SilentlyContinue) {
            $stashSrv = Get-PoolStorageServerName -NetworkPath $stashCfg.NetworkPath
            if (Test-PoolStorageServerReachable -Config $stashCfg -TimeoutSeconds 5) {
                $stashReachable = $true
                Write-Pass "networkStorage stash: SMB server reachable (${stashSrv}:445)."
            } else {
                Write-Warn "networkStorage stash: SMB server '${stashSrv}:445' is not reachable right now -- fine if the NAS is intentionally offline; otherwise check stashNetworkPath / firewall / VPN."
            }
        }
        # ACTIVE write-path pre-flight: the stash share is configured as a SUBFOLDER
        # ('\\server\share\yuruna.stash'); New-SmbMapping to a missing subfolder fails
        # with a vague "network name cannot be found", so ensure the target folder
        # exists (create it via the parent share when missing), then verify an actual
        # mount of it. Advisory throughout -- the stash is optional and Start-StashServer
        # hard-fails at build time -- but this catches the "reachable NAS, credential
        # stored, yet the mount still fails because the folder was never created" class
        # the passive checks above cannot see. Only attempted when a credential is
        # stored AND the server answered, so a merely-offline NAS stays the WARN above.
        if ($stashCredStored -and $stashReachable -and (Get-Command Initialize-PoolStorageTargetFolder -ErrorAction SilentlyContinue)) {
            $mk = Initialize-PoolStorageTargetFolder -Config $stashCfg -Confirm:$false
            if ($mk.ok) {
                if ($mk.created) {
                    Write-Pass "networkStorage stash: created the missing target folder '$($stashCfg.NetworkPath)' on the share."
                } else {
                    Write-Pass "networkStorage stash: target folder '$($stashCfg.NetworkPath)' already present on the share."
                }
                if (Get-Command Connect-YurunaPoolStorage -ErrorAction SilentlyContinue) {
                    if (Connect-YurunaPoolStorage -Config $stashCfg -Confirm:$false) {
                        Write-Pass "networkStorage stash: localPath mounted ('$($stashCfg.LocalPath)' -> '$($stashCfg.NetworkPath)')."
                    } else {
                        Write-Warn "networkStorage stash: the target folder exists but mounting '$($stashCfg.LocalPath)' -> '$($stashCfg.NetworkPath)' still failed -- check the '$($stashCfg.NetworkUser)' password and that no other mapping holds the same NAS under a conflicting credential. Start-StashServer will buffer locally until this is fixed."
                        Show-LinuxSudoHintOnce
                    }
                }
            } else {
                Write-Warn "networkStorage stash: could not ensure the target folder '$($stashCfg.NetworkPath)' -- $($mk.error). Start-StashServer will buffer locally until this is fixed."
                if ($mk.error -match 'mount') { Show-LinuxSudoHintOnce }
            }
        }
    }
}

# -- Section 9d: pool (intent sync) -------------------------------------------
# Validate the optional pool-intent PULL when configured: enabled implies a
# non-empty intentGitUrl, and the LAN intent store answers a bounded git
# ls-remote. Reachability is a WARN (the runner degrades to single-host when the
# store is down), so a momentarily-offline proxy never blocks a healthy cycle.
# The intent-store CONTENT (pools.yml shape) is validated by Test-PoolIntent.ps1;
# this gate only checks the LOCAL config block + reachability.

Write-Section "pool (intent sync)"

$poolSyncMod = Join-Path $ModulesDir 'Test.PoolSync.psm1'
if (-not (Test-Path $poolSyncMod)) {
    Write-Info "Test.PoolSync.psm1 not found at ${poolSyncMod}; pool check skipped."
} else {
    Import-Module $poolSyncMod -Global -Force
    $plRaw = if ($Config.Contains('pool')) { $Config['pool'] } else { $null }
    if ($plRaw -isnot [System.Collections.IDictionary]) {
        Write-Info "pool block not present -- pool intent sync is off (optional)."
    } else {
        $plEnabled = ConvertTo-YurunaBool $plRaw['enabled']
        $plUrl     = [string]$plRaw['intentGitUrl']
        if ([string]::IsNullOrWhiteSpace($plUrl)) {
            if ($plEnabled) { Write-Fail "pool.enabled is true but pool.intentGitUrl is empty -- the runner cannot pull intent. Set the LAN bare-repo URL. See docs/pool-storage.md." -FullPath $ConfigPath }
            else            { Write-Info "pool.enabled = false and pool.intentGitUrl is empty -- pool intent sync is off (optional). Populate intentGitUrl to pre-validate the store before enabling." }
        } else {
            $plState = if ($plEnabled) { 'enabled' } else { 'configured (disabled)' }
            Write-Pass "pool [$plState]: intent store '$plUrl'."
            # Bounded, credential-prompt-proof reachability probe (read-only).
            $rc = Invoke-PoolSyncGit -ArgumentList @('ls-remote', '--quiet', $plUrl) -TimeoutSeconds 15
            if ($rc -eq 0) {
                Write-Pass "pool: intent store reachable ($plUrl)."
            } else {
                $why = if ($rc -eq 124) { 'timed out' } elseif ($rc -eq -1) { 'git not available' } else { "git ls-remote exit $rc" }
                Write-Warn "pool: intent store '$plUrl' not reachable right now ($why) -- fine if the proxy is intentionally offline; the runner degrades to single-host. Otherwise check the URL / apache / network."
            }
        }
    }
}

# -- Section 10: Resend transport settings ------------------------------------

Write-Section "Resend transport settings"

$resend = $null
if (Test-Path $NotificationCfgPath) {
    try {
        $notifCfg = Read-TestConfig -Path $NotificationCfgPath -ThrowOnError
        if ($notifCfg.Contains('transports') -and $notifCfg.transports.Contains('resend')) {
            $resend = $notifCfg.transports.resend
        }
    } catch {
        Write-Fail "transports.yml parse error in ${NotificationCfgPath}: $($_.Exception.Message)" -FullPath $NotificationCfgPath
    }
}

if (-not $resend) {
    Write-Warn "transports.resend not configured in transports.yml -- email transport will warn at runtime."
} else {
    if (Test-IsSet $resend.apiKey) {
        Write-Pass "transports.resend.apiKey is set (not shown)."
        if (-not "$($resend.apiKey)".StartsWith("re_")) {
            Write-Warn "transports.resend.apiKey does not start with 're_' -- Resend API keys typically begin with 're_'."
        }
    } else {
        Write-Fail "transports.resend.apiKey is not set in ${NotificationCfgPath}. Get your API key at https://resend.com/api-keys" -FullPath $NotificationCfgPath
    }

    if (Test-IsSet $resend.fromEmail) {
        Write-Pass "transports.resend.fromEmail = '$($resend.fromEmail)'"
    } else {
        Write-Fail "transports.resend.fromEmail is not set in ${NotificationCfgPath}. Example: 'Yuruna <notifications@yourdomain.com>'" -FullPath $NotificationCfgPath
    }
}

# Abort if any FAIL was recorded before network checks. Use
# Exit-WithSummary so the FAILURES block is printed at the bottom of
# the transcript -- this is the most common exit path, hit when a
# config-file or schema check failed early.
if ((Get-OutputState).FailCount -gt 0) {
    Write-Output "`nFix the errors above before testing network connectivity."
    Exit-WithSummary -Code 1
}

# -- Section 11: Resend API connectivity --------------------------------------

Write-Section "Resend API connectivity"

try {
    $resolved = [System.Net.Dns]::GetHostAddresses("api.resend.com")
    Write-Pass "DNS resolved 'api.resend.com' -> $($resolved[0].IPAddressToString)"
} catch {
    Write-Fail "DNS resolution failed for 'api.resend.com': $_"
    Write-Info "Check that DNS is available and api.resend.com is reachable."
    Exit-WithSummary 1
}

try {
    if (Test-TcpReachable -HostName "api.resend.com" -Port 443 -TimeoutMs 5000) {
        Write-Pass "TCP connection to api.resend.com:443 succeeded."
    } else {
        Write-Fail "TCP connection to api.resend.com:443 timed out."
        Write-Info "Verify that no firewall is blocking outbound HTTPS."
    }
} catch {
    Write-Fail "TCP connection to api.resend.com:443 failed: $_"
}

# -- Section 12: Live smoke notification --------------------------------------

Write-Section "Live smoke notification (config.smoke)"

if ($SkipSend) {
    Write-Warn "Skipping live send (-SkipSend was specified)."
} elseif ((Get-OutputState).FailCount -gt 0) {
    Write-Warn "Skipping live send because earlier checks failed."
} else {
    $notifyMod  = Join-Path $ModulesDir "Test.Notify.psm1"
    if (-not (Test-Path $notifyMod)) {
        Write-Fail "Cannot find Test.Notify.psm1 at: $notifyMod"
    } else {
        Import-Module -Name $notifyMod -Force

        $message = "Yuruna -- configuration smoke test (config.smoke)"
        $note    = @"
This is a smoke notification fired by Test-Config.ps1 against the
'config.smoke' event code. If you received it, the active notification
extensions and their transports are wired correctly.

Add subscribers under subscribers.config.smoke in
test/status/extension/notification/transports.yml to receive these.
With no subscribers, this run is a verbose no-op (which is fine).

Sent: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")) UTC
"@

        Write-Info "Dispatching 'config.smoke' to the active notification extensions..."
        try {
            Send-YurunaNotification -EventCode 'config.smoke' -EventMessage $message -EventNote $note
            Write-Pass "Send-YurunaNotification dispatch completed without error."
            Write-Info "Empty subscribers list is normal -- check subscribers.config.smoke if you expected delivery."
        } catch {
            Write-Fail "Send-YurunaNotification failed: $_"
            Write-Info "Verify your transports.resend.apiKey and fromEmail in transports.yml"
        }
    }
}

# -- Section: Bootstrap script encoding (ASCII, no BOM) -----------------------
# The PS 5.1 `irm | iex` installer and the guest/windows.11 scripts the fresh
# Windows guest runs the same way are parsed byte-for-byte before any
# BOM-tolerant shell exists, so a UTF-8 BOM or non-ASCII byte aborts them at
# line 1. Fold the shared Test-AsciiNoBom guard into this pre-cycle gate so an
# accidental re-encode blocks the cycle here instead of breaking first-install
# on the guest. See feedback_bootstrap_installer_no_bom.md.

Write-Section "Bootstrap script encoding (ASCII, no BOM)"

$asciiGate = Join-Path $TestRoot "Test-AsciiNoBom.ps1"
if (-not (Test-Path -LiteralPath $asciiGate)) {
    Write-Info "Test-AsciiNoBom.ps1 not found at ${asciiGate}; encoding gate skipped."
} else {
    $asciiPwsh = Get-PwshExePath
    $asciiOut  = & $asciiPwsh -NoProfile -ExecutionPolicy Bypass -File $asciiGate -Quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "irm|iex installer and guest scripts are BOM-less 7-bit ASCII."
    } else {
        Write-Fail "An irm|iex / first-run guest script is not BOM-less ASCII." -FullPath $asciiGate
        foreach ($asciiLine in $asciiOut) { Write-Info ([string]$asciiLine) }
    }
}

# -- Summary -------------------------------------------------------------------
#
# Exit-WithSummary prints the PASS/WARN/FAIL tally AND the repeated
# FAILURES block (every Write-Fail's message + full path, grouped by
# section). Centralized so every early-exit site upstream (missing
# config file, YAML parse error, network probe failure, abort-before-
# network-checks) lands on the same final layout -- the operator never
# has to scroll up to find what failed.

Exit-WithSummary -Code ((Get-OutputState).FailCount -gt 0 ? 1 : 0)

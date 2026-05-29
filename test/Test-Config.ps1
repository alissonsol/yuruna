<#PSScriptInfo
.VERSION 2026.05.29
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

.EXAMPLE
    pwsh test/Test-Config.ps1

.EXAMPLE
    pwsh test/Test-Config.ps1 -SkipSend
#>

param(
    [string]$ConfigPath = $null,
    [switch]$SkipSend
)

$TestRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test.config.yml" }
$TemplatePath         = Join-Path $TestRoot "test.config.yml.template"
$ExtensionRoot        = Join-Path $TestRoot "extension"
$ExtensionStateRoot   = Join-Path -Path $TestRoot -ChildPath "status" -AdditionalChildPath "extension"
$SchemasRoot          = Join-Path $TestRoot "schemas"
$NotificationCfgPath  = Join-Path $ExtensionStateRoot "notification/transports.yml"
$NotificationTmplPath = Join-Path $ExtensionRoot      "notification/transports.yml.template"

# ── helpers ──────────────────────────────────────────────────────────────────
# Write-Pass / Write-Fail / Write-Warn / Write-Info / Write-Section /
# Write-Summary / Exit-WithSummary are exported by Test.Output.psm1.
# Test-IsSet / Test-AgainstSchema / Test-RepoFreshness are exported by
# Test.ConfigValidator.psm1. Both modules share a $global: counters
# anchor so every Write-Fail / Write-Pass from either module lands in
# the same end-of-run summary.
$script:ModulesDir = Join-Path $TestRoot "modules"
Import-Module (Join-Path $script:ModulesDir 'Test.Output.psm1')          -Global -Force
Import-Module (Join-Path $script:ModulesDir 'Test.ConfigValidator.psm1') -Global -Force
Initialize-OutputState

# ── Section 1: Config file ────────────────────────────────────────────────────

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

# ── Section 2: YAML parsing ───────────────────────────────────────────────────

Write-Section "YAML structure"

try {
    $Config = Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered
    Write-Pass "YAML is valid and parsed successfully."
} catch {
    Write-Fail "YAML parse error in ${ConfigPath}: $_" -FullPath $ConfigPath
    Write-Info "Open test.config.yml and fix the syntax error above."
    Exit-WithSummary 1
}

# ── Section 3: Host requirements (quick) ─────────────────────────────────────
# Imports Test.Host.psm1 and runs the same fast pre-flight that
# operator-facing helpers (Remove-TestVMFiles.ps1, ...) call: detects
# the host type and verifies the absolute minimum (Administrator +
# vmms on Hyper-V, virsh + /dev/kvm on Ubuntu, UTM.app + utmctl on
# macOS). The pointer Write-Information inside Test-HostRequirement
# is suppressed here because THIS script IS the deeper check it would
# otherwise advertise.

Write-Section "Host requirements (quick)"

$ModulesDir  = Join-Path $TestRoot "modules"
$hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
$HostType    = $null
if (-not (Test-Path $hostModPath)) {
    Write-Fail "Test.Host.psm1 not found at: $hostModPath"
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

# ── Section 4: Host capacity ─────────────────────────────────────────────────
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

# ── Section 5: Host-specific feature state ───────────────────────────────────
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

# ── Section 6: Framework / project staleness ─────────────────────────────────
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
        # Cheap, no-fetch reachability probe. GIT_TERMINAL_PROMPT=0
        # makes a private/missing repo exit non-zero instead of blocking
        # on a credential dialog (Git Credential Manager on Windows).
        $prevPrompt = $env:GIT_TERMINAL_PROMPT
        $env:GIT_TERMINAL_PROMPT = '0'
        try {
            $lsOut = & git ls-remote --exit-code --quiet $projectUrlConfigured HEAD 2>&1
            $lsRc  = $LASTEXITCODE
            if ($lsRc -eq 0) {
                Write-Pass "projectUrl reachable (git ls-remote HEAD exit 0): $projectUrlConfigured"
            } else {
                $msg = ($lsOut | Out-String).Trim()
                Write-Fail "projectUrl='$projectUrlConfigured' is not reachable (git ls-remote exit $lsRc). Common causes: typo, private repo without cached credentials, or repo doesn't exist. ls-remote output: $msg" -FullPath $ConfigPath
            }
        } catch {
            Write-Fail "projectUrl='$projectUrlConfigured': ls-remote threw -- $($_.Exception.Message)" -FullPath $ConfigPath
        } finally {
            if ($null -eq $prevPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
            else                       { $env:GIT_TERMINAL_PROMPT = $prevPrompt }
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

# ── Section 7: GitHub connectivity ───────────────────────────────────────────
# DNS + TCP probes of github.com:443. Surfaces a bad network state HERE
# rather than later when Invoke-GitPull retries inside a running cycle.

Write-Section "GitHub connectivity"

try {
    $resolved = [System.Net.Dns]::GetHostAddresses("github.com")
    Write-Pass "DNS resolved 'github.com' -> $($resolved[0].IPAddressToString)"
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect("github.com", 443, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne(5000, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            Write-Pass "TCP connection to github.com:443 succeeded."
        } else {
            Write-Fail "TCP connection to github.com:443 timed out -- check firewall / VPN / captive portal."
        }
        $tcp.Close()
    } catch {
        Write-Fail "TCP connection to github.com:443 failed: $($_.Exception.Message)"
    }
} catch {
    Write-Fail "DNS resolution failed for 'github.com': $($_.Exception.Message)"
}

# ── Section 8: Top-level fields ───────────────────────────────────────────────

Write-Section "Top-level settings"

if ($Config.Contains("notification")) {
    Write-Pass "'notification' block is present."
} else {
    Write-Fail "'notification' block is missing."
}

if ($Config.vmImage -is [System.Collections.IDictionary] -and $Config.vmImage.Contains("alwaysRedownload")) {
    Write-Pass "'vmImage.alwaysRedownload' = $($Config.vmImage.alwaysRedownload)"
} else {
    Write-Warn "'vmImage.alwaysRedownload' not set — defaults to false."
}

if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains("testVmNamePrefix")) {
    Write-Pass "'vmStart.testVmNamePrefix' = '$($Config.vmStart.testVmNamePrefix)'"
} else {
    Write-Warn "'vmStart.testVmNamePrefix' not set — defaults to 'test-'."
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("recentDisplayCount")) {
    $rdc = [int]$Config.testCycle.recentDisplayCount
    if ($rdc -gt 0) { Write-Pass "'testCycle.recentDisplayCount' = $rdc" }
    else            { Write-Warn "'testCycle.recentDisplayCount' is $rdc — should be a positive integer." }
} else {
    Write-Warn "'testCycle.recentDisplayCount' not set — defaults to 30."
}

if ($Config.Contains("statusService")) {
    $ss = $Config.statusService
    Write-Pass "'statusService' block present (isEnabled=$($ss.isEnabled), port=$($ss.port))."
} else {
    Write-Warn "'statusService' not set — status HTTP server will be disabled."
}

if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains("frameworkUrl")) {
    Write-Pass "'repositories.frameworkUrl' = '$($Config.repositories.frameworkUrl)'"
} else {
    Write-Warn "'repositories.frameworkUrl' not set — status page commit links may not work, and the failure-pause break-out trigger that watches the framework repo will be a no-op."
}

# Deeper validation (URL reachability, <RepoRoot>/project/ state) lives in
# Section 6; here we only flag presence so the top-level summary matches
# frameworkUrl's treatment.
if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains("projectUrl")) {
    $projectUrlVal = [string]$Config.repositories.projectUrl
    if (Test-IsSet $projectUrlVal) {
        Write-Pass "'repositories.projectUrl' = '$projectUrlVal'"
    } else {
        Write-Warn "'repositories.projectUrl' is empty — in-tree <RepoRoot>/project/ will be used (no clone)."
    }
} else {
    Write-Warn "'repositories.projectUrl' not set — in-tree <RepoRoot>/project/ will be used (no clone)."
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("shouldStopOnFailure")) {
    Write-Pass "'testCycle.shouldStopOnFailure' = $($Config.testCycle.shouldStopOnFailure)"
} else {
    Write-Warn "'testCycle.shouldStopOnFailure' not set — defaults to false (continues on failure)."
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

# ── Section 9: Extension configs ─────────────────────────────────────────────

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

# ── Section 9b: Authentication users mapping (users.yml) ────────────────────
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
        $usersDoc = Get-Content -Raw $UsersPath | ConvertFrom-Yaml -Ordered
    } catch {
        Write-Fail "users.yml parse error in ${UsersPath}: $($_.Exception.Message)" -FullPath $UsersPath
    }

    if ($usersDoc) {
        $strict   = $true
        if ($usersDoc.Contains('strict')) { $strict = [bool]$usersDoc['strict'] }
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
            try { $vaultDoc = Get-Content -Raw $VaultPath | ConvertFrom-Yaml -Ordered } catch { Write-Verbose "vault.yml parse for users.yml cross-check failed: $_" }
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
                            $seq = Get-Content -Raw $_.FullName | ConvertFrom-Yaml -Ordered
                            if ($seq -is [System.Collections.IDictionary] -and $seq.Contains('variables') -and $seq['variables'] -is [System.Collections.IDictionary]) {
                                if ($seq['variables'].Contains('username')) {
                                    $u = [string]$seq['variables']['username']
                                    if ($u.Trim()) {
                                        $uTrim = $u.Trim()
                                        if ([void]$referenced.Add($uTrim)) { $referencedBy[$uTrim] = $_.FullName }
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

# ── Section 10: Resend transport settings ────────────────────────────────────

Write-Section "Resend transport settings"

$resend = $null
if (Test-Path $NotificationCfgPath) {
    try {
        $notifCfg = Get-Content -Raw $NotificationCfgPath | ConvertFrom-Yaml -Ordered
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

# ── Section 11: Resend API connectivity ──────────────────────────────────────

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
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $ar  = $tcp.BeginConnect("api.resend.com", 443, $null, $null)
    $ok  = $ar.AsyncWaitHandle.WaitOne(5000, $false)
    if ($ok -and $tcp.Connected) {
        $tcp.EndConnect($ar)
        Write-Pass "TCP connection to api.resend.com:443 succeeded."
    } else {
        Write-Fail "TCP connection to api.resend.com:443 timed out."
        Write-Info "Verify that no firewall is blocking outbound HTTPS."
    }
    $tcp.Close()
} catch {
    Write-Fail "TCP connection to api.resend.com:443 failed: $_"
}

# ── Section 12: Live smoke notification ──────────────────────────────────────

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
            Send-Notification -EventCode 'config.smoke' -EventMessage $message -EventNote $note
            Write-Pass "Send-Notification dispatch completed without error."
            Write-Info "Empty subscribers list is normal -- check subscribers.config.smoke if you expected delivery."
        } catch {
            Write-Fail "Send-Notification failed: $_"
            Write-Info "Verify your transports.resend.apiKey and fromEmail in transports.yml"
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
#
# Exit-WithSummary prints the PASS/WARN/FAIL tally AND the repeated
# FAILURES block (every Write-Fail's message + full path, grouped by
# section). Centralized so every early-exit site upstream (missing
# config file, YAML parse error, network probe failure, abort-before-
# network-checks) lands on the same final layout -- the operator never
# has to scroll up to find what failed.

Exit-WithSummary -Code ((Get-OutputState).FailCount -gt 0 ? 1 : 0)

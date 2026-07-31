<#PSScriptInfo
.VERSION 2026.07.31
.GUID 426d4f21-8a35-49be-b7e0-3d18f52a9c6b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna install setup standalone lab
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
    Guided setup: take a machine with the repo on disk to a working Standalone
    host or a working Lab.
.DESCRIPTION
    Runs AFTER the OS bootstrapper (install/ubuntu.kvm.sh, install/macos.utm.sh,
    install/windows.hyper-v.ps1) has installed packages and cloned the repo.
    This script installs nothing and clones nothing: it asks what it cannot
    infer, then orchestrates the scripts that already do each job.

    Two modes:

      Standalone host  one machine that runs tests by itself. Storage defaults
                       to this machine.
      Lab              a beacon that other machines join: shared storage, the
                       caching proxy, the stash and pool-control services, and a
                       'default' pool.

    ORDERING. Storage comes BEFORE the service VMs, in both modes. The stash
    service exits 1 without configured storage, and the caching proxy bakes
    storage into its guest seed at build time -- so a proxy built first is a
    proxy that has to be rebuilt.

    RE-RUNNABLE. Re-running detects what is already true and skips it, so a run
    interrupted halfway is resumed by running it again.

    The service VMs are deliberately never "already true". Every run stops and
    removes the caching-proxy service, and the stash and pool-control services
    it is about to start, then builds them fresh. That is what lets a re-run
    APPLY a change instead of preserving the very thing the change was meant to
    replace -- and it is what keeps a start from failing over a half-removed VM
    the last run left registered. Budget for it: rebuilding the proxy is roughly
    15 minutes.

    WINDOWS RUNS ELEVATED. Enable-TestAutomation and all three Start-*VM scripts
    independently refuse without Administrator, so the whole run is elevated
    once, up front, rather than failing four steps in. The Stop-*VM scripts need
    it just as much and announce it far less: they remove Hyper-V VMs, so
    unelevated they fail somewhere inside the teardown instead of refusing at
    the top.
.PARAMETER AnswerFile
    YAML answers for an unattended run -- the same code path as the interactive
    one, with no prompts. A guided run writes the answer file it used, so the
    next machine can be set up with it. Schema:

        setup:
          type: standalone          # or: lab
          runTests: true            # configure this machine's host settings
          projectUrl: ''            # '' keeps whatever test.config.yml has;
                                    # omit the key to take the script's default
        storage:
          kind: local               # local | nas | none  ('none' is standalone-only)
          localRoot: '/srv'         # kind: local -- REQUIRED unattended, see below
          networkPath: '//ypool-nas/work/yuruna.pool'
          networkUser: 'yuruna-pool'
          onFailure: stop           # stop | local -- see below
        lab:
          name: workshop
          createDefaultPool: true

    setup.projectUrl is never prompted for. A run with no answer file entry uses
    the $DefaultProjectUrl set at the top of the script, so an operator who does
    not know the project repo still ends with a testable machine. Setting the key
    to '' opts out and keeps whatever test.config.yml already has.

    storage.localRoot is required for an unattended kind: local run (and for an
    unattended NAS run whose onFailure is 'local'). New-LocalLabStorage.ps1 asks
    where the lab's storage should live, and with no answer file entry and nobody
    at the console the run would hang rather than fail -- so setup.ps1 stops with
    this key named instead.

    storage.onFailure governs an unreachable NAS. The default is 'stop': a lab
    quietly becoming beacon-local when the operator asked for a NAS is the kind
    of divergence nobody notices until the beacon is a single point of failure.
    An interactive run offers the choice instead of taking it.
.PARAMETER WhatIf
    Print the ordered task list and stop, changing nothing.
.EXAMPLE
    pwsh install/setup.ps1
.EXAMPLE
    pwsh install/setup.ps1 -WhatIf
.EXAMPLE
    pwsh install/setup.ps1 -AnswerFile lab-answers.yml
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AnswerFile = ''
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
# Several preflight probes read a native command's exit code as the ANSWER
# ("is libvirtd running?"), not as a failure. Pinned so an ambient preference
# cannot turn those into terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TestRoot = Join-Path $RepoRoot 'test'
$ConfigPath = Join-Path $TestRoot 'test.config.yml'

# The project repo a setup run points test.config.yml at. Not asked: every run
# that does not say otherwise should land on the same known-good project, so a
# fresh machine is testable without the operator knowing the URL. Change this
# one line to retarget every future run; an answer file's setup.projectUrl still
# wins per-run, and '' there keeps whatever test.config.yml already has.
$DefaultProjectUrl = 'https://github.com/alissonsol/yuruna-project'

# --- REGION: task bookkeeping
# Every step lands in one of three buckets, and the closing report prints all
# three. "Skipped" is the one that matters: a setup that silently declines to do
# something reads as a setup that already did it.
$Script:Done    = [System.Collections.Generic.List[string]]::new()
$Script:Skipped = [System.Collections.Generic.List[string]]::new()
$Script:Failed  = [System.Collections.Generic.List[string]]::new()
$Script:Plan    = [System.Collections.Generic.List[string]]::new()
$Script:StepNo  = 0

function Add-PlannedStep {
    param([Parameter(Mandatory)][string]$Description)
    $Script:StepNo++
    $Script:Plan.Add(("{0,2}. {1}" -f $Script:StepNo, $Description))
}

function Invoke-SetupStep {
<#
.SYNOPSIS
    Run one setup step, recording its outcome. Under -WhatIf, records the step in
    the plan and runs nothing.
.PARAMETER AlreadyDone
    A predicate that returns $true when the step's work is already true on this
    machine. This is what makes re-running safe.
.PARAMETER Critical
    A failure here stops the run. Non-critical steps report and continue, so one
    optional piece failing does not cost the operator everything after it.
#>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [scriptblock]$AlreadyDone,
        [switch]$Critical
    )
    Add-PlannedStep -Description $Name
    if ($WhatIfPreference) { return $true }

    if ($AlreadyDone) {
        $done = $false
        try { $done = [bool](& $AlreadyDone) } catch { $done = $false }
        if ($done) {
            Write-Information "  [skip] $Name -- already done."
            $Script:Skipped.Add("$Name (already done)")
            return $true
        }
    }

    Write-Information ''
    Write-Information "==> $Name"
    try {
        & $Action
        $Script:Done.Add($Name)
        return $true
    } catch {
        $message = $_.Exception.Message
        if ($Critical) {
            $Script:Failed.Add("$Name -- $message")
            Write-Error "$Name failed: $message"
            Write-SetupReport
            exit 1
        }
        $Script:Failed.Add("$Name -- $message")
        Write-Warning "$Name failed: $message"
        return $false
    }
}

function Invoke-RepoScript {
<#
.SYNOPSIS
    Run one of the repo's own scripts in a child pwsh and throw on a non-zero
    exit.
.DESCRIPTION
    A child process, not dot-sourcing: these scripts set their own preferences,
    import their own modules and call exit. Hosting them in this session would
    let one of them terminate the whole setup, and would leak their module
    imports into every later step.

    THE CHILD INHERITS THIS CONSOLE. Started through ProcessStartInfo with no
    redirection, so its stdout and stdin are this terminal's -- not a pipe.

    `& pwsh ...` cannot be used here. PowerShell captures a native command's
    output whenever something downstream consumes it, and every call site is
    consumed: the exit code is read, and the enclosing step's result is
    assigned. The child's every line then lands in a pipeline nobody prints.
    The operator sees a script that has produced nothing for minutes, and a
    child that stops at a Read-Host stops INVISIBLY -- the prompt is captured
    with everything else, so the run looks hung until someone presses Enter at
    a question they were never shown. Both the storage script's consent prompt
    and its "where should storage live?" question are exactly that.

    ArgumentList (not a joined string) so each argument reaches the child as one
    argv entry: a storage root or lab name carrying a space must not be re-split
    on the way in -- the legacy-quoting regression class.
#>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [switch]$TolerateFailure
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "script not found: $Path" }
    Write-Information "    $([IO.Path]::GetFileName($Path)) $($Arguments -join ' ')"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CurrentPwshPath
    # UseShellExecute stays false: on .NET it is what makes the child inherit
    # the parent's standard handles rather than being given a new console.
    $startInfo.UseShellExecute = $false
    foreach ($argument in (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $code = 1
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        $code = $process.ExitCode
    } finally {
        if ($process) { $process.Dispose() }
    }
    if ($code -ne 0 -and -not $TolerateFailure) {
        throw "$([IO.Path]::GetFileName($Path)) exited $code"
    }
    return $code
}

function Invoke-ServiceVMReset {
<#
.SYNOPSIS
    Stop and remove a service VM so the Start step that follows it builds from a
    clean slate. Recorded as a step of its own.
.DESCRIPTION
    Every run tears down the service VMs it is about to start rather than
    building over whatever the last run left. Two things make this the setup's
    job and not the Start scripts':

    The stash and pool-control Starts delegate to a per-host New-VM.ps1 that
    deletes the VM's bundle/disk directory in place and never unregisters the VM
    from the hypervisor. Rebuilding over a still-registered VM leaves the
    hypervisor holding a registration whose files are gone, and the start that
    follows fails on a VM it believes it already has. The Stop scripts
    unregister first, which is the whole difference.

    The caching proxy is ADOPTED whenever its health probe passes -- the
    fast path that skips a ~15-minute rebuild, and the one outcome a re-run
    cannot use, because an adopted VM keeps the base image, the seed and the
    baked configuration the re-run exists to replace. Stopping it first also
    clears an abandoned bring-up lock; a Start refuses to take that over on its
    own and stops the run instead.

    Paired with its Start rather than swept up front, so a run only ever removes
    a service it is going to rebuild: a standalone re-run on a machine that was
    once a lab must not silently delete that lab's pool-control service.

    Never critical. A teardown that fails still leaves the Start script its own
    destroy-and-rebuild path, so the run is better off continuing and letting
    the start report what it actually hits.
#>
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$StopScript
    )
    $stopPath = Join-Path $TestRoot $StopScript
    [void](Invoke-SetupStep -Name "Stop and remove any existing $Service VM (clean slate for the start)" -Action {
        [void](Invoke-RepoScript -Path $stopPath)
    })
}

function Get-LocalLabStorageArgument {
<#
.SYNOPSIS
    The argument list for New-LocalLabStorage.ps1, correct for both an
    interactive and an unattended run.
.DESCRIPTION
    Two of that script's prompts are invisible from here and neither is
    suppressed by anything setup.ps1 sets: the "storage is LOCAL to this machine,
    continue?" consent (skipped only by -Force) and "where should the lab's
    storage live?" (skipped only by -Root). Under -AnswerFile the child would sit
    on a Read-Host that nobody is present to answer -- the exact silent stall an
    unattended run must never produce.

    So an unattended run passes -Force (the answer file IS the consent) and
    requires storage.localRoot. Missing it FAILS with the key to set rather than
    blocking: a run that stops with a message can be fixed, a run that hangs
    cannot even be diagnosed remotely.

    The lab name is sanitised to the pool-id charset here. New-LocalLabStorage
    only sanitises the name it invents for itself, so a machine whose hostname
    carries an underscore would pass its own check by hand and fail through us.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$LabName = '',
        [string]$LocalRoot = '',
        [bool]$Unattended = $false
    )
    $name = if ($LabName) { $LabName } else { [Environment]::MachineName }
    $name = ($name.ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $name) { $name = 'lab' }
    if ($name.Length -gt 63) { $name = $name.Substring(0, 63).TrimEnd('-') }

    $argList = @('-LabName', $name)
    if ($LocalRoot) { $argList += @('-Root', $LocalRoot) }
    if ($Unattended) {
        if (-not $LocalRoot) {
            throw ("an unattended local-storage run needs storage.localRoot in the answer file: " +
                   "New-LocalLabStorage.ps1 asks where the lab's storage should live, and with nobody " +
                   "there to answer it the run would hang instead of failing")
        }
        # The answer file is the operator's consent; without -Force the child
        # stops on its local-only confirmation prompt.
        $argList += '-Force'
    }
    return ,$argList
}

function Get-StorageAliasTier {
<#
.SYNOPSIS
    One record per configured storage tier: the server NAME its alias is keyed on
    and the share path that name came from. Empty when storage is unconfigured.
.DESCRIPTION
    Read from test.config.yml rather than from this run's answers, because the
    hosts file has to agree with what the RUNNER will later mount, and that is
    the file -- not the questionnaire. The two tiers are returned separately: a
    machine can legitimately carry a different server name per tier.
.OUTPUTS
    System.Collections.Hashtable[]  @{ Name; NetworkPath }
#>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
    $tiers = [System.Collections.Generic.List[hashtable]]::new()
    $cfg = Read-TestConfig -Path $ConfigPath
    foreach ($storage in @(
        (Get-YurunaPoolStorageConfig  -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue),
        (Get-YurunaStashStorageConfig -Config $cfg -WarningAction SilentlyContinue))) {
        if (-not $storage -or -not $storage.NetworkPath) { continue }
        $name = Get-PoolStorageServerName -NetworkPath $storage.NetworkPath
        if (-not $name) { continue }
        if ($tiers.Name -contains $name) { continue }
        $tiers.Add(@{ Name = $name; NetworkPath = $storage.NetworkPath })
    }
    return $tiers.ToArray()
}

function Import-YamlModule {
<#
.SYNOPSIS
    Import powershell-yaml without its alias creation narrating itself under
    -WhatIf.
.DESCRIPTION
    powershell-yaml creates two aliases at import, and New-Alias supports
    ShouldProcess -- so a preview run prints "What if: New Alias" twice before
    the task list it was actually asked for. The preference has to be cleared in
    the GLOBAL scope: a module's top-level code resolves preference variables up
    the module/global chain, not through the caller's dynamic scope, so setting
    it locally (or in a child scope) has no effect.
#>
    $prior = $global:WhatIfPreference
    try {
        $global:WhatIfPreference = $false
        Import-Module powershell-yaml -Verbose:$false
    } finally {
        $global:WhatIfPreference = $prior
    }
}

function Read-Choice {
<#
.SYNOPSIS
    Ask a numbered question. Returns the chosen option's Value.
.DESCRIPTION
    Never prompts on an unattended run: with an answer file the value is already
    known, and a Read-Host here is exactly the stall that makes a remote setup
    hang with nobody present to answer it.
#>
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][hashtable[]]$Option,
        [Parameter(Mandatory)]$Default
    )
    if ($Script:Unattended) { return $Default }
    Write-Information ''
    Write-Information $Question
    for ($i = 0; $i -lt $Option.Count; $i++) {
        $marker = if ($Option[$i].Value -eq $Default) { ' (default)' } else { '' }
        Write-Information ("  [{0}] {1}{2}" -f ($i + 1), $Option[$i].Label, $marker)
    }
    while ($true) {
        $answer = (Read-Host 'Choice').Trim()
        if (-not $answer) { return $Default }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Option.Count) {
            return $Option[$n - 1].Value
        }
        Write-Information "  Enter a number between 1 and $($Option.Count)."
    }
}

function Read-Text {
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Default = ''
    )
    if ($Script:Unattended) { return $Default }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = (Read-Host "$Question$suffix").Trim()
    if (-not $answer) { return $Default }
    return $answer
}

function Write-SetupReport {
    Write-Information ''
    Write-Information '================ Yuruna setup ================'
    if ($Script:Done.Count -gt 0) {
        Write-Information 'Done:'
        foreach ($d in $Script:Done) { Write-Information "  - $d" }
    }
    if ($Script:Skipped.Count -gt 0) {
        Write-Information ''
        Write-Information 'Skipped:'
        foreach ($s in $Script:Skipped) { Write-Information "  - $s" }
    }
    if ($Script:Failed.Count -gt 0) {
        Write-Information ''
        Write-Information 'Failed:'
        foreach ($f in $Script:Failed) { Write-Information "  - $f" }
    }
    Write-Information '=============================================='
}

# --- REGION: preflight
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking
# Test.HostDetection directly: Yuruna.HostRedirect keeps its own
# Import-HostDetectionModule private, and Get-HostType / Get-HostFolder are what
# this needs.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostDetection.psm1') -Force -DisableNameChecking
$HostType = Get-HostType
if (-not $HostType) {
    Write-Error 'Host type could not be determined. Only macOS (UTM), Windows (Hyper-V) and Linux (KVM/libvirt) are supported.'
    exit 1
}
$HostFolderName = (Get-HostFolder $HostType) -replace '^host[/\\]', ''

Write-Information ''
Write-Information "Yuruna setup -- $HostFolderName"
Write-Information "Repo: $RepoRoot"

# Windows: elevate ONCE, up front. Enable-TestAutomation and all three Start-*VM
# scripts each refuse without Administrator, so a non-elevated run would get
# four steps in and then fail on every one that matters.
if ($IsWindows) {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if ($WhatIfPreference) {
            # A preview changes nothing, so it needs no elevation -- and
            # relaunching here would be worse than useless: Start-Process itself
            # honours -WhatIf, so the elevated run would never start and this
            # script would exit 0 as though the preview had succeeded.
            Write-Warning 'Not running as Administrator. This preview needs no elevation, but the real run does -- it will relaunch elevated.'
        } else {
            Write-Information ''
            Write-Information 'This setup needs Administrator: host settings, the firewall rules and'
            Write-Information 'every Hyper-V VM operation require it. Relaunching elevated...'
            $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
            if ($AnswerFile) { $relaunchArgs += @('-AnswerFile', (Resolve-Path -LiteralPath $AnswerFile).Path) }
            try {
                # -Confirm:$false so an ambient $ConfirmPreference cannot turn the
                # relaunch into a prompt that the elevated child never sees.
                $proc = Start-Process -FilePath (Get-CurrentPwshPath) -ArgumentList $relaunchArgs -Verb RunAs -PassThru -Wait -Confirm:$false
                if (-not $proc) { throw 'the elevated process did not start' }
                exit ([int]$proc.ExitCode)
            } catch {
                Write-Error "Could not relaunch elevated ($($_.Exception.Message)). Start an Administrator PowerShell and run: pwsh $PSCommandPath"
                exit 1
            }
        }
    }
}

# --- REGION: answers
$Script:Unattended = [bool]$AnswerFile
$answers = $null
if ($AnswerFile) {
    if (-not (Test-Path -LiteralPath $AnswerFile)) {
        Write-Error "Answer file not found: $AnswerFile"
        exit 1
    }
    Import-YamlModule
    $answers = Get-Content -LiteralPath $AnswerFile -Raw | ConvertFrom-Yaml -Ordered
}

function Get-Answer {
<#
.SYNOPSIS
    One value from the answer file by 'section.key' path, or $null.
#>
    param([Parameter(Mandatory)][string]$Path)
    if (-not $answers) { return $null }
    $node = $answers
    foreach ($part in ($Path -split '\.')) {
        if ($node -isnot [System.Collections.IDictionary] -or -not $node.Contains($part)) { return $null }
        $node = $node[$part]
    }
    return $node
}

$setupType = Get-Answer 'setup.type'
if (-not $setupType) {
    $setupType = Read-Choice -Question 'What are you setting up?' -Default 'standalone' -Option @(
        @{ Label = 'Standalone host -- one machine that runs tests by itself'; Value = 'standalone' }
        @{ Label = 'Lab -- a beacon other machines join (shared storage + services + a pool)'; Value = 'lab' }
    )
}
if ($setupType -notin @('standalone', 'lab')) {
    Write-Error "setup.type must be 'standalone' or 'lab' (got '$setupType')."
    exit 1
}
$isLab = ($setupType -eq 'lab')

$runTestsAnswer = Get-Answer 'setup.runTests'
$runTests = if ($null -ne $runTestsAnswer) { [bool]$runTestsAnswer } else {
    (Read-Choice -Question 'Should this machine run tests itself?' -Default $true -Option @(
        @{ Label = 'Yes -- configure host settings (display sleep, screen lock, firewall)'; Value = $true }
        @{ Label = 'No -- this machine only hosts services'; Value = $false }
    ))
}

$projectUrl = Get-Answer 'setup.projectUrl'
if ($null -eq $projectUrl) { $projectUrl = $DefaultProjectUrl }

$storageKind = Get-Answer 'storage.kind'
if (-not $storageKind) {
    $storageOptions = @(
        @{ Label = 'This machine -- stand up local SMB shares here (New-LocalLabStorage)'; Value = 'local' }
        @{ Label = 'An existing NAS share'; Value = 'nas' }
    )
    # 'none' is standalone-only: a lab without shared storage is not a lab -- the
    # stash service and the pool intent store both live on it.
    if (-not $isLab) { $storageOptions += @{ Label = 'None -- skip shared storage and the stash service'; Value = 'none' } }
    $storageKind = Read-Choice -Question 'Where should pool and stash storage live?' `
        -Default $(if ($isLab) { 'nas' } else { 'local' }) -Option $storageOptions
}
if ($storageKind -notin @('local', 'nas', 'none')) {
    Write-Error "storage.kind must be 'local', 'nas' or 'none' (got '$storageKind')."
    exit 1
}
if ($isLab -and $storageKind -eq 'none') {
    Write-Error "storage.kind 'none' is not valid for a lab: the stash service and the pool intent store both need shared storage."
    exit 1
}

$storageNetworkPath = [string](Get-Answer 'storage.networkPath')
$storageNetworkUser = [string](Get-Answer 'storage.networkUser')
if ($storageKind -eq 'nas') {
    if (-not $storageNetworkPath) { $storageNetworkPath = Read-Text -Question 'NAS share for the pool (e.g. //ypool-nas/work/yuruna.pool)' }
    if (-not $storageNetworkUser) { $storageNetworkUser = Read-Text -Question 'NAS account' -Default 'yuruna-pool' }
    if (-not $storageNetworkPath -or -not $storageNetworkUser) {
        Write-Error "storage.kind 'nas' needs both storage.networkPath and storage.networkUser."
        exit 1
    }
}
# Where local shares live. Only consulted for storage.kind = local (including the
# NAS fallback); interactively New-LocalLabStorage asks and suggests a default.
$storageLocalRoot = [string](Get-Answer 'storage.localRoot')
$storageOnFailure = [string](Get-Answer 'storage.onFailure')
if (-not $storageOnFailure) { $storageOnFailure = 'stop' }
if ($storageOnFailure -notin @('stop', 'local')) {
    Write-Error "storage.onFailure must be 'stop' or 'local' (got '$storageOnFailure')."
    exit 1
}

$labName = ''
$createDefaultPool = $false
if ($isLab) {
    $labName = [string](Get-Answer 'lab.name')
    if (-not $labName) { $labName = Read-Text -Question 'Lab beacon name' -Default ([Environment]::MachineName.ToLowerInvariant()) }
    $poolAnswer = Get-Answer 'lab.createDefaultPool'
    $createDefaultPool = if ($null -ne $poolAnswer) { [bool]$poolAnswer } else {
        (Read-Choice -Question "Create the 'default' pool?" -Default $true -Option @(
            @{ Label = 'Yes'; Value = $true }
            @{ Label = 'No'; Value = $false }
        ))
    }
}

# --- REGION: 1. preflight checks
[void](Invoke-SetupStep -Name 'Preflight: pwsh, hypervisor, powershell-yaml, disk headroom' -Critical -Action {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml is not installed. Run the bootstrapper first: install/$HostFolderName.*"
    }
    $home_ = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    try {
        $drive = Get-PSDrive -Name (Split-Path -Qualifier $home_).TrimEnd(':') -ErrorAction SilentlyContinue
        if ($drive -and $drive.Free -and $drive.Free -lt 40GB) {
            Write-Warning "Only $([Math]::Round($drive.Free / 1GB, 1)) GB free on $($drive.Name): -- VM images need roughly 40 GB. Continuing."
        }
    } catch { Write-Verbose "disk headroom check: $($_.Exception.Message)" }
    Write-Information "    host type: $HostType"
})

# --- REGION: 2. config
[void](Invoke-SetupStep -Name 'Create or refresh test/test.config.yml from the template' -Critical -AlreadyDone {
    # Only "already done" when the file exists AND the operator named no project
    # URL -- otherwise there is a change to apply.
    (Test-Path -LiteralPath $ConfigPath) -and -not $projectUrl
} -Action {
    Import-Module (Join-Path $TestRoot 'modules/Test.ConfigSync.psm1') -Force -DisableNameChecking
    # test.config.yml.template -- NOT test.config.template.yml. Getting this
    # backwards silently disabled the refresh AND, on a machine with no
    # test.config.yml yet, killed the whole run on this -Critical step.
    $template = Join-Path $TestRoot 'test.config.yml.template'
    if (Test-Path -LiteralPath $template) {
        [void](Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $template)
    } elseif (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "neither $ConfigPath nor its template ($template) exists"
    }
    if ($projectUrl) {
        # Line-level edit, deliberately: a full YAML round-trip through
        # ConvertTo-Yaml would drop this file's comments, which are most of its
        # documentation.
        $lines = Get-Content -LiteralPath $ConfigPath
        $hit = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^(\s*)projectUrl\s*:') {
                $lines[$i] = "$($Matches[1])projectUrl: $projectUrl"
                $hit = $true
                break
            }
        }
        if (-not $hit) { throw "no projectUrl key found in $ConfigPath to set" }
        Set-Content -LiteralPath $ConfigPath -Value $lines
        Write-Information "    projectUrl -> $projectUrl"
    }
})

# --- REGION: 3. folders
[void](Invoke-SetupStep -Name 'Create the image, VM, log and runtime folders' -Action {
    $base = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    foreach ($d in @(
        (Join-Path $base 'yuruna/image'),
        (Join-Path $base 'yuruna/vms'),
        (Join-Path $TestRoot 'status/log'),
        (Join-Path $TestRoot 'status/runtime')
    )) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
})

# --- REGION: 4. host settings
if ($runTests) {
    [void](Invoke-SetupStep -Name 'Configure host settings (Enable-TestAutomation -SkipPoolStorage)' -Action {
        # -SkipPoolStorage: setup.ps1 owns storage, in its own order, at step 5.
        # Without the switch Enable ends in an interactive NAS questionnaire,
        # which would both duplicate step 5 and stall an unattended run.
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Enable-TestAutomation.ps1') -Arguments @('-SkipPoolStorage'))
    })
} else {
    $Script:Skipped.Add('Host settings (this machine was declared services-only)')
}

# --- REGION: 5. storage
$storageConfigured = $false
if ($storageKind -eq 'none') {
    $Script:Skipped.Add('Shared storage, and with it the stash service (storage.kind = none)')
} elseif ($storageKind -eq 'local') {
    $ok = Invoke-SetupStep -Name 'Stand up local pool and stash shares (New-LocalLabStorage)' -AlreadyDone {
        Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
        $cfg = Read-TestConfig -Path $ConfigPath
        $pool = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue
        if (-not ($pool -and $pool.LocalPath)) { return $false }
        # A mounted share is NOT enough to call this done. The config a machine
        # carries for a NAS is identical in every key to the config for shares on
        # this machine -- only the host alias differs -- so a machine still
        # pointed at a NAS reads as "already local" and keeps the storage, the
        # aliases and the credentials the operator just asked to replace. The
        # alias is the one thing that tells them apart.
        if (-not (Test-PoolStorageServerIsLocal -NetworkPath $pool.NetworkPath)) { return $false }
        [bool](Test-YurunaPoolStorageMounted -Config $pool)
    } -Action {
        $storageArgs = Get-LocalLabStorageArgument -LabName $labName -LocalRoot $storageLocalRoot -Unattended $Script:Unattended
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'New-LocalLabStorage.ps1') -Arguments $storageArgs)
    }
    $storageConfigured = $ok
} else {
    $ok = Invoke-SetupStep -Name "Mount the NAS share $storageNetworkPath" -Action {
        Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
        # Sudoers FIRST on Linux: the mount runs `sudo -n` and fails outright
        # without the drop-in, which reads as an unreachable NAS.
        if ($IsLinux -and (Get-Command Set-PoolStorageSudoers -ErrorAction SilentlyContinue)) {
            [void](Set-PoolStorageSudoers -Confirm:$false)
        }
        $cfg  = Read-TestConfig -Path $ConfigPath
        $pool = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue
        if (-not $pool) {
            throw "networkStorage.pool is not configured in $ConfigPath. Set networkPath ($storageNetworkPath), networkUser ($storageNetworkUser) and localPath there, then re-run."
        }
        if (-not (Connect-YurunaPoolStorage -Config $pool)) {
            throw "could not mount $storageNetworkPath"
        }
    }
    if (-not $ok) {
        # A NAS that cannot be mounted is ordinary -- it is down, or this
        # operator never had one. Neither should end a setup that is otherwise
        # complete, so offer real local shares rather than a degraded anything.
        $fallback = if ($Script:Unattended) { $storageOnFailure } else {
            Read-Choice -Question "The NAS $storageNetworkPath could not be mounted. What now?" -Default 'stop' -Option @(
                @{ Label = 'Stop here -- fix the NAS and re-run'; Value = 'stop' }
                @{ Label = 'Use local shares on this machine instead (a real lab others can join)'; Value = 'local' }
            )
        }
        if ($fallback -eq 'local') {
            $ok = Invoke-SetupStep -Name 'Fall back to local pool and stash shares (New-LocalLabStorage)' -Action {
                $storageArgs = Get-LocalLabStorageArgument -LabName $labName -LocalRoot $storageLocalRoot -Unattended $Script:Unattended
                [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'New-LocalLabStorage.ps1') -Arguments $storageArgs)
            }
            $storageConfigured = $ok
            $storageKind = 'local'
        } else {
            Write-Error "Storage is not configured and storage.onFailure is 'stop'. Nothing further will run."
            Write-SetupReport
            exit 1
        }
    } else {
        $storageConfigured = $true
    }
}

# --- REGION: 5b. hosts aliases -- standalone
# Standalone is the mode where nothing else owns these lines. A lab always stands
# up storage, and the local-storage script writes the aliases as part of it; a
# standalone host may decline storage entirely (storage.kind = none is
# standalone-only) or point at a NAS, and then no step in the run ever looks at
# the hosts file.
#
# What that costs: 'ypool-nas' is a NAME, and the same name means the NAS on a
# machine that used to have one and this machine on a machine that now serves its
# own shares. Every other value is identical between those two worlds -- share
# path, account, mount point -- so a stale line does not fail, it SUCCEEDS against
# the wrong server. The alias is the only thing that decides which, and this is
# where it is made to agree with the storage the operator just chose.
if (-not $isLab -and $storageKind -eq 'local') {
    [void](Invoke-SetupStep -Name 'Point the pool and stash aliases at this machine (hosts file)' -AlreadyDone {
        $tiers = @(Get-StorageAliasTier)
        if ($tiers.Count -eq 0) { return $false }
        foreach ($tier in $tiers) {
            if (-not (Test-PoolStorageServerIsLocal -NetworkPath $tier.NetworkPath)) { return $false }
        }
        return $true
    } -Action {
        $tiers = @(Get-StorageAliasTier)
        if ($tiers.Count -eq 0) {
            throw "no networkStorage server names are set in $ConfigPath, so there is no alias to point anywhere. Re-run the storage step first."
        }
        # Set-LocalLabStorageHostAlias, not a hosts-file edit of our own: it owns
        # the loopback address the local shares are published on, and the elevated
        # re-launch the hosts file needs on macOS and Linux.
        Import-Module (Join-Path $TestRoot 'modules/Test.LocalLabStorage.psm1') -Force -DisableNameChecking
        $names = @($tiers | ForEach-Object { $_.Name })
        $written = Set-LocalLabStorageHostAlias -RepoRoot $RepoRoot -Name $names
        Write-Information "    $written of $($names.Count) alias(es) rewritten: $($names -join ', ')"
    })
} elseif (-not $isLab) {
    # storage.kind nas / none. The right address is the operator's NAS, which this
    # script has no way to learn -- they gave a name, not an address. But a name
    # resolving to LOOPBACK is knowably wrong here: it is what a previous
    # local-storage run left behind, and it silently redirects the mount to this
    # machine. Reported rather than repaired, with the line to delete.
    [void](Invoke-SetupStep -Name 'Check the pool and stash aliases in the hosts file' -Action {
        $stale = @(Get-StorageAliasTier | Where-Object { Test-PoolStorageServerIsLocal -NetworkPath $_.NetworkPath })
        if ($stale.Count -eq 0) { return }
        $hostsFile = if ($IsWindows) { "$env:SystemRoot\System32\drivers\etc\hosts" } else { '/etc/hosts' }
        throw ("$(($stale | ForEach-Object { $_.Name }) -join ', ') still resolve(s) to this machine, which is left over from local " +
               "shares and would point the mount at this host instead of the NAS. Remove those line(s) from $hostsFile " +
               "(or run: pwsh automation/Set-HostAlias.ps1 -ComputerName <name>, with no -IPAddress, elevated) and re-run.")
    })
}

# --- REGION: 6. caching proxy
$proxyIp = ''
Invoke-ServiceVMReset -Service 'caching-proxy service' -StopScript 'Stop-CachingProxyServiceVM.ps1'
[void](Invoke-SetupStep -Name 'Start the caching-proxy service VM' -Critical -Action {
    [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Start-CachingProxyServiceVM.ps1'))
})
if (-not $WhatIfPreference) {
    Import-Module (Join-Path $TestRoot 'modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking
    try {
        $state = Read-CachingProxyServiceState
        if ($state -and $state.ipAddress) { $proxyIp = [string]$state.ipAddress }
    } catch { Write-Verbose "proxy state read: $($_.Exception.Message)" }
}

# --- REGION: 6b. aggregator readiness
# The gate that closes the "services never register" bug: the aggregator URL is
# baked into each dependent guest's seed ONCE, and an empty value there is never
# re-resolved for the life of that VM.
[void](Invoke-SetupStep -Name 'Wait for the pool-aggregator service to answer (up to 15 min)' -Critical -Action {
    $ready = if ($proxyIp) { Wait-YurunaAggregatorReady -ProxyAddress $proxyIp } else { Wait-YurunaAggregatorReady }
    if (-not $ready) {
        throw ("the pool-aggregator service did not become ready. Creating the stash or pool-control VM now would bake an " +
               "EMPTY aggregator URL into its seed, which never re-resolves -- the service would run but never appear on " +
               "the dashboard. Check it inside the proxy VM with 'journalctl -u pool-aggregator-service -n 50', then re-run this script.")
    }
})

# --- REGION: 7. stash service
if ($storageConfigured) {
    Invoke-ServiceVMReset -Service 'stash service' -StopScript 'Stop-StashServiceVM.ps1'
    [void](Invoke-SetupStep -Name 'Start the stash service VM' -Action {
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Start-StashServiceVM.ps1'))
    })
} else {
    $Script:Skipped.Add('Stash service (it exits 1 without configured storage)')
}

# --- REGION: 8. bind config to the local proxy
[void](Invoke-SetupStep -Name 'Point test.config.yml at this machine''s caching proxy' -AlreadyDone {
    if (-not $proxyIp) { return $false }
    (Get-Content -LiteralPath $ConfigPath -Raw) -match "(?m)^\s*cachingProxyIp\s*:\s*$([regex]::Escape($proxyIp))\s*$"
} -Action {
    if (-not $proxyIp) { throw 'the caching proxy VM did not report an IP address' }
    $lines = Get-Content -LiteralPath $ConfigPath
    $hit = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)cachingProxyIp\s*:') {
            $lines[$i] = "$($Matches[1])cachingProxyIp: $proxyIp"
            $hit = $true
            break
        }
    }
    if (-not $hit) { throw "no vmStart.cachingProxyIp key found in $ConfigPath to set" }
    Set-Content -LiteralPath $ConfigPath -Value $lines
    Write-Information "    cachingProxyIp -> $proxyIp"
})

# --- REGION: 9. validate
[void](Invoke-SetupStep -Name 'Validate the configuration (Test-Config gate)' -Action {
    Import-Module (Join-Path $TestRoot 'modules/Test.ConfigPreflight.psm1') -Force -DisableNameChecking
    $gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -CallerName 'setup.ps1'
    if (-not $gate.passed) { throw "Test-Config reported failures (exit $($gate.exitCode)); the block above names them" }
})

# --- REGION: 10-13. lab only
$intentGitUrl = ''
if ($isLab) {
    Invoke-ServiceVMReset -Service 'pool-control service' -StopScript 'Stop-PoolControlServiceVM.ps1'
    [void](Invoke-SetupStep -Name 'Start the pool-control service VM' -Action {
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Start-PoolControlServiceVM.ps1'))
    })

    [void](Invoke-SetupStep -Name 'Enrol this machine into its own lab (Set-LabToken)' -Action {
        if (-not $proxyIp) { throw 'no caching-proxy address is known, so there is nothing to enrol against' }
        # The 6-char code rotates about once a minute, so it is read here rather
        # than asked for -- an operator could not type one fast enough to still
        # be valid. /metrics is open by design (the dashboard shows the same
        # value) and this read is beacon-local.
        $code = ''
        foreach ($scheme in @('https', 'http')) {
            try {
                $metrics = Invoke-WebRequest -Uri "${scheme}://${proxyIp}:9400/metrics" -TimeoutSec 10 -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
                if ([int]$metrics.StatusCode -ge 200 -and [int]$metrics.StatusCode -lt 300 -and
                    "$($metrics.Content)" -match 'yuruna_pool_lab_token\{[^}]*token="([^"]+)"') {
                    $code = $Matches[1]
                    break
                }
            } catch { Write-Verbose "metrics read over ${scheme}: $($_.Exception.Message)" }
        }
        if (-not $code) { throw "could not read the lab token from ${proxyIp}:9400/metrics; the dashboard's 'Lab token' tile shows it, and 'pwsh test/Set-LabToken.ps1 -LabToken <code> -CachingProxyService $proxyIp -BounceStatusService' finishes this step" }
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Set-LabToken.ps1') `
            -Arguments @($code, '-CachingProxyService', $proxyIp, '-BounceStatusService', '-NonInteractive'))
    })

    if ($createDefaultPool) {
        [void](Invoke-SetupStep -Name "Create the 'default' pool" -Action {
            Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
            Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
            $cfg  = Read-TestConfig -Path $ConfigPath
            $pool = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue
            if (-not $pool -or -not $pool.LocalPath) { throw 'pool storage has no localPath, so the intent store has nowhere to live' }
            # The WRITABLE local path through the mount. The http:// URL apache
            # serves is read-only by design and push-fails; without an explicit
            # writable URL New-Pool exits "No intent store URL".
            $script:intentGitUrl = Join-Path $pool.LocalPath 'pool-intent.git'
            [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'New-Pool.ps1') `
                -Arguments @('-PoolId', 'default', '-IntentGitUrl', $script:intentGitUrl))
        })

        [void](Invoke-SetupStep -Name 'Validate the pool intent store' -Action {
            if (-not $intentGitUrl) { throw 'no intent store URL was resolved' }
            [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Test-PoolIntent.ps1') -Arguments @('-IntentGitUrl', $intentGitUrl))
        })
    } else {
        $Script:Skipped.Add("The 'default' pool (not requested)")
    }
}

# --- REGION: -WhatIf stops here
if ($WhatIfPreference) {
    Write-Information ''
    Write-Information "Planned tasks for a $setupType setup on $HostFolderName :"
    foreach ($p in $Script:Plan) { Write-Information "  $p" }
    Write-Information ''
    Write-Information 'Nothing was changed (-WhatIf).'
    exit 0
}

# --- REGION: write the answer file this run used
$answerOut = Join-Path $RepoRoot "install/setup.answers.$setupType.yml"
if (-not $AnswerFile) {
    try {
        $doc = [ordered]@{
            setup = [ordered]@{ type = $setupType; runTests = $runTests; projectUrl = "$projectUrl" }
            storage = [ordered]@{ kind = $storageKind; localRoot = "$storageLocalRoot"; networkPath = "$storageNetworkPath"; networkUser = "$storageNetworkUser"; onFailure = $storageOnFailure }
        }
        if ($isLab) { $doc['lab'] = [ordered]@{ name = $labName; createDefaultPool = $createDefaultPool } }
        Import-YamlModule
        ConvertTo-Yaml $doc | Set-Content -LiteralPath $answerOut -Encoding utf8
        Write-Information ''
        Write-Information "Answers written to $answerOut -- pass it with -AnswerFile to set up the next machine the same way."
    } catch {
        Write-Verbose "could not write the answer file: $($_.Exception.Message)"
    }
}

# --- REGION: report
Write-SetupReport

# A non-critical step that failed still leaves the run here. Saying "ready" and
# exiting 0 over a Failed list is the same defect this whole feature exists to
# prevent -- green while broken -- and a CI caller reading only the exit code
# would never learn otherwise. So the banner and the exit code both tell the
# truth, and the run still reports everything it DID manage.
$hadFailures = ($Script:Failed.Count -gt 0)
Write-Information ''
if ($hadFailures) {
    Write-Warning "$($Script:Failed.Count) step(s) failed -- this machine is NOT fully set up. The Failed list above names each one."
    Write-Information 'Fix what it names and re-run this script: completed steps detect themselves and are skipped.'
}

if ($isLab) {
    Write-Information $(if ($hadFailures) { "Lab `"$labName`" is INCOMPLETE -- see the failures above." } else { "Lab `"$labName`" is ready. This machine is the lab beacon." })
    if ($proxyIp) {
        Write-Information ''
        Write-Information 'To join another machine: read the Lab token tile on the dashboard'
        Write-Information "  http://${proxyIp}:3000"
        Write-Information 'then run THERE (the code rotates every minute, so read it at the time):'
        Write-Information "  pwsh test/Set-LabToken.ps1 -CachingProxyService $proxyIp -LabToken <code from the tile>"
    }
    if ($storageKind -eq 'local') {
        Write-Information ''
        Write-Information 'This lab uses LOCAL shares on this machine. That is a real lab others can join,'
        Write-Information 'with two consequences worth knowing:'
        Write-Information '  - this machine is now the single point of failure for the pool storage;'
        Write-Information "  - 'ypool-nas' and 'ystash-nas' map to loopback here, so each joining host needs"
        Write-Information '    a hosts-file entry pointing those names at this machine, plus the share credential.'
        Write-Information 'Moving to a NAS later is a re-run of the storage step, not a rebuild.'
    }
    Write-Information ''
    Write-Information 'The auto-enrolment sweep is NOT on. Two steps turn it on when you want it:'
    Write-Information '  1. add autoEnrollment: { enabled: true, targetPoolId: default } to pools.yml in the intent store'
    Write-Information '  2. start the pool-control daemon with --auto-enrol'
    Write-Information "Until (1) is written, the 'target pool carries no test-set' guard is not armed for"
    Write-Information "a pool merely NAMED default -- the guard binds to autoEnrollment.targetPoolId."
} else {
    Write-Information $(if ($hadFailures) { 'Standalone host is INCOMPLETE -- see the failures above.' } else { 'Standalone host is ready.' })
    if (-not $hadFailures) {
        Write-Information ''
        Write-Information 'Next:'
        Write-Information '  pwsh test/Invoke-TestRunner.ps1'
    }
}
Write-Information ''

# The config gate is deliberately non-critical -- a validation failure should not
# throw away a proxy VM that came up correctly -- but it must not be reported as
# success either.
exit $(if ($hadFailures) { 1 } else { 0 })

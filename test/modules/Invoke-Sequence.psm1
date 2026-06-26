<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456770
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

$InformationPreference = 'Continue'
$ProgressPreference = 'Continue'

# Inherit logLevel from the parent process via $env:YURUNA_LOG_LEVEL.
# Child pwsh processes don't inherit PowerShell preference variables, so
# the env var is the only way to propagate. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'Test.LogLevel.psm1') -Global -Force
Use-LogLevelFromEnv

# Shared, cross-module sequence failure-state. The verb Handlers below and
# the SSH/OCR handlers in Test.SequenceHandler all read and write the SAME
# slots; binding $script:Fail to the one $global:-anchored store (a
# scriptblock's $script: otherwise resolves to its own defining module) is
# what makes that work. See Test.SequenceFailureState.psm1.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceFailureState.psm1') -Global -Force
$script:Fail = Get-SequenceFailureState

# OCR-tolerant matching (Get-OCRNormalized / Test-OCRMatch / Test-CombinedOcrMatch)
# lives in its own module so Wait-ForText here and sshWaitReady in
# Test.SequenceHandler reach the SAME matcher through one export.
Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1') -Global -Force

# Variable substitution (Expand-Variable / ${ext:...} expansion) lives in its
# own module. The -Global import is load-bearing: the engine captures
# ${function:Expand-Variable} into each step's Context for the verb Handlers,
# and that ref is $null unless the defining module is imported here.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceVariable.psm1') -Global -Force

# Sequence-file reading + gui/ssh search-path resolution. -Global so the
# engine's own callers (Invoke-SequenceByName, Invoke-Sequence) and the
# external importers (Test.SequencePlanner / Test.SequenceRunner / Test-Sequence)
# resolve the moved functions transitively. Get-SequenceMode there reads the
# keystroke mechanism from $env:YURUNA_KEYSTROKE_MECHANISM, mirrored below.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceResolve.psm1') -Global -Force

# ── Wire the host driver ─────────────────────────────────────────────────────
# Invoke-Sequence's body and Wait-ForText / Invoke-TapOn call
# contract functions (Get-VMScreenshot, Restart-VMConsole) that live in
# Yuruna.Host. When this module loads inside a child pwsh process spawned
# by Test.Start-GuestOS / Test.Start-GuestWorkload, the child has no other path
# to Yuruna.Host; calling Initialize-YurunaHost here guarantees the
# contract is resolvable from every sequence-engine call site. Idempotent
# in the parent runner where Yuruna.Host is already loaded -- Get-Module
# short-circuits the re-load if the module is already imported.
try {
    $repoRoot      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $testHostMod   = Join-Path $repoRoot 'test/modules/Test.HostContract.psm1'
    if (Test-Path $testHostMod) {
        Import-Module $testHostMod -Global -DisableNameChecking
        if (Get-Command Initialize-YurunaHost -ErrorAction SilentlyContinue) {
            [void](Initialize-YurunaHost -RepoRoot $repoRoot)
        }
    }
} catch {
    Write-Warning "Invoke-Sequence: Initialize-YurunaHost failed at module load -- contract calls (Restart-VMConsole, Get-VMScreenshot) will fail. Detail: $($_.Exception.Message)"
}

# ── Load global defaults from test.config.yml ──────────────────────────────
# The config file lives one level up from this module (test/test.config.yml).
$script:DefaultCharDelayMs      = 20
$script:DefaultVncPort          = 5900
$script:DefaultKeystrokeMechanism = "GUI"
# Independence default: under keystrokeMechanism=SSH, a missing ssh/ sequence is
# a hard error, NOT a silent run on the gui/ (OCR) sibling. Set
# vmCommunication.allowGuiFallback=true to opt back into the legacy degrade-to-GUI
# behavior. Keeps the SSH and GUI mechanisms independent by default.
$script:AllowGuiFallback        = $false
# Default poll interval for wait-style actions (waitForText, passwdPrompt,
# fetchAndExecute, ...). A step's own `pollSeconds` overrides this; when the
# step omits it, this global value (vmCommunication.pollSeconds) is used.
# Each waitForText iteration already pays a screenshot + OCR pass (200-1000 ms)
# before sleeping; the sleep dominates total iteration cost, so trimming it
# directly trims success-path lag.
$script:DefaultPollSeconds      = 3
# Default timeout for wait-style actions (waitForText, passwdPrompt,
# fetchAndExecute, sshExec, sshWaitReady, ...). A step's own `timeoutSeconds`
# overrides this; otherwise this global value (vmCommunication.timeoutSeconds)
# is used.
$script:DefaultTimeoutSeconds   = 180
# Ring-buffer depth for raw pre-OCR screen captures kept per VM (Wait-ForText).
# On guest success the buffer dir is deleted; on failure the whole sequence is
# preserved so the failure-screenshot link can point at the run-up to the bug.
$script:DefaultScreenHistorySize = 5

# Exponential-backoff helper for filesystem-state poll loops is
# centralised in Test.Backoff.psm1 (Get-PollDelay) so a tuning change
# lands once. Imported with -Global by Test.Prelude's module sets,
# so callers in this file resolve the function via the global scope.

# ── Progress wrapper ─────────────────────────────────────────────────────────
# Invoke-Sequence runs inline in the runner's interactive host now (the cycle
# planner dispatches Invoke-SequenceByName directly from Test.Start-GuestOS /
# Test.Start-GuestWorkload -- no child pwsh in the path), so Write-Progress works
# natively. This wrapper keeps the call sites uniform with the previous
# child-pwsh era when a stdout marker protocol was also needed.
function Write-ProgressTick {
    <#
    .SYNOPSIS
        Uniform Write-Progress wrapper for sequence-step heartbeats.
    .DESCRIPTION
        Forwards to Write-Progress with a -Completed shortcut. Kept as a
        thin wrapper so call sites stay uniform across hosts and across
        the inline / former-child-spawn runtimes.
    #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Completed
    )
    if ($Completed) {
        Write-Progress -Activity $Activity -Completed
    } else {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    }
}
Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1') -Global -Force
# Test.Transport carries the per-host keystroke / mouse / VNC backends.
# -Global so the per-host Test.HostIO.<Host>.psm1 modules (loaded below)
# resolve Send-KeyHyperV / Send-KeyVNC / Send-KeyUTM / Send-KeyKvm /
# Send-TextHyperV / Send-TextVNC / Send-TextUTM / Send-TextKvm /
# Send-ClickHyperV / Send-ClickUtm by bare name. See docs/host-io.md.
Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Global -Force
# Per-host I/O wiring: each module's load-time Register-HostIOProvider
# calls populate the Test.HostIO registry that the Send-Key / Send-Text /
# Send-Click dispatchers below delegate to via Invoke-HostIOAction.
# Adding a new host adds a parallel Test.HostIO.<NewHost>.psm1 plus one
# Import-Module line here.
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.HyperV.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.Utm.psm1')    -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.Kvm.psm1')    -Global -Force
# Built-in verb Handlers (Register-SequenceAction blocks) live in
# Test.SequenceHandler.psm1. retry and recoverFromSnapshot still sit in
# this module, but no longer because of scope: the failure slots they
# coordinate now live in the shared Test.SequenceFailureState store
# ($script:Fail), reachable from either module. They remain here pending
# their own migration; the rest of the verb catalog is local to
# Test.SequenceHandler so adding a verb does not collide with engine edits.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1') -Global -Force
$_configPath = Join-Path (Split-Path -Parent $PSScriptRoot) "test.config.yml"
$_cfg = Read-TestConfig -Path $_configPath
if ($_cfg) {
    # test.config.yml keys live under the `vmCommunication` node
    # (`characterDelayMs`, `vncPort`, `keystrokeMechanism`,
    # `pollSeconds`, `timeoutSeconds`); per-step YAML in sequences/
    # still uses `charDelayMs` / `pollSeconds` / `timeoutSeconds` to
    # override these defaults for an individual step (see actions.yml).
    $_comm = $_cfg.vmCommunication
    if ($_comm.characterDelayMs)   { $script:DefaultCharDelayMs        = [int]$_comm.characterDelayMs }
    if ($_comm.vncPort)            { $script:DefaultVncPort            = [int]$_comm.vncPort }
    if ($_comm.keystrokeMechanism) { $script:DefaultKeystrokeMechanism = [string]$_comm.keystrokeMechanism }
    if ($null -ne $_comm.allowGuiFallback) { $script:AllowGuiFallback  = [bool]$_comm.allowGuiFallback }
    if ($_comm.pollSeconds)        { $script:DefaultPollSeconds        = [int]$_comm.pollSeconds }
    if ($_comm.timeoutSeconds)     { $script:DefaultTimeoutSeconds     = [int]$_comm.timeoutSeconds }
    # 0 disables the ring buffer; we still accept it as a configured value.
    if ($null -ne $_cfg.screenHistorySize) { $script:DefaultScreenHistorySize = [int]$_cfg.screenHistorySize }
}
# Mirror the keystroke mechanism into an env var so Get-SequenceMode in
# Test.SequenceResolve (which no longer shares this module's $script: scope)
# resolves gui-vs-ssh identically -- same cross-process pattern as
# YURUNA_LOG_LEVEL. The engine keeps $script:DefaultKeystrokeMechanism for its
# own direct read in Invoke-Sequence.
$env:YURUNA_KEYSTROKE_MECHANISM = $script:DefaultKeystrokeMechanism
# Mirror the gui-fallback policy too, so Get-SequenceMode's sibling resolver in
# Test.SequenceResolve (foreign $script: scope) gates the gui/ fallback on the
# same value the engine reads directly below.
$env:YURUNA_ALLOW_GUI_FALLBACK = if ($script:AllowGuiFallback) { 'true' } else { 'false' }
Remove-Variable -Name _configPath, _cfg, _comm -ErrorAction SilentlyContinue

# Per-guest keystroke mechanism. The pool runner switches GUI<->SSH per
# guest (test-set perGuestOverrides.keystrokeMechanism). Both reads of the
# mechanism -- the engine's direct $script:DefaultKeystrokeMechanism (path
# resolution below) AND Get-SequenceMode's $env:YURUNA_KEYSTROKE_MECHANISM (the
# foreign-scope mirror) -- MUST move together, so the setter writes both. The
# getter returns the live value so the caller can capture the cycle baseline and
# restore it between guests. No-op on the single-host path (never called).
function Get-DefaultKeystrokeMechanism {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string]$script:DefaultKeystrokeMechanism
}

function Set-EngineKeystrokeMechanism {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets a transient per-guest dispatch knob (engine var + env mirror); no -WhatIf semantics for an in-loop mode switch.')]
    param([Parameter(Mandatory)][string]$Value)
    $script:DefaultKeystrokeMechanism = $Value
    $env:YURUNA_KEYSTROKE_MECHANISM   = $Value
}

# Shared engine for executing interaction sequences from YAML files.
# Action catalog, variable substitution, and on-failure artifact layout
# are documented in docs/test-sequences.md (the operator-facing spec) --
# do not duplicate them here. This module is the executable definition;
# the Markdown is the contract.

function Invoke-HostIODispatch {
    # Shared try/catch + Write-Warning + return-$false envelope for the public
    # Send-Key / Send-Text / Send-Click dispatchers, so the failure shape cannot
    # drift between the three and there is one place to add cross-cutting
    # behavior (e.g. retry-on-transient) later. The public wrapper names and
    # signatures stay exactly as-is -- the Yuruna.Host / Invoke-Sequence
    # qualified-call discipline depends on them.
    param([string]$HostType, [string]$Action, [hashtable]$Arguments)
    try {
        return (Invoke-HostIOAction -HostType $HostType -Action $Action -Arguments $Arguments)
    } catch {
        Write-Warning "${Action}: $($_.Exception.Message)"
        return $false
    }
}

function Send-Key {
<#
.SYNOPSIS
    Host-aware dispatcher for sending a named key (e.g. Enter, Tab) to
    the guest VM's GUI keyboard input channel.
.DESCRIPTION
    Dispatches via the Test.HostIO registry. Per-host backends are
    registered at module-load time below (search for
    Register-HostIOProvider 'Send-Key'). Yuruna.Host's Send-Key contract
    routes here so each host driver doesn't import the platform-specific
    helpers itself.
#>
    param([string]$HostType, [string]$VMName, [string]$KeyName)
    return (Invoke-HostIODispatch -HostType $HostType -Action 'Send-Key' -Arguments @{ VMName=$VMName; KeyName=$KeyName })
}

# ── Action: type / typeAndEnter ──────────────────────────────────────────────


function Send-Text {
<#
.SYNOPSIS
    Host-aware dispatcher for typing a text string into the guest VM's
    GUI keyboard input channel, char by char with optional inter-key delay.
.DESCRIPTION
    Routes by HostType to the matching backend (Send-TextHyperV,
    Send-TextVNC/Send-TextUTM, Send-TextKvm). Called by the Yuruna.Host
    Send-Text contract so the host driver does not need to import the
    host-specific helpers itself.
#>
    param(
        [string]$HostType,
        [string]$VMName,
        [string]$Text,
        [int]$CharDelayMs = $script:DefaultCharDelayMs,
        # ShellEscape is only honored by Send-TextUTM (rewrites Text as
        # a bash decode wrapper for hosts that can't deliver synthetic
        # Shift reliably). Hyper-V's PS/2 controller and KVM's `virsh
        # send-key` paths deliver Shift correctly without needing the
        # wrapper, so this switch is a no-op there.
        [switch]$ShellEscape
    )
    return (Invoke-HostIODispatch -HostType $HostType -Action 'Send-Text' -Arguments @{ VMName=$VMName; Text=$Text; CharDelayMs=$CharDelayMs; ShellEscape=[bool]$ShellEscape })
}


# ── Action: tapOn — OCR-located mouse click ─────────────────────────────────
#
# Button-focus navigation via Tab keystrokes is brittle: initial focus depends
# on splash animation state, async-loaded widgets, and installer redesigns,
# so the "correct" Tab count drifts. tapOn sidesteps focus
# entirely — it OCRs the VM screen, locates the button's bounding box, and
# synthesizes a mouse click at that box's centre.
#
# Coordinate contract: the captured image and the click target share the
# same pixel space. On Hyper-V we use PrintWindow on the vmconnect client
# area so image (x,y) == vmconnect client (x,y), and ClientToScreen maps
# it to a SetCursorPos + mouse_event sequence.


function Send-Click {
<#
.SYNOPSIS
    Host-aware dispatcher for sending a mouse click at the given pixel
    coordinate to the guest VM's GUI input channel.
.DESCRIPTION
    Routes by HostType to the matching backend (Send-ClickHyperV,
    Send-ClickUtm). The Capture hashtable carries the UTM window
    origin and scale produced by Get-UtmWindowScreenshot; Hyper-V
    ignores it and resolves the window via ClientToScreen at click
    time. Called by the Yuruna.Host Send-Click contract.
#>
    param(
        [string]$HostType,
        [string]$VMName,
        [int]$X,
        [int]$Y,
        # UTM branch reads OriginX / OriginY / Scale from this hashtable
        # (produced by Get-UtmWindowScreenshot). Hyper-V ignores it and
        # resolves the window via ClientToScreen at click time.
        [hashtable]$Capture = $null
    )
    return (Invoke-HostIODispatch -HostType $HostType -Action 'Send-Click' -Arguments @{ VMName=$VMName; X=$X; Y=$Y; Capture=$Capture })
}

function Find-TextLocation {
    param(
        [Parameter(Mandatory)] [string]$ImagePath,
        [Parameter(Mandatory)] [string]$Label
    )
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    # -Global keeps Test.Tesseract in the global session; a bare -Force
    # re-import would evict the already-global copy into this module's
    # private scope and break Tesseract callers elsewhere (legacy
    # module-eviction regression class).
    Import-Module (Join-Path $modulesDir "Test.Tesseract.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false

    try {
        $boxes = Get-TesseractWordBox -ImagePath $ImagePath
    } catch {
        Write-Warning "Tesseract TSV OCR failed: $_"
        return $null
    }
    if (-not $boxes -or $boxes.Count -eq 0) { return $null }

    $tokens = @(($Label.Trim() -split '\s+') | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return $null }

    for ($i = 0; $i -le ($boxes.Count - $tokens.Count); $i++) {
        $match = $true
        for ($j = 0; $j -lt $tokens.Count; $j++) {
            # -like is case-insensitive in PowerShell; substring match
            # tolerates partial OCR ("Install." vs "Install").
            if ($boxes[$i + $j].text -notlike "*$($tokens[$j])*") {
                $match = $false
                break
            }
        }
        if (-not $match) { continue }

        # Multi-word label: require words on roughly the same line so we
        # don't stitch together a token from a header and another from a
        # footer that happens to share vocabulary.
        if ($tokens.Count -gt 1) {
            $firstY = $boxes[$i].y
            $firstH = [math]::Max(1, $boxes[$i].h)
            $sameLine = $true
            for ($j = 1; $j -lt $tokens.Count; $j++) {
                $yDiff = [math]::Abs($boxes[$i + $j].y - $firstY)
                if ($yDiff -gt ($firstH / 2)) { $sameLine = $false; break }
            }
            if (-not $sameLine) { continue }
        }

        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = 0; $maxY = 0
        for ($j = 0; $j -lt $tokens.Count; $j++) {
            $b = $boxes[$i + $j]
            if ($b.x -lt $minX) { $minX = $b.x }
            if ($b.y -lt $minY) { $minY = $b.y }
            if (($b.x + $b.w) -gt $maxX) { $maxX = $b.x + $b.w }
            if (($b.y + $b.h) -gt $maxY) { $maxY = $b.y + $b.h }
        }
        return @{
            x       = $minX
            y       = $minY
            w       = $maxX - $minX
            h       = $maxY - $minY
            centerX = [int](($minX + $maxX) / 2)
            centerY = [int](($minY + $maxY) / 2)
            text    = ($tokens -join ' ')
        }
    }
    return $null
}

<#
.SYNOPSIS
    Copies a screenshot to $DestPath with a red X drawn at ($X, $Y).
.DESCRIPTION
    The X marks the pixel the click was dispatched to, so the operator
    can eyeball whether OCR coordinates landed on the intended button.
    A white halo stroke underneath keeps the marker readable on both
    dark and light installer backgrounds.
#>
function Save-ScreenshotWithClickMarker {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [int]$Size = 20
    )
    # System.Drawing.Common is Windows-only in .NET 6+; on macOS/Linux the
    # GDI+ type initializer throws. Skip the marker draw and preserve the
    # diagnostic by logging the click coordinates alongside the plain copy.
    # ($IsWindows is $null on Windows PowerShell 5.1, which leaves GDI+ enabled.)
    if ($IsWindows -eq $false) {
        Copy-Item -Path $SourcePath -Destination $DestPath -Force -ErrorAction SilentlyContinue
        Write-Debug "      Save-ScreenshotWithClickMarker: GDI+ unavailable on $($PSVersionTable.Platform); copied to $DestPath (click would be at X=$X Y=$Y)"
        return $false
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        # GDI+ locks the source file for the lifetime of the bitmap, so we
        # clone into an independent in-memory bitmap and release the source
        # before saving — otherwise SourcePath stays locked until GC runs.
        $src  = [System.Drawing.Bitmap]::FromFile($SourcePath)
        $copy = New-Object System.Drawing.Bitmap $src
        $src.Dispose()

        $g      = [System.Drawing.Graphics]::FromImage($copy)
        $halo   = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 5)
        $marker = New-Object System.Drawing.Pen([System.Drawing.Color]::Red,   3)
        $g.DrawLine($halo,   $X - $Size, $Y - $Size, $X + $Size, $Y + $Size)
        $g.DrawLine($halo,   $X - $Size, $Y + $Size, $X + $Size, $Y - $Size)
        $g.DrawLine($marker, $X - $Size, $Y - $Size, $X + $Size, $Y + $Size)
        $g.DrawLine($marker, $X - $Size, $Y + $Size, $X + $Size, $Y - $Size)
        $g.Dispose(); $halo.Dispose(); $marker.Dispose()

        $copy.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $copy.Dispose()
        return $true
    } catch {
        Write-Warning "Save-ScreenshotWithClickMarker failed: $_"
        # Fall back to plain copy so the operator still has a screenshot.
        Copy-Item -Path $SourcePath -Destination $DestPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

<#
.SYNOPSIS
    Waits for a labeled button to appear on the VM screen and clicks it.
.DESCRIPTION
    Loops: capture the VM window at the host's coordinate space, OCR for
    the label, and if found, click at the label's centre. Falls back to
    returning $false after TimeoutSeconds if the button never resolves
    (caller can then decide to send Tab+Enter as a legacy fallback).
.OUTPUTS
    $true on click dispatched, $false on timeout / unsupported host.
#>
function Invoke-TapOn {
    param(
        [string]$HostType,
        [string]$VMName,
        [string[]]$Label,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 3,
        [int]$OffsetX = 0,
        [int]$OffsetY = 0
    )
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    # -Global: a nested -Force without -Global evicts Test.YurunaDir from
    # the parent script's session state, breaking later top-level calls.
    Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false

    $logDir = Initialize-YurunaLogDir
    $capturePath = Join-Path $logDir "clickbutton_${VMName}.png"
    # Avoid '|' as the join separator — Write-ProgressTick's marker uses '|'
    # as its field delimiter, and embedding one here would shift parsing on the
    # parent side. Write-ProgressTick sanitizes defensively, but keep the
    # display clean at the source too.
    $labelDisplay = $Label -join "' / '"
    # Wall-clock deadline. See the matching commentary in Wait-ForText for
    # why this is NOT an iteration counter -- on a slow Hyper-V host a
    # configured timeoutSeconds: 60 used to expand to 3-5 minutes of
    # wall-clock when each iteration paid full screenshot + OCR cost on
    # top of the $PollSeconds sleep.
    $startUtc    = [DateTime]::UtcNow
    $deadlineUtc = $startUtc.AddSeconds($TimeoutSeconds)
    $elapsed     = 0

    try {
        while ([DateTime]::UtcNow -lt $deadlineUtc) {
            $elapsed = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "tapOn" -Status "'$labelDisplay' (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct

            Remove-Item $capturePath -Force -ErrorAction SilentlyContinue
            $capture = Get-VMScreenshot -VMName $VMName -Source window -OutFile $capturePath
            if (-not $capture) {
                Write-Debug "      Window capture unavailable — retrying"
                Start-Sleep -Seconds $PollSeconds
                continue
            }

            foreach ($candidate in $Label) {
                $coord = Find-TextLocation -ImagePath $capture.ImagePath -Label $candidate
                if ($coord) {
                    $clickX = $coord.centerX + $OffsetX
                    $clickY = $coord.centerY + $OffsetY
                    Write-Debug "      Found '$candidate' at ($($coord.x),$($coord.y)) $($coord.w)x$($coord.h) → click ($clickX, $clickY)"
                    # logLevel=Debug: preserve a per-detection screenshot under
                    # a UTC timestamp so the operator can correlate a stuck
                    # installer with exactly what OCR saw and where we aimed
                    # the click.
                    if ($env:YURUNA_LOG_LEVEL -eq 'Debug') {
                        $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
                        $stampedPath = Join-Path $logDir "tapOn.$stamp.png"
                        Save-ScreenshotWithClickMarker -SourcePath $capture.ImagePath -DestPath $stampedPath -X $clickX -Y $clickY | Out-Null
                        Write-Debug "      logLevel=Debug: saved detection screenshot $stampedPath"
                        Write-Debug "      logLevel=Debug: button '$candidate' box=($($coord.x),$($coord.y)) size=$($coord.w)x$($coord.h) click=($clickX, $clickY) offset=($OffsetX, $OffsetY) image=$($capture.Width)x$($capture.Height)"
                    }
                    $ok = Send-Click -HostType $HostType -VMName $VMName -X $clickX -Y $clickY -Capture $capture
                    # Preserve a diagnostic capture so a failed click can be inspected;
                    # the X marker shows where the click actually landed in image space.
                    $debugCopy = Join-Path $logDir "clickbutton_${VMName}_last.png"
                    Save-ScreenshotWithClickMarker -SourcePath $capture.ImagePath -DestPath $debugCopy -X $clickX -Y $clickY | Out-Null
                    return $ok
                }
            }

            Start-Sleep -Seconds $PollSeconds
        }

        # Timeout — preserve the final screenshot so the operator can see
        # what the OCR was looking at.
        $failScreenPath = Join-Path $logDir "failure_clickbutton_${VMName}.png"
        if (Test-Path $capturePath) {
            Copy-Item -Path $capturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure screenshot saved: $failScreenPath"
        }
        Write-Warning "Button with label '$labelDisplay' not located within ${TimeoutSeconds}s"
        return $false
    } finally {
        Remove-Item $capturePath -Force -ErrorAction SilentlyContinue
        Write-ProgressTick -Activity "tapOn" -Completed
    }
}

# Persist this frame's OCR output as raw_${stamp}.txt next to the
# raw_${stamp}.png it was extracted from. The text file is what the
# matcher actually saw — invaluable for diagnosing "should have matched"
# regressions, since the ring-buffer .png alone leaves the reader to
# re-OCR the image to figure out why the pattern didn't fire.
#
# AllowEmptyCollection: a [Parameter(Mandatory)] typed-collection param
# rejects empty input with the misleading "Cannot bind argument ...
# because it is an empty string" error. The empty case happens when
# Test-CombinedOcrMatch returns no EngineResults (no providers ran on
# this frame); skipping the write is correct — an empty sidecar would
# misrepresent "no engine ran" as "engines ran and saw nothing."
#
# AllowEmptyString: PowerShell's Mandatory binder enumerates a typed
# List[string] and validates each element against the implicit non-
# empty-string check, so a list containing the trailing '' separators
# the callers add between engine sections fails with the same
# "empty string" message. AllowEmptyString lifts that per-element
# check; AllowEmptyCollection lifts the whole-list one.
function Save-OcrSidecar {
    param(
        [Parameter(Mandatory)] [string]$ScreenshotPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$Sections
    )
    if ($Sections.Count -eq 0) { return }
    $ocrPath = [System.IO.Path]::ChangeExtension($ScreenshotPath, '.txt')
    Set-Content -Path $ocrPath -Value ($Sections -join "`n") -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ── Action: waitForText ──────────────────────────────────────────────────────

function Get-OcrDegradationGrace {
    <#
    .SYNOPSIS
        How many seconds of deadline grace Wait-ForText grants after a
        capture-feed self-heal, so a *recovering* feed gets a fair window to
        deliver the pattern instead of timing out mid-recovery (the false
        ocr_timeout). Pure + bounded: returns 0 once the per-wait grace cap is
        exhausted, so a genuinely dead feed still times out.
    .PARAMETER Action
        'console-restart' (frozen-feed reconnect) or 'ring-repair' (no-text
        VNC-handle reset). A console restart needs a full fresh frame-delivery
        window to prove the relaunched viewer is live; a ring repair is lighter,
        so half the window suffices.
    .PARAMETER AlreadyGrantedSeconds
        Grace already granted in this wait (the running total).
    .PARAMETER MaxGrantSeconds
        Per-wait cap on total grace (keeps a dead feed bounded).
    .PARAMETER BaseWindowSeconds
        The frozen-feed detection window (the natural full grace unit).
    .OUTPUTS
        [int] seconds to add to the deadline (>= 0).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][ValidateSet('console-restart','ring-repair')][string]$Action,
        [Parameter(Mandatory)][int]$AlreadyGrantedSeconds,
        [Parameter(Mandatory)][int]$MaxGrantSeconds,
        [Parameter(Mandatory)][int]$BaseWindowSeconds
    )
    if ($MaxGrantSeconds -le 0 -or $AlreadyGrantedSeconds -ge $MaxGrantSeconds) { return 0 }
    if ($BaseWindowSeconds -lt 0) { $BaseWindowSeconds = 0 }
    $want = if ($Action -eq 'console-restart') { $BaseWindowSeconds } else { [int][math]::Ceiling($BaseWindowSeconds / 2.0) }
    $remaining = $MaxGrantSeconds - $AlreadyGrantedSeconds
    return [int][math]::Max(0, [math]::Min($want, $remaining))
}

function Wait-ForText {
    <#
    .SYNOPSIS
        Poll the guest framebuffer via OCR until $Pattern matches or
        $TimeoutSeconds elapses.
    .DESCRIPTION
        Drives the waitForText sequence action: takes a screenshot,
        OCRs it, fuzzy-matches against $Pattern, and either returns
        $true on a match or sleeps $PollSeconds before retrying. Also
        evaluates $FailurePattern entries each poll so a known crash
        screen aborts the wait immediately instead of consuming the
        full timeout budget.
    .OUTPUTS
        [bool] $true on positive match; $false on timeout or anti-pattern hit.
    #>
    param(
        # HostType is accepted but ignored at the dispatch level: the
        # host driver's own Get-VMScreenshot resolves the per-host
        # backend internally. We accept it for caller-site uniformity
        # and surface it in the debug stream for cross-host triage.
        [string]$HostType,
        [string]$VMName,
        [string[]]$Pattern,
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 3,
        [bool]$FreshMatch = $false,
        [int]$FreshMatchTailLines = 12,
        # Anti-patterns: if ANY of these fuzzy-matches on screen OCR,
        # abort the wait immediately and return $false. Canonical use
        # case is subiquity's "install_fail.crash" / "An error occurred.
        # Press enter to start a shell" output -- at that point the
        # positive pattern (e.g. "Not listed?" from the GDM login screen)
        # is never going to appear, so polling until $TimeoutSeconds
        # wastes up to an hour before the runner gets a misleading
        # "pattern not found" failure. On match this function also sets
        # the shared cross-module WaitForTextMatchedFailurePattern signal so
        # the caller's failure-label builder can surface *which* anti-
        # pattern fired, producing a banner like
        #   waitForAndEnter: "Not listed?" -- matched failurePattern "install_fail.crash"
        # instead of the opaque timeout message.
        [string[]]$FailurePattern = @()
    )
    # Reset the cross-function signals so a prior call can't leak into the next
    # Wait-ForText invocation. Like WaitForTextMatchedFailurePattern, the cause
    # slots are populated ONLY at the failure return points below (not at entry),
    # so a SUCCESSFUL wait leaves them empty and cannot leak its sought-pattern
    # set into a later non-wait step's failure record.
    $script:Fail.WaitForTextMatchedFailurePattern = $null
    $script:Fail.WaitForTextOcrTail        = $null
    $script:Fail.WaitForTextPatternsSought = [string[]]@()
    if ($HostType) { Write-Debug "Wait-ForText: -HostType '$HostType' is informational; Yuruna.Host dispatches Get-VMScreenshot internally." }

    # Display label uses first pattern for log messages
    $patternLabel = $Pattern[0]
    # Wall-clock deadline -- NOT an iteration counter. Earlier revisions
    # tracked $elapsed by adding $PollSeconds each loop pass, which assumed
    # every iteration finished in $PollSeconds wall-clock. In practice each
    # iteration does a screenshot + tesseract OCR + sidecar write before
    # the Start-Sleep -Seconds $PollSeconds at the bottom -- on a busy
    # Hyper-V host that adds 5-25 s on top of the sleep, so a configured
    # timeoutSeconds: 1800 took 1-3 hours of wall-clock to expire (and
    # multiplied by retry maxAttempts could exceed half a day before
    # giving up). With a wall-clock deadline timeoutSeconds means exactly
    # what the operator configured.
    $startUtc    = [DateTime]::UtcNow
    $deadlineUtc = $startUtc.AddSeconds($TimeoutSeconds)
    $elapsed     = 0

    # Import required modules. Screenshot capture is via the Yuruna.Host
    # contract (Get-VMScreenshot) -- assumed already loaded by the caller's
    # Initialize-YurunaHost. OcrEngine stays in test/modules/ as a
    # cross-host helper. -Global is load-bearing: the poll loop below calls
    # Test-CombinedOcrMatch (Test.OcrMatch module), which resolves
    # Get-EnabledOcrProvider / Invoke-OcrProvider through the global session
    # state. A nested -Force WITHOUT -Global evicts Test.OcrEngine from
    # global (the module-eviction regression class,
    # feedback_module_force_import_evicts_global.md), so the very next
    # Test-CombinedOcrMatch call crashes with "Get-EnabledOcrProvider is not
    # recognized".
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.OcrEngine.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false

    # Log which OCR engines are active for this wait
    $enabledEngines = Get-EnabledOcrProvider
    $combineMode = Get-OcrCombineMode
    Write-Debug "      OCR engines: $($enabledEngines -join ', ') | combine: $combineMode"

    # Per-VM ring buffer of raw pre-OCR captures. Persists across multiple
    # Wait-ForText calls within a guest run so the failure path can surface
    # the run-up to the bug. Cleared at end-of-guest on success by the
    # runner; preserved on failure and copied alongside the failure log.
    # -Global on the -Force re-imports: a nested -Force without -Global
    # evicts the modules from the parent script's session state, so a
    # later top-level call to Get-CycleScreenDir (Invoke-TestInnerRunner.ps1
    # success branch, seen on macOS in-process runners) fails with
    # "term not recognized".
    Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.Log.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir     = Initialize-YurunaLogDir
    # Ring buffer lives INSIDE the cycle folder so a stuck/restarted
    # runner can't overwrite it -- the next cycle gets its own folder.
    # Falls back to $logDir/screens_<VM>/ when no cycle folder is set.
    $screensDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false
    $historySize = [int]$script:DefaultScreenHistorySize
    if ($historySize -lt 1) { $historySize = 1 }

    # Cross-poll fallback buffer for non-FreshMatch mode. A pattern can be split
    # at the OCR capture boundary between two ADJACENT frames (a line OCR'd half
    # in frame N, half in N+1). Keep only the last few frames' text, not the whole
    # growing history: the live frame is matched directly each poll, and once any
    # frame (or adjacent pair) matches the wait returns, so older frames are never
    # re-examined. A bounded ring keeps this O(1) per poll instead of the O(n^2)
    # a full-history rescan would cost over a 60-300 s loop.
    $recentFrameMax = 3
    $recentFrames   = [System.Collections.Generic.List[string]]::new()
    $lastOcrText = ''
    $lastCapturePath = $null
    # Bounded no-text self-heal: count consecutive polls where OCR finds no
    # text at all (a likely sign the capture feed is stale -- e.g. a dropped
    # VNC handle returning a frozen frame -- rather than the screen being
    # genuinely blank), and cap how many times we repair per wait.
    $noTextPolls = 0
    $ringRepairs = 0
    # Frozen-feed self-heal state (the poll loop's second repair path, below).
    # The no-text counter above only catches a BLANK capture; a feed that
    # froze on a frame still holding readable text slips past it. Track the
    # raw-frame hash and how long it has been unchanged so a stale viewer
    # surface can be forced to reconnect. Thresholds are wall-clock so they
    # don't drift with $PollSeconds.
    $lastFrameHash          = $null
    $frameUnchangedSinceUtc = $null
    $consoleRestarts        = 0
    $frozenFeedSeconds      = 45
    $maxConsoleRestarts     = 2
    # F6 degradation-trend: the two self-heals above are reactive at a fixed
    # threshold. Once the feed has proven flaky (a console restart fired), drop
    # the freeze threshold so the next stall is caught sooner -- acting on the
    # trend rather than re-waiting the full window. And grant the deadline a
    # bounded grace per self-heal so a feed that IS recovering isn't killed
    # mid-recovery by the original deadline (the false ocr_timeout); the cap
    # keeps a dead feed bounded. Each proactive action emits an F3 `degradation`
    # event so a degraded-but-passing wait is queryable, not silent.
    $deadlineGrantedSeconds  = 0
    $maxDeadlineGrantSeconds = [math]::Min([int]$TimeoutSeconds, 120)

    # Seed the ring-buffer queue once with anything already on disk from
    # earlier Wait-ForText calls in this guest run (the screensDir persists
    # across calls; see the ring-buffer note above). Subsequent iterations
    # append + dequeue in O(1) instead of re-enumerating the directory.
    $rawQueue = [System.Collections.Generic.Queue[string]]::new()
    Get-ChildItem -Path $screensDir -Filter 'raw_*.png' -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { $rawQueue.Enqueue($_.FullName) }

    try {
        while ([DateTime]::UtcNow -lt $deadlineUtc) {
            $elapsed = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            # PROGRESS-INLINE-TICK: reference impl lives in "waitForSeconds"
            $pct = [math]::Min(100, [math]::Round(($elapsed / [math]::Max($TimeoutSeconds,1)) * 100))
            Write-ProgressTick -Activity "waitForText" -Status "'$patternLabel' (${elapsed}s / ${TimeoutSeconds}s)" -PercentComplete $pct

            # Capture into the ring buffer with a millisecond-precise UTC name
            # so multiple Wait-ForText calls within the same guest produce a
            # contiguous, sortable sequence. [DateTime]::UtcNow is a static
            # property read; Get-Date pays cmdlet-binding overhead on every
            # poll iteration.
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $rawScreenPath = Join-Path $screensDir "raw_${stamp}.png"
            $captured = Get-VMScreenshot -VMName $VMName -OutFile $rawScreenPath
            if (-not $captured -or -not (Test-Path $rawScreenPath)) {
                Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            $lastCapturePath = $rawScreenPath

            # Trim ring buffer to the most recent $historySize entries.
            # Each raw_*.png has a sibling raw_*.txt holding that frame's
            # OCR output (per-engine sections, written further below).
            # Delete the .txt whenever we evict its .png so the two stay
            # in lockstep -- otherwise orphan .txt files accumulate.
            $rawQueue.Enqueue($rawScreenPath)
            while ($rawQueue.Count -gt $historySize) {
                $evict = $rawQueue.Dequeue()
                $txtSibling = [System.IO.Path]::ChangeExtension($evict, '.txt')
                Remove-Item -Path $evict -Force -ErrorAction SilentlyContinue
                if (Test-Path $txtSibling) { Remove-Item -Path $txtSibling -Force -ErrorAction SilentlyContinue }
            }

            # OCR is fed the raw capture as-is — no preprocessing. Earlier
            # revisions ran a vertical-line / grayscale / invert / contrast-
            # stretch / 2x-scale pipeline (and before that, a diff-against-
            # the-previous-frame stage that suppressed unchanged pixels);
            # both stages were dropped so every operating system delivers
            # the intact screenshot straight to the OCR engines and edge
            # cases the pipeline corrupted (anti-aliased serifs collapsing,
            # fresh text being suppressed when the surrounding pixels also
            # changed) stop biting. Tesseract / WinRT OCR / macOS Vision
            # all handle native-resolution color screenshots fine.
            if ($rawScreenPath -and (Test-Path $rawScreenPath)) {
                if ($FreshMatch) {
                    # ── FreshMatch mode: only check the last N lines ──
                    $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $Pattern -FreshMatchTailLines $FreshMatchTailLines

                    $ocrSections = [System.Collections.Generic.List[string]]::new()
                    foreach ($eName in $result.EngineResults.Keys) {
                        $er = $result.EngineResults[$eName]
                        $snippet = $er.Text.Length -le 120 ? $er.Text : ("..." + $er.Text.Substring($er.Text.Length - 120))
                        $status = $er.Matched ? "MATCH '$($er.MatchedPattern)'" : "no match"
                        Write-Verbose "      [$eName] $status | $snippet"
                        $ocrSections.Add("== $eName ($status) ==")
                        $ocrSections.Add($er.Text)
                        $ocrSections.Add('')
                    }
                    Save-OcrSidecar -ScreenshotPath $rawScreenPath -Sections $ocrSections

                    if ($result.AnyText) { $lastOcrText = $result.AnyText }

                    if ($result.Match) {
                        Write-Debug "      Text detected at end of screen (combine=$combineMode)"
                        return $true
                    }
                } else {
                    # ── Non-FreshMatch mode: accumulate text, check for pattern ──
                    $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $Pattern

                    $ocrSections = [System.Collections.Generic.List[string]]::new()
                    foreach ($eName in $result.EngineResults.Keys) {
                        $er = $result.EngineResults[$eName]
                        $snippet = $er.Text.Length -le 120 ? $er.Text : ("..." + $er.Text.Substring($er.Text.Length - 120))
                        $status = $er.Matched ? "MATCH '$($er.MatchedPattern)'" : "no match"
                        Write-Verbose "      [$eName] $status | $snippet"
                        $ocrSections.Add("== $eName ($status) ===")
                        $ocrSections.Add($er.Text)
                        $ocrSections.Add('')
                    }
                    Save-OcrSidecar -ScreenshotPath $rawScreenPath -Sections $ocrSections

                    if ($result.AnyText) {
                        $lastOcrText = $result.AnyText
                        $recentFrames.Add([string]$result.AnyText)
                        if ($recentFrames.Count -gt $recentFrameMax) { $recentFrames.RemoveAt(0) }
                    }

                    if ($result.Match) {
                        Write-Debug "      Text detected (combine=$combineMode)"
                        return $true
                    }

                    # Fallback: a pattern split across the boundary of two adjacent
                    # frames. Match the last few frames' join (not the whole growing
                    # history -- see the $recentFrames note above); the live frame
                    # already matched above, so this only catches a frame-straddling
                    # split.
                    $recentText = [string]::Join("`n", $recentFrames)
                    foreach ($p in $Pattern) {
                        if (Test-OCRMatch -Text $recentText -Pattern $p) {
                            Write-Debug "      Text detected across recent frames: '$p'"
                            return $true
                        }
                    }
                }

                # Bounded self-heal (arms Test.VncProvider / Test.ScreenshotProvider):
                # several consecutive no-text polls suggest the capture feed went
                # stale. Force the next Get-VMScreenshot to re-handshake by clearing
                # the cached VNC handle, and best-effort clear the screenshot ring.
                # Capped per wait so a genuinely blank screen still times out
                # normally rather than thrashing the transport.
                if ($result.AnyText) {
                    $noTextPolls = 0
                } else {
                    $noTextPolls++
                    if ($noTextPolls -ge 4 -and $ringRepairs -lt 2) {
                        $noTextPolls = 0
                        $ringRepairs++
                        Write-Verbose "      Wait-ForText: no OCR text for 4 polls; self-heal repair $ringRepairs/2 (clear VNC handle + screenshot ring)."
                        if (Get-Command Repair-VncConnection -ErrorAction SilentlyContinue) { [void](Repair-VncConnection -VMName $VMName -HostType $HostType -Confirm:$false) }
                        if (Get-Command Repair-ScreenshotRing -ErrorAction SilentlyContinue) { [void](Repair-ScreenshotRing -VMName $VMName -Confirm:$false) }
                        # F6: grant bounded grace so the reset feed can deliver
                        # text before the deadline, and record the degradation.
                        $grace = Get-OcrDegradationGrace -Action 'ring-repair' -AlreadyGrantedSeconds $deadlineGrantedSeconds -MaxGrantSeconds $maxDeadlineGrantSeconds -BaseWindowSeconds $frozenFeedSeconds
                        if ($grace -gt 0) { $deadlineUtc = $deadlineUtc.AddSeconds($grace); $deadlineGrantedSeconds += $grace }
                        if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
                            Send-YurunaDegradation -Dependency 'capture-feed' -Primary 'ocr-text-feed' -Fallback 'vnc-handle-reset' `
                                -Reason "no OCR text 4 polls seeking '$patternLabel'; repair $ringRepairs/2, deadline +${grace}s"
                        }
                    }
                }

                # Frozen-feed self-heal (distinct from the no-text case above).
                # On a headless Hyper-V host the vmconnect PrintWindow surface
                # can go stale during an idle console tail: the guest has
                # already repainted -- e.g. printed the fetchAndExecute
                # completion marker after a quiet network-convergence wait --
                # but every captured frame is byte-identical, so OCR keeps
                # reading a dead frame that will never contain the pattern and
                # the wait burns its full timeout. The no-text branch can't see
                # this: the frozen frame still holds readable text, so
                # $result.AnyText is true. Detect a feed whose raw bytes have
                # not changed for $frozenFeedSeconds and force the console
                # viewer to reconnect -- Restart-VMConsole relaunches vmconnect
                # (virt-viewer on KVM, the UTM console on macOS), which
                # re-attaches to the guest's live framebuffer. A live-but-idle
                # console keeps a blinking cursor, so its captures differ
                # frame-to-frame and never trip this; the repair is capped so a
                # genuinely static screen still times out normally instead of
                # thrashing the viewer.
                if ($result.AnyText) {
                    $frameHash = $null
                    try { $frameHash = (Get-FileHash -LiteralPath $rawScreenPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $frameHash = $null }
                    if ($frameHash) {
                        if ($frameHash -ne $lastFrameHash) {
                            $lastFrameHash = $frameHash
                            $frameUnchangedSinceUtc = [DateTime]::UtcNow
                        } elseif ($frameUnchangedSinceUtc) {
                            $frozenSecs = [int]([DateTime]::UtcNow - $frameUnchangedSinceUtc).TotalSeconds
                            # F6 trend-aware threshold: the first stall waits the
                            # full window, but once a restart has fired the feed
                            # is known-flaky, so catch the next stall at half the
                            # window instead of re-waiting the full one.
                            $effectiveFreezeThreshold = if ($consoleRestarts -gt 0) { [int][math]::Ceiling($frozenFeedSeconds / 2.0) } else { $frozenFeedSeconds }
                            if ($frozenSecs -ge $effectiveFreezeThreshold -and $consoleRestarts -lt $maxConsoleRestarts) {
                                $consoleRestarts++
                                # F6: grant bounded grace so the relaunched viewer
                                # can deliver a fresh frame before the deadline.
                                $grace = Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds $deadlineGrantedSeconds -MaxGrantSeconds $maxDeadlineGrantSeconds -BaseWindowSeconds $frozenFeedSeconds
                                if ($grace -gt 0) { $deadlineUtc = $deadlineUtc.AddSeconds($grace); $deadlineGrantedSeconds += $grace }
                                Write-Warning "      Wait-ForText: capture feed frozen (byte-identical ${frozenSecs}s, threshold ${effectiveFreezeThreshold}s) while still seeking '$patternLabel' -- forcing console reconnect (repair $consoleRestarts/$maxConsoleRestarts, deadline +${grace}s)."
                                if (Get-Command Restart-VMConsole -ErrorAction SilentlyContinue) {
                                    try { [void](Restart-VMConsole -VMName $VMName -Confirm:$false) }
                                    catch { Write-Verbose "      Restart-VMConsole failed: $($_.Exception.Message)" }
                                }
                                if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
                                    Send-YurunaDegradation -Dependency 'capture-feed' -Primary 'live-framebuffer' -Fallback 'console-reconnect' `
                                        -Reason "frozen ${frozenSecs}s (threshold ${effectiveFreezeThreshold}s) seeking '$patternLabel'; restart $consoleRestarts/$maxConsoleRestarts, deadline +${grace}s"
                                }
                                # Re-arm: give the relaunched viewer a fresh full
                                # $frozenFeedSeconds window to deliver an updated
                                # frame before considering another repair.
                                $lastFrameHash = $null
                                $frameUnchangedSinceUtc = $null
                            }
                        }
                    }
                }
            }

            # Anti-pattern (early-fail) check. Runs AFTER the positive-match
            # check so a positive match wins ties when both appear in one
            # frame. Uses $lastOcrText (the freshest OCR output) so the
            # signature isn't masked by an OCR glitch on the current poll.
            if ($FailurePattern -and $FailurePattern.Count -gt 0 -and $lastOcrText) {
                foreach ($fp in $FailurePattern) {
                    if ([string]::IsNullOrWhiteSpace($fp)) { continue }
                    if (Test-OCRMatch -Text $lastOcrText -Pattern $fp) {
                        $script:Fail.WaitForTextMatchedFailurePattern = $fp
                        Write-Warning "      Failure pattern matched: '$fp' -- aborting wait early (elapsed ${elapsed}s / ${TimeoutSeconds}s)"
                        if ($lastCapturePath -and (Test-Path $lastCapturePath)) {
                            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
                            Copy-Item -Path $lastCapturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
                            Write-Information "      Failure screenshot saved: $failScreenPath (sequence: $screensDir)"
                        }
                        if ($lastOcrText) {
                            $failOcrPath = Join-Path $logDir "failure_ocr_${VMName}.txt"
                            Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
                            Write-Information "      Failure OCR text saved: $failOcrPath"
                            # Bounded tail + the sought patterns into causeDetail (set
                            # on failure only, so a successful wait can't leak them).
                            $script:Fail.WaitForTextOcrTail = if ($lastOcrText.Length -le 1200) { $lastOcrText } else { $lastOcrText.Substring($lastOcrText.Length - 1200) }
                            $script:Fail.WaitForTextPatternsSought = [string[]]@($Pattern)
                        }
                        return $false
                    }
                }
            }

            Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
            Start-Sleep -Seconds $PollSeconds
        }

        # Timeout — preserve last screenshot, full sequence, and OCR text
        if ($lastCapturePath -and (Test-Path $lastCapturePath)) {
            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
            Copy-Item -Path $lastCapturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure screenshot saved: $failScreenPath (sequence: $screensDir)"
        }
        if ($lastOcrText) {
            $failOcrPath = Join-Path $logDir "failure_ocr_${VMName}.txt"
            Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure OCR text saved: $failOcrPath"
            # Bounded tail + the sought patterns into causeDetail (set on failure
            # only, so a successful wait can't leak them).
            $script:Fail.WaitForTextOcrTail = if ($lastOcrText.Length -le 1200) { $lastOcrText } else { $lastOcrText.Substring($lastOcrText.Length - 1200) }
            $script:Fail.WaitForTextPatternsSought = [string[]]@($Pattern)
        }

        if ($deadlineGrantedSeconds -gt 0) {
            $waited = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            Write-Warning "Text '$patternLabel' not found within ${TimeoutSeconds}s (+${deadlineGrantedSeconds}s degradation grace; waited ~${waited}s)"
        } else {
            Write-Warning "Text '$patternLabel' not found within ${TimeoutSeconds}s"
        }
        return $false
    } finally {
        # Note: $screensDir is intentionally NOT cleared here — it survives
        # across all Wait-ForText calls in a guest, and the runner deletes
        # it at end-of-guest on success (or surfaces it on failure).
        Write-ProgressTick -Activity "waitForText" -Completed
    }
}

# ── Action: takeScreenshot ───────────────────────────────────────────────────

function Save-DebugScreenshot {
    <#
    .SYNOPSIS
        Capture a labeled screenshot for the takeScreenshot sequence action.
    .DESCRIPTION
        Builds an HH-mm-ss filename under $OutputDir and asks the host
        driver's Get-VMScreenshot to write it. Returns $true on success
        so the calling step records a passing result.
    .OUTPUTS
        [bool] $true on capture; $false on host-driver failure.
    #>
    param([string]$VMName, [string]$Label, [string]$OutputDir)
    $fileName = "$VMName-$Label-$(Get-Date -Format 'HHmmss').png"
    $outputPath = Join-Path $OutputDir $fileName
    $dir = Split-Path -Parent $outputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $result = Get-VMScreenshot -VMName $VMName -OutFile $outputPath
    if ($result) { Write-Debug "      Screenshot: $outputPath"; return $true }
    return $false
}

# ── Main executor ────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Resolves a sequence name to a mode-appropriate path and runs it.
.DESCRIPTION
    Thin wrapper around Invoke-Sequence: takes a sequence NAME plus the
    sequences root, resolves to gui/<Name>.yml or ssh/<Name>.yml based on
    keystrokeMechanism (with gui fallback), and delegates to Invoke-Sequence.
    Extension scripts that iterate over a list of sequence names should call
    this instead of building paths and calling Invoke-Sequence directly; the
    future config-driven runner can then reuse this function unchanged.
#>
function Invoke-SequenceByName {
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$RepoRoot,
        # Planner-cascaded variable overrides. When present, each key in
        # this map REPLACES the same-named entry under the sequence
        # file's `variables:` block before step expansion (top-of-chain
        # wins for the whole chain -- see Test.SequencePlanner). Empty
        # map = standalone Test-Sequence.ps1 invocation, keeps the
        # legacy "sequence-local variables win" path.
        # Use IDictionary (not [hashtable]) so an [ordered]@{} from the
        # planner keeps its insertion order through parameter binding.
        # A [hashtable] cast would coerce OrderedDictionary -> Hashtable
        # and lose the order, which then has the override loop below
        # process e.g. `currentPassword: ${ext:...(${username})}` BEFORE
        # `username: yauser1`. The `${username}` placeholder fails to
        # resolve and the literal string ends up as a vault key.
        [System.Collections.IDictionary]$EffectiveVariables,
        [switch]$ShowSensitive
    )
    $sequenceFile = Resolve-SequencePath -SequencesDir $SequencesDir -Name $Name -HostType $HostType -RepoRoot $RepoRoot
    if (-not $sequenceFile) {
        # Missing sequence file is a setup error, not an optional skip.
        # Returning $true here would let a typo in a sequence name
        # silently mark the test as passing.
        # Resolve-SequencePath returns $null on miss; show what was searched
        # (Get-SequenceSearchPath enumerates the same tier order) so the
        # operator can see the locations that were probed.
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $Name -HostType $HostType -RepoRoot $RepoRoot
        $list = ($searched | ForEach-Object { "    $_" }) -join "`n"
        Write-Warning "[$GuestKey] Sequence file not found: $Name`nSearched (no match):`n$list"
        return $false
    }
    # Informational lines go through Write-Information, NOT Write-Output.
    # Write-Output emits to the pipeline, and combined with `return (...)`
    # below it would fold these strings into the caller's `$ok` variable —
    # turning the boolean into @("Running…", "Sequence file…", $true/$false).
    # The caller's `$ok -eq $false` still catches an honest $false inside
    # that array, but a returned $null (e.g. from an unhandled crash path)
    # would look identical to success. Keep the pipeline clean so the
    # return is strictly [bool].
    Write-Information "[$GuestKey] Running sequence: $Name on $HostType (VM: $VMName)" -InformationAction Continue
    Write-Verbose "    Sequence file: $sequenceFile"
    $result = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $sequenceFile -EffectiveVariables $EffectiveVariables -ShowSensitive:$ShowSensitive
    # Normalize: only $true is success. Anything else — $null, objects,
    # arrays — fails. A sane Invoke-Sequence returns $true / $false and
    # this is a no-op; a broken one no longer slips past.
    return ($result -eq $true)
}

# Slice a sequence's steps to an optional 1-based window. A whole-sequence
# window (StartStep <= 1 and StopStep <= 0) returns the steps unchanged; an
# out-of-range window returns an empty array. Invoke-Sequence uses this so the
# chain runner can run a step range via -StartStep / -StopStep without writing a
# sliced temp YAML -- the returned slice renumbers 1..N exactly as the temp file
# did, so step numbering, totals, and PASS/FAIL logging are identical for a
# windowed run.
function Select-SequenceStepWindow {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$Steps = @(),
        [int]$StartStep = 1,
        [int]$StopStep = 0
    )
    if ($StartStep -le 1 -and $StopStep -le 0) { return $Steps }
    $total = $Steps.Count
    $from  = [Math]::Max(1, $StartStep)
    $to    = if ($StopStep -gt 0) { [Math]::Min($StopStep, $total) } else { $total }
    if ($total -eq 0 -or $from -gt $total -or $from -gt $to) { return @() }
    return @($Steps[($from - 1)..($to - 1)])
}

# The VM name in effect when the most recent Invoke-Sequence returned, including
# a mid-sequence saveDiskSnapshot rename. Chain callers read this after each
# sequence so the next one targets the renamed VM -- one shared mechanism for
# both the inner runner's Start-Guest* loops and Test-Sequence's chain runner.
function Get-SequenceFinishedVMName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string]$script:SequenceFinishedVMName
}

<#
.SYNOPSIS
    Executes an interaction sequence from a YAML file against a VM.
.DESCRIPTION
    Reads the steps array from the YAML file and executes each action
    sequentially. Variables in the YAML are substituted into parameters.
    Returns $true if all steps succeed, $false otherwise.
#>
function Invoke-Sequence {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$SequencePath,
        # Planner-cascaded variable overrides; see Invoke-SequenceByName.
        # Null/empty = use the sequence file's own `variables:` block
        # verbatim (standalone Test-Sequence.ps1 path).
        # Use IDictionary (not [hashtable]) so an [ordered]@{} from the
        # planner keeps its insertion order through parameter binding.
        # A [hashtable] cast would coerce OrderedDictionary -> Hashtable
        # and lose the order, which then has the override loop below
        # process e.g. `currentPassword: ${ext:...(${username})}` BEFORE
        # `username: yauser1`. The `${username}` placeholder fails to
        # resolve and the literal string ends up as a vault key.
        [System.Collections.IDictionary]$EffectiveVariables,
        [switch]$ShowSensitive,
        # Optional 1-based step window over this sequence's steps (StopStep 0 =
        # run to the end). The chain runner passes a per-entry local window so a
        # `-StartStep` / `-StopStep` debug run needs no temp-file slicing;
        # default (1, 0) runs the whole sequence unchanged.
        [int]$StartStep = 1,
        [int]$StopStep = 0
    )
    # $ShowSensitive is consumed inside $invokeStepBlock via dynamic scoping
    # (see comment block at the scriptblock definition). Touched here as
    # $null = ... so PSReviewUnusedParameter sees a body-level reference.
    $null = $ShowSensitive

    # Surfaced VM name for chain-rename propagation. A mid-sequence
    # saveDiskSnapshot renames the live VM (test-X -> <id>); the engine tracks
    # that internally (below) but the change is local to the step scriptblock, so
    # chain callers (Invoke-TestSequenceChain, Start-GuestOS / Start-GuestWorkload)
    # read Get-SequenceFinishedVMName after this returns to target the renamed VM
    # in the next sequence. Seeded to the passed name; updated on $ctx.NewVMName.
    $script:SequenceFinishedVMName = $VMName

    # ── SSH variant selection ──────────────────────────────────────────────
    # Sequences live in mode-specific subfolders: sequences/gui/ and
    # sequences/ssh/. When test.config.yml sets keystrokeMechanism="SSH"
    # and the caller passed a path under sequences/gui/, redirect to the
    # sequences/ssh/ sibling with the same filename. If that sibling does
    # not exist, fall back to the gui/ file so guests without an SSH
    # sequence yet continue to work (same degrade path as the legacy
    # .ssh.json sibling lookup). Comparison is case-insensitive so
    # "ssh"/"SSH" both select this branch; the canonical uppercase form
    # is written back to test.config.yml by Invoke-TestRunner's
    # validation step.
    if ($script:DefaultKeystrokeMechanism -eq "SSH") {
        $sshVariant = Get-SequenceModePath -SequencePath $SequencePath -Mode "ssh"
        if ($sshVariant -and (Test-Path $sshVariant)) {
            Write-Information "    keystrokeMechanism=SSH → using SSH variant: $(Split-Path -Leaf $sshVariant)"
            $SequencePath = $sshVariant
        } else {
            # SSH mechanism selected but no ssh/ sibling exists. Record the
            # degradation either way (best-effort: Send-YurunaDegradation can be
            # out of scope on the test-start extension import path, where the
            # parent runner's global modules don't propagate -- see the nested-
            # scope note at Initialize-YurunaLogDir).
            $leaf = Split-Path -Leaf $SequencePath
            if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
                Send-YurunaDegradation -Dependency 'keystroke-mechanism' -Primary 'ssh-sequence' `
                    -Fallback 'gui-sequence' -Reason "no ssh variant for $leaf"
            }
            if (-not $script:AllowGuiFallback) {
                # Independent mechanisms (the default): do NOT silently run the
                # gui/ (OCR) sibling under an SSH config. Fail loudly so an
                # SSH-only host doesn't get an OCR sequence it cannot drive.
                Write-Warning "    keystrokeMechanism=SSH: no ssh/ variant for '$leaf' and vmCommunication.allowGuiFallback=false -- not falling back to gui/. Add sequences/ssh/$leaf or set allowGuiFallback: true."
                return $false
            }
            Write-Information "    keystrokeMechanism=SSH: no ssh/ variant for '$leaf'; allowGuiFallback=true -- running the gui/ sequence."
        }
    }

    if (-not (Test-Path $SequencePath)) {
        # Missing sequence file = setup error. A silent-skip return of
        # $true would mask sequence-name typos and bad mode resolution
        # as test successes.
        Write-Warning "    Sequence file not found: $SequencePath"
        return $false
    }

    # Initialize logDir + trackDir early so the catch block can write
    # diagnostics and the pause-flag paths resolve below. Invoke-Sequence
    # runs inside a child module scope when a test-start extension script
    # imports it, so the parent runner's global Import-Module doesn't
    # propagate here — each helper has to be re-imported on this path.
    # -Global on the -Force re-imports: without it, the nested reload
    # evicts these modules from the parent script's session state and
    # breaks subsequent top-level calls (see Get-CycleScreenDir crash).
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    Import-Module (Join-Path $modulesDir "Test.Ssh.psm1")      -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir = Initialize-YurunaLogDir

  try {
    $sequence = Read-SequenceFile -Path $SequencePath

    # Clean up stale failure artifacts from any prior run
    Remove-Item (Join-Path $logDir "last_failure.json") -Force -ErrorAction SilentlyContinue

    # Build variables table: built-ins first, then YAML-defined entries
    # evaluated EAGERLY in file order. Each entry can reference any
    # variable declared above it, plus the built-ins. ${ext:...} inside
    # a value is invoked once at definition time and the resolved value
    # is stored, so two step references to the same variable always
    # type the same value (even though ${ext:...} itself is no longer
    # memoized -- pinning a generated value across multiple steps is now
    # an explicit, file-visible operation rather than implicit caching).
    #
    # Planner-cascaded overrides (-EffectiveVariables) REPLACE same-named
    # YAML entries: a workload.*.yml that defines `username: webuser`
    # propagates that value into every sequence in its dependency chain,
    # so the baseline `start.*.yml` still saying `username: yuuser26`
    # silently runs with `webuser` whenever the workload is the cycle's
    # top-level. Sequence YAML stays self-contained -- the local
    # variables: block remains the standalone-invocation fallback for
    # Test-Sequence.ps1 runs with no cascade context.
    $vars = @{ "vmName" = $VMName; "hostType" = $HostType; "guestKey" = $GuestKey }
    if ($sequence.variables) {
        foreach ($_varKey in $sequence.variables.Keys) {
            # .Contains() (not .ContainsKey) so OrderedDictionary works
            # alongside Hashtable -- OrderedDictionary only exposes Contains.
            if ($EffectiveVariables -and $EffectiveVariables.Contains($_varKey)) {
                # Cascade override wins -- skip the YAML value entirely
                # (incl. any ${ext:...} side-effecting expansion). Picked
                # up in the override-merge loop below.
                continue
            }
            $_raw = $sequence.variables[$_varKey]
            if ($_raw -is [string]) {
                $vars[$_varKey] = Expand-Variable $_raw $vars
            } else {
                $vars[$_varKey] = $_raw
            }
        }
    }
    if ($EffectiveVariables) {
        foreach ($_ovKey in $EffectiveVariables.Keys) {
            $_ovRaw = $EffectiveVariables[$_ovKey]
            if ($_ovRaw -is [string]) {
                $vars[$_ovKey] = Expand-Variable $_ovRaw $vars
            } else {
                $vars[$_ovKey] = $_ovRaw
            }
        }
    }
    # Auto-derive ${loginUser} from the resolved ${username} via the
    # authentication extension's users.yml mapping. The sequence file
    # is free to declare its own `loginUser` under variables: (or pass
    # one in via the cascade) -- only the unset case is auto-filled.
    # Empty corporate fields in users.yml mean loginUser == username
    # (today's local-only behavior); a populated corporate mapping
    # renders DOMAIN\sam or upn@domain.com.
    if (-not $vars.ContainsKey('loginUser') -and $vars.ContainsKey('username')) {
        try {
            # Import the extension area lazily; the planner / runner has
            # usually already loaded it, but standalone Test-Sequence
            # invocations may reach this path cold.
            $extLoader = Join-Path $PSScriptRoot 'Test.Extension.psm1'
            if (Test-Path $extLoader) {
                Import-Module $extLoader -Global -Force -Verbose:$false -ErrorAction SilentlyContinue
            }
            if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
                [void](Import-Extension -Area 'authentication' -RequireSingle)
            }
            if (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) {
                $effU = Get-EffectiveUser -LogicalUser ([string]$vars['username'])
                if ($effU -and $effU.loginUser) {
                    $vars['loginUser'] = [string]$effU.loginUser
                }
            }
        } catch {
            Write-Verbose "loginUser auto-derivation skipped: $($_.Exception.Message)"
        }
        # Defensive: when the auth extension is unavailable (rare;
        # standalone test eval) keep ${loginUser} == ${username} so
        # sequences referencing the token don't render as the literal
        # placeholder string.
        if (-not $vars.ContainsKey('loginUser')) { $vars['loginUser'] = $vars['username'] }
    }

    Write-Information "    Sequence: $($sequence.description)"
    # Apply the optional step window (default = whole sequence). Slicing here
    # (rather than the caller writing a sliced temp YAML) is what lets the chain
    # runner drive a step range with -StartStep / -StopStep on the real file.
    # @() guards the single-step case: PowerShell unwraps a one-element return,
    # so without it a 1-step window would arrive as a bare step, not an array.
    $steps = @(Select-SequenceStepWindow -Steps @($sequence.steps) -StartStep $StartStep -StopStep $StopStep)

    # Per-step perf logging. Set-PerfSequenceContext / Set-PerfGuestContext
    # are silent no-ops when Test.Perf is not loaded OR when Start-PerfCycle
    # never ran (e.g. a direct Test-Sequence.ps1 invocation outside the
    # runner), so this block is safe to call unconditionally. The raw YAML
    # body is snapshotted so a row's sequenceContentHash can be mapped
    # back to the exact sequence that ran -- gui/ and ssh/ variants of
    # the same logical sequence share a sequenceGuid; the content hash
    # discriminates them.
    if (Get-Command -Name Set-PerfSequenceContext -ErrorAction SilentlyContinue) {
        try {
            $seqName     = [System.IO.Path]::GetFileNameWithoutExtension($SequencePath)
            $seqGuid     = if ($sequence.Contains('sequenceGuid'))     { [string]$sequence.sequenceGuid }     else { $null }
            $seqRevision = if ($sequence.Contains('sequenceRevision')) { [int]$sequence.sequenceRevision }   else { 0 }
            $seqBody     = $null
            try {
                $seqBody = [System.IO.File]::ReadAllText($SequencePath)
            } catch {
                $readErr = $_
                Write-Information "Perf: sequence file read failed; perf row will lack sequenceContentHash. Path=$SequencePath Error=$($readErr.Exception.Message)"
                Send-CycleEventSafely -EventRecord @{
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event     = 'perf_context_unavailable'
                    reason    = 'sequence_read_failed'
                    path      = [string]$SequencePath
                    error     = $readErr.Exception.Message
                }
            }
            Set-PerfSequenceContext -SequenceName $seqName -SequenceGuid $seqGuid -SequenceRevision $seqRevision -SequenceContent $seqBody
            Set-PerfGuestContext    -GuestKey $GuestKey -VMName $VMName
        } catch {
            $setupErr = $_
            Write-Information "Perf-context setup failed (non-fatal): $($setupErr.Exception.Message)"
            Send-CycleEventSafely -EventRecord @{
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event     = 'perf_context_unavailable'
                reason    = 'setup_failed'
                path      = [string]$SequencePath
                error     = $setupErr.Exception.Message
            }
        }
    }

    if ($steps.Count -eq 0) {
        Write-Verbose "    No steps defined."
        return $true
    }
    Write-Verbose "    Steps: $($steps.Count)"

    # Step-pause back-channel: the status server's /control/step-pause
    # endpoint creates $env:YURUNA_RUNTIME_DIR/control.step-pause. We gate
    # on that file in two places:
    #   1. Before sequence setup (here, below) — so Restart-VMConnect and any
    #      per-sequence work don't run while paused, and the very first
    #      action of a new sequence can't start while paused. This matters
    #      most between two sequences (e.g. Test-Start → Test-Workload, or
    #      one guest's workload → the next guest's workload) where clicking
    #      Pause used to only take effect after the next sequence had
    #      already started its first action.
    #   2. At the top of each step iteration (further below) — so a click
    #      mid-sequence takes effect before the next action.
    # Empty-steps sequences have already returned above, so the sequence-
    # level wait here never triggers for a sequence that has nothing to do.
    # Cycle-pause (control.cycle-pause) is gated separately in
    # Invoke-TestRunner.ps1 at cycle boundaries — Invoke-Sequence is only
    # concerned with step-level pauses.
    $runtimeDir = Initialize-YurunaRuntimeDir
    $stepPauseFlagFile = Join-Path $runtimeDir 'control.step-pause'
    # Cycle-restart back-channel: the status server's /control/start-cycle
    # endpoint sets this flag while it kills in-progress VMs. The inter-
    # cycle delay loop in Invoke-TestInnerRunner already breaks on it, but
    # if the request lands while a cycle is actively executing steps the
    # delay loop never sees it — the cycle limps through screenshot
    # failures of deleted VMs and the operator's "restart now" never
    # arrives. Gating here too makes the abort fire from inside an active
    # cycle: the throw escapes through retry / sequence / runner and is
    # recognised by the inner's cycle-catch by the message prefix.
    $cycleRestartFlagFile = Join-Path $runtimeDir 'control.cycle-restart'

    # Current-action sidecar: write the in-progress step to a small JSON file
    # that the status server can serve at /runtime/current-action.json. The UI
    # polls it alongside status.json and renders the line under the matching
    # guest card. We write at the top of each iteration (so the UI sees the
    # step that's about to run, not the one that just finished) and once more
    # at the end of a successful sequence with the "[All N steps completed]"
    # summary.
    $currentActionFile = Join-Path $runtimeDir 'current-action.json'
    $writeCurrentAction = {
        param([string]$Line)
        $attempts = 0
        $lastErr  = $null
        while ($attempts -lt 3) {
            $attempts++
            try {
                $doc = [ordered]@{
                    guestKey  = $GuestKey
                    vmName    = $VMName
                    line      = $Line
                    updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                }
                # Route through the shared atomic writer: a fixed "$Path.tmp"
                # lets a concurrent writer's rename clobber a half-written temp,
                # so the primitive uses a per-PID unique temp name (and a
                # guaranteed no-BOM encoding) in one place. It returns $false
                # rather than throwing, so surface that into the retry loop.
                if (-not (Write-YurunaStateFileJson -Path $currentActionFile -InputObject $doc -Confirm:$false)) {
                    throw "Write-YurunaStateFileJson returned false for $currentActionFile"
                }
                return
            } catch {
                $lastErr = $_
                Start-Sleep -Milliseconds (50 * $attempts)
            }
        }
        Write-Warning "current-action.json write failed after $attempts attempts: $($lastErr.Exception.Message) (path=$currentActionFile)"
        Send-CycleEventSafely -EventRecord @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event     = 'sidecar_write_failed'
            file      = 'current-action.json'
            path      = [string]$currentActionFile
            attempts  = $attempts
            error     = $lastErr.Exception.Message
        }
    }

    # Shared pause-wait block. Used both at sequence start (Label='[sequence
    # start]') and at the top of each step (Label='[stepNum/Count]').
    # Dynamic scoping resolves $stepPauseFlagFile and $writeCurrentAction
    # from the caller's scope at invoke time, so the scriptblock doesn't
    # need its own parameters for those.
    $waitWhilePaused = {
        param([string]$Label)
        if (Test-Path $stepPauseFlagFile) {
            & $writeCurrentAction "$Label Paused (waiting for resume)"
            Write-Information "    $Label Paused (status-service request). Waiting for resume..."
            $pauseAttempt = 1
            while (Test-Path $stepPauseFlagFile) {
                Start-Sleep -Milliseconds (Get-PollDelay -Attempt $pauseAttempt)
                $pauseAttempt++
            }
            Write-Information "    $Label Resumed."
        }
    }

    # Cycle-restart gate. Throws a message-prefixed exception so the inner
    # runner's cycle-catch (see Invoke-TestInnerRunner.ps1) can short-
    # circuit emergency-cleanup chatter and skip the ConsecutiveCrashes
    # increment for this expected abort. The flag is intentionally NOT
    # cleared here: the post-cycle inter-cycle delay loop will consume it
    # on its next tick, which keeps the existing "wake delay early" path
    # working unchanged. If the inner is already past the delay (i.e.
    # actively running this sequence), the throw propagates up through
    # any enclosing retry / step / sequence frames straight to the cycle
    # try/catch.
    $checkCycleRestart = {
        param([string]$Label)
        if (Test-Path $cycleRestartFlagFile) {
            & $writeCurrentAction "$Label cycle-restart requested (aborting cycle)"
            Write-Information "    $Label cycle-restart signal seen — aborting current cycle."
            throw "YurunaCycleRestart: status-service /control/start-cycle requested mid-cycle abort at $Label"
        }
    }

    # Gate #1: sequence-level pause + cycle-restart check, before any per-
    # sequence work. Pause is checked first so an operator-initiated pause
    # that overlaps a restart click still resolves predictably (pause
    # wins until released, then the restart flag is observed).
    & $waitWhilePaused "[sequence start]"
    & $checkCycleRestart "[sequence start]"

    # HACK: Force vmconnect to repaint by reconnecting.
    # After a host reboot the Hyper-V console window may render blank;
    # closing and reopening it forces a full framebuffer refresh.
    # Yuruna.Host's Restart-VMConsole is in scope here because
    # Initialize-YurunaHost is called by Test-Sequence.ps1 /
    # Invoke-TestRunner.ps1 before sequences run.
    [void](Restart-VMConsole -VMName $VMName -Confirm:$false)

    # takeScreenshot debug PNGs land under test/status/captures/sequences/
    # (gitignored runtime data, lives with the rest of the harness state
    # so cleaning a host is one rm -rf status/* away). Sequence name is
    # prefixed onto each filename in Save-DebugScreenshot, so a single
    # flat folder keeps captures organized without a per-sequence subdir.
    # Anchor on $PSScriptRoot (this module lives at <TestRoot>/modules/);
    # $SequencePath is unreliable as an anchor because the chain runner
    # writes per-entry slices to the OS temp dir and project-tree
    # sequences live under <RepoRoot>/project/.../test/<mode>/.
    $testRoot = Split-Path -Parent $PSScriptRoot
    $screenshotDir = Join-Path -Path $testRoot -ChildPath 'status' `
                         -AdditionalChildPath 'captures', 'sequences'
    $sequenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ── Recursive step executor ─────────────────────────────────────────────
    # Wrapped as a script-block so the `retry` action case (below) can call
    # it on its inner `steps:` array, reusing the full per-step
    # infrastructure: pause checks, currentAction sidecar, progress ticks,
    # variable expansion, the action switch, PASS/FAIL logging. The block
    # resolves $vars, $writeCurrentAction, $waitWhilePaused, $HostType,
    # $VMName, $GuestKey, $logDir, $screenshotDir, $ShowSensitive, and the
    # $script:Default* defaults from the enclosing function scope via
    # PowerShell's dynamic-scoping read semantics; the param $Steps shadows
    # the outer $steps within the block. On step failure the block captures
    # context into the shared failure store ($script:Fail) and returns $false. The OUTER call
    # site below is what writes last_failure.json + failure screenshot +
    # post-failure pause, so a transient failure inside a retry attempt
    # never pollutes last_failure.json -- only an exhausted-retry failure
    # (or a non-retry failure) does, after the outer call finally returns.
    $invokeStepBlock = {
        param(
            [Parameter(Mandatory)][object[]]$Steps,
            # Set by the retry recursion: outer retry's ordinal + 'retry' so
            # rows from inner steps can be joined back to the retry wrapper
            # at query time without inventing a step GUID.
            [int]$ParentOrdinal = 0,
            [string]$ParentAction = ''
        )
        $stepNum = 0
        foreach ($step in $Steps) {
            $stepNum++
            # Gate #2: between-steps pause + cycle-restart check. Catches
            # a Pause or a "Save and start cycle" clicked while the previous
            # step was running. The throw inside $checkCycleRestart escapes
            # this $invokeStepBlock (including any wrapping `retry` block —
            # retry only catches $false returns, not exceptions) and bubbles
            # up to the cycle-level try/catch in Invoke-TestInnerRunner.
            & $waitWhilePaused "[$stepNum/$($Steps.Count)]"
            & $checkCycleRestart "[$stepNum/$($Steps.Count)]"
            $desc = $step.description ? (Expand-Variable $step.description $vars) : $step.action
            & $writeCurrentAction "[$stepNum/$($Steps.Count)] $($step.action): $desc"
            # Refresh runner.stepHeartbeat from the runspace so the outer
            # watchdog can detect a single step that exceeds stepTimeout-
            # Minutes. We do NOT update this inside the action's own poll
            # loop -- the threadpool-driven runner.heartbeat already
            # provides proof-of-life for the process. Refreshing only at
            # step boundaries means the watchdog kicks in if any single
            # step (waitForText with its own deadline, ssh exec, retry
            # block) hangs longer than the configured budget.
            try {
                $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh failed: $($_.Exception.Message)"
            }

            # `retry` is dispatched through the registry like every other
            # verb; the Handler lives at the bottom of this module next
            # to its Register-SequenceAction.

        # Current-step visibility is intentionally driven by Write-Progress
        # (via Write-ProgressTick below), NOT by a Write-Information here.
        # A Write-Information at step-start would go through the Yuruna.Log
        # proxy and leave a permanent line in both the terminal and the log
        # transcript — then the end-of-step completion line (with elapsed
        # time) would appear below rather than replacing it. Write-Progress
        # renders out-of-band (floating bar) and auto-dismisses on
        # -Completed, so the scroll-permanent log gets exactly one entry
        # per step (the completion).
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'Continue'
        try {
        Write-ProgressTick -Activity "Sequence" -Status "[$stepNum/$($steps.Count)] $($step.action): $desc" -PercentComplete ([math]::Round((($stepNum - 1) / [math]::Max($steps.Count,1)) * 100))

        $stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        # Wall-clock start captured alongside the stopwatch so the perf
        # row carries an absolute UTC timestamp (needed for cross-host
        # joins) without trying to subtract elapsed ms from the END
        # time -- the two clocks would diverge by the GC/IO time of the
        # write itself.
        $stepStartUtc = [DateTime]::UtcNow
        $ok = $true

        # Per-step registry dispatch. Test.SequenceAction lets a verb
        # register a Handler scriptblock; the Context hashtable is the
        # canonical state surface (no closures over the parent function's
        # locals). Every built-in verb -- including `retry` -- registers
        # a Handler.
        # A YAML typo (e.g. "tapButton" instead of "tapOn") or a third-
        # party verb that registered a FailureLabel without a Handler
        # surfaces here as a hard fail so it never silently passes.
        if (Test-SequenceActionHasHandler -Name $step.action) {
            $ctx = @{
                Step                  = $step
                StepNum               = $stepNum
                StepCount             = $steps.Count
                Steps                 = $steps
                Vars                  = $vars
                VMName                = $VMName
                GuestKey              = $GuestKey
                HostType              = $HostType
                LogDir                = $logDir
                RuntimeDir            = $runtimeDir
                ScreenshotDir         = $screenshotDir
                ShowSensitive         = $ShowSensitive
                SequencePath          = $SequencePath
                ExpandVariable        = ${function:Expand-Variable}
                # Step-default param resolution lives in each handler
                # scriptblock; these mirror the values the engine used to
                # read directly from $script:Default*.
                DefaultCharDelayMs    = $script:DefaultCharDelayMs
                DefaultPollSeconds    = $script:DefaultPollSeconds
                DefaultTimeoutSeconds = $script:DefaultTimeoutSeconds
                # Action helpers used by break / retry / composite verbs.
                WriteCurrentAction    = $writeCurrentAction
                WaitWhilePaused       = $waitWhilePaused
                InvokeStepBlock       = $invokeStepBlock
                # Description string the engine resolved for this step;
                # the retry handler uses it in attempt-progress logs so
                # the operator sees the original ${var}-expanded text.
                Description           = $desc
            }
            $ok = Invoke-SequenceActionHandler -Name $step.action -Context $ctx
            # A handler that renamed the VM mid-sequence (saveDiskSnapshot
            # promotes a snapshot by renaming the live VM) reports the new name
            # via $ctx.NewVMName. Propagate it so subsequent steps -- and every
            # ${vmName} expansion -- target the renamed VM, not the stale name.
            if ($ctx.NewVMName) {
                $VMName = [string]$ctx.NewVMName
                $vars['vmName'] = $VMName
                # Surface to module scope so chain callers see the rename after
                # this sequence returns ($VMName here is scriptblock-local).
                $script:SequenceFinishedVMName = $VMName
            }
        } else {
            Write-Warning "Unknown action '$($step.action)' -- treating as failure."
            $ok = $false
        }
        } finally {
            $global:ProgressPreference = $savedProgress
        }

        # Normalize $ok. Anything that isn't a strict [bool] — $null, an
        # accidentally-polluted pipeline array, a string, an exception object
        # wrapped by a catch — is treated as failure. Without this, helpers
        # that forget to `return $true`/`return $false` (or that leak a stray
        # Write-Output) silently pass the step despite a timeout.
        if ($ok -isnot [bool]) {
            $okType = if ($null -eq $ok) { '<null>' } else { $ok.GetType().Name }
            Write-Warning "    Step [$stepNum] action '$($step.action)' returned a non-boolean ($okType) — treating as failure."
            $ok = $false
        }

        $stepStopwatch.Stop()
        $elapsedLabel = ("    {0,4}" -f [int]$stepStopwatch.Elapsed.TotalSeconds)
        $stepMarker   = if ($ok) { 'PASS' } else { 'FAIL' }
        Write-Information "$elapsedLabel s [$stepNum/$($steps.Count)] $stepMarker $($step.action): $desc"

        # One NDJSON line per step_end so a downstream consumer can plot
        # pass/fail rates without HTML scraping. Carries the SUPERSET
        # schema (hostType, action, description, failureClass-when-known)
        # of step_failure so a downstream consumer can do a single
        # schema join across step_end + step_failure rows. The
        # failureClass/severity/suggestedRecoveries fields are populated
        # from the verb's static registration -- on a passing step they
        # surface "what the verb *would* class a failure as".
        $stepVerbEntry = Get-SequenceAction -Name ([string]$step.action)
        $stepFailureClass = if ($stepVerbEntry) { [string]$stepVerbEntry.FailureClass } else { 'unknown' }
        $stepSeverity     = if ($stepVerbEntry) { [string]$stepVerbEntry.Severity }     else { 'unknown' }
        # Avoid the dual unwrap trap: PowerShell flattens single-element
        # arrays AND empty arrays out of an if-statement's pipeline
        # output, so `[string[]]$x = if (...) { @(...) }` yields a scalar
        # on a 1-element value and $null on an empty value. The two-step
        # form below initialises to an empty string[] up front, then
        # overwrites only when there are entries to materialise; either
        # outcome serialises as a JSON array and clears the schema
        # validator's typed-array check.
        [string[]]$stepSuggested = @()
        if ($stepVerbEntry -and $null -ne $stepVerbEntry.SuggestedRecoveries) {
            [string[]]$stepSuggested = @($stepVerbEntry.SuggestedRecoveries)
        }
        Send-CycleEventSafely -EventRecord @{
            timestamp           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event               = 'step_end'
            stepNumber          = [int]$stepNum
            totalSteps          = [int]$steps.Count
            actionVerb          = [string]$step.action
            ok                  = [bool]$ok
            durationMs          = [int]$stepStopwatch.Elapsed.TotalMilliseconds
            vmName              = $VMName
            guestKey            = $GuestKey
            hostType            = $HostType
            action              = [string]$step.action
            description         = [string]$desc
            failureClass        = $stepFailureClass
            severity            = $stepSeverity
            suggestedRecoveries = $stepSuggested
            sequencePath        = $SequencePath
        }
        # Track the last passing step number so the failure payload can
        # surface lastSucceededStepNumber -- a remediator that wants to
        # replay needs to know the boundary it can safely resume past.
        if ($ok) { $script:Fail.LastSucceededStepNumber = $stepNum }

        # Emit one structured row per step execution. stepName is the
        # RAW (pre-expansion) YAML `description:` -- variables like
        # ${vmName} are intentionally NOT expanded here so cross-cycle
        # joins on stepName remain stable even though vmName carries a
        # per-cycle timestamp suffix. Falls back to step.action when no
        # description is set. retry-wrappers don't emit (they exit via
        # `continue` above the stopwatch); their wall-clock cost is the
        # sum of the inner rows.
        if (Get-Command -Name Write-PerfStepRow -ErrorAction SilentlyContinue) {
            try {
                $stepName = if ($step.Contains('description') -and $step.description) { [string]$step.description } else { [string]$step.action }
                Write-PerfStepRow `
                    -StepName          $stepName `
                    -StepOrdinal       $stepNum `
                    -StepKind          ([string]$step.action) `
                    -StartedAtUtc      $stepStartUtc `
                    -EndedAtUtc        ([DateTime]::UtcNow) `
                    -DurationMs        ([int]$stepStopwatch.Elapsed.TotalMilliseconds) `
                    -Outcome           ($ok ? 'pass' : 'fail') `
                    -ParentStepOrdinal $ParentOrdinal `
                    -ParentAction      $ParentAction
            } catch {
                Write-Verbose "Write-PerfStepRow failed (non-fatal): $($_.Exception.Message)"
            }
        }

        if (-not $ok) {
            Write-Warning "    Step [$stepNum] failed: $desc"

            # Build a human-readable failed-step label (e.g. 'waitForText: "login prompt"').
            # Canonical builder: Test.SequenceAction\Get-SequenceActionFailureLabel.
            # Each verb's FailureLabel scriptblock lives next to its capability
            # requirements at the bottom of this module — search for
            # Register-SequenceAction. The OUTER call site reads $script:Fail.Last-
            # Failure* below to write last_failure.json + the failure screen-
            # shot. Capturing here (and only returning $false) keeps transient
            # retry-attempt failures from leaving a stale last_failure.json
            # behind.
            $actionLabel = Get-SequenceActionFailureLabel -Step $step -Vars $vars -ExpandVariable ${function:Expand-Variable}

            # If Wait-ForText short-circuited on a failurePattern, annotate
            # the step label so the runner's ERROR banner and the per-run
            # failure JSON both say *why* the step died instead of the
            # generic "pattern not found within Ns". Only waitForText /
            # waitForAndEnter / passwdPrompt / sshWaitReady set this signal;
            # for other actions it is $null and the label is unchanged.
            if (($step.action -eq 'waitForText' -or $step.action -eq 'waitForAndEnter' -or $step.action -eq 'passwdPrompt' -or $step.action -eq 'sshWaitReady') -and
                $script:Fail.WaitForTextMatchedFailurePattern) {
                $actionLabel = $actionLabel + " -- matched failurePattern `"$($script:Fail.WaitForTextMatchedFailurePattern)`""
            }

            $script:Fail.LastFailureLabel       = $actionLabel
            $script:Fail.LastFailureDescription = $desc
            $script:Fail.LastFailedAction       = $step.action
            $script:Fail.LastFailedStepNumber   = $stepNum
            return $false
        }
        }  # end foreach inside $invokeStepBlock
        return $true
    }  # end $invokeStepBlock

    $script:Fail.LastFailureLabel       = $null
    $script:Fail.LastFailureDescription = $null
    $script:Fail.LastFailedAction       = $null
    $script:Fail.LastFailedStepNumber   = 0
    # Inner-verb capture for retry-exhausted failures. The outer per-step
    # block at line ~2063 overwrites $script:Fail.LastFailedAction with the
    # OUTER step's action name (= 'retry') whenever a Handler returns
    # $false; that collapses the deepest inner verb's classification
    # into 'retry_exhausted'. The retry Handler captures the inner verb
    # into these slots BEFORE returning so the v2 emitter below can
    # surface both classes -- 'retry_exhausted' for the outer step,
    # plus the inner class an autonomous remediator needs to pick the
    # right recovery (an OCR timeout asks for a different remediation
    # than an SSH down).
    $script:Fail.LastInnerFailedAction         = $null
    $script:Fail.LastInnerFailureClass         = $null
    $script:Fail.LastInnerSeverity             = $null
    $script:Fail.LastInnerSuggestedRecoveries  = @()
    # lastSucceededStepNumber: the step-N boundary a replay can safely
    # resume past. Reset to 0 at sequence start so a fresh-cycle
    # failure on step 1 surfaces as "no step succeeded" rather than
    # carrying a leftover value from a prior sequence's run.
    $script:Fail.LastSucceededStepNumber       = 0
    # Cause slots reset per sequence so a prior sequence's OCR tail / sought
    # patterns can't leak into a non-wait step's failure record that fails before
    # any wait runs (the wait functions also reset them at entry).
    $script:Fail.WaitForTextOcrTail            = $null
    $script:Fail.WaitForTextPatternsSought     = [string[]]@()
    $result = & $invokeStepBlock -Steps $steps
    if (-not $result) {
        # Build the schema-v2 failure record once; New-SequenceFailureRecord
        # reads the $script:Fail slots and returns both the last_failure.json
        # ordered dict and the matching step_failure NDJSON record so the file
        # and the event stream can never drift. See docs/failure-schema.md.
        $failRec = New-SequenceFailureRecord -Reason 'step' -VMName $VMName -GuestKey $GuestKey -HostType $HostType -SequencePath $SequencePath -LogDir $logDir -TotalSteps $steps.Count
        $failureFile = Join-Path $logDir "last_failure.json"
        # Atomic write: a remediator/status reader must never observe a truncated
        # last_failure.json mid-write (partial-write regression class).
        $null = Write-YurunaStateFile -Path $failureFile -Content ($failRec.File | ConvertTo-Json -Depth 6) -Confirm:$false
        # One NDJSON line for stream consumers (status server, remediation loop, CI hook).
        Send-CycleEventSafely -EventRecord $failRec.Event

        # For non-OCR failures, capture a screenshot now (waitForText / waitForAndEnter
        # / passwdPrompt / fetchAndExecute already save one in their own failure paths).
        # Use the DEEPEST failed action's name -- after retry-exhausted, that's the inner
        # action, not 'retry' itself.
        if ($script:Fail.LastFailedAction -ne "waitForText" -and $script:Fail.LastFailedAction -ne "waitForAndEnter" -and $script:Fail.LastFailedAction -ne "passwdPrompt" -and $script:Fail.LastFailedAction -ne "fetchAndExecute") {
            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
            $captured = Get-VMScreenshot -VMName $VMName -OutFile $failScreenPath
            if ($captured) {
                Write-Information "      Failure screenshot saved: $failScreenPath"
            }
        }

        # Gate #3: post-failure pause check. Without this gate, a Pause-after-step
        # armed during the failing step is silently dropped and the caller
        # cascades the failure to the next sequence/cycle. Run AFTER writing
        # last_failure.json + the screenshot so the status UI shows the failure
        # context while the user decides whether to resume. Resuming does not
        # change the outcome -- the step is still a failure -- it only gives
        # the user time to investigate before the runner moves on.
        & $waitWhilePaused "[$($script:Fail.LastFailedStepNumber)/$($steps.Count)] FAIL"
        return $false
    }

    Write-ProgressTick -Activity "Sequence" -Completed
    $sequenceStopwatch.Stop()
    $sequenceElapsedLabel = ("{0,4}" -f [int]$sequenceStopwatch.Elapsed.TotalSeconds)
    $elapsedTotalSeconds = [int]$sequenceStopwatch.Elapsed.TotalSeconds
    $elapsedTimeIsMinutes = "$([int]($elapsedTotalSeconds / 60)) min and $($elapsedTotalSeconds % 60) s"
    Write-Information "    $sequenceElapsedLabel s [All $($steps.Count) steps completed in $elapsedTimeIsMinutes]"
    & $writeCurrentAction "[All $($steps.Count) steps completed in $elapsedTimeIsMinutes]"
    return $true

  } catch {
    # YurunaCycleRestart is a control-flow marker from the cycle-restart
    # gate ($checkCycleRestart), not an actual sequence failure. The gate
    # comment at Gate #2 promises it "bubbles up to the cycle-level try/
    # catch in Invoke-TestInnerRunner" — re-throw before the generic
    # handler turns it into a Write-Warning + return $false, which would
    # leave control.cycle-restart unconsumed and the flag re-fires on every
    # subsequent sequence's [sequence start] gate.
    if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
    # Print the message AND the throwing-statement origin AND the
    # call stack. Without these the operator gets only the .Exception
    # text (e.g. 'Exception calling "Replace" with "3" argument(s)')
    # and has to grep ten modules to find the actual throw.
    Write-Warning "    Invoke-Sequence unhandled error: $_"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Warning "    Origin:"
        foreach ($line in ($_.InvocationInfo.PositionMessage -split "`n")) {
            Write-Warning "      $line"
        }
    }
    if ($_.ScriptStackTrace) {
        Write-Warning "    Stack:"
        foreach ($line in ($_.ScriptStackTrace -split "`n")) {
            Write-Warning "      $line"
        }
    }
    # Preserve diagnostics for the crash, in the SAME schema-v2 shape
    # the normal failure path emits at line ~2195. Without this, a
    # throw from any verb Handler (or from infrastructure between
    # steps) silently downgrades last_failure.json from v2 to a v0
    # crash payload, stripping failureClass/severity/suggested
    # Recoveries -- the exact fields a downstream remediator routes
    # on. When $script:Fail.LastFailedAction was already captured by the
    # foreach at L~2162 we resolve its registry entry; otherwise we
    # fall back to the canonical 'unknown' classification (the same
    # fallback the per-step paths above use when a verb is unresolved)
    # so the record stays schema-v2 AND passes the failureClass/severity
    # enum validation in Test.EventSchema. The crash stays distinguishable
    # via the "engine crash: ..." action label, the crashError field, and
    # the .context.crash block -- a separate enum value carries no routing
    # weight, since the remediation dispatcher already maps 'unknown' to
    # pause-and-inspect.
    try {
        $failRec = New-SequenceFailureRecord -Reason 'crash' -VMName $VMName -GuestKey $GuestKey -HostType $HostType -SequencePath $SequencePath -LogDir $logDir -TotalSteps $steps.Count -CrashError $_
        # Atomic, best-effort: a reader must never see a truncated crash record.
        $null = Write-YurunaStateFile -Path (Join-Path $logDir "last_failure.json") -Content ($failRec.File | ConvertTo-Json -Depth 6) -Confirm:$false
        # Mirror the normal failure path NDJSON so a stream consumer does not see
        # the cycle go silent (last step_end but no step_failure).
        Send-CycleEventSafely -EventRecord $failRec.Event
    } catch {
        $writeErr = $_
        Write-Warning "Could not write last_failure.json: $($writeErr.Exception.Message)"
        Send-CycleEventSafely -EventRecord @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event     = 'last_failure_write_failed'
            path      = (Join-Path $logDir 'last_failure.json')
            error     = $writeErr.Exception.Message
        }
    }
    return $false
  }
}

# ── Host I/O provider registrations ─────────────────────────────────────────
# Lifted to per-host singular-noun modules:
#   Test.HostIO.HyperV.psm1   host.windows.hyper-v
#   Test.HostIO.Utm.psm1      host.macos.utm
#   Test.HostIO.Kvm.psm1      host.ubuntu.kvm
# Each module owns only its Register-HostIOProvider calls; the
# function bodies (Send-KeyHyperV / Send-KeyVNC / Send-KeyUTM /
# Send-KeyKvm / Send-TextHyperV / Send-TextVNC / Send-TextUTM /
# Send-TextKvm / Send-ClickHyperV / Send-ClickUtm) live in
# Test.Transport.psm1. The startup capability matrix reads
# Get-HostIOProviderMatrix so the operator sees which actions are
# wired on the current host before the cycle starts. See docs/host-io.md.

# ── Sequence action metadata registrations ──────────────────────────────────
# Failure-label scriptblock convention: $Context carries Step (parsed YAML
# step), Vars (variable scope), and ExpandVariable (live reference to
# Expand-Variable; we pass it in so the registry module does NOT have to
# import Invoke-Sequence). Each block reads $Context and returns the
# label string. Capability requirements (HostIORequirement + OcrRequired)
# are the same table Test.Capability used to carry.
#
# The catalog of built-in verb Handlers lives in
# Test.SequenceHandler.psm1, which is imported -Global at module load so
# its Register-SequenceAction side effects populate the same
# Test.SequenceAction registry the engine dispatches against. That
# catalog now includes retry and recoverFromSnapshot; the cross-module
# failure state they coordinate lives in the shared Test.SequenceFailureState
# store ($script:Fail), so this module stays the pure executor.

Export-ModuleMember -Function Invoke-Sequence, Invoke-SequenceByName, Send-Text, Send-Key, Send-Click, `
    Wait-ForText, Invoke-TapOn, Save-DebugScreenshot, Write-ProgressTick, Get-PollDelay, `
    Select-SequenceStepWindow, Get-SequenceFinishedVMName, Get-OcrDegradationGrace, `
    Get-DefaultKeystrokeMechanism, Set-EngineKeystrokeMechanism

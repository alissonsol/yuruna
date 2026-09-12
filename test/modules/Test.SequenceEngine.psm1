<#PSScriptInfo
.VERSION 2026.09.12
.GUID 4210c3aa-ab5b-4b2b-9259-5c68ad1cb72e
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
# external importers (Test.SequencePlanner / Test.SequenceRunner / Debug-TestSequence)
# resolve the moved functions transitively.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceResolve.psm1') -Global -Force

# --- REGION: Wire the host driver
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

# --- REGION: Load global defaults from test.config.yml
# The config file lives one level up from this module (test/test.config.yml).
$script:DefaultCharDelayMs      = 10
$script:DefaultVncPort          = 5900
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
# How long a handed-forward console baseline stays usable (see
# Set-CarriedConsoleBaseline). It has to cover the gap between one wait matching
# its prompt and the next wait starting -- Tab navigation, the typing itself and
# the step's settle delay, seconds in practice -- without covering so much that a
# whole further prompt exchange could have happened inside it. Past this the slot
# describes a console that may since have been replaced, and a wait falls back to
# reading its own first frame, which is never wrong, only late.
$script:CarriedConsoleBaselineMaxAgeSeconds = 120
# The console as it stood when the previous wait matched, handed to the next
# ${sinceStepStart} wait so it can tell what the guest printed in answer to the
# last thing typed. $null when there is nothing to hand on. Holds VMName so one
# guest's console can never seed another's, and the capture time so a slot left
# behind by a step that then did minutes of other work expires instead of
# describing a screen that has moved on.
$script:CarriedConsoleBaseline  = $null
# Ring-buffer depth for raw pre-OCR screen captures kept per VM (Wait-ForText).
# On guest success the buffer dir is deleted; on failure the whole sequence is
# preserved so the failure-screenshot link can point at the run-up to the bug.
#
# Measured in FRAMES but it has to be CHOSEN as a duration: what a reader needs
# is the window between the keystrokes that caused a failure and the frames that
# survive to be looked at. A poll pass is a screenshot plus an OCR pass plus a
# sidecar write on top of the pollSeconds sleep -- about 8 s of wall-clock per
# frame in practice -- so 20 frames is roughly two and a half minutes of console
# history, comfortably more than a multi-prompt credential exchange and the
# verdict that follows it have been measured to occupy together.
# A handful of frames spans well under a minute and evicts the keystrokes that
# explain the failure before the failure is even detected.
#
# The cost is disk, never memory: the ring holds file PATHS, while each frame on
# disk is a PNG plus its OCR sidecar (order 100 KB together). A guest that
# passes has the whole directory deleted; a guest that FAILS keeps its frames
# twice -- here and in the copy taken alongside the failure log -- and cycle-log
# rotation moves those folders into a history bucket rather than deleting them.
# So every extra frame is paid for twice, indefinitely, and only by hosts that
# fail.
$script:DefaultScreenHistorySize = 20

# Exponential-backoff helper for filesystem-state poll loops is
# centralized in Test.Backoff.psm1 (Get-PollDelay) so a tuning change
# lands once. Imported with -Global by Test.Prelude's module sets,
# so callers in this file resolve the function via the global scope.

# --- REGION: Progress wrapper
# Invoke-Sequence runs inline in the runner's interactive host (the cycle
# planner dispatches Invoke-SequenceByName directly from Test.Start-GuestOS /
# Test.Start-GuestWorkload -- no child pwsh in the path), so Write-Progress works
# natively. The wrapper stays so every call site funnels through one place.
function Write-ProgressTick {
    <#
    .SYNOPSIS
        Uniform Write-Progress wrapper for sequence-step heartbeats.
    .DESCRIPTION
        Forwards to Write-Progress with a -Completed shortcut. Kept as a
        thin wrapper so call sites stay uniform across hosts.
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
# Test.SequenceHandler.psm1 -- including retry and recoverFromSnapshot,
# whose failure slots live in the shared Test.SequenceFailureState store
# ($script:Fail), reachable from either module. Keeping the verb catalog
# local to Test.SequenceHandler means adding a verb does not collide with
# engine edits.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1') -Global -Force
# YURUNA_CONFIG_PATH wins over the in-tree template guess so a host running with
# `-ConfigPath <elsewhere>` seeds its vmCommunication.* defaults from the config
# it actually runs, not the in-tree template. Matches Test.Transport.
$_configPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } `
               else { Join-Path (Split-Path -Parent $PSScriptRoot) "test.config.yml" }
$_cfg = Read-TestConfig -Path $_configPath
if ($_cfg) {
    # test.config.yml keys live under the `vmCommunication` node
    # (`charDelayMs`, `vncPort`, `pollSeconds`, `screenHistorySize`,
    # `timeoutSeconds`); per-step
    # YAML in sequences still uses `charDelayMs` / `pollSeconds` /
    # `timeoutSeconds` to override these defaults for an individual step.
    $_comm = $_cfg.vmCommunication
    if ($_comm.charDelayMs)   { $script:DefaultCharDelayMs        = [int]$_comm.charDelayMs }
    if ($_comm.vncPort)            { $script:DefaultVncPort            = [int]$_comm.vncPort }
    if ($_comm.pollSeconds)        { $script:DefaultPollSeconds        = [int]$_comm.pollSeconds }
    if ($_comm.timeoutSeconds)     { $script:DefaultTimeoutSeconds     = [int]$_comm.timeoutSeconds }
    # Under `vmCommunication` with its siblings, not at the file root: the
    # template overlay is the schema and it DROPS every key the template does
    # not define, so a root-level key would be deleted from the operator's file
    # on the next reconciliation and the setting would silently revert to the
    # built-in default on the following cycle.
    # Tested with `$null -ne` rather than truthiness because 0 is a value an
    # operator can mean; the consumer clamps it into range instead of reading
    # it as "unset".
    if ($null -ne $_comm.screenHistorySize) { $script:DefaultScreenHistorySize = [int]$_comm.screenHistorySize }
}
Remove-Variable -Name _configPath, _cfg, _comm -ErrorAction SilentlyContinue

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
    Routes by HostType to the matching backend (Send-KeyHyperV; VNC-first
    then Send-KeyUTM on UTM; Send-KeyKvm). Yuruna.Host's Send-Key contract
    routes here so each host driver doesn't import the platform-specific
    helpers itself.
#>
    param([string]$HostType, [string]$VMName, [string]$KeyName)
    return (Invoke-HostIODispatch -HostType $HostType -Action 'Send-Key' -Arguments @{ VMName=$VMName; KeyName=$KeyName })
}

# --- REGION: Action: type / typeAndEnter
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


# --- REGION: Action: tapOn -- OCR-located mouse click
#
# Button-focus navigation via Tab keystrokes is brittle: initial focus depends
# on splash animation state, async-loaded widgets, and installer redesigns,
# so the "correct" Tab count drifts. tapOn sidesteps focus
# entirely -- it OCRs the VM screen, locates the button's bounding box, and
# synthesizes a mouse click at that box's center.
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

<#
.SYNOPSIS
    Runs OCR on an image, finds the bounding box of a button-label pattern,
    and returns its coordinates in the image's pixel space.
.DESCRIPTION
    Uses Tesseract TSV mode (word-level boxes) because TSV boxes are
    directly consumable -- Vision / WinRT don't surface per-word coords in
    our existing shims. For multi-word labels, requires contiguous words
    on the same line (y-diff within half a word height). Matching is
    case-insensitive substring so low-confidence words ("lnstall") still
    resolve.
.OUTPUTS
    Hashtable @{ x; y; w; h; centerX; centerY; text } or $null if not found.
#>
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
        # before saving -- otherwise SourcePath stays locked until GC runs.
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
    the label, and if found, click at the label's center. Falls back to
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
    # Pure eviction recovery: Test.YurunaDir is stateless (Initialize-YurunaLogDir is
    # env-backed; $env:YURUNA_LOG_DIR survives re-imports), so re-parse the psm1 only
    # when its command is actually unresolvable -- i.e. when a nested -Force evicted it
    # -- not on every hot-path pass. Gate on Get-Command, NOT Get-Module: Get-Module
    # stays truthy after an eviction moves the module into another scope, so it would
    # skip the very re-assert this exists to perform. (Stateful modules re-imported
    # nearby -- OcrEngine/Log/Ssh -- are deliberately left unconditional: their -Force
    # reload also resets $script: registrations/caches, a side effect gating would drop.)
    if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    }

    $logDir = Initialize-YurunaLogDir
    $capturePath = Join-Path $logDir "clickbutton_${VMName}.png"
    # Avoid '|' as the join separator -- Write-ProgressTick's marker uses '|'
    # as its field delimiter, and embedding one here would shift parsing on the
    # parent side. Write-ProgressTick sanitizes defensively, but keep the
    # display clean at the source too.
    $labelDisplay = $Label -join "' / '"
    # Wall-clock deadline. See the matching commentary in Wait-ForText for
    # why this is NOT an iteration counter -- on a slow Hyper-V host a
    # configured timeoutSeconds: 60 would expand to 3-5 minutes of wall-clock
    # when each iteration pays full screenshot + OCR cost on top of the
    # $PollSeconds sleep.
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
                Write-Debug "      Window capture unavailable -- retrying"
                Start-Sleep -Seconds $PollSeconds
                continue
            }

            foreach ($candidate in $Label) {
                $coord = Find-TextLocation -ImagePath $capture.ImagePath -Label $candidate
                if ($coord) {
                    $clickX = $coord.centerX + $OffsetX
                    $clickY = $coord.centerY + $OffsetY
                    Write-Debug "      Found '$candidate' at ($($coord.x),$($coord.y)) $($coord.w)x$($coord.h) -> click ($clickX, $clickY)"
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

        # Timeout -- preserve the final screenshot so the operator can see
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
# matcher actually saw -- invaluable for diagnosing "should have matched"
# regressions, since the ring-buffer .png alone leaves the reader to
# re-OCR the image to figure out why the pattern didn't fire.
#
# AllowEmptyCollection: a [Parameter(Mandatory)] typed-collection param
# rejects empty input with the misleading "Cannot bind argument ...
# because it is an empty string" error. The empty case happens when
# Test-CombinedOcrMatch returns no EngineResults (no providers ran on
# this frame); skipping the write is correct -- an empty sidecar would
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

# --- REGION: Action: waitForText
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

function Get-ConsoleFloodVerdict {
    <#
    .SYNOPSIS
        Is this console surface a repeating log line rather than a screen the
        sought pattern could still be read from? Pure, so the thresholds are
        testable without a VM.
    .DESCRIPTION
        The third content state a poll can be in. A blank capture is caught by
        the no-text counter; a capture that stopped changing is caught by the
        frame-hash freeze detector. A console scrolling one line escapes both:
        every frame differs, so the feed is provably live, and every frame is
        full of text, so there is nothing to self-heal. The pattern being sought
        has simply been pushed off the visible surface and cannot come back
        while the flood continues -- so the wait is already lost, and the record
        has to say which failure it was.

        Judged on LINE DIVERSITY, not on volume. A busy screen is not a flooded
        one: an installer printing many different lines is making progress and
        may yet print the pattern, while a surface whose lines are nearly all
        the same line is overwriting itself. Digits and runs of whitespace are
        normalized away first because the repeating line usually carries a
        counter or a timestamp, and because OCR of a framebuffer misreads
        characters differently in each frame -- comparing raw text would see
        variety that is only noise.

        Requires a minimum line count so a nearly-empty screen (two lines, both
        a prompt) cannot look like a flood.
    .PARAMETER Text
        The OCR text of one captured frame.
    .PARAMETER MinLines
        Fewest non-empty lines before diversity is meaningful.
    .OUTPUTS
        [hashtable] Flooded, TotalLines, DistinctLines, DominantLine,
        DominantCount.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$MinLines = 12
    )
    $verdict = @{
        Flooded = $false; TotalLines = 0; DistinctLines = 0
        DominantLine = ''; DominantCount = 0
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $verdict }

    $counts = @{}
    $total  = 0
    foreach ($raw in ($Text -split "`r?`n")) {
        # Normalize before counting: strip digits, collapse whitespace, fold
        # case. What survives is the line's shape, which is what repeats.
        $norm = ($raw -replace '\d+', '#') -replace '\s+', ' '
        $norm = $norm.Trim().ToLowerInvariant()
        # Very short fragments are OCR debris (a lone bracket, a stray glyph)
        # and would inflate the repeat count on any screen at all.
        if ($norm.Length -lt 8) { continue }
        $total++
        $counts[$norm] = 1 + ($counts[$norm] ?? 0)
    }
    $verdict.TotalLines    = $total
    $verdict.DistinctLines = $counts.Keys.Count
    if ($total -lt $MinLines -or $counts.Keys.Count -eq 0) { return $verdict }

    $ranked = @($counts.GetEnumerator() | Sort-Object -Property Value -Descending)
    $verdict.DominantLine  = [string]$ranked[0].Key
    $verdict.DominantCount = [int]$ranked[0].Value

    # Two independent conditions, both required.
    #
    # Diversity is the primary signal, and it scales with the evidence: a
    # 200-line screen may hold a couple of dozen shapes and still be repeating,
    # while a 12-line one has to be almost entirely uniform before the same
    # claim is safe.
    $fewDistinct = $counts.Keys.Count -le [math]::Max(2, [int][math]::Floor($total / 8))

    # Concentration across the TOP FEW lines, not the single most common one. A
    # real flood is a repeating UNIT rather than a repeating line: the observed
    # case alternates a start/finish pair, and OCR further splits each into
    # fragments, so no individual line reaches half the screen even when the
    # screen carries nothing else. Requiring one line to dominate therefore
    # misses exactly the shape this exists to catch, while the top few lines
    # covering most of the surface describes it precisely.
    $topCount = 0
    foreach ($e in ($ranked | Select-Object -First 3)) { $topCount += [int]$e.Value }
    $topConcentrated = $topCount -ge [int][math]::Ceiling($total * 0.7)

    $verdict.Flooded = ($fewDistinct -and $topConcentrated)
    return $verdict
}

function Get-ConsoleTextSignature {
    <#
    .SYNOPSIS
        Whitespace-normalized form of a console OCR capture, for equality
        comparison between two captures of the same screen.
    .DESCRIPTION
        Two captures of an unchanged console are not byte-equal: a blinking
        cursor, a redrawn status line and single-glyph OCR jitter all move
        characters around without the guest having printed anything. Collapsing
        runs of whitespace and trimming leaves a form that is stable across
        captures of a screen that has not actually changed, which is what makes
        "the console content stopped moving" measurable at all.
    .OUTPUTS
        [string] the normalized signature ('' for empty input).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)
    return (([string]$Text) -replace '\s+', ' ').Trim()
}

function Get-ConsoleLineSignature {
    <#
    .SYNOPSIS
        Per-line signatures of one console OCR capture, for asking later
        whether a given line was already on screen when it was taken.
    .DESCRIPTION
        Get-ConsoleTextSignature answers "has this screen changed" for a whole
        frame. A wait that must ignore what was already printed asks the
        narrower question per line instead, so the lines a guest prints during
        a step can be told from the ones it printed before the step began.

        Whitespace is collapsed for the reason it is collapsed there: a
        blinking cursor and the spurious spaces monospace OCR inserts move
        characters around on a line the guest has not touched, and raw equality
        reads that as freshly printed output.

        Lines that normalize to nothing carry no evidence and are dropped, so a
        frame that merely gains blank space does not read as new output.
    .PARAMETER Text
        The OCR text of one capture, split on newlines.
    .OUTPUTS
        [string[]] one signature per non-empty line, in screen order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [string[]]@() }
    $signatures = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (([string]$Text) -split "`n")) {
        $sig = Get-ConsoleTextSignature -Text $line
        if ($sig) { [void]$signatures.Add($sig) }
    }
    return [string[]]$signatures.ToArray()
}

function Set-CarriedConsoleBaseline {
    <#
    .SYNOPSIS
        Record the console a wait matched on, for the next wait to treat as
        already-seen.
    .DESCRIPTION
        A ${sinceStepStart} wait must ignore what was on screen before its step
        began. Reading that baseline off its own first frame dates it from the
        first poll AFTER the step started, which is one poll interval -- seconds
        -- later than the step actually began. A console answers far faster than
        that: a password prompt follows the Enter that earned it within
        milliseconds, so it lands in the frame the wait is about to treat as
        "what was already there" and is excluded from matching for the rest of
        the wait. The prompt is then on screen, unmatched and unanswerable,
        until the budget runs out, because a guest prints each prompt once.

        The fix is to date the baseline from the last thing the sequence KNOWS
        it saw: the frame the previous wait matched on. Everything after that --
        the echo of what was typed, and the prompt printed in reply -- is
        genuinely new, and stays eligible no matter how long the poll gap is.
    .PARAMETER VMName
        The guest whose console this is; a baseline is only ever handed to a
        wait on the same guest.
    .PARAMETER Text
        OCR text of the frame the wait matched on.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes one in-memory module slot on the wait hot path, touching nothing outside the process; ShouldProcess would put a -WhatIf gate on bookkeeping every caller needs unconditionally, and a skipped write would silently degrade the next wait rather than decline an action.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text
    )
    $script:CarriedConsoleBaseline = @{
        VMName    = $VMName
        Signature = [string[]]@(Get-ConsoleLineSignature -Text $Text)
        AtUtc     = [DateTime]::UtcNow
    }
}

function Clear-CarriedConsoleBaseline {
    <#
    .SYNOPSIS
        Drop any console baseline waiting to be handed on.
    .DESCRIPTION
        Carrying a baseline forward is only sound between waits that are
        consecutive steps of ONE sequence run, because the claim it encodes is
        "this is the screen the step before me left". Across a sequence boundary
        the claim is false: the guest may have rebooted, or another sequence may
        have driven the same VM in between, and a baseline from before that
        excludes lines the next wait must be free to match.

        Called where a run begins, so the first gated wait of a sequence reads
        its own first frame rather than inheriting a screen from whatever ran
        last. Callers that drive Wait-ForText directly, outside a sequence, do
        the same for the same reason.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Clears one in-memory module slot, touching nothing outside the process; a -WhatIf gate on it would leave a stale baseline in place, which is the unsafe state this exists to prevent.')]
    param()
    $script:CarriedConsoleBaseline = $null
}

function Get-CarriedConsoleBaseline {
    <#
    .SYNOPSIS
        Take the console baseline left by the previous wait, if it is this
        guest's and still current.
    .DESCRIPTION
        Consuming clears the slot, so a baseline is used at most once. That is
        what keeps a wait from being seeded by a frame two or more steps old:
        a stale exclusion set is the permissive direction -- it leaves lines
        eligible that a later step did NOT print in answer to anything -- which
        is the mis-targeting ${sinceStepStart} exists to prevent. Unconsumed or
        expired, the caller reads its own first frame instead.
    .PARAMETER VMName
        The guest about to wait.
    .OUTPUTS
        [string[]] line signatures, or $null when there is nothing usable.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$VMName)
    $carried = $script:CarriedConsoleBaseline
    $script:CarriedConsoleBaseline = $null
    if (-not $carried) { return $null }
    if ($carried.VMName -ne $VMName) { return $null }
    $age = ([DateTime]::UtcNow - $carried.AtUtc).TotalSeconds
    if ($age -gt $script:CarriedConsoleBaselineMaxAgeSeconds) { return $null }
    # An empty signature set means the matched frame read as blank. Handing that
    # on would exclude nothing, which is indistinguishable from having no
    # baseline at all -- and worse than reading this wait's own first frame,
    # which at least records whatever is legible now.
    if (@($carried.Signature).Count -eq 0) { return $null }
    return [string[]]$carried.Signature
}

function Select-ConsoleTextSinceBaseline {
    <#
    .SYNOPSIS
        The lines of a console OCR capture that are absent from a baseline
        capture taken earlier in the same wait.
    .DESCRIPTION
        A prompt is evidence a step can act on only when the guest prints it
        during that step. Text left on screen by whatever ran before is not,
        and it is re-read verbatim by every poll of every wait that follows.
        That matters because OCR-tolerant matching is deliberately generous:
        a short prompt pattern survives dropped and confused characters, and
        the same tolerance lets its letters be found in order inside a long
        line of unrelated prose. A password prompt is the sharpest case --
        matching one that is not really there types a secret into a terminal
        that is still echoing what it receives.

        Comparing by Get-ConsoleTextSignature rather than raw equality is
        load-bearing: OCR re-reads an untouched line with different spacing
        from one capture to the next, and raw equality would call the whole
        screen new on the second poll.

        Survivors are rejoined with newlines, never with spaces. The bounded
        matching strategies work one line at a time, so keeping the breaks
        keeps a match anchored to a single real line; fusing survivors would
        splice text printed at opposite ends of the screen into a neighborhood
        the matcher then reads as one phrase.
    .PARAMETER Text
        The current capture's OCR text.
    .PARAMETER BaselineSignature
        Get-ConsoleLineSignature of the capture taken when the step began. An
        empty baseline keeps the whole capture, so a wait whose first frame was
        unreadable degrades to an ordinary wait rather than to one that can
        never match.
    .PARAMETER TailLines
        When greater than 0, keep only the last N surviving lines, so a caller
        that also confines matching to the bottom of the screen applies that
        window to what survives here. Defaults to 0 (keep every survivor).
    .OUTPUTS
        [string] the surviving lines joined by newline ('' when none survive).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$BaselineSignature,
        [int]$TailLines = 0
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $known = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(@($BaselineSignature) | Where-Object { $_ }), [System.StringComparer]::Ordinal)
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (([string]$Text) -split "`n")) {
        $sig = Get-ConsoleTextSignature -Text $line
        if (-not $sig) { continue }
        if ($known.Contains($sig)) { continue }
        [void]$kept.Add([string]$line)
    }
    if ($TailLines -gt 0 -and $kept.Count -gt $TailLines) {
        return ([string]::Join("`n", ($kept.ToArray() | Select-Object -Last $TailLines)))
    }
    return ([string]::Join("`n", $kept))
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
    .PARAMETER SinceStepStart
        Restricts the positive pattern to console lines that were not already
        on screen when the wait began; $FailurePattern and $EarlyFailurePattern
        keep reading the whole frame. Composes with $FreshMatch, which then
        applies its tail window to the surviving lines. "When the wait began"
        is the frame the PREVIOUS wait matched on where one is available (see
        Set-CarriedConsoleBaseline), and this wait's own first frame otherwise.
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
        # Match the positive pattern only against console lines the guest
        # printed after this step began, ignoring everything the previous step
        # left on the surface. Set it on a step whose pattern is short enough
        # that unrelated prose already on screen can satisfy it -- a class the
        # tolerant matcher cannot avoid, because the same tolerance that lets a
        # prompt survive dropped and confused characters also lets its letters
        # be found in order inside a sentence about something else.
        #
        # Where the previous wait handed one on, the baseline is the frame THAT
        # wait matched, so a prompt printed in answer to what the step before
        # typed is new and matchable however long the poll gap was. Without one
        # -- the first gated step of a sequence, or one whose predecessor failed
        # -- it falls back to this wait's own first frame and costs a poll: that
        # frame records what was already there and only later frames can match.
        #
        # Anti-patterns are deliberately NOT gated by this. Their job is to
        # notice that the screen is in a state the sought text can never arrive
        # from, and that state is routinely already on screen when the step
        # starts -- so they keep reading the whole frame.
        [bool]$SinceStepStart = $false,
        # Optional periodic console nudge. This stays inside the same wall-clock
        # deadline as the OCR wait: it is for one-shot prompts (notably agetty's
        # login prompt) that can be scrolled off a live console and redrawn with
        # a harmless keypress. A dedicated sequence action supplies these
        # parameters so capability preflight can require Send-Key only when the
        # nudge is actually requested.
        [string]$NudgeKey = '',
        [int]$NudgeIntervalSeconds = 0,
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
        [string[]]$FailurePattern = @(),
        # Anti-patterns that are only meaningful for the first
        # $EarlyFailureSeconds of the wait, then stop being evaluated.
        #
        # The canonical use is a shell REJECTING the command line it was just
        # handed ("command not found", "No such file or directory"). That
        # verdict is delivered within a second of Enter and means nothing ever
        # started, so the positive pattern can never arrive and the whole
        # timeout would be spent proving it. The same strings are also ordinary
        # output from a script that IS running and healthy -- a package tool
        # probing for an optional binary prints them constantly -- so as
        # permanent anti-patterns they would abort good runs. The window is
        # what separates the two readings: inside it the only thing that has
        # had time to speak is the shell, outside it the answer is whatever the
        # payload is printing. That is why this cannot simply be folded into
        # $FailurePattern, whose entries are (correctly) evaluated for the
        # whole wait.
        [string[]]$EarlyFailurePattern = @(),
        [int]$EarlyFailureSeconds = 0
    )
    # Reset the cross-function signals so a prior call can't leak into the next
    # Wait-ForText invocation. Like WaitForTextMatchedFailurePattern, the cause
    # slots are populated ONLY at the failure return points below (not at entry),
    # so a SUCCESSFUL wait leaves them empty and cannot leak its sought-pattern
    # set into a later non-wait step's failure record.
    $script:Fail.WaitForTextMatchedFailurePattern = $null
    $script:Fail.WaitForTextOcrTail        = $null
    $script:Fail.WaitForTextPatternsSought = [string[]]@()
    $script:Fail.WaitForTextFreshWindowNearMiss = [string[]]@()
    # $null, not an empty list: the closest-line scan runs on the timeout path
    # only, so every other way out of this wait -- a match, a failure pattern --
    # leaves no reading, and an empty list would report one.
    $script:Fail.WaitForTextClosestOnScreen = $null
    $script:Fail.WaitForTextConsoleFlood   = $null
    $script:Fail.WaitForTextConsoleStaticSeconds = 0
    # Which of the two match paths below this wait will take, because only one of
    # them measures the console's shape. A tail-confined (freshMatch) wait reads
    # the same frames but runs neither the flood check nor the content-static
    # tracker, so the two slots above keep the values set here for the whole wait
    # -- and 0 / empty are the SAME values a wait that did measure a moving,
    # non-repeating console leaves behind. Published without this flag the pair
    # invites the one reading it cannot support: that something looked at the
    # screen and found it healthy. Recorded here rather than at the failure
    # returns so it is scoped to this wait exactly like the slots it qualifies.
    $script:Fail.WaitForTextConsoleSignalsMeasured = (-not $FreshMatch)
    # Per-wait verdict, readable by a caller that has to decide what to do with a
    # wait that came back false. The bool return says only "not found"; it cannot
    # distinguish a guest still working from a guest parked on a prompt that has
    # already scrolled off, and those two want opposite handling. Reset at entry so
    # a caller can never read a previous wait's shape.
    $script:LastWaitVerdict = @{
        Matched              = $false
        Flooded              = $false
        DominantLine         = ''
        ConsoleStaticSeconds = 0
        ConsoleRestartsUsed  = 0
        ElapsedSeconds       = 0
        ConsoleText          = ''
        NudgeAttempts        = 0
        ConsoleSignalsMeasured = (-not $FreshMatch)
    }
    if ($HostType) { Write-Debug "Wait-ForText: -HostType '$HostType' is informational; Yuruna.Host dispatches Get-VMScreenshot internally." }

    $patternLabel = $Pattern[0]
    # Wall-clock deadline -- NOT an iteration counter. Adding $PollSeconds per
    # loop pass would assume every iteration finishes in $PollSeconds of
    # wall-clock. In practice each iteration does a screenshot + tesseract OCR
    # + sidecar write before the Start-Sleep -Seconds $PollSeconds at the
    # bottom -- on a busy Hyper-V host that adds 5-25 s on top of the sleep, so
    # a configured timeoutSeconds: 1800 would take 1-3 hours of wall-clock to
    # expire (and multiplied by retry maxAttempts could exceed half a day
    # before giving up). With a wall-clock deadline timeoutSeconds means
    # exactly what the operator configured.
    $startUtc    = [DateTime]::UtcNow
    $deadlineUtc = $startUtc.AddSeconds($TimeoutSeconds)
    $elapsed     = 0
    $nudgeEnabled = (-not [string]::IsNullOrWhiteSpace($NudgeKey) -and $NudgeIntervalSeconds -gt 0)
    $nextNudgeUtc = if ($nudgeEnabled) { $startUtc.AddSeconds($NudgeIntervalSeconds) } else { $null }

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

    $enabledEngines = Get-EnabledOcrProvider
    $combineMode = Get-OcrCombineMode
    Write-Debug "      OCR engines: $($enabledEngines -join ', ') | combine: $combineMode"

    # Per-VM ring buffer of raw pre-OCR captures. Persists across multiple
    # Wait-ForText calls within a guest run so the failure path can surface
    # the run-up to the bug. Cleared at end-of-guest on success by the
    # runner; preserved on failure and copied alongside the failure log.
    # -Global on the -Force re-imports: a nested -Force without -Global
    # evicts the modules from the parent script's session state, so a
    # later top-level call to Get-CycleScreenDir (Invoke-TestRunnerInnerLoop.ps1
    # success branch, seen on macOS in-process runners) fails with
    # "term not recognized".
    # Pure eviction recovery: Test.YurunaDir is stateless (Initialize-YurunaLogDir is
    # env-backed; $env:YURUNA_LOG_DIR survives re-imports), so re-parse the psm1 only
    # when its command is actually unresolvable -- i.e. when a nested -Force evicted it
    # -- not on every hot-path pass. Gate on Get-Command, NOT Get-Module: Get-Module
    # stays truthy after an eviction moves the module into another scope, so it would
    # skip the very re-assert this exists to perform. (Stateful modules re-imported
    # nearby -- OcrEngine/Log/Ssh -- are deliberately left unconditional: their -Force
    # reload also resets $script: registrations/caches, a side effect gating would drop.)
    if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    }
    Import-Module (Join-Path $modulesDir "Test.Log.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir     = Initialize-YurunaLogDir
    # Ring buffer lives INSIDE the cycle folder so a stuck/restarted
    # runner can't overwrite it -- the next cycle gets its own folder.
    # Falls back to $logDir/screens_<VM>/ when no cycle folder is set.
    $screensDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false
    # Clamped at both ends. The floor is load-bearing: at 0 the trim loop below
    # evicts the frame captured on this very pass, before OCR can read it, so
    # the wait would never match anything. The ceiling bounds a typo -- each
    # retained frame is a PNG plus its OCR sidecar, kept twice over for a guest
    # that fails and never deleted by cycle-log rotation, so one extra digit
    # here is measured in gigabytes on a host that fails regularly.
    $historySize = [int]$script:DefaultScreenHistorySize
    if ($historySize -lt 1)   { $historySize = 1 }
    if ($historySize -gt 240) { $historySize = 240 }

    # Cross-poll fallback buffer for non-FreshMatch mode. A pattern can be split
    # at the OCR capture boundary between two ADJACENT frames (a line OCR'd half
    # in frame N, half in N+1). Keep only the last few frames' text, not the whole
    # growing history: the live frame is matched directly each poll, and once any
    # frame (or adjacent pair) matches the wait returns, so older frames are never
    # re-examined. A bounded ring keeps this O(1) per poll instead of the O(n^2)
    # a full-history rescan would cost over a 60-300 s loop.
    $recentFrameMax = 3
    $recentFrames   = [System.Collections.Generic.List[string]]::new()
    # Per-line signatures of the console as it stood on this wait's first
    # readable frame, plus the window applied on top of them. $FreshMatch
    # narrows the lines a pattern is tested against by POSITION on the screen;
    # $SinceStepStart narrows them by whether the guest printed them during this
    # step. Asked for together they compose -- the window applies to whatever
    # survives the baseline -- so each can only remove lines from what is
    # matched, never add any. $null (not an empty array) means "not recorded
    # yet": a screen that read as empty is a legitimate baseline and must not be
    # re-taken on the next poll.
    $sinceBaseline  = $null
    # Prefer the console the previous wait matched on over this wait's own first
    # frame: it dates the baseline from the last moment the sequence knows what
    # was on screen, instead of from a poll interval into the step, which is
    # already too late for a prompt printed in answer to the previous step's
    # keystroke. Consumed unconditionally, even by a wait that will not use it,
    # so it can only ever describe the wait immediately before this one.
    $carriedBaseline = Get-CarriedConsoleBaseline -VMName $VMName
    if ($SinceStepStart -and $carriedBaseline) {
        $sinceBaseline = $carriedBaseline
        Write-Verbose "      Wait-ForText: carrying $($sinceBaseline.Count) console line(s) from the previous wait as the baseline; '$($Pattern[0])' will be matched against anything printed since then."
    }
    $sinceTailLines = if ($FreshMatch) { $FreshMatchTailLines } else { 0 }
    $lastOcrText = ''
    $lastCapturePath = $null
    # Kept so the timeout path can ask, per engine, whether the sought text was
    # read but fell outside the freshMatch window. $lastOcrText alone cannot
    # answer that: it is every engine's text joined, so line offsets across the
    # join are meaningless and the window is a per-engine measurement.
    $lastEngineResults = $null
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
    # Flooded-console state (the poll loop's third content case). Neither
    # counter above can see it: the feed is live and full of text, and only the
    # text is useless. Counted in polls rather than wall-clock because what has
    # to persist is the CONTENT across independent captures, not a duration.
    $floodPolls    = 0
    $floodReported = $false
    # Content-static state (the console-parked signal, and the one the byte-hash
    # freeze detector below cannot supply). A live-but-idle console keeps a
    # blinking cursor, so its raw frames differ every capture while the CONTENT
    # has not moved for minutes -- which is exactly the shape of a guest waiting
    # on a prompt whose text has already scrolled out of the visible surface.
    # Measured on whitespace-normalized OCR text so cursor blink and single-glyph
    # OCR jitter do not read as movement.
    $lastStaticText        = $null
    $contentStaticSinceUtc = [DateTime]::UtcNow
    $maxConsoleStaticSecs  = 0
    # Degradation-trend early action: the two self-heals above are reactive at a fixed
    # threshold. Once the feed has proven flaky (a console restart fired), drop
    # the freeze threshold so the next stall is caught sooner -- acting on the
    # trend rather than re-waiting the full window. And grant the deadline a
    # bounded grace per self-heal so a feed that IS recovering isn't killed
    # mid-recovery by the original deadline (the false ocr_timeout); the cap
    # keeps a dead feed bounded. Each proactive action emits a `degradation`
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

            # OCR is fed the raw capture as-is -- no preprocessing. Do not
            # reintroduce a vertical-line / grayscale / invert / contrast-
            # stretch / 2x-scale pipeline, nor a diff-against-the-previous-
            # frame stage that suppresses unchanged pixels: both corrupt edge
            # cases (anti-aliased serifs collapsing, fresh text suppressed
            # when the surrounding pixels also changed). Tesseract / WinRT OCR
            # / macOS Vision all handle native-resolution color screenshots
            # fine.
            if ($rawScreenPath -and (Test-Path $rawScreenPath)) {
                if ($FreshMatch) {
                    # -- FreshMatch mode: only check the last N lines --
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
                    $lastEngineResults = $result.EngineResults

                    # Re-decide the combiner's verdict against the step-start
                    # baseline, rather than handing the combiner a filtered
                    # frame, so the whole surface stays available to everything
                    # else this loop does with it: the anti-pattern scan, the
                    # failure artifacts and the stall detectors all need the
                    # screen as it actually is.
                    if ($SinceStepStart) {
                        # Filtering the very frame the baseline was taken from
                        # leaves nothing, by construction -- which is exactly
                        # right: that frame IS what was already there.
                        if ($null -eq $sinceBaseline) {
                            $sinceBaseline = [string[]]@(Get-ConsoleLineSignature -Text ([string]$result.AnyText))
                            Write-Verbose "      Wait-ForText: $($sinceBaseline.Count) console line(s) were already on screen; '$patternLabel' will be matched only against lines printed after this."
                        }
                        $matchText = Select-ConsoleTextSinceBaseline -Text ([string]$result.AnyText) -BaselineSignature $sinceBaseline -TailLines $sinceTailLines
                        $sinceMatch = $false
                        if ($matchText) {
                            foreach ($p in $Pattern) {
                                if (Test-OCRMatch -Text $matchText -Pattern $p) { $sinceMatch = $true; break }
                            }
                        }
                        if ($result.Match -and -not $sinceMatch) {
                            Write-Verbose "      Wait-ForText: '$patternLabel' reads somewhere on screen, but on no line printed since this step began -- still waiting."
                        }
                        $result.Match = $sinceMatch
                    }

                    if ($result.Match) {
                        Write-Debug "      Text detected at end of screen (combine=$combineMode)"
                        Set-CarriedConsoleBaseline -VMName $VMName -Text ([string]$result.AnyText)
                        return $true
                    }
                } else {
                    # -- Non-FreshMatch mode: accumulate text, check for pattern --
                    $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $Pattern

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

                    # Re-decide the combiner's verdict against the step-start
                    # baseline, rather than handing the combiner a filtered
                    # frame, so the whole surface stays available to everything
                    # else this loop does with it: the anti-pattern scan, the
                    # failure artifacts and the stall detectors all need the
                    # screen as it actually is.
                    $matchText = [string]$result.AnyText
                    if ($SinceStepStart) {
                        # Filtering the very frame the baseline was taken from
                        # leaves nothing, by construction -- which is exactly
                        # right: that frame IS what was already there.
                        if ($null -eq $sinceBaseline) {
                            $sinceBaseline = [string[]]@(Get-ConsoleLineSignature -Text ([string]$result.AnyText))
                            Write-Verbose "      Wait-ForText: $($sinceBaseline.Count) console line(s) were already on screen; '$patternLabel' will be matched only against lines printed after this."
                        }
                        $matchText = Select-ConsoleTextSinceBaseline -Text ([string]$result.AnyText) -BaselineSignature $sinceBaseline -TailLines $sinceTailLines
                        $sinceMatch = $false
                        if ($matchText) {
                            foreach ($p in $Pattern) {
                                if (Test-OCRMatch -Text $matchText -Pattern $p) { $sinceMatch = $true; break }
                            }
                        }
                        if ($result.Match -and -not $sinceMatch) {
                            Write-Verbose "      Wait-ForText: '$patternLabel' reads somewhere on screen, but on no line printed since this step began -- still waiting."
                        }
                        $result.Match = $sinceMatch
                    }

                    if ($result.AnyText) {
                        $lastOcrText = $result.AnyText
                        $lastEngineResults = $result.EngineResults
                        # The cross-frame fallback below joins these, so they
                        # have to carry the same text the live frame was matched
                        # against -- otherwise a gated wait would match on the
                        # join what it just declined to match on the frame.
                        $recentFrames.Add([string]$matchText)
                        if ($recentFrames.Count -gt $recentFrameMax) { $recentFrames.RemoveAt(0) }
                        $normalizedNow = Get-ConsoleTextSignature -Text ([string]$result.AnyText)
                        if ($normalizedNow -ne $lastStaticText) {
                            $lastStaticText        = $normalizedNow
                            $contentStaticSinceUtc = [DateTime]::UtcNow
                        }
                        $staticSecs = [int]([DateTime]::UtcNow - $contentStaticSinceUtc).TotalSeconds
                        if ($staticSecs -gt $maxConsoleStaticSecs) { $maxConsoleStaticSecs = $staticSecs }
                        $script:LastWaitVerdict.ConsoleStaticSeconds = $staticSecs
                        $script:LastWaitVerdict.ConsoleText          = [string]$result.AnyText
                        $script:LastWaitVerdict.ElapsedSeconds       = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
                    }

                    if ($result.Match) {
                        Write-Debug "      Text detected (combine=$combineMode)"
                        $script:LastWaitVerdict.Matched = $true
                        Set-CarriedConsoleBaseline -VMName $VMName -Text ([string]$result.AnyText)
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
                            $script:LastWaitVerdict.Matched = $true
                            # The live frame, not the join the match was found
                            # in: the join spans several polls, and handing on a
                            # frame older than the newest one read would leave
                            # lines eligible that were already on screen.
                            Set-CarriedConsoleBaseline -VMName $VMName -Text ([string]$result.AnyText)
                            return $true
                        }
                    }

                    # Flooded-console detection, and a THIRD case distinct from
                    # both branches around it. The no-text branch below sees a
                    # feed with nothing on it; the byte-hash freeze detector
                    # further down sees a feed that stopped changing. A console
                    # scrolling one repeating log line is neither: every frame
                    # differs, so the feed looks perfectly healthy, and every
                    # frame is full of text, so AnyText is true -- while the
                    # pattern being sought has already scrolled out of the
                    # visible surface and is never coming back into it. Left
                    # unnamed this spends the entire timeout and is recorded as
                    # an ordinary pattern-never-printed, which sends the reader
                    # to the guest script that was in fact never reached.
                    #
                    # Recorded, NOT acted on: the wait still runs its full
                    # budget. A flood can stop, and aborting early on a
                    # heuristic would trade a slow correct answer for a fast
                    # wrong one. What changes is that the failure names itself.
                    $floodVerdict = Get-ConsoleFloodVerdict -Text ([string]$result.AnyText)
                    if ($floodVerdict.Flooded) {
                        $floodPolls++
                        # One burst is not a flood -- a legitimate screen can
                        # repeat a line while something else is mid-print. The
                        # signal is persistence across polls, each of which is a
                        # fresh capture seconds apart.
                        if ($floodPolls -ge 3 -and -not $floodReported) {
                            $floodReported = $true
                            $floodDetail = ("console filled with a repeating line while seeking '$patternLabel': " +
                                "$($floodVerdict.DistinctLines) distinct line(s) across $($floodVerdict.TotalLines) " +
                                "on screen, dominant line '$($floodVerdict.DominantLine)' x$($floodVerdict.DominantCount)")
                            $script:Fail.WaitForTextConsoleFlood = $floodDetail
                            $script:LastWaitVerdict.Flooded      = $true
                            $script:LastWaitVerdict.DominantLine = [string]$floodVerdict.DominantLine
                            Write-Warning "      Wait-ForText: $floodDetail -- the pattern cannot be read off a surface this is overwriting, so the wait will run its budget and the failure will be recorded as a flooded console rather than a missing pattern."
                            if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
                                Send-YurunaDegradation -Dependency 'console-content' -Primary 'readable-console' -Fallback 'none' `
                                    -Reason $floodDetail
                            }
                        }
                    } else {
                        $floodPolls = 0
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
                        # Only count a repair + grant deadline grace when a repair primitive
                        # actually exists and ran. A feed with NO self-heal available must not
                        # keep extending its own deadline (that masks a dead feed as recovering);
                        # record the degradation but let the normal budget expire.
                        $ringRepaired = $false
                        if (Get-Command Repair-VncConnection -ErrorAction SilentlyContinue) { [void](Repair-VncConnection -VMName $VMName -HostType $HostType -Confirm:$false); $ringRepaired = $true }
                        if (Get-Command Repair-ScreenshotRing -ErrorAction SilentlyContinue) { [void](Repair-ScreenshotRing -VMName $VMName -Confirm:$false); $ringRepaired = $true }
                        if ($ringRepaired) {
                            $ringRepairs++
                            Write-Verbose "      Wait-ForText: no OCR text for 4 polls; self-heal repair $ringRepairs/2 (clear VNC handle + screenshot ring)."
                            # Grant bounded grace so the reset feed can deliver text before the
                            # deadline, and record the degradation.
                            $grace = Get-OcrDegradationGrace -Action 'ring-repair' -AlreadyGrantedSeconds $deadlineGrantedSeconds -MaxGrantSeconds $maxDeadlineGrantSeconds -BaseWindowSeconds $frozenFeedSeconds
                            if ($grace -gt 0) { $deadlineUtc = $deadlineUtc.AddSeconds($grace); $deadlineGrantedSeconds += $grace }
                            if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
                                Send-YurunaDegradation -Dependency 'capture-feed' -Primary 'ocr-text-feed' -Fallback 'vnc-handle-reset' `
                                    -Reason "no OCR text 4 polls seeking '$patternLabel'; repair $ringRepairs/2, deadline +${grace}s"
                            }
                        } elseif (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
                            Send-YurunaDegradation -Dependency 'capture-feed' -Primary 'ocr-text-feed' -Fallback 'none' `
                                -Reason "no OCR text 4 polls seeking '$patternLabel'; no repair primitive available, deadline NOT extended"
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
                            # Trend-aware threshold: the first stall waits the
                            # full window, but once a restart has fired the feed
                            # is known-flaky, so catch the next stall at half the
                            # window instead of re-waiting the full one.
                            $effectiveFreezeThreshold = if ($consoleRestarts -gt 0) { [int][math]::Ceiling($frozenFeedSeconds / 2.0) } else { $frozenFeedSeconds }
                            if ($frozenSecs -ge $effectiveFreezeThreshold -and $consoleRestarts -lt $maxConsoleRestarts) {
                                $consoleRestarts++
                                $script:LastWaitVerdict.ConsoleRestartsUsed = $consoleRestarts
                                # Grant bounded grace so the relaunched viewer
                                # can deliver a fresh frame before the deadline.
                                $grace = Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds $deadlineGrantedSeconds -MaxGrantSeconds $maxDeadlineGrantSeconds -BaseWindowSeconds $frozenFeedSeconds
                                if ($grace -gt 0) { $deadlineUtc = $deadlineUtc.AddSeconds($grace); $deadlineGrantedSeconds += $grace }
                                Write-Verbose "      Wait-ForText: capture feed frozen (byte-identical ${frozenSecs}s, threshold ${effectiveFreezeThreshold}s) while still seeking '$patternLabel' -- forcing console reconnect (repair $consoleRestarts/$maxConsoleRestarts, deadline +${grace}s)."
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
            # The early set joins the permanent one only while the window is
            # open, so a match inside it reports through the same signal, the
            # same screenshot capture and the same failure label as any other
            # anti-pattern -- the window governs WHEN a pattern is consulted,
            # never what happens once it fires.
            $activeFailurePattern = @($FailurePattern)
            # The early set is matched without Test-OCRMatch's segment strategy.
            # Its members are short, ordinary phrases, and that strategy asks
            # only whether each of their words turns up somewhere on the screen
            # -- which a healthy step's own output supplies by accident as soon
            # as it prints a few KB of URLs or paths. A permanent anti-pattern
            # is chosen by a step author against the one script that step runs
            # and keeps the full matcher; these are matched against every guest
            # in the fleet, so they are held to evidence that sits on one line.
            $strictFailurePattern = @{}
            if ($EarlyFailurePattern.Count -gt 0 -and $elapsed -le $EarlyFailureSeconds) {
                foreach ($efp in $EarlyFailurePattern) {
                    $activeFailurePattern += $efp
                    if ($FailurePattern -notcontains $efp) { $strictFailurePattern[$efp] = $true }
                }
            }
            if ($activeFailurePattern.Count -gt 0 -and $lastOcrText) {
                foreach ($fp in $activeFailurePattern) {
                    if ([string]::IsNullOrWhiteSpace($fp)) { continue }
                    if (Test-OCRMatch -Text $lastOcrText -Pattern $fp -NoSegmentMatch:([bool]$strictFailurePattern[$fp])) {
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

            # Check positive and failure patterns BEFORE injecting input. A
            # crash screen must abort immediately rather than receive Enter,
            # and a prompt already visible must complete without one extra
            # redraw. Re-arm from the actual send time (not the prior target)
            # so a slow OCR pass cannot trigger a catch-up burst of keys.
            $nudgeNowUtc = [DateTime]::UtcNow
            if ($nudgeEnabled -and $nudgeNowUtc -ge $nextNudgeUtc) {
                $script:LastWaitVerdict.NudgeAttempts++
                Write-Verbose "      Wait-ForText: nudging console with '$NudgeKey' while seeking '$patternLabel' (elapsed ${elapsed}s / ${TimeoutSeconds}s)"
                $nudgeOk = [bool](Send-Key -HostType $HostType -VMName $VMName -KeyName $NudgeKey)
                if (-not $nudgeOk) {
                    # A failed recovery key must not turn an otherwise healthy
                    # wait into a false failure. Keep polling and try again at
                    # the next interval; the action's host-I/O preflight has
                    # already established that the transport exists.
                    Write-Warning "      Wait-ForText: console nudge '$NudgeKey' did not land; continuing OCR wait."
                }
                $nextNudgeUtc = $nudgeNowUtc.AddSeconds($NudgeIntervalSeconds)
            }

            Write-Debug "      Waiting for text '$patternLabel'... (${elapsed}s / ${TimeoutSeconds}s)"
            Start-Sleep -Seconds $PollSeconds
        }

        # Timeout -- preserve last screenshot, full sequence, and OCR text
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

        # How long the console content sat unchanged, at its longest. Separates a
        # guest that was working the whole time from one parked on an unreadable
        # screen, which the flood detail alone cannot do: Get-ConsoleFloodVerdict
        # counts repeats WITHIN one frame, so a frozen wall of already-scrolled
        # text reads as a flood even though nothing is moving.
        #
        # Only the accumulating match path feeds this. Under a tail-confined
        # match $maxConsoleStaticSecs is still its initializer, which is what the
        # measured flag set at entry exists to declare -- the value written here
        # is an observation only when that flag is true.
        $script:Fail.WaitForTextConsoleStaticSeconds = [int]$maxConsoleStaticSecs
        # The verdict deliberately keeps the CURRENT unchanged run rather than the
        # longest one: a caller deciding whether to send input to this console
        # cares about the state it is in now, and a screen that sat still early
        # and is scrolling again by the end is not a parked guest. The record
        # keeps the longest run, which is the better evidence after the fact.
        $script:LastWaitVerdict.ElapsedSeconds = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds

        # Before reporting "not found", check whether the engines actually read
        # it and the freshMatch window is what hid it. Reporting a bare timeout
        # in that case sends the operator to debug a guest that did its job, and
        # -- where the caller retries -- replays a step that already ran.
        if ($FreshMatch -and $lastEngineResults -and (Get-Command Get-OcrFreshWindowNearMiss -ErrorAction SilentlyContinue)) {
            [string[]]$nearMiss = @(Get-OcrFreshWindowNearMiss -EngineResult $lastEngineResults `
                -Pattern $Pattern -FreshMatchTailLines $FreshMatchTailLines)
            if ($nearMiss.Count -gt 0) {
                $script:Fail.WaitForTextFreshWindowNearMiss = $nearMiss
                foreach ($line in $nearMiss) {
                    Write-Warning "      freshMatch near miss: $line"
                }
            }
        }

        # An empty near-miss list covers three unrelated screens: no window was
        # in force, the window covered the whole frame, or the text was nowhere
        # on it. Read alone it is taken for the third. Recording what the screen
        # DID hold that came closest separates them, and on a frame too short
        # for a window to hide anything -- a console sitting at a login prompt
        # -- it is the only evidence there is. Deliberately not gated on
        # $FreshMatch: a wait with no window that timed out wants the same
        # answer, and pays for it once, here, not in the poll loop.
        if ($lastEngineResults -and (Get-Command Get-OcrClosestOnScreen -ErrorAction SilentlyContinue)) {
            [string[]]$closestOnScreen = @(Get-OcrClosestOnScreen -EngineResult $lastEngineResults -Pattern $Pattern)
            # Recorded even when it came back empty: the scan ran, and "compared
            # the frame, nothing resembled it" is a reading the record is
            # entitled to keep separate from "never compared anything".
            $script:Fail.WaitForTextClosestOnScreen = $closestOnScreen
            foreach ($closestLine in $closestOnScreen) {
                Write-Warning "      closest on screen: $closestLine"
            }
        }

        # An exhausted repair budget leaves an ambiguity the artifacts cannot
        # settle: a byte-identical capture can mean a guest that stopped
        # drawing or a capture pipeline that lost the live feed while the
        # guest kept going. Where the host driver can read the framebuffer
        # independently of the capture path, ask it, so the failure names the
        # side to investigate instead of leaving both under suspicion.
        if ($consoleRestarts -ge $maxConsoleRestarts -and (Get-Command Get-VMConsoleSecondOpinion -ErrorAction SilentlyContinue)) {
            try {
                $secondOpinion = Get-VMConsoleSecondOpinion -VMName $VMName
                if ($secondOpinion -and $secondOpinion.Verdict -ne 'unavailable') {
                    Write-Warning "      Console second opinion ($($secondOpinion.Verdict)): $($secondOpinion.Detail)"
                } elseif ($secondOpinion) {
                    Write-Verbose "      Console second opinion unavailable: $($secondOpinion.Detail)"
                }
            } catch {
                Write-Verbose "      Get-VMConsoleSecondOpinion failed: $($_.Exception.Message)"
            }
        }

        if ($deadlineGrantedSeconds -gt 0) {
            $waited = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            Write-Warning "Text '$patternLabel' not found within ${TimeoutSeconds}s (+${deadlineGrantedSeconds}s degradation grace; waited ~${waited}s)"
        } else {
            Write-Warning "Text '$patternLabel' not found within ${TimeoutSeconds}s"
        }
        return $false
    } finally {
        # Note: $screensDir is intentionally NOT cleared here -- it survives
        # across all Wait-ForText calls in a guest, and the runner deletes
        # it at end-of-guest on success (or surfaces it on failure).
        Write-ProgressTick -Activity "waitForText" -Completed
    }
}

function Get-LastWaitVerdict {
    <#
    .SYNOPSIS
        Shape of the most recent Wait-ForText call, for a caller deciding what
        to do about a wait that came back false.
    .DESCRIPTION
        Wait-ForText answers a bool, which says only that the pattern was not
        read. That single bit covers two opposite guests: one still working
        toward the state the pattern describes, and one parked on a prompt whose
        text has already scrolled out of the visible surface and will never come
        back into it. Only the second can be unblocked by sending input, so the
        signals that separate them -- how long the console content sat unchanged,
        whether the surface was a wall of one repeating line, how many capture
        repairs were already spent -- are published here rather than left in the
        engine's locals.

        Returns a copy: a caller that mutates the result cannot corrupt the
        engine's own view of the wait it just ran.
    .OUTPUTS
        [hashtable] Matched, Flooded, DominantLine, ConsoleStaticSeconds,
        ConsoleRestartsUsed, ElapsedSeconds, ConsoleText,
        ConsoleSignalsMeasured. The last one qualifies the three before it:
        $false means the wait confined its match to the console tail and ran
        neither console-shape tracker, so their values are initializers and a
        caller must not read a decision out of them.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if (-not $script:LastWaitVerdict) {
        return @{
            Matched              = $false
            Flooded              = $false
            DominantLine         = ''
            ConsoleStaticSeconds = 0
            ConsoleRestartsUsed  = 0
            ElapsedSeconds       = 0
            ConsoleText          = ''
            ConsoleSignalsMeasured = $true
        }
    }
    $copy = @{}
    foreach ($k in $script:LastWaitVerdict.Keys) { $copy[$k] = $script:LastWaitVerdict[$k] }
    return $copy
}

# The Pattern parameter of Test-CombinedOcrMatch is mandatory, and the console-
# change probe below has no pattern to seek -- it reads only the text the call
# harvests. This is the literal it passes so the match result is always false
# and the probe cannot be mistaken for a search.
$script:ConsoleChangeProbePattern = 'yuruna.console.change.probe'

function Wait-ForConsoleChange {
    <#
    .SYNOPSIS
        Poll the guest console until its content differs from $BaselineText.
    .DESCRIPTION
        The proof that input sent to an unreadable console landed: a guest
        parked on a prompt prints nothing until it is answered, so the content
        moving again is the answer being consumed. Content, not raw frames -- a
        parked console still blinks its cursor, so every raw capture differs
        while nothing has happened (the same reason Wait-ForText's byte-hash
        freeze detector cannot see a parked guest).

        Captures to a fixed probe file rather than the raw_*.png ring so a
        confirmation poll never displaces the failure run-up the ring exists to
        preserve.

        A $false answer covers two opposite consoles: one that did not move, and
        one this function could not read. Only the first says anything about the
        guest, so the counts that separate them are published through
        Get-LastConsoleChangeVerdict rather than collapsed into the bool.
    .OUTPUTS
        [bool] $true when the console content changed; $false on timeout or on
        a console that could not be read.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$HostType,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$BaselineText,
        [int]$TimeoutSeconds = 90,
        [int]$PollSeconds = 5
    )
    if ($HostType) { Write-Debug "Wait-ForConsoleChange: -HostType '$HostType' is informational; Yuruna.Host dispatches Get-VMScreenshot internally." }
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    if (-not (Get-Command Get-EnabledOcrProvider -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $modulesDir "Test.OcrEngine.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    }
    $baseline  = Get-ConsoleTextSignature -Text $BaselineText
    # Same guarded re-assert Wait-ForText makes: a nested -Force import elsewhere
    # can evict the directory helper from this session state, and a confirmation
    # that throws would take the step down with it instead of leaving it to fail
    # on its own terms.
    if (-not (Get-Command Get-CycleScreenDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $modulesDir "Test.Log.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    }
    $script:LastConsoleChangeVerdict = @{
        Changed        = $false
        Readable       = $false
        Polls          = 0
        Captures       = 0
        Reads          = 0
        TimeoutSeconds = $TimeoutSeconds
    }
    $screensDir = $null
    try { $screensDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false } catch { $screensDir = $null }
    if (-not $screensDir) {
        Write-Warning "      Wait-ForConsoleChange: no capture directory available; cannot confirm."
        return $false
    }
    # Short by intent, and not for tidiness: the directory is already per-VM, so
    # repeating the guest name in the file name only lengthens a path that a
    # native OCR reader has a hard ceiling on -- and a capture the reader cannot
    # open comes back as a console with no text on it, which is exactly the
    # answer this function exists to distinguish from a console that did not move.
    $probePath = Join-Path $screensDir 'probe.png'
    $deadline  = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    if ($PollSeconds -lt 1) { $PollSeconds = 1 }
    while ([DateTime]::UtcNow -lt $deadline) {
        $script:LastConsoleChangeVerdict.Polls++
        $captured = $false
        try { $captured = [bool](Get-VMScreenshot -VMName $VMName -OutFile $probePath) }
        catch { Write-Verbose "      Wait-ForConsoleChange: capture failed: $($_.Exception.Message)" }
        if ($captured -and (Test-Path -LiteralPath $probePath)) {
            $script:LastConsoleChangeVerdict.Captures++
            $probe = $null
            try { $probe = Test-CombinedOcrMatch -ImagePath $probePath -Pattern @($script:ConsoleChangeProbePattern) }
            catch { Write-Verbose "      Wait-ForConsoleChange: OCR failed: $($_.Exception.Message)" }
            if ($probe -and $probe.AnyText) {
                $script:LastConsoleChangeVerdict.Reads++
                $script:LastConsoleChangeVerdict.Readable = $true
                $now = Get-ConsoleTextSignature -Text ([string]$probe.AnyText)
                # An empty baseline would make any readable screen a "change",
                # which proves nothing about the input that was just sent.
                if ($baseline -and $now -ne $baseline) {
                    Write-Debug "      Wait-ForConsoleChange: console content changed."
                    $script:LastConsoleChangeVerdict.Changed = $true
                    return $true
                }
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    # Frames written and none of them read: every engine came back empty on a
    # file that was captured and confirmed present. That is the reader failing,
    # not the guest holding still, and reporting it as a console that did not
    # move would put the blame on a guest that may well have moved on.
    if ($script:LastConsoleChangeVerdict.Captures -gt 0 -and $script:LastConsoleChangeVerdict.Reads -eq 0) {
        $blindDetail = ("captured $($script:LastConsoleChangeVerdict.Captures) frame(s) in ${TimeoutSeconds}s and read text from none of them; " +
            "the console could not be read, so the console standing still was neither observed nor ruled out")
        Write-Warning "      Wait-ForConsoleChange: $blindDetail."
        if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
            Send-YurunaDegradation -Dependency 'console-content' -Primary 'readable-console' -Fallback 'none' `
                -Reason $blindDetail
        }
        return $false
    }
    Write-Debug "      Wait-ForConsoleChange: console content unchanged after ${TimeoutSeconds}s."
    return $false
}

function Get-LastConsoleChangeVerdict {
    <#
    .SYNOPSIS
        Shape of the most recent Wait-ForConsoleChange call, for a caller
        deciding what a $false answer actually proved.
    .DESCRIPTION
        Separates "the console did not move" from "the console could not be
        read", which the bool cannot: a reader that came back empty on every
        frame observed nothing about the guest, and a caller that reports it as
        the guest ignoring its input states something it does not know.

        Returns a copy, so a caller that mutates the result cannot corrupt the
        engine's own view of the probe it just ran.
    .OUTPUTS
        [hashtable] Changed, Readable, Polls, Captures, Reads, TimeoutSeconds.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if (-not $script:LastConsoleChangeVerdict) {
        return @{
            Changed        = $false
            Readable       = $false
            Polls          = 0
            Captures       = 0
            Reads          = 0
            TimeoutSeconds = 0
        }
    }
    $copy = @{}
    foreach ($k in $script:LastConsoleChangeVerdict.Keys) { $copy[$k] = $script:LastConsoleChangeVerdict[$k] }
    return $copy
}

# --- REGION: Action: takeScreenshot
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

# --- REGION: Main executor
function Invoke-SequenceByName {
    <#
    .SYNOPSIS
        Resolves a sequence name to its file and runs it.
    .DESCRIPTION
        Thin wrapper around Invoke-Sequence: takes a sequence NAME plus the
        sequences root, resolves it via Resolve-SequencePath (host-specific
        variant first, then the plain file), and delegates to Invoke-Sequence.
        Extension scripts that iterate over a list of sequence names should call
        this instead of building paths and calling Invoke-Sequence directly; the
        future config-driven runner can then reuse this function unchanged.
    #>
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
        # map = standalone Debug-TestSequence.ps1 invocation, keeps the
        # legacy "sequence-local variables win" path.
        # Use IDictionary (not [hashtable]) so an [ordered]@{} from the
        # planner keeps its insertion order through parameter binding.
        # A [hashtable] cast would coerce OrderedDictionary -> Hashtable
        # and lose the order, which then has the override loop below
        # process e.g. `currentPassword: ${ext:...(${username})}` BEFORE
        # `username: yauser1`. The `${username}` placeholder fails to
        # resolve and the literal string ends up as a vault key.
        [System.Collections.IDictionary]$EffectiveVariables,
        [switch]$ShowSensitive,
        # File-local 1-based start step, forwarded to Invoke-Sequence. The
        # runner's warm-resume path uses it to restart this single sequence at
        # its last-good step; default 1 = whole sequence (every other caller).
        [int]$StartStep = 1
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
        $list = Format-SequenceSearchList -Item $searched
        Write-Warning "[$GuestKey] Sequence file not found: $Name`nSearched (no match):`n$list"
        return $false
    }
    # Informational lines go through Write-Information, NOT Write-Output.
    # Write-Output emits to the pipeline, and combined with `return (...)`
    # below it would fold these strings into the caller's `$ok` variable --
    # turning the boolean into @("Running...", "Sequence file...", $true/$false).
    # The caller's `$ok -eq $false` still catches an honest $false inside
    # that array, but a returned $null (e.g. from an unhandled crash path)
    # would look identical to success. Keep the pipeline clean so the
    # return is strictly [bool].
    Write-Information "[$GuestKey] Running sequence: $Name on $HostType (VM: $VMName)" -InformationAction Continue
    Write-Verbose "    Sequence file: $sequenceFile"
    $result = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $sequenceFile -EffectiveVariables $EffectiveVariables -ShowSensitive:$ShowSensitive -StartStep $StartStep
    # Normalize: only $true is success. Anything else -- $null, objects,
    # arrays -- fails. A sane Invoke-Sequence returns $true / $false and
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
    <#
    .SYNOPSIS
        Slices a sequence's steps to an optional 1-based window, renumbered 1..N,
        so a step range can run without writing a sliced temp YAML.
    #>
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
# both the inner runner's Start-Guest* loops and Debug-TestSequence's chain runner.
function Get-SequenceFinishedVMName {
    <#
    .SYNOPSIS
        Returns the VM name in effect when the most recent Invoke-Sequence
        returned, including any mid-sequence saveDiskSnapshot rename.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string]$script:SequenceFinishedVMName
}

<#
.SYNOPSIS
    Runs a caller-supplied list of sequence names in order via Invoke-SequenceByName --
    the shared dispatcher body behind Start-GuestOS and Start-GuestWorkload.
.DESCRIPTION
    An empty list returns success/skipped so the caller's cycle step shows as skipped
    rather than failing. On a sequence failure it reads the last_failure.json sidecar
    (only when written DURING this sequence, gated on mtime) to surface the step
    location, and picks up a mid-sequence saveDiskSnapshot rename -- e.g. a baseline
    ending in saveDiskSnapshot before a dependent workload sequence loads it -- so the
    next sequence targets the renamed VM. -PhaseLabel is the only value that varies
    between the two callers: it prefixes the generic failure message ('Start' or 'Workload').
    Returns @{ success; skipped; errorMessage }.
#>
function Invoke-GuestSequenceList {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PhaseLabel,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string[]]$SequenceNames = @(),
        [System.Collections.IDictionary]$EffectiveVariables,
        # Warm-resume: skip every sequence before ResumeFromSequence (they passed
        # on the prior attempt), restart ResumeFromSequence at ResumeFromStep, and
        # run the rest from step 1. Default ('' / 1) runs the whole list normally.
        [string]$ResumeFromSequence = '',
        [int]$ResumeFromStep = 1
    )
    if (-not $SequenceNames -or $SequenceNames.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    $resuming      = -not [string]::IsNullOrEmpty($ResumeFromSequence)
    $reachedResume = -not $resuming
    foreach ($s in $SequenceNames) {
        if ($resuming -and -not $reachedResume) {
            if ($s -eq $ResumeFromSequence) {
                $reachedResume = $true
            } else {
                Write-Information "  Skipping (passed before warm-resume point): $s" -InformationAction Continue
                continue
            }
        }
        $thisStart = if ($resuming -and $s -eq $ResumeFromSequence) { [int]$ResumeFromStep } else { 1 }
        Write-Information ("  Running: $s" + $(if ($thisStart -gt 1) { " (warm-resume at step $thisStart)" } else { '' })) -InformationAction Continue
        $seqStartUtc = [DateTime]::UtcNow
        $ok = Invoke-SequenceByName -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencesDir $SequencesDir -RepoRoot $RepoRoot -Name $s -EffectiveVariables $EffectiveVariables -StartStep $thisStart
        if (-not $ok) {
            $errMsg = "$PhaseLabel sequence '$s' failed"
            # -Global: a nested -Force without -Global evicts Test.YurunaDir from
            # the parent script's session state, breaking later top-level calls.
            $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
            # Pure eviction recovery for the stateless Test.YurunaDir -- re-parse only
            # when its command is actually unresolvable (gate on Get-Command, not the
            # eviction-blind Get-Module).
            if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
            }
            $logDir = Initialize-YurunaLogDir
            $failFile = Join-Path $logDir "last_failure.json"
            if (Test-Path $failFile) {
                try {
                    # Trust last_failure.json only when it was written DURING this
                    # sequence: a stale file from an earlier sequence (or a prior
                    # same-cycle attempt) would misattribute its step location to
                    # '$s' and send triage to the wrong step. Gate on the mtime
                    # advancing past this sequence's start (2s clock tolerance).
                    $failItem = Get-Item -LiteralPath $failFile -ErrorAction Stop
                    if ($failItem.LastWriteTimeUtc -ge $seqStartUtc.AddSeconds(-2)) {
                        $failInfo = Get-Content -Raw $failFile | ConvertFrom-Json
                        $errMsg = "Step [$($failInfo.stepNumber)/$($failInfo.totalSteps)] $($failInfo.action) - $($failInfo.description) (sequence: $s)"
                    } else {
                        Write-Verbose "last_failure.json predates sequence '$s'; using the generic message rather than a stale step location."
                    }
                } catch {
                    Write-Verbose "Could not parse failure details: $_"
                }
            }
            return @{ success=$false; skipped=$false; errorMessage=$errMsg }
        }
        Write-Information "  ${s}: PASS" -InformationAction Continue
        # Pick up a mid-sequence saveDiskSnapshot rename so the next sequence in the
        # list targets the renamed VM -- the same Get-SequenceFinishedVMName mechanism
        # Debug-TestSequence's chain runner uses. No-op when nothing renamed.
        $finishedVm = Get-SequenceFinishedVMName
        if ($finishedVm -and $finishedVm -ne $VMName) {
            Write-Information "  VM renamed mid-chain: '$VMName' -> '$finishedVm'." -InformationAction Continue
            $VMName = $finishedVm
        }
    }
    if ($resuming -and -not $reachedResume) {
        # The resume target is not in this list -- refuse to report success (every
        # sequence would have been silently skipped). The runner re-derives the
        # target from last_failure.json, so this only trips on a bad call.
        return @{ success=$false; skipped=$false; errorMessage="warm-resume target sequence '$ResumeFromSequence' not found in the workload list" }
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
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
        # verbatim (standalone Debug-TestSequence.ps1 path).
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

    # Sequences are flat and self-describing: gui vs ssh is chosen by the
    # sequence's own `keystrokeMechanism` and encoded in its own steps (OCR vs
    # sshExec), and the caller already resolved the exact file by name -- so
    # there is no machine-global mode redirect here.

    if (-not (Test-Path $SequencePath)) {
        # Missing sequence file = setup error. A silent-skip return of
        # $true would mask sequence-name typos and bad mode resolution
        # as test successes.
        Write-Warning "    Sequence file not found: $SequencePath"
        return $false
    }

    # No wait in this run may inherit a console baseline from whatever drove
    # this VM before it. Handing one forward asserts "this is what the step
    # before me left on screen", and only a wait inside the same run can make
    # that claim -- the guest may have been rebooted or rebuilt since.
    Clear-CarriedConsoleBaseline

    # Initialize logDir + trackDir early so the catch block can write
    # diagnostics and the pause-flag paths resolve below. Invoke-Sequence
    # runs inside a child module scope when a test-start extension script
    # imports it, so the parent runner's global Import-Module doesn't
    # propagate here -- each helper has to be re-imported on this path.
    # -Global on the -Force re-imports: without it, the nested reload
    # evicts these modules from the parent script's session state and
    # breaks subsequent top-level calls (see Get-CycleScreenDir crash).
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    # Pure eviction recovery: Test.YurunaDir is stateless (Initialize-YurunaLogDir is
    # env-backed; $env:YURUNA_LOG_DIR survives re-imports), so re-parse the psm1 only
    # when its command is actually unresolvable -- i.e. when a nested -Force evicted it
    # -- not on every hot-path pass. Gate on Get-Command, NOT Get-Module: Get-Module
    # stays truthy after an eviction moves the module into another scope, so it would
    # skip the very re-assert this exists to perform. (Stateful modules re-imported
    # nearby -- OcrEngine/Log/Ssh -- are deliberately left unconditional: their -Force
    # reload also resets $script: registrations/caches, a side effect gating would drop.)
    if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    }
    Import-Module (Join-Path $modulesDir "Test.Ssh.psm1")      -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir = Initialize-YurunaLogDir

  try {
    $sequence = Read-SequenceFile -Path $SequencePath

    # Clean up stale failure artifacts from any prior run
    Remove-Item (Join-Path $logDir "last_failure.json") -Force -ErrorAction SilentlyContinue

    # Build variables table: built-ins first, then YAML-defined entries
    # evaluated EAGERLY in file order (full contract:
    # docs/test-sequences.md#variable-substitution-rules -- the Markdown
    # is the contract). ${ext:...} in a value runs once at definition
    # time, so pinning a generated value across steps is an explicit,
    # file-visible operation. Planner overrides (-EffectiveVariables)
    # REPLACE same-named YAML entries; ${hostname} is seeded from
    # -VMName and overwritten by the sequence's variables: block or the
    # cascade when declared.
    $vars = @{ "vmName" = $VMName; "hostType" = $HostType; "guestKey" = $GuestKey; "hostname" = $VMName }
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
    # Auto-derive ${hostLabel}: the host name a guest's own console prints,
    # which is not ${hostname}. ${hostname} defaults to the VM name, and a VM
    # name carries dots -- test-guest.ubuntu.server.26-01 -- while agetty and a
    # shell prompt both print only the first label, "test-guest". The full name
    # appears on the console in exactly one place, the /etc/issue banner, so a
    # pattern built from ${hostname} matches only while that banner is on
    # screen and stops matching the moment it scrolls, even though the prompt
    # it is waiting for is still sitting there. A wait like that cannot fail
    # fast: it spends its entire budget and is recovered only by a retry that
    # redraws the banner.
    #
    # Derived after the override merge so it follows whatever hostname is
    # actually in force, and only when unset, so a sequence or a cascade can
    # still name it outright.
    if (-not $vars.ContainsKey('hostLabel') -and $vars.ContainsKey('hostname')) {
        $vars['hostLabel'] = ([string]$vars['hostname']).Split('.')[0]
    }

    # Auto-derive ${loginUser} from the resolved ${username} via the
    # authentication extension's users.yml mapping. The sequence file
    # is free to declare its own `loginUser` under variables: (or pass
    # one in via the cascade) -- only the unset case is auto-filled.
    # Empty corporate fields in users.yml mean loginUser == username
    # (the local-only case); a populated corporate mapping renders
    # DOMAIN\sam or upn@domain.com.
    if (-not $vars.ContainsKey('loginUser') -and $vars.ContainsKey('username')) {
        try {
            # Import the extension area lazily; the planner / runner has
            # usually already loaded it, but standalone Debug-TestSequence
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
    # never ran (e.g. a direct Debug-TestSequence.ps1 invocation outside the
    # runner), so this block is safe to call unconditionally. The raw YAML
    # body is snapshotted so a row's sequenceContentHash can be mapped
    # back to the exact sequence that ran. Each invocation gets its own
    # identity even when another VM later reuses the same name and sequence.
    $sequenceInvocationId = $null
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
            $sequenceInvocationId = Set-PerfSequenceContext -SequenceName $seqName -SequenceGuid $seqGuid -SequenceRevision $seqRevision -SequenceContent $seqBody -PassThru
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

    # Step-pause back-channel: the status service's /control/step-pause
    # endpoint creates $env:YURUNA_RUNTIME_DIR/control.step-pause. We gate
    # on that file in two places:
    #   1. Before sequence setup (here, below) -- so Restart-VMConnect and any
    #      per-sequence work don't run while paused, and the very first
    #      action of a new sequence can't start while paused. This matters
    #      most between two sequences (e.g. Test-Start -> Test-Workload, or
    #      one guest's workload -> the next guest's workload), where a Pause
    #      click would otherwise only take effect after the next sequence had
    #      already started its first action.
    #   2. At the top of each step iteration (further below) -- so a click
    #      mid-sequence takes effect before the next action.
    # Empty-steps sequences have already returned above, so the sequence-
    # level wait here never triggers for a sequence that has nothing to do.
    # Cycle-pause (control.cycle-pause) is gated separately in
    # Start-TestRunner.ps1 at cycle boundaries -- Invoke-Sequence is only
    # concerned with step-level pauses.
    $runtimeDir = Initialize-YurunaRuntimeDir
    $stepPauseFlagFile = Join-Path $runtimeDir 'control.step-pause'
    # Cycle-restart back-channel: the status service's /control/start-cycle
    # endpoint sets this flag while it kills in-progress VMs. The inter-
    # cycle delay loop in Invoke-TestRunnerInnerLoop already breaks on it, but
    # if the request lands while a cycle is actively executing steps the
    # delay loop never sees it -- the cycle limps through screenshot
    # failures of deleted VMs and the operator's "restart now" never
    # arrives. Gating here too makes the abort fire from inside an active
    # cycle: the throw escapes through retry / sequence / runner and is
    # recognized by the inner's cycle-catch by the message prefix.
    $cycleRestartFlagFile = Join-Path $runtimeDir 'control.cycle-restart'

    # Current-action sidecar: write the in-progress step to a small JSON file
    # that the status service can serve at /runtime/current-action.json. The UI
    # polls it alongside status.json and renders the line under the matching
    # guest card. We write at the top of each iteration (so the UI sees the
    # step that's about to run, not the one that just finished) and once more
    # at the end of a successful sequence with the "[All N steps completed]"
    # summary.
    $currentActionFile = Join-Path $runtimeDir 'current-action.json'
    # $Code names a branchable condition; $Line is the sentence a person reads.
    # They are separate because every reader of this sidecar used to recover the
    # condition by matching the sentence -- the status page and the pool
    # aggregator both tested for "Paused (waiting for resume)" -- which makes
    # the English wording a wire format that cannot be reworded or translated
    # without breaking a consumer in another language. A reader now branches on
    # the code and renders whatever prose it likes.
    $writeCurrentAction = {
        # Line is what a reader sees when nothing can render the code -- an old
        # page, a log tail, a transcript. Code and Label are what a surface that
        # CAN render reads: the sentence comes from its own catalog and the
        # label is data, so the reader's language is decided where the reader
        # is rather than here.
        param([string]$Line, [string]$Code = '', [string]$Label = '')
        $attempts = 0
        $lastErr  = $null
        while ($attempts -lt 3) {
            $attempts++
            try {
                $doc = [ordered]@{
                    guestKey  = $GuestKey
                    vmName    = $VMName
                    line      = $Line
                    code      = $Code
                    label     = $Label
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
    #
    # This gate holds the RUNNER, not the guest: the VM is created and started
    # before the sequence begins, so it keeps running -- and printing -- for as
    # long as the hold lasts. Anything the guest prints once and does not reprint
    # (a boot-time confirmation prompt) can therefore expire while parked here,
    # and the step that was going to read it resumes against a screen that no
    # longer carries it. Both ends of the hold are published to the event stream
    # so a failure that follows one can be read as such instead of as a guest
    # that never printed; see docs/control-routes.md, "Pause and resume".
    $waitWhilePaused = {
        param([string]$Label)
        if (Test-Path $stepPauseFlagFile) {
            # The status service stamps the flag file with the moment the operator
            # armed it, so the hold can be reported against the request rather than
            # against the first gate that happened to observe it.
            $requestedAtUtc = ''
            try {
                $stamp = [string](Get-Content -LiteralPath $stepPauseFlagFile -Raw -ErrorAction Stop)
                $requestedAtUtc = $stamp.Trim()
            } catch {
                Write-Verbose "pause flag stamp unreadable: $($_.Exception.Message)"
            }
            $pauseSeqName = [System.IO.Path]::GetFileNameWithoutExtension($SequencePath)
            $pauseCommon = @{
                pauseScope     = 'step'
                label          = [string]$Label
                guestKey       = [string]$GuestKey
                vmName         = [string]$VMName
                sequenceName   = [string]$pauseSeqName
                requestedAtUtc = [string]$requestedAtUtc
            }
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                # Emitted on entry as well as on release: a hold still open when the
                # runner dies leaves no release event, and an unpaired begin is the
                # only record that the run was parked rather than stuck.
                Send-CycleEventSafely -EventRecord ($pauseCommon + @{
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event     = 'sequence_paused'
                })
            }
            & $writeCurrentAction "$Label Paused (waiting for resume)" 'sequence_paused_waiting_resume' $Label
            Write-Information "    $Label Paused (status-service request). Waiting for resume..."
            $heldFromUtc  = [DateTime]::UtcNow
            $pauseAttempt = 1
            while (Test-Path $stepPauseFlagFile) {
                Start-Sleep -Milliseconds (Get-PollDelay -Attempt $pauseAttempt)
                $pauseAttempt++
            }
            $heldSeconds = [int]([DateTime]::UtcNow - $heldFromUtc).TotalSeconds
            Write-Information "    $Label Resumed after ${heldSeconds}s."
            # Handed to the failure record so a step that fails right after a long
            # hold reports the hold as part of its cause. Read by
            # New-SequenceFailureRecord; harmless on the passing path, where
            # nothing consults it.
            $script:Fail.LastPauseRelease = @{
                releasedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                heldSeconds   = $heldSeconds
                label         = [string]$Label
                pauseScope    = 'step'
            }
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord ($pauseCommon + @{
                    timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event       = 'sequence_resumed'
                    heldSeconds = $heldSeconds
                })
            }
        }
    }

    # Cycle-restart gate. Throws a control-flow marker so the inner
    # runner's cycle-catch (see Invoke-TestRunnerInnerLoop.ps1) can short-
    # circuit emergency-cleanup chatter and skip the ConsecutiveCrashes
    # increment for this expected abort. The flag is intentionally NOT
    # cleared here: the post-cycle inter-cycle delay loop will consume it
    # on its next tick, which keeps the existing "wake delay early" path
    # working unchanged. If the inner is already past the delay (i.e.
    # actively running this sequence), the throw propagates up through
    # any enclosing retry / step / sequence frames straight to the cycle
    # try/catch.
    #
    # The marker is carried BOTH as an Exception.Data tag and as the
    # 'YurunaCycleRestart:' message prefix. Consumers prefer the structured
    # tag, which survives a rewrap that a downstream `throw "wrapped: $_"`
    # would strip from the message; the prefix stays as the fallback so any
    # reader still matching on the message routes this abort correctly.
    $checkCycleRestart = {
        param([string]$Label)
        if (Test-Path $cycleRestartFlagFile) {
            & $writeCurrentAction "$Label cycle-restart requested (aborting cycle)"
            Write-Information "    $Label cycle-restart signal seen -- aborting current cycle."
            $restart = [System.Management.Automation.RuntimeException]::new("YurunaCycleRestart: status-service /control/start-cycle requested mid-cycle abort at $Label")
            $restart.Data['YurunaCycleRestart'] = $true
            throw $restart
        }
    }

    # Lab-health gate: hold here while a lab service this host HAD been
    # reaching has stopped answering, and resume when it returns. A service
    # that was never reachable is deliberately not a hold -- see
    # Test.LabHealth -- so a host with no stash still fails fast in the
    # caller's own pre-flight rather than parking on its first cycle.
    #
    # Get-Command-guarded: an entry point whose module set omits Test.LabHealth
    # runs ungated, which is the behavior every caller had before the gate and
    # is a better failure mode than a step that cannot start.
    $waitWhileLabHealthy = {
        param([string]$Label)
        if (-not (Get-Command Invoke-LabHealthGate -ErrorAction SilentlyContinue)) { return }
        # Stage name derived here rather than read from $seqName: that variable
        # is only assigned inside the perf-context block, so a run with
        # Test.Perf absent would name the failure record after nothing.
        $labStage = [System.IO.Path]::GetFileNameWithoutExtension($SequencePath)
        $null = Invoke-LabHealthGate -Label $Label -HostType $HostType -Stage $labStage `
            -WriteAction $writeCurrentAction -CheckAbort $checkCycleRestart -WaitWhilePaused $waitWhilePaused
    }

    # Gate #1: sequence-level pause + cycle-restart check, before any per-
    # sequence work. Pause is checked first so an operator-initiated pause
    # that overlaps a restart click still resolves predictably (pause
    # wins until released, then the restart flag is observed). The lab-health
    # hold sits between them: an operator who has parked the cycle is present
    # and outranks a machine-initiated hold, and re-probing a lab nobody is
    # watching achieves nothing.
    # Cleared here rather than with the other per-sequence cause slots further
    # down: those run AFTER this gate, and the hold this gate is about to record
    # is the one most worth reporting -- it ends with the guest already booted and
    # a step about to read a screen that moved on without the runner.
    $script:Fail.LastPauseRelease = $null
    & $waitWhilePaused "[sequence start]"
    & $waitWhileLabHealthy "[sequence start]"
    & $checkCycleRestart "[sequence start]"

    # HACK: Force vmconnect to repaint by reconnecting.
    # After a host reboot the Hyper-V console window may render blank;
    # closing and reopening it forces a full framebuffer refresh.
    # Yuruna.Host's Restart-VMConsole is in scope here because
    # Initialize-YurunaHost is called by Debug-TestSequence.ps1 /
    # Start-TestRunner.ps1 before sequences run. Guard it like the other contract calls so a
    # missing/failed host contract degrades to "no repaint" instead of crashing the sequence.
    if (Get-Command Restart-VMConsole -ErrorAction SilentlyContinue) {
        try { [void](Restart-VMConsole -VMName $VMName -Confirm:$false) }
        catch { Write-Verbose "      Restart-VMConsole failed: $($_.Exception.Message)" }
    }

    # takeScreenshot debug PNGs land under test/status/captures/sequences/
    # (gitignored runtime data, lives with the rest of the harness state
    # so cleaning a host is one rm -rf status/* away). Sequence name is
    # prefixed onto each filename in Save-DebugScreenshot, so a single
    # flat folder keeps captures organized without a per-sequence subdir.
    # Anchor on $PSScriptRoot (this module lives at <TestRoot>/modules/);
    # $SequencePath is unreliable as an anchor because the chain runner
    # writes per-entry slices to the OS temp dir and project-tree
    # sequences live under <RepoRoot>/project/.../test/.
    $testRoot = Split-Path -Parent $PSScriptRoot
    $screenshotDir = Join-Path -Path $testRoot -ChildPath 'status' `
                         -AdditionalChildPath 'captures', 'sequences'
    $sequenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # --- REGION: Recursive step executor
    # Wrapped as a script-block so the `retry` action case (below) can call
    # it on its inner `steps:` array, reusing the full per-step
    # infrastructure: pause checks, currentAction sidecar, progress ticks,
    # variable expansion, the action switch, PASS/FAIL logging. The block
    # resolves $vars, $writeCurrentAction, $waitWhilePaused,
    # $waitWhileLabHealthy, $HostType,
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
            [string]$ParentAction = '',
            # Which attempt of that retry these rows belong to (1-based; 0
            # outside a retry). A retry re-runs the SAME steps: block, so every
            # attempt emits the same ordinals under the same step names. With
            # nothing but the ordinal on the row, a reader cannot separate a
            # later attempt's rows from the first attempt's, and a step first
            # reached in a later attempt reads as though it ran beside the
            # first attempt's failure.
            [int]$ParentAttempt = 0
        )
        $stepNum = 0
        foreach ($step in $Steps) {
            $stepNum++
            # Gate #2: between-steps pause + cycle-restart check. Catches
            # a Pause or a "Save and start cycle" clicked while the previous
            # step was running. The throw inside $checkCycleRestart escapes
            # this $invokeStepBlock (including any wrapping `retry` block --
            # retry only catches $false returns, not exceptions) and bubbles
            # up to the cycle-level try/catch in Invoke-TestRunnerInnerLoop.
            & $waitWhilePaused "[$stepNum/$($Steps.Count)]"
            & $waitWhileLabHealthy "[$stepNum/$($Steps.Count)]"
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
            # verb; its Handler lives in Test.SequenceHandler.psm1 next
            # to its Register-SequenceAction.

        # Current-step visibility is intentionally driven by Write-Progress
        # (via Write-ProgressTick below), NOT by a Write-Information here.
        # A Write-Information at step-start would go through the Yuruna.Log
        # proxy and leave a permanent line in both the terminal and the log
        # transcript -- then the end-of-step completion line (with elapsed
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
        $stepInvocationId = [Guid]::NewGuid().ToString('N')
        $ctx = $null
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
                SnapshotPolicy        = $sequence.snapshotPolicy
                SequenceInvocationId  = $sequenceInvocationId
                StepInvocationId      = $stepInvocationId
                # Served-repo root (== the base the host status service serves at
                # /yuruna-repo). fetchAndExecute/sshFetchAndExecute use it to
                # hash the working-tree copy of the script the guest is about to
                # fetch, so the guest can verify the bytes before running them.
                RepoRoot              = $repoRoot
                ExpandVariable        = ${function:Expand-Variable}
                # Step-default param resolution lives in each handler
                # scriptblock; these mirror the engine's $script:Default*
                # values.
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

        # Normalize $ok. Anything that isn't a strict [bool] -- $null, an
        # accidentally-polluted pipeline array, a string, an exception object
        # wrapped by a catch -- is treated as failure. Without this, helpers
        # that forget to `return $true`/`return $false` (or that leak a stray
        # Write-Output) silently pass the step despite a timeout.
        if ($ok -isnot [bool]) {
            $okType = if ($null -eq $ok) { '<null>' } else { $ok.GetType().Name }
            Write-Warning "    Step [$stepNum] action '$($step.action)' returned a non-boolean ($okType) -- treating as failure."
            $ok = $false
        }

        $stepStopwatch.Stop()
        $elapsedLabel = ("    {0,4}" -f [int]$stepStopwatch.Elapsed.TotalSeconds)
        $stepMarker   = if ($ok) { 'PASS' } else { 'FAIL' }
        Write-Information "$elapsedLabel s [$stepNum/$($steps.Count)] $stepMarker $($step.action): $desc"

        # One NDJSON line per step_end so a downstream consumer can plot
        # pass/fail rates without HTML scraping. Carries the SUPERSET
        # schema (hostType, action, description, and -- on a failure --
        # the verb's registered defaults, under their own names) of
        # step_failure so a downstream consumer can do a single schema
        # join across step_end + step_failure rows.
        $stepEndRecord = @{
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
            sequencePath        = $SequencePath
            sequenceInvocationId = $sequenceInvocationId
            stepInvocationId    = $stepInvocationId
        }
        $diagnosticOutcome = if ($ctx -and $ctx.DiagnosticOutcome) { [string]$ctx.DiagnosticOutcome } else { '' }
        $checkpointSourceStepInvocationId = if ($ctx -and $ctx.CheckpointSourceStepInvocationId) { [string]$ctx.CheckpointSourceStepInvocationId } else { '' }
        $evidenceCaptureDurationMs = if ($ctx -and $ctx.EvidenceCaptureDurationMs) { [long]$ctx.EvidenceCaptureDurationMs } else { 0L }
        if ($diagnosticOutcome) { $stepEndRecord.diagnosticOutcome = $diagnosticOutcome }
        if ($evidenceCaptureDurationMs -gt 0) { $stepEndRecord.evidenceCaptureDurationMs = $evidenceCaptureDurationMs }
        # A verb's registration states how it classifies ITS OWN failure, so it
        # belongs only on a row that actually failed. Stamped on a passing row
        # it leaves `ok` as the single field that separates a real failure from
        # a static registration, and every grep, Loki selector and dashboard
        # filter for a class then matches once per executed step of that verb --
        # all of them passes. Nothing is lost by omitting it: actionVerb is on
        # the row, and Get-SequenceAction maps it back to the same registration
        # for a consumer that wants to know what the verb WOULD have classed a
        # failure as.
        #
        # The verbDefault* names say the other half: these are the registry's
        # values for the verb, not a reading of what went wrong here, while
        # step_failure publishes a real classification under failureClass /
        # severity / suggestedRecoveries -- one that a matched failure pattern
        # or an unreachable guest can move off the registration entirely. One
        # key over both would make a join across the two rows compare a
        # measurement against a constant and call them the same field.
        if (-not $ok) {
            $stepVerbEntry = Get-SequenceAction -Name ([string]$step.action)
            $stepFailureClass = if ($stepVerbEntry) { [string]$stepVerbEntry.FailureClass } else { 'unknown' }
            $stepSeverity     = if ($stepVerbEntry) { [string]$stepVerbEntry.Severity }     else { 'unknown' }
            # Avoid the dual unwrap trap: PowerShell flattens single-element
            # arrays AND empty arrays out of an if-statement's pipeline
            # output, so `[string[]]$x = if (...) { @(...) }` yields a scalar
            # on a 1-element value and $null on an empty value. The two-step
            # form below initializes to an empty string[] up front, then
            # overwrites only when there are entries to materialize; either
            # outcome serializes as a JSON array and clears the schema
            # validator's typed-array check.
            [string[]]$stepSuggested = @()
            if ($stepVerbEntry -and $null -ne $stepVerbEntry.SuggestedRecoveries) {
                [string[]]$stepSuggested = @($stepVerbEntry.SuggestedRecoveries)
            }
            $stepEndRecord['verbDefaultFailureClass']        = $stepFailureClass
            $stepEndRecord['verbDefaultSeverity']            = $stepSeverity
            $stepEndRecord['verbDefaultSuggestedRecoveries'] = $stepSuggested
        }
        Send-CycleEventSafely -EventRecord $stepEndRecord
        # Track the last passing step number so the failure payload can
        # surface lastSucceededStepNumber -- a remediator that wants to
        # replay needs to know the boundary it can safely resume past.
        if ($ok) { $script:Fail.LastSucceededStepNumber = $stepNum }

        # Emit one structured row per step execution. stepName is the
        # RAW (pre-expansion) YAML `description:` -- variables like
        # ${vmName} are intentionally NOT expanded here so cross-cycle
        # joins on stepName remain stable even though vmName carries a
        # per-cycle timestamp suffix. Falls back to step.action when no
        # description is set. A retry emits its enclosing interval and final
        # outcome as well as the children; readers count only top-level rows
        # when summing work and final failures.
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
                    -ParentAction      $ParentAction `
                    -ParentAttempt     $ParentAttempt `
                    -StepInvocationId  $stepInvocationId `
                    -CheckpointSourceStepInvocationId $checkpointSourceStepInvocationId `
                    -EvidenceCaptureDurationMs $evidenceCaptureDurationMs `
                    -DiagnosticOutcome $diagnosticOutcome
            } catch {
                Write-Verbose "Write-PerfStepRow failed (non-fatal): $($_.Exception.Message)"
            }
        }

        if (-not $ok) {
            Write-Warning "    Step [$stepNum] failed: $desc"

            # Build a human-readable failed-step label (e.g. 'waitForText: "login prompt"').
            # Canonical builder: Test.SequenceAction\Get-SequenceActionFailureLabel.
            # Each verb's FailureLabel scriptblock lives next to its capability
            # requirements in Test.SequenceHandler.psm1 -- search for
            # Register-SequenceAction. The OUTER call site reads $script:Fail.Last-
            # Failure* below to write last_failure.json + the failure screen-
            # shot. Capturing here (and only returning $false) keeps transient
            # retry-attempt failures from leaving a stale last_failure.json
            # behind.
            $actionLabel = Get-SequenceActionFailureLabel -Step $step -Vars $vars -ExpandVariable ${function:Expand-Variable}

            # If a wait-signal verb short-circuited on a failurePattern,
            # annotate the step label so the runner's ERROR banner and the
            # per-run failure JSON both say *why* the step died instead of
            # the generic "pattern not found within Ns". The set of verbs
            # that populate this signal is declared per-verb via the
            # UsesWaitSignals registry flag (Register-SequenceAction), so a
            # new wait verb opts in at its registration rather than editing
            # this engine site. For other actions the signal is $null and
            # the label is unchanged.
            $stepUsesWaitSignals = $false
            if (-not [string]::IsNullOrEmpty([string]$step.action)) {
                $waitSignalEntry = Get-SequenceAction -Name ([string]$step.action)
                if ($waitSignalEntry) { $stepUsesWaitSignals = [bool]$waitSignalEntry.UsesWaitSignals }
            }
            if ($stepUsesWaitSignals -and $script:Fail.WaitForTextMatchedFailurePattern) {
                $actionLabel = $actionLabel + " -- matched failurePattern `"$($script:Fail.WaitForTextMatchedFailurePattern)`""
            }

            $script:Fail.LastFailureLabel       = $actionLabel
            $script:Fail.LastFailureDescription = $desc
            $script:Fail.LastFailedAction       = $step.action
            $script:Fail.LastFailedStepNumber   = $stepNum
            # The boundary the failure record judges the per-VM screen artifacts
            # against: those files at the log root are sticky and only the verbs
            # that read a screen rewrite them, so one last written before this
            # step began shows an earlier step and is not this failure's
            # evidence. A retry wrapper overwrites this with its own (earlier)
            # start as the stack unwinds, which is what keeps an attempt's own
            # screen claimable by the exhausted-retry failure that followed it.
            $script:Fail.LastFailedStepStartedUtc = $stepStartUtc
            return $false
        }
        }  # end foreach inside $invokeStepBlock
        return $true
    }  # end $invokeStepBlock

    $script:Fail.LastFailureLabel       = $null
    $script:Fail.LastFailureDescription = $null
    $script:Fail.LastFailedAction       = $null
    $script:Fail.LastFailedStepNumber   = 0
    $script:Fail.LastFailedStepStartedUtc = $null
    # Inner-verb capture for retry-exhausted failures. The per-step failure
    # branch in $invokeStepBlock overwrites $script:Fail.LastFailedAction with
    # the OUTER step's action name (= 'retry') whenever a Handler returns
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
        # Capture a screenshot now unless the failed verb already saved one
        # in its own failure path (avoids overwriting the verb's richer,
        # in-context frame with a later capture). Which verbs self-capture
        # is declared per-verb via the CapturesOwnFailureScreenshot registry
        # flag (Register-SequenceAction), so a new self-capturing verb opts
        # out here at its registration rather than editing this engine site.
        # Use the DEEPEST failed action's name -- after retry-exhausted, that's the inner
        # action, not 'retry' itself.
        $failedVerbSelfCaptures = $false
        if (-not [string]::IsNullOrEmpty([string]$script:Fail.LastFailedAction)) {
            $failedVerbEntry = Get-SequenceAction -Name ([string]$script:Fail.LastFailedAction)
            if ($failedVerbEntry) { $failedVerbSelfCaptures = [bool]$failedVerbEntry.CapturesOwnFailureScreenshot }
        }
        if (-not $failedVerbSelfCaptures) {
            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
            $captured = Get-VMScreenshot -VMName $VMName -OutFile $failScreenPath
            # Confirm the file landed before advertising it: Get-VMScreenshot can
            # report truthy without writing the file, so verify it is on disk
            # before logging -- the capture and Wait-ForText failure paths in this
            # module gate on Test-Path the same way.
            if ($captured -and (Test-Path $failScreenPath)) {
                Write-Information "      Failure screenshot saved: $failScreenPath"
            }
        }

        # Built after the capture above, not before it: the record names the
        # screen artifacts this failure left behind and only claims one that is
        # already on disk and newer than the failing step, so a record built
        # first would have to describe a frame that does not exist yet.
        # New-SequenceFailureRecord reads the $script:Fail slots and returns
        # both the last_failure.json ordered dict and the matching step_failure
        # NDJSON record so the file and the event stream can never drift. See
        # docs/failure-schema.md.
        $failRec = New-SequenceFailureRecord -Reason 'step' -VMName $VMName -GuestKey $GuestKey -HostType $HostType -SequencePath $SequencePath -LogDir $logDir -TotalSteps $steps.Count
        $failureFile = Join-Path $logDir "last_failure.json"
        # Atomic write: a remediator/status reader must never observe a truncated
        # last_failure.json mid-write (partial-write regression class).
        $null = Write-YurunaStateFile -Path $failureFile -Content ($failRec.File | ConvertTo-Json -Depth 6) -Confirm:$false
        # One NDJSON line for stream consumers (status service, remediation loop, CI hook).
        Send-CycleEventSafely -EventRecord $failRec.Event
        # Mirror it into the cycle folder in the same breath. The copy above
        # lives at the SHARED log root, which the next sequence start clears --
        # so on a cycle that runs several guests and does not stop at the first
        # failure, this record is deleted before the cycle-end notifier, the
        # remediation dispatcher or a post-hoc reader ever looks at it.
        if (Get-Command Copy-CycleFailureRecord -ErrorAction SilentlyContinue) {
            $null = Copy-CycleFailureRecord -LogDir $logDir
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
    $elapsedTotalSeconds = [long][math]::Floor($sequenceStopwatch.Elapsed.TotalSeconds)
    $elapsedTimeIsMinutes = "$([math]::Floor($elapsedTotalSeconds / 60)) min and $($elapsedTotalSeconds % 60) s"
    Write-Information "    $sequenceElapsedLabel s [All $($steps.Count) steps completed in $elapsedTimeIsMinutes]"
    & $writeCurrentAction "[All $($steps.Count) steps completed in $elapsedTimeIsMinutes]"
    return $true

  } catch {
    # YurunaCycleRestart is a control-flow marker from the cycle-restart
    # gate ($checkCycleRestart), not an actual sequence failure. The gate
    # comment at Gate #2 promises it "bubbles up to the cycle-level try/
    # catch in Invoke-TestRunnerInnerLoop" -- re-throw before the generic
    # handler turns it into a Write-Warning + return $false, which would
    # leave control.cycle-restart unconsumed and the flag re-fires on every
    # subsequent sequence's [sequence start] gate. Prefer the structured
    # Exception.Data tag (survives a rewrap that would strip the message
    # prefix); fall back to the message prefix so an untagged marker from an
    # older throw path still re-throws instead of being counted as a crash.
    if (($_.Exception.Data -and $_.Exception.Data['YurunaCycleRestart']) -or
        ($_.Exception.Message -like 'YurunaCycleRestart:*')) { throw }
    # An exhausted lab hold is a classified infra failure, not a crash. The gate
    # has already written last_failure.json as 'lab_dependency_down' and the
    # crash record below writes unconditionally -- reaching it would replace a
    # record naming the missing service with a generic 'unknown' crash, at
    # exactly the layer the remediation dispatcher routes on. Report and return
    # $false so the sequence fails through the caller's ordinary path with the
    # gate's record intact.
    if (($_.Exception.Data -and $_.Exception.Data['YurunaLabDependencyDown']) -or
        ($_.Exception.Message -like 'YurunaLabDependencyDown:*')) {
        Write-Warning "    Sequence stopped: $($_.Exception.Message)"
        return $false
    }
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
    # the normal failure path emits above. Without this, a
    # throw from any verb Handler (or from infrastructure between
    # steps) silently downgrades last_failure.json from v2 to a v0
    # crash payload, stripping failureClass/severity/suggested
    # Recoveries -- the exact fields a downstream remediator routes
    # on. When $script:Fail.LastFailedAction was already captured by the
    # per-step failure branch we resolve its registry entry; otherwise we
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
        # Same cycle-folder mirror the step path takes: a crash record at the
        # shared log root is cleared by the next sequence start like any other.
        if (Get-Command Copy-CycleFailureRecord -ErrorAction SilentlyContinue) {
            $null = Copy-CycleFailureRecord -LogDir $logDir
        }
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

# --- REGION: Host I/O provider registrations
# Registered in per-host singular-noun modules:
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

# --- REGION: Sequence action metadata registrations
# Failure-label scriptblock convention: $Context carries Step (parsed YAML
# step), Vars (variable scope), and ExpandVariable (live reference to
# Expand-Variable; we pass it in so the registry module does NOT have to
# import Invoke-Sequence). Each block reads $Context and returns the
# label string. Capability requirements (HostIORequirement + OcrRequired)
# ride in the same registry entries; Test.Capability reads them from there.
#
# The catalog of built-in verb Handlers lives in
# Test.SequenceHandler.psm1, which is imported -Global at module load so
# its Register-SequenceAction side effects populate the same
# Test.SequenceAction registry the engine dispatches against. That
# catalog includes retry and recoverFromSnapshot; the cross-module
# failure state they coordinate lives in the shared Test.SequenceFailureState
# store ($script:Fail), so this module stays the pure executor.

Export-ModuleMember -Function Invoke-Sequence, Invoke-SequenceByName, Send-Text, Send-Key, Send-Click, `
    Wait-ForText, Invoke-TapOn, Save-DebugScreenshot, Write-ProgressTick, `
    Select-SequenceStepWindow, Get-SequenceFinishedVMName, Get-OcrDegradationGrace, `
    Get-ConsoleFloodVerdict, Invoke-GuestSequenceList, Get-ConsoleTextSignature, `
    Get-ConsoleLineSignature, Select-ConsoleTextSinceBaseline, `
    Set-CarriedConsoleBaseline, Get-CarriedConsoleBaseline, Clear-CarriedConsoleBaseline, `
    Get-LastWaitVerdict, Wait-ForConsoleChange, Get-LastConsoleChangeVerdict

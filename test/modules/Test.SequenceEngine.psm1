<#PSScriptInfo
.VERSION 2026.10.18.2
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RunnerHeartbeat.psm1') -DisableNameChecking
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
# See https://yuruna.link/4213a0b3-011d
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_67f9991e2652e324' -Arguments @{ message = "$($_.Exception.Message)" })
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
# See https://yuruna.link/4213a0b3-011e
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
    if ($null -ne $_comm.charDelayMs) { $script:DefaultCharDelayMs = [int]$_comm.charDelayMs }
    if ($_comm.vncPort)            { $script:DefaultVncPort            = [int]$_comm.vncPort }
    if ($_comm.pollSeconds)        { $script:DefaultPollSeconds        = [int]$_comm.pollSeconds }
    if ($_comm.timeoutSeconds)     { $script:DefaultTimeoutSeconds     = [int]$_comm.timeoutSeconds }
    # See https://yuruna.link/4213a0b3-011f
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
# See https://yuruna.link/4213a0b3-0120


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
        $boxes = @(Get-TesseractWordBox -ImagePath $ImagePath | ForEach-Object { $_ })
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_afe15df7c41fff0a' -Arguments @{ value = "$_" })
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d8523930547c291e' -Arguments @{ value = "$_" })
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
    # See https://yuruna.link/4213a0b3-0121
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
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4333edb4f597ba98' -Arguments @{ failScreenPath = "$failScreenPath" })
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f82bcebaee6fc7b8' -Arguments @{ labelDisplay = "$labelDisplay"; timeoutSeconds = "${TimeoutSeconds}" })
        return $false
    } finally {
        Remove-Item $capturePath -Force -ErrorAction SilentlyContinue
        Write-ProgressTick -Activity "tapOn" -Completed
    }
}

# See https://yuruna.link/4213a0b3-0122
function Save-OcrSidecar {
    <# .SYNOPSIS
        Save the raw OCR provider results beside their screenshot.
    #>
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

function Test-RecentOcrFramesMatch {
    [OutputType([bool])]
    param(
        [hashtable]$Frames, $EngineResults, [string[]]$EnabledEngines,
        [string[]]$Pattern, [string]$CombineMode, [int]$MaxFrames = 3,
        [switch]$SinceBaseline, [string[]]$Baseline, [int]$TailLines = 0,
        [switch]$NoSegmentMatch
    )
    $engineMatches = @()
    foreach ($engine in $EnabledEngines) {
        if (-not $Frames.ContainsKey($engine)) { $Frames[$engine] = [Collections.Generic.List[string]]::new() }
        $text = if ($EngineResults.Contains($engine)) { [string]$EngineResults[$engine].Text } else { '' }
        if ($SinceBaseline) { $text = Select-ConsoleTextSinceBaseline -Text $text -BaselineSignature $Baseline -TailLines $TailLines }
        $Frames[$engine].Add($text)
        while ($Frames[$engine].Count -gt $MaxFrames) { $Frames[$engine].RemoveAt(0) }
        $joined = [string]::Join("`n", $Frames[$engine])
        $matched = $false
        foreach ($wanted in $Pattern) {
            if (Test-OCRMatch -Text $joined -Pattern $wanted -NoSegmentMatch:$NoSegmentMatch) { $matched = $true; break }
        }
        $engineMatches += $matched
    }
    if ($engineMatches.Count -eq 0) { return $false }
    if ($CombineMode -eq 'And') { return $false -notin $engineMatches }
    return $true -in $engineMatches
}

function Save-EngineOcrSidecar {
    <#
    .SYNOPSIS
        Save each engine's text and match status beside its captured frame.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScreenshotPath, [Parameter(Mandatory)]$EngineResults,
        [switch]$VerboseSummary)
    $sections = [Collections.Generic.List[string]]::new()
    foreach ($name in $EngineResults.Keys) {
        $engine = $EngineResults[$name]
        $text = [string]$engine.Text
        $status = if ($engine.Matched) { "MATCH '$($engine.MatchedPattern)'" } else { 'no match' }
        if ($VerboseSummary) {
            $snippet = if ($text.Length -le 120) { $text } else { '...' + $text.Substring($text.Length - 120) }
            Write-Verbose "      [$name] $status | $snippet"
        }
        $sections.Add("== $name ($status) ==")
        $sections.Add($text)
        $sections.Add('')
    }
    Save-OcrSidecar -ScreenshotPath $ScreenshotPath -Sections $sections
}

function Set-OcrMatchSinceStepStart {
    <#
    .SYNOPSIS
        Re-decide OCR against newly printed lines without filtering diagnostic evidence.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates only in-memory OCR observations; no external state is changed.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string[]]$Pattern,
        [Parameter(Mandatory)][ref]$Baseline, [int]$TailLines, [switch]$NoSegmentMatch,
        [switch]$RequireCombinedMatch)
    if ($null -eq $Baseline.Value) { $Baseline.Value = [string[]]@(Get-ConsoleLineSignature -Text ([string]$Result.AnyText)) }
    $text = Select-ConsoleTextSinceBaseline -Text ([string]$Result.AnyText) -BaselineSignature $Baseline.Value -TailLines $TailLines
    $matched = $false
    if ($text) {
        foreach ($candidate in $Pattern) {
            if (Test-OCRMatch -Text $text -Pattern $candidate -NoSegmentMatch:$NoSegmentMatch) { $matched = $true; break }
        }
    }
    if ($Result.Match -and -not $matched) { Write-Verbose 'The sought text is present only in the step-start baseline; still waiting.' }
    $Result.Match = $matched -and (-not $RequireCombinedMatch -or $Result.Match)
    return @{ Match = $matched; Text = $text }
}

function Get-InstallerConsoleStage {
    <#
    .SYNOPSIS
        Return the last substantive Subiquity stage visible in an OCR frame.
    #>
    param([AllowEmptyString()][string]$Text)
    $stageMatches = [regex]::Matches($Text, '(?im)^\s*(start|finish):\s+(subiquity/(?:Install|Mirror)/[A-Za-z0-9_./-]+)')
    if ($stageMatches.Count -eq 0) { return '' }
    $last = $stageMatches[$stageMatches.Count - 1]
    return "$($last.Groups[1].Value.ToLowerInvariant()): $($last.Groups[2].Value)"
}

function Get-GuestLivelockVerdict {
    <#
    .SYNOPSIS
        The host recording's livelock verdict for a VM, or $null when no
        recording can be read.
    .DESCRIPTION
        Evidence gathering must never fail the wait it serves, so a sampling
        module that will not load or a recording that will not parse answers
        $null -- not measured -- rather than an error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        # Readings older than this are not judged; a wait passes its own start.
        [datetime]$Since = [datetime]::MinValue
    )
    try {
        if (-not (Get-Command Get-YurunaVmLivelockState -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Global -ErrorAction Stop -Verbose:$false
        }
        return (Get-YurunaVmLivelockState -VMName $VMName -Since $Since)
    } catch {
        Write-Verbose "      Host livelock verdict unavailable for '$VMName': $($_.Exception.Message)"
        return $null
    }
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
    .PARAMETER NoSegmentMatch
        Match positive patterns within one line and a bounded character span.
        Applies to live frames, step-start filtering, accumulated text, and
        fresh-window diagnostics. Character-confusion tolerance is preserved.
    .OUTPUTS
        [bool] $true on positive match; $false on timeout or anti-pattern hit.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
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
        [switch]$NoSegmentMatch,
        # See https://yuruna.link/4213a0b3-0123
        [bool]$SinceStepStart = $false,
        # Optional periodic console nudge. This stays inside the same wall-clock
        # deadline as the OCR wait: it is for one-shot prompts (notably agetty's
        # login prompt) that can be scrolled off a live console and redrawn with
        # a harmless keypress. A dedicated sequence action supplies these
        # parameters so capability preflight can require Send-Key only when the
        # nudge is actually requested.
        [string]$NudgeKey = '',
        [int]$NudgeIntervalSeconds = 0,
        # See https://yuruna.link/4213a0b3-0124
        [string[]]$FailurePattern = @(),
        # See https://yuruna.link/4213a0b3-0125
        [string[]]$EarlyFailurePattern = @(),
        [int]$EarlyFailureSeconds = 0,
        # End the wait as soon as the host recording shows the guest livelocked
        # (see Get-YurunaVmLivelockVerdict). Callers can then diagnose or cold
        # restart at a safe boundary; a partially executed payload must not be
        # replayed merely because its completion wait ended early.
        [switch]$EndOnGuestLivelock,
        # Where a wait that ends on a livelock starts judging the verdict, for the
        # early end and for the verdict it records on timeout alike: a cold restart
        # just before the wait must not hand it the previous boot's run. Defaults
        # to this call's start; a step that waits in several calls passes its own
        # start so every call judges the same stretch of one boot.
        [datetime]$GuestLivelockSinceUtc = [datetime]::MinValue
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
    $script:Fail.WaitForTextInstallerStage = ''
    $script:Fail.WaitForTextInstallerStageSeconds = 0
    $script:Fail.WaitForTextGuestBootStalled = $false
    $script:Fail.WaitForTextGuestLivelocked = $false
    $script:Fail.WaitForTextGuestLivelock = $null
    $script:Fail.WaitForTextBlankScreenSeconds = 0
    # See https://yuruna.link/4213a0b3-0126
    $script:Fail.WaitForTextConsoleSignalsMeasured = (-not $FreshMatch)
    $script:Fail.WaitForTextOutputStaticSeconds = $null
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
    # See https://yuruna.link/4213a0b3-0127
    $startUtc    = [DateTime]::UtcNow
    $livelockSinceUtc = if ($PSBoundParameters.ContainsKey('GuestLivelockSinceUtc')) { $GuestLivelockSinceUtc.ToUniversalTime() } else { $startUtc }
    $deadlineUtc = $startUtc.AddSeconds($TimeoutSeconds)
    $elapsed     = 0
    $nudgeEnabled = (-not [string]::IsNullOrWhiteSpace($NudgeKey) -and $NudgeIntervalSeconds -gt 0)
    $nextNudgeUtc = if ($nudgeEnabled) { $startUtc.AddSeconds($NudgeIntervalSeconds) } else { $null }

    # See https://yuruna.link/4213a0b3-0128
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    Import-Module (Join-Path $modulesDir "Test.OcrEngine.psm1") -Global -ErrorAction SilentlyContinue -Verbose:$false

    $enabledEngines = Get-EnabledOcrProvider
    $combineMode = Get-OcrCombineMode
    Write-Debug "      OCR engines: $($enabledEngines -join ', ') | combine: $combineMode"

    # See https://yuruna.link/4213a0b3-0129
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
    $recentFrames   = @{}
    # See https://yuruna.link/4213a0b3-012a
    $sinceBaseline  = $null
    # Prefer the console the previous wait matched on over this wait's own first
    # frame: it dates the baseline from the last moment the sequence knows what
    # was on screen, instead of from a poll interval into the step, which is
    # already too late for a prompt printed in answer to the previous step's
    # keystroke. Consumed unconditionally, even by a wait that will not use it,
    # so it can only ever describe the wait immediately before this one.
    $carriedBaseline = Get-CarriedConsoleBaseline -VMName $VMName
    $earlyBaseline = $carriedBaseline
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
    $progressText = $null
    $progressSinceUtc = $null
    $progressStaticSeconds = $null
    $installerStage = ''
    $installerStageSinceUtc = $null
    # See https://yuruna.link/4213a0b3-012b
    $deadlineGrantedSeconds  = 0
    $maxDeadlineGrantSeconds = [math]::Min([int]$TimeoutSeconds, 120)
    # Blank-console run: consecutive captures from which no engine read any
    # text. The content-static tracker above measures only text it can read,
    # so a console that went black would otherwise leave no trace in the
    # failure record, which then reads like a wait that compared nothing.
    $blankSinceUtc = $null
    # The host recording advances once per sampler interval, so asking more
    # than once a minute buys nothing but parsing.
    $nextLivelockCheckUtc = $startUtc
    $livelockVerdict = $null
    $endedOnLivelock = $false

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

            # Checked before the capture so a feed that stopped delivering
            # frames cannot postpone the verdict: the hypervisor's view does
            # not depend on the console path at all.
            if ($EndOnGuestLivelock -and [DateTime]::UtcNow -ge $nextLivelockCheckUtc) {
                $nextLivelockCheckUtc = [DateTime]::UtcNow.AddSeconds(60)
                $livelockVerdict = Get-GuestLivelockVerdict -VMName $VMName -Since $livelockSinceUtc
                if ($livelockVerdict -and $livelockVerdict.Verdict -eq 'livelocked') {
                    $endedOnLivelock = $true
                    break
                }
            }

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
            Add-OcrHistoryFrame -Queue $rawQueue -Path $rawScreenPath -Limit $historySize

            # See https://yuruna.link/4213a0b3-012c
            if ($rawScreenPath -and (Test-Path $rawScreenPath)) {
                if ($FreshMatch) {
                    # -- FreshMatch mode: only check the last N lines --
                    $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $Pattern -FreshMatchTailLines $FreshMatchTailLines -NoSegmentMatch:$NoSegmentMatch

                    Save-EngineOcrSidecar -ScreenshotPath $rawScreenPath -EngineResults $result.EngineResults -VerboseSummary

                    if ($result.AnyText) {
                        $lastOcrText = $result.AnyText
                        $observedInstallerStage = Get-InstallerConsoleStage -Text ([string]$result.AnyText)
                        if ($observedInstallerStage -and $observedInstallerStage -cne $installerStage) {
                            $installerStage = $observedInstallerStage
                            $installerStageSinceUtc = [DateTime]::UtcNow
                        }
                    }
                    $lastEngineResults = $result.EngineResults

                    # Re-decide the combiner's verdict against the step-start
                    # baseline, rather than handing the combiner a filtered
                    # frame, so the whole surface stays available to everything
                    # else this loop does with it: the anti-pattern scan, the
                    # failure artifacts and the stall detectors all need the
                    # screen as it actually is.
                    if ($SinceStepStart) {
                        $null = Set-OcrMatchSinceStepStart -Result $result -Pattern $Pattern -Baseline ([ref]$sinceBaseline) -TailLines $sinceTailLines -NoSegmentMatch:$NoSegmentMatch -RequireCombinedMatch:($combineMode -eq 'And')
                    }

                    if ($result.Match) {
                        Write-Debug "      Text detected at end of screen (combine=$combineMode)"
                        Set-CarriedConsoleBaseline -VMName $VMName -Text ([string]$result.AnyText)
                        return $true
                    }
                } else {
                    # -- Non-FreshMatch mode: accumulate text, check for pattern --
                    $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $Pattern -NoSegmentMatch:$NoSegmentMatch

                    Save-EngineOcrSidecar -ScreenshotPath $rawScreenPath -EngineResults $result.EngineResults -VerboseSummary

                    # Re-decide the combiner's verdict against the step-start
                    # baseline, rather than handing the combiner a filtered
                    # frame, so the whole surface stays available to everything
                    # else this loop does with it: the anti-pattern scan, the
                    # failure artifacts and the stall detectors all need the
                    # screen as it actually is.
                    if ($SinceStepStart) {
                        $null = Set-OcrMatchSinceStepStart -Result $result -Pattern $Pattern -Baseline ([ref]$sinceBaseline) -TailLines $sinceTailLines -NoSegmentMatch:$NoSegmentMatch
                    }

                    if ($result.AnyText) {
                        $lastOcrText = $result.AnyText
                        $lastEngineResults = $result.EngineResults
                        $observedInstallerStage = Get-InstallerConsoleStage -Text ([string]$result.AnyText)
                        if ($observedInstallerStage -and $observedInstallerStage -cne $installerStage) {
                            $installerStage = $observedInstallerStage
                            $installerStageSinceUtc = [DateTime]::UtcNow
                        }
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
                    $recentMatched = Test-RecentOcrFramesMatch -Frames $recentFrames -EngineResults $result.EngineResults `
                        -EnabledEngines $enabledEngines -Pattern $Pattern -CombineMode $combineMode -MaxFrames $recentFrameMax `
                        -SinceBaseline:$SinceStepStart -Baseline $sinceBaseline -TailLines $sinceTailLines `
                        -NoSegmentMatch:$NoSegmentMatch
                    if ($recentMatched) {
                        Write-Debug '      Text detected across recent frames'
                        $script:LastWaitVerdict.Matched = $true
                        Set-CarriedConsoleBaseline -VMName $VMName -Text ([string]$result.AnyText)
                        return $true
                    }

                    # See https://yuruna.link/4213a0b3-012d
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
                            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_b995254a51c06d12' -Arguments @{ floodDetail = "$floodDetail" })
                            if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
                                Send-YurunaDegradation -Dependency 'console-content' -Primary 'readable-console' -Fallback 'none' `
                                    -Reason $floodDetail
                            }
                        }
                    } else {
                        $floodPolls = 0
                    }
                }

                # Observe output even when a tail-only match disables the
                # recovery signals. This advisory never triggers console input
                # or a restart of state-changing work.
                $progressNow = Get-ConsoleTextSignature -Text ([string]$result.AnyText)
                if ($progressNow) {
                    if ($progressNow -cne $progressText) { $progressText=$progressNow; $progressSinceUtc=[datetime]::UtcNow }
                    $progressStaticSeconds = [int]([datetime]::UtcNow - $progressSinceUtc).TotalSeconds
                } else {
                    $progressText=$null; $progressSinceUtc=$null; $progressStaticSeconds=$null
                }

                # Bounded self-heal (arms Test.VncProvider / Test.ScreenshotProvider):
                # several consecutive no-text polls suggest the capture feed went
                # stale. Force the next Get-VMScreenshot to re-handshake by clearing
                # the cached VNC handle, and best-effort clear the screenshot ring.
                # Capped per wait so a genuinely blank screen still times out
                # normally rather than thrashing the transport.
                if ($result.AnyText) {
                    $noTextPolls = 0
                    $blankSinceUtc = $null
                } else {
                    if (-not $blankSinceUtc) { $blankSinceUtc = [DateTime]::UtcNow }
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

                # Repair a readable capture feed whose frames have stopped changing.
                # See https://yuruna.link/42e220c4-0007
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

            # See https://yuruna.link/4213a0b3-012e
            $activeFailurePattern = @($FailurePattern)
            # See https://yuruna.link/4213a0b3-012f
            $strictFailurePattern = @{}
            if ($null -eq $earlyBaseline) { $earlyBaseline = [string[]]@(Get-ConsoleLineSignature -Text $lastOcrText) }
            if ($EarlyFailurePattern.Count -gt 0 -and $elapsed -le $EarlyFailureSeconds) {
                foreach ($efp in $EarlyFailurePattern) {
                    $activeFailurePattern += $efp
                    if ($FailurePattern -notcontains $efp) { $strictFailurePattern[$efp] = $true }
                }
            }
            if ($activeFailurePattern.Count -gt 0 -and $lastOcrText) {
                foreach ($fp in $activeFailurePattern) {
                    if ([string]::IsNullOrWhiteSpace($fp)) { continue }
                    $failureText = if ($strictFailurePattern[$fp]) {
                        Select-ConsoleTextSinceBaseline -Text $lastOcrText -BaselineSignature $earlyBaseline
                    } else { $lastOcrText }
                    if (Test-OCRMatch -Text $failureText -Pattern $fp -NoSegmentMatch:([bool]$strictFailurePattern[$fp])) {
                        $script:Fail.WaitForTextMatchedFailurePattern = $fp
                        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_62980faa8cb2736d' -Arguments @{ fp = "$fp"; elapsed = "${elapsed}"; timeoutSeconds = "${TimeoutSeconds}" })
                        if ($lastCapturePath -and (Test-Path $lastCapturePath)) {
                            $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
                            Copy-Item -Path $lastCapturePath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
                            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b24a2d8bfa724905' -Arguments @{ failScreenPath = "$failScreenPath"; screensDir = "$screensDir" })
                        }
                        if ($lastOcrText) {
                            $failOcrPath = Join-Path $logDir "failure_ocr_${VMName}.txt"
                            Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
                            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ae9f061222f374f7' -Arguments @{ failOcrPath = "$failOcrPath" })
                            # Bounded tail + the sought patterns into causeDetail (set
                            # on failure only, so a successful wait can't leak them).
                            $script:Fail.WaitForTextOcrTail = if ($lastOcrText.Length -le 1200) { $lastOcrText } else { $lastOcrText.Substring($lastOcrText.Length - 1200) }
                            $script:Fail.WaitForTextPatternsSought = [string[]]@($Pattern)
                        }
                        $script:Fail.WaitForTextInstallerStage = $installerStage
                        if ($installerStageSinceUtc) {
                            $script:Fail.WaitForTextInstallerStageSeconds = [int]([DateTime]::UtcNow - $installerStageSinceUtc).TotalSeconds
                        }
                        # The hypervisor's view belongs on a pattern match as much
                        # as on a timeout: a script that gave up because the guest
                        # lost its network reads the same on the console as one
                        # whose peer was down, and only the host recording shows
                        # which processor was trapping in place at that moment.
                        $patternLivelock = Get-GuestLivelockVerdict -VMName $VMName -Since $livelockSinceUtc
                        if ($patternLivelock) {
                            $script:Fail.WaitForTextGuestLivelock = $patternLivelock
                            $script:Fail.WaitForTextGuestLivelocked = ($patternLivelock.Verdict -eq 'livelocked')
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
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e0fe1d922e8ae72b' -Arguments @{ nudgeKey = "$NudgeKey" })
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
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b24a2d8bfa724905' -Arguments @{ failScreenPath = "$failScreenPath"; screensDir = "$screensDir" })
        }
        # The sought patterns go into causeDetail on every timeout, set on
        # failure only so a successful wait can't leak them. Recording them
        # only beside readable text made a blank console's record look like a
        # wait that sought nothing.
        $script:Fail.WaitForTextPatternsSought = [string[]]@($Pattern)
        if ($lastOcrText) {
            $failOcrPath = Join-Path $logDir "failure_ocr_${VMName}.txt"
            Set-Content -Path $failOcrPath -Value $lastOcrText -Force -ErrorAction SilentlyContinue
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ae9f061222f374f7' -Arguments @{ failOcrPath = "$failOcrPath" })
            $script:Fail.WaitForTextOcrTail = if ($lastOcrText.Length -le 1200) { $lastOcrText } else { $lastOcrText.Substring($lastOcrText.Length - 1200) }
        }
        if ($blankSinceUtc) {
            $script:Fail.WaitForTextBlankScreenSeconds = [int]([DateTime]::UtcNow - $blankSinceUtc).TotalSeconds
        }

        # The hypervisor's view of the guest, recorded on every timeout where a
        # host recording exists: it is the one reading that separates a guest
        # still working from one whose processors are trapping in place, and
        # neither the console nor the capture path can tell those apart.
        # A wait that acts on the verdict records the one its early end judged;
        # any other wait records the whole recording window.
        if (-not $endedOnLivelock) {
            $livelockVerdict = if ($EndOnGuestLivelock) { Get-GuestLivelockVerdict -VMName $VMName -Since $livelockSinceUtc } else { Get-GuestLivelockVerdict -VMName $VMName }
        }
        if ($livelockVerdict) {
            $script:Fail.WaitForTextGuestLivelock = $livelockVerdict
            $script:Fail.WaitForTextGuestLivelocked = ($livelockVerdict.Verdict -eq 'livelocked')
            if ($script:Fail.WaitForTextGuestLivelocked -and -not $endedOnLivelock) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7e0c2dd4aa0c5981' -Arguments @{ detail = "$($livelockVerdict.Detail)" })
            }
        }

        # See https://yuruna.link/4213a0b3-0130
        $script:Fail.WaitForTextConsoleStaticSeconds = [int]$maxConsoleStaticSecs
        $script:Fail.WaitForTextOutputStaticSeconds = $progressStaticSeconds
        $script:Fail.WaitForTextInstallerStage = $installerStage
        if ($installerStageSinceUtc) {
            $script:Fail.WaitForTextInstallerStageSeconds = [int]([DateTime]::UtcNow - $installerStageSinceUtc).TotalSeconds
        }
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
                -Pattern $Pattern -FreshMatchTailLines $FreshMatchTailLines -NoSegmentMatch:$NoSegmentMatch)
            if ($nearMiss.Count -gt 0) {
                $script:Fail.WaitForTextFreshWindowNearMiss = $nearMiss
                foreach ($line in $nearMiss) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7fd9fd9e44112055' -Arguments @{ line = "$line" })
                }
            }
        }

        # See https://yuruna.link/4213a0b3-0131
        if ($lastEngineResults -and (Get-Command Get-OcrClosestOnScreen -ErrorAction SilentlyContinue)) {
            [string[]]$closestOnScreen = @(Get-OcrClosestOnScreen -EngineResult $lastEngineResults -Pattern $Pattern)
            # Recorded even when it came back empty: the scan ran, and "compared
            # the frame, nothing resembled it" is a reading the record is
            # entitled to keep separate from "never compared anything".
            $script:Fail.WaitForTextClosestOnScreen = $closestOnScreen
            foreach ($closestLine in $closestOnScreen) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_35445ede93646e87' -Arguments @{ closestLine = "$closestLine" })
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
                $script:Fail.WaitForTextGuestBootStalled = (
                    $secondOpinion -and $secondOpinion.Verdict -eq 'guest-static' -and
                    $script:LastWaitVerdict.ConsoleSignalsMeasured -and
                    $script:LastWaitVerdict.ConsoleStaticSeconds -ge 120 -and
                    -not $script:Fail.WaitForTextMatchedFailurePattern -and
                    -not $script:Fail.WaitForTextConsoleFlood
                )
                if ($secondOpinion -and $secondOpinion.Verdict -ne 'unavailable') {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_b3dea02d8275ec49' -Arguments @{ verdict = "$($secondOpinion.Verdict)"; detail = "$($secondOpinion.Detail)" })
                } elseif ($secondOpinion) {
                    Write-Verbose "      Console second opinion unavailable: $($secondOpinion.Detail)"
                }
            } catch {
                Write-Verbose "      Get-VMConsoleSecondOpinion failed: $($_.Exception.Message)"
            }
        }

        if ($endedOnLivelock) {
            $waited = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6d4042dbe6943c27' -Arguments @{ patternLabel = "$patternLabel"; waited = "${waited}"; timeoutSeconds = "${TimeoutSeconds}"; detail = "$($livelockVerdict.Detail)" })
        } elseif ($deadlineGrantedSeconds -gt 0) {
            $waited = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5d951715d9614411' -Arguments @{ patternLabel = "$patternLabel"; timeoutSeconds = "${TimeoutSeconds}"; deadlineGrantedSeconds = "${deadlineGrantedSeconds}"; waited = "${waited}" })
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_55583f4e86287622' -Arguments @{ patternLabel = "$patternLabel"; timeoutSeconds = "${TimeoutSeconds}" })
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
        Import-Module (Join-Path $modulesDir "Test.OcrEngine.psm1") -Global -ErrorAction SilentlyContinue -Verbose:$false
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_fc8f368b71282373')
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
        # See https://yuruna.link/4213a0b3-0132
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_0eb7bda9b10d1bc4' -Arguments @{ guestKey = "$GuestKey"; name = "$Name"; list = "$list" })
        return $false
    }
    # See https://yuruna.link/4213a0b3-0133
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bf9f079318a27ce2' -Arguments @{ guestKey = "$GuestKey"; name = "$Name"; hostType = "$HostType"; vMName = "$VMName" }) -InformationAction Continue
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

function Get-ScreenHistorySize {
    <#
    .SYNOPSIS
        Returns the bounded screen history size used by the sequence engine.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [Math]::Clamp([int]$script:DefaultScreenHistorySize, 1, 240)
}

function Get-SequenceFinishedVMName {
    <#
    .SYNOPSIS
        Returns the VM name in effect when the most recent Invoke-Sequence
        returned, including any mid-sequence saveDiskSnapshot rename.
    .DESCRIPTION
        Chain callers read this after each sequence so the next one targets
        the renamed VM in both the inner runner and Debug-TestSequence.
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
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_1c23340e88163829' -Arguments @{ s = "$s" }) -InformationAction Continue
                continue
            }
        }
        $thisStart = if ($resuming -and $s -eq $ResumeFromSequence) { [int]$ResumeFromStep } else { 1 }
        $runningMessage = if ($thisStart -gt 1) { Format-YurunaOperatorMessage -Key 'runner.sequence_running_resume' -Arguments @{ sequence = $s; step = $thisStart } } else { Format-YurunaOperatorMessage -Key 'runner.sequence_running' -Arguments @{ sequence = $s } }
        Write-Information $runningMessage -InformationAction Continue
        $seqStartUtc = [DateTime]::UtcNow
        $ok = Invoke-SequenceByName -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencesDir $SequencesDir -RepoRoot $RepoRoot -Name $s -EffectiveVariables $EffectiveVariables -StartStep $thisStart
        if (-not $ok) {
            $errMsg = (Format-YurunaOperatorMessage -Key 'runner.operator_af33f0960f92ab46' -Arguments @{ phaseLabel = "$PhaseLabel"; s = "$s" })
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
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9d7be750017c3720' -Arguments @{ vMName = "$VMName"; finishedVm = "$finishedVm" }) -InformationAction Continue
            $VMName = $finishedVm
        }
    }
    if ($resuming -and -not $reachedResume) {
        # The resume target is not in this list -- refuse to report success (every
        # sequence would have been silently skipped). The runner re-derives the
        # target from last_failure.json, so this only trips on a bad call.
        return @{ success=$false; skipped=$false; errorMessage=(Format-YurunaOperatorMessage -Key 'runner.operator_b8e59ada0f2a685a' -Arguments @{ resumeFromSequence = "$ResumeFromSequence" }) }
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
        # See https://yuruna.link/4213a0b3-0134
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9bd500968f410241' -Arguments @{ sequencePath = "$SequencePath" })
        return $false
    }

    # No wait in this run may inherit a console baseline from whatever drove
    # this VM before it. Handing one forward asserts "this is what the step
    # before me left on screen", and only a wait inside the same run can make
    # that claim -- the guest may have been rebooted or rebuilt since.
    Clear-CarriedConsoleBaseline

    # See https://yuruna.link/4213a0b3-0135
    $modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "modules"
    # See https://yuruna.link/4213a0b3-0136
    if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $modulesDir "Test.YurunaDir.psm1") -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    }
    Import-Module (Join-Path $modulesDir "Test.Ssh.psm1")      -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
    $logDir = Initialize-YurunaLogDir

  try {
    $sequence = Read-SequenceFile -Path $SequencePath

    # Clean up stale failure artifacts from any prior run
    Remove-Item (Join-Path $logDir "last_failure.json") -Force -ErrorAction SilentlyContinue

    # See https://yuruna.link/4213a0b3-0137
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
    # See https://yuruna.link/4213a0b3-0138
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

    Write-Information (Format-YurunaOperatorMessage -Key 'runner.sequence_description' -Arguments @{ description = (Resolve-YurunaOperatorProjectLabel -Entry $sequence) })
    # Apply the optional step window (default = whole sequence). Slicing here
    # (rather than the caller writing a sliced temp YAML) is what lets the chain
    # runner drive a step range with -StartStep / -StopStep on the real file.
    # @() guards the single-step case: PowerShell unwraps a one-element return,
    # so without it a 1-step window would arrive as a bare step, not an array.
    $sourceStepCount = @($sequence.steps).Count
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
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7545bc97968f08e8' -Arguments @{ sequencePath = "$SequencePath"; message = "$($readErr.Exception.Message)" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
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
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6c35bcc6c529958c' -Arguments @{ message = "$($setupErr.Exception.Message)" })
            Send-CycleEventSafely -EventRecord @{
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                event     = 'perf_context_unavailable'
                reason    = 'setup_failed'
                path      = [string]$SequencePath
                error     = $setupErr.Exception.Message
            }
        }
    }

    # Evidence correlation also applies to direct/debug runs without an active
    # performance cycle. Prefer its ID when available, otherwise own one here.
    if (-not $sequenceInvocationId) { $sequenceInvocationId = [Guid]::NewGuid().ToString('N') }

    if ($steps.Count -eq 0) {
        Write-Verbose "    No steps defined."
        return $true
    }
    Write-Verbose "    Steps: $($steps.Count)"

    # Gate step pauses before setup and before each action.
    # See https://yuruna.link/42e220c4-0007
    $runtimeDir = Initialize-YurunaRuntimeDir
    $stepPauseFlagFile = Join-Path $runtimeDir 'control.step-pause'
    # See https://yuruna.link/4213a0b3-0139
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
        param([string]$Line, [string]$Code = '', [string]$Label = '', [hashtable]$Arguments = @{})
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
                    arguments = $Arguments
                    updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                }
                # Route through the shared atomic writer: a fixed "$Path.tmp"
                # lets a concurrent writer's rename clobber a half-written temp,
                # so the primitive uses a per-PID unique temp name (and a
                # guaranteed no-BOM encoding) in one place. It returns $false
                # rather than throwing, so surface that into the retry loop.
                if (-not (Write-YurunaStateFileJson -Path $currentActionFile -InputObject $doc -Confirm:$false)) {
                    throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_140e410616042231' -Arguments @{ currentActionFile = "$currentActionFile" })
                }
                return
            } catch {
                $lastErr = $_
                Start-Sleep -Milliseconds (50 * $attempts)
            }
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7f0366c89e03f268' -Arguments @{ attempts = "$attempts"; message = "$($lastErr.Exception.Message)"; currentActionFile = "$currentActionFile" })
        Send-CycleEventSafely -EventRecord @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            event     = 'sidecar_write_failed'
            file      = 'current-action.json'
            path      = [string]$currentActionFile
            attempts  = $attempts
            error     = $lastErr.Exception.Message
        }
    }

    # See https://yuruna.link/4213a0b3-013a
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
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event     = 'sequence_paused'
                })
            }
            & $writeCurrentAction (Format-YurunaOperatorMessage -Key 'runner.sequence_paused' -Arguments @{ label = $Label }) 'sequence_paused_waiting_resume' $Label @{ label = $Label }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_119f0ffa59a9f297' -Arguments @{ label = "$Label" })
            $heldFromUtc  = [DateTime]::UtcNow
            $pauseAttempt = 1
            while (Test-Path $stepPauseFlagFile) {
                Start-Sleep -Milliseconds (Get-PollDelay -Attempt $pauseAttempt)
                Write-RunnerStepHeartbeat -RuntimeDir $runtimeDir
                $pauseAttempt++
            }
            $heldSeconds = [int]([DateTime]::UtcNow - $heldFromUtc).TotalSeconds
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0c5e7a2f9a68193c' -Arguments @{ label = "$Label"; heldSeconds = "${heldSeconds}" })
            # Handed to the failure record so a step that fails right after a long
            # hold reports the hold as part of its cause. Read by
            # New-SequenceFailureRecord; harmless on the passing path, where
            # nothing consults it.
            $script:Fail.LastPauseRelease = @{
                releasedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                heldSeconds   = $heldSeconds
                label         = [string]$Label
                pauseScope    = 'step'
            }
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord ($pauseCommon + @{
                    timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event       = 'sequence_resumed'
                    heldSeconds = $heldSeconds
                })
            }
        }
    }

    # See https://yuruna.link/4213a0b3-013b
    $checkCycleRestart = {
        param([string]$Label)
        if (Test-Path $cycleRestartFlagFile) {
            & $writeCurrentAction (Format-YurunaOperatorMessage -Key 'runner.sequence_restart' -Arguments @{ label = $Label }) 'sequence_restart_requested' $Label @{ label = $Label }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_2b07789beedbf479' -Arguments @{ label = "$Label" })
            $restart = [System.Management.Automation.RuntimeException]::new("YurunaCycleRestart: status-service /control/start-cycle requested mid-cycle abort at $Label")
            $restart.Data['YurunaCycleRestart'] = $true
            throw $restart
        }
    }

    # See https://yuruna.link/4213a0b3-013c
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

    # See https://yuruna.link/4213a0b3-013d
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

    # See https://yuruna.link/4213a0b3-013e
    $testRoot = Split-Path -Parent $PSScriptRoot
    $screenshotDir = Join-Path -Path $testRoot -ChildPath 'status' `
                         -AdditionalChildPath 'captures', 'sequences'
    $sequenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # --- REGION: Recursive step executor
    # See https://yuruna.link/4213a0b3-013f
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
            [int]$ParentAttempt = 0,
            [int]$StepOffset = 0
        )
        $stepTotal = if ($ParentOrdinal -eq 0) { $sourceStepCount } else { $Steps.Count }
        $stepNum = $StepOffset
        foreach ($step in $Steps) {
            $stepNum++
            $ctx = $null
            $script:Fail.LastFailedStepInvocationId = ''
            $script:Fail.LastFailedSequenceInvocationId = ''
            $script:Fail.OriginatingStepInvocationId = ''
            $script:Fail.OriginatingSequenceInvocationId = ''
            # Cause signals belong to one attempted step, including nested retries.
            foreach ($cause in @('WaitForTextMatchedFailurePattern', 'WaitForTextOcrTail',
                'WaitForTextClosestOnScreen', 'WaitForTextConsoleFlood', 'StepGuestAddressUnresolved',
                'StepGuestTransportLost', 'StepGuestRunLost', 'StepGuestPayloadUnavailable', 'StepInputLost',
                'StepLauncherRejection', 'StepVmNotStopped', 'WaitForTextGuestLivelock', 'WaitForTextOutputStaticSeconds', 'StepProgressAdvisory')) {
                $script:Fail[$cause] = $null
            }
            $script:Fail.WaitForTextPatternsSought = [string[]]@()
            $script:Fail.WaitForTextFreshWindowNearMiss = [string[]]@()
            $script:Fail.WaitForTextConsoleStaticSeconds = 0
            $script:Fail.WaitForTextInstallerStage = ''
            $script:Fail.WaitForTextInstallerStageSeconds = 0
            $script:Fail.WaitForTextGuestBootStalled = $false
            $script:Fail.WaitForTextGuestLivelocked = $false
            $script:Fail.WaitForTextBlankScreenSeconds = 0
            $script:Fail.WaitForTextConsoleSignalsMeasured = $true

            # Gate #2: between-steps pause + cycle-restart check. Catches
            # a Pause or a "Save and start cycle" clicked while the previous
            # step was running. The throw inside $checkCycleRestart escapes
            # this $invokeStepBlock (including any wrapping `retry` block --
            # retry only catches $false returns, not exceptions) and bubbles
            # up to the cycle-level try/catch in Invoke-TestRunnerInnerLoop.
            & $waitWhilePaused "[$stepNum/$($stepTotal)]"
            & $waitWhileLabHealthy "[$stepNum/$($stepTotal)]"
            & $checkCycleRestart "[$stepNum/$($stepTotal)]"
            $displayDescription = Resolve-YurunaOperatorProjectLabel -Entry $step
            $desc = $displayDescription ? (Expand-Variable $displayDescription $vars) : $step.action
            $actionArguments = @{ index = $stepNum; total = $stepTotal; action = [string]$step.action; description = $desc }
            & $writeCurrentAction (Format-YurunaOperatorMessage -Key 'runner.sequence_step' -Arguments $actionArguments) 'sequence_step_active' $desc $actionArguments
            # See https://yuruna.link/4213a0b3-0140
            Write-RunnerStepHeartbeat -RuntimeDir $runtimeDir

            # `retry` is dispatched through the registry like every other
            # verb; its Handler lives in Test.SequenceHandler.psm1 next
            # to its Register-SequenceAction.

        # See https://yuruna.link/4213a0b3-0141
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'Continue'
        try {
        Write-ProgressTick -Activity "Sequence" -Status "[$stepNum/$($stepTotal)] $($step.action): $desc" -PercentComplete ([math]::Round((($stepNum - 1) / [math]::Max($stepTotal,1)) * 100))

        $stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        # Wall-clock start captured alongside the stopwatch so the perf
        # row carries an absolute UTC timestamp (needed for cross-host
        # joins) without trying to subtract elapsed ms from the END
        # time -- the two clocks would diverge by the GC/IO time of the
        # write itself.
        $stepStartUtc = [DateTime]::UtcNow
        $stepInvocationId = [Guid]::NewGuid().ToString('N')
        $script:Fail.LastFailedStepInvocationId = $stepInvocationId
        $script:Fail.LastFailedSequenceInvocationId = $sequenceInvocationId
        $ctx = $null
        $ok = $true

        # See https://yuruna.link/4213a0b3-0142
        if (Test-SequenceActionHasHandler -Name $step.action) {
            $ctx = @{
                Step                  = $step
                StepNum               = $stepNum
                StepCount             = $stepTotal
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
                RepoRoot              = $script:repoRoot
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8fc728510686c969' -Arguments @{ action = "$($step.action)" })
            $ok = $false
        }
        } finally {
            $global:ProgressPreference = $savedProgress
            if ($ctx) {
                $script:Fail.LastFailedStepInvocationId = $ctx.StepInvocationId
                $script:Fail.LastFailedSequenceInvocationId = $ctx.SequenceInvocationId
            }
        }

        # Normalize $ok. Anything that isn't a strict [bool] -- $null, an
        # accidentally-polluted pipeline array, a string, an exception object
        # wrapped by a catch -- is treated as failure. Without this, helpers
        # that forget to `return $true`/`return $false` (or that leak a stray
        # Write-Output) silently pass the step despite a timeout.
        if ($ok -isnot [bool]) {
            $okType = if ($null -eq $ok) { '<null>' } else { $ok.GetType().Name }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7314781ecf320be5' -Arguments @{ stepNum = "$stepNum"; action = "$($step.action)"; okType = "$okType" })
            $ok = $false
        }

        $stepStopwatch.Stop()
        $elapsedLabel = ("    {0,4}" -f [int]$stepStopwatch.Elapsed.TotalSeconds)
        $stepMarker   = if ($ok) { 'PASS' } else { 'FAIL' }
        Write-Information "$elapsedLabel s [$stepNum/$($stepTotal)] $stepMarker $($step.action): $desc"

        # One NDJSON line per step_end so a downstream consumer can plot
        # pass/fail rates without HTML scraping. Carries the SUPERSET
        # schema (hostType, action, description, and -- on a failure --
        # the verb's registered defaults, under their own names) of
        # step_failure so a downstream consumer can do a single schema
        # join across step_end + step_failure rows.
        $stepEndRecord = @{
            timestamp           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            event               = 'step_end'
            stepNumber          = [int]$stepNum
            totalSteps          = if ($ParentOrdinal -eq 0) { $sourceStepCount } else { $stepTotal }
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
        if ($ctx -and $ctx.ExecutionProfile) { $stepEndRecord.executionEvidence = $ctx.ExecutionProfile }
        if (-not $ok) {
            # Retry explicitly forwards the failed leaf's observations. Its
            # wrapper has no SSH measurement of its own and must not erase them.
            if ($ctx -and $ctx.OriginatingStepInvocationId -and $ctx.OriginatingSequenceInvocationId) {
                $script:Fail.OriginatingStepInvocationId = [string]$ctx.OriginatingStepInvocationId
                $script:Fail.OriginatingSequenceInvocationId = [string]$ctx.OriginatingSequenceInvocationId
                $script:Fail.StepProgressAdvisory = $ctx.OriginatingProgressAdvisory
            } else {
                $sshResponsiveness = 'unavailable'
                $heartbeatAge = $null
                $clockWarningCodes = [string[]]@()
                if ($ctx -and $ctx.ExecutionProfile) {
                    # The client's own connect failure (exit 255 with a timeout or
                    # no-route line) is as much a measurement as a harness kill.
                    if ($ctx.ExecutionProfile.sshResponsive) { $sshResponsiveness='responsive' }
                    elseif ($ctx.ExecutionProfile.timedOut -or $ctx.ExecutionProfile.transportFailed -or
                        ([string]$ctx.ExecutionProfile.reasonCode -in @('profile-ssh-timeout','profile-ssh-unreachable'))) { $sshResponsiveness='unresponsive' }
                    $heartbeatAge = $ctx.ExecutionProfile.recorder.heartbeatAgeSeconds
                    $clockWarningCodes = [string[]]@($ctx.ExecutionProfile.recorder.clockAnalysis.warnings |
                        ForEach-Object { if ($_) { [string]$_.code } } | Where-Object { $_ })
                }
                $script:Fail.StepProgressAdvisory = Get-GuestProgressAdvisory `
                    -OutputStaticSeconds $script:Fail.WaitForTextOutputStaticSeconds `
                    -HeartbeatAgeSeconds $heartbeatAge -SshResponsiveness $sshResponsiveness -ClockWarningCodes $clockWarningCodes
                $script:Fail.OriginatingStepInvocationId = $stepInvocationId
                $script:Fail.OriginatingSequenceInvocationId = $sequenceInvocationId
            }
            $stepEndRecord.originatingStepInvocationId = $script:Fail.OriginatingStepInvocationId
            $stepEndRecord.originatingSequenceInvocationId = $script:Fail.OriginatingSequenceInvocationId
            $stepEndRecord.progressAdvisory = $script:Fail.StepProgressAdvisory
        }
        # See https://yuruna.link/4213a0b3-0143
        if (-not $ok) {
            $stepVerbEntry = Get-SequenceAction -Name ([string]$step.action)
            $stepFailureClass = if ($stepVerbEntry) { [string]$stepVerbEntry.FailureClass } else { 'unknown' }
            $stepSeverity     = if ($stepVerbEntry) { [string]$stepVerbEntry.Severity }     else { 'unknown' }
            # See https://yuruna.link/4213a0b3-0144
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
        if ($ok -and $ParentOrdinal -eq 0) { $script:Fail.LastSucceededStepNumber = $stepNum }

        # See https://yuruna.link/4213a0b3-0145
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_dd72f34f455cfe9b' -Arguments @{ stepNum = "$stepNum"; desc = "$desc" })

            # See https://yuruna.link/4213a0b3-0146
            $actionLabel = Get-SequenceActionFailureLabel -Step $step -Vars $vars -ExpandVariable ${function:Expand-Variable} -VMName $VMName -GuestKey $GuestKey

            # See https://yuruna.link/4213a0b3-0147
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
            $script:Fail.LastFailedStepInvocationId = $stepInvocationId
            $script:Fail.LastFailedSequenceInvocationId = $sequenceInvocationId
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
        $script:Fail.LastFailedStepInvocationId = ''
        $script:Fail.LastFailedSequenceInvocationId = ''
        $script:Fail.OriginatingStepInvocationId = ''
        $script:Fail.OriginatingSequenceInvocationId = ''
        $script:Fail.StepProgressAdvisory = $null
        }  # end foreach inside $invokeStepBlock
        return $true
    }  # end $invokeStepBlock

    $script:Fail.LastFailureLabel       = $null
    $script:Fail.LastFailureDescription = $null
    $script:Fail.LastFailedAction       = $null
    $script:Fail.LastFailedStepNumber   = 0
    $script:Fail.LastFailedStepStartedUtc = $null
    $script:Fail.LastFailedStepInvocationId = ''
    $script:Fail.LastFailedSequenceInvocationId = ''
    $script:Fail.OriginatingStepInvocationId = ''
    $script:Fail.OriginatingSequenceInvocationId = ''
    $script:Fail.StepProgressAdvisory = $null
    # See https://yuruna.link/4213a0b3-0148
    $script:Fail.LastInnerFailedAction         = $null
    $script:Fail.LastInnerFailureClass         = $null
    $script:Fail.LastInnerSeverity             = $null
    $script:Fail.LastInnerSuggestedRecoveries  = @()
    # lastSucceededStepNumber: the step-N boundary a replay can safely
    # resume past. Reset to 0 at sequence start so a fresh-cycle
    # failure on step 1 surfaces as "no step succeeded" rather than
    # carrying a leftover value from a prior sequence's run.
    $script:Fail.LastSucceededStepNumber       = 0
    # The first-silence marker spans the whole sequence: it is the earliest
    # symptom, so a step must not clear it, and the next sequence starts clean.
    $script:Fail.FirstGuestSilenceUtc          = $null
    $script:Fail.FirstGuestSilenceSource       = $null
    # Cause slots reset per sequence so a prior sequence's OCR tail / sought
    # patterns can't leak into a non-wait step's failure record that fails before
    # any wait runs (the wait functions also reset them at entry).
    $script:Fail.WaitForTextOcrTail            = $null
    $script:Fail.WaitForTextPatternsSought     = [string[]]@()
    $script:Fail.WaitForTextInstallerStage = ''
    $script:Fail.WaitForTextInstallerStageSeconds = 0
    $result = & $invokeStepBlock -Steps $steps -StepOffset ([Math]::Max(0, $StartStep - 1))
    if (-not $result) {
        # Keep the exact frame saved by the failed attempt; recapture only
        # when no frame from this step exists.
        $VMName = [string]$script:SequenceFinishedVMName
        $failScreenPath = Join-Path $logDir "failure_screenshot_${VMName}.png"
        $failureScreen = Get-Item -LiteralPath $failScreenPath -ErrorAction SilentlyContinue
        $freshFailureScreen = $failureScreen -and $script:Fail.LastFailedStepStartedUtc -and
            $failureScreen.LastWriteTimeUtc -ge $script:Fail.LastFailedStepStartedUtc
        if (-not $freshFailureScreen) {
            $captured = Get-VMScreenshot -VMName $VMName -OutFile $failScreenPath
            # Confirm the file landed before advertising it: Get-VMScreenshot can
            # report truthy without writing the file, so verify it is on disk
            # before logging -- the capture and Wait-ForText failure paths in this
            # module gate on Test-Path the same way.
            if ($captured -and (Test-Path $failScreenPath)) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4333edb4f597ba98' -Arguments @{ failScreenPath = "$failScreenPath" })
            }
        }

        # See https://yuruna.link/4213a0b3-0149
        $failRec = New-SequenceFailureRecord -Reason 'step' -VMName $VMName -GuestKey $GuestKey -HostType $HostType -SequencePath $SequencePath -LogDir $logDir -TotalSteps $sourceStepCount
        $failureFile = Join-Path $logDir "last_failure.json"
        # Atomic write: a remediator/status reader must never observe a truncated
        # last_failure.json mid-write (partial-write regression class).
        $null = Write-YurunaStateFile -Path $failureFile -Content ($failRec.File | ConvertTo-Json -Depth 12) -Confirm:$false
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
        & $waitWhilePaused "[$($script:Fail.LastFailedStepNumber)/$sourceStepCount] FAIL"
        return $false
    }

    Write-ProgressTick -Activity "Sequence" -Completed
    $sequenceStopwatch.Stop()
    $sequenceElapsedLabel = ("{0,4}" -f [int]$sequenceStopwatch.Elapsed.TotalSeconds)
    $elapsedTotalSeconds = [long][math]::Floor($sequenceStopwatch.Elapsed.TotalSeconds)
    $elapsedTimeIsMinutes = Format-YurunaOperatorMessage -Key 'runner.sequence_duration' -Arguments @{ minutes = [long][math]::Floor($elapsedTotalSeconds / 60); seconds = $elapsedTotalSeconds % 60 }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0a9fd5fd1526e2d2' -Arguments @{ sequenceElapsedLabel = "$sequenceElapsedLabel"; count = "$($steps.Count)"; elapsedTimeIsMinutes = "$elapsedTimeIsMinutes" })
    $completedArguments = @{ total = $steps.Count; duration = $elapsedTimeIsMinutes }
    & $writeCurrentAction (Format-YurunaOperatorMessage -Key 'runner.sequence_completed' -Arguments $completedArguments) 'sequence_completed' '' $completedArguments
    return $true

  } catch {
    # See https://yuruna.link/4213a0b3-014a
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8f310b1b3a2d7721' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    # Print the message AND the throwing-statement origin AND the
    # call stack. Without these the operator gets only the .Exception
    # text (e.g. 'Exception calling "Replace" with "3" argument(s)')
    # and has to grep ten modules to find the actual throw.
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4579f44a5d893c14' -Arguments @{ value = "$_" })
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
    # See https://yuruna.link/4213a0b3-014b
    try {
        $VMName = [string]$script:SequenceFinishedVMName
        $failRec = New-SequenceFailureRecord -Reason 'crash' -VMName $VMName -GuestKey $GuestKey -HostType $HostType -SequencePath $SequencePath -LogDir $logDir -TotalSteps $sourceStepCount -CrashError $_
        # Atomic, best-effort: a reader must never see a truncated crash record.
        $null = Write-YurunaStateFile -Path (Join-Path $logDir "last_failure.json") -Content ($failRec.File | ConvertTo-Json -Depth 12) -Confirm:$false
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_aff1f890bceeea18' -Arguments @{ message = "$($writeErr.Exception.Message)" })
        Send-CycleEventSafely -EventRecord @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            event     = 'last_failure_write_failed'
            path      = (Join-Path $logDir 'last_failure.json')
            error     = $writeErr.Exception.Message
        }
    }
    return $false
  }
}

# --- REGION: Host I/O provider registrations
# See https://yuruna.link/4213a0b3-014c

# --- REGION: Sequence action metadata registrations
# See https://yuruna.link/4213a0b3-014d

Export-ModuleMember -Function Invoke-Sequence, Get-GuestLivelockVerdict, Invoke-SequenceByName, Send-Text, Send-Key, Send-Click, `
    Wait-ForText, Invoke-TapOn, Save-DebugScreenshot, Save-EngineOcrSidecar, Save-OcrSidecar, Write-ProgressTick, `
    Select-SequenceStepWindow, Get-ScreenHistorySize, Get-SequenceFinishedVMName, Get-OcrDegradationGrace, `
    Get-ConsoleFloodVerdict, Invoke-GuestSequenceList, Get-ConsoleTextSignature, `
    Get-ConsoleLineSignature, Select-ConsoleTextSinceBaseline, `
    Set-CarriedConsoleBaseline, Get-CarriedConsoleBaseline, Clear-CarriedConsoleBaseline, `
    Get-LastWaitVerdict, Wait-ForConsoleChange, Get-LastConsoleChangeVerdict

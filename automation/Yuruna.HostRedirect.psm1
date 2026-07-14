<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42b2897a-ae65-437f-a651-3e7a48775174
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host redirect
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

# Runs a host-specific script from a host-neutral entry point: detect the host,
# resolve host/<short>/<name>.ps1, and run it in a child pwsh whose working
# directory IS that host folder -- the same shell an operator gets by cd'ing
# there and calling ./<name>.ps1 by hand. The caller's own location is restored
# on the way out.
#
# Host detection is NOT reimplemented here. Get-HostType / Get-HostFolder
# (test/modules/Test.HostDetection.psm1) are the one definition the whole
# harness resolves against; this module imports them on demand and never keeps
# a second copy, because a second copy is a second answer the day a new host
# type is added.
#
# Nothing here is specific to the three scripts that use it today: -ScriptName
# takes any script that exists in all (or some) of the host folders.

# Test-IsAdministrator comes from the dependency-free leaf next door. Imported
# into this module's scope only -- the caller's session is left alone.
Import-Module -Name (Join-Path $PSScriptRoot 'Yuruna.Common.psm1') -Force -DisableNameChecking

function Get-YurunaRepoRoot {
<#
.SYNOPSIS
    Absolute path of the repository root, derived from this module's location
    (<repo>/automation/Yuruna.HostRedirect.psm1).
.OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-CurrentPwshPath {
<#
.SYNOPSIS
    Full path of the pwsh executable running this process.
.DESCRIPTION
    The child is launched with THIS pwsh, not with whatever "pwsh" resolves to
    on PATH. On a host carrying more than one PowerShell (a 7.x plus a preview,
    or a Windows PowerShell 5.1 earlier in PATH), the PATH answer can be a
    different engine than the one the operator chose -- and the host scripts'
    `#requires -version 7` would then fail against a 5.1 the operator never
    invoked.
.OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $imagePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($imagePath) { return $imagePath }
    } catch {
        Write-Verbose "Could not read the current process image path: $($_.Exception.Message)"
    }
    $fallback = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($fallback) { return $fallback.Source }
    throw 'Could not locate a pwsh executable to launch the host script with.'
}

function Test-ScriptRequiresElevation {
<#
.SYNOPSIS
    True when a script file declares `#requires -RunAsAdministrator`.
.DESCRIPTION
    Read from the script's own parsed requirements rather than a list of
    "these host scripts need elevation" kept here, so a host script that
    starts (or stops) requiring elevation stays correct on this side with no
    edit. Uses the language parser, not a regex: `#requires` is only honored
    by PowerShell at the top level, and the parser is the component that
    decides what counts.
.OUTPUTS
    System.Boolean
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if (-not $ast -or -not $ast.ScriptRequirements) { return $false }
    return [bool]$ast.ScriptRequirements.IsElevationRequired
}

function Import-HostDetectionModule {
<#
.SYNOPSIS
    Make Get-HostType / Get-HostFolder resolvable, importing them only when the
    caller's session does not already have them.
.DESCRIPTION
    The runner and most test entry points have already imported the host
    contract by the time they get here; re-importing would evict the loaded
    module out from under them (the legacy-eviction regression class). The
    short-circuit keeps this module usable from a bare `pwsh test/<x>.ps1`
    and from inside a session that is already fully wired.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if ((Get-Command -Name 'Get-HostType' -ErrorAction SilentlyContinue) -and
        (Get-Command -Name 'Get-HostFolder' -ErrorAction SilentlyContinue)) {
        return
    }
    $detectionModule = Join-Path $RepoRoot 'test/modules/Test.HostDetection.psm1'
    if (-not (Test-Path -LiteralPath $detectionModule -PathType Leaf)) {
        throw "Host detection module not found: $detectionModule"
    }
    # -Global: the importing script (and anything it calls) must see these too,
    # not just this module's scope.
    Import-Module -Name $detectionModule -Force -DisableNameChecking -Global
}

function Resolve-YurunaHostScript {
<#
.SYNOPSIS
    Locate the current host's copy of a script under host/<host type>/.
.PARAMETER ScriptName
    File name of the per-host script, with or without the .ps1 suffix.
.PARAMETER RepoRoot
    Repository root. Defaults to this module's repository.
.PARAMETER HostType
    Override the detected host type ("host.windows.hyper-v", ...). Detection is
    used when omitted; an override is mostly useful to a test.
.OUTPUTS
    [hashtable] @{ HostType; HostFolder; Path; RequiresElevation }
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$RepoRoot,
        [string]$HostType
    )
    if (-not $RepoRoot) { $RepoRoot = Get-YurunaRepoRoot }
    Import-HostDetectionModule -RepoRoot $RepoRoot

    if (-not $HostType) { $HostType = Get-HostType }
    if (-not $HostType) {
        throw 'Host type could not be determined. Only macOS (UTM), Windows (Hyper-V), and Linux (KVM/libvirt) are supported.'
    }

    if ($ScriptName -notmatch '\.ps1$') { $ScriptName = "$ScriptName.ps1" }

    $relativeFolder = Get-HostFolder $HostType
    $hostFolder     = Join-Path $RepoRoot $relativeFolder
    if (-not (Test-Path -LiteralPath $hostFolder -PathType Container)) {
        throw "Host folder not found: $hostFolder"
    }

    $scriptPath = Join-Path $hostFolder $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "'$ScriptName' is not available for $HostType (looked for: $scriptPath)."
    }

    return @{
        HostType          = $HostType
        HostFolder        = (Resolve-Path -LiteralPath $hostFolder).Path
        Path              = (Resolve-Path -LiteralPath $scriptPath).Path
        RelativePath      = "$relativeFolder/$ScriptName"
        RequiresElevation = (Test-ScriptRequiresElevation -Path $scriptPath)
    }
}

function ConvertTo-HostScriptArgument {
<#
.SYNOPSIS
    Turn a redirector's $PSBoundParameters (plus its unmatched arguments) into
    the argument array for the per-host script.
.DESCRIPTION
    Only parameters the caller actually PASSED are forwarded. A redirector
    therefore declares its mirrored parameters without default values: an
    omitted parameter reaches the child as omitted, and the child's own default
    applies. Restating the child's defaults on this side would create a second
    place for them to drift.

    PowerShell's common parameters (-Verbose, -ErrorAction, ...) are never
    forwarded automatically: they bind to the redirector, and not every
    per-host script is an advanced script that can accept them. A redirector
    whose target does accept them passes them explicitly via -ExtraArgument.
.PARAMETER BoundParameters
    The redirector's $PSBoundParameters.
.PARAMETER RemainingArguments
    The redirector's ValueFromRemainingArguments catch-all: anything the
    redirector does not declare, forwarded verbatim so a parameter added to a
    per-host script needs no edit here.
.PARAMETER Exclude
    Parameter names to drop, on top of the common parameters. A redirector
    excludes the name of its own catch-all (it is appended separately).
.PARAMETER ExtraArgument
    Literal arguments appended before the catch-all.
.OUTPUTS
    System.String[]
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [System.Collections.IDictionary]$BoundParameters = @{},
        [string[]]$RemainingArguments = @(),
        [string[]]$Exclude = @(),
        [string[]]$ExtraArgument = @()
    )
    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in [System.Management.Automation.PSCmdlet]::CommonParameters) { [void]$skip.Add($name) }
    foreach ($name in [System.Management.Automation.PSCmdlet]::OptionalCommonParameters) { [void]$skip.Add($name) }
    foreach ($name in $Exclude) { [void]$skip.Add($name) }

    $forwarded = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $BoundParameters.Keys) {
        if ($skip.Contains($name)) { continue }
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            # A switch is forwarded only when present. "-Name:$false" is not
            # emitted: to a `pwsh -File` child it means the same as leaving the
            # switch off, and every target here treats absent as false.
            if ($value.IsPresent) { $forwarded.Add("-$name") }
            continue
        }
        $forwarded.Add("-$name")
        $forwarded.Add([string]$value)
    }
    foreach ($argument in $ExtraArgument)      { $forwarded.Add($argument) }
    foreach ($argument in $RemainingArguments) { $forwarded.Add($argument) }

    return $forwarded.ToArray()
}

function Invoke-YurunaHostScript {
<#
.SYNOPSIS
    Run this host's copy of a script (host/<host type>/<name>.ps1) in a child
    pwsh rooted in that host folder.
.DESCRIPTION
    The child's stdout and stderr flow through unchanged, so a long host script
    still narrates live and can still prompt. Nothing is returned on the success
    stream: read $LASTEXITCODE afterwards for the child's exit code, exactly as
    for any other native command.
.PARAMETER ScriptName
    File name of the per-host script, with or without the .ps1 suffix.
.PARAMETER ArgumentList
    Arguments for the per-host script, typically from ConvertTo-HostScriptArgument.
.PARAMETER RepoRoot
    Repository root. Defaults to this module's repository.
.PARAMETER Quiet
    Suppress the two-line "Host type / Running" banner. The per-host script's
    own output is never suppressed.
.OUTPUTS
    None. Sets $LASTEXITCODE from the child process.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$ArgumentList = @(),
        [string]$RepoRoot,
        [switch]$Quiet
    )
    if (-not $RepoRoot) { $RepoRoot = Get-YurunaRepoRoot }
    $target = Resolve-YurunaHostScript -ScriptName $ScriptName -RepoRoot $RepoRoot

    # A child process inherits the parent's token: it cannot gain an elevation
    # the caller does not already hold. Refusing here, with the way out, beats
    # letting the child die on its own `#requires -RunAsAdministrator` line --
    # that failure names the per-host script the operator never typed, and says
    # nothing about how they got there. Windows only: elevation is the only
    # thing `#requires -RunAsAdministrator` can mean, and on macOS / Linux the
    # per-host scripts ask for sudo themselves, per operation, with a reason.
    if ($target.RequiresElevation -and $IsWindows -and -not (Test-IsAdministrator)) {
        # One line, no embedded newlines: PowerShell re-wraps a multi-line
        # exception message into its error block and the shape is lost.
        throw ("$($target.RelativePath) requires Administrator, and this session is not elevated. " +
               "Re-run the same command from an elevated PowerShell (Start-Process pwsh -Verb RunAs).")
    }

    if (-not $Quiet) {
        Write-Output "Host type: $($target.HostType)"
        Write-Output "Running:   $($target.RelativePath)"
        Write-Output ''
    }

    # Each element of the argument array must reach the child as exactly one
    # argv entry. Under Legacy passing, a value carrying a space or a quote (a
    # share path, a token) is re-split on the way in and the per-host script
    # binds the wrong values -- the legacy-quoting regression class.
    $PSNativeCommandArgumentPassing = 'Standard'

    # A non-zero exit from the child is a RESULT to hand back to the caller,
    # not a terminating error: the per-host cleanup scripts exit non-zero to
    # report partial work (survivors), and the redirector must be able to
    # propagate that code. Without this, a caller running under
    # $ErrorActionPreference='Stop' would get a NativeCommandExitException
    # instead, losing the code.
    $PSNativeCommandUseErrorActionPreference = $false

    # Run FROM the host folder: that is how the per-host scripts are documented
    # and normally invoked (./<name>.ps1), and it is what an operator would do
    # by hand. Push/Pop keeps the move scoped to this call -- the caller's own
    # location is restored whether the child succeeds, fails, or throws.
    Push-Location -LiteralPath $target.HostFolder
    try {
        & (Get-CurrentPwshPath) -NoLogo -NoProfile -File $target.Path @ArgumentList
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Get-YurunaRepoRoot, Get-CurrentPwshPath, Test-ScriptRequiresElevation, Resolve-YurunaHostScript, ConvertTo-HostScriptArgument, Invoke-YurunaHostScript

<#PSScriptInfo
.VERSION 2026.09.08
.GUID 4290efe6-0b47-4573-a67c-44f74ba35a69
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test modules import scope eviction pester
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
    Hold every module-to-module import to a scope that leaves the importer's
    commands where the importer put them.
.DESCRIPTION
    Import-Module -Force does two things, and only the first one is obvious. It
    loads the target, and before that it REMOVES any copy already resident. Where
    the reloaded copy lands is decided by the other switch: with -Global it lands
    in the global session state, and without it, it lands in the private session
    state of whichever module ran the import.

    Put those together in a module that imports a sibling with -Force and no
    -Global, and the sibling is not merely loaded twice -- it is moved. A caller
    that had already imported that sibling, and was holding its exported
    commands, loses them at the instant it imports the wrapper. The sibling stops
    appearing in Get-Module entirely, because it now lives inside the wrapper.

    Every part of that is silent. Both Import-Module calls return normally, emit
    no object, and write to no stream, so $ErrorActionPreference = 'Stop' does not
    see it and neither does a -ErrorAction Stop on the import itself. The damage
    only surfaces later, as CommandNotFoundException from whatever calls the
    evicted command -- arbitrarily far from the import that caused it.

    It is also order-dependent, which is why a behavioral test alone cannot be
    trusted to find it. The collision needs the caller to import the dependency
    BEFORE the wrapper; import them the other way round and the caller re-imports
    the dependency afterward and never notices. A suite that happens to use the
    safe order passes while a long-lived process using the other order comes up
    with commands missing. So the primary guard here is static: it reads the
    switch list off every import in the tree rather than waiting for an order
    that reproduces the loss.

    The rule binds imports inside function bodies exactly as it binds imports at
    module top level. Deferred imports are not a weaker case -- they are the worse
    one. A top-level import evicts once, at load, before the caller has done any
    work; an import inside a function evicts whenever something calls that
    function, so a runspace that came up correctly can lose commands in the middle
    of a run, long after every import in the file has already succeeded.

    Sites that pass -Force without -Global today are enumerated below, one entry
    per body, each capped so an exempt body cannot quietly grow a second one. An
    entry leaves this list one of two ways: the import gains -Global, or the site
    goes away. Neither the list nor any entry's cap may grow.

    Run: Invoke-Pester -Path test/modules/Test.ModuleImportScope.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here

# Only .psm1 is scanned. A .ps1 imports at its own top level, which is the
# global session state, so -Force there reloads in place and evicts nothing.
# The eviction needs a module's private session state to move the target into.
#
# The set of modules is selected the way tools/Invoke-TestSuite.ps1 and
# tools/Invoke-Lint.ps1 select theirs -- tracked plus new, minus everything
# .gitignore covers -- rather than from a list of directories. A named-root
# list is the wrong shape for a rule that has to hold everywhere: it is
# complete only for the trees somebody remembered, and a module tree nobody
# added reads as compliance rather than as an unexamined area. The same
# selector also keeps the generated working copies under project/ out, which a
# plain filesystem walk would sweep in and make the findings depend on whether
# the harness had run.
function Get-WalkedModulePath {
    <#
    .SYNOPSIS
        Every .psm1 under a root that belongs to the repository at that root.
    .DESCRIPTION
        A directory carrying its own .git is a different repository that happens
        to sit inside this one -- here, the per-cycle clone the harness drops
        under project/. Its modules answer to their own tree's rules, and
        reporting them names a file whose owner cannot act on the finding.
        Testing for the nested checkout keeps them out without a list of
        directory names to maintain, and without needing git to run.
    .PARAMETER Root
        The repository root to walk.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Root)

    $normalizedRoot = $Root.TrimEnd('/', '\')
    return , @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.psm1' -ErrorAction SilentlyContinue |
            Where-Object {
                $directory = Split-Path -Parent $_.FullName
                $nested = $false
                while ($directory -and $directory.TrimEnd('/', '\') -ne $normalizedRoot) {
                    if (Test-Path -LiteralPath (Join-Path $directory '.git')) { $nested = $true; break }
                    $parent = Split-Path -Parent $directory
                    if ($parent -eq $directory) { break }
                    $directory = $parent
                }
                -not $nested
            } | ForEach-Object { $_.FullName })
}

function Get-ScannedModulePath {
    <#
    .SYNOPSIS
        Every repository module the rule applies to, as full paths.
    .PARAMETER Root
        The repository root to select within.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Root)

    $relative = $null
    try {
        Push-Location -LiteralPath $Root
        $relative = @(git ls-files --cached --others --exclude-standard -- '*.psm1' 2>$null |
                Where-Object { $_ })
    } catch {
        $relative = $null
    } finally {
        Pop-Location
    }

    if ($relative) {
        return , @($relative | ForEach-Object { Join-Path $Root $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }

    # No git, or an export that is not a work tree. The walk is wider than the
    # selector above rather than narrower, so the rule is still applied
    # everywhere; it can only add files the selector would have hidden.
    return , (Get-WalkedModulePath -Root $Root)
}

# --- REGION: Recorded sites

# Each entry names one body -- File plus the enclosing function, '' for module
# top level -- and caps how many un-Global -Force sibling imports it may hold.
# The cap is what makes an entry an exception rather than an exemption: a body
# on this list still fails the moment it grows another one.
#
# Reason states what the import is for and what stands between the site and a
# lost command. Two shapes recur. Some sites import only after Get-Command has
# already shown the command is NOT resolvable, which settles the question --
# eviction cannot take a command the caller was demonstrably not holding. The
# rest are recorded, not cleared: adding -Global publishes the sibling into
# every caller's session, which is a wider surface than the site asked for, so
# the correction is a deliberate edit and not a mechanical one.
$script:RecordedSite = @(
    @{
        File = 'automation/Yuruna.CloudInitTemplate.psm1'; Function = ''; Max = 1
        Reason = @'
Yuruna.GitHubSource supplies the repository, commit and token that
New-CloudInitUserData bakes into every guest seed. Recorded, not cleared.
'@
    }
    @{
        File = 'automation/Yuruna.HostRedirect.psm1'; Function = ''; Max = 1
        Reason = @'
Deliberate: the site states at the import that Test-IsAdministrator is wanted in
this module's scope only and the caller's session is to be left alone. The
target is a dependency-free leaf, so nothing else can be reached through it.
'@
    }
    @{
        File = 'automation/Yuruna.HostSetup.psm1'; Function = 'Initialize-HostSetupModule'; Max = 1
        Reason = @'
The generic loader every host-setup module is pulled in through, taking its
target as a parameter. Recorded, not cleared.
'@
    }
    @{
        File = 'automation/Yuruna.Resource.psm1'; Function = ''; Max = 1
        Reason = @'
The shared retry policy that mirrors automation/yuruna-retry.sh. The two imports
beside it already pass -Global; this one is the odd member. Recorded, not cleared.
'@
    }
    @{
        File = 'host/macos.utm/modules/Yuruna.Host.psm1'; Function = ''; Max = 1
        Reason = @'
Loads Yuruna.Host.Contract to run the load-time export-coverage assertion just
below it. The three host-family modules carry one of these each and are the only
importers of the contract module, so no caller can be holding the commands the
reload moves. Recorded, not cleared.
'@
    }
    @{
        File = 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'; Function = ''; Max = 1
        Reason = @'
The ubuntu.kvm member of the host-family contract-coverage triple, in the same
shape as its two siblings. Recorded, not cleared.
'@
    }
    @{
        File = 'host/windows.hyper-v/modules/Yuruna.Host.psm1'; Function = ''; Max = 1
        Reason = @'
The windows.hyper-v member of the host-family contract-coverage triple, in the
same shape as its two siblings. Recorded, not cleared.
'@
    }
    @{
        File = 'host/modules/Yuruna.VMCleanup.psm1'; Function = 'Resolve-BaseImageName'; Max = 1
        Reason = @'
Reached once per cleanup to ask Yuruna.Image for the canonical extension base
image stem, which no guest folder owns. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.ConfigServiceSync.psm1'; Function = ''; Max = 3
        Reason = @'
The config-sync grammar helpers -- Test.ConfigSync, Test.PoolStorage and
Test.HostDetection. The Test.StateFile import above them already passes -Global.
Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.ConfigServiceSync.psm1'; Function = 'Resolve-ConfigSyncInternalAuthKey'; Max = 1
        Reason = @'
Loads the caching-proxy module to read the aggregator seed URL, inside a
try/catch whose failure path is a blank base URL. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.ConfigServiceSync.psm1'; Function = 'Sync-ConfigSyncVaultCredential'; Max = 1
        Reason = @'
Loads the extension loader to reach the authentication area. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.ConfigServiceSync.psm1'; Function = 'Test-ConfigSyncReferenceFreshness'; Max = 1
        Reason = @'
Guarded: the import is reached only when Get-RetiredConfigKeyMap does not
already resolve, so there is no resident copy for the reload to take away.
'@
    }
    @{
        File = 'test/modules/Test.ConfigServiceSync.psm1'; Function = 'Sync-HostConfiguration'; Max = 1
        Reason = @'
Loads Test.ConfigNaming to rewrite retired keys during a per-host sync.
Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.DownloadAgentService.psm1'; Function = ''; Max = 1
        Reason = @'
Test.ExtensionService carries the marker layer these thin wrappers rename.
Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.HostCondition.Windows.psm1'; Function = 'Set-WindowsHostConditionSet'; Max = 1
        Reason = @'
Loads Test.StatusFirewall so host setup applies the same create/enable/rebuild
rule the status service self-heals with. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.Log.psm1'; Function = 'Get-CycleScreenDir'; Max = 1
        Reason = @'
Reached only when neither a cycle folder nor YURUNA_LOG_DIR is set, to establish
a log directory. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.Log.psm1'; Function = 'Stop-LogFile'; Max = 1
        Reason = @'
Guarded: the import is reached only when Get-HostAddressChangeCount does not
already resolve. The beacon module imports nothing, so it pulls no third module
into this scope with it.
'@
    }
    @{
        File = 'test/modules/Test.PoolWorker.psm1'; Function = ''; Max = 3
        Reason = @'
The service-VM roster, the extension half of that roster, and the share-path
grammar -- the three modules the teardown rules are written against. Recorded,
not cleared.
'@
    }
    @{
        File = 'test/modules/Test.ServiceVm.psm1'; Function = ''; Max = 1
        Reason = @'
Test.ExtensionService supplies the extension half of the service-VM roster. This
module is loaded on its own by the reboot sweep, where an empty roster is the
failure that matters. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.Start-GuestOS.psm1'; Function = ''; Max = 1
        Reason = @'
Test.YurunaDir for the log-directory helpers. The Test.SequenceEngine import
directly below it passes -Global and says why. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.Start-GuestWorkload.psm1'; Function = ''; Max = 1
        Reason = @'
Test.YurunaDir for the log-directory helpers, the same shape as its sibling
dispatcher. Recorded, not cleared.
'@
    }
    @{
        File = 'test/modules/Test.Transport.psm1'; Function = 'Connect-VNC'; Max = 1
        Reason = @'
Guarded: reached only when Get-VncPortForVm does not already resolve, which is
the case where the macOS host module was never loaded in the first place.
'@
    }
    @{
        File = 'test/modules/Test.VMUtility.psm1'; Function = 'Get-StashServiceProbeCommand'; Max = 1
        Reason = @'
Guarded: the function returns early when Test-StashServiceHost already resolves,
so the import runs only against a session that does not hold the extension
module.
'@
    }
)

# --- REGION: Scan

# Switches take no following value, so the element after one is still a
# candidate target. Everything else on Import-Module consumes the next element
# unless it carries an inline argument (-Verbose:$false), which is why a naive
# "first non-parameter element" reader can mistake 'Stop' for a module path.
$script:ImportSwitch = @(
    'Force', 'Global', 'DisableNameChecking', 'PassThru', 'NoClobber',
    'AsCustomObject', 'SkipEditionCheck', 'UseWindowsPowerShell',
    'Verbose', 'Debug', 'WhatIf', 'Confirm'
)

function Test-ImportParameterName {
    <#
    .SYNOPSIS
        Whether a parameter as written names the given Import-Module parameter.
    .DESCRIPTION
        The AST records the abbreviation the author typed, not the resolved
        parameter, so -Glo binds -Global at run time while an equality test on
        'Global' misses it. Prefix matching is the only reading that agrees with
        the parser.
    .PARAMETER Written
        The ParameterName exactly as it appears in the source.
    .PARAMETER Canonical
        The full parameter name to test against.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Written,
        [Parameter(Mandatory, Position = 1)][string]$Canonical
    )
    if (-not $Written) { return $false }
    return $Canonical.StartsWith($Written, [StringComparison]::OrdinalIgnoreCase)
}

function Test-ImportSwitchOn {
    <#
    .SYNOPSIS
        Whether a switch as written is actually on.
    .DESCRIPTION
        A switch carries a value when it is written with a colon, and -Force:$false
        is off however much it looks like a -Force. Reading presence alone gets
        both halves of that wrong: it demands -Global from an import that never
        reloads anything, and it accepts -Global:$false as the correction.
    .PARAMETER Element
        The CommandParameterAst for the switch.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)]$Element)

    if (-not $Element.Argument) { return $true }
    return ([string]$Element.Argument.Extent.Text) -notmatch '^\s*\$false\s*$'
}

function Test-ImportPublishedGlobally {
    <#
    .SYNOPSIS
        Whether an Import-Module call lands its target in the global session
        state.
    .DESCRIPTION
        Two spellings reach the same session state: the -Global switch, and
        -Scope with the value Global. Reading only the switch reports the second
        spelling as a private import and asks for a correction that is already
        there, so both count here.

        -Scope Local is the default written out rather than an alternative to
        it. It is still a private import, and -Force beside it still evicts the
        caller's copy, so it is not a global import and is not treated as one.
    .PARAMETER Node
        The Import-Module CommandAst.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)]$Node)

    $elements = @($Node.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        if (Test-ImportParameterName -Written $element.ParameterName -Canonical 'Global') {
            if (Test-ImportSwitchOn -Element $element) { return $true }
            continue
        }
        if (-not (Test-ImportParameterName -Written $element.ParameterName -Canonical 'Scope')) { continue }
        $value = $null
        if ($element.Argument) {
            $value = $element.Argument
        } elseif ($index + 1 -lt $elements.Count) {
            $value = $elements[$index + 1]
        }
        if (-not $value) { continue }
        if (([string]$value.Extent.Text).Trim("'", '"') -eq 'Global') { return $true }
    }
    return $false
}

function Get-ImportScopeLabel {
    <#
    .SYNOPSIS
        The body an import sits in: a function name, a script-block literal, or
        '' for module top level.
    .DESCRIPTION
        Walking only for a function definition is wrong here. A script-block
        literal passed to a command runs when that command dispatches it, not at
        module load, so reporting one of those as module top level names a moment
        that never happens. The walk stops at whichever construct is innermost.
    .PARAMETER Node
        The Import-Module CommandAst.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)]$Node)

    $current = $Node.Parent
    while ($current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current.Name
        }
        if ($current -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $consumer = ''
            if ($current.Parent -is [System.Management.Automation.Language.CommandAst]) {
                $consumer = [string]$current.Parent.GetCommandName()
            }
            if ($consumer) { return "<script block passed to $consumer>" }
            return '<script block>'
        }
        $current = $current.Parent
    }
    return ''
}

function Get-ImportTargetText {
    <#
    .SYNOPSIS
        The source text of the module an Import-Module call names, or '' when
        the call does not name one it can read.
    .PARAMETER Node
        The Import-Module CommandAst.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)]$Node)

    $elements = @($Node.CommandElements)
    $index = 1
    while ($index -lt $elements.Count) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $named = Test-ImportParameterName -Written $element.ParameterName -Canonical 'Name'
            $isSwitch = [bool](@($script:ImportSwitch |
                    Where-Object { Test-ImportParameterName -Written $element.ParameterName -Canonical $_ }).Count)
            if ($element.Argument) {
                if ($named) { return [string]$element.Argument.Extent.Text }
                $index++
                continue
            }
            if ($isSwitch) { $index++; continue }
            # A value-taking parameter: its value is the next element, never a target.
            if ($index + 1 -lt $elements.Count) {
                if ($named) { return [string]$elements[$index + 1].Extent.Text }
                $index += 2
                continue
            }
            $index++
            continue
        }
        return [string]$element.Extent.Text
    }
    return ''
}

function Test-SiblingModuleTarget {
    <#
    .SYNOPSIS
        Whether an import target is a repository module addressed by path.
    .DESCRIPTION
        The rule is about modules that live beside the importer in this tree, so
        a shipped or gallery module imported by bare name is out of scope: it is
        not a sibling and nothing here owns where it lands.

        A path is recognized by how it is built rather than by its extension --
        at least one repository import names a module file with no extension at
        all -- so a $PSScriptRoot or Join-Path expression counts, as does any
        literal carrying a separator.

        A variable target counts as in scope. The guard cannot follow the
        assignment that produced it, and every such target in this tree does
        resolve to a repository module, so the unreadable case fails closed: a
        real defect hidden behind a variable is worth more than the false
        positive of asking one shipped-module import to justify itself.
    .PARAMETER TargetText
        The source text returned by Get-ImportTargetText.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$TargetText)

    if (-not $TargetText) { return $false }
    if ($TargetText -match '\$') { return $true }
    if ($TargetText -match 'Join-Path') { return $true }
    if ($TargetText -match '[\\/]') { return $true }
    return $false
}

$script:ParseFailure = [System.Collections.Generic.List[string]]::new()
$script:Unreadable = [System.Collections.Generic.List[string]]::new()
$script:ForceImport = [System.Collections.Generic.List[object]]::new()

# Bare assignment, no @() around the call. The function returns its list
# comma-wrapped so a one-module result cannot unroll to a bare string, and
# @() around that would collect the wrapper instead -- one element holding
# the whole list, which parses as a single unreadable path rather than as a
# short list and is why the wrapper is unwound here and not by the caller.
$script:ScannedFile = Get-ScannedModulePath -Root $script:RepoRoot

function ConvertTo-RepoRelativePath {
    <#
    .SYNOPSIS
        A full path as the repository-relative, forward-slashed form the
        findings and the recorded sites are written in.
    .PARAMETER Path
        The full path.
    .PARAMETER Root
        The repository root it sits under.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$Root
    )
    return $Path.Substring($Root.Length).TrimStart('/', '\').Replace('\', '/')
}

# The selector above decides what is scanned, so it cannot also be the proof
# that the scan is complete -- asked whether it saw everything it chose, it
# always says yes. This walks the tree independently and subtracts what git
# reports as ignored, which is the one question the selector is not the
# authority on. What survives is a module that ships and that nothing scanned.
$script:Unscanned = @()
$script:WalkedFile = @((Get-WalkedModulePath -Root $script:RepoRoot) |
        ForEach-Object { ConvertTo-RepoRelativePath -Path $_ -Root $script:RepoRoot })

# git collapses a directory it ignores in its entirety to the directory name
# with a trailing slash, and never names the files inside it. Reading those
# entries as file paths subtracts nothing, so every module under a wholly
# ignored tree comes back as a finding -- and the tree most likely to be
# ignored whole is a per-cycle clone of another repository, whose modules this
# rule does not own. An entry ending in a slash is therefore a prefix.
$script:IgnoredEntry = $null
try {
    Push-Location -LiteralPath $script:RepoRoot
    $script:IgnoredEntry = @(git ls-files --others --ignored --exclude-standard --directory -- '*.psm1' 2>$null |
            Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') })
} catch {
    $script:IgnoredEntry = $null
} finally {
    Pop-Location
}
if ($null -ne $script:IgnoredEntry) {
    $ignoredPrefix = @($script:IgnoredEntry | Where-Object { $_.EndsWith('/') })
    $covered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $script:ScannedFile) {
        $null = $covered.Add((ConvertTo-RepoRelativePath -Path $path -Root $script:RepoRoot))
    }
    foreach ($entry in @($script:IgnoredEntry | Where-Object { -not $_.EndsWith('/') })) {
        $null = $covered.Add($entry)
    }
    $script:Unscanned = @($script:WalkedFile |
            Where-Object { -not $covered.Contains($_) } |
            Where-Object {
                $relative = $_
                -not (@($ignoredPrefix | Where-Object {
                            $relative.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
                        }).Count)
            } | Sort-Object)
}

foreach ($path in $script:ScannedFile) {
    $parseError = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseError)
    $relative = ConvertTo-RepoRelativePath -Path $path -Root $script:RepoRoot
    if ($parseError -and $parseError.Count -gt 0) {
        $script:ParseFailure.Add("${relative}: $($parseError[0].Message)")
        continue
    }

    foreach ($node in $fileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($node.GetCommandName() -ne 'Import-Module') { continue }

        # A splatted call hides its switches in a hashtable this scan cannot
        # read. None exist today; recording it as unreadable rather than
        # skipping it keeps the first one from passing unexamined.
        $splatted = @($node.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            })
        if ($splatted.Count -gt 0) {
            $script:Unreadable.Add("${relative}:$($node.Extent.StartLineNumber) splatted call: $($node.Extent.Text)")
            continue
        }

        $parameter = @($node.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
        $written = @($parameter | ForEach-Object { $_.ParameterName })
        $hasForce = [bool](@($parameter | Where-Object {
                    (Test-ImportParameterName -Written $_.ParameterName -Canonical 'Force') -and
                    (Test-ImportSwitchOn -Element $_)
                }).Count)
        if (-not $hasForce) { continue }

        $target = Get-ImportTargetText -Node $node
        if (-not (Test-SiblingModuleTarget -TargetText $target)) { continue }

        $hasGlobal = Test-ImportPublishedGlobally -Node $node
        $leaf = $target
        $match = [regex]::Matches($target, '[\w.\-]+\.psm1')
        if ($match.Count -gt 0) { $leaf = $match[$match.Count - 1].Value }

        $script:ForceImport.Add([pscustomobject]@{
                File     = $relative
                Line     = $node.Extent.StartLineNumber
                Function = (Get-ImportScopeLabel -Node $node)
                Module   = $leaf
                Switches = (($written | ForEach-Object { "-$_" }) -join ' ')
                Global   = $hasGlobal
            })
    }
}

$script:Evicting = @($script:ForceImport | Where-Object { -not $_.Global })

# --- REGION: Adjudication

$script:Unrecorded = @($script:Evicting | Where-Object {
        $site = $_
        -not (@($script:RecordedSite | Where-Object {
                    $_.File -eq $site.File -and $_.Function -eq $site.Function
                }).Count)
    })

$script:OverCap = @()
$script:StaleEntry = @()
foreach ($entry in $script:RecordedSite) {
    $matched = @($script:Evicting | Where-Object {
            $_.File -eq $entry.File -and $_.Function -eq $entry.Function
        })
    $where = if ($entry.Function) { $entry.Function } else { '<module top level>' }
    if ($matched.Count -eq 0) {
        $script:StaleEntry += "$($entry.File) [$where] no longer holds such an import -- remove the entry"
        continue
    }
    if ($matched.Count -gt $entry.Max) {
        $script:OverCap += ("$($entry.File) [$where] holds $($matched.Count) such imports, capped at $($entry.Max): " +
            (($matched | ForEach-Object { "line $($_.Line)" }) -join ', '))
    }
}

$script:CatalogModule = Join-Path $script:RepoRoot 'test/modules/Test.Catalog.psm1'
$script:LocaleModule = Join-Path $script:RepoRoot 'test/modules/Test.Locale.psm1'
}

Describe 'a module import leaves the importer holding what it already imported' {

    It 'parses every module it scans' {
        Assert-Equal -Expected 0 -Actual $script:ParseFailure.Count `
            "these files did not parse, so the scan never saw their imports:`n  $($script:ParseFailure -join "`n  ")"
        Assert-True ($script:ScannedFile.Count -gt 100) `
            "only $($script:ScannedFile.Count) modules were scanned, so the selector is wrong"
    }

    It 'scans every module that ships, not only the ones under a familiar path' {
        # A rule about where imports land is worth what it covers. A module the
        # scan never opens reads as a module with nothing wrong in it, and the
        # areas most likely to be missed are the ones added last -- which are
        # also the ones nobody has read for this defect yet.
        Assert-NoFinding $script:Unscanned @'
these modules ship and are not ignored, yet nothing scanned them, so the import
rule was never applied to them:
'@
    }

    It 'reads the switch list off every import it scans' {
        Assert-NoFinding $script:Unreadable `
            'these imports hide their switches from the scan, so the rule cannot be applied to them:'
    }

    It 'accepts every spelling that reaches the global session state and no spelling that does not' {
        # The rule is about where a module lands, not about which parameter the
        # author reached for. A reader that recognizes only the -Global switch
        # rejects an import that is already correct, and the site it names has
        # nothing left to change -- the worst kind of finding to hand someone.
        $cases = @(
            @{ Switches = '-Force -Global';        Global = $true;  Why = 'the plain switch' }
            @{ Switches = '-Force -Glo';           Global = $true;  Why = 'the abbreviation the parser accepts' }
            @{ Switches = '-Force -Scope Global';  Global = $true;  Why = 'the parameter spelling of the same scope' }
            @{ Switches = "-Force -Scope 'Global'"; Global = $true; Why = 'a quoted scope value' }
            @{ Switches = '-Force -Scope:Global';  Global = $true;  Why = 'a colon-bound scope value' }
            @{ Switches = '-Force -Scope Local';   Global = $false; Why = 'the default written out is still private' }
            @{ Switches = '-Force';                Global = $false; Why = 'no scope stated at all' }
            @{ Switches = '-Force -Global:$false'; Global = $false; Why = 'a switch turned off is not a switch passed' }
        )
        $findings = @()
        foreach ($case in $cases) {
            $source = "Import-Module (Join-Path `$here 'Sibling.psm1') $($case.Switches)"
            $node = [System.Management.Automation.Language.Parser]::ParseInput(
                $source, [ref]$null, [ref]$null).FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst]
                }, $true) | Select-Object -First 1
            $got = Test-ImportPublishedGlobally -Node $node
            if ($got -ne $case.Global) {
                $findings += "'$($case.Switches)' read as global=$got, want $($case.Global) -- $($case.Why)"
            }
        }

        # The other half of the same reading. -Force:$false reloads nothing, so
        # a site written that way evicts nothing and has no case to answer.
        foreach ($case in @(
                @{ Switches = '-Force'; Force = $true }
                @{ Switches = '-Force:$true'; Force = $true }
                @{ Switches = '-Force:$false'; Force = $false }
            )) {
            $source = "Import-Module (Join-Path `$here 'Sibling.psm1') $($case.Switches)"
            $node = [System.Management.Automation.Language.Parser]::ParseInput(
                $source, [ref]$null, [ref]$null).FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst]
                }, $true) | Select-Object -First 1
            $element = @($node.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })[0]
            $got = Test-ImportSwitchOn -Element $element
            if ($got -ne $case.Force) {
                $findings += "'$($case.Switches)' read as on=$got, want $($case.Force)"
            }
        }
        Assert-NoFinding $findings 'the scan misreads which imports publish globally'
    }

    It 'passes -Global wherever it passes -Force to a sibling module' {
        $detail = @($script:Unrecorded | ForEach-Object {
                $where = if ($_.Function) { $_.Function } else { '<module top level>' }
                "$($_.File):$($_.Line) [$where] imports $($_.Module) with $($_.Switches)"
            })
        Assert-NoFinding $detail @'
these imports reload a sibling module into their own private scope and remove it
from the runspace of whatever imported them first. Add -Global, or record the
site in this file with the reason it is safe there:
'@
    }

    It 'keeps every recorded site inside the cap it was recorded with' {
        Assert-NoFinding $script:OverCap @'
these bodies grew another un-Global -Force import. The cap is per body, so a
recorded site does not admit the next one:
'@
    }

    It 'holds no record of a site that no longer exists' {
        Assert-NoFinding $script:StaleEntry @'
these entries describe imports that are no longer there. A record left behind
after its site is fixed silently re-admits the defect the day something is added
back to that body:
'@
    }
}

Describe 'the catalog renderer and the locale resolver stay visible together' {

    It 'imports the locale resolver globally, so a catalog caller keeps the resolver' {
        $imports = @((Get-YurunaTestFileAst -Path $script:CatalogModule).FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Import-Module' -and
                    $n.Extent.Text -match 'Test\.Locale\.psm1'
                }, $true))

        Assert-Equal -Expected 1 -Actual $imports.Count `
            "Test.Catalog.psm1 imports Test.Locale.psm1 $($imports.Count) time(s); the pairing is meant to be stated once"

        $written = @($imports[0].CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object { $_.ParameterName })
        $hasGlobal = Test-ImportPublishedGlobally -Node $imports[0]

        Assert-True $hasGlobal @"
Test.Catalog.psm1 line $($imports[0].Extent.StartLineNumber) imports Test.Locale.psm1 with $(($written | ForEach-Object { "-$_" }) -join ' ').
Without -Global the resolver is moved into Test.Catalog's private scope, and any
caller that imported Test.Locale first loses Get-LocaleManifest and
New-LocaleContext the moment it imports Test.Catalog.
"@
    }

    It 'still resolves the locale commands after a runspace imports the resolver and then the renderer' {
        # A child pwsh, not this runspace, for three reasons that all point the
        # same way. The order under test must be the only variable, and this
        # runspace has already imported modules of its own. -Global means
        # "the global session state", and a Pester block does not run in it, so
        # an import here would answer a question about Pester's scope rather
        # than about the scope a script's top-level import actually reaches.
        # And a -Force import performed here would move modules underneath the
        # other tests in this file, making them depend on execution order.
        $exe = (Get-Process -Id $PID).Path
        if (-not $exe) { $exe = 'pwsh' }
        if (-not (Get-Command -Name $exe -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'no pwsh executable resolves here to open a fresh runspace with'
            return
        }

        $localePath = $script:LocaleModule.Replace("'", "''")
        $catalogPath = $script:CatalogModule.Replace("'", "''")

        # Switches match what a consuming script passes: -Global is deliberately
        # absent, because a script's top level already IS the global session
        # state. The import that has to carry -Global is the nested one inside
        # Test.Catalog, and this is the arrangement that reveals whether it does.
        #
        # Resolution is probed with Get-Command per function name rather than
        # with Get-Module. Several modules in this tree share a base name, so a
        # name-keyed module lookup answers about whichever copy is resident;
        # a command name is unambiguous, and CommandNotFoundException on these
        # exact names is the shape the loss takes anyway.
        $child = @"
`$ErrorActionPreference = 'Stop'
# Escape sequences in colored output would land inside the lines read back
# below, and inside the child output quoted in this test's failure message.
# `$PSStyle is 7.2 and newer, and touching an absent variable under the
# preference above would end the child before it imported anything.
if (Get-Variable -Name PSStyle -ErrorAction Ignore) { `$PSStyle.OutputRendering = 'PlainText' }
Import-Module '$localePath'  -Force -DisableNameChecking
Import-Module '$catalogPath' -Force -DisableNameChecking
foreach (`$name in @('Get-LocaleManifest', 'New-LocaleContext', 'Format-CatalogMessage')) {
    `$found = [bool](Get-Command -Name `$name -CommandType Function -ErrorAction SilentlyContinue)
    Write-Output "`$name=`$found"
}
`$manifest = Get-LocaleManifest
Write-Output "invoked=`$(`$manifest -is [hashtable])"
"@
        $output = (& $exe -NoProfile -Command $child 2>&1 | Out-String)

        $findings = @()
        foreach ($name in @('Get-LocaleManifest', 'New-LocaleContext', 'Format-CatalogMessage')) {
            if ($output -notmatch [regex]::Escape("$name=True")) {
                $findings += "$name did not resolve in the child runspace"
            }
        }
        if ($output -notmatch 'invoked=True') {
            $findings += 'Get-LocaleManifest did not return a manifest when called'
        }
        Assert-NoFinding $findings @"
a runspace that imports Test.Locale and then Test.Catalog lost the locale
commands, which is what a long-lived server does at startup and what every
localized page then fails on. Child output was:
$output
"@
    }
}

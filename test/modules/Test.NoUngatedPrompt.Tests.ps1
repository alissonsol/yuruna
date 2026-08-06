<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42f3a1c8-7b2d-4e59-8c04-1d6ea9b73f52
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test prompt unattended guard ast pester
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
    Repo-wide guard: a console prompt may only be reached through the shared
    "can I ask" predicate, or through an entry in the known-site inventory below.
.DESCRIPTION
    THE CLASS THIS CLOSES. A prompt raised where nobody can answer it does not
    fail -- it waits. When the caller is also capturing the child's stdout, the
    question itself goes into a file, so the run shows a step that has printed
    nothing and a cursor waiting on text nobody has seen. Every individual fix
    for that closes one call site. This closes the class, by making a new
    unguarded prompt fail a test instead of failing an unattended run.

    THE RULE. For each Read-Host / Get-Credential / $Host.UI.Prompt* site, a call
    to Test-YurunaCanPrompt or Assert-YurunaPromptable must appear lexically
    BEFORE it in the SAME body -- the same function, or file scope for a prompt
    at file scope. A guard somewhere else in the file does not count: a function
    is entered by whoever calls it, so a file-scope check decides nothing about
    what happens inside one, and accepting it would let the guards inside those
    functions be deleted one at a time with this rule still green.

    There is deliberately NO escape hatch for a -Force or -NonInteractive
    parameter. A file-scope switch says nothing about which prompt it suppresses:
    a script can carry -Force for its consent gate while a second, unrelated
    prompt in the same file is suppressed only by a different parameter, and a
    rule that accepts any switch in the param block green-lights exactly that
    second prompt. The predicate is the only signal that is about the prompt in
    front of it.

    WHAT IS NOT SCANNED. ShouldContinue / ShouldProcess are left to the engine:
    under -NonInteractive a confirmation is an error rather than a wait, and
    -Confirm:$false suppresses it at the call site, which is a mechanism the
    caller can see. Mandatory parameters are a prompt too, and are not detectable
    this way; the predicate's own companion takes none for that reason.

    THE INVENTORY. $KnownPromptSite carries the prompt sites that reach an
    operator by some other route, one explicit file+function entry at a time with
    a written reason -- never a directory glob, because a glob keeps admitting
    sites nobody read.
    Each entry states what protects that site instead of the shared predicate.
    An entry caps the number of prompts its body may contain, so an allowlisted
    function cannot quietly grow a new one; losing a prompt is fine and never
    fails, so removing a question needs no bookkeeping here.

    Throw-based assertions (no Should), and Describe/Context/It are supplied
    locally when Pester is absent -- a guard that cannot be executed on the host
    that needs it guards nothing.
    Run: pwsh -NoProfile -File test/modules/Test.NoUngatedPrompt.Tests.ps1
         (or Invoke-Pester -Path test/modules/Test.NoUngatedPrompt.Tests.ps1)
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Pester is not installed on every host that runs this repo's scripts, and the
# assertions here are plain throws, so the harness the file needs is three
# functions. Defined only when the real ones are absent; every fixture is
# computed at file scope, so the immediate-run shim and Pester's
# discovery-then-run split observe the same state.
if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    function Describe { param([string]$Name, [scriptblock]$Fixture) Write-Output "Describe: $Name"; & $Fixture }
    function Context  { param([string]$Name, [scriptblock]$Fixture) Write-Output "  Context: $Name"; & $Fixture }
    function It       { param([string]$Name, [scriptblock]$Test)    & $Test; Write-Output "    [pass] $Name" }
}

# --- the inventory of prompts protected by something other than the predicate -
# File is repo-relative with forward slashes; Function is '' for a prompt at file
# scope; Max is the number of prompt sites that body may contain.
$KnownPromptSite = @(
    @{
        File = 'install/setup.ps1'; Function = 'Read-Choice'; Max = 1
        Reason = @'
setup.ps1's own questionnaire, and the one place in a run that legitimately owns
the terminal: it asks BEFORE the run's single authorization is taken and the
no-prompt contract is published to everything the script starts. It must keep
self-answering on the answer file alone -- the contract variable is exported to
children and grandchildren, so a run launched under an inherited copy would skip
the entire questionnaire and record answers no operator gave.
'@
    }
    @{
        File = 'install/setup.ps1'; Function = 'Read-Text'; Max = 1
        Reason = 'The free-text half of the same questionnaire; see the Read-Choice entry.'
    }
    @{
        File = 'install/windows.hyper-v.ps1'; Function = 'Test-SystemRequirement'; Max = 1
        Reason = @'
The Windows bootstrap an operator runs by hand before any of this exists, so
there is no parent that could have taken the authorization. The question it asks
-- continue on hardware the harness is not tested on -- has no safe default in
either direction.
'@
    }
    @{
        File = 'host/macos.utm/Remove-OrphanedVMFiles.ps1'; Function = ''; Max = 1
        Reason = 'Interactive-by-design operator tool: it deletes VM disk images and asks per file. Nothing in the harness starts it.'
    }
    @{
        File = 'host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1'; Function = ''; Max = 1
        Reason = 'Interactive-by-design operator tool: it deletes VM disk images and asks per file. Nothing in the harness starts it.'
    }
    @{
        File = 'host/windows.hyper-v/Remove-OrphanedVMFiles.ps1'; Function = ''; Max = 1
        Reason = 'Interactive-by-design operator tool: it deletes VM disk images and asks per file. Nothing in the harness starts it.'
    }
    @{
        File = 'test/Move-CachingProxyService.ps1'; Function = ''; Max = 2
        Reason = 'Interactive-by-design operator tool for moving a service between addresses; it is invoked by hand and by nothing else.'
    }
    @{
        File = 'host/ubuntu.kvm/Enable-TestAutomation.ps1'; Function = ''; Max = 1
        Reason = @'
Gated on [Console]::IsInputRedirected, which every child the installer starts has
forced true, so the apt-get install this offers is already unreachable from a
parent-driven run. The guard is a narrower spelling of the shared predicate: it
cannot see the published contract, and it accepts a console whose OUTPUT is
being captured.
'@
    }
    @{
        File = 'test/modules/Test.HostIdentity.psm1'; Function = 'Read-HostIdentityConfirm'; Max = 1
        Reason = @'
The module's confirm helper. Its only caller path is entered behind
Test-HostIdentityInteractive, the file's own copy of the console probe -- the
same narrower spelling as above.
'@
    }
    @{
        File = 'test/modules/Test.HostIdentity.psm1'; Function = 'Invoke-PoolStorageSetupAndReclaim'; Max = 5
        Reason = @'
The interactive NAS/identity questionnaire an operator reaches by running
Enable-TestAutomation.ps1 by hand. The function returns early on
Test-HostIdentityInteractive before any of these reads, and setup.ps1 keeps it
out of its own run entirely by passing -SkipPoolStorage.
'@
    }
    @{
        File = 'test/modules/Test.ConfigServiceSync.psm1'; Function = 'Sync-ConfigSyncHostAlias'; Max = 1
        Reason = @'
Suppressed by the module's own -NonInteractive parameter, checked two lines
above the read, and every unattended caller passes it. The parameter is a
call-site contract rather than a fact about the console, so it holds only as
long as each caller keeps its half.
'@
    }
    @{
        File = 'test/modules/Test.ConfigServiceSync.psm1'; Function = 'Read-ConfigSyncSecret'; Max = 1
        Reason = 'The secret-reading helper for the same flow; its callers make the same -NonInteractive decision before reaching it.'
    }
    @{
        File = 'test/New-LocalTestUser.ps1'; Function = 'Confirm-Step'; Max = 1
        Reason = 'Interactive-by-design operator tool that creates an OS account; nothing in the harness invokes it. Its consent gate is answered in advance by -Force.'
    }
    @{
        File = 'test/New-LocalTestUser.ps1'; Function = 'Read-NewPassword'; Max = 2
        Reason = 'The password pair for the same tool, reached only when no password was supplied on the command line.'
    }
    @{
        File = 'test/Set-LabToken.ps1'; Function = ''; Max = 1
        Reason = @'
Suppressed by the script's own -NonInteractive switch, checked immediately above
the read, and setup.ps1 passes it. Same call-site-contract caveat as the config
sync helpers.
'@
    }
)

# --- scan ---------------------------------------------------------------------
$PromptCommand = @('Read-Host', 'Get-Credential')

function Get-EnclosingFunctionName {
    # Innermost function whose extent contains the offset, or '' at file scope.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$FunctionAst, [Parameter(Mandatory)][int]$Offset)
    $best = $null
    foreach ($fn in $FunctionAst) {
        if ($fn.Extent.StartOffset -le $Offset -and $Offset -lt $fn.Extent.EndOffset) {
            if ($null -eq $best -or $fn.Extent.StartOffset -gt $best.Extent.StartOffset) { $best = $fn }
        }
    }
    if ($best) { return $best.Name }
    return ''
}

$scanRoot   = @('install', 'test', 'host', 'automation')
$scanFile   = foreach ($r in $scanRoot) {
    Get-ChildItem -Path (Join-Path $repoRoot $r) -Recurse -File -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue
}
$promptSite = [System.Collections.Generic.List[object]]::new()
$parseFail  = [System.Collections.Generic.List[string]]::new()

foreach ($file in $scanFile) {
    # This file names the primitives in its own rule data. They are string
    # literals, so the AST never sees them as calls, but skipping it keeps the
    # guard from ever being about itself.
    if ($file.FullName -eq $PSCommandPath) { continue }

    $parseError = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseError)
    if ($parseError -and $parseError.Count -gt 0) {
        $parseFail.Add("$($file.FullName): $($parseError[0].Message)")
        continue
    }
    $functionAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if ($name -and ($PromptCommand -contains $name)) {
            $found.Add([pscustomobject]@{ Offset = $cmd.Extent.StartOffset; Line = $cmd.Extent.StartLineNumber; Kind = $name })
        }
    }
    foreach ($member in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $memberName = "$($member.Member.Extent.Text)"
        if ($memberName -match '^Prompt') {
            $found.Add([pscustomobject]@{ Offset = $member.Extent.StartOffset; Line = $member.Extent.StartLineNumber; Kind = "`$Host.UI.$memberName" })
        }
    }
    if ($found.Count -eq 0) { continue }

    # Guard calls, with the scope each one governs.
    $guard = foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if ($name -in @('Test-YurunaCanPrompt', 'Assert-YurunaPromptable')) {
            [pscustomobject]@{
                Offset   = $cmd.Extent.StartOffset
                Function = (Get-EnclosingFunctionName -FunctionAst $functionAst -Offset $cmd.Extent.StartOffset)
            }
        }
    }
    $guard = @($guard)

    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart('/', '\').Replace('\', '/')
    foreach ($site in $found) {
        $siteFunction = Get-EnclosingFunctionName -FunctionAst $functionAst -Offset $site.Offset
        # Same body, not merely the same file. A guard at file scope runs once,
        # while a function carrying a prompt runs whenever something calls it, so
        # only a guard inside that body is a statement about that prompt.
        $guarded = [bool](@($guard | Where-Object {
            $_.Offset -lt $site.Offset -and $_.Function -eq $siteFunction
        }).Count)
        $promptSite.Add([pscustomobject]@{
            File     = $relative
            Function = $siteFunction
            Line     = $site.Line
            Kind     = $site.Kind
            Guarded  = $guarded
        })
    }
}

function Test-KnownPromptSite {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Site, [Parameter(Mandatory)]$Inventory)
    foreach ($known in $Inventory) {
        if ($known.File -eq $Site.File -and $known.Function -eq $Site.Function) { return $true }
    }
    return $false
}

Describe 'No ungated console prompt' {

    It 'parses every scanned file' {
        Assert-True ($parseFail.Count -eq 0) "unparseable file(s), so the scan is incomplete:`n  $($parseFail -join "`n  ")"
    }

    It 'reaches every prompt through the shared predicate, or through a known site' {
        $offenders = @($promptSite | Where-Object { -not $_.Guarded -and -not (Test-KnownPromptSite -Site $_ -Inventory $KnownPromptSite) })
        $detail = ($offenders | ForEach-Object {
            $where = if ($_.Function) { $_.Function } else { '<file scope>' }
            "  $($_.File):$($_.Line)  $($_.Kind) in $where"
        }) -join "`n"
        Assert-True ($offenders.Count -eq 0) @"
$($offenders.Count) prompt(s) can be raised where nobody may be able to answer:
$detail
Call Test-YurunaCanPrompt before the prompt and take the non-interactive path, or
call Assert-YurunaPromptable to fail naming the parameter that answers it in
advance. Both come from automation/Yuruna.Common.psm1. If the prompt genuinely
belongs to a tool an operator runs by hand, add a file+function entry to
`$KnownPromptSite with the reason.
"@
    }

    It 'never lets a known site grow a new prompt' {
        # Only growth fails. A body that loses a prompt is a body that got safer,
        # and making that fail would turn every deletion into a two-file edit.
        $grown = foreach ($known in $KnownPromptSite) {
            $actual = @($promptSite | Where-Object { $_.File -eq $known.File -and $_.Function -eq $known.Function }).Count
            if ($actual -gt $known.Max) {
                $where = if ($known.Function) { $known.Function } else { '<file scope>' }
                "  $($known.File) / $where -- allows $($known.Max), found $actual"
            }
        }
        $grown = @($grown)
        Assert-True ($grown.Count -eq 0) @"
$($grown.Count) known prompt site(s) gained a prompt the recorded reason does not cover:
$($grown -join "`n")
Guard the new prompt with the shared predicate, or raise the entry's Max and say
in its reason why the new question is safe where it is asked.
"@
        # Stale entries are reported, not failed: an entry outlives its prompt the
        # moment someone guards or deletes it, and a change that improves another
        # file should never be blocked by bookkeeping in this one.
        $stale = foreach ($known in $KnownPromptSite) {
            $actual = @($promptSite | Where-Object { $_.File -eq $known.File -and $_.Function -eq $known.Function }).Count
            if ($actual -eq 0) {
                $where = if ($known.Function) { $known.Function } else { '<file scope>' }
                "$($known.File) / $where"
            }
        }
        $stale = @($stale)
        if ($stale.Count -gt 0) {
            Write-Warning "Known prompt sites with nothing left to cover (safe to delete): $($stale -join '; ')"
        }
    }
}

Describe 'The shared predicate the rule points at' {

    It 'is exported by automation/Yuruna.Common.psm1 under both names' {
        # The rule above is only as good as the names it looks for: renaming or
        # un-exporting either one would silently turn every guarded site into an
        # unguarded one that still passes, because the scan would stop matching.
        $commonPath = Join-Path -Path $repoRoot -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1'
        Assert-True (Test-Path -LiteralPath $commonPath) "not found: $commonPath"
        $module = Import-Module $commonPath -Force -DisableNameChecking -PassThru
        try {
            foreach ($name in @('Test-YurunaCanPrompt', 'Assert-YurunaPromptable')) {
                Assert-True ($module.ExportedFunctions.ContainsKey($name)) "Yuruna.Common must export $name"
            }
        } finally {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
        }
    }

    It 'answers no when this process cannot be asked' {
        # Run in a child with stdin and stdout redirected -- the shape a captured
        # child gets -- because the predicate must be false there even though the
        # terminal that started the run is perfectly interactive.
        $pwshExe = if (Get-Command -Name 'Get-PwshExePath' -ErrorAction SilentlyContinue) {
            Get-PwshExePath
        } else {
            (Get-Process -Id $PID).Path
        }
        $commonPath = Join-Path -Path $repoRoot -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1'
        $probe = "Import-Module '$commonPath' -Force -DisableNameChecking; if (Test-YurunaCanPrompt) { 'yes' } else { 'no' }"
        $answer = (@() | & $pwshExe -NoProfile -NonInteractive -Command $probe 2>&1 | Select-Object -Last 1)
        Assert-True ("$answer".Trim() -eq 'no') "a child with redirected stdin/stdout must not believe it can prompt (got '$answer')"
    }
}

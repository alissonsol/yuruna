<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42c1a7d4-3b28-4e60-9f15-6d0c83b7ae21
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sudo elevation noninteractive pester
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
    No bare interactive `sudo` in the scripts install/setup.ps1 starts.
.DESCRIPTION
    WHY THIS RULE EXISTS. sudo reads its password from /dev/tty, not from stdin.
    Every other no-prompt mechanism this repo relies on -- closing the child's
    stdin, passing -NonInteractive, publishing the no-prompt environment
    contract -- controls PowerShell's prompts and reaches none of sudo's. So a
    bare `sudo <cmd>` inside a child whose stdout is captured to a log writes its
    password prompt onto a console the parent has taken over, where nothing
    displays it and nothing answers it, and the step waits until something kills
    it. `sudo -n` turns that into an exit code in the same millisecond.

    WHAT COUNTS AS COMPLIANT. Either the invocation carries -n, or it is one of
    the sites listed in $KnownInteractiveSudo below: a place that legitimately
    asks a person for a password because a person is provably there. Those are
    listed individually, with the reason, rather than matched by a pattern --
    a pattern is how the next one gets in.

    SCOPE. The scripts reachable from install/setup.ps1's storage and host-
    settings steps, which is where the capture-plus-tty combination actually
    occurs. Widening this to the whole tree is a deliberate act, not a default:
    there are bare `sudo` calls elsewhere in interactive operator tools, and a
    rule that fails on day one gets suppressed rather than obeyed.

    Assertions are plain throws and the Pester harness is shimmed when Pester is
    absent, so this runs either way.
    Run: pwsh -NoProfile -File test/modules/Test.SudoDiscipline.Tests.ps1
         (or Invoke-Pester -Path test/modules/Test.SudoDiscipline.Tests.ps1)
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

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

# Repo-relative, forward slashes.
$ScopedFile = @(
    'test/modules/Test.HostCondition.Mac.psm1'
    'test/modules/Test.HostAutomationState.psm1'
    'test/modules/Test.LocalLabStorage.psm1'
    'test/New-LocalLabStorage.ps1'
    # Called straight out of the storage step's step 8, so its sudo calls run
    # inside the same captured child as everything above. A scan that stops at
    # the scripts and skips the module one of them calls is a scan that cannot
    # see the shape it exists to catch.
    'test/modules/Test.PoolStorage.psm1'
    'host/macos.utm/Enable-TestAutomation.ps1'
    'host/macos.utm/Disable-TestAutomation.ps1'
    'host/macos.utm/modules/Yuruna.Host.psm1'
    'host/ubuntu.kvm/Enable-TestAutomation.ps1'
    # The service bring-up and teardown scripts elevate to bind a sub-1024 port
    # and to stop a root-owned forwarder. Both run as captured children of the
    # setup step graph, so they are governed by the same contract as the storage
    # scripts -- and a scan that names only the storage half would have gone on
    # passing while these two held the one shape it exists to catch.
    'test/Start-CachingProxyServiceVM.ps1'
    'test/Stop-CachingProxyServiceVM.ps1'
    # Elevates to take the status-service port back from a holder this account
    # cannot stop. Every service bring-up in the graph above reaches it through
    # Start-StatusService.ps1, so its sudo runs inside those same captured
    # children -- the module a scoped script calls is where the shape hides.
    'test/modules/Test.PortOwner.psm1'
    'install/setup.ps1'
)

# Functions whose whole contract is "install a sudoers drop-in, prompting the
# operator once". They are safe only while every caller in the scoped graph
# binds the switch that turns the prompt off, which the last test below pins.
$SudoersInstaller = @('Set-PoolStorageSudoers')

# --- the inventory of sudo calls that may prompt --------------------------
# File is repo-relative; Function is the enclosing function ('' for file scope);
# Max is how many prompting sudo calls that body may contain.
$KnownInteractiveSudo = @(
    @{
        File = 'test/modules/Test.HostCondition.Mac.psm1'; Function = 'Initialize-SudoCache'; Max = 1
        Reason = @'
The one place whose entire job is to ask, once, with the reasons on screen. It
declines silently under the published no-prompt contract and only reaches the
prompt when no caller has taken the run's authorization. Adding -n here would
not make the run safer -- it would remove the only sanctioned way to obtain the
credential every -n call downstream depends on.
'@
    }
    @{
        File = 'test/New-LocalLabStorage.ps1'; Function = ''; Max = 1
        Reason = @'
The elevation banner, reached only after `sudo -n -v` failed AND
Test-YurunaCanPrompt confirmed a person can see and answer the question. The
banner names the accounts and shares the password will pay for, so this is
informed consent, not an unexplained password box.
'@
    }
    @{
        File = 'host/macos.utm/modules/Yuruna.Host.psm1'; Function = 'Invoke-MacElevationIfNeeded'; Max = 1
        Reason = @'
Same shape: `sudo -n -v` first, then Test-YurunaCanPrompt, and only then a
visible prompt with the reason printed above it.
'@
    }
    @{
        File = 'host/ubuntu.kvm/Enable-TestAutomation.ps1'; Function = ''; Max = 2
        Reason = @'
`apt-get update` and `apt-get install`, reached only after a person answered
"install them now?" at this terminal. sudo's prompt and apt's progress both
belong on the terminal that asked, so routing them through a capturing helper
would hide both.
'@
    }
    @{
        File = 'install/setup.ps1'; Function = 'Initialize-SetupElevation'; Max = 1
        Reason = @'
The run's single authorization, taken while the operator still owns the terminal
and before the no-prompt contract is published. Every -n call for the rest of the
run spends the timestamp this obtains, so -n here would leave nothing to spend.
'@
    }
    @{
        File = 'test/Start-CachingProxyServiceVM.ps1'; Function = ''; Max = 1
        Reason = @'
The else arm of the no-prompt branch: the captured path probes `sudo -n -v` and
warns, and this is only reached when the environment says a person is present.
The forwarder it pays for is a remote-LAN convenience, so declining costs the
run nothing else.
'@
    }
    @{
        File = 'test/Stop-CachingProxyServiceVM.ps1'; Function = ''; Max = 1
        Reason = @'
Same shape as the start script's: reached only when the run is not captured, to
stop a root-owned forwarder a previous run left behind. The captured path probes
and reports the manual command instead.
'@
    }
    @{
        File = 'test/modules/Test.PortOwner.psm1'; Function = 'Request-PortReclaimElevation'; Max = 1
        Reason = @'
The `sudo -v` that pays for taking the status-service port back from a holder
this account cannot stop -- reached only after `sudo -n true` has already failed
AND Test-YurunaCanPrompt has confirmed a person can see and answer the question.
The line printed immediately above it names the port and why root is needed, so
the operator is answering a stated question rather than a bare password box.
Adding -n here would not make the run safer: it would remove the only sanctioned
way to obtain the credential, and the takeover would go back to handing the
operator a manual kill for a server this harness left behind itself.
'@
    }
    @{
        File = 'test/modules/Test.PoolStorage.psm1'; Function = 'Set-PoolStorageSudoers'; Max = 4
        Reason = @'
tee / chmod / visudo / rm, writing the /etc/sudoers.d drop-in that makes every
LATER mount passwordless. The prompt is the point: this is the one moment an
operator is asked to pay for elevation so the unattended cycles never are, and
routing it through a capturing helper would hide the password prompt it needs.

Safe only because the function refuses before reaching any of them when its
-NonInteractive switch is set. That makes the switch the real guard, so it is
the CALLERS that have to be checked -- see the caller test below.
'@
    }
)

# --- AST scan -------------------------------------------------------------
function Get-EnclosingBodyText {
    <#
    .SYNOPSIS
        Source text of the function that contains a node, or of the whole file
        when the node sits at file scope.
    .DESCRIPTION
        A Start-Process spawn names its program and its argument vector by
        variable, and both are assigned in the body above the call. That body is
        the smallest region that can answer either question, so it is what the
        scan reads.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$FileAst
    )
    $parent = $Node.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return "$($parent.Extent.Text)" }
        $parent = $parent.Parent
    }
    return "$($FileAst.Extent.Text)"
}

function Get-SudoInvocation {
    <#
    .SYNOPSIS
        Every place in one file that runs sudo, with the enclosing function and
        whether -n is among its arguments.
    .DESCRIPTION
        Two shapes count, and only two, because only these two put sudo in front
        of a tty. A direct CommandAst (`& sudo ...` / `sudo ...`), and
        Start-Process -FilePath sudo, whose argument vector is a separate
        parameter. Calls that hand 'sudo' to one of this repo's own wrappers are
        NOT counted here: the wrapper owns the -n decision, and a separate test
        below pins that it still does.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]], [object[]])]
    param([Parameter(Mandatory)][string]$Path)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    $found = @()
    foreach ($cmd in $commands) {
        $name = $cmd.GetCommandName()
        $isDirect = ($name -eq 'sudo')
        $argText = @()
        if ($isDirect) {
            # Skip element 0 (the command itself); the rest are sudo's own
            # options up to the command it will run.
            for ($i = 1; $i -lt $cmd.CommandElements.Count; $i++) {
                $argText += "$($cmd.CommandElements[$i].Extent.Text)"
            }
        } elseif ($name -eq 'Start-Process') {
            $elements = @($cmd.CommandElements | ForEach-Object { "$($_.Extent.Text)" })
            $fileIndex = -1
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -match '^-FilePath$') { $fileIndex = $i + 1; break }
            }
            if ($fileIndex -lt 0 -or $fileIndex -ge $elements.Count) { continue }
            $fileToken = $elements[$fileIndex] -replace "^['`"]|['`"]$", ''
            # The spawn that most needs this rule is also the one that names its
            # program in a variable, because whether it needs sudo at all is
            # decided a few lines up ($f = if ($needsSudo) { 'sudo' } else { ... }).
            # Matching only a literal 'sudo' would skip exactly the shape that
            # hands sudo a DETACHED process with its output going to a file, where
            # a password prompt is written to a log and waits forever. So a
            # variable counts when the enclosing body assigns it the literal.
            $scopeText = Get-EnclosingBodyText -Node $cmd -FileAst $ast
            $isSudoSpawn = ($fileToken -eq 'sudo')
            if (-not $isSudoSpawn -and $fileToken -match '^\$[A-Za-z_][A-Za-z0-9_]*$') {
                $isSudoSpawn = [bool]($scopeText -match ('(?m)^\s*' + [regex]::Escape($fileToken) + "\s*=.*'sudo'"))
            }
            if (-not $isSudoSpawn) { continue }
            $isDirect = $true
            # The argument vector is built above the call and referenced by name,
            # so the check has to look at the whole enclosing body, not at the
            # call's own tokens -- which never carry the options at all.
            $argText = @($elements) + @($scopeText)
        }
        if (-not $isDirect) { continue }

        # -n anywhere in the vector is enough: sudo takes its options before the
        # command, and no command this repo runs under sudo has its own -n.
        $hasN = [bool](@($argText | Where-Object { $_ -eq '-n' -or $_ -eq "'-n'" -or $_ -eq '"-n"' }).Count)
        if (-not $hasN) {
            # Start-Process builds its vector elsewhere; accept an assignment to
            # the referenced variable that includes -n.
            $hasN = [bool]($argText -join ' ' | Select-String -SimpleMatch -Pattern "'-n'" -Quiet)
        }

        $fnName = ''
        $parent = $cmd.Parent
        while ($parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $fnName = $parent.Name; break }
            $parent = $parent.Parent
        }
        $found += @{
            Function = $fnName
            Line     = $cmd.Extent.StartLineNumber
            Text     = ($cmd.Extent.Text -split "`n")[0].Trim()
            HasN     = $hasN
        }
    }
    return @($found)
}

$Prompting = @()
foreach ($rel in $ScopedFile) {
    $full = Join-Path $repoRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { throw "Scoped file not found: $rel" }
    foreach ($site in (Get-SudoInvocation -Path $full)) {
        if ($site.HasN) { continue }
        $Prompting += @{ File = $rel; Function = $site.Function; Line = $site.Line; Text = $site.Text }
    }
}

Describe 'sudo discipline in the setup child graph' {
    It 'runs every unattended sudo call with -n' {
        $unknown = @()
        foreach ($p in $Prompting) {
            $allowed = @($KnownInteractiveSudo | Where-Object { $_.File -eq $p.File -and $_.Function -eq $p.Function })
            if ($allowed.Count -eq 0) { $unknown += "$($p.File):$($p.Line) [$(if ($p.Function) { $p.Function } else { '<file scope>' })] $($p.Text)" }
        }
        Assert-Equal -Expected '' -Actual ($unknown -join "`n") @'
A sudo call with no -n and no entry in $KnownInteractiveSudo. sudo reads its
password from /dev/tty, so under a captured child this prompts where nobody can
see or answer it. Add -n, or add an entry stating who is present to answer.
'@
    }

    It 'holds each sanctioned site to its declared count' {
        foreach ($entry in $KnownInteractiveSudo) {
            $actual = @($Prompting | Where-Object { $_.File -eq $entry.File -and $_.Function -eq $entry.Function }).Count
            Assert-True ($actual -le $entry.Max) `
                "$($entry.File) [$(if ($entry.Function) { $entry.Function } else { '<file scope>' })] has $actual prompting sudo call(s), declared max $($entry.Max). A new one needs its own reason."
        }
    }

    It 'gives every sanctioned site a written reason' {
        foreach ($entry in $KnownInteractiveSudo) {
            Assert-True ($entry.Reason -and $entry.Reason.Trim().Length -gt 40) `
                "$($entry.File) [$($entry.Function)] needs a reason someone can evaluate, not a placeholder."
        }
    }

    It 'keeps every allowlist entry pointing at real code' {
        # An entry that no longer matches anything is a rule nobody is obeying:
        # it makes the list look considered while protecting nothing.
        foreach ($entry in $KnownInteractiveSudo) {
            $actual = @($Prompting | Where-Object { $_.File -eq $entry.File -and $_.Function -eq $entry.Function }).Count
            Assert-True ($actual -gt 0) `
                "$($entry.File) [$($entry.Function)] no longer contains a prompting sudo call; remove the entry."
        }
    }
}

Describe 'the shared sudo wrappers stay the chokepoint' {
    It 'routes Invoke-LocalLabStorageNative sudo through Invoke-YurunaSudo' {
        # ~35 privileged calls in the local-storage build reach sudo through this
        # one helper. Most pass -AllowFailure because a non-zero exit is their
        # answer ("no such sharepoint"); "sudo would not run this at all" is not
        # an answer to any of them, and swallowing it builds half a storage
        # configuration and then reports the tiers it did create.
        $path = Join-Path $repoRoot 'test/modules/Test.LocalLabStorage.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Invoke-LocalLabStorageNative' }, $true))
        Assert-Equal -Expected 1 -Actual $fn.Count 'Invoke-LocalLabStorageNative must be defined once'
        $calls = @($fn[0].Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Invoke-YurunaSudo' }, $true))
        Assert-True ($calls.Count -ge 1) 'the sudo path must go through Invoke-YurunaSudo, which owns the -n decision and the blocked-elevation message'
    }

    It 'probes capability rather than provenance in the macOS host settings' {
        # An environment variable published by whoever started the run says a
        # human authorized sudo once. It does not say the privileged writes were
        # performed -- no installer in this repo performs them -- and it does not
        # say root is reachable now, because a timestamp expires and `sudo -k`
        # runs from package post-installs. Read as either, it skips every write in
        # this function while `sudo -n` succeeds three lines away.
        $path = Join-Path $repoRoot 'test/modules/Test.HostCondition.Mac.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Set-MacHostConditionSet' }, $true))
        Assert-Equal -Expected 1 -Actual $fn.Count 'Set-MacHostConditionSet must be defined once'
        $probes = @($fn[0].Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Test-MacSudoAvailable' }, $true))
        Assert-True ($probes.Count -ge 4) "every privileged block must probe for itself; found $($probes.Count)"
        $envReads = @($fn[0].Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.VariablePath.UserPath -match '^env:YURUNA_SUDO_PRIMED$' }, $true))
        Assert-Equal -Expected 0 -Actual $envReads.Count 'who started the run does not say whether root is reachable now'
    }

    It 'binds -NonInteractive on every sudoers-installer call in the scoped graph' {
        # The installer is allowed to prompt, so the switch that suppresses the
        # prompt is the entire safety property -- and it lives at the CALL SITE,
        # where it is invisible from the function that does the prompting. A call
        # that omits it inside a captured child reaches `sudo tee /etc/sudoers.d`
        # with sudo reading from /dev/tty: a prompt written to a terminal the
        # parent owns, which nothing displays and nothing answers, after the
        # accounts and the shares have already been created.
        $missing = @()
        foreach ($rel in $ScopedFile) {
            $path = Join-Path $repoRoot $rel
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -in $SudoersInstaller }, $true))
            foreach ($call in $calls) {
                # The definition itself is not a call, and a call from inside the
                # module that defines it has already made the decision.
                $bound = @($call.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'NonInteractive' })
                if ($bound.Count -eq 0) {
                    $missing += "${rel}:$($call.Extent.StartLineNumber) $(($call.Extent.Text -split "`n")[0].Trim())"
                }
            }
        }
        Assert-Equal -Expected '' -Actual ($missing -join "`n") @'
A sudoers-installer call that does not say whether anyone can answer a password
prompt. Bind -NonInteractive from the same predicate the rest of the script
uses, so a captured child gets the manual commands instead of a hidden prompt.
'@
    }

    It 'builds every splatted defaults argv through Get-MacDefaultsCommandArgument' {
        # `defaults` takes its host selector BEFORE the verb. A knob table that
        # carries '-currentHost' inside the domain+key vector, splatted after a
        # literal verb, emits `defaults write -currentHost <domain> <key> -int 0`
        # -- which binds -currentHost as the DOMAIN, rejects the type flag, and
        # leaves the write undone while the matching read reports the key absent.
        # That is how three ByHost knobs came to be neither applied nor restored,
        # and it is invisible in a read-back of the intended domain. One builder,
        # so the position cannot be decided per call site.
        foreach ($rel in @(
            'test/modules/Test.HostCondition.Mac.psm1'
            'test/modules/Test.HostAutomationState.psm1'
            'host/macos.utm/Disable-TestAutomation.ps1'
        )) {
            $path = Join-Path $repoRoot $rel
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $defaultsCalls = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'defaults' }, $true))
            foreach ($call in $defaultsCalls) {
                $elements = @($call.CommandElements)
                if ($elements.Count -lt 2) { continue }
                $line = $call.Extent.StartLineNumber
                $splats = @($elements | Where-Object {
                    $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted })
                if ($splats.Count -gt 0) {
                    # A splatted vector can carry a host selector, and the call
                    # site cannot see whether it does. So the vector must BE the
                    # whole argv, built by the one function that knows where the
                    # selector goes -- a literal verb in front of a splat is the
                    # exact shape that emitted the broken command.
                    $first = $elements[1]
                    Assert-True ($first -is [System.Management.Automation.Language.VariableExpressionAst] -and $first.Splatted) `
                        "${rel}:${line} puts a literal token before a splatted defaults vector; build the whole argv with Get-MacDefaultsCommandArgument"
                    $varName = $first.VariablePath.UserPath
                    $built = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left.Extent.Text -eq "`$$varName" -and
                        $n.Right.Extent.Text -match 'Get-MacDefaultsCommandArgument' }, $true))
                    Assert-True ($built.Count -ge 1) `
                        "${rel}:${line} splats `$$varName into defaults without building it through Get-MacDefaultsCommandArgument"
                    continue
                }
                # A fully literal argv: the verb may not precede a host selector.
                $text = ($elements[1..($elements.Count - 1)] | ForEach-Object { "$($_.Extent.Text)" }) -join ' '
                Assert-True ($text -notmatch '^(read|write|delete)\b.*(-currentHost|-host)\b') `
                    "${rel}:${line} puts the defaults verb before the host selector: defaults $text"
            }
        }
    }
}

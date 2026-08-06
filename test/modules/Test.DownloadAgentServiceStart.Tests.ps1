<#PSScriptInfo
.VERSION 2026.08.06
.GUID 4286c42a-cb68-48ff-84e9-b41d354f419b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service ast pester
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
    Structural (AST) guards on the download-agent service lifecycle entry
    points: Start-DownloadAgentServiceVM.ps1 and Stop-DownloadAgentServiceVM.ps1.
.DESCRIPTION
    Both scripts run top-to-bottom with `exit` and heavy I/O (hypervisor calls,
    a multi-minute VM build, SSH into the guest), so they are not invoked
    in-process here; instead the tests parse each file and assert the required
    SHAPE via AST nodes -- invoked commands, bound arguments, string literals,
    statement order -- rather than raw source text. A code comment is not an AST
    node, so a comment cannot satisfy a guard, and reformatting cannot break one.

    Pinned invariants:
      * The Start script waits for the daemon on a wall-clock deadline loop and
        probes the real port, so an IP alone is never reported as "the service
        is up".
      * The marker's `active` is bound to the readiness VERDICT variable, which
        starts $false and is only set $true by a successful probe. The
        aggregator paints the Extension-hosts row and its deep-link from that
        value; a marker that said "active" because the script merely ran would
        send operators and hosts to a dead endpoint.
      * The published base URL comes from the Shared-NAT-aware resolver, not
        from the VM address alone -- on UTM Shared NAT the VM address is
        unroutable for every peer.
      * Both scripts honor the log-level cascade and the entry-point exit-code
        contract.
      * The Stop script clears the marker and republishes the registration
        BEFORE it touches the VM, so the host never advertises an agent whose
        VM is already being destroyed.

    These are structural guards: they verify the required nodes are present and
    correctly shaped, not that the scripts execute correctly end to end.

    The throw-based Assert-* helpers live at script scope and are referenced from
    It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split hides
    top-level helpers from It blocks).
#>

$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here   # .../test

$startAgent = Join-Path $testDir 'Start-DownloadAgentServiceVM.ps1'
$stopAgent  = Join-Path $testDir 'Stop-DownloadAgentServiceVM.ps1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-ScriptAst {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}

function Get-CommandCall {
    param($Ast, [string]$Name)
    # Bind to a local so the parameter is referenced in the function body itself
    # (the closure below captures it, but PSReviewUnusedParameter cannot see a
    # use that only occurs inside a scriptblock handed to another command).
    $wanted = $Name
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted }, $true))
}

# Text of the argument bound to a named parameter on a CommandAst, covering both
# `-Name value` and `-Name:value` forms.
function Get-NamedArgumentText {
    param($CommandAst, [string]$ParameterName)
    $els = $CommandAst.CommandElements
    for ($i = 0; $i -lt $els.Count; $i++) {
        if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $ParameterName) {
            $arg = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
            if ($arg) { return $arg.Extent.Text }
        }
    }
    return $null
}

# String LITERAL nodes only (excludes comments), so a phrase match cannot be
# satisfied by an unrelated code comment.
function Get-StringLiteralExtent {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true) | ForEach-Object { $_.Extent.Text })
}

function Get-WhileStatement {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true))
}

# Every assignment of the named variable, as {LeftText; RightText} pairs.
function Get-AssignmentTo {
    param($Ast, [string]$VariableText)
    $wanted = $VariableText
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq $wanted
    }, $true))
}

# Start offset of the FIRST invocation of a command, or -1 when it never runs.
# Offsets are how statement ORDER is asserted: a guard that says "clear the
# marker before the teardown" has to compare positions, and the extent offset is
# the only position the AST exposes that survives reformatting.
function Get-FirstCallOffset {
    param($Ast, [string]$Name)
    $calls = @(Get-CommandCall -Ast $Ast -Name $Name)
    if ($calls.Count -eq 0) { return -1 }
    return (@($calls | ForEach-Object { $_.Extent.StartOffset }) | Sort-Object)[0]
}

$entryPointCases = @(
    @{ Name = 'Start-DownloadAgentServiceVM.ps1'; Path = $startAgent },
    @{ Name = 'Stop-DownloadAgentServiceVM.ps1';  Path = $stopAgent }
)

Describe 'Download-agent lifecycle entry points honor the entry-point contract' {
    foreach ($case in $entryPointCases) {
        # The per-case path reaches the It body through -TestCases rather than the
        # loop variable: a Describe body -- including a foreach that emits Its --
        # runs during discovery, and its variables are discarded before any It
        # executes, so a `$case.Path` read inside the body would arrive as $null.
        It "$($case.Name) calls Use-LogLevelFromEnv and Get-EntryPointExitCode" -TestCases @(@{ Path = $case.Path }) {
            param([string]$Path)
            $ast = Get-ScriptAst $Path
            Assert-True ((Get-CommandCall -Ast $ast -Name 'Use-LogLevelFromEnv').Count -ge 1) 'the log-level cascade is applied (a real invocation, not a comment)'
            $exitCalls = @(Get-CommandCall -Ast $ast -Name 'Get-EntryPointExitCode')
            Assert-True ($exitCalls.Count -ge 2) "both the Ok and Failure exit codes come from Get-EntryPointExitCode; found $($exitCalls.Count)"
            $outcomes = @($exitCalls | ForEach-Object { Get-NamedArgumentText -CommandAst $_ -ParameterName 'Outcome' })
            Assert-True ($outcomes -contains 'Ok') 'the Ok outcome is requested by name'
            Assert-True ($outcomes -contains 'Failure') 'the Failure outcome is requested by name'
        }
    }
}

Describe 'Start-DownloadAgentServiceVM.ps1 waits for the daemon before it advertises one' {
    It 'polls the real port inside a wall-clock deadline loop' {
        $ast = Get-ScriptAst $startAgent
        $deadlineLoops = @(Get-WhileStatement -Ast $ast | Where-Object { $_.Condition.Extent.Text -match '\$readyDeadline' })
        Assert-True ($deadlineLoops.Count -ge 1) 'the readiness wait is a while loop bounded by $readyDeadline (not an iteration counter)'
        $probes = @(Get-CommandCall -Ast $deadlineLoops[0] -Name 'Test-DownloadAgentServicePort')
        Assert-True ($probes.Count -ge 1) 'the loop body probes the port for real'
        Assert-True ((Get-NamedArgumentText -CommandAst $probes[0] -ParameterName 'Port') -eq '80') 'the probe targets the daemon port :80'
        Assert-True ((Get-CommandCall -Ast $ast -Name 'Get-DownloadAgentServiceReadyTimeoutSeconds').Count -ge 1) 'the budget comes from the overridable resolver, not a bare literal'
    }

    It 'discriminates "still building" from "serving but unreachable" by asking the guest' {
        $ast = Get-ScriptAst $startAgent
        $sshCalls = @(Get-CommandCall -Ast $ast -Name 'Invoke-GuestSsh')
        Assert-True ($sshCalls.Count -ge 2) "the guest is asked both during the wait and for the failure diagnostics; found $($sshCalls.Count)"
        $listenerProbe = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -match 'ss -ltn' })
        Assert-True ($listenerProbe.Count -ge 1) 'an in-guest `ss -ltn` listener probe literal is present'
        $timeoutHint = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -match 'YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS' })
        Assert-True ($timeoutHint.Count -ge 1) 'the failure guidance names the readiness-timeout override the operator can raise'
    }

    It 'binds the marker''s active to the readiness verdict, which starts false' {
        $ast = Get-ScriptAst $startAgent
        $markerWrites = @(Get-CommandCall -Ast $ast -Name 'Write-DownloadAgentServiceMarker')
        Assert-True ($markerWrites.Count -ge 1) 'the marker is written through the module helper'
        $active = Get-NamedArgumentText -CommandAst $markerWrites[0] -ParameterName 'Active'
        Assert-True ($active -eq '$daemonReady') "-Active must carry the readiness verdict variable, got '$active'"
        $verdictAssignments = @(Get-AssignmentTo -Ast $ast -VariableText '$daemonReady')
        Assert-True ($verdictAssignments.Count -ge 2) 'the verdict is initialized and then set by the probe'
        Assert-True ((@($verdictAssignments | ForEach-Object { $_.Right.Extent.Text })) -contains '$false') 'the verdict starts $false, so every path that never probed publishes inactive'
        $insideLoop = @(Get-WhileStatement -Ast $ast |
            ForEach-Object { Get-AssignmentTo -Ast $_ -VariableText '$daemonReady' } |
            Where-Object { $_.Right.Extent.Text -eq '$true' })
        Assert-True ($insideLoop.Count -ge 1) 'only the probe loop can set the verdict $true'
    }

    It 'publishes the Shared-NAT-aware address and refreshes the registration' {
        $ast = Get-ScriptAst $startAgent
        $resolves = @(Get-CommandCall -Ast $ast -Name 'Resolve-DownloadAgentServiceBaseUrl')
        Assert-True ($resolves.Count -ge 1) 'the published address goes through the Shared-NAT-aware resolver'
        Assert-True ((Get-NamedArgumentText -CommandAst $resolves[0] -ParameterName 'NetworkMode') -eq '$bundleMode') 'the resolver is told the bundle''s real network mode'
        $markerWrites = @(Get-CommandCall -Ast $ast -Name 'Write-DownloadAgentServiceMarker')
        Assert-True ((Get-NamedArgumentText -CommandAst $markerWrites[0] -ParameterName 'BaseUrl') -eq '$downloadAgentServiceBaseUrl') 'the resolved URL is what the marker publishes'
        Assert-True ((Get-CommandCall -Ast $ast -Name 'Write-HostRegistrationRecord').Count -ge 1) 'the registration is refreshed so the aggregator sees the marker within one poll'

        # The forward has to be installed before the address that names it is
        # published, and 8082 specifically: 80, 2222, and 8081 are already taken
        # on a shared-services Mac.
        $portMaps = @(Get-CommandCall -Ast $ast -Name 'Add-PortMap')
        Assert-True ($portMaps.Count -ge 1) 'the Shared-NAT host port is forwarded'
        $remap = Get-NamedArgumentText -CommandAst $portMaps[0] -ParameterName 'PortRemap'
        Assert-True ($remap -match '8082\s*=\s*80') "the forward maps host 8082 to guest 80, got '$remap'"
        Assert-True ((Get-FirstCallOffset -Ast $ast -Name 'Add-PortMap') -lt (Get-FirstCallOffset -Ast $ast -Name 'Write-DownloadAgentServiceMarker')) 'the forward is installed before the URL naming it is published'
    }

    It 'gates the build on the pool-storage credential before anything is created' {
        $ast = Get-ScriptAst $startAgent
        $storageGate = Get-FirstCallOffset -Ast $ast -Name 'Test-PoolStorageStoredCredential'
        Assert-True ($storageGate -ge 0) 'the stored-credential hard gate is present'
        Assert-True ((Get-CommandCall -Ast $ast -Name 'Connect-YurunaPoolStorage').Count -ge 1) 'the soft gate verifies the credential actually authenticates'
        # The status service serves the framework archive the guest fetches at
        # first boot; one started after the build is one the guest never saw.
        $statusEnsure = Get-FirstCallOffset -Ast $ast -Name 'Start-YurunaStatusServiceIfEnabled'
        Assert-True ($statusEnsure -ge 0) 'the host status service is ensured'
        $newVmOffsets = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.CommandElements.Count -gt 0 -and
            $n.CommandElements[-1].Extent.Text -eq '$VMName' -and
            $n.Extent.Text -match '\$newVm'
        }, $true) | ForEach-Object { $_.Extent.StartOffset })
        Assert-True ($newVmOffsets.Count -ge 1) 'the per-host New-VM.ps1 is invoked with -VMName'
        $newVmOffset = (@($newVmOffsets) | Sort-Object)[0]
        Assert-True ($storageGate -lt $newVmOffset) 'the storage gate runs before the VM is built'
        Assert-True ($statusEnsure -lt $newVmOffset) 'the status service is up before the guest first boots'
        Assert-True ((Get-FirstCallOffset -Ast $ast -Name 'Wait-VMRunning') -gt $newVmOffset) 'the running gate follows the build'
    }
}

Describe 'Stop-DownloadAgentServiceVM.ps1 retracts the claim before it destroys the VM' {
    It 'removes the marker and republishes the registration ahead of every teardown call' {
        $ast = Get-ScriptAst $stopAgent
        $markerRemoval = Get-FirstCallOffset -Ast $ast -Name 'Remove-DownloadAgentServiceMarker'
        Assert-True ($markerRemoval -ge 0) 'the marker is removed through the module helper'
        $registration = Get-FirstCallOffset -Ast $ast -Name 'Write-HostRegistrationRecord'
        Assert-True ($registration -ge 0) 'the registration record is refreshed so the removal reaches the aggregator'
        Assert-True ($markerRemoval -lt $registration) 'the marker is gone before the registration that reads it is regenerated'
        foreach ($teardown in @('Stop-VM', 'Stop-VMForce', 'Remove-GuestVMQuietly')) {
            $offset = Get-FirstCallOffset -Ast $ast -Name $teardown
            Assert-True ($offset -ge 0) "the teardown calls $teardown"
            Assert-True ($markerRemoval -lt $offset) "the marker is cleared before $teardown runs"
            Assert-True ($registration -lt $offset) "the registration is refreshed before $teardown runs"
        }
    }
}

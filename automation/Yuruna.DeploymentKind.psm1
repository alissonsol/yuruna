<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42c7d8e9-f0a1-4b23-8456-7c8d9e0f1a23
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.DeploymentKind
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
    Single catalog of workload deployment kinds (chart | kubectl | helm |
    shell) shared by the validator (Confirm-WorkloadList) and the
    publisher (Publish-WorkloadList).

.DESCRIPTION
    A deployment "kind" is the YAML key under a workloads.yml deployment
    (chart, kubectl, helm, shell). The validator and the publisher both
    need the same knowledge -- the kind list, the at-least-one detection,
    the "should be ..."/"must be ..." error text, the tool-expression
    mapping, and the retry-gating boolean. Holding it in one catalog keeps
    their two views from diverging, so a new tool-expression kind
    (kustomize, flux, oc, ...) is a single Register-YurunaDeploymentKind
    line below and ZERO edits in the validator or publisher.

    Catalog entries are PLAIN DATA descriptors, never scriptblocks. A
    scriptblock registered here but invoked from the Workload/Validation
    module scope would lose name-resolution of those modules' private
    commands (the closure-invoked-in-a-foreign-module class:
    feedback_closure_foreign_module_command_resolution.md). So the heavy
    apply bodies (the chart helm-upgrade pipeline; the chart-specific
    validation) STAY in their owning modules and merely dispatch off the
    descriptor fields exported here.

    Descriptor fields (all plain data):
      Name          kind name + the workloads.yml key (chart/kubectl/...).
      Field         the deployment hashtable key probed for presence
                    (same as Name today; kept distinct so a kind whose
                    display name differs from its YAML key stays possible).
      IsChart       $true only for the bespoke helm-chart pipeline, which
                    needs its own apply/validate branch (folder copy,
                    values.yaml, lint, pending-* recovery). A pure
                    tool-expression kind is $false and needs no branch.
      ToolName      label for the <tool>.stderr.log / <tool>.rc sidecar.
      CommandPrefix prepended (verbatim, including any trailing space) to
                    the deployment value to build the shell expression;
                    '' means run the value as-is (shell).
      Retryable     $true to let the shared transient-fetch retry wrap
                    this kind's command; $false fails fast.

    Detection is "a deployment IS kind K when K's Field is present and
    non-empty". When more than one is present, Resolve picks chart if
    present, else the LAST present non-chart kind in registration order
    -- the publisher's sequential (non-elseif) if-chain has last-write
    semantics, and registration order here is the catalog's source of
    truth for that precedence.

    Extension point: add one Register-YurunaDeploymentKind line in the
    built-in block. A pure tool-expression kind (a CommandPrefix + a
    ToolName) needs nothing else. A kind that needs bespoke apply logic
    like chart still needs IsChart=$true plus its own branch in the
    publisher/validator -- unavoidable, because that logic (chart folder
    copy, values.yaml render, helm lint, pending-* rollback) cannot be
    expressed as "prefix + value".
#>

# Eviction-safe catalog anchor. A defensive -Force re-import of this
# module from any consumer must NOT wipe the registered kinds, and the
# init must be idempotent so re-running module load does not clear a
# live catalog (the $script:foo=@{} reset-on-reimport class:
# feedback_module_script_state_reset_by_force_reimport.md). An ordered
# dictionary preserves registration order, which IS the precedence and
# the order the expected-text phrase is built in.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe catalog anchor; the only reliable way to keep registered kinds across -Force re-imports.')]
param()

if (-not (Get-Variable -Name '__YurunaDeploymentKindCatalog' -Scope Global -ErrorAction SilentlyContinue)) {
    Set-Variable -Name '__YurunaDeploymentKindCatalog' -Scope Global -Value ([ordered]@{})
}

function Register-YurunaDeploymentKind {
    <#
    .SYNOPSIS
        Register (or replace) one deployment-kind descriptor in the catalog.
    .DESCRIPTION
        Plain-data registration only: stores a descriptor hashtable keyed
        by Name. Re-registering the same Name replaces the descriptor and
        preserves its original position (last writer wins, position
        stable) so a -Force re-import re-running the built-in block does
        not reorder the precedence. Returns nothing.
    .PARAMETER Name
        Kind name and the workloads.yml deployment key (chart/kubectl/...).
    .PARAMETER Field
        Deployment-hashtable key probed for presence. Defaults to Name.
    .PARAMETER IsChart
        $true for the bespoke chart pipeline; $false for a pure
        tool-expression kind.
    .PARAMETER ToolName
        Label for the <tool>.stderr.log / <tool>.rc capture sidecar.
    .PARAMETER CommandPrefix
        Verbatim prefix (keep any trailing space) for the shell
        expression; '' runs the value unprefixed.
    .PARAMETER Retryable
        $true to allow the shared transient-fetch retry to wrap the
        command; $false to fail fast.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates only the in-process catalog dictionary; no external/system state changes.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Writes the eviction-safe catalog anchor created at module load.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Field,
        [bool]$IsChart = $false,
        [string]$ToolName,
        [string]$CommandPrefix = '',
        [bool]$Retryable = $false
    )
    if ([string]::IsNullOrEmpty($Field)) { $Field = $Name }
    if ([string]::IsNullOrEmpty($ToolName)) { $ToolName = $Name }
    $global:__YurunaDeploymentKindCatalog[$Name] = @{
        Name          = $Name
        Field         = $Field
        IsChart       = $IsChart
        ToolName      = $ToolName
        CommandPrefix = $CommandPrefix
        Retryable     = $Retryable
    }
}

function Get-YurunaDeploymentKindList {
    <#
    .SYNOPSIS
        Every registered deployment-kind descriptor, in registration order.
    .DESCRIPTION
        Registration order is the precedence order and the order the
        expected-text phrase is built in. The returned descriptors are the
        live catalog hashtables (plain data); callers read fields off them.
    .OUTPUTS
        [hashtable[]] descriptors (Name, Field, IsChart, ToolName,
        CommandPrefix, Retryable).
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the catalog anchor created at module load.')]
    param()
    # Two-step build: a typed-array cast over an empty/loop result can
    # collapse to $null (the typed-array-cast-if-empty class:
    # feedback_pwsh_typed_array_cast_if_empty_null.md), so initialise then
    # append.
    $list = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($key in $global:__YurunaDeploymentKindCatalog.Keys) {
        $list.Add($global:__YurunaDeploymentKindCatalog[$key])
    }
    return $list.ToArray()
}

function Get-YurunaDeploymentKind {
    <#
    .SYNOPSIS
        One registered descriptor by Name, or $null if not registered.
    .OUTPUTS
        [hashtable] descriptor, or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the catalog anchor created at module load.')]
    param([Parameter(Mandatory)][string]$Name)
    if ($global:__YurunaDeploymentKindCatalog.Contains($Name)) {
        return $global:__YurunaDeploymentKindCatalog[$Name]
    }
    return $null
}

function Get-YurunaDeploymentKindExpectedText {
    <#
    .SYNOPSIS
        The catalog-generated kinds phrase, e.g. "'chart', 'kubectl',
        'helm' or 'shell'".
    .DESCRIPTION
        Single-quotes each kind name, joins all but the last with ", ",
        and separates the last with " or ". The validator and publisher
        embed this verbatim in their "context.deployment should be ... in
        file: <f>" / "context.deployment must be ... in <f>" messages so
        the kinds list in the message can never drift from the catalog.
        With zero kinds returns ''; with one kind returns just "'<name>'".
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $names = @(Get-YurunaDeploymentKindList | ForEach-Object { "'$($_.Name)'" })
    if ($names.Count -eq 0) { return '' }
    if ($names.Count -eq 1) { return $names[0] }
    $head = $names[0..($names.Count - 2)] -join ', '
    return "$head or $($names[-1])"
}

function Resolve-YurunaDeploymentKind {
    <#
    .SYNOPSIS
        Pick the effective deployment-kind descriptor for a deployment
        hashtable, or $null when none apply.
    .DESCRIPTION
        A kind applies when its Field is present and non-empty on the
        deployment. Reproduces the publisher's branch precedence exactly:
        chart wins if present; otherwise the LAST present non-chart kind
        in registration order wins (the publisher's sequential, non-elseif
        if-chain has last-write semantics). Real configs carry exactly one
        key, but the theoretical precedence is preserved.
    .PARAMETER Deployment
        The per-deployment hashtable from workloads.yml.
    .OUTPUTS
        [hashtable] descriptor, or $null when no kind is present.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowNull()]$Deployment)
    if ($null -eq $Deployment) { return $null }
    $effective = $null
    foreach ($kind in (Get-YurunaDeploymentKindList)) {
        $present = -not [string]::IsNullOrEmpty($Deployment[$kind.Field])
        if (-not $present) { continue }
        if ($kind.IsChart) { return $kind }
        # Non-chart: last present wins, matching the sequential if-chain.
        $effective = $kind
    }
    return $effective
}

# Built-in kinds. Registration order IS the precedence order and the
# order the expected-text phrase is built in: chart first (its own
# pipeline), then kubectl, helm, shell. Adding a pure tool-expression
# kind is exactly one line here. kubectl/helm prepend their tool name +
# a space to the value; shell runs the value verbatim ('' prefix).
# kubectl/helm cross the network so they opt into the transient-fetch
# retry; shell does not. chart never reaches the tool-expression branch
# (IsChart routes it to the bespoke helm pipeline) so its CommandPrefix
# is irrelevant and Retryable is $false.
Register-YurunaDeploymentKind -Name 'chart'   -IsChart $true  -ToolName 'helm'    -CommandPrefix ''         -Retryable $false
Register-YurunaDeploymentKind -Name 'kubectl' -IsChart $false -ToolName 'kubectl' -CommandPrefix 'kubectl ' -Retryable $true
Register-YurunaDeploymentKind -Name 'helm'    -IsChart $false -ToolName 'helm'    -CommandPrefix 'helm '    -Retryable $true
Register-YurunaDeploymentKind -Name 'shell'   -IsChart $false -ToolName 'shell'   -CommandPrefix ''         -Retryable $false

Export-ModuleMember -Function Register-YurunaDeploymentKind, Get-YurunaDeploymentKindList, Get-YurunaDeploymentKind, Get-YurunaDeploymentKindExpectedText, Resolve-YurunaDeploymentKind

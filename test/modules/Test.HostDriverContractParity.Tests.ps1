<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42e5a9c3-7b16-4f02-a8d4-9c3b1e6f5a27
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host driver contract parity ast pester
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
    Every host-contract verb is defined, exported and declared exactly once in
    each of the three host drivers, and the virtualization repair verbs carry
    the same parameters everywhere.
.DESCRIPTION
    The three host/<family>/modules/Yuruna.Host.psm1 drivers are near-identical
    siblings, and an edit that reaches two of them passes every suite that runs
    on the host doing the editing: the third driver only fails when it is
    imported on its own platform, as a missing-verb warning, and a host-neutral
    caller then stops at command-not-found there
    (feedback_host-family-triples-drop-out-of-sweeps.md). This suite reads all
    three drivers through the PowerShell AST -- no driver is imported, so it
    runs identically on every host -- and holds each one to the verb list the
    contract module itself returns.
#>

# Static per-family cases, computed at discovery time because -ForEach reads
# them then; BeforeAll rebuilds the same list for the run pass, which does not
# reliably see discovery-time variables.
$parityDiscoveryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$parityDriverCases = @(
    @{ Driver = 'macos.utm';       Path = (Join-Path $parityDiscoveryRoot 'host/macos.utm/modules/Yuruna.Host.psm1') }
    @{ Driver = 'ubuntu.kvm';      Path = (Join-Path $parityDiscoveryRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') }
    @{ Driver = 'windows.hyper-v'; Path = (Join-Path $parityDiscoveryRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1') }
)

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $repoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $repoRoot 'host/Yuruna.Host.Contract.psm1') -Force -Global -DisableNameChecking
    # The contract returns its list as one array object; assign rather than
    # wrap it in @() so it is not nested.
    [string[]]$script:ContractVerb = Get-YurunaHostContractVerb
    $script:DriverCaseList = foreach ($family in 'macos.utm', 'ubuntu.kvm', 'windows.hyper-v') {
        @{ Driver = $family; Path = (Join-Path $repoRoot "host/$family/modules/Yuruna.Host.psm1") }
    }

    function Get-CommandArgumentName {
        <#
        .SYNOPSIS
            Every string constant inside the argument bound to -ParameterName
            of each call to CommandName in the AST.
        #>
        param($Ast, [string]$CommandName, [string]$ParameterName)
        $calls = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($call in $calls) {
            if ($call.GetCommandName() -ne $CommandName) { continue }
            $elements = $call.CommandElements
            for ($i = 0; $i -lt $elements.Count; $i++) {
                $element = $elements[$i]
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or $element.ParameterName -ne $ParameterName) { continue }
                $argument = if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
                if (-not $argument) { continue }
                foreach ($constant in $argument.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                    [string]$constant.Value
                }
            }
        }
    }

    function Get-DriverSurface {
        <#
        .SYNOPSIS
            Top-level function definitions, Export-ModuleMember -Function names
            and the Assert-YurunaHostContractCoverage declaration of one driver.
        #>
        param([string]$Path)
        $ast = Get-YurunaTestFileAst -Path $Path
        $top = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
        return [pscustomobject]@{
            Defined   = [string[]]@($top | ForEach-Object { $_.Name })
            Functions = $top
            Exported  = [string[]]@(Get-CommandArgumentName -Ast $ast -CommandName 'Export-ModuleMember' -ParameterName 'Function')
            Declared  = [string[]]@(Get-CommandArgumentName -Ast $ast -CommandName 'Assert-YurunaHostContractCoverage' -ParameterName 'ExportedFunction')
        }
    }

    function Get-ParameterAst {
        <#
        .SYNOPSIS
            The named parameter of a function definition, or $null.
        #>
        param($FunctionAst, [string]$Name)
        if (-not $FunctionAst.Body.ParamBlock) { return $null }
        return @($FunctionAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }) | Select-Object -First 1
    }

    function Get-ValidateRange {
        <#
        .SYNOPSIS
            The ValidateRange bounds on a parameter as 'min,max', or ''.
        #>
        param($ParameterAst)
        $range = @($ParameterAst.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'ValidateRange'
            }) | Select-Object -First 1
        if (-not $range) { return '' }
        return (@($range.PositionalArguments | ForEach-Object { $_.Extent.Text }) -join ',')
    }

    function Get-CmdletBindingArgument {
        <#
        .SYNOPSIS
            The named arguments of a function's [CmdletBinding()] as a
            hashtable of name -> extent text ('$true' when the value is omitted),
            or $null when the attribute is absent.
        #>
        param($FunctionAst)
        if (-not $FunctionAst.Body.ParamBlock) { return $null }
        $binding = @($FunctionAst.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }) | Select-Object -First 1
        if (-not $binding) { return $null }
        $named = @{}
        foreach ($argument in $binding.NamedArguments) {
            $named[$argument.ArgumentName] = if ($argument.ExpressionOmitted) { '$true' } else { $argument.Argument.Extent.Text }
        }
        return $named
    }

    function Test-HasOutputType {
        <#
        .SYNOPSIS
            $true when the function's param block carries an [OutputType()].
        #>
        param($FunctionAst)
        if (-not $FunctionAst.Body.ParamBlock) { return $false }
        return [bool](@($FunctionAst.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'OutputType' }).Count)
    }
}

Describe 'Host driver contract parity' {
    It 'lists both virtualization repair verbs in the contract' {
        $script:ContractVerb | Should -Contain 'Test-VirtualizationResponsive'
        $script:ContractVerb | Should -Contain 'Start-VirtualizationServiceIfStopped'
        @($script:ContractVerb | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0 -Because 'a verb listed twice would hide a missing one in a count'
    }

    It 'defines, exports and declares every contract verb exactly once in <Driver>' -ForEach $parityDriverCases {
        $surface = Get-DriverSurface -Path $Path
        $findings = foreach ($verb in $script:ContractVerb) {
            $defined  = @($surface.Defined | Where-Object { $_ -eq $verb }).Count
            $exported = @($surface.Exported | Where-Object { $_ -eq $verb }).Count
            $declared = @($surface.Declared | Where-Object { $_ -eq $verb }).Count
            if ($defined -ne 1) { "${Driver}: $verb is defined $defined times at the top level" }
            if ($exported -ne 1) { "${Driver}: $verb appears $exported times in Export-ModuleMember -Function" }
            if ($declared -ne 1) { "${Driver}: $verb appears $declared times in the Assert-YurunaHostContractCoverage declaration" }
        }
        Assert-NoFinding $findings "$Driver does not carry the contract surface"
    }

    It 'gives the three drivers equal per-family contract counts' {
        $counts = foreach ($case in $script:DriverCaseList) {
            $surface = Get-DriverSurface -Path $case.Path
            [pscustomobject]@{
                Driver   = $case.Driver
                Defined  = @($script:ContractVerb | Where-Object { $surface.Defined -contains $_ }).Count
                Exported = @($script:ContractVerb | Where-Object { $surface.Exported -contains $_ }).Count
                Declared = @($script:ContractVerb | Where-Object { $surface.Declared -contains $_ }).Count
            }
        }
        $findings = foreach ($row in $counts) {
            foreach ($kind in 'Defined', 'Exported', 'Declared') {
                if ($row.$kind -ne $script:ContractVerb.Count) {
                    "$($row.Driver): $kind $($row.$kind) of $($script:ContractVerb.Count) contract verbs"
                }
            }
        }
        Assert-NoFinding $findings 'the three drivers must carry the same contract surface'
    }

    It 'declares the bounded read-only probe signature in <Driver>' -ForEach $parityDriverCases {
        $surface = Get-DriverSurface -Path $Path
        $fn = @($surface.Functions | Where-Object { $_.Name -eq 'Test-VirtualizationResponsive' }) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because "$Driver must define the probe"
        $binding = Get-CmdletBindingArgument -FunctionAst $fn
        ($null -eq $binding) | Should -BeFalse -Because 'the probe needs [CmdletBinding()]'
        $binding.ContainsKey('SupportsShouldProcess') | Should -BeFalse -Because 'the probe is read-only'
        Test-HasOutputType -FunctionAst $fn | Should -BeTrue
        $timeout = Get-ParameterAst -FunctionAst $fn -Name 'TimeoutSeconds'
        $timeout | Should -Not -BeNullOrEmpty
        Get-ValidateRange -ParameterAst $timeout | Should -Be '1,600'
        $timeout.DefaultValue.Extent.Text | Should -Be '20'
        Get-ParameterAst -FunctionAst $fn -Name 'Deadline' | Should -Not -BeNullOrEmpty
    }

    It 'declares the rung-2 start signature with ShouldProcess in <Driver>' -ForEach $parityDriverCases {
        $surface = Get-DriverSurface -Path $Path
        $fn = @($surface.Functions | Where-Object { $_.Name -eq 'Start-VirtualizationServiceIfStopped' }) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because "$Driver must define the rung-2 verb"
        $binding = Get-CmdletBindingArgument -FunctionAst $fn
        ($null -eq $binding) | Should -BeFalse -Because 'the rung-2 verb needs [CmdletBinding()]'
        $binding.ContainsKey('SupportsShouldProcess') | Should -BeTrue
        $binding['SupportsShouldProcess'] | Should -Not -Be '$false'
        if ($binding.ContainsKey('ConfirmImpact')) {
            $binding['ConfirmImpact'] | Should -Not -Match 'High' -Because 'a repair path must never raise a confirmation prompt'
        }
        Test-HasOutputType -FunctionAst $fn | Should -BeTrue
        $timeout = Get-ParameterAst -FunctionAst $fn -Name 'TimeoutSeconds'
        $timeout | Should -Not -BeNullOrEmpty
        Get-ValidateRange -ParameterAst $timeout | Should -Be '1,600'
        $timeout.DefaultValue.Extent.Text | Should -Be '120'
        Get-ParameterAst -FunctionAst $fn -Name 'Deadline' | Should -Not -BeNullOrEmpty
        $dependent = Get-ParameterAst -FunctionAst $fn -Name 'DependentVMName'
        $dependent | Should -Not -BeNullOrEmpty
        $dependent.StaticType | Should -Be ([string[]])
    }
}

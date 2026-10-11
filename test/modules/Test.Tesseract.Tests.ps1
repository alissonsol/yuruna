<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42f2943e-7155-4ed8-aedb-db7d6166f795
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test tesseract ocr pester
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
    Tesseract process isolation, recognition output and executable discovery.
.DESCRIPTION
    Native fixtures exercise literal arguments, Unicode output and failures
    without needing an installed OCR engine. Mocks cover child-only OpenMP
    overrides and incomplete stream captures on every host platform.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Tesseract.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FunctionName)
    $func = Get-YurunaTestFunctionAst -Path $Path -Name $FunctionName
    if (-not $func) { throw "Function '$FunctionName' not found in $Path" }
    return $func
}

function Get-OcrDispatchCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$FuncAst)
    $calls = $FuncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-TesseractNative'
    }, $true)
    return @($calls).Count
}

# True iff the function assigns $VarName AND references it inside a throw, i.e.
# the thrown failure message carries that variable's content (here: partitioned
# stderr), not merely a bare exit code.
function Test-FunctionAssignsAndThrowsVar {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Checking that '$VarName' is assigned and referenced in a throw"
    $assigned = $FuncAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $VarName
    }, $true)
    if (@($assigned).Count -eq 0) { return $false }
    $throws = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)
    foreach ($t in $throws) {
        $ref = $t.FindAll({
            param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $VarName
        }, $true)
        if (@($ref).Count -gt 0) { return $true }
    }
    return $false
}

# Returns the body (StatementBlockAst) of the first if-branch whose condition
# references $VarName, or $null. Proves a real branch exists, distinct from a
# comment that names the variable.
function Get-IfBranchBodyOnVar {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Searching for an if-branch conditioned on '$VarName'"
    $ifs = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
    foreach ($if in $ifs) {
        foreach ($clause in $if.Clauses) {
            $cond = $clause.Item1
            $hit = $cond.FindAll({
                param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $VarName
            }, $true)
            if (@($hit).Count -gt 0) { return $clause.Item2 }
        }
    }
    return $null
}

# True iff the AST subtree contains a string constant equal to $Value.
function Test-AstContainsStringConstant {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Value)
    Write-Verbose "Searching AST for string constant '$Value'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq $Value
    }, $true)
    return (@($hits).Count -gt 0)
}

# The parsed function ASTs are built at file scope, above the first Describe. A
# Describe body is evaluated during the discovery pass and its scope is torn
# down before any It runs, so an AST captured inside one arrives at the
# assertions as $null; only file-level declarations that precede the first
# Describe are still in scope during the run pass.
$script:invokeAst  = Get-FunctionAst -Path $modulePath -FunctionName 'Invoke-TesseractOcr'
$script:wordboxAst = Get-FunctionAst -Path $modulePath -FunctionName 'Get-TesseractWordBox'
$script:findAst    = Get-FunctionAst -Path $modulePath -FunctionName 'Find-Tesseract'

}

Describe 'Test.Tesseract OCR invocations are single-pass and diagnosable' {

    It 'Invoke-TesseractOcr invokes tesseract exactly once (no stderr re-run)' {
        Assert-Equal -Expected 1 -Actual (Get-OcrDispatchCount -FuncAst $script:invokeAst) -Because `
            'a second invocation to capture stderr can diverge from the first and doubles the process spawn.'
    }
    It 'Get-TesseractWordBox invokes tesseract exactly once' {
        Assert-Equal -Expected 1 -Actual (Get-OcrDispatchCount -FuncAst $script:wordboxAst) -Because `
            'the TSV path must not re-run tesseract to fetch stderr.'
    }
    It 'Invoke-TesseractOcr surfaces tesseract stderr in the thrown message' {
        Assert-True (Test-FunctionAssignsAndThrowsVar -FuncAst $script:invokeAst -VarName 'errMsg') -Because `
            'a failure must carry tesseract stderr, not just an exit code.'
    }
    It 'Get-TesseractWordBox surfaces tesseract stderr in the thrown message' {
        Assert-True (Test-FunctionAssignsAndThrowsVar -FuncAst $script:wordboxAst -VarName 'errMsg') -Because `
            'the bare exit-code throw is not diagnosable; the partitioned stderr must be included.'
    }
}

Describe 'Find-Tesseract has a real Linux filesystem-fallback branch' {

    It 'branches on $IsLinux (a real if-branch, not a comment mention)' {
        Assert-True ($null -ne (Get-IfBranchBodyOnVar -FuncAst $script:findAst -VarName 'IsLinux')) -Because `
            'Linux needs a filesystem fallback for parity with the Windows/macOS branches.'
    }
    It 'probes /usr/bin/tesseract inside the $IsLinux branch' {
        $body = Get-IfBranchBodyOnVar -FuncAst $script:findAst -VarName 'IsLinux'
        Assert-True ($null -ne $body -and (Test-AstContainsStringConstant -Ast $body -Value '/usr/bin/tesseract')) -Because `
            'the Linux branch must probe the standard package install path.'
    }
}

Describe 'the function lookup behind these guards' {
    It 'throws for a function the module does not define' {
        # A guard reads what the lookup hands it. Were an absent function to come
        # back as nothing, a guard asserting that something is NOT in it would
        # pass against nothing.
        Assert-Throw { Get-FunctionAst -Path $modulePath -FunctionName 'Get-FunctionThatIsNotDefined' } 'not found' `
            'an absent function must stop the test that asked for it'
    }
}

Describe 'Tesseract child environment and complete capture' {
    BeforeAll {
        Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
        Import-Module $modulePath -Global -Force -DisableNameChecking
        function Invoke-OcrFixture {
            param([string]$FilePath, [string]$ImagePath, [switch]$WordBoxes)
            & (Get-Module Test.Tesseract) { param($Parameters) Invoke-TesseractNative @Parameters } $PSBoundParameters
        }
    }
        BeforeEach {
            $script:SavedOmpLimit = [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT')
            $script:SavedOmpThreads = [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS')
            Remove-Item Env:OMP_THREAD_LIMIT, Env:OMP_NUM_THREADS -ErrorAction SilentlyContinue
            $script:Probe = @{ Started = $true; ExitCode = 0; StdOut = "hello`r`nworld`r`n`r`n"; StdErr = "warning`n"
                TimedOut = $false; DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; StartError = '' }
            Mock Invoke-BoundedNativeCommand -ModuleName Test.Tesseract {
                $script:CapturedArguments = @($ArgumentList)
                $script:CapturedEnvironment = $Environment.Clone()
                $script:CapturedTimeout = $TimeoutSeconds
                $script:CapturedEncoding = $StreamEncoding
                return $script:Probe
            }
        }
        AfterEach {
            if ($null -eq $script:SavedOmpLimit) { Remove-Item Env:OMP_THREAD_LIMIT -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable('OMP_THREAD_LIMIT', $script:SavedOmpLimit) }
            if ($null -eq $script:SavedOmpThreads) { Remove-Item Env:OMP_NUM_THREADS -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable('OMP_NUM_THREADS', $script:SavedOmpThreads) }
        }
        It 'defaults to two threads in the child only and retains the generous timeout' {
            $result = Invoke-OcrFixture -FilePath 'tesseract' -ImagePath 'literal image.png'
            $script:CapturedEnvironment.OMP_THREAD_LIMIT | Should -BeExactly '2'
            [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT') | Should -BeNullOrEmpty
            [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS') | Should -BeNullOrEmpty
            $script:CapturedTimeout | Should -Be 300
            $script:CapturedEncoding.WebName | Should -Be ([Console]::OutputEncoding.WebName)
            $result.StdOut | Should -BeExactly "hello`nworld`n"
            $result.StdErr | Should -BeExactly 'warning'
            Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Tesseract -Times 1 -Exactly
        }
        It 'honors explicit <Limit>/<Threads> without a child override' -ForEach @(
            @{ Limit = '1'; Threads = $null }, @{ Limit = $null; Threads = '3' }, @{ Limit = '8'; Threads = '4' },
            @{ Limit = ''; Threads = $null }, @{ Limit = $null; Threads = '' }
        ) {
            if ($null -ne $Limit) { [Environment]::SetEnvironmentVariable('OMP_THREAD_LIMIT', $Limit) }
            if ($null -ne $Threads) { [Environment]::SetEnvironmentVariable('OMP_NUM_THREADS', $Threads) }
            # Older .NET releases delete empty values; preserve whatever the
            # platform can actually inherit rather than assuming .NET 9.
            $inheritedLimit = [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT')
            $inheritedThreads = [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS')
            $null = Invoke-OcrFixture -FilePath 'tesseract' -ImagePath 'image.png'
            $expectedOverrides = if ($null -ne $inheritedLimit -or $null -ne $inheritedThreads) { 0 } else { 1 }
            $script:CapturedEnvironment.Count | Should -Be $expectedOverrides
            [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT') | Should -Be $inheritedLimit
            [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS') | Should -Be $inheritedThreads
        }
        It 'passes literal image arguments and requests TSV exactly once' {
            $null = Invoke-OcrFixture -FilePath 'tesseract' -ImagePath "image [1]; `u{fc}.png" -WordBoxes
            ($script:CapturedArguments -join '|') | Should -BeExactly "image [1]; `u{fc}.png|stdout|--psm|6|tsv"
            Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Tesseract -Times 1 -Exactly
        }
        It 'rejects incomplete captures flagged <Field>' -ForEach @(
            @{ Field = 'TimedOut' }, @{ Field = 'DrainTimedOut' }, @{ Field = 'KillFailed' }, @{ Field = 'OutputTruncated' }
        ) {
            $script:Probe[$Field] = $true
            $result = Invoke-OcrFixture -FilePath 'tesseract' -ImagePath 'image.png'
            $result.ExitCode | Should -Be -1
            $result.StdErr | Should -Match "$Field=True"
        }
        It 'rejects a process that did not start and retains its start error' {
            $script:Probe.Started = $false
            $script:Probe.StartError = 'launch denied'
            $result = Invoke-OcrFixture -FilePath 'tesseract' -ImagePath 'image.png'
            $result.ExitCode | Should -Be -1
            $result.StdErr | Should -Match 'launch denied'
        }
        It 'does not accept missing completeness flags as a complete answer' {
            $script:Probe.Remove('DrainTimedOut')
            (Invoke-OcrFixture -FilePath 'tesseract' -ImagePath 'image.png').ExitCode | Should -Be -1
        }
}

Describe 'Tesseract actual native child compatibility' {
    BeforeAll {
        Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
        Import-Module $modulePath -Global -Force -DisableNameChecking
        $script:NativeFixture = Join-Path $TestDrive "OCR `u{fc} [1]; child.ps1"
        @'
if ($args.Count -ne 3 -and $args.Count -ne 4) { exit 17 }
if ($args[0] -ne 'stdout' -or $args[1] -ne '--psm' -or $args[2] -ne '6') { exit 18 }
[Console]::Error.WriteLine("diagnostic `u{fc} stderr")
if ($env:YURUNA_OCR_FIXTURE_ENV -eq 'yes') {
    [Console]::Out.Write([Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT') + '|' + [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS'))
    exit 0
}
if ($env:YURUNA_OCR_FIXTURE_FAIL -eq 'yes') { exit 9 }
if ($args.Count -eq 4) {
    if ($args[3] -ne 'tsv') { exit 19 }
    [Console]::Out.Write("level`tpage_num`tblock_num`tpar_num`tline_num`tword_num`tleft`ttop`twidth`theight`tconf`ttext`r`n")
    [Console]::Out.Write("5`t1`t1`t1`t1`t1`t13`t17`t23`t29`t95`tCaf`u{e9}`r`n")
} else {
    [Console]::Out.Write("Caf`u{e9}`t`u{6771}`u{4eac}`r`nsecond line`r`n`r`n")
}
'@ | Set-Content -LiteralPath $script:NativeFixture -Encoding utf8
        $script:NativePwsh = (Get-Process -Id $PID).Path
        Mock Find-Tesseract -ModuleName Test.Tesseract { $script:NativePwsh }
    }
    BeforeEach {
        $script:OriginalFixtureFail = [Environment]::GetEnvironmentVariable('YURUNA_OCR_FIXTURE_FAIL')
        $script:OriginalFixtureEnv = [Environment]::GetEnvironmentVariable('YURUNA_OCR_FIXTURE_ENV')
        $script:OriginalLimit = [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT')
        $script:OriginalThreads = [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS')
        Remove-Item Env:YURUNA_OCR_FIXTURE_FAIL, Env:YURUNA_OCR_FIXTURE_ENV -ErrorAction SilentlyContinue
    }
    AfterEach {
        foreach ($entry in @(
            @{ Name = 'YURUNA_OCR_FIXTURE_FAIL'; Value = $script:OriginalFixtureFail },
            @{ Name = 'YURUNA_OCR_FIXTURE_ENV'; Value = $script:OriginalFixtureEnv },
            @{ Name = 'OMP_THREAD_LIMIT'; Value = $script:OriginalLimit },
            @{ Name = 'OMP_NUM_THREADS'; Value = $script:OriginalThreads }
        )) {
            if ($null -eq $entry.Value) { Remove-Item -LiteralPath ('Env:' + $entry.Name) -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($entry.Name, $entry.Value) }
        }
    }
    It 'applies the default only inside the actual native child' {
        Remove-Item Env:OMP_THREAD_LIMIT, Env:OMP_NUM_THREADS -ErrorAction SilentlyContinue
        $env:YURUNA_OCR_FIXTURE_ENV = 'yes'
        Invoke-TesseractOcr -ImagePath $script:NativeFixture | Should -BeExactly '2|'
        [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT') | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS') | Should -BeNullOrEmpty
    }
    It 'inherits an explicit thread setting in the actual native child' {
        Remove-Item Env:OMP_THREAD_LIMIT -ErrorAction SilentlyContinue
        $env:OMP_NUM_THREADS = '7'
        $env:YURUNA_OCR_FIXTURE_ENV = 'yes'
        Invoke-TesseractOcr -ImagePath $script:NativeFixture | Should -BeExactly '|7'
        [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT') | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS') | Should -BeExactly '7'
    }
    It 'preserves Unicode, line endings and literal Windows/macOS/Linux path characters' {
        Invoke-TesseractOcr -ImagePath $script:NativeFixture | Should -BeExactly "Caf`u{e9}`t`u{6771}`u{4eac}`nsecond line`n"
    }
    It 'parses actual child TSV word coordinates and excludes stderr chatter' {
        $boxes = Get-TesseractWordBox -ImagePath $script:NativeFixture
        $boxes.Count | Should -Be 1
        $boxes[0].text | Should -BeExactly "Caf`u{e9}"
        $boxes[0].x | Should -Be 13
        $boxes[0].y | Should -Be 17
        $boxes[0].w | Should -Be 23
        $boxes[0].h | Should -Be 29
        $boxes[0].conf | Should -Be 95
    }
    It 'retains native stderr and exit code with EAP Stop in <Function>' -ForEach @(
        @{ Function = 'Invoke-TesseractOcr' }, @{ Function = 'Get-TesseractWordBox' }
    ) {
        [Environment]::SetEnvironmentVariable('YURUNA_OCR_FIXTURE_FAIL', 'yes')
        $ErrorActionPreference = 'Stop'
        $PSNativeCommandUseErrorActionPreference = $true
        { & $Function -ImagePath $script:NativeFixture } | Should -Throw "*9*diagnostic `u{fc} stderr*"
    }
}

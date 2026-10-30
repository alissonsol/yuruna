<#PSScriptInfo
.VERSION 2026.10.30
.GUID 4264d5c7-e082-4c67-a5f9-915f2f84141e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cachingproxy deadline lastexitcode pester
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
    Structural (AST) guards on Start-CachingProxyServiceVM.ps1's UTM wait loops and its
    child-script ($GetImageScript / $NewVMScript) exit-code gates.
.DESCRIPTION
    Start-CachingProxyServiceVM.ps1 builds a VM and exits, so it is not invoked in-process
    here; the tests parse it and assert the required SHAPE via AST nodes rather
    than raw source text, so a code comment cannot satisfy a guard.

    Pinned invariants:
      * The UTM register (30 s) and start-transition (15 s) waits loop on a
        [DateTime]::UtcNow deadline rather than an iteration counter (an $i-bounded
        for loop drifts past the stated timeout by the per-call utmctl latency).
        The bounded start-RETRY loop ($attempt -le 3) is a count, not a timer, and
        is intentionally left as a for loop.
      * The exit-code gates after & $GetImageScript / & $NewVMScript reset
        $global:LASTEXITCODE to $null before the call and test
        $null -ne $LASTEXITCODE, so a child .ps1 that ends on a cmdlet (no native
        command) does not false-fail on stale/absent $LASTEXITCODE. The reset must
        be $global:-qualified -- a bare assignment creates a script-scoped shadow
        that freezes every later read (here and in child scopes) at $null while
        the engine writes real exit codes to the global.
      * The New-VM call forwards -MacAddress via HASHTABLE (by-name) splatting.
        Array splatting binds every element positionally -- a literal
        '-MacAddress' string element is never re-parsed as a parameter name, so
        the child rejects it ("A positional parameter cannot be found") and
        never runs. A live-binding test splats the harness's exact hashtable
        shape against each platform New-VM.ps1's REAL param block (extracted by
        AST), so all three hosts' signatures are exercised on any dev machine.
      * Both child invocations capture $? on the immediately-following statement
        and gate on it. $LASTEXITCODE cannot see a child that never RAN
        (parameter-binding or parse failure leaves it $null); without the $?
        gate the run sails on and prints a false "READY" banner.
      * ConvertTo-YurunaMacAddress (Yuruna.Common) normalizes the accepted
        notations to canonical colon form and rejects multicast / all-zero /
        mixed-separator / wrong-length values with $null.

    The throw-based Assert-* helpers and the AST readers live in the file's
    BeforeAll, which is the scope Pester 5 shares with the It blocks; defining
    them at script scope instead makes every It fail on a missing command rather
    than on an assertion, because script scope belongs to the discovery pass only.
#>

BeforeAll {
$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here
$script:startCp  = Join-Path $testDir 'service/Start-CachingProxyServiceVM.ps1'
$script:repoRoot = Split-Path -Parent $testDir

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-Ast {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}


function Get-WhileConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

function Get-ForConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

# Text of every if-statement condition (AST nodes only -- comments excluded).
function Get-IfConditionText {
    param($Ast)
    $texts = @()
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) { $texts += $clause.Item1.Extent.Text }
    }
    $texts
}

# Count of `$global:LASTEXITCODE = $null` resets (AssignmentStatementAst). The
# $global: qualifier is load-bearing: a bare `$LASTEXITCODE = $null` creates a
# script-scoped copy that shadows the engine's global for the rest of the script
# and inside every child scope, so successful natives read back as failures.
function Get-LastExitResetCount {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$global:LASTEXITCODE' -and
        $n.Right.Extent.Text -eq '$null'
    }, $true)).Count
}

# Count of bare (unqualified) `$LASTEXITCODE = ...` assignments -- the scope-shadow
# trap above. Must stay zero.
function Get-LastExitShadowCount {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$LASTEXITCODE'
    }, $true)).Count
}

# Named parameters declared by a script's param() block.
function Get-ScriptParameterName {
    param($Ast)
    if (-not $Ast.ParamBlock) { return @() }
    @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

# Every assignment whose right-hand side is exactly `$?`, with the pipeline
# statement that immediately precedes it in the same statement block. The
# pairing matters: any statement between the child call and the capture
# overwrites $?, silently disabling the did-it-even-run gate.
function Get-HookCapture {
    param($Ast)
    $captures = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Right.Extent.Text -eq '$?'
    }, $true))
    foreach ($cap in $captures) {
        $block = $cap.Parent
        while ($block -and $block -isnot [System.Management.Automation.Language.NamedBlockAst] -and
               $block -isnot [System.Management.Automation.Language.StatementBlockAst]) {
            $block = $block.Parent
        }
        $stmts = @($block.Statements)
        $idx = $stmts.IndexOf($cap)
        [pscustomobject]@{
            Name     = $cap.Left.Extent.Text
            Previous = if ($idx -gt 0) { $stmts[$idx - 1].Extent.Text } else { '' }
        }
    }
}

}

Describe 'proxy CA preparation and recovery entry points' {
    It 'enables recovery and selects a rebuild without any recovery argument' {
        $ast = Get-Ast $script:startCp
        $decision = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RepairPoolCaTrust'
        })[0]
        $fixture = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + $decision.Extent.Text +
            "`n" + '[pscustomobject]@{Repair=[bool]$RepairPoolCaTrust;Rebuild=[bool]$ForceRebuild;Forwarded=[bool]$PSBoundParameters["ForceRebuild"]}')
        $result = & $fixture
        $result.Repair | Should -BeTrue
        $result.Rebuild | Should -BeTrue
        $result.Forwarded | Should -BeTrue
    }

    It 'enrolls trust after a rebuild: repair=<Strict>, result=<Case>' -ForEach @(
        @{Strict=$false;Case='success';Success=$true;Count=1;Raises=$false;ExpectedThrow=$false;Warnings=0}
        @{Strict=$true;Case='success';Success=$true;Count=1;Raises=$false;ExpectedThrow=$false;Warnings=0}
        @{Strict=$false;Case='partial';Success=$false;Count=1;Raises=$false;ExpectedThrow=$false;Warnings=1}
        @{Strict=$false;Case='empty inventory';Success=$false;Count=0;Raises=$false;ExpectedThrow=$false;Warnings=0}
        @{Strict=$true;Case='partial';Success=$false;Count=1;Raises=$false;ExpectedThrow=$true;Warnings=0}
        @{Strict=$true;Case='empty inventory';Success=$false;Count=0;Raises=$false;ExpectedThrow=$true;Warnings=0}
        @{Strict=$false;Case='invalid statement';Success=$false;Count=0;Raises=$true;ExpectedThrow=$false;Warnings=1}
        @{Strict=$true;Case='invalid statement';Success=$false;Count=0;Raises=$true;ExpectedThrow=$true;Warnings=0}
    ) {
        $source = Get-Content -LiteralPath $script:startCp -Raw
        $begin = $source.IndexOf('# --- REGION: Confirm caching proxy readiness')
        $end = $source.IndexOf("`$serviceOpResult = 'confirmed'", $begin)
        $complete = [scriptblock]::Create('param([bool]$RepairPoolCaTrust)' + "`n" +
            '$cacheIp = "192.0.2.42"; $ModulesDir = "fixture"; $poolRepairArgs = @{}; $serviceOp = $null' + "`n" +
            'function Test-YurunaServiceOperationCurrent { param($Context) $null = $Context; $true }' + "`n" + $source.Substring($begin, $end - $begin))
        function Repair-CachingProxyPoolCaTrust {
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([hashtable])]
            param([string]$CacheHost, [object[]]$HostRecord)
            if ($PSCmdlet.ShouldProcess($CacheHost, 'Fixture enrollment')) { @{Success=$true;Hosts=$HostRecord;Proxy=$CacheHost} }
        }
        Mock Repair-CachingProxyPoolCaTrust {
            if ($Raises) { throw 'fixture-invalid-statement' }
            @{Success=$Success;Hosts=@(1..$Count | Where-Object { $Count -gt 0 } | ForEach-Object { @{Success=$Success} })}
        }
        Mock Import-Module { }
        Mock Write-Warning { }
        if ($ExpectedThrow) { { & $complete -RepairPoolCaTrust $Strict } | Should -Throw }
        else { & $complete -RepairPoolCaTrust $Strict }
        Should -Invoke Repair-CachingProxyPoolCaTrust -Times 1 -Exactly -ParameterFilter { $CacheHost -eq '192.0.2.42' }
        Should -Invoke Write-Warning -Times $Warnings -Exactly
    }
    It 'keeps a working proxy available during automatic enrollment with <Case>' -ForEach @(
        @{Case='an offline pool host';Count=1;Warnings=1;Raises=$false}
        @{Case='no registered hosts yet';Count=0;Warnings=0;Raises=$false}
        @{Case='an invalid signed CA statement';Count=0;Warnings=0;Raises=$true}
    ) {
        $source = Get-Content -LiteralPath $script:startCp -Raw
        $begin = $source.IndexOf('# --- REGION: Confirm caching proxy readiness')
        $end = $source.IndexOf("`$serviceOpResult = 'confirmed'", $begin)
        $complete = [scriptblock]::Create('param([switch]$RepairPoolCaTrust = $true)' + "`n" +
            '$cacheIp = "192.0.2.42"; $ModulesDir = "fixture"; $poolRepairArgs = @{}; $serviceOp = $null' + "`n" +
            'function Test-YurunaServiceOperationCurrent { param($Context) $null = $Context; $true }' + "`n" + $source.Substring($begin, $end - $begin))
        function Repair-CachingProxyPoolCaTrust {
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([hashtable])]
            param([string]$CacheHost)
            if ($PSCmdlet.ShouldProcess($CacheHost, 'Fixture enrollment')) { @{Success=$false;Hosts=@()} }
        }
        Mock Repair-CachingProxyPoolCaTrust { if ($Raises) { throw 'fixture-invalid-statement' }; @{Success=$false;Hosts=@(1..$Count | Where-Object { $Count -gt 0 } | ForEach-Object { @{HostId=('a'*32);Success=$false;Reason='host-config-read';HttpStatus=0} })} }
        Mock Import-Module { }
        Mock Write-Warning { }
        if ($Raises) { { & $complete } | Should -Throw '*fixture-invalid-statement*' }
        else { { & $complete } | Should -Not -Throw }
        Should -Invoke Repair-CachingProxyPoolCaTrust -Times 1 -Exactly
        Should -Invoke Write-Warning -Times $Warnings -Exactly
    }

    It 'rechecks its start intent before it pushes the CA to the pool or confirms' {
        $source = Get-Content -LiteralPath $script:startCp -Raw
        $begin = $source.IndexOf('# --- REGION: Confirm caching proxy readiness')
        $region = $source.Substring($begin, $source.IndexOf("`$serviceOpResult = 'confirmed'", $begin) - $begin)
        $recheck = $region.IndexOf('Test-YurunaServiceOperationCurrent -Context $serviceOp')
        $recheck | Should -BeGreaterThan 0
        $recheck | Should -BeLessThan $region.IndexOf('Repair-CachingProxyPoolCaTrust')
    }
    It 'checks the builder plan before its own teardown' {
        $ast = Get-Ast $script:startCp
        $plan = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-YurunaServiceVmBuildPlan'}, $true))
        $teardown = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Remove-VM', 'Remove-HostProxy')}, $true))
        $plan.Count | Should -Be 1
        $plan[0].Extent.Text | Should -Match '-BuilderPath \$NewVMScript'
        $teardown.Count | Should -BeGreaterThan 0
        foreach ($call in $teardown) { $plan[0].Extent.EndOffset | Should -BeLessThan $call.Extent.StartOffset }
    }
    It 'persists the existing CA before any entry-point VM deletion' {
        $ast = Get-Ast $script:startCp
        $ca = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-YurunaBumpCa'}, $true))
        $remove = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-VM'}, $true))
        $ca.Count | Should -Be 1
        $remove.Count | Should -BeGreaterThan 0
        foreach ($call in $remove) { $ca[0].Extent.StartOffset | Should -BeLessThan $call.Extent.StartOffset }
        $ca[0].Extent.Text | Should -Match '-ReadExistingCa'
    }
    It 'repairs trust only after building the proxy' {
        $ast = Get-Ast $script:startCp
        (Get-ScriptParameterName $ast) | Should -Contain 'RepairPoolCaTrust'
        $repairs = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Repair-CachingProxyPoolCaTrust'}, $true))
        $repairs.Count | Should -Be 1
        $build = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-YurunaServiceVmBuilderRun'}, $true))
        $build.Count | Should -Be 1
        $repairs[0].Extent.StartOffset | Should -BeGreaterThan $build[0].Extent.StartOffset
    }
    It 'restarts the credential service for a rebuild while keeping adoption inexpensive' {
        $ast = Get-Ast $script:startCp
        $calls = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-YurunaConfigServiceIfEnabled'}, $true))
        $calls.Count | Should -Be 2
        $calls[0].Extent.Text | Should -Not -Match '-Restart'
        $calls[1].Extent.Text | Should -Match '-Restart'
    }
    It 'selects rebuild=<Expected> for repair=<Repair> and explicit rebuild=<Force>' -ForEach @(
        @{Repair=$true;Force=$false;Expected=$true}
        @{Repair=$true;Force=$true;Expected=$true}
        @{Repair=$false;Force=$false;Expected=$false}
        @{Repair=$false;Force=$true;Expected=$true}
    ) {
        $ast = Get-Ast $script:startCp
        $decision = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RepairPoolCaTrust'
        })
        $decision.Count | Should -Be 1
        $relaunch = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('Invoke-LibvirtGroupReExecIfNeeded ') })[0]
        $decision[0].Extent.StartOffset | Should -BeLessThan $relaunch.Extent.StartOffset
        $adopt = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if (-not $ForceRebuild)')}, $true))[0]
        $fixture = [scriptblock]::Create('param([bool]$RepairPoolCaTrust, [bool]$ForceRebuild)' + "`n" +
            $decision[0].Extent.Text + "`n" + '[pscustomobject]@{Rebuild=[bool]$ForceRebuild;Forwarded=[bool]$PSBoundParameters["ForceRebuild"];AdoptAllowed=(' + $adopt.Clauses[0].Item1.Extent.Text + ')}')
        $result = & $fixture -RepairPoolCaTrust $Repair -ForceRebuild $Force
        $result.Rebuild | Should -Be $Expected
        $result.Forwarded | Should -Be $Expected
        $result.AdoptAllowed | Should -Be (-not $Expected)
    }
    It 'retains the old pool inventory before teardown for hosts whose test cycles are stopped' {
        $ast = Get-Ast $script:startCp
        $snapshot = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$poolRepairArgs.HostRecord'}, $true))
        $remove = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-VM'}, $true))
        $snapshot.Count | Should -Be 1
        foreach ($call in $remove) { $snapshot[0].Extent.StartOffset | Should -BeLessThan $call.Extent.StartOffset }
        $repair = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Repair-CachingProxyPoolCaTrust'}, $true))[-1]
        $repair.Extent.Text | Should -Match '@poolRepairArgs'
    }
    It 'captures stopped hosts from the existing proxy at <Address>' -ForEach @(
        @{Address='192.0.2.42';Url='http://192.0.2.42:9400/api/v1/pool-status'}
        @{Address='2001:db8::42';Url='http://[2001:db8::42]:9400/api/v1/pool-status'}
    ) {
        Import-Module (Join-Path $script:repoRoot 'automation/Yuruna.Common.psm1') -Global -DisableNameChecking
        $ast = Get-Ast $script:startCp
        $capture = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -eq "(Get-VMState -VMName `$VMName) -ne 'absent'" -and $n.Extent.Text.Contains('$previousPool')}, $true))[0]
        function Get-VMState { 'running' }
        function Get-VMIp { $Address }
        Mock Invoke-RestMethod {
            $script:SnapshotUrl = [string]$Uri
            @{hosts=@(@{hostId=('a'*32);baseUrl='http://192.0.2.7:8080'})}
        }
        $runCapture = [scriptblock]::Create('param([switch]$RepairPoolCaTrust, [string]$VMName)' + "`n" +
            '$poolRepairArgs = @{}' + "`n" + $capture.Extent.Text + "`n" + 'return ,$poolRepairArgs')
        $poolRepairArgs = & $runCapture -RepairPoolCaTrust -VMName 'owned-proxy'
        $poolRepairArgs.ContainsKey('HostRecord') | Should -BeTrue
        @($poolRepairArgs.HostRecord).Count | Should -Be 1
        $poolRepairArgs.HostRecord[0].hostId | Should -BeExactly ('a'*32)
        $script:SnapshotUrl | Should -BeExactly $Url
    }
}

# A proxy URL can carry a user and password, and the runtime directory is
# read by more than this process.
Describe 'Start-CachingProxyServiceVM.ps1 clears the inherited proxy environment without keeping it' {
    It 'clears the variables, keeps no copy of their values and drops one an older run left' {
        $source = Get-Content -LiteralPath $script:startCp -Raw
        $begin = $source.IndexOf('# --- REGION: Clear the inherited proxy environment')
        $end = $source.IndexOf('# --- REGION: Initialize host access', $begin)
        $begin | Should -BeGreaterOrEqual 0
        $end | Should -BeGreaterThan $begin
        $runtime = Join-Path $TestDrive 'proxy-env'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $leftover = Join-Path $runtime '.caching-proxy-service.env.json'
        Set-Content -LiteralPath $leftover -Value '{"HTTP_PROXY":"http://operator:fixture-secret@192.0.2.9:3128"}'
        $priorProxy = $env:HTTP_PROXY
        $priorRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        try {
            $env:HTTP_PROXY = 'http://operator:fixture-secret@192.0.2.9:3128'
            $env:YURUNA_RUNTIME_DIR = $runtime
            # The region resolves module paths from the script's own folder.
            $rootLine = '$PSScriptRoot = ''' + ((Split-Path -Parent $script:startCp) -replace "'", "''") + "'"
            $region = [scriptblock]::Create($rootLine + "`n" + $source.Substring($begin, $end - $begin))
            $verbose = @(& { $VerbosePreference = 'Continue'; & $region } 4>&1 | ForEach-Object { "$_" }) -join "`n"
            Test-Path -LiteralPath Env:HTTP_PROXY | Should -BeFalse
            @(Get-ChildItem -LiteralPath $runtime -Force).Count | Should -Be 0 -Because 'no copy of the values is kept, and the old one is gone'
            $verbose | Should -Match 'HTTP_PROXY'
            $verbose | Should -Not -Match 'fixture-secret'
        } finally {
            if ($null -eq $priorProxy) { Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue } else { $env:HTTP_PROXY = $priorProxy }
            Restore-YurunaTestEnvironment -Saved $priorRuntime
        }
    }
}

Describe 'Start-CachingProxyServiceVM.ps1 bounds the UTM waits by wall-clock' {
    It 'loops the register + start waits on a UtcNow deadline, not an $i iteration counter' {
        $ast = Get-Ast $script:startCp
        $utcWhiles = @(Get-WhileConditionText -Ast $ast | Where-Object { $_ -match 'UtcNow' })
        Assert-True ($utcWhiles.Count -ge 2) "the register + start waits both gate on [DateTime]::UtcNow; found $($utcWhiles.Count)"
        # Scoped to a timeout literal (-lt 30 / -lt 15) so this catches a reverted
        # iteration-counted TIME wait specifically, without false-failing a
        # legitimate fixed-count for loop (e.g. `for ($i -lt 3)`) or the retained
        # `$attempt -le 3` retry.
        $timeWaitFor = @(Get-ForConditionText -Ast $ast | Where-Object { $_ -match '-lt\s+(30|15)\b' })
        Assert-True ($timeWaitFor.Count -eq 0) "no UTM time wait is left as an iteration-counted for loop (a -lt 30/15 bound); found: $($timeWaitFor -join ' | ')"
    }
}

Describe 'Start-CachingProxyServiceVM.ps1 gates child scripts on a reset $LASTEXITCODE' {
    It 'resets $global:LASTEXITCODE to $null before the in-process child call and tests it null-safely' {
        # Get-Image runs in this process; New-VM.ps1 runs as a bounded child whose
        # exit code the shared builder run classifies (covered below).
        $ast = Get-Ast $script:startCp
        Assert-True ((Get-LastExitResetCount -Ast $ast) -ge 1) '& $GetImageScript is preceded by $global:LASTEXITCODE = $null'
        $nullSafe = @(Get-IfConditionText -Ast $ast | Where-Object { $_ -match '\$null -ne \$LASTEXITCODE' })
        Assert-True ($nullSafe.Count -ge 1) "the Get-Image gate uses a null-safe `$null -ne `$LASTEXITCODE test; found $($nullSafe.Count)"
    }
    It 'has no bare $LASTEXITCODE assignment (script-scope shadow of the engine global)' {
        $ast = Get-Ast $script:startCp
        Assert-True ((Get-LastExitShadowCount -Ast $ast) -eq 0) 'a bare $LASTEXITCODE assignment shadows the engine global; qualify with $global:'
    }
}

# --- REGION: Discovery cases
# See https://yuruna.link/42e220c4-0014
$discoveryRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$newVmScriptCases = @(
    @{ Platform = 'windows.hyper-v'; Path = (Join-Path $discoveryRepoRoot 'host/windows.hyper-v/guest.caching-proxy-service/New-VM.ps1') }
    @{ Platform = 'ubuntu.kvm';      Path = (Join-Path $discoveryRepoRoot 'host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1') }
    @{ Platform = 'macos.utm';       Path = (Join-Path $discoveryRepoRoot 'host/macos.utm/guest.caching-proxy-service/New-VM.ps1') }
)
if ($newVmScriptCases.Count -ne 3) {
    throw "Expected the caching-proxy New-VM.ps1 case list to cover 3 platforms, found $($newVmScriptCases.Count)."
}

Describe 'Every platform New-VM.ps1 accepts -MacAddress (cross-host param contract)' {
    It '<Platform> New-VM.ps1 declares -MacAddress and -VMName' -TestCases $newVmScriptCases {
        $names = Get-ScriptParameterName -Ast (Get-Ast $Path)
        Assert-True ($names -contains 'MacAddress') "$Path declares -MacAddress; found: $($names -join ', ')"
        Assert-True ($names -contains 'VMName') "$Path declares -VMName; found: $($names -join ', ')"
    }
    It '<Platform> New-VM.ps1 binds the Start''s child command line against its real param block' -TestCases $newVmScriptCases {
        # Extract the script's ACTUAL param block into a stub that echoes what
        # bound, then start it the way Start-CachingProxyServiceVM.ps1 starts the
        # builder: a child pwsh -File with each parameter as a separate argument
        # after its name, the squid size (which holds a space) included. This
        # exercises real parameter binding for every platform on any dev host --
        # no hypervisor needed -- and fails if a platform's param block drifts
        # away from the harness's call shape.
        $ast = Get-Ast $Path
        Assert-True ($null -ne $ast.ParamBlock) "$Path has a param() block"
        $stubPath = Join-Path $TestDrive ($Platform + '.New-VM.stub.ps1')
        Set-Content -LiteralPath $stubPath -Value ($ast.ParamBlock.Extent.Text + "`nWrite-Output `"BOUND:`$VMName|`$MacAddress|`$MemoryMb|`$SquidCacheMem`"")
        $out = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $stubPath -VMName 'stub-vm' -MacAddress '02:42:42:42:42:42' -MemoryMb '4096' -SquidCacheMem '2 GB'
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because "the child for $Path binds without error"
        Assert-True (@($out) -contains 'BOUND:stub-vm|02:42:42:42:42:42|4096|2 GB') "stub for $Path bound every value; got: $out"
    }
}

Describe 'Start-CachingProxyServiceVM.ps1 forwards -MacAddress by name and fails fast when a child never runs' {
    It 'runs New-VM.ps1 only as the bounded child, each parameter a separate argument after its name' {
        $ast = Get-Ast $script:startCp
        # Run in this process, the builder would hold the service lock for as long
        # as a wedged call lasted; the bounded child is the only way it runs.
        $inProcess = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.CommandElements[0].Extent.Text -eq '$NewVMScript'
        }, $true))
        Assert-True ($inProcess.Count -eq 0) "New-VM.ps1 is not invoked in this process; found $($inProcess.Count)"
        $runs = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Invoke-YurunaServiceVmBuilderRun'
        }, $true))
        Assert-True ($runs.Count -eq 1) "one bounded builder run; found $($runs.Count)"
        Assert-True ($runs[0].Extent.Text -match '-BuilderPath \$NewVMScript\b') 'the run starts the resolved New-VM.ps1'
        Assert-True ($runs[0].Extent.Text -match '-BuilderArgument \$newVmArgs\.ToArray\(\)') 'the run passes the collected builder arguments'
        # On the child's command line a parameter binds by name only when its
        # value follows it as the next argument.
        $macPair = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ArrayLiteralAst] -and
            $n.Elements.Count -eq 2 -and
            $n.Elements[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Elements[0].Value -eq '-MacAddress' -and $n.Elements[1].Extent.Text -eq '$MacAddress'
        }, $true))
        Assert-True ($macPair.Count -eq 1) "-MacAddress is followed by its value; found $($macPair.Count)"
    }
    It 'captures $? right after the in-process Get-Image call, and stops on a failed builder run with its exit code' {
        $ast = Get-Ast $script:startCp
        $hooks = @(Get-HookCapture -Ast $ast)
        $childHooks = @($hooks | Where-Object { $_.Previous -match '^&\s+\$GetImageScript\b' })
        Assert-True ($childHooks.Count -ge 1) "& `$GetImageScript is immediately followed by a `$? capture; found $($childHooks.Count) (any statement in between overwrites `$?)"
        $gated = @(Get-IfConditionText -Ast $ast | Where-Object { $_ -match '-not \$getImageInvokeOk\b' })
        Assert-True ($gated.Count -ge 1) "the Get-Image invocation-ok flag is tested with -not; found $($gated.Count)"
        $failed = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -eq '-not $cpBuild.Ok'
        }, $true))
        Assert-True ($failed.Count -eq 1) 'a failed builder run is tested'
        Assert-True ($failed[0].Clauses[0].Item2.Extent.Text -match 'exit \$cpBuild\.ExitCode') 'it exits with the run''s exit code (124 for a build stopped at its bound)'
    }
}

Describe 'ConvertTo-YurunaMacAddress normalizes and validates (Yuruna.Common)' {
    # In BeforeAll, not the Describe body: the body is executed during discovery,
    # where importing a module is a side effect performed long before -- and
    # independently of -- the It blocks that need the commands.
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    }

    It 'normalizes dash, bare-hex, and colon notations to canonical colon form' {
        Assert-True ((ConvertTo-YurunaMacAddress '02-11-22-33-44-55') -eq '02:11:22:33:44:55') 'dash notation'
        Assert-True ((ConvertTo-YurunaMacAddress 'aabbccddeeff' -WarningAction SilentlyContinue) -eq 'AA:BB:CC:DD:EE:FF') 'bare hex, uppercased'
        Assert-True ((ConvertTo-YurunaMacAddress '02:11:22:33:44:55') -eq '02:11:22:33:44:55') 'colon passthrough'
    }
    It 'rejects multicast, all-zero, mixed-separator, and wrong-length values' {
        foreach ($bad in @('01:00:5E:00:00:01', '000000000000', '02:11-22:33:44:55', '0211223344', 'zz:11:22:33:44:55')) {
            $out = ConvertTo-YurunaMacAddress $bad -WarningAction SilentlyContinue
            Assert-True ($null -eq $out) "'$bad' is rejected with `$null; got '$out'"
        }
    }
    It 'accepts a globally-unique OUI but warns about hardware collision risk' {
        $out = ConvertTo-YurunaMacAddress '08:00:27:AA:BB:CC' -WarningAction SilentlyContinue -WarningVariable macWarn
        Assert-True ($out -eq '08:00:27:AA:BB:CC') 'value still accepted'
        Assert-True (@($macWarn).Count -ge 1) 'a locally-administered-bit warning is emitted'
    }
}

Describe 'the cache VM RAM and squid cache_mem are chosen as one pair' {
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    }

    # The pairing is the whole point of the function: swap is masked in the
    # guest, so a cache_mem raised without the RAM under it is an unrecoverable
    # OOM rather than a slowdown. Pinning both numbers of both pairings is what
    # makes one of them impossible to move alone.
    It 'defaults to the pairing sized for a host that also runs test guests' {
        $p = Get-CachingProxyMemoryProfile
        Assert-Equal 8192  $p.VmMemoryMb    -Because 'a host running its own guests cannot spare a beacon-sized cache'
        Assert-Equal '3 GB' $p.SquidCacheMem
    }
    It 'gives a lab beacon the larger pairing' {
        $p = Get-CachingProxyMemoryProfile -Lab
        Assert-Equal 12288 $p.VmMemoryMb
        Assert-Equal '7 GB' $p.SquidCacheMem
    }
    # squid's resident set runs about a gigabyte above cache_mem, and what is
    # left over has to carry zot (2 GB) and the rest of the stack (~2 GB). That
    # headroom -- not a percentage of the VM -- is what both pairings hold
    # constant, so it is the arithmetic a third pairing has to satisfy.
    It 'leaves the same 4 GB above squid in both pairings' {
        foreach ($pair in @((Get-CachingProxyMemoryProfile), (Get-CachingProxyMemoryProfile -Lab))) {
            $cacheMemGb = [int]($pair.SquidCacheMem -replace '\D', '')
            $headroomGb = ($pair.VmMemoryMb / 1024) - ($cacheMemGb + 1)
            Assert-Equal 4 $headroomGb `
                -Because "cache_mem $cacheMemGb GB in $($pair.VmMemoryMb / 1024) GB leaves $headroomGb GB for zot and the rest of the stack, not 4"
        }
    }
    # The switch names the exception, so the size a host gets is the safe one
    # unless something says otherwise. A run that has to opt IN to the smaller
    # pairing gives a beacon-sized cache to every host whose operator did not
    # know to ask.
    It 'names the exception, so the default needs no argument' {
        $declared = Get-ScriptParameterName -Ast (Get-Ast $script:startCp)
        Assert-True ($declared -contains 'Lab') 'the launcher takes -Lab'
        Assert-True ($declared -notcontains 'Standalone') 'and no longer asks the ordinary host to opt in'
    }
}


Describe 'Syzygy uses proxy recovery defaults and reports its failures' {
    BeforeAll {
        function New-SyzygyFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Creates only disposable test fixtures under TestDrive.')]
            [CmdletBinding()]
            [OutputType([string])]
            param()
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'lab'), (Join-Path $root 'service')
            Copy-Item (Join-Path $script:repoRoot 'test/lab/Start-Syzygy.ps1') (Join-Path $root 'lab/Start-Syzygy.ps1')
            $child = @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$MacAddress, [switch]$AllowPseudoLocale, [switch]$RepairPoolCaTrust = $true)
$row = @{Name=[IO.Path]::GetFileName($PSCommandPath);Mac=$MacAddress;Pseudo=[bool]$AllowPseudoLocale;Repair=[bool]$RepairPoolCaTrust;RepairBound=$PSBoundParameters.ContainsKey('RepairPoolCaTrust');Preview=[bool]$PSBoundParameters['WhatIf'];ConfirmBound=$PSBoundParameters.ContainsKey('Confirm')}
[IO.File]::AppendAllText((Join-Path $PSScriptRoot '../calls.jsonl'), ($row | ConvertTo-Json -Compress) + "`n")
'@
            foreach ($name in 'CachingProxy', 'Stash', 'PoolControl', 'DownloadAgent') {
                Set-Content -LiteralPath (Join-Path $root "service/Start-${name}ServiceVM.ps1") -Value $child
            }
            return $root
        }
    }
    It 'uses recovery defaults with preview=<Preview> and confirmation=<Confirmation>' -ForEach @(
        @{Preview=$false;Confirmation=$false}
        @{Preview=$false;Confirmation=$true}
        @{Preview=$true;Confirmation=$false}
        @{Preview=$true;Confirmation=$true}
    ) {
        $root = New-SyzygyFixture
        & (Join-Path $root 'lab/Start-Syzygy.ps1') -WhatIf:$Preview -Confirm:$Confirmation
        $rows = @(Get-Content -LiteralPath (Join-Path $root 'calls.jsonl') | ConvertFrom-Json)
        @($rows.Name) -join ',' | Should -BeExactly 'Start-CachingProxyServiceVM.ps1,Start-StashServiceVM.ps1,Start-PoolControlServiceVM.ps1,Start-DownloadAgentServiceVM.ps1'
        $rows[0].Mac | Should -BeExactly '42:42:42:42:42:42'
        $rows[0].Repair | Should -BeTrue
        $rows[0].RepairBound | Should -BeFalse
        foreach ($row in $rows) {
            $row.Pseudo | Should -BeTrue
            $row.Preview | Should -Be $Preview
            $row.ConfirmBound | Should -BeTrue
        }
        foreach ($row in $rows[1..3]) { $row.RepairBound | Should -BeFalse }
    }
    It 'stops before other service starts when proxy recovery <Failure>' -ForEach @(
        @{Failure='throws';Body="throw 'fixture-recovery-failed'"}
        @{Failure='exits unsuccessfully';Body='exit 7'}
    ) {
        $root = New-SyzygyFixture
        Set-Content -LiteralPath (Join-Path $root 'service/Start-CachingProxyServiceVM.ps1') -Value $Body
        { & (Join-Path $root 'lab/Start-Syzygy.ps1') -Confirm:$false } | Should -Throw
        Test-Path -LiteralPath (Join-Path $root 'calls.jsonl') | Should -BeFalse
    }
}

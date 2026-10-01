<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42074735-e5df-4b56-b216-96e6299e53f9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool admin gate retry pester
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
    Test-YurunaPoolIntentFile fails a REQUIRED but absent file (pools.yml) while
    SKIPping optional ones, and the idempotent network git ops (fetch/clone/push)
    retry within one wall-clock budget.
.DESCRIPTION
    Behavioral tests exercise the exported Test-YurunaPoolIntentFile and the
    module-private Invoke-PoolAdminGitWithRetry (in module scope), with the git
    primitive + schema validator mocked. AST guards pin that the CI gate marks
    pools.yml -Required and that fetch/clone/push route through the retry wrapper.
    The throw-free Should assertions run under Pester 4.10.1.
#>

BeforeAll {
$here          = Split-Path -Parent $PSCommandPath
$adminPath     = Join-Path $here 'Test.PoolAdmin.psm1'
$syncPath      = Join-Path $here 'Test.PoolSync.psm1'
$script:poolIntentPs1 = Join-Path (Split-Path -Parent $here) 'pool/Test-PoolIntent.ps1'
Import-Module $syncPath  -Force   # exports Invoke-PoolSyncGit (mocked below)
Import-Module $adminPath -Force

# powershell-yaml may be absent in the test session; shim ConvertFrom-Yaml so the
# present-file cases can mock it in module scope.
$script:yamlShimmed = $false
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    function global:ConvertFrom-Yaml {
        param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Ordered)
        process { $null = $InputObject; $null = $Ordered }
    }
    $script:yamlShimmed = $true
}

# --- REGION: https://yuruna.link/42d69dfa-0015
function Get-FileAst {
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}
function Get-CommandInvocation {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
    }, $true))
}
function Get-FunctionDefCount {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
    }, $true)).Count
}
function Test-CallHasSwitch {
    param($Call, [string]$SwitchName)
    $sw = $SwitchName
    @($Call.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq $sw
    }).Count -gt 0
}
function Test-AnyExtentMatch {
    param($Nodes, [string]$Pattern)
    $p = $Pattern
    @($Nodes | Where-Object { $_.Extent.Text -match $p }).Count -gt 0
}

}

Describe 'Test-YurunaPoolIntentFile enforces required vs optional intent files' {
    It 'FAILS a required file that is absent (pools.yml must not read as success)' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('nope-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Test-YurunaPoolIntentFile -Path $missing -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required -WarningAction SilentlyContinue | Should -Be $false
    }
    It 'SKIPs (passes) an optional file that is absent' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('nope-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Test-YurunaPoolIntentFile -Path $missing -SchemaName 'guests.compatibility.schema.yml' -Label 'guests.compatibility.yml' | Should -Be $true
    }
    It 'PASSes a present, schema-valid file' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yes-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Set-Content -LiteralPath $tmp -Value 'schemaVersion: 1'
        try {
            Mock -ModuleName Test.PoolAdmin ConvertFrom-Yaml { @{ schemaVersion = 1 } }
            Mock -ModuleName Test.PoolAdmin Test-YurunaPoolDocValid { @{ Ok = $true; Errors = @() } }
            Test-YurunaPoolIntentFile -Path $tmp -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required | Should -Be $true
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    It 'FAILs a present file that is schema-invalid' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('bad-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Set-Content -LiteralPath $tmp -Value 'schemaVersion: 1'
        try {
            Mock -ModuleName Test.PoolAdmin ConvertFrom-Yaml { @{ schemaVersion = 1 } }
            Mock -ModuleName Test.PoolAdmin Test-YurunaPoolDocValid { @{ Ok = $false; Errors = @('pools[0].poolId required') } }
            Test-YurunaPoolIntentFile -Path $tmp -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required -WarningAction SilentlyContinue | Should -Be $false
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    It 'FAILs a present file that will not parse as YAML' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('unparse-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Set-Content -LiteralPath $tmp -Value ': not yaml'
        try {
            Mock -ModuleName Test.PoolAdmin ConvertFrom-Yaml { throw 'bad yaml' }
            Test-YurunaPoolIntentFile -Path $tmp -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required -WarningAction SilentlyContinue | Should -Be $false
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-PoolAdminGitWithRetry survives a transient failure within a bounded budget' {
    It 'returns 0 and calls git once when the first attempt succeeds (no retry, no sleep)' {
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 0 }
        Mock -ModuleName Test.PoolAdmin Start-Sleep { }
        $rc = & (Get-Module Test.PoolAdmin) {
            param($Budget, $Delay)
            Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', 'x', 'fetch', '--quiet', 'origin') -Label 'git fetch' -BudgetSeconds $Budget -DelaySeconds $Delay
        } 30 1
        $rc | Should -Be 0
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Times 1 -Exactly -Scope It
        Assert-MockCalled -ModuleName Test.PoolAdmin Start-Sleep -Times 0 -Exactly -Scope It
    }
    It 'retries a transient failure and returns 0 once the next attempt succeeds' {
        $env:POOLADMIN_GIT_ATTEMPTS = '0'
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit {
            $n = [int]$env:POOLADMIN_GIT_ATTEMPTS + 1
            $env:POOLADMIN_GIT_ATTEMPTS = "$n"
            if ($n -lt 2) { 128 } else { 0 }
        }
        Mock -ModuleName Test.PoolAdmin Start-Sleep { }
        try {
            $rc = & (Get-Module Test.PoolAdmin) {
                param($Budget, $Delay)
                Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', 'x', 'push', '--quiet', 'origin', 'HEAD:main') -Label 'git push' -BudgetSeconds $Budget -DelaySeconds $Delay
            } 30 1
            $rc | Should -Be 0
            Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Times 2 -Exactly -Scope It
            Assert-MockCalled -ModuleName Test.PoolAdmin Start-Sleep -Times 1 -Exactly -Scope It
        } finally { Remove-Item Env:\POOLADMIN_GIT_ATTEMPTS -ErrorAction SilentlyContinue }
    }
    It 'gives up with the failing exit code once the wall-clock budget is spent (bounded, real backoff)' {
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 128 }
        $rc = & (Get-Module Test.PoolAdmin) {
            param($Budget, $Delay)
            Invoke-PoolAdminGitWithRetry -ArgumentList @('clone', '--quiet', 'url', 'dir') -Label 'git clone' -BudgetSeconds $Budget -DelaySeconds $Delay
        } 2 1
        $rc | Should -Be 128
        # >=2 attempts proves it retried; the test returning at all proves the
        # deadline bounds the loop (a budget-blind retry would spin forever).
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Times 2 -Scope It
    }
}

Describe 'CI gate marks pools.yml required and admin git ops route through retry (AST)' {
    It 'Test-PoolIntent.ps1 defines no local intent-file validator (delegates to the module)' {
        (Get-FunctionDefCount -Ast (Get-FileAst $script:poolIntentPs1) -Name 'Test-OneIntentFile') | Should -Be 0
    }
    It 'Test-PoolIntent.ps1 marks exactly the pools.yml check -Required' {
        $calls = Get-CommandInvocation -Ast (Get-FileAst $script:poolIntentPs1) -Name 'Test-YurunaPoolIntentFile'
        $calls.Count | Should -BeGreaterOrEqual 2
        $required = @($calls | Where-Object { Test-CallHasSwitch -Call $_ -SwitchName 'Required' })
        $required.Count | Should -Be 1
        $required[0].Extent.Text | Should -Match 'pools\.yml'
    }
    It 'Test.PoolAdmin.psm1 routes ONLY the network ops (fetch/clone/push) through the retry wrapper' {
        $ast = Get-FileAst $adminPath
        (Get-FunctionDefCount -Ast $ast -Name 'Invoke-PoolAdminGitWithRetry') | Should -BeGreaterOrEqual 1
        $wrapped = Get-CommandInvocation -Ast $ast -Name 'Invoke-PoolAdminGitWithRetry'
        $direct  = Get-CommandInvocation -Ast $ast -Name 'Invoke-PoolSyncGit'
        $wrapped.Count | Should -BeGreaterOrEqual 3
        # Idempotent network ops retry; local ops must NOT (a retry there cannot clear
        # a real repo-state error and would only mask it). Assert op identities, not a
        # bare count, so wrapping a local op or unwrapping a network op is caught.
        foreach ($op in 'fetch', 'clone', 'push') {
            (Test-AnyExtentMatch -Nodes $wrapped -Pattern "'$op'") | Should -Be $true
            (Test-AnyExtentMatch -Nodes $direct  -Pattern "'$op'") | Should -Be $false
        }
        # merge-base + rebase are LOCAL ops: retrying a rebase could re-enter a
        # half-applied rebase, so they must stay direct like add/commit/reset/diff.
        foreach ($op in 'add', 'commit', 'reset', 'diff', 'merge-base', 'rebase') {
            (Test-AnyExtentMatch -Nodes $direct  -Pattern "'$op'") | Should -Be $true
            (Test-AnyExtentMatch -Nodes $wrapped -Pattern "'$op'") | Should -Be $false
        }
    }
}

Describe 'Open-YurunaPoolIntent refuses to reset --hard over unpushed local commits' {
    # Open takes a lock file beside the clone; Windows will not delete the drive while it is open.
    AfterAll { Unlock-YurunaPoolIntentClone -All }
    It 'returns Ok=$false and does NOT reset when the clone is local-ahead (merge-base --is-ancestor = 1)' {
        Mock -ModuleName Test.PoolAdmin Test-Path { param($LiteralPath) $LiteralPath -notlike '*rebase-*' }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry { 0 }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { if ($ArgumentList -contains 'merge-base') { 1 } else { 0 } }
        $r = Open-YurunaPoolIntent -IntentGitUrl 'https://example/intent' -IntentDir 'TestDrive:\intent' -Confirm:$false
        $r.Ok | Should -Be $false
        $r.Error | Should -Match 'refusing to reset'
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Scope It -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'reset' }
    }
    It 'proceeds with the reset when HEAD is contained in FETCH_HEAD (merge-base = 0)' {
        Mock -ModuleName Test.PoolAdmin Test-Path { param($LiteralPath) $LiteralPath -notlike '*rebase-*' }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry { 0 }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 0 }
        $r = Open-YurunaPoolIntent -IntentGitUrl 'https://example/intent' -IntentDir 'TestDrive:\intent' -Confirm:$false
        $r.Ok | Should -Be $true
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Scope It -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'reset' }
    }
    It 'returns Ok=$false and does NOT reset when a rebase is in progress (mid-rebase clone)' {
        Mock -ModuleName Test.PoolAdmin Test-Path { $true }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry { 0 }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 0 }
        $r = Open-YurunaPoolIntent -IntentGitUrl 'https://example/intent' -IntentDir 'TestDrive:\intent' -Confirm:$false
        $r.Ok | Should -Be $false
        $r.Error | Should -Match 'unfinished rebase'
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Scope It -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'reset' }
    }
}

Describe 'An existing intent clone must match the requested intentGitUrl' {
    BeforeAll {
        $script:originRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('poolorigin-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:originClone = Join-Path $script:originRoot 'clone'
        New-Item -ItemType Directory -Path $script:originClone -Force | Out-Null
        & git -C $script:originClone init --quiet 2>&1 | Out-Null
        & git -C $script:originClone remote add origin 'https://example.test/org/intent-one.git' 2>&1 | Out-Null
    }
    AfterAll {
        Unlock-YurunaPoolIntentClone -All
        if (Test-Path -LiteralPath $script:originRoot) { [System.IO.Directory]::Delete($script:originRoot, $true) }
    }
    It 'accepts the same URL despite case, a .git suffix or a trailing slash' {
        (Test-PoolIntentCloneOrigin -Path $script:originClone -Url 'HTTPS://example.test/org/intent-one/') | Should -BeTrue
    }
    It 'reports a different URL as a mismatch' {
        (Test-PoolIntentCloneOrigin -Path $script:originClone -Url 'https://example.test/org/intent-two.git') | Should -BeFalse
    }
    It 'does not judge a path that is not a repository' {
        (Test-PoolIntentCloneOrigin -Path (Join-Path $script:originRoot 'absent') -Url 'https://example.test/x.git') | Should -BeTrue
    }
    It 'makes Open-YurunaPoolIntent refuse a clone whose origin is another URL, before any fetch' {
        Mock -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry { 0 }
        $r = Open-YurunaPoolIntent -IntentGitUrl 'https://example.test/org/intent-two.git' -IntentDir $script:originClone -Confirm:$false
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'different origin'
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry -Scope It -Times 0 -Exactly
    }
    It 'repoints the runner cache clone at the configured URL before it fetches' {
        Mock -ModuleName Test.PoolSync Invoke-PoolSyncGit { 0 }
        Mock -ModuleName Test.PoolSync Write-YurunaPoolState { $true }
        Mock -ModuleName Test.PoolSync Write-YurunaPoolManifest { $true }
        $shimmed = $false
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { function global:ConvertFrom-Yaml { }; $shimmed = $true }
        try {
            $cfg = @{ pool = @{ enabled = $true; intentGitUrl = 'https://example.test/org/intent-two.git'; localClonePath = $script:originClone; pullTimeoutSeconds = 5 } }
            $null = Sync-YurunaPoolIntent -Config $cfg -HostId '42none000000000000000000000000'
            Assert-MockCalled -ModuleName Test.PoolSync Invoke-PoolSyncGit -Scope It -Times 1 -Exactly -ParameterFilter { ($ArgumentList -contains 'set-url') -and ($ArgumentList -contains 'https://example.test/org/intent-two.git') }
        } finally { if ($shimmed) { Remove-Item function:\ConvertFrom-Yaml -Force -ErrorAction SilentlyContinue } }
    }
}
Describe 'Open-YurunaPoolIntent keeps concurrent admin commands out of one admin clone' {
    BeforeAll {
        $modules = Split-Path -Parent $PSCommandPath
        $script:lockAdmin = Join-Path $modules 'Test.PoolAdmin.psm1'
        $script:lockSync = Join-Path $modules 'Test.PoolSync.psm1'
        $script:lockRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('poollock-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:lockRoot -Force | Out-Null
        # A real bare store with one commit, so a clone has something to fetch.
        $script:lockStore = Join-Path $script:lockRoot 'store.git'
        $seed = Join-Path $script:lockRoot 'seed'
        & git init --quiet --bare --initial-branch=main $script:lockStore 2>&1 | Out-Null
        & git clone --quiet $script:lockStore $seed 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $seed 'pools.yml') -Value 'schemaVersion: 3' -Encoding ascii
        & git -C $seed add -A 2>&1 | Out-Null
        & git -C $seed -c user.email=t@example.invalid -c user.name=t commit --quiet -m seed 2>&1 | Out-Null
        & git -C $seed push --quiet origin HEAD:main 2>&1 | Out-Null

        function Start-LockChild {
            # One admin command is one process, so the tests use real ones.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: starts short-lived child processes that touch only the suite temp directory.')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([Parameter(Mandatory)][string]$Body, [string[]]$ArgumentList = @())
            $file = Join-Path $script:lockRoot ('child-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            $header = "param(`$Dir, `$Signal)`nImport-Module '$($script:lockSync)' -Force`nImport-Module '$($script:lockAdmin)' -Force`n"
            Set-Content -LiteralPath $file -Value ($header + $Body) -Encoding utf8NoBOM
            $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $file) + $ArgumentList) { $psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $process = [System.Diagnostics.Process]::Start($psi)
            return @{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
        }
    }
    AfterAll {
        Unlock-YurunaPoolIntentClone -All
        if (Test-Path -LiteralPath $script:lockRoot) { [System.IO.Directory]::Delete($script:lockRoot, $true) }
    }

    It 'lets six processes open one clone that does not exist yet, and every one succeeds' {
        $dir = Join-Path $script:lockRoot 'first-use'
        $open = "`$r = Open-YurunaPoolIntent -IntentGitUrl '$($script:lockStore)' -IntentDir `$Dir -Confirm:`$false`n" +
            "'{0}|{1}' -f `$r.Ok, `$r.Error`nStart-Sleep -Milliseconds 300"
        $children = 1..6 | ForEach-Object { Start-LockChild -Body $open -ArgumentList @('-Dir', $dir) }
        $results = foreach ($c in $children) {
            if (-not $c.Process.WaitForExit(120000)) { $c.Process.Kill($true); 'timed out' } else { $c.Out.GetAwaiter().GetResult().Trim() }
        }
        $results | Should -HaveCount 6
        @($results | Where-Object { $_ -ne 'True|' }) | Should -HaveCount 0 -Because ("every opener must succeed; got: " + ($results -join ' ; '))
        (& git -C $dir log --format=%s) | Should -Be 'seed'
    }

    It 'makes a second process wait while one holds the clone, then let it in' {
        $dir = Join-Path $script:lockRoot 'held'
        $held = Join-Path $script:lockRoot 'held.signal'
        $release = Join-Path $script:lockRoot 'held.release'
        $holder = Start-LockChild -ArgumentList @('-Dir', $dir, '-Signal', $held) -Body (
            "`$null = Lock-YurunaPoolIntentClone -IntentDir `$Dir`nSet-Content -LiteralPath `$Signal -Value held`n" +
            "`$end = [DateTime]::UtcNow.AddSeconds(60)`nwhile (-not (Test-Path -LiteralPath '$release') -and [DateTime]::UtcNow -lt `$end) { Start-Sleep -Milliseconds 100 }")
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Test-Path -LiteralPath $held) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $held | Should -BeTrue -Because 'the holder must take the lock first'

            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $refused = Lock-YurunaPoolIntentClone -IntentDir $dir -WaitSeconds 1
            $clock.Stop()
            $refused.Ok | Should -BeFalse
            $refused.Error | Should -Match 'another pool admin command'
            $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 0.9 -Because 'it waits for the holder before it gives up'

            Set-Content -LiteralPath $release -Value go
            $holder.Process.WaitForExit(60000) | Should -BeTrue
            (Lock-YurunaPoolIntentClone -IntentDir $dir -WaitSeconds 30).Ok | Should -BeTrue
        } finally {
            if (-not $holder.Process.HasExited) { $holder.Process.Kill($true) }
            Unlock-YurunaPoolIntentClone -IntentDir $dir
        }
    }

    It 'is re-entrant within one process and frees the clone when it is unlocked' {
        $dir = Join-Path $script:lockRoot 'reentrant'
        (Lock-YurunaPoolIntentClone -IntentDir $dir -WaitSeconds 1).Ok | Should -BeTrue
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        (Lock-YurunaPoolIntentClone -IntentDir $dir -WaitSeconds 30).Ok | Should -BeTrue
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 5 -Because 'a second lock by the holder itself must not wait'
        Unlock-YurunaPoolIntentClone -IntentDir $dir
        # Released: an exclusive open of the lock file now succeeds.
        $probe = [System.IO.FileStream]::new("$dir.lock", [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $probe.Dispose()
    }

    It 'does not put the lock inside the clone, where git add -A would stage it' {
        $dir = Join-Path $script:lockRoot 'beside'
        (Lock-YurunaPoolIntentClone -IntentDir $dir -WaitSeconds 1).Ok | Should -BeTrue
        Test-Path -LiteralPath "$dir.lock" | Should -BeTrue
        Test-Path -LiteralPath $dir | Should -BeFalse -Because 'locking must not create the clone directory itself'
        Unlock-YurunaPoolIntentClone -IntentDir $dir
    }

    It 'skips a lock it cannot create instead of failing the command' -Skip:($IsWindows) {
        $readOnly = Join-Path $script:lockRoot 'read-only'
        New-Item -ItemType Directory -Path $readOnly -Force | Out-Null
        & chmod 555 $readOnly
        try {
            (Lock-YurunaPoolIntentClone -IntentDir (Join-Path $readOnly 'clone') -WaitSeconds 1).Ok | Should -BeTrue
        } finally { & chmod 755 $readOnly }
    }
}

# Drop the portability shim so it does not leak into a later suite sharing this session.
AfterAll { if ($script:yamlShimmed) { Remove-Item -LiteralPath Function:global:ConvertFrom-Yaml -Force -ErrorAction SilentlyContinue } }

<#PSScriptInfo
.VERSION 2026.06.19
.GUID 42e2607c-3d4e-4f50-8a61-7c8d9e0f1a2b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner inner-loop pester
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
    Pester smoke harness for the inner runner's config-reload seam and the
    cycle helpers extracted into Test.RunnerInnerLoop.psm1 / Test.ConfigSync.psm1.
.DESCRIPTION
    Guards the regression-prone mechanics the inner runner depends on before
    the rest of the per-cycle body is decomposed into a module function:
      * the reloadable-knob resolution rules (defaults, int coercion, the
        0/absent-falls-back-to-default behavior, the -CycleDelaySeconds fallback);
      * Sync-RunnerCycleConfig's mtime parse-cache, its keep-previous-on-failure
        contract, and the by-reference $State mutation the wrapped cycle body
        will rely on (the scope-collapse risk);
      * the pure config-merge / template-shape / secret-hiding contracts.

    Assertions are throw-based inside It blocks so the file runs under the
    OS-bundled Pester 3.4 (no Install-Module needed) and under Pester 5+.
    Run with:  Invoke-Pester -Path test/modules/Test.RunnerInnerLoop.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Prelude.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.RunnerInnerLoop.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.ConfigSync.psm1')      -Force -DisableNameChecking
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning "powershell-yaml unavailable; YAML-dependent tests will fail." }

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) { throw "Expected [$Expected] but got [$Actual]. $Because" }
}
function Assert-True {
    param($Condition, [string]$Because = '')
    if (-not $Condition) { throw "Expected condition to be true. $Because" }
}
function New-TempConfigFile {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: writes a throwaway temp config file the calling It block deletes in its finally.')]
    param([string]$Content)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-cfg-" + [guid]::NewGuid().ToString('N') + ".yml")
    [System.IO.File]::WriteAllText($p, $Content, [System.Text.UTF8Encoding]::new($false))
    return $p
}

Describe 'Get-RunnerReloadableConfig' {
    It 'applies defaults when the parsed config is null' {
        $r = Get-RunnerReloadableConfig -Config $null -CycleDelayFallback 30
        Assert-Equal $false $r.StopOnFailure 'default StopOnFailure'
        Assert-Equal 120    $r.VmStartTimeout 'default VmStartTimeout'
        Assert-Equal 15     $r.VmBootDelay 'default VmBootDelay'
        Assert-Equal 24     $r.GetImageRefreshHours 'default GetImageRefreshHours'
        Assert-Equal 30     $r.CycleDelay 'CycleDelay falls back to -CycleDelayFallback'
    }
    It 'reads operator values and coerces strings to int' {
        $cfg = @{
            testCycle = @{ shouldStopOnFailure = $true; cycleDelaySeconds = '45' }
            vmStart   = @{ startTimeoutSeconds = '200'; bootDelaySeconds = 9 }
            vmImage   = @{ refreshHours = 6 }
        }
        $r = Get-RunnerReloadableConfig -Config $cfg -CycleDelayFallback 30
        Assert-Equal $true $r.StopOnFailure 'operator StopOnFailure'
        Assert-Equal 200   $r.VmStartTimeout 'operator VmStartTimeout'
        Assert-Equal 9     $r.VmBootDelay 'operator VmBootDelay'
        Assert-Equal 6     $r.GetImageRefreshHours 'operator GetImageRefreshHours'
        Assert-Equal 45    $r.CycleDelay 'config cycleDelaySeconds wins over fallback'
        Assert-True ($r.VmStartTimeout -is [int]) 'VmStartTimeout coerced to int'
    }
    It 'treats a 0/absent value as falling back to the default' {
        $r = Get-RunnerReloadableConfig -Config @{ vmStart = @{ startTimeoutSeconds = 0 } } -CycleDelayFallback 30
        Assert-Equal 120 $r.VmStartTimeout '0 is falsy -> default 120'
    }
}

Describe 'New-RunnerConfigState' {
    It 'seeds cache slots null and knobs to defaults' {
        $s = New-RunnerConfigState -CmdLineLogLevel 'Debug' -CycleDelayFallback 42
        Assert-Equal 'Debug' $s.CmdLineLogLevel 'cmdline level captured'
        Assert-Equal 42      $s.CycleDelayFallback 'fallback captured'
        Assert-True ($null -eq $s.CachedConfigMtime) 'mtime cache empty'
        Assert-True ($null -eq $s.CachedConfigValue) 'value cache empty'
        Assert-True ($null -eq $s.Config) 'config empty'
        Assert-Equal 120 $s.VmStartTimeout 'knob default seeded'
        Assert-Equal 42  $s.CycleDelay 'CycleDelay seeded to fallback'
    }
}

Describe 'Sync-RunnerCycleConfig' {
    It 'resolves knobs from a real file and mutates $State by reference' {
        $yaml = "testCycle:`n  shouldStopOnFailure: true`n  cycleDelaySeconds: 55`nvmStart:`n  startTimeoutSeconds: 300`n  bootDelaySeconds: 20`nvmImage:`n  refreshHours: 12`n"
        $p = New-TempConfigFile -Content $yaml
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $alias = $s   # second reference to prove by-reference mutation (the scope-collapse guard)
            $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p
            Assert-Equal 'resolved' $status 'parsed + dict -> resolved'
            Assert-Equal $true $s.StopOnFailure 'StopOnFailure mirrored'
            Assert-Equal 300   $s.VmStartTimeout 'VmStartTimeout mirrored'
            Assert-Equal 20    $s.VmBootDelay 'VmBootDelay mirrored'
            Assert-Equal 12    $s.GetImageRefreshHours 'GetImageRefreshHours mirrored'
            Assert-Equal 55    $s.CycleDelay 'CycleDelay mirrored'
            Assert-Equal 300   $alias.VmStartTimeout 'the other reference sees the same mutation'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
    It 'returns the cached Config object on an unchanged file (no re-parse)' {
        $yaml = "vmStart:`n  startTimeoutSeconds: 150`n"
        $p = New-TempConfigFile -Content $yaml
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $null = Sync-RunnerCycleConfig -State $s -ConfigPath $p
            $first = $s.Config
            $null = Sync-RunnerCycleConfig -State $s -ConfigPath $p   # unchanged mtime -> cache hit
            $second = $s.Config
            Assert-True ([object]::ReferenceEquals($first, $second)) 'unchanged file returns the same cached parse object'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps previously resolved values and returns failed when a later read fails' {
        $yaml = "vmStart:`n  startTimeoutSeconds: 175`n"
        $p = New-TempConfigFile -Content $yaml
        $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
        $null = Sync-RunnerCycleConfig -State $s -ConfigPath $p
        Assert-Equal 175 $s.VmStartTimeout 'resolved good value first'
        $prevConfig = $s.Config
        Remove-Item $p -Force -ErrorAction SilentlyContinue   # force a read failure on the next sync
        $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p
        Assert-Equal 'failed' $status 'read failure -> failed'
        Assert-Equal 175 $s.VmStartTimeout 'knob kept at last-known-good'
        Assert-True ([object]::ReferenceEquals($prevConfig, $s.Config)) 'Config kept (not wiped) on failure'
    }
    It 'returns failed on malformed YAML without throwing' {
        $p = New-TempConfigFile -Content "vmStart: [unterminated"
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p -WarningAction SilentlyContinue
            Assert-Equal 'failed' $status 'malformed yaml -> failed'
            Assert-True ($null -eq $s.Config) 'Config stays null when first parse fails'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
    It 'returns nondict when the parsed value is a scalar' {
        $p = New-TempConfigFile -Content "just-a-scalar-string"
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p
            Assert-Equal 'nondict' $status 'scalar config -> nondict'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Convert-LocalRepoUrlToPath' {
    It 'maps file:// URLs and bare drive paths, rejects remote/empty' {
        Assert-Equal 'c:/git/yuruna-project' (Convert-LocalRepoUrlToPath -Url 'file:///c:/git/yuruna-project') 'file:// stripped'
        Assert-Equal 'c:\git\yuruna' (Convert-LocalRepoUrlToPath -Url 'c:\git\yuruna') 'drive path passes through'
        Assert-True ($null -eq (Convert-LocalRepoUrlToPath -Url 'https://github.com/x/y')) 'remote url -> null'
        Assert-True ($null -eq (Convert-LocalRepoUrlToPath -Url '')) 'empty -> null'
    }
}

Describe 'Assert-CachingProxyStillReachable' {
    It 'no-ops without warning on an empty or non-http URL' {
        $out = @()
        $out += Assert-CachingProxyStillReachable -ProxyUrl '' -StepName 'New-VM' -GuestKey 'g' 3>&1
        $out += Assert-CachingProxyStillReachable -ProxyUrl 'not-a-url' -StepName 'New-VM' -GuestKey 'g' 3>&1
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal 0 $warnings.Count 'no warnings on the no-op paths'
    }
    It 'warns when the proxy URL does not answer (1s probe to TEST-NET-1)' {
        $out = Assert-CachingProxyStillReachable -ProxyUrl 'http://192.0.2.1:3128' -StepName 'New-VM' -GuestKey 'g' 3>&1
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-True ($warnings.Count -ge 1) 'unreachable proxy surfaces a warning'
    }
}

Describe 'Write-InnerLog' {
    It 'appends an [inner]-tagged line to outer.log under YURUNA_RUNTIME_DIR' {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-il-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d
        $old = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $d
        try {
            Write-InnerLog 'hello-innerlog-test'
            $log = Join-Path $d 'outer.log'
            Assert-True (Test-Path $log) 'outer.log created'
            Assert-True ([bool]((Get-Content $log -Raw) -match '\[inner\] hello-innerlog-test')) 'line is [inner]-tagged and present'
        } finally {
            $env:YURUNA_RUNTIME_DIR = $old
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Inner-cycle child-script import discipline' {
    # Regression guard for the eviction class: scripts the inner cycle &-invokes
    # from inside the Test.RunnerInnerLoop module must import the host contract /
    # driver with -Global, or a -Force import pulls it out of the global table
    # and a later contract call from a foreign module (Invoke-Sequence) fails.
    # AST-based so here-string content (the detached status-service child) is not
    # mis-scanned -- only real Import-Module calls are checked.
    It 'host-contract/driver -Force imports in the &-invoked cycle scripts use -Global' {
        $testRoot = Split-Path -Parent $here
        foreach ($name in @('Remove-TestVMFiles.ps1', 'Start-StatusService.ps1')) {
            $path = Join-Path $testRoot $name
            Assert-True (Test-Path $path) "cycle script exists: $name"
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $imports = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true)
            foreach ($imp in $imports) {
                $text = $imp.Extent.Text
                if (($text -match 'Test\.HostContract|Yuruna\.Host') -and ($text -match '-Force')) {
                    Assert-True ($text -match '-Global') "$name : host-contract/driver -Force import must use -Global -> $text"
                }
            }
        }
    }
}

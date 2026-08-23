<#PSScriptInfo
.VERSION 2026.08.23
.GUID 42e861b5-08b7-414a-a164-c414c541a30d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test portowner perf pester
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
    Guards on perf/port-owner invariants: Resolve-PortOrphan classifies every port
    holder before stopping any (no partial kill), Get-PerfHostUuid creates its id
    atomically (one uuid per machine under concurrent first use), and
    Get-PortHolderServiceInfo requires a Yuruna field combination.
.DESCRIPTION
    Behavioral, with the OS-touching primitives mocked in module scope. Mock and the
    throw-free Should assertions run under Pester 4.10.1.
#>

BeforeAll {
$here          = Split-Path -Parent $PSCommandPath
$portOwnerPath = Join-Path $here 'Test.PortOwner.psm1'
$perfPath      = Join-Path $here 'Test.Perf.psm1'
Import-Module $portOwnerPath -Force
Import-Module $perfPath -Force

# Count of static-method invocations matching [<TypePattern>]::<Member>(...) with
# exactly $ArgCount arguments (-1 = any). AST nodes only.
function Get-StaticInvokeCount {
    param([string]$Path, [string]$TypePattern, [string]$Member, [int]$ArgCount = -1)
    $tp = $TypePattern; $m = $Member; $ac = $ArgCount
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq $m -and $n.Expression.Extent.Text -match $tp -and
        ($ac -lt 0 -or (@($n.Arguments).Count -eq $ac))
    }, $true)).Count
}

# Count [IO.File]::Open(...) calls that pass FileMode::CreateNew -- the claim
# host.uuid depends on, and the only form that admits exactly one racer.
function Get-CreateExclusiveOpenCount {
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq 'Open' -and
        $n.Expression.Extent.Text -match 'System\.IO\.File' -and
        $n.Extent.Text -match 'FileMode\]::CreateNew'
    }, $true)).Count
}

}

Describe 'Resolve-PortOrphan classifies all holders before stopping any' {
    It 'returns Conflict WITHOUT stopping our owned holder when a foreign holder is also present' {
        Mock -ModuleName Test.PortOwner Test-PortListenerFree { $false }
        Mock -ModuleName Test.PortOwner Get-PortListenerPid { 1001, 1002 }
        Mock -ModuleName Test.PortOwner Get-PortHolderServiceInfo { @{ IsYuruna = $false; Hostname = ''; Host = ''; HostId = '' } }
        Mock -ModuleName Test.PortOwner Get-Process { [pscustomobject]@{ ProcessName = 'pwsh'; StartTime = (Get-Date) } }
        Mock -ModuleName Test.PortOwner Get-ProcessOwnerName { if ($Id -eq 1001) { 'me' } else { 'stranger' } }
        Mock -ModuleName Test.PortOwner Test-OwnedByCurrentUser { $Owner -eq 'me' }
        Mock -ModuleName Test.PortOwner Stop-Process { }

        $r = Resolve-PortOrphan -Port 65001 -Confirm:$false

        $r.Status | Should -Be 'Conflict'
        # The reclaimable holder (1001) precedes the foreign one (1002); a single-pass
        # kill-as-you-go would have stopped 1001 before returning Conflict on 1002.
        Assert-MockCalled -ModuleName Test.PortOwner Stop-Process -Times 0 -Exactly
    }
    It 'stops every holder when all are reclaimable owned pwsh' {
        Mock -ModuleName Test.PortOwner Test-PortListenerFree { $false }
        Mock -ModuleName Test.PortOwner Get-PortListenerPid { 2001, 2002 }
        Mock -ModuleName Test.PortOwner Get-PortHolderServiceInfo { @{ IsYuruna = $false; Hostname = ''; Host = ''; HostId = '' } }
        Mock -ModuleName Test.PortOwner Get-Process { [pscustomobject]@{ ProcessName = 'pwsh'; StartTime = (Get-Date) } }
        Mock -ModuleName Test.PortOwner Get-ProcessOwnerName { 'me' }
        Mock -ModuleName Test.PortOwner Test-OwnedByCurrentUser { $true }
        Mock -ModuleName Test.PortOwner Stop-Process { }

        $null = Resolve-PortOrphan -Port 65002 -Confirm:$false

        Assert-MockCalled -ModuleName Test.PortOwner Stop-Process -Times 2 -Exactly
    }
}

Describe 'Get-PortHolderServiceInfo requires the Yuruna field combination' {
    It 'classifies a full per-cycle Yuruna status doc as Yuruna' {
        Mock -ModuleName Test.PortOwner Invoke-WebRequest {
            [pscustomobject]@{ Content = '{"schemaVersion":1,"hostId":"42abc","overallStatus":"running","host":"h","hostname":"hn"}' }
        }
        (Get-PortHolderServiceInfo -Port 65010).IsYuruna | Should -Be $true
    }
    It 'classifies the bootstrap template (schemaVersion + overallStatus, no hostId) as Yuruna' {
        # The status service answers with status.json.template before the first cycle;
        # it carries schemaVersion + overallStatus but no hostId, so the marker must
        # not require hostId or a just-launched peer would go unnamed.
        Mock -ModuleName Test.PortOwner Invoke-WebRequest {
            [pscustomobject]@{ Content = '{"schemaVersion":1,"overallStatus":"idle"}' }
        }
        (Get-PortHolderServiceInfo -Port 65011).IsYuruna | Should -Be $true
    }
    It 'does NOT classify a foreign service that merely has a host/hostname key' {
        Mock -ModuleName Test.PortOwner Invoke-WebRequest {
            [pscustomobject]@{ Content = '{"host":"other-app","hostname":"box","version":"9"}' }
        }
        (Get-PortHolderServiceInfo -Port 65012).IsYuruna | Should -Be $false
    }
    It 'does NOT classify a doc with schemaVersion but no overallStatus' {
        Mock -ModuleName Test.PortOwner Invoke-WebRequest {
            [pscustomobject]@{ Content = '{"schemaVersion":1,"host":"x"}' }
        }
        (Get-PortHolderServiceInfo -Port 65013).IsYuruna | Should -Be $false
    }
    It 'does NOT classify a doc with overallStatus but no schemaVersion' {
        Mock -ModuleName Test.PortOwner Invoke-WebRequest {
            [pscustomobject]@{ Content = '{"overallStatus":"running","host":"x"}' }
        }
        (Get-PortHolderServiceInfo -Port 65014).IsYuruna | Should -Be $false
    }
}

Describe 'Get-PerfHostUuid creates the host id atomically' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('perfuuid-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:savedRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:root
    }
    AfterEach {
        $env:YURUNA_RUNTIME_DIR = $script:savedRuntime
        if (Test-Path -LiteralPath $script:root) { [System.IO.Directory]::Delete($script:root, $true) }
    }
    It 'generates a 42-prefixed id, persists it, and is idempotent' {
        $first = Get-PerfHostUuid
        $first | Should -Match '^42[0-9a-f]{30}$'
        (Test-Path -LiteralPath (Join-Path $script:root 'host.uuid')) | Should -Be $true
        Get-PerfHostUuid | Should -Be $first
    }
    It 'adopts an existing host.uuid instead of regenerating' {
        $existing = '42deadbeefdeadbeefdeadbeefdeadb'
        [System.IO.File]::WriteAllText((Join-Path $script:root 'host.uuid'), $existing)
        Get-PerfHostUuid | Should -Be $existing
    }
    It 'converges on ONE id under concurrent first use' {
        $r = $script:root; $mp = $perfPath
        $jobs = 1..5 | ForEach-Object {
            Start-Job -ScriptBlock {
                $env:YURUNA_RUNTIME_DIR = $using:r
                Import-Module $using:mp -Force
                Get-PerfHostUuid
            }
        }
        $results = @($jobs | Wait-Job -Timeout 90 | Receive-Job)
        $jobs | Remove-Job -Force
        $results.Count               | Should -Be 5
        (@($results | Sort-Object -Unique)).Count | Should -Be 1
    }
    It 'claims host.uuid with a create-exclusive open, never a rename' {
        # A bare overwrite lets concurrent first-use racers clobber each other, and a
        # rename is no better on POSIX: [System.IO.File]::Move tests for the
        # destination and then renames, so racers that pass the test together all
        # rename successfully, the last one lands on disk, and every earlier one
        # returns a UUID that was never persisted. Only the create can be the lock --
        # FileMode.CreateNew is O_CREAT|O_EXCL on POSIX and CREATE_NEW on Windows.
        (Get-CreateExclusiveOpenCount -Path $perfPath) | Should -BeGreaterOrEqual 1
        (Get-StaticInvokeCount -Path $perfPath -TypePattern 'System\.IO\.File' -Member 'Move') | Should -Be 0
    }
}

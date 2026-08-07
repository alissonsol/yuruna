<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b7c3e9-5d81-4a06-9f24-3e8d1c705b6a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test setup preflight memory service vm pester
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
    setup.ps1 must tell an operator what the service VMs will commit, and what
    this host has, BEFORE it starts building them.
.DESCRIPTION
    WHY THIS EXISTS. Every service guest is built at a size fixed in its per-host
    New-VM.ps1, and none of those guests balloon: a size is spent for as long as
    the service runs. Four services on one machine is 24 GB of guest memory
    whether the host has 16 GB or 128 GB, so the only place that arithmetic can
    still change an operator's mind is ahead of the first build.

    WHAT IS PINNED HERE.
      * the sizes are READ from the builders, in all three of their hypervisor
        shapes, and a builder that stops matching is a test failure rather than a
        silently wrong total;
      * only the services a run actually starts are counted -- a standalone host
        with storage.kind = none never builds the stash or the download agent,
        and charging it for them would be a false alarm;
      * the arithmetic across host sizes and service combinations, including the
        boundary that separates 'ok' from 'warn';
      * that the verdict never becomes a hard failure, and never silently reads
        'ok' when something could not be measured;
      * that setup.ps1 spends the check before the first service bring-up, and
        restates none of the builders' numbers.

    Assertions are plain throws and the Pester harness is shimmed when Pester is
    absent, so this runs either way.
    Run: pwsh -NoProfile -File test/modules/Test.HostMemoryPreflight.Tests.ps1
         (or Invoke-Pester -Path test/modules/Test.HostMemoryPreflight.Tests.ps1)
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

Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

# Every host driver, and the four services each of them builds. Read from disk
# rather than listed with their sizes: the point of the check under test is that
# the builders are the only statement of how large a service guest is.
$HostFolder  = @('macos.utm', 'windows.hyper-v', 'ubuntu.kvm')
$ServiceKey  = @('caching-proxy', 'stash', 'download-agent', 'pool-control')
$RealSize    = @{}
foreach ($hostFolder in $HostFolder) {
    foreach ($key in $ServiceKey) {
        $RealSize["$hostFolder/$key"] = Get-ServiceVmMemoryMb -RepoRoot $repoRoot -HostFolder $hostFolder -Key $key
    }
}

# One plan-row builder, so a fixture names services rather than numbers.
function Get-PlanRow {
    param([string[]]$Key, [string]$From = 'macos.utm', [hashtable]$Override = @{})
    return @($Key | ForEach-Object {
        $mb = if ($Override.ContainsKey($_)) { [int]$Override[$_] } else { [int]$RealSize["$From/$_"] }
        [pscustomobject]@{ Name = $_; MemoryMb = $mb }
    })
}

$SetupSrc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'install/setup.ps1')
$SetupAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'install/setup.ps1'), [ref]$null, [ref]$null)

# The plans a real run produces, and the host sizes worth asking about:
# 16 GB and 32 GB are the machines this is meant to catch, 24 GB is the awkward
# middle, and 36/64/128 GB are the ones that must NOT be warned at.
# PlanStandaloneAgent is the opt-in shape (downloadAgentService.enabled: true on
# a standalone host); the default standalone set stops at the stash.
$PlanStandalone      = Get-PlanRow -Key (Select-SetupServiceVmKey -StorageKind 'local')
$PlanStandaloneAgent = Get-PlanRow -Key (Select-SetupServiceVmKey -StorageKind 'local' -DownloadAgentEnabled $true)
$PlanProxyOnly       = Get-PlanRow -Key (Select-SetupServiceVmKey -StorageKind 'none')
$PlanLab             = Get-PlanRow -Key (Select-SetupServiceVmKey -StorageKind 'local' -Lab)
$HostSizeMb          = @(8192, 16384, 24576, 32768, 36864, 65536, 131072)
$PlanSet             = @(
    (Select-SetupServiceVmKey -StorageKind 'none'),
    (Select-SetupServiceVmKey -StorageKind 'local'),
    (Select-SetupServiceVmKey -StorageKind 'local' -DownloadAgentEnabled $true),
    (Select-SetupServiceVmKey -StorageKind 'local' -DownloadAgentEnabled $false),
    (Select-SetupServiceVmKey -StorageKind 'local' -Lab)
)

Describe 'host-memory preflight -- the size comes out of the guest builders' {
    It 'reads the UTM shape (an MB count substituted into the plist)' {
        Assert-Equal 12288 (Get-GuestBuilderMemoryMb -Text "    -replace '__MEMORY_SIZE__',        '12288'")
    }
    It 'reads the libvirt shape (virt-install --memory, MiB)' {
        Assert-Equal 4096 (Get-GuestBuilderMemoryMb -Text "    '--memory',     '4096',")
    }
    It 'reads the Hyper-V shape (bytes, as a PowerShell size literal)' {
        Assert-Equal 12288 (Get-GuestBuilderMemoryMb -Text 'New-VM -Name $VMName -MemoryStartupBytes 12GB -SwitchName $s')
        Assert-Equal 4096  (Get-GuestBuilderMemoryMb -Text 'Set-VM -MemoryStartupBytes 4096MB -MemoryMaximumBytes 4096MB')
    }
    It 'takes the largest when a builder states the size more than once' {
        $text = @'
Hyper-V\New-VM -Name $VMName -MemoryStartupBytes 4GB -SwitchName $s
Set-VM -Name $VMName -MemoryStartupBytes 4GB -MemoryMaximumBytes 8GB
'@
        Assert-Equal 8192 (Get-GuestBuilderMemoryMb -Text $text) -Because 'the ceiling is what the host has to carry'
    }
    It 'reports 0 -- unknown -- when the size comes from a parameter, never a guess' {
        Assert-Equal 0 (Get-GuestBuilderMemoryMb -Text "    -replace '__MEMORY_SIZE__',         `"`$vmMemoryMb`"")
        Assert-Equal 0 (Get-GuestBuilderMemoryMb -Text 'New-VM -MemoryStartupBytes $MemoryStartupBytes')
    }
    It 'reports 0 for empty, whitespace and unrelated text' {
        Assert-Equal 0 (Get-GuestBuilderMemoryMb -Text '')
        Assert-Equal 0 (Get-GuestBuilderMemoryMb -Text '   ')
        Assert-Equal 0 (Get-GuestBuilderMemoryMb -Text 'Write-Output "no memory here"')
    }
    It 'still finds a size in every service builder on every host' {
        foreach ($hostFolder in $HostFolder) {
            foreach ($key in $ServiceKey) {
                Assert-True ($RealSize["$hostFolder/$key"] -gt 0) `
                    "no literal memory size found in host/$hostFolder/guest.$key-service/New-VM.ps1 -- the preflight would report that service as unsized"
            }
        }
    }
    It 'finds the caching proxy to be the largest of them (squid cache_mem is what it is budgeted around)' {
        foreach ($hostFolder in $HostFolder) {
            foreach ($key in @('stash', 'download-agent', 'pool-control')) {
                Assert-True ($RealSize["$hostFolder/caching-proxy"] -ge $RealSize["$hostFolder/$key"]) `
                    "${hostFolder}: $key is sized above the caching proxy"
            }
        }
    }
    It 'reports 0 for a host folder or service it does not have, rather than throwing' {
        Assert-Equal 0 (Get-ServiceVmMemoryMb -RepoRoot $repoRoot -HostFolder 'no.such.host' -Key 'stash')
        Assert-Equal 0 (Get-ServiceVmMemoryMb -RepoRoot $repoRoot -HostFolder 'macos.utm' -Key 'no-such-service')
    }
}

Describe 'host-memory preflight -- only the services this run starts are counted' {
    It 'standalone starts only the proxy and the stash unless the agent is opted in' {
        Assert-Equal 'caching-proxy,stash' ((Select-SetupServiceVmKey -StorageKind 'local') -join ',') `
            -Because 'every service gigabyte on a standalone host is one its test guests cannot have'
        Assert-Equal 'caching-proxy,stash' ((Select-SetupServiceVmKey -StorageKind 'nas') -join ',')
        Assert-Equal 'caching-proxy,stash,download-agent' ((Select-SetupServiceVmKey -StorageKind 'local' -DownloadAgentEnabled $true) -join ',') `
            -Because 'an explicit downloadAgentService.enabled: true overrides the standalone default'
    }
    It 'storage.kind = none starts the proxy alone' {
        Assert-Equal 'caching-proxy' ((Select-SetupServiceVmKey -StorageKind 'none') -join ',') `
            -Because 'charging a host for the stash and download agent it never builds is a false alarm'
    }
    It 'downloadAgentService.enabled = false drops the agent and nothing else' {
        Assert-Equal 'caching-proxy,stash' ((Select-SetupServiceVmKey -StorageKind 'local' -DownloadAgentEnabled $false) -join ',')
    }
    It 'a lab adds the download agent and the pool-control service' {
        Assert-Equal 'caching-proxy,stash,download-agent,pool-control' ((Select-SetupServiceVmKey -StorageKind 'local' -Lab) -join ',') `
            -Because 'sharing images across the pool''s hosts is the agent''s whole point, so a lab runs it unasked'
        Assert-Equal 'caching-proxy,stash,pool-control' ((Select-SetupServiceVmKey -StorageKind 'local' -Lab -DownloadAgentEnabled $false) -join ',')
    }
    It 'an unresolved storage.kind counts the storage services rather than dropping them' {
        Assert-Equal 'caching-proxy,stash' ((Select-SetupServiceVmKey -StorageKind '') -join ',') `
            -Because 'unknown must not read as "no storage", the answer that hides the stash'
        Assert-Equal 'caching-proxy,stash,download-agent,pool-control' ((Select-SetupServiceVmKey -StorageKind '' -Lab) -join ',')
    }
}

Describe 'host-memory preflight -- the arithmetic across host sizes' {
    It 'sums only the services in the plan' {
        Assert-Equal 16384 (Get-ServiceVmMemoryVerdict -Service $PlanStandalone      -HostMemoryMb 32768).CommittedMb
        Assert-Equal 20480 (Get-ServiceVmMemoryVerdict -Service $PlanStandaloneAgent -HostMemoryMb 32768).CommittedMb
        Assert-Equal 12288 (Get-ServiceVmMemoryVerdict -Service $PlanProxyOnly       -HostMemoryMb 32768).CommittedMb
        Assert-Equal 24576 (Get-ServiceVmMemoryVerdict -Service $PlanLab             -HostMemoryMb 32768).CommittedMb
    }
    It 'estimates a resident set larger than the guests are configured with' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanStandalone -HostMemoryMb 32768
        Assert-True ($v.ResidentMb -gt $v.CommittedMb) 'a hypervisor holds more than the guest size; ignoring that under-reports the bill'
        Assert-True ($v.ResidentMb -lt ($v.CommittedMb * 2)) 'the overhead factor has run away'
        Assert-Equal ($v.HostMemoryMb - $v.ResidentMb) $v.RemainingMb
        Assert-Equal ($v.ResidentMb + $v.ReserveMb)    $v.NeededMb
    }
    It 'passes a 32 GB host on the default standalone set, and warns once the agent is opted in' {
        Assert-Equal 'ok' (Get-ServiceVmMemoryVerdict -Service $PlanStandalone -HostMemoryMb 32768).Level `
            -Because 'proxy + stash is sized so a 32 GB machine keeps its reserve'
        $v = Get-ServiceVmMemoryVerdict -Service $PlanStandaloneAgent -HostMemoryMb 32768
        Assert-Equal 'warn' $v.Level
        Assert-True ($v.RemainingMb -lt $v.ReserveMb) 'the warning has to follow from the arithmetic, not from a host-size table'
    }
    It 'passes the same host once storage -- and with it two services -- is declined' {
        Assert-Equal 'ok' (Get-ServiceVmMemoryVerdict -Service $PlanProxyOnly -HostMemoryMb 32768).Level
    }
    It 'passes a 64 GB host running a full lab, and warns at 32 GB' {
        Assert-Equal 'ok'   (Get-ServiceVmMemoryVerdict -Service $PlanLab -HostMemoryMb 65536).Level
        Assert-Equal 'ok'   (Get-ServiceVmMemoryVerdict -Service $PlanLab -HostMemoryMb 131072).Level
        Assert-Equal 'warn' (Get-ServiceVmMemoryVerdict -Service $PlanLab -HostMemoryMb 32768).Level
    }
    It 'warns on a 16 GB host even for the proxy alone' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanProxyOnly -HostMemoryMb 16384
        Assert-Equal 'warn' $v.Level
        Assert-True ($v.Message -match 'Nothing in this run can be skipped') 'with one service left there is no service to drop, and saying otherwise is false advice'
    }
    It 'says how much MORE is wanted when the plan exceeds the machine' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanLab -HostMemoryMb 8192
        Assert-Equal 'warn' $v.Level
        Assert-True ($v.RemainingMb -lt 0) 'fixture must exceed the host for this case to mean anything'
        Assert-True ($v.Message -match 'more than it has') "a negative remainder must not be printed as 'leaving -13.8 GB'"
    }
    It 'turns on the remainder against the reserve, exactly at the boundary' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanStandalone -HostMemoryMb 32768
        $atLine    = $v.ResidentMb + $v.ReserveMb
        Assert-Equal 'ok'   (Get-ServiceVmMemoryVerdict -Service $PlanStandalone -HostMemoryMb $atLine).Level
        Assert-Equal 'warn' (Get-ServiceVmMemoryVerdict -Service $PlanStandalone -HostMemoryMb ($atLine - 1)).Level
        Assert-Equal 'ok'   (Get-ServiceVmMemoryVerdict -Service $PlanStandalone -HostMemoryMb ($atLine + 1)).Level
    }
    It 'names the whole arithmetic in the warning, not just the verdict' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanStandaloneAgent -HostMemoryMb 32768
        foreach ($fragment in @('32.0 GB', '20.0 GB', '7.2 GB', '8.0 GB', '32.8 GB')) {
            Assert-True ($v.Message -match [regex]::Escape($fragment)) `
                "the warning must state $fragment (host, committed, left, reserve, needed) -- 'low memory' is not actionable"
        }
        foreach ($key in @('caching-proxy', 'stash', 'download-agent')) {
            Assert-True ($v.Message -match [regex]::Escape($key)) "the breakdown must name $key so the total can be checked by hand"
        }
    }
    It 'offers a lab only the levers a lab is allowed to pull' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanLab -HostMemoryMb 32768
        Assert-True ($v.Message -notmatch 'storage\.kind = none') `
            "a lab needs the shares for its stash and its intent store, so setup rejects storage.kind = none for one"
        Assert-True ($v.Message -match 'downloadAgentService\.enabled') 'the download agent is a lever a lab does have'
    }
    It 'offers a standalone host both of its levers, with what each one is worth' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanStandaloneAgent -HostMemoryMb 32768
        Assert-True ($v.Message -match 'storage\.kind = none')          'the storage lever'
        Assert-True ($v.Message -match 'downloadAgentService\.enabled') 'the narrower lever'
        Assert-True ($v.Message -match '\(8\.0 GB\)')                   'what dropping both storage services is worth'
        Assert-True ($v.Message -match '\(4\.0 GB\)')                   'what dropping the agent alone is worth'
    }
}

Describe 'host-memory preflight -- what it does when it cannot measure' {
    It 'reports unknown -- never ok -- when the host does not state its memory' {
        $v = Get-ServiceVmMemoryVerdict -Service $PlanStandalone -HostMemoryMb 0
        Assert-Equal 'unknown' $v.Level
        Assert-True ($v.Message -match 'not checked') 'silence would read as a host that passed'
    }
    It 'reports unknown when no builder could be read' {
        $blind = Get-PlanRow -Key @('caching-proxy', 'stash') -Override @{ 'caching-proxy' = 0; 'stash' = 0 }
        Assert-Equal 'unknown' (Get-ServiceVmMemoryVerdict -Service $blind -HostMemoryMb 32768).Level
    }
    It 'names the services missing from the total, and calls the total a floor' {
        $partial = Get-PlanRow -Key @('caching-proxy', 'stash', 'download-agent') -Override @{ 'stash' = 0 }
        $v = Get-ServiceVmMemoryVerdict -Service $partial -HostMemoryMb 32768
        Assert-Equal 16384 $v.CommittedMb -Because 'an unreadable size must not be guessed at'
        Assert-True ($v.Message -match 'floor')  'a total missing a service is a floor, and has to say so'
        Assert-True ($v.Message -match 'stash')  'the operator has to know WHICH service is not in the figure'
    }
    It 'still offers a service as a lever when its size could not be read' {
        $partial = Get-PlanRow -Key @('caching-proxy', 'stash', 'download-agent') -Override @{ 'stash' = 0; 'download-agent' = 0 }
        $v = Get-ServiceVmMemoryVerdict -Service $partial -HostMemoryMb 16384
        Assert-Equal 'warn' $v.Level
        Assert-True ($v.Message -match 'storage\.kind = none') 'an unsized service is still a service the operator can decline'
    }
    It 'survives an empty plan without arithmetic on nothing' {
        Assert-Equal 'unknown' (Get-ServiceVmMemoryVerdict -Service @() -HostMemoryMb 32768).Level
    }
}

Describe 'host-memory preflight -- the verdict is a warning, and stays one' {
    It 'never returns a level that would stop a run' {
        # An over-commitment is not proof that a build cannot finish: the size is
        # what the hypervisor commits, not what the guest touches, and all three
        # platforms overcommit. A host measured at 20 GB committed on 32 GB
        # completed its builds while compressing. A hard stop there would block
        # machines that work today, so 'warn' is the loudest level there is.
        foreach ($mb in $HostSizeMb) {
            foreach ($plan in $PlanSet) {
                $v = Get-ServiceVmMemoryVerdict -Service (Get-PlanRow -Key $plan) -HostMemoryMb $mb
                Assert-True ($v.Level -in @('ok', 'warn', 'unknown')) "unexpected level '$($v.Level)' at ${mb}MB"
            }
        }
    }
    It 'fits its one-line summary in the width a step outcome shows' {
        # Write-StepOutcome trims a step's detail to 140 characters, and this
        # summary IS that detail -- a summary that overflows loses its numbers.
        foreach ($mb in $HostSizeMb) {
            foreach ($plan in $PlanSet) {
                $v = Get-ServiceVmMemoryVerdict -Service (Get-PlanRow -Key $plan) -HostMemoryMb $mb
                Assert-True ($v.Summary.Length -le 140) "summary is $($v.Summary.Length) chars at ${mb}MB: $($v.Summary)"
                Assert-True ($v.Summary -notmatch "`n") 'the step line is one line'
            }
        }
    }
    It 'agrees with itself on every host size: ok exactly when the reserve survives' {
        foreach ($mb in $HostSizeMb) {
            foreach ($plan in $PlanSet) {
                $v = Get-ServiceVmMemoryVerdict -Service (Get-PlanRow -Key $plan) -HostMemoryMb $mb
                $expected = if ($v.RemainingMb -ge $v.ReserveMb) { 'ok' } else { 'warn' }
                Assert-Equal $expected $v.Level -Because "level disagrees with the arithmetic at ${mb}MB for $($plan -join ',')"
            }
        }
    }
    It 'reads the same on every host driver, because the builders agree' {
        foreach ($hostFolder in $HostFolder) {
            $keys = Select-SetupServiceVmKey -StorageKind 'local' -DownloadAgentEnabled $true
            $v = Get-ServiceVmMemoryVerdict -Service (Get-PlanRow -Key $keys -From $hostFolder) -HostMemoryMb 32768
            Assert-Equal 'warn' $v.Level -Because "$hostFolder disagrees with the other host drivers about the same machine"
            Assert-Equal 'ok' (Get-ServiceVmMemoryVerdict -Service (Get-PlanRow -Key (Select-SetupServiceVmKey -StorageKind 'local') -From $hostFolder) -HostMemoryMb 32768).Level `
                -Because "$hostFolder disagrees about the default standalone set fitting the same machine"
        }
    }
}

Describe 'host-memory preflight -- this host answers for its own memory' {
    It 'reports a plausible installed size on the platform running the test' {
        $mb = Get-HostPhysicalMemoryMb
        Assert-True ($mb -gt 0) 'macOS, Linux and Windows all state installed memory; 0 here means the reading broke'
        Assert-True ($mb -ge 1024) "implausibly small: $mb MB"
        Assert-True ($mb -le 8388608) "implausibly large: $mb MB"
    }
}

Describe 'host-memory preflight -- setup.ps1 spends it before it builds anything' {
    It 'imports the module the arithmetic lives in' {
        Assert-True ($SetupSrc -match [regex]::Escape("automation/Yuruna.Common.psm1")) `
            'Yuruna.HostRedirect imports Yuruna.Common into its own session state, which does not reach setup.ps1'
    }
    It 'names memory in the preflight step, so a skipped check is visible in the outcome list' {
        Assert-True ($SetupSrc -match "Invoke-SetupStep -Name 'Preflight:[^']*memory[^']*'") 'the step name must say what it checked'
    }
    It 'runs the check inside the preflight, ahead of every service bring-up' {
        $calls = @($SetupAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Write-SetupMemoryHeadroom' }, $true))
        Assert-Equal 1 $calls.Count -Because 'exactly one call site'
        $bringUp = @($SetupAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Invoke-ServiceVMEnsure' }, $true) |
            Sort-Object { $_.Extent.StartLineNumber })
        Assert-True ($bringUp.Count -ge 1) 'fixture sanity: setup.ps1 brings up service VMs'
        Assert-True ($calls[0].Extent.StartLineNumber -lt $bringUp[0].Extent.StartLineNumber) `
            'a memory report after the first VM build is a report about a decision already made'
    }
    It 'passes the check the two answers that decide which services start' {
        $call = @($SetupAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Write-SetupMemoryHeadroom' }, $true))[0]
        $text = $call.Extent.Text
        Assert-True ($text -match '-StorageKind') 'without storage.kind it would bill a standalone host for services it never starts'
        Assert-True ($text -match '-Lab')         'without the lab answer it would miss the pool-control service'
    }
    It 'restates none of the builders numbers' {
        foreach ($literal in @('12288', '4096', '20480', '24576')) {
            Assert-True ($SetupSrc -notmatch "\b$literal\b") `
                "setup.ps1 hardcodes $literal -- a second copy of a guest size drifts the moment the builder changes"
        }
    }
    It 'warns and records the shortfall, and stays silent about what it could not measure' {
        $fn = $SetupAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Write-SetupMemoryHeadroom' }, $true) | Select-Object -First 1
        Assert-True ($null -ne $fn) 'Write-SetupMemoryHeadroom is defined in setup.ps1'
        $body = $fn.Extent.Text
        Assert-True ($body -match 'Write-SetupWarning')  'a shortfall the operator never sees is not a warning'
        Assert-True ($body -match 'Add-UnmetCondition')  'the closing report is where a warning from minute two is read again'
        Assert-True ($body -match 'Write-SetupVerbose')  'an unmeasurable host is a log note, not a warning about nothing'
        Assert-True ($body -match '(?s)catch\s*\{')      'this runs inside a Critical step: a fault in a REPORT must not end the run'
    }
    It 'accounts for every service VM setup.ps1 actually brings up, and invents none' {
        # Which services a run starts is setup policy, and Select-SetupServiceVmKey
        # is a second statement of it. A service added to the bring-up and not to
        # that rule leaves the memory bill short by a whole guest, silently and in
        # exactly the direction that makes a host look fine when it is not. The
        # roster keys are what the two statements have in common, so they are what
        # is compared.
        $rosterKey = @($SetupAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Invoke-ServiceVMEnsure' }, $true) | ForEach-Object {
                $elements = $_.CommandElements
                for ($i = 0; $i -lt ($elements.Count - 1); $i++) {
                    if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $elements[$i].ParameterName -eq 'RosterKey') { [string]$elements[$i + 1].Value }
                }
            } | Sort-Object -Unique)
        Assert-True ($rosterKey.Count -ge 1) 'fixture sanity: setup.ps1 names its service VMs with -RosterKey'
        $selectable = @($PlanSet | ForEach-Object { $_ } | Sort-Object -Unique)
        foreach ($key in $rosterKey) {
            Assert-True ($selectable -contains $key) `
                "setup.ps1 brings up the '$key' service VM and no Select-SetupServiceVmKey plan returns it -- the preflight would under-report the bill by that guest"
        }
        foreach ($key in $selectable) {
            Assert-True ($rosterKey -contains $key) `
                "Select-SetupServiceVmKey returns '$key' and setup.ps1 brings up no such service VM -- the preflight is charging for a guest that never starts"
        }
    }
    It 'reads downloadAgentService.enabled once, for both the report and the bring-up' {
        $calls = @($SetupAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-DownloadAgentServiceEnabledValue' }, $true))
        Assert-Equal 2 $calls.Count -Because 'two callers, one reading -- two readings could disagree about which services a run starts'
        $direct = @($SetupAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Value -eq 'downloadAgentService.enabled' }, $true))
        Assert-Equal 1 $direct.Count -Because 'the config key is named in exactly one place'
    }
}

<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42d90c17-58b4-4a3e-b6f1-9c2e70a4d835
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test setup dashboard hosts-alias pester
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
    Guards the standalone dashboard hosts alias and the URL setup.ps1 prints.
.DESCRIPTION
    The dashboard is the one address an operator types by hand and bookmarks,
    and it is a DHCP lease: without an alias the bookmark is wrong the next time
    the cache VM is rebuilt. The alias makes the name the durable part.

    Two properties are worth defending, and both are about not lying to the
    operator. The name is only offered once it actually resolves to this run's
    proxy -- a URL printed under a name nothing resolves reads as a broken
    install -- and the address is printed alongside it, because the moment the
    name IS the broken thing is exactly when the address is needed.

    The two functions are lifted out of setup.ps1 by AST and re-defined here, so
    these run the real implementations rather than a restatement of them.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.DashboardAlias.Tests.ps1
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$setupPs1 = Join-Path $repoRoot 'install/setup.ps1'

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-NoFinding {
    param([string[]]$Findings, [string]$Because = '')
    if ($Findings.Count -gt 0) { throw ("$Because`n  " + ($Findings -join "`n  ")) }
}

# File scope, above the first Describe: a Describe body is evaluated during
# discovery and its variables are gone before any It runs.
$SetupSource = Get-Content -Raw -LiteralPath $setupPs1
$parseErrors = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPs1, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "Parse errors in ${setupPs1}: $($parseErrors[0].Message)" }
foreach ($wanted in @('Test-DashboardAlias', 'Write-DashboardHint')) {
    $definition = @($setupAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "$wanted is not defined in $setupPs1" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Write-DashboardHint talks through Write-SetupMessage, which writes to the
# information stream and the run log. Capturing the stream is enough here, and
# it keeps the test out of the log file.
function Get-HintLine {
    param([string]$ProxyIp, [string]$AliasName = '')
    $out = Write-DashboardHint -ProxyIp $ProxyIp -AliasName $AliasName 6>&1
    return @($out | ForEach-Object { [string]$_ })
}
function Write-SetupMessage { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '') Write-Information $Message }

Describe 'the dashboard alias is only offered once it resolves' {

    It 'answers false for a name that resolves nowhere' {
        # A name no resolver knows is the ordinary state on a lab, and on a
        # standalone run whose alias step has not happened yet.
        Assert-Equal -Expected $false `
            -Actual (Test-DashboardAlias -Name 'yuruna-dash-does-not-exist.invalid' -ProxyIp '10.0.0.9') `
            -Because 'an unresolvable name must be a plain false, not a throw'
    }

    It 'answers false when either side is missing' {
        foreach ($case in @(
                @{ Name = ''; Ip = '10.0.0.9' },
                @{ Name = 'yuruna-dash'; Ip = '' },
                @{ Name = ''; Ip = '' })) {
            Assert-Equal -Expected $false -Actual (Test-DashboardAlias -Name $case.Name -ProxyIp $case.Ip) `
                -Because "Name='$($case.Name)' ProxyIp='$($case.Ip)' cannot be a match"
        }
    }

    It 'answers true when the name resolves to that address' {
        # localhost is the one name every platform resolves without a hosts-file
        # edit, so the match logic is exercised without touching a root-owned
        # file from a test.
        Assert-True (Test-DashboardAlias -Name 'localhost' -ProxyIp '127.0.0.1') `
            'localhost resolves to 127.0.0.1 on every supported platform'
    }

    It 'answers false when the name resolves somewhere else' {
        Assert-Equal -Expected $false -Actual (Test-DashboardAlias -Name 'localhost' -ProxyIp '10.99.99.99') `
            -Because 'a stale alias pointing at a rebuilt VM must not read as a match'
    }
}

Describe 'the dashboard URL setup prints' {

    It 'prints the address alone when no alias was published' {
        $lines = Get-HintLine -ProxyIp '10.0.0.9'
        $url = @($lines | Where-Object { $_ -match 'dashboard:' })
        Assert-Equal -Expected 1 -Actual $url.Count -Because 'exactly one dashboard line'
        Assert-True ($url[0] -match 'http://10\.0\.0\.9:3000/d/yuruna-pool/yuruna-hosts') `
            "want the address form, got: $($url[0])"
        Assert-Equal -Expected 0 -Actual @($lines | Where-Object { $_ -match 'yuruna-dash' }).Count `
            -Because 'a name this run did not publish must never be printed'
    }

    It 'leads with the alias and keeps the address alongside it' {
        $lines = Get-HintLine -ProxyIp '10.0.0.9' -AliasName 'yuruna-dash'
        $lead = @($lines | Where-Object { $_ -match 'dashboard:' })
        Assert-Equal -Expected 1 -Actual $lead.Count -Because 'exactly one dashboard line'
        Assert-True ($lead[0] -match 'http://yuruna-dash:3000/d/yuruna-pool/yuruna-hosts') `
            "the offered URL must use the alias, got: $($lead[0])"
        # The address is what an operator needs the moment the NAME is what is
        # wrong, which is precisely when they cannot look it up by name.
        Assert-True (@($lines | Where-Object { $_ -match 'http://10\.0\.0\.9:3000/d/yuruna-pool/yuruna-hosts' }).Count -eq 1) `
            'the address form must still be printed as the fallback'
    }

    It 'carries the port, because :80 on the proxy is Apache' {
        # Grafana is on :3000 and Apache owns :80 there, serving the CA certs a
        # guest installer fetches. A portless URL would reach Apache and 404.
        $findings = @()
        foreach ($lines in @((Get-HintLine -ProxyIp '10.0.0.9'), (Get-HintLine -ProxyIp '10.0.0.9' -AliasName 'yuruna-dash'))) {
            foreach ($l in @($lines | Where-Object { $_ -match '/d/yuruna-pool/yuruna-hosts' })) {
                if ($l -notmatch ':3000/d/') { $findings += "dashboard URL without :3000 -- $l" }
            }
        }
        Assert-NoFinding $findings 'the dashboard is not served on port 80'
    }

    It 'says nothing at all without a proxy address' {
        Assert-Equal -Expected 0 -Actual (Get-HintLine -ProxyIp '').Count `
            -Because 'no proxy means no dashboard to point at'
    }
}

Describe 'setup.ps1 publishes the alias where the proxy address is settled' {

    It 'names the alias once, and uses that one name everywhere' {
        Assert-True ($SetupSource -match "\`$Script:DashboardAliasName\s*=\s*'yuruna-dash'") `
            'the alias name must be defined once at script scope'
        # Anything that hard-codes the string again can drift from the published
        # name, and the failure is a URL that resolves nowhere.
        $literals = [regex]::Matches($SetupSource, "'yuruna-dash'").Count
        Assert-Equal -Expected 1 -Actual $literals `
            -Because 'the name belongs in one place; every other use reads $Script:DashboardAliasName'
    }

    It 'writes it only on a standalone run' {
        # A lab beacon's proxy is shared, and the other machines reach it through
        # vmStart.cachingProxyIp rather than a name each would have to publish.
        Assert-True ($SetupSource -match '(?s)if \(-not \$isLab\) \{\s*\r?\n\s*\[void\]\(Invoke-SetupStep -Name "Point the \$Script:DashboardAliasName alias') `
            'the alias step must be gated on a standalone run'
    }

    It 'writes it from the same proxy address the config key is set from' {
        # One freshly-read proxy state behind both, so the hosts entry and
        # vmStart.cachingProxyIp cannot come to disagree about where the proxy is.
        $configAt = $SetupSource.IndexOf('cachingProxyIp: $proxyIp')
        $aliasAt  = $SetupSource.IndexOf('Set-YurunaHostAlias -RepoRoot $RepoRoot -Name @($Script:DashboardAliasName) -IPAddress $proxyIp')
        Assert-True ($configAt -gt 0) 'the cachingProxyIp write must still exist'
        Assert-True ($aliasAt -gt 0) 'the alias must be written from $proxyIp'
        Assert-True ($aliasAt -gt $configAt) `
            'the alias step must follow the config write, where $proxyIp is already settled'
    }

    It 'reuses the shared elevated alias writer rather than editing the hosts file itself' {
        # The hosts file is root-owned on macOS and Linux and needs elevation on
        # Windows; a second copy of that dance is a second thing to get wrong.
        Assert-True ($SetupSource -match 'Set-YurunaHostAlias') 'the alias must go through the shared writer'
        $module = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.LocalLabStorage.psm1')
        Assert-True ($module -match 'function Set-YurunaHostAlias') 'Set-YurunaHostAlias must exist in the module'
        Assert-True ($module -match 'Set-YurunaHostAlias,') 'Set-YurunaHostAlias must be exported'
        # The storage aliases keep working through the same writer, supplying
        # loopback because those names ARE this machine.
        Assert-True ($module -match '(?s)function Set-LocalLabStorageHostAlias.*?Set-YurunaHostAlias -RepoRoot \$RepoRoot -Name \$Name -IPAddress \$script:LoopbackAddress') `
            'the storage alias writer must delegate to the shared one'
    }
}

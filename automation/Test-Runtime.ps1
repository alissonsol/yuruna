<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42716d16-84b0-4329-82d3-c96aec139664
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    A developer toolset for cross-cloud Kubernetes-based applications - Check runtime.

    .DESCRIPTION
    Check all conditions needed to deploy the Kubernetes examples:
    Docker running and healthy, kubectl connected to cluster, cluster healthy,
    and mkcert local CA installed. Reports problems with suggested solutions,
    or lists Docker images and running containers when everything is healthy.

    .PARAMETER logLevel
    One of Error|Warning|Information|Verbose|Debug. Each level shows
    itself + all higher-priority streams (Error highest). Default 'Error'.

    .INPUTS
    None.

    .OUTPUTS
    Runtime status output.

    .EXAMPLE
    C:\PS> Test-Runtime.ps1
    Check all conditions needed to deploy the Kubernetes examples.

    .LINK
    Online version: https://yuruna.com
#>

param (
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel='Error'
)

# logLevel cascade: shared by every automation entrypoint (see Yuruna.LogLevel.psm1).
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

$problems = [System.Collections.Generic.List[string]]::new()

function Get-ToolProbeOutput {
    <#
    .SYNOPSIS
        Run a tool's version/query probe and return its first output line, or
        $null when the tool is missing, not executable, or answers nothing.
    .DESCRIPTION
        A binary can be on PATH and still not run. A zero-length file carrying the
        +x bit -- a truncated download, or a write lost to a crash-consistent VM
        snapshot -- satisfies Get-Command, and bash even executes it as an empty
        script (exit 0, no output), so shell-side probes call it healthy.
        PowerShell execve()s it directly and raises a ResourceUnavailable "Exec
        format error", which without this catch escapes as a raw exception rather
        than a diagnosed problem. Treat "no output" as "not usable": every tool
        probed here prints something when it works.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$ToolArgs
    )
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) { return $null }
    try {
        $out = & $Name @ToolArgs 2>$null
    } catch {
        Write-Verbose "Probe '$Name $ToolArgs' failed to run: $($_.Exception.Message)"
        return $null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    $first = @($out) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ($null -eq $first) { return $null }
    return ([string]$first).Trim()
}

# 1. Docker -- running and healthy
Write-Verbose "Checking Docker..."
# Confirm the binary exists before trusting $LASTEXITCODE: a missing native command raises
# CommandNotFound without updating $LASTEXITCODE, so a stale exit code from an earlier step
# could otherwise be read as a passing verdict.
if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerExit = 127
} else {
    $null = docker info 2>&1
    $dockerExit = $LASTEXITCODE
}
if ($dockerExit -ne 0) {
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_82c987150223392e'))
    if ($IsWindows) {
        $dockerDesktopExe = $null
        $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
        if ($dockerCmd) {
            # docker.exe at ...\Docker\Docker\resources\bin\docker.exe,
            # Docker Desktop.exe at ...\Docker\Docker\Docker Desktop.exe
            $candidate = Join-Path ($dockerCmd.Source | Split-Path | Split-Path | Split-Path) "Docker Desktop.exe"
            if (Test-Path $candidate) { $dockerDesktopExe = $candidate }
        }
        if (-not $dockerDesktopExe) {
            $candidate = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
            if (Test-Path $candidate) { $dockerDesktopExe = $candidate }
        }
        if ($dockerDesktopExe) {
            $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_00dc7c766802c16f'))
            $problems.Add("       Start-Process '$dockerDesktopExe'")
        } else {
            $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_a6a3fec0977d82a0'))
        }
    } elseif ($IsLinux) {
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_039d15ebf558f3cc'))
        $problems.Add("       sudo systemctl start docker")
    } else {
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_1b15bdf8fde492ca'))
        $problems.Add("       open -a Docker")
    }
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_538dbbedc6313351'))
} else {
    Write-Verbose "Docker is running and healthy."
}

# 2. Kubectl -- available and able to connect to the cluster
Write-Verbose "Checking kubectl..."
if ($null -eq (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    $kubectlVersionExit = 127
} else {
    $null = kubectl version --client 2>&1
    $kubectlVersionExit = $LASTEXITCODE
}
if ($kubectlVersionExit -ne 0) {
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_5916ef3813bf8149'))
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_9da6aea5b3ca9c8c'))
} else {
    $null = kubectl cluster-info 2>&1
    if ($LASTEXITCODE -ne 0) {
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_d2d4c3349fa9c41f'))
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_ee5948b70f314800'))
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_81c43d658d161aa5'))
        if ($IsLinux) {
            if (Get-Command swapon -ErrorAction SilentlyContinue) {
                $swapInfo = swapon --show 2>&1
                if (-not [string]::IsNullOrWhiteSpace($swapInfo)) {
                    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_acf06d0797fb527b'))
                    $problems.Add("       sudo swapoff -a")
                    $problems.Add("       sudo systemctl restart kubelet")
                }
            }
            if (Get-Command systemctl -ErrorAction SilentlyContinue) {
                $kubeletStatus = systemctl is-active kubelet 2>&1
                if ($kubeletStatus -ne "active") {
                    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_250f4d20840b7daf'))
                    $problems.Add("       sudo systemctl start kubelet")
                }
            }
        }
    } else {
        Write-Verbose "kubectl is connected to the cluster."
    }
}

# 3. Kubernetes cluster -- healthy nodes
Write-Verbose "Checking Kubernetes cluster health..."
if ($problems | Where-Object { $_ -like "KUBECTL:*" }) {
    Write-Verbose "Skipping cluster health check because kubectl is not connected."
} else {
    $nodeLines = @(kubectl get nodes --no-headers 2>&1 | Where-Object { $_ -ne "" })
    if ($LASTEXITCODE -ne 0) {
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_c1183a01da877148'))
        foreach ($line in $nodeLines) { $problems.Add("  $line") }
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_60108482ffac31eb'))
    } else {
        # Error lines must not be filtered out (filtering them hides failures) and zero nodes
        # must not count as healthy: require at least one Ready node. `\bReady\b` matches
        # "Ready" but not "NotReady".
        $readyNodes    = @($nodeLines | Where-Object { $_ -match "\bReady\b" })
        $notReadyNodes = @($nodeLines | Where-Object { $_ -notmatch "\bReady\b" })
        if ($readyNodes.Count -eq 0) {
            $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_8deabd038eb2770d'))
            foreach ($line in $nodeLines) { $problems.Add("  $line") }
            $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_9a08e978373feffe'))
        } elseif ($notReadyNodes.Count -gt 0) {
            $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_6b21049f8cccfe28'))
            foreach ($line in $notReadyNodes) { $problems.Add("  $line") }
            $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_4c8c5980fef3a417'))
            $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_b2776f3a9666e4d4'))
        } else {
            Write-Verbose "All Kubernetes nodes are Ready."
        }
    }
}

# 4. helm -- installed and runnable. Every chart deployment in Set-Workload
# shells out to it, so a helm that cannot run means nothing will deploy.
Write-Verbose "Checking helm..."
$helmVersion = Get-ToolProbeOutput -Name 'helm' -ToolArgs @('version', '--short')
if ([string]::IsNullOrWhiteSpace($helmVersion)) {
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_87bba5430b63c2ef'))
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_72e28a58e0301f9b'))
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_1cb63907b21a7688'))
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_3bc6d2f5edbf00c0'))
} else {
    Write-Verbose "helm is runnable: $helmVersion"
}

# 5. mkcert -- installed, runnable, and its local CA present and non-empty
Write-Verbose "Checking mkcert local CA..."
$caRoot = Get-ToolProbeOutput -Name 'mkcert' -ToolArgs @('-CAROOT')
if ([string]::IsNullOrWhiteSpace($caRoot)) {
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_d522efedd63f0b44'))
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_f147ac8566432a50'))
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_a102b702035dd928'))
    $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_b5e24639de15386d'))
} else {
    $caPem = Join-Path $caRoot "rootCA.pem"
    $caItem = Get-Item -LiteralPath $caPem -ErrorAction SilentlyContinue
    if (-not $caItem) {
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_b77f5899ba9b851a' -Arguments @{ caPem = "$caPem" }))
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_dd0de2a2eaf244da'))
    } elseif ($caItem.Length -eq 0) {
        # An existing-but-empty CA passes a bare Test-Path, then fails later as an
        # unexplained TLS error in the ingress. Same lost-write class as the
        # zero-length binaries above.
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_a447c115b0de3b93' -Arguments @{ caPem = "$caPem" }))
        $problems.Add((Format-YurunaOperatorMessage -Key 'automation.operator_dd0de2a2eaf244da'))
    } else {
        Write-Verbose "mkcert local CA is installed at: $caRoot"
    }
}

if ($problems.Count -gt 0) {
    # The failing verdict goes to the ERROR stream, not Information: the deploy
    # entrypoints call this with the default logLevel ('Error'), which silences
    # Information AND Warning, so a problem reported there prints nothing and a
    # runtime fault (broken tool, unreachable cluster) becomes a deploy that
    # silently does nothing. The logLevel cascade leaves $ErrorActionPreference
    # at 'Continue' precisely so errors stay visible at every level.
    $report = @("", "== Runtime Check: PROBLEMS FOUND ==") + $problems + @("")
    Write-Error ($report -join [Environment]::NewLine)
    return $false
}

Write-Information ""
Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_c5d7264ec6630cba')
Write-Information ""

Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_142e2f906a880a91')
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}"
Write-Information ""

Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_64cf72692732e576')
docker ps --all --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
Write-Information ""

return $true

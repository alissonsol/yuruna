<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a7b8c9-d0e1-4f23-4567-8a9b0c112435
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
        format error", which without this catch escapes as a raw exception
        instead of a diagnosed problem. Treat "no output" as "not usable": every
        tool probed here prints something when it works.
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
    $problems.Add("DOCKER: Docker is not running or is unhealthy.")
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
            $problems.Add("  -> Start Docker Desktop on Windows:")
            $problems.Add("       Start-Process '$dockerDesktopExe'")
        } else {
            $problems.Add("  -> Start Docker Desktop on Windows (not found in the default location).")
        }
    } elseif ($IsLinux) {
        $problems.Add("  -> Start Docker on Linux:")
        $problems.Add("       sudo systemctl start docker")
    } else {
        $problems.Add("  -> Start Docker Desktop on macOS:")
        $problems.Add("       open -a Docker")
    }
    $problems.Add("  -> Then retry this check.")
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
    $problems.Add("KUBECTL: kubectl is not installed or not in PATH.")
    $problems.Add("  -> Install kubectl: https://kubernetes.io/docs/tasks/tools/")
} else {
    $null = kubectl cluster-info 2>&1
    if ($LASTEXITCODE -ne 0) {
        $problems.Add("KUBECTL: kubectl cannot connect to the Kubernetes cluster.")
        $problems.Add("  -> Verify your kubeconfig with: kubectl config view")
        $problems.Add("  -> If using Docker Desktop, enable Kubernetes in Docker Desktop settings.")
        if ($IsLinux) {
            if (Get-Command swapon -ErrorAction SilentlyContinue) {
                $swapInfo = swapon --show 2>&1
                if (-not [string]::IsNullOrWhiteSpace($swapInfo)) {
                    $problems.Add("  -> Swap is ON. Kubernetes requires swap to be disabled:")
                    $problems.Add("       sudo swapoff -a")
                    $problems.Add("       sudo systemctl restart kubelet")
                }
            }
            if (Get-Command systemctl -ErrorAction SilentlyContinue) {
                $kubeletStatus = systemctl is-active kubelet 2>&1
                if ($kubeletStatus -ne "active") {
                    $problems.Add("  -> kubelet is not active. Try:")
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
        $problems.Add("CLUSTER: Could not retrieve node status.")
        foreach ($line in $nodeLines) { $problems.Add("  $line") }
        $problems.Add("  -> Run 'kubectl get nodes' manually to investigate.")
    } else {
        # Error lines must not be filtered out (filtering them hides failures) and zero nodes
        # must not count as healthy: require at least one Ready node. `\bReady\b` matches
        # "Ready" but not "NotReady".
        $readyNodes    = @($nodeLines | Where-Object { $_ -match "\bReady\b" })
        $notReadyNodes = @($nodeLines | Where-Object { $_ -notmatch "\bReady\b" })
        if ($readyNodes.Count -eq 0) {
            $problems.Add("CLUSTER: No Ready nodes reported.")
            foreach ($line in $nodeLines) { $problems.Add("  $line") }
            $problems.Add("  -> Run 'kubectl get nodes' manually; the cluster reports no schedulable nodes.")
        } elseif ($notReadyNodes.Count -gt 0) {
            $problems.Add("CLUSTER: One or more nodes are not in Ready state:")
            foreach ($line in $notReadyNodes) { $problems.Add("  $line") }
            $problems.Add("  -> Run 'kubectl describe node <node-name>' for details.")
            $problems.Add("  -> On Linux, check: sudo systemctl status kubelet")
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
    $problems.Add("HELM: helm is missing, or is present but not runnable (a zero-length or corrupt binary).")
    $problems.Add("  -> Chart deployments cannot run without it.")
    $problems.Add("  -> Check with: ls -l `$(command -v helm); helm version --short")
    $problems.Add("  -> Reinstall helm: https://helm.sh/docs/intro/install/")
} else {
    Write-Verbose "helm is runnable: $helmVersion"
}

# 5. mkcert -- installed, runnable, and its local CA present and non-empty
Write-Verbose "Checking mkcert local CA..."
$caRoot = Get-ToolProbeOutput -Name 'mkcert' -ToolArgs @('-CAROOT')
if ([string]::IsNullOrWhiteSpace($caRoot)) {
    $problems.Add("MKCERT: mkcert is missing, or is present but not runnable (a zero-length or corrupt binary).")
    $problems.Add("  -> Check with: ls -l `$(command -v mkcert); mkcert -version")
    $problems.Add("  -> Install mkcert: https://github.com/FiloSottile/mkcert/releases")
    $problems.Add("  -> After installing, run: mkcert -install")
} else {
    $caPem = Join-Path $caRoot "rootCA.pem"
    $caItem = Get-Item -LiteralPath $caPem -ErrorAction SilentlyContinue
    if (-not $caItem) {
        $problems.Add("MKCERT: Local CA certificate not found at: $caPem")
        $problems.Add("  -> Run (may require elevated privileges): mkcert -install")
    } elseif ($caItem.Length -eq 0) {
        # An existing-but-empty CA passes a bare Test-Path, then fails later as an
        # unexplained TLS error in the ingress. Same lost-write class as the
        # zero-length binaries above.
        $problems.Add("MKCERT: Local CA certificate at $caPem is zero-length.")
        $problems.Add("  -> Run (may require elevated privileges): mkcert -install")
    } else {
        Write-Verbose "mkcert local CA is installed at: $caRoot"
    }
}

if ($problems.Count -gt 0) {
    # The failing verdict goes to the ERROR stream, not Information. The deploy
    # entrypoints call this with the default logLevel ('Error'), which silences
    # Information AND Warning -- a pre-flight that reported its problems there
    # printed nothing at all, so a runtime fault (a broken tool, an unreachable
    # cluster) became a deploy that silently did nothing. $ErrorActionPreference
    # is left at 'Continue' by the logLevel cascade precisely so errors stay
    # visible at every level; this is an error.
    $report = @("", "== Runtime Check: PROBLEMS FOUND ==") + $problems + @("")
    Write-Error ($report -join [Environment]::NewLine)
    return $false
}

Write-Information ""
Write-Information "== Runtime Check: ALL OK =="
Write-Information ""

Write-Information "-- Docker images --"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}"
Write-Information ""

Write-Information "-- Running containers (all) --"
docker ps --all --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
Write-Information ""

return $true

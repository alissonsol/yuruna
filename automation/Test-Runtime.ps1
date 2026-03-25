<#PSScriptInfo
.VERSION 0.1
.GUID 42a7b8c9-d0e1-4f23-4567-8a9b0c112435
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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

    .PARAMETER debug_mode
    Set to $true to see debug messages.

    .PARAMETER verbose_mode
    Set to $true to see verbose messages.

    .INPUTS
    None.

    .OUTPUTS
    Runtime status output.

    .EXAMPLE
    C:\PS> Test-Runtime.ps1
    Check all conditions needed to deploy the Kubernetes examples.

    .LINK
    Online version: http://www.yuruna.com
#>

param (
    [bool]$debug_mode=$false,
    [bool]$verbose_mode=$false
)

$global:InformationPreference = "Continue"
$global:DebugPreference   = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"
if ($true -eq $debug_mode)   { $global:DebugPreference   = "Continue" }
if ($true -eq $verbose_mode) { $global:VerbosePreference = "Continue" }

$problems = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------
# 1. Docker — running and healthy
# ---------------------------------------------------------------------------
Write-Verbose "Checking Docker..."
$null = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    $problems.Add("DOCKER: Docker is not running or is unhealthy.")
    if ($IsWindows) {
        $dockerDesktopExe = $null
        $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
        if ($dockerCmd) {
            # docker.exe is typically at ...\Docker\Docker\resources\bin\docker.exe
            # Docker Desktop.exe is at ...\Docker\Docker\Docker Desktop.exe
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

# ---------------------------------------------------------------------------
# 2. Kubectl — available and able to connect to the cluster
# ---------------------------------------------------------------------------
Write-Verbose "Checking kubectl..."
$null = kubectl version --client 2>&1
if ($LASTEXITCODE -ne 0) {
    $problems.Add("KUBECTL: kubectl is not installed or not in PATH.")
    $problems.Add("  -> Install kubectl: https://kubernetes.io/docs/tasks/tools/")
} else {
    $null = kubectl cluster-info 2>&1
    if ($LASTEXITCODE -ne 0) {
        $problems.Add("KUBECTL: kubectl cannot connect to the Kubernetes cluster.")
        $problems.Add("  -> Verify your kubeconfig with: kubectl config view")
        $problems.Add("  -> If using Docker Desktop, enable Kubernetes in Docker Desktop settings.")
        if ($IsLinux) {
            $swapInfo = swapon --show 2>&1
            if (-not [string]::IsNullOrWhiteSpace($swapInfo)) {
                $problems.Add("  -> Swap is ON. Kubernetes requires swap to be disabled:")
                $problems.Add("       sudo swapoff -a")
                $problems.Add("       sudo systemctl restart kubelet")
            }
            $kubeletStatus = systemctl is-active kubelet 2>&1
            if ($kubeletStatus -ne "active") {
                $problems.Add("  -> kubelet is not active. Try:")
                $problems.Add("       sudo systemctl start kubelet")
            }
        }
    } else {
        Write-Verbose "kubectl is connected to the cluster."
    }
}

# ---------------------------------------------------------------------------
# 3. Kubernetes cluster — healthy nodes
# ---------------------------------------------------------------------------
Write-Verbose "Checking Kubernetes cluster health..."
if ($problems | Where-Object { $_ -like "KUBECTL:*" }) {
    Write-Verbose "Skipping cluster health check because kubectl is not connected."
} else {
    $notReadyNodes = kubectl get nodes --no-headers 2>&1 | Where-Object { $_ -notmatch "\bReady\b" -and $_ -notmatch "^error" -and $_ -ne "" }
    if ($LASTEXITCODE -ne 0) {
        $problems.Add("CLUSTER: Could not retrieve node status.")
        $problems.Add("  -> Run 'kubectl get nodes' manually to investigate.")
    } elseif ($notReadyNodes) {
        $problems.Add("CLUSTER: One or more nodes are not in Ready state:")
        foreach ($line in $notReadyNodes) {
            $problems.Add("  $line")
        }
        $problems.Add("  -> Run 'kubectl describe node <node-name>' for details.")
        $problems.Add("  -> On Linux, check: sudo systemctl status kubelet")
    } else {
        Write-Verbose "All Kubernetes nodes are Ready."
    }
}

# ---------------------------------------------------------------------------
# 4. mkcert — local CA installed
# ---------------------------------------------------------------------------
Write-Verbose "Checking mkcert local CA..."
$mkcertAvailable = $null -ne (Get-Command mkcert -ErrorAction SilentlyContinue)
if (-not $mkcertAvailable) {
    $problems.Add("MKCERT: mkcert is not installed or not in PATH.")
    $problems.Add("  -> Install mkcert: https://github.com/FiloSottile/mkcert/releases")
    $problems.Add("  -> After installing, run: mkcert -install")
} else {
    # mkcert -CAROOT returns the CA root directory; check that rootCA.pem exists there
    $caRoot = mkcert -CAROOT 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($caRoot)) {
        $problems.Add("MKCERT: Could not determine mkcert CA root directory.")
        $problems.Add("  -> Run: mkcert -install")
    } else {
        $caRoot = $caRoot.Trim()
        $caPem  = Join-Path $caRoot "rootCA.pem"
        if (-not (Test-Path $caPem)) {
            $problems.Add("MKCERT: Local CA certificate not found at: $caPem")
            $problems.Add("  -> Run (may require elevated privileges): mkcert -install")
        } else {
            Write-Verbose "mkcert local CA is installed at: $caRoot"
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if ($problems.Count -gt 0) {
    Write-Information ""
    Write-Information "== Runtime Check: PROBLEMS FOUND =="
    foreach ($msg in $problems) {
        Write-Information $msg
    }
    Write-Information ""
    return $false
}

Write-Information ""
Write-Information "== Runtime Check: ALL OK =="
Write-Information ""

# ---------------------------------------------------------------------------
# List Docker images
# ---------------------------------------------------------------------------
Write-Information "-- Docker images --"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}"
Write-Information ""

# ---------------------------------------------------------------------------
# List all running containers (including system / infrastructure ones)
# ---------------------------------------------------------------------------
Write-Information "-- Running containers (all) --"
docker ps --all --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
Write-Information ""

return $true

# Adds the 'automation' subfolder of this repository to the current session's PATH.
$repoRoot = git rev-parse --show-toplevel
$automationPath = Join-Path $repoRoot "automation"

if (-not (Test-Path $automationPath)) {
    Write-Error "Automation folder not found: $automationPath"
    return
}

if ($env:PATH -split [IO.Path]::PathSeparator -notcontains $automationPath) {
    $env:PATH = $automationPath + [IO.Path]::PathSeparator + $env:PATH
    Write-Host "Added to PATH: $automationPath"
} else {
    Write-Host "Already in PATH: $automationPath"
}

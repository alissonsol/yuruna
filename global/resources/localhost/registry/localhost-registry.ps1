<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42039415-c637-4845-b678-9012f7081920
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Idempotent: the baseline ubuntu.server.workload.k8s.website.sh) starts a
# registry container BEFORE invoking Set-Resource.ps1 so the image pull
# can exit loudly with rate-limit diagnostics.
#
# Branch: start the existing container if present (no-op if already
# running), else create a fresh one. Either path leaves a working
# registry listening on :5000 and tofu's provisioner succeeds, so the
# output blocks populate normally.
#
$existing = docker ps -a --filter 'name=^registry$' --format '{{.Names}}' 2>$null
if ($existing -eq 'registry') {
    docker start registry 2>$null | Out-Null
} else {
    docker run -d -p 5000:5000 --restart always --name registry registry:latest
}
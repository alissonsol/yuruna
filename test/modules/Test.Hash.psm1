<#PSScriptInfo
.VERSION 2026.07.10
.GUID 429a379b-7c9a-4161-901c-8b2f50b06936
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hash hex util
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

# Leaf utility module: byte-array -> hex encoding shared across the test harness.
# It has no dependencies and holds no module state, so a `-Force -Global` re-import
# (the codebase idiom for a consumer to pull in a dependency) is a pure no-op with
# no cache to reset -- which is why the SHA-256->hex converter lives here instead of
# in a stateful module like Test.Config.

<#
.SYNOPSIS
    Lowercase hex string of a byte array (e.g. a SHA-256 digest).
.DESCRIPTION
    One converter so the hash-to-hex encoding stays consistent across the
    content-hash cache key, the snapshot-slot filename tag, the perf
    sidecar tag, and the OCR source-hash key.
#>
function ConvertTo-LowerHex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return ([System.BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

Export-ModuleMember -Function ConvertTo-LowerHex

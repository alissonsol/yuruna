<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42b8e1f4-7c2a-4d09-8e3b-1a5c9f0d2e64
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

# Variable substitution for sequence step text: ${var} placeholders and
# ${ext:area.Method(args)} extension expressions. Extracted from the engine so
# the engine's by-name calls AND the verb Handlers -- which receive
# Expand-Variable as the ${function:Expand-Variable} scriptblock ref through the
# step Context -- share one definition. Test.Extension is imported lazily inside
# Invoke-ExtensionExpression, so it travels with the function; no top-level
# import is needed here.
# Private-use Unicode codepoint used as the placeholder for `$` after the
# $$ → sentinel pre-pass and before the sentinel → $ post-pass. The
# Unicode private-use area (U+E000–U+F8FF) is reserved for application-
# specific use and effectively never appears in legitimate input, so it
# is safe to round-trip through the regex pass without colliding with
# something a user actually typed.
$script:DollarSentinel = [char]0xE000

# ${ext:area.Method(arg1, arg2, ...)} -- inline expression form. ArgList
# may include nested ${var} placeholders, which are expanded BEFORE the
# extension is invoked. Each call is dispatched fresh -- there is no
# caching, so ${ext:authentication.NewRandomPassword()} returns a new
# value every time it is evaluated. Side-effecting calls
# (e.g. Set-Password) still belong in the dedicated `callExtension`
# action; ${ext:...} is for value-producing reads. Parameter is named
# ArgList (not Args) because $Args is a PowerShell automatic variable.
function Invoke-ExtensionExpression {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Method,
        [string[]]$ArgList = @()
    )
    $loaderPath = Join-Path $PSScriptRoot 'Test.Extension.psm1'
    if (Test-Path $loaderPath) {
        Import-Module $loaderPath -Global -Force -Verbose:$false
    }
    $names = @(Get-ActiveExtensionName -Area $Area)
    $extName = $names[0]
    [void](Import-Extension -Area $Area)
    $cmd = Resolve-ExtensionMethod -Area $Area -ExtensionName $extName -Method $Method
    if ($ArgList.Count -eq 0) { return (& $cmd) }
    return (& $cmd @ArgList)
}

# Resolves `${ext:area.Method(arg1, arg2)}` occurrences in $Text. Nested
# `${var}` inside args are expanded first, then the call is invoked
# fresh on every match. Plain `${var}` substitution remains the
# responsibility of the surrounding regex pass.
function Expand-ExtensionExpression {
    param([string]$Text, [hashtable]$Variables)
    if (-not $Text -or -not $Text.Contains('${ext:')) { return $Text }
    # Pre-materialize the variable map keys for the MatchEvaluator closure
    # below -- the analyzer cannot see references through [regex]::Replace's
    # scriptblock, so binding $vars here keeps the parameter explicitly used.
    $vars = $Variables
    $sentinel = $script:DollarSentinel
    $pattern = '\$\{ext:([A-Za-z0-9_]+)\.([A-Za-z][A-Za-z0-9_-]*)\(([^)]*)\)\}'
    return [regex]::Replace($Text, $pattern, {
        param($m)
        $area    = $m.Groups[1].Value
        $method  = $m.Groups[2].Value
        $rawArgs = $m.Groups[3].Value
        $argList = @()
        if ($rawArgs.Trim() -ne '') {
            foreach ($raw in ($rawArgs -split ',')) {
                $a = $raw.Trim()
                # Expand inner ${var} so e.g. ${ext:authentication.GetPassword(${username})}
                # resolves to GetPassword('yauser1') before the call.
                foreach ($key in $vars.Keys) {
                    $a = $a -replace [regex]::Escape("`${$key}"), $vars[$key]
                }
                # Restore any $$ escapes the caller had in the arg text
                # so the extension sees the user's intended literal `$`,
                # not the internal sentinel.
                $argList += $a.Replace($sentinel, '$')
            }
        }
        return [string](Invoke-ExtensionExpression -Area $area -Method $method -ArgList $argList)
    })
}

function Expand-Variable {
    param([string]$Text, [hashtable]$Variables)
    if ($null -eq $Text) { return $Text }
    # Escape pass: $$ → sentinel hides escaped dollars from both the
    # ${ext:...} regex and the ${var} text replacement below. The
    # closing sentinel → $ pass at the end restores them. So $${foo}
    # survives as literal "${foo}", and $$$${foo} survives as "$${foo}".
    $result = $Text.Replace('$$', $script:DollarSentinel)
    # ${ext:...} expressions are resolved first so any ${var} placeholders
    # inside their args see the current Variables table.
    $result = Expand-ExtensionExpression -Text $result -Variables $Variables
    # [string]::Replace is literal substitution -- no regex compile, no
    # [regex]::Escape needed for $key, no $1-backreference surprise from
    # -replace if a Variables value contained dollar-digit text.
    foreach ($key in $Variables.Keys) {
        $result = $result.Replace("`${$key}", [string]$Variables[$key])
    }
    # Restore $$ escapes.
    return $result.Replace($script:DollarSentinel, '$')
}

Export-ModuleMember -Function Expand-Variable, Expand-ExtensionExpression, Invoke-ExtensionExpression
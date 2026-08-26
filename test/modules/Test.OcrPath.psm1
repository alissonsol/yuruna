<#PSScriptInfo
.VERSION 2026.08.25
.GUID 422a0a3f-565d-4bf4-a26d-438b393c841e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ocr path util
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

# ConvertTo-LowerHex (SHA-256 -> lowercase-hex) lives in the leaf Test.Hash module
# so the byte[] -> hex encode has one definition across the harness.
Import-Module (Join-Path $PSScriptRoot 'Test.Hash.psm1') -Global -Force

<#
.SYNOPSIS
    Hands a native OCR engine an image path it can actually open.

.DESCRIPTION
    Leaf utility module: no harness dependencies beyond the hex converter and
    no module state, so a `-Force -Global` re-import is a pure no-op. Both the
    tesseract module and the WinRT provider in Test.OcrEngine route their image
    paths through here, which is why it cannot live in either of them.
#>

# Windows passes a path of 260 characters or more to a process only when that
# process is manifested long-path aware. The OCR engines are native and are not:
# tesseract's reader answers "cannot read input file ... No such file or
# directory" and WinRT's StorageFile.GetFileFromPathAsync throws, both for a file
# that is plainly on disk. .NET *is* long-path aware, so PowerShell's own
# Test-Path, Get-VMScreenshot and Copy-Item over the same path all succeed --
# which is what makes this quiet. Every guard the harness can write in PowerShell
# passes and only the engine at the end of the chain cannot open the file, so the
# capture is written, confirmed present, and then read as a blank screen.
#
# MAX_PATH counts the terminating NUL, so 259 characters is the longest path
# those engines accept and 260 is the first they refuse. The trigger is that
# boundary rather than a margin below it: the engines are handed the capture and
# read it to stdout, never deriving a longer name from it, and a margin would
# copy paths that are demonstrably readable -- on every poll, for every frame.
$script:NativePathCeiling = 260

function Test-OcrPathBeyondNativeCeiling {
    <#
    .SYNOPSIS
        True when a native OCR engine would refuse to open this path.
    .PARAMETER Path
        The absolute path the engine would be handed.
    .PARAMETER WindowsHost
        Defaults to the running platform. Named rather than read from $IsWindows
        directly so the question a Windows reader faces can be asked from any
        platform -- the ceiling is a Windows rule, and a check that can only run
        on Windows is a check that goes unrun until it fails in a lab.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [bool]$WindowsHost = $IsWindows
    )
    if (-not $WindowsHost) { return $false }
    return ([string]$Path).Length -ge $script:NativePathCeiling
}

function Resolve-OcrImagePath {
    <#
    .SYNOPSIS
        Absolute image path a native OCR engine can open, copying the capture to
        a short temporary path when the real one is past the native ceiling.
    .DESCRIPTION
        Returns a handle rather than a bare string: a caller that receives a copy
        owns it and must hand the handle back to Clear-OcrImagePath. Where the
        engine can already open the file -- every non-Windows platform, and any
        Windows path under the ceiling -- no copy is made and the handle carries
        the original path, so the common case costs one length comparison.
    .PARAMETER ImagePath
        Path to the capture the engine is about to read.
    .OUTPUTS
        [hashtable] @{ Path = <path to hand the engine>; IsCopy = [bool] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$ImagePath)

    $abs = (Resolve-Path -LiteralPath $ImagePath).Path
    if (-not (Test-OcrPathBeyondNativeCeiling -Path $abs)) {
        return @{ Path = $abs; IsCopy = $false }
    }

    # Named from the source path, so repeated OCR of one capture reuses a single
    # temp file: a process killed before its cleanup runs then leaves one stale
    # copy per captured file instead of one per poll.
    $key = (ConvertTo-LowerHex (
        [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes($abs)
        )
    )).Substring(0, 16)
    $short = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ocr-$key" + [System.IO.Path]::GetExtension($abs))
    try {
        Copy-Item -LiteralPath $abs -Destination $short -Force -ErrorAction Stop
    } catch {
        # Hand back the original. The engine will probably fail on it too, but it
        # fails with its own diagnostic naming the capture the operator can find,
        # rather than a temp path that no longer exists by the time they look.
        Write-Verbose "Resolve-OcrImagePath: short-path copy failed ($($_.Exception.Message)); using the original path."
        return @{ Path = $abs; IsCopy = $false }
    }
    return @{ Path = $short; IsCopy = $true }
}

function Clear-OcrImagePath {
    <#
    .SYNOPSIS
        Deletes the temporary copy a Resolve-OcrImagePath handle owns, if any.
    .DESCRIPTION
        Safe to call with a handle that carries the original path, and safe to
        call twice; both are no-ops. Deliberately silent on failure -- a temp
        file that outlives its poll is overwritten by the next OCR of the same
        capture, and a cleanup error must never become the error the caller
        reports for the OCR itself.
    .PARAMETER Handle
        The hashtable returned by Resolve-OcrImagePath.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Handle)
    if (-not $Handle -or -not $Handle.IsCopy) { return }
    Remove-Item -LiteralPath ([string]$Handle.Path) -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Test-OcrPathBeyondNativeCeiling, Resolve-OcrImagePath, Clear-OcrImagePath

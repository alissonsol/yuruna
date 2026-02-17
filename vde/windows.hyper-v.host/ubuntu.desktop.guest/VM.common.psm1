<#PSScriptInfo
.VERSION 0.1
.GUID 42c0ffee-b1df-4f20-a3c4-d5e6f7a8b9c0
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# --- Define Oscdimg Path (adjust '10' for your ADK version if necessary) ---
$OscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\Oscdimg.exe"

# CreateIso: build an ISO from a source directory using Oscdimg
function CreateIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [string]$VolumeId = "cidata"
    )

    # Resolve current working directory
    $cwd = (Get-Location).ProviderPath

    # Make SourceDir absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($SourceDir)) {
        $SourceDir = Join-Path $cwd $SourceDir
    }
    $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

    if (-not (Test-Path -Path $SourceDir)) {
        Throw "SourceDir not found: $SourceDir"
    }

    # Make OutputFile absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
        $OutputFile = Join-Path $cwd $OutputFile
    }
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)

    # Ensure output directory exists
    $outDir = Split-Path -Path $OutputFile -Parent
    if ($outDir -and -not (Test-Path -Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    if (-not (Test-Path -Path $OscdimgPath)) {
        Throw "Oscdimg.exe not found at path: $OscdimgPath. Install the Windows ADK Deployment Tools or set ``-OscdimgPath`` to the proper location."
    }

    Write-Information "Creating ISO `nfrom '$SourceDir' `nto '$OutputFile' `nwith Volume ID '$VolumeId'..."
    & $OscdimgPath "$SourceDir" "$OutputFile" -n -h -m -l"$VolumeId"

    Write-Output "ISO created successfully at: $OutputFile"
}

# SHA-512 crypt ($6$) password hashing - pure PowerShell implementation
# Follows Ulrich Drepper's specification for SHA-512 based Unix crypt
# https://www.akkadia.org/drepper/SHA-crypt.txt
function Get-Sha512CryptHash {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$Rounds = 5000
    )

    $b64chars = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    # Generate random 16-character salt from b64 alphabet
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $saltRandom = New-Object byte[] 16
    $rng.GetBytes($saltRandom)
    $salt = ""
    foreach ($b in $saltRandom) { $salt += $b64chars[$b % 64] }

    $enc = [System.Text.Encoding]::UTF8
    $P = $enc.GetBytes($Password)
    $S = $enc.GetBytes($salt)
    $pLen = $P.Length
    $sLen = $S.Length
    $sha = [System.Security.Cryptography.SHA512]::Create()

    # Helper: take first N bytes from array, repeating as needed
    function RepeatBytes([byte[]]$Source, [int]$Length) {
        $result = New-Object byte[] $Length
        $srcLen = $Source.Length
        for ($i = 0; $i -lt $Length; $i++) { $result[$i] = $Source[$i % $srcLen] }
        $result
    }

    # Step 1: B = SHA512(P + S + P)
    $ms = New-Object System.IO.MemoryStream
    $ms.Write($P, 0, $pLen); $ms.Write($S, 0, $sLen); $ms.Write($P, 0, $pLen)
    $B = $sha.ComputeHash($ms.ToArray())

    # Steps 2-4: Build input for A
    $ms = New-Object System.IO.MemoryStream
    $ms.Write($P, 0, $pLen)
    $ms.Write($S, 0, $sLen)
    $bChunk = RepeatBytes $B $pLen
    $ms.Write($bChunk, 0, $bChunk.Length)

    # Process bits of password length
    $n = $pLen
    while ($n -gt 0) {
        if ($n -band 1) { $ms.Write($B, 0, $B.Length) }
        else { $ms.Write($P, 0, $pLen) }
        $n = $n -shr 1
    }
    $A = $sha.ComputeHash($ms.ToArray())

    # Step 5: DP = SHA512(P concatenated pLen times)
    $ms = New-Object System.IO.MemoryStream
    for ($i = 0; $i -lt $pLen; $i++) { $ms.Write($P, 0, $pLen) }
    $DP = $sha.ComputeHash($ms.ToArray())

    # Step 6: P-string = first pLen bytes of repeating DP
    $Pstring = RepeatBytes $DP $pLen

    # Step 7: DS = SHA512(S concatenated (16 + A[0]) times)
    $dsCount = 16 + [int]$A[0]
    $ms = New-Object System.IO.MemoryStream
    for ($i = 0; $i -lt $dsCount; $i++) { $ms.Write($S, 0, $sLen) }
    $DS = $sha.ComputeHash($ms.ToArray())

    # Step 8: S-string = first sLen bytes of repeating DS
    $Sstring = RepeatBytes $DS $sLen

    # Step 9: 5000 rounds of hashing
    $C = $A
    for ($i = 0; $i -lt $Rounds; $i++) {
        $ms = New-Object System.IO.MemoryStream
        if ($i % 2 -ne 0) { $ms.Write($Pstring, 0, $Pstring.Length) }
        else { $ms.Write($C, 0, $C.Length) }
        if ($i % 3 -ne 0) { $ms.Write($Sstring, 0, $Sstring.Length) }
        if ($i % 7 -ne 0) { $ms.Write($Pstring, 0, $Pstring.Length) }
        if ($i % 2 -ne 0) { $ms.Write($C, 0, $C.Length) }
        else { $ms.Write($Pstring, 0, $Pstring.Length) }
        $C = $sha.ComputeHash($ms.ToArray())
    }

    # Step 10: Encode with SHA-512 crypt custom base64
    # Byte permutation groups per Drepper's specification
    $groups = @(
        @(0,21,42), @(22,43,1),  @(44,2,23),  @(3,24,45),
        @(25,46,4), @(47,5,26),  @(6,27,48),  @(28,49,7),
        @(50,8,29), @(9,30,51),  @(31,52,10), @(53,11,32),
        @(12,33,54),@(34,55,13), @(56,14,35), @(15,36,57),
        @(37,58,16),@(59,17,38), @(18,39,60), @(40,61,19),
        @(62,20,41)
    )
    $hash = ""
    foreach ($g in $groups) {
        $v = ([int]$C[$g[0]] -shl 16) -bor ([int]$C[$g[1]] -shl 8) -bor [int]$C[$g[2]]
        for ($j = 0; $j -lt 4; $j++) { $hash += $b64chars[$v -band 0x3F]; $v = $v -shr 6 }
    }
    # Last byte
    $v = [int]$C[63]
    for ($j = 0; $j -lt 2; $j++) { $hash += $b64chars[$v -band 0x3F]; $v = $v -shr 6 }

    "`$6`$$salt`$$hash"
}

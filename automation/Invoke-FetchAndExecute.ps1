param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FilePath
)

# Configuration with environment overrides
$BaseUrl = if ($env:EXEC_BASE_URL) { $env:EXEC_BASE_URL } else { "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/" }
$QueryParams = if ($env:EXEC_QUERY_PARAMS) { $env:EXEC_QUERY_PARAMS } else { "?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }

# Construct and execute
$FullUrl = "${BaseUrl}${FilePath}${QueryParams}"
Invoke-Expression (Invoke-RestMethod -Uri $FullUrl)

# Write the localhost IP back for further processing
# Use DNS to get host addresses, filter for IPv4 and non-loopback, return first match
$hostname = [System.Net.Dns]::GetHostName()
$addresses = [System.Net.Dns]::GetHostAddresses($hostname) |
    Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($_) }

if ($addresses -and $addresses.Count -gt 0) {
    $ip_address = $addresses[0].IPAddressToString
} else {
    $ip_address = '127.0.0.1'
}

Write-Output "{ ""ip_address"": ""$ip_address"" }"
# Write the localhost IP back for further processing
$hostname=[System.Net.Dns]::GetHostByName($null).HostName
$ip_addresses =  $([System.Net.Dns]::GetHostAddresses($hostname) | where {$_.AddressFamily -notlike "InterNetworkV6"} | where {$_.IPAddressToString -notlike "127.0.0.1"} | foreach {echo $_.IPAddressToString })
$ip_address = $ip_addresses
if ($ip_addresses -is [array]) {
    $ip_address = $ip_addresses[0]
}
Write-Output "{ ""ip_address"": ""$ip_address"" }"
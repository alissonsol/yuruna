Push-Location $PSScriptRoot

$env:basePath = $HOME
echo "basePath: ${env:basePath}";

$env:pfxPath = ".aspnet/https/aspnetapp.pfx"
echo "pfxPath: ${env:pfxPath}";

$env:pfxFile = Join-Path -Path ${env:basePath} -ChildPath ${env:pfxPath}
echo "pfxFile: $env:pfxFile"

Copy-Item -Path $env:pfxFile -Destination . -Force;

Pop-Location

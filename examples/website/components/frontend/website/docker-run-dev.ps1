Push-Location $PSScriptRoot

.\copy-pfx.ps1

docker build --rm -f Dockerfile -t yrn42website-prefix/website:latest .
docker run --rm -it -p 8000:80 -p 8001:443 --name "yrn42website-prefix-example-website" -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 -e ASPNETCORE_Kestrel__Certificates__Default__Password="password" -e ASPNETCORE_Kestrel__Certificates__Default__Path=/app/aspnetapp.pfx yrn42website-prefix/website:latest

Pop-Location

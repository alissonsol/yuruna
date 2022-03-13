#!/bin/bash
# Docs: https://github.com/microsoft/Ironclad/tree/main/ironfleet
#   dotnet bin/CreateIronServiceCerts.dll outputdir=certs name=MyKV type=IronRSLKV addr1=127.0.0.1 port1=4001 addr2=127.0.0.1 port2=4002 addr3=127.0.0.1 port3=4003
#   becomes
#   dotnet bin/CreateIronServiceCerts.dll outputdir=certs name=MyKV type=IronRSLKV ${env:ironCerts}

echo "-- certs started --"

# Configuration
binariesDir="/workspace/Ironclad/ironfleet/bin/"
echo "certsName: ${certsName}"
echo "certsType: ${certsType}"
echo "certsDir: ${certsDir}"
echo "ironCerts: ${ironCerts}"

# CreateIronServiceCerts
dotnet ${binariesDir}/CreateIronServiceCerts.dll outputdir=${certsDir} name=${certsName} type=${certsType} ${ironCerts}

while true; do echo 'Hit CTRL+C'; sleep 60; done
echo "-- certs ended --"

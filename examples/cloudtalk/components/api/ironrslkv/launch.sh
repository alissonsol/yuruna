#!/bin/bash
# Example: https://github.com/microsoft/Ironclad/tree/main/ironfleet
# export IRON_PARAMS='127.0.0.1 4001 127.0.0.1 4002 127.0.0.1 4003 127.0.0.1 4001'

echo "-- launch started --"

# Install tools
# curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
# touch /etc/apt/sources.list.d/kubernetes.list 
# echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | tee -a /etc/apt/sources.list.d/kubernetes.list
# apt-get update
# apt-get install -y kubectl
# sleep 9

# Configuration
binariesDir="/workspace/Ironclad/ironfleet/bin/"
signalFile="signalFile"
podAddr=$(hostname -i)
echo "--"
echo "certsDir: ${certsDir}"
echo "certsServiceFile: ${certsServiceFile}"
echo "certsServerFile: ${certsServerFile}"
echo "signalFile: ${signalFile}"
echo "_ironinstance: ${_ironinstance}"
echo "podAddr: ${podAddr}"
echo "--"

# Waits for signal file
echo "Waiting for: ${signalFile}"
while [ ! -f ${signalFile} ]; do sleep 9; done
echo "Signal received"

# Now run with the IP parameters
# dotnet ${binariesDir}/IronRSLKVServer.dll ${certsDir}/${certsServiceFile} ${certsDir}/${certsServerFile} addr=localhost verbose=true
dotnet ${binariesDir}/IronRSLKVServer.dll ${certsDir}/${certsServiceFile} ${certsDir}/${certsServerFile} addr=${podAddr}

while true; do echo 'Hit CTRL+C'; sleep 60; done
echo "-- launch ended --"

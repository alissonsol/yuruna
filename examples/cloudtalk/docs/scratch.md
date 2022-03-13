# Scratch

Scratch pad for commands and investigations.

## Debugging summary

- Get terminal into `ironrslkvNNN`
- `env` shows the environment variables. Check `ironMachines`
- `ping` remote servers to confirm DNS resolution
- `netstat -ltnp` will show processes listening in a certain port
- `ifconfig` will show the network addresses
- `dotnet /workspace/Ironclad/ironfleet/bin/IronRSLKVClient.dll certs/certs.IronRSLKV.service.txt nthreads=10 duration=30 setfraction=0.25 deletefraction=0.05 print=true verbose=true`

## New debugging info

### macOS and ingress investigation

```shell

    - helm: >
        install nginx-ingress ingress-nginx/ingress-nginx
        --namespace ingress-ns
        --set controller.replicaCount=1
        --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux
        --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux
        --set controller.admissionWebhooks.enabled=false
        --set controller.ingressClass=${env:ingressClass}
        --set controller.service.type="LoadBalancer"
        --set controller.service.externalTrafficPolicy="Local"
        --set controller.service.loadBalancerIP="${env:_frontendIp}"
        --set tcp.${env:_ironServerPort001}="${env:_namespace001}/${env:ironPrefix}001:${env:_ironServerPort001}"
        --set tcp.${env:_ironServerPort002}="${env:_namespace002}/${env:ironPrefix}002:${env:_ironServerPort002}"
        --set tcp.${env:_ironServerPort003}="${env:_namespace003}/${env:ironPrefix}003:${env:_ironServerPort003}"
        --set controller.service.annotations."metallb\.universe\.tf/address-pool"="default"
        --debug
    # For localhost: metallb
    - shell: "$( $config = \"apiVersion: v1`nkind: ConfigMap`nmetadata:`n  namespace: metallb-system`n  name: config`ndata:`n  config: |`n    address-pools:`n    - name: default`n      protocol: layer2`n      addresses:`n      - ${env:_frontendIp}/32`n\"; $config | Out-File -FilePath ./config.yml ); $true"
    - kubectl: "delete namespace metallb-system --ignore-not-found=true --v=1"
    - kubectl: "create namespace metallb-system --v=1"
    - kubectl: "create secret generic -n metallb-system metallb-memberlist --from-literal=secretkey=\"$( $algo = new-Object System.Security.Cryptography.RijndaelManaged; $algo.KeySize=128; $algo.GenerateKey(); [Convert]::ToBase64String($algo.key) )\""
    - kubectl: "apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/metallb.yaml"
    - kubectl: "apply -f ./config.yml"

    # For localhost: hack using port forward - https://kubernetes.github.io/ingress-nginx/deploy/baremetal/
    - kubectl: "patch svc nginx-ingress-ingress-nginx-controller -n ingress-ns -p '{\\\"spec\\\": {\\\"type\\\": \\\"LoadBalancer\\\", \\\"externalIPs\\\":[\\\"${env:_frontendIp}\\\"]}}'"
    - shell: 'Write-Information ">>    Find and kill any other processes using TCP ports :80 and :443 with netstat"'
    - shell: 'Write-Information ">>    Localhost HACK. Manually execute: kubectl port-forward services/nginx-ingress-ingress-nginx-controller 80:80 443:443 -n ingress-nsF"'

```

###

### ingree issues

```shell

kubectl patch svc nginx-ingress-ingress-nginx-controller -n ingress-ns -p '{"spec": {"type": "LoadBalancer", "externalIPs":["192.168.1.19"]}}'

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/metallb.yaml

kubectl apply -f file.yml

file.yml

apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: | 
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 192.168.1.19/32
      
```

### 

Same issue before and after starting servers. Grave log.

```shell
00:22:30 - grava.Get[a]
-- RslDictionary.ContainsKey(a): Sending a request with sequence number 0 to IronfleetIoFramework.PublicIdentity
#timeout; rotating to server 1
Stopped authenticating connection to certs.IronRSLKV.server3 (key rLMOs+cd) @ cloudtalk003-azure.westus2.cloudapp.azure.com:42003 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
#timeout; rotating to server 2
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server3 (key rLMOs+cd) @ cloudtalk003-azure.westus2.cloudapp.azure.com:42003 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server2 (key sj5lYzAW) @ cloudtalk002-azure.northeurope.cloudapp.azure.com:42002 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server3 (key rLMOs+cd) @ cloudtalk003-azure.westus2.cloudapp.azure.com:42003 because of the following exception, but will try again later if necessary:
#timeout; rotating to server 0
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
#timeout; rotating to server 1
#timeout; rotating to server 2
```

ironrslkv log

```shell
-- launch started --
Warning: apt-key is deprecated. Manage keyring files in trusted.gpg.d instead (see apt-key(8)).
OK
deb http://apt.kubernetes.io/ kubernetes-xenial main
Hit:1 http://deb.debian.org/debian bullseye InRelease
Get:2 http://deb.debian.org/debian bullseye-updates InRelease [39.4 kB]
Get:3 http://security.debian.org/debian-security bullseye-security InRelease [44.1 kB]
Get:5 https://packages.microsoft.com/debian/11/prod bullseye InRelease [10.5 kB]
Get:4 https://packages.cloud.google.com/apt kubernetes-xenial InRelease [9383 B]
Get:6 http://security.debian.org/debian-security bullseye-security/main amd64 Packages [119 kB]
Get:7 https://packages.microsoft.com/debian/11/prod bullseye/main amd64 Packages [37.0 kB]
Get:8 https://packages.cloud.google.com/apt kubernetes-xenial/main amd64 Packages [53.9 kB]
Fetched 313 kB in 8s (38.6 kB/s)
Reading package lists...
Reading package lists...
Building dependency tree...
Reading state information...
The following NEW packages will be installed:
kubectl
0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.
Need to get 8927 kB of archives.
After this operation, 46.6 MB of additional disk space will be used.
Get:1 https://packages.cloud.google.com/apt kubernetes-xenial/main amd64 kubectl amd64 1.23.4-00 [8927 kB]
debconf: delaying package configuration, since apt-utils is not installed
Fetched 8927 kB in 1s (8119 kB/s)
Selecting previously unselected package kubectl.
(Reading database ... 
(Reading database ... 5%
(Reading database ... 10%
(Reading database ... 15%
(Reading database ... 20%
(Reading database ... 25%
(Reading database ... 30%
(Reading database ... 35%
(Reading database ... 40%
(Reading database ... 45%
(Reading database ... 50%
(Reading database ... 55%
(Reading database ... 60%
(Reading database ... 65%
(Reading database ... 70%
(Reading database ... 75%
(Reading database ... 80%
(Reading database ... 85%
(Reading database ... 90%
(Reading database ... 95%
(Reading database ... 100%
(Reading database ... 28472 files and directories currently installed.)
Preparing to unpack .../kubectl_1.23.4-00_amd64.deb ...
Unpacking kubectl (1.23.4-00) ...
Setting up kubectl (1.23.4-00) ...
--
certsDir: certs
certsServiceFile: certs.IronRSLKV.service.txt
certsServerFile: certs.IronRSLKV.server1.private.txt
signalFile: signalFile
_ironinstance: ironrslkv003
podAddr: 10.244.2.15
--
Waiting for: signalFile
Signal received
IronRSLKVServer program started
Processing command-line arguments
Deleted private key file after reading it since RSL servers should never run twice.
[[READY]]
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server2 (key sj5lYzAW) @ cloudtalk002-azure.northeurope.cloudapp.azure.com:42002 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server2 (key sj5lYzAW) @ cloudtalk002-azure.northeurope.cloudapp.azure.com:42002 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server1 (key lrdSWDOH) @ cloudtalk001-azure.eastus.cloudapp.azure.com:42001 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server2 (key sj5lYzAW) @ cloudtalk002-azure.northeurope.cloudapp.azure.com:42002 because of the following exception, but will try again later if necessary:
Stopped authenticating connection to certs.IronRSLKV.server3 (key rLMOs+cd) @ cloudtalk003-azure.westus2.cloudapp.azure.com:42003 because of the following exception, but will try again later if necessary:
```

### Test from terminal in some ironrsl container

```shell
/workspace# dotnet /workspace/Ironclad/ironfleet/bin/IronRSLKVClient.dll certs/certs.IronRSLKV.service.txt nthreads=10 duration=30 setfraction=0.25 deletefraction=0.05 print=true verbose=true
Client process starting 10 threads running for 30 s...
[[READY]]
Starting I/O scheduler as client with certificate CN=client (key pYvA232m)
Starting I/O scheduler as client with certificate CN=client (key 2AUl+qgE)
Waiting for the next send to dispatch
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Starting I/O scheduler as client with certificate CN=client (key rxP+YFvY)
Starting I/O scheduler as client with certificate CN=client (key wc2Zt6d3)
Starting I/O scheduler as client with certificate CN=client (key 4CjD3jCA)
Starting I/O scheduler as client with certificate CN=client (key yhjH3B8O)
Waiting for the next send to dispatch
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Starting I/O scheduler as client with certificate CN=client (key nstk+66E)
Starting I/O scheduler as client with certificate CN=client (key qq/CVvnN)
Creating sender thread to send to remote public key certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002
Waiting for the next send to dispatch
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Starting connection to certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Waiting for the next send to dispatch
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Starting I/O scheduler as client with certificate CN=client (key xYSVZlEU)
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Starting connection to certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Creating sender thread to send to remote public key certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002
Starting I/O scheduler as client with certificate CN=client (key n9KUf8PC)
Waiting for the next send to dispatch
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Waiting for the next send to dispatch
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Waiting for the next send to dispatch
Starting connection to certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Creating sender thread to send to remote public key certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002
Creating sender thread to send to remote public key certs.IronRSLKV.server3 (key raq5/vew) @ ironrslkv003.cloudtalk003:4003
Starting connection to certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Waiting for the next send to dispatch
Waiting for the next send to dispatch
Creating sender thread to send to remote public key certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Creating sender thread to send to remote public key certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002
Creating sender thread to send to remote public key certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002
Starting connection to certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Starting connection to certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001
Stopped connecting to certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001 because the connection was refused. Will try again later if necessary.
Starting connection to certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002
Stopped connecting to certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002 because the connection was refused. Will try again later if necessary.
Stopped connecting to certs.IronRSLKV.server1 (key vz92KEuQ) @ ironrslkv001.cloudtalk001:4001 because the connection was refused. Will try again later if necessary.
Stopped connecting to certs.IronRSLKV.server2 (key 4PtsaYAm) @ ironrslkv002.cloudtalk002:4002 because the connection was refused. Will try again later if necessary.
```

## Previous debugging info

Issue: lack of the `verbose=true`. Requests were submitted but never answered.

### Test from terminal in some ironrsl container

```shell
root@:/workspace# dotnet /workspace/Ironclad/ironfleet/bin/IronRSLKVClient.dll certs/certs.IronRSLKV.service.txt nthreads=10 duration=30 setfraction=0.25 deletefraction=0.05 print=true
[[READY]]
Submitting get request for iii
Submitting get request for zzz
Submitting set request for kkk => KKKK96271
Submitting get request for rrr
Submitting get request for ooo
Submitting get request for jjj
Submitting get request for uuu
Submitting get request for zzz
Submitting get request for ppp
Submitting set request for qqq => QQQQ30575
[[DONE]]
```

### Copy binaries from the ironrslkv container and certs from the ironrsl-certs container to the grava container

Using namespace "001" below. Below commands for PowerShell (`pwsh`). Go to some `temp` folder.

```shell
$_ironpod001 = $(kubectl get pods --selector=app=ironrslkv001 --all-namespaces --no-headers -o custom-columns=":metadata.name")
$_gravapod001 = $(kubectl get pods --selector=app=cloudtalk001-grava --all-namespaces --no-headers -o custom-columns=":metadata.name")

kubectl cp ${_ironpod001}:/workspace/Ironclad/ironfleet/bin/ ./bin --namespace cloudtalk001
kubectl cp ironrslkv-certs:/workspace/certs ./certs --namespace default
kubectl cp ./ ${_gravapod001}:/workspace --namespace cloudtalk001
```

### Test from terminal in the grava container

```shell
cd /workspace

# First install .NET 5.0 (used by ironrslkv) - Reference: https://www.makeuseof.com/install-dotnet-5-ubuntu-linux/
apt-get -y install wget
wget https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
apt-get update
apt-get -y install apt-transport-https
apt-get -y install dotnet-sdk-5.0

# Test with IronRSLKVClient
root@:/workspace# dotnet /workspace/bin/IronRSLKVClient.dll certs/certs.IronRSLKV.service.txt nthreads=10 duration=30 setfraction=0.25 deletefraction=0.05 print=true
[[READY]]
Submitting get request for ccc
Submitting get request for ooo
Submitting get request for ccc
Submitting get request for eee
Submitting get request for fff
Submitting set request for ccc => CCCC54164
Submitting set request for eee => EEEE46928
Submitting get request for fff
Submitting get request for kkk
Submitting get request for lll
[[DONE]]

# Test with the irontest.dll
cd /app
root@:/app# /app# dotnet irontest.dll a
Starting test!
-- RslDictionary.ContainsKey(a): -- RslDictionary.EnsureConnected()
Connected()
KVRequest request = new KVGetRequest(_key);
byte[] requestBytes = request.Encode();
byte[] replyBytes = _rslClient.SubmitRequest(requestBytes, isVerbose);
Sending a request with sequence number 0 to IronfleetIoFramework.PublicIdentity
#timeout; rotating to server 1
#timeout; rotating to server 2
#timeout; rotating to server 0
#timeout; rotating to server 1
#timeout; rotating to server 2
#timeout; rotating to server 0
#timeout; rotating to server 1
#timeout; rotating to server 2
#timeout; rotating to server 0
```

Back to main [readme](../README.md)

# TODO, DONE and Investigations

## TODO

- AWS, CGP resource templates

## DONE

- Linux: certs didn't stop and CPU may not be enough
- Debug: `/app# dotnet irontest.dll key`
  - IoFramework.cs -> SendLoop() issue.
    - ReportException() - Line 1111 - se.SocketErrorCode == SocketError.ConnectionRefused

    ```shell
    Stopped sending to [ExternalIP-ironrslvk001]:4001 because the connection was refused. Will try again later if necessary.
    Stopped sending to [ExternalIP-ironrslvk002]:4002 because the connection was refused. Will try again later if necessary.
    Stopped sending to [ExternalIP-ironrslvk003]:4003 because the connection was refused. Will try again later if necessary.
    ```
  - Problem was old version of the IronRSLClient package
- Error regarding the dictionaries: should use IDictionary for the variable pointing to the configurable implementation
  - Otherwise, it would be like casting to the base class all the time
- Solved by adding addr=127.0.0.1 to launch.sh
  - Old problem of the binding to the external pod service address not working.

```shell
   System.Net.Sockets.SocketException (99): Cannot assign requested address
   at System.Net.Sockets.Socket.UpdateStatusAfterSocketErrorAndThrowException(SocketError error, String callerName)
   at System.Net.Sockets.Socket.DoBind(EndPoint endPointSnapshot, SocketAddress socketAddress)
   at System.Net.Sockets.Socket.Bind(EndPoint localEP)
   at System.Net.Sockets.TcpListener.Start(Int32 backlog)
   at IronfleetIoFramework.ListenerThread.ListenLoop() in /workspace/Ironclad/ironfleet/src/Dafny/Distributed/Common/Native/IoFramework.cs:line 776
   at IronfleetIoFramework.ListenerThread.Run() in /workspace/Ironclad/ironfleet/src/Dafny/Distributed/Common/Native/IoFramework.cs:line 759
```

- DNS resolution issue
  - Needed to expose pods as services
- Docker build fails with exit 100
  - Clock sync issue. Reset and stop Docker. Restart machine/VM. Start Docker.
  - Tried this (from Internet) but didn't work
     - ENV TZ=America/Los_Angeles
     - RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
- Use the [`yuruna`](https://bit.ly/asol-yrn) scripts for automation. Now, check documentation for that framework regarding more of the operational procedures.
- Created CSharp project "website" as per instructions from [Tutorial: Get started with ASP.NET Core](https://docs.microsoft.com/en-us/aspnet/core/getting-started/?view=aspnetcore-3.1)
  - `dotnet new webapp -o website --no-https`
  - Test in Docker: `docker run -d -p 8080:8080 --name cloudtalk-website cloudtalk/website`
  - Browse to <http://localhost:8080>
- Created and containerized API project as per instructions for [ASP.NET Core in a container](https://code.visualstudio.com/docs/containers/quickstart-aspnet-core)
  - `dotnet new webapi -o grava --no-https`
  - Test in Docker: `docker run -d -p 8088:8088 --name cloudtalk-grava cloudtalk/grava`
  - Browse to <http://localhost:8088/weatherforecast/>
- Connected services using [IronRSLKVServer](https://github.com/microsoft/Ironclad/tree/main/ironfleet/src/IronRSLKVServer) for the KV replication. 

## Other options

- Antiforgery key persistence instead of ignoring error, as per guidance](https://docs.microsoft.com/en-us/aspnet/core/security/data-protection/configuration/overview)
- Connect services in service pool
- Test admin app to disconnect/connect servers dynamically
  - Investigate <https://jepsen.io/>
- HTTPS/TLS setup
- Cloud communications investigations
  - <https://networktest.twilio.com/>
  - <https://test.webrtc.org/>
- Options
  - Raft Consensus Algorithm: <https://raft.github.io/>
    - Visualization: [The Secret Lives of Data](http://thesecretlivesofdata.com/raft/)
    - C# implementation [.NEXT Raft Suite](https://github.com/sakno/dotNext/tree/master/src/cluster)
  - Zookeeper
    - [Because Coordinating Distributed Systems is a Zoo](https://zookeeper.apache.org/doc/current/zookeeperOver.html)
    - Docker [container](https://hub.docker.com/_/zookeeper)
    - Application: Java [KeptCollections](https://github.com/anthonyu/KeptCollections)

Back to main [readme](../README.md)

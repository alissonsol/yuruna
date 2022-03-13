# Notes

## Replication

NOTE:
- Unexpected Azure behavior: [How to make Azure not delete Public IP when deleting service / ingress-controller?](https://www.javaer101.com/en/article/75709569.html)
  - This also has its side-effects. Makes is better to `clear`, and then rebuild everything (`resources`, `components`, and `workloads`).

### Debugging DNS Resolution

See the corresponding article [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/).

### Ironfleet

Using [IronRSLKVServer](https://github.com/microsoft/Ironclad/tree/main/ironfleet/src/IronRSLKVServer) for the KV replication. Client connects to server as per the [Client.cs](https://github.com/microsoft/Ironclad/blob/main/ironfleet/src/IronRSLKVClient/Client.cs) code.

The client receives the `ironMachines` information as a space-separated sequence of servers and ports.

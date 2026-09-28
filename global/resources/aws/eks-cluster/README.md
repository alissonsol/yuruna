# EKS resource and workload contract

This template creates one untainted, on-demand x86-64 node group with exactly
`nodeCount` nodes of `nodeType`. Use an x86-64 instance type; ARM instance types
are incompatible with the selected AL2023 AMI. The public Kubernetes API is
restricted by `apiServerAuthorizedCidrs`, which must include the operator's
public egress address or VPN CIDR.

After provisioning, Bash and an authenticated AWS CLI import kubeconfig using
`destinationContext` as the context alias. The resource exports `clusterName`,
`clusterEndpoint`, and `destinationContext`.

Application ingress uses an internet-facing IPv4 Network Load Balancer with
one static Elastic IP in each of three public subnets. It routes TCP ports
80 and 443 to NodePorts 30080 and 30443 on the private worker nodes. Auto Scaling
attachments keep replacement nodes registered. Node security groups accept
these ports only from the load balancer's security group. Cross-zone balancing
allows any healthy worker to serve each ingress address.

Deploy the ingress controller with service type `NodePort`, HTTP NodePort 30080,
HTTPS NodePort 30443, and `externalTrafficPolicy: Cluster`. The AWS website
example in yuruna-project supplies these settings. Kubernetes does not create a
second load balancer. TLS terminates at the ingress controller.

`hostname` is the application's NLB DNS name. Prefer a CNAME or Route 53 alias
to this name; `frontendIp` is the first static IPv4 address for single-address
consumers, and `frontendIps` contains all three addresses. These are available
before workloads deploy, although health checks remain unhealthy until the
ingress pods are running. `clusterEndpoint` is only the control-plane API.

The template provisions billable NLB, EIP, NAT, and worker resources. Existing
clusters created with the older IPv6/example-node-group configuration require
review of the OpenTofu plan: changing the cluster IP family replaces the cluster,
and replacing the example groups drains their workloads. Preserve state and
backups and plan workload migration before applying to an existing deployment.

References: [NLB target groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html)
and [EKS managed node group outputs](https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.24.0/modules/eks-managed-node-group/outputs.tf).

Validate the template and run the isolated ingress plan tests without creating
cloud resources:

```sh
python3 global/resources/aws/eks-cluster/tests/verify.py /path/to/tofu
```

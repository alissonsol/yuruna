# `yuruna` examples

*NOTE*: Because some examples use the same ingress component and namespace, one may stop working after another using that component is deployed. If you "redeploy the ingress rules", then you can have the previously working example alive again! (And if you understood all this, you likely didn't need this warning anyway :-)

Read the Connectivity section of the [Frequently Asked Questions](../docs/faq.md).

## Basic end-to-end test

- [website](website/README.md): A simple .NET C# website container deployed to a Kubernetes cluster.

## cloudtalk

- [cloudtalk](cloudtalk/README.md) demonstrates key/value replication across nodes using the [IronRSL - Key-Value Store](https://github.com/microsoft/Ironclad/blob/main/ironfleet/README.md#ironrsl---key-value-store).

## Template

- This is just the [folder structure](../projects/template/) to create a new project.
  - Copy and paste folder structure to new folder.
  - Make needed changes and add component code (seek for `TO-SET`).

Back to main [readme](../../README.md)

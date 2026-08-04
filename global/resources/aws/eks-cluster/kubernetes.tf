# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Kubernetes provider
# https://learn.hashicorp.com/terraform/kubernetes/provision-eks-cluster#optional-configure-terraform-kubernetes-provider
# Scheduling deployments and services: https://learn.hashicorp.com/terraform/kubernetes/deploy-nginx-kubernetes

# The provider is declared here so Kubernetes resources added to this workspace can authenticate against the cluster.
# Do NOT schedule deployments and services in this workspace: keeping workspaces modular (one provisions EKS, another schedules Kubernetes resources) is the recommended practice.

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  token                  = data.aws_eks_cluster_auth.this.token
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
}

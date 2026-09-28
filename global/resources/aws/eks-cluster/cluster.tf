# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
locals {
  name             = var.clusterName
  cluster_version  = var.clusterVersion
  region           = var.resourceRegion
  desired_size     = var.nodeCount
  tags             = { resourceTags = var.resourceTags }
  authorized_cidrs = [for c in split(",", var.apiServerAuthorizedCidrs) : trimspace(c) if trimspace(c) != ""]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name                                     = local.name
  kubernetes_version                       = local.cluster_version
  endpoint_private_access                  = true
  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = local.authorized_cidrs
  enable_cluster_creator_admin_permissions = true
  ip_family                                = "ipv4"

  addons = {
    coredns = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  create_kms_key = false
  encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.nodeType]
      capacity_type  = "ON_DEMAND"
      min_size       = var.nodeCount
      max_size       = var.nodeCount
      desired_size   = var.nodeCount
    }
  }

  tags = local.tags
}

# Authentication remains available to the separately configured Kubernetes provider.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.name
  cidr = "10.0.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]



  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
  }

  tags = local.tags
}

resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption Key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.tags
}

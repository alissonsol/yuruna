# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/fixture/0123456789abcdef", dns_name = "fixture.elb.example.test" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/fixture/0123456789abcdef" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012" }
  }
}
mock_provider "kubernetes" {}
mock_provider "null" {}

variables {
  clusterDnsPrefix         = "fixture"
  clusterName              = "fixture"
  clusterVersion           = "1.36"
  nodeCount                = 3
  nodeType                 = "m5.large"
  nodeResourceGroup        = "fixture"
  resourceGroup            = "fixture"
  resourceRegion           = "us-east-1"
  resourceTags             = "fixture"
  destinationContext       = "fixture"
  apiServerAuthorizedCidrs = "192.0.2.1/32"
}

run "ingress_contract" {
  command = plan

  assert {
    condition     = length(module.eks.eks_managed_node_groups) == 1 && module.eks.eks_managed_node_groups["default"].desired_size == var.nodeCount && module.eks.eks_managed_node_groups["default"].min_size == var.nodeCount && module.eks.eks_managed_node_groups["default"].max_size == var.nodeCount && module.eks.eks_managed_node_groups["default"].instance_types == [var.nodeType]
    error_message = "The only worker group must honor the configured node type and count."
  }
  assert {
    condition     = module.eks.eks_managed_node_groups["default"].ami_type == "AL2023_x86_64_STANDARD" && module.eks.eks_managed_node_groups["default"].capacity_type == "ON_DEMAND" && !can(module.eks.eks_managed_node_groups["default"].taints)
    error_message = "Ordinary x86-64 workloads need untainted on-demand workers."
  }
  assert {
    condition     = length(aws_eip.frontend) == 3 && length(aws_lb.ingress.subnet_mapping) == 3
    error_message = "Every public subnet needs its own static ingress address."
  }
  assert {
    condition     = aws_lb.ingress.load_balancer_type == "network" && !aws_lb.ingress.internal && aws_lb.ingress.enable_cross_zone_load_balancing
    error_message = "Ingress must route public traffic across healthy worker zones."
  }
  assert {
    condition     = aws_lb_listener.ingress["http"].port == 80 && aws_lb_listener.ingress["https"].port == 443 && aws_lb_target_group.ingress["http"].port == 30080 && aws_lb_target_group.ingress["https"].port == 30443
    error_message = "External listener ports must agree with the workload NodePort contract."
  }
  assert {
    condition     = alltrue([for attachment in aws_autoscaling_attachment.ingress : attachment.autoscaling_group_name == "fixture-workers"])
    error_message = "Both ingress target groups must follow worker replacement."
  }
  assert {
    condition     = alltrue([for rule in aws_security_group_rule.ingress_nodes : rule.security_group_id == "sg-0123456789abcdef0" && rule.type == "ingress"])
    error_message = "Ingress NodePorts must be opened on the actual worker security group."
  }
}

run "reject_zero_nodes" {
  command = plan
  variables { nodeCount = 0 }
  expect_failures = [var.nodeCount]
}

run "reject_fractional_nodes" {
  command = plan
  variables { nodeCount = 1.5 }
  expect_failures = [var.nodeCount]
}

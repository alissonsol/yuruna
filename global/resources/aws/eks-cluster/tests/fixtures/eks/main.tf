# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
variable "name" { type = any }
variable "kubernetes_version" { type = any }
variable "endpoint_private_access" { type = any }
variable "endpoint_public_access" { type = any }
variable "endpoint_public_access_cidrs" { type = any }
variable "enable_cluster_creator_admin_permissions" { type = any }
variable "ip_family" { type = any }
variable "addons" { type = any }
variable "create_kms_key" { type = any }
variable "encryption_config" { type = any }
variable "vpc_id" { type = any }
variable "subnet_ids" { type = any }
variable "eks_managed_node_groups" { type = any }
variable "tags" { type = any }
output "cluster_name" { value = var.name }
output "cluster_arn" { value = "arn:aws:eks:us-east-1:123456789012:cluster/fixture" }
output "cluster_endpoint" { value = "https://fixture.example.test" }
output "cluster_certificate_authority_data" { value = "Zml4dHVyZQ==" }
output "node_security_group_id" { value = "sg-0123456789abcdef0" }
output "eks_managed_node_groups" {
  value = { for key, group in var.eks_managed_node_groups : key => merge(group, { node_group_autoscaling_group_names = ["fixture-workers"] }) }
}
